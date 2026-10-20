# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/bow32_flash.py against a Python model of the boot ROM
UART loader (sw/bootrom/loader.c). Run: python3 -m unittest discover tools/tests
"""

import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bow32_flash  # noqa: E402

FLASH_BASE, FLASH_SIZE, PAGE = 0x08000000, 128 * 1024, 1024


class FakeLoaderSerial:
    """Byte level model of the boot ROM loader behind a serial port."""

    def __init__(self, *args, **kwargs):
        self.port, self.baudrate = "fake", 115200
        self.flash = bytearray(b"\xff" * FLASH_SIZE)
        self.rx = bytearray()      # host -> device
        self.tx = bytearray(b"\nBow32 boot ROM banner text\n")  # device -> host
        self.booted = False
        self.breaks = 0

    # pyserial API used by the tool
    def send_break(self, duration=0.25):
        self.breaks += 1

    def reset_input_buffer(self):
        self.tx.clear()

    def flush(self):
        pass

    def read(self, n):
        out, self.tx = bytes(self.tx[:n]), self.tx[n:]
        return out

    def write(self, data):
        self.rx += data
        self._process()

    # loader model
    def _respond(self, status, payload=b""):
        body = struct.pack("<BH", status, len(payload)) + payload
        self.tx += bytes([bow32_flash.SOF_RSP]) + body + struct.pack("<I", zlib.crc32(body))

    def _process(self):
        while True:
            start = self.rx.find(bytes([bow32_flash.SOF_REQ]))
            if start < 0 or len(self.rx) < start + 4:
                return
            cmd, length = struct.unpack_from("<BH", self.rx, start + 1)
            end = start + 4 + length + 4
            if len(self.rx) < end:
                return
            body = bytes(self.rx[start + 1:start + 4 + length])
            (crc,) = struct.unpack_from("<I", self.rx, start + 4 + length)
            del self.rx[:end]
            if crc != zlib.crc32(body):
                self._respond(1)
                continue
            self._command(cmd, body[3:])

    def _command(self, cmd, p):
        if cmd == bow32_flash.CMD_INFO:
            self._respond(0, struct.pack("<8I", 0xB0320100, 0x00010000, FLASH_BASE, FLASH_SIZE,
                                         PAGE, 256, 0x20000000, 16 * 1024))
        elif cmd == bow32_flash.CMD_ERASE:
            addr, length = struct.unpack("<II", p)
            if length == 0xFFFFFFFF:
                self.flash[:] = b"\xff" * FLASH_SIZE
            else:
                first = (addr - FLASH_BASE) // PAGE * PAGE
                last = (addr - FLASH_BASE + length - 1) // PAGE * PAGE
                for off in range(first, last + PAGE, PAGE):
                    self.flash[off:off + PAGE] = b"\xff" * PAGE
            self._respond(0)
        elif cmd == bow32_flash.CMD_WRITE:
            addr, data = struct.unpack_from("<I", p)[0], p[4:]
            if addr % 4 or len(data) % 4:
                return self._respond(3)
            off = addr - FLASH_BASE
            for i, b in enumerate(data):  # NOR semantics: bits only go 1 -> 0
                self.flash[off + i] &= b
            ok = bytes(self.flash[off:off + len(data)]) == data
            self._respond(0 if ok else 4)
        elif cmd == bow32_flash.CMD_READ:
            addr, length = struct.unpack("<II", p)
            off = addr - FLASH_BASE
            self._respond(0, bytes(self.flash[off:off + length]))
        elif cmd == bow32_flash.CMD_CRC:
            addr, length = struct.unpack("<II", p)
            off = addr - FLASH_BASE
            self._respond(0, struct.pack("<I", zlib.crc32(self.flash[off:off + length])))
        elif cmd == bow32_flash.CMD_BOOT:
            self.booted = True
            self._respond(0)
        else:
            self._respond(2)


def make_image(payload):
    payload += b"\xff" * (-len(payload) % 4)
    hdr = struct.pack("<8I", 0x32334F42, 1, len(payload), zlib.crc32(payload),
                      FLASH_BASE + 32, 0, 0, 0)
    return hdr + payload


class FlashToolTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        patcher = mock.patch.object(bow32_flash.serial, "Serial", FakeLoaderSerial)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.ld = bow32_flash.Loader("fake", 115200)
        self.dev = self.ld.ser

    def test_connect_sends_break_and_reads_info(self):
        info = self.ld.connect()
        self.assertEqual(self.dev.breaks, 1)
        self.assertEqual(info["chip_id"], 0xB0320100)
        self.assertEqual(info["flash_size"], FLASH_SIZE)

    def test_flash_verify_boot(self):
        image = make_image(bytes(range(256)) * 9 + b"tail")
        path = self.tmp / "app.bin"
        path.write_bytes(image)
        self.ld.connect()
        args = mock.Mock(image=str(path), addr=FLASH_BASE, raw=False, no_verify=False,
                         no_boot=False)
        with mock.patch("sys.stdout"):
            bow32_flash.cmd_flash(self.ld, args)
        self.assertEqual(bytes(self.dev.flash[:len(image)]), image)
        self.assertTrue(self.dev.booted)
        self.assertEqual(self.ld.read(FLASH_BASE, 64), image[:64])

    def test_write_without_erase_fails(self):
        self.ld.connect()
        self.ld.write(FLASH_BASE, b"\x00\x00\x00\x00")
        with self.assertRaises(bow32_flash.LoaderError):
            self.ld.write(FLASH_BASE, b"\xff\xff\xff\xff")

    def test_rejects_invalid_image(self):
        path = self.tmp / "bad.bin"
        path.write_bytes(b"\x00" * 64)
        self.ld.connect()
        args = mock.Mock(image=str(path), addr=FLASH_BASE, raw=False, no_verify=False,
                         no_boot=False)
        with self.assertRaises(SystemExit):
            bow32_flash.cmd_flash(self.ld, args)


if __name__ == "__main__":
    unittest.main()
