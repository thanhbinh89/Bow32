#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bow32 HyperRAM tool - drives the HyperRAM test (sw/apps/hyperram on UART0)
of the bow_hyperram IP: self-test, calibration, eye map, write phase scan,
bandwidth, and a data check with seeds chosen here and the memory read back
with `dump`.

Examples:
  bow32_hyperram.py -p PORT test                    self-test of the app (`test`)
  bow32_hyperram.py -p PORT test --quick --seed 7
  bow32_hyperram.py -p PORT cal --step 2            init (if needed), read calibration
  bow32_hyperram.py -p PORT cal --write             + write phase scan (card only)
  bow32_hyperram.py -p PORT eye --step 1            eye map only
  bow32_hyperram.py -p PORT bench                   CPU and BIST bandwidth
  bow32_hyperram.py -p PORT --fast 921600 verify -n 40
  bow32_hyperram.py -p PORT cmd stat "reg CR0" "cap ID0"

`verify` initialises the memory if needed, then runs random cases: `bist ADDR
LEN prbs|count w BURST SEED` (the hardware BIST writes LEN bytes) or `fill ADDR
LEN SEED` (the CPU writes through the window, posted writes). Each case must
succeed, then `dump` reads the range back through the window and every byte
must equal the data computed here: bist_bytes() is the Python twin of the BIST
data generator of bow_hyperram_bist (xorshift32 PRBS or address ^ seed per
HyperRAM word), fill_bytes() the xorshift fill of the app. Exit status 0 when
everything matches.

Needs pyserial.
"""

import argparse
import random
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bow32_cam import Camera, PROMPT, serial  # noqa: E402

M32 = 0xFFFFFFFF
WINDOW = 0x60000000

BANNER_RE = re.compile(r"^hyperram: Bow32 HyperRAM (\d+) MiB x8, PHY (\w+), (\d+) MHz \((\d+) Hz\), "
                       r"(\d+) phase steps(, level shifters)?(?:, emulator (\d+) KiB)?", re.M)
NOT_FOUND_RE = re.compile(r"^hyperram: IP not found \((.*)\)$", re.M)
REGION_RE = re.compile(r"memory: (\d+) MiB at [0-9a-f]{8}, test region (\d+) KiB")
BIST_RE = re.compile(r"^bist: words (\d+) at ([0-9a-f]{8}), bursts of (\d+), data (prbs|count) seed "
                     r"([0-9a-f]{8}), (write|read|both): errors (\d+), cycles (\d+)", re.M)
FILL_RE = re.compile(r"^fill: ([0-9a-f]{8}) \+ (\d+) bytes seed (\d+): xorshift written$", re.M)
DUMP_RE = re.compile(r"^([0-9a-f]{8}):((?: [0-9a-f]{2})+)$")
CAL_RE = re.compile(r"^hyperram: read phase (-?\d+) width (\d+) RD_DLY (\d+) "
                    r"\(first byte A at half cycle (\d+)\)", re.M)
WCAL_RE = re.compile(r"^hyperram: write phase (-?\d+) width (\d+)$", re.M)
EYE_RE = re.compile(r"^hyperram: (eye \((?:ID0|pattern)\)|write eye) \|(.*?)\|", re.M | re.S)
CHECK_RE = re.compile(r"^  \[\s*(\d+)\] (.*?)\s+(ok|FAIL)$", re.M)
RESULT_RE = re.compile(r"^hyperram: (PASS|FAIL) \((\d+)/(\d+)\)$", re.M)


class HrError(Exception):
    pass


# ---------------------------------------------------------------- data models
def xs32(x):
    """xorshift32 (13, 17, 5), as the BIST and the app's fill."""
    x ^= (x << 13) & M32
    x ^= x >> 17
    x ^= (x << 5) & M32
    return x


def bist_words(count_data, seed, waddr, words):
    """16 bit words of a BIST write of `words` HyperRAM words from word address
    waddr (bow_hyperram_bist): counter: (address ^ seed) & 0xFFFF; PRBS: the
    xorshift32 state from seed (1 if 0), word k = state after k steps, low 16
    bits."""
    if count_data:
        return [((waddr + k) ^ seed) & 0xFFFF for k in range(words)]
    x, out = seed & M32 or 1, []
    for _ in range(words):
        out.append(x & 0xFFFF)
        x = xs32(x)
    return out


