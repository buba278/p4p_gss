// spectrum_uart_tx.sv
// Streams power_stage's per-bin spectrum output over UART, one line per bin:
//   "<bin><exp><mantissa><checksum>\n"   (3 hex digit bin index, 1 hex digit
//                                         exponent, 4 hex digit mantissa,
//                                         1 hex digit checksum)
//
// checksum is the XOR of all 8 nibbles above it (see entry_checksum below).
// This link has no other error detection, and the hex-float encoding makes
// a single corrupted byte expensive: a bit flip in the exponent nibble can
// shift the mantissa by up to 32 extra bits, turning a normal value into
// something ~1e9x too large. The checksum lets the receiver tell a
// corrupted line apart from a real (if noisy) one and drop it instead of
// plotting it as fact.
//
// The bin index is sent explicitly, not inferred by counting lines: on a
// link with no flow control, sustained loss is common enough (observed
// ~5-10% even after fixing the receive-side overrun that caused ~50% loss)
// that a count-based scheme would have one dropped line shift every bin
// after it for the rest of that sweep — which is what "PC display still
// wrong after checksum" turned out to be. With an explicit bin field, a
// dropped/corrupted line only loses that one bin (stays stale until the
// next sweep updates it); nothing downstream is affected.
//
// mag2 is compressed as a tiny hex float instead of sent raw (12 hex digits
// would be 2/3 of the line): exp is the index (0..11) of the most-significant
// non-zero nibble in the 48-bit value, mantissa is the 4 hex digits starting
// there. Reconstruct on the receiving end as:
//   value = (exp >= 3) ? (mantissa << ((exp-3)*4)) : mantissa
// Exact for small values (exp < 3, value fits in the mantissa outright),
// truncated (not rounded) for large ones — fine for a log-scale plot, and
// far better than a fixed right-shift, which would zero out anything below
// the shift threshold and flatten the noise floor.
//
// Architecture: mem_live is continuously overwritten by power_stage as bins
// stream through (mem_live[power_bin] <= ..., no gating) — draining one line
// over UART is far slower than one power_stage frame (tens of ms), so a full
// drain pass spans many frames' worth of writes. Reading mem_live directly
// while it's being drained would tear: early bins in a pass come from an
// older frame, later bins from several frames newer, since the write side
// laps ahead of the slow read sweep repeatedly during one pass (observed on
// hardware as a stair-step spectrum — each "step" is a chunk of bins from a
// different frame generation, stitched together into one line).
//
// mem_snapshot fixes that: at the start of each drain pass, mem_live is
// bulk-copied into mem_snapshot (~2049 cycles, ~41us at 50MHz — negligible
// next to the ~266ms drain), and the UART only ever reads from that frozen
// copy while draining. mem_live keeps changing underneath throughout the
// whole slow drain without affecting what's being sent; the next pass's
// copy just picks up whatever's most current at that point.
//
// The copy itself isn't safe to run at an arbitrary moment, though: if it
// happens to overlap power_stage's output burst for a frame (which, for a
// 4096-point FFT streamed out at 50MHz, is itself on the order of the same
// ~41us as the copy loop — not necessarily much longer, despite the "one
// stale bin" intuition that held when this was first written), the copy can
// tear mid-burst: addresses the new frame hasn't reached yet still hold
// last frame's value while later ones already have the new one, producing a
// wide flat plateau of stale data with a sharp step at each end (observed
// on hardware). ST_WAIT_FRAME below fixes this by only starting a copy
// right after power_last, when mem_live is guaranteed freshly complete and
// there's a comfortable idle gap (~42ms typical hop period) before the next
// burst can start.
//
// This is a best-effort/lossy debug telemetry link, not the eventual CAN
// output — each snapshot is a coherent single frame, but it's on the order
// of one drain period (~266ms) stale by the time it's fully sent, which is
// irrelevant for a live tuning display.

