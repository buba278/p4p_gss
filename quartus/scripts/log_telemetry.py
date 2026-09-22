
# log_telemetry.py
"""
Logs the FPGA's telemetry UART link to CSV instead of a live plot — for
runs (e.g. the calibrated treadmill test) where you want a real record to
correlate against a known-speed reference afterward, not just a live look.

Expects telemetry_uart_tx.sv's tagged line format:
    "S<3 hex bin><1 hex exp><4 hex mantissa><1 hex checksum>\n"   spectrum bin
    "A<3 hex addr><6 hex sample><1 hex checksum>\n"               raw ADC sample
    "P<3 hex peak_bin><5 hex freq_scaled><10 hex speed_scaled><1 hex checksum>\n"
                                                                   pipeline output, one per cycle

mag2 is reconstructed from the exponent/mantissa hex-float encoding (see
spectrum_uart_tx.sv's header for the exact formula — telemetry_uart_tx.sv
reuses it unchanged). Raw ADC samples are a plain 24-bit two's-complement
hex word, sign-extended to a normal signed int for the CSV. freq_scaled/
speed_scaled are the fixed-point values straight off bin_to_freq.sv /
freq_to_speed.sv (Hz*16, km/h*65536) — divided back down to real units here.

checksum is the XOR of every nibble before it on the line (tag byte
excluded, since it's fixed per line kind). A line whose checksum doesn't
match is dropped rather than logged as a false reading — same reasoning as
live_spectrum.py.

Each pass over the spectrum snapshot / raw-sample snapshot restarts at
index 0, so a wraparound (bin/addr going back to 0) marks the start of a
new frame — that's how frame_id increments below. A dropped line only
loses that one row; nothing else is affected.

Writes three CSVs (spectrum.csv, adc.csv, peak.csv) into --out-dir, all
with a wall-clock timestamp column so they can be joined against an
external reference log (e.g. the treadmill's own speed timestamps) after
the run.
"""

import argparse
import csv
import sys
import time

import serial

BIN_DIGITS = 3        # must match BIN_DIGITS in telemetry_uart_tx.sv
MANTISSA_DIGITS = 4   # must match MANTISSA_DIGITS in telemetry_uart_tx.sv
ADC_DIGITS = 6         # must match ADC_WIDTH/4 in telemetry_uart_tx.sv
ADC_WIDTH = 24
FREQ_DIGITS = 5        # must match FREQ_WIDTH/4 in telemetry_uart_tx.sv
SPEED_DIGITS = 10      # must match SPEED_WIDTH/4 in telemetry_uart_tx.sv
FREQ_FRAC_BITS = 4     # must match bin_to_freq.sv's FREQ_FRAC_BITS (freq_scaled = Hz * 2^this)
SPEED_FRAC_BITS = 16   # must match freq_to_speed.sv's K_FRAC_BITS (speed_scaled = km/h * 2^this)


def decode_spectrum(body):
    """'<3 bin digits><1 exp digit><4 mantissa digits><1 checksum digit>' -> (bin, mag2)."""
    expected_len = BIN_DIGITS + 1 + MANTISSA_DIGITS + 1
    if len(body) != expected_len:
        raise ValueError(f"expected {expected_len} hex chars, got {body!r}")
    nibbles = [int(c, 16) for c in body]
    checksum = 0
    for n in nibbles[:-1]:
        checksum ^= n
    if checksum != nibbles[-1]:
        raise ValueError(f"checksum mismatch in {body!r}")
    bin_idx = int(body[:BIN_DIGITS], 16)
    exp = nibbles[BIN_DIGITS]
    mantissa = int(body[BIN_DIGITS + 1:BIN_DIGITS + 1 + MANTISSA_DIGITS], 16)
    if exp >= MANTISSA_DIGITS - 1:
        mag2 = mantissa << ((exp - (MANTISSA_DIGITS - 1)) * 4)
    else:
        mag2 = mantissa
    return bin_idx, mag2


def decode_adc(body):
    """'<3 addr digits><6 sample digits><1 checksum digit>' -> (addr, signed sample)."""
    expected_len = BIN_DIGITS + ADC_DIGITS + 1
    if len(body) != expected_len:
        raise ValueError(f"expected {expected_len} hex chars, got {body!r}")
    nibbles = [int(c, 16) for c in body]
    checksum = 0
    for n in nibbles[:-1]:
        checksum ^= n
    if checksum != nibbles[-1]:
        raise ValueError(f"checksum mismatch in {body!r}")
    addr = int(body[:BIN_DIGITS], 16)
    sample = int(body[BIN_DIGITS:BIN_DIGITS + ADC_DIGITS], 16)
    if sample >= (1 << (ADC_WIDTH - 1)):
        sample -= 1 << ADC_WIDTH
    return addr, sample


