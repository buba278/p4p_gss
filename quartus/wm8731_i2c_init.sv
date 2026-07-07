// wm8731_i2c_init.sv - setup the codec with I2C register writes
// - I2C address: 0x34 (7-bit: 0b0011010, CSB pin tied to GND on DE2-115)
// - write-only 2-wire mode, 100 kHz
// - data sent as: [device_addr+W] [B15:B8] [B7:B0] with ACK after each byte
// - NACK on any byte aborts the sequence: 
//   bus is cleanly STOPped, init_done never asserts

module wm8731_i2c_init (
    input  logic clk,        // 50 MHz FPGA system clock
    input  logic rst_n,      // active-low; tie to pll_locked so init waits for stable MCLK
    output logic scl,        // I2C clock (driven push-pull: we're the only master, see 3.1.1)
    inout  wire  sda,        // I2C data  (open-drain: we drive low or release to Z)
    output logic init_done,  // asserted permanently once all registers ACKed successfully
    output logic nack_error // sticky, non-blinking: asserted permanently if any byte was NACKed
);

// packed array of constants - synthesises to hardwired mux, not RAM (refer to wm8731 datasheet "Software Control")
localparam int NUM_REGS = 8;
localparam logic [15:0] PROGRAM_REGISTERS [0:NUM_REGS-1] = '{
    // reg data (7 bit address + 9 bits of data), reg description
    // order based on usage - leave stuff as "flat" as possible + only use left line (we are mono)
    16'h1E00,  // R15 Reset: write 0x00 once trigger hardware reset
    16'h0017,  // R0  Left Line In: LINVOL=10111 (0 dB), LINMUTE=0, LRINBOTH=0 (independent L/R control)
    16'h0802,  // R4  Analogue Audio Path:
               //     MICBOOST=0 (no mic preamp boost)
               //     MUTEMIC=1  (mute mic input — we use line-in, not mic)
               //     INSEL=0    (select line-in as ADC input, not microphone)
               //     BYPASS=0, DACSEL=0, SIDETONE=0 (no bypass path to output)
    16'h0A08,  // R5  Digital Audio Path:
               //     ADCHPD=0   (HPF enabled - removes DC offset from ADC output before digital output)
               //     DEEMP=00   (no de-emphasis, its for audio tuning)
               //     DACMU=1    (mute DAC, we not playing anything back)
    16'h0C7A,  // R6  Power Down Control:
               //     LINEINPD=0 (line-in ON, needed for ADC)
               //     MICPD=1    (mic input OFF, saves power, we use line-in)
               //     ADCPD=0    (ADC ON, so we can get values from our input)
               //     DACPD=1    (DAC OFF, no outputs)
               //     OUTPD=1    (line/headphone output OFF)
               //     OSCPD=1    (internal crystal oscillator OFF, we supply MCLK "externally")
               //     CLKOUTPD=1 (CLKOUT pin OFF, we dont need codec CLK to be outputted - save power)
               //     POWEROFF=0 (device ON)
    16'h0E4A,  // R7  Digital Audio Interface Format:
               //     FORMAT=10  (I2S mode, MSB delayed 1 BCLK after LRCLK edge - default)
               //     IWL=10     (24-bit word length = full resolution)
               //     LRP=0      (normal LRCLK polarity)
               //     LRSWAP=0   (no channel swap)
               //     MS=1       (MASTER mode, codec drives BCLK (from MCLK) and LRCLK) - no phase alignment needed
               //     BCLKINV=0  (dont care - just default)
    16'h101D,  // R8  Sampling Control (USB mode, 96 kHz):
               //     USB/NORMAL=1  (USB mode: MCLK = 12.000 MHz)
               //     BOSR=0        (250fs oversampling base rate, Table 22 WM8731 datasheet)
               //     SR=0111       (selects 96 kHz for both ADC and DAC)
               //     CLKIDIV2=0, CLKODIV2=0 (use full MCLK as core clock)
    16'h1201   // R9  Active Control: ACTIVE=1 (start I2S interface) do last and once active, changing other registers
};

// --- clock divider ---
// 100 kHz I2C, 4 timing phases per bit (setup/rise/hold/fall).
// PHASE_CYCLES = 50 MHz / 4 / 100 kHz = 125 clk cycles -> 2.5 us/phase.
// Steady-state bit clocking: tLOW = 2 phases = 5.0 us (spec min 4.7 us),
// tHIGH = 2 phases = 5.0 us (spec min 4.0 us) -> fully compliant at 100 kHz.
// Only the START/STOP-specific parameters (tSU;STA, tHD;STA, tSU;STO, each
// spec min ~4.0-4.7 us) don't fit in a single 2.5 us phase - handled below
// by holding those specific states for 2 ticks instead of 1.
localparam int PHASE_CYCLES = 125; // in cycles