module spectrum_uart_tx #(
    parameter int CLK_FREQ_HZ    = 50_000_000,
    parameter int BAUD_RATE      = 921_600,
    parameter int BIN_WIDTH      = 12,
    parameter int MAG_WIDTH      = 48,
    parameter int NUM_BINS       = 2049,  // FFT_N/2 + 1: DC..Nyquist inclusive
    parameter int MANTISSA_DIGITS = 4     // hex digits of mag2 precision kept
)(
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 power_valid,
    input  logic [BIN_WIDTH-1:0] power_bin,
    input  logic [MAG_WIDTH-1:0] power_mag2,
    input  logic                 power_last,   // frame-boundary marker — see ST_WAIT_FRAME below

    output logic                 uart_txd
);

localparam int MAG_NIBBLES   = MAG_WIDTH / 4;
localparam int MANTISSA_BITS = MANTISSA_DIGITS * 4;
localparam int ENTRY_WIDTH   = 4 + MANTISSA_BITS;  // exp nibble + mantissa
localparam int BIN_DIGITS    = BIN_WIDTH / 4;       // hex digits to print the bin index (12 bits -> 3)

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

// ── live buffer: continuously overwritten off power_stage, never read
//    directly by the drain side ────────────────────────────────────────────
logic [ENTRY_WIDTH-1:0] mem_live     [0:NUM_BINS-1];
logic [ENTRY_WIDTH-1:0] mem_snapshot [0:NUM_BINS-1];

logic [3:0]               wr_exp;
logic [MANTISSA_BITS-1:0] wr_mantissa;
assign wr_exp      = msn_index(power_mag2);
assign wr_mantissa = extract_mantissa(power_mag2, wr_exp);

always_ff @(posedge clk) begin
    if (power_valid) begin
        mem_live[power_bin] <= {wr_exp, wr_mantissa};
    end
end

// ── copy-then-drain FSM: each pass first bulk-copies mem_live into the
//    static mem_snapshot, then walks mem_snapshot 0..NUM_BINS-1, one UART
//    line per entry, then repeats ──────────────────────────────────────────
typedef enum logic [3:0] {
    ST_WAIT_FRAME,  // idle until power_last — only then is mem_live guaranteed
                    // fully written by the frame just finished, with a quiet
                    // gap before the next frame's burst can start the copy
    ST_COPY_ADDR,   // addr just set, wait 1 cycle for mem_live's registered read
    ST_COPY_WRITE,  // live_rd_data now valid, commit it into mem_snapshot
    ST_ADDR,        // addr just set, wait 1 cycle for mem_snapshot's registered read
    ST_LATCH,       // snap_rd_data now valid, latch it and start transmitting
    ST_BIN,         // 3 hex digits, the bin index this line is for
    ST_EXP,
    ST_MANTISSA,
    ST_CHECKSUM,    // 1 hex digit, XOR of the bin+entry nibbles — lets the receiver
                    // detect a line corrupted in transit instead of trusting it
    ST_NEWLINE
} state_t;

state_t                             state;
logic [BIN_WIDTH-1:0]               addr;  // shared index: copy phase, then read phase
logic [ENTRY_WIDTH-1:0]             live_rd_data;
logic [ENTRY_WIDTH-1:0]             snap_rd_data;
logic [3:0]                         exp_reg;
logic [MANTISSA_BITS-1:0]           mantissa_shift;
logic [3:0]                         checksum_reg;  // XOR of all bin+entry nibbles — catches single-line bit errors
logic [$clog2(MANTISSA_DIGITS)-1:0] digit_cnt;      // reused across ST_BIN (3 digits) and ST_MANTISSA (4 digits)

// reduction XOR of every nibble in a line's bin index + entry — cheap error
// detection for a link with no other integrity check. Not a strong checksum
// (misses even numbers of bit flips landing in the same position), but it
// catches the case that actually matters here: a single corrupted byte
// inflating mag2 by orders of magnitude via the exponent field, or a
// corrupted bin field misrouting a value to the wrong bin entirely.
function automatic logic [3:0] entry_checksum(
    input logic [BIN_WIDTH-1:0]   bin,
    input logic [ENTRY_WIDTH-1:0] entry
);
    entry_checksum = '0;
    for (int i = 0; i < BIN_DIGITS; i++) begin
        entry_checksum ^= bin[i*4 +: 4];
    end
    for (int i = 0; i < ENTRY_WIDTH/4; i++) begin
        entry_checksum ^= entry[i*4 +: 4];
    end
