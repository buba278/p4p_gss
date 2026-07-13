// overlap_buffer.sv - sliding window buffer
// currently using simpler mirrored design for tradeoff of logic simplicity:
// - lets your increment over boundary rather than wrapping around (no mux on addr input to fft)
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

    // FFT IP 
    output logic fft_start,                // effectively a fft reset
    output logic [23:0] fft_data,
    output logic [$clog2(N)-1:0] fft_addr, // pos within hamming window coefficients
    output logic fft_data_valid,
    output logic fft_last,                 // fft_data is the last sample before data invalid (why I need this?)

    // FFT diagnostic error
    output logic fft_overrun // if writing is ready before FFT completed (stays latched)
);
    localparam int HOP = N / HOP_DIV; // hop size

    // bit widths
    localparam int BUF_W = $clog2(2*N); // note: mirrored
    localparam int FFT_W = $clog2(N);
    localparam int HOP_W = $clog2(HOP);

    logic [23:0] ram [0:(2*N)-1];

    // -- write side --
    logic [FFT_W-1:0] wr_ptr;
    logic [HOP_W-1:0] hop_cnt;
    logic [FFT_W-1:0] window_base;

    logic initialised; // flag for if buffer (N) fully filled at startup
    logic [FFT_W-1:0] init_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= '0;
            hop_cnt     <= '0;
            window_base <= '0;
            fft_start   <= '0;
        end else begin
            fft_start <= '0;
    
            if (valid_l) begin
                // mirroring
                ram[wr_ptr]     <= sample_l;
                ram[wr_ptr + N] <= sample_l;
    
                // cycle the buffer
                if (wr_ptr == N-1)
                    wr_ptr <= '0;
                else
                    wr_ptr <= wr_ptr + 1'b1;
    
                // at startup, no FFT compute without filling all buffer values once
                if (!initialised) begin
                    if (init_cnt == N-1) begin
                        initialised <= 1'b1;
                        hop_cnt     <= '0;
                        window_base <= '0; // first full window starts at 0
                        fft_start   <= 1'b1;
                    end else begin
                        init_cnt <= init_cnt + 1'b1;
                    end
                end else begin
                    // have gotten enough samples to trigger FFT
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
    end

    // -- read side --
    typedef enum logic [1:0] {R_IDLE, R_BURST_READ} rstate_t;
    rstate_t rstate; // read state - 
    logic [FFT_W-1:0] rd_cnt;
    logic [BUF_W-1:0] rd_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate         <= R_IDLE;
            rd_cnt         <= '0;
            fft_data_valid <= '0;
            fft_last       <= '0;
            fft_data       <= '0;
            fft_addr       <= '0;
        end else begin
            fft_data_valid <= '0;
            fft_last       <= '0;

            case (rstate)
                // waiting for hop to be filled
                R_IDLE: begin
                    if (fft_start) begin
                        rd_addr <= window_base;
                        rd_cnt  <= '0;
                        rstate  <= R_BURST_READ;
                    end
                end
                R_BURST_READ: begin
                    // set start based one where written (mirror dep logic)
                    fft_data       <= ram[rd_addr];
                    fft_addr       <= rd_cnt;
                    fft_data_valid <= 1'b1;
                    fft_last       <= (rd_cnt == N-1);

                    // read enough for full fft
                    if (rd_cnt == N-1) begin
                        rstate <= R_IDLE;
                    end else begin
                        rd_cnt  <= rd_cnt + 1'b1;
                        rd_addr <= rd_addr + 1'b1;
                    end
                end
            endcase    
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) fft_overrun <= '0;
        else if (fft_start && (rstate != R_IDLE)) fft_overrun <= 1'b1;
    end
endmodule