// wm8731_i2c_init.sv - setup the codec with I2C register writes
// - I2C address: 0x34 (7-bit: 0b0011010, CSB pin tied to GND on DE2-115) 
// - write-only 2-wire mode, 100 kHz
// - data sent as: [device_addr+W] [B15:B8] [B7:B0] with ACK after each byte

module wm8731_i2c_init (
    input  logic clk,       // 50 MHz FPGA system clock
    input  logic rst_n,     // active-low; tie to pll_locked so init waits for stable MCLK
    output logic scl,       // I2C clock (driven as push-pull: we're the only master)
    inout  wire  sda,       // I2C data  (open-drain: we drive low or release to Z)
    output logic init_done  // asserted permanently when the last write has completed
);

// packed array of constants - synthesises to hardwired mux, not RAM (refer to wm8731 datasheet "Software Control")
localparam int NUM_REGS = 9;
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
               //     BCLKINV=0  (don care - just default)
    16'h101D,  // R8  Sampling Control (USB mode, 96 kHz):
               //     USB/NORMAL=1  (USB mode: MCLK = 12.000 MHz) - easily achievable from 50 MHz FPGA clock
               //     BOSR=0        (250fs oversampling base rate) - (Table 22 WM8731 datasheet) STILL VERY CONFUSED WITH 12MHz/125 where does that come from and what oversampling means
               //     SR=0111       (selects 96 kHz for both ADC and DAC)
               //     CLKIDIV2=0, CLKODIV2=0 (use full MCLK as core clock) 
    16'h1201   // R9  Active Control: ACTIVE=1 (start I2S interface) do last and once active, changing other registers
};

// --- clock divider ---
// - 100kHz I2C, 4 timing phases per bit (setup/rise/hold/fall).
// - phase = 50 MHz / 4 / 100 kHz = 125 clk cycles.
// At 2.5 µs per phase, start-hold time = 2.5 µs (spec requires ≥4 µs for
// 100 kHz mode, but WM8731 works fine at this rate on a single-master bus).
// To be strictly compliant, increase PHASE_LEN to 250 (50 kHz I2C). 
// im confused why would 100kHz be a valid operating point if the spec requires >= 4 uS, doesnt that mean you can have max freq of 50kHz by spec?

localparam int PHASE_CYCLES = 125; // in cycles

logic [6:0] cycle_cnt;
logic phase_tick; // phase pulse every PHASE_CYCLES system clocks

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cycle_cnt <= '0;
        phase_tick <= 1'b0;
    end else begin
        phase_tick <= 1'b0;
        if (cycle_cnt == PHASE_CYCLES - 1) begin
            cycle_cnt <= '0;
            phase_tick    <= 1'b1;
        end else
            cycle_cnt <= cycle_cnt + 1'b1;
    end
end

// --- FSM ---
// Each generic bit of I2S occupies 4 ticks (phases 0-3):
// - phase 0: SCL=0, set SDA to the bit we're sending
// - phase 1: SCL rises  (SDA must be stable before this)
// - phase 2: SCL=1 held (slave samples SDA here, potentially sample ACK here)
// - phase 3: SCL falls  (SDA may change after this)
// START and STOP are special: SDA changes while SCL is high.

typedef enum logic [3:0] {
    S_IDLE,         // SCL=1, SDA=1, waiting one tick before generating START
    S_START_A,      // SCL=1, SDA falls <- START condition
    S_START_B,      // SCL falls
    S_SEND,         // generic bit sending (4 phases x bit_cnt bits)
    S_ACK,          // release SDA for one bit period (slave drives ACK)
    S_STOP_A,       // SCL=0, SDA=0 (precondition for STOP)
    S_STOP_B,       // SCL rises
    S_STOP_C,       // SDA rises while SCL=1 <- STOP condition
    S_STOP_D,       // hold, then decide: next register or done
    S_GAP,          // short idle between consecutive register writes
    S_DONE          // init_done=1, stay here forever
} state_t;

