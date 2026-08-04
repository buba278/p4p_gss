// radar_top.sv — DE2-115 top-level for Doppler radar DSP pipeline
// device: Cyclone IV E EP4CE115F29C7
// this file only contains wires and instantiations.
// all logic lives in sub-modules.

module radar_top (
    // main board clock
    input  logic        CLOCK_50,       // 50 MHz crystal, PIN_Y2

    // == WM8731 Audio CODEC ==
    // FPGA drives AUD_XCK; the codec drives everything else in master mode
    output logic        AUD_XCK,        // master clock we supply,    PIN_E1
    input  logic        AUD_BCLK,       // bit clock FROM codec,      PIN_F2
    input  logic        AUD_ADCLRCK,    // word-select FROM codec,    PIN_C2
    input  logic        AUD_ADCDAT,     // serial ADC data FROM codec,PIN_D2
    input  logic        AUD_DACLRCK,    // DAC word-select (unused),  PIN_E3
    output logic        AUD_DACDAT,     // DAC data (driven to 0),    PIN_D1

    // == I2C config bus ==
    // SCL is driven as a regular output (we're the only master).
    // SDA is open-drain: we drive low, release to high-Z for slave ACK.
    output logic        I2C_SCLK,       // PIN_B7
    inout  wire         I2C_SDAT,       // PIN_A8 — must be 'wire' for Z state

    // == Debug ==
    output logic [17:0] LEDR,
    output logic  [8:0] LEDG
);

// internal wires — declared here because only the top level sees across modules
logic        pll_locked;    // audio_pll -> wm8731_i2c_init reset, and debug LED
logic        clk_12m;       // 12.000 MHz AUD_XCK from PLL (USB mode)
logic        init_done;     // wm8731_i2c_init -> i2s_rx reset gating
logic        nack_error;    // wm8731_i2c_init I2C ack failure
logic [23:0] sample_l;      // i2s_rx -> DSP pipeline
logic        valid_l;       // one-cycle pulse when sample_l is fresh

// overlap_buffer -> hamming_window
localparam int FFT_N = 4096;
logic                        fft_start;
logic [23:0]                 fft_data;
logic [$clog2(FFT_N)-1:0]    fft_addr;
logic                        fft_data_valid;
logic                        fft_first;
logic                        fft_last;
logic                        fft_overrun;

// hamming_window -> fft_ip (Avalon-ST sink side)
logic                sink_valid, sink_ready, sink_sop, sink_eop;
logic [1:0]          sink_error;
logic [23:0]         sink_real, sink_imag;
logic                fft_sink_stall;

// fft_ip -> power_stage (Avalon-ST source side)
logic                source_valid, source_ready, source_sop, source_eop;
logic [1:0]          source_error;
logic [23:0]         source_real, source_imag;
logic [5:0]          source_exp;

// power_stage -> peak_argmax
logic                        power_valid;
logic [$clog2(FFT_N)-1:0]    power_bin;
logic [47:0]                 power_mag2;
logic                        power_first;
logic                        power_last;

// peak_argmax -> (next stage / debug taps)
logic                        peak_valid;
logic [$clog2(FFT_N)-1:0]    peak_bin;
logic [47:0]                 peak_mag2;

// == instantiations ==

// PLL - 50 MHz -> 12.000 MHz for AUD_XCK (USB mode)
// 'locked' goes high once the PLL has phase-locked — use it as reset release.
// equiv of audio_pll_inst.v file generated with IP catalogue ALTPLL
audio_pll audio_pll_inst (
    .areset (1'b0), // never reset PLL
    .inclk0 (CLOCK_50),
    .c0     (clk_12m),
    .locked (pll_locked)
);
assign AUD_XCK = clk_12m;

// WM8731 audio codec I2C initialisation sequencer
wm8731_i2c_init i2c_init_inst (
    .clk        (CLOCK_50),
    .rst_n      (pll_locked), // dont send I2C till clock stable
    .scl        (I2C_SCLK),
    .sda        (I2C_SDAT),
    .init_done  (init_done),
    .nack_error (nack_error)
);
assign AUD_DACDAT = 1'b0;       // DAC is powered down

// I2S receiver (internal FPGA one not audio codec)
i2s_rx i2s_rx_inst (
    .clk      (CLOCK_50),
    .rst_n    (init_done),  // wait till codec outputs valid data
    .bclk     (AUD_BCLK),
    .lrclk    (AUD_ADCLRCK),
    .sdata    (AUD_ADCDAT),
    .sample_l (sample_l),
    .valid_l  (valid_l)
);

// == DSP ==

// sliding-window overlap buffer: N=4096 (resolution), HOP_DIV=2 -> 50% overlap (latency)
overlap_buffer #(
    .N       (FFT_N),
    .HOP_DIV (2)
) overlap_buffer_inst (
    .clk            (CLOCK_50),
    .rst_n          (init_done),   // same reset domain as i2s_rx — don't fill buffer with garbage pre-codec-init
    .valid_l        (valid_l),
    .sample_l       (sample_l),
    .fft_start      (fft_start),
    .fft_data       (fft_data),
    .fft_addr       (fft_addr),
    .fft_data_valid (fft_data_valid),
    .fft_first      (fft_first),
    .fft_last       (fft_last),
    .fft_overrun    (fft_overrun)
);

