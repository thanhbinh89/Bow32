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
        self.assertEqual(m.lane_split(data, 4), [[0, 4, 8], [1, 5, 9], [2, 6, 10], [3, 7]])
        self.assertEqual(m.lane_merge(m.lane_split(data, 4)), data)
        self.assertEqual([m.ctrl_lanes(n) for n in (1, 2, 4)], [0, m.CTRL_LANES, m.CTRL_LANES4])

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

    def test_aligner_deskew(self):
        bits = [0] * 20 + m.to_bits([m.DESKEW_SYNC, 0xFF] + [0x55] * 4)    # FFFFh, 0101...
        self.assertEqual(m.align_search(bits, deskew=True), (12, True))
        self.assertIsNone(m.align_search(bits))           # plain search: no sync byte
        rx = m.lane_receive([0xFF] + [0x55] * 8, m.DESKEW_SYNC, 0, 5)
        self.assertFalse(rx.locked)
        self.assertTrue(rx.deskew)
        bits = [0] * 20 + m.to_bits([m.DESKEW_SYNC] + [0x55] * 4)          # only 8 ones
        self.assertEqual(m.align_search(bits, deskew=True), (None, False))

    def test_aligner_deskew_only_after_hs_zero(self):
        # a corrupted sync byte stays a sync error even when the data hold the
        # deskew pattern (8 zero bits, 8 one bits) or end in 0x00 + a 0xFF trail
        data = [0xFF, 0x00, 0xFF, 0x00, 0x33] * 2
        bits = [0] * 16 + m.to_bits([0xB9] + data)
        self.assertEqual(m.align_search(bits, deskew=True), (None, False))
        rx = m.lane_receive(data, 0xB9, 0, 3)
        self.assertFalse(rx.locked)
        self.assertFalse(rx.deskew)
        rx = m.lane_receive([0x02, 0x00], 0xB9, 0, 0)    # lane 0 of an LS: DI, WC MSB, trail
        self.assertFalse(rx.deskew)
        # a corrupted sync ending in ones + the low ones of DI 0x2B: 8..10 ones
        for sync in (0xFC, 0xFE, 0xFF):
            pkt = m.long_packet(0, 0x2B, [0x11] * 10)
            self.assertFalse(m.lane_receive(pkt, sync, 0, 3).deskew, hex(sync))

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

    def test_deskew_lanes(self):
        def skew_cal(sync, n=2):                          # raw burst: FF then 0101... per lane
            return m.Burst(-1, 0, 0, extra=[0xFF] * n + [0x55] * (32 * n), sync=sync)
        dsk, sync = m.DESKEW_SYNC, m.SYNC
        r = m.burst_receive(skew_cal((dsk, dsk, sync, sync)), 2)
        self.assertEqual((r.sot_err, r.deskew, r.skew, r.merged), ([], [0, 1], False, None))
        r = m.burst_receive(skew_cal((sync, dsk, sync, sync)), 2)
        self.assertEqual((r.sot_err, r.deskew, r.skew), ([], [1], True))
        b = skew_cal((dsk, dsk, sync, sync))
        self.assertEqual(m.Burst.parse(b.stim().split()[1:]).sent(), b.sent())
        r = m.burst_receive(self.burst(sync=(dsk, dsk, sync, sync)), 2)
        self.assertEqual(r.sot_err, [0, 1])               # 0xFF + a packet: only 8 ones
        # 4 lanes: all lanes deskew; lane 0 alone or all but lane 0: skew
        r = m.burst_receive(skew_cal((dsk,) * 4, 4), 4)
        self.assertEqual((r.sot_err, r.deskew, r.skew, r.merged), ([], [0, 1, 2, 3], False, None))
        r = m.burst_receive(skew_cal((dsk, sync, sync, sync), 4), 4)
        self.assertEqual((r.sot_err, r.deskew, r.skew), ([], [0], True))
        r = m.burst_receive(skew_cal((sync, dsk, dsk, dsk), 4), 4)
        self.assertEqual((r.sot_err, r.deskew, r.skew), ([], [1, 2, 3], True))

    def test_extra_bytes(self):
        b = self.burst(extra=[1, 2, 3])
        self.assertEqual(b.sent(), b.packet() + [1, 2, 3])
        self.assertEqual(m.Burst.parse(b.stim().split()[1:]).extra, [1, 2, 3])
        self.assertEqual(m.burst_receive(b, 2).real, len(b.packet()) + 3)

    def test_merged_real_bytes(self):
        b = self.burst()
        r = m.burst_receive(b, 2)
        self.assertEqual(r.real, len(b.packet()))
        self.assertEqual(r.merged[:r.real], b.packet())
        b.trunc = 7
        self.assertEqual(m.burst_receive(b, 2).real, 7)

    def test_four_lanes(self):
        # byte 4k + l on lane l; any packet length (last bytes on lanes 0..3)
        for wc in (5, 10, 11, 12, 13):
            b = m.Burst(0, 0x2B, wc, list(range(wc)))
            r = m.burst_receive(b, 4)
            self.assertEqual(r.merged[:r.real], b.packet(), wc)
            self.assertEqual(r.real, len(b.packet()), wc)
        # skew: up to 4 bytes on any lane, >= 12 drops the burst, between is not predicted
        b = m.Burst(0, 0x2B, 10, list(range(10)), zeros=(0, 4, 0, 1), phase=(3, 0, 7, 5))
        self.assertIsNotNone(m.burst_receive(b, 4).merged)
        b.zeros = (0, 0, 13, 0)
        self.assertTrue(m.burst_receive(b, 4).skew)
        b.zeros = (6, 0, 0, 0)
        self.assertIn("skew", m.burst_receive(b, 4).note)
        # a bad sync byte on lane 3 only (WC 6: no false lock later on that lane,
        # e.g. in the ECC byte): sync error there, skew error, no packet
        b = m.Burst(0, 0x2B, 6, [0xFF] * 6, sync=(m.SYNC, m.SYNC, m.SYNC, 0x00))
        r = m.burst_receive(b, 4)
        self.assertEqual((r.sot_err, r.skew, r.merged), ([3], True, None))

    def test_skew_exact(self):
        # PHY without lane offsets, regular sync and one bit phase on every
        # lane: the lane merge takes up to SKEW_MAX (6) byte clocks, from 7 on
        # the burst is dropped; otherwise 5..11 stay unpredicted
        self.assertEqual(m.SKEW_MAX, 6)
        for lanes, late in ((2, (0, 1)), (4, (0, 3))):
            for n in (5, 6, 7, 8, 11):
                for k in late:
                    zeros = tuple(n if l == k else 0 for l in range(lanes)) + (0,) * (4 - lanes)
                    b = m.Burst(0, 0x2B, 40, list(range(40)), zeros=zeros, phase=(5,) * 4)
                    r = m.burst_receive(b, lanes, exact=True)
                    self.assertEqual(r.note, "")
                    if n <= 6:
                        self.assertEqual(r.merged[:r.real], b.packet(), (lanes, n, k))
                    else:
                        self.assertEqual((r.skew, r.merged), (True, None), (lanes, n, k))
                    self.assertIn("skew", m.burst_receive(b, lanes).note)
            # one lane early by 7: dropped too
            b = m.Burst(0, 0x2B, 40, list(range(40)), zeros=(0,) + (7,) * (lanes - 1) +
                        (0,) * (4 - lanes), phase=(2,) * 4)
            self.assertTrue(m.burst_receive(b, lanes, exact=True).skew)
            # different bit phases: back to the coarse rule
            b.phase = (2, 3, 2, 2)
            self.assertIn("skew", m.burst_receive(b, lanes, exact=True).note)
        # a corrupted sync byte (it may lock late): not the exact rule either
        b = m.Burst(0, 0x2B, 40, list(range(40)), zeros=(6, 0, 0, 0), phase=(1,) * 4,
                    sync=(m.SYNC, m.SYNC ^ 0x01, m.SYNC, m.SYNC))
        self.assertFalse(m.burst_receive(b, 4, exact=True).merged)

    def test_skew_exact_config(self):
        # the exact rule needs a PHY without lane offsets
        base = dict(m.DEFAULT_CFG, lanes=4, dut_lanes=4)
        self.assertTrue(m.Receiver(base).skew_exact)
        self.assertTrue(m.Receiver(dict(base, **m.VERSAL_CFG)).skew_exact)
        self.assertTrue(m.Receiver(dict(base, **dict(m.VERSAL_CFG, v_burst_rst=1))).skew_exact)
        self.assertFalse(m.Receiver(dict(base, **dict(m.VERSAL_CFG, v_lat_lane=1))).skew_exact)
        self.assertFalse(m.Receiver(dict(base, **dict(m.VERSAL_CFG, v_gap_pm=10))).skew_exact)

    def test_stim_round_trip(self):
        b = m.Burst(2, 0x2B, 5, [1, 2, 3, 4, 5], hflip=(3, -1), pflip=7, trunc=9,
                    sync=(0xB8, 0xB9, 0xB8, 0x38), zeros=(0, 1, 2, 3), phase=(7, 6, 5, 4), zero_ns=12)
        f = b.stim().split()
        self.assertEqual(len(f), 22)
        self.assertEqual(m.Burst.parse(f[1:]), b)