state_t       state;
logic [1:0]   bit_phase;        // 0..3 within a bit period (increments on tick)
logic [2:0]   bit_cnt;      // counts bits 7..0 within the current byte (MSB first!)
logic [3:0]   reg_idx;      // which PROGRAM_REGISTERS we're writing (0..8)
logic [4:0]   gap_cnt;      // inter-write gap counter - what this for?

// SDA output control: open-drain
// When sda_oe=1: we drive sda_o onto the bus
// When sda_oe=0: bus released, external 4.7kΩ pullup holds it high
logic sda_o, sda_oe;
logic scl_r; // registered just so symmetrical with sda

// SDA tristate: inout wire driven by combinational assign
assign sda = sda_oe ? sda_o : 1'bz; // im very confused? why can sda_o be 1?, I thought we could only pull low?
assign scl  = scl_r; // why not just use scl directly?

// The byte currently being serialised (shifted left after each bit)
logic [7:0] tx_byte;

// After each ACK phase, we need to know what to send next:
// - ACK following address byte -> load high data byte
// - ACK following high data    -> load low data byte
// - ACK following low data     -> go to STOP
// track this with a 2-bit counter (ack_phase: 0=addr, 1=data_h, 2=data_l)
logic [1:0] ack_phase;  // which ACK are we transitioning 

