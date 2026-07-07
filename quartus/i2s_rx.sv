// i2s_rx.sv - I2S left-channel receiver for WM8731 in master mode
// bclk/lrclk/sdata are async to clk (WM8731's own PLL, not derived from CLOCK_50)
//
// Frame timing: LRCLK falls, 1 BCLK idle, MSB on 2nd BCLK rise, 23 more bits, 7 zero-padding bits, repeat. 
// The idle cycle is mandated by the I2S spec so both sides have a clock to do bookkeeping before data starts. 
// sdata is the output of the codec's own internal parallel-to-serial shift register.
//
// Sync: bclk/lrclk get 3 stages (need edge detection, so need this cycle's settled value AND last cycle's, to compare). 
// sdata gets 2 stages (only needs a stable level, no edge comparison, so no third stage to pay for).
//
// only capture left cause mono

module i2s_rx (
    input  logic        clk,        // FPGA system clock (50 MHz)
    input  logic        rst_n,      // active-low. Note: init_done (radar_top) is already
                                    // synchronous to this clk, so async style here is unused
                                    // capability, not a bug. Real async domain is below.

    // I2S signals from WM8731 - async to clk
    input  logic        bclk,       // 6.144 MHz bit clock (64*96kHz)
    input  logic        lrclk,      // 96 kHz word select (0=left, 1=right)
    input  logic        sdata,      // serial ADC data, MSB first - output of the codec's
                                    // own internal parallel-to-serial shift register

    // outputs - synchronous to clk
    output logic [23:0] sample_l,   // left channel sample, held until updated
    output logic        valid_l     // one-cycle pulse when sample_l is fresh
);

// sr[1] = stable value, use for logic. sr[2] = one cycle older, use for edge detect.
// Edge = sr[1]=1 AND sr[2]=0. Never use sr[0], it may still be metastable.

logic [2:0] bclk_sr, lrclk_sr;
logic [1:0] sdata_sr;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bclk_sr  <= '0;
        lrclk_sr <= '0;
        sdata_sr <= '0;
    end else begin
        bclk_sr  <= {bclk_sr[1:0],  bclk};
        lrclk_sr <= {lrclk_sr[1:0], lrclk};
        sdata_sr <= {sdata_sr[0],   sdata};
    end
end

// Stable synchronised values (use sr[1])
// Edge detection uses sr[1] vs sr[2]
logic bclk_rise, lrclk_fall;
logic sdata_s;

assign bclk_rise  =  bclk_sr[1] & ~bclk_sr[2];   // BCLK: 0->1
assign lrclk_fall = ~lrclk_sr[1] & lrclk_sr[2];  // LRCLK: 1->0 (left channel start)
assign sdata_s    = sdata_sr[1];                 // stable sdata

// Counts BCLK rises since the last LRCLK fall. 0 = idle gap (skip), 1-24 = data
// bits MSB first, 25-31 = zero padding (ignore). Shift condition uses bclk_cnt
// pre-increment, so cnt=0 blocks the shift (idle skipped) and cnt=1 shifts MSB.

logic [4:0]  bclk_cnt;     // 0..31 within a half-frame
logic [23:0] shift_reg;    // accumulates bits MSB-first

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bclk_cnt <= '0;
        shift_reg <= '0;
        sample_l  <= '0;
        valid_l   <= 1'b0;
    end else begin
        valid_l <= 1'b0;    // default; overridden below on the 24th bit

        if (lrclk_fall) begin
            // New left-channel frame starting.
            // Reset counter regardless of where we are in the previous frame.
            bclk_cnt <= 5'd0;

        end else if (bclk_rise) begin
            // Advance counter (cap at 31 so we don't wrap before next LRCLK fall)
            if (bclk_cnt < 5'd31)
                bclk_cnt <= bclk_cnt + 1'b1;

            // Shift in a data bit if we're in the data window (counts 1..24).
            // Uses PRE-increment bclk_cnt
            if (bclk_cnt >= 5'd1 && bclk_cnt <= 5'd24) begin
                shift_reg <= {shift_reg[22:0], sdata_s};
            end

            // On the 24th data bit: combine shift_reg[22:0] with the current
            // sdata_s to form the complete 24-bit sample.
            // Both use the same sdata_s value (non-blocking: RHS evaluated now).
            if (bclk_cnt == 5'd24) begin
                sample_l <= {shift_reg[22:0], sdata_s};
                valid_l  <= 1'b1;
            end
        end
    end
end

endmodule