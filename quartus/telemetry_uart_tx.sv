// telemetry_uart_tx.sv
// Replaces spectrum_uart_tx.sv: streams the raw (pre-Hamming-window) ADC
// samples that fed a frame's FFT, in addition to that frame's spectrum -
// requested for the 2026-08-20 treadmill test so the Python side can log
// raw+spectrum together to CSV instead of eyeballing a live plot, and
// verify the DSP pipeline (windowing/FFT/power) against the raw input
// offline. Same single UART link as before (no second pin available/wired
// on the DE2-115 header for this project) - each line now starts with a
// tag byte ('S' spectrum / 'A' raw ADC sample) so one Python script can
// demux both streams.
//
// Architecture is spectrum_uart_tx.sv's copy-then-drain pattern, run
// twice per cycle: copy+drain the spectrum snapshot (as before), then
// copy+drain a raw-sample snapshot, then repeat. See spectrum_uart_tx.sv's
// header for the full rationale behind mem_live/mem_snapshot and the
// ST_WAIT_FRAME copy-timing safety argument - identical reasoning applies
// to the raw-sample buffer, using fft_last as its own "just finished, safe
// to copy" marker.
//
// Caveat carried over from spectrum_uart_tx.sv: this is a slow, lossy,
// best-effort debug link, not the eventual CAN output. Draining both a
// 2049-entry spectrum snapshot AND a 4096-entry raw-sample snapshot every
// cycle is roughly 3x the line count spectrum_uart_tx.sv sent alone, so
// this link is correspondingly slower per update - fine for offline
// logging against a calibrated reference, not intended as a live scope.
//
// Also sends one "P" line per telemetry cycle carrying the pipeline's
// actual output (peak bin / frequency / speed) — added so the CSV logger
// can record what the pipeline decided alongside the raw data, not just
// what a human reads off the LCD. This is one line, not a whole buffer, so
// it's sent once at the start of every cycle (right after ST_WAIT_FRAME)
// using whatever the latest peak/freq/speed values are at that moment,
// rather than being tied to the multi-second spectrum+ADC drain cadence.
//
// Line formats (ASCII, one per line, '\n' terminated):
//   Spectrum: "S<3 hex bin><1 hex exp><4 hex mantissa><1 hex checksum>"
//             (unchanged encoding from spectrum_uart_tx.sv, just tagged)
//   Raw ADC:  "A<3 hex addr><6 hex sample><1 hex checksum>"
//             (addr 0..N-1, sample is the raw 24-bit two's-complement ADC
//             word, printed as plain hex - not compressed, small enough)
//   Peak:     "P<3 hex peak_bin><5 hex freq_scaled><10 hex speed_scaled><1 hex checksum>"
//             (freq_scaled is Hz*16 per bin_to_freq.sv, speed_scaled is
//             km/h*65536 per freq_to_speed.sv - both printed as plain hex,
//             raw enough for the receiver to just do the fixed-point math)
// checksum in all cases is the XOR of every nibble before it on the line
// (tag byte excluded - it's fixed per line kind and self-identifying).

