// xca_core.sv - single-width cross-correlation peak scorer
//
// One correlator pass at a fixed GAUSSIAN_WIDTH_BINS. peak_xca.sv runs two
// of these in parallel at different widths (see its header) and picks
// whichever scores higher, since the real target's spectral width scales
// with speed (confirmed against real captures - see project notes) and no
// single fixed width fits the whole speed range well.
//
// Besides the winning bin and its score, also reports the score of the
// immediate left/right neighbour bins (peak_corr_left/right), so the
// caller can do sub-bin interpolation without re-running the correlator.
module xca_core #(
    parameter int FFT_N = 4096,
    parameter int MIN_BIN = 1,                        // excludes DC/bin 0 only
    parameter int MAX_BIN = 225,                      // ~150 km/h cap at 40 deg mount, 23.4375 Hz/bin, with margin
    parameter int GAUSSIAN_WIDTH_BINS = 4             // sigma, in bins - only 3 or 9 have a ROM (see rom_sel below)
)(
    input logic clk,
    input logic rst_n,

    input logic                         power_valid,
    input logic [$clog2(FFT_N)-1:0]     power_bin,
    input logic [47:0]                  power_mag2,
    input logic                         power_last,

    output logic                        peak_valid,
    output logic [$clog2(FFT_N)-1:0]    peak_bin,
    output logic [47:0]                 peak_corr,       // winning bin's score
    output logic [47:0]                 peak_corr_left,  // score at peak_bin-1, for interpolation
    output logic [47:0]                 peak_corr_right  // score at peak_bin+1, for interpolation
);

localparam int HALF_WIDTH_BINS = 3 * GAUSSIAN_WIDTH_BINS; // taps beyond 3 sigma are ~zero, not worth storing
localparam int NUM_TAPS    = 2 * HALF_WIDTH_BINS + 1;
localparam int NUM_COEFFS  = HALF_WIDTH_BINS + 1;   // offsets 0..HALF_WIDTH_BINS, symmetry-folded
localparam int ADDR_W      = $clog2(NUM_COEFFS);
localparam int TRUNC_BITS  = 20;                    // see mag_trunc below
localparam int BIN_W       = $clog2(FFT_N);

