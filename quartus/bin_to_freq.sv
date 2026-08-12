// bin_to_freq.sv - FFT bin index -> frequency
// Values stored as FIXED POINT: agree on div factor to maximise precision
// Bin spacing is Fs/N = 96000/4096 = 23.4375 Hz/bin - not a whole number
// storing bin frequencies as plain whole Hz would round every single bin.
// But 23.4375 written as a fraction is EXACTLY 375/16, denominator is (16 = 2^4)
// scale factor = 16 means every bin frequency is "sixteenths of a Hz" with zero precision loss
 
module bin_to_freq #(
    // (If Fs or N ever changes, redo Fs/N as a fraction - 
    // this exact trick only works if the new denominator is still a power of two.)
    parameter int FFT_N          = 4096,
    parameter int BIN_RES_NUM    = 375,  // Fs/N numerator after reduction (Fs=96kHz, N=4096)
    parameter int FREQ_FRAC_BITS = 4     // scale factor = 2^FREQ_FRAC_BITS (16) -> output is Hz * 16
)(
    input  logic clk,
    input  logic rst_n,
 
    input  logic                        bin_valid,
    input  logic [$clog2(FFT_N)-1:0]    bin_in,
 
    output logic                        freq_valid,
    output logic [19:0]                 freq_scaled   // Hz * 2^FREQ_FRAC_BITS, exact
);
 
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        freq_valid  <= '0;
        freq_scaled <= '0;
    end else begin
        freq_valid <= bin_valid;
        if (bin_valid)
            freq_scaled <= bin_in * BIN_RES_NUM[19:0];
    end
end
 
endmodule
