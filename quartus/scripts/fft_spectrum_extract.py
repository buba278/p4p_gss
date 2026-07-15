#!/usr/bin/env python3
"""
fft_spectrum_extract.py

Converts a SignalTap CSV export of the fft_ip Avalon-ST source signals
(source_exp / source_imag / source_real / source_sop / source_eop, all as
hex text) into a plain two- or three-column CSV of bin_index, [frequency_hz,]
magnitude -- suitable for pasting into csvplot.com or any other plotting tool.

Expected SignalTap export columns (Export... > .csv, hex radix, one row per
system clock cycle):
    fft_ip:fft_ip_inst|source_exp[5..0]
    fft_ip:fft_ip_inst|source_imag[23..0]
    fft_ip:fft_ip_inst|source_real[23..0]
    fft_ip:fft_ip_inst|source_sop
    fft_ip:fft_ip_inst|source_eop      (optional, only used for a sanity check)

Usage:
    python3 fft_spectrum_extract.py input.csv output.csv [--fs 96000] [--frame 1]

    --fs      sample rate in Hz, used to add a frequency_hz column
              (omit to get bin_index only)
    --frame   which FFT frame to extract if the capture contains more than
              one (1 = first sop found, 2 = second, ...). Default: 1.

Notes on the two things that bite people most with these exports:

  1. Never open/save the raw .csv in Excel before running this script.
     Excel's default "General" cell format auto-detects any hex string that
     happens to look like scientific notation (hex uses A-F, and 'E' is a
     valid hex digit) and silently mangles it into a number, permanently,
     on save. This script does NOT try to repair that -- it just skips rows
     it can't parse and tells you how many. If you see corrupted_rows > 0,
     re-export from Quartus rather than trusting the output.

  2. Only bins 0..N/2 are written out. For a real-valued time-domain input
     (which this is -- a single ADC channel, not I/Q), the FFT output is
     Hermitian-symmetric: bin k and bin N-k are complex conjugates with
     identical magnitude. Bins N/2+1..N-1 are a mirror image of 1..N/2-1
     and add no information, so there's no reason to plot them.
"""

import argparse
import csv
import math
import re
import sys

HEXPAT = re.compile(r'^[0-9A-Fa-f]+$')


def to_signed(hex_str: str, bits: int) -> int:
    """Interpret a hex string as a two's-complement signed integer of the given width."""
    v = int(hex_str, 16)
    if v & (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def find_header_row(lines):
    for i, row in enumerate(lines):
        if row and row[0].strip().startswith('time unit'):
            return i
    raise ValueError("Could not find a 'time unit: ...' header row -- "
                     "is this a raw SignalTap CSV export?")


def col_index(header, needle):
    """Find a column whose name ends with `needle` (handles the full
    'fft_ip:fft_ip_inst|source_exp[5..0]' style names without requiring
    the caller to know the exact instance path)."""
    matches = [i for i, h in enumerate(header) if h.strip().endswith(needle)]
    if not matches:
        raise ValueError(f"Column ending in '{needle}' not found in header.\n"
                          f"Available columns:\n  " + "\n  ".join(header))
    return matches[0]


def extract_frame(rows, i_sop, frame_number):
    sop_idxs = [i for i, row in enumerate(rows)
                if len(row) > i_sop and row[i_sop].strip() == '1']
    if len(sop_idxs) < frame_number:
        raise ValueError(f"Requested frame {frame_number} but only found "
                          f"{len(sop_idxs)} sop pulse(s) in this capture.")
    start = sop_idxs[frame_number - 1]
    end = sop_idxs[frame_number] if len(sop_idxs) > frame_number else len(rows)
    return rows[start:end], sop_idxs


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('input_csv', help='Raw SignalTap CSV export')
    ap.add_argument('output_csv', help='Where to write the spectrum CSV')
    ap.add_argument('--fs', type=float, default=None,
                     help='Sample rate in Hz -- adds a frequency_hz column')
    ap.add_argument('--frame', type=int, default=1,
                     help='Which captured FFT frame to extract (1-indexed). Default: 1')
    args = ap.parse_args()

    with open(args.input_csv, newline='') as f:
        lines = list(csv.reader(f))

    hdr_idx = find_header_row(lines)
    header = [c.strip() for c in lines[hdr_idx]]
    data_rows = [row for row in lines[hdr_idx + 1:] if row and row[0].strip() != '']

    i_exp = col_index(header, 'source_exp[5..0]')
    i_imag = col_index(header, 'source_imag[23..0]')
    i_real = col_index(header, 'source_real[23..0]')
    i_sop = col_index(header, 'source_sop')

    rows = [row for row in data_rows if len(row) > i_sop]
    if not rows:
        sys.exit("No data rows found after the header -- check the file.")

    frame, sop_idxs = extract_frame(rows, i_sop, args.frame)
    n_samples = len(frame)

    mags = [None] * n_samples
    corrupted = 0
    for k, row in enumerate(frame):
        e, re_, im = row[i_exp].strip(), row[i_real].strip(), row[i_imag].strip()
        if not (HEXPAT.match(e) and HEXPAT.match(re_) and HEXPAT.match(im)):
            corrupted += 1
            continue
        exponent = to_signed(e, 6)
        real = to_signed(re_, 24)
        imag = to_signed(im, 24)
        mags[k] = math.hypot(real, imag) * (2.0 ** exponent)

    half = mags[: n_samples // 2 + 1]  # real input -> spectrum is Hermitian-symmetric

    with open(args.output_csv, 'w', newline='') as out:
        w = csv.writer(out)
        if args.fs:
            w.writerow(['bin_index', 'frequency_hz', 'magnitude'])
            for i, m in enumerate(half):
                if m is None:
                    continue
                w.writerow([i, round(i * args.fs / n_samples, 3), round(m, 2)])
        else:
            w.writerow(['bin_index', 'magnitude'])
            for i, m in enumerate(half):
                if m is None:
                    continue
                w.writerow([i, round(m, 2)])

    print(f"Frame {args.frame}: {n_samples} samples "
          f"(sop at row {sop_idxs[args.frame - 1]}), {corrupted} unparseable/corrupted rows skipped.")
    print(f"Wrote {len(half) - sum(1 for m in half if m is None)} spectrum points to {args.output_csv}")


if __name__ == '__main__':
    main()