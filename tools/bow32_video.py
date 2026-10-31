#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bow32 video tool - records H.264 video with sw/apps/video on UART0.

Examples:
  bow32_video.py -p /dev/ttyACM0 --fast 921600 rec -n 45 --skip 1 -o video.mp4
  bow32_video.py -p /dev/ttyACM0 rec --source tpg4 --mode 640 360 -n 60 -o tpg.mp4
  bow32_video.py -p /dev/ttyACM0 cmd "mode 1080p" cam stat
  bow32_video.py mp4 video.h264 -o video.mp4 --fps 15

`rec` starts the source (camera by default: `mode`, `cam`, then waits for
auto exposure / white balance), records n frames into the 1 MiB video RAM of
the board (`rec n skip kbytes`: a rate control aims at kbytes per frame,
default the size that fits), transfers the stream (`send`):
  H264 <bytes> <crc32> <frames> <w> <h> <fps_num> <fps_den>\\r\\n <bytes>  \\r\\nEND
checks the CRC and writes <output>.h264 (Annex B) and <output>.mp4.

--fast switches the console to a higher baud rate first (921600: about
90 KB/s, 1 MiB in 12 s); the board stays at that rate until it is reset.

Needs pyserial; the MP4 is written by tools/h264/mp4.py (no ffmpeg needed).
"""

import argparse
import re
import sys
import time
import zlib
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "h264"))
from bow32_cam import Camera, CameraError, serial  # noqa: E402
import mp4  # noqa: E402

H264_RE = re.compile(rb"H264 (\d+) ([0-9a-fA-F]{8}) (\d+) (\d+) (\d+) (\d+) (\d+)")


class Recording:
    def __init__(self, data, frames, width, height, fps_num, fps_den):
        self.data, self.frames = data, frames
        self.width, self.height = width, height
        self.fps = Fraction(fps_num, fps_den)

    def save(self, output):
        """Write <stem>.h264 and <stem>.mp4, return both paths."""
        out = Path(output)
        stem = out.with_suffix("") if out.suffix.lower() in (".mp4", ".h264", ".264") else out
        h264 = stem.with_suffix(".h264")
        mp4_path = stem.with_suffix(".mp4")
        h264.write_bytes(self.data)
        mp4.write_mp4(str(mp4_path), self.data, self.fps.numerator, self.fps.denominator)
        return h264, mp4_path


class Video(Camera):
    def sync(self, timeout=2.0):
        """Fresh prompt. USB serial adapters deliver late bytes (a boot banner,
        the end of an earlier command): after the first prompt drain the line,
        then make a second round trip."""
        super().sync(timeout)
        end = time.monotonic() + 0.2
        while time.monotonic() < end:
            self.ser.read(getattr(self.ser, "in_waiting", 0) or 1)
        super().sync(timeout)

    def record(self, frames, skip=0, kbytes=0, timeout=None, progress=True):
        """`rec` on the board, prints its progress lines, returns the summary."""
        line = f"rec {frames} {skip} {kbytes}"
        self.ser.write(line.encode() + b"\r")
        deadline = time.monotonic() + (timeout or 30.0 + frames * 0.5 * (skip + 1))
        text = b""
        while True:
            chunk = self._read_until(b"\n", max(1.0, deadline - time.monotonic()))
            text += chunk
            s = chunk.decode(errors="replace").strip()
            if progress and (s.startswith("frame ") or s.startswith("rec:") or
                             s.startswith("warning") or s.startswith("error")):
                print(f"  {s}")
            if s in ("ok", "error"):
                break
        self._read_until(b"> ", 2.0)
        if s != "ok":
            raise CameraError(f"'{line}' failed: {text.decode(errors='replace').strip()}")
        return text.decode(errors="replace")

    def receive(self, timeout=120.0, progress=True):
        """`send`: the recorded stream."""
        self.ser.write(b"send\r")
        self._read_until(b"H264 ", 10.0)
        header = b"H264 " + self._read_until(b"\n", 5.0)
        m = H264_RE.match(header)
        if not m:
            raise CameraError(f"bad stream header {header!r}")
        n, crc = int(m.group(1)), int(m.group(2), 16)
        frames, w, h, num, den = (int(m.group(i)) for i in range(3, 8))
        t0 = time.monotonic()
        data = bytearray()
        deadline = t0 + timeout
        while len(data) < n:
            want = min(n - len(data), 65536)
            data += self._read_exact(want, max(1.0, deadline - time.monotonic()))
            if progress:
                rate = len(data) / max(1e-3, time.monotonic() - t0)
                print(f"\r  {len(data)}/{n} bytes, {rate / 1024:.1f} KiB/s", end="", flush=True)
        if progress:
            print()
        if zlib.crc32(data) != crc:
            raise CameraError("stream CRC mismatch (try a lower baud rate)")
        self._read_until(b"> ", 5.0)
        return Recording(bytes(data), frames, w, h, num, den)


def wait_3a(cam, seconds):
    """Let auto exposure / white balance settle (the board prints 'locked')."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        time.sleep(0.2)
        cam.ser.read(getattr(cam.ser, "in_waiting", 0) or 1)
    cam.sync()