def bist_bytes(count_data, seed, waddr, words):
    """Memory content after the BIST write: byte A (lower address) = word[7:0]."""
    return b"".join(w.to_bytes(2, "little") for w in bist_words(count_data, seed, waddr, words))


def fill_bytes(seed, words):
    """Content left by `fill ADDR LEN SEED` / `memtest`: x = seed (1 if 0), word
    i = x after i + 1 xorshift32 steps, little endian."""
    x = seed & M32 or 1
    out = bytearray()
    for _ in range(words):
        x = xs32(x)
        out += x.to_bytes(4, "little")
    return bytes(out)


def first_difference(got, want, base):
    for k, (g, w) in enumerate(zip(got, want)):
        if g != w:
            return f"first difference at {base + k:08x}: read {g:02x}, expected {w:02x}"
    if len(got) != len(want):
        return f"{len(got)} bytes read, {len(want)} expected"
    return ""


# ---------------------------------------------------------------- parsing
def parse_dump(text, addr, length):
    data = bytearray()
    for line in text.split("\n"):
        m = DUMP_RE.match(line.strip())
        if not m:
            continue
        if int(m.group(1), 16) != addr + len(data):
            raise HrError(f"dump: line {m.group(1)} out of order (expected {addr + len(data):08x})")
        data += bytes.fromhex(m.group(2).replace(" ", ""))
    if len(data) != length:
        raise HrError(f"dump: {len(data)} of {length} bytes")
    return bytes(data)


def parse_test(text):
    checks = [(int(m.group(1)), m.group(2), m.group(3) == "ok") for m in CHECK_RE.finditer(text)]
    m = RESULT_RE.search(text)
    if not m:
        return checks, None, None
    return checks, int(m.group(2)), int(m.group(3))


def parse_cal(text):
    m = CAL_RE.search(text)
    if not m:
        return None
    return dict(zip(("phase", "width", "rd_dly", "first_half"), (int(v) for v in m.groups())))


def parse_eyes(text):
    """{title: map} of every eye block (continuation lines joined)."""
    return {m.group(1): "".join(p.strip() for p in m.group(2).split("\n")) for m in EYE_RE.finditer(text)}


def parse_bist(text):
    m = BIST_RE.search(text)
    if not m:
        return None
    g = m.groups()
    return {"words": int(g[0]), "addr": int(g[1], 16), "burst": int(g[2]), "count": g[3] == "count",
            "seed": int(g[4], 16), "mode": g[5], "errors": int(g[6]), "cycles": int(g[7])}


