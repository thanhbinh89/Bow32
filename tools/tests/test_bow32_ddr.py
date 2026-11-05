# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/bow32_ddr.py: the twin of the LiteDRAM BIST data
generator against words of litedram/frontend/bist.py simulated with Migen
(_LiteDRAMBISTGenerator on a native port), the xorshift fill of `memtest`,
the parsers, and the commands against a fake board that answers like
sw/apps/ddr (correct and broken variants). Also: the refresh interval the
app's self-test expects of each LiteDRAM core is the one generated. Run:
python3 -m unittest discover -s tools/tests
"""

import contextlib
import io
import random
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bow32_ddr as ddr  # noqa: E402

REPO = Path(__file__).resolve().parents[2]

# (word bytes, PRBS data, word index k, native word as written by the
# generator) from a Migen simulation of LiteDRAM's _LiteDRAMBISTGenerator
LITEDRAM_VECTORS = [
    (8, True, 0, 0x3ffffffc7ffffff8),
    (8, True, 1, 0x3fffffe07fffffc0),
    (8, True, 7, 0x3f8000007f000000),
    (8, True, 100, 0xdfc8df91bf91bf23),
    (8, True, 599, 0x3db75d167b6eba2c),
    (8, False, 1, 0x4000000080000001),
    (8, False, 599, 0xc000012b80000257),
    (16, True, 0, 0x8fffffff1ffffffe3ffffffc7ffffff8),
    (16, True, 7, 0x0fe000001fc000003f8000007f000000),
    (16, True, 299, 0xbc9270257924e04af249c095e493812b),
    (16, False, 1, 0x10000000200000004000000080000001),
    (16, False, 7, 0x70000000e0000001c000000380000007),
]


class DataTest(unittest.TestCase):
    def test_litedram_vectors(self):
        for wbytes, rnd, k, want in LITEDRAM_VECTORS:
            with self.subTest(wbytes=wbytes, random=rnd, k=k):
                o = ddr.bist_words(rnd, k + 1)[k]
                got = ddr.word_bytes(o, wbytes)
                self.assertEqual(len(got), wbytes)
                self.assertEqual(int.from_bytes(got, "little"), want)
                data = ddr.bist_bytes(rnd, (k + 1) * wbytes, wbytes)
                self.assertEqual(data[k * wbytes:], got)

    def test_properties(self):
        rnd = random.Random(3)
        for _ in range(50):
            o = rnd.getrandbits(31)
            for wbytes in (8, 16):
                v = int.from_bytes(ddr.word_bytes(o, wbytes), "little")
                self.assertEqual(v & ddr.M31, o)                          # o from bit 0
                self.assertEqual((v >> 31) & ddr.M31, o)                  # then repeated
        self.assertEqual(ddr.bist_words(False, 4), [0, 1, 2, 3])
        words = ddr.bist_words(True, 200)
        self.assertEqual(len(set(words)), 200)                            # no short cycle
        self.assertEqual(words[1], ddr.prbs31(words[0]))

    def test_memtest_fill(self):
        self.assertEqual(ddr.xs32(1), 0x00042021)
        self.assertEqual(ddr.memtest_bytes(0, 2), ddr.memtest_bytes(1, 2))
        self.assertEqual(ddr.memtest_bytes(1, 2)[:4], (0x00042021).to_bytes(4, "little"))
        self.assertEqual(ddr.memtest_bytes(1, 2)[4:], ddr.xs32(0x00042021).to_bytes(4, "little"))


class ParseTest(unittest.TestCase):
    def test_dump(self):
        text = "80000000: 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f\n80000010: 10 11"
        self.assertEqual(ddr.parse_dump(text, 0x80000000, 18), bytes(range(18)))
        with self.assertRaises(ddr.DdrError):
            ddr.parse_dump(text, 0x80000000, 20)
        with self.assertRaises(ddr.DdrError):
            ddr.parse_dump(text.replace("80000010", "80000020"), 0x80000000, 18)

    def test_test_cal_eye_bist(self):
        text = ("ddr: self-test (quick, seed 1)\n"
                "  [ 1] IP present: ID, INFO, CLK_HZ, link, DDR clock, LiteDRAM CSRs   ok\n"
                "ddr: eye |ffff....eeee\n          eeee..dd| phase 264 width 184 p 14\n"
                "ddr: read phase 264 width 184 p 14 RD_DLY 3 SLIP 0, BIST 0 errors\n"
                "  [ 4] read calibration: eye, RD_DLY / RD_SLIP, verify, hand-over     FAIL\n"
                "ddr: FAIL (1/2)")
        checks, passed, total = ddr.parse_test(text)
        self.assertEqual(checks, [(1, "IP present: ID, INFO, CLK_HZ, link, DDR clock, LiteDRAM CSRs", True),
                                  (4, "read calibration: eye, RD_DLY / RD_SLIP, verify, hand-over", False)])
        self.assertEqual((passed, total), (1, 2))
        self.assertEqual(ddr.parse_cal(text), {"phase": 264, "width": 184, "p": 14, "rd_dly": 3,
                                               "rd_slip": 0, "bist_errors": 0})
        eye, result = ddr.parse_eye(text)
        self.assertEqual(eye, "ffff....eeeeeeee..dd")
        self.assertEqual(result, "phase 264 width 184 p 14")
        self.assertEqual(ddr.parse_eye(text, write=True), (None, None))
        b = ddr.parse_bist("bist: addr 00100000 len 4096 data count: done 1 errors 0 wticks 517 rticks 520 "
                           "(write 264.08 MB/s, read 262.56 MB/s)\n")
        self.assertEqual(b, {"addr": 0x100000, "len": 4096, "random": False, "done": 1, "errors": 0,
                             "wticks": 517, "rticks": 520})
        self.assertIsNone(ddr.parse_bist("bist: pat 1 seed 2 addr 00000000 len 4"))


class FirmwareCoreTest(unittest.TestCase):
    def test_trefi_matches_the_generated_core(self):
        """trefi_cycles of sw/common/litedram/bow_litedram_<core>.c (the REF
        interval check of `test`) = TRefi of the generated package (the C
        headers of the core do not carry it)."""
        for core in ("ddr2", "ddr3"):
            with self.subTest(core=core):
                pkg = (REPO / "hw/ip/ddr/litedram/generated" / core / f"litedram_{core}_pkg.sv").read_text()
                src = (REPO / "sw/common/litedram" / f"bow_litedram_{core}.c").read_text()
                want = re.search(r"\bTRefi\s*=\s*(\d+)\s*;", pkg)
                got = re.search(r"\.trefi_cycles\s*=\s*(\d+)\s*,", src)
                self.assertIsNotNone(want, "TRefi not found in the package")
                self.assertIsNotNone(got, ".trefi_cycles not found in the core description")
                self.assertEqual(int(got.group(1)), int(want.group(1)))


class FakeDdrSerial:
    """The shell of sw/apps/ddr (echo, ok / error, prompt) over a memory model.
    broken: None, "bist_data" (BIST writes counter data for prbs), "flip"
    (dump flips a bit), "memtest" (fill one xorshift step late), "test" (a
    check fails), "prompt" (a check fails with "> " inside a detail line, as
    the old "(> 50)"), "bist_errors" (BIST reports errors), "absent" (no IP)."""

    def __init__(self, broken=None, x16=False):
        self.baudrate = 115200
        self.rx = bytearray()
        self.tx = bytearray(b"> ")
        self.broken = broken
        self.x16 = x16
        self.wbytes = 16 if x16 else 8
        self.mem = bytearray(b"\xa5" * (4 << 20))
        self.inited = self.ready = False
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

    def _banner(self):
        if self.broken == "absent":
            return "ddr: IP not found (stub: DdrEn = 0, INFO 00000000)\n"
        return (f"ddr: Bow32 DDR{3 if self.x16 else 2} x{16 if self.x16 else 8} (LiteDRAM controller), "
                "PHY loopback, 133 MHz (133333333 Hz), 504 phase steps, emulator 4096 KiB\n")

    def _line(self, line):
        w = line.split()
        cmd, args = w[0], w[1:]
        if cmd == "info":
            text = self._banner()
            if self.broken != "absent":
                text += ("  memory: 64 MiB at 80000000, test region 4096 KiB\n"
                         f"  state: {'ready' if self.ready else 'not initialised (init, cal)'}\n")
            if self.ready:
                text += "  calibration: phase 262 width 184 RD_DLY 3 SLIP 0, write phase 0\n"
            return True, text
        if self.broken == "absent":
            return False, "error: no DDR IP (stub or bus error)\n"
        if cmd == "init":
            self.inited, self.ready = True, False
            return True, ("ddr: init DDR2 (LiteDRAM core: CL 3 CWL 2, controller 33333333 Hz), "
                          "CK 133333333 Hz, CTRL 000008c1 LAT 22240083\nddr: init done, LiteDRAM refresh "
                          "on (DFII hardware control), not handed over\n")
        if cmd in ("cal", "eye"):
            self.inited = True
            text = "ddr: eye |fffff.....eeeeeeeee\n          eeeee.....ddd| phase 262 width 184 p 14\n"
            if cmd == "cal":
                self.ready = True
                text += "ddr: read phase 262 width 184 p 14 RD_DLY 3 SLIP 0, BIST 0 errors\n"
                if "--write" in args:
                    text += ("ddr: write eye |...#####..| write phase 10 width 168\n"
                             "ddr: write phase 10 width 168\n")
            return True, text
        if cmd == "bist":
            addr, n, mode = int(args[0], 0) & 0x1FFFFFFF, int(args[1]), args[2] if len(args) > 2 else "prbs"
            rnd = mode == "prbs" and self.broken != "bist_data"
            data = ddr.bist_bytes(rnd, n, self.wbytes)
            self.mem[addr:addr + len(data)] = data
            errs = n // self.wbytes if self.broken == "bist_errors" else 0
            ticks = n // self.wbytes + 5
            text = (f"bist: addr {addr:08x} len {n} data {mode}: done 1 errors {errs} wticks {ticks} "
                    f"rticks {ticks} (write 260.00 MB/s, read 260.00 MB/s)\n")
            return errs == 0, text
        if cmd == "memtest":
            addr, n, seed = int(args[0], 0) & 0x1FFFFFFF, int(args[1]), int(args[2])
            data = ddr.memtest_bytes(seed, n // 4)
            if self.broken == "memtest":
                data = ddr.memtest_bytes(ddr.xs32(seed or 1), n // 4)
            self.mem[addr:addr + n] = data
            return True, (f"memtest: {0x80000000 + addr:08x} + {n} bytes seed {seed}: {n // 2} words, "
                          "errors 0\n")
        if cmd == "dump":
            addr, n = int(args[0], 0), int(args[1])
            off = addr - 0x80000000
            data = bytearray(self.mem[off:off + n])
            if self.broken == "flip" and n > 5:
                data[5] ^= 0x10
            text = ""
            for o in range(0, n, 16):
                text += f"{addr + o:08x}:" + "".join(f" {b:02x}" for b in data[o:o + 16]) + "\n"
            return True, text
        if cmd == "test":
            fail = self.broken in ("test", "prompt")
            text = (f"ddr: self-test ({'quick' if 'quick' in args else 'full'}, seed 1)\n"
                    "  [ 1] IP present: ID, INFO, CLK_HZ, link, DDR clock, LiteDRAM CSRs   ok\n")
            if self.broken == "prompt":
                text += "       longest DFII software section 55 us (> 50)\n"
            text += ("  [ 2] read calibration: eye, RD_DLY / RD_SLIP, verify, hand-over     "
                     f"{'FAIL' if fail else 'ok'}\n"
                     f"ddr: {'FAIL (1/2)' if fail else 'PASS (2/2)'}\n")
            return not fail, text
        if cmd == "bench":
            return True, "bench: CPU 50 MHz through the window, 4096 bytes\n"
        if cmd == "baud":
            self.baudrate_pending = int(args[0])
            return True, f"ok, switching to {args[0]} baud\n"
        if cmd == "stat":
            return True, "ddr: ready (handed over to the LiteDRAM controller)\n"
        return False, "unknown command, h for help\n"


def board(broken=None, x16=False):
    b = ddr.DdrBoard(FakeDdrSerial(broken, x16))
    b.sync()
    return b


def run_main(argv, ser):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        rc = ddr.main(["-p", "fake"] + argv, open_serial=lambda: ser)
    return rc, out.getvalue()


class BoardTest(unittest.TestCase):
    def test_run_and_info(self):
        b = board()
        ok, text = b.run("bogus")
        self.assertFalse(ok)
        self.assertIn("unknown command", text)
        info = b.info()
        self.assertEqual((info["ddr"], info["dq"], info["phy"], info["steps"], info["memory"],
                          info["capacity"], info["calibrated"], info["ready"]),
                         (2, 8, "loopback", 504, 64 << 20, 4 << 20, False, False))
        b.run("cal 4")
        info = b.info()
        self.assertEqual((info["calibrated"], info["ready"]), (True, True))
        self.assertEqual(board(x16=True).info()["dq"], 16)
        with self.assertRaises(ddr.DdrError):
            board("absent").info()

    def test_bist_memtest_dump(self):
        b = board()
        r = b.bist(0x1000, 64, True)
        self.assertEqual((r["addr"], r["len"], r["random"], r["done"], r["errors"], r["ok"]),
                         (0x1000, 64, True, 1, 0, True))
        self.assertEqual(b.dump(0x80001000, 64), ddr.bist_bytes(True, 64, 8))
        r = b.bist(0x2000, 32, False)
        self.assertFalse(r["random"])
        self.assertEqual(b.dump(0x80002000, 32), ddr.bist_bytes(False, 32, 8))
        r = b.memtest(0x3000, 64, 5)
        self.assertEqual((r["addr"], r["len"], r["seed"], r["errors"]), (0x80003000, 64, 5, 0))
        self.assertEqual(b.dump(0x80003000, 64), ddr.memtest_bytes(5, 16))
        r = board("bist_errors").bist(0, 16, True)
        self.assertEqual((r["errors"], r["ok"]), (2, False))

    def test_prompt_only_at_a_line_start(self):
        """'> ' inside an output line is text: the command ends at the prompt
        after 'ok' / 'error', and the next command gets its own output."""
        b = board("prompt")
        ok, text = b.run("test quick")
        self.assertFalse(ok)
        self.assertIn("55 us (> 50)", text)
        self.assertEqual(ddr.parse_test(text)[1:], (1, 2))
        ok, text = b.run("stat")
        self.assertEqual((ok, text), (True, "ddr: ready (handed over to the LiteDRAM controller)"))
        rc, out = run_main(["test", "--quick"], FakeDdrSerial("prompt"))
        self.assertEqual(rc, 1)
        self.assertIn("FAILED [2] read calibration", out)
        self.assertNotIn("no result line", out)


class VerifyTest(unittest.TestCase):
    def test_verify_passes(self):
        for x16 in (False, True):
            with self.subTest(x16=x16):
                b = board(x16=x16)
                failed, errors = ddr.verify(b, 24, seed=5, progress=False)
                self.assertEqual((failed, errors), (0, []))
                cmds = b.ser.commands
                self.assertTrue(any(c.startswith("bist ") and c.endswith(" prbs") for c in cmds))
                self.assertTrue(any(c.startswith("bist ") and c.endswith(" count") for c in cmds))
                self.assertTrue(any(c.startswith("memtest ") for c in cmds))
                self.assertEqual(sum(c.startswith("dump ") for c in cmds), 24)
                self.assertIn("cal 4", cmds)            # brought up first
                for c in cmds:
                    if c.startswith("bist "):
                        addr, length = int(c.split()[1], 0), int(c.split()[2])
                        self.assertEqual((addr % b.ser.wbytes, length % b.ser.wbytes), (0, 0))

    def test_verify_finds_errors(self):
        for broken, min_failed in (("bist_data", 1), ("flip", 24), ("memtest", 1), ("bist_errors", 1)):
            with self.subTest(broken=broken):
                failed, errors = ddr.verify(board(broken), 24, seed=5, progress=False)
                self.assertGreaterEqual(failed, min_failed)
                self.assertGreaterEqual(len(errors), failed)
        _, errors = ddr.verify(board("flip"), 3, seed=1, progress=False)
        self.assertIn("first difference at", errors[0])

    def test_verify_seeds_differ(self):
        b1, b2 = board(), board()
        ddr.verify(b1, 6, seed=1, progress=False)
        ddr.verify(b2, 6, seed=2, progress=False)
        self.assertNotEqual(b1.ser.commands, b2.ser.commands)

    def test_bring_up_skips_cal_when_ready(self):
        b = board()
        b.run("cal 4")
        ddr.verify(b, 2, seed=1, progress=False)
        self.assertEqual(b.ser.commands.count("cal 4"), 1)


class MainTest(unittest.TestCase):
    def test_subcommands(self):
        ser = FakeDdrSerial()
        self.assertEqual(run_main(["test", "--quick"], ser)[0], 0)
        self.assertIn("test quick 1", ser.commands)
        ser = FakeDdrSerial()
        rc, out = run_main(["test", "--seed", "4"], ser)
        self.assertEqual(rc, 0)
        self.assertIn("test full 4", ser.commands)
        rc, out = run_main(["test"], FakeDdrSerial("test"))
        self.assertEqual(rc, 1)
        self.assertIn("FAILED [2] read calibration", out)
        ser = FakeDdrSerial()
        rc, out = run_main(["cal", "--step", "2", "--write", "--init"], ser)
        self.assertEqual(rc, 0)
        self.assertIn("cal: phase 262 width 184 RD_DLY 3 SLIP 0", out)
        self.assertIn("cal 2 --write", ser.commands)
        rc, out = run_main(["eye"], FakeDdrSerial())
        self.assertEqual(rc, 0)
        self.assertIn("eye: 22 of 32 points show the pattern; phase 262 width 184 p 14", out)
        self.assertEqual(run_main(["bench"], FakeDdrSerial())[0], 0)
        self.assertEqual(run_main(["cmd", "stat", "info"], FakeDdrSerial())[0], 0)
        self.assertEqual(run_main(["cmd", "stat", "bogus"], FakeDdrSerial())[0], 1)
        rc, out = run_main(["verify", "-n", "8", "--seed", "3"], FakeDdrSerial())
        self.assertEqual(rc, 0)
        self.assertIn("verify: PASS (8/8 cases", out)
        rc, out = run_main(["verify", "-n", "8", "--seed", "3"], FakeDdrSerial("flip"))
        self.assertEqual(rc, 1)
        self.assertIn("verify: FAIL (0/8 cases", out)
        rc, out = run_main(["verify", "-n", "8", "--seed", "3"], FakeDdrSerial("bist_errors"))
        self.assertEqual(rc, 1)
        self.assertRegex(out, r"verify: FAIL \(\d/8 cases")
        rc, out = run_main(["verify", "-n", "2"], FakeDdrSerial("absent"))
        self.assertEqual(rc, 2)
        self.assertIn("no DDR controller (stub: DdrEn = 0", out)

    def test_fast(self):
        ser = FakeDdrSerial()
        rc, _ = run_main(["--fast", "921600", "cmd", "stat"], ser)
        self.assertEqual((rc, ser.baudrate), (0, 921600))


if __name__ == "__main__":
    unittest.main()
