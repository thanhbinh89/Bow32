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


# First lines of `info` of sw/apps/camera with each sensor (the csi2rx status
# that follows is left out)
INFO_IMX219 = ("ISP    id 49535001 ctrl 1 status 02 frames 12 size 1920x1080 input 1920x1080 "
               "modules 1f\n"
               "mode   1920x1080, frame length 1763 lines = 30 fps\n"
               "sensor IMX219  exp 1000 gain 0  tp 0  flip 0/0\n")
INFO_IMX274 = ("ISP    id 49535001 ctrl 1 status 02 frames 12 size 1280x720 input 1280x720 "
               "modules 1f\n"
               "mode   1280x720, HMAX 300, VMAX 4000 = 60 fps\n"
               "sensor IMX274  exp 1000 gain 0  tp 0  flip 0/0\n")


UART_FIFO = 16   # UART0 receive FIFO (hw/ip/uart/rtl/bow_uart.sv FifoDepth)
LINE_MAX = 47    # sw/apps/camera: line[48]


class FakeCameraSerial:
    """Byte level model of the shell of sw/apps/camera: the 16 byte receive
    FIFO, the echo of every character the app reads, the line run at CR;
    answers cap / dump / baud / info. busy: the app reads the FIFO only when
    the host reads (it is busy, e.g. on I2C, while the host writes), so the
    bytes of one write beyond 16 are lost (`lost`), as on the board."""

    def __init__(self, width=8, height=4, fmt="rgb", corrupt=False, info=INFO_IMX219, busy=False):
        self.baudrate = 115200
        self.fifo = bytearray()   # receive FIFO
        self.line = bytearray()   # line buffer of the app
        self.tx = bytearray()
        self.w, self.h, self.fmt, self.corrupt = width, height, fmt, corrupt
        self.info = info
        self.pixels = bytes((7 * i) & 0xFF for i in range(3 * width * height))
        self.busy = busy
        self.busy_until = 0.0     # `baud`: firmware in bow_delay_ms(100)
        self.commands = []
        self.lost = 0
        self.writes = []          # bytes per write() of the host

    def _tick(self):
        if self.busy_until and time.monotonic() >= self.busy_until:
            self.busy_until = 0.0
            self._say("ok\n> ")
        self._drain()              # input received during the delay / while busy

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
        self.writes.append(len(data))
        for b in data:
            if len(self.fifo) < UART_FIFO:
                self.fifo.append(b)
            else:
                self.lost += 1
        if not self.busy:
            self._drain()

    def _drain(self):
        """Main loop of the app: read the FIFO, echo, run the line at CR."""
        while not self.busy_until and self.fifo:
            b = self.fifo.pop(0)
            if b == 0x0D:
                line, self.line = self.line.decode(), bytearray()
                self._say("\n")
                self._line(line)
            elif 0x20 <= b < 0x7F and len(self.line) < LINE_MAX:
                self.line.append(b)
                self.tx.append(b)  # echo

    def _say(self, text):
        self.tx += text.replace("\n", "\r\n").encode()

    def _line(self, line):
        self.commands.append(line)
        if line == "":
            pass
        elif line == "info":
            self._say(self.info + "ok\n")
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

    def test_command_paced_by_echo(self):
        # one character per write, each after the echo of the one before, then CR
        ser = FakeCameraSerial()
        cam = bow32_cam.Camera(ser)
        cam.sync()
        ser.writes.clear()
        self.assertIn("ae: locked", cam.command("ae on"))
        self.assertEqual(ser.writes, [1] * len("ae on") + [1])
        self.assertEqual(ser.commands[-1], "ae on")

    def test_long_command_busy_app(self):
        # "mode 1920 1080 30" + CR = 18 bytes written at once while the app is
        # busy (I2C): the receive FIFO keeps 16, the CR is lost, the command
        # never runs (seen in the video274 simulation) ...
        ser = FakeCameraSerial(busy=True)
        ser.write(b"mode 1920 1080 30\r")
        ser.read(100)
        self.assertEqual(ser.lost, 2)
        self.assertNotIn("mode 1920 1080 30", ser.commands)
        # ... paced by its echo, the line arrives whole
        ser = FakeCameraSerial(busy=True)
        cam = bow32_cam.Camera(ser)
        cam.sync()
        cam.command("mode 1920 1080 30")
        self.assertEqual((ser.commands[-1], ser.lost), ("mode 1920 1080 30", 0))
        # so do the commands of snap (cap, dump) and of --fast (baud)
        img = cam.snap("cap 0 0 8 4 0")
        self.assertEqual(img.data, ser.pixels)
        cam.fast(921600)
        self.assertIn("ae: locked", cam.command("ae on"))
        self.assertEqual(ser.lost, 0)

    def test_no_echo(self):
        # a line longer than the app's line buffer: the echo stops, error
        # instead of a command cut short
        cam = bow32_cam.Camera(FakeCameraSerial())
        cam.sync()
        cam.ECHO_TIMEOUT = 0.2
        with self.assertRaises(bow32_cam.CameraError):
            cam.command("x" * (LINE_MAX + 1))

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

    def test_frame_size_both_sensors(self):
        for info, size in ((INFO_IMX219, (1920, 1080)), (INFO_IMX274, (1280, 720))):
            cam = bow32_cam.Camera(FakeCameraSerial(info=info))
            cam.sync()
            self.assertEqual(cam.frame_size(), size)

    def test_frame_size_missing(self):
        cam = bow32_cam.Camera(FakeCameraSerial(info="ISP    id 0\n"))
        cam.sync()
        with self.assertRaises(bow32_cam.CameraError):
            cam.frame_size()

    def test_snap_centre(self):
        # IMX274 720p: 1:1 crop of 240x135 in the middle, as `snap --center 240 135`
        ser = FakeCameraSerial(info=INFO_IMX274)
        cam = bow32_cam.Camera(ser)
        cam.sync()
        cap = bow32_cam.centre_cap(*cam.frame_size(), 240, 135)
        self.assertEqual(cap, "cap 520 292 240 135 0")
        cam.snap(cap)
        self.assertIn("cap 520 292 240 135 0", ser.commands)