# ------------------------------------------------------------------- board
class HrBoard(Camera):
    """Shell of sw/apps/hyperram (prompt / command helpers of bow32_cam)."""

    LINE_PROMPT = b"\n" + PROMPT

    def sync(self, timeout=2.0):
        """USB serial adapters deliver late bytes: drain, then two round trips."""
        super().sync(timeout)
        end = time.monotonic() + 0.2
        while time.monotonic() < end:
            self.ser.read(getattr(self.ser, "in_waiting", 0) or 1)
        super().sync(timeout)

    def run(self, line, timeout=5.0):
        """Run one command: (ok, output); 'error' does not raise."""
        self.ser.write(line.encode() + b"\r")
        text = self._read_until(self.LINE_PROMPT, timeout).decode(errors="replace")
        lines = text.replace("\r", "").split("\n")
        if lines and lines[0].endswith(line):   # echo
            lines = lines[1:]
        body = "\n".join(lines[:-2]) if len(lines) >= 2 else ""
        status = lines[-2].strip() if len(lines) >= 2 else ""
        if self.verbose:
            print(body)
        return status == "ok", body

    def info(self):
        """Banner fields, the device size and the size of the test region."""
        ok, text = self.run("info")
        m = BANNER_RE.search(text)
        if not m:
            nf = NOT_FOUND_RE.search(text)
            raise HrError("no HyperRAM controller" + (f" ({nf.group(1)})" if nf else f": {text.strip()!r}"))
        info = {"mib": int(m.group(1)), "phy": m.group(2), "mhz": int(m.group(3)), "hz": int(m.group(4)),
                "steps": int(m.group(5)), "level_shifters": bool(m.group(6)),
                "emulator": int(m.group(7)) << 10 if m.group(7) else 0}
        r = REGION_RE.search(text)
        info["capacity"] = int(r.group(2)) << 10 if r else 0
        info["ready"] = "state: ready" in text
        return info

    def dump(self, addr, length, timeout=None):
        if timeout is None:
            timeout = 5.0 + length / 200.0
        ok, text = self.run(f"dump 0x{addr:08x} {length}", timeout)
        if not ok:
            raise HrError(f"dump 0x{addr:08x} {length}: {text.strip()}")
        return parse_dump(text, addr, length)

    def bist(self, addr, length, count_data, seed, burst=0, mode="", timeout=60.0):
        cmd = f"bist 0x{addr:x} {length} {'count' if count_data else 'prbs'}"
        if mode:
            cmd += f" {mode}"
        cmd += f" {burst} {seed}"
        ok, text = self.run(cmd, timeout)
        res = parse_bist(text)
        if res is None:
            raise HrError(f"bist: no result in {text.strip()!r}")
        res["ok"] = ok
        res["text"] = text.strip()
        return res

    def fill(self, addr, length, seed, timeout=60.0):
        ok, text = self.run(f"fill 0x{addr:x} {length} {seed}", timeout)
        if not FILL_RE.search(text):
            raise HrError(f"fill: no result in {text.strip()!r}")
        return ok, text.strip()


def bring_up(board, timeout=180.0):
    """init (enable, reset, calibration, configuration) when not ready."""
    info = board.info()
    if not info["ready"]:
        ok, text = board.run("init", timeout)
        if not ok:
            raise HrError(f"init failed: {text.strip()}")
        info = board.info()
    if not info["capacity"]:
        raise HrError("size of the test region unknown")
    return info


