
# run_adc_through_pipeline.py
"""
Feeds a captured raw ADC window (from log_telemetry.py's adc.csv) through
the Python reference DSP pipeline (python_pipeline/pipeline.py), so you can
see what the reference estimators (argmax/cma/xca/zero_crossing) would
have said about the exact same signal the FPGA processed — useful for
sanity-checking the hardware's XCA output against its own reference model
on real data, not synthetic test signals.

IMPORTANT: python_pipeline/config.py's SAMPLE_RATE/FFT_SIZE/MOUNT_ANGLE_DEG
are placeholders left over from before the hardware config was finalised
(see project history) — NOT the real hardware numbers, and NOT the same
40 degrees freq_to_speed.sv uses (config.py still says 45). This script
does not edit config.py (other work may depend on its current placeholder
values); instead it monkeypatches the already-imported pipeline/plotting
modules' copies of these constants at runtime, for this run only:
    SAMPLE_RATE         96000   (real hardware rate)
    FFT_SIZE            4096    (real hardware window, == adc.csv's frame length)
    MOUNT_ANGLE_DEG     40      (real MEASURED mount angle — matches freq_to_speed.sv's
                                 MOUNT_ANGLE_DEG/K_INT, NOT config.py's stale 45)
    XCA_GAUSSIAN_WIDTH_BINS  4  (matches peak_xca.sv's GAUSSIAN_WIDTH_BINS, before zero-padding)
CARRIER_FREQ is left at config.py's 24e9 (vs. the K-LC6's actual 24.125GHz)
— close enough (~0.5%) not to matter next to bin quantisation error, but
it does mean this script's numbers won't bit-match the hardware's fixed
44.7Hz/km/h constant exactly.

Zero-padding (--zero-pad-factor, default 4): appends zeros after the
Hamming-windowed 4096 real samples before the FFT, up to FFT_SIZE *
zero_pad_factor points. This does NOT add real frequency resolution —
that's fundamentally capped by the 42.6ms real observation window
(Rayleigh limit, ~23.4Hz already-exact bin spacing) — zero-padding just
interpolates the same underlying continuous spectrum onto a finer bin
grid, which reduces how much the peak estimate gets rounded to whichever
23.4Hz-wide bin it happened to fall in. Cheap way to sanity-check whether
XCA's answer is sensitive to that rounding. GAUSSIAN_WIDTH_BINS and
CFAR's guard/ref bin counts are scaled by the same factor so they still
cover the same real Hz width after padding, not a narrower one.

DC removal: adc.csv frames carry a large low-frequency/DC component (see
the 2026-08-20 treadmill test session — this is exactly what peak_xca.sv's
DC-bin-zeroing fix targets on the hardware side). The Python pipeline has
no equivalent, so the mean is subtracted here before windowing, same as
data_loader.py's prepare_scope_signal does for scope captures.

Usage:
    python run_adc_through_pipeline.py data/test/adc.csv                 # every frame, table only
    python run_adc_through_pipeline.py data/test/adc.csv --frame 3       # one frame, table + comparison plot
    python run_adc_through_pipeline.py data/test/adc.csv --no-cfar
    python run_adc_through_pipeline.py data/test/adc.csv --zero-pad-factor 1   # disable zero-padding
"""

import argparse
import csv
import os
import sys
from collections import defaultdict

import numpy as np

PYTHON_PIPELINE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "python_pipeline")
sys.path.insert(0, PYTHON_PIPELINE_DIR)

import pipeline as pl  # noqa: E402
import plotting as pt  # noqa: E402
from pipeline import apply_window, compute_spectrum, apply_cfar, ESTIMATORS, doppler_to_velocity  # noqa: E402

# real hardware config, overriding config.py's placeholders for this run only
HW_SAMPLE_RATE = 96000
HW_FFT_SIZE = 4096
HW_MOUNT_ANGLE_DEG = 40  # matches freq_to_speed.sv — NOT config.py's stale 45
HW_XCA_GAUSSIAN_WIDTH_BINS = 4  # matches peak_xca.sv, before zero-pad scaling
HW_CFAR_GUARD_BINS = pl.CFAR_GUARD_BINS  # config.py's values, scaled below for zero-padding
HW_CFAR_REF_BINS = pl.CFAR_REF_BINS

pl.SAMPLE_RATE = HW_SAMPLE_RATE
pl.MOUNT_ANGLE_DEG = HW_MOUNT_ANGLE_DEG
pt.SAMPLE_RATE = HW_SAMPLE_RATE


