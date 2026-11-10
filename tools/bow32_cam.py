#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bow32 camera tool - talks to sw/apps/camera on UART0.

Examples:
  bow32_cam.py -p /dev/ttyUSB0 cmd "mode 720p" cam "ae on" "awb on"
  bow32_cam.py -p /dev/ttyUSB0 snap -o frame.png          # whole frame, scaled to fit
  bow32_cam.py -p /dev/ttyUSB0 snap -o crop.png --cap "cap 800 450 320 180 0"
  bow32_cam.py -p /dev/ttyUSB0 snap -o crop.png --center 240 135   # 1:1 at the centre
  bow32_cam.py -p /dev/ttyUSB0 --fast 921600 view         # live preview (tkinter)

`snap` captures with the ISP (`cap`, default: the whole frame with the box
filter that fits the 32K word buffer) and transfers the image with `dump`:
  IMG <w> <h> rgb|yuv <bytes> <crc32>\\r\\n  <raw bytes, 3 per pixel>  \\r\\nEND
YUV images (fmt yuv, BT.709 full range) are converted back to RGB for PNG.
--center W H [--scale S] asks the board for its frame size (`info`) and
captures W x H pixels (box filter 2^S) in the middle of the frame, e.g. to
focus the lens; W x H must fit the buffer (32768 pixels, W <= 1024 when
S > 0).

The same protocol works with both sensors of the camera app: the IMX219
(Raspberry Pi camera v2) on the KV260 (docs/camera_kv260.md) and the
IMX274 (LI-IMX274MIPI-FMC) on the Huins MFP-VP1902 (docs/camera_huins.md).

--fast switches the console to a higher baud rate first (`baud` command);
the board stays at that rate until it is reset.

Commands go out one character at a time, each after the echo of the one
before (Camera.send_line): the UART0 receive FIFO of the board holds 16
bytes, and the app does not read it while it is busy (I2C at 100 kHz to the
IMX274, auto exposure), so a whole line sent at once can lose its end. The
other board tools (bow32_video, bow32_ddr, bow32_hyperram, bow32_mkv) send
their commands the same way.

Only the Python standard library and pyserial are needed (PNG is written with
zlib).
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
# `info`: "mode   1920x1080, frame length 1763 lines = 30 fps" (IMX219)
#         "mode   1280x720, HMAX 300, VMAX 4000 = 60 fps"     (IMX274)
MODE_RE = re.compile(r"^mode\s+(\d+)x(\d+)", re.MULTILINE)
CAP_WORDS = 32768      # ISP capture buffer (IspBufWords)
CAP_COLUMNS = 1024     # box filter columns: width limit when scale > 0


class CameraError(Exception):
    pass


def centre_cap(frame_w, frame_h, w, h, scale=0):
    """`cap` command for w x h output pixels (box filter 2^scale) in the
    middle of a frame_w x frame_h frame; even origin."""
    if not 0 <= scale <= 3:
        raise CameraError("scale must be 0..3")
    span_w, span_h = w << scale, h << scale
    if w <= 0 or h <= 0 or span_w > frame_w or span_h > frame_h:
        raise CameraError(f"{w}x{h} at scale {scale} does not fit the {frame_w}x{frame_h} frame")
    if w * h > CAP_WORDS or (scale and w > CAP_COLUMNS):
        raise CameraError(f"{w}x{h} does not fit the capture buffer ({CAP_WORDS} pixels, "
                          f"width <= {CAP_COLUMNS} when scaled)")
    x = ((frame_w - span_w) // 2) & ~1
    y = ((frame_h - span_h) // 2) & ~1
    return f"cap {x} {y} {w} {h} {scale}"


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
    # Characters sent per echo (send_line): 1 = one at a time. Any value up to
    # the 16 byte receive FIFO cannot overflow it, whatever the app is doing.
    ECHO_CHUNK = 1
    ECHO_TIMEOUT = 2.0  # s per echo

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

    def send_line(self, line, timeout=None):
        """Send a command line, then CR, paced by its echo: ECHO_CHUNK
        characters, then wait until the app echoes the last of them (it has
        read them all), ... The echo stays in the buffer for the reader of
        the answer. CameraError when an echo does not come (app not running,
        or a line longer than the app's line buffer: it echoes no more)."""
        data = line.encode()
        limit = self.ECHO_TIMEOUT if timeout is None else timeout
        pos = len(self.buf)
        for k in range(0, len(data), self.ECHO_CHUNK):
            chunk = data[k:k + self.ECHO_CHUNK]
            self.ser.write(chunk)
            deadline = time.monotonic() + limit
            while True:
                i = self.buf.find(chunk[-1:], pos)
                if i >= 0:
                    pos = i + 1
                    break
                if time.monotonic() > deadline:
                    raise CameraError(f"no echo of {data[:k + len(chunk)].decode()!r} of the "
                                      f"command {line!r} (app not running, or the line is "
                                      f"too long for it)")
                self.buf += self.ser.read(max(1, getattr(self.ser, "in_waiting", 0) or 1))
        self.ser.write(b"\r")

    def command(self, line, timeout=5.0):
        """Run one shell command, return its output; CameraError on 'error'."""
        self.send_line(line)
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
        self.send_line("baud %d" % baud)
        self._read_until(b"switching", 2.0)
        self._read_until(b"\n", 2.0)
        time.sleep(0.01)
        self.ser.baudrate = baud
        # The firmware waits 100 ms, then ends the command with "ok" and a
        # prompt at the new rate. Wait for them: a "\r" sent earlier is only
        # read after them and its prompt would be taken as the answer of the
        # next command.
        self._read_until(PROMPT, 2.0)
        self.sync()

    def frame_size(self, timeout=10.0):
        """Frame size of the current mode (`info`, not printed)."""
        verbose, self.verbose = self.verbose, False
        try:
            text = self.command("info", timeout)
        finally:
            self.verbose = verbose
        m = MODE_RE.search(text)
        if not m:
            raise CameraError("no frame size in the answer of 'info'")
        return int(m.group(1)), int(m.group(2))

    def snap(self, cap=None, timeout=60.0):
        """Capture (command `cap ...`, default whole frame) and transfer."""
        self.command(cap or "cap")
        self.send_line("dump")
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
    p.add_argument("--center", type=int, nargs=2, metavar=("W", "H"),
                   help="capture W x H pixels in the middle of the frame (instead of --cap)")
    p.add_argument("--scale", type=int, default=0, help="box filter 2^SCALE for --center (0)")
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
            if args.center:
                args.cap = centre_cap(*cam.frame_size(), *args.center, args.scale)
                print(args.cap)
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
