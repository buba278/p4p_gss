
# live_spectrum.py
"""
Live spectrum plot from the FPGA's UART telemetry link.

Expects one line per bin, straight off power_stage as power_valid pulses:
    "<bin><exp><mantissa><checksum>\n"   (3 hex digit bin index, 1 hex digit
                                          exponent, 4 hex digit mantissa,
                                          1 hex digit checksum; matches
                                          spectrum_uart_tx.sv)
The bin index is sent explicitly rather than inferred by counting lines: on
a link with no flow control, sustained line loss is common enough that a
count-based scheme has one dropped line shift every bin after it for the
rest of that sweep. With the bin field, a dropped/corrupted line only
leaves that one bin stale until the next sweep updates it — nothing else is
affected, so buffer[bin] is written directly.

mag2 is reconstructed from the exponent/mantissa hex-float encoding (see
spectrum_uart_tx.sv's header for the exact formula). checksum is the XOR of
the other 7 nibbles — this link has no other error detection, and a single
corrupted byte in the exponent field can inflate mag2 by ~1e9x, so a line
whose checksum doesn't match is dropped rather than plotted as a false
spike. The plot buffer is naturally overwritten sweep by sweep, giving a
live-scope persistence effect; redraws on a fixed timer, independent of
sweep boundaries.
"""

import argparse
import sys
import threading
import time

import matplotlib.animation as animation
import matplotlib.pyplot as plt
import numpy as np
import serial

FFT_N = 4096            # must match radar_top.sv
N_BINS = FFT_N // 2 + 1  # 0 (DC) .. FFT_N/2 (Nyquist) inclusive
BIN_DIGITS = 3           # must match BIN_DIGITS in spectrum_uart_tx.sv (BIN_WIDTH/4)
MANTISSA_DIGITS = 4      # must match MANTISSA_DIGITS in spectrum_uart_tx.sv


def decode_line(line):
    """'<3 bin digits><1 exp digit><4 mantissa digits><1 checksum digit>'
    -> (bin, magnitude)."""
    expected_len = BIN_DIGITS + 1 + MANTISSA_DIGITS + 1
    if len(line) != expected_len:
        raise ValueError(f"expected {expected_len} hex chars, got {line!r}")
    nibbles = [int(c, 16) for c in line]  # raises ValueError on any non-hex char too
    checksum = 0
    for n in nibbles[:-1]:
        checksum ^= n
    if checksum != nibbles[-1]:
        raise ValueError(f"checksum mismatch in {line!r}")
    bin_idx = int(line[:BIN_DIGITS], 16)
    if bin_idx >= N_BINS:
        raise ValueError(f"bin {bin_idx} out of range in {line!r}")
    exp = nibbles[BIN_DIGITS]
    mantissa = int(line[BIN_DIGITS + 1:BIN_DIGITS + 1 + MANTISSA_DIGITS], 16)
    if exp >= MANTISSA_DIGITS - 1:
        mag2 = mantissa << ((exp - (MANTISSA_DIGITS - 1)) * 4)
    else:
        mag2 = mantissa
    return bin_idx, mag2


def reader_thread(port, baud, buffer, lock, stop_event):
    try:
        ser = serial.Serial(port, baud, timeout=1)
    except serial.SerialException as exc:
        print(f"ERROR: could not open {port} at {baud} baud: {exc}", file=sys.stderr)
        stop_event.set()
        return

    print(f"Connected to {port} at {baud} baud, waiting for data...")
    lines_seen = 0
    lines_parsed = 0
    last_report = time.monotonic()

    with ser:
        while not stop_event.is_set():
            raw = ser.readline()
            if not raw:
                continue  # timeout with no bytes at all
            line = raw.decode("ascii", errors="ignore").strip()
            if not line:
                continue
            lines_seen += 1
            try:
                bin_idx, mag2 = decode_line(line)
            except ValueError:
                continue

            lines_parsed += 1
            with lock:
                buffer[bin_idx] = mag2

            now = time.monotonic()
            if now - last_report > 2:
                print(f"  {lines_seen} lines received, {lines_parsed} parsed OK, "
                      f"last bin: {bin_idx} (last raw line: {line!r})")
                last_report = now


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="Serial port, e.g. /dev/ttyUSB0 or COM3")
    parser.add_argument("--baud", type=int, default=115200)  # must match BAUD_RATE in radar_top.sv
    parser.add_argument("--refresh-ms", type=int, default=100)
    args = parser.parse_args()

    buffer = np.ones(N_BINS)  # 1, not 0, so log scale starts sane
    lock = threading.Lock()
    stop_event = threading.Event()

    thread = threading.Thread(
        target=reader_thread, args=(args.port, args.baud, buffer, lock, stop_event), daemon=True
    )
    thread.start()

    fig, ax = plt.subplots()
    (line,) = ax.plot(np.arange(N_BINS), buffer)
    ax.set_yscale("log")
    ax.set_xlabel("power_bin")
    ax.set_ylabel("power_mag2")
    ax.set_xlim(0, N_BINS - 1)

    def update(_frame):
        with lock:
            line.set_ydata(buffer)
        ax.relim()
        ax.autoscale_view(scalex=False)
        return (line,)

    ani = animation.FuncAnimation(
        fig, update, interval=args.refresh_ms, blit=False, cache_frame_data=False
    )
    try:
        plt.show()
    finally:
        stop_event.set()


if __name__ == "__main__":
    main()
