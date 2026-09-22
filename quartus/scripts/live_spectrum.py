
# live_spectrum.py
"""
Live spectrum plot from the FPGA's UART telemetry link.

telemetry_uart_tx.sv (replaced spectrum_uart_tx.sv) also drains a raw-ADC
snapshot on the same link, tagged 'A' — this viewer only cares about the
spectrum, so 'A' lines are just skipped. See log_telemetry.py if you want
both streams logged to CSV instead of a live plot.

Also overlays the pipeline's actual peak/freq/speed output (tag 'P', one
line per telemetry cycle) as a vertical line + text box on the plot, so you
can see at a glance whether the winning bin lines up with what the
spectrum actually shows.

Expects one line per bin, tagged 'S':
    "S<bin><exp><mantissa><checksum>\n"   (3 hex digit bin index, 1 hex digit
                                           exponent, 4 hex digit mantissa,
                                           1 hex digit checksum; matches
                                           telemetry_uart_tx.sv)
and one peak/freq/speed line per cycle, tagged 'P':
    "P<peak_bin><freq_scaled><speed_scaled><checksum>\n" (see
                                           telemetry_uart_tx.sv header)
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
BIN_DIGITS = 3           # must match BIN_DIGITS in telemetry_uart_tx.sv (BIN_WIDTH/4)
MANTISSA_DIGITS = 4      # must match MANTISSA_DIGITS in telemetry_uart_tx.sv
FREQ_DIGITS = 5          # must match FREQ_WIDTH/4 in telemetry_uart_tx.sv
SPEED_DIGITS = 10        # must match SPEED_WIDTH/4 in telemetry_uart_tx.sv
FREQ_FRAC_BITS = 4       # must match bin_to_freq.sv's FREQ_FRAC_BITS
SPEED_FRAC_BITS = 16     # must match freq_to_speed.sv's K_FRAC_BITS


def decode_line(line):
    """'S<3 bin digits><1 exp digit><4 mantissa digits><1 checksum digit>'
    -> (bin, magnitude). Raises ValueError (including on 'A'/'P' lines,
    which this viewer isn't interested in) so the caller just skips them."""
    if not line or line[0] != "S":
        raise ValueError(f"not a spectrum line: {line!r}")
    line = line[1:]
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


def decode_peak(line):
    """'P<3 bin digits><5 freq digits><10 speed digits><1 checksum digit>'
    -> (peak_bin, freq_hz, speed_kmh). Raises ValueError on anything else,
    same convention as decode_line."""
    if not line or line[0] != "P":
        raise ValueError(f"not a peak line: {line!r}")
    line = line[1:]
    expected_len = BIN_DIGITS + FREQ_DIGITS + SPEED_DIGITS + 1
    if len(line) != expected_len:
        raise ValueError(f"expected {expected_len} hex chars, got {line!r}")
    nibbles = [int(c, 16) for c in line]
    checksum = 0
    for n in nibbles[:-1]:
        checksum ^= n
    if checksum != nibbles[-1]:
        raise ValueError(f"checksum mismatch in {line!r}")
    peak_bin = int(line[:BIN_DIGITS], 16)
    freq_scaled = int(line[BIN_DIGITS:BIN_DIGITS + FREQ_DIGITS], 16)
    speed_scaled = int(line[BIN_DIGITS + FREQ_DIGITS:BIN_DIGITS + FREQ_DIGITS + SPEED_DIGITS], 16)
    freq_hz = freq_scaled / (1 << FREQ_FRAC_BITS)
    speed_kmh = speed_scaled / (1 << SPEED_FRAC_BITS)
    return peak_bin, freq_hz, speed_kmh


def reader_thread(port, baud, buffer, peak_state, lock, stop_event):
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
            if line[0] == "P":
                try:
                    peak_bin, freq_hz, speed_kmh = decode_peak(line)
                except ValueError:
                    continue
                lines_parsed += 1
                with lock:
                    peak_state["bin"] = peak_bin
                    peak_state["freq_hz"] = freq_hz
                    peak_state["speed_kmh"] = speed_kmh
                continue

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
    peak_state = {"bin": None, "freq_hz": None, "speed_kmh": None}
    lock = threading.Lock()
    stop_event = threading.Event()

    thread = threading.Thread(
        target=reader_thread, args=(args.port, args.baud, buffer, peak_state, lock, stop_event), daemon=True
    )
    thread.start()

    fig, ax = plt.subplots()
    (line,) = ax.plot(np.arange(N_BINS), buffer)
    ax.set_yscale("log")
    ax.set_xlabel("power_bin")
    ax.set_ylabel("power_mag2")
    ax.set_xlim(0, N_BINS - 1)

    peak_vline = ax.axvline(0, color="red", linestyle="--", linewidth=1, alpha=0.7, visible=False)
    peak_text = ax.text(
        0.98, 0.97, "waiting for peak...", transform=ax.transAxes,
        ha="right", va="top", fontsize=10, color="red",
        bbox=dict(boxstyle="round", facecolor="white", alpha=0.8, edgecolor="red"),
    )

    def update(_frame):
        with lock:
            line.set_ydata(buffer)
            peak_bin   = peak_state["bin"]
            freq_hz    = peak_state["freq_hz"]
            speed_kmh  = peak_state["speed_kmh"]
        ax.relim()
        ax.autoscale_view(scalex=False)
        if peak_bin is not None:
            peak_vline.set_xdata([peak_bin, peak_bin])
            peak_vline.set_visible(True)
            peak_text.set_text(f"bin {peak_bin}\n{freq_hz:.1f} Hz\n{speed_kmh:.1f} km/h")
        return (line, peak_vline, peak_text)

    ani = animation.FuncAnimation(
        fig, update, interval=args.refresh_ms, blit=False, cache_frame_data=False
    )
    try:
        plt.show()
    finally:
        stop_event.set()


if __name__ == "__main__":
    main()
