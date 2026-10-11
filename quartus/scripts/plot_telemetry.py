
# plot_telemetry.py
"""
Plots any of log_telemetry.py's three CSVs (adc.csv, spectrum.csv,
peak.csv) — a quick local alternative to csvplot for sanity-checking a
capture without fighting its overlay/filtering.

adc.csv / spectrum.csv are both per-frame buffers (one raw ADC window or
one spectrum snapshot per frame — see log_telemetry.py's header for what
"frame" means), so each frame is plotted as its own line, addr/bin-sorted.
Overlaying every frame on one plot tangles them together since each frame
is a different few-second snapshot with its own amplitude/shape — this
script keeps them separate by default.

peak.csv is one row per telemetry cycle (no frame column), so it's always
plotted as a time series instead.

The CSV kind is auto-detected from the header row; pass --kind to force it
if you've renamed a file.

Usage:
    python plot_telemetry.py data/test/adc.csv                # small-multiples grid, all frames
    python plot_telemetry.py data/test/adc.csv --frame 3       # just one frame, full size
    python plot_telemetry.py data/test/adc.csv --overlay       # all frames on one axes
    python plot_telemetry.py data/test/spectrum.csv --frame 2  # same options for spectrum
    python plot_telemetry.py data/test/peak.csv                # time series (no --frame/--overlay)
"""

import argparse
import csv
from collections import defaultdict

import matplotlib.pyplot as plt

KIND_COLUMNS = {
    "adc": {"addr", "sample"},
    "spectrum": {"bin", "mag2"},
    "peak": {"peak_bin", "freq_hz", "speed_kmh"},
}


def detect_kind(header):
    fields = set(header)
    for kind, required in KIND_COLUMNS.items():
        if required.issubset(fields):
            return kind
    raise ValueError(f"couldn't detect CSV kind from header {header!r} — pass --kind explicitly")


def load_buffer_frames(csv_path, x_field, y_field):
    """For adc.csv/spectrum.csv: frame -> sorted list of (x, y)."""
    frames = defaultdict(list)
    with open(csv_path, newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            frames[int(row["frame"])].append((int(row[x_field]), int(row[y_field])))
    for frame_id in frames:
        frames[frame_id].sort()  # ensure x-ascending even if the CSV wasn't (shouldn't happen, but cheap to guarantee)
    return frames


def load_peak_series(csv_path):
    timestamps, peak_bins, freqs, speeds = [], [], [], []
    with open(csv_path, newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            timestamps.append(float(row["timestamp"]))
            peak_bins.append(int(row["peak_bin"]))
            freqs.append(float(row["freq_hz"]))
            speeds.append(float(row["speed_kmh"]))
    if timestamps:
        t0 = timestamps[0]
        timestamps = [t - t0 for t in timestamps]
    return timestamps, peak_bins, freqs, speeds


def plot_buffer(csv_path, kind, x_field, y_field, y_label, y_log, args):
    frames = load_buffer_frames(csv_path, x_field, y_field)
    if not frames:
        print(f"No rows found in {csv_path}")
        return

    frame_ids = sorted(frames)
    print(f"{len(frame_ids)} frame(s) found: {frame_ids}")
    for fid in frame_ids:
        ys = [y for _, y in frames[fid]]
        print(f"  frame {fid}: {len(ys)} samples, range [{min(ys)}, {max(ys)}]")

    if args.frame is not None:
        if args.frame not in frames:
            print(f"frame {args.frame} not found")
            return
        xs, ys = zip(*frames[args.frame])
        fig, ax = plt.subplots()
        ax.plot(xs, ys, linewidth=0.8)
        if y_log:
            ax.set_yscale("log")
        ax.set_title(f"{kind}.csv — frame {args.frame}")
        ax.set_xlabel(x_field)
        ax.set_ylabel(y_label)
        plt.show()
        return

    if args.overlay:
        fig, ax = plt.subplots()
        for fid in frame_ids:
            xs, ys = zip(*frames[fid])
            ax.plot(xs, ys, linewidth=0.8, label=f"frame {fid}", alpha=0.8)
        if y_log:
            ax.set_yscale("log")
        ax.set_title(f"{kind}.csv — {len(frame_ids)} frames overlaid")
        ax.set_xlabel(x_field)
        ax.set_ylabel(y_label)
        ax.legend(fontsize="small")
        plt.show()
        return

    # default: small-multiples grid, one subplot per frame
    n = len(frame_ids)
    ncols = min(3, n)
    nrows = (n + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, squeeze=False, figsize=(4 * ncols, 3 * nrows), sharex=True)
    for i, fid in enumerate(frame_ids):
        ax = axes[i // ncols][i % ncols]
        xs, ys = zip(*frames[fid])
        ax.plot(xs, ys, linewidth=0.8)
        if y_log:
            ax.set_yscale("log")
        ax.set_title(f"frame {fid} (n={len(ys)})")
        ax.set_xlabel(x_field)
        ax.set_ylabel(y_label)
    for i in range(n, nrows * ncols):
        axes[i // ncols][i % ncols].axis("off")
    fig.suptitle(f"{kind}.csv — {csv_path}")
    fig.tight_layout()
    plt.show()


def plot_peak(csv_path, args):
    if args.frame is not None or args.overlay:
        print("--frame/--overlay don't apply to peak.csv (no frame column, always a time series)")
    timestamps, peak_bins, freqs, speeds = load_peak_series(csv_path)
    if not timestamps:
        print(f"No rows found in {csv_path}")
        return
    print(f"{len(timestamps)} peak line(s), spanning {timestamps[-1]:.1f}s")
    print(f"  speed range: [{min(speeds):.1f}, {max(speeds):.1f}] km/h")

    fig, axes = plt.subplots(3, 1, sharex=True, figsize=(8, 7))
    axes[0].plot(timestamps, peak_bins, marker=".", linewidth=0.8)
    axes[0].set_ylabel("peak_bin")
    axes[1].plot(timestamps, freqs, marker=".", linewidth=0.8, color="tab:orange")
    axes[1].set_ylabel("freq_hz")
    axes[2].plot(timestamps, speeds, marker=".", linewidth=0.8, color="tab:green")
    axes[2].set_ylabel("speed_kmh")
    axes[2].set_xlabel("seconds since first peak line")
    fig.suptitle(f"peak.csv — {csv_path}")
    fig.tight_layout()
    plt.show()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv_path", help="path to adc.csv / spectrum.csv / peak.csv from log_telemetry.py")
    parser.add_argument("--kind", choices=["adc", "spectrum", "peak"], default=None,
                         help="override auto-detection of CSV kind")
    parser.add_argument("--frame", type=int, default=None, help="(adc/spectrum only) plot only this frame, full-size")
    parser.add_argument("--overlay", action="store_true",
                         help="(adc/spectrum only) plot all frames on one shared axes instead of a grid")
    args = parser.parse_args()

    with open(args.csv_path, newline="") as f:
        header = next(csv.reader(f))
    kind = args.kind or detect_kind(header)

    if kind == "adc":
        plot_buffer(args.csv_path, "adc", "addr", "sample", "sample", y_log=False, args=args)
    elif kind == "spectrum":
        plot_buffer(args.csv_path, "spectrum", "bin", "mag2", "mag2", y_log=True, args=args)
    elif kind == "peak":
        plot_peak(args.csv_path, args)


if __name__ == "__main__":
    main()