def receiver(lanes=2, dut_lanes=None, versal=False, **kw):
    cfg = dict(m.DEFAULT_CFG, lanes=lanes, dut_lanes=dut_lanes or lanes, **kw)
    if versal:
        cfg.update(m.VERSAL_CFG)
    rx = m.Receiver(cfg)
    if versal:
        rx.phy_ready()
    rx.write(m.REG["CTRL"], m.CTRL_PHY_EN | m.CTRL_RX_EN | m.ctrl_lanes(lanes) | m.DT_RAW10 << 8)
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

    def test_line_error(self):
        rx = receiver()
        rx.burst(m.Burst(0, m.DT_FS, 1))
        rx.burst(m.Burst(0, m.DT_RAW10, 5, [0] * 5, pflip=3))      # CRC error
        rx.burst(m.Burst(0, m.DT_RAW10, 3, [0] * 3))               # no pixel group: lost
        rx.burst(m.Burst(0, m.DT_RAW10, 5, [0] * 5))               # reports the lost line
        rx.burst(m.Burst(0, m.DT_RAW10, 5, [0] * 5))
        lines = [it for it in rx.items if isinstance(it, m.LineOut)]
        self.assertEqual([it.err for it in lines], [True, True, False])

    def test_overflow_keeps_lines(self):
        rx = receiver()
        rx.nocheck("ovf")
        rx.fifo_used = rx.cfg["fifo_depth"] + 2 - 3   # 3 free slots incl. the output registers
        rx.burst(m.Burst(0, m.DT_FS, 1))
        rx.burst(m.Burst(0, m.DT_RAW10, 20, m.raw10_pack(list(range(16)))))   # 4 groups
        rx.burst(m.Burst(0, m.DT_RAW10, 20, m.raw10_pack(list(range(16)))))
        rx.burst(m.Burst(0, m.DT_RAW10, 5, m.raw10_pack([7] * 4)))
        lines = [it for it in rx.items if isinstance(it, m.LineOut)]
        # 2 groups written, then cut: its last group (err); next line lost; the
        # 1 group line has no free slot either: lost too
        self.assertEqual([(it.px, it.sof, it.err) for it in lines],
                         [([0, 1, 2, 3, 4, 5, 6, 7, 12, 13, 14, 15], True, True)])
        self.assertEqual(read(rx, "CNT_DROP") >> 16, 3)
        self.assertTrue(rx.lost_pend)

    def test_lost_burst_flags_next_line(self):
        rx = receiver(lanes=1)
        bad = m.Burst(0, m.DT_RAW10, 20, [0x55] * 20, sync=(0xB9, m.SYNC))
        self.assertEqual(m.burst_receive(bad, 1).sot_err, [0])     # (WC 5: false lock later)
        rx.burst(m.Burst(0, m.DT_FS, 1))
        rx.burst(m.Burst(0, m.DT_RAW10, 20, [0x55] * 20))
        rx.burst(bad)                                              # SOT: line lost
        rx.burst(m.Burst(0, m.DT_RAW10, 20, [0x55] * 20))          # reports it
        rx.burst(m.Burst(0, m.DT_RAW10, 20, [0x55] * 20, hflip=(3, 17)))   # last line lost
        rx.burst(m.Burst(0, m.DT_FE, 1))
        lines = [it for it in rx.items if isinstance(it, m.LineOut)]
        self.assertEqual([(it.sof, it.err) for it in lines], [(True, False), (False, True)])
        e = m.ERR
        self.assertEqual(read(rx, "FRAME_ERR"), 1 << e["sot"] | 1 << e["ecc_err"])
        rx.burst(m.Burst(0, m.DT_FS, 2))
        rx.burst(m.Burst(0, m.DT_RAW10, 5, [0] * 5))
        rx.burst(m.Burst(0, m.DT_FE, 2))
        self.assertEqual(read(rx, "FRAME_ERR"), 0)                 # per frame
        self.assertEqual(read(rx, "ERR_STATUS"), 1 << e["sot"] | 1 << e["ecc_err"])

    def test_frame_skipped_before_first_line(self):
        rx = receiver(lanes=1)
        rx.burst(m.Burst(0, m.DT_LS, 1, hflip=(3, 17)))          # between frames: next frame
        rx.burst(m.Burst(0, m.DT_FS, 1))
        rx.burst(m.Burst(0, m.DT_RAW10, 5, [0] * 5, hflip=(3, 17)))  # first line lost
        rx.burst(m.Burst(0, m.DT_RAW10, 5, [1] * 5))
        rx.burst(m.Burst(0, m.DT_FE, 1))
        rx.burst(m.Burst(0, m.DT_RAW10, 5, [2] * 5))               # outside a frame
        self.assertEqual([(it.sof, it.err) for it in rx.items if isinstance(it, m.LineOut)],
                         [(False, False)])
        e = m.ERR
        self.assertEqual(read(rx, "FRAME_ERR"), 1 << e["ecc_err"] | 1 << e["skip"])
        self.assertEqual(read(rx, "FRAME_SUM"), 0)
        self.assertEqual(read(rx, "FRAME_INFO"), 1 << 16 | 1)      # lines received
        self.assertEqual(read(rx, "CNT_MISC") >> 24, 1)           # one skip

    def test_output_stage_one_pixel_head(self):
        # tready low from the start, the first group has 1 pixel: it moves
        # whole into the m_axis flops, the stage holds 3 groups
        rx = receiver()
        rx.write(m.REG["CTRL"], m.CTRL_PHY_EN | m.CTRL_RX_EN | m.CTRL_LANES | m.DT_RAW8 << 8)
        rx.nocheck("ovf")
        rx.burst(m.Burst(0, m.DT_FS, 1))
        rx.burst(m.Burst(0, m.DT_RAW8, 1, [9]))
        for _ in range(17):
            rx.burst(m.Burst(0, m.DT_RAW8, 64, [1] * 64))
        self.assertEqual(rx.out_cap, 3)
        self.assertEqual(rx.fifo_used, rx.cfg["fifo_depth"] + 3)
        last = [it for it in rx.items if isinstance(it, m.LineOut)][-1]
        self.assertEqual((len(last.px), last.err), (8, True))      # cut: 1 group + its last

    def test_extra_and_byte_enables(self):
        rx = receiver()
        rx.write(m.REG["CTRL"], m.ctrl_extra(64), be=0x4)
        b = m.Burst(0, m.DT_FS, 1, extra=m.Burst(0, m.DT_RAW10, 80, [0] * 80).packet())
        self.assertEqual(m.burst_problem(rx, b), "")
        rx.burst(b)
        self.assertEqual(read(rx, "CNT_EXT"), 1)
        # line 1 was lost in the FS burst: the frame is skipped
        both = 1 << m.ERR["extra"] | 1 << m.ERR["skip"]
        self.assertEqual(read(rx, "ERR_STATUS"), both)
        self.assertTrue(rx.skip)
        rx.write(m.REG["ERR_STATUS"], m.ERR_ALL, be=0x1)   # bits 10, 11 are in byte 1
        self.assertEqual(read(rx, "ERR_STATUS"), both)
        rx.write(m.REG["CNT_CLR"], 1, be=0x2)
        self.assertEqual(read(rx, "CNT_EXT"), 1)
        self.assertIn("trail", m.burst_problem(rx, m.Burst(0, m.DT_FS, 1, extra=[0] * 30)))

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

    def test_four_lane_registers(self):
        rx = receiver(lanes=4, versal=True, fifo_depth=512)
        self.assertEqual(read(rx, "INFO"), 0x0200C834)              # Huins camera build
        self.assertEqual(read(rx, "CTRL"), 0x2B83)
        px = [(5 * i) & 0x3FF for i in range(16)]
        rx.burst(m.Burst(0, m.DT_FS, 1))
        rx.burst(m.Burst(0, m.DT_RAW10, 20, m.raw10_pack(px)))
        rx.burst(m.Burst(0, m.DT_FE, 1))
        self.assertEqual(read(rx, "CNT_BURST"), 3 | 3 << 16)
        self.assertEqual(read(rx, "CNT_BURST23"), 3 | 3 << 16)
        self.assertEqual(read(rx, "FRAME_SUM"), sum(px))
        e = rx.read(m.REG["STATUS"])
        self.assertEqual((e.value, e.mask), (0x000F403F | 3 << 16, 0x3F5FFF))  # LP-11 x 5, PHY_RDY
        # lane 2 only with LP-01: STATUS[17:16]; LP-00 from Stop on lane 3: LP error
        rx.lp_item(4, "01", 3000)
        self.assertEqual(rx.read(m.REG["STATUS"]).value >> 16 & 0xF, 0b1101)
        rx.idle()
        rx.lp_item(8, "00", 200)
        self.assertEqual(read(rx, "CNT_MISC") >> 16 & 0xFF, 1)
        # 2 of the 4 lanes: lanes 2/3 off (their FSMs stay in Off)
        rx.write(m.REG["CTRL"], m.CTRL_PHY_EN | m.CTRL_RX_EN | m.CTRL_LANES | m.DT_RAW10 << 8)
        self.assertEqual(rx.lanes, 2)
        self.assertEqual(rx.fsm[2:4], ["off", "off"])
        # with Lanes = 2 the LANES4 bit reads 0
        self.assertEqual(read(receiver(), "CTRL") & 0x80, 0)

    def test_dly_vid(self):
        cfg = dict(m.DEFAULT_CFG, lanes=4, dut_lanes=4, **m.VERSAL_CFG)
        rx = m.Receiver(cfg)
        self.assertEqual(read(rx, "STATUS") & m.STATUS_PHY_RDY, 0)
        self.assertEqual(read(rx, "DLY2"), 0)                       # CNTVALUEOUT 0 before init
        rx.phy_ready()
        self.assertEqual(read(rx, "DLY2"), cfg["bisc2"] << 16)     # BISC tap, nothing loaded
        rx.write(m.REG["DLY2"], 0x155)
        rx.bus_access()
        e = rx.read(m.REG["DLY2"])
        self.assertEqual((e.value & 0x1FF, e.mask), (0x155, 0x1FF))  # load in flight
        rx.time_step()
        self.assertEqual(read(rx, "DLY2"), 0x155 | 0x155 << 16)    # no byte clock needed
        rx.write(m.REG["DLY2"], 0x10)
        rx.bus_access()
        rx.write(m.REG["DLY2"], 0x11)                              # back to back: may merge
        rx.close_seg()
        self.assertEqual(rx.seg_expect[0]["dly_loads2"], "any")
        rx.mark(1)
        rx.write(m.REG["DLY1"], 1)
        rx.bus_access()
        rx.bus_access()
        rx.write(m.REG["DLY1"], 2)
        rx.close_seg()
        self.assertEqual(rx.seg_expect[1]["dly_loads1"], "=2")
        self.assertEqual(rx.seg_expect[1]["dly_loads0"], "=0")
        # PHY re-init: PHY_RDY and CNTVALUEOUT drop, the written tap stays in
        # DLYn[8:0], the BISC tap comes back once the PHY is ready again
        rx.phy_reinit()
        self.assertEqual(read(rx, "STATUS") & m.STATUS_PHY_RDY, 0)
        self.assertEqual(read(rx, "DLY1"), 2)
        self.assertFalse(rx.byte_clock_ok())
        rx.phy_ready()
        self.assertEqual(read(rx, "STATUS") & m.STATUS_PHY_RDY, m.STATUS_PHY_RDY)
        self.assertEqual(read(rx, "DLY1"), 2 | cfg["bisc1"] << 16)

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


