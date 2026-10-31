#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""H.264 Annex B byte stream -> MP4 file (ISO/IEC 14496-12 / -15).

Pure Python, no dependencies. One video track, every access unit is one
sample (the slice NAL units of a picture, with 4 byte length prefixes), SPS
and PPS go into the avcC box. The moov box comes first ("fast start"), so
browsers and players can start before the whole file is loaded.

Library:
    write_mp4("out.mp4", annexb_bytes, fps_num=30, fps_den=1)
Command line:
    mp4.py in.h264 -o out.mp4 [--fps 30 | --fps 30000/1001]
"""

import argparse
import struct
import sys
from fractions import Fraction


def nal_units(stream):
    """Annex B -> NAL units (header + payload, emulation prevention kept)."""
    starts = []
    i, n = 0, len(stream)
    while i + 3 <= n:
        if stream[i] == 0 and stream[i + 1] == 0 and stream[i + 2] == 1:
            starts.append(i + 3)
            i += 3
        else:
            i += 1
    out = []
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else n
        nal = bytes(stream[s:e]).rstrip(b"\x00")   # zero_byte / trailing_zero_8bits
        if nal:
            out.append(nal)
    return out


def access_units(nals):
    """Group the slice NAL units into pictures (first_mb_in_slice == 0 starts
    a new one: its ue(v) code is the single bit '1'). Returns (sps, pps, aus)."""
    sps = pps = None
    aus = []
    for nal in nals:
        typ = nal[0] & 0x1F
        if typ == 7 and sps is None:
            sps = nal
        elif typ == 8 and pps is None:
            pps = nal
        elif typ in (1, 5):
            first_mb_zero = len(nal) > 1 and (nal[1] & 0x80)
            if first_mb_zero or not aus:
                aus.append([nal])
            else:
                aus[-1].append(nal)
    return sps, pps, aus


def box(kind, *payload):
    data = b"".join(payload)
    return struct.pack(">I4s", 8 + len(data), kind) + data


def full_box(kind, version, flags, *payload):
    return box(kind, struct.pack(">I", (version << 24) | flags), *payload)


UNITY = struct.pack(">9I", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)


def sps_size(sps):
    """Width and height from the SPS of this encoder family (baseline, no
    scaling lists): parsed with a small Exp-Golomb reader."""
    rbsp = bytearray()
    zeros = 0
    for b in sps[1:]:
        if zeros == 2 and b == 3:
            zeros = 0
            continue
        rbsp.append(b)
        zeros = zeros + 1 if b == 0 else 0
    pos = [0]

    def u(nbits):
        v = 0
        for _ in range(nbits):
            v = (v << 1) | ((rbsp[pos[0] >> 3] >> (7 - (pos[0] & 7))) & 1)
            pos[0] += 1
        return v

    def ue():
        z = 0
        while u(1) == 0:
            z += 1
        return (1 << z) - 1 + u(z)

    profile = u(8)
    u(16)
    ue()
    if profile in (100, 110, 122, 244, 44, 83, 86, 118, 128):
        raise ValueError("high profile SPS not supported")
    ue()                                    # log2_max_frame_num_minus4
    poc = ue()
    if poc == 0:
        ue()
    elif poc == 1:
        raise ValueError("pic_order_cnt_type 1 not supported")
    ue()
    u(1)
    mbw, mbh = ue() + 1, ue() + 1
    frame_mbs_only = u(1)
    if not frame_mbs_only:
        u(1)
    u(1)
    crop = [0, 0, 0, 0]
    if u(1):
        crop = [ue() for _ in range(4)]
    return 16 * mbw - 2 * (crop[0] + crop[1]), 16 * mbh * (2 - frame_mbs_only) - 2 * (crop[2] + crop[3])


def mp4_bytes(stream, fps_num=30, fps_den=1):
    """MP4 file of an Annex B stream (SPS + PPS + frames)."""
    sps, pps, aus = access_units(nal_units(stream))
    if sps is None or pps is None:
        raise ValueError("no SPS / PPS in the stream")
    if not aus:
        raise ValueError("no frames in the stream")
    width, height = sps_size(sps)
    samples = [b"".join(struct.pack(">I", len(n)) + n for n in au) for au in aus]

    timescale = 1000 * fps_num               # media time units per second
    delta = 1000 * fps_den                   # per frame
    count = len(samples)
    mduration = count * delta
    movie_ts = 1000
    duration = count * 1000 * fps_den // fps_num

    avcc = box(b"avcC", bytes([1, sps[1], sps[2], sps[3], 0xFF, 0xE1]),
               struct.pack(">H", len(sps)), sps, b"\x01", struct.pack(">H", len(pps)), pps)
    avc1 = box(b"avc1", b"\x00" * 6, struct.pack(">H", 1), b"\x00" * 16,
               struct.pack(">HHIIIH", width, height, 0x00480000, 0x00480000, 0, 1),
               bytes([5]) + b"Bow32".ljust(31, b"\x00"), struct.pack(">Hh", 0x18, -1), avcc)

    def moov(chunk_offset):
        stbl = box(b"stbl",
                   full_box(b"stsd", 0, 0, struct.pack(">I", 1), avc1),
                   full_box(b"stts", 0, 0, struct.pack(">III", 1, count, delta)),
                   full_box(b"stsc", 0, 0, struct.pack(">IIII", 1, 1, count, 1)),
                   full_box(b"stsz", 0, 0, struct.pack(">II", 0, count),
                            b"".join(struct.pack(">I", len(s)) for s in samples)),
                   full_box(b"stco", 0, 0, struct.pack(">II", 1, chunk_offset)))
        minf = box(b"minf",
                   full_box(b"vmhd", 0, 1, b"\x00" * 8),
                   box(b"dinf", full_box(b"dref", 0, 0, struct.pack(">I", 1),
                                         full_box(b"url ", 0, 1))),
                   stbl)
        mdia = box(b"mdia",
                   full_box(b"mdhd", 0, 0, struct.pack(">IIIIHH", 0, 0, timescale, mduration,
                                                       0x55C4, 0)),
                   full_box(b"hdlr", 0, 0, struct.pack(">I4s", 0, b"vide"), b"\x00" * 12,
                            b"Bow32 H.264\x00"),
                   minf)
        tkhd = full_box(b"tkhd", 0, 3, struct.pack(">IIIII", 0, 0, 1, 0, duration),
                        b"\x00" * 8, struct.pack(">hhhH", 0, 0, 0, 0), UNITY,
                        struct.pack(">II", width << 16, height << 16))
        mvhd = full_box(b"mvhd", 0, 0, struct.pack(">IIII", 0, 0, movie_ts, duration),
                        struct.pack(">IH", 0x10000, 0x100), b"\x00" * 10, UNITY,
                        b"\x00" * 24, struct.pack(">I", 2))
        return box(b"moov", mvhd, box(b"trak", tkhd, mdia))

    ftyp = box(b"ftyp", b"isom", struct.pack(">I", 0x200), b"isomiso2avc1mp41")
    head = len(ftyp) + len(moov(0)) + 8
    data = b"".join(samples)
    return ftyp + moov(head) + struct.pack(">I4s", 8 + len(data), b"mdat") + data


def write_mp4(path, stream, fps_num=30, fps_den=1):
    blob = mp4_bytes(stream, fps_num, fps_den)
    with open(path, "wb") as f:
        f.write(blob)
    return len(blob)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("input", help="H.264 Annex B file")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--fps", default="30", help="frame rate, e.g. 30, 15 or 30000/1001")
    args = ap.parse_args()
    fps = Fraction(args.fps)
    with open(args.input, "rb") as f:
        stream = f.read()
    size = write_mp4(args.output, stream, fps.numerator, fps.denominator)
    print(f"{args.output}: {size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