// is there any way of chunking this or this big ff block is the best way?
always_ff @(posedge clk or negedge rst_n) begin // why not posedge phase_tick?
    if (!rst_n) begin
        state     <= S_IDLE;
        bit_phase     <= '0;
        bit_cnt   <= 3'd7;
        reg_idx   <= '0;
        gap_cnt   <= '0;
        ack_phase <= '0;
        scl_r     <= 1'b1; // why not use '1 notation here just like '0?
        sda_o     <= 1'b1;
        sda_oe    <= 1'b1;
        init_done <= 1'b0;
        tx_byte   <= 8'h34; // is this the address so its setup for every transmission??
    end else if (phase_tick) begin
        case (state)

            // IDLE: bus is high, emit one full idle phase then generate START
            S_IDLE: begin
                scl_r  <= 1'b1;
                sda_o  <= 1'b1; // I thought emmitting high wasnt good, should be pulled up so Z?
                sda_oe <= 1'b1;
                state  <= S_START_A;
            end

            // START condition: SDA falls while SCL=1
            S_START_A: begin
                scl_r  <= 1'b1;     // SCL stays high
                sda_o  <= 1'b0;     // SDA falls -> START
                sda_oe <= 1'b1;
                state  <= S_START_B;
            end

            // SCL falls after START — now ready to clock the address byte
            // I dont really get the point of this start_b, is this just preloading tx_byte so it gets sent?
            S_START_B: begin
                scl_r     <= 1'b0;
                tx_byte   <= 8'h34;     // I2C device address (0x34) + W=0
                bit_cnt   <= 3'd7;
                ack_phase <= 2'd0;
                bit_phase <= 2'd0;
                state     <= S_SEND;
            end

            // ── Generic byte send (address, high byte, low byte all use this)
            // phase 0: SCL=0, drive the MSB of tx_byte onto SDA
            // phase 1: SCL rises
            // phase 2: SCL=1 hold
            // phase 3: SCL falls; shift tx_byte; decrement or transition to ACK
            S_SEND: begin
                case (bit_phase)
                    2'd0: begin
                        scl_r       <= 1'b0;
                        sda_o       <= tx_byte[7];   // MSB first
                        sda_oe      <= 1'b1;
                        bit_phase   <= 2'd1;
                    end
                    2'd1: begin
                        scl_r <= 1'b1;
                        bit_phase <= 2'd2;
                    end
                    2'd2: begin
                        // hold — no change
                        bit_phase <= 2'd3;
                    end
                    2'd3: begin
                        scl_r <= 1'b0;
                        if (bit_cnt == 3'd0) begin
                            // all 8 bits sent - clock one ACK bit
                            bit_phase <= 2'd0;
                            state <= S_ACK;
                        end else begin
                            // shift the next bit into position [7]
                            tx_byte <= {tx_byte[6:0], 1'b0};
                            bit_cnt <= bit_cnt - 1'b1;
                            bit_phase   <= 2'd0;
                        end
                    end
                endcase
            end

            // ACK: release SDA for one bit period so slave can pull low
            // We don't check the ACK value — would need a read path for that. - wdym by that?
            // In practice the WM8731 always ACKs correctly writes to valid registers. - what?
            S_ACK: begin
                case (bit_phase)
                    2'd0: begin
                        scl_r <= 1'b0;
                        sda_oe <= 1'b0; // release SDA (slave will pull low = ACK)
                        bit_phase <= 2'd1;
                    end
                    2'd1: begin
                        scl_r <= 1'b1;
                        bit_phase <= 2'd2;
                    end
                    2'd2: begin
                        // could sample sda here to verify ACK if needed - why is ACK not needed?
                        bit_phase <= 2'd3;
                    end
                    2'd3: begin
                        scl_r  <= 1'b0;
                        sda_oe <= 1'b1;     // take bus back
                        sda_o  <= 1'b0;     // ensure SDA=0 going into SEND or STOP
                        bit_phase  <= 2'd0;
                        bit_cnt <= 3'd7;
                        case (ack_phase)
                            2'd0: begin     // just ACKed address → send high byte
                                tx_byte   <= PROGRAM_REGISTERS[reg_idx][15:8];
                                ack_phase <= 2'd1;
                                state     <= S_SEND;
                            end
                            2'd1: begin     // just ACKed high byte → send low byte
                                tx_byte   <= PROGRAM_REGISTERS[reg_idx][7:0];
                                ack_phase <= 2'd2;
                                state     <= S_SEND;
                            end
                            2'd2: begin     // just ACKed low byte → STOP
                                ack_phase <= 2'd0;
                                state     <= S_STOP_A;
                            end
                            default: state <= S_DONE;
                        endcase
                    end
                endcase
            end

            // STOP condition: SDA rises while SCL=1
            // precondition from S_ACK phase 3: SCL=0, SDA=0.
            S_STOP_A: begin
                scl_r  <= 1'b0;     // confirm SCL=0
                sda_o  <= 1'b0;     // confirm SDA=0
                sda_oe <= 1'b1;
                state  <= S_STOP_B;
            end
            S_STOP_B: begin
                scl_r <= 1'b1;      // SCL rises
                state <= S_STOP_C;
            end
            S_STOP_C: begin
                sda_o <= 1'b1;      // SDA rises while SCL=1 -> STOP condition
                state <= S_STOP_D;
            end
            S_STOP_D: begin
                // one hold tick, then decide what to do next - whats the point of the hold ticks? sampling?
                if (reg_idx == NUM_REGS - 1) begin
                    state <= S_DONE;
                end else begin
                    reg_idx <= reg_idx + 1'b1;
                    gap_cnt <= '0;
                    state   <= S_GAP;
                end
            end

            // Short gap between consecutive writes (keeps bus idle briefly) - whats the point of this?
            S_GAP: begin
                scl_r <= 1'b1;
                sda_o <= 1'b1;
                if (gap_cnt == 5'd15)
                    state <= S_IDLE;    // IDLE generates the next START
                else
                    gap_cnt <= gap_cnt + 1'b1;
            end

            // ── Done: hold bus idle, assert init_done permanently
            S_DONE: begin
                init_done <= 1'b1;
                scl_r     <= 1'b1;
                sda_o     <= 1'b1;
                sda_oe    <= 1'b1;
            end

        endcase
    end
end

endmodule