logic [6:0] cycle_cnt;
logic phase_tick; // one-cycle enable pulse every PHASE_CYCLES system clocks

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cycle_cnt  <= '0;
        phase_tick <= 1'b0;
    end else begin
        phase_tick <= 1'b0;
        if (cycle_cnt == PHASE_CYCLES - 1) begin
            cycle_cnt  <= '0;
            phase_tick <= 1'b1;
        end else
            cycle_cnt <= cycle_cnt + 1'b1;
    end
end

// --- FSM ---
// Every bit occupies 4 ticks (UM10204 3.1.3, 3.1.5):
//   phase 0: SCL=0, set SDA to the bit we're sending
//   phase 1: SCL rises  (SDA must be stable before this - target samples on the high)
//   phase 2: SCL=1 held (ACK bit is also sampled here, mid-high)
//   phase 3: SCL falls  (SDA may change after this)
// START/STOP are the deliberate exception to "SDA only changes while SCL is
// low": SDA transitions while SCL is HIGH mark start/stop instead (3.1.4).

typedef enum logic [3:0] {
    S_IDLE,      // bus free; 2-tick hold for tSU;STA before generating START
    S_START_A,   // SCL=1, SDA falls <- START condition; 2-tick hold for tHD;STA
    S_START_B,   // SCL falls, load address byte
    S_SEND,      // generic bit sending (4 phases x bit_cnt bits)
    S_ACK,       // release SDA for one bit period; sample it back for ACK/NACK
    S_STOP_A,    // SCL=0, SDA=0 (precondition for STOP)
    S_STOP_B,    // SCL rises; 2-tick hold for tSU;STO before SDA rises
    S_STOP_C,    // SDA rises while SCL=1 <- STOP condition
    S_STOP_D,    // decide: next register, error halt, or done
    S_GAP,       // tBUF: bus-free time between a STOP and the next START
    S_DONE,      // init_done=1, stay here forever
    S_ERROR      // nack_error=1, stay here forever (init_done never asserts)
} state_t;

state_t     state;
logic [1:0] bit_phase; // 0..3 within a bit period; also reused as a plain
                       // used as 2-tick counter in S_IDLE/S_START_A/S_STOP_B, where
                       // "phase" doesn't apply but a 2-tick hold is still needed
logic [2:0] bit_cnt;   // counts bits 7..0 within the current byte (MSB first)
logic [3:0] reg_idx;   // which PROGRAM_REGISTERS entry we're writing (0..8)
logic [4:0] gap_cnt;   // tBUF counter: 15 ticks x 2.5 us = 37.5 us, > 4.7 us min

// SDA output control: open-drain (3.1.1) 
// driving rather than pull up as single device
logic sda_o, sda_oe;
assign sda = sda_oe ? sda_o : 1'bz; 

logic [7:0] tx_byte;   // byte currently being serialised (shifted left after each bit)
logic       ack_bit;   // SDA sampled during the ACK window: 0=ACK, 1=NACK (3.1.6)

