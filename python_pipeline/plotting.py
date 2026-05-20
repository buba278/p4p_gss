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

# ── Estimator comparison ──────────────────────────────────────────────────────

def plot_estimator_comparison(results_dict, true_freq=None,
                               title='', filename='comparison.png'):
    estimators = list(results_dict.keys())
    n          = len(estimators)
    # 4 rows now: time domain, FFT, CFAR, peak estimate
    fig, axes  = plt.subplots(4, n, figsize=(5*n, 13))
    if n == 1:
        axes = axes.reshape(-1, 1)

    fig.suptitle(title, fontsize=13, fontweight='bold')
    row_labels = ['Time domain\n(first 5ms)', 'FFT spectrum', 
                  'After CFAR', 'Peak estimate']
    for row, label in enumerate(row_labels):
        axes[row, 0].set_ylabel(label, fontsize=9)

    # x_max shared across all columns so spectra are comparable
    if true_freq:
        x_max = max(true_freq * 4, 500)
    else:
        # use the median peak freq across estimators to avoid one bad
        # estimator stretching the axis for everyone
        peak_freqs = [r['peak_freq'] for r in results_dict.values() 
                      if r['peak_freq'] > 0]
        x_max = max(np.median(peak_freqs) * 4, 500) if peak_freqs else 2000

    t           = np.arange(len(list(results_dict.values())[0]['raw'])) / SAMPLE_RATE
    samples_5ms = int(0.005 * SAMPLE_RATE)

    for col, est in enumerate(estimators):
        r         = results_dict[est]
        freqs     = r['freqs']
        peak_freq = r['peak_freq']
        velocity  = r['velocity']

        axes[0, col].set_title(est.upper().replace('_', ' '),
                               fontsize=11, fontweight='bold')

        # ── Row 0: time domain ────────────────────────────────────────────
        axes[0, col].plot(t[:samples_5ms] * 1000, r['raw'][:samples_5ms],
                          color='steelblue', linewidth=0.8)
        axes[0, col].axhline(0, color='gray', linewidth=0.5)
        axes[0, col].set_xlabel('Time (ms)')

        # ── Row 1: FFT spectrum ───────────────────────────────────────────
        axes[1, col].plot(freqs, r['spectrum'], color='steelblue', linewidth=0.7)
        axes[1, col].set_xlim(0, x_max)
        if true_freq:
            axes[1, col].axvline(true_freq, color='red', linestyle='--', linewidth=1)
        axes[1, col].set_xlabel('Frequency (Hz)')

        # ── Row 2: CFAR ───────────────────────────────────────────────────
        axes[2, col].plot(freqs, r['cfar_spectrum'], color='darkorange', linewidth=0.7)
        axes[2, col].set_xlim(0, x_max)
        if true_freq:
            axes[2, col].axvline(true_freq, color='red', linestyle='--', linewidth=1)
        axes[2, col].set_xlabel('Frequency (Hz)')

        # ── Row 3: peak estimate ──────────────────────────────────────────
        axes[3, col].plot(freqs, r['cfar_spectrum'], color='darkorange',
                          linewidth=0.7, alpha=0.5)
        axes[3, col].axvline(peak_freq, color='green', linewidth=1.5,
                             label=f'{peak_freq:.0f} Hz')
        axes[3, col].set_xlim(0, x_max)
        if true_freq:
            axes[3, col].axvline(true_freq, color='red', linestyle='--',
                                 linewidth=1.2)
            error_pct = abs(velocity - doppler_to_velocity(true_freq)) \
                        / doppler_to_velocity(true_freq) * 100
            colour = 'green' if error_pct < 5 else 'red'
            axes[3, col].set_title(f'{velocity:.2f} m/s  ({error_pct:.1f}%)',
                                   fontsize=9, color=colour)
        else:
            axes[3, col].set_title(f'{velocity:.2f} m/s', fontsize=9)
        axes[3, col].set_xlabel('Frequency (Hz)')
        axes[3, col].legend(fontsize=7)

    _save(filename)
