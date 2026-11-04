#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Reference model of the MKV block cipher for the Bow32 MKV IP (hw/ip/mkv).

MKV is the block cipher of the draft Vietnamese national standard
"TCVN XXXX:2024 Cong nghe thong tin - Cac ky thuat an toan - Thuat toan mat
ma - Ma khoi MKV" (docs/ref/Du-thao-TCVN-XXXX2024.pdf). Six versions:

    MKV-128  block 128 bit, key 128 / 192 / 256 bit, R = 6 / 7 / 8 rounds
    MKV-256  block 256 bit, key 256 / 384 / 512 bit, R = 6 / 7 / 8 rounds

Round function (FLC-SDS structure, state X = x0 || x1 || x2 || x3, every
sub-state x_i is a column of t = l / 32 bytes):

    F(K0 || K1, X) = XWords(SubCells(MixWords(SubCells(X ^ K0)) ^ K1))
    C = F(K_{R-1}, ... F(K_0, P)) ^ K_post

This model follows the text of the draft and its test vectors (Annex A,
tools/mkv/tcvn_mkv_vectors.json, extracted from the PDF by
extract_vectors.py). Where the two disagree, the test vectors win (they are
what any other implementation of the standard produces):

  * Erratum 1 - matrix M4 of MixWords (MKV-128), clause 4.2.2.2: the text
    prints 0x0C at (row 2, col 3) and (row 3, col 0). Every MKV-128 vector
    needs 0x0D there, and the printed inverse M4^-1 is the inverse of the
    matrix with 0x0D (with 0x0C, M4 * M4^-1 != I).
  * Erratum 2 - key schedule constants, clause 4.6: the text writes
    Const^Left_i = <2i>_2l, Const^Right_i = <2i+1>_2l and uses Const_{i-1}
    in update i. The vectors need, for update i = 1..R:
        K_i^Left  = F(0, F(c(2i),     K_{i-1}^Right))
        K_i^Right = K_i^Left ^ F(0, F(c(2i - 1), K_{i-1}^Left))
    where c(v) = <v>_l || 0^l: the l-bit big-endian value v as K0 (the
    first key addition), K1 = 0.

Byte order: a block / key is a byte string in the order of the standard
(the hex strings of Annex A). Sub-state x_i = bytes [i*t, (i+1)*t), byte j
of it is the j-th entry of the column vector of MixWords.

Library use:
    ct = encrypt(key, pt)                # key 16..64 bytes, pt 16 or 32 bytes
    pt = decrypt(key, ct)
    h = key_schedule(key, len(pt) * 8)   # half-round keys, see below

Command line:
    mkv_model.py selftest                       model vs Annex A (all states)
    mkv_model.py kat                            print the Annex A vectors
    mkv_model.py enc|dec <l> <key> <block>      one block (hex)
    mkv_model.py gen DIR [--seed N --count N]   test case for hw/ip/mkv/dv
    mkv_model.py check DIR                      check the testbench results
    mkv_model.py tables [--check]               tables of RTL and C, C vectors
