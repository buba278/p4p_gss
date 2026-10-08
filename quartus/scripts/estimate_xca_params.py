
# estimate_xca_params.py
"""
Estimates two of peak_xca.sv's still-placeholder parameters -
GAUSSIAN_WIDTH_BINS and DETECT_THRESHOLD - from the real treadmill captures
in data/run*_*/spectrum.csv.

GAUSSIAN_WIDTH_BINS (sigma): for each frame, fits a Gaussian to the real
magnitude around a candidate peak bin (a Gaussian is a parabola in log
space, so this is a quadratic least-squares fit to ln(mag2 - noise_floor)
over a window that adaptively widens until the data drops back into the
noise floor). Two filters are applied before trusting a fit:
  - corrupted/dropped-line frames (near-zero total energy) are skipped
  - the candidate bin must land near the bin physically expected from that
    run's labelled treadmill speed (folder name), via the same Doppler
    conversion freq_to_speed.sv uses - otherwise it's more likely clutter
    or DC/1-over-f leakage into a low bin than the real target, even if it
    locally looks Gaussian-ish
Reports the spread across every frame/run, not just one number, so you can
see how consistent the real return width actually is across speeds and
radome conditions before picking a value.

DETECT_THRESHOLD: replays the exact hardware correlator math (same
top-20-bit truncation, same 18-bit Q0.17 coefficient quantisation as
gen_gaussian_mif.py/peak_xca.sv) over every eligible bin of every real
frame, using the sigma estimated above, and finds each frame's winning bin
the same way peak_xca.sv would (argmax of corr_score, not of raw
magnitude). Frames whose XCA winner doesn't land near the physically
expected bin are excluded from the "true detection" distribution - we
can't trust their score represents a real detection. Compares that
distribution against the correlation score of bins clearly unrelated to
either the winner or the expected target location (the correlation-domain
noise floor) to see if there's a clean gap to set a threshold in.

Caveat: every capture in this dataset has a real target somewhere in the
frame - there's no target-free capture to show what corr_score looks like
with nothing to detect at all. So this is a starting point for bench
validation, not a final calibrated number.
"""

import csv
import glob
import re

import numpy as np

MIN_BIN = 1
MAX_BIN = 225          # the real ~150 km/h cap, not the 2047 treadmill-testing override
TRUNC_BITS = 20
COEFF_BITS = 18
MAG2_BITS = 48
NUM_BINS = 2049         # bin 0 (DC) .. bin 2048 (Nyquist) inclusive

# Real hardware constants (see freq_to_speed.sv / run_adc_through_pipeline.py),
# not python_pipeline/config.py's placeholders.
SAMPLE_RATE = 96000
FFT_N = 4096
MOUNT_ANGLE_DEG = 40
HZ_PER_BIN = SAMPLE_RATE / FFT_N
BIN_TOLERANCE = 6       # how many bins from the expected location still counts as "the target"


def expected_bin(speed_kmh):
    freq_hz = speed_kmh * 44.7 * np.cos(np.radians(MOUNT_ANGLE_DEG))
    return freq_hz / HZ_PER_BIN


def speed_from_path(path):
    m = re.search(r'run\d+_(\d+)kmh', path)
    return float(m.group(1)) if m else None


def load_run(path):
    """spectrum.csv -> {frame: mag2 array of length NUM_BINS}"""
    frames = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            frame = int(row['frame'])
            frames.setdefault(frame, np.zeros(NUM_BINS, dtype=np.int64))
            frames[frame][int(row['bin'])] = int(row['mag2'])
    return frames


def is_corrupted(mag2):
    """Dropped/lost telemetry lines leave bins at their zero-init value;
    a frame that's almost entirely zero over the eligible range is a lost
    capture, not a quiet one."""
    eligible = mag2[MIN_BIN:MAX_BIN + 1]
    return np.count_nonzero(eligible) < 0.5 * len(eligible)


