
# plot_xca_analysis.py
"""
Generates supporting plots for the GAUSSIAN_WIDTH_BINS / DETECT_THRESHOLD
discussion in estimate_xca_params.py: shows the DC-leakage problem at low
speed directly, the sigma-vs-speed split, and the corr_score separation
DETECT_THRESHOLD is picked from. Each plot annotates the specific
comparison it's meant to make, rather than just showing the data and
leaving the reader to find it. Not meant to be a polished report figure,
just something to put next to the numbers in chat.

Writes PNGs into quartus/scripts/xca_plots/ (gitignored, regenerate with
this script rather than committing the images).
"""

import glob
import os
import re

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

from estimate_xca_params import (
    load_run, is_corrupted, fit_sigma, expected_bin, speed_from_path,
    gaussian_coeffs, corr_scores, MIN_BIN, MAX_BIN, BIN_TOLERANCE,
)

OUT_DIR = os.path.join(os.path.dirname(__file__), 'xca_plots')


def plot_dc_leakage_examples():
    """Same run, same target speed (15 km/h no-radome), two different
    frames: one where the raw peak got fooled by DC/1-over-f leakage into
    bin 1, one where it correctly found the real target - shows this is
    frame-dependent noise, not a speed difference. Arrows call out the
    leakage bar and the real-target bar directly in each panel."""
    frames = load_run('data/run4_15kmh_noradome/spectrum.csv')
    fooled = frames[0]
    correct = frames[4]
    exp = expected_bin(15)

    fig, axes = plt.subplots(1, 2, figsize=(11, 5))
    ymax = max(fooled.max(), correct.max()) * 1.15
    panels = [
        (axes[0], fooled, 'Frame 0 - argmax picks the WRONG bin', [
            (0, 'DC leakage\n(argmax picks this)', '#c44e52', (6, ymax * 0.92)),
            (17, 'real target\n(weaker, loses)', '#4c72b0', (24, ymax * 0.45)),
        ]),
        (axes[1], correct, 'Frame 4 - argmax picks the RIGHT bin', [
            (0, 'DC leakage\n(still there)', '#999999', (6, ymax * 0.92)),
            (20, 'real target\n(stronger, wins)', '#2ca02c', (26, ymax * 0.75)),
        ]),
    ]
    for ax, mag2, title, raw_callouts in panels:
        callouts = [(b, mag2[b], text, color, xt) for b, text, color, xt in raw_callouts]
        bins = np.arange(0, 40)
        colors = ['#c44e52' if b == 0 else '#4c72b0' for b in bins]
        ax.bar(bins, mag2[:40], color=colors)
        ax.axvline(exp, color='black', linestyle=':', alpha=0.5, label=f'expected bin ({exp:.0f})')
        for bin_idx, val, text, color, (tx, ty) in callouts:
            ax.annotate(text, xy=(bin_idx, val), xytext=(tx, ty),
                        fontsize=9, color=color, fontweight='bold', ha='left', va='center',
                        arrowprops=dict(arrowstyle='->', color=color, lw=1.5))
        ax.set_ylim(0, ymax)
        ax.set_title(title, fontsize=11, pad=10)
        ax.set_xlabel('bin')
        ax.set_ylabel('mag2')
        ax.legend(fontsize=8, loc='lower right')
    fig.suptitle('Same target, same speed - whether argmax gets fooled depends on the frame, not the speed',
                 fontsize=12)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    fig.savefig(os.path.join(OUT_DIR, 'dc_leakage_examples.png'), dpi=130)
    plt.close(fig)