"""

import argparse
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
VECTORS_JSON = Path(__file__).resolve().parent / "tcvn_mkv_vectors.json"

# ============================================================== constants
# GF(2^8) of the standard: x^8 + x^5 + x^3 + x + 1
POLY = 0x12B

# Table 1 of the standard: S-box s, one row per high nibble of the input.
# The inverse (Table 2) is computed; both are checked against the tables
# extracted from the PDF (tcvn_mkv_vectors.json).
SBOX = bytes.fromhex("".join((
    "011191e1d1b17161f121c151a1413181",
    "0010e392b5d477668938ab4acd5c2ffe",
    "085f3eb01cc283dde8f64779952baa64",
    "0f48d029a31af2bb65cce43d577e869f",
    "0c2af41f5b90eec5366d7388bca749d2",
    "0a3c1885e04d99a4b35edac772ff6b26",
    "0676cfa84e596017dc9b32f52384edba",
    "07672d3bfa8c167054a298beefd9c345",
    "0ea9625a27bf349cfdd58ee61b4378c0",
    "03b287c49d6e4bf87ae92cafd6155033",
    "0dfb56ec3f75b8421e24c993806ad7ad",
    "04e5b97d82a6ca2e97136fdb4430fc58",
    "0b8d9a467428df53cbb7f06caee23519",
    "05947bdec6f3ac394f8a552068bd12e7",
    "02d3a5f769eb5d8f2240b6143ac89e7c",
    "09ce4c63d83725eaa07f1d52f996b48b")))
SBOX_INV = bytes(SBOX.index(x) for x in range(256))

# MixWords matrices (rows), clause 4.2.2.2. M4 with erratum 1 corrected.
M4 = ((0x01, 0x02, 0x01, 0x03),
      (0x03, 0x07, 0x01, 0x04),
      (0x04, 0x0B, 0x03, 0x0D),
      (0x0D, 0x1E, 0x06, 0x14))
M4_PRINTED = ((0x01, 0x02, 0x01, 0x03),      # as printed in the draft
              (0x03, 0x07, 0x01, 0x04),
              (0x04, 0x0B, 0x03, 0x0C),
              (0x0C, 0x1E, 0x06, 0x14))
M4_INV = ((0x14, 0x06, 0x18, 0x0B),
          (0x0B, 0x02, 0x0D, 0x05),
          (0x05, 0x01, 0x07, 0x02),
          (0x02, 0x01, 0x03, 0x01))
M8 = ((0x01, 0x04, 0xDB, 0x0C, 0x14, 0x0C, 0xDB, 0x04),
      (0x04, 0x11, 0x15, 0xEB, 0x5C, 0x24, 0x1D, 0xCB),
      (0xCB, 0x55, 0x38, 0xE6, 0xD5, 0xAF, 0x0D, 0x4C),
      (0x4C, 0xD0, 0x5D, 0x15, 0x91, 0xF8, 0xA7, 0x16),
      (0x16, 0x14, 0x18, 0xB5, 0x06, 0x79, 0x30, 0xFF),
      (0xFF, 0x97, 0xE0, 0xB0, 0x66, 0xAE, 0x8D, 0xB1),
      (0xB1, 0x6D, 0xF6, 0x7D, 0x3C, 0xFB, 0xCF, 0x1F),
      (0x1F, 0xCD, 0x5C, 0x72, 0xDA, 0xB8, 0xCA, 0xB3))
M8_INV = ((0xB3, 0xCA, 0xB8, 0xDA, 0x72, 0x5C, 0xCD, 0x1F),
          (0x1F, 0xCF, 0xFB, 0x3C, 0x7D, 0xF6, 0x6D, 0xB1),
          (0xB1, 0x8D, 0xAE, 0x66, 0xB0, 0xE0, 0x97, 0xFF),
          (0xFF, 0x30, 0x79, 0x06, 0xB5, 0x18, 0x14, 0x16),
          (0x16, 0xA7, 0xF8, 0x91, 0x15, 0x5D, 0xD0, 0x4C),
          (0x4C, 0x0D, 0xAF, 0xD5, 0xE6, 0x38, 0x55, 0xCB),
          (0xCB, 0x1D, 0x24, 0x5C, 0xEB, 0x15, 0x11, 0x04),
          (0x04, 0xDB, 0x0C, 0x14, 0x0C, 0xDB, 0x04, 0x01))

# (block bits, key bits) -> rounds R, Table 1 of the standard
VERSIONS = {(128, 128): 6, (128, 192): 7, (128, 256): 8,
            (256, 256): 6, (256, 384): 7, (256, 512): 8}


# ============================================================ primitives
def gmul(a, b):
    """Product in GF(2^8) / POLY."""
    r = 0
    while b:
        if b & 1:
            r ^= a
        a <<= 1
        if a & 0x100:
            a ^= POLY
        b >>= 1
    return r


def matmul(a, b):
    n = len(a)
    return tuple(tuple(_dot(a[i], [b[k][j] for k in range(n)]) for j in range(n)) for i in range(n))


def _dot(row, col):
    v = 0
    for m, x in zip(row, col):
        v ^= gmul(m, x)
    return v


def xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


def sub_cells(x):
    return bytes(SBOX[b] for b in x)


def inv_sub_cells(x):
    return bytes(SBOX_INV[b] for b in x)


def _mix(x, matrix):
    t = len(matrix)
    out = bytearray()
    for c in range(4):
        col = x[c * t:(c + 1) * t]
        out += bytes(_dot(row, col) for row in matrix)
    return bytes(out)


def mix_words(x):
    return _mix(x, M8 if len(x) == 32 else M4)


def inv_mix_words(x):
    return _mix(x, M8_INV if len(x) == 32 else M4_INV)


def x_words(x):
    """y_i = XOR of the three other sub-states (an involution)."""
    t = len(x) // 4
    cols = [x[c * t:(c + 1) * t] for c in range(4)]
    total = xor(xor(cols[0], cols[1]), xor(cols[2], cols[3]))
    return b"".join(xor(total, col) for col in cols)


def round_f(k, x, trace=None):
    """F_l(K0 || K1, X). trace: list that receives the 6 steps of Annex A."""
    n = len(x)
    s1 = xor(x, k[:n])
    s2 = sub_cells(s1)
    s3 = mix_words(s2)
    s4 = xor(s3, k[n:])
    s5 = sub_cells(s4)
    s6 = x_words(s5)
    if trace is not None:
        trace.append([s1, s2, s3, s4, s5, s6])
    return s6


def inv_round_f(k, x):
    n = len(x)
    return xor(inv_sub_cells(inv_mix_words(xor(inv_sub_cells(x_words(x)), k[n:]))), k[:n])


# ========================================================== key schedule
def rounds_for(block_bits, key_bits):
    try:
        return VERSIONS[(block_bits, key_bits)]
    except KeyError:
        raise ValueError(f"no MKV-{block_bits} version with a {key_bits} bit key") from None


def initial_key_state(key, block_bits):
    """K_0 (2l bits) from the master key, clause 4.6 step 1."""
    n = block_bits // 8
    w = n // 4
    rounds_for(block_bits, len(key) * 8)
    words = [key[i:i + w] for i in range(0, len(key), w)]
    inv = [bytes(b ^ 0xFF for b in word) for word in words]
    if len(key) == 2 * n:
        return bytes(key)
    if len(key) == n:                               # k0..k3 || ~k0..~k3
        return bytes(key) + b"".join(inv)
    return bytes(key) + inv[2] + inv[3]             # k0..k5 || ~k2 || ~k3


def schedule_constant(v, block_bits):
    """Round key of F for the key schedule constant v (erratum 2)."""
    n = block_bits // 8
    return v.to_bytes(n, "big") + bytes(n)


def update_ks(kl, kr, i, block_bits):
    """UpdateKS for update i = 1..R: (K_{i-1}^L, K_{i-1}^R) -> (K_i^L, K_i^R)."""
    zero = bytes(block_bits // 4)
    new_l = round_f(zero, round_f(schedule_constant(2 * i, block_bits), kr))
    new_r = xor(new_l, round_f(zero, round_f(schedule_constant(2 * i - 1, block_bits), kl)))
    return new_l, new_r


def key_schedule(key, block_bits):
    """Half-round keys h[0..2R]: K_0^L, K_1^L, K_1^R, ..., K_R^L, K_R^R.

    Round key i is h[2i] || h[2i+1] (K_0 = K_0^L || K_1^L,
    K_i = K_i^R || K_{i+1}^L), K_post = h[2R]. This is also the order of the
    round key memory of the RTL."""
    rounds = rounds_for(block_bits, len(key) * 8)
    n = block_bits // 8
    k0 = initial_key_state(key, block_bits)
    kl, kr = k0[:n], k0[n:]
    out = [kl]
    for i in range(1, rounds + 1):
        kl, kr = update_ks(kl, kr, i, block_bits)
        out += [kl, kr]
    return out


# ============================================================ encryption
def _check(key, block):
    if len(block) not in (16, 32):
        raise ValueError("block of 16 or 32 bytes expected")
    return key_schedule(bytes(key), len(block) * 8)


def encrypt(key, pt, trace=None, h=None):
    """trace: receives the six steps of every round (Annex A layout)."""
    h = h or _check(key, pt)
    rounds = (len(h) - 1) // 2
    x = bytes(pt)
    for r in range(rounds):
        x = round_f(h[2 * r] + h[2 * r + 1], x, trace)
    return xor(x, h[2 * rounds])


def decrypt(key, ct, h=None):
    h = h or _check(key, ct)
    rounds = (len(h) - 1) // 2
    x = xor(ct, h[2 * rounds])
    for r in reversed(range(rounds)):
        x = inv_round_f(h[2 * r] + h[2 * r + 1], x)
    return x


def half_round_states(key, block, decrypt_op=False, h=None):
    """States of the RTL state register after each of the 2R + 1 steps of
    an operation. Encryption: MixWords / XWords output of every round, then
    the ciphertext. Decryption: block ^ K_post, then the same values as the
    encryption of the result, in reverse order, ending with the plaintext."""
    h = h or _check(key, block)
    rounds = (len(h) - 1) // 2
    if not decrypt_op:
        trace = []
        ct = encrypt(key, block, trace, h)
        states = []
        for steps in trace:
            states += [steps[2], steps[5]]
        return states + [ct]
    pt = decrypt(key, block, h)
    states = half_round_states(key, pt, False, h)[:-1]     # MixWords / XWords outputs
    # block ^ K_post is the last XWords output; then backwards from the
    # last MixWords output to the first one, then the plaintext
    return [xor(block, h[2 * rounds])] + list(reversed(states[:-1])) + [pt]


# ======================================================= Annex A vectors
def load_spec(path=VECTORS_JSON):
    """Tables, matrices and test vectors as printed in the draft."""
    return json.loads(Path(path).read_text())


def load_vectors(path=VECTORS_JSON):
    return load_spec(path)["cases"]


def tuples(rows):
    return tuple(tuple(r) for r in rows)


def selftest(verbose=True):
    """Model vs every value of the draft (tables, matrices, Annex A).
    Returns a list of errors."""
    errors = []

    def check(cond, what):
        if not cond:
            errors.append(what)

    spec = load_spec()
    check(SBOX.hex() == spec["sbox"], "S-box differs from Table 1")
    check(SBOX_INV.hex() == spec["sbox_inv"], "inverse S-box differs from Table 2")
    check(SBOX[0x24] == 0x1C and SBOX_INV[0x82] == 0xB4, "S-box examples of 4.2.2.1")
    check(tuples(spec["m4_inv"]) == M4_INV and tuples(spec["m8"]) == M8
          and tuples(spec["m8_inv"]) == M8_INV, "matrices differ from 4.2.2.2")
    check(tuples(spec["m4"]) == M4_PRINTED, "printed M4 is not the one of erratum 1")
    ident4 = tuple(tuple(int(i == j) for j in range(4)) for i in range(4))
    ident8 = tuple(tuple(int(i == j) for j in range(8)) for i in range(8))
    check(matmul(M4, M4_INV) == ident4 and matmul(M4_INV, M4) == ident4, "M4 * M4^-1 != I")
    check(matmul(M8, M8_INV) == ident8 and matmul(M8_INV, M8) == ident8, "M8 * M8^-1 != I")
    for case in spec["cases"]:
        name = f"{case['section']} MKV-{case['block_bits']}/{case['key_bits']}"
        key = bytes.fromhex(case["key"])
        pt = bytes.fromhex(case["plaintext"])
        ct = bytes.fromhex(case["ciphertext"])
        h = key_schedule(key, case["block_bits"])
        check(len(h) == 2 * case["rounds"] + 1, f"{name}: number of rounds")
        want = [bytes.fromhex(k) for k in case["round_keys"]] + [bytes.fromhex(case["k_post"])]
        for i, (a, b) in enumerate(zip(h, want)):
            check(a == b, f"{name}: round key K{i:02d}" if i < len(h) - 1 else f"{name}: K_post")
        trace = []
        out = encrypt(key, pt, trace)
        for r, (got, exp) in enumerate(zip(trace, case["trace"])):
            for s in range(6):
                check(got[s] == bytes.fromhex(exp[s]), f"{name}: round {r + 1} step {s + 1}")
        check(out == ct, f"{name}: ciphertext")
        check(decrypt(key, ct) == pt, f"{name}: decryption")
        if verbose:
            print(f"{name:24s} R={case['rounds']}  {len(want)} keys, {6 * len(trace)} states, "
                  f"ct {ct.hex()} {'ok' if out == ct else 'MISMATCH'}")
    return errors


# ===================================================== RTL unit test I/O
# case.txt: one operation per line
#   <op> <l> <k> <key hex> <input hex> <output hex>     op: K (key only), E, D
# The key hex is the master key (k / 4 digits), blocks l / 4 digits, in
# the byte order of the standard. Lines after a K / E / D line that starts
# with '#' are comments. The testbench (hw/ip/mkv/dv/tb_bow_mkv.sv) writes
#   out.txt     "<op> <output hex>" per operation (key only: round keys)
#   trace.txt   "<n> <step> <state hex>": state register after every step
#   rk.txt      "<n> <index> <half-round key hex>" after every K operation
#   status.txt  "OK <n>" or "ERR <text>"
def random_case(rnd, count):
    ops = []
    # the Annex A vectors first, encryption then decryption
    for case in load_vectors():
        key = bytes.fromhex(case["key"])
        pt = bytes.fromhex(case["plaintext"])
        ct = bytes.fromhex(case["ciphertext"])
        ops.append(("E", case["block_bits"], key, pt, ct))
        ops.append(("D", case["block_bits"], key, ct, pt))
    versions = sorted(VERSIONS)
    for i in range(count):
        l, k = versions[i % len(versions)] if i < len(versions) else rnd.choice(versions)
        key = bytes(rnd.randrange(256) for _ in range(k // 8))
        # some structured keys / blocks: all zero, all one
        if i % 17 == 5:
            key = bytes(k // 8)
        elif i % 17 == 11:
            key = b"\xff" * (k // 8)
        h = key_schedule(key, l)
        nblk = rnd.randint(1, 3)
        for _ in range(nblk):
            blk = bytes(rnd.randrange(256) for _ in range(l // 8))
            if rnd.random() < 0.5:
                ops.append(("E", l, key, blk, encrypt(key, blk, h=h)))
            else:
                ops.append(("D", l, key, blk, decrypt(key, blk, h=h)))
    return ops


def cmd_gen(args):
    d = Path(args.dir)
    d.mkdir(parents=True, exist_ok=True)
    rnd = random.Random(args.seed)
    ops = random_case(rnd, args.count)
    with open(d / "case.txt", "w") as f:
        f.write(f"# mkv_model.py gen --seed {args.seed} --count {args.count}: {len(ops)} operations\n")
        for op, l, key, blk_in, blk_out in ops:
            f.write(f"{op} {l} {len(key) * 8} {key.hex()} {blk_in.hex()} {blk_out.hex()}\n")
    print(f"{d}: {len(ops)} operations")
    return 0


def read_case(d):
    ops = []
    for line in (Path(d) / "case.txt").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        op, l, k, key, blk_in, blk_out = line.split()
        ops.append((op, int(l), bytes.fromhex(key), bytes.fromhex(blk_in), bytes.fromhex(blk_out)))
    return ops


def cmd_check(args):
    d = Path(args.dir)
    status = (d / "status.txt").read_text().strip() if (d / "status.txt").exists() else "no status"
    ops = read_case(d)
    errors = []
    if status != f"OK {len(ops)}":
        errors.append(f"testbench status '{status}', expected 'OK {len(ops)}'")
    outs = [line.split() for line in (d / "out.txt").read_text().splitlines()] if (d / "out.txt").exists() else []
    if len(outs) != len(ops):
        errors.append(f"{len(outs)} results for {len(ops)} operations")
    traces = {}
    if (d / "trace.txt").exists():
        for line in (d / "trace.txt").read_text().splitlines():
            n, step, val = line.split()
            traces.setdefault(int(n), []).append((int(step), bytes.fromhex(val)))
    rks = {}
    if (d / "rk.txt").exists():
        for line in (d / "rk.txt").read_text().splitlines():
            n, idx, val = line.split()
            rks.setdefault(int(n), []).append((int(idx), bytes.fromhex(val)))
    schedules = {}
    for n, (op, l, key, blk_in, blk_out) in enumerate(ops):
        if n >= len(outs):
            break
        if (key, l) not in schedules:
            schedules[(key, l)] = key_schedule(key, l)
        h = schedules[(key, l)]
        want = encrypt(key, blk_in, h=h) if op == "E" else decrypt(key, blk_in, h=h)
        if want != blk_out:
            errors.append(f"op {n}: case file does not match the model")
        if outs[n][0] != op or bytes.fromhex(outs[n][1]) != want:
            errors.append(f"op {n} {op} MKV-{l}/{len(key) * 8}: RTL {outs[n][1]}, model {want.hex()}")
        steps = half_round_states(key, blk_in, op == "D", h)
        got = traces.get(n, [])
        if [s for s, _ in got] != list(range(len(steps))):
            errors.append(f"op {n}: trace has steps {[s for s, _ in got]}, expected 0..{len(steps) - 1}")
        else:
            for s, (val, exp) in enumerate(zip([v for _, v in got], steps)):
                if val != exp:
                    errors.append(f"op {n} step {s}: RTL {val.hex()}, model {exp.hex()}")
                    break
        if n in rks:
            if [i for i, _ in rks[n]] != list(range(len(h))) or [v for _, v in rks[n]] != h:
                errors.append(f"op {n}: round key memory differs from the key schedule")
    nrk = len(rks)
    for e in errors[:20]:
        print("ERROR", e)
    if errors:
        print(f"{d}: FAIL ({len(errors)} errors)")
        return 1
    print(f"{d}: {len(ops)} operations, {sum(len(v) for v in traces.values())} states, "
          f"{nrk} key schedules match the model")
    return 0


# ================================================================ tables
# Generated from this model (which `selftest` checks against the PDF):
SV_TABLES = "hw/ip/mkv/rtl/bow_mkv_tables_pkg.sv"   # S-boxes, matrices (RTL)
C_TABLES = "sw/apps/mkv/mkv_tables.h"               # S-boxes, matrices (C reference)
C_VECTORS = "sw/apps/mkv/mkv_vectors.h"             # Annex A (self-test of the app)


def _sv_matrix(name, m):
    n = len(m)
    rows = ["".join(f"{v:02x}" for v in row) for row in m]
    head = f"  localparam logic [{8 * n * n - 1}:0] {name:5s} = "
    if n == 4:
        return head + f"128'h{'_'.join(rows)};"
    pairs = [f"64'h{rows[i]}, 64'h{rows[i + 1]}" for i in range(0, n, 2)]
    return head + "{" + (",\n" + " " * (len(head) + 1)).join(pairs) + "};"


def sv_tables():
    lines = ["// AUTO-GENERATED by `tools/mkv/mkv_model.py tables` - DO NOT EDIT",
             "//",
             "// Constants of the MKV block cipher (draft TCVN XXXX:2024), the same values",
             "// as tools/mkv/mkv_model.py: S-box s and its inverse (Tables 1 / 2), MixWords",
             "// matrices (clause 4.2.2.2; M4 with 0x0D at (2, 3) and (3, 0), see the model).",
             "",
             "package bow_mkv_tables_pkg;",
             "",
             "  // n x n matrix, row major: entry (r, c) = M[8 * (n*n - 1 - (n*r + c)) +: 8]",
             _sv_matrix("M4", M4),
             _sv_matrix("M4Inv", M4_INV),
             _sv_matrix("M8", M8),
             _sv_matrix("M8Inv", M8_INV),
             ""]
    for name, table in (("sbox", SBOX), ("sbox_inv", SBOX_INV)):
        lines.append(f"  function automatic logic [7:0] {name}(logic [7:0] x);")
        lines.append("    logic [7:0] r;")
        lines.append("    unique case (x)")
        for i in range(256):
            lines.append(f"      8'h{i:02x}: r = 8'h{table[i]:02x};")
        lines.append("      default: r = 8'h00;")
        lines.append("    endcase")
        lines.append("    return r;")
        lines.append("  endfunction")
        lines.append("")
    lines.append("endpackage")
    return "\n".join(lines) + "\n"


def _c_bytes(data, indent="    ", per_line=16):
    return [indent + ", ".join(f"0x{b:02x}" for b in data[i:i + per_line]) + ","
            for i in range(0, len(data), per_line)]


def c_tables():
    lines = ["/* AUTO-GENERATED by `tools/mkv/mkv_model.py tables` - DO NOT EDIT */",
             "/* Constants of the MKV block cipher (draft TCVN XXXX:2024), the same values as",
             " * tools/mkv/mkv_model.py: S-box and inverse, MixWords matrices (M4 with 0x0D",
             " * at (2, 3) and (3, 0), see the model). */",
             "#ifndef MKV_TABLES_H_",
             "#define MKV_TABLES_H_",
             "",
             "#include <stdint.h>",
             ""]
    for name, table in (("mkv_sbox", SBOX), ("mkv_sbox_inv", SBOX_INV)):
        lines += [f"static const uint8_t {name}[256] = {{"] + _c_bytes(table) + ["};", ""]
    for name, m in (("mkv_m4", M4), ("mkv_m4_inv", M4_INV), ("mkv_m8", M8), ("mkv_m8_inv", M8_INV)):
        n = len(m)
        lines.append(f"static const uint8_t {name}[{n}][{n}] = {{")
        lines += ["    {" + ", ".join(f"0x{v:02x}" for v in row) + "}," for row in m]
        lines += ["};", ""]
    lines += ["#endif /* MKV_TABLES_H_ */"]
    return "\n".join(lines) + "\n"


def c_vectors():
    cases = load_vectors()
    lines = ["/* AUTO-GENERATED by `tools/mkv/mkv_model.py tables` - DO NOT EDIT */",
             "/* Test vectors of Annex A of the draft TCVN XXXX:2024 (tools/mkv/tcvn_mkv_vectors.json,",
             " * extracted from the PDF): key, plaintext, ciphertext and the half-round keys",
             " * h[0..2R] = K00 .. K(2R-1), K_post as printed. */",
             "#ifndef MKV_VECTORS_H_",
             "#define MKV_VECTORS_H_",
             "",
             "#include <stdint.h>",
             "",
             "typedef struct {",
             "  const char *name;",
             "  uint16_t block_bits, key_bits;",
             "  uint8_t rounds;",
             "  const uint8_t *key, *pt, *ct;",
             "  const uint8_t *h; /* 2R + 1 half-round keys of block_bits / 8 bytes */",
             "} mkv_vector_t;",
             ""]
    for i, c in enumerate(cases):
        h = b"".join(bytes.fromhex(k) for k in c["round_keys"]) + bytes.fromhex(c["k_post"])
        for name, data in (("key", bytes.fromhex(c["key"])), ("pt", bytes.fromhex(c["plaintext"])),
                           ("ct", bytes.fromhex(c["ciphertext"])), ("h", h)):
            lines += [f"static const uint8_t mkv_v{i}_{name}[{len(data)}] = {{"] + _c_bytes(data) + ["};"]
        lines.append("")
    lines.append(f"static const mkv_vector_t mkv_vectors[{len(cases)}] = {{")
    for i, c in enumerate(cases):
        lines.append(f'    {{"{c["section"]}", {c["block_bits"]}, {c["key_bits"]}, {c["rounds"]}, '
                     f"mkv_v{i}_key, mkv_v{i}_pt, mkv_v{i}_ct, mkv_v{i}_h}},")
    lines += ["};", "", "#endif /* MKV_VECTORS_H_ */"]
    return "\n".join(lines) + "\n"


def cmd_tables(args):
    stale = []
    files = ((SV_TABLES, sv_tables()), (C_TABLES, c_tables()), (C_VECTORS, c_vectors()))
    for rel, text in files:
        path = ROOT / rel
        if args.check:
            if not path.exists() or path.read_text() != text:
                stale.append(rel)
            continue
        path.write_text(text)
        print(f"wrote {rel}")
    if args.check:
        for rel in stale:
            print(f"{rel} is stale (run `tools/mkv/mkv_model.py tables`)")
        if not stale:
            print(", ".join(rel for rel, _ in files) + " are up to date")
        return 1 if stale else 0
    return 0


# =================================================================== CLI
def cmd_selftest(args):
    errors = selftest(verbose=True)
    for e in errors:
        print("ERROR", e)
    print("selftest:", "FAIL" if errors else "PASS (Annex A: 6 versions, every round key and state)")
    return 1 if errors else 0


def cmd_kat(args):
    for case in load_vectors():
        print(f"{case['section']} MKV-{case['block_bits']}/{case['key_bits']} R={case['rounds']}")
        print(f"  key {case['key']}\n  pt  {case['plaintext']}\n  ct  {case['ciphertext']}")
    return 0


def cmd_crypt(args):
    key = bytes.fromhex(args.key)
    blk = bytes.fromhex(args.block)
    if len(blk) * 8 != args.l:
        sys.exit(f"error: block of {len(blk) * 8} bits for MKV-{args.l}")
    out = encrypt(key, blk) if args.cmd == "enc" else decrypt(key, blk)
    print(out.hex())
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest", help="check the model against Annex A of the standard")
    sub.add_parser("kat", help="print the Annex A vectors")
    for name in ("enc", "dec"):
        p = sub.add_parser(name, help=f"{name}rypt one block")
        p.add_argument("l", type=int, choices=(128, 256), help="block size")
        p.add_argument("key", help="master key (hex)")
        p.add_argument("block", help="block (hex)")
    p = sub.add_parser("gen", help="write a test case for hw/ip/mkv/dv")
    p.add_argument("dir")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--count", type=int, default=60, help="random keys (each 1..3 blocks)")
    p = sub.add_parser("check", help="compare the testbench output with the model")
    p.add_argument("dir")
    p = sub.add_parser("tables", help=f"write {SV_TABLES}, {C_TABLES}, {C_VECTORS}")
    p.add_argument("--check", action="store_true", help="only check that the files are up to date")
    args = ap.parse_args()
    return {"selftest": cmd_selftest, "kat": cmd_kat, "enc": cmd_crypt, "dec": cmd_crypt,
            "gen": cmd_gen, "check": cmd_check, "tables": cmd_tables}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
