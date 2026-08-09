// lcd_freq_display.sv
// ---------------------------------------------------------------------------
// Drives the DE2-115 on-board 16×2 HD44780-compatible LCD in simpler 8-bit mode.
//
// NOTE: this file is fully AI generated
//
// Line 1 : "Doppler Radar   "  — static, written once after init.
// Line 2 : "DDDDD Hz        "  — updated on every freq_valid pulse.
//
// ── Why RW tied to 0? ───────────────────────────────────────────────────────
// Reading the busy flag (BF) requires making DB7 an input, which in
// SystemVerilog means an inout port and three-state logic on lcd_data_r.
// Since we use fixed instruction-time delays instead (safe, and at a ~23 Hz
// update rate the extra idle cycles are imperceptible), we never need to
// read back. RW=0 keeps the whole data bus unidirectional output.
//
// ── Why snapshot into bcd_bin instead of reading freq_latched directly? ─────
// freq_latched can change on any freq_valid pulse, which fires independently
// of the LCD write sequence. If freq_latched changed mid-write, we could
// produce a garbled number (e.g. thousands digit from one update, units from
// the next). bcd_bin/dg4..dg0 are snapped and computed once at the start of
// each line-2 write (ST_L2_SNAP/ST_L2_BCD) and stay constant until that
// write completes.
//
// ── Timing reference ────────────────────────────────────────────────────────
// HD44780 AC Characteristics, VCC = 2.7–4.5 V table.
// The DE2-115 LCD I/O standard is 3.3 V (confirmed in Table 4-6 of the
// DE2-115 user manual), so we use this table rather than the 4.5–5.5 V one.
// All timing constants below include comfortable margin over the minimums.
// ---------------------------------------------------------------------------

module lcd_freq_display (
    input  logic        clk,           // 50 MHz
    input  logic        rst_n,         // active-low synchronous reset
    input  logic        freq_valid,    // single-cycle strobe from bin_to_freq
    input  logic [19:0] freq_scaled,   // Doppler peak frequency in Hz × 16

    // HD44780 interface (8-bit, write-only)
    output logic        LCD_RS,        // 0 = instruction register, 1 = data register
    output logic        LCD_RW,        // permanently 0 (always write)
    output logic        LCD_EN,        // active-high enable — LCD latches on falling edge
    output logic [7:0]  LCD_DATA,      // DB0–DB7
    output logic        LCD_ON         // 1 = LCD panel powered
);

// ===========================================================================
// Timing constants  (50 MHz clock → 1 cycle = 20 ns)
// ===========================================================================
//
//   tAS  (RS setup before E rises)  min 60 ns  → 10 cycles = 200 ns
//   PW_EH (E pulse high)            min 450 ns → 30 cycles = 600 ns
//   tH   (data hold after E falls)  min 10 ns  → 10 cycles = 200 ns
//   Instruction execution           max 37 µs  → 2 500 cycles = 50 µs
//   Display clear / return home     max 1.52ms → 100 000 cycles = 2 ms
//
// Init waits (Figure 23 of HD44780 datasheet, software initialisation path):
//   Power-on settling                min 40 ms → 2 500 000 cycles = 50 ms
//   After first 0x30 sync write      min 4.1ms → 250 000 cycles  =  5 ms
//   After second and third 0x30      min 100µs → 10 000 cycles   = 200 µs

localparam int E_SETUP  = 10;
localparam int E_HIGH   = 30;
localparam int E_HOLD   = 10;
localparam int T_INSTR  = 2_500;
localparam int T_CLEAR  = 100_000;
localparam int T_50MS   = 2_500_000;
localparam int T_5MS    = 250_000;
localparam int T_200US  = 10_000;
localparam int N_INIT   = 8;          // number of init commands sent

// DDRAM start addresses for each display line.
// Line 1 starts at 0x00, line 2 at 0x40 — they are not contiguous.
// The "set DDRAM address" instruction has bit 7 forced to 1, so the
// actual command bytes are 0x80 (line 1) and 0xC0 (line 2).
localparam logic [6:0] L1_ADDR = 7'h00;
localparam logic [6:0] L2_ADDR = 7'h40;

