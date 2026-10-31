# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/h264 (the H.264 encoder reference model, its decoder,
the MP4 writer) and tools/bow32_video.py. Run:
python3 -m unittest discover -s tools/tests

When PyAV is installed (pip install av), the streams are also decoded with
FFmpeg and must give exactly the reconstruction of the model.
"""

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
        self.rx += data
        while b"\r" in self.rx:
            line, _, rest = bytes(self.rx).partition(b"\r")
            self.rx = bytearray(rest)
            self.line(line.decode())

    def say(self, s):
        self.tx += s.replace("\n", "\r\n").encode() if isinstance(s, str) else s

    def line(self, cmd):
        self.say(cmd + "\n")
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
