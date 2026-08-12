// uart_tx.sv
// Generic byte-level UART transmitter: 8 data bits, no parity, 1 stop bit (8N1).
// CLKS_PER_BIT is CLK_FREQ_HZ/BAUD_RATE by integer division, so actual baud has
// some rounding error — negligible for standard baud rates off a 50 MHz clock,
// well under the ~2% mismatch a UART receiver tolerates.

module uart_tx #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int BAUD_RATE   = 921_600
)(
    input  logic       clk,
    input  logic        rst_n,

    input  logic [7:0]  tx_data,
    input  logic         tx_valid,
    output logic         tx_ready,   // high when idle, able to accept a new byte

    output logic         tx_serial   // idles high
);

localparam int CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;

typedef enum logic [1:0] {
    ST_IDLE,
    ST_START,
    ST_DATA,
    ST_STOP
} state_t;

state_t                          state;
logic [$clog2(CLKS_PER_BIT)-1:0] clk_cnt;
logic [2:0]                      bit_idx;
logic [7:0]                      data_shift;

assign tx_ready = (state == ST_IDLE);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= ST_IDLE;
        tx_serial  <= 1'b1;
        clk_cnt    <= '0;
        bit_idx    <= '0;
        data_shift <= '0;
    end else begin
        case (state)
            ST_IDLE: begin
                tx_serial <= 1'b1;
                if (tx_valid) begin
                    data_shift <= tx_data;
                    clk_cnt    <= '0;
                    state      <= ST_START;
                end
            end

            ST_START: begin
                tx_serial <= 1'b0;
                if (clk_cnt == CLKS_PER_BIT-1) begin
                    clk_cnt <= '0;
                    bit_idx <= '0;
                    state   <= ST_DATA;
                end else begin
                    clk_cnt <= clk_cnt + 1'b1;
                end
            end

            ST_DATA: begin
                tx_serial <= data_shift[0];
                if (clk_cnt == CLKS_PER_BIT-1) begin
                    clk_cnt    <= '0;
                    data_shift <= data_shift >> 1;
                    if (bit_idx == 3'd7) begin
                        state <= ST_STOP;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                    end
                end else begin
                    clk_cnt <= clk_cnt + 1'b1;
                end
            end

            ST_STOP: begin
                tx_serial <= 1'b1;
                if (clk_cnt == CLKS_PER_BIT-1) begin
                    clk_cnt <= '0;
                    state   <= ST_IDLE;
                end else begin
                    clk_cnt <= clk_cnt + 1'b1;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