// ===========================================================================
// Constant outputs
// ===========================================================================
assign LCD_RW = 1'b0;
assign LCD_ON = 1'b1;

// ===========================================================================
// Registered LCD bus outputs
// ===========================================================================
logic lcd_rs_r, lcd_en_r;
logic [7:0] lcd_data_r;

assign LCD_RS   = lcd_rs_r;
assign LCD_EN   = lcd_en_r;
assign LCD_DATA = lcd_data_r;

// ===========================================================================
// Frequency latch
// ===========================================================================
// freq_latched: captures every freq_valid strobe asynchronously relative
// to the LCD write FSM.
// update_pending: set when a new value arrives, cleared when the sequencer
// starts consuming it (ST_L2_SNAP).
logic [19:0] freq_latched;
logic        update_pending;

// ---------------------------------------------------------------------------
// BCD digit extraction (double dabble, spread over 16 clock cycles)
// ---------------------------------------------------------------------------
// The original version of this block used `assign dgN = freq_hz / ... % ...`
// — combinational divide/modulo by a non-power-of-2 constant on a runtime
// value. Quartus synthesises that to a genuinely slow combinational divider
// chain (confirmed: 8 inferred lpm_divide megafunctions from this logic,
// producing a measured -16.7 ns setup violation on a 20 ns CLOCK_50 period).
// Because dg4..dg0 fed into dc4..dc0 which feeds lcd_data_r — the single
// register shared by every LCD write, init and line-1 text included — that
// one slow path could corrupt ANY write, not just the line-2 digits.
//
// Double dabble (shift-add-3) computes the same 5 BCD digits using only
// cheap per-cycle add/compare/shift logic, processing one bit of the 16-bit
// dividend per clock over 16 cycles (see ST_L2_BCD below) — comfortably
// inside the idle time already budgeted between ST_L2_SNAP and the digits
// actually being needed on the bus.
// Max useful value: Nyquist at 48 kHz = 24 000 Hz, well within 15 bits, so
// dg4's max digit is 2 and the 5-digit/20-bit BCD register is sufficient.
logic [3:0]  dg4, dg3, dg2, dg1, dg0;   // final digits, registered
logic [15:0] bcd_bin;                   // remaining dividend bits still to shift in
logic [19:0] bcd_digits;                // {dg4,dg3,dg2,dg1,dg0} in progress

// ---------------------------------------------------------------------------
// ASCII conversion with leading-zero suppression
// ---------------------------------------------------------------------------
// A digit shows as a space if it is zero AND all digits to its left are
// also zero (i.e. no non-zero digit has appeared yet from the left).
// The units digit (dc0) always shows — "0 Hz" is more readable than " Hz".
logic [7:0] dc4, dc3, dc2, dc1, dc0;
always_comb begin
    dc4 = (dg4 != 0)                                               ? (8'h30 + {4'b0, dg4}) : 8'h20;
    dc3 = (dg4 != 0 || dg3 != 0)                                  ? (8'h30 + {4'b0, dg3}) : 8'h20;
    dc2 = (dg4 != 0 || dg3 != 0 || dg2 != 0)                     ? (8'h30 + {4'b0, dg2}) : 8'h20;
    dc1 = (dg4 != 0 || dg3 != 0 || dg2 != 0 || dg1 != 0)        ? (8'h30 + {4'b0, dg1}) : 8'h20;
    dc0 =                                                            8'h30 + {4'b0, dg0};
end

// ===========================================================================
// State machine
// ===========================================================================
// Two-level structure:
//   Write-byte engine (ST_WB_*): handles the E-pulse timing for a single
//     8-bit write. Any sequencer state that needs to send a byte sets
//     lcd_rs_r, lcd_data_r, wb_wait, after_wb, cnt = E_SETUP-1, then jumps
//     to ST_WB_SETUP. The engine returns to after_wb when done.
//   Sequencer: walks through init commands, writes the static line-1 header,
//     then loops watching update_pending to write line 2 on each new value.

