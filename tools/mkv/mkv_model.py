#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Reference model of the MKV block cipher for the Bow32 MKV IP (hw/ip/mkv).

MKV is the block cipher of the Vietnamese national standard TCVN 14263:2024
"Cong nghe thong tin - Ky thuat an toan - Thuat toan ma khoi MKV"
(Information technology - Security techniques - Block cipher algorithm MKV).
Six versions (Table 1):

    MKV-128  block 128 bit, key 128 / 192 / 256 bit, R = 7 / 8 / 9 rounds
    MKV-256  block 256 bit, key 256 / 384 / 512 bit, R = 7 / 8 / 9 rounds

Round function (clause 5.2, state X = x^0 || x^1 || x^2 || x^3, every
sub-state x^j is a column of t = l / 32 bytes, w = 8t bits):

    F(K_i^0 || K_i^1, X) = XWords(SubCells(MixWords(SubCells(X ^ K_i^0)) ^ K_i^1))
    C = F(K_{R-1}, ... F(K_0, P)) ^ K_post

MixWords (clause 5.4.3) rotates sub-state j left by j * w / 4 bits, then
multiplies it by M4 (MKV-128) or M8 (MKV-256): y^j = M_t (x^j <<<_w j*w/4).

Key schedule (clause 5.5): K = K^0 || K^1 = K_int from the master key,
RK_0 = K^0, then for i = 0 .. R - 1, with G(X) = XWords(SubCells(MixWords(
SubCells(X)))):
    K^1 <- G(G(K^1 ^ Const^1_l ^ <2i + 2>_l))
    K^0 <- G(G(K^0 ^ Const^0_l ^ <2i + 1>_l)) ^ K^1
    SWAP(K^0, K^1);  RK_{2i+1} = K^0, RK_{2i+2} = K^1
Round key K_i = RK_2i || RK_2i+1, K_post = RK_2R. <v>_l is v as an l-bit
big-endian number (v in the last byte).

The model is checked against Annex A of the standard
(tools/mkv/tcvn14263_vectors.json, transcribed from the scanned standard:
for each of the six versions the inputs, every round key, both branches of
the first key schedule update, the first and the last round and the
ciphertext).

The draft of the standard (docs/ref/Du-thao-TCVN-XXXX2024.pdf) is a
different cipher in three points, all three fixed by TCVN 14263:2024:
R = 6 / 7 / 8, MixWords without the rotation, and a key schedule without
Const^0 / Const^1. The DRAFT edition of this model (with edition(DRAFT):
...) reproduces every value of the Annex A of the draft
(tools/mkv/draft_vectors.json, extracted from its PDF by extract_vectors.py),
which shows that these three are the only differences. The text of the
draft also had two errata against its own vectors, both corrected in the
standard: M4 printed with 0x0C at (2, 3) and (3, 0) instead of 0x0D, and
key schedule constants that did not give its vectors.

Byte order: a block / key is a byte string in the order of the standard
(the hex strings of Annex A). Sub-state x^j = bytes [j*t, (j+1)*t), byte b
of it is x^j_b, the b-th entry of the column vector of MixWords and the b-th
byte of the w-bit string x^j (x^j_0 first: x^j <<<_w 8 = x^j_1 .. x^j_0).

Library use:
    ct = encrypt(key, pt)                # key 16..64 bytes, pt 16 or 32 bytes
    pt = decrypt(key, ct)
    h = key_schedule(key, len(pt) * 8)   # h[j] = RK_j, see below

Command line:
    mkv_model.py selftest                       model vs Annex A (standard, draft)
    mkv_model.py kat                            print the Annex A vectors
    mkv_model.py enc|dec <l> <key> <block>      one block (hex)
    mkv_model.py gen DIR [--seed N --count N]   test case for hw/ip/mkv/dv
    mkv_model.py check DIR                      check the testbench results
    mkv_model.py tables [--check]               tables of RTL and C, C vectors
