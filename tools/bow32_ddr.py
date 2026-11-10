#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bow32 DDR tool - drives the DDR2/DDR3 test (sw/apps/ddr on UART0) of the
bow_ddr IP (LiteDRAM controller + Bow32 PHY): self-test, calibration, eye
map, bandwidth, and a data check with seeds chosen here and the memory read
back with `dump`.

Examples:
  bow32_ddr.py -p /dev/ttyACM0 test                 self-test of the app (`test`)
  bow32_ddr.py -p /dev/ttyACM0 test --quick --seed 7
  bow32_ddr.py -p /dev/ttyACM0 cal --step 2         read calibration, eye map
  bow32_ddr.py -p /dev/ttyACM0 cal --write          + write phase scan (not on the emulator)
  bow32_ddr.py -p /dev/ttyACM0 eye --step 1         eye map only
  bow32_ddr.py -p /dev/ttyACM0 bench                CPU and BIST bandwidth
  bow32_ddr.py -p /dev/ttyACM0 --fast 921600 verify -n 40
  bow32_ddr.py -p /dev/ttyACM0 cmd stat "phase 120" "cap 0 0 0"

`verify` initialises and calibrates the memory if needed, then runs random
cases: `bist ADDR LEN prbs|count` (the LiteDRAM BIST writes and checks
LEN bytes) or `memtest ADDR LEN SEED` (the CPU writes and checks through the
window). Each case must report 0 errors, then `dump` reads the range back
and every byte must equal the data computed here: bist_bytes() is the Python
twin of the data generator of LiteDRAM's BIST (litedram/frontend/bist.py,
checked against its Migen simulation), memtest_bytes() the xorshift fill of
the app. Exit status 0 when everything matches.

