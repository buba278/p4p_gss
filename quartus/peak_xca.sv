// peak_xca.sv - cross-correlation peak tracker bank (replaces peak_argmax)
//
// Runs two xca_core correlator passes in parallel, one narrow (sigma=3)
// and one wide (sigma=9), and reports whichever scores higher. A single
// fixed template width can't fit the whole speed range: real captures
// show the target's spectral spread scaling with speed (matches the
// standard beamwidth-Doppler-spread relationship for this kind of radar -
// see project notes), roughly 2.5-3 bins at low speed and 9-10 bins at
// high speed. A mismatched template loses the correlator's whole
// advantage, so instead of picking one compromise width, both run and the
// better match wins.
//
// Also does sub-bin interpolation on the winning core's own output: a
// 3-point parabolic fit through the winning bin and its immediate
// neighbours (all already computed by xca_core, no extra correlation
// passes needed), giving peak_bin/peak_bin_frac as a fixed-point bin
// position instead of a bare integer. This is a different concern to the
// dual-width bank above - interpolation locates the peak precisely,
// GAUSSIAN_WIDTH_BINS is about matching the correlator's shape to the
// target's actual width - and doesn't need the width picked before it can
// run, since it only reads whichever core already won.
module peak_xca #(
    parameter int FFT_N = 4096,
    parameter int MIN_BIN = 1,                        // excludes DC/bin 0 only
    parameter int MAX_BIN = 225,                      // ~150 km/h cap at 40 deg mount, 23.4375 Hz/bin, with margin
    parameter int SIGMA_A = 3,                        // narrow core - low-speed returns
    parameter int SIGMA_B = 9,                        // wide core - high-speed returns
    parameter int BIN_FRAC_BITS = 4,                  // sub-bin resolution: 1/16 bin, matches bin_to_freq.sv's own FREQ_FRAC_BITS
    parameter logic [47:0] DETECT_THRESHOLD = 48'd1_169_886_992
                                                       // fixed (not CFAR-adaptive) correlation floor below which a
                                                       // frame reports "no target" (bin 0). Estimated from real
                                                       // treadmill captures - see quartus/scripts/estimate_xca_params.py.
)(
    input logic clk,
    input logic rst_n,

    // from power_stage
    input logic                         power_valid,
    input logic [$clog2(FFT_N)-1:0]     power_bin,
    input logic [47:0]                  power_mag2,
    input logic                         power_last,

    // pulses once per frame, once both correlator cores have reported
    output logic                        peak_valid,
    output logic [$clog2(FFT_N)-1:0]    peak_bin,       // integer part of the interpolated position
    output logic [BIN_FRAC_BITS-1:0]    peak_bin_frac,  // fractional part, in units of 1/2^BIN_FRAC_BITS of a bin
    output logic [47:0]                 peak_corr       // winning core's raw score (not a raw magnitude)
);

localparam int BIN_W = $clog2(FFT_N);

logic                a_valid, b_valid;
logic [BIN_W-1:0]    a_bin, b_bin;
logic [47:0]         a_corr, b_corr, a_left, a_right, b_left, b_right;

xca_core #(
    .FFT_N               (FFT_N),
    .MIN_BIN             (MIN_BIN),
    .MAX_BIN             (MAX_BIN),
    .GAUSSIAN_WIDTH_BINS (SIGMA_A)
) core_a (
    .clk             (clk),
    .rst_n           (rst_n),
    .power_valid     (power_valid),
    .power_bin       (power_bin),
    .power_mag2      (power_mag2),
    .power_last      (power_last),
    .peak_valid      (a_valid),
    .peak_bin        (a_bin),
    .peak_corr       (a_corr),
    .peak_corr_left  (a_left),
    .peak_corr_right (a_right)
);

xca_core #(
    .FFT_N               (FFT_N),
    .MIN_BIN             (MIN_BIN),
    .MAX_BIN             (MAX_BIN),
    .GAUSSIAN_WIDTH_BINS (SIGMA_B)
) core_b (
    .clk             (clk),
    .rst_n           (rst_n),
    .power_valid     (power_valid),
    .power_bin       (power_bin),
    .power_mag2      (power_mag2),
    .power_last      (power_last),
    .peak_valid      (b_valid),
    .peak_bin        (b_bin),
    .peak_corr       (b_corr),
    .peak_corr_left  (b_left),
    .peak_corr_right (b_right)
);

