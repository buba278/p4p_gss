# pipeline.py — DSP stages only, no plotting, no IO

import numpy as np
from scipy import signal as scipy_signal
from config import (SAMPLE_RATE, CFAR_GUARD_BINS, CFAR_REF_BINS,
                    CFAR_THRESHOLD_FACTOR, XCA_GAUSSIAN_WIDTH_BINS,
                    CMA_NOISE_THRESHOLD_FACTOR, CARRIER_FREQ,
                    SPEED_OF_LIGHT, MOUNT_ANGLE_DEG)

# ── Doppler conversions ───────────────────────────────────────────────────────

def velocity_to_doppler(velocity_ms):
    angle = np.radians(MOUNT_ANGLE_DEG)
    return (2 * CARRIER_FREQ * velocity_ms * np.cos(angle)) / SPEED_OF_LIGHT

def doppler_to_velocity(freq_hz):
    angle = np.radians(MOUNT_ANGLE_DEG)
    return (freq_hz * SPEED_OF_LIGHT) / (2 * CARRIER_FREQ * np.cos(angle))

# ── Stage 1: windowing ────────────────────────────────────────────────────────

def apply_window(samples, window_type='hamming'):
    """
    Tapers the sample block edges before FFT to suppress spectral leakage.
    'rectangular' means no windowing — useful as a before/after comparison.
    """
    windows = {
        'hamming':     np.hamming,
        'hanning':     np.hanning,
        'blackman':    np.blackman,
        'rectangular': np.ones,
    }
    if window_type not in windows:
        raise ValueError(f"Unknown window: {window_type}. "
                         f"Choose from {list(windows.keys())}")
    return samples * windows[window_type](len(samples))

# ── Stage 2: FFT ──────────────────────────────────────────────────────────────

def compute_spectrum(windowed_samples):
    """
    Returns magnitude spectrum and frequency axis.
    Both arrays are N/2+1 long, covering 0 to SAMPLE_RATE/2.
    """
    spectrum = np.abs(np.fft.rfft(windowed_samples))
    freqs    = np.fft.rfftfreq(len(windowed_samples), d=1.0 / SAMPLE_RATE)
    return spectrum, freqs

# ── Stage 3: CFAR thresholding ────────────────────────────────────────────────

def apply_cfar(spectrum,
               guard_bins=CFAR_GUARD_BINS,
               ref_bins=CFAR_REF_BINS,
               threshold_factor=CFAR_THRESHOLD_FACTOR):
    """
    For each bin, estimate the local noise floor from surrounding reference bins
    and zero out anything that doesn't stand clearly above it.

    Layout around candidate bin i:
      [ref_bins | guard_bins | i | guard_bins | ref_bins]
    Guard bins are excluded from the noise estimate because signal energy
    spills into adjacent bins and would inflate the threshold.
    """
    result = np.zeros_like(spectrum)
    n = len(spectrum)
    for i in range(n):
        left_refs  = spectrum[max(0, i-guard_bins-ref_bins) : max(0, i-guard_bins)]
        right_refs = spectrum[min(n, i+guard_bins+1)        : min(n, i+guard_bins+ref_bins+1)]
        refs = np.concatenate([left_refs, right_refs])
        if len(refs) > 0 and spectrum[i] > threshold_factor * np.mean(refs):
            result[i] = spectrum[i]
    return result

# ── Stage 4: peak estimators ──────────────────────────────────────────────────

def estimate_zero_crossing(samples):
    """
    Time-domain method — counts rising zero crossings to estimate frequency.
    Operates on raw samples, not the spectrum.
    Included as a baseline to show why it fails at low SNR.
    """
    crossings = sum(
        1 for i in range(1, len(samples))
        if samples[i-1] < 0 and samples[i] >= 0
    )
    return crossings / (len(samples) / SAMPLE_RATE)

def estimate_argmax(spectrum, freqs):
    """
    Returns the frequency of the single tallest bin.
    Simplest possible estimator — quantisation error of up to one bin width.
    """
    return freqs[np.argmax(spectrum)]

def estimate_cma(spectrum, freqs,
                 threshold_factor=CMA_NOISE_THRESHOLD_FACTOR):
    """
    Center-of-Mass Algorithm: power-weighted average frequency of bins
    above a threshold. Fast but pulled off-centre by noise at low SNR.
    """
    threshold = threshold_factor * np.max(spectrum)
    mask = spectrum > threshold
    if not np.any(mask):
        return 0.0
    return np.sum(freqs[mask] * spectrum[mask]) / np.sum(spectrum[mask])

def estimate_xca(spectrum, freqs,
                 gaussian_width_bins=XCA_GAUSSIAN_WIDTH_BINS):
    """
    Cross-Correlation Algorithm: slide a Gaussian template across the spectrum.
    The ground return is Gaussian-shaped because the antenna illuminates a cone —
    each point scatterer contributes a slightly different Doppler shift.
    XCA finds the position of best shape-match rather than the tallest single bin.
    """
    half = 3 * gaussian_width_bins
    x    = np.arange(-half, half + 1)
    ref  = np.exp(-0.5 * (x / gaussian_width_bins) ** 2)
    corr = scipy_signal.correlate(spectrum, ref, mode='same')
    return freqs[np.argmax(corr)]

# ── Full pipeline ─────────────────────────────────────────────────────────────

ESTIMATORS = {
    'zero_crossing': lambda spec, freqs, raw: estimate_zero_crossing(raw),
    'argmax':        lambda spec, freqs, raw: estimate_argmax(spec, freqs),
    'cma':           lambda spec, freqs, raw: estimate_cma(spec, freqs),
    'xca':           lambda spec, freqs, raw: estimate_xca(spec, freqs),
}

def run_pipeline(samples, window_type='hamming', use_cfar=True, estimator='xca'):
    """
    Runs the full DSP chain and returns a dict of intermediate results
    so every stage can be inspected or plotted.
    """
    windowed      = apply_window(samples, window_type)
    spectrum, freqs = compute_spectrum(windowed)
    cfar_spectrum = apply_cfar(spectrum) if use_cfar else spectrum

    if estimator not in ESTIMATORS:
        raise ValueError(f"Unknown estimator: {estimator}. "
                         f"Choose from {list(ESTIMATORS.keys())}")

    peak_freq = ESTIMATORS[estimator](cfar_spectrum, freqs, samples)

    return {
        'raw':          samples,
        'windowed':     windowed,
        'spectrum':     spectrum,
        'cfar_spectrum': cfar_spectrum,
        'freqs':        freqs,
        'peak_freq':    peak_freq,
        'velocity':     doppler_to_velocity(peak_freq),
    }