Needs pyserial.
"""

import argparse
import random
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bow32_cam import Camera, CameraError, PROMPT, serial  # noqa: E402

M31 = 0x7FFFFFFF
M32 = 0xFFFFFFFF
WINDOW = 0x80000000

BANNER_RE = re.compile(r"^ddr: Bow32 DDR([23]) x(\d+) \(LiteDRAM controller\), PHY (\w+), (\d+) MHz "
                       r"\((\d+) Hz\), (\d+) phase steps", re.M)
NOT_FOUND_RE = re.compile(r"^ddr: IP not found \((.*)\)$", re.M)
REGION_RE = re.compile(r"memory: (\d+) MiB at [0-9a-f]{8}, test region (\d+) KiB")
BIST_RE = re.compile(r"^bist: addr ([0-9a-f]{8}) len (\d+) data (prbs|count): done (\d) errors (\d+) "
                     r"wticks (\d+) rticks (\d+)", re.M)
MEMTEST_RE = re.compile(r"^memtest: ([0-9a-f]{8}) \+ (\d+) bytes seed (\d+): (\d+) words, errors (\d+)", re.M)
DUMP_RE = re.compile(r"^([0-9a-f]{8}):((?: [0-9a-f]{2})+)$")
CAL_RE = re.compile(r"^ddr: read phase (-?\d+) width (\d+) p (\d+) RD_DLY (\d+) SLIP (\d+), "
                    r"BIST (\d+) errors", re.M)
WCAL_RE = re.compile(r"^ddr: write phase (-?\d+) width (\d+)$", re.M)
EYE_RE = re.compile(r"^ddr: (write )?eye \|(.*?)\| (.*)$", re.M | re.S)
CHECK_RE = re.compile(r"^  \[\s*(\d+)\] (.*?)\s+(ok|FAIL)$", re.M)
RESULT_RE = re.compile(r"^ddr: (PASS|FAIL) \((\d+)/(\d+)\)$", re.M)
VERIFY_RE = re.compile(r"^verify: (PASS|FAIL) \((\d+)/(\d+) cases\)$", re.M)


class DdrError(Exception):
    pass


# ---------------------------------------------------------------- data models
def xs32(x):
    """xorshift32 (13, 17, 5) as in the app (memtest fill)."""
    x ^= (x << 13) & M32
    x ^= x >> 17
    x ^= (x << 5) & M32
    return x


def prbs31(s):
    """Generator(31, n_state=31, taps=[27, 30]) of LiteDRAM's BIST: 31
    shifts per word, new bit = !(s[27] ^ s[30]) into bit 0."""
    for _ in range(31):
        s = ((s << 1) | (~((s >> 27) ^ (s >> 30)) & 1)) & M31
    return s


def bist_words(random_data, count):
    """The 31 bit values o_k of words k = 0 .. count-1 of a BIST run: PRBS31
    state after k + 1 steps from 0, or the counter k."""
    out, o = [], prbs31(0) if random_data else 0
    for k in range(count):
        out.append(o)
        o = prbs31(o) if random_data else (k + 1) & M31
    return out


def word_bytes(o, wbytes):
    """Native word of the BIST (wbytes = 8 for x8, 16 for x16): o repeated
    from bit 0 up (bit j = o[j mod 31]), little endian."""
    v = 0
    for j in range(8 * wbytes):
        v |= ((o >> (j % 31)) & 1) << j
    return v.to_bytes(wbytes, "little")


def bist_bytes(random_data, length, wbytes):
    """Memory content after `bist ADDR LEN` from ADDR (LEN a multiple of wbytes)."""
    return b"".join(word_bytes(o, wbytes) for o in bist_words(random_data, length // wbytes))


def memtest_bytes(seed, words):
    """Content left by `memtest ADDR LEN SEED`: x = seed (1 if 0), word i =
    x after i + 1 xorshift32 steps, little endian."""
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
    """Bytes of a `dump` output; DdrError when lines are missing or out of order."""
    data = bytearray()
    for line in text.split("\n"):
        m = DUMP_RE.match(line.strip())
        if not m:
            continue
        if int(m.group(1), 16) != addr + len(data):
            raise DdrError(f"dump: line {m.group(1)} out of order (expected {addr + len(data):08x})")
        data += bytes.fromhex(m.group(2).replace(" ", ""))
    if len(data) != length:
        raise DdrError(f"dump: {len(data)} of {length} bytes")
    return bytes(data)


def parse_test(text):
    """Checks of a `test` run: (list of (n, name, ok), passed, total) or None."""
    checks = [(int(m.group(1)), m.group(2), m.group(3) == "ok") for m in CHECK_RE.finditer(text)]
    m = RESULT_RE.search(text)
    if not m:
        return checks, None, None
    return checks, int(m.group(2)), int(m.group(3))


def parse_cal(text):
    m = CAL_RE.search(text)
    if not m:
        return None
    keys = ("phase", "width", "p", "rd_dly", "rd_slip", "bist_errors")
    return dict(zip(keys, (int(v) for v in m.groups())))


def parse_eye(text, write=False):
    """Eye map (one character per point, continuation lines joined) and the
    result text of the first `ddr: eye` (`ddr: write eye`) block."""
    for m in EYE_RE.finditer(text):
        if bool(m.group(1)) == write:
            return "".join(part.strip() for part in m.group(2).split("\n")), m.group(3).split("\n")[0]
    return None, None


def parse_bist(text):
    m = BIST_RE.search(text)
    if not m:
        return None
    g = m.groups()
    return {"addr": int(g[0], 16), "len": int(g[1]), "random": g[2] == "prbs", "done": int(g[3]),
            "errors": int(g[4]), "wticks": int(g[5]), "rticks": int(g[6])}


# ------------------------------------------------------------------- board
class DdrBoard(Camera):
    """Shell of sw/apps/ddr (prompt / command helpers of bow32_cam)."""

    # The app prints the prompt at the start of a line, after "ok" / "error":
    # a "> " inside an output line is text, not the end of the command.
    LINE_PROMPT = b"\n" + PROMPT

    def sync(self, timeout=2.0):
        """USB serial adapters deliver late bytes: drain, then two round trips."""
        super().sync(timeout)
        end = time.monotonic() + 0.2
        while time.monotonic() < end:
            self.ser.read(getattr(self.ser, "in_waiting", 0) or 1)
        super().sync(timeout)

    def run(self, line, timeout=5.0):
        """Run one command: (ok, output) - 'error' does not raise."""
        self.send_line(line)  # paced by the echo (bow32_cam.Camera.send_line)
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
        """Banner fields (ddr, dq, phy, mhz, hz, steps), the DRAM size and the
        size of the region the tests may use, in bytes. DdrError when the IP
        is missing."""
        ok, text = self.run("info")
        m = BANNER_RE.search(text)
        if not m:
            nf = NOT_FOUND_RE.search(text)
            raise DdrError("no DDR controller" + (f" ({nf.group(1)})" if nf else f": {text.strip()!r}"))
        info = dict(zip(("ddr", "dq", "phy", "mhz", "hz", "steps"),
                        (int(m.group(1)), int(m.group(2)), m.group(3), int(m.group(4)), int(m.group(5)),
                         int(m.group(6)))))
        r = REGION_RE.search(text)
        info["memory"] = int(r.group(1)) << 20 if r else 0
        info["capacity"] = int(r.group(2)) << 10 if r else 0
        info["calibrated"] = "calibration:" in text
        info["ready"] = "state: ready" in text
        return info

    def dump(self, addr, length, timeout=None):
        if timeout is None:
            timeout = 5.0 + length / 200.0
        ok, text = self.run(f"dump 0x{addr:08x} {length}", timeout)
        if not ok:
            raise DdrError(f"dump 0x{addr:08x} {length}: {text.strip()}")
        return parse_dump(text, addr, length)

    def bist(self, addr, length, random_data, timeout=60.0):
        ok, text = self.run(f"bist 0x{addr:x} {length} {'prbs' if random_data else 'count'}", timeout)
        res = parse_bist(text)
        if res is None:
            raise DdrError(f"bist: no result in {text.strip()!r}")
        res["ok"] = ok
        res["text"] = text.strip()
        return res

    def memtest(self, addr, length, seed, timeout=60.0):
        ok, text = self.run(f"memtest 0x{addr:x} {length} {seed}", timeout)
        m = MEMTEST_RE.search(text)
        if not m:
            raise DdrError(f"memtest: no result in {text.strip()!r}")
        res = dict(zip(("addr", "len", "seed", "words", "errors"),
                       (int(v, 16) if k == 0 else int(v) for k, v in enumerate(m.groups()))))
        res["ok"] = ok
        res["text"] = text.strip()
        return res


def bring_up(board, step=4, timeout=120.0):
    """Init + read calibration (and hand-over) when the memory is not ready."""
    info = board.info()
    if not info["ready"]:
        ok, text = board.run(f"cal {step}", timeout)
        if not ok:
            raise DdrError(f"calibration failed: {text.strip()}")
        info = board.info()
    if not info["capacity"]:
        raise DdrError("size of the test region unknown")
    return info


def verify(board, count, seed, region=0x100000, max_bytes=2048, progress=True):
    """Random BIST / memtest cases, each read back with dump and compared
    with the host models. Returns (failed cases, list of errors)."""
    info = bring_up(board)
    wbytes = info["dq"]                   # native word: 8 beats of DQ bits
    size = min(info["capacity"] - region, 1 << 20)
    if size < max_bytes:
        raise DdrError(f"region 0x{region:x} too close to the end of the {info['capacity']} bytes tested")
    rnd = random.Random(seed)
    errors, failed, t0 = [], 0, time.monotonic()
    for case in range(count):
        before = len(errors)
        if rnd.random() < 0.7:
            words = rnd.randint(1, max_bytes // wbytes)
            addr = region + rnd.randrange((size - words * wbytes) // wbytes + 1) * wbytes
            random_data = rnd.random() < 0.5
            what = f"case {case}: bist 0x{addr:x} {words * wbytes} {'prbs' if random_data else 'count'}"
            res = board.bist(addr, words * wbytes, random_data)
            if not res["ok"] or res["errors"] or not res["done"]:
                errors.append(f"{what}: done {res['done']} errors {res['errors']}")
            want = bist_bytes(random_data, words * wbytes, wbytes)
        else:
            nwords = rnd.randint(1, max_bytes // 4)
            addr = region + rnd.randrange((size - 4 * nwords) // 4 + 1) * 4
            s = rnd.getrandbits(32)
            what = f"case {case}: memtest 0x{addr:x} {4 * nwords} {s}"
            res = board.memtest(addr, 4 * nwords, s)
            if not res["ok"] or res["errors"]:
                errors.append(f"{what}: {res['text']}")
            want = memtest_bytes(s, nwords)
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
    ap.add_argument("-p", "--port", required=True, help="serial port, e.g. /dev/ttyACM0")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="current baud rate (115200)")
    ap.add_argument("--fast", type=int, metavar="BAUD", help="switch to this baud rate first")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("test", help="run the self-test of the app")
    p.add_argument("--quick", action="store_true", help="small regions (as in the simulation)")
    p.add_argument("--seed", type=int, default=1)
    p = sub.add_parser("cal", help="init (if needed), read calibration and hand-over")
    p.add_argument("--step", type=int, default=4, help="phase sweep step (4)")
    p.add_argument("--write", action="store_true", help="then the write phase scan (BIST)")
    p.add_argument("--init", action="store_true", help="init again first")
    p = sub.add_parser("eye", help="eye map only (phase, READY and the data are kept if the read path "
                                   "verifies again, else the window is blocked: cal again)")
    p.add_argument("--step", type=int, default=4)
    sub.add_parser("bench", help="CPU and BIST bandwidth")
    p = sub.add_parser("verify", help="BIST / memtest with host seeds, dumps compared here")
    p.add_argument("-n", "--count", type=int, default=20, help="cases (20)")
    p.add_argument("--seed", type=int, default=None)
    p.add_argument("--region", type=lambda v: int(v, 0), default=0x100000,
                   help="window offset of the test region (0x100000, 1 MiB long)")
    p.add_argument("--max-bytes", type=int, default=2048, help="largest case (2048 bytes)")
    p = sub.add_parser("cmd", help="run shell commands")
    p.add_argument("commands", nargs="+")
    args = ap.parse_args(argv)

    if open_serial is None:
        if serial is None:
            sys.exit("error: pyserial is required (pip install -r requirements.txt)")
        open_serial = lambda: serial.Serial(args.port, args.baud, timeout=0.1)  # noqa: E731
    board = DdrBoard(open_serial())
    try:
        board.sync()
        if args.fast:
            board.fast(args.fast)
        if args.cmd == "test":
            line = f"test {'quick' if args.quick else 'full'} {args.seed}"
            print(f"> {line}")
            ok, text = board.run(line, timeout=120.0 if args.quick else 900.0)
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
                ok, text = board.run("init", timeout=10.0)
                print(text)
                if not ok:
                    return 1
            ok, text = board.run(f"cal {args.step}{' --write' if args.write else ''}", timeout=240.0)
            print(text)
            cal = parse_cal(text)
            if cal is None:
                return 1
            print("cal: phase {phase} width {width} RD_DLY {rd_dly} SLIP {rd_slip}".format(**cal))
            if args.write and not WCAL_RE.search(text):
                return 1
            return 0 if ok else 1
        if args.cmd == "eye":
            ok, text = board.run(f"eye {args.step}", timeout=120.0)
            print(text)
            eye, result = parse_eye(text)
            if eye is not None:
                good = sum(c != "." for c in eye)
                print(f"eye: {good} of {len(eye)} points show the pattern; {result}")
            return 0 if ok else 1
        if args.cmd == "bench":
            ok, text = board.run("bench", timeout=60.0)
            print(text)
            return 0 if ok else 1
        if args.cmd == "verify":
            seed = args.seed if args.seed is not None else int(time.time())
            print(f"verify: {args.count} cases, seed {seed}")
            failed, errors = verify(board, args.count, seed, args.region, args.max_bytes,
                                    progress=sys.stdout.isatty())
            for e in errors[:20]:
                print("ERROR", e)
            print(f"verify: {'FAIL' if errors else 'PASS'} ({args.count - failed}/{args.count} cases "
                  "equal the host model)")
            return 1 if errors else 0
        status = 0
        for c in args.commands:
            print(f"> {c}")
            ok, text = board.run(c, timeout=120.0)
            print(text)
            print("ok" if ok else "error")
            status |= 0 if ok else 1
        return status
    except (CameraError, DdrError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