class PpiTest(unittest.TestCase):
    """The PPI rendering (gen --ppi) and the model's view of the controller alone."""

    def test_merge_rule(self):
        # gapless lanes d byte clocks apart: up to SKEW_MAX (6) merged, from 7 on dropped
        for d in range(10):
            push = [list(range(10, 40)), list(range(10 + d, 40 + d))]
            got = m.ppi_merge(push, 50 + d, 30)
            self.assertEqual(got, 30 if d <= m.SKEW_MAX else "skew", d)
        # the early lane pausing before the late one starts holds fewer bytes: 7 merged
        early = [10, 11, 12, 14] + list(range(15, 45))
        self.assertIsInstance(m.ppi_merge([early, list(range(17, 50))], 60, 20), int)
        # after the start a lane waiting 9 cycles overflows the other lane's FIFO: a needed
        # byte lost is an error of the rendering, a trail byte is not
        push = [list(range(10, 40)), [10] + list(range(21, 50))]
        self.assertEqual(m.ppi_merge(push, 60, 25), "lost")
        self.assertIsInstance(m.ppi_merge(push, 60, 8), int)
        # RxActiveHS low one cycle after the last byte: its word does not leave the FIFOs
        self.assertEqual(m.ppi_merge([[10, 11, 12], [10, 11, 12]], 14, 3), 3)
        self.assertEqual(m.ppi_merge([[10, 11, 12], [10, 11, 12]], 13, 3), 2)

    def gen(self, mode, lanes=2, **kw):
        cfg = dict(m.DEFAULT_CFG, test="random", seed=3, lanes=lanes, dut_lanes=lanes,
                   ppi=m.PPI_MODES[mode], tready=100, **kw)
        g = m.Gen(cfg)
        m.on(g)
        return g

    @staticmethod
    def bursts(lines):
        """[(pkt line, {lane: fields}, stop, tend)] of the ppl / ppb lines."""
        out, cur, pkt = [], {}, None
        for ln in lines:
            f = ln.split()
            if f[0] == "pkt":
                pkt = m.Burst.parse(f[1:])
            elif f[0] == "ppl":
                b = f[9]
                cur[int(f[1])] = dict(zip("a f s e k kl h".split(), map(int, f[2:9])),
                                      b=[] if b == "-" else
                                      [-1 if b[i:i + 2] == "--" else int(b[i:i + 2], 16)
                                       for i in range(0, len(b), 2)])
            elif f[0] == "ppb":
                out.append((pkt, cur, int(f[3]), int(f[4])))
                cur = {}
        return out

    def test_rendering(self):
        for mode in m.PPI_MODES:
            for lanes in (1, 2, 4):
                g = self.gen(mode, lanes, fifo_depth=512 if lanes == 4 else 256)
                if mode == "bow":
                    g.ppi.gap = 0.3
                for w in (4, 16, 64):
                    g.send(g.line(0, m.DT_RAW10, w))
                g.send(g.short(0, m.DT_FS, 1))
                bs = self.bursts(g.lines)
                self.assertEqual(len(bs), 4)
                gaps = 0
                for b, ln, stop, tend in bs:
                    self.assertEqual(sorted(ln), list(range(lanes)))
                    for l, x in ln.items():
                        if mode == "bow":
                            self.assertGreaterEqual(x["s"] - x["a"], 4)     # RAW: 00 .. B8 first
                        else:
                            self.assertEqual(x["a"], x["s"])                # with RxSyncHS
                            self.assertNotIn(-1, x["b"])                    # no gaps
                        gaps += x["b"].count(-1)
                        self.assertEqual(x["e"], -1)
                    # the lane bytes, merged: the burst, then its trail
                    per = [[v for v in ln[l]["b"] if v >= 0] for l in range(lanes)]
                    n = min(len(p) for p in per)
                    merged = [per[l][k] for k in range(n) for l in range(lanes)]
                    self.assertEqual(merged[:len(b.sent())], b.sent())
                    self.assertGreater(stop, 0)
                if mode == "bow":
                    self.assertGreater(gaps, 0)

    def test_errors_rendering(self):
        # a sync error on lane 1: bow ErrSotSyncHS one cycle after the fall, std early (at
        # the sync) with or without RxActiveHS; a skew error: the early lane fills its FIFO
        for mode in m.PPI_MODES:
            g = self.gen(mode)
            b = g.line(0, m.DT_RAW10, 32)
            b.sync = (m.SYNC, 0x00, m.SYNC, m.SYNC)
            self.assertTrue(g.pkt(b))
            b = g.line(0, m.DT_RAW10, 32)
            b.zeros = (0, 14, 0, 0)
            self.assertTrue(g.pkt(b))
            (_, ln, _, _), (_, sk, _, _) = self.bursts(g.lines)
            x = ln[1]
            self.assertEqual(x["s"], -1)
            if mode == "bow":
                self.assertEqual(x["e"], x["f"] + 1)
                self.assertGreaterEqual(x["a"], 0)
            else:
                self.assertLess(x["e"], ln[0]["s"] + len(ln[0]["b"]))
            self.assertGreaterEqual(len([v for v in sk[0]["b"] if v >= 0]), 9)
            self.assertGreaterEqual(sk[1]["s"] - sk[0]["s"], 7)

    def test_receiver(self):
        # what the band (bow) and the flat wrapper (std) give the controller
        for mode in (m.PPI_BOW, m.PPI_STD):
            rx = receiver(ppi=mode)
            rx.write(m.REG["RAW_CTRL"], 1)
            rx.burst(m.Burst(0, m.DT_FS, 1))
            self.assertEqual(read(rx, "CNT_BURST"), 0 if mode == m.PPI_STD else 1 | 1 << 16)
            self.assertEqual(read(rx, "CNT_MISC") & 0xFFFF, 0 if mode == m.PPI_STD else 1)
            self.assertEqual(read(rx, "RAW_CTRL") & 0x101, 1 if mode == m.PPI_STD else 0x100)
            rx.idle()
            rx.lp_item(1 << m.CLK, "00", 200)             # clock lane LP error: no ErrControlClk
            self.assertEqual(read(rx, "CNT_MISC") >> 16 & 0xFF, 0 if mode == m.PPI_STD else 1)
            e = rx.read(m.REG["STATUS"])
            self.assertEqual((e.value, e.mask), (0x403F | 1 << 12, 0x3FF7FF))   # LP-11, in frame
            self.assertEqual(read(rx, "BYTECLK"), 0)
        # 'lperr': counted always, a lost burst unless in the first masked cycle
        rx = receiver(ppi=m.PPI_BOW)
        rx.burst(m.Burst(0, m.DT_FS, 1))
        rx.ppi_lp_error(2, 1)
        self.assertFalse(rx.lp_lost)
        rx.ppi_lp_error(1 << m.CLK, 2)
        self.assertTrue(rx.lp_lost)
        self.assertEqual(read(rx, "CNT_MISC") >> 16 & 0xFF, 2)


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
                last = int(k == len(px) - 1 and it.fuzzy != 'stop')
                out.append(f"{v:03x} {int(it.sof and k == 0)} {last} {int(it.err) if last else 0}")
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
        regs.append(f"fe {f['info']:08x} {fs:08x} {f['err']:03x}")
    for s in sorted(set(rx.seg_expect)):
        for name, cond in [("ce_bad", 0), ("ce_rise_toggle", 0), ("lat0", 20000), ("flips", 0)]:
            c = rx.seg_expect[s].get(name, "")
            regs.append(f"inv {s} {name} {1 if c == 'nz' else cond}")
        for name, c in rx.seg_expect[s].items():
            if name.startswith("dly_loads"):
                regs.append(f"inv {s} {name} {int(c[1:]) if c.startswith('=') else 7}")
    regs += [f"tend {i} {t}" for i, t in tend.items()] + ["end"]
    (d / "regs.txt").write_text("\n".join(regs) + "\n")
    return seg


