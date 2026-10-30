# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/bow32_cam.py against a byte level model of the shell of
sw/apps/camera. Run: python3 -m unittest discover tools/tests
"""

import struct
import sys
import tempfile
import time
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bow32_cam  # noqa: E402


def png_decode(blob):
    """Minimal decoder for the PNGs written by bow32_cam (RGB, filter 0)."""
    assert blob[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(blob):
        (n,) = struct.unpack(">I", blob[pos:pos + 4])
        kind, payload = blob[pos + 4:pos + 8], blob[pos + 8:pos + 8 + n]
        (crc,) = struct.unpack(">I", blob[pos + 8 + n:pos + 12 + n])
        assert crc == zlib.crc32(kind + payload)
        if kind == b"IHDR":
            w, h = struct.unpack(">II", payload[:8])
            assert payload[8:] == bytes([8, 2, 0, 0, 0])
        elif kind == b"IDAT":
            idat += payload
        pos += 12 + n
    raw = zlib.decompress(idat)
    rows = [raw[y * (3 * w + 1):(y + 1) * (3 * w + 1)] for y in range(h)]
    assert all(r[0] == 0 for r in rows)
    return w, h, b"".join(r[1:] for r in rows)


class FakeCameraSerial:
    """Echoes like the firmware shell and answers cap / dump / baud."""

    def __init__(self, width=8, height=4, fmt="rgb", corrupt=False):
        self.baudrate = 115200
        self.rx = bytearray()
        self.tx = bytearray()
        self.w, self.h, self.fmt, self.corrupt = width, height, fmt, corrupt
        self.pixels = bytes((7 * i) & 0xFF for i in range(3 * width * height))
        self.busy_until = 0.0     # `baud`: firmware in bow_delay_ms(100)

    def _tick(self):
        if self.busy_until and time.monotonic() >= self.busy_until:
            self.busy_until = 0.0
            self._say("ok\n> ")
            self._process()        # input received during the delay

    @property
    def in_waiting(self):
        self._tick()
        return len(self.tx)

    def reset_input_buffer(self):
        self._tick()
        self.tx.clear()

    def read(self, n):
        self._tick()
        out, self.tx = bytes(self.tx[:n]), self.tx[n:]
        return out

    def write(self, data):
        self._tick()
        self.rx += data
        self._process()

    def _process(self):
        while not self.busy_until and b"\r" in self.rx:
            line, _, rest = bytes(self.rx).partition(b"\r")
            self.rx = bytearray(rest)
            self._line(line.decode())

    def _say(self, text):
        self.tx += text.replace("\n", "\r\n").encode()

    def _line(self, line):
        self._say(line + "\n")             # echo + newline
        if line == "":
            pass
        elif line.startswith("cap"):
            self._say(f"captured {self.w}x{self.h} (scale 0)\nok\n")
        elif line == "dump":
            data = self.pixels
            crc = zlib.crc32(data)
            if self.corrupt:
                data = bytes([data[0] ^ 1]) + data[1:]
            self._say(f"IMG {self.w} {self.h} {self.fmt} {len(data)} {crc:08x}\n")
            self.tx += data
            self._say("\nEND\nok\n")
        elif line.startswith("baud "):
            self._say(f"ok, switching to {line[5:]} baud\n")
            self.busy_until = time.monotonic() + 0.1
            return                         # "ok" and the prompt come after the delay
        elif line == "boom":
            self._say("unknown command, h for help\nerror\n")
        else:
            self._say("ae: locked exp=1 gain=0 mean=180\nok\n")
        self._say("> ")


class TestImages(unittest.TestCase):
    def test_png_roundtrip(self):
        rgb = bytes(range(3 * 5 * 3))
        w, h, data = png_decode(bow32_cam.png_bytes(5, 3, rgb))
        self.assertEqual((w, h, data), (5, 3, rgb))

    def test_yuv_to_rgb(self):
        out = bow32_cam.yuv_to_rgb(bytes([128, 128, 128, 255, 128, 128, 0, 128, 128, 76, 85, 255]))
        self.assertEqual(out[0:3], bytes([128, 128, 128]))
        self.assertEqual(out[3:6], bytes([255, 255, 255]))
        self.assertEqual(out[6:9], bytes([0, 0, 0]))
        r, g, b = out[9:12]   # strong red
        self.assertGreater(r, 200)
        self.assertLess(g, 60)
        self.assertLess(b, 60)


class TestShell(unittest.TestCase):
    def test_command_output_and_error(self):
        cam = bow32_cam.Camera(FakeCameraSerial())
        cam.sync()
        self.assertIn("ae: locked", cam.command("ae on"))
        with self.assertRaises(bow32_cam.CameraError):
            cam.command("boom")

    def test_snap_rgb_png(self):
        ser = FakeCameraSerial(width=8, height=4)
        cam = bow32_cam.Camera(ser)
        cam.sync()
        img = cam.snap()
        self.assertEqual((img.width, img.height, img.fmt), (8, 4, "rgb"))
        self.assertEqual(img.data, ser.pixels)
        with tempfile.TemporaryDirectory() as d:
            path = str(Path(d) / "x.png")
            img.save(path)
            self.assertEqual(png_decode(Path(path).read_bytes()), (8, 4, ser.pixels))
        # the shell is usable afterwards
        self.assertIn("captured", cam.command("cap 0 0 8 4 0"))

    def test_snap_crc_error(self):
        cam = bow32_cam.Camera(FakeCameraSerial(corrupt=True))
        cam.sync()
        with self.assertRaises(bow32_cam.CameraError):
            cam.snap()

    def test_fast(self):
        ser = FakeCameraSerial()
        cam = bow32_cam.Camera(ser)
        cam.sync()
        cam.fast(921600)
        self.assertEqual(ser.baudrate, 921600)
        # the shell is usable afterwards
        self.assertIn("ae: locked", cam.command("ae on"))


if __name__ == "__main__":
    unittest.main()