"""

import argparse
import contextlib
import json
import random
import sys
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parent.parent.parent
VECTORS_JSON = Path(__file__).resolve().parent / "tcvn14263_vectors.json"
DRAFT_JSON = Path(__file__).resolve().parent / "draft_vectors.json"

# ============================================================== constants
# GF(2^8) of the standard: x^8 + x^5 + x^3 + x + 1
POLY = 0x12B

# Table 2 of the standard: S-box s, one row per high nibble of the input.
# The inverse (Table 3) is computed; both are checked against the tables
# extracted from the PDF of the draft (draft_vectors.json), which are the
# same as in the standard.
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

# MixWords matrices (rows), clauses 5.4.3 / 5.4.4.
M4 = ((0x01, 0x02, 0x01, 0x03),
      (0x03, 0x07, 0x01, 0x04),
      (0x04, 0x0B, 0x03, 0x0D),
      (0x0D, 0x1E, 0x06, 0x14))
M4_PRINTED = ((0x01, 0x02, 0x01, 0x03),      # as printed in the draft (erratum)
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

# Constants Const^0_l, Const^1_l of the key schedule, clause 5.5
CONST = {128: (bytes.fromhex("9302ee911a2ad98cad13e7948ad8b3b2"),
               bytes.fromhex("d4da00f33f11fd8822166bb9cd187c55")),
         256: (bytes.fromhex("9302ee911a2ad98cad13e7948ad8b3b2d4da00f33f11fd8822166bb9cd187c55"),
               bytes.fromhex("43c853a3f90f70ae8d72ad0e7aac0c71afad739c17a14bd656c9436300def1e5"))}


class Edition(NamedTuple):
    name: str
    rounds: dict      # (block bits, key bits) -> rounds R, Table 1
    rotate: bool      # MixWords rotates sub-state j by j * w / 4 bits
    const: dict       # block bits -> (Const^0_l, Const^1_l); empty: no constants


TCVN_14263 = Edition("TCVN 14263:2024",
                     {(128, 128): 7, (128, 192): 8, (128, 256): 9,
                      (256, 256): 7, (256, 384): 8, (256, 512): 9}, True, CONST)
DRAFT = Edition("draft TCVN XXXX:2024",
                {(128, 128): 6, (128, 192): 7, (128, 256): 8,
                 (256, 256): 6, (256, 384): 7, (256, 512): 8}, False, {})

EDITION = TCVN_14263            # the one the functions below compute
VERSIONS = TCVN_14263.rounds


@contextlib.contextmanager
def edition(ed):
    """with edition(DRAFT): ... computes the cipher of the draft."""
    global EDITION
    saved, EDITION = EDITION, ed
    try:
        yield ed
    finally:
        EDITION = saved


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
    """Every sub-state times the matrix (no rotation)."""
    t = len(matrix)
    out = bytearray()
    for c in range(4):
        col = x[c * t:(c + 1) * t]
        out += bytes(_dot(row, col) for row in matrix)
    return bytes(out)


def rotate_words(x, sign=1):
    """x^j <<<_w j * w / 4 for every sub-state j (sign -1: >>>_w). Byte b of
    the result is byte (b + j * t / 4) mod t of x^j."""
    t = len(x) // 4
    out = bytearray()
    for j in range(4):
        col = x[j * t:(j + 1) * t]
        n = (sign * j * t // 4) % t
        out += col[n:] + col[:n]
    return bytes(out)


def mix_words(x):
    """y^j = M_t (x^j <<<_w j * w / 4), clause 5.4.3."""
    if EDITION.rotate:
        x = rotate_words(x)
    return _mix(x, M8 if len(x) == 32 else M4)


def inv_mix_words(x):
    """y^j = (M_t^-1 x^j) >>>_w j * w / 4, clause 5.4.4."""
    y = _mix(x, M8_INV if len(x) == 32 else M4_INV)
    return rotate_words(y, -1) if EDITION.rotate else y


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
        return EDITION.rounds[(block_bits, key_bits)]
    except KeyError:
        raise ValueError(f"no MKV-{block_bits} version with a {key_bits} bit key") from None


def initial_key_state(key, block_bits):
    """K_int (2l bits) from the master key, clause 5.5 step 1."""
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


def schedule_constant(v, block_bits, half):
    """Round key K0 || K1 of the first F of a key schedule branch, clause 5.5:
    K0 = Const^half_l ^ <v>_l, K1 = 0. half 0: K^0 (left branch, v = 2i + 1),
    1: K^1 (right branch, v = 2i + 2). The draft has no Const."""
    n = block_bits // 8
    c = v.to_bytes(n, "big")
    if EDITION.const:
        c = xor(c, EDITION.const[block_bits][half])
    return c + bytes(n)


def update_ks(k0, k1, i, block_bits):
    """Update i = 1..R of the key schedule (the loop index of clause 5.5 step 3
    is i - 1): (K^0, K^1) -> (K^0, K^1) after SWAP = (RK_{2i-1}, RK_{2i})."""
    zero = bytes(block_bits // 4)
    right = round_f(zero, round_f(schedule_constant(2 * i, block_bits, 1), k1))           # 3.1, 3.2
    left = xor(round_f(zero, round_f(schedule_constant(2 * i - 1, block_bits, 0), k0)), right)  # 3.3, 3.4
    return right, left                                                                      # 3.5


def update_trace(k0, k1, i, block_bits):
    """The nine steps of each branch of update i as printed in Annex A: add
    constant, SubCells, MixWords, SubCells, XWords, SubCells, MixWords,
    SubCells, XWords (the left one before the XOR with the right one)."""
    zero = bytes(block_bits // 4)
    out = {}
    for name, k, half, v in (("left", k0, 0, 2 * i - 1), ("right", k1, 1, 2 * i)):
        first, second = [], []
        round_f(zero, round_f(schedule_constant(v, block_bits, half), k, first), second)
        a, b = first[0], second[0]
        out[name] = [a[0], a[1], a[2], a[4], a[5], b[1], b[2], b[4], b[5]]
    return out


def key_schedule(key, block_bits):
    """Half-round keys h[0..2R] = RK_0 .. RK_2R of clause 5.5.

    Round key i is K_i = K_i^0 || K_i^1 = h[2i] || h[2i+1], K_post = h[2R].
    This is also the order of the round key memory of the RTL."""
    rounds = rounds_for(block_bits, len(key) * 8)
    n = block_bits // 8
    k = initial_key_state(key, block_bits)
    k0, k1 = k[:n], k[n:]
    out = [k0]
    for i in range(1, rounds + 1):
        k0, k1 = update_ks(k0, k1, i, block_bits)
        out += [k0, k1]
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
def load_vectors(path=VECTORS_JSON):
    """Annex A of TCVN 14263:2024, per version: key, plaintext, ciphertext,
    round_keys RK_0 .. RK_2R-1 and k_post, first_update (both branches of
    update 1, nine steps each), trace_first / trace_last (the six steps of
    the first / last round)."""
    return json.loads(Path(path).read_text())["cases"]


def load_spec(path=DRAFT_JSON):
    """Tables, matrices and test vectors as printed in the draft."""
    return json.loads(Path(path).read_text())


def tuples(rows):
    return tuple(tuple(r) for r in rows)


def selftest(verbose=True):
    """Model vs every value of Annex A of the standard, and (DRAFT edition)
    vs every value of the draft: tables, matrices, Annex A. Returns a list
    of errors."""
    errors = []

    def check(cond, what):
        if not cond:
            errors.append(what)

    spec = load_spec()
    check(SBOX.hex() == spec["sbox"], "S-box differs from Table 2")
    check(SBOX_INV.hex() == spec["sbox_inv"], "inverse S-box differs from Table 3")
    check(SBOX[0x24] == 0x1C and SBOX_INV[0x82] == 0xB4, "S-box examples of 5.4.1")
    check(tuples(spec["m4_inv"]) == M4_INV and tuples(spec["m8"]) == M8
          and tuples(spec["m8_inv"]) == M8_INV, "matrices differ from 5.4.3 / 5.4.4")
    check(tuples(spec["m4"]) == M4_PRINTED, "M4 of the draft is not the one of its erratum")
    ident4 = tuple(tuple(int(i == j) for j in range(4)) for i in range(4))
    ident8 = tuple(tuple(int(i == j) for j in range(8)) for i in range(8))
    check(matmul(M4, M4_INV) == ident4 and matmul(M4_INV, M4) == ident4, "M4 * M4^-1 != I")
    check(matmul(M8, M8_INV) == ident8 and matmul(M8_INV, M8) == ident8, "M8 * M8^-1 != I")
    for case in load_vectors():
        name = f"{case['section']} MKV-{case['block_bits']}/{case['key_bits']}"
        l, n = case["block_bits"], case["block_bits"] // 8
        key = bytes.fromhex(case["key"])
        pt = bytes.fromhex(case["plaintext"])
        ct = bytes.fromhex(case["ciphertext"])
        h = key_schedule(key, l)
        check(len(h) == 2 * case["rounds"] + 1, f"{name}: number of rounds")
        want = [bytes.fromhex(k) for k in case["round_keys"]] + [bytes.fromhex(case["k_post"])]
        for i, (a, b) in enumerate(zip(h, want)):
            check(a == b, f"{name}: RK_{i}")
        k = initial_key_state(key, l)
        upd = update_trace(k[:n], k[n:], 1, l)
        for side in ("left", "right"):
            for s, (a, b) in enumerate(zip(upd[side], case["first_update"][side])):
                check(a == bytes.fromhex(b), f"{name}: update 1, {side} branch, step {s + 1}")
        trace = []
        out = encrypt(key, pt, trace)
        for r, exp in ((1, case["trace_first"]), (case["rounds"], case["trace_last"])):
            for s in range(6):
                check(trace[r - 1][s] == bytes.fromhex(exp[s]), f"{name}: round {r} step {s + 1}")
        check(out == ct, f"{name}: ciphertext")
        check(decrypt(key, ct) == pt, f"{name}: decryption")
        if verbose:
            print(f"{name:24s} R={case['rounds']}  {len(want)} round keys, 18 + 12 states, "
                  f"ct {ct.hex()} {'ok' if out == ct else 'MISMATCH'}")
    with edition(DRAFT):
        for case in spec["cases"]:
            name = f"draft {case['section']} MKV-{case['block_bits']}/{case['key_bits']}"
            key = bytes.fromhex(case["key"])
            pt = bytes.fromhex(case["plaintext"])
            ct = bytes.fromhex(case["ciphertext"])
            h = key_schedule(key, case["block_bits"])
            check(len(h) == 2 * case["rounds"] + 1, f"{name}: number of rounds")
            want = [bytes.fromhex(k) for k in case["round_keys"]] + [bytes.fromhex(case["k_post"])]
            for i, (a, b) in enumerate(zip(h, want)):
                check(a == b, f"{name}: RK_{i}")
            trace = []
            out = encrypt(key, pt, trace)
            for r, (got, exp) in enumerate(zip(trace, case["trace"])):
                for s in range(6):
                    check(got[s] == bytes.fromhex(exp[s]), f"{name}: round {r + 1} step {s + 1}")
            check(out == ct, f"{name}: ciphertext")
            check(decrypt(key, ct) == pt, f"{name}: decryption")
            if verbose:
                print(f"{name:24s} R={case['rounds']}  {len(want)} round keys, {6 * len(trace)} states, "
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
# Generated from this model (which `selftest` checks against Annex A):
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
             "// Constants of the MKV block cipher (TCVN 14263:2024), the same values as",
             "// tools/mkv/mkv_model.py: S-box s and its inverse (Tables 2 / 3), MixWords",
             "// matrices (clauses 5.4.3 / 5.4.4), key schedule constants (clause 5.5).",
             "",
             "package bow_mkv_tables_pkg;",
             "",
             "  // n x n matrix, row major: entry (r, c) = M[8 * (n*n - 1 - (n*r + c)) +: 8]",
             _sv_matrix("M4", M4),
             _sv_matrix("M4Inv", M4_INV),
             _sv_matrix("M8", M8),
             _sv_matrix("M8Inv", M8_INV),
             "",
             "  // Const^h_l in the byte order of the state: byte b of the constant (the",
             "  // first byte of the hex string of the standard is byte 0) = [8*b +: 8]"]
    for l in (128, 256):
        for half in (0, 1):
            value = CONST[l][half][::-1].hex()
            lines.append(f"  localparam logic [{l - 1}:0] Const{half}L{l} = {l}'h"
                         + "_".join(value[i:i + 32] for i in range(0, len(value), 32)) + ";")
    lines.append("")
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
             "/* Constants of the MKV block cipher (TCVN 14263:2024), the same values as",
             " * tools/mkv/mkv_model.py: S-box and inverse, MixWords matrices, key schedule",
             " * constants Const^0_l, Const^1_l. */",
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
    for l in (128, 256):
        lines.append(f"static const uint8_t mkv_const{l}[2][{l // 8}] = {{")
        for half in (0, 1):
            lines += ["    {"] + _c_bytes(CONST[l][half], indent="        ") + ["    },"]
        lines += ["};", ""]
    lines += ["#endif /* MKV_TABLES_H_ */"]
    return "\n".join(lines) + "\n"


def c_vectors():
    cases = load_vectors()
    lines = ["/* AUTO-GENERATED by `tools/mkv/mkv_model.py tables` - DO NOT EDIT */",
             "/* Test vectors of Annex A of TCVN 14263:2024 (tools/mkv/tcvn14263_vectors.json,",
             " * transcribed from the standard): key, plaintext, ciphertext and the half-round",
             " * keys h[0..2R] = RK_0 .. RK_2R (K_post = RK_2R) as printed. */",
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
    print("selftest:", "FAIL" if errors else
          "PASS (Annex A of TCVN 14263:2024 and of the draft, 6 versions each)")
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
