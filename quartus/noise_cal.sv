// noise_cal.sv - button-triggered per-bin baseline (static clutter / spur) subtraction
//
// Sits between power_stage and the peak finder. Until the first calibration
// it passes the spectrum through untouched. Pressing the button (cal_btn,
// active-low) starts a calibration: wait for a frame boundary, discard
// SETTLE_FRAMES frames (button-press vibration, filter settling), then
// average CAL_FRAMES frames of mag2 per bin. Afterwards every frame has the
// stored baseline subtracted per bin (clamped at 0), which removes anything
// that doesn't move between frames: ADC/clock spurs, TX leakage, the
// Nyquist spike, low-bin 1/f rise, static clutter. Do this with the radar
// powered and pointed at a static scene - an unpowered/unplugged capture is
// a different (much higher) floor and is not a valid baseline.
//
// During SETTLE/ACCUM the output is held invalid so nothing downstream
// reports detections from a half-built baseline. cal_busy flashes an LED.
//
// Baseline storage: one RAM holds the running per-bin SUM (not the mean).
// CAL_FRAMES is a power of two so the mean is just sum >> CAL_LOG2, applied
// at read time - no divide, no second RAM, and no clear pass (the first
// accumulation frame writes mag2 instead of adding to the old sum).
module noise_cal #(
    parameter int FFT_N         = 4096,
    parameter int CAL_LOG2      = 7,    // 2^7 = 128 frames, ~2.7 s at ~47 frames/s (4096-pt, 50% overlap, 96 kHz)
    parameter int SETTLE_FRAMES = 8,    // ~0.17 s discarded after the press
    parameter int DEBOUNCE_CYC  = 1_000_000 // 20 ms at 50 MHz
)(
    input logic clk,
    input logic rst_n,

    input logic cal_btn,          // raw active-low pushbutton (asynchronous)

    input logic                         power_valid,
    input logic [$clog2(FFT_N)-1:0]     power_bin,
    input logic [47:0]                  power_mag2,
    input logic                         power_last,

    output logic                        cal_valid,
    output logic [$clog2(FFT_N)-1:0]    cal_bin,
    output logic [47:0]                 cal_mag2,
    output logic                        cal_last,

    output logic                        cal_busy,   // settling or accumulating
    output logic                        cal_done    // a baseline is stored and being applied
);

localparam int BIN_W   = $clog2(FFT_N);
localparam int NBINS   = FFT_N / 2 + 1;            // half spectrum incl. Nyquist, matches power_stage
localparam int CAL_FRAMES = 1 << CAL_LOG2;
localparam int SUM_W   = 48 + CAL_LOG2;            // mag2 < 2^48, so CAL_FRAMES of them fit
localparam int CNT_W   = $clog2(CAL_FRAMES + SETTLE_FRAMES + 1);

// ---- button: 2FF sync -> debounce -> one-cycle press pulse ----
logic btn_s1, btn_s2, btn_stable, btn_stable_q;
logic [$clog2(DEBOUNCE_CYC+1)-1:0] deb_cnt;
logic press;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        btn_s1 <= 1'b1; btn_s2 <= 1'b1;
        btn_stable <= 1'b1; btn_stable_q <= 1'b1;
        deb_cnt <= '0;
    end else begin
        btn_s1 <= cal_btn;
        btn_s2 <= btn_s1;
        btn_stable_q <= btn_stable;
        if (btn_s2 == btn_stable) begin
            deb_cnt <= '0;
        end else if (deb_cnt == DEBOUNCE_CYC[$bits(deb_cnt)-1:0]) begin
            btn_stable <= btn_s2;
            deb_cnt    <= '0;
        end else begin
            deb_cnt <= deb_cnt + 1'b1;
        end
    end
end
assign press = btn_stable_q && !btn_stable;   // falling edge = pressed

// ---- calibration sequencer (state only changes on frame boundaries) ----
typedef enum logic [1:0] {RUN, WAIT_FRAME, SETTLE, ACCUM} state_t;
state_t state;
logic [CNT_W-1:0] frame_cnt;
logic             first_accum;   // next accumulated frame is the first -> overwrite, don't add
logic             have_base;
logic             req;           // press seen, waiting for the current frame to end

wire frame_end = power_valid && power_last;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= RUN;
        frame_cnt   <= '0;
        first_accum <= 1'b1;
        have_base   <= 1'b0;
        req         <= 1'b0;
    end else begin
        if (press && state == RUN) req <= 1'b1;   // presses during a calibration are ignored

        if (frame_end) begin
            case (state)
                RUN: if (req || press) begin
                    req       <= 1'b0;
                    state     <= SETTLE;
                    frame_cnt <= '0;
                end
                SETTLE: begin
                    if (frame_cnt == SETTLE_FRAMES[CNT_W-1:0] - 1'b1) begin
                        state       <= ACCUM;
                        frame_cnt   <= '0;
                        first_accum <= 1'b1;
                    end else begin
                        frame_cnt <= frame_cnt + 1'b1;
                    end
                end
                ACCUM: begin
                    first_accum <= 1'b0;
                    if (frame_cnt == CAL_FRAMES[CNT_W-1:0] - 1'b1) begin
                        state     <= RUN;
                        have_base <= 1'b1;
                    end else begin
                        frame_cnt <= frame_cnt + 1'b1;
                    end
                end
                default: state <= RUN;
            endcase
        end
    end
end

assign cal_busy = (state == SETTLE) || (state == ACCUM);
assign cal_done = have_base;

// ---- per-bin sum RAM: read at stage 0, add + write / subtract at stage 1 ----
(* ramstyle = "M9K, no_rw_check" *) logic [SUM_W-1:0] sum_ram [0:NBINS-1];
logic [SUM_W-1:0] sum_rd;

// stage-1 copies of the stream and the mode it was captured under
logic                s1_valid, s1_last, s1_accum, s1_first, s1_apply, s1_hold;
logic [BIN_W-1:0]    s1_bin;
logic [47:0]         s1_mag2;

wire in_range = (power_bin < NBINS[BIN_W-1:0]);

always_ff @(posedge clk) begin
    sum_rd <= sum_ram[power_bin];   // consecutive bins differ, so no read-during-write hazard
    if (s1_valid && s1_accum)
        sum_ram[s1_bin] <= s1_first ? SUM_W'(s1_mag2) : (sum_rd + SUM_W'(s1_mag2));
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s1_valid <= 1'b0;
        s1_last  <= 1'b0;
        s1_accum <= 1'b0;
        s1_first <= 1'b0;
        s1_apply <= 1'b0;
        s1_hold  <= 1'b0;
    end else begin
        s1_valid <= power_valid && in_range;
        s1_last  <= power_last;
        s1_bin   <= power_bin;
        s1_mag2  <= power_mag2;
        s1_accum <= (state == ACCUM);
        s1_first <= first_accum;
        s1_apply <= have_base && (state == RUN);
        s1_hold  <= cal_busy;
    end
end

// ---- output stage ----
wire [SUM_W-1:0] mean_full = sum_rd >> CAL_LOG2;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cal_valid <= 1'b0;
        cal_last  <= 1'b0;
        cal_bin   <= '0;
        cal_mag2  <= '0;
    end else begin
        cal_bin   <= s1_bin;
        cal_last  <= s1_last;
        // hold output off while a baseline is being built
        cal_valid <= s1_valid && !s1_hold;
        if (s1_apply)
            cal_mag2 <= (s1_mag2 > mean_full[47:0]) ? (s1_mag2 - mean_full[47:0]) : '0;
        else
            cal_mag2 <= s1_mag2;
    end
end

endmodule
