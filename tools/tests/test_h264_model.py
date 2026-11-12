# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/h264 (the H.264 encoder reference model, its decoder,
the MP4 writer) and tools/bow32_video.py. Run:
python3 -m unittest discover -s tools/tests

When PyAV is installed (pip install av), the streams are also decoded with
FFmpeg and must give exactly the reconstruction of the model.
"""

import ctypes
import random
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "h264"))
import h264_model as m  # noqa: E402
import mp4  # noqa: E402
import bow32_video  # noqa: E402

try:
    import av  # noqa: E402
except ImportError:  # pragma: no cover
    av = None


def ffmpeg_frames(stream):
    ctx = av.CodecContext.create("h264", "r")
    out = []
    for pkt in list(ctx.parse(stream)) + list(ctx.parse(None)):
        for fr in ctx.decode(pkt):
            out.append(fr.to_ndarray(format="yuv420p"))
    for fr in ctx.decode(None):
        out.append(fr.to_ndarray(format="yuv420p"))
    return out


class BitsTest(unittest.TestCase):
    def test_exp_golomb(self):
        w = m.BitWriter()
        for v in (0, 1, 2, 3, 7, 8, 255):
            w.ue(v)
        for v in (0, 1, -1, 2, -2, 25, -26):
            w.se(v)
        w.trailing()
        r = m.BitReader(w.data())
        self.assertEqual([r.ue() for _ in range(7)], [0, 1, 2, 3, 7, 8, 255])
        self.assertEqual([r.se() for _ in range(7)], [0, 1, -1, 2, -2, 25, -26])

    def test_emulation_prevention(self):
        self.assertEqual(m.emulation_prevention(b"\x00\x00\x00\x00\x01\x00\x00\x04"),
                         b"\x00\x00\x03\x00\x00\x03\x01\x00\x00\x04")
        nal = m.nal(0x65, b"\x00\x00\x02\x80")
        self.assertEqual(nal, b"\x00\x00\x00\x01\x65\x00\x00\x03\x02\x80\x00\x00")
        (typ, ref, rbsp), = m.split_nals(nal)
        self.assertEqual((typ, ref, rbsp), (5, 3, b"\x00\x00\x02\x80"))

    def test_transform_quantise_inverse(self):
        """Forward transform + quantiser at QP 10, then the decoder scaling
        and inverse transform: the residual comes back within +-2."""
        rnd = random.Random(1)
        qp = 10
        k, mq = qp // 6, qp % 6
        qbits = 15 + k
        for _ in range(200):
            x = [rnd.randrange(-255, 256) for _ in range(16)]
            w = m.fwd4x4(x)
            lv = [m.quant(w[i], m.MF[mq][m.POS_CLASS[i]], qbits, (1 << qbits) // 3)
                  for i in range(16)]
            d = [(lv[i] * m.VS[mq][m.POS_CLASS[i]]) << k for i in range(16)]
            r = m.inv4x4(d)
            self.assertLessEqual(max(abs(a - b) for a, b in zip(r, x)), 2)


class EncoderTest(unittest.TestCase):
    def roundtrip(self, w, h, kinds, qps, deblock=False, seed=1):
        rnd = random.Random(seed)
        frames = [m.test_frame(rnd, w, h, k) for k in kinds]
        stream, recons = m.encode_sequence(frames, w, h, qps, deblock=deblock)
        decoded = m.decode(stream)
        self.assertEqual(len(decoded), len(frames))
        for i, (rec, dec) in enumerate(zip(recons, decoded)):
            for p in range(3):
                hh = h if p == 0 else h // 2
                self.assertEqual(dec[p], [row for row in rec[p][:hh]], f"frame {i} plane {p}")
        if av is not None:
            got = ffmpeg_frames(stream)
            self.assertEqual(len(got), len(frames))
            if not deblock:        # FFmpeg filters the output when deblocking is on
                for i, g in enumerate(got):
                    self.assertEqual([list(r) for r in g[:h]], recons[i][0][:h], f"frame {i}")
        return stream

    def test_sizes_and_modes(self):
        self.roundtrip(32, 32, ["flat", "ramp"], [28])
        self.roundtrip(48, 34, ["scene", "noise"], [40, 51])        # cropped height
        self.roundtrip(64, 48, ["scene", "ramp", "noise"], [10, 22, 33])

    def test_low_qp_noise(self):
        # many coefficients, large levels (escape codes), every suffix length
        self.roundtrip(32, 32, ["noise", "noise"], [10, 12], seed=7)

    def test_deblocking_flag(self):
        stream = self.roundtrip(32, 32, ["scene"], [30], deblock=True)
        dec = m.Decoder()
        dec.feed(stream)
        self.assertEqual(dec.mb_info[0]["deblock_idc"], 0)

    def test_every_prediction_mode_is_used(self):
        rnd = random.Random(4)
        modes, cmodes = set(), set()
        for kind in ("scene", "ramp", "noise", "flat", "scene"):
            enc = m.Encoder(64, 48)
            _, _, info = enc.encode(m.yuv444_to_420(m.test_frame(rnd, 64, 48, kind), 64, 48), 24)
            modes |= {mi.mode for mi in info}
            cmodes |= {mi.cmode for mi in info}
        self.assertEqual(modes, {0, 1, 2, 3})
        self.assertEqual(cmodes, {0, 1, 2, 3})


class ParameterSetTest(unittest.TestCase):
    def test_sps_fields(self):
        dec = m.Decoder()
        dec.parse_sps(m.sps_rbsp(1920, 1080, 30, 1))
        s = dec.sps
        self.assertEqual((s["profile"], s["constraints"], s["level"]), (66, 0xC0, 41))
        self.assertEqual((s["width"], s["height"], s["mbw"], s["mbh"]), (1920, 1080, 120, 68))
        self.assertEqual(mp4.sps_size(m.sps_nal(1920, 1080)[4:].rstrip(b"\x00")), (1920, 1080))

    def test_levels(self):
        self.assertEqual(m.level_for(1920, 1080, 30), 41)
        self.assertEqual(m.level_for(1280, 720, 60), 41)
        self.assertEqual(m.level_for(1920, 1080, 60), 42)
        self.assertEqual(m.level_for(2048, 1088, 30), 42)

    def test_c_writer_matches(self):
        """sw/common/src/bow_h264.c gives the same SPS / PPS bytes."""
        cc = "gcc"
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "t.c"
            src.write_text(
                '#include <stdio.h>\n#define BOW32_H264_BASE 0u\n#include "bow_h264.h"\n'
                '#include "' + str(ROOT.parent / "sw/common/src/bow_h264.c") + '"\n'
                "int main(void) { unsigned w, h, n, d, f; uint8_t b[256];\n"
                "  while (scanf(\"%u %u %u %u %u\", &w, &h, &n, &d, &f) == 5) {\n"
                "    bow_h264_params_t p = {w, h, n, d, f != 0, 0};\n"
                "    uint32_t k = bow_h264_write_headers(b, sizeof b, &p);\n"
                "    for (uint32_t i = 0; i < k; i++) printf(\"%02x\", b[i]); printf(\"\\n\"); }\n"
                "  return 0; }\n")
            exe = Path(d) / "t"
            try:
                subprocess.run([cc, "-w", "-I", str(ROOT.parent / "sw/common/include"), "-o",
                                str(exe), str(src)], check=True, capture_output=True)
            except (OSError, subprocess.CalledProcessError):
                self.skipTest("no host C compiler")
            cases = [(1280, 720, 30, 1, 0), (1920, 1080, 30, 2, 1), (64, 48, 15, 1, 0),
                     (176, 136, 60, 4, 1), (2048, 1088, 30, 1, 0)]
            out = subprocess.run([str(exe)], input="".join("%d %d %d %d %d\n" % c for c in cases),
                                 capture_output=True, text=True, check=True).stdout.split()
            for c, o in zip(cases, out):
                self.assertEqual(o, (m.sps_nal(c[0], c[1], c[2], c[3], bool(c[4])) +
                                     m.pps_nal()).hex(), c)


class RcState(ctypes.Structure):
    """bow_h264_rc_t of sw/common/include/bow_h264.h"""
    _fields_ = [(n, ctypes.c_uint32) for n in ("space", "reserve", "frames", "cap", "target", "qp")]


class RateControlTest(unittest.TestCase):
    """The rate control of sw/apps/video `rec` (bow_h264_rc_* of
    sw/common/src/bow_h264.c, built for the host) in closed loop: with the
    frame sizes the Huins board measured (board run 1, 2026-11-10: 1080p;
    run 2, 2026-11-11: 1080p and 720p, BOARD_RUN2) and with the frame sizes
    of this encoder model on camera-like frames. The firmware loop: rc_init
    gives the first QP; after each frame rc_frame with the frame count and
    the total bytes (FRAME_CNT, TOTAL_BYTES) gives the QP of the next frame
    (the encoder takes it at its next frame start); false means STOP."""

    VRAM = 1 << 20
    HDR = 64  # SPS + PPS of the video app (rounded up)
    # Board run 2 (IMX274 on the Huins MFP-VP1902, office scene, 2026-11-11):
    # `rec` with the qp auto of the firmware then (first QP 37 at 1080p, 33
    # at 720p), skip 1; the bytes and the QP of every frame, in order.
    # 1080p30: 12 frames at QP 37 (37384..37736 bytes), 18 at QP 38
    # (32664..32972); 720p30: 42 at QP 37 (22884..23048), one each at QP 33,
    # 36 and 38.
    BOARD_RUN2 = {
        (1920, 1080): (
            [37600, 32792, 32852, 32956, 32972, 32816, 37736, 32940, 37408, 32732,
             37632, 32844, 37384, 32664, 37468, 32728, 37600, 32912, 32800, 37616,
             32756, 37420, 32852, 32816, 37580, 32948, 32792, 37420, 32788, 37512],
            [37, 38, 38, 38, 38, 38, 37, 38, 37, 38, 37, 38, 37, 38, 37, 38, 37, 38, 38, 37,
             38, 37, 38, 38, 37, 38, 38, 37, 38, 37]),
        (1280, 720): (
            [33600, 24424, 22972, 22920, 23028, 22968, 22992, 22964, 22972, 22972,
             22976, 22932, 22916, 22916, 22896, 22968, 22912, 22928, 22908, 22980,
             22988, 22924, 22968, 22976, 22964, 22912, 23008, 22948, 22932, 23028,
             22992, 22912, 23012, 22984, 22884, 22964, 23048, 22944, 22960, 23032,
             22992, 23008, 20040, 23016, 23000],
            [33, 36] + [37] * 40 + [38, 37, 37]),
    }

    @classmethod
    def run2_size(cls, w, h, qp):
        """Bytes of a frame of the run-2 scene at qp: the mean of the frames
        measured at a QP, log-linear between those, 6 QP per halving beyond
        them."""
        at = {}
        for b, q in zip(*cls.BOARD_RUN2[(w, h)]):
            at.setdefault(q, []).append(b)
        pts = sorted((q, sum(v) / len(v)) for q, v in at.items())
        if qp <= pts[0][0]:
            return pts[0][1] * 2 ** ((pts[0][0] - qp) / 6)
        if qp >= pts[-1][0]:
            return pts[-1][1] * 2 ** ((pts[-1][0] - qp) / 6)
        for (q0, b0), (q1, b1) in zip(pts, pts[1:]):
            if q0 <= qp <= q1:
                return b0 * (b1 / b0) ** ((qp - q0) / (q1 - q0))
        raise AssertionError(qp)

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = Path(cls.tmp.name)
        src = d / "rc.c"
        src.write_text('#define BOW32_H264_BASE 0u\n#include "bow_h264.h"\n'
                       '#include "' + str(ROOT.parent / "sw/common/src/bow_h264.c") + '"\n')
        lib = d / "librc.so"
        try:
            subprocess.run(["gcc", "-w", "-O1", "-shared", "-fPIC", "-I",
                            str(ROOT.parent / "sw/common/include"), "-o", str(lib), str(src)],
                           check=True, capture_output=True)
        except (OSError, subprocess.CalledProcessError):
            raise unittest.SkipTest("no host C compiler")
        cls.c = ctypes.CDLL(str(lib))
        u32, p = ctypes.c_uint32, ctypes.POINTER(RcState)
        cls.c.bow_h264_rc_init.argtypes = [p, u32, u32, u32, u32, u32, u32]
        cls.c.bow_h264_rc_frame.argtypes = [p, u32, u32, u32]
        cls.c.bow_h264_rc_frame.restype = ctypes.c_bool
        cls.c.bow_h264_rc_size.argtypes = [u32, u32, u32]
        cls.c.bow_h264_rc_size.restype = u32

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def init(self, w, h, frames, space=None, cap=0, qp=0):
        rc = RcState()
        self.c.bow_h264_rc_init(ctypes.byref(rc), w, h, space or self.VRAM - self.HDR, frames,
                                cap, qp)
        return rc

    def record(self, rc, size_at):
        """size_at(k, qp): bytes of frame k (0..) coded at qp. Returns the
        sizes, QPs and targets of the frames recorded, and how it ended:
        "done", "stop" (rc_frame said no: STOP) or "cut" (a frame did not
        fit: the DMA would have cut it)."""
        total, sizes, qps, targets = 0, [], [], []
        for k in range(rc.frames):
            used, target = rc.qp, rc.target
            b = size_at(k, used)
            if total + b > rc.space:
                return sizes, qps, targets, "cut"
            total += b
            sizes.append(b)
            qps.append(used)
            targets.append(target)
            if not self.c.bow_h264_rc_frame(ctypes.byref(rc), k + 1, b, total):
                return sizes, qps, targets, "stop"
        return sizes, qps, targets, "done"

    def test_size_and_steps(self):
        for b in (1000, 34567, 77112):
            for e in range(-40, 41):
                want = b * 2 ** (e / 6)
                got = self.c.bow_h264_rc_size(b, 30 + e if e > 0 else 30, 30 if e > 0 else 30 - e)
                self.assertLess(abs(got - want), want * 0.005 + 1, (b, e))
        cases = [(30, 2000, 1000, 36), (30, 500, 1000, 24), (30, 1000, 1000, 30), (30, 1100, 1000, 31),
                 (30, 1050, 1000, 30), (30, 940, 1000, 29), (30, 10**6, 1000, 42),
                 (30, 10, 10**6, 18), (48, 8000, 1000, 51), (14, 100, 8000, 10)]
        for qp, b, t, want in cases:
            rc = RcState(space=10**7, reserve=0, frames=10, cap=t, target=t, qp=qp)
            self.c.bow_h264_rc_frame(ctypes.byref(rc), 1, b, b)
            self.assertEqual(rc.qp, want, (qp, b, t))

    def test_first_qp(self):
        rc = self.init(1920, 1080, 30)
        self.assertEqual((rc.qp, rc.reserve), (38, (self.VRAM - self.HDR) // 30 // 8 + 4096))
        self.assertEqual(rc.target, (rc.space - rc.reserve) // 30)
        self.assertEqual(self.init(1280, 720, 45).qp, 37)
        self.assertEqual(self.init(1280, 720, 30).qp, 33)
        self.assertEqual(self.init(1920, 1080, 10).qp, 28)
        self.assertEqual(self.init(64, 48, 3).qp, 10)
        self.assertEqual(self.init(1920, 1080, 30, qp=26).qp, 26)     # `qp 26`
        rc = self.init(1920, 1080, 30, cap=20 * 1024)                 # `rec 30 0 20`
        self.assertEqual(rc.target, 20 * 1024)

    def test_board_1080p30(self):
        """The 1080p office scene of the Huins board: 77112 bytes at QP 30,
        38344 at QP 37 (QP 30 start, one QP per frame: 20 of 30 frames fit).
        All 30 frames fit now, with +-10 % scatter from frame to frame."""
        rnd = random.Random(5)
        scatter = [1 + rnd.uniform(-0.1, 0.1) for _ in range(30)]
        slope = 7 / 1.008  # QP per halving between the two measured points

        def size_at(k, qp):
            return int(77112 * 2 ** ((30 - qp) / slope) * scatter[k]) & ~3

        rc = self.init(1920, 1080, 30)
        sizes, qps, targets, end = self.record(rc, size_at)
        self.assertEqual((len(sizes), end), (30, "done"), (sizes, qps))
        self.assertLessEqual(sum(sizes), self.VRAM - self.HDR)
        self.assertGreater(sum(sizes), 0.9 * (self.VRAM - self.HDR))   # the space is used
        for k in range(3, 30):
            self.assertLess(abs(sizes[k] - targets[k]), 0.3 * targets[k], (k, sizes, targets))
        # the old start (QP 30) also fits now
        rc = self.init(1920, 1080, 30, qp=30)
        self.assertEqual(self.record(rc, size_at)[3], "done")

    def test_board_run2(self):
        """Board run 2 (BOARD_RUN2) started at the first QP of the old model:
        37 at 1080p (37600 bytes, 8 % above the target 34669) and 33 at 720p
        (33600 bytes, 45 % above 23145, QP 37 from frame 3 on). Fed the
        measured sizes in order, the rate control built here gives the QP of
        every frame the board coded. The first QP now fits each mode: 38 at
        1080p and 37 at 720p, where the frames of that scene come out within
        10 % below the target; with +-3 % scatter all frames fit and stay
        within 15 % of their targets."""
        rnd = random.Random(7)
        for (w, h), first in (((1920, 1080), 38), ((1280, 720), 37)):
            board_sizes, board_qps = self.BOARD_RUN2[(w, h)]
            n = len(board_sizes)
            rc = self.init(w, h, n, qp=board_qps[0])
            sizes, qps, _, end = self.record(rc, lambda k, qp: board_sizes[k])
            self.assertEqual((qps, end), (board_qps, "done"), (w, h))

            scatter = [1 + rnd.uniform(-0.03, 0.03) for _ in range(n)]

            def size_at(k, qp):
                return int(self.run2_size(w, h, qp) * scatter[k]) & ~3

            rc = self.init(w, h, n)
            b = self.run2_size(w, h, rc.qp)
            self.assertEqual(rc.qp, first, (w, h))
            self.assertTrue(0.9 * rc.target < b <= rc.target, (w, h, rc.qp, b, rc.target))
            sizes, qps, targets, end = self.record(rc, size_at)
            self.assertEqual((len(sizes), end), (n, "done"), (w, h, sizes, qps))
            self.assertLessEqual(sum(sizes), self.VRAM - self.HDR)
            self.assertGreater(sum(sizes), 0.9 * (self.VRAM - self.HDR))
            for k in range(n):
                self.assertLess(abs(sizes[k] - targets[k]), 0.15 * targets[k],
                                (w, h, k, sizes, qps, targets))

    def test_stop_when_full(self):
        """A scene too detailed for the space even at QP 51 (60 KB per 1080p
        frame): the QP goes to 51, then the rate control stops the recording
        before a frame would overflow the buffer."""
        def size_at(k, qp):
            return int(60000 * 2 ** ((51 - qp) / 6)) & ~3

        rc = self.init(1920, 1080, 30)
        sizes, qps, _, end = self.record(rc, size_at)
        self.assertEqual(end, "stop", (sizes, qps))
        self.assertEqual((len(sizes), qps[-1]), (13, 51), (sizes, qps))
        self.assertGreater(sum(sizes) + size_at(len(sizes), 51), rc.space)

    def test_model_frames(self):
        """Camera-like frames of this model (320x176, three scenes in turn,
        sizes of the real encoder at each QP), 24 frames into a buffer that
        needs ~QP 36: all fit, the last 12 within 30 % of their target."""
        rnd = random.Random(11)
        w, h = 320, 176
        planes = [m.yuv444_to_420(m.test_frame(rnd, w, h, "scene"), w, h) for _ in range(3)]
        enc, cache = m.Encoder(w, h), {}

        def size_at(k, qp):
            key = (k % 3, qp)
            if key not in cache:
                cache[key] = len(enc.encode(planes[k % 3], qp)[0])
            return cache[key]

        rc = self.init(w, h, 24, space=24 * 2600)
        sizes, qps, targets, end = self.record(rc, size_at)
        self.assertEqual((len(sizes), end), (24, "done"), (sizes, qps))
        self.assertLessEqual(sum(sizes), 24 * 2600)
        for k in range(12, 24):
            self.assertLess(abs(sizes[k] - targets[k]), 0.3 * targets[k], (k, sizes, qps, targets))


class TablesTest(unittest.TestCase):
    def test_rtl_tables_up_to_date(self):
        path = ROOT.parent / m.SV_TABLES
        self.assertEqual(path.read_text(), m.sv_tables(), "run `tools/h264/h264_model.py tables`")

    def test_vlc_tables_are_prefix_free(self):
        def check(lens, bits):
            codes = [format(b, f"0{n}b") for n, b in zip(lens, bits) if n]
            for a in codes:
                for b in codes:
                    if a is not b and b.startswith(a):
                        self.fail(f"{a} is a prefix of {b}")
        for t in range(3):
            check(m.COEFF_TOKEN_LEN[t], m.COEFF_TOKEN_BITS[t])
        check(m.CHROMA_DC_COEFF_TOKEN_LEN, m.CHROMA_DC_COEFF_TOKEN_BITS)
        for i in range(15):
            check(m.TOTAL_ZEROS_LEN[i], m.TOTAL_ZEROS_BITS[i])
        for i in range(7):
            check(m.RUN_LEN[i], m.RUN_BITS[i])


class Mp4Test(unittest.TestCase):
    def stream(self, n=4):
        rnd = random.Random(2)
        frames = [m.test_frame(rnd, 48, 32, k) for k in ("scene", "ramp", "noise", "flat")[:n]]
        return m.encode_sequence(frames, 48, 32, [30], fps=(15, 1))

    def test_boxes(self):
        stream, _ = self.stream()
        blob = mp4.mp4_bytes(stream, 15, 1)
        pos, kinds = 0, []
        while pos < len(blob):
            size, kind = struct.unpack(">I4s", blob[pos:pos + 8])
            kinds.append(kind)
            pos += size
        self.assertEqual(kinds, [b"ftyp", b"moov", b"mdat"])
        self.assertEqual(pos, len(blob))
        for k in (b"avcC", b"stts", b"stsz", b"stco", b"avc1"):
            self.assertIn(k, blob)
        # samples: the 4 slice NAL units with length prefixes
        sps, pps, aus = mp4.access_units(mp4.nal_units(stream))
        self.assertEqual((sps[0], pps[0], len(aus)), (0x67, 0x68, 4))

    @unittest.skipIf(av is None, "PyAV not installed")
    def test_ffmpeg_reads_the_file(self):
        stream, recons = self.stream()
        with tempfile.TemporaryDirectory() as d:
            path = str(Path(d) / "t.mp4")
            mp4.write_mp4(path, stream, 15, 1)
            c = av.open(path)
            vs = c.streams.video[0]
            self.assertEqual((vs.codec_context.width, vs.codec_context.height), (48, 32))
            self.assertEqual(vs.average_rate, 15)
            frames = list(c.decode(video=0))
            self.assertEqual(len(frames), 4)
            y = frames[0].to_ndarray(format="yuv420p")[:32]
            self.assertEqual([list(r) for r in y], recons[0][0][:32])


class FakeVideoSerial:
    """Byte level model of the shell of sw/apps/video: rec / send."""

    def __init__(self, stream, corrupt=False):
        self.baudrate = 115200
        self.rx = bytearray()
        self.tx = bytearray()
        self.stream, self.corrupt = stream, corrupt

    @property
    def in_waiting(self):
        return len(self.tx)

    def reset_input_buffer(self):
        self.tx.clear()

    def read(self, n):
        out, self.tx = bytes(self.tx[:n]), self.tx[n:]
        return out

    def write(self, data):
        for b in data:  # the app echoes every character it reads and runs the line at CR
            if b != 0x0D:
                self.rx.append(b)
                self.tx.append(b)
                continue
            line, self.rx = self.rx.decode(), bytearray()
            self.say("\n")
            self.line(line)

    def say(self, s):
        self.tx += s.replace("\n", "\r\n").encode() if isinstance(s, str) else s

    def line(self, cmd):
        if cmd.startswith("rec"):
            self.say("rec: 2 frames 48x32, 15/1 fps, QP 30, 1000 bytes per frame\n"
                     "frame 1: 500 bytes, 10 us\nframe 2: 520 bytes, 10 us\n"
                     f"rec: 2 frames, {len(self.stream)} bytes\nok\n")
        elif cmd == "send":
            data = bytearray(self.stream)
            crc = zlib.crc32(data)
            if self.corrupt:
                data[10] ^= 1
            self.say(f"H264 {len(data)} {crc:08x} 2 48 32 15 1\n")
            self.say(bytes(data))
            self.say("\nEND\nok\n")
        elif cmd:
            self.say("ok\n")
        self.say("> ")


class VideoToolTest(unittest.TestCase):
    def setUp(self):
        rnd = random.Random(3)
        frames = [m.test_frame(rnd, 48, 32, "scene") for _ in range(2)]
        self.stream, _ = m.encode_sequence(frames, 48, 32, [30], fps=(15, 1))

    def test_record_and_save(self):
        v = bow32_video.Video(FakeVideoSerial(self.stream))
        v.sync()
        v.record(2, 0, 0, progress=False)
        rec = v.receive(progress=False)
        self.assertEqual((rec.frames, rec.width, rec.height, rec.fps), (2, 48, 32, 15))
        self.assertEqual(rec.data, self.stream)
        with tempfile.TemporaryDirectory() as d:
            h264, mp4_path = rec.save(str(Path(d) / "clip.mp4"))
            self.assertEqual(h264.read_bytes(), self.stream)
            self.assertEqual(mp4_path.read_bytes()[4:8], b"ftyp")
            self.assertEqual(len(m.decode(h264.read_bytes())), 2)

    def test_crc_error(self):
        v = bow32_video.Video(FakeVideoSerial(self.stream, corrupt=True))
        v.sync()
        with self.assertRaises(bow32_video.CameraError):
            v.receive(progress=False)


class DvCaseTest(unittest.TestCase):
    """The gen / check round trip of hw/ip/h264/dv with a perfect DUT."""

    def test_gen_check(self):
        with tempfile.TemporaryDirectory() as d:
            for seed in (1, 3):
                case = Path(d) / f"s{seed}"
                subprocess.run([sys.executable, str(ROOT / "h264/h264_model.py"), "gen", str(case),
                                "--seed", str(seed), "--frames", "2"], check=True,
                               capture_output=True)
                (case / "out.hex").write_text((case / "expect.hex").read_text())
                (case / "status.txt").write_text("OK\n")
                r = subprocess.run([sys.executable, str(ROOT / "h264/h264_model.py"), "check",
                                    str(case)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stdout)
                self.assertIn("PASS", r.stdout)


if __name__ == "__main__":
    unittest.main()
