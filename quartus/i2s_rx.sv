// i2s_rx.sv - I2S left-channel receiver for WM8731 in master mode
//
// Frame timing: LRCLK falls, 1 BCLK idle, MSB on 2nd BCLK rise, 23 more bits, 7 zero-padding bits, repeat. 
// The idle cycle is mandated by the I2S spec so both sides have a clock to do bookkeeping before data starts. 

module i2s_rx (
    input  logic        clk,        // FPGA system clock (50 MHz)
    input  logic        rst_n,      // active-low 

    // I2S signals from WM8731 - async to clk
    input  logic        bclk,       // 6.144 MHz bit clock
    input  logic        lrclk,      // 96 kHz word select (0=left, 1=right)
    input  logic        sdata,      // serial ADC data, MSB first

    // outputs - sync to clk
    output logic [23:0] sample_l,   // left channel sample, held until updated
    output logic        valid_l     // one-cycle pulse when sample_l is ready
);

// -- BCLK Domain --
// lrclk and sdata are sampled directly - no sync needed

logic lrclk_d;    // one cycle delayed for edge detect
logic lrclk_fall_b; // left channel start

logic [4:0]  bclk_cnt_b;   // 0..31 within a half-frame (left channel)
logic [23:0] shift_reg_b;    // accumulates bits MSB-first

// outputs but in bclk domain - need to transfer for rest of FPGA
logic [23:0] sample_l_b;
logic        valid_b;

// reset is async to bclk
logic rst_n_bclk_meta, rst_n_bclk;
always_ff @(posedge bclk or negedge rst_n) begin
    if (!rst_n) begin 
        rst_n_bclk_meta <= '0;
        rst_n_bclk      <= '0;
    end else begin
        rst_n_bclk_meta <= 1'b1;
        rst_n_bclk      <= rst_n_bclk_meta;
    end
end

// protocol bit timing logic
always_ff @(posedge bclk or negedge rst_n_bclk) begin
    if (!rst_n_bclk) begin
        lrclk_d      <= '0;
        bclk_cnt_b   <= '0;
        shift_reg_b  <= '0;
        sample_l_b   <= '0;
        valid_b      <= '0;
    end else begin
        lrclk_d <= lrclk; // remember its a clocked assignment!
        valid_b <= '0; // default: overridden on the 24th bit

        lrclk_fall_b = lrclk_d & ~lrclk;

        if (lrclk_fall_b) begin
            bclk_cnt_b <= '0;
        end else begin
            if (bclk_cnt_b < 5'd31)
                bclk_cnt_b <= bclk_cnt_b + 1'b1;

            // ignore idle and padding bits
            if ((bclk_cnt_b) >= 5'd1 && bclk_cnt_b <= 5'd24)
                shift_reg_b <= {shift_reg_b[22:0], sdata};

            // done shifting data
            if (bclk_cnt_b == 5'd24) begin
                sample_l_b <= {shift_reg_b[22:0], sdata}; // remember its clocked
                valid_b    <= 1'b1;
            end
        end
    end
end

// -- bclk -> clk domain crossing for outputs --
logic [23:0] sample_l_sync0, sample_l_sync1;
logic        valid_sync0, valid_sync1, valid_sync2;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sample_l_sync0 <= '0;
        sample_l_sync1 <= '0;
        valid_sync0    <= 1'b0;
        valid_sync1    <= 1'b0;
        valid_sync2    <= 1'b0;
        sample_l       <= '0;
        valid_l        <= 1'b0;
    end else begin
        // 2 flop sync for the data bus 
        sample_l_sync0 <= sample_l_b;
        sample_l_sync1 <= sample_l_sync0;

        // 2-flop then edge - for clk pulse
        valid_sync0 <= valid_b;
        valid_sync1 <= valid_sync0;
        valid_sync2 <= valid_sync1;

        valid_l  <= valid_sync1 & ~valid_sync2;   // rising edge -> 1-cycle pulse
        sample_l <= sample_l_sync1;               // latch alongside valid_l
    end
end

endmodule