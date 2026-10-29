#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bit-exact reference model of the Bow32 ISP (hw/ip/isp).

Every stage uses exactly the integer arithmetic documented in docs/ip/isp.md
and implemented in the RTL, so RTL output can be compared word by word.
Pure Python (no numpy), meant for small test images.

Library use:
    cfg = IspConfig(width=64, height=48)
    raw = tpg(cfg)                         # or any list of rows of 10 bit values
    res = run(raw, cfg)                    # res.out, res.stats, res.rgb_linear
    words = capture(res.out, CaptureConfig(...))

Command line (used by hw/ip/isp/dv):
    isp_model.py gen DIR --seed N [--tpg] [--width W --height H]
    isp_model.py check DIR
"""

import argparse
import json
import random
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

# Register offsets (docs/ip/isp.md)
REG = {
    "CTRL": 0x004, "UPDATE": 0x008, "STATUS": 0x00C, "SIZE": 0x020, "MODULES": 0x024,
    "BAYER": 0x028, "BLC": 0x02C, "DPC_TH": 0x030, "WB_R": 0x034, "WB_GR": 0x038,
    "WB_GB": 0x03C, "WB_B": 0x040, "STAT_X": 0x044, "STAT_Y": 0x048, "STAT_SAT": 0x04C,
    "TPG_CTRL": 0x050, "TPG_BLANK": 0x054, "TPG_COLOR": 0x058, "CCM": 0x060,
    "CCM_OFF": 0x084, "CSC": 0x0A0, "CSC_OFF": 0x0C4, "GAMMA_ADDR": 0x0E0,
    "GAMMA_DATA": 0x0E4, "CAP_CTRL": 0x0F0, "CAP_ORIGIN": 0x0F4, "CAP_SIZE": 0x0F8,
    "CAP_SCALE": 0x0FC,
}

IDENTITY = [256, 0, 0, 0, 256, 0, 0, 0, 256]

# CFA colours
R, GR, GB, B = 0, 1, 2, 3


@dataclass
class IspConfig:
    width: int = 64
    height: int = 48
    bayer: int = 0          # 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR
    blc_en: bool = False
    dpc_en: bool = False
    wb_en: bool = False
    ccm_en: bool = False
    gamma_en: bool = False
    csc_en: bool = False
    blc: int = 64
    dpc_th: int = 64
    wb_gain: list = field(default_factory=lambda: [256, 256, 256, 256])  # R Gr Gb B
    st_x0: int = 0
    st_x1: int = 4095
    st_y0: int = 0
    st_y1: int = 4095
    st_sat: int = 1023
    tpg_pattern: int = 0
    tpg_motion: bool = False
    tpg_hblank: int = 256
    tpg_vblank: int = 32
    tpg_color: list = field(default_factory=lambda: [512, 512, 512])
    ccm: list = field(default_factory=lambda: list(IDENTITY))       # c_ij, s3.8
    ccm_off: list = field(default_factory=lambda: [0, 0, 0])
    csc: list = field(default_factory=lambda: list(IDENTITY))
    csc_off: list = field(default_factory=lambda: [0, 0, 0])
    gamma: list = None      # 3 lists of 1024 entries, None = identity (in >> 2)


@dataclass
class CaptureConfig:
    x0: int = 0
    y0: int = 0
    width: int = 8
    height: int = 6
    scale: int = 3


@dataclass
class Result:
    out: list            # rows of (c0, c1, c2) 8 bit
    stats: dict
    rgb_linear: list     # demosaic output, rows of (R, G, B) 10 bit


def cfa(pattern, x, y):
    return ((((y & 1) ^ (pattern >> 1)) & 1) << 1) | (((x & 1) ^ pattern) & 1)


def mirror(i, n):
    """Reflect-101 border: p[-1] = p[1], p[n] = p[n-2]."""
    if i < 0:
        return -i
    if i > n - 1:
        return 2 * (n - 1) - i
    return i


def clamp(v, hi):
    return 0 if v < 0 else hi if v > hi else v


# ----------------------------------------------------------------------- TPG
def tpg(cfg, frame=0):
    w, h = max(cfg.width, 16), max(cfg.height, 2)
    offset = (4 * frame) & 1023 if cfg.tpg_motion else 0
    bw = w >> 3
    on, low = 0x3C0, 0x040
    img = []
    for y in range(h):
        row = []
        for x in range(w):
            p = cfg.tpg_pattern
            if p == 0:
                bar = min(x // bw, 7)
                rgb = (0 if bar & 2 else on, 0 if bar & 4 else on, 0 if bar & 1 else on)
            elif p == 1:
                v = ((x & 1023) + offset + (y & 1023)) & 1023
                rgb = (v, v, v)
            elif p == 2:
                xs = ((x & 1023) + offset) & 1023
                v = on if ((xs >> 5) & 1) ^ ((y >> 5) & 1) else low
                rgb = (v, v, v)
            else:
                rgb = tuple(cfg.tpg_color)
            c = cfa(cfg.bayer, x, y)
            row.append(rgb[0] if c == R else rgb[2] if c == B else rgb[1])
        img.append(row)
    return img


# -------------------------------------------------------------------- stages
def stage_blc(img, cfg):
    if not cfg.blc_en:
        return [list(r) for r in img]
    return [[max(p - cfg.blc, 0) for p in row] for row in img]


DPC_NEIGHBOURS = [(-2, -2), (0, -2), (2, -2), (-2, 0), (2, 0), (-2, 2), (0, 2), (2, 2)]


def stage_dpc(img, cfg):
    h, w = len(img), len(img[0])
    out, hits = [], 0
    for y in range(h):
        row = []
        for x in range(w):
            c = img[y][x]
            n = [img[mirror(y + dy, h)][mirror(x + dx, w)] for dx, dy in DPC_NEIGHBOURS]
            mn, mx = min(n), max(n)
            if cfg.dpc_en and c > mx + cfg.dpc_th:
                c, hits = mx, hits + 1
            elif cfg.dpc_en and c + cfg.dpc_th < mn:
                c, hits = mn, hits + 1
            row.append(c)
        out.append(row)
    return out, hits


def stage_wb(img, cfg):
    out = []
    for y, row in enumerate(img):
        o = []
        for x, p in enumerate(row):
            g = cfg.wb_gain[cfa(cfg.bayer, x, y)] if cfg.wb_en else 256
            o.append(min((p * g + 128) >> 8, 1023))
        out.append(o)
    return out


def stage_demosaic(img, cfg):
    h, w = len(img), len(img[0])
    out = []
    for y in range(h):
        row = []
        for x in range(w):
            def p(dx, dy):
                return img[mirror(y + dy, h)][mirror(x + dx, w)]
            c = p(0, 0)
            cross = (p(0, -1) + p(0, 1) + p(-1, 0) + p(1, 0) + 2) >> 2
            diag = (p(-1, -1) + p(1, -1) + p(-1, 1) + p(1, 1) + 2) >> 2
            hor = (p(-1, 0) + p(1, 0) + 1) >> 1
            ver = (p(0, -1) + p(0, 1) + 1) >> 1
            col = cfa(cfg.bayer, x, y)
            if col == R:
                row.append((c, cross, diag))
            elif col == B:
                row.append((diag, cross, c))
            elif col == GR:
                row.append((hor, c, ver))
            else:
                row.append((ver, c, hor))
        out.append(row)
    return out


def signed(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def stage_matrix(img, coef, off, enable, bits):
    if not enable:
        return [list(r) for r in img]
    maxv = (1 << bits) - 1
    out = []
    for row in img:
        o = []
        for px in row:
            vals = []
            for i in range(3):
                acc = sum(signed(coef[3 * i + j], 12) * px[j] for j in range(3))
                acc += (off[i] << 8) + 128
                vals.append(clamp(acc >> 8, maxv))
            o.append(tuple(vals))
        out.append(o)
    return out


def stage_gamma(img, cfg):
    if not cfg.gamma_en:
        return [[tuple(c >> 2 for c in px) for px in row] for row in img]
    lut = cfg.gamma
    return [[tuple(lut[i][px[i]] for i in range(3)) for px in row] for row in img]


def statistics(rgb, cfg, dpc_hits):
    s = {"sum_r": 0, "sum_g": 0, "sum_b": 0, "cnt": 0, "sum_y": 0, "af": 0,
         "dpc": dpc_hits, "hist": [0] * 64}
    for y, row in enumerate(rgb):
        if not cfg.st_y0 <= y <= cfg.st_y1:
            continue
        for x, (r, g, b) in enumerate(row):
            if not cfg.st_x0 <= x <= cfg.st_x1:
                continue
            luma = (77 * r + 150 * g + 29 * b + 128) >> 8
            s["sum_y"] += luma
            s["hist"][luma >> 4] += 1
            if r < cfg.st_sat and g < cfg.st_sat and b < cfg.st_sat:
                s["sum_r"] += r
                s["sum_g"] += g
                s["sum_b"] += b
                s["cnt"] += 1
            if x > cfg.st_x0:
                s["af"] += abs(g - row[x - 1][1])
    for k in ("sum_r", "sum_g", "sum_b", "cnt", "sum_y", "af"):
        s[k] &= 0xFFFFFFFF
    return s


def run(raw, cfg):
    img = stage_blc(raw, cfg)
    img, hits = stage_dpc(img, cfg)
    img = stage_wb(img, cfg)
    rgb = stage_demosaic(img, cfg)
    stats = statistics(rgb, cfg, hits)
    ccm = stage_matrix(rgb, cfg.ccm, [signed(v, 11) for v in cfg.ccm_off], cfg.ccm_en, 10)
    gam = stage_gamma(ccm, cfg)
    out = stage_matrix(gam, cfg.csc, [signed(v, 9) for v in cfg.csc_off], cfg.csc_en, 8)
    return Result(out=out, stats=stats, rgb_linear=rgb)


def stream_word(px, cfg):
    """AXI4-Stream tdata of an output pixel (UG934 component order)."""
    c0, c1, c2 = px
    return (c2 << 16 | c1 << 8 | c0) if cfg.csc_en else (c0 << 16 | c2 << 8 | c1)


def capture(out, cap, buf_words=32768):
    """Capture buffer contents: {address: 24 bit word}."""
    h, w = len(out), len(out[0])
    d = 1 << cap.scale
    words = {}
    for by in range(cap.height):
        for bx in range(cap.width):
            y0, x0 = cap.y0 + by * d, cap.x0 + bx * d
            if y0 + d > h or x0 + d > w:
                continue          # block not complete inside the frame
            sums = [0, 0, 0]
            for dy in range(d):
                for dx in range(d):
                    for c in range(3):
                        sums[c] += out[y0 + dy][x0 + dx][c]
            rnd = (1 << (2 * cap.scale - 1)) if cap.scale else 0
            v = [(s + rnd) >> (2 * cap.scale) for s in sums]
            addr = by * cap.width + bx
            if addr < buf_words:
                words[addr] = v[0] << 16 | v[1] << 8 | v[2]
    return words


# ----------------------------------------------------------- register image
def register_writes(cfg, cap):
    """(address, data) writes that program cfg/cap (CTRL/UPDATE excluded)."""
    m = [cfg.blc_en, cfg.dpc_en, cfg.wb_en, cfg.ccm_en, cfg.gamma_en, cfg.csc_en]
    w = [
        (REG["SIZE"], cfg.height << 16 | cfg.width),
        (REG["MODULES"], sum(int(b) << i for i, b in enumerate(m))),
        (REG["BAYER"], cfg.bayer),
        (REG["BLC"], cfg.blc),
        (REG["DPC_TH"], cfg.dpc_th),
        (REG["WB_R"], cfg.wb_gain[0]), (REG["WB_GR"], cfg.wb_gain[1]),
        (REG["WB_GB"], cfg.wb_gain[2]), (REG["WB_B"], cfg.wb_gain[3]),
        (REG["STAT_X"], cfg.st_x1 << 16 | cfg.st_x0),
        (REG["STAT_Y"], cfg.st_y1 << 16 | cfg.st_y0),
        (REG["STAT_SAT"], cfg.st_sat),
        (REG["TPG_CTRL"], int(cfg.tpg_motion) << 4 | cfg.tpg_pattern),
        (REG["TPG_BLANK"], cfg.tpg_vblank << 16 | cfg.tpg_hblank),
        (REG["TPG_COLOR"], cfg.tpg_color[2] << 20 | cfg.tpg_color[1] << 10 | cfg.tpg_color[0]),
    ]
    w += [(REG["CCM"] + 4 * i, c & 0xFFF) for i, c in enumerate(cfg.ccm)]
    w += [(REG["CCM_OFF"] + 4 * i, o & 0x7FF) for i, o in enumerate(cfg.ccm_off)]
    w += [(REG["CSC"] + 4 * i, c & 0xFFF) for i, c in enumerate(cfg.csc)]
    w += [(REG["CSC_OFF"] + 4 * i, o & 0x1FF) for i, o in enumerate(cfg.csc_off)]
    if cfg.gamma is not None:
        for ch in range(3):
            w.append((REG["GAMMA_ADDR"], (1 << ch) << 16))
            w += [(REG["GAMMA_DATA"], v) for v in cfg.gamma[ch]]
    w += [
        (REG["CAP_ORIGIN"], cap.y0 << 16 | cap.x0),
        (REG["CAP_SIZE"], cap.height << 16 | cap.width),
        (REG["CAP_SCALE"], cap.scale),
    ]
    return w


# ------------------------------------------------------------ test vectors
def random_config(rnd, width, height, use_tpg):
    cfg = IspConfig(width=width, height=height)
    cfg.bayer = rnd.randrange(4)
    cfg.blc_en, cfg.dpc_en, cfg.wb_en = (rnd.random() < 0.8 for _ in range(3))
    cfg.ccm_en, cfg.gamma_en, cfg.csc_en = (rnd.random() < 0.7 for _ in range(3))
    cfg.blc = rnd.randrange(0, 128)
    cfg.dpc_th = rnd.randrange(0, 200)
    cfg.wb_gain = [rnd.randrange(128, 1024) for _ in range(4)]
    cfg.st_x0, cfg.st_y0 = rnd.randrange(width // 2), rnd.randrange(height // 2)
    cfg.st_x1 = rnd.randrange(cfg.st_x0, width + 8)
    cfg.st_y1 = rnd.randrange(cfg.st_y0, height + 8)
    cfg.st_sat = rnd.randrange(600, 1024)
    cfg.ccm = [rnd.randrange(-600, 900) & 0xFFF for _ in range(9)]
    cfg.ccm_off = [rnd.randrange(-100, 100) & 0x7FF for _ in range(3)]
    cfg.csc = [rnd.randrange(-300, 400) & 0xFFF for _ in range(9)]
    cfg.csc_off = [rnd.randrange(-64, 200) & 0x1FF for _ in range(3)]
    if cfg.gamma_en:
        cfg.gamma = [[rnd.randrange(256) for _ in range(1024)] for _ in range(3)]
    if use_tpg:
        cfg.tpg_pattern = rnd.randrange(4)
        cfg.tpg_color = [rnd.randrange(1024) for _ in range(3)]
        cfg.tpg_hblank = rnd.randrange(16, 64)
        cfg.tpg_vblank = rnd.randrange(1, 8)
    return cfg


def random_image(rnd, width, height):
    """Smooth gradients + noise + a few hot / dead pixels."""
    img = []
    for y in range(height):
        row = []
        for x in range(width):
            v = 64 + (x * 700) // width + (y * 200) // height + rnd.randrange(-20, 20)
            row.append(clamp(v, 1023))
        img.append(row)
    for _ in range(max(1, width * height // 200)):
        x, y = rnd.randrange(width), rnd.randrange(height)
        img[y][x] = rnd.choice([0, 1023])
    return img


def write_hex(path, values, digits):
    Path(path).write_text("".join(f"{v:0{digits}x}\n" for v in values))


def read_hex(path):
    return [int(l, 16) for l in Path(path).read_text().split() if l]


def cmd_gen(args):
    out = Path(args.dir)
    out.mkdir(parents=True, exist_ok=True)
    rnd = random.Random(args.seed)
    cfg = random_config(rnd, args.width, args.height, args.tpg)
    scale = rnd.randrange(4)
    d = 1 << scale
    cap = CaptureConfig(x0=rnd.randrange(8), y0=rnd.randrange(8), scale=scale,
                        width=max(1, (args.width - 8) // d - rnd.randrange(2)),
                        height=max(1, (args.height - 8) // d - rnd.randrange(2)))
    raw = tpg(cfg) if args.tpg else random_image(rnd, args.width, args.height)
    regs = register_writes(cfg, cap)
    (out / "regs.txt").write_text("".join(f"{a:03x} {d:08x}\n" for a, d in regs))
    (out / "meta.txt").write_text(f"{cfg.width} {cfg.height} {int(args.tpg)}\n")
    write_hex(out / "input.hex", [p for row in raw for p in row], 3)
    state = {"cfg": asdict(cfg), "cap": asdict(cap), "tpg": args.tpg}
    (out / "test.json").write_text(json.dumps(state))
    print(f"{out}: {cfg.width}x{cfg.height} seed {args.seed} "
          f"{'tpg' if args.tpg else 'sensor'} capture scale {scale}")


def cmd_check(args):
    d = Path(args.dir)
    state = json.loads((d / "test.json").read_text())
    cfg = IspConfig(**state["cfg"])
    cap = CaptureConfig(**state["cap"])
    raw = [read_hex(d / "input.hex")[y * cfg.width:(y + 1) * cfg.width] for y in range(cfg.height)]
    res = run(raw, cfg)
    errors = []

    # Output stream
    exp = [stream_word(px, cfg) for row in res.out for px in row]
    got = read_hex(d / "out.hex")
    if len(got) != len(exp):
        errors.append(f"output: {len(got)} pixels, expected {len(exp)}")
    for i, (g, e) in enumerate(zip(got, exp)):
        if g != e:
            errors.append(f"output pixel ({i % cfg.width},{i // cfg.width}): "
                          f"got {g:06x} expected {e:06x}")
            if len(errors) > 10:
                break

    # Statistics
    names = ["sum_r", "sum_g", "sum_b", "cnt", "sum_y", "af", "dpc"]
    got = read_hex(d / "stats.hex")
    exp = [res.stats[n] for n in names] + res.stats["hist"]
    labels = names + [f"hist[{i}]" for i in range(64)]
    for lbl, g, e in zip(labels, got, exp):
        if g != e:
            errors.append(f"stats {lbl}: got {g} expected {e}")

    # Capture
    words = capture(res.out, cap)
    got = read_hex(d / "cap.hex")
    for a, e in sorted(words.items()):
        if a >= len(got) or got[a] != e:
            errors.append(f"capture word {a}: got {got[a] if a < len(got) else None!s} "
                          f"expected {e:06x}")
            if len(errors) > 20:
                break

    if errors:
        print(f"{d}: FAIL")
        for e in errors[:25]:
            print("  " + e)
        return 1
    print(f"{d}: PASS ({cfg.width}x{cfg.height}, {len(words)} capture words, "
          f"dpc {res.stats['dpc']})")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("gen", help="generate a random test case")
    p.add_argument("dir")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--width", type=int, default=64)
    p.add_argument("--height", type=int, default=40)
    p.add_argument("--tpg", action="store_true", help="use the test pattern generator")
    p = sub.add_parser("check", help="compare RTL dumps in DIR with the model")
    p.add_argument("dir")
    args = ap.parse_args()
    return {"gen": cmd_gen, "check": cmd_check}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
