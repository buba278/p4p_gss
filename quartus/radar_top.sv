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
logic        init_done;     // wm8731_i2c_init → i2s_rx reset gating
logic [23:0] sample_l;      // i2s_rx → DSP pipeline
logic        valid_l;       // one-cycle pulse when sample_l is fresh

// == instantiations ==
// 
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
    .clk       (CLOCK_50),
    .rst_n     (pll_locked), // dont send I2C till clock stable
    .scl       (I2C_SCLK),
    .sda       (I2C_SDAT),
    .init_done (init_done),
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

// DSP
// TODO: instantiate dc_remove, window, fft, cfar, peak_detect

// indicators
assign LEDG[0] = pll_locked;   // green: PLL stable
assign LEDG[1] = init_done;    // green: codec configured
assign LEDG[8:2] = '0;
assign LEDR = '0;

endmodule
