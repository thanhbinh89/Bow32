#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bit-exact reference model of the Bow32 H.264 encoder (hw/ip/h264).

H.264 / AVC constrained baseline, intra only: every frame is one IDR slice
of Intra_16x16 macroblocks, CAVLC entropy coding, one QP per frame. The
model takes exactly the encoder decisions of the RTL (4:2:0 box filter, SAD
mode decision, quantiser rounding), so the RTL output can be compared byte
for byte. The reconstruction follows the decoding process of the standard
(ITU-T H.264 clause 8): it is identical to the output of any decoder with
the deblocking filter off (checked against FFmpeg in
tools/tests/test_h264_model.py when PyAV is installed). Arithmetic and
decisions are specified in docs/ip/h264.md.

Also here:
  * a decoder for this subset (stream checks without FFmpeg),
  * the SPS / PPS writer (the same bytes as sw/common/src/bow_h264.c),
  * the commands of the RTL unit test (hw/ip/h264/dv).

Pure Python, no dependencies: meant for small frames (a 1280x720 frame takes
about a minute).

Library use:
    planes = yuv444_to_420(frame, w, h)            # frame: rows of (Y, U, V)
    enc = Encoder(w, h)
    nal, recon = enc.encode(planes, qp=28, idr_pic_id=0, deblock=True)
    stream = sps_nal(w, h, ...) + pps_nal() + nal
    frames = decode(stream)                         # list of (Y, Cb, Cr)

Command line:
    h264_model.py gen DIR --seed N [--width W --height H --frames F]
    h264_model.py check DIR
    h264_model.py decode in.264 [--yuv out.yuv]
    h264_model.py tables [--check]      CAVLC tables of the RTL