module telemetry_uart_tx #(
    parameter int CLK_FREQ_HZ     = 50_000_000,
    parameter int BAUD_RATE       = 115_200,
    parameter int BIN_WIDTH       = 12,
    parameter int MAG_WIDTH       = 48,
    parameter int NUM_SPEC_BINS   = 2049,  // FFT_N/2 + 1: DC..Nyquist inclusive
    parameter int MANTISSA_DIGITS = 4,     // hex digits of mag2 precision kept
    parameter int ADC_WIDTH       = 24,
    parameter int NUM_ADC_SAMPLES = 4096,  // FFT_N: full raw window
    parameter int FREQ_WIDTH      = 20,    // must match bin_to_freq.sv's freq_scaled width
    parameter int SPEED_WIDTH     = 40     // must match freq_to_speed.sv's speed_scaled width
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // spectrum tap (post power_stage) - same as spectrum_uart_tx.sv
    input  logic                 power_valid,
    input  logic [BIN_WIDTH-1:0] power_bin,
    input  logic [MAG_WIDTH-1:0] power_mag2,
    input  logic                 power_last,

    // raw sample tap (post overlap_buffer, pre hamming_window) - the exact
    // window that fed the FFT for the spectrum above, one sample per addr
    input  logic                 adc_valid,
    input  logic [BIN_WIDTH-1:0] adc_addr,
    input  logic [ADC_WIDTH-1:0] adc_data,
    input  logic                 adc_last,

    // pipeline output tap (one value per frame) - see header
    input  logic                 peak_valid,
    input  logic [BIN_WIDTH-1:0] peak_bin,
    input  logic                 freq_valid,
    input  logic [FREQ_WIDTH-1:0] freq_scaled,
    input  logic                 speed_valid,
    input  logic [SPEED_WIDTH-1:0] speed_scaled,

    output logic                 uart_txd
);

localparam int MAG_NIBBLES   = MAG_WIDTH / 4;
localparam int MANTISSA_BITS = MANTISSA_DIGITS * 4;
localparam int ENTRY_WIDTH   = 4 + MANTISSA_BITS;   // exp nibble + mantissa
localparam int BIN_DIGITS    = BIN_WIDTH / 4;       // 12 bits -> 3 hex digits
localparam int ADC_NIBBLES   = ADC_WIDTH / 4;       // 24 bits -> 6 hex digits
localparam int FREQ_DIGITS   = FREQ_WIDTH / 4;      // 20 bits -> 5 hex digits
localparam int SPEED_DIGITS  = SPEED_WIDTH / 4;     // 40 bits -> 10 hex digits
localparam int MAX_DIGITS    = SPEED_DIGITS;        // widest field - sizes digit_cnt

function automatic logic [7:0] hex_ascii(input logic [3:0] nibble);
    hex_ascii = (nibble < 4'd10) ? (8'h30 + nibble) : (8'h41 + nibble - 8'd10);
endfunction