class TestCentreCap(unittest.TestCase):
    def test_values(self):
        cc = bow32_cam.centre_cap
        self.assertEqual(cc(1920, 1080, 160, 120), "cap 880 480 160 120 0")
        self.assertEqual(cc(1920, 1080, 240, 135, 3), "cap 0 0 240 135 3")
        self.assertEqual(cc(1280, 720, 160, 90, 3), "cap 0 0 160 90 3")
        # IMX274 uncropped mode 3: 241x136 at scale 3 is 4 words too many, 240x136 fits;
        # the origin is rounded down to even
        self.assertEqual(cc(1932, 1094, 240, 136, 3), "cap 6 2 240 136 3")
        with self.assertRaises(bow32_cam.CameraError):
            cc(1932, 1094, 241, 136, 3)
        self.assertEqual(cc(64, 48, 32, 24, 1), "cap 0 0 32 24 1")

    def test_limits(self):
        cc = bow32_cam.centre_cap
        with self.assertRaises(bow32_cam.CameraError):
            cc(1920, 1080, 1921, 10)          # wider than the frame
        with self.assertRaises(bow32_cam.CameraError):
            cc(1920, 1080, 240, 136, 3)       # 136 x 8 > 1080
        with self.assertRaises(bow32_cam.CameraError):
            cc(1920, 1080, 256, 129)          # 33024 > 32768 pixels
        with self.assertRaises(bow32_cam.CameraError):
            cc(3840, 2160, 1040, 20, 1)       # box filter: width <= 1024
        with self.assertRaises(bow32_cam.CameraError):
            cc(1920, 1080, 10, 10, 4)         # scale 0..3
        with self.assertRaises(bow32_cam.CameraError):
            cc(1920, 1080, 0, 10)


if __name__ == "__main__":
    unittest.main()
