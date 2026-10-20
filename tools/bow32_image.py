#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bow32 firmware image utility (standard library only).

  bow32_image.py patch  app.bin               fill size + CRC in the image header
  bow32_image.py vmem   in.bin out.vmem [--size N]
                                              $readmemh file, one 32 bit LE word per line
  bow32_image.py info   app.bin               print and verify the image header

Image header layout: sw/common/include/bow32_image.h
"""

import argparse
import struct
import sys
import zlib
from pathlib import Path

MAGIC = 0x32334F42  # "BO32"
HDR_VERSION = 1
HDR_SIZE = 32
HDR_FMT = "<8I"  # magic, version, size, crc32, entry, reserved[3]


def parse_header(data):
    if len(data) < HDR_SIZE:
        raise ValueError("file too small for an image header")
    magic, ver, size, crc, entry, *_ = struct.unpack_from(HDR_FMT, data)
    return magic, ver, size, crc, entry


def cmd_patch(args):
    path = Path(args.bin)
    data = bytearray(path.read_bytes())
    magic, ver, _, _, entry = parse_header(data)
    if magic != MAGIC or ver != HDR_VERSION:
        sys.exit(f"{path}: no Bow32 image header at offset 0 (magic 0x{magic:08x})")
    # Pad the payload to a multiple of 4 bytes: the loader programs words.
    while len(data) % 4:
        data.append(0xFF)
    payload = bytes(data[HDR_SIZE:])
    struct.pack_into("<II", data, 8, len(payload), zlib.crc32(payload))
    path.write_bytes(data)
    print(f"{path}: {len(payload)} bytes payload, crc32 0x{zlib.crc32(payload):08x}, "
          f"entry 0x{entry:08x}")


def cmd_vmem(args):
    data = bytearray(Path(args.bin).read_bytes())
    if args.size is not None:
        if len(data) > args.size:
            sys.exit(f"{args.bin}: {len(data)} bytes do not fit into {args.size} bytes")
        data += bytes([args.fill]) * (args.size - len(data))
    while len(data) % 4:
        data.append(args.fill)
    words = struct.unpack(f"<{len(data) // 4}I", data)
    with open(args.vmem, "w") as f:
        for w in words:
            f.write(f"{w:08x}\n")


def cmd_info(args):
    data = Path(args.bin).read_bytes()
    magic, ver, size, crc, entry = parse_header(data)
    payload = data[HDR_SIZE:HDR_SIZE + size]
    ok = (magic == MAGIC and ver == HDR_VERSION and len(payload) == size
          and zlib.crc32(payload) == crc)
    print(f"magic   0x{magic:08x} ({'ok' if magic == MAGIC else 'BAD'})")
    print(f"version {ver}")
    print(f"size    {size} bytes")
    print(f"crc32   0x{crc:08x}")
    print(f"entry   0x{entry:08x}")
    print("image is", "VALID" if ok else "INVALID")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("patch", help="fill size and CRC of the image header in place")
    p.add_argument("bin")
    p = sub.add_parser("vmem", help="convert a binary into a $readmemh file")
    p.add_argument("bin")
    p.add_argument("vmem")
    p.add_argument("--size", type=lambda s: int(s, 0), help="pad to this many bytes")
    p.add_argument("--fill", type=lambda s: int(s, 0), default=0xFF, help="pad byte (default 0xff)")
    p = sub.add_parser("info", help="show and verify the image header")
    p.add_argument("bin")
    args = ap.parse_args()
    return {"patch": cmd_patch, "vmem": cmd_vmem, "info": cmd_info}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
