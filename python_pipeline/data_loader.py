# data_loader.py — loading real data and generating synthetic test signals

import os
import numpy as np
from config import SAMPLE_RATE, FFT_SIZE, CARRIER_FREQ, SPEED_OF_LIGHT, MOUNT_ANGLE_DEG
from pipeline import velocity_to_doppler

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── Synthetic signals ─────────────────────────────────────────────────────────

def make_sine(velocity_ms, noise_config=None, n_samples=FFT_SIZE):
    """
    Generates a synthetic Doppler radar return signal with combinable noise models.
    
    noise_config can be a float (treated as standard white noise amplitude) or a dict:
    {
        'white': 0.5,         # Additive White Gaussian Noise amplitude
        'flicker': 0.4,       # 1/f noise amplitude (ruins low frequencies/CMA)
        'dropout': True,      # Simulates hitting a puddle (signal drops by 90%)
        'vibration': 0.15,    # Chassis/engine vibration amplitude (adds phase jitter)
        'beam_spread': 0.04   # Simulates antenna beam cone width spread (fraction of freq)
    }
    """
    # Maintain backward-compatibility with single-float inputs
    if isinstance(noise_config, (int, float)):
        noise_config = {'white': float(noise_config)}
    elif noise_config is None:
        noise_config = {}

    t = np.arange(n_samples) / SAMPLE_RATE
    freq = velocity_to_doppler(velocity_ms)

    # 1. Base Phase Generation + Vibration Phase Jitter
    # Vibration shakes the physical sensor, which modulates the carrier phase over time
    phase = 2 * np.pi * freq * t
    if 'vibration' in noise_config and noise_config['vibration'] > 0:
        v_amp = noise_config['vibration']
        v_freq = noise_config.get('vibration_freq', 120.0) # 120 Hz engine hum baseline
        phase += v_amp * np.sin(2 * np.pi * v_freq * t)

    # 2. Core Signal Generation (with optional Beam Spread)
    # Ground radar beams have finite widths; they look like a cluster of frequencies
    # rather than an infinitely thin line. This gives XCA its Gaussian target shape.
    if noise_config.get('beam_spread', 0) > 0:
        spread_hz = freq * noise_config['beam_spread']
        num_components = 30
        freq_components = np.random.normal(freq, spread_hz, num_components)
        
        signal = np.zeros(n_samples)
        for f in freq_components:
            p = 2 * np.pi * f * t
            if 'vibration' in noise_config and noise_config['vibration'] > 0:
                p += v_amp * np.sin(2 * np.pi * v_freq * t)
            signal += np.sin(p)
        signal /= np.sqrt(num_components) # Normalize power
    else:
        signal = np.sin(phase)

    # 3. Specular Dropout (Wet Track / Puddles)
    # Water acts like a mirror, bouncing energy away from the receiver.
    if noise_config.get('dropout', False):
        dropout_mask = np.ones(n_samples)
        # Drop signal power to 10% for the middle portion of the sampling frame
        dropout_mask[n_samples // 4 : 3 * n_samples // 4] = 0.1
        signal *= dropout_mask

    # 4. Generate and Combine Noise Types
    total_noise = np.zeros(n_samples)

    # Additive White Gaussian Noise (AWGN)
    if 'white' in noise_config and noise_config['white'] > 0:
        total_noise += np.random.normal(0, noise_config['white'], n_samples)

    # Pink/Flicker (1/f) Noise
    if 'flicker' in noise_config and noise_config['flicker'] > 0:
        white_source = np.random.normal(0, 1, n_samples)
        f_axis = np.fft.rfftfreq(n_samples)
        f_axis[0] = 1.0  # Avoid division by zero at DC bin
        flicker_filter = 1.0 / np.sqrt(f_axis)
        
        flicker_raw = np.fft.irfft(np.fft.rfft(white_source) * flicker_filter, n=n_samples)
        flicker_noise = (flicker_raw / np.std(flicker_raw)) * noise_config['flicker']
        total_noise += flicker_noise

    return signal + total_noise, freq

# ── Real data loader ──────────────────────────────────────────────────────────

def load_scope_csv(filepath):
    """
    Loads oscilloscope CSV exports (Rigol and similar).
    Skips header rows by attempting to parse each line as two floats.
    Returns raw times and voltages as numpy arrays.
    """
    times, voltages = [], []
    resolved = os.path.join(REPO_ROOT, filepath) if not os.path.isabs(filepath) else filepath
    with open(resolved, 'r') as f:
        for line in f:
            parts = line.strip().split(',')
            if len(parts) < 2:
                continue
            try:
                t = float(parts[0])
                v = float(parts[1])  # this will raise if parts[1] is empty
                times.append(t)
                voltages.append(v)
            except (ValueError, IndexError):
                continue
    return np.array(times), np.array(voltages)

def prepare_scope_signal(times, voltages, frame_size=FFT_SIZE, start_sample=0):
    """
    Takes raw scope output and returns a frame ready for the pipeline.

    Two things happen here:
    1. DC removal: the radar IF signal rides on a ~2.4V bias from the module
       power supply. The FFT would put all that energy in bin 0 and visually
       swamp the Doppler peak. Subtracting the mean centres the signal on zero.
    2. Frame extraction: cuts frame_size samples starting at start_sample.
       Move start_sample along to check consistency across the capture.

    Also infers and prints the actual sample rate from the time axis —
    update SAMPLE_RATE in config.py if it differs from the current value.
    """
    dt          = np.mean(np.diff(times))
    sample_rate = 1.0 / dt

    print(f"Inferred sample rate : {sample_rate:.1f} Hz")
    print(f"Total samples        : {len(voltages)}")
    print(f"Duration             : {times[-1] - times[0]:.3f} s")
    print(f"DC offset (mean)     : {voltages.mean():.4f} V")
    print(f"Peak-to-peak         : {voltages.max() - voltages.min():.4f} V")

    if abs(sample_rate - SAMPLE_RATE) / SAMPLE_RATE > 0.05:
        print(f"\nWARNING: inferred rate {sample_rate:.0f} Hz differs from "
              f"config SAMPLE_RATE {SAMPLE_RATE} Hz by more than 5%.\n"
              f"Update SAMPLE_RATE in config.py or velocity output will be wrong.")

    signal = voltages - np.mean(voltages)
    frame  = signal[start_sample : start_sample + frame_size]

    if len(frame) < frame_size:
        raise ValueError(
            f"Only {len(frame)} samples available from start_sample={start_sample}, "
            f"need {frame_size}. Reduce frame_size or start_sample.")

    return frame, sample_rate
