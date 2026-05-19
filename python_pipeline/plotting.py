# plotting.py — all matplotlib code, nothing else

import os
import numpy as np
import matplotlib.pyplot as plt
from config import SAMPLE_RATE
from pipeline import doppler_to_velocity

IMAGES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'output_images')

def _save(filename):
    os.makedirs(IMAGES_DIR, exist_ok=True)
    filepath = os.path.join(IMAGES_DIR, filename)
    plt.tight_layout()
    plt.savefig(filepath, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"Saved {filepath}")

# ── Raw signal inspection ─────────────────────────────────────────────────────

def plot_raw_signal(times, voltages, signal_dc_removed, filename='raw_signal.png'):
    """
    Two-panel plot: raw scope capture and the same signal after DC removal.
    Run this first on any new dataset to check the signal looks sensible
    before putting it through the pipeline.
    """
    fig, axes = plt.subplots(2, 1, figsize=(12, 6))

    axes[0].plot(times, voltages, linewidth=0.5, color='steelblue')
    axes[0].set_title('Raw scope capture')
    axes[0].set_xlabel('Time (s)')
    axes[0].set_ylabel('Voltage (V)')

    axes[1].plot(times[:len(signal_dc_removed)], signal_dc_removed,
                 linewidth=0.5, color='darkorange')
    axes[1].axhline(0, color='gray', linewidth=0.5)
    axes[1].set_title('After DC removal — ready for pipeline')
    axes[1].set_xlabel('Time (s)')
    axes[1].set_ylabel('Voltage (V)')

    _save(filename)

# ── Single pipeline result ────────────────────────────────────────────────────

def plot_pipeline_stages(result, true_freq=None, filename='pipeline_stages.png'):
    """
    Four-panel walkthrough of a single pipeline run:
      1. Time domain (first 5ms so individual cycles are visible)
      2. FFT magnitude spectrum
      3. Spectrum after CFAR thresholding
      4. Final peak estimate marked on the CFAR spectrum
    true_freq: if known (synthetic signal), marks it in red for comparison.
    """
    freqs        = result['freqs']
    peak_freq    = result['peak_freq']
    x_max        = max(peak_freq * 3, 500)   # zoom to relevant frequency range
    t            = np.arange(len(result['raw'])) / SAMPLE_RATE
    samples_5ms  = int(0.005 * SAMPLE_RATE)

    fig, axes = plt.subplots(4, 1, figsize=(10, 12))

    # Time domain
    axes[0].plot(t[:samples_5ms] * 1000, result['raw'][:samples_5ms],
                 color='steelblue', linewidth=0.8)
    axes[0].axhline(0, color='gray', linewidth=0.5)
    axes[0].set_title('Time domain (first 5 ms)')
    axes[0].set_xlabel('Time (ms)')
    axes[0].set_ylabel('Amplitude')

    # FFT spectrum
    axes[1].plot(freqs, result['spectrum'], color='steelblue', linewidth=0.8)
    axes[1].set_title('FFT magnitude spectrum')
    axes[1].set_xlabel('Frequency (Hz)')
    axes[1].set_xlim(0, x_max)
    if true_freq:
        axes[1].axvline(true_freq, color='red', linestyle='--',
                        linewidth=1, label=f'True: {true_freq:.1f} Hz')
        axes[1].legend()

    # CFAR output
    axes[2].plot(freqs, result['cfar_spectrum'], color='darkorange', linewidth=0.8)
    axes[2].set_title('After CFAR thresholding')
    axes[2].set_xlabel('Frequency (Hz)')
    axes[2].set_xlim(0, x_max)
    if true_freq:
        axes[2].axvline(true_freq, color='red', linestyle='--', linewidth=1)

    # Peak estimate
    velocity  = result['velocity']
    error_pct = (abs(velocity - doppler_to_velocity(true_freq))
                 / doppler_to_velocity(true_freq) * 100) if true_freq else None
    title = f'Peak estimate: {peak_freq:.1f} Hz → {velocity:.2f} m/s'
    if error_pct is not None:
        title += f'  (error: {error_pct:.1f}%)'

    axes[3].plot(freqs, result['cfar_spectrum'], color='darkorange',
                 linewidth=0.8, alpha=0.6)
    axes[3].axvline(peak_freq, color='green', linewidth=1.5,
                    label=f'Estimate: {peak_freq:.1f} Hz')
    if true_freq:
        axes[3].axvline(true_freq, color='red', linestyle='--',
                        linewidth=1.2, label=f'True: {true_freq:.1f} Hz')
    axes[3].set_title(title,
                      color='green' if error_pct is None or error_pct < 5 else 'red')
    axes[3].set_xlabel('Frequency (Hz)')
    axes[3].set_xlim(0, x_max)
    axes[3].legend()

    _save(filename)

# ── Estimator comparison ──────────────────────────────────────────────────────

def plot_estimator_comparison(results_dict, true_freq=None,
                               title='', filename='comparison.png'):
    """
    Side-by-side comparison of multiple estimators on the same signal.
    results_dict: {estimator_name: pipeline_result_dict}
    Each column is one estimator, rows show FFT → CFAR → peak estimate.
    """
    estimators = list(results_dict.keys())
    n          = len(estimators)
    fig, axes  = plt.subplots(3, n, figsize=(5*n, 10))
    if n == 1:
        axes = axes.reshape(-1, 1)

    fig.suptitle(title, fontsize=13, fontweight='bold')
    row_labels = ['FFT spectrum', 'After CFAR', 'Peak estimate']
    for row, label in enumerate(row_labels):
        axes[row, 0].set_ylabel(label, fontsize=9)

    for col, est in enumerate(estimators):
        r         = results_dict[est]
        freqs     = r['freqs']
        peak_freq = r['peak_freq']
        velocity  = r['velocity']
        x_max     = max(peak_freq * 3, 500) if peak_freq > 0 else 2000

        axes[0, col].set_title(est.upper().replace('_', ' '),
                               fontsize=11, fontweight='bold')

        axes[0, col].plot(freqs, r['spectrum'], color='steelblue', linewidth=0.7)
        axes[0, col].set_xlim(0, x_max)
        if true_freq:
            axes[0, col].axvline(true_freq, color='red', linestyle='--', linewidth=1)

        axes[1, col].plot(freqs, r['cfar_spectrum'], color='darkorange', linewidth=0.7)
        axes[1, col].set_xlim(0, x_max)
        if true_freq:
            axes[1, col].axvline(true_freq, color='red', linestyle='--', linewidth=1)

        axes[2, col].plot(freqs, r['cfar_spectrum'], color='darkorange',
                          linewidth=0.7, alpha=0.5)
        axes[2, col].axvline(peak_freq, color='green', linewidth=1.5,
                             label=f'{peak_freq:.0f} Hz')
        if true_freq:
            axes[2, col].axvline(true_freq, color='red', linestyle='--',
                                 linewidth=1.2)
            error_pct = abs(velocity - doppler_to_velocity(true_freq)) \
                        / doppler_to_velocity(true_freq) * 100
            colour = 'green' if error_pct < 5 else 'red'
            axes[2, col].set_title(f'{velocity:.2f} m/s  ({error_pct:.1f}%)',
                                   fontsize=9, color=colour)
        else:
            axes[2, col].set_title(f'{velocity:.2f} m/s', fontsize=9)

        axes[2, col].set_xlim(0, x_max)
        axes[2, col].legend(fontsize=7)

        for row in range(3):
            axes[row, col].set_xlabel('Frequency (Hz)', fontsize=8)

    _save(filename)
