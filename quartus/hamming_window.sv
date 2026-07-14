// hamming_window.sv - apply coefficients and bridge buffer to fft

module hamming_window #(
    parameter int N = 4096
) (
    input  logic        clk,
    input  logic        rst_n,
 
    // from overlap_buffer
    input  logic [23:0] fft_data,
    input  logic [$clog2(N)-1:0] fft_addr,
    input  logic        fft_data_valid,
    input  logic        fft_first,
    input  logic        fft_last,
 
    // to fft_ip Avalon-ST sink
    output logic         sink_valid,
    input  logic         sink_ready,
    output logic  [1:0]  sink_error,
    output logic         sink_sop,
    output logic         sink_eop,
    output logic [23:0]  sink_real,
    output logic [23:0]  sink_imag,
 
    output logic fft_sink_stall // sticky: sink_valid was high while sink_ready was low
);

    // -- ROM: init from hamming_window.mif --
    logic [17:0] coeff_q; // 1 cycle latency

    // init module
    rom_ip hamming_rom (
        .address (fft_addr),
        .clock   (clk),
        .q       (coeff_q)
    );

    // delay samples and tags by 1 cycle so allign with q
    logic [23:0] data_q;
    logic valid_q, sop_q, eop_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_q  <= '0;
            valid_q <= '0;
            sop_q   <= '0;
            eop_q   <= '0;
        end else begin
            data_q  <= fft_data;
            valid_q <= fft_data_valid;
            sop_q   <= fft_first;
            eop_q   <= fft_last;
        end
    end

    // multiply and rescale 
    logic signed [41:0] product; // ADC data is twos compliment signed
    // extend coeffecient with 0 then interpret zero (positive)
    assign product = $signed(data_q) * $signed({1'b0, coeff_q}); 
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sink_valid <= '0;
            sink_sop   <= '0;
            sink_eop   <= '0;
            sink_real  <= '0;
        end else begin
            sink_valid <= valid_q;
            sink_sop   <= sop_q;
            sink_eop   <= eop_q;
            // + (1 <<< 16) = force round to nearest, >>> 17 = apply fraction
            sink_real  <= (product + (1 <<< 16)) >>> 17;
        end
    end

    assign sink_imag  = '0;
    assign sink_error = '0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fft_sink_stall <= '0;
        else if (sink_valid && !sink_ready)
            fft_sink_stall <= 1'b1;
    end
    
endmodule