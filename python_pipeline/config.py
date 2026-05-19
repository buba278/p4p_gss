# config.py — all constants and tunable parameters

# ── Radar / physics ───────────────────────────────────────────────────────────
CARRIER_FREQ    = 24e9      # Hz — radar carrier frequency
SPEED_OF_LIGHT  = 3e8       # m/s
MOUNT_ANGLE_DEG = 45        # degrees from ground plane

# ── Sampling ──────────────────────────────────────────────────────────────────
SAMPLE_RATE = 31250         # Hz — update this to match your scope's inferred rate
FFT_SIZE    = 1024          # number of samples per frame
# ── CFAR ─────────────────────────────────────────────────────────────────────

CFAR_GUARD_BINS      = 4
CFAR_REF_BINS        = 16
CFAR_THRESHOLD_FACTOR = 2.0

# ── XCA ───────────────────────────────────────────────────────────────────────
XCA_GAUSSIAN_WIDTH_BINS = 10  # tune once you have real data

# ── CMA ───────────────────────────────────────────────────────────────────────
CMA_NOISE_THRESHOLD_FACTOR = 0.1
