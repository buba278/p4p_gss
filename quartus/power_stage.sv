// power_stage.sv: complex bins -> (real*imag) so mag^2 -> extract half spectrum
// element wise processing (1 input = 1 output per cycle, 1 cycle latency)

module power_stage #(
    parameter int FFT_N = 4096
) (
    input logic clk,
    input logic rst_n,

    // fft_ip side
    input  logic        source_valid,
    output logic        source_ready, // in place for when calculations in future need to stall
    input  logic        source_sop,
    input  logic        source_eop,
    input  logic [23:0] source_real,
    input  logic [23:0] source_imag,
    input  logic [23:0] source_real,
    input  logic [5:0]  source_exp,  // unused scaling

    // per bin power stream out (half spectrum only)
    output logic power_valid,
    output logic [$clog2(FFT_N)-1:0] power_bin, // if half spectrum why not FFT_N/2 ? 
    output logic [47:0] power_mag2,
    output logic power_first, // bin 0 of frame
    output logic power_last // Nyquist bin FFT/2 of this frame 
);

localparam int NYQ_BIN = FFT_N / 2;

// currently this stage never stalls
assign source_ready = 1'b1;

// bin address tracking
logic [$clog2(FFT_N)-1:0] bin_cnt;
logic within_half;  

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin 
        bin_cnt <= '0;
    end else if (source_valid) begin
        if (source_eop)
            bin_cnt <= '0;
        else 
            bin_cnt <= bin_cnt + 1'b1;
    end
end

assign within_half = (bin_cnt <= NYQ_BIN[$clog2(FFT_N)-1:0]); // 32->12bit conversion

// mag squared
logic [47:0] mag2_d;
logic        valid_d, within_half_d, first_d, last_d;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_d <= '0;
    end else begin
        valid_d <= source_valid;
        if (source_valid) begin 
            mag2_d <= ($signed(source_real) * $signed(source_real))
                    + ($signed(source_imag) * $signed(source_imag));
            bin_d <= bin_cnt;
            within_half_d <= within_half;
            first_d <= (bin_cnt == '0);
            last_d <= (bin_cnt == NYQ_BIN[$clog2(FFT_N)-1:0]);
        end
    end
end

assign power_valid = valid_d && within_half_d;
assign power_bin = bin_d;
assign power_mag2 = mag2_d;
assign power_first = first_d;
assign power_last = last_d;

endmodule