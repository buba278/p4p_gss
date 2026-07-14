
# gen_hamming_mif.py
"""
Generates hamming_window.mif -> precomputed hamming window coefficients in 18 bit
Q0.17 fixed point format for use in hamming_window.sv
"""

import numpy as np

N = 4096        # FFT length
BIT_WIDTH = 18  # (cyclone IV 18 wide multipliers)

PATH = "hamming_window.mif"

def hamming_bit_scaled():
    scale = 1 << (BIT_WIDTH - 1) # 2^(WIDTH-1)
    window = np.hamming(N)
    return np.round(window * scale).astype(int)

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
    coeffs = hamming_bit_scaled()
    write_mif(coeffs)
    print(f"Written: {PATH}, n={N}, width={BIT_WIDTH}")