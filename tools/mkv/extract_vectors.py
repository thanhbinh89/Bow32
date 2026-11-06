#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Extract the tables and the test vectors of the draft of the MKV standard.

    extract_vectors.py docs/ref/Du-thao-TCVN-XXXX2024.pdf [-o draft_vectors.json]

Needs `pdftotext` (poppler-utils). Reads the text layer of the PDF
(`pdftotext -layout`) and writes, exactly as printed:
  * the S-box s and its inverse (Tables 1 / 2 of clause 4.2.2.1),
  * the MixWords matrices M4, M4^-1, M8, M8^-1 (clause 4.2.2.2),
  * the six test vectors of Annex A: plaintext, master key, the round keys
    K00..K(2R-1) and K_post, the six steps of every round, the ciphertext.
The S-boxes and matrices are those of TCVN 14263:2024 too (the draft prints
M4 with an erratum); the test vectors are those of the draft cipher, which
tools/mkv/mkv_model.py computes with its DRAFT edition. mkv_model.py
(selftest) and tools/tests/test_mkv_model.py check the model against this
file. The standard itself is a scanned PDF: its Annex A is transcribed in
tools/mkv/tcvn14263_vectors.json.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SECTIONS = (("A.1.1", 128, 128, 6), ("A.1.2", 128, 192, 7), ("A.1.3", 128, 256, 8),
            ("A.2.1", 256, 256, 6), ("A.2.2", 256, 384, 7), ("A.2.3", 256, 512, 8))


def hexbytes(s):
    s = s.strip()
    if re.fullmatch(r"[0-9A-Fa-f]{6,}", s):          # MKV-256: one hex string
        return bytes.fromhex(s)
    toks = s.split()                                  # MKV-128: spaced bytes
    if not all(re.fullmatch(r"[0-9A-Fa-f]{2}", t) for t in toks):
        raise ValueError(f"not a byte list: {s!r}")
    return bytes(int(t, 16) for t in toks)


def sbox_table(lines, title):
    i = next(i for i, s in enumerate(lines) if title in s)
    rows = []
    for s in lines[i + 1:]:
        m = re.match(r"\s*([0-9A-F]0)\s+((?:[0-9A-F]{2}\s+){15}[0-9A-F]{2})\s*$", s)
        if m:
            rows.append((int(m.group(1), 16), [int(x, 16) for x in m.group(2).split()]))
        if len(rows) == 16:
            break
    if [r[0] for r in rows] != list(range(0, 256, 16)):
        raise ValueError(f"table '{title}' not found")
    return bytes(v for _, row in rows for v in row)


def matrices(lines):
    """M4, M4^-1, M8, M8^-1: the 0x.. values of clause 4.2.2.2 in order."""
    i = next(i for i, s in enumerate(lines) if "MKV-128, MixWords" in s)
    j = next(j for j in range(i, len(lines)) if "Hình 4" in lines[j])
    vals = [int(v, 16) for s in lines[i:j] for v in re.findall(r"0x([0-9A-Fa-f]{2})", s)]
    if len(vals) != 16 + 16 + 64 + 64:
        raise ValueError(f"{len(vals)} matrix entries, expected 160")
    def rows(v, n):
        return [v[k * n:(k + 1) * n] for k in range(n)]
    return {"m4": rows(vals[0:16], 4), "m4_inv": rows(vals[16:32], 4),
            "m8": rows(vals[32:96], 8), "m8_inv": rows(vals[96:160], 8)}


def c_array(sec, label):
    i = next(i for i, s in enumerate(sec) if re.search(label, s))
    out = []
    for s in sec[i:]:
        out += [int(t, 16) for t in re.findall(r"0x([0-9A-Fa-f]{2})", s)]
        if "}" in s:
            break
    return bytes(out)


def annex_a(lines):
    start = next(i for i, s in enumerate(lines)
                 if s.strip().startswith("PHỤ LỤC A") and "...." not in s)
    lines = lines[start:]
    starts = [next(i for i, s in enumerate(lines) if s.strip().startswith(name + "."))
              for name, *_ in SECTIONS] + [len(lines)]
    cases = []
    for n, (name, l, k, rounds) in enumerate(SECTIONS):
        sec = lines[starts[n]:starts[n + 1]]
        pt, key = c_array(sec, r"u8 X\["), c_array(sec, r"u8 MasterKey")
        rks, post, trace, ct, final = {}, None, [], None, None
        for s in sec:
            st = s.strip()
            if m := re.match(r"K(\d\d):\s*(.*)$", st):
                rks[int(m.group(1))] = hexbytes(m.group(2))
            elif m := re.match(r"K_post:\s*(.*)$", st):
                post = hexbytes(m.group(1))
            elif m := re.match(r"Vòng (\d+)$", st):
                trace.append({})
            elif m := re.match(r"([1-6])\.(AddRoundKey|SubCells|MixWords|XWord):\s*(.*)$", st):
                trace[-1][int(m.group(1))] = hexbytes(m.group(3))
            elif m := re.match(r"AddRoundKey:\s*(.*)$", st):
                final = hexbytes(m.group(1))
            elif m := re.match(r"Bản mã:\s*(.*)$", st):
                ct = hexbytes(m.group(1))
        n_bytes = l // 8
        ok = (len(pt) == n_bytes and len(key) == k // 8 and sorted(rks) == list(range(2 * rounds))
              and all(len(v) == n_bytes for v in rks.values()) and post and len(post) == n_bytes
              and len(trace) == rounds and all(sorted(r) == list(range(1, 7)) for r in trace)
              and final == ct and len(ct) == n_bytes)
        if not ok:
            raise ValueError(f"section {name}: incomplete test vector")
        cases.append({"section": name, "block_bits": l, "key_bits": k, "rounds": rounds,
                      "plaintext": pt.hex(), "key": key.hex(),
                      "round_keys": [rks[i].hex() for i in range(2 * rounds)],
                      "k_post": post.hex(),
                      "trace": [[r[j].hex() for j in range(1, 7)] for r in trace],
                      "ciphertext": ct.hex()})
    return cases


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("pdf")
    ap.add_argument("-o", "--output", default=str(Path(__file__).resolve().parent / "draft_vectors.json"))
    args = ap.parse_args()
    text = subprocess.run(["pdftotext", "-layout", args.pdf, "-"], check=True,
                          capture_output=True).stdout.decode("utf-8")
    lines = text.splitlines()
    data = {"source": "Du thao TCVN XXXX:2024 Ma khoi MKV (" + Path(args.pdf).name + "), as printed",
            "sbox": sbox_table(lines, "Bảng 1 – Biểu diễn dạng tra bảng của hộp thế").hex(),
            "sbox_inv": sbox_table(lines, "Bảng 2 – Biểu diễn dạng tra bảng của hộp thế").hex(),
            **matrices(lines),
            "cases": annex_a(lines)}
    Path(args.output).write_text(json.dumps(data, indent=1) + "\n")
    print(f"wrote {args.output}: S-boxes, 4 matrices, {len(data['cases'])} test vectors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