def cmd_rec(cam, args):
    if args.source != "none":
        if args.mode:
            cam.command("mode " + " ".join(args.mode), timeout=30.0)
        if args.source == "cam":
            cam.command("cam", timeout=60.0)
        else:
            cam.command("tpg " + args.source[3:] if len(args.source) > 3 else "tpg", timeout=30.0)
        cam.command("ae " + ("on" if args.ae else "off"))
        cam.command("awb " + ("on" if args.awb else "off"))
        if args.settle > 0:
            print(f"waiting {args.settle:.0f} s for exposure / white balance")
            wait_3a(cam, args.settle)
    cam.command(f"qp {args.qp}")
    cam.command("deblock " + ("off" if args.no_deblock else "on"))
    print(f"recording {args.frames} frames (skip {args.skip})")
    cam.record(args.frames, args.skip, args.kbytes)
    t0 = time.monotonic()
    rec = cam.receive()
    h264, mp4_path = rec.save(args.output)
    print(f"{mp4_path}: {rec.frames} frames {rec.width}x{rec.height} @ {float(rec.fps):.2f} fps, "
          f"{len(rec.data)} bytes ({time.monotonic() - t0:.1f} s transfer), also {h264}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("-p", "--port", help="serial port, e.g. /dev/ttyACM0")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="current baud rate (115200)")
    ap.add_argument("--fast", type=int, metavar="BAUD", help="switch to this baud rate first")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("cmd", help="run shell commands of the video app")
    p.add_argument("commands", nargs="+")
    p = sub.add_parser("rec", help="record a video and save it as .h264 + .mp4")
    p.add_argument("-n", "--frames", type=int, default=45)
    p.add_argument("--skip", type=int, default=1, help="input frames dropped between two coded")
    p.add_argument("--kbytes", type=int, default=0, help="target size per frame (0: what fits)")
    p.add_argument("--qp", type=int, default=30, help="first QP (10..51)")
    p.add_argument("--no-deblock", action="store_true", help="no deblocking filter in the decoder")
    p.add_argument("--source", default="cam",
                   help="cam (default), tpg<n> (ISP test pattern n, +4 moving) or none (keep)")
    p.add_argument("--mode", nargs="+", help="frame size: 1080p, 720p or W H [fps]")
    p.add_argument("--settle", type=float, default=4.0, help="seconds for AE / AWB (camera)")
    p.add_argument("--no-ae", dest="ae", action="store_false")
    p.add_argument("--no-awb", dest="awb", action="store_false")
    p.add_argument("-o", "--output", default="bow32_video.mp4")
    p = sub.add_parser("mp4", help="Annex B .h264 file -> .mp4 (no board needed)")
    p.add_argument("input")
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--fps", default="30")
    args = ap.parse_args()

    if args.cmd == "mp4":
        fps = Fraction(args.fps)
        size = mp4.write_mp4(args.output, Path(args.input).read_bytes(), fps.numerator,
                             fps.denominator)
        print(f"{args.output}: {size} bytes")
        return 0
    if not args.port:
        sys.exit("error: --port is required")
    if serial is None:
        sys.exit("error: pyserial is required (pip install -r requirements.txt)")
    cam = Video(serial.Serial(args.port, args.baud, timeout=0.1), verbose=True)
    try:
        cam.sync()
        if args.fast:
            cam.fast(args.fast)
        if args.cmd == "cmd":
            for c in args.commands:
                print(f"> {c}")
                cam.command(c, timeout=120.0)
        else:
            cmd_rec(cam, args)
    except CameraError as e:
        sys.exit(f"error: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
