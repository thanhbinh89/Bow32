#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bow32 MKV tool - checks the MKV block cipher IP on the board (sw/apps/mkv
on UART0) against the reference model tools/mkv/mkv_model.py.

Examples:
  bow32_mkv.py -p /dev/ttyACM0 test              self-test of the app (`test`)
  bow32_mkv.py -p /dev/ttyACM0 kat               Annex A on the IP vs the values of the standard
  bow32_mkv.py -p /dev/ttyACM0 verify -n 120     random keys / blocks: IP vs model
  bow32_mkv.py -p /dev/ttyACM0 enc 256 <key> <block>
  bow32_mkv.py -p /dev/ttyACM0 bench

`verify` goes round the six versions (MKV-128/128 ... MKV-256/512); for each
case a random key (`key`), a random block encrypted (`enc`) and decrypted
back (`dec`), and a random block decrypted. Every result must equal the
model. Exit status 0 when everything matches.

Needs pyserial.
"""

import argparse
import random
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "mkv"))
from bow32_cam import Camera, CameraError, serial  # noqa: E402
import mkv_model  # noqa: E402

OUT_RE = re.compile(r"^out ([0-9a-f]+)$", re.M)
KAT_RE = re.compile(r"^(A\.\d\.\d) MKV-(\d+)/(\d+) R=(\d+)\n  key ([0-9a-f]+)\n  pt  ([0-9a-f]+)\n"
                    r"  ct  ([0-9a-f]+)  (ok|FAIL)$", re.M)
VERSIONS = sorted(mkv_model.VERSIONS)


class MkvBoard(Camera):
    """Shell of sw/apps/mkv (the prompt / command helpers of bow32_cam)."""

    def sync(self, timeout=2.0):
        """USB serial adapters deliver late bytes: drain, then two round trips."""
        super().sync(timeout)
        end = time.monotonic() + 0.2
        while time.monotonic() < end:
            self.ser.read(getattr(self.ser, "in_waiting", 0) or 1)
        super().sync(timeout)

    def set_key(self, block_bits, key):
        return self.command(f"key {block_bits} {key.hex()}")

    def crypt(self, op, block):
        text = self.command(f"{op} {block.hex()}")
        m = OUT_RE.search(text)
        if not m:
            raise CameraError(f"no result in {text!r}")
        return bytes.fromhex(m.group(1))


def verify(board, count, seed, progress=True):
    """Random keys / blocks through the board, compared with the model.
    Returns (operations, list of errors)."""
    rnd = random.Random(seed)
    errors, ops = [], 0
    per_version = {v: 0 for v in VERSIONS}
    t0 = time.monotonic()
    for i in range(count):
        l, k = VERSIONS[i % len(VERSIONS)]
        key = bytes(rnd.randrange(256) for _ in range(k // 8))
        pt = bytes(rnd.randrange(256) for _ in range(l // 8))
        blk = bytes(rnd.randrange(256) for _ in range(l // 8))
        h = mkv_model.key_schedule(key, l)
        board.set_key(l, key)
        ct = board.crypt("enc", pt)
        back = board.crypt("dec", ct)
        dec = board.crypt("dec", blk)
        ops += 3
        name = f"MKV-{l}/{k}"
        if ct != mkv_model.encrypt(key, pt, h=h):
            errors.append(f"case {i} {name}: enc {pt.hex()} -> {ct.hex()}, model "
                          f"{mkv_model.encrypt(key, pt, h=h).hex()} (key {key.hex()})")
        if back != pt:
            errors.append(f"case {i} {name}: dec(enc(x)) = {back.hex()}, x = {pt.hex()}")
        if dec != mkv_model.decrypt(key, blk, h=h):
            errors.append(f"case {i} {name}: dec {blk.hex()} -> {dec.hex()}, model "
                          f"{mkv_model.decrypt(key, blk, h=h).hex()} (key {key.hex()})")
        per_version[(l, k)] += 1
        if progress:
            print(f"\r  {i + 1}/{count} cases, {len(errors)} errors, "
                  f"{time.monotonic() - t0:.1f} s", end="", flush=True)
    if progress:
        print()
    return ops, per_version, errors


def check_kat(text):
    """`kat` output vs Annex A of TCVN 14263:2024. Returns a list of errors."""
    errors = []
    found = {m.group(1): m for m in KAT_RE.finditer(text)}
    for case in mkv_model.load_vectors():
        m = found.get(case["section"])
        if not m:
            errors.append(f"{case['section']}: missing in the output")
            continue
        got = (int(m.group(2)), int(m.group(3)), int(m.group(4)), m.group(5), m.group(6), m.group(7))
        want = (case["block_bits"], case["key_bits"], case["rounds"], case["key"], case["plaintext"],
                case["ciphertext"])
        if got != want or m.group(8) != "ok":
            errors.append(f"{case['section']}: board {got[5]} ({m.group(8)}), standard {want[5]}")
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("-p", "--port", required=True, help="serial port, e.g. /dev/ttyACM0")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="current baud rate (115200)")
    ap.add_argument("--fast", type=int, metavar="BAUD", help="switch to this baud rate first")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("test", help="run the self-test of the app")
    p.add_argument("--quick", action="store_true")
    p.add_argument("--seed", type=int, default=1)
    sub.add_parser("kat", help="Annex A on the IP, compared with the standard")
    p = sub.add_parser("verify", help="random keys / blocks: IP vs model")
    p.add_argument("-n", "--count", type=int, default=60, help="cases (each key + 3 blocks)")
    p.add_argument("--seed", type=int, default=None)
    for name in ("enc", "dec"):
        p = sub.add_parser(name, help=f"{name}rypt one block on the board")
        p.add_argument("l", type=int, choices=(128, 256))
        p.add_argument("key")
        p.add_argument("block")
    sub.add_parser("bench", help="cycles of the IP and of the software")
    args = ap.parse_args()

    if serial is None:
        sys.exit("error: pyserial is required (pip install -r requirements.txt)")
    board = MkvBoard(serial.Serial(args.port, args.baud, timeout=0.1))
    try:
        board.sync()
        if args.fast:
            board.fast(args.fast)
        if args.cmd == "test":
            line = f"test{' quick' if args.quick else ''} {args.seed}"
            print(f"> {line}")
            try:
                text = board.command(line, timeout=300.0)
            except CameraError as e:
                print(e)
                return 1
            print(text)
            return 0 if "mkv: PASS" in text else 1
        if args.cmd == "kat":
            text = board.command("kat", timeout=30.0)
            print(text)
            errors = check_kat(text)
            for e in errors:
                print("ERROR", e)
            print("kat: " + ("FAIL" if errors else "PASS (6 versions, ciphertexts equal Annex A)"))
            return 1 if errors else 0
        if args.cmd == "verify":
            seed = args.seed if args.seed is not None else int(time.time())
            print(f"verify: {args.count} cases, seed {seed}")
            ops, per_version, errors = verify(board, args.count, seed, progress=sys.stdout.isatty())
            for e in errors[:20]:
                print("ERROR", e)
            for (l, k), n in per_version.items():
                print(f"  MKV-{l}/{k}: {n} keys, {3 * n} blocks")
            print(f"verify: {'FAIL' if errors else 'PASS'} ({ops - len(errors)}/{ops} blocks equal the model)")
            return 1 if errors else 0
        if args.cmd in ("enc", "dec"):
            key, block = bytes.fromhex(args.key), bytes.fromhex(args.block)
            board.set_key(args.l, key)
            out = board.crypt(args.cmd, block)
            model = mkv_model.encrypt(key, block) if args.cmd == "enc" else mkv_model.decrypt(key, block)
            print(f"board {out.hex()}\nmodel {model.hex()}  {'ok' if out == model else 'MISMATCH'}")
            return 0 if out == model else 1
        print(board.command("bench", timeout=60.0))
        return 0
    except CameraError as e:
        sys.exit(f"error: {e}")


if __name__ == "__main__":
    sys.exit(main())
