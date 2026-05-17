import numpy as np
import matplotlib.pyplot as plt
import scipy as sp

# Sampling at ~108kHz
# f = 2 * 24e9 * 30 * cos(45deg) / 3e8 = ~3394 Hz
SAMPLE_RATE = 50000 # ADC rate - nyquist 25kHz

# frequency resolution = SAMPLE_RATE / N = 50000 / 1024 = 48.8 Hz per bin
# velocity resolution = 48.8 * C / (2 * CARRIER * cos(45)) = ~0.43 m/s per bin
FFT_SIZE = 1024 # (accuracy vs latency)

CARRIER_FREQ = 24e9
MOUNT_ANGLE_DEG = 45
MOUNT_ANGLE_RAD = np.radians(MOUNT_ANGLE_DEG)
C = 3e8 # speed of light

def velocity_to_doppler(velocity_ms):
    # find what peak freq to expect in spectrum
    # fd = 2v * f0 * cos(theta) / c
    return (2 * velocity_ms * CARRIER_FREQ * np.cos(MOUNT_ANGLE_RAD)) / C

def doppler_to_velocity(freq_hz):
    # FPGA computation from freq bin - END GOAL
    return (freq_hz * C) / (2 * CARRIER_FREQ * np.cos(MOUNT_ANGLE_RAD))

def make_test_signal(velocity_ms, noise_amplitude=0.0, n_samples=FFT_SIZE):
    # seconds axis
    t = np.arrange(n_samples) / SAMPLE_RATE
    
    # IF signal is sine wave at CARRIER freq
    target_freq = velocity_to_doppler(velocity_ms)
    clean_signal = np.sin(2 * np.pi * target_freq * t)

    # fake gaussian noise
    noise = np.random.normal(0, noise_amplitude, n_samples)

    return clean_signal + noise, target_freq

def process_frame(samples):
    n = len(samples)

    # -- hamming window --
    # tapering coefficients (will have same coefficients in ROM)
    window = np.hamming(n)
    windowed_samples = samples * window

    # -- fft --
    # rfft folds results from n to n/2 + 1
    # get freq magnitude bins - bins from 0 -> SAMPLE_RATE/2 (nyquist)
    freq_spectrum = np.abs(np.fft.rfft(windowed_samples))
    # map each bin index to a frequency (Hz)
    freq_axis = np.fft.rfftfreq(n, d=1.0/SAMPLE_RATE)

    # -- CFAR (adaptive noise floor) --
    bin_count = len(freq_spectrum)
    # decide threshold based off of estimated surrounding noise floor, per each bin
    guard_bins = 4 # num bins adjacent to candidate - to be ignored (could have signal energy)
    ref_bins = 16  # num bins around guard bins used to estimate noise floor
    cfar_threshold = np.zeros_like(freq_spectrum)

    # calculate threshold for each bin i
    for i in range(bin_count):
        # slice ref bins width - excl guard bins
        left_refs = freq_spectrum[max(0, i-guard_bins-ref_bins):max(0, i-guard_bins)]
        right_refs = freq_spectrum[min(bin_count, i+guard_bins+1):min(bin_count, i+guard_bins+ref_bins+1)]
        all_refs = np.concatenate([left_refs, right_refs])

        if (len(all_refs > 0)):
            # threshold = arbitrarily 2x local average
            cfar_threshold[i] = 2 * np.mean(all_refs)

    # clear all bins that dont meet local threshold
    freq_spectrum = np.where(freq_spectrum > cfar_threshold, freq_spectrum, 0)

    # -- XCA peak detection --
    gaussian_width = 10 # tune based off antenna width
    gaussian_x = np.arrange(-3*gaussian_width, 3*gaussian_width + 1)
    reference_gaussian = np.exp(-0.5 * (gaussian_x / gaussian_width)**2)

    # cross correlation - slide curve across spectrum
    # output peaks where shapes align the best
    correlation = sp.correlate(freq_spectrum, reference_gaussian, mode='same')
    peak_bin = np.argmax(correlation)
    peak_freq = freq_axis[peak_bin]
    velocity = doppler_to_velocity(peak_freq)
    
    return velocity, freq_axis, freq_spectrum, correlation, peak_freq