// After each ACK phase, track what to load/send next:
//   ack_phase 0 -> just ACKed address    -> load register's high byte
//   ack_phase 1 -> just ACKed high byte  -> load register's low byte
//   ack_phase 2 -> just ACKed low byte   -> go to STOP
logic [1:0] ack_phase;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= S_IDLE;
        bit_phase  <= '0;
        bit_cnt    <= 3'd7;
        reg_idx    <= '0;
        gap_cnt    <= '0;
        ack_phase  <= '0;
        scl      <= 1'b1;
        sda_o      <= 1'b1;
        sda_oe     <= 1'b1;
        init_done  <= 1'b0;
        nack_error <= 1'b0;
        ack_bit    <= 1'b0;
        tx_byte    <= 8'h34; // harmless known default at reset
    end else if (phase_tick) begin
        case (state)

            // IDLE: hold bus free for 2 ticks (tSU;STA) before generating START
            S_IDLE: begin
                scl  <= 1'b1;
                sda_o  <= 1'b1;
                sda_oe <= 1'b1;
                if (bit_phase == 2'd0) begin
                    bit_phase <= 2'd1;
                end else begin
                    bit_phase <= 2'd0;
                    state     <= S_START_A;
                end
            end

            // START condition: SDA falls while SCL=1; hold 2 ticks (tHD;STA)
            // before dropping SCL, per UM10204 Table 11.
            S_START_A: begin
                scl  <= 1'b1;
                sda_o  <= 1'b0;     // SDA falls -> START
                sda_oe <= 1'b1;
                if (bit_phase == 2'd0) begin
                    bit_phase <= 2'd1;
                end else begin
                    bit_phase <= 2'd0;
                    state     <= S_START_B;
                end
            end

            // SCL falls after START - load the address+W byte and start clocking it
            S_START_B: begin
                scl       <= 1'b0;
                tx_byte   <= 8'h34;     // I2C device address (0x34) + W=0
                bit_cnt   <= 3'd7;
                ack_phase <= 2'd0;
                bit_phase <= 2'd0;
                state     <= S_SEND;
            end

            // Generic byte send (address, high byte, low byte all use this)
            S_SEND: begin
                case (bit_phase)
                    2'd0: begin
                        scl     <= 1'b0;
                        sda_o     <= tx_byte[7];   // MSB first (3.1.5)
                        sda_oe    <= 1'b1;
                        bit_phase <= 2'd1;
                    end
                    2'd1: begin
                        scl     <= 1'b1;
                        bit_phase <= 2'd2;
                    end
                    2'd2: begin
                        // hold - target samples SDA here
                        bit_phase <= 2'd3;
                    end
                    2'd3: begin
                        scl <= 1'b0;
                        if (bit_cnt == 3'd0) begin
                            bit_phase <= 2'd0;
                            state     <= S_ACK;
                        end else begin
                            tx_byte   <= {tx_byte[6:0], 1'b0};
                            bit_cnt   <= bit_cnt - 1'b1;
                            bit_phase <= 2'd0;
                        end
                    end
                endcase
            end

            // ACK/NACK: release SDA for one bit period so the target can drive
            // it (3.1.6). We sample it back - 0 = ACK, 1 = NACK - and branch:
            // a NACK aborts the whole init sequence via S_STOP_A -> S_ERROR
            // instead of continuing to the next byte.
            S_ACK: begin
                case (bit_phase)
                    2'd0: begin
                        scl     <= 1'b0;
                        sda_oe    <= 1'b0;     // release SDA for target to drive
                        bit_phase <= 2'd1;
                    end
                    2'd1: begin
                        scl     <= 1'b1;
                        bit_phase <= 2'd2;
                    end
                    2'd2: begin
                        ack_bit   <= sda;      // sample mid-high, same point target latched our bits
                        bit_phase <= 2'd3;
                    end
                    2'd3: begin
                        scl  <= 1'b0;
                        sda_oe <= 1'b1;     // take the bus back
                        sda_o  <= 1'b0;     // ensure SDA=0 going into SEND or STOP
                        bit_phase <= 2'd0;
                        bit_cnt   <= 3'd7;
                        if (ack_bit) begin
                            // NACK: stop transmitting, terminate the bus cleanly,
                            // and latch the error instead of proceeding.
                            nack_error <= 1'b1;
                            state      <= S_STOP_A;
                        end else begin
                            case (ack_phase)
                                2'd0: begin     // just ACKed address -> send high byte
                                    tx_byte   <= PROGRAM_REGISTERS[reg_idx][15:8];
                                    ack_phase <= 2'd1;
                                    state     <= S_SEND;
                                end
                                2'd1: begin     // just ACKed high byte -> send low byte
                                    tx_byte   <= PROGRAM_REGISTERS[reg_idx][7:0];
                                    ack_phase <= 2'd2;
                                    state     <= S_SEND;
                                end
                                default: begin  // just ACKed low byte -> STOP
                                    ack_phase <= 2'd0;
                                    state     <= S_STOP_A;
                                end
                            endcase
                        end
                    end
                endcase
            end

            // STOP precondition: SCL=0, SDA=0 (already true on entry from S_ACK)
            S_STOP_A: begin
                scl  <= 1'b0;
                sda_o  <= 1'b0;
                sda_oe <= 1'b1;
                state  <= S_STOP_B;
            end

            // SCL rises; hold 2 ticks (tSU;STO) before SDA is allowed to rise
            S_STOP_B: begin
                scl <= 1'b1;
                if (bit_phase == 2'd0) begin
                    bit_phase <= 2'd1;
                end else begin
                    bit_phase <= 2'd0;
                    state     <= S_STOP_C;
                end
            end

            // STOP condition: SDA rises while SCL=1
            S_STOP_C: begin
                sda_o <= 1'b1;
                state <= S_STOP_D;
            end

            // Decide what happens after STOP: error halt, next register, or done
            S_STOP_D: begin
                if (nack_error) begin
                    state <= S_ERROR;
                end else if (reg_idx == NUM_REGS - 1) begin
                    state <= S_DONE;
                end else begin
                    reg_idx <= reg_idx + 1'b1;
                    gap_cnt <= '0;
                    state   <= S_GAP;
                end
            end

            // tBUF: bus-free time before the next START (Table 11)
            S_GAP: begin
                scl <= 1'b1;
                sda_o <= 1'b1;
                if (gap_cnt == 5'd15)
                    state <= S_IDLE;
                else
                    gap_cnt <= gap_cnt + 1'b1;
            end

            // Done: hold bus idle, assert init_done permanently
            S_DONE: begin
                init_done <= 1'b1;
                scl     <= 1'b1;
                sda_o     <= 1'b1;
                sda_oe    <= 1'b1;
            end

            // Error: hold bus idle, init_done never asserts, nack_error stays latched
            S_ERROR: begin
                scl  <= 1'b1;
                sda_o  <= 1'b1;
                sda_oe <= 1'b1;
            end

        endcase
    end
end

endmodule