typedef enum logic [3:0] {
    ST_PWRWAIT,    // 50 ms power-on wait (before first E pulse)
    ST_WB_SETUP,   // E-pulse: RS+data stable, E=0, count E_SETUP
    ST_WB_EHIGH,   // E-pulse: E=1, count E_HIGH
    ST_WB_EHOLD,   // E-pulse: E=0 hold, count E_HOLD
    ST_WB_INSTR,   // E-pulse: instruction execution wait, count wb_wait
    ST_INIT_LOAD,  // load next init command and launch write-byte
    ST_INIT_NEXT,  // post-write: advance init_idx or move to line-1 write
    ST_L1_ADDR,    // send "set DDRAM 0x00" (line 1 start)
    ST_L1_CHARS,   // send one line-1 character
    ST_L1_NEXT,    // post-write: advance char_idx or move to READY
    ST_READY,      // idle: watch update_pending
    ST_L2_SNAP,    // snapshot freq_latched, kick off BCD conversion (no LCD write)
    ST_L2_BCD,     // double-dabble BCD conversion, 16 cycles (no LCD write)
    ST_L2_ADDR,    // send "set DDRAM 0x40" (line 2 start)
    ST_L2_CHARS,   // send one line-2 character
    ST_L2_NEXT     // post-write: advance char_idx or return to READY
} state_t;

state_t      state;
state_t      after_wb;    // "return address" for the write-byte sub-FSM
logic [21:0] cnt;         // shared countdown (max T_50MS = 2_500_000 → needs 22 bits)
logic [3:0]  init_idx;    // which init command is next  (0 .. N_INIT-1)
logic [3:0]  char_idx;    // which character of the current line (0 .. 15)
logic [21:0] wb_wait;     // instruction execution cycles for the current command

// ===========================================================================
// Frequency latch  (separate always_ff from the sequencer)
// ===========================================================================
// Separating these two always_ff blocks means each register has exactly one
// driver, avoiding implicit priority in a single monolithic process.
// The sequencer reads freq_latched and update_pending as normal registered
// signals (no combinatorial loops).
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        freq_latched   <= '0;
        update_pending <= 1'b0;
    end else begin
        if (freq_valid) begin
            // New valid data always wins — even if the sequencer is
            // simultaneously trying to clear update_pending (if freq_valid
            // fires on the same cycle as ST_L2_SNAP, we keep pending=1 so
            // the next READY pass picks up the fresh value).
            freq_latched   <= freq_scaled;
            update_pending <= 1'b1;
        end else if (state == ST_L2_SNAP) begin
            // Sequencer has acknowledged the pending update.
            update_pending <= 1'b0;
        end
    end
end

