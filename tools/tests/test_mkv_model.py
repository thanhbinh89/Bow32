# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/mkv (the MKV block cipher reference model of the
draft TCVN XXXX:2024) and tools/bow32_mkv.py. Run:
python3 -m unittest discover -s tools/tests

The model is checked against every value printed in the draft
(tools/mkv/tcvn_mkv_vectors.json, extracted from the PDF): the S-boxes, the
MixWords matrices, and for the six versions of Annex A the round keys, the
six steps of every round and the ciphertext. The two places where the text
of the draft and its test vectors disagree are tested explicitly.
"""

import random
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "mkv"))
import mkv_model as m  # noqa: E402
import bow32_mkv  # noqa: E402

SPEC = m.load_spec()
CASES = SPEC["cases"]
IDENT4 = tuple(tuple(int(i == j) for j in range(4)) for i in range(4))


class TablesTest(unittest.TestCase):
    def test_sbox_tables_as_printed(self):
        self.assertEqual(m.SBOX.hex(), SPEC["sbox"])
        self.assertEqual(m.SBOX_INV.hex(), SPEC["sbox_inv"])
        self.assertEqual(sorted(m.SBOX), list(range(256)))
        self.assertTrue(all(m.SBOX_INV[m.SBOX[x]] == x for x in range(256)))
        # examples of clause 4.2.2.1
        self.assertEqual(m.SBOX[0x24], 0x1C)
        self.assertEqual(m.SBOX_INV[0x82], 0xB4)

    def test_field(self):
        """x^8 + x^5 + x^3 + x + 1 is primitive: 0x02 has order 255."""
        x, order = 1, 0
        while True:
            x, order = m.gmul(x, 2), order + 1
            if x == 1:
                break
        self.assertEqual(order, 255)

    def test_matrices_as_printed(self):
        self.assertEqual(m.tuples(SPEC["m8"]), m.M8)
        self.assertEqual(m.tuples(SPEC["m8_inv"]), m.M8_INV)
        self.assertEqual(m.tuples(SPEC["m4_inv"]), m.M4_INV)
        self.assertEqual(m.tuples(SPEC["m4"]), m.M4_PRINTED)
        ident8 = tuple(tuple(int(i == j) for j in range(8)) for i in range(8))
        self.assertEqual(m.matmul(m.M8, m.M8_INV), ident8)

    def test_erratum_1_m4(self):
        """The printed M4 is not the inverse of the printed M4^-1; with 0x0D
        at (2, 3) and (3, 0) it is."""
        diff = [(r, c) for r in range(4) for c in range(4) if m.M4[r][c] != m.M4_PRINTED[r][c]]
        self.assertEqual(diff, [(2, 3), (3, 0)])
        self.assertEqual((m.M4[2][3], m.M4[3][0], m.M4_PRINTED[2][3]), (0x0D, 0x0D, 0x0C))
        self.assertNotEqual(m.matmul(m.M4_PRINTED, m.M4_INV), IDENT4)
        self.assertEqual(m.matmul(m.M4, m.M4_INV), IDENT4)
        self.assertEqual(m.matmul(m.M4_INV, m.M4), IDENT4)

    def test_erratum_1_vectors_need_0x0d(self):
        """With the printed M4 the MixWords step of round 1 of A.1.1 is wrong."""
        case = CASES[0]
        x = bytes.fromhex(case["trace"][0][1])          # SubCells output of round 1
        want = bytes.fromhex(case["trace"][0][2])       # MixWords output
        self.assertEqual(m.mix_words(x), want)
        self.assertNotEqual(m._mix(x, m.M4_PRINTED), want)


class AnnexATest(unittest.TestCase):
    def test_six_versions(self):
        self.assertEqual([(c["block_bits"], c["key_bits"], c["rounds"]) for c in CASES],
                         [(l, k, r) for (l, k), r in sorted(m.VERSIONS.items())])

    def test_round_keys(self):
        for case in CASES:
            with self.subTest(case["section"]):
                h = m.key_schedule(bytes.fromhex(case["key"]), case["block_bits"])
                self.assertEqual([x.hex() for x in h[:-1]], case["round_keys"])
                self.assertEqual(h[-1].hex(), case["k_post"])

    def test_every_round_step(self):
        for case in CASES:
            with self.subTest(case["section"]):
                trace = []
                ct = m.encrypt(bytes.fromhex(case["key"]), bytes.fromhex(case["plaintext"]), trace)
                self.assertEqual([[s.hex() for s in r] for r in trace], case["trace"])
                self.assertEqual(ct.hex(), case["ciphertext"])

    def test_decryption(self):
        for case in CASES:
            with self.subTest(case["section"]):
                pt = m.decrypt(bytes.fromhex(case["key"]), bytes.fromhex(case["ciphertext"]))
                self.assertEqual(pt.hex(), case["plaintext"])

    def test_selftest(self):
        self.assertEqual(m.selftest(verbose=False), [])


class KeyScheduleTest(unittest.TestCase):
    def test_initial_key_state(self):
        key = bytes(range(1, 25))                       # MKV-128, 192 bit key: words of 4 bytes
        k0 = m.initial_key_state(key, 128)
        inv = bytes(b ^ 0xFF for b in key)
        self.assertEqual(k0, key + inv[8:16])           # k0..k5 ~k2 ~k3
        key = bytes(range(1, 33))
        self.assertEqual(m.initial_key_state(key, 128), key)
        self.assertEqual(m.initial_key_state(key, 256), key + bytes(b ^ 0xFF for b in key))
        key = bytes(range(48))                          # MKV-256, 384 bit key: words of 8 bytes
        self.assertEqual(m.initial_key_state(key, 256), key + bytes(b ^ 0xFF for b in key[16:32]))

    def _schedule_as_written(self, key, l):
        """Clause 4.6 read literally: update i uses Const_{i-1}, Const^Left =
        <2(i-1)>_2l, Const^Right = <2(i-1)+1>_2l (2l-bit big-endian)."""
        n = l // 8
        k0 = m.initial_key_state(key, l)
        kl, kr = k0[:n], k0[n:]
        zero = bytes(2 * n)
        out = [kl]
        for i in range(1, m.rounds_for(l, len(key) * 8) + 1):
            c_left = (2 * (i - 1)).to_bytes(2 * n, "big")
            c_right = (2 * (i - 1) + 1).to_bytes(2 * n, "big")
            new_l = m.round_f(zero, m.round_f(c_right, kr))
            new_r = m.xor(new_l, m.round_f(zero, m.round_f(c_left, kl)))
            kl, kr = new_l, new_r
            out += [kl, kr]
        return out

    def test_erratum_2_constants(self):
        """The literal reading of the text misses K01 of every vector; the
        model (constants 2i and 2i - 1 in the first key half) gets them all."""
        for case in CASES:
            with self.subTest(case["section"]):
                key = bytes.fromhex(case["key"])
                literal = self._schedule_as_written(key, case["block_bits"])
                self.assertEqual(literal[0].hex(), case["round_keys"][0])
                self.assertNotEqual(literal[1].hex(), case["round_keys"][1])
        self.assertEqual(m.schedule_constant(5, 128), bytes(15) + b"\x05" + bytes(16))

    def test_bad_versions(self):
        with self.assertRaises(ValueError):
            m.key_schedule(bytes(20), 128)
        with self.assertRaises(ValueError):
            m.key_schedule(bytes(16), 256)
        with self.assertRaises(ValueError):
            m.encrypt(bytes(16), bytes(24))


class PropertiesTest(unittest.TestCase):
    def test_round_trip_and_inverse_layers(self):
        rnd = random.Random(5)
        for (l, k) in m.VERSIONS:
            for _ in range(3):
                key = bytes(rnd.randrange(256) for _ in range(k // 8))
                x = bytes(rnd.randrange(256) for _ in range(l // 8))
                self.assertEqual(m.decrypt(key, m.encrypt(key, x)), x)
                self.assertEqual(m.encrypt(key, m.decrypt(key, x)), x)
                self.assertEqual(m.inv_mix_words(m.mix_words(x)), x)
                self.assertEqual(m.x_words(m.x_words(x)), x)
                rk = bytes(rnd.randrange(256) for _ in range(l // 4))
                self.assertEqual(m.inv_round_f(rk, m.round_f(rk, x)), x)

    def test_half_round_states(self):
        """The RTL state register sequence: encryption = MixWords / XWords
        outputs then the ciphertext; decryption visits them backwards."""
        case = CASES[3]
        key, pt = bytes.fromhex(case["key"]), bytes.fromhex(case["plaintext"])
        ct = bytes.fromhex(case["ciphertext"])
        enc = m.half_round_states(key, pt)
        self.assertEqual(len(enc), 2 * case["rounds"] + 1)
        self.assertEqual([s.hex() for s in enc[:-1]],
                         [v for r in case["trace"] for v in (r[2], r[5])])
        self.assertEqual(enc[-1], ct)
        dec = m.half_round_states(key, ct, decrypt_op=True)
        self.assertEqual(dec[0].hex(), case["trace"][-1][5])     # ct ^ K_post
        self.assertEqual(dec[1:-1], list(reversed(enc[:-2])))
        self.assertEqual(dec[-1], pt)


class GeneratedFilesTest(unittest.TestCase):
    def test_tables_up_to_date(self):
        self.assertEqual((ROOT.parent / m.SV_TABLES).read_text(), m.sv_tables())
        self.assertEqual((ROOT.parent / m.C_TABLES).read_text(), m.c_tables())
        self.assertEqual((ROOT.parent / m.C_VECTORS).read_text(), m.c_vectors())

    def test_c_vectors_hold_annex_a(self):
        text = m.c_vectors()
        for case in CASES:
            self.assertIn(f'"{case["section"]}", {case["block_bits"]}, {case["key_bits"]}, '
                          f'{case["rounds"]}', text)
            ct = ", ".join(f"0x{b:02x}" for b in bytes.fromhex(case["ciphertext"])[:16])
            self.assertIn(ct, text)


class DvFilesTest(unittest.TestCase):
    """gen / check of the RTL unit test, with a fake testbench."""

    def _fake_tb(self, d, corrupt=None):
        ops = m.read_case(d)
        out, trace, rk = [], [], []
        last = None
        for n, (op, l, key, blk_in, blk_out) in enumerate(ops):
            h = m.key_schedule(key, l)
            if (key, l) != last:
                rk += [f"{n} {i} {x.hex()}" for i, x in enumerate(h)]
                last = (key, l)
            res = m.encrypt(key, blk_in, h=h) if op == "E" else m.decrypt(key, blk_in, h=h)
            if corrupt == n:
                res = bytes([res[0] ^ 1]) + res[1:]
            out.append(f"{op} {res.hex()}")
            trace += [f"{n} {s} {x.hex()}" for s, x in enumerate(m.half_round_states(key, blk_in, op == "D", h))]
        (d / "out.txt").write_text("\n".join(out) + "\n")
        (d / "trace.txt").write_text("\n".join(trace) + "\n")
        (d / "rk.txt").write_text("\n".join(rk) + "\n")
        (d / "status.txt").write_text(f"OK {len(ops)}\n")

    def test_gen_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            m.cmd_gen(type("A", (), {"dir": tmp, "seed": 3, "count": 12})())
            ops = m.read_case(d)
            self.assertEqual(len([o for o in ops if o[0] in "ED"]), len(ops))
            self.assertEqual(ops[0][3].hex(), CASES[0]["plaintext"])      # Annex A first
            self.assertEqual(ops[0][4].hex(), CASES[0]["ciphertext"])
            self._fake_tb(d)
            self.assertEqual(m.cmd_check(type("A", (), {"dir": tmp})()), 0)
            self._fake_tb(d, corrupt=len(ops) - 1)
            self.assertEqual(m.cmd_check(type("A", (), {"dir": tmp})()), 1)


class FakeMkvSerial:
    """The shell of sw/apps/mkv (echo, ok / error, prompt) on the model."""

    def __init__(self, broken=False):
        self.baudrate = 115200
        self.rx = bytearray()
        self.tx = bytearray(b"> ")
        self.key = None
        self.broken = broken

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
            ok, text = self._line(line)
            self.tx += text.encode() + (b"ok\r\n" if ok else b"error\r\n") + b"> "
        return len(data)

    def _line(self, line):
        words = line.split()
        if not words:
            return True, ""
        if words[0] == "key":
            l, key = int(words[1]), bytes.fromhex(words[2])
            self.key = (l, key)
            return True, f"key MKV-{l}/{len(key) * 8} R={m.rounds_for(l, len(key) * 8)} (98 cycles)\r\n"
        if words[0] in ("enc", "dec"):
            l, key = self.key
            blk = bytes.fromhex(words[1])
            out = m.encrypt(key, blk) if words[0] == "enc" else m.decrypt(key, blk)
            if self.broken and words[0] == "dec":
                out = bytes([out[0] ^ 0x80]) + out[1:]
            return True, f"out {out.hex()}\r\n"
        if words[0] == "kat":
            text = ""
            for c in CASES:
                text += (f"{c['section']} MKV-{c['block_bits']}/{c['key_bits']} R={c['rounds']}\r\n"
                         f"  key {c['key']}\r\n  pt  {c['plaintext']}\r\n  ct  {c['ciphertext']}  ok\r\n")
            return True, text
        return False, "unknown command, h for help\r\n"


class ToolTest(unittest.TestCase):
    def test_verify(self):
        board = bow32_mkv.MkvBoard(FakeMkvSerial())
        board.sync()
        ops, per_version, errors = bow32_mkv.verify(board, 12, seed=4, progress=False)
        self.assertEqual((ops, errors), (36, []))
        self.assertEqual(set(per_version.values()), {2})

    def test_verify_finds_errors(self):
        board = bow32_mkv.MkvBoard(FakeMkvSerial(broken=True))
        board.sync()
        ops, _, errors = bow32_mkv.verify(board, 6, seed=4, progress=False)
        self.assertEqual(len(errors), 12)            # dec(enc(x)) and dec(random) of every case

    def test_kat(self):
        board = bow32_mkv.MkvBoard(FakeMkvSerial())
        board.sync()
        text = board.command("kat")
        self.assertEqual(bow32_mkv.check_kat(text.replace("\r", "")), [])
        bad = text.replace(CASES[4]["ciphertext"], "00" * 32)
        self.assertEqual(len(bow32_mkv.check_kat(bad.replace("\r", ""))), 1)


if __name__ == "__main__":
    unittest.main()