// index (0..MAG_NIBBLES-1) of the most-significant non-zero nibble
function automatic logic [3:0] msn_index(input logic [MAG_WIDTH-1:0] value);
    for (int i = MAG_NIBBLES-1; i >= 0; i--) begin
        if (value[i*4 +: 4] != 4'h0) begin
            return i[3:0];
        end
    end
    return 4'h0;
endfunction

function automatic logic [MANTISSA_BITS-1:0] extract_mantissa(
    input logic [MAG_WIDTH-1:0] value,
    input logic [3:0]           msn_idx
);
    int shift_nibbles;
    shift_nibbles = (msn_idx >= (MANTISSA_DIGITS-1)) ? (msn_idx - (MANTISSA_DIGITS-1)) : 0;
    extract_mantissa = value >> (shift_nibbles * 4);
endfunction

function automatic logic [3:0] spec_checksum(
    input logic [BIN_WIDTH-1:0]   bin,
    input logic [ENTRY_WIDTH-1:0] entry
);
    spec_checksum = '0;
    for (int i = 0; i < BIN_DIGITS; i++)
        spec_checksum ^= bin[i*4 +: 4];
    for (int i = 0; i < ENTRY_WIDTH/4; i++)
        spec_checksum ^= entry[i*4 +: 4];
endfunction

function automatic logic [3:0] adc_checksum(
    input logic [BIN_WIDTH-1:0] addr,
    input logic [ADC_WIDTH-1:0] data
);
    adc_checksum = '0;
    for (int i = 0; i < BIN_DIGITS; i++)
        adc_checksum ^= addr[i*4 +: 4];
    for (int i = 0; i < ADC_NIBBLES; i++)
        adc_checksum ^= data[i*4 +: 4];
endfunction

function automatic logic [3:0] peak_checksum(
    input logic [BIN_WIDTH-1:0]   bin,
    input logic [FREQ_WIDTH-1:0]  freq,
    input logic [SPEED_WIDTH-1:0] speed
);
    peak_checksum = '0;
    for (int i = 0; i < BIN_DIGITS; i++)
        peak_checksum ^= bin[i*4 +: 4];
    for (int i = 0; i < FREQ_DIGITS; i++)
        peak_checksum ^= freq[i*4 +: 4];
    for (int i = 0; i < SPEED_DIGITS; i++)
        peak_checksum ^= speed[i*4 +: 4];
endfunction

// ── live buffers: continuously overwritten off their source streams,
//    never read directly by the drain side (see spectrum_uart_tx.sv header
//    for why - tearing between write and slow-drain rates) ────────────────
logic [ENTRY_WIDTH-1:0] mem_live_spec     [0:NUM_SPEC_BINS-1];
logic [ENTRY_WIDTH-1:0] mem_snapshot_spec [0:NUM_SPEC_BINS-1];
logic [ADC_WIDTH-1:0]   mem_live_adc      [0:NUM_ADC_SAMPLES-1];
logic [ADC_WIDTH-1:0]   mem_snapshot_adc  [0:NUM_ADC_SAMPLES-1];

logic [3:0]               wr_exp;
logic [MANTISSA_BITS-1:0] wr_mantissa;
assign wr_exp      = msn_index(power_mag2);
assign wr_mantissa = extract_mantissa(power_mag2, wr_exp);

always_ff @(posedge clk) begin
    if (power_valid)
        mem_live_spec[power_bin] <= {wr_exp, wr_mantissa};
    if (adc_valid)
        mem_live_adc[adc_addr] <= adc_data;
end

// latest peak/freq/speed values - held until the next valid pulse for each.
// peak_valid -> freq_valid -> speed_valid fire in strict sequence a few
// cycles apart (same event working through bin_to_freq/freq_to_speed), and
// the next peak is a whole frame away, so whenever ST_PEAK_LATCH samples
// these below they're always a consistent (bin, freq, speed) triple for
// the same frame - not required to be in lockstep on the same cycle.
logic [BIN_WIDTH-1:0]   latched_peak_bin;
logic [FREQ_WIDTH-1:0]  latched_freq_scaled;
logic [SPEED_WIDTH-1:0] latched_speed_scaled;

always_ff @(posedge clk) begin
    if (peak_valid)  latched_peak_bin     <= peak_bin;
    if (freq_valid)  latched_freq_scaled  <= freq_scaled;
    if (speed_valid) latched_speed_scaled <= speed_scaled;
end

// ── copy-then-drain FSM: spectrum snapshot+drain, then raw-sample
//    snapshot+drain, then repeat. Each half mirrors spectrum_uart_tx.sv's
//    single-buffer FSM exactly, just run back to back. ────────────────────
typedef enum logic [4:0] {
    ST_WAIT_FRAME,      // idle until power_last (spectrum side just completed)
    ST_PEAK_LATCH,      // snapshot latest peak/freq/speed for this cycle's P line
    ST_PEAK_TAG,
    ST_PEAK_BIN,
    ST_PEAK_FREQ,
    ST_PEAK_SPEED,
    ST_PEAK_CHECKSUM,
    ST_PEAK_NEWLINE,
    ST_COPY_SPEC_ADDR,
    ST_COPY_SPEC_WRITE,
    ST_SPEC_ADDR,
    ST_SPEC_LATCH,
    ST_SPEC_TAG,
    ST_SPEC_BIN,
    ST_SPEC_EXP,
    ST_SPEC_MANTISSA,
    ST_SPEC_CHECKSUM,
    ST_SPEC_NEWLINE,
    ST_WAIT_ADC_FRAME,  // idle until adc_last (raw side just completed a window)
    ST_COPY_ADC_ADDR,
    ST_COPY_ADC_WRITE,
    ST_ADC_ADDR,
    ST_ADC_LATCH,
    ST_ADC_TAG,
    ST_ADC_ADDR_DIGITS,
    ST_ADC_DATA_DIGITS,
    ST_ADC_CHECKSUM,
    ST_ADC_NEWLINE
} state_t;

state_t                             state;
logic [BIN_WIDTH-1:0]               addr;  // shared index: copy phase, then read phase (both buffers)
logic [ENTRY_WIDTH-1:0]             live_rd_data_spec;
logic [ENTRY_WIDTH-1:0]             snap_rd_data_spec;
logic [ADC_WIDTH-1:0]               live_rd_data_adc;
logic [ADC_WIDTH-1:0]               snap_rd_data_adc;
logic [3:0]                         exp_reg;
logic [MANTISSA_BITS-1:0]           mantissa_shift;
logic [ADC_WIDTH-1:0]               adc_data_shift;
logic [BIN_WIDTH-1:0]               peak_bin_reg;
logic [FREQ_WIDTH-1:0]              freq_shift;
logic [SPEED_WIDTH-1:0]             speed_shift;
logic [3:0]                         checksum_reg;
logic [$clog2(MAX_DIGITS)-1:0]      digit_cnt;      // reused across all fixed-digit-count states (max width = SPEED_DIGITS=10)

always_ff @(posedge clk) begin
    live_rd_data_spec <= mem_live_spec[addr];
    snap_rd_data_spec <= mem_snapshot_spec[addr];
    live_rd_data_adc  <= mem_live_adc[addr];
    snap_rd_data_adc  <= mem_snapshot_adc[addr];
end

logic [7:0] tx_data;
logic       tx_valid;
logic       tx_ready;

always_comb begin
    tx_data  = 8'h00;
    tx_valid = 1'b0;
    unique case (state)
        ST_PEAK_TAG:       begin tx_data = "P";                                              tx_valid = 1'b1; end
        ST_PEAK_BIN:       begin tx_data = hex_ascii(peak_bin_reg[(BIN_DIGITS-1-digit_cnt)*4 +: 4]); tx_valid = 1'b1; end
        ST_PEAK_FREQ:      begin tx_data = hex_ascii(freq_shift[FREQ_WIDTH-1 -: 4]);          tx_valid = 1'b1; end
        ST_PEAK_SPEED:     begin tx_data = hex_ascii(speed_shift[SPEED_WIDTH-1 -: 4]);        tx_valid = 1'b1; end
        ST_PEAK_CHECKSUM:  begin tx_data = hex_ascii(checksum_reg);                           tx_valid = 1'b1; end
        ST_PEAK_NEWLINE:   begin tx_data = 8'h0A;                                             tx_valid = 1'b1; end
        ST_SPEC_TAG:       begin tx_data = "S";                                              tx_valid = 1'b1; end
        ST_SPEC_BIN:       begin tx_data = hex_ascii(addr[(BIN_DIGITS-1-digit_cnt)*4 +: 4]);  tx_valid = 1'b1; end
        ST_SPEC_EXP:       begin tx_data = hex_ascii(exp_reg);                                tx_valid = 1'b1; end
        ST_SPEC_MANTISSA:  begin tx_data = hex_ascii(mantissa_shift[MANTISSA_BITS-1 -: 4]);   tx_valid = 1'b1; end
        ST_SPEC_CHECKSUM:  begin tx_data = hex_ascii(checksum_reg);                           tx_valid = 1'b1; end
        ST_SPEC_NEWLINE:   begin tx_data = 8'h0A;                                             tx_valid = 1'b1; end
        ST_ADC_TAG:        begin tx_data = "A";                                               tx_valid = 1'b1; end
        ST_ADC_ADDR_DIGITS:begin tx_data = hex_ascii(addr[(BIN_DIGITS-1-digit_cnt)*4 +: 4]);   tx_valid = 1'b1; end
        ST_ADC_DATA_DIGITS:begin tx_data = hex_ascii(adc_data_shift[ADC_WIDTH-1 -: 4]);        tx_valid = 1'b1; end
        ST_ADC_CHECKSUM:   begin tx_data = hex_ascii(checksum_reg);                           tx_valid = 1'b1; end
        ST_ADC_NEWLINE:    begin tx_data = 8'h0A;                                             tx_valid = 1'b1; end
        default: ;
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= ST_WAIT_FRAME;
        addr           <= '0;
        exp_reg        <= '0;
        mantissa_shift <= '0;
        adc_data_shift <= '0;
        peak_bin_reg   <= '0;
        freq_shift     <= '0;
        speed_shift    <= '0;
        checksum_reg   <= '0;
        digit_cnt      <= '0;
    end else begin
        case (state)
            // -- peak/freq/speed line: one line, sent fresh at the start of
            // every telemetry cycle (see header) --
            ST_WAIT_FRAME: if (power_last) begin
                state <= ST_PEAK_LATCH;
            end

            ST_PEAK_LATCH: begin
                peak_bin_reg <= latched_peak_bin;
                freq_shift   <= latched_freq_scaled;
                speed_shift  <= latched_speed_scaled;
                checksum_reg <= peak_checksum(latched_peak_bin, latched_freq_scaled, latched_speed_scaled);
                digit_cnt    <= '0;
                state        <= ST_PEAK_TAG;
            end

            ST_PEAK_TAG: if (tx_ready) state <= ST_PEAK_BIN;

            ST_PEAK_BIN: if (tx_ready) begin
                if (digit_cnt == BIN_DIGITS-1) begin
                    digit_cnt <= '0;
                    state     <= ST_PEAK_FREQ;
                end else begin
                    digit_cnt <= digit_cnt + 1'b1;
                end
            end

            ST_PEAK_FREQ: if (tx_ready) begin
                freq_shift <= freq_shift << 4;
                if (digit_cnt == FREQ_DIGITS-1) begin
                    digit_cnt <= '0;
                    state     <= ST_PEAK_SPEED;
                end else begin
                    digit_cnt <= digit_cnt + 1'b1;
                end
            end

            ST_PEAK_SPEED: if (tx_ready) begin
                speed_shift <= speed_shift << 4;
                if (digit_cnt == SPEED_DIGITS-1) begin
                    digit_cnt <= '0;
                    state     <= ST_PEAK_CHECKSUM;
                end else begin
                    digit_cnt <= digit_cnt + 1'b1;
                end
            end

            ST_PEAK_CHECKSUM: if (tx_ready) state <= ST_PEAK_NEWLINE;

            ST_PEAK_NEWLINE: if (tx_ready) begin
                state <= ST_COPY_SPEC_ADDR;  // P line done - spectrum snapshot+drain as before
            end

            // -- spectrum snapshot + drain (mirrors spectrum_uart_tx.sv) --
            ST_COPY_SPEC_ADDR: state <= ST_COPY_SPEC_WRITE;

            ST_COPY_SPEC_WRITE: begin
                mem_snapshot_spec[addr] <= live_rd_data_spec;
                if (addr == NUM_SPEC_BINS-1) begin
                    addr  <= '0;
                    state <= ST_SPEC_ADDR;
                end else begin
                    addr  <= addr + 1'b1;
                    state <= ST_COPY_SPEC_ADDR;
                end
            end

            ST_SPEC_ADDR: state <= ST_SPEC_LATCH;

            ST_SPEC_LATCH: begin
                exp_reg        <= snap_rd_data_spec[ENTRY_WIDTH-1 -: 4];
                mantissa_shift <= snap_rd_data_spec[MANTISSA_BITS-1:0];
                checksum_reg   <= spec_checksum(addr, snap_rd_data_spec);
                digit_cnt      <= '0;
                state          <= ST_SPEC_TAG;
            end

            ST_SPEC_TAG: if (tx_ready) state <= ST_SPEC_BIN;

            ST_SPEC_BIN: if (tx_ready) begin
                if (digit_cnt == BIN_DIGITS-1) begin
                    digit_cnt <= '0;
                    state     <= ST_SPEC_EXP;
                end else begin
                    digit_cnt <= digit_cnt + 1'b1;
                end
            end

            ST_SPEC_EXP: if (tx_ready) state <= ST_SPEC_MANTISSA;

            ST_SPEC_MANTISSA: if (tx_ready) begin
                mantissa_shift <= mantissa_shift << 4;
                if (digit_cnt == MANTISSA_DIGITS-1) begin
                    digit_cnt <= '0;
                    state     <= ST_SPEC_CHECKSUM;
                end else begin
                    digit_cnt <= digit_cnt + 1'b1;
                end
            end

            ST_SPEC_CHECKSUM: if (tx_ready) state <= ST_SPEC_NEWLINE;

            ST_SPEC_NEWLINE: if (tx_ready) begin
                if (addr == NUM_SPEC_BINS-1) begin
                    addr  <= '0;
                    state <= ST_WAIT_ADC_FRAME;  // spectrum pass done - move on to the raw-sample pass
                end else begin
                    addr  <= addr + 1'b1;
                    state <= ST_SPEC_ADDR;
                end
            end

            // -- raw-sample snapshot + drain (same pattern, second buffer) --
            ST_WAIT_ADC_FRAME: if (adc_last) begin
                state <= ST_COPY_ADC_ADDR;
            end

            ST_COPY_ADC_ADDR: state <= ST_COPY_ADC_WRITE;

            ST_COPY_ADC_WRITE: begin
                mem_snapshot_adc[addr] <= live_rd_data_adc;
                if (addr == NUM_ADC_SAMPLES-1) begin
                    addr  <= '0;
                    state <= ST_ADC_ADDR;
                end else begin
                    addr  <= addr + 1'b1;
                    state <= ST_COPY_ADC_ADDR;
                end
            end

            ST_ADC_ADDR: state <= ST_ADC_LATCH;

            ST_ADC_LATCH: begin
                adc_data_shift <= snap_rd_data_adc;
                checksum_reg   <= adc_checksum(addr, snap_rd_data_adc);
                digit_cnt      <= '0;
                state          <= ST_ADC_TAG;
            end

            ST_ADC_TAG: if (tx_ready) state <= ST_ADC_ADDR_DIGITS;

            ST_ADC_ADDR_DIGITS: if (tx_ready) begin
                if (digit_cnt == BIN_DIGITS-1) begin
                    digit_cnt <= '0;
                    state     <= ST_ADC_DATA_DIGITS;
                end else begin
                    digit_cnt <= digit_cnt + 1'b1;
                end
            end

            ST_ADC_DATA_DIGITS: if (tx_ready) begin
                adc_data_shift <= adc_data_shift << 4;
                if (digit_cnt == ADC_NIBBLES-1) begin
                    digit_cnt <= '0;
                    state     <= ST_ADC_CHECKSUM;
                end else begin
                    digit_cnt <= digit_cnt + 1'b1;
                end
            end

            ST_ADC_CHECKSUM: if (tx_ready) state <= ST_ADC_NEWLINE;

            ST_ADC_NEWLINE: if (tx_ready) begin
                if (addr == NUM_ADC_SAMPLES-1) begin
                    addr  <= '0;
                    state <= ST_WAIT_FRAME;  // full cycle done - wait for the next spectrum frame
                end else begin
                    addr  <= addr + 1'b1;
                    state <= ST_ADC_ADDR;
                end
            end

            default: state <= ST_WAIT_FRAME;
        endcase
    end
end

uart_tx #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .BAUD_RATE   (BAUD_RATE)
) uart_tx_inst (
    .clk       (clk),
    .rst_n     (rst_n),
    .tx_data   (tx_data),
    .tx_valid  (tx_valid),
    .tx_ready  (tx_ready),
    .tx_serial (uart_txd)
);

endmodule
