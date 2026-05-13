import numpy as np
import matplotlib.pyplot as plt

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

def make_test_signal(velocity_ms, noise_amplitude=0.0, n_samples=FFT_SIZE):
    # seconds axis
    t = np.arrange(n_samples) / SAMPLE_RATE
    
    # IF signal is sine wave at CARRIER freq
    target_freq = velocity_to_doppler(velocity_ms)
    clean_signal = np.sin(2 * np.pi * target_freq * t)

    # fake gaussian noise
    noise = np.random.normal(0, noise_amplitude, n_samples)

    return clean_signal + noise, target_freq

