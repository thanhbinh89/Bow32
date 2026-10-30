# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/csi2/csi2_model.py (the CSI-2 receiver reference
model): MIPI check vectors, ECC/CRC/RAW10, the aligner, the receiver rules,
and a round trip of every generated test through the checker with a perfect
(model generated) DUT output. Run: python3 -m unittest discover -s tools/tests
"""

import contextlib
import io
import itertools
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "csi2"))
import csi2_model as m  # noqa: E402


class EccCrcTest(unittest.TestCase):
    def test_ecc_spec_vectors(self):
        for di, wc, ecc in [(0x2B, 0x0960, 0x1D), (0x00, 0x0001, 0x1A), (0x37, 0x01F0, 0x3F)]:
            self.assertEqual(m.ecc6(di | wc << 8), ecc)
            self.assertEqual(m.header(di >> 6, di & 0x3F, wc), [di, wc & 0xFF, wc >> 8, ecc])

    def test_ecc_single_bit_errors_corrected(self):
        hdr = m.header(1, 0x2B, 0x1234)
        for bit in range(32):
            h = list(hdr)
            h[bit >> 3] ^= 1 << (bit & 7)
            st, di, wc = m.ecc_decode(h)
            # ECC[7:6] are ignored, P0..P5 and D0..D23 are corrected
            self.assertEqual(st, m.ECC_OK if bit >= 30 else m.ECC_CORR, bit)
            self.assertEqual((di, wc), (hdr[0], 0x1234), bit)

    def test_ecc_double_bit_errors_detected(self):
        hdr = m.header(2, 0x00, 0xBEEF)
        for a, b in itertools.combinations(range(30), 2):
            h = list(hdr)
            for bit in (a, b):
                h[bit >> 3] ^= 1 << (bit & 7)
            self.assertEqual(m.ecc_decode(h)[0], m.ECC_ERR, (a, b))

    def test_crc_spec_vectors(self):
        a = bytes.fromhex("FF000002B9DCF372BBD4B85AC875C27C81F805DFFF000001")
        b = bytes.fromhex("FF0000001EF01EC74F8278C582E08C70D23C78E9FF000001")
        self.assertEqual(m.crc16(a), 0x00F0)
        self.assertEqual(m.crc16(b), 0xE569)
        pkt = m.long_packet(0, 0x2B, list(a))
        self.assertEqual(pkt[-2:], [0xF0, 0x00])
        self.assertEqual(m.crc16(b""), 0xFFFF)


class PixelLaneTest(unittest.TestCase):
    def test_raw10(self):
        px = [0x3FF, 0x000, 0x155, 0x2AA]
        self.assertEqual(m.raw10_pack(px), [0xFF, 0x00, 0x55, 0xAA, 0b10_01_00_11])
        data = list(range(23))
        self.assertEqual(len(m.raw10_unpack(data)), 16)          # 3 leftover bytes dropped
        px = [(i * 37) & 0x3FF for i in range(64)]
        self.assertEqual(m.raw10_unpack(m.raw10_pack(px)), px)
        self.assertEqual(m.raw8_unpack([0x80, 0x01]), [0x200, 0x004])

    def test_lanes(self):
        data = list(range(11))
        self.assertEqual(m.lane_split(data, 2), [[0, 2, 4, 6, 8, 10], [1, 3, 5, 7, 9]])
        self.assertEqual(m.lane_merge(m.lane_split(data, 2)), data)
        self.assertEqual(m.lane_split(data, 1), [data])

    def test_aligner_every_phase(self):
        data = [0x12, 0x00, 0xB8, 0xFF, 0x47]
        for pre in range(16, 40):
            bits = [0] * pre + m.to_bits([m.SYNC] + data)
            b = m.align_search(bits)
            self.assertEqual(b, pre - 8)
            self.assertEqual(m.from_bits(bits[b + 16:]), data)

    def test_aligner_corrupted_sync(self):
        # one bit slip: 0x70 + data bit 0 = 1 completes the pattern 1 bit early
        rx = m.lane_receive([0x01, 0x02], 0x70, 0, 0)
        self.assertTrue(rx.locked)
        self.assertNotEqual(rx.data[:2], [0x01, 0x02])
        self.assertFalse(m.lane_receive([0x55] * 4, 0xB0, 0, 3).locked)

    def test_find_lane_bytes(self):
        lane = [0x2B, 0x60, 0x09, 0x1D, 0x11]
        bits = [1, 0, 1] + [0] * 21 + m.to_bits([m.SYNC] + lane) + [1] * 40
        words = m.from_bits(bits)
        self.assertEqual(m.find_lane_bytes(words, lane), len(lane))
        self.assertEqual(m.find_lane_bytes(words, [0x2C]), -1)


class BurstTest(unittest.TestCase):
    def burst(self, **kw):
        return m.Burst(0, 0x2B, 10, list(range(10)), **kw)

    def test_skew(self):
        self.assertIsNotNone(m.burst_receive(self.burst(zeros=(4, 0), phase=(7, 0)), 2).merged)
        r = m.burst_receive(self.burst(zeros=(0, 12)), 2)
        self.assertTrue(r.skew)
        self.assertIsNone(r.merged)
        self.assertIn("skew", m.burst_receive(self.burst(zeros=(8, 0)), 2).note)

    def test_bad_sync_one_lane(self):
        r = m.burst_receive(self.burst(sync=(m.SYNC, 0x00)), 2)
        self.assertEqual(r.sot_err, [1])
        self.assertTrue(r.skew)

    def test_merged_real_bytes(self):
        b = self.burst()
        r = m.burst_receive(b, 2)
        self.assertEqual(r.real, len(b.packet()))
        self.assertEqual(r.merged[:r.real], b.packet())
        b.trunc = 7
        self.assertEqual(m.burst_receive(b, 2).real, 7)


def receiver(lanes=2, **kw):
    cfg = dict(m.DEFAULT_CFG, lanes=lanes, dut_lanes=lanes, **kw)
    rx = m.Receiver(cfg)
    rx.write(m.REG["CTRL"], m.CTRL_PHY_EN | m.CTRL_RX_EN | (m.CTRL_LANES if lanes == 2 else 0)
             | m.DT_RAW10 << 8)
    rx.idle()
    return rx


def read(rx, name):
    return rx.read(m.REG[name]).value


class ReceiverTest(unittest.TestCase):
    def test_frame(self):
        rx = receiver()
        px = [(7 * i) & 0x3FF for i in range(16)]
        rx.burst(m.Burst(0, m.DT_FS, 5))
        rx.burst(m.Burst(0, m.DT_EMB, 20, [1] * 20))
        for _ in range(3):
            rx.burst(m.Burst(0, m.DT_RAW10, 20, m.raw10_pack(px)))
        rx.burst(m.Burst(0, m.DT_FE, 5))
        self.assertEqual(read(rx, "FRAME_INFO"), 5 << 16 | 3)
        self.assertEqual(read(rx, "FRAME_SUM"), 3 * sum(px))
        self.assertEqual(read(rx, "LINE_INFO"), 20 | 0x2B << 16)
        self.assertEqual(read(rx, "CNT_PKT"), 6)
        self.assertEqual(read(rx, "CNT_LINE"), 3)
        self.assertEqual(read(rx, "CNT_DROP"), 1)
        self.assertEqual(read(rx, "CNT_BURST"), 6 | 6 << 16)
        self.assertEqual(read(rx, "CNT_MISC") & 0xFFFF, 6)          # clock lane HS entries
        self.assertEqual(rx.read(m.REG["FRAME_TIME"]).kind, "exact")  # one FS only: 0
        lines = [it for it in rx.items if isinstance(it, m.LineOut)]
        self.assertEqual([it.sof for it in lines], [True, False, False])
        self.assertEqual(lines[0].px, px)

    def test_errors(self):
        rx = receiver(lanes=1)
        rx.burst(m.Burst(0, m.DT_FE, 0))                 # first FE after start: ignored
        self.assertEqual(read(rx, "ERR_STATUS"), 0)
        rx.burst(m.Burst(0, m.DT_FS, 0))
        rx.burst(m.Burst(0, m.DT_FS, 0))                 # FS in a frame
        rx.burst(m.Burst(0, m.DT_RAW10, 7, list(range(7))))       # WC % 5 != 0
        rx.burst(m.Burst(0, m.DT_RAW10, 5, list(range(5)), pflip=3))
        rx.burst(m.Burst(0, m.DT_FE, 0, hflip=(3, 17)))  # uncorrectable: frame stays open
        rx.burst(m.Burst(0, m.DT_FE, 0, hflip=(9, -1)))  # corrected
        self.assertEqual(read(rx, "CNT_ECC"), 1 | 1 << 16)
        self.assertEqual(read(rx, "CNT_CRC"), 1)
        self.assertEqual(read(rx, "CNT_MISC") >> 24, 2)
        self.assertEqual(read(rx, "FRAME_INFO"), 2)
        e = m.ERR
        self.assertEqual(read(rx, "ERR_STATUS"), 1 << e["ecc_corr"] | 1 << e["ecc_err"] |
                         1 << e["crc"] | 1 << e["format"] | 1 << e["frame"])

    def test_truncation_rule(self):
        rx = receiver()
        b = m.Burst(0, m.DT_RAW10, 100, list(range(100)), trunc=30)
        self.assertEqual(m.burst_problem(rx, b), "")
        rx.burst(b)
        self.assertEqual(rx.items[-1].fuzzy, "trunc")
        self.assertEqual(len(rx.items[-1].px), 20)        # 26 payload bytes -> 5 groups
        self.assertEqual(read(rx, "CNT_CRC"), 1 << 16)
        b.trunc = 70                                      # the trail could complete it
        self.assertIn("open packet", m.burst_problem(rx, b))

    def test_lp_fsm(self):
        rx = receiver()
        rx.lp_item(1, "10", 100)                         # escape entry
        rx.idle()
        rx.lp_item(1, "01", 100)
        rx.lp_item(1, "11", 100)                         # aborted request: no error
        rx.lp_item(2, "00", 100)                         # LP-00 from Stop
        rx.idle()
        rx.write(m.REG["PHY_CFG"], m.PHY_CFG_RESET & ~0xF00 | 4 << 8)
        rx.lp_item(1, "10", 9)                           # glitch below LP_FILTER
        self.assertEqual(read(rx, "CNT_MISC") >> 16 & 0xFF, 2)
        self.assertEqual(read(rx, "CNT_BURST"), 0)

    def test_log_modes(self):
        for mode, first, n in [(0, 0, 64), (2, 3, 64), (4, None, None), (6, 3, 4)]:
            rx = receiver()
            rx.write(m.REG["LOG_CTRL"], 1 | mode)
            for i in range(3):
                rx.burst(m.Burst(1, 0x08, i))
            rx.burst(m.Burst(0, m.DT_FS, 1))
            rx.burst(m.Burst(0, m.DT_RAW10, 5, [0] * 5))
            rx.burst(m.Burst(0, m.DT_RAW10, 5, [0] * 5))
            rx.burst(m.Burst(0, m.DT_FE, 1))
            for i in range(70):
                rx.burst(m.Burst(2, 0x09, i))
            ctrl = read(rx, "LOG_CTRL")
            self.assertEqual(ctrl & 0x106, 0x100 | mode, mode)
            log = [read(rx, "LOG") if i == 0 else rx.read(m.REG["LOG"] + 4 * i).value
                   for i in range(64)]
            if mode == 4:                                # circular until the FE: 7 entries
                self.assertEqual(log[6] & 0x3F, m.DT_FE)
                self.assertEqual(ctrl >> 16 & 0x3F, 0)
            else:
                self.assertEqual(log[0] & 0x3F, [0x08, m.DT_FS, 0, m.DT_FS][mode >> 1])
                if mode == 6:
                    self.assertEqual(log[n - 1] & 0x3F, m.DT_FE)


def perfect_dut(d):
    """Write out.txt/regs.txt the way an RTL that matches the model would."""
    cfg = m.read_cfg(d / "cfg.txt")
    lines = (d / "stim.txt").read_text().splitlines()
    rx, exps = m.run_stim(cfg, lines)
    out = []
    for it in rx.items:
        if isinstance(it, m.Mark):
            out.append(f"mark {it.n}")
        elif isinstance(it, m.LineOut):
            px = it.px if it.fuzzy != "stop" else it.px[:3]
            px = px + ([0x155] if it.fuzzy == "trunc" else [])
            for k, v in enumerate(px):
                out.append(f"{v:03x} {int(it.sof and k == 0)} {int(k == len(px) - 1 and it.fuzzy != 'stop')}")
    (d / "out.txt").write_text("\n".join(out) + "\n")
    tend = {i: 1_000_000 * i for i in range(rx.burst_idx)}
    sums = {}
    for it in rx.items:
        if isinstance(it, m.LineOut) and it.frame >= 0:
            extra = 0x155 if it.fuzzy == "trunc" else 0
            sums[it.frame] = sums.get(it.frame, 0) + (sum(it.px[:3]) if it.fuzzy == "stop" else
                                                      sum(it.px) + extra)
    regs = []
    for a, e in exps:
        if e.kind == "exact":
            v = e.value
        elif e.kind == "time":
            v = (tend[e.b] - tend[e.a]) // cfg["cpu_ps"]
        elif e.kind in ("range", "nonzero"):
            v = max(e.value, 1)
        elif e.kind == "framesum":
            v = sums[e.value] & 0xFFFFFFFF
        elif e.kind == "raw":
            v = 0
            if e.a is not None:
                for l, lane in enumerate(m.lane_split(e.a.sent(), e.b)):
                    w = m.from_bits([0] * 13 + m.to_bits([m.SYNC] + lane) + [0] * 512)[e.value]
                    v |= w << (8 * l)
        else:
            v = 0
        regs.append(f"rd {a:03x} {v:08x}")
    seg = 0
    for f in rx.frames:
        while seg < f["seg"]:
            seg += 1
            regs.append(f"mark {seg}")
        fs = sums.get(f["id"], 0) & 0xFFFFFFFF if f["id"] in rx.fuzzy_frames else (f["sum"] or 0)
        regs.append(f"fe {f['info']:08x} {fs:08x}")
    for s in sorted(set(rx.seg_expect)):
        for name, cond in [("ce_bad", 0), ("ce_rise_toggle", 0), ("lat0", 20000), ("flips", 0)]:
            c = rx.seg_expect[s].get(name, "")
            regs.append(f"inv {s} {name} {1 if c == 'nz' else cond}")
    regs += [f"tend {i} {t}" for i, t in tend.items()] + ["end"]
    (d / "regs.txt").write_text("\n".join(regs) + "\n")
    return seg


class GenCheckTest(unittest.TestCase):
    def gen(self, d, *argv):
        sys.argv = ["csi2_model.py", "gen", str(d)] + list(argv)
        with contextlib.redirect_stdout(io.StringIO()):
            m.main()

    def test_all_tests_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            cases = [(t, "--seed", "2") for t in sorted(m.TESTS)]
            cases += [("random", "--seed", str(s), *o) for s in (1, 2) for o in
                      [(), ("--errors",), ("--raw8", "--errors", "--lanes", "1"), ("--contclk",),
                       ("--errors", "--contclk", "--lanes", "1", "--dut-lanes", "2")]]
            for n, (test, *argv) in enumerate(cases):
                d = Path(tmp) / f"c{n}"
                self.gen(d, "--test", test, *argv)
                first = (d / "stim.txt").read_text()
                self.gen(d, "--test", test, *argv)
                self.assertEqual((d / "stim.txt").read_text(), first, "deterministic generator")
                perfect_dut(d)
                errs, _ = m.check(d)
                self.assertEqual(errs, [], (test, argv))

    def test_checker_catches_mistakes(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.gen(d, "--seed", "4", "--errors")
            perfect_dut(d)
            out = (d / "out.txt").read_text().splitlines()
            regs = (d / "regs.txt").read_text().splitlines()
            px = next(i for i, ln in enumerate(out) if not ln.startswith("mark"))
            v = int(out[px].split()[0], 16) ^ 1
            bad = list(out)
            bad[px] = f"{v:03x} " + " ".join(out[px].split()[1:])
            (d / "out.txt").write_text("\n".join(bad) + "\n")
            self.assertTrue(any("pixel" in e for e in m.check(d)[0]))
            (d / "out.txt").write_text("\n".join(out[:-1]) + "\n")
            self.assertTrue(m.check(d)[0])
            (d / "out.txt").write_text("\n".join(out) + "\n")
            k = next(i for i, ln in enumerate(regs) if ln.startswith("rd 02c"))
            bad = list(regs)
            bad[k] = "rd 02c 00000063"
            (d / "regs.txt").write_text("\n".join(bad) + "\n")
            self.assertTrue(any("CNT_LINE" in e for e in m.check(d)[0]))


if __name__ == "__main__":
    unittest.main()
