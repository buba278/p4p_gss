
# gen_gaussian_mif.py
"""
Generates gaussian_window.mif -> precomputed Gaussian correlation template
coefficients for use in peak_xca.sv, as unsigned 18-bit fixed-point integers
with 17 fractional bits (so stored value v represents v / 2^17; the peak
coefficient at offset 0, weight 1.0, is stored as 2^17). 18 bits because
that's the Cyclone IV's native multiplier width, not tied to the FFT's own
output format.

Only stores offsets 0..HALF (the coefficient is even-symmetric, coeff[k] ==
coeff[-k], so peak_xca folds each pair of taps before multiplying by the
shared coefficient - the ROM only ever needs to hold one side).

GAUSSIAN_WIDTH_BINS is sigma, in bins. HALF = 3*sigma (3 standard
deviations either side of the peak captures ~99.7% of the template's
weight; coefficients further out are negligible and not worth storing).

Must match peak_xca.sv's GAUSSIAN_WIDTH_BINS parameter and gaussian_rom.v's
numwords_a - these are not derived from each other automatically, same
caveat as gen_hamming_mif.py's N vs rom_ip.v's numwords_a.
"""

import numpy as np

GAUSSIAN_WIDTH_BINS = 4   # sigma, in bins - placeholder, tune with real data
HALF = 3 * GAUSSIAN_WIDTH_BINS
BIT_WIDTH = 18  # (cyclone IV 18 wide multipliers)

PATH = "gaussian_window.mif"

def gaussian_bit_scaled():
    scale = 1 << (BIT_WIDTH - 1)  # 2^(WIDTH-1) - peak (offset 0) coefficient is 1.0
    k = np.arange(HALF + 1)
    coeffs = np.exp(-(k**2) / (2 * GAUSSIAN_WIDTH_BINS**2))
    return np.round(coeffs * scale).astype(int)

def write_mif(coeffs):
    depth = len(coeffs)
    with open(PATH, "w") as f:
        f.write(f"WIDTH={BIT_WIDTH};\nDEPTH={depth};\n\n")
        f.write("ADDRESS_RADIX=UNS;\nDATA_RADIX=UNS;\n\n")
        f.write("CONTENT BEGIN\n")
        for address, value in enumerate(coeffs):
            f.write(f"    {address} : {value};\n")
        f.write("END;\n")

if __name__ == "__main__":
    coeffs = gaussian_bit_scaled()
    write_mif(coeffs)
    print(f"Written: {PATH}, half={HALF}, depth={HALF+1}, width={BIT_WIDTH}")