"""

import argparse
import random
import sys
from pathlib import Path

# ============================================================== constants
NAL_SLICE_IDR = 5
NAL_SPS = 7
NAL_PPS = 8
NAL_HDR_IDR = 0x65          # nal_ref_idc 3, IDR slice
NAL_HDR_SPS = 0x67
NAL_HDR_PPS = 0x68
START_CODE = b"\x00\x00\x00\x01"

QP_MIN = 10                 # encoder limits (docs/ip/h264.md, "Levels")
QP_MAX = 51
LEVEL_MAX = 2063            # largest |level| CAVLC can code with suffixLength 0

# Intra_16x16 prediction modes (mb_type) and chroma modes
I16_V, I16_H, I16_DC, I16_P = 0, 1, 2, 3
C_DC, C_H, C_V, C_P = 0, 1, 2, 3

# zig-zag scan: scan index -> raster index (4 * row + column)
ZIGZAG = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]
# luma4x4BlkIdx -> (bx, by) in 4x4 block units inside the macroblock
BLK_XY = [(0, 0), (1, 0), (0, 1), (1, 1), (2, 0), (3, 0), (2, 1), (3, 1),
          (0, 2), (1, 2), (0, 3), (1, 3), (2, 2), (3, 2), (2, 3), (3, 3)]

# Quantisation (MF, encoder) and scaling (V = normAdjust4x4, decoder) for
# QP % 6 and the three position classes: 0 both even, 1 both odd, 2 others.
MF = [[13107, 5243, 8066], [11916, 4660, 7490], [10082, 4194, 6554],
      [9362, 3647, 5825], [8192, 3355, 5243], [7282, 2893, 4559]]
VS = [[10, 16, 13], [11, 18, 14], [13, 20, 16], [14, 23, 18], [16, 25, 20], [18, 29, 23]]
POS_CLASS = [0 if (i % 2 == 0 and j % 2 == 0) else 1 if (i % 2 and j % 2) else 2
             for i in range(4) for j in range(4)]
# QPc as a function of qPI (Table 8-15), chroma_qp_index_offset = 0
QPC = list(range(30)) + [29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36,
                         37, 37, 37, 38, 38, 38, 39, 39, 39, 39]

# ----------------------------------------------------------- CAVLC tables
# Copied from FFmpeg libavcodec/h264_cavlc.c (ITU-T H.264 tables 9-5, 9-7,
# 9-8, 9-9a, 9-10). Index [total_coeff * 4 + trailing_ones].
COEFF_TOKEN_LEN = [
    [1, 0, 0, 0, 6, 2, 0, 0, 8, 6, 3, 0, 9, 8, 7, 5, 10, 9, 8, 6,
     11, 10, 9, 7, 13, 11, 10, 8, 13, 13, 11, 9, 13, 13, 13, 10,
     14, 14, 13, 11, 14, 14, 14, 13, 15, 15, 14, 14, 15, 15, 15, 14,
     16, 15, 15, 15, 16, 16, 16, 15, 16, 16, 16, 16, 16, 16, 16, 16],
    [2, 0, 0, 0, 6, 2, 0, 0, 6, 5, 3, 0, 7, 6, 6, 4, 8, 6, 6, 4,
     8, 7, 7, 5, 9, 8, 8, 6, 11, 9, 9, 6, 11, 11, 11, 7,
     12, 11, 11, 9, 12, 12, 12, 11, 12, 12, 12, 11, 13, 13, 13, 12,
     13, 13, 13, 13, 13, 14, 13, 13, 14, 14, 14, 13, 14, 14, 14, 14],
    [4, 0, 0, 0, 6, 4, 0, 0, 6, 5, 4, 0, 6, 5, 5, 4, 7, 5, 5, 4,
     7, 5, 5, 4, 7, 6, 6, 4, 7, 6, 6, 4, 8, 7, 7, 5,
     8, 8, 7, 6, 9, 8, 8, 7, 9, 9, 8, 8, 9, 9, 9, 8,
     10, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10],
    [6, 0, 0, 0, 6, 6, 0, 0, 6, 6, 6, 0] + [6] * 56,
]
COEFF_TOKEN_BITS = [
    [1, 0, 0, 0, 5, 1, 0, 0, 7, 4, 1, 0, 7, 6, 5, 3, 7, 6, 5, 3,
     7, 6, 5, 4, 15, 6, 5, 4, 11, 14, 5, 4, 8, 10, 13, 4,
     15, 14, 9, 4, 11, 10, 13, 12, 15, 14, 9, 12, 11, 10, 13, 8,
     15, 1, 9, 12, 11, 14, 13, 8, 7, 10, 9, 12, 4, 6, 5, 8],
    [3, 0, 0, 0, 11, 2, 0, 0, 7, 7, 3, 0, 7, 10, 9, 5, 7, 6, 5, 4,
     4, 6, 5, 6, 7, 6, 5, 8, 15, 6, 5, 4, 11, 14, 13, 4,
     15, 10, 9, 4, 11, 14, 13, 12, 8, 10, 9, 8, 15, 14, 13, 12,
     11, 10, 9, 12, 7, 11, 6, 8, 9, 8, 10, 1, 7, 6, 5, 4],
    [15, 0, 0, 0, 15, 14, 0, 0, 11, 15, 13, 0, 8, 12, 14, 12, 15, 10, 11, 11,
     11, 8, 9, 10, 9, 14, 13, 9, 8, 10, 9, 8, 15, 14, 13, 13,
     11, 14, 10, 12, 15, 10, 13, 12, 11, 14, 9, 12, 8, 10, 13, 8,
     13, 7, 9, 12, 9, 12, 11, 10, 5, 8, 7, 6, 1, 4, 3, 2],
    [3, 0, 0, 0, 0, 1, 0, 0, 4, 5, 6, 0] + list(range(8, 64)),
]
CHROMA_DC_COEFF_TOKEN_LEN = [2, 0, 0, 0, 6, 1, 0, 0, 6, 6, 3, 0, 6, 7, 7, 6, 6, 8, 8, 7]
CHROMA_DC_COEFF_TOKEN_BITS = [1, 0, 0, 0, 7, 1, 0, 0, 4, 6, 1, 0, 3, 3, 2, 5, 2, 3, 2, 0]

# [total_coeff - 1][total_zeros]
TOTAL_ZEROS_LEN = [
    [1, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 9],
    [3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6],
    [4, 3, 3, 3, 4, 4, 3, 3, 4, 5, 5, 6, 5, 6],
    [5, 3, 4, 4, 3, 3, 3, 4, 3, 4, 5, 5, 5],
    [4, 4, 4, 3, 3, 3, 3, 3, 4, 5, 4, 5],
    [6, 5, 3, 3, 3, 3, 3, 3, 4, 3, 6],
    [6, 5, 3, 3, 3, 2, 3, 4, 3, 6],
    [6, 4, 5, 3, 2, 2, 3, 3, 6],
    [6, 6, 4, 2, 2, 3, 2, 5],
    [5, 5, 3, 2, 2, 2, 4],
    [4, 4, 3, 3, 1, 3],
    [4, 4, 2, 1, 3],
    [3, 3, 1, 2],
    [2, 2, 1],
    [1, 1],
]
TOTAL_ZEROS_BITS = [
    [1, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 1],
    [7, 6, 5, 4, 3, 5, 4, 3, 2, 3, 2, 3, 2, 1, 0],
    [5, 7, 6, 5, 4, 3, 4, 3, 2, 3, 2, 1, 1, 0],
    [3, 7, 5, 4, 6, 5, 4, 3, 3, 2, 2, 1, 0],
    [5, 4, 3, 7, 6, 5, 4, 3, 2, 1, 1, 0],
    [1, 1, 7, 6, 5, 4, 3, 2, 1, 1, 0],
    [1, 1, 5, 4, 3, 3, 2, 1, 1, 0],
    [1, 1, 1, 3, 3, 2, 2, 1, 0],
    [1, 0, 1, 3, 2, 1, 1, 1],
    [1, 0, 1, 3, 2, 1, 1],
    [0, 1, 1, 2, 1, 3],
    [0, 1, 1, 1, 1],
    [0, 1, 1, 1],
    [0, 1, 1],
    [0, 1],
]
CHROMA_DC_TOTAL_ZEROS_LEN = [[1, 2, 3, 3], [1, 2, 2], [1, 1]]
CHROMA_DC_TOTAL_ZEROS_BITS = [[1, 1, 1, 0], [1, 1, 0], [1, 0]]
# [min(zeros_left, 7) - 1][run_before]
RUN_LEN = [[1, 1], [1, 2, 2], [2, 2, 2, 2], [2, 2, 2, 3, 3], [2, 2, 3, 3, 3, 3],
           [2, 3, 3, 3, 3, 3, 3], [3, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11]]
RUN_BITS = [[1, 0], [1, 1, 0], [3, 2, 1, 0], [3, 2, 1, 1, 0], [3, 2, 3, 2, 1, 0],
            [3, 0, 1, 3, 2, 5, 4], [7, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1]]


def coeff_token_table(nc):
    """Table index of coeff_token for nC (-1 = chroma DC)."""
    if nc < 0:
        return -1
    return 0 if nc < 2 else 1 if nc < 4 else 2 if nc < 8 else 3


def coeff_token_code(nc, tc, t1):
    t = coeff_token_table(nc)
    if t < 0:
        return CHROMA_DC_COEFF_TOKEN_LEN[tc * 4 + t1], CHROMA_DC_COEFF_TOKEN_BITS[tc * 4 + t1]
    return COEFF_TOKEN_LEN[t][tc * 4 + t1], COEFF_TOKEN_BITS[t][tc * 4 + t1]


# ============================================================ bit writing
class BitWriter:
    """MSB first bit writer (RBSP)."""

    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0
        self.nbits = 0

    def u(self, n, v):
        if n == 0:
            return
        self.acc = (self.acc << n) | (v & ((1 << n) - 1))
        self.n += n
        self.nbits += n
        while self.n >= 8:
            self.n -= 8
            self.out.append((self.acc >> self.n) & 0xFF)
        self.acc &= (1 << self.n) - 1

    def ue(self, v):
        x = v + 1
        self.u(2 * x.bit_length() - 1, x)

    def se(self, v):
        self.ue(2 * v - 1 if v > 0 else -2 * v)

    def trailing(self):
        """rbsp_trailing_bits: stop bit, then zeros up to a byte boundary."""
        self.u(1, 1)
        if self.n:
            self.u(8 - self.n, 0)

    def data(self):
        assert self.n == 0, "RBSP not byte aligned"
        return bytes(self.out)


def ue_code(v):
    """(length, value) of the Exp-Golomb code of v."""
    x = v + 1
    return 2 * x.bit_length() - 1, x


def se_code(v):
    return ue_code(2 * v - 1 if v > 0 else -2 * v)


def emulation_prevention(rbsp):
    """Insert 0x03 after two zero bytes followed by a byte <= 3."""
    out = bytearray()
    zeros = 0
    for b in rbsp:
        if zeros == 2 and b <= 3:
            out.append(3)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


def nal(header, rbsp, pad=True):
    """Annex B NAL unit: start code, header byte, payload with emulation
    prevention, then zero bytes up to a multiple of 4 (trailing_zero_8bits,
    like the encoder output)."""
    out = START_CODE + bytes([header]) + emulation_prevention(rbsp)
    if pad:
        out += b"\x00" * (-len(out) % 4)
    return out


# ================================================================ SPS / PPS
def level_for(width, height, fps):
    """level_idc that allows the frame size and macroblock rate (the bit
    rate of intra only video is high: at least level 4.1)."""
    mbs = (width // 16) * ((height + 15) // 16)
    rate = mbs * fps
    for level, max_fs, max_mbps in ((41, 8192, 245760), (42, 8704, 522240),
                                    (50, 22080, 589824), (51, 36864, 983040)):
        if mbs <= max_fs and rate <= max_mbps:
            return level
    return 52


def sps_rbsp(width, height, fps_num=30, fps_den=1, full_range=False, level=None):
    """Sequence parameter set (constrained baseline, VUI with BT.709 colour,
    frame rate fps_num / fps_den). Same bits as bow_h264_write_sps()."""
    mbw, mbh = width // 16, (height + 15) // 16
    if level is None:
        level = level_for(width, height, (fps_num + fps_den - 1) // fps_den)
    w = BitWriter()
    w.u(8, 66)                  # profile_idc: baseline
    w.u(8, 0xC0)                # constraint_set0_flag = constraint_set1_flag = 1
    w.u(8, level)
    w.ue(0)                     # seq_parameter_set_id
    w.ue(0)                     # log2_max_frame_num_minus4
    w.ue(2)                     # pic_order_cnt_type: output order = decoding order
    w.ue(1)                     # max_num_ref_frames
    w.u(1, 0)                   # gaps_in_frame_num_value_allowed_flag
    w.ue(mbw - 1)
    w.ue(mbh - 1)
    w.u(1, 1)                   # frame_mbs_only_flag
    w.u(1, 1)                   # direct_8x8_inference_flag
    crop = mbh * 16 - height
    w.u(1, 1 if crop else 0)    # frame_cropping_flag
    if crop:
        w.ue(0)
        w.ue(0)
        w.ue(0)
        w.ue(crop // 2)         # frame_crop_bottom_offset (2 lines, 4:2:0)
    w.u(1, 1)                   # vui_parameters_present_flag
    w.u(1, 0)                   # aspect_ratio_info_present_flag
    w.u(1, 0)                   # overscan_info_present_flag
    w.u(1, 1)                   # video_signal_type_present_flag
    w.u(3, 5)                   # video_format: unspecified
    w.u(1, 1 if full_range else 0)
    w.u(1, 1)                   # colour_description_present_flag
    w.u(8, 1)                   # colour_primaries: BT.709
    w.u(8, 1)                   # transfer_characteristics: BT.709
    w.u(8, 1)                   # matrix_coefficients: BT.709
    w.u(1, 1)                   # chroma_loc_info_present_flag
    w.ue(1)                     # chroma_sample_loc_type_top_field: centre (2x2 average)
    w.ue(1)                     # chroma_sample_loc_type_bottom_field
    w.u(1, 1)                   # timing_info_present_flag
    w.u(32, fps_den)            # num_units_in_tick
    w.u(32, 2 * fps_num)        # time_scale (two ticks per frame)
    w.u(1, 1)                   # fixed_frame_rate_flag
    w.u(1, 0)                   # nal_hrd_parameters_present_flag
    w.u(1, 0)                   # vcl_hrd_parameters_present_flag
    w.u(1, 0)                   # pic_struct_present_flag
    w.u(1, 0)                   # bitstream_restriction_flag
    w.trailing()
    return w.data()


def pps_rbsp():
    """Picture parameter set: CAVLC, pic_init_qp 26, deblocking control in
    the slice header. Same bits as bow_h264_write_pps()."""
    w = BitWriter()
    w.ue(0)                     # pic_parameter_set_id
    w.ue(0)                     # seq_parameter_set_id
    w.u(1, 0)                   # entropy_coding_mode_flag: CAVLC
    w.u(1, 0)                   # bottom_field_pic_order_in_frame_present_flag
    w.ue(0)                     # num_slice_groups_minus1
    w.ue(0)                     # num_ref_idx_l0_default_active_minus1
    w.ue(0)                     # num_ref_idx_l1_default_active_minus1
    w.u(1, 0)                   # weighted_pred_flag
    w.u(2, 0)                   # weighted_bipred_idc
    w.se(0)                     # pic_init_qp_minus26
    w.se(0)                     # pic_init_qs_minus26
    w.se(0)                     # chroma_qp_index_offset
    w.u(1, 1)                   # deblocking_filter_control_present_flag
    w.u(1, 0)                   # constrained_intra_pred_flag
    w.u(1, 0)                   # redundant_pic_cnt_present_flag
    w.trailing()
    return w.data()


def sps_nal(width, height, fps_num=30, fps_den=1, full_range=False, level=None):
    return nal(NAL_HDR_SPS, sps_rbsp(width, height, fps_num, fps_den, full_range, level))


def pps_nal():
    return nal(NAL_HDR_PPS, pps_rbsp())


def slice_header(w, idr_pic_id, qp, deblock):
    """IDR I slice header (first_mb 0, slice_type 7, frame_num 0)."""
    w.ue(0)                     # first_mb_in_slice
    w.ue(7)                     # slice_type: I (all slices of the picture)
    w.ue(0)                     # pic_parameter_set_id
    w.u(4, 0)                   # frame_num (log2_max_frame_num = 4)
    w.ue(idr_pic_id)
    w.u(1, 0)                   # no_output_of_prior_pics_flag
    w.u(1, 0)                   # long_term_reference_flag
    w.se(qp - 26)               # slice_qp_delta
    if deblock:
        w.ue(0)                 # disable_deblocking_filter_idc: filter on
        w.se(0)                 # slice_alpha_c0_offset_div2
        w.se(0)                 # slice_beta_offset_div2
    else:
        w.ue(1)                 # filter off


# ============================================================ 4:2:0 input
def yuv444_to_420(frame, width, height):
    """ISP output (rows of (Y, U, V), 8 bit) -> Y, Cb, Cr planes. Chroma is
    the rounded mean of each 2x2 block (bow_h264_input)."""
    assert width % 16 == 0 and height % 2 == 0
    Y = [[p[0] for p in row[:width]] for row in frame[:height]]
    Cb, Cr = [], []
    for cy in range(height // 2):
        r0, r1 = frame[2 * cy], frame[2 * cy + 1]
        Cb.append([(r0[2 * x][1] + r0[2 * x + 1][1] + r1[2 * x][1] + r1[2 * x + 1][1] + 2) >> 2
                   for x in range(width // 2)])
        Cr.append([(r0[2 * x][2] + r0[2 * x + 1][2] + r1[2 * x][2] + r1[2 * x + 1][2] + 2) >> 2
                   for x in range(width // 2)])
    return Y, Cb, Cr


# =========================================================== transforms
def fwd4x4(x):
    """Forward core transform W = Cf X Cf^T (exact), raster order."""
    t = [0] * 16
    for i in range(4):
        x0, x1, x2, x3 = x[4 * i:4 * i + 4]
        s03, d03, s12, d12 = x0 + x3, x0 - x3, x1 + x2, x1 - x2
        t[4 * i:4 * i + 4] = [s03 + s12, 2 * d03 + d12, s03 - s12, d03 - 2 * d12]
    w = [0] * 16
    for j in range(4):
        t0, t1, t2, t3 = t[j], t[4 + j], t[8 + j], t[12 + j]
        s03, d03, s12, d12 = t0 + t3, t0 - t3, t1 + t2, t1 - t2
        w[j], w[4 + j], w[8 + j], w[12 + j] = s03 + s12, 2 * d03 + d12, s03 - s12, d03 - 2 * d12
    return w


def inv4x4(d):
    """Inverse transform of clause 8.5.12.2 (rows first), residual r_ij."""
    f = [0] * 16
    for i in range(4):
        d0, d1, d2, d3 = d[4 * i:4 * i + 4]
        e0, e1, e2, e3 = d0 + d2, d0 - d2, (d1 >> 1) - d3, d1 + (d3 >> 1)
        f[4 * i:4 * i + 4] = [e0 + e3, e1 + e2, e1 - e2, e0 - e3]
    r = [0] * 16
    for j in range(4):
        f0, f1, f2, f3 = f[j], f[4 + j], f[8 + j], f[12 + j]
        g0, g1, g2, g3 = f0 + f2, f0 - f2, (f1 >> 1) - f3, f1 + (f3 >> 1)
        r[j] = (g0 + g3 + 32) >> 6
        r[4 + j] = (g1 + g2 + 32) >> 6
        r[8 + j] = (g1 - g2 + 32) >> 6
        r[12 + j] = (g0 - g3 + 32) >> 6
    return r


H4 = [[1, 1, 1, 1], [1, 1, -1, -1], [1, -1, -1, 1], [1, -1, 1, -1]]
H2 = [[1, 1], [1, -1]]


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(len(b))) for j in range(len(b[0]))]
            for i in range(len(a))]


def hadamard(m, h):
    return matmul(matmul(h, m), h)


def quant(w, mf, qbits, f):
    a = (abs(w) * mf + f) >> qbits
    if a > LEVEL_MAX:
        a = LEVEL_MAX
    return -a if w < 0 else a


def clip8(v):
    return 0 if v < 0 else 255 if v > 255 else v


# ===================================================== intra prediction
def pred_luma(mode, top, left, tl):
    """16x16 prediction (clause 8.3.3), list of 16 rows."""
    if mode == I16_V:
        return [list(top) for _ in range(16)]
    if mode == I16_H:
        return [[left[y]] * 16 for y in range(16)]
    if mode == I16_DC:
        if top is not None and left is not None:
            dc = (sum(top) + sum(left) + 16) >> 5
        elif left is not None:
            dc = (sum(left) + 8) >> 4
        elif top is not None:
            dc = (sum(top) + 8) >> 4
        else:
            dc = 128
        return [[dc] * 16 for _ in range(16)]
    a, b, c = plane_params(top, left, tl, 16)
    return [[clip8((a + b * (x - 7) + c * (y - 7) + 16) >> 5) for x in range(16)]
            for y in range(16)]


def plane_params(top, left, tl, n):
    """a, b, c of the plane prediction for an n x n block (16 luma, 8 chroma
    4:2:0). p[-1] of the formulas is the top-left sample."""
    t = [tl] + list(top)        # t[k + 1] = p[k, -1]
    l = [tl] + list(left)       # l[k + 1] = p[-1, k]
    h2 = n // 2
    hs = sum((k + 1) * (t[h2 + k + 1] - t[h2 - 2 - k + 1]) for k in range(h2))
    vs = sum((k + 1) * (l[h2 + k + 1] - l[h2 - 2 - k + 1]) for k in range(h2))
    a = 16 * (left[n - 1] + top[n - 1])
    if n == 16:
        b = (5 * hs + 32) >> 6
        c = (5 * vs + 32) >> 6
    else:
        b = (34 * hs + 32) >> 6
        c = (34 * vs + 32) >> 6
    return a, b, c


def pred_chroma(mode, top, left, tl):
    """8x8 chroma prediction (clause 8.3.4, 4:2:0), list of 8 rows."""
    if mode == C_H:
        return [[left[y]] * 8 for y in range(8)]
    if mode == C_V:
        return [list(top) for _ in range(8)]
    if mode == C_P:
        a, b, c = plane_params(top, left, tl, 8)
        return [[clip8((a + b * (x - 3) + c * (y - 3) + 16) >> 5) for x in range(8)]
                for y in range(8)]
    p = [[0] * 8 for _ in range(8)]
    for k in range(4):
        xo, yo = 4 * (k % 2), 4 * (k // 2)
        st = sum(top[xo:xo + 4]) if top is not None else None
        sl = sum(left[yo:yo + 4]) if left is not None else None
        if k in (0, 3):
            if st is not None and sl is not None:
                dc = (st + sl + 4) >> 3
            elif sl is not None:
                dc = (sl + 2) >> 2
            elif st is not None:
                dc = (st + 2) >> 2
            else:
                dc = 128
        elif k == 1:
            dc = (st + 2) >> 2 if st is not None else (sl + 2) >> 2 if sl is not None else 128
        else:
            dc = (sl + 2) >> 2 if sl is not None else (st + 2) >> 2 if st is not None else 128
        for y in range(4):
            for x in range(4):
                p[yo + y][xo + x] = dc
    return p


def sad(orig, pred):
    return sum(abs(o - p) for ro, rp in zip(orig, pred) for o, p in zip(ro, rp))


# ===================================================================== CAVLC
def cavlc_block(w, coeffs, nc, maxnum):
    """residual_block_cavlc() of `coeffs` (coding order). Returns TotalCoeff."""
    nz = [i for i, c in enumerate(coeffs) if c]
    tc = len(nz)
    levels = [coeffs[i] for i in reversed(nz)]      # highest frequency first
    t1 = 0
    while t1 < min(3, tc) and abs(levels[t1]) == 1:
        t1 += 1
    w.u(*coeff_token_code(nc, tc, t1))
    if tc == 0:
        return 0
    for i in range(t1):
        w.u(1, 1 if levels[i] < 0 else 0)            # trailing_ones_sign_flag
    suffix_len = 1 if tc > 10 and t1 < 3 else 0
    for i in range(t1, tc):
        lv = levels[i]
        code = 2 * lv - 2 if lv > 0 else -2 * lv - 1
        if i == t1 and t1 < 3:
            code -= 2
        if suffix_len == 0:
            if code < 14:
                prefix, sbits, sval = code, 0, 0
            elif code < 30:
                prefix, sbits, sval = 14, 4, code - 14
            else:
                prefix, sbits, sval = 15, 12, code - 30
        elif code < (15 << suffix_len):
            prefix, sbits, sval = code >> suffix_len, suffix_len, code & ((1 << suffix_len) - 1)
        else:
            prefix, sbits, sval = 15, 12, code - (15 << suffix_len)
        assert sval < (1 << sbits) or sbits == 0, "level out of the CAVLC range"
        w.u(prefix + 1, 1)                           # level_prefix
        w.u(sbits, sval)                             # level_suffix
        if suffix_len == 0:
            suffix_len = 1
        if abs(lv) > (3 << (suffix_len - 1)) and suffix_len < 6:
            suffix_len += 1
    if tc < maxnum:
        tz = nz[-1] + 1 - tc
        if maxnum == 4:
            w.u(CHROMA_DC_TOTAL_ZEROS_LEN[tc - 1][tz], CHROMA_DC_TOTAL_ZEROS_BITS[tc - 1][tz])
        else:
            w.u(TOTAL_ZEROS_LEN[tc - 1][tz], TOTAL_ZEROS_BITS[tc - 1][tz])
    else:
        tz = 0
    zl = tz
    for i in range(tc - 1):
        if zl == 0:
            break
        run = nz[tc - 1 - i] - nz[tc - 2 - i] - 1
        k = min(zl, 7) - 1
        w.u(RUN_LEN[k][run], RUN_BITS[k][run])
        zl -= run
    return tc


def predict_nc(tc_map, x, y):
    """nC from the left (A) and top (B) 4x4 blocks of block (x, y) of a
    TotalCoeff map (one slice per frame: unavailable only outside)."""
    na = tc_map[y][x - 1] if x > 0 else None
    nb = tc_map[y - 1][x] if y > 0 else None
    if na is not None and nb is not None:
        return (na + nb + 1) >> 1
    if na is not None:
        return na
    if nb is not None:
        return nb
    return 0


# ================================================================== encoder
class MbInfo:
    __slots__ = ("mode", "cmode", "cbp_luma", "cbp_chroma", "bits")


class Encoder:
    """Frame encoder (one IDR slice per frame), see module docstring."""

    def __init__(self, width, height):
        assert width % 16 == 0 and 16 <= width <= 4096 and height % 2 == 0 and height >= 16
        self.w, self.h = width, height
        self.mbw, self.mbh = width // 16, (height + 15) // 16

    def encode(self, planes, qp, idr_pic_id=0, deblock=False):
        """Encode one frame. Returns (Annex B NAL padded to 4 bytes,
        reconstruction (Y, Cb, Cr) of the coded size, list of MbInfo)."""
        assert QP_MIN <= qp <= QP_MAX
        Y, Cb, Cr = planes
        self.qp = qp
        self.qpc = QPC[qp]
        self.ry = [[0] * self.w for _ in range(16 * self.mbh)]
        self.rc = [[[0] * (self.w // 2) for _ in range(8 * self.mbh)] for _ in range(2)]
        self.tcl = [[0] * (4 * self.mbw) for _ in range(4 * self.mbh)]
        self.tcc = [[[0] * (2 * self.mbw) for _ in range(2 * self.mbh)] for _ in range(2)]
        # source planes with the last line repeated down to the coded size
        hy, hc = self.h, self.h // 2
        self.sy = [Y[min(y, hy - 1)] for y in range(16 * self.mbh)]
        self.sc = [[P[min(y, hc - 1)] for y in range(8 * self.mbh)] for P in (Cb, Cr)]

        w = BitWriter()
        slice_header(w, idr_pic_id, qp, deblock)
        info = []
        for mby in range(self.mbh):
            for mbx in range(self.mbw):
                start = w.nbits
                mi = self.encode_mb(w, mbx, mby)
                mi.bits = w.nbits - start
                info.append(mi)
        w.trailing()
        return nal(NAL_HDR_IDR, w.data()), (self.ry, self.rc[0], self.rc[1]), info

    # ---------------------------------------------------------------- luma
    def luma(self, mbx, mby):
        x0, y0 = 16 * mbx, 16 * mby
        ry = self.ry
        top = ry[y0 - 1][x0:x0 + 16] if mby else None
        left = [ry[y0 + y][x0 - 1] for y in range(16)] if mbx else None
        tl = ry[y0 - 1][x0 - 1] if mbx and mby else None
        orig = [self.sy[y0 + y][x0:x0 + 16] for y in range(16)]

        # mode decision: smallest SAD, the lowest mode number on a tie
        best, best_sad, pred = None, None, None
        for mode in (I16_V, I16_H, I16_DC, I16_P):
            if (mode == I16_V and top is None) or (mode == I16_H and left is None) or \
               (mode == I16_P and (top is None or left is None)):
                continue
            p = pred_luma(mode, top, left, tl)
            s = sad(orig, p)
            if best is None or s < best_sad:
                best, best_sad, pred = mode, s, p

        qp = self.qp
        m, k = qp % 6, qp // 6
        qbits = 15 + k
        f = (1 << qbits) // 3
        mfs = [MF[m][POS_CLASS[i]] for i in range(16)]
        # forward: residual, transform, AC quantisation; DC to the Hadamard
        ac = []
        dcm = [[0] * 4 for _ in range(4)]
        for blk in range(16):
            bx, by = BLK_XY[blk]
            res = [orig[4 * by + i][4 * bx + j] - pred[4 * by + i][4 * bx + j]
                   for i in range(4) for j in range(4)]
            wc = fwd4x4(res)
            dcm[by][bx] = wc[0]
            lv = [0] + [quant(wc[i], mfs[i], qbits, f) for i in range(1, 16)]
            ac.append(lv)
        hd = hadamard(dcm, H4)
        dcl = [[quant(hd[i][j] >> 1, MF[m][0], qbits + 1, 2 * f) for j in range(4)]
               for i in range(4)]
        # inverse: DC (clause 8.5.10), then every block
        fd = hadamard(dcl, H4)
        ls0 = 16 * VS[m][0]
        if k >= 6:
            dcy = [[(fd[i][j] * ls0) << (k - 6) for j in range(4)] for i in range(4)]
        else:
            rnd = 1 << (5 - k)
            dcy = [[(fd[i][j] * ls0 + rnd) >> (6 - k) for j in range(4)] for i in range(4)]
        vs = [VS[m][POS_CLASS[i]] for i in range(16)]
        for blk in range(16):
            bx, by = BLK_XY[blk]
            d = [dcy[by][bx]] + [(ac[blk][i] * vs[i]) << k for i in range(1, 16)]
            r = inv4x4(d)
            for i in range(4):
                row = ry[y0 + 4 * by + i]
                for j in range(4):
                    row[x0 + 4 * bx + j] = clip8(pred[4 * by + i][4 * bx + j] + r[4 * i + j])
        cbp = 15 if any(any(lv) for lv in ac) else 0
        return best, cbp, ac, dcl

    # -------------------------------------------------------------- chroma
    def chroma(self, mbx, mby):
        x0, y0 = 8 * mbx, 8 * mby
        tops, lefts, tls, origs = [], [], [], []
        for c in range(2):
            rc = self.rc[c]
            tops.append(rc[y0 - 1][x0:x0 + 8] if mby else None)
            lefts.append([rc[y0 + y][x0 - 1] for y in range(8)] if mbx else None)
            tls.append(rc[y0 - 1][x0 - 1] if mbx and mby else None)
            origs.append([self.sc[c][y0 + y][x0:x0 + 8] for y in range(8)])
        best, best_sad, preds = None, None, None
        for mode in (C_DC, C_H, C_V, C_P):
            if (mode == C_H and mbx == 0) or (mode == C_V and mby == 0) or \
               (mode == C_P and (mbx == 0 or mby == 0)):
                continue
            p = [pred_chroma(mode, tops[c], lefts[c], tls[c]) for c in range(2)]
            s = sad(origs[0], p[0]) + sad(origs[1], p[1])
            if best is None or s < best_sad:
                best, best_sad, preds = mode, s, p

        qpc = self.qpc
        m, k = qpc % 6, qpc // 6
        qbits = 15 + k
        f = (1 << qbits) // 3
        mfs = [MF[m][POS_CLASS[i]] for i in range(16)]
        vs = [VS[m][POS_CLASS[i]] for i in range(16)]
        ls0 = 16 * VS[m][0]
        acs, dcls = [], []
        for c in range(2):
            orig, pred, rc = origs[c], preds[c], self.rc[c]
            ac = []
            dcm = [[0, 0], [0, 0]]
            for blk in range(4):
                bx, by = blk % 2, blk // 2
                res = [orig[4 * by + i][4 * bx + j] - pred[4 * by + i][4 * bx + j]
                       for i in range(4) for j in range(4)]
                wc = fwd4x4(res)
                dcm[by][bx] = wc[0]
                ac.append([0] + [quant(wc[i], mfs[i], qbits, f) for i in range(1, 16)])
            hd = hadamard(dcm, H2)
            dcl = [quant(hd[i][j], MF[m][0], qbits + 1, 2 * f) for i in range(2) for j in range(2)]
            fd = hadamard([dcl[0:2], dcl[2:4]], H2)
            dcc = [((fd[i][j] * ls0) << k) >> 5 for i in range(2) for j in range(2)]
            for blk in range(4):
                bx, by = blk % 2, blk // 2
                d = [dcc[blk]] + [(ac[blk][i] * vs[i]) << k for i in range(1, 16)]
                r = inv4x4(d)
                for i in range(4):
                    row = rc[y0 + 4 * by + i]
                    for j in range(4):
                        row[x0 + 4 * bx + j] = clip8(pred[4 * by + i][4 * bx + j] + r[4 * i + j])
            acs.append(ac)
            dcls.append(dcl)
        if any(any(lv) for ac in acs for lv in ac):
            cbp = 2
        elif any(any(d) for d in dcls):
            cbp = 1
        else:
            cbp = 0
        return best, cbp, acs, dcls

    # ---------------------------------------------------------- macroblock
    def encode_mb(self, w, mbx, mby):
        mode, cbpl, ac, dcl = self.luma(mbx, mby)
        cmode, cbpc, cac, cdcl = self.chroma(mbx, mby)
        mi = MbInfo()
        mi.mode, mi.cmode, mi.cbp_luma, mi.cbp_chroma = mode, cmode, cbpl, cbpc
        w.ue(1 + mode + 4 * cbpc + (12 if cbpl else 0))     # mb_type I_16x16_m_c_l
        w.ue(cmode)                                          # intra_chroma_pred_mode
        w.se(0)                                              # mb_qp_delta
        bx0, by0 = 4 * mbx, 4 * mby
        # Intra16x16DCLevel: nC of luma block 0
        cavlc_block(w, [dcl[ZIGZAG[s] // 4][ZIGZAG[s] % 4] for s in range(16)],
                    predict_nc(self.tcl, bx0, by0), 16)
        for blk in range(16):
            bx, by = BLK_XY[blk]
            if cbpl:
                coeffs = [ac[blk][ZIGZAG[s]] for s in range(1, 16)]
                tc = cavlc_block(w, coeffs, predict_nc(self.tcl, bx0 + bx, by0 + by), 15)
            else:
                tc = 0
            self.tcl[by0 + by][bx0 + bx] = tc
        if cbpc:
            for c in range(2):
                cavlc_block(w, cdcl[c], -1, 4)
        cx0, cy0 = 2 * mbx, 2 * mby
        for c in range(2):
            for blk in range(4):
                bx, by = blk % 2, blk // 2
                if cbpc == 2:
                    coeffs = [cac[c][blk][ZIGZAG[s]] for s in range(1, 16)]
                    tc = cavlc_block(w, coeffs, predict_nc(self.tcc[c], cx0 + bx, cy0 + by), 15)
                else:
                    tc = 0
                self.tcc[c][cy0 + by][cx0 + bx] = tc
        return mi


def encode_sequence(frames444, width, height, qps, deblock=False, fps=(30, 1), full_range=False):
    """Whole Annex B stream (SPS, PPS, one IDR per frame, idr_pic_id 0, 1,
    0, ...). Returns (stream, reconstructions)."""
    out = sps_nal(width, height, fps[0], fps[1], full_range) + pps_nal()
    enc = Encoder(width, height)
    recons = []
    for i, fr in enumerate(frames444):
        n, rec, _ = enc.encode(yuv444_to_420(fr, width, height), qps[i % len(qps)], i & 1, deblock)
        out += n
        recons.append(rec)
    return out, recons


# ================================================================== decoder
class BitReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def u(self, n):
        v = 0
        for _ in range(n):
            byte = self.data[self.pos >> 3]
            v = (v << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v

    def ue(self, limit=32):
        z = 0
        while self.u(1) == 0:
            z += 1
            if z > limit:
                raise ValueError("bad Exp-Golomb code")
        return (1 << z) - 1 + self.u(z)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)

    def more_rbsp_data(self):
        """True while bits other than the rbsp_trailing_bits are left."""
        total = len(self.data) * 8
        last = total - 1
        while last >= 0 and not (self.data[last >> 3] >> (7 - (last & 7))) & 1:
            last -= 1
        return self.pos < last


def split_nals(stream):
    """Annex B byte stream -> list of (nal_unit_type, nal_ref_idc, rbsp)."""
    out = []
    i, n = 0, len(stream)
    starts = []
    while i + 3 <= n:
        if stream[i] == 0 and stream[i + 1] == 0 and stream[i + 2] == 1:
            starts.append(i + 3)
            i += 3
        else:
            i += 1
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else n
        body = stream[s:e]
        while body and body[-1] == 0:   # trailing_zero_8bits / next zero_byte
            body = body[:-1]
        if not body:
            continue
        rbsp = bytearray()
        zeros = 0
        for b in body[1:]:
            if zeros == 2 and b == 3:
                zeros = 0
                continue
            rbsp.append(b)
            zeros = zeros + 1 if b == 0 else 0
        out.append((body[0] & 0x1F, (body[0] >> 5) & 3, bytes(rbsp)))
    return out


def _build_vlc(lens, bits):
    return {(lens[i], bits[i]): i for i in range(len(lens)) if lens[i]}


_CT_VLC = [_build_vlc(COEFF_TOKEN_LEN[t], COEFF_TOKEN_BITS[t]) for t in range(4)]
_CT_DC_VLC = _build_vlc(CHROMA_DC_COEFF_TOKEN_LEN, CHROMA_DC_COEFF_TOKEN_BITS)
_TZ_VLC = [_build_vlc(TOTAL_ZEROS_LEN[i], TOTAL_ZEROS_BITS[i]) for i in range(15)]
_TZ_DC_VLC = [_build_vlc(CHROMA_DC_TOTAL_ZEROS_LEN[i], CHROMA_DC_TOTAL_ZEROS_BITS[i])
              for i in range(3)]
_RUN_VLC = [_build_vlc(RUN_LEN[i], RUN_BITS[i]) for i in range(7)]


def _read_vlc(r, table, maxlen=16):
    code = 0
    for n in range(1, maxlen + 1):
        code = (code << 1) | r.u(1)
        if (n, code) in table:
            return table[(n, code)]
    raise ValueError("invalid VLC code")


def cavlc_read(r, nc, maxnum):
    """Decode residual_block_cavlc(), coefficients in coding order + TC."""
    t = coeff_token_table(nc)
    idx = _read_vlc(r, _CT_DC_VLC if t < 0 else _CT_VLC[t])
    tc, t1 = idx >> 2, idx & 3
    coeffs = [0] * maxnum
    if tc == 0:
        return coeffs, 0
    if tc > maxnum:
        raise ValueError("TotalCoeff larger than the block")
    levels = []
    for _ in range(t1):
        levels.append(-1 if r.u(1) else 1)
    suffix_len = 1 if tc > 10 and t1 < 3 else 0
    for i in range(t1, tc):
        prefix = 0
        while r.u(1) == 0:
            prefix += 1
            if prefix > 15:
                raise ValueError("level_prefix > 15 (not allowed in baseline)")
        if prefix == 14 and suffix_len == 0:
            ssize = 4
        elif prefix >= 15:
            ssize = prefix - 3
        else:
            ssize = suffix_len
        code = (min(15, prefix) << suffix_len) + (r.u(ssize) if ssize else 0)
        if prefix >= 15 and suffix_len == 0:
            code += 15
        if i == t1 and t1 < 3:
            code += 2
        lv = (code + 2) >> 1 if code % 2 == 0 else (-code - 1) >> 1
        levels.append(lv)
        if suffix_len == 0:
            suffix_len = 1
        if abs(lv) > (3 << (suffix_len - 1)) and suffix_len < 6:
            suffix_len += 1
    if tc < maxnum:
        tz = _read_vlc(r, _TZ_DC_VLC[tc - 1] if maxnum == 4 else _TZ_VLC[tc - 1])
    else:
        tz = 0
    runs = [0] * tc
    zl = tz
    for i in range(tc - 1):
        if zl > 0:
            runs[i] = _read_vlc(r, _RUN_VLC[min(zl, 7) - 1])
            zl -= runs[i]
    runs[tc - 1] = zl
    pos = -1
    for i in range(tc - 1, -1, -1):
        pos += runs[i] + 1
        if pos >= maxnum:
            raise ValueError("coefficients beyond the block")
        coeffs[pos] = levels[i]
    return coeffs, tc


class Decoder:
    """Decoder for the streams of this encoder: IDR / I slices of I_16x16
    macroblocks, CAVLC. Output: reconstructed frames before deblocking."""

    def __init__(self):
        self.sps = None
        self.pps = None
        self.frames = []
        self.mb_info = []

    def feed(self, stream):
        for typ, ref, rbsp in split_nals(stream):
            if typ == NAL_SPS:
                self.parse_sps(rbsp)
            elif typ == NAL_PPS:
                self.parse_pps(rbsp)
            elif typ in (1, NAL_SLICE_IDR):
                self.decode_slice(typ, ref, rbsp)
        return self.frames

    def parse_sps(self, rbsp):
        r = BitReader(rbsp)
        s = {"profile": r.u(8), "constraints": r.u(8), "level": r.u(8), "id": r.ue()}
        if s["profile"] in (100, 110, 122, 244, 44, 83, 86, 118, 128):
            raise ValueError("high profiles not supported")
        s["log2_max_frame_num"] = r.ue() + 4
        s["poc_type"] = r.ue()
        if s["poc_type"] == 0:
            s["log2_max_poc_lsb"] = r.ue() + 4
        elif s["poc_type"] == 1:
            raise ValueError("pic_order_cnt_type 1 not supported")
        s["max_num_ref_frames"] = r.ue()
        r.u(1)
        s["mbw"] = r.ue() + 1
        s["mbh"] = r.ue() + 1
        if not r.u(1):
            raise ValueError("field coding not supported")
        r.u(1)
        crop = [0, 0, 0, 0]
        if r.u(1):
            crop = [r.ue() for _ in range(4)]
        s["crop"] = crop
        s["width"] = 16 * s["mbw"] - 2 * (crop[0] + crop[1])
        s["height"] = 16 * s["mbh"] - 2 * (crop[2] + crop[3])
        s["vui"] = r.u(1)
        self.sps = s

    def parse_pps(self, rbsp):
        r = BitReader(rbsp)
        p = {"id": r.ue(), "sps_id": r.ue(), "cabac": r.u(1), "bottom_field_poc": r.u(1),
             "slice_groups": r.ue() + 1}
        if p["cabac"] or p["slice_groups"] != 1:
            raise ValueError("CABAC / slice groups not supported")
        p["ref_l0"] = r.ue() + 1
        p["ref_l1"] = r.ue() + 1
        p["weighted_pred"] = r.u(1)
        p["weighted_bipred"] = r.u(2)
        p["init_qp"] = 26 + r.se()
        p["init_qs"] = 26 + r.se()
        p["chroma_qp_offset"] = r.se()
        p["deblock_ctrl"] = r.u(1)
        p["constrained_intra"] = r.u(1)
        p["redundant_pic_cnt"] = r.u(1)
        self.pps = p

    def decode_slice(self, typ, ref, rbsp):
        sps, pps = self.sps, self.pps
        if sps is None or pps is None:
            raise ValueError("slice before SPS / PPS")
        r = BitReader(rbsp)
        first_mb = r.ue()
        slice_type = r.ue()
        if slice_type % 5 != 2:
            raise ValueError("only I slices are supported")
        r.ue()                                          # pic_parameter_set_id
        r.u(sps["log2_max_frame_num"])                  # frame_num
        hdr = {"first_mb": first_mb, "slice_type": slice_type}
        if typ == NAL_SLICE_IDR:
            hdr["idr_pic_id"] = r.ue()
        if sps["poc_type"] == 0:
            r.u(sps["log2_max_poc_lsb"])
            if pps["bottom_field_poc"]:
                r.se()
        if pps["redundant_pic_cnt"]:
            r.ue()
        if ref:
            if typ == NAL_SLICE_IDR:
                r.u(1)
                r.u(1)
            elif r.u(1):
                raise ValueError("adaptive_ref_pic_marking not supported")
        qp = pps["init_qp"] + r.se()
        hdr["qp"] = qp
        hdr["deblock_idc"] = 0
        if pps["deblock_ctrl"]:
            hdr["deblock_idc"] = r.ue()
            if hdr["deblock_idc"] != 1:
                r.se()
                r.se()
        mbw, mbh = sps["mbw"], sps["mbh"]
        if first_mb != 0:
            raise ValueError("one slice per frame expected")
        self.ry = [[0] * (16 * mbw) for _ in range(16 * mbh)]
        self.rc = [[[0] * (8 * mbw) for _ in range(8 * mbh)] for _ in range(2)]
        self.tcl = [[0] * (4 * mbw) for _ in range(4 * mbh)]
        self.tcc = [[[0] * (2 * mbw) for _ in range(2 * mbh)] for _ in range(2)]
        self.qp = qp
        info = []
        for mb in range(mbw * mbh):
            info.append(self.decode_mb(r, mb % mbw, mb // mbw, pps["chroma_qp_offset"]))
        if r.more_rbsp_data():
            raise ValueError("data after the last macroblock")
        hdr["mbs"] = info
        self.mb_info.append(hdr)
        h, wd = sps["height"], sps["width"]
        self.frames.append(([row[:wd] for row in self.ry[:h]],
                            [row[:wd // 2] for row in self.rc[0][:h // 2]],
                            [row[:wd // 2] for row in self.rc[1][:h // 2]]))

    def decode_mb(self, r, mbx, mby, cqp_off):
        mb_type = r.ue()
        if not 1 <= mb_type <= 24:
            raise ValueError(f"mb_type {mb_type} not supported (MB {mbx},{mby})")
        mode = (mb_type - 1) % 4
        cbpc = ((mb_type - 1) // 4) % 3
        cbpl = 15 if mb_type >= 13 else 0
        cmode = r.ue()
        if cmode > 3:
            raise ValueError("bad intra_chroma_pred_mode")
        self.qp = (self.qp + r.se() + 52) % 52
        qp = self.qp
        bx0, by0 = 4 * mbx, 4 * mby
        dcc, _ = cavlc_read(r, predict_nc(self.tcl, bx0, by0), 16)
        dcl = [[0] * 4 for _ in range(4)]
        for s in range(16):
            dcl[ZIGZAG[s] // 4][ZIGZAG[s] % 4] = dcc[s]
        ac = []
        for blk in range(16):
            bx, by = BLK_XY[blk]
            lv = [0] * 16
            tc = 0
            if cbpl:
                coeffs, tc = cavlc_read(r, predict_nc(self.tcl, bx0 + bx, by0 + by), 15)
                for s in range(1, 16):
                    lv[ZIGZAG[s]] = coeffs[s - 1]
            self.tcl[by0 + by][bx0 + bx] = tc
            ac.append(lv)
        cdc = [[0] * 4, [0] * 4]
        if cbpc:
            for c in range(2):
                cdc[c], _ = cavlc_read(r, -1, 4)
        cac = [[], []]
        cx0, cy0 = 2 * mbx, 2 * mby
        for c in range(2):
            for blk in range(4):
                bx, by = blk % 2, blk // 2
                lv = [0] * 16
                tc = 0
                if cbpc == 2:
                    coeffs, tc = cavlc_read(r, predict_nc(self.tcc[c], cx0 + bx, cy0 + by), 15)
                    for s in range(1, 16):
                        lv[ZIGZAG[s]] = coeffs[s - 1]
                self.tcc[c][cy0 + by][cx0 + bx] = tc
                cac[c].append(lv)
        # luma reconstruction
        x0, y0 = 16 * mbx, 16 * mby
        ry = self.ry
        top = ry[y0 - 1][x0:x0 + 16] if mby else None
        left = [ry[y0 + y][x0 - 1] for y in range(16)] if mbx else None
        tl = ry[y0 - 1][x0 - 1] if mbx and mby else None
        if (mode in (I16_V, I16_P) and top is None) or (mode in (I16_H, I16_P) and left is None):
            raise ValueError(f"prediction mode {mode} needs unavailable samples (MB {mbx},{mby})")
        pred = pred_luma(mode, top, left, tl)
        m, k = qp % 6, qp // 6
        fd = hadamard(dcl, H4)
        ls0 = 16 * VS[m][0]
        if k >= 6:
            dcy = [[(fd[i][j] * ls0) << (k - 6) for j in range(4)] for i in range(4)]
        else:
            dcy = [[(fd[i][j] * ls0 + (1 << (5 - k))) >> (6 - k) for j in range(4)]
                   for i in range(4)]
        vs = [VS[m][POS_CLASS[i]] for i in range(16)]
        for blk in range(16):
            bx, by = BLK_XY[blk]
            d = [dcy[by][bx]] + [(ac[blk][i] * vs[i]) << k for i in range(1, 16)]
            res = inv4x4(d)
            for i in range(4):
                for j in range(4):
                    ry[y0 + 4 * by + i][x0 + 4 * bx + j] = clip8(pred[4 * by + i][4 * bx + j] +
                                                                 res[4 * i + j])
        # chroma reconstruction
        qpc = QPC[max(0, min(51, qp + cqp_off))]
        m, k = qpc % 6, qpc // 6
        vs = [VS[m][POS_CLASS[i]] for i in range(16)]
        ls0 = 16 * VS[m][0]
        cx, cy = 8 * mbx, 8 * mby
        for c in range(2):
            rc = self.rc[c]
            top = rc[cy - 1][cx:cx + 8] if mby else None
            left = [rc[cy + y][cx - 1] for y in range(8)] if mbx else None
            tl = rc[cy - 1][cx - 1] if mbx and mby else None
            if (cmode in (C_V, C_P) and top is None) or (cmode in (C_H, C_P) and left is None):
                raise ValueError(f"chroma mode {cmode} needs unavailable samples")
            pred = pred_chroma(cmode, top, left, tl)
            fd = hadamard([cdc[c][0:2], cdc[c][2:4]], H2)
            dcc = [((fd[i][j] * ls0) << k) >> 5 for i in range(2) for j in range(2)]
            for blk in range(4):
                bx, by = blk % 2, blk // 2
                d = [dcc[blk]] + [(cac[c][blk][i] * vs[i]) << k for i in range(1, 16)]
                res = inv4x4(d)
                for i in range(4):
                    for j in range(4):
                        rc[cy + 4 * by + i][cx + 4 * bx + j] = clip8(pred[4 * by + i][4 * bx + j] +
                                                                     res[4 * i + j])
        return (mode, cmode, cbpl, cbpc)


def decode(stream):
    """Decode an Annex B stream of this encoder: list of (Y, Cb, Cr)."""
    return Decoder().feed(stream)


# ============================================================ test images
def test_frame(rnd, width, height, kind):
    """YUV 4:4:4 test frame (rows of (Y, U, V)) of a given kind."""
    if kind == "noise":
        return [[(rnd.randrange(256), rnd.randrange(256), rnd.randrange(256))
                 for _ in range(width)] for _ in range(height)]
    if kind == "flat":
        v = (rnd.randrange(256), rnd.randrange(256), rnd.randrange(256))
        return [[v] * width for _ in range(height)]
    if kind == "ramp":
        ax, ay = rnd.uniform(-2, 2), rnd.uniform(-2, 2)
        return [[(clip8(int(128 + ax * (x - width / 2) + ay * (y - height / 2))),
                  clip8(int(128 + ay * (x - width / 2))), clip8(int(128 - ax * (y - height / 2))))
                 for x in range(width)] for y in range(height)]
    # "scene": smooth shapes + edges + some noise, like a camera image
    shapes = [(rnd.randrange(width), rnd.randrange(height), rnd.randrange(4, max(5, width // 3)),
               (rnd.randrange(256), rnd.randrange(256), rnd.randrange(256))) for _ in range(6)]
    ax, ay = rnd.uniform(-1, 1), rnd.uniform(-1, 1)
    out = []
    for y in range(height):
        row = []
        for x in range(width):
            p = [clip8(int(100 + ax * x + ay * y)), 128, 128]
            for cx, cy, rad, col in shapes:
                if (x - cx) ** 2 + (y - cy) ** 2 < rad * rad:
                    p = list(col)
            n = rnd.randrange(-6, 7)
            row.append((clip8(p[0] + n), clip8(p[1] + n // 2), clip8(p[2] - n // 2)))
        out.append(row)
    return out


# ============================================================ unit test I/O
# Test case of hw/ip/h264/dv (read by tb_bow_h264.sv):
#   case.txt   "<w> <h> <frames> <skip> <count> <deblock> <hblank> <vblank> <gap> <bp> <seed>"
#              then one QP per input frame
#   input.hex  frames x h x w pixels, {V, U, Y} (ISP output order), 6 hex digits
#   expect.hex expected output words, "<8 hex digits> <last>"
# The testbench writes out.hex (same format) and status.txt.
def selected_frames(frames, skip, count):
    """Input frames the encoder codes with SKIP and FRAMES (0 = all)."""
    sel = [i for i in range(frames) if i % (skip + 1) == 0]
    return sel[:count] if count else sel


def expected_words(stream_frames):
    words = []
    for data in stream_frames:
        assert len(data) % 4 == 0
        for i in range(0, len(data), 4):
            w = data[i] | data[i + 1] << 8 | data[i + 2] << 16 | data[i + 3] << 24
            words.append((w, 1 if i + 4 == len(data) else 0))
    return words


def cmd_gen(args):
    rnd = random.Random(args.seed)
    d = Path(args.dir)
    d.mkdir(parents=True, exist_ok=True)
    w = args.width or rnd.choice([16, 32, 48, 64, 80])
    h = args.height or rnd.choice([16, 18, 32, 34, 40, 48])
    nf = args.frames
    skip = rnd.choice([0, 0, 1]) if args.skip is None else args.skip
    count = 0
    deblock = rnd.randrange(2)
    kinds = ["scene", "noise", "flat", "ramp"]
    qps = [rnd.randrange(QP_MIN, 52) if i % 4 == 3 else rnd.randrange(18, 40) for i in range(nf)]
    if args.seed % 3 == 0:
        qps[0] = QP_MIN             # large levels: escape codes, many coefficients
    frames = [test_frame(rnd, w, h, kinds[(args.seed + i) % 4]) for i in range(nf)]
    if args.seed % 3 == 0:
        frames[0] = test_frame(rnd, w, h, "noise")
    hblank = rnd.choice([8, 16, 64])
    vblank = rnd.choice([4, 8, 16])
    gap = rnd.choice([0, 10, 30])
    bp = rnd.choice([0, 20, 60])
    with open(d / "case.txt", "w") as f:
        f.write(f"{w} {h} {nf} {skip} {count} {deblock} {hblank} {vblank} {gap} {bp} {args.seed}\n")
        f.write(" ".join(str(q) for q in qps) + "\n")
    with open(d / "input.hex", "w") as f:
        for fr in frames:
            for row in fr:
                for (y, u, v) in row:
                    f.write(f"{v:02x}{u:02x}{y:02x}\n")
    enc = Encoder(w, h)
    outs = []
    for k, i in enumerate(selected_frames(nf, skip, count)):
        n, _, _ = enc.encode(yuv444_to_420(frames[i], w, h), qps[i], k & 1, bool(deblock))
        outs.append(n)
    with open(d / "expect.hex", "w") as f:
        for wd, last in expected_words(outs):
            f.write(f"{wd:08x} {last}\n")
    print(f"{d}: {w}x{h}, {nf} input frames, skip {skip}, deblock {deblock}, "
          f"QP {qps}, {sum(len(o) for o in outs)} bytes expected")


def read_words(path):
    out = []
    for line in Path(path).read_text().split("\n"):
        if line.strip():
            a, b = line.split()
            out.append((int(a, 16), int(b)))
    return out


def words_to_frames(words):
    frames, cur = [], bytearray()
    for wd, last in words:
        cur += bytes([wd & 0xFF, (wd >> 8) & 0xFF, (wd >> 16) & 0xFF, wd >> 24])
        if last:
            frames.append(bytes(cur))
            cur = bytearray()
    if cur:
        frames.append(bytes(cur))
    return frames


def first_difference(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return min(len(a), len(b)) if len(a) != len(b) else -1


def cmd_check(args):
    d = Path(args.dir)
    exp = words_to_frames(read_words(d / "expect.hex"))
    got = words_to_frames(read_words(d / "out.hex"))
    ok = True
    if len(exp) != len(got):
        print(f"FAIL: {len(got)} frames received, {len(exp)} expected")
        ok = False
    for i, (e, g) in enumerate(zip(exp, got)):
        pos = first_difference(e, g)
        if pos >= 0:
            print(f"FAIL: frame {i}: {len(g)} bytes received, {len(e)} expected, "
                  f"first difference at byte {pos}")
            print("  expected", e[max(0, pos - 8):pos + 8].hex(" "))
            print("  received", g[max(0, pos - 8):pos + 8].hex(" "))
            try:
                hdr = START_CODE + b"\x00"
                fs = Decoder()
                case = (d / "case.txt").read_text().split()
                fs.parse_sps(sps_rbsp(int(case[0]), int(case[1])))
                fs.parse_pps(pps_rbsp())
                fs.feed(g)
                print("  the received frame decodes (different encoder decisions)")
            except (ValueError, IndexError) as err:
                print(f"  the received frame does not decode: {err}")
            del hdr
            ok = False
            break
    status = (d / "status.txt").read_text() if (d / "status.txt").exists() else ""
    if "ERR" in status:
        print(f"FAIL: testbench status: {status.strip()}")
        ok = False
    if ok:
        print(f"PASS: {d}: {len(got)} frames, {sum(len(g) for g in got)} bytes identical")
    return 0 if ok else 1


SV_TABLES = "hw/ip/h264/rtl/bow_h264_tables_pkg.sv"


def sv_tables():
    """SystemVerilog package with the CAVLC tables of this file."""
    o = ["// AUTO-GENERATED by `tools/h264/h264_model.py tables` - DO NOT EDIT",
         "//",
         "// CAVLC code tables of ITU-T H.264 (9-5, 9-7, 9-8, 9-9a, 9-10), the same",
         "// values as tools/h264/h264_model.py (copied from FFmpeg h264_cavlc.c).",
         "// Every function returns {length, code}; the code is right aligned.",
         "",
         "package bow_h264_tables_pkg;",
         "",
         "  // coeff_token. tab: 0..3 = nC 0-1, 2-3, 4-7, >= 8; 4 = chroma DC (nC = -1).",
         "  function automatic logic [20:0] coeff_token(logic [2:0] tab, logic [4:0] tc, logic [1:0] t1);",
         "    logic [20:0] r;",
         "    unique case ({tab, tc, t1})"]
    for tab in range(5):
        for tc in range(17 if tab < 4 else 5):
            for t1 in range(min(3, tc) + 1):
                if tab < 4:
                    ln, b = COEFF_TOKEN_LEN[tab][tc * 4 + t1], COEFF_TOKEN_BITS[tab][tc * 4 + t1]
                else:
                    ln, b = CHROMA_DC_COEFF_TOKEN_LEN[tc * 4 + t1], CHROMA_DC_COEFF_TOKEN_BITS[tc * 4 + t1]
                o.append(f"      10'h{(tab << 7) | (tc << 2) | t1:03x}: r = {{5'd{ln}, 16'h{b:04x}}};")
    o += ["      default: r = '0;", "    endcase", "    return r;", "  endfunction", "",
          "  // total_zeros. dc = 1: chroma DC 2x2 (tc 1..3), else 4x4 blocks (tc 1..15).",
          "  function automatic logic [12:0] total_zeros(logic dc, logic [3:0] tc, logic [3:0] tz);",
          "    logic [12:0] r;",
          "    unique case ({dc, tc, tz})"]
    for dc in range(2):
        lens, bits = (CHROMA_DC_TOTAL_ZEROS_LEN, CHROMA_DC_TOTAL_ZEROS_BITS) if dc else \
                     (TOTAL_ZEROS_LEN, TOTAL_ZEROS_BITS)
        for tc in range(1, len(lens) + 1):
            for tz in range(len(lens[tc - 1])):
                o.append(f"      9'h{(dc << 8) | (tc << 4) | tz:03x}: "
                         f"r = {{4'd{lens[tc - 1][tz]}, 9'h{bits[tc - 1][tz]:03x}}};")
    o += ["      default: r = '0;", "    endcase", "    return r;", "  endfunction", "",
          "  // run_before. zl = min(zerosLeft, 7), 1..7.",
          "  function automatic logic [14:0] run_before(logic [2:0] zl, logic [3:0] run);",
          "    logic [14:0] r;",
          "    unique case ({zl, run})"]
    for zl in range(1, 8):
        for run in range(len(RUN_LEN[zl - 1])):
            o.append(f"      7'h{(zl << 4) | run:02x}: r = {{4'd{RUN_LEN[zl - 1][run]}, "
                     f"11'h{RUN_BITS[zl - 1][run]:03x}}};")
    o += ["      default: r = '0;", "    endcase", "    return r;", "  endfunction", "",
          "endpackage", ""]
    return "\n".join(o)


def cmd_tables(args):
    path = Path(__file__).resolve().parent.parent.parent / SV_TABLES
    text = sv_tables()
    if args.check:
        if not path.exists() or path.read_text() != text:
            print(f"{SV_TABLES} is stale (run `tools/h264/h264_model.py tables`)")
            return 1
        print(f"{SV_TABLES} is up to date")
        return 0
    path.write_text(text)
    print(f"wrote {SV_TABLES}")
    return 0


def yuv_to_rgb709(y, u, v, full_range=False):
    """One BT.709 sample -> RGB (8 bit)."""
    if full_range:
        yy, cb, cr = y, u - 128, v - 128
    else:
        yy, cb, cr = (y - 16) * 255 / 219, (u - 128) * 255 / 224, (v - 128) * 255 / 224
    rgb = (yy + 1.5748 * cr, yy - 0.1873 * cb - 0.4681 * cr, yy + 1.8556 * cb)
    return tuple(clip8(int(round(c))) for c in rgb)


def check_bars(frame, width, height):
    """The ISP colour bars (white yellow cyan green magenta red blue black):
    every bar centre in the middle row on / off per RGB component. Returns
    a list of errors."""
    y_pl, cb_pl, cr_pl = frame
    errors = []
    yy = height // 2
    for k in range(8):
        x = k * width // 8 + width // 16
        rgb = yuv_to_rgb709(y_pl[yy][x], cb_pl[yy // 2][x // 2], cr_pl[yy // 2][x // 2])
        want = (k in (0, 1, 4, 5), k < 4, k in (0, 2, 4, 6))
        for c, on in enumerate(want):
            if (on and rgb[c] <= 160) or (not on and rgb[c] >= 80):
                errors.append(f"bar {k} at x={x}: RGB {rgb}")
                break
    return errors


def cmd_decode(args):
    data = Path(args.input).read_bytes()
    if args.hex:
        data = bytes(int(t, 16) for t in data.split())
    dec = Decoder()
    try:
        frames = dec.feed(data)
    except (ValueError, IndexError) as err:
        print(f"FAIL: {args.input} does not decode: {err}")
        return 1
    sps = dec.sps
    print(f"{args.input}: {sps['width']}x{sps['height']} level {sps['level']}, "
          f"{len(frames)} frames")
    ok = True
    if args.frames is not None and len(frames) != args.frames:
        print(f"FAIL: {len(frames)} frames, expected {args.frames}")
        ok = False
    if args.bars:
        for i, fr in enumerate(frames):
            errs = check_bars(fr, sps["width"], sps["height"])
            if errs:
                print(f"FAIL: frame {i}: colour bars wrong: {errs[0]}")
                ok = False
        if ok:
            print(f"PASS: {len(frames)} frames with the 8 colour bars")
    for i, hdr in enumerate(dec.mb_info):
        modes = [0] * 4
        for (m, _, _, _) in hdr["mbs"]:
            modes[m] += 1
        print(f"  frame {i}: QP {hdr['qp']} idr_pic_id {hdr.get('idr_pic_id')} "
              f"deblock_idc {hdr['deblock_idc']} modes V/H/DC/P {modes}")
    if args.yuv:
        with open(args.yuv, "wb") as f:
            for (y, cb, cr) in frames:
                for plane in (y, cb, cr):
                    for row in plane:
                        f.write(bytes(row))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("gen", help="write a test case for hw/ip/h264/dv")
    p.add_argument("dir")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--width", type=int, default=0)
    p.add_argument("--height", type=int, default=0)
    p.add_argument("--frames", type=int, default=3)
    p.add_argument("--skip", type=int, default=None)
    p = sub.add_parser("check", help="compare the testbench output with the model")
    p.add_argument("dir")
    p = sub.add_parser("decode", help="decode an Annex B stream of this encoder")
    p.add_argument("input")
    p.add_argument("--yuv", help="write the frames as raw I420")
    p.add_argument("--hex", action="store_true", help="the input is hex text, one byte per line")
    p.add_argument("--frames", type=int, help="expected number of frames")
    p.add_argument("--bars", action="store_true", help="check the ISP colour bars in every frame")
    p = sub.add_parser("tables", help=f"write the CAVLC tables of the RTL ({SV_TABLES})")
    p.add_argument("--check", action="store_true", help="only check that the file is up to date")
    args = ap.parse_args()
    return {"gen": cmd_gen, "check": cmd_check, "decode": cmd_decode,
            "tables": cmd_tables}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