// Hamming windowing, coefficients from rom_ip (hamming_window.mif)
hamming_window #(
    .N (FFT_N)
) hamming_window_inst (
    .clk            (CLOCK_50),
    .rst_n          (init_done),
    .fft_data       (fft_data),
    .fft_addr       (fft_addr),
    .fft_data_valid (fft_data_valid),
    .fft_first      (fft_first),
    .fft_last       (fft_last),
    .sink_valid     (sink_valid),
    .sink_ready     (sink_ready),
    .sink_error     (sink_error),
    .sink_sop       (sink_sop),
    .sink_eop       (sink_eop),
    .sink_real      (sink_real),
    .sink_imag      (sink_imag),
    .fft_sink_stall (fft_sink_stall)
);

// FFT IP: N=4096, burst, natural in/out, block floating point out, 24bit in/out

fft_ip fft_ip_inst (
    .clk          (CLOCK_50),
    .reset_n      (init_done),
    .sink_valid   (sink_valid),
    .sink_ready   (sink_ready),
    .sink_error   (sink_error),
    .sink_sop     (sink_sop),
    .sink_eop     (sink_eop),
    .sink_real    (sink_real),
    .sink_imag    (sink_imag),
    .inverse      (1'b0),       // forward transform only
    .source_valid (source_valid),
    .source_ready (source_ready),
    .source_error (source_error),
    .source_sop   (source_sop),
    .source_eop   (source_eop),
    .source_real  (source_real),
    .source_imag  (source_imag),
    .source_exp   (source_exp)
);

// power/magnitude stage: complex bin -> magnitude-squared, half-spectrum only
power_stage #(
    .FFT_N (FFT_N)
) power_stage_inst (
    .clk          (CLOCK_50),
    .rst_n        (init_done),     // same reset domain as fft_ip — stays frame-aligned with it
    .source_valid (source_valid),
    .source_ready (source_ready),  // drives fft_ip's source_ready — see note above
    .source_sop   (source_sop),
    .source_eop   (source_eop),
    .source_real  (source_real),
    .source_imag  (source_imag),
    .source_exp   (source_exp),
    .power_valid  (power_valid),
    .power_bin    (power_bin),
    .power_mag2   (power_mag2),
    .power_first  (power_first),
    .power_last   (power_last)
);

// naive per-frame argmax - proof-of-concept peak search
peak_argmax #(
    .FFT_N   (FFT_N),
    .MIN_BIN (1)          // exclude bin 0 (DC / residual 1/f)
) peak_argmax_inst (
    .clk         (CLOCK_50),
    .rst_n       (init_done),
    .power_valid (power_valid),
    .power_bin   (power_bin),
    .power_mag2  (power_mag2),
    .power_first (power_first),
    .power_last  (power_last),
    .peak_valid  (peak_valid),
    .peak_bin    (peak_bin),
    .peak_mag2   (peak_mag2)
);

// TODO: cfar goes here later, inserted between power_stage and whatever
// replaces peak_argmax — consumes power_valid/power_bin/power_mag2/
// power_first/power_last, same as peak_argmax does now

// indicators
assign LEDG[0] = pll_locked;   // green: PLL stable
assign LEDG[1] = init_done;    // green: codec configured
assign LEDG[8:2] = '0;

assign LEDR[0] = fft_overrun;     // red: overlap_buffer tried to start a new window before FFT read the last one
assign LEDR[1] = fft_sink_stall;  // red: hamming_window presented data the FFT IP didn't accept
assign LEDR[17:2] = '0;

endmodule