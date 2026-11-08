# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/bow32_hyperram.py: the twin of the BIST data generator
of bow_hyperram_bist (xorshift32 PRBS, address ^ seed), the xorshift fill of
`fill` / `memtest`, the parsers, and the commands against a fake board that
answers like sw/apps/hyperram (correct and broken variants). Run:
python3 -m unittest discover -s tools/tests
"""

import contextlib
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bow32_hyperram as hr  # noqa: E402


class DataTest(unittest.TestCase):
    def test_xorshift(self):
        self.assertEqual(hr.xs32(1), 0x00042021)
        self.assertEqual(hr.xs32(0x00042021), 0x04080601)

    def test_bist_prbs(self):
        # word k = state after k steps (word 0 = the seed), low 16 bits
        self.assertEqual(hr.bist_words(False, 1, 0, 3), [0x0001, 0x2021, 0x0601])
        self.assertEqual(hr.bist_words(False, 0, 0, 2), hr.bist_words(False, 1, 0, 2))   # seed 0 -> 1
        words = hr.bist_words(False, 0xCAFEF00D, 77, 300)
        self.assertEqual(words[0], 0xF00D)
        self.assertEqual(words, hr.bist_words(False, 0xCAFEF00D, 0, 300))              # no address
        self.assertGreater(len(set(words)), 280)

    def test_bist_count(self):
        self.assertEqual(hr.bist_words(True, 0x1234, 0x10, 3), [0x1224, 0x1225, 0x1226])
        self.assertEqual(hr.bist_words(True, 0xABCD0000, 0x1FFFF, 2), [0xFFFF, 0x0000])

    def test_bytes(self):
        self.assertEqual(hr.bist_bytes(True, 0, 0x0102, 2), bytes([0x02, 0x01, 0x03, 0x01]))
        self.assertEqual(hr.fill_bytes(0, 2), hr.fill_bytes(1, 2))
        self.assertEqual(hr.fill_bytes(1, 1), (0x00042021).to_bytes(4, "little"))


class ParseTest(unittest.TestCase):
    def test_dump(self):
        text = "60000000: 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f\n60000010: 10 11"
        self.assertEqual(hr.parse_dump(text, 0x60000000, 18), bytes(range(18)))
        with self.assertRaises(hr.HrError):
            hr.parse_dump(text, 0x60000000, 20)
        with self.assertRaises(hr.HrError):
            hr.parse_dump(text, 0x60000010, 18)

    def test_cal_eye_bist(self):
        text = ("hyperram: eye (ID0) |####....\n            ####|\n"
                "hyperram: eye (pattern) |##..##|\n"
                "hyperram: read phase 1008 width 672 RD_DLY 12 (first byte A at half cycle 46)\n")
        self.assertEqual(hr.parse_cal(text), {"phase": 1008, "width": 672, "rd_dly": 12, "first_half": 46})
        self.assertEqual(hr.parse_eyes(text), {"eye (ID0)": "####....####", "eye (pattern)": "##..##"})
        b = hr.parse_bist("bist: words 512 at 60100000, bursts of 64, data prbs seed 0000002a, both: "
                          "errors 0, cycles 1234 (150.00 MB/s)\n")
        self.assertEqual((b["words"], b["addr"], b["burst"], b["count"], b["seed"], b["mode"], b["errors"],
                          b["cycles"]), (512, 0x60100000, 64, False, 42, "both", 0, 1234))
        self.assertIsNone(hr.parse_cal("nothing"))

    def test_test(self):
        text = ("  [ 1] IP present: ID, INFO, CLK_HZ, HyperRAM clock                   ok\n"
                "  [ 2] refused: 2 CMD bits, ID0 write, window while not READY         FAIL\n"
                "hyperram: FAIL (1/2)\n")
        checks, passed, total = hr.parse_test(text)
        self.assertEqual((passed, total), (1, 2))
        self.assertEqual([ok for _, _, ok in checks], [True, False])


class FakeHrSerial:
    """The shell of sw/apps/hyperram (echo, ok / error, prompt) over a memory
    model. broken: None, "bist_data" (PRBS written for count), "flip" (dump
    flips a bit), "fill" (fill one xorshift step late), "test" (a check
    fails), "absent" (no IP)."""

    def __init__(self, broken=None):
        self.baudrate = 115200
        self.rx = bytearray()
        self.tx = bytearray(b"> ")
        self.broken = broken
        self.mem = bytearray(b"\xa5" * (4 << 20))
        self.ready = False
        self.commands = []

    @property
    def in_waiting(self):
        return len(self.tx)

    def reset_input_buffer(self):
        self.tx.clear()

    def read(self, n):
        out = bytes(self.tx[:n])
        del self.tx[:n]
        return out

    def close(self):
        pass

    def write(self, data):
        self.rx += data
        while b"\r" in self.rx:
            i = self.rx.index(b"\r")
            line, self.rx = self.rx[:i].decode(), self.rx[i + 1:]
            self.tx += line.encode() + b"\r\n"
            if line:
                self.commands.append(line)
                ok, text = self._line(line)
                self.tx += text.replace("\n", "\r\n").encode() + (b"ok\r\n" if ok else b"error\r\n")
            self.tx += b"> "
        return len(data)

    def _line(self, line):
        w = line.split()
        cmd, args = w[0], w[1:]
        if cmd == "info":
            if self.broken == "absent":
                return True, "hyperram: IP not found (stub: HrEn = 0, INFO 00000000)\n"
            text = ("hyperram: Bow32 HyperRAM 32 MiB x8, PHY loopback, 100 MHz (100000000 Hz), 672 phase "
                    "steps, emulator 4096 KiB\n  memory: 32 MiB at 60000000, test region 4096 KiB, read "
                    f"buffer 4 x 32 bytes\n  state: {'ready' if self.ready else 'not initialised (init)'}\n")
            return True, text
        if self.broken == "absent":
            return False, "error: no HyperRAM IP (stub or bus error)\n"
        if cmd == "init":
            self.ready = True
            return True, ("hyperram: eye (ID0) |####|\nhyperram: eye (pattern) |####|\nhyperram: read phase "
                          "100 width 600 RD_DLY 12 (first byte A at half cycle 46)\nhyperram: ready: ID0 0e86 "
                          "ID1 0001 CR0 8fff, latency 4 fixed, TCSM 395 cycles\n")
        if cmd == "bist":
            addr, n = int(args[0], 0) & 0x0FFFFFFF, int(args[1])
            count = "count" in args
            nums = [a for a in args[2:] if a not in ("count", "prbs", "w", "r")]
            burst, seed = int(nums[0]), int(nums[1])
            data = hr.bist_bytes(count if self.broken != "bist_data" else not count, seed, addr // 2, n // 2)
            self.mem[addr:addr + n] = data
            return True, (f"bist: words {n // 2} at {0x60000000 + addr:08x}, bursts of {burst or 64}, data "
                          f"{'count' if count else 'prbs'} seed {seed:08x}, write: errors 0, cycles {n} "
                          "(100.00 MB/s)\n")
        if cmd == "fill":
            addr, n, seed = int(args[0], 0) & 0x0FFFFFFF, int(args[1]), int(args[2])
            data = hr.fill_bytes(hr.xs32(seed or 1) if self.broken == "fill" else seed, n // 4)
            self.mem[addr:addr + n] = data
            return True, f"fill: {0x60000000 + addr:08x} + {n} bytes seed {seed}: xorshift written\n"
        if cmd == "dump":
            addr, n = int(args[0], 0), int(args[1])
            off = addr - 0x60000000
            data = bytearray(self.mem[off:off + n])
            if self.broken == "flip" and n > 5:
                data[5] ^= 0x10
            text = ""
            for o in range(0, n, 16):
                text += f"{addr + o:08x}:" + "".join(f" {b:02x}" for b in data[o:o + 16]) + "\n"
            return True, text
        if cmd == "test":
            fail = self.broken == "test"
            return not fail, ("hyperram: self-test (quick, seed 1)\n"
                              "  [ 1] IP present: ID, INFO, CLK_HZ, HyperRAM clock                   ok\n"
                              "  [ 2] init: RESET#, ID0 eye, CR0 / CR1, pattern eye, window open     "
                              f"{'FAIL' if fail else 'ok'}\nhyperram: {'FAIL (1/2)' if fail else 'PASS (2/2)'}\n")
        if cmd in ("cal", "eye"):
            return True, ("hyperram: eye (ID0) |##..|\nhyperram: eye (pattern) |#...|\nhyperram: read phase 5 "
                          "width 300 RD_DLY 11 (first byte A at half cycle 44)\n")
        if cmd == "calw":
            return True, "hyperram: write eye |..##..|\nhyperram: write phase 8 width 64\n"
        if cmd in ("bench", "stat"):
            return True, f"{cmd}: fine\n"
        return False, "unknown command, h for help\n"


def board(broken=None):
    b = hr.HrBoard(FakeHrSerial(broken))
    b.sync()
    return b


def run_main(argv, ser):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        rc = hr.main(["-p", "fake"] + argv, open_serial=lambda: ser)
    return rc, out.getvalue()


class BoardTest(unittest.TestCase):
    def test_info(self):
        info = board().info()
        self.assertEqual((info["mib"], info["phy"], info["mhz"], info["steps"], info["emulator"],
                          info["capacity"], info["ready"], info["level_shifters"]),
                         (32, "loopback", 100, 672, 4 << 20, 4 << 20, False, False))
        with self.assertRaises(hr.HrError):
            board("absent").info()

    def test_bist_fill_dump(self):
        b = board()
        r = b.bist(0x1000, 64, False, 42, 16, "w")
        self.assertEqual((r["words"], r["seed"], r["count"], r["ok"]), (32, 42, False, True))
        self.assertEqual(b.dump(0x60001000, 64), hr.bist_bytes(False, 42, 0x800, 32))
        b.fill(0x2000, 32, 9)
        self.assertEqual(b.dump(0x60002000, 32), hr.fill_bytes(9, 8))


class VerifyTest(unittest.TestCase):
    def test_verify_passes(self):
        b = board()
        failed, errors = hr.verify(b, 30, seed=5, progress=False)
        self.assertEqual((failed, errors), (0, []))
        cmds = b.ser.commands
        self.assertIn("init", cmds)
        self.assertTrue(any(c.startswith("bist ") and " count " in c for c in cmds))
        self.assertTrue(any(c.startswith("bist ") and " prbs " in c for c in cmds))
        self.assertTrue(any(c.startswith("fill ") for c in cmds))
        self.assertEqual(sum(c.startswith("dump ") for c in cmds), 30)
        for c in cmds:
            if c.startswith(("bist ", "fill ")):
                addr, length = int(c.split()[1], 0), int(c.split()[2])
                self.assertEqual((addr % 4, length % 4), (0, 0))

    def test_verify_finds_errors(self):
        for broken in ("bist_data", "flip", "fill"):
            with self.subTest(broken=broken):
                failed, errors = hr.verify(board(broken), 20, seed=3, progress=False)
                self.assertGreater(failed, 0)
                self.assertIn("first difference at", errors[0])


class MainTest(unittest.TestCase):
    def test_subcommands(self):
        self.assertEqual(run_main(["test", "--quick"], FakeHrSerial())[0], 0)
        self.assertEqual(run_main(["test"], FakeHrSerial("test"))[0], 1)
        rc, out = run_main(["cal", "--write"], FakeHrSerial())
        self.assertEqual(rc, 0)
        self.assertIn("cal: phase 5 width 300 RD_DLY 11", out)
        rc, out = run_main(["eye"], FakeHrSerial())
        self.assertIn("eye (pattern): 1 of 4 points good", out)
        rc, out = run_main(["verify", "-n", "5", "--seed", "1"], FakeHrSerial())
        self.assertEqual(rc, 0)
        self.assertIn("verify: PASS (5/5 cases)", out)
        self.assertEqual(run_main(["verify", "-n", "5", "--seed", "1"], FakeHrSerial("flip"))[0], 1)
        rc, out = run_main(["cmd", "stat", "bogus"], FakeHrSerial())
        self.assertEqual(rc, 1)
        self.assertEqual(run_main(["bench"], FakeHrSerial("absent"))[0], 1)   # no IP: error


if __name__ == "__main__":
    unittest.main()