def decode_peak(body):
    """'<3 bin digits><5 freq digits><10 speed digits><1 checksum digit>'
    -> (peak_bin, freq_hz, speed_kmh)."""
    expected_len = BIN_DIGITS + FREQ_DIGITS + SPEED_DIGITS + 1
    if len(body) != expected_len:
        raise ValueError(f"expected {expected_len} hex chars, got {body!r}")
    nibbles = [int(c, 16) for c in body]
    checksum = 0
    for n in nibbles[:-1]:
        checksum ^= n
    if checksum != nibbles[-1]:
        raise ValueError(f"checksum mismatch in {body!r}")
    peak_bin = int(body[:BIN_DIGITS], 16)
    freq_scaled = int(body[BIN_DIGITS:BIN_DIGITS + FREQ_DIGITS], 16)
    speed_scaled = int(body[BIN_DIGITS + FREQ_DIGITS:BIN_DIGITS + FREQ_DIGITS + SPEED_DIGITS], 16)
    freq_hz = freq_scaled / (1 << FREQ_FRAC_BITS)
    speed_kmh = speed_scaled / (1 << SPEED_FRAC_BITS)
    return peak_bin, freq_hz, speed_kmh


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("port", help="Serial port, e.g. /dev/ttyUSB0 or COM3")
    parser.add_argument("--baud", type=int, default=115200)  # must match BAUD_RATE in radar_top.sv
    parser.add_argument("--out-dir", default=".", help="directory to write spectrum.csv/adc.csv into")
    args = parser.parse_args()

    try:
        ser = serial.Serial(args.port, args.baud, timeout=1)
    except serial.SerialException as exc:
        print(f"ERROR: could not open {args.port} at {args.baud} baud: {exc}", file=sys.stderr)
        sys.exit(1)

    spectrum_path = f"{args.out_dir}/spectrum.csv"
    adc_path = f"{args.out_dir}/adc.csv"
    peak_path = f"{args.out_dir}/peak.csv"
    spectrum_f = open(spectrum_path, "w", newline="")
    adc_f = open(adc_path, "w", newline="")
    peak_f = open(peak_path, "w", newline="")
    spectrum_w = csv.writer(spectrum_f)
    adc_w = csv.writer(adc_f)
    peak_w = csv.writer(peak_f)
    spectrum_w.writerow(["timestamp", "frame", "bin", "mag2"])
    adc_w.writerow(["timestamp", "frame", "addr", "sample"])
    peak_w.writerow(["timestamp", "peak_bin", "freq_hz", "speed_kmh"])

    spectrum_frame = -1
    spectrum_prev_bin = None
    adc_frame = -1
    adc_prev_addr = None
    latest_peak = None  # (peak_bin, freq_hz, speed_kmh) - for the console report

    lines_seen = 0
    lines_parsed = 0
    last_report = time.monotonic()

    print(f"Connected to {args.port} at {args.baud} baud, logging to "
          f"{spectrum_path}, {adc_path} and {peak_path}...")
    print("Ctrl-C to stop.")

    with ser:
        try:
            while True:
                raw = ser.readline()
                if not raw:
                    continue
                line = raw.decode("ascii", errors="ignore").strip()
                if not line:
                    continue
                lines_seen += 1
                tag, body = line[0], line[1:]
                ts = time.time()
                try:
                    if tag == "S":
                        bin_idx, mag2 = decode_spectrum(body)
                        if spectrum_prev_bin is None or bin_idx < spectrum_prev_bin:
                            spectrum_frame += 1
                        spectrum_prev_bin = bin_idx
                        spectrum_w.writerow([f"{ts:.6f}", spectrum_frame, bin_idx, mag2])
                    elif tag == "A":
                        addr, sample = decode_adc(body)
                        if adc_prev_addr is None or addr < adc_prev_addr:
                            adc_frame += 1
                        adc_prev_addr = addr
                        adc_w.writerow([f"{ts:.6f}", adc_frame, addr, sample])
                    elif tag == "P":
                        peak_bin, freq_hz, speed_kmh = decode_peak(body)
                        latest_peak = (peak_bin, freq_hz, speed_kmh)
                        peak_w.writerow([f"{ts:.6f}", peak_bin, f"{freq_hz:.4f}", f"{speed_kmh:.4f}"])
                        peak_f.flush()  # low volume (one line/cycle) - flush so a tail -f stays live
                    else:
                        continue
                except ValueError:
                    continue

                lines_parsed += 1
                now = time.monotonic()
                if now - last_report > 2:
                    peak_str = (f"bin={latest_peak[0]} freq={latest_peak[1]:.1f}Hz speed={latest_peak[2]:.1f}km/h"
                                if latest_peak else "no peak line yet")
                    print(f"  {lines_seen} lines received, {lines_parsed} parsed OK, "
                          f"spectrum frame {spectrum_frame}, adc frame {adc_frame}, latest peak: {peak_str}")
                    last_report = now
        except KeyboardInterrupt:
            pass
        finally:
            spectrum_f.close()
            adc_f.close()
            peak_f.close()
            print(f"\nWrote {spectrum_path}, {adc_path} and {peak_path}.")


if __name__ == "__main__":
    main()
