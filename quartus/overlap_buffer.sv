// overlap_buffer.sv - sliding window buffer
// currently using simpler mirrored design for tradeoff of logic simplicity
// NOTE: might need to change if go for cheaper FPGA chip

module overlap_buffer #(
    parameter int N = 4096,   // FFT window length - resolution
    parameter int HOP_DIV = 2 // overlap = 1-(1/HOP_DIV) - latency
) (
    input logic clk,
    input logic rst_n,

    // from i2s_rx
    input logic valid_l,
    input logic [23:0] sample_l,

    output logic fft_start,
    output logic [23:0] fft_data,
    output logic [$clog2(N)-1] fft_addr, // pos within window
    output logic fft_data_valid,
    output logic fft_last
);
    localparam int HOP = N / HOP_DIV; // hop size

    // bit widths
    localparam int ADDR_W = $clog2(2*N); // why *2? I dont get depth 8192
    localparam int PTR_W = $clog2(N);
    localparam int HOP_W = $clow2(HOP);

    logic [23:0] ram [0:(2*N)-1];

    // -- write side --
    logic [PTR_W-1:0] wr_ptr;
    logic [HOP_W-1:0] hop_cnt;
    logic [PTR_W-1:0] window_base;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= '0;
            hop_cnt     <= '0;
            window_base <= '0;
            fft_start   <= 1'b0;
        end else begin
            fft_start <= 1'b0;
    
            if (valid_l) begin
                // mirroring
                ram[wr_ptr]     <= sample_l;
                ram[wr_ptr + N] <= sample_l;
    
                // cycle the buffer
                if (wr_ptr == N-1)
                    wr_ptr <= '0;
                else
                    wr_ptr <= wr_ptr + 1'b1;
    
                // have gotten enough samples to trigger fft
                if (hop_cnt == HOP-1) begin
                    hop_cnt     <= '0;
                    window_base <= (wr_ptr == N-1) ? '0 : (wr_ptr + 1'b1);
                    fft_start   <= 1'b1;
                end else begin
                    hop_cnt <= hop_cnt + 1'b1;
                end
            end
        end
    end

    // -- read side --
    
endmodule