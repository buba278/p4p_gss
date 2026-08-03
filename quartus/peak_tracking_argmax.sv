// peak_tracking_argmax.sv

module peak_argmax #(
    parameter int FFT_N = 4096,
    parameter int MIN_BIN = 1
)(
    input logic clk,
    input logic rst_n,

    // from power_stage
    input logic                         power_valid,
    input logic [$clog2(FFT_N)-1:0]     power_bin,
    input logic [47:0]                  power_mag2,
    input logic                         power_first,
    input logic                         power_last,

    // pulses once per frame, after the last half-spectrum bin
    output logic                        peak_valid,
    output logic [$clog2(FFT_N)-1:0]    peak_bin,
    output logic [47:0]                 peak_mag2
);

// bin is elegible to participate in (and win) the running max
logic eligible;
assign eligible = power_valid && (power_bin >= MIN_BIN[$clog(FFT_N)-1:0]);

logic [47:0]              running_max_mag2;
logic [$clog2(FFT_N)-1:0] running_max_bin;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        running_max_mag2 <= '0;
        running_max_bin  <= '0;
        peak_valid       <= '0;
        peak_bin         <= '0;
        peak_mag2        <= '0;
    end else begin
        peak_valid <= '0; // default

        if (eligible) begin
            // MIN_BIN is first eligible frame
            if ((power_bin == MIN_BIN[$clog2(FFT_N)-1:0]) || (power_mag2 > running_max_mag2)) begin
                running_max_mag2 <= power_mag2;
                running_max_bin  <= power_bin;
            end
        end

        if (power_valid && power_last) begin
            peak_valid <= 1'b1;
            peak_bin   <= running_max_bin;
            peak_mag2  <= running_max_mag2;
        end
    end
end

endmodule