// The two cores have different pipeline depths (proportional to their own
// HALF_WIDTH_BINS), so their peak_valid pulses land on different cycles
// even though they're fed the same stream - wait for both before
// combining. Each core only pulses once per frame (min-bin re-arms its
// own running max), so "both since the last combine" is enough.
logic a_done, b_done, both_ready;
assign both_ready = (a_done | a_valid) & (b_done | b_valid);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        a_done <= 1'b0;
        b_done <= 1'b0;
    end else if (both_ready) begin
        a_done <= 1'b0;
        b_done <= 1'b0;
    end else begin
        if (a_valid) a_done <= 1'b1;
        if (b_valid) b_done <= 1'b1;
    end
end

logic             sel_b;      // which core's result is winning this combine
logic [BIN_W-1:0] sel_bin;
logic [47:0]      sel_corr, sel_left, sel_right;
assign sel_b     = b_corr > a_corr;
assign sel_bin   = sel_b ? b_bin   : a_bin;
assign sel_corr  = sel_b ? b_corr  : a_corr;
assign sel_left  = sel_b ? b_left  : a_left;
assign sel_right = sel_b ? b_right : a_right;

// 3-point parabolic interpolation on the winning core's own score at
// bin-1/bin/bin+1: offset (as a fraction of a bin) = 0.5*(left-right) /
// (left - 2*peak + right). Only evaluated once per frame - there are
// thousands of idle cycles before the next frame needs this again, so a
// plain combinational divide is fine; revisit only if post-fit timing
// actually needs it.
localparam int OFFSET_W = 64; // headroom for numer<<<(BIN_FRAC_BITS-1): 48-bit corr_score difference, shifted
localparam signed [OFFSET_W-1:0] OFFSET_MAX = (1 <<< (BIN_FRAC_BITS - 1)) - 1;
localparam signed [OFFSET_W-1:0] OFFSET_MIN = -(1 <<< (BIN_FRAC_BITS - 1));
logic signed [OFFSET_W-1:0] numer, denom, offset_raw, offset_clamped;

always_comb begin
    numer = $signed({2'b0, sel_left}) - $signed({2'b0, sel_right});
    denom = $signed({2'b0, sel_left}) - 2 * $signed({2'b0, sel_corr}) + $signed({2'b0, sel_right});
    if (denom == 0)
        offset_raw = '0;                                    // flat/degenerate - no meaningful vertex
    else
        offset_raw = (numer <<< (BIN_FRAC_BITS - 1)) / denom; // 0.5 * numer/denom, scaled to 1/2^BIN_FRAC_BITS units

    if (offset_raw > OFFSET_MAX)      offset_clamped = OFFSET_MAX;
    else if (offset_raw < OFFSET_MIN) offset_clamped = OFFSET_MIN;
    else                              offset_clamped = offset_raw;
end

logic signed [BIN_W+BIN_FRAC_BITS:0] bin_scaled_signed;
assign bin_scaled_signed = ($signed({1'b0, sel_bin}) <<< BIN_FRAC_BITS) + offset_clamped;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        peak_valid    <= '0;
        peak_bin      <= '0;
        peak_bin_frac <= '0;
        peak_corr     <= '0;
    end else begin
        peak_valid <= '0; // default

        if (both_ready) begin
            peak_valid <= 1'b1;
            peak_corr  <= sel_corr;
            // below threshold => no confident target this frame, report 0 km/h
            // once this flows through the unmodified bin_to_freq/freq_to_speed chain
            if (sel_corr >= DETECT_THRESHOLD) begin
                peak_bin      <= bin_scaled_signed[BIN_W+BIN_FRAC_BITS-1:BIN_FRAC_BITS];
                peak_bin_frac <= bin_scaled_signed[BIN_FRAC_BITS-1:0];
            end else begin
                peak_bin      <= '0;
                peak_bin_frac <= '0;
            end
        end
    end
end

endmodule
