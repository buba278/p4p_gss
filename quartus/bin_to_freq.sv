// bin_to_freq.sv - FFT bin index -> frequency
// Values stored as FIXED POINT: agree on div factor to maximise precision
// Bin spacing is Fs/N = 96000/4096 = 23.4375 Hz/bin - not a whole number
// storing bin frequencies as plain whole Hz would round every single bin.
// But 23.4375 written as a fraction is EXACTLY 375/16, denominator is (16 = 2^4)
// scale factor = 16 means every bin frequency is "sixteenths of a Hz" with zero precision loss
//
// bin_in/bin_frac_in together are peak_xca.sv's interpolated bin position
// (bin_in + bin_frac_in / 2^BIN_FRAC_BITS). Combining them before the
// multiply and shifting back down by BIN_FRAC_BITS afterward isn't exact
// the way the integer-only path above is (sub-bin position is itself an
// estimate, not a measured quantity) - but it's still division-free, just
// a shift instead of the usual "multiply by precomputed reciprocal" trick.

module bin_to_freq #(
    // (If Fs or N ever changes, redo Fs/N as a fraction -
    // this exact trick only works if the new denominator is still a power of two.)
    parameter int FFT_N          = 4096,
    parameter int BIN_RES_NUM    = 375,  // Fs/N numerator after reduction (Fs=96kHz, N=4096)
    parameter int FREQ_FRAC_BITS = 4,    // scale factor = 2^FREQ_FRAC_BITS (16) -> output is Hz * 16
    parameter int BIN_FRAC_BITS  = 4     // must match peak_xca.sv's BIN_FRAC_BITS
)(
    input  logic clk,
    input  logic rst_n,

    input  logic                        bin_valid,
    input  logic [$clog2(FFT_N)-1:0]    bin_in,
    input  logic [BIN_FRAC_BITS-1:0]    bin_frac_in,

    output logic                        freq_valid,
    output logic [19:0]                 freq_scaled   // Hz * 2^FREQ_FRAC_BITS, exact for integer bin_in
);

logic [$clog2(FFT_N)+BIN_FRAC_BITS-1:0] bin_scaled;
assign bin_scaled = {bin_in, bin_frac_in};

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        freq_valid  <= '0;
        freq_scaled <= '0;
    end else begin
        freq_valid <= bin_valid;
        if (bin_valid)
            freq_scaled <= (bin_scaled * BIN_RES_NUM[19:0]) >> BIN_FRAC_BITS;
    end
end

endmodule