// Correlator compares relative shape, not absolute magnitude, so only the
// top TRUNC_BITS of power_mag2 are kept (fixed right-shift, since mag2 is
// always non-negative) - keeps each tap's multiplier operand near the
// FPGA's native 18-bit width. Verified against real captures that bins
// near the true peak retain enough precision after truncation.
logic [TRUNC_BITS-1:0] mag_trunc;
// bin 0 (DC) is forced to zero here, not just excluded via MIN_BIN,
// because its magnitude would otherwise dominate the correlation sum of
// every window that includes it (bins 1..HALF_WIDTH_BINS).
assign mag_trunc = (power_bin == '0) ? '0 : power_mag2[47 -: TRUNC_BITS];

// Coefficients are fixed and known at compile time: walk the ROM's
// address space once at reset and latch every value into coeff_reg, so
// the parallel correlator has all taps available every cycle. Only
// sigma=3 and sigma=9 have a hand-authored ROM/mif pair right now (see
// quartus/scripts/gen_gaussian_mif.py) - add another generate branch and
// gaussian_rom_sigma<N>.v/.mif if a third width is ever needed.
logic [ADDR_W-1:0] coeff_addr;
logic [17:0]       coeff_q;
logic [17:0]       coeff_reg [0:NUM_COEFFS-1];
logic [ADDR_W-1:0] coeff_addr_q;
logic              coeff_addr_q_valid;
logic              coeffs_loaded;

generate
    if (GAUSSIAN_WIDTH_BINS == 3) begin : rom_sel
        gaussian_rom_sigma3 gaussian_rom_inst (.address(coeff_addr), .clock(clk), .q(coeff_q));
    end else if (GAUSSIAN_WIDTH_BINS == 9) begin : rom_sel
        gaussian_rom_sigma9 gaussian_rom_inst (.address(coeff_addr), .clock(clk), .q(coeff_q));
    end else begin : rom_sel
        // Quartus rejects $error in generate; unsupported widths get an all-zero
        // ROM, so the correlator scores zero everywhere and the mistake is obvious.
        assign coeff_q = '0;
    end
endgenerate

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        coeff_addr         <= '0;
        coeff_addr_q        <= '0;
        coeff_addr_q_valid <= 1'b0;
        coeffs_loaded      <= 1'b0;
    end else if (!coeffs_loaded) begin
        coeff_addr_q       <= coeff_addr;
        coeff_addr_q_valid <= 1'b1;
        if (coeff_addr != NUM_COEFFS[ADDR_W-1:0] - 1'b1)
            coeff_addr <= coeff_addr + 1'b1;

        if (coeff_addr_q_valid) begin
            coeff_reg[coeff_addr_q] <= coeff_q;
            if (coeff_addr_q == NUM_COEFFS[ADDR_W-1:0] - 1'b1)
                coeffs_loaded <= 1'b1;
        end
    end
end

// Matched-filter window is centered, not causal: the correlator needs
// bins before AND after the one it's scoring, but bins arrive one at a
// time. mag_shift holds the trailing window; bin/last/valid_delay carry
// the centered bin's metadata through the same delay so they stay matched
// to the correlation score describing it.
logic [TRUNC_BITS-1:0] mag_shift    [0:NUM_TAPS-1];
logic [BIN_W-1:0]      bin_delay    [0:HALF_WIDTH_BINS];
logic                  last_delay   [0:HALF_WIDTH_BINS];
logic                  valid_delay  [0:HALF_WIDTH_BINS];

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < NUM_TAPS; i++)
            mag_shift[i] <= '0;
        for (int i = 0; i <= HALF_WIDTH_BINS; i++) begin
            bin_delay[i]   <= '0;
            last_delay[i]  <= '0;
            valid_delay[i] <= '0;
        end
    end else if (power_valid) begin
        for (int i = NUM_TAPS - 1; i > 0; i--)
            mag_shift[i] <= mag_shift[i-1];
        mag_shift[0] <= mag_trunc;

        for (int i = HALF_WIDTH_BINS; i > 0; i--) begin
            bin_delay[i]   <= bin_delay[i-1];
            last_delay[i]  <= last_delay[i-1];
            valid_delay[i] <= valid_delay[i-1];
        end
        bin_delay[0]   <= power_bin;
        last_delay[0]  <= power_last;
        valid_delay[0] <= 1'b1;
    end
end

// coeff[k] == coeff[-k] (Gaussian symmetry): add paired taps before the
// shared multiply - NUM_COEFFS multiplies instead of NUM_TAPS.
logic [TRUNC_BITS:0]        sum_k     [0:HALF_WIDTH_BINS];
logic [TRUNC_BITS+18:0]     product_k [0:HALF_WIDTH_BINS];
logic [47:0]                corr_score;

always_comb begin
    sum_k[0] = {1'b0, mag_shift[HALF_WIDTH_BINS]};
    for (int k = 1; k <= HALF_WIDTH_BINS; k++)
        sum_k[k] = mag_shift[HALF_WIDTH_BINS-k] + mag_shift[HALF_WIDTH_BINS+k];

    for (int k = 0; k <= HALF_WIDTH_BINS; k++)
        product_k[k] = sum_k[k] * coeff_reg[k];

    corr_score = '0;
    for (int k = 0; k <= HALF_WIDTH_BINS; k++)
        corr_score += product_k[k];
end

// corr_score one cycle ago - by the time the center bin advances to B,
// this is B-1's score (its left neighbour). See running-max tracker below
// for how the right neighbour is captured (has to wait a cycle for B+1
// to actually arrive).
logic [47:0] corr_score_d1;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        corr_score_d1 <= '0;
    else if (power_valid)
        corr_score_d1 <= corr_score;
end

// Running-max tracker (same structure as peak_argmax.sv), but reading the
// delayed bin index. No DETECT_THRESHOLD gating here - peak_xca.sv applies
// that once it's picked which of the two cores actually won.
logic eligible;
assign eligible = valid_delay[HALF_WIDTH_BINS] &&
                   (bin_delay[HALF_WIDTH_BINS] >= MIN_BIN[BIN_W-1:0]) &&
                   (bin_delay[HALF_WIDTH_BINS] <= MAX_BIN[BIN_W-1:0]);

logic [47:0]      running_max_corr;
logic [BIN_W-1:0] running_max_bin;
logic [47:0]      running_max_left_corr;
logic [47:0]      running_max_right_corr;
logic             awaiting_right; // pulses for the one cycle after a new max, to catch its right neighbour

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        running_max_corr       <= '0;
        running_max_bin        <= '0;
        running_max_left_corr  <= '0;
        running_max_right_corr <= '0;
        awaiting_right          <= 1'b0;
        peak_valid              <= '0;
        peak_bin                <= '0;
        peak_corr               <= '0;
        peak_corr_left          <= '0;
        peak_corr_right         <= '0;
    end else begin
        peak_valid     <= '0; // default
        awaiting_right <= 1'b0; // default, pulses for exactly one cycle

        // the bin right after a new max is that max's right neighbour -
        // corr_score here is simply that next bin's own score
        if (awaiting_right)
            running_max_right_corr <= corr_score;

        if (eligible) begin
            // MIN_BIN is first eligible bin of the (delayed) frame
            if ((bin_delay[HALF_WIDTH_BINS] == MIN_BIN[BIN_W-1:0]) || (corr_score > running_max_corr)) begin
                running_max_corr      <= corr_score;
                running_max_bin       <= bin_delay[HALF_WIDTH_BINS];
                running_max_left_corr <= corr_score_d1;
                awaiting_right        <= 1'b1;
            end
        end

        if (valid_delay[HALF_WIDTH_BINS] && last_delay[HALF_WIDTH_BINS]) begin
            peak_valid      <= 1'b1;
            peak_bin        <= running_max_bin;
            peak_corr       <= running_max_corr;
            peak_corr_left  <= running_max_left_corr;
            peak_corr_right <= running_max_right_corr;
        end
    end
end

endmodule