endfunction

always_ff @(posedge clk) begin
    live_rd_data <= mem_live[addr];
    snap_rd_data <= mem_snapshot[addr];
end

logic [7:0] tx_data;
logic       tx_valid;
logic       tx_ready;

always_comb begin
    tx_data  = 8'h00;
    tx_valid = 1'b0;
    unique case (state)
        ST_BIN:      begin tx_data = hex_ascii(addr[(BIN_DIGITS-1-digit_cnt)*4 +: 4]);   tx_valid = 1'b1; end
        ST_EXP:      begin tx_data = hex_ascii(exp_reg);                              tx_valid = 1'b1; end
        ST_MANTISSA: begin tx_data = hex_ascii(mantissa_shift[MANTISSA_BITS-1 -: 4]); tx_valid = 1'b1; end
        ST_CHECKSUM: begin tx_data = hex_ascii(checksum_reg);                         tx_valid = 1'b1; end
        ST_NEWLINE:  begin tx_data = 8'h0A;                                           tx_valid = 1'b1; end // '\n'
        default: ;
    endcase
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= ST_WAIT_FRAME;
        addr           <= '0;
        exp_reg        <= '0;
        mantissa_shift <= '0;
        checksum_reg   <= '0;
        digit_cnt      <= '0;
    end else begin
        case (state)
            ST_WAIT_FRAME: if (power_last) begin
                state <= ST_COPY_ADDR;  // frame just completed — safe to copy until the next one's burst starts
            end

            ST_COPY_ADDR: begin
                state <= ST_COPY_WRITE;  // live_rd_data settles this cycle
            end

            ST_COPY_WRITE: begin
                mem_snapshot[addr] <= live_rd_data;
                if (addr == NUM_BINS-1) begin
                    addr  <= '0;
                    state <= ST_ADDR;  // copy done — start draining the frozen snapshot
                end else begin
                    addr  <= addr + 1'b1;
                    state <= ST_COPY_ADDR;
                end
            end

            ST_ADDR: begin
                state <= ST_LATCH;  // snap_rd_data settles this cycle
            end

            ST_LATCH: begin
                exp_reg        <= snap_rd_data[ENTRY_WIDTH-1 -: 4];
                mantissa_shift <= snap_rd_data[MANTISSA_BITS-1:0];
                checksum_reg   <= entry_checksum(addr, snap_rd_data);
                digit_cnt      <= '0;
                state          <= ST_BIN;
            end

            ST_BIN: if (tx_ready) begin
                if (digit_cnt == BIN_DIGITS-1) begin
                    digit_cnt <= '0;
                    state     <= ST_EXP;
                end else begin
                    digit_cnt <= digit_cnt + 1'b1;
                end
            end

            ST_EXP: if (tx_ready) begin
                state <= ST_MANTISSA;
            end

            ST_MANTISSA: if (tx_ready) begin
                mantissa_shift <= mantissa_shift << 4;
                if (digit_cnt == MANTISSA_DIGITS-1) begin
                    digit_cnt <= '0;
                    state     <= ST_CHECKSUM;
                end else begin
                    digit_cnt <= digit_cnt + 1'b1;
                end
            end

            ST_CHECKSUM: if (tx_ready) begin
                state <= ST_NEWLINE;
            end

            ST_NEWLINE: if (tx_ready) begin
                if (addr == NUM_BINS-1) begin
                    addr  <= '0;
                    state <= ST_WAIT_FRAME;  // full pass sent — wait for a quiet point before the next copy
                end else begin
                    addr  <= addr + 1'b1;
                    state <= ST_ADDR;
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