def plot_sigma_vs_speed():
    paths = sorted(glob.glob('data/run*_*/spectrum.csv'))
    rows = []  # (speed, radome, sigma)
    for path in paths:
        speed = speed_from_path(path)
        radome = 'radome' in path and 'noradome' not in path
        exp_bin = expected_bin(speed)
        frames = load_run(path)
        for mag2 in frames.values():
            if is_corrupted(mag2):
                continue
            peak_bin = MIN_BIN + int(np.argmax(mag2[MIN_BIN:MAX_BIN + 1]))
            if abs(peak_bin - exp_bin) > BIN_TOLERANCE:
                continue
            sigma = fit_sigma(mag2, peak_bin)
            if sigma is not None:
                rows.append((speed, radome, sigma))

    fig, ax = plt.subplots(figsize=(8, 5))

    # shaded zones behind the points, labelled directly
    ax.axvspan(0, 7, color='#c44e52', alpha=0.08)
    ax.axvspan(7, 17, color='#2ca02c', alpha=0.08)
    ax.text(3.5, 21.5, 'LOW SPEED\nclose to DC - possibly\nbiased narrow by the skirt',
            ha='center', fontsize=9, color='#c44e52', fontweight='bold')
    ax.text(12, 21.5, 'HIGH SPEED\nfar from DC - trust these,\nneed MORE data here',
            ha='center', fontsize=9, color='#2ca02c', fontweight='bold')

    for radome, marker, label, color in [
        (False, 'o', 'no radome', '#4c72b0'),
        (True, '^', 'radome', '#dd8452'),
    ]:
        pts = [(s, sig) for s, r, sig in rows if r == radome]
        if pts:
            xs, ys = zip(*pts)
            jitter = np.random.default_rng(0).uniform(-0.3, 0.3, len(xs))
            ax.scatter(np.array(xs) + jitter, ys, marker=marker, label=label, color=color,
                       s=70, alpha=0.85, zorder=3, edgecolors='white', linewidths=0.5)

    low_med = np.median([sig for s, r, sig in rows if s < 7])
    high_med = np.median([sig for s, r, sig in rows if s >= 7])
    ax.annotate('', xy=(3.5, low_med), xytext=(3.5, high_med),
                arrowprops=dict(arrowstyle='<->', color='black', lw=1))
    ax.text(4.3, (low_med + high_med) / 2, f'~{high_med/low_med:.1f}x gap',
            fontsize=9, fontweight='bold', va='center')

    ax.axhline(4, color='gray', linestyle=':', label='current placeholder (4)', zorder=1)
    ax.set_xlabel('treadmill speed (km/h)')
    ax.set_ylabel('fitted sigma (bins)')
    ax.set_ylim(0, 24)
    ax.set_title('The fitted "width" roughly triples once you get away from DC\n'
                 'is that real, or measurement bias? Need more high-speed runs to know.', fontsize=11)
    ax.legend(fontsize=8, loc='lower right')
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_DIR, 'sigma_vs_speed.png'), dpi=130)
    plt.close(fig)


def plot_corr_score_separation():
    chosen_sigma = 4
    half, coeffs = gaussian_coeffs(chosen_sigma)
    paths = sorted(glob.glob('data/run*_*/spectrum.csv'))

    peak_scores, bg_scores = [], []
    for path in paths:
        exp_bin = expected_bin(speed_from_path(path))
        frames = load_run(path)
        for mag2 in frames.values():
            if is_corrupted(mag2):
                continue
            scores = corr_scores(mag2, half, coeffs)
            xca_bin = MIN_BIN + int(np.argmax(scores[MIN_BIN:MAX_BIN + 1]))

            guard = max(3 * half, BIN_TOLERANCE)
            bg_mask = np.zeros(len(scores), dtype=bool)
            bg_mask[MIN_BIN:MAX_BIN + 1] = True
            for center in (xca_bin, int(round(exp_bin))):
                lo, hi = max(MIN_BIN, center - guard), min(MAX_BIN, center + guard)
                bg_mask[lo:hi + 1] = False
            bg = scores[bg_mask]
            bg_scores.extend(bg[bg > 0].tolist())

            if abs(xca_bin - exp_bin) <= BIN_TOLERANCE:
                peak_scores.append(int(scores[xca_bin]))

    bg_scores = np.array(bg_scores)
    peak_scores = np.array(peak_scores)
    bg_p95 = np.percentile(bg_scores, 95)
    peak_p5 = np.percentile(peak_scores, 5)
    threshold = int((bg_p95 + peak_p5) / 2)
    gap_ratio = peak_p5 / bg_p95

    fig, ax = plt.subplots(figsize=(9, 5))
    bins = np.logspace(np.log10(max(min(bg_scores), 1)), np.log10(max(peak_scores)), 40)
    ax.hist(bg_scores, bins=bins, alpha=0.7, label=f'background bins (n={len(bg_scores)})', color='#4c72b0')
    ax.hist(peak_scores, bins=bins, alpha=0.7, label=f'real detections (n={len(peak_scores)})', color='#c44e52')

    ax.axvspan(bg_p95, peak_p5, color='#2ca02c', alpha=0.15, zorder=0)
    ax.text(np.sqrt(bg_p95 * peak_p5), ax.get_ylim()[1] * 0.85,
            f'EMPTY GAP\n~{gap_ratio:.0f}x\nsafe to threshold here',
            ha='center', fontsize=10, fontweight='bold', color='#2ca02c')

    ax.axvline(threshold, color='black', linestyle='--', lw=2)
    ax.annotate(f'proposed\nDETECT_THRESHOLD\n{threshold:.2e}', xy=(threshold, ax.get_ylim()[1] * 0.4),
                xytext=(15, 0), textcoords='offset points', fontsize=9, fontweight='bold')

    ax.set_xscale('log')
    ax.set_xlabel('corr_score (log scale)')
    ax.set_ylabel('count')
    ax.set_title(f'Background noise and real detections barely come close to touching (sigma={chosen_sigma})',
                 fontsize=11)
    ax.legend(fontsize=8, loc='upper left')
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_DIR, 'corr_score_separation.png'), dpi=130)
    plt.close(fig)


if __name__ == '__main__':
    os.makedirs(OUT_DIR, exist_ok=True)
    plot_dc_leakage_examples()
    plot_sigma_vs_speed()
    plot_corr_score_separation()
    print(f"wrote plots to {OUT_DIR}")