def verify(board, count, seed, region=0x100000, max_bytes=2048, progress=True):
    """Random BIST / fill cases, each read back with dump and compared with the
    host models. Returns (failed cases, list of errors)."""
    info = bring_up(board)
    if info["capacity"] <= region:
        region = info["capacity"] // 2
    size = min(info["capacity"] - region, 1 << 20)
    if size < max_bytes:
        raise HrError(f"region 0x{region:x} too close to the end of the {info['capacity']} bytes tested")
    rnd = random.Random(seed)
    errors, failed, t0 = [], 0, time.monotonic()
    for case in range(count):
        before = len(errors)
        if rnd.random() < 0.6:
            words = rnd.randint(1, max_bytes // 2)
            addr = region + rnd.randrange((size - 2 * words) // 2 + 1) * 2
            addr &= ~3                                   # the app takes multiples of 4
            words &= ~1
            words = max(words, 2)
            count_data = rnd.random() < 0.5
            s = rnd.getrandbits(32)
            burst = rnd.choice([0, 1, 7, 16, 64])
            what = (f"case {case}: bist 0x{addr:x} {2 * words} {'count' if count_data else 'prbs'} w "
                    f"{burst} {s}")
            res = board.bist(addr, 2 * words, count_data, s, burst, "w")
            if not res["ok"]:
                errors.append(f"{what}: {res['text']}")
            want = bist_bytes(count_data, s, addr // 2, words)
        else:
            nwords = rnd.randint(1, max_bytes // 4)
            addr = region + rnd.randrange((size - 4 * nwords) // 4 + 1) * 4
            s = rnd.getrandbits(32)
            what = f"case {case}: fill 0x{addr:x} {4 * nwords} {s}"
            ok, text = board.fill(addr, 4 * nwords, s)
            if not ok:
                errors.append(f"{what}: {text}")
            want = fill_bytes(s, nwords)
        got = board.dump(WINDOW + addr, len(want))
        if got != want:
            errors.append(f"{what}: dump differs, {first_difference(got, want, WINDOW + addr)}")
        failed += len(errors) > before
        if progress:
            print(f"\r  {case + 1}/{count} cases, {failed} failed, "
                  f"{time.monotonic() - t0:.1f} s", end="", flush=True)
    if progress:
        print()
    return failed, errors


# --------------------------------------------------------------------- CLI
def main(argv=None, open_serial=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("-p", "--port", required=True, help="serial port")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="current baud rate (115200)")
    ap.add_argument("--fast", type=int, metavar="BAUD", help="switch to this baud rate first")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("test", help="run the self-test of the app")
    p.add_argument("--quick", action="store_true", help="small regions (as in the simulation)")
    p.add_argument("--seed", type=int, default=1)
    p = sub.add_parser("cal", help="init (if needed), read calibration")
    p.add_argument("--step", type=int, default=4, help="phase sweep step (4)")
    p.add_argument("--write", action="store_true", help="then the write phase scan (card)")
    p.add_argument("--init", action="store_true", help="init again first")
    p = sub.add_parser("eye", help="eye maps only (the phase is restored and verified)")
    p.add_argument("--step", type=int, default=4)
    sub.add_parser("bench", help="CPU and BIST bandwidth")
    p = sub.add_parser("verify", help="BIST / fill with host seeds, dumps compared here")
    p.add_argument("-n", "--count", type=int, default=20, help="cases (20)")
    p.add_argument("--seed", type=int, default=None)
    p.add_argument("--region", type=lambda v: int(v, 0), default=0x100000,
                   help="window offset of the test region (0x100000, up to 1 MiB long)")
    p.add_argument("--max-bytes", type=int, default=2048, help="largest case (2048 bytes)")
    p = sub.add_parser("cmd", help="run shell commands")
    p.add_argument("commands", nargs="+")
    args = ap.parse_args(argv)

    if open_serial is None:
        if serial is None:
            sys.exit("error: pyserial is required (pip install -r requirements.txt)")
        open_serial = lambda: serial.Serial(args.port, args.baud, timeout=0.1)  # noqa: E731
    board = HrBoard(open_serial())
    try:
        board.sync()
        if args.fast:
            board.fast(args.fast)
        if args.cmd == "test":
            line = f"test {'quick' if args.quick else 'full'} {args.seed}"
            print(f"> {line}")
            ok, text = board.run(line, timeout=300.0 if args.quick else 1200.0)
            print(text)
            checks, passed, total = parse_test(text)
            if total is None:
                print("test: no result line")
                return 1
            failed = [f"[{n}] {name}" for n, name, good in checks if not good]
            for f in failed:
                print("FAILED", f)
            return 0 if ok and passed == total and not failed else 1
        if args.cmd == "cal":
            if args.init:
                ok, text = board.run("init", timeout=180.0)
                print(text)
                if not ok:
                    return 1
            ok, text = board.run(f"cal {args.step}", timeout=240.0)
            print(text)
            cal = parse_cal(text)
            if cal is None or not ok:
                return 1
            print("cal: phase {phase} width {width} RD_DLY {rd_dly}".format(**cal))
            if args.write:
                okw, text = board.run("calw", timeout=240.0)
                print(text)
                if not okw or not WCAL_RE.search(text):
                    return 1
            return 0
        if args.cmd == "eye":
            ok, text = board.run(f"eye {args.step}", timeout=240.0)
            print(text)
            for title, eye in parse_eyes(text).items():
                good = sum(c == "#" for c in eye)
                print(f"{title}: {good} of {len(eye)} points good")
            return 0 if ok else 1
        if args.cmd == "bench":
            ok, text = board.run("bench", timeout=120.0)
            print(text)
            return 0 if ok else 1
        if args.cmd == "verify":
            seed = args.seed if args.seed is not None else random.randrange(1 << 30)
            print(f"verify: {args.count} cases, seed {seed}")
            failed, errors = verify(board, args.count, seed, args.region, args.max_bytes)
            for e in errors:
                print(e)
            print(f"verify: {'FAIL' if failed else 'PASS'} ({args.count - failed}/{args.count} cases)")
            return 1 if failed else 0
        if args.cmd == "cmd":
            status = 0
            for line in args.commands:
                print(f"> {line}")
                ok, text = board.run(line, timeout=300.0)
                print(text)
                print("ok" if ok else "error")
                status |= 0 if ok else 1
            return status
    except HrError as e:
        print(f"error: {e}")
        return 1
    finally:
        board.ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
