#!/usr/bin/env python3
# gen_hamming_mif.py
"""
Generates hamming_window.mif -> precomputed window coefficients in 18-bit
Q1.17 fixed point format for use in hamming_window.sv

Q1.17: 1 integer bit + 17 fractional bits, unsigned. A coefficient value of
scale (2^17 = 131072) represents 1.0 in this format -- that's what
hamming_window.sv's ">>> 17" rescale expects to divide back out.

--flat produces a boxcar (rectangular) window instead: every address holds
the unity-gain code (scale), not the raw integer 1. This gives a fair A/B
baseline -- amplitude-preserving, only the tapering is removed -- so any
difference in FFT output between the two .mif files is attributable to the
window shape itself, not to an accidental ~2^17x gain cut.
"""
import argparse
import numpy as np

N = 4096        # FFT length
BIT_WIDTH = 18  # (cyclone IV 18-wide multipliers)


def hamming_bit_scaled():
    scale = 1 << (BIT_WIDTH - 1)  # 2^(WIDTH-1) = unity gain in Q1.17
    window = np.hamming(N)
    return np.round(window * scale).astype(int)


def flat_bit_scaled():
    """Boxcar window: every coefficient = unity gain (Q1.17 code for 1.0),
    not the raw integer 1. See module docstring for why that distinction
    matters for a fair before/after comparison."""
    scale = 1 << (BIT_WIDTH - 1)
    return np.full(N, scale, dtype=int)


def write_mif(coeffs, path):
    depth = len(coeffs)
    with open(path, "w") as f:
        f.write(f"WIDTH={BIT_WIDTH};\nDEPTH={depth};\n\n")
        f.write("ADDRESS_RADIX=UNS;\nDATA_RADIX=UNS;\n\n")
        f.write("CONTENT BEGIN\n")
        for address, value in enumerate(coeffs):
            f.write(f"    {address} : {value};\n")
        f.write("END;\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--flat", action="store_true",
        help="Emit a boxcar (all-unity-gain) window instead of Hamming, "
             "for A/B baseline testing against the real coefficients."
    )
    parser.add_argument(
        "-o", "--output", default=None,
        help="Output .mif path (default: hamming_window.mif or "
             "hamming_window_flat.mif in --flat mode)"
    )
    args = parser.parse_args()

    if args.flat:
        coeffs = flat_bit_scaled()
        path = args.output or "hamming_window_flat.mif"
        label = "boxcar (unity gain, all addresses)"
    else:
        coeffs = hamming_bit_scaled()
        path = args.output or "hamming_window.mif"
        label = "Hamming"

    write_mif(coeffs, path)
    print(f"Written: {path}, n={N}, width={BIT_WIDTH}, window={label}")
    print(f"  coeff[0]={coeffs[0]}  coeff[N/2]={coeffs[N//2]}  coeff[N-1]={coeffs[-1]}")