def interpolate_peak(mag2, peak_bin):
    """
    3-point log-domain (Gaussian) sub-bin interpolation: fits a parabola to
    ln(mag2) at peak_bin-1/peak_bin/peak_bin+1 and returns the vertex
    position. This is the same shape assumption the correlator template
    uses, so it's the natural interpolator for a return we expect to be
    Gaussian - a plain linear-magnitude parabola would be a worse fit to a
    Gaussian peak. Falls back to the plain integer bin if the neighbours
    can't support a log (zero) or don't actually look like a peak.
    """
    y_m1, y_0, y_p1 = mag2[peak_bin - 1], mag2[peak_bin], mag2[peak_bin + 1]
    if y_m1 <= 0 or y_0 <= 0 or y_p1 <= 0:
        return float(peak_bin)
    l_m1, l_0, l_p1 = np.log(float(y_m1)), np.log(float(y_0)), np.log(float(y_p1))
    denom = l_m1 - 2 * l_0 + l_p1
    if denom >= 0:
        return float(peak_bin)  # not concave here, no meaningful vertex
    offset = 0.5 * (l_m1 - l_p1) / denom
    return peak_bin + max(-0.5, min(0.5, offset))


def fit_sigma(mag2, peak_bin, center=None, max_half_width=40, floor_snr=3.0):
    """
    Gaussian sigma (in bins) of the return centred on `center` (a possibly
    fractional bin position; defaults to the integer peak_bin), via a
    quadratic fit to ln(mag2 - floor) vs offset-from-center. None if
    there's no usable window (too close to an edge, or too few bins clear
    the floor).
    """
    if center is None:
        center = float(peak_bin)
    n = len(mag2)
    far = np.concatenate([mag2[max(0, peak_bin - 200):max(0, peak_bin - 60)],
                           mag2[peak_bin + 60: peak_bin + 200]])
    if len(far) < 20:
        return None
    floor = np.median(far)

    half = 0
    while half < max_half_width:
        lo, hi = peak_bin - half - 1, peak_bin + half + 1
        if lo < 1 or hi >= n:
            break
        if mag2[lo] < floor_snr * floor and mag2[hi] < floor_snr * floor:
            break
        half += 1
    if half < 2:
        return None

    bins = np.arange(peak_bin - half, peak_bin + half + 1)
    offsets = bins - center
    window = mag2[peak_bin - half: peak_bin + half + 1].astype(np.float64) - floor
    mask = window > 0
    if mask.sum() < 5:
        return None

    a2, a1, a0 = np.polyfit(offsets[mask], np.log(window[mask]), 2)
    if a2 >= 0:
        return None
    return float(np.sqrt(-1.0 / (2 * a2)))


def gaussian_coeffs(sigma, bit_width=COEFF_BITS):
    """Same construction as gen_gaussian_mif.py."""
    half = int(round(3 * sigma))
    scale = 1 << (bit_width - 1)
    k = np.arange(half + 1)
    coeffs = np.exp(-(k ** 2) / (2 * sigma ** 2))
    return half, np.round(coeffs * scale).astype(np.int64)


def truncate(mag2):
    """Top TRUNC_BITS of a MAG2_BITS-wide value (mirrors peak_xca.sv's
    mag_trunc: power_mag2[47 -: TRUNC_BITS])."""
    return (mag2.astype(np.int64) >> (MAG2_BITS - TRUNC_BITS))


def corr_scores(mag2, half, coeffs):
    """Same symmetry-folded correlator as peak_xca.sv, for every bin."""
    trunc = truncate(mag2)
    trunc[0] = 0  # DC forced to zero, same as hardware
    kernel = np.concatenate([coeffs[:0:-1], coeffs])  # symmetric, length 2*half+1
    return np.convolve(trunc, kernel, mode='same')