class GenCheckTest(unittest.TestCase):
    def gen(self, d, *argv):
        sys.argv = ["csi2_model.py", "gen", str(d)] + list(argv)
        with contextlib.redirect_stdout(io.StringIO()):
            m.main()

    def test_all_tests_round_trip(self):
        v4 = ("--lanes", "4", "--versal", "--fifo-depth", "512")
        tx = sorted(t for t in m.TESTS if t not in ("clkstop", "gaps", "lpmask"))   # not PPI only
        with tempfile.TemporaryDirectory() as tmp:
            cases = [(t, "--seed", "2") for t in tx if t != "dly"]
            cases += [(t, "--seed", "3", *v4) for t in tx]
            cases += [("cmd", "--seed", "1", "--lanes", "2", "--dut-lanes", "4", "--versal")]
            cases += [("random", "--seed", str(s), *o) for s in (1, 2) for o in
                      [(), ("--errors",), ("--raw8", "--errors", "--lanes", "1"), ("--contclk",),
                       ("--errors", "--contclk", "--lanes", "1", "--dut-lanes", "2"),
                       v4, ("--errors",) + v4, ("--raw8", "--contclk") + v4,
                       ("--errors", "--burst-rst", "1") + v4,
                       ("--errors", "--lanes", "2", "--dut-lanes", "4", "--versal"),
                       ("--errors", "--lanes", "1", "--dut-lanes", "4", "--versal")]]
            cases += [("skew", "--seed", "4", "--lanes", "2", "--dut-lanes", "4", "--versal")]
            # the PPI bench, both timings (the PPI lines do not change the expectations)
            p4 = ("--lanes", "4", "--fifo-depth", "512")
            for mode in m.PPI_MODES:
                for t in m.PPI_TESTS:
                    if mode == "std" and t in m.PPI_BOW_ONLY:
                        continue
                    cases += [(t, "--seed", "5", "--ppi", mode)]
                    cases += [(t, "--seed", "6", "--ppi", mode, *p4)]
                cases += [("random", "--seed", "7", "--ppi", mode, "--errors", "--contclk", *p4),
                          ("random", "--seed", "8", "--ppi", mode, "--errors", "--lanes", "1",
                           "--dut-lanes", "4", "--fifo-depth", "512")]
            for n, (test, *argv) in enumerate(cases):
                d = Path(tmp) / f"c{n}"
                self.gen(d, "--test", test, *argv)
                first = (d / "stim.txt").read_text()
                self.gen(d, "--test", test, *argv)
                self.assertEqual((d / "stim.txt").read_text(), first, "deterministic generator")
                perfect_dut(d)
                errs, _ = m.check(d)
                self.assertEqual(errs, [], (test, argv))

    def test_versal_phy_config(self):
        # BurstRxRst of the PHY model from --burst-rst (0 = the shipped default);
        # per lane FIFO latencies only where a FIFO wrap cannot become lane skew
        with tempfile.TemporaryDirectory() as tmp:
            seen = set()
            for s in range(1, 25):
                for brst in ("0", "1"):
                    d = Path(tmp) / f"s{s}_{brst}"
                    self.gen(d, "--seed", str(s), "--lanes", "4", "--versal", "--fifo-depth", "512",
                             "--burst-rst", brst)
                    cfg = m.read_cfg(d / "cfg.txt")
                    self.assertEqual(cfg["v_burst_rst"], int(brst))
                    self.assertNotIn("v_rst_pct", cfg)
                    if cfg["v_lat_lane"]:
                        self.assertTrue(cfg["v_burst_rst"] or not cfg["v_glitch_pct"])
                    seen.add((cfg["v_burst_rst"], cfg["v_lat_lane"]))
            self.assertEqual(seen, {(0, 0), (0, 1), (1, 0), (1, 1)})
            self.gen(Path(tmp) / "skew", "--test", "skew", "--lanes", "4", "--versal")
            cfg = m.read_cfg(Path(tmp) / "skew" / "cfg.txt")
            self.assertEqual((cfg["v_burst_rst"], cfg["v_lat_lane"], cfg["v_gap_pm"]), (0, 0, 0))
            with self.assertRaises(SystemExit):
                self.gen(Path(tmp) / "x", "--burst-rst", "1")
            with self.assertRaises(SystemExit):
                self.gen(Path(tmp) / "y", "--test", "skew", "--lanes", "1")
            # PPI bench: the controller alone, no D-PHY model, no D-PHY tests
            for argv in (("--ppi", "bow", "--versal"), ("--ppi", "bow", "--test", "lp"),
                         ("--ppi", "std", "--test", "gaps"), ("--ppi", "std", "--test", "lpmask"),
                         ("--test", "clkstop"), ("--test", "gaps")):
                with self.assertRaises(SystemExit, msg=argv):
                    self.gen(Path(tmp) / "z", *argv)

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
