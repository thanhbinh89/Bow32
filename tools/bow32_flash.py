#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bow32 UART flash tool - talks to the boot ROM loader on UART0.

Examples:
  bow32_flash.py -p /dev/ttyUSB0 info
  bow32_flash.py -p /dev/ttyUSB0 flash build/sw/hello/hello.bin      # erase+write+verify+boot
  bow32_flash.py -p /dev/ttyUSB0 read 0x08000000 64
  bow32_flash.py -p /dev/ttyUSB0 erase --all
  bow32_flash.py -p /dev/ttyUSB0 boot
  bow32_flash.py -p /dev/ttyUSB0 monitor                            # interactive serial console

Entering the loader: by default the tool sends a UART BREAK, which makes
Bow32 reset into the loader (SYSCTRL BRK_CTRL). Use --no-break if your
adapter cannot send BREAK; then reset the board and the tool keeps knocking
during the boot ROM wait window.

Protocol: docs/boot.md, sw/common/include/bow32_boot_proto.h
"""

import argparse
import struct
import sys
import time
import zlib
from pathlib import Path

try:
    import serial
except ImportError:  # pragma: no cover
    sys.exit("error: pyserial is required (pip install -r requirements.txt)")

SOF_REQ = 0xA5
SOF_RSP = 0xB5

CMD_INFO, CMD_ERASE, CMD_WRITE, CMD_READ, CMD_CRC, CMD_BOOT, CMD_RESET = range(1, 8)

STATUS = {0: "OK", 1: "CRC error", 2: "unknown command", 3: "bad argument",
          4: "flash error", 5: "bad length"}

IMAGE_MAGIC = 0x32334F42
FLASH_BASE = 0x08000000


class LoaderError(Exception):
    pass


class Loader:
    def __init__(self, port, baud, timeout=1.0, verbose=False):
        self.ser = serial.Serial(port, baud, timeout=timeout)
        self.verbose = verbose
        self.info = None

    # ------------------------------------------------------------ transport
    def _read_exact(self, n):
        data = self.ser.read(n)
        if len(data) != n:
            raise LoaderError("timeout waiting for response")
        return data

    def transact(self, cmd, payload=b"", timeout=1.0):
        body = struct.pack("<BH", cmd, len(payload)) + payload
        frame = bytes([SOF_REQ]) + body + struct.pack("<I", zlib.crc32(body))
        self.ser.write(frame)
        self.ser.flush()

        # Skip anything (e.g. ROM banner text) before the response SOF.
        deadline = time.monotonic() + timeout
        while True:
            b = self.ser.read(1)
            if b and b[0] == SOF_RSP:
                break
            if b and self.verbose:
                sys.stderr.write(b.decode("ascii", "replace"))
            if time.monotonic() > deadline:
                raise LoaderError("no response from the boot ROM")
        hdr = self._read_exact(3)
        status, length = struct.unpack("<BH", hdr)
        data = self._read_exact(length)
        (crc,) = struct.unpack("<I", self._read_exact(4))
        if crc != zlib.crc32(hdr + data):
            raise LoaderError("response CRC mismatch")
        if status != 0:
            raise LoaderError(f"command 0x{cmd:02x} failed: {STATUS.get(status, status)}")
        return data

    # --------------------------------------------------------------- connect
    def connect(self, use_break=True, attempts=50):
        if use_break:
            # BREAK >= 10 ms resets Bow32 into the loader.
            try:
                self.ser.send_break(duration=0.05)
            except Exception as e:  # termios.error / SerialException
                raise LoaderError("the adapter cannot send a BREAK; enter the loader another "
                                  f"way ('B' in hello, reload the PL) and use --no-break [{e}]")
            time.sleep(0.05)
        self.ser.reset_input_buffer()
        last = None
        for _ in range(attempts):
            try:
                return self.get_info(timeout=0.2)
            except LoaderError as e:
                last = e
        raise LoaderError(f"cannot reach the boot ROM loader ({last})")

    # -------------------------------------------------------------- commands
    def get_info(self, timeout=1.0):
        d = self.transact(CMD_INFO, timeout=timeout)
        keys = ("chip_id", "rom_version", "flash_base", "flash_size", "page_size",
                "max_data", "sram_base", "sram_size")
        self.info = dict(zip(keys, struct.unpack("<8I", d)))
        return self.info

    def erase(self, addr, length):
        # Page erase takes ~page/4 cycles per page; allow generous time.
        self.transact(CMD_ERASE, struct.pack("<II", addr, length), timeout=5.0)

    def mass_erase(self):
        self.transact(CMD_ERASE, struct.pack("<II", 0, 0xFFFFFFFF), timeout=10.0)

    def write(self, addr, data, progress=None):
        step = self.info["max_data"] if self.info else 256
        for off in range(0, len(data), step):
            chunk = data[off:off + step]
            chunk += b"\xff" * (-len(chunk) % 4)
            self.transact(CMD_WRITE, struct.pack("<I", addr + off) + chunk, timeout=2.0)
            if progress:
                progress(min(off + step, len(data)), len(data))

    def read(self, addr, length):
        out = bytearray()
        step = self.info["max_data"] if self.info else 256
        while len(out) < length:
            n = min(step, length - len(out))
            out += self.transact(CMD_READ, struct.pack("<II", addr + len(out), n))
        return bytes(out)

    def crc(self, addr, length):
        d = self.transact(CMD_CRC, struct.pack("<II", addr, length), timeout=10.0)
        return struct.unpack("<I", d)[0]

    def boot(self):
        self.transact(CMD_BOOT)

    def reset(self):
        self.transact(CMD_RESET)


def progress_bar(done, total):
    width = 40
    fill = width * done // total
    sys.stdout.write(f"\r  [{'#' * fill}{'.' * (width - fill)}] {done}/{total} bytes")
    if done == total:
        sys.stdout.write("\n")
    sys.stdout.flush()


def print_info(info):
    v = info["rom_version"]
    print(f"chip id    : 0x{info['chip_id']:08x}")
    print(f"ROM version: {v >> 16}.{(v >> 8) & 0xff}.{v & 0xff}")
    print(f"flash      : {info['flash_size'] // 1024} KiB @ 0x{info['flash_base']:08x}, "
          f"page {info['page_size']} bytes")
    print(f"sram       : {info['sram_size'] // 1024} KiB @ 0x{info['sram_base']:08x}")


def cmd_flash(ld, args):
    data = Path(args.image).read_bytes()
    addr = args.addr
    if addr == FLASH_BASE and not args.raw:
        magic, _, size, crc, entry = struct.unpack_from("<5I", data)
        if magic != IMAGE_MAGIC or size + 32 > len(data) or zlib.crc32(data[32:32 + size]) != crc:
            sys.exit(f"{args.image}: not a valid Bow32 image (build it with sw/mk/app.mk, "
                     "or use --raw)")
        print(f"image: {size} bytes payload, entry 0x{entry:08x}, crc 0x{crc:08x}")
    print(f"erasing 0x{addr:08x} .. 0x{addr + len(data) - 1:08x}")
    ld.erase(addr, len(data))
    print("writing")
    ld.write(addr, data, progress=progress_bar)
    if not args.no_verify:
        dev_crc = ld.crc(addr, len(data))
        if dev_crc != zlib.crc32(data):
            sys.exit(f"verify FAILED: device crc 0x{dev_crc:08x} != 0x{zlib.crc32(data):08x}")
        print("verify OK")
    if not args.no_boot:
        print("booting")
        ld.boot()


def cmd_monitor(ser):
    # Interactive: keys typed are sent to the board (e.g. 'B' in hello).
    from serial.tools.miniterm import Miniterm

    term = Miniterm(ser, eol="lf")
    term.exit_character = "\x03"  # Ctrl-C
    term.set_rx_encoding("utf-8", "replace")
    term.set_tx_encoding("utf-8")
    print(f"--- monitor on {ser.port} @ {ser.baudrate}, Ctrl-C to quit ---")
    term.start()
    term.join(True)
    term.join()
    term.close()
    print()


def main():
    auto_int = lambda s: int(s, 0)  # noqa: E731
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("-p", "--port", required=True, help="serial port, e.g. /dev/ttyUSB0 or COM5")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="baud rate (default 115200)")
    ap.add_argument("--no-break", action="store_true",
                    help="do not send a BREAK to enter the loader (reset the board yourself)")
    ap.add_argument("-v", "--verbose", action="store_true", help="show text printed by the ROM")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("info", help="show chip information")
    p = sub.add_parser("flash", help="erase, write, verify and boot an image")
    p.add_argument("image")
    p.add_argument("--addr", type=auto_int, default=FLASH_BASE)
    p.add_argument("--raw", action="store_true", help="do not check the image header")
    p.add_argument("--no-verify", action="store_true")
    p.add_argument("--no-boot", action="store_true")
    p = sub.add_parser("erase", help="erase flash pages (or --all)")
    p.add_argument("addr", type=auto_int, nargs="?", default=FLASH_BASE)
    p.add_argument("length", type=auto_int, nargs="?", default=1)
    p.add_argument("--all", action="store_true", help="mass erase")
    p = sub.add_parser("read", help="read memory (ROM/flash/SRAM) to stdout or a file")
    p.add_argument("addr", type=auto_int)
    p.add_argument("length", type=auto_int)
    p.add_argument("-o", "--output")
    p = sub.add_parser("crc", help="CRC-32 of a memory range")
    p.add_argument("addr", type=auto_int)
    p.add_argument("length", type=auto_int)
    sub.add_parser("boot", help="start the image in flash")
    sub.add_parser("reset", help="reset the SoC (normal boot)")
    sub.add_parser("monitor", help="interactive serial console (no loader)")
    args = ap.parse_args()

    if args.cmd == "monitor":
        cmd_monitor(serial.Serial(args.port, args.baud, timeout=0.1))
        return 0

    ld = Loader(args.port, args.baud, verbose=args.verbose)
    try:
        info = ld.connect(use_break=not args.no_break)
        if args.cmd == "info":
            print_info(info)
        elif args.cmd == "flash":
            cmd_flash(ld, args)
        elif args.cmd == "erase":
            if args.all:
                ld.mass_erase()
            else:
                ld.erase(args.addr, args.length)
            print("erase OK")
        elif args.cmd == "read":
            data = ld.read(args.addr, args.length)
            if args.output:
                Path(args.output).write_bytes(data)
            else:
                for off in range(0, len(data), 16):
                    line = data[off:off + 16]
                    print(f"{args.addr + off:08x}: {line.hex(' ')}")
        elif args.cmd == "crc":
            print(f"0x{ld.crc(args.addr, args.length):08x}")
        elif args.cmd == "boot":
            ld.boot()
        elif args.cmd == "reset":
            ld.reset()
    except LoaderError as e:
        sys.exit(f"error: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