// ===========================================================================
// Sequencer + write-byte engine
// ===========================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= ST_PWRWAIT;
        cnt          <= 22'(T_50MS - 1);
        init_idx     <= '0;
        char_idx     <= '0;
        after_wb     <= ST_PWRWAIT;  // safe default
        wb_wait      <= 22'(T_INSTR);
        bcd_bin      <= '0;
        bcd_digits   <= '0;
        {dg4, dg3, dg2, dg1, dg0} <= '0;
        lcd_rs_r     <= 1'b0;
        lcd_en_r     <= 1'b0;
        lcd_data_r   <= 8'h00;
    end else begin
        case (state)

            // ---------------------------------------------------------------
            // Power-on wait
            // ---------------------------------------------------------------
            // The HD44780 needs ≥ 40 ms after VCC rises above 4.5 V (or ≥ 15 ms
            // above 2.7 V) before the first instruction. We wait 50 ms from
            // rst_n release to be safe even if the power supply is slow to settle.
            ST_PWRWAIT: begin
                lcd_en_r <= 1'b0;
                if (cnt == 0) begin
                    init_idx <= '0;
                    state    <= ST_INIT_LOAD;
                end else begin
                    cnt <= cnt - 1;
                end
            end

            // ---------------------------------------------------------------
            // Write-byte engine
            // ---------------------------------------------------------------
            // The calling state (INIT_LOAD, L1_ADDR, L1_CHARS, L2_ADDR,
            // L2_CHARS) sets lcd_rs_r and lcd_data_r before jumping here, so
            // those outputs are already stable on the first cycle of WB_SETUP.
            // The E-pulse timing is:
            //   E_SETUP cycles: E=0, RS+data stable (satisfies tAS ≥ 60 ns)
            //   E_HIGH  cycles: E=1 (satisfies PW_EH ≥ 450 ns)
            //   E_HOLD  cycles: E=0 hold (satisfies tH ≥ 10 ns)
            //   wb_wait cycles: E=0, instruction execution wait
            ST_WB_SETUP: begin
                lcd_en_r <= 1'b0;
                if (cnt == 0) begin
                    lcd_en_r <= 1'b1;             // E rises here (last cycle of setup)
                    cnt      <= 22'(E_HIGH - 1);
                    state    <= ST_WB_EHIGH;
                end else begin
                    cnt <= cnt - 1;
                end
            end

            ST_WB_EHIGH: begin
                lcd_en_r <= 1'b1;
                if (cnt == 0) begin
                    lcd_en_r <= 1'b0;             // E falls here; HD44780 latches data
                    cnt      <= 22'(E_HOLD - 1);
                    state    <= ST_WB_EHOLD;
                end else begin
                    cnt <= cnt - 1;
                end
            end

            ST_WB_EHOLD: begin
                lcd_en_r <= 1'b0;
                if (cnt == 0) begin
                    cnt   <= wb_wait - 1;         // load instruction execution time
                    state <= ST_WB_INSTR;
                end else begin
                    cnt <= cnt - 1;
                end
            end

            ST_WB_INSTR: begin
                lcd_en_r <= 1'b0;
                if (cnt == 0) begin
                    state <= after_wb;            // return to calling sequencer state
                end else begin
                    cnt <= cnt - 1;
                end
            end

            // ---------------------------------------------------------------
            // Initialisation sequence  (8-bit mode, Figure 23)
            // ---------------------------------------------------------------
            // The three 0x30 writes exist to synchronise the HD44780's internal
            // state machine. After a power cycle the controller could be at any
            // point in its command parser — mid-byte, mid-nibble, or idle. Sending
            // 0x30 (Function Set, DL=1) three times with the required inter-write
            // delays guarantees the controller ends up in a known state (idle,
            // awaiting a new 8-bit instruction) regardless of where it started.
            // Only after those three writes may the busy flag be read; we use
            // fixed delays instead for simplicity.
            ST_INIT_LOAD: begin
                lcd_rs_r <= 1'b0;   // all init writes target the instruction register
                case (init_idx)
                    // sync writes — N and F bits are don't-care; DL=1 selects 8-bit
                    4'd0: begin lcd_data_r <= 8'h30; wb_wait <= 22'(T_5MS);   end
                    4'd1: begin lcd_data_r <= 8'h30; wb_wait <= 22'(T_200US); end
                    4'd2: begin lcd_data_r <= 8'h30; wb_wait <= 22'(T_200US); end
                    // Function Set: DL=1 (8-bit), N=1 (2-line), F=0 (5×8 font)
                    4'd3: begin lcd_data_r <= 8'h38; wb_wait <= 22'(T_INSTR); end
                    // Display Off: D=0, C=0, B=0
                    4'd4: begin lcd_data_r <= 8'h08; wb_wait <= 22'(T_INSTR); end
                    // Display Clear: fills DDRAM with spaces, resets cursor to 0x00
                    // Takes up to 1.52 ms; T_CLEAR = 2 ms gives safe margin
                    4'd5: begin lcd_data_r <= 8'h01; wb_wait <= 22'(T_CLEAR); end
                    // Entry Mode: I/D=1 (auto-increment cursor), S=0 (no display shift)
                    4'd6: begin lcd_data_r <= 8'h06; wb_wait <= 22'(T_INSTR); end
                    // Display On: D=1 (display on), C=0 (cursor off), B=0 (no blink)
                    4'd7: begin lcd_data_r <= 8'h0C; wb_wait <= 22'(T_INSTR); end
                    default: begin lcd_data_r <= 8'h00; wb_wait <= 22'(T_INSTR); end
                endcase
                after_wb <= ST_INIT_NEXT;
                cnt      <= 22'(E_SETUP - 1);
                state    <= ST_WB_SETUP;
            end

            ST_INIT_NEXT: begin
                if (init_idx == 4'(N_INIT - 1)) begin
                    state <= ST_L1_ADDR;          // init complete; write static header
                end else begin
                    init_idx <= init_idx + 1'b1;
                    state    <= ST_INIT_LOAD;
                end
            end

            // ---------------------------------------------------------------
            // Line 1 — static header: "Doppler Radar   "
            // ---------------------------------------------------------------
            // "Set DDRAM Address" command format: bit 7 = 1, bits 6:0 = address.
            // Line 1 starts at 0x00, so the command byte is {1'b1, 7'h00} = 0x80.
            // Line 2 starts at 0x40 (not 0x10), so the command is 0xC0.
            // The two lines' DDRAM ranges are not contiguous in the HD44780 —
            // that's why we must re-issue a set-address command between lines.
            ST_L1_ADDR: begin
                lcd_rs_r   <= 1'b0;
                lcd_data_r <= {1'b1, L1_ADDR};   // 0x80
                wb_wait    <= 22'(T_INSTR);
                after_wb   <= ST_L1_CHARS;
                char_idx   <= '0;
                cnt        <= 22'(E_SETUP - 1);
                state      <= ST_WB_SETUP;
            end

            ST_L1_CHARS: begin
                // RS=1 selects the data register — writes go to DDRAM.
                // After each write the address counter auto-increments,
                // so we just send characters sequentially without re-issuing
                // a set-address command.
                lcd_rs_r <= 1'b1;
                case (char_idx)
                    4'd0:  lcd_data_r <= 8'h44;   // 'D'
                    4'd1:  lcd_data_r <= 8'h6F;   // 'o'
                    4'd2:  lcd_data_r <= 8'h70;   // 'p'
                    4'd3:  lcd_data_r <= 8'h70;   // 'p'
                    4'd4:  lcd_data_r <= 8'h6C;   // 'l'
                    4'd5:  lcd_data_r <= 8'h65;   // 'e'
                    4'd6:  lcd_data_r <= 8'h72;   // 'r'
                    4'd7:  lcd_data_r <= 8'h20;   // ' '
                    4'd8:  lcd_data_r <= 8'h52;   // 'R'
                    4'd9:  lcd_data_r <= 8'h61;   // 'a'
                    4'd10: lcd_data_r <= 8'h64;   // 'd'
                    4'd11: lcd_data_r <= 8'h61;   // 'a'
                    4'd12: lcd_data_r <= 8'h72;   // 'r'
                    4'd13: lcd_data_r <= 8'h20;   // ' '
                    4'd14: lcd_data_r <= 8'h20;   // ' '
                    4'd15: lcd_data_r <= 8'h20;   // ' '
                    default: lcd_data_r <= 8'h20;
                endcase
                wb_wait  <= 22'(T_INSTR);
                after_wb <= ST_L1_NEXT;
                cnt      <= 22'(E_SETUP - 1);
                state    <= ST_WB_SETUP;
            end

            ST_L1_NEXT: begin
                if (char_idx == 4'd15) begin
                    state <= ST_READY;
                end else begin
                    char_idx <= char_idx + 1'b1;
                    state    <= ST_L1_CHARS;
                end
            end

            // ---------------------------------------------------------------
            // Idle — wait for a frequency update
            // ---------------------------------------------------------------
            ST_READY: begin
                lcd_en_r <= 1'b0;
                if (update_pending) begin
                    state <= ST_L2_SNAP;
                end
            end

            // ---------------------------------------------------------------
            // Line 2 — dynamic frequency: "DDDDD Hz        "
            // ---------------------------------------------------------------
            ST_L2_SNAP: begin
                // Snapshot freq_latched (dropping the ×16 scale from
                // bin_to_freq via the >>4 slice) and kick off the double-
                // dabble BCD conversion in ST_L2_BCD. dg4..dg0 stay stable
                // once written, so dc4..dc0 are stable throughout the
                // 16-character write that follows.
                bcd_bin    <= freq_latched[19:4];
                bcd_digits <= '0;
                cnt        <= 22'(16 - 1);   // 16 double-dabble iterations
                state      <= ST_L2_BCD;
            end

            ST_L2_BCD: begin
                // One double-dabble step per cycle: add 3 to any BCD nibble
                // >= 5, then shift {digits, remaining bin} left by 1 — all
                // cheap combinational logic (5 parallel 4-bit add/compares
                // + a wired shift), unlike the divider chain this replaces.
                // On the final iteration, write straight through to the
                // registered dg4..dg0 instead of bouncing through bcd_digits
                // for one more cycle.
                logic [19:0] adj;
                logic [35:0] shifted;
                for (int i = 0; i < 5; i++) begin
                    adj[i*4 +: 4] = (bcd_digits[i*4 +: 4] >= 5) ? (bcd_digits[i*4 +: 4] + 4'd3)
                                                                  : bcd_digits[i*4 +: 4];
                end
                shifted = {adj, bcd_bin} << 1;
                if (cnt == 0) begin
                    {dg4, dg3, dg2, dg1, dg0} <= shifted[35:16];
                    state <= ST_L2_ADDR;
                end else begin
                    {bcd_digits, bcd_bin} <= shifted;
                    cnt <= cnt - 1'b1;
                end
            end

            ST_L2_ADDR: begin
                lcd_rs_r   <= 1'b0;
                lcd_data_r <= {1'b1, L2_ADDR};   // 0xC0
                wb_wait    <= 22'(T_INSTR);
                after_wb   <= ST_L2_CHARS;
                char_idx   <= '0;
                cnt        <= 22'(E_SETUP - 1);
                state      <= ST_WB_SETUP;
            end

            ST_L2_CHARS: begin
                // Display layout: positions 0-4 = 5 frequency digits (with
                // leading-zero suppression), position 5 = space, 6 = 'H',
                // 7 = 'z', positions 8-15 = spaces to blank any previous
                // longer number that may have been displayed.
                // dc4..dc0 derive from dg4..dg0 (registered by ST_L2_BCD) —
                // they do not change while we write this line.
                lcd_rs_r <= 1'b1;
                case (char_idx)
                    4'd0:    lcd_data_r <= dc4;
                    4'd1:    lcd_data_r <= dc3;
                    4'd2:    lcd_data_r <= dc2;
                    4'd3:    lcd_data_r <= dc1;
                    4'd4:    lcd_data_r <= dc0;
                    4'd5:    lcd_data_r <= 8'h20;   // ' '
                    4'd6:    lcd_data_r <= 8'h48;   // 'H'
                    4'd7:    lcd_data_r <= 8'h7A;   // 'z'
                    default: lcd_data_r <= 8'h20;   // spaces for positions 8–15
                endcase
                wb_wait  <= 22'(T_INSTR);
                after_wb <= ST_L2_NEXT;
                cnt      <= 22'(E_SETUP - 1);
                state    <= ST_WB_SETUP;
            end

            ST_L2_NEXT: begin
                if (char_idx == 4'd15) begin
                    state <= ST_READY;
                end else begin
                    char_idx <= char_idx + 1'b1;
                    state    <= ST_L2_CHARS;
                end
            end

            default: state <= ST_PWRWAIT;

        endcase
    end
end

endmodule
