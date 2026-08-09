
# parse_signaltap.py
"""
Converts a raw SignalTap "Export as ASCII" CSV (Groups:/Data: sections, each
multi-bit signal expanded into an aggregate hex column plus one column per bit)
into a tidy CSV: one time column plus one decoded column per signal, ready for
pandas/matplotlib/csvplotter-style tools without hand-editing.

Multi-bit signals are decoded as two's complement (they're DSP sample/magnitude
values in this project); pre-trigger "X" (unknown) samples become empty cells.
"""

import argparse
import csv
import re

GROUP_RE = re.compile(r"^(.*)\[(\d+)\.\.(\d+)\]$")


def parse_header(data_header):
    """Walk the Data: header row and return (time_unit, columns).

    columns is a list of (name, width, is_group) in row order. is_group
    marks aggregate hex columns, which are followed by `width` per-bit
    expansion columns in the row; plain single-bit signals (e.g. a bare
    "valid" flag) get no such expansion and occupy only one column.
    """
    time_unit = data_header[0].split("unit:", 1)[1].strip()

    columns = []
    i = 1
    n = len(data_header)
    while i < n:
        token = data_header[i].strip()
        if not token:
            i += 1
            continue

        match = GROUP_RE.match(token)
        if match:
            name, msb, lsb = match.group(1), int(match.group(2)), int(match.group(3))
            width = msb - lsb + 1
            columns.append((name, width, True))
            i += 1 + width  # skip the expanded per-bit columns
        else:
            columns.append((token, 1, False))
            i += 1

    return time_unit, columns


# Only true two's-complement DSP samples get signed decoding. Everything
# else (bin indices, magnitude-squared, valid/first/last flags) is unsigned
# — signed-decoding an index field flips it negative the moment its MSB
# is set (e.g. bin 2048 in a 12-bit field reading as -2048).
SIGNED_NAME_HINTS = ("real", "imag", "exp")


def short_name(name):
    """fft_ip:fft_ip_inst|source_real -> source_real"""
    return name.rsplit("|", 1)[-1]


def is_signed(short_signal_name):
    return any(hint in short_signal_name for hint in SIGNED_NAME_HINTS)


def decode_value(hex_str, width, signed):
    hex_str = hex_str.strip()
    if not hex_str or "X" in hex_str:
        return ""
    value = int(hex_str, 16)
    if signed and width > 1 and value >= (1 << (width - 1)):
        value -= 1 << width
    return value


def parse_signaltap_csv(in_path):
    with open(in_path, newline="") as f:
        reader = csv.reader(f)
        rows = list(reader)

    data_idx = next(i for i, row in enumerate(rows) if row and row[0].strip() == "Data:")
    header_row = rows[data_idx + 1]
    time_unit, columns = parse_header(header_row)

    signal_names = [short_name(name) for name, _, _ in columns]
    out_header = [f"time_{time_unit}"] + signal_names
    out_rows = []
    for row in rows[data_idx + 2:]:
        if not row or not row[0].strip():
            continue
        decoded = []
        col_idx = 1
        for signal_name, (_, width, is_group) in zip(signal_names, columns):
            decoded.append(decode_value(row[col_idx], width, is_signed(signal_name)))
            col_idx += 1 + width if is_group else 1

        if any(v == "" for v in decoded):
            continue  # pre-trigger row: every field is unknown ("X")

        out_rows.append([row[0].strip()] + [str(v) for v in decoded])

    return out_header, out_rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="Raw SignalTap ASCII export CSV")
    parser.add_argument("-o", "--output", help="Output path (default: <input>_tidy.csv)")
    args = parser.parse_args()

    out_path = args.output or args.input.rsplit(".", 1)[0] + "_tidy.csv"

    header, rows = parse_signaltap_csv(args.input)
    with open(out_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows(rows)

    print(f"Written: {out_path}, {len(rows)} rows, {len(header) - 1} signals")


if __name__ == "__main__":
    main()
