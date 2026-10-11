# FPGA pipeline overview

High-level description of each stage of the ground speed sensor design as it currently stands on `feat/xca` (including uncommitted work). Target is a DE2-115 (Cyclone IV E). `radar_top.sv` only wires modules together; all logic lives in the modules below.

## Signal flow

```
radar IF signal (analogue, line-in)
        |
   WM8731 codec  <-- audio_pll (12 MHz clock), wm8731_i2c_init (register setup)
        |  I2S, 24-bit, 96 kHz
     i2s_rx
        |  one sample at a time
  overlap_buffer        4096-sample windows, 50% overlap (~47 frames/s)
        |
  hamming_window
        |
     fft_ip             4096-point FFT, block floating point
        |
   power_stage          |X|^2, bins 0..2048 only
        |
    noise_cal           button-triggered baseline subtraction
        |-----------------------------> telemetry_uart_tx ('S' lines)
     peak_xca           two Gaussian correlators (xca_core x2) + interpolation
        |  peak bin + 1/16 bin fraction
   bin_to_freq          bin -> Hz
        |-----------------------------> lcd_freq_display
  freq_to_speed         Hz -> km/h
        |-----------------------------> telemetry_uart_tx ('P' lines)
   (CAN output, not built yet)
```

Key numbers: sample rate 96 kHz, FFT size 4096, bin spacing 23.4375 Hz, one bin ≈ 0.68 km/h at the 40° mount angle, new frame every 2048 samples (~21 ms).

## Front end

### `audio_pll`
Turns the board's 50 MHz clock into the 12 MHz master clock the audio codec needs. Its `locked` output holds the rest of the design in reset until the clock is stable.

### `wm8731_i2c_init`
Runs once at power-up. Writes the codec's configuration registers over I2C: line-in selected, ADC on, DAC and mic off, 24-bit I2S, 96 kHz. Raises `init_done` when finished, which releases reset for everything downstream. If the codec doesn't acknowledge, `init_done` never goes high.

### `i2s_rx`
Receives the codec's serial audio stream and hands out one 24-bit left-channel sample at a time, moved safely into the 50 MHz clock domain. Only the left channel is used (the radar is mono).

## Framing and transform

### `overlap_buffer`
Collects samples into a 4096-deep RAM and, every 2048 new samples, plays out the latest 4096 as one frame. The 50% overlap doubles the update rate without giving up frequency resolution. Raises `fft_overrun` (LEDR0) if a new frame is due before the previous one has been read out.

### `hamming_window`
Multiplies each sample by a Hamming window coefficient from a ROM, which reduces spectral leakage, then presents the frame to the FFT in the Avalon-ST format the IP expects. Raises `fft_sink_stall` (LEDR1) if the FFT wasn't ready to accept data.

### `fft_ip`
Intel FFT IP core: 4096 points, forward only, 24-bit, burst mode, natural bin order. It uses **block floating point**, meaning each frame comes out with its own scale factor reported on `source_exp`.

### `power_stage`
Converts each complex bin to power (real² + imag²) and keeps only bins 0 to 2048, since the upper half of a real signal's spectrum is a mirror image. Marks the last bin of each frame so later stages know where frames end.

Known issue: `source_exp` is not applied, so the power values change scale from frame to frame (in steps of 4x). Picking the biggest bin within a frame is unaffected, but anything comparing against a fixed number or a stored frame is.

## Detection

### `noise_cal`
Removes the stationary part of the spectrum. Pressing KEY0 starts a calibration: it skips 8 frames to let things settle, averages the next 128 frames (~2.7 s) per bin, and stores that as the baseline. From then on the baseline is subtracted from every frame, with negative results clamped to zero. Before the first calibration the spectrum passes through unchanged. Output is paused while a calibration is running. LEDG2 flashes during calibration and stays lit once a baseline is in use.

Known issue: because of the `power_stage` scale problem, the baseline and the live frame are often at different scales, so the subtraction over- or under-corrects. Offline tests also suggest dividing by the baseline works better than subtracting it.

### `peak_xca` and `xca_core`
Finds the target's Doppler peak. Rather than just taking the largest bin, it slides a Gaussian-shaped template along the spectrum and scores how well each position matches (a matched filter), which is more robust to single-bin spikes.

- `xca_core` is one correlator at one template width. It reports the best-scoring bin, its score, and the scores of the bins either side.
- `peak_xca` runs two of them side by side, narrow (sigma 3 bins) and wide (sigma 9 bins), because the target's peak gets broader at higher speed. Whichever scores higher wins.
- The winner is refined to 1/16 of a bin with a 3-point parabolic fit through the peak and its neighbours.
- If the winning score is below `DETECT_THRESHOLD`, the frame reports bin 0 ("no target").
- Search range is bins 1 to 220, i.e. just above DC up to about 150 km/h.

The Gaussian templates are stored in `gaussian_rom_sigma3` and `gaussian_rom_sigma9`.

## Conversion

### `bin_to_freq`
Converts the fractional bin position to frequency. Uses the fact that 23.4375 Hz is exactly 375/16, so the result is exact integer arithmetic with no divider. Output is Hz × 16.

### `freq_to_speed`
Converts Doppler frequency to ground speed using v = f / (44.7 × cos 40°), implemented as a multiply by a precomputed constant (`K_INT = 120`). Output is km/h × 65536. The mount angle is baked into `K_INT`, so it has to be recalculated by hand if the angle changes.

## Outputs

### `lcd_freq_display`
Shows the current peak frequency in Hz on the board's 16×2 LCD.

### `telemetry_uart_tx` and `uart_tx`
Debug link to the PC at 115200 baud, read by `scripts/log_telemetry.py` and `scripts/live_spectrum.py`. It repeatedly sends three kinds of line, each with a checksum:

- `P`: the pipeline's result (peak bin, frequency, speed), one per cycle.
- `S`: a snapshot of one full spectrum, taken after `noise_cal`.
- `A`: a snapshot of the 4096 raw ADC samples of one frame.

The link is slow compared with the frame rate, so a full cycle takes about 6 seconds and each snapshot is one frame out of roughly 290. `uart_tx` is the plain byte-level transmitter underneath.

### Status LEDs

| LED | Meaning |
|---|---|
| LEDG0 | PLL locked |
| LEDG1 | Codec configured |
| LEDG2 | Flashing: calibrating. Solid: baseline in use |
| LEDR0 | FFT overrun |
| LEDR1 | FFT input stall |

## Not in the active pipeline

- `peak_tracking_argmax.sv`: the original "largest bin wins" peak finder, replaced by `peak_xca`.
- `spectrum_uart_tx.sv`: the original spectrum-only UART sender, replaced by `telemetry_uart_tx`.
- CAN output of the speed value is planned but not built.
