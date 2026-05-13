import numpy as np
import matplotlib.pyplot as plt

# Sampling at ~108kHz
# f = 2 * 24e9 * 30 * cos(45deg) / 3e8 = ~3394 Hz
SAMPLE_RATE = 50000 # ADC rate - nyquist 25kHz

# frequency resolution = SAMPLE_RATE / N = 50000 / 1024 = 48.8 Hz per bin
# velocity resolution = 48.8 * C / (2 * CARRIER * cos(45)) = ~0.43 m/s per bin
N = 1024            # FFT sample size (accuracy vs latency)

CARRIER = 24e9      # 24GHz
MOUNTING_ANGLE = 45 # degrees
C = 3e8             # speed of light