def main():
    paths = sorted(glob.glob('data/run*_*/spectrum.csv'))
    runs = {path: load_run(path) for path in paths}
    total_frames = sum(len(f) for f in runs.values())

    n_corrupted = 0
    n_off_target = 0
    sigma_rows = []
    for path, frames in runs.items():
        exp_bin = expected_bin(speed_from_path(path))
        for frame_idx, mag2 in frames.items():
            if is_corrupted(mag2):
                n_corrupted += 1
                continue
            peak_bin = MIN_BIN + int(np.argmax(mag2[MIN_BIN:MAX_BIN + 1]))
            if abs(peak_bin - exp_bin) > BIN_TOLERANCE:
                n_off_target += 1
                continue
            sigma_int = fit_sigma(mag2, peak_bin)
            center = interpolate_peak(mag2, peak_bin)
            sigma_interp = fit_sigma(mag2, peak_bin, center=center)
            if sigma_int is not None and sigma_interp is not None:
                sigma_rows.append((path, frame_idx, peak_bin, center, sigma_int, sigma_interp))

    print(f"=== data quality ===")
    print(f"{total_frames} frames total, {n_corrupted} corrupted/dropped, "
          f"{n_off_target} where raw-magnitude peak isn't near the expected bin "
          f"(DC/1-over-f leakage or clutter, not a fit failure)\n")

    sigmas_int = np.array([r[4] for r in sigma_rows])
    sigmas_interp = np.array([r[5] for r in sigma_rows])
    print(f"=== GAUSSIAN_WIDTH_BINS (sigma): integer-centred vs interpolated-centred ===")
    print(f"fitted {len(sigmas_int)}/{total_frames} frames (after quality + on-target filtering)")
    if len(sigmas_int) == 0:
        print("no usable fits - nothing to propose")
        return
    print(f"  integer-centred:     median={np.median(sigmas_int):.2f}  mean={sigmas_int.mean():.2f}  "
          f"std={sigmas_int.std():.2f}")
    print(f"  interpolated-centred: median={np.median(sigmas_interp):.2f}  mean={sigmas_interp.mean():.2f}  "
          f"std={sigmas_interp.std():.2f}")
    print(f"  mean |shift| from interpolation: {np.mean(np.abs(sigmas_interp - sigmas_int)):.3f} bins")
    print("  by run (interpolated-centred):")
    for path in paths:
        rows = [r for r in sigma_rows if r[0] == path]
        if rows:
            vals = [r[5] for r in rows]
            print(f"    {path:45s} n={len(vals):2d}  median={np.median(vals):.2f}")

    sigmas = sigmas_interp
    chosen_sigma = int(round(float(np.median(sigmas))))
    print(f"-> proposing GAUSSIAN_WIDTH_BINS = {chosen_sigma} (using interpolated-centred fits)\n")

    half, coeffs = gaussian_coeffs(chosen_sigma)

    peak_scores = []
    bg_scores = []
    n_xca_off_target = 0
    for path, frames in runs.items():
        exp_bin = expected_bin(speed_from_path(path))
        for frame_idx, mag2 in frames.items():
            if is_corrupted(mag2):
                continue
            scores = corr_scores(mag2, half, coeffs)
            eligible_scores = scores[MIN_BIN:MAX_BIN + 1]
            xca_bin = MIN_BIN + int(np.argmax(eligible_scores))

            guard = max(3 * half, BIN_TOLERANCE)
            bg_mask = np.zeros(len(scores), dtype=bool)
            bg_mask[MIN_BIN:MAX_BIN + 1] = True
            for center in (xca_bin, int(round(exp_bin))):
                lo, hi = max(MIN_BIN, center - guard), min(MAX_BIN, center + guard)
                bg_mask[lo:hi + 1] = False
            bg = scores[bg_mask]
            bg_scores.extend(bg[bg > 0].tolist())

            if abs(xca_bin - exp_bin) > BIN_TOLERANCE:
                n_xca_off_target += 1
                continue
            peak_scores.append(int(scores[xca_bin]))

    peak_scores = np.array(peak_scores)
    bg_scores = np.array(bg_scores)
    print(f"=== DETECT_THRESHOLD (sigma={chosen_sigma}) ===")
    print(f"XCA's own winning bin landed near the expected target in "
          f"{len(peak_scores)}/{total_frames - n_corrupted} clean frames "
          f"({n_xca_off_target} missed the expected bin)")
    print(f"winning-bin corr_score:  min={peak_scores.min()}  p5={np.percentile(peak_scores, 5):.0f}  "
          f"median={np.median(peak_scores):.0f}")
    print(f"background corr_score:   median={np.median(bg_scores):.0f}  "
          f"p95={np.percentile(bg_scores, 95):.0f}  max={bg_scores.max()}")

    gap_lo, gap_hi = np.percentile(bg_scores, 95), np.percentile(peak_scores, 5)
    if gap_hi > gap_lo:
        proposed = int((gap_lo + gap_hi) / 2)
        print(f"-> clean separation: background p95={gap_lo:.0f} < winning-bin p5={gap_hi:.0f}")
        print(f"-> proposing DETECT_THRESHOLD = {proposed} (roughly midway, in corr_score units)")
    else:
        print(f"-> NO clean separation (background p95={gap_lo:.0f} >= winning-bin p5={gap_hi:.0f})")
        print("-> can't propose a safe threshold from this data alone")


if __name__ == '__main__':
    main()
