
# gen_gaussian_mif.py
"""
Generates a gaussian_window*.mif -> precomputed Gaussian correlation
template coefficients for use in xca_core.sv, as unsigned 18-bit
fixed-point integers with 17 fractional bits (so stored value v represents
v / 2^17; the peak coefficient at offset 0, weight 1.0, is stored as
2^17). 18 bits because that's the Cyclone IV's native multiplier width,
not tied to the FFT's own output format.

Only stores offsets 0..HALF (the coefficient is even-symmetric, coeff[k] ==
coeff[-k], so xca_core folds each pair of taps before multiplying by the
shared coefficient - the ROM only ever needs to hold one side).

sigma (GAUSSIAN_WIDTH_BINS) is passed as an argument since peak_xca.sv now
runs two correlator cores side by side (see gen_gaussian_mif.py --help),
one per candidate width, each needing its own ROM/mif. HALF = 3*sigma (3
standard deviations either side of the peak captures ~99.7% of the
template's weight; coefficients further out are negligible and not worth
storing).

The chosen sigma and output path must match the corresponding
gaussian_rom_sigma<N>.v's numwords_a/widthad_a and peak_xca.sv's core
instantiation - these are not derived from each other automatically, same
caveat as gen_hamming_mif.py's N vs rom_ip.v's numwords_a.
"""

import argparse

import numpy as np

BIT_WIDTH = 18  # (cyclone IV 18 wide multipliers)


def gaussian_bit_scaled(sigma, bit_width=BIT_WIDTH):
    half = 3 * sigma
    scale = 1 << (bit_width - 1)  # 2^(WIDTH-1) - peak (offset 0) coefficient is 1.0
    k = np.arange(half + 1)
    coeffs = np.exp(-(k ** 2) / (2 * sigma ** 2))
    return half, np.round(coeffs * scale).astype(int)


def write_mif(path, coeffs, bit_width=BIT_WIDTH):
    depth = len(coeffs)
    with open(path, "w") as f:
        f.write(f"WIDTH={bit_width};\nDEPTH={depth};\n\n")
        f.write("ADDRESS_RADIX=UNS;\nDATA_RADIX=UNS;\n\n")
        f.write("CONTENT BEGIN\n")
        for address, value in enumerate(coeffs):
            f.write(f"    {address} : {value};\n")
        f.write("END;\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sigma", type=int, default=4,
                        help="GAUSSIAN_WIDTH_BINS to generate coefficients for (default: 4)")
    parser.add_argument("--out", type=str, default=None,
                        help="output .mif path (default: gaussian_window_sigma<N>.mif)")
    args = parser.parse_args()

    path = args.out or f"gaussian_window_sigma{args.sigma}.mif"
    half, coeffs = gaussian_bit_scaled(args.sigma)
    write_mif(path, coeffs)
    print(f"Written: {path}, sigma={args.sigma}, half={half}, depth={half+1}, width={BIT_WIDTH}")
