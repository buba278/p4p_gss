# data_loader.py — loading real data and generating synthetic test signals

import os
import numpy as np
from config import SAMPLE_RATE, FFT_SIZE, CARRIER_FREQ, SPEED_OF_LIGHT, MOUNT_ANGLE_DEG
from pipeline import velocity_to_doppler

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── Synthetic signals ─────────────────────────────────────────────────────────

def make_sine(velocity_ms, noise_amplitude=0.0, n_samples=FFT_SIZE):
    """
    Single sine wave at the Doppler frequency for a given velocity.
    noise_amplitude=0 gives a clean signal, increase to simulate real conditions.
    """
    t      = np.arange(n_samples) / SAMPLE_RATE
    freq   = velocity_to_doppler(velocity_ms)
    signal = np.sin(2 * np.pi * freq * t)
    noise  = np.random.normal(0, noise_amplitude, n_samples)
    return signal + noise, freq

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