def load_adc_frames(csv_path):
    frames = defaultdict(list)
    with open(csv_path, newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            frames[int(row["frame"])].append((int(row["addr"]), int(row["sample"])))
    out = {}
    for fid, pairs in frames.items():
        pairs.sort()
        out[fid] = np.array([s for _, s in pairs], dtype=float)
    return out


def run_one_frame(frame_id, samples, use_cfar, zero_pad_factor, make_plot):
    if len(samples) != HW_FFT_SIZE:
        print(f"  [skip] frame {frame_id}: {len(samples)} samples, need exactly {HW_FFT_SIZE} — "
              f"partial frame (logger started/stopped mid-capture)")
        return

    dc = samples.mean()
    centred = samples - dc

    # window the real samples, THEN zero-pad — padding before windowing
    # would let the taper stretch across the padding too, which is wrong
    windowed = apply_window(centred, "hamming")
    fft_size = HW_FFT_SIZE * zero_pad_factor
    padded = np.zeros(fft_size)
    padded[:len(windowed)] = windowed

    spectrum, freqs = compute_spectrum(padded)  # uses pl.SAMPLE_RATE (already overridden to 96000)

    gaussian_width_bins = HW_XCA_GAUSSIAN_WIDTH_BINS * zero_pad_factor
    guard_bins = HW_CFAR_GUARD_BINS * zero_pad_factor
    ref_bins = HW_CFAR_REF_BINS * zero_pad_factor
    cfar_spectrum = apply_cfar(spectrum, guard_bins=guard_bins, ref_bins=ref_bins) if use_cfar else spectrum

    print(f"\nframe {frame_id}  (DC offset removed: {dc:.1f}, fft_size={fft_size}, "
          f"bin_res={HW_SAMPLE_RATE/fft_size:.3f} Hz/bin)")
    print(f"  {'estimator':<16} {'freq (Hz)':>10} {'m/s':>8} {'km/h':>8}")
    print("  " + "-" * 46)

    estimator_fns = {
        "zero_crossing": lambda: pl.estimate_zero_crossing(centred),
        "argmax":        lambda: pl.estimate_argmax(cfar_spectrum, freqs),
        "cma":           lambda: pl.estimate_cma(cfar_spectrum, freqs),
        "xca":           lambda: pl.estimate_xca(cfar_spectrum, freqs, gaussian_width_bins=gaussian_width_bins),
    }

    results = {}
    for name, fn in estimator_fns.items():
        peak_freq = fn()
        velocity = doppler_to_velocity(peak_freq)
        print(f"  {name:<16} {peak_freq:>10.1f} {velocity:>8.3f} {velocity*3.6:>8.1f}")
        results[name] = {
            "raw": centred, "spectrum": spectrum, "cfar_spectrum": cfar_spectrum,
            "freqs": freqs, "peak_freq": peak_freq, "velocity": velocity,
        }

    if make_plot:
        pt.plot_estimator_comparison(
            results,
            title=f"adc.csv frame {frame_id} through Python pipeline "
                  f"(cfar={use_cfar}, zero_pad_factor={zero_pad_factor})",
            filename=f"adc_frame_{frame_id}_pipeline.png",
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv_path", help="path to adc.csv from log_telemetry.py")
    parser.add_argument("--frame", type=int, default=None, help="only run this frame (also saves a comparison plot)")
    parser.add_argument("--no-cfar", action="store_true", help="skip CFAR gating before the estimators")
    parser.add_argument("--zero-pad-factor", type=int, default=4,
                         help="zero-pad the FFT by this factor for finer bin interpolation (1 = disabled, default 4)")
    args = parser.parse_args()

    frames = load_adc_frames(args.csv_path)
    if not frames:
        print(f"No rows found in {args.csv_path}")
        return

    use_cfar = not args.no_cfar
    print(f"MOUNT_ANGLE_DEG = {HW_MOUNT_ANGLE_DEG} degrees "
          f"(matches freq_to_speed.sv's real measured angle — NOT config.py's stale 45)")
    print(f"SAMPLE_RATE={HW_SAMPLE_RATE}, FFT_SIZE={HW_FFT_SIZE}, "
          f"zero_pad_factor={args.zero_pad_factor} (effective fft_size={HW_FFT_SIZE * args.zero_pad_factor}), "
          f"XCA_GAUSSIAN_WIDTH_BINS={HW_XCA_GAUSSIAN_WIDTH_BINS} (pre-padding), "
          f"CFAR={'on' if use_cfar else 'off'}")

    if args.frame is not None:
        if args.frame not in frames:
            print(f"frame {args.frame} not found (available: {sorted(frames)})")
            return
        run_one_frame(args.frame, frames[args.frame], use_cfar, args.zero_pad_factor, make_plot=True)
        return

    for fid in sorted(frames):
        run_one_frame(fid, frames[fid], use_cfar, args.zero_pad_factor, make_plot=False)


if __name__ == "__main__":
    main()
