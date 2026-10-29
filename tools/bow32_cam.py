#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bow32 camera tool - talks to sw/apps/camera on UART0.

Examples:
  bow32_cam.py -p /dev/ttyUSB0 cmd "mode 720p" cam "ae on" "awb on"
  bow32_cam.py -p /dev/ttyUSB0 snap -o frame.png          # whole frame, scaled to fit
  bow32_cam.py -p /dev/ttyUSB0 snap -o crop.png --cap "cap 800 450 320 180 0"
  bow32_cam.py -p /dev/ttyUSB0 --fast 921600 view         # live preview (tkinter)

`snap` captures with the ISP (`cap`, default: the whole frame with the box
filter that fits the 32K word buffer) and transfers the image with `dump`:
  IMG <w> <h> rgb|yuv <bytes> <crc32>\\r\\n  <raw bytes, 3 per pixel>  \\r\\nEND
YUV images (fmt yuv, BT.709 full range) are converted back to RGB for PNG.

--fast switches the console to a higher baud rate first (`baud` command);
the board stays at that rate until it is reset.

Only the Python standard library and pyserial are needed (PNG is written with
zlib). docs/camera_kv260.md describes the whole set-up.
"""

import argparse
import re
import struct
import sys
import time
import zlib

try:
    import serial
except ImportError:  # pragma: no cover
    serial = None

PROMPT = b"> "
IMG_RE = re.compile(rb"IMG (\d+) (\d+) (rgb|yuv) (\d+) ([0-9a-fA-F]{8})")


class CameraError(Exception):
    pass


# ------------------------------------------------------------------ images
def yuv_to_rgb(data):
    """BT.709 full range YCbCr (bytes Y U V ...) -> RGB bytes."""
    out = bytearray(len(data))
    for i in range(0, len(data), 3):
        y, u, v = data[i], data[i + 1] - 128, data[i + 2] - 128
        rgb = (y + 1.5748 * v, y - 0.1873 * u - 0.4681 * v, y + 1.8556 * u)
        out[i:i + 3] = bytes(min(255, max(0, int(round(c)))) for c in rgb)
    return bytes(out)


def png_bytes(width, height, rgb):
    """8 bit RGB PNG of `rgb` (3 * width * height bytes, row by row)."""
    if len(rgb) != 3 * width * height:
        raise ValueError("pixel data does not match the size")

    def chunk(kind, payload):
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    stride = 3 * width
    raw = b"".join(b"\x00" + rgb[y * stride:(y + 1) * stride] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 9)) +
            chunk(b"IEND", b""))


def ppm_bytes(width, height, rgb):
    return b"P6 %d %d 255\n" % (width, height) + rgb


class Image:
    def __init__(self, width, height, fmt, data):
        self.width, self.height, self.fmt, self.data = width, height, fmt, data

    def rgb(self):
        return yuv_to_rgb(self.data) if self.fmt == "yuv" else self.data

    def save(self, path):
        data = self.rgb()
        if path.lower().endswith(".ppm"):
            blob = ppm_bytes(self.width, self.height, data)
        else:
            blob = png_bytes(self.width, self.height, data)
        with open(path, "wb") as f:
            f.write(blob)


# ------------------------------------------------------------------- shell
class Camera:
    def __init__(self, ser, verbose=False):
        self.ser = ser
        self.verbose = verbose
        self.buf = bytearray()

    def _fill(self, deadline):
        if time.monotonic() > deadline:
            raise CameraError("timeout, received: %r" % bytes(self.buf[-200:]))
        data = self.ser.read(max(1, getattr(self.ser, "in_waiting", 0) or 1))
        self.buf += data

    def _read_until(self, token, timeout):
        deadline = time.monotonic() + timeout
        while True:
            i = self.buf.find(token)
            if i >= 0:
                out = bytes(self.buf[:i + len(token)])
                del self.buf[:i + len(token)]
                return out
            self._fill(deadline)

    def _read_exact(self, n, timeout):
        deadline = time.monotonic() + timeout
        while len(self.buf) < n:
            self._fill(deadline)
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def sync(self, timeout=2.0):
        """Get a fresh prompt (also checks that the camera app is running)."""
        self.ser.reset_input_buffer()
        self.buf.clear()
        self.ser.write(b"\r")
        self._read_until(PROMPT, timeout)

    def command(self, line, timeout=5.0):
        """Run one shell command, return its output; CameraError on 'error'."""
        self.ser.write(line.encode() + b"\r")
        text = self._read_until(PROMPT, timeout).decode(errors="replace")
        lines = text.replace("\r", "").split("\n")
        if lines and lines[0].endswith(line):   # echo
            lines = lines[1:]
        body = "\n".join(lines[:-2]) if len(lines) >= 2 else ""
        status = lines[-2].strip() if len(lines) >= 2 else ""
        if self.verbose:
            print(body)
        if status != "ok":
            raise CameraError(f"'{line}' failed: {body.strip() or status}")
        return body

    def fast(self, baud):
        self.ser.write(b"baud %d\r" % baud)
        self._read_until(b"switching", 2.0)
        self._read_until(b"\n", 2.0)
        time.sleep(0.01)
        self.ser.baudrate = baud
        time.sleep(0.05)     # the firmware waits 100 ms before it answers
        self.sync()

    def snap(self, cap=None, timeout=60.0):
        """Capture (command `cap ...`, default whole frame) and transfer."""
        self.command(cap or "cap")
        self.ser.write(b"dump\r")
        self._read_until(b"IMG ", timeout)
        header = b"IMG " + self._read_until(b"\n", 5.0)
        m = IMG_RE.match(header)
        if not m:
            raise CameraError("bad image header %r" % header)
        w, h, n = int(m.group(1)), int(m.group(2)), int(m.group(4))
        fmt, crc = m.group(3).decode(), int(m.group(5), 16)
        if n != 3 * w * h:
            raise CameraError("image size mismatch in %r" % header)
        data = self._read_exact(n, timeout)
        if zlib.crc32(data) != crc:
            raise CameraError("image CRC mismatch (try a lower baud rate)")
        self._read_until(PROMPT, 5.0)
        return Image(w, h, fmt, data)


# --------------------------------------------------------------------- CLI
def cmd_view(cam, args):  # pragma: no cover - needs a display
    import tkinter as tk
    root = tk.Tk()
    root.title("Bow32 camera")
    label = tk.Label(root)
    label.pack()
    state = {"n": 0, "t0": time.monotonic()}

    def update():
        img = cam.snap(args.cap)
        photo = tk.PhotoImage(data=ppm_bytes(img.width, img.height, img.rgb()), format="PPM")
        if args.zoom > 1:
            photo = photo.zoom(args.zoom)
        label.configure(image=photo)
        label.image = photo
        state["n"] += 1
        fps = state["n"] / (time.monotonic() - state["t0"])
        root.title(f"Bow32 camera {img.width}x{img.height} {img.fmt}  {fps:.2f} fps")
        root.after(1, update)

    root.after(1, update)
    root.mainloop()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("-p", "--port", required=True, help="serial port, e.g. /dev/ttyUSB0 or COM5")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="current baud rate (115200)")
    ap.add_argument("--fast", type=int, metavar="BAUD", help="switch to this baud rate first")
    ap.add_argument("-v", "--verbose", action="store_true", help="print the command output")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("cmd", help="run shell commands")
    p.add_argument("commands", nargs="+")
    p = sub.add_parser("snap", help="capture an image and save it (PNG or PPM)")
    p.add_argument("-o", "--output", default="bow32_snap.png")
    p.add_argument("--cap", help="capture command, e.g. 'cap 0 0 320 180 2' (default 'cap')")
    p.add_argument("-n", "--count", type=int, default=1, help="number of images (name_N.png)")
    p = sub.add_parser("view", help="live preview window (needs tkinter)")
    p.add_argument("--cap", help="capture command (default 'cap')")
    p.add_argument("--zoom", type=int, default=2)
    args = ap.parse_args()

    if serial is None:
        sys.exit("error: pyserial is required (pip install -r requirements.txt)")
    cam = Camera(serial.Serial(args.port, args.baud, timeout=0.1), verbose=True)
    try:
        cam.sync()
        if args.fast:
            cam.fast(args.fast)
        if args.cmd == "cmd":
            for c in args.commands:
                print(f"> {c}")
                cam.command(c, timeout=30.0)
        elif args.cmd == "snap":
            for i in range(args.count):
                t0 = time.monotonic()
                img = cam.snap(args.cap)
                out = args.output
                if args.count > 1:
                    stem, dot, ext = out.rpartition(".")
                    out = f"{stem}_{i}.{ext}" if dot else f"{out}_{i}"
                img.save(out)
                print(f"{out}: {img.width}x{img.height} {img.fmt} "
                      f"({time.monotonic() - t0:.1f} s)")
        else:
            cmd_view(cam, args)
    except CameraError as e:
        sys.exit(f"error: {e}")


if __name__ == "__main__":
    main()
