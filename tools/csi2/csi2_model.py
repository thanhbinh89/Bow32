#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Reference model of the Bow32 MIPI CSI-2 receiver (hw/ip/csi2rx).

Written from the receiver spec and the MIPI CSI-2 v1.x / D-PHY rules, NOT
from the RTL, so that the two check each other. Pure Python (stdlib only).

Library use:
    pkt  = long_packet(0, 0x2B, raw10_pack(pixels))    # header + ECC + payload + CRC
    st, di, wc = ecc_decode(pkt[:4])                    # ECC_OK / ECC_CORR / ECC_ERR
    lanes = lane_split(pkt, 2)                          # byte i -> lane i % 2
    pos = align_search(to_bits([0] * 2 + [SYNC] + pkt)) # aligner of the D-PHY layer
    rx, expect = run_stim(cfg, lines)                   # receiver model over stim.txt

Command line (used by hw/ip/csi2rx/dv):
    csi2_model.py gen DIR --seed N [--lanes 1|2] [--dut-lanes 1|2] [--errors]
                          [--raw8] [--contclk] [--test NAME]
        -> DIR/cfg.txt (testbench and TX model settings), DIR/stim.txt (commands,
           see tb_bow_csi2rx.sv). NAME: random (default), lp, watchdog, clk, cmd,
           ovf, stop, byteclk, eye (directed tests, see gen_<name>).
    csi2_model.py check DIR
        compares DIR/out.txt (m_axis transfers) and DIR/regs.txt (register reads,
        frame end records, invariants, burst end times) with the prediction.

Determinism (the generator only creates what the checker can predict):
  * lane skew (extra HS-zero bytes) <= 4 bytes, or >= 12 bytes (burst dropped);
  * a corrupted sync byte is scanned like the RTL aligner, including a false
    lock later in the burst; the case is re-rolled when its outcome depends on
    the unknown number of trail bytes the receiver sees after the data;
  * a packet still open at the end of the data (truncation) must need more
    bytes than any trail can provide (garbage_max), and only its pixels formed
    from bytes actually sent are compared (then any number of extra pixels,
    then eol); truncated packets are accepted lines without format error;
  * register accesses follow a clock-only burst + wait, so that work the
    stopped byte clock deferred is done; FRAME_TIME/LINE_TIME are only exact
    when CLK-POST meets the D-PHY minimum (60 ns + 52 UI);
  * no FIFO overflow except in the 'ovf' test (tready duty >= 1.2 x the input
    pixel rate averaged over a line period).
"""

import argparse
import random
import sys
from dataclasses import dataclass, replace
from pathlib import Path

# --------------------------------------------------------------- registers
REG = {
    "ID": 0x000, "INFO": 0x004, "CTRL": 0x008, "PHY_CFG": 0x00C, "STATUS": 0x010,
    "IRQ_STATUS": 0x014, "IRQ_EN": 0x018, "ERR_STATUS": 0x01C, "CNT_CLR": 0x020,
    "CNT_FRAME": 0x024, "CNT_PKT": 0x028, "CNT_LINE": 0x02C, "CNT_ECC": 0x030,
    "CNT_CRC": 0x034, "CNT_SOT": 0x038, "CNT_DROP": 0x03C, "CNT_BURST": 0x040,
    "CNT_MISC": 0x044, "FRAME_INFO": 0x050, "LINE_INFO": 0x054, "FRAME_SUM": 0x058,
    "FRAME_TIME": 0x05C, "LINE_TIME": 0x060, "BYTECLK": 0x064, "DLY0": 0x070,
    "DLY1": 0x074, "LOG_CTRL": 0x080, "RAW_CTRL": 0x084, "LOG": 0x400, "RAW": 0x800,
}
REG_NAME = {v: k for k, v in REG.items()}
ID_VALUE = 0x43533201

CTRL_PHY_EN, CTRL_RX_EN, CTRL_LANES, CTRL_CLK_FORCE, CTRL_VC_ANY = 1, 2, 4, 8, 16
PHY_CFG_RESET = 14 | 2 << 8 | 30 << 16 | 8 << 24

# ERR_STATUS bits
ERR = {"sot": 0, "ecc_corr": 1, "ecc_err": 2, "crc": 3, "trunc": 4, "ovf": 5,
       "skew": 6, "format": 7, "frame": 8, "lp": 9}
IRQ_FS, IRQ_FE, IRQ_ERR, IRQ_LOG, IRQ_RAW = 1, 2, 4, 8, 16

# Data types
DT_FS, DT_FE, DT_LS, DT_LE = 0x00, 0x01, 0x02, 0x03
DT_NULL, DT_BLANK, DT_EMB = 0x10, 0x11, 0x12
DT_RAW8, DT_RAW10 = 0x2A, 0x2B

# ------------------------------------------------------------ CSI-2 header ECC
# Column of every header bit D0..D23 (DI[0..7], WC[0..15]): bit i = parity P_i.
ECC_COLUMNS = [0x07, 0x0B, 0x0D, 0x0E, 0x13, 0x15, 0x16, 0x19, 0x1A, 0x1C, 0x23, 0x25,
               0x26, 0x29, 0x2A, 0x2C, 0x31, 0x32, 0x34, 0x38, 0x1F, 0x2F, 0x37, 0x3B]
ECC_OK, ECC_CORR, ECC_ERR = 0, 1, 2


def ecc6(d24):
    """6 bit ECC of a 24 bit packet header (bit 0 = DI bit 0)."""
    p = 0
    for i, col in enumerate(ECC_COLUMNS):
        if (d24 >> i) & 1:
            p ^= col
    return p


def ecc_decode(hdr):
    """4 header bytes -> (status, di, wc); corrected fields when status is ECC_CORR.

    ECC[7:6] are ignored (CSI-2 v1.x). A syndrome equal to a column flips that
    data bit, a single bit syndrome is a parity bit error (data ok); anything
    else is uncorrectable and the raw fields are returned.
    """
    d = hdr[0] | hdr[1] << 8 | hdr[2] << 16
    syn = ecc6(d) ^ (hdr[3] & 0x3F)
    st = ECC_OK
    if syn in ECC_COLUMNS:
        d ^= 1 << ECC_COLUMNS.index(syn)
        st = ECC_CORR
    elif syn and syn & (syn - 1) == 0:
        st = ECC_CORR
    elif syn:
        st = ECC_ERR
    return st, d & 0xFF, d >> 8


# ------------------------------------------------------------------ CRC-16
def crc16(data, crc=0xFFFF):
    """CSI-2 payload CRC: x^16+x^12+x^5+1, reflected (0x8408), init 0xFFFF."""
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc


# ------------------------------------------------------------------ packets
def header(vc, dt, wc):
    di = (vc & 3) << 6 | (dt & 0x3F)
    return [di, wc & 0xFF, (wc >> 8) & 0xFF, ecc6(di | (wc & 0xFFFF) << 8)]


def short_packet(vc, dt, data):
    return header(vc, dt, data)


def long_packet(vc, dt, payload):
    c = crc16(payload)
    return header(vc, dt, len(payload)) + list(payload) + [c & 0xFF, c >> 8]


def raw10_pack(px):
    """4 pixels (10 bit) -> 5 bytes: P0..P3 [9:2], then {P3, P2, P1, P0}[1:0]."""
    out = []
    for i in range(0, len(px) - len(px) % 4, 4):
        g = px[i:i + 4]
        out += [p >> 2 for p in g] + [sum((p & 3) << (2 * k) for k, p in enumerate(g))]
    return out


def raw10_unpack(data):
    """5 bytes -> 4 pixels; leftover bytes (len % 5) are dropped like the RTL."""
    px = []
    for i in range(0, len(data) - len(data) % 5, 5):
        px += [data[i + k] << 2 | (data[i + 4] >> (2 * k)) & 3 for k in range(4)]
    return px


def raw8_unpack(data):
    return [b << 2 for b in data]


def unpack(dt, data):
    return raw10_unpack(data) if dt == DT_RAW10 else raw8_unpack(data)


# -------------------------------------------------------- D-PHY lane level
SYNC = 0xB8


def lane_split(data, lanes):
    """Byte i of a burst goes to lane i % lanes."""
    return [list(data[l::lanes]) for l in range(lanes)]


def lane_merge(per_lane):
    """Inverse of lane_split (lockstep: stops at the shortest lane + 1 round)."""
    out = []
    for k in range(max(len(x) for x in per_lane)):
        for x in per_lane:
            if k < len(x):
                out.append(x[k])
    return out


def to_bits(data):
    """Bytes -> bits in transmission order (LSB first)."""
    return [(b >> i) & 1 for b in data for i in range(8)]


def from_bits(bits):
    return [sum(bits[i + k] << k for k in range(8)) for i in range(0, len(bits) - 7, 8)]


SYNC_PATTERN = [0] * 8 + to_bits([SYNC])


def align_search(bits, start=0):
    """Aligner sync search (spec 5.2): first window start B >= start with 8 zero
    bits followed by the sync byte 0xB8. The bytes then start at B + 16."""
    for b in range(start, len(bits) - 15):
        if bits[b:b + 16] == SYNC_PATTERN:
            return b
    return None


def words_to_bits(words):
    return [(w >> i) & 1 for w in words for i in range(8)]


def find_lane_bytes(words, expect):
    """Raw capture check: some sync position in the raw words is followed by
    the expected lane bytes (as many as the window holds). Returns the number
    of bytes compared, or -1."""
    bits = words_to_bits(words)
    pos = 0
    while True:
        b = align_search(bits, pos)
        if b is None:
            return -1
        got = from_bits(bits[b + 16:])
        n = min(len(got), len(expect))
        if n > 0 and got[:n] == expect[:n]:
            return n
        pos = b + 1


# ------------------------------------------------------------------ bursts
TRAIL_SCAN = 32          # trail bits scanned after the data (a false lock can end 1 bit in)


@dataclass
class Burst:
    """One HS burst = one packet, as written to stim.txt ('pkt' line).

    hflip: header bits to flip (bit 8 * i + j = bit j of header byte i);
    pflip: payload/CRC bit to flip; trunc: packet bytes sent (-1 = all);
    sync, zeros, phase: per lane sync byte, extra HS-zero bytes, bit phase;
    zero_ns: extra HS-zero time of the TX (no effect on the result).
    """
    vc: int
    dt: int
    wc: int
    payload: list = None
    hflip: tuple = (-1, -1)
    pflip: int = -1
    trunc: int = -1
    sync: tuple = (SYNC, SYNC)
    zeros: tuple = (0, 0)
    phase: tuple = (0, 0)
    zero_ns: int = 0

    @property
    def is_long(self):
        return self.dt >= 0x10

    def packet(self):
        if self.is_long:
            return long_packet(self.vc, self.dt, self.payload)
        return short_packet(self.vc, self.dt, self.wc)

    def sent(self):
        """Bytes the TX sends after the error knobs (bit flips, truncation)."""
        b = self.packet()
        for f in self.hflip:
            if f >= 0:
                b[f >> 3] ^= 1 << (f & 7)
        if self.pflip >= 0:
            b[4 + (self.pflip >> 3)] ^= 1 << (self.pflip & 7)
        return b if self.trunc < 0 else b[:self.trunc]

    def stim(self):
        pay = "".join(f"{x:02x}" for x in self.payload) if self.is_long and self.payload else "-"
        return (f"pkt {self.vc} {self.dt:02x} {self.wc:04x} {self.hflip[0]} {self.hflip[1]} "
                f"{self.pflip} {self.trunc} {self.sync[0]:02x} {self.sync[1]:02x} "
                f"{self.zeros[0]} {self.zeros[1]} {self.phase[0]} {self.phase[1]} "
                f"{self.zero_ns} {pay}")

    @classmethod
    def parse(cls, f):
        dt = int(f[1], 16)
        pay = None if dt < 0x10 else [] if f[14] == "-" else \
            [int(f[14][i:i + 2], 16) for i in range(0, len(f[14]), 2)]
        return cls(vc=int(f[0]), dt=dt, wc=int(f[2], 16), payload=pay,
                   hflip=(int(f[3]), int(f[4])), pflip=int(f[5]), trunc=int(f[6]),
                   sync=(int(f[7], 16), int(f[8], 16)), zeros=(int(f[9]), int(f[10])),
                   phase=(int(f[11]), int(f[12])), zero_ns=int(f[13]))


@dataclass
class LaneRx:
    """What the aligner of one lane does with a burst."""
    locked: bool
    sot: int = 0          # relative cycle of the first byte (common offset removed)
    data: list = None     # bytes from the lock on (incl. trail bytes, long enough)
    real: int = 0         # leading bytes made of transmitted bits only


def lane_receive(lane_bytes, sync, zeros, phase):
    """Aligner (spec 5.2) on one lane: [HS-zero] sync, data, then the trail
    (inverted last bit, constant until the receiver drops hs_en)."""
    data_bits = to_bits([sync] + list(lane_bytes))
    trail = 1 - data_bits[-1]
    bits = [0] * 16 + data_bits + [trail] * TRAIL_SCAN
    b = align_search(bits)
    if b is None:
        return LaneRx(False)
    tail = bits[b + 16:] + [trail] * 64 * 8
    real = max(0, (16 + len(data_bits) - (b + 16)) // 8)
    return LaneRx(True, sot=zeros + (phase + b - 16) // 8, data=from_bits(tail), real=real)


@dataclass
class BurstRx:
    """Lane level result of a burst: sync errors, skew, merged byte stream."""
    sot_err: list         # active lanes without lock
    skew: bool = False    # ev_skew (burst dropped)
    merged: list = None   # merged bytes (None: no sop)
    real: int = 0         # merged bytes that are certainly received and transmitted
    note: str = ""        # why the case is not deterministic ('' = ok)


def burst_receive(burst, lanes):
    """Lane level model of one burst on `lanes` active lanes."""
    sent = burst.sent()
    per = lane_split(sent, lanes)
    rx = [lane_receive(per[l], burst.sync[l], burst.zeros[l], burst.phase[l]) for l in range(lanes)]
    res = BurstRx(sot_err=[l for l in range(lanes) if not rx[l].locked])
    locked = [r for r in rx if r.locked]
    if not locked:
        return res
    if len(locked) != lanes:
        res.skew = True
        return res
    skew = max(r.sot for r in rx) - min(r.sot for r in rx)
    if skew >= 12:
        res.skew = True
        return res
    if skew > 4:
        res.note = f"lane skew {skew} bytes (not 0..4 or >= 12)"
        return res
    n = min(len(r.data) for r in rx)
    res.merged = [rx[l].data[k] for k in range(n) for l in range(lanes)]
    res.real = min(r.real * lanes + l for l, r in enumerate(rx))
    return res


def burst_problem(rx, b, res=None):
    """Why the outcome of burst b is not predictable in the state of receiver
    rx (VC/DT filter, lanes), or '' when it is."""
    res = res or burst_receive(b, rx.lanes)
    if res.note:
        return res.note
    if res.skew or res.merged is None:
        return ""
    m, real = res.merged, res.real
    if real < 4:
        return "packet header not complete in the transmitted bytes"
    st, di, wc = ecc_decode(m[:4])
    vc, dt = di >> 6, di & 0x3F
    if st == ECC_ERR or dt < 0x10:
        return ""
    acc = rx.vc_match(vc) and dt == (rx.ctrl >> 8) & 0x3F and dt in (DT_RAW8, DT_RAW10)
    fmt = acc and ((dt == DT_RAW10 and wc % 5 != 0) or (dt == DT_RAW8 and wc == 0))
    need = 4 + wc + 2
    if real >= need:
        return ""
    if need - real <= rx.garbage_max:
        return f"open packet needs {need - real} bytes, the trail may provide {rx.garbage_max}"
    if not acc or fmt:
        return "truncated packet that is dropped or has a format error"
    if not unpack(dt, m[4:real]):
        return "truncated line without a complete pixel group"
    return ""


# ----------------------------------------------------------------- receiver
class NotDeterministic(Exception):
    """The outcome of a stimulus depends on timing the model does not know."""


@dataclass
class LineOut:
    """Predicted m_axis pixels of one accepted packet. fuzzy: '' exact line
    (tlast on the last pixel); 'trunc' prefix, then any number of extra
    pixels, the last one with tlast; 'stop' any prefix, no tlast."""
    px: list
    sof: bool
    fuzzy: str = ""
    frame: int = -1


@dataclass
class Mark:
    n: int


@dataclass
class Unchecked:
    """The output until the next Mark is not predicted (ovf, eye tests)."""
    reason: str


@dataclass
class Expect:
    """Predicted register read: kind 'exact' (value & mask), 'time' (CPU
    cycles between the end of bursts a and b, 0 if a is None), 'range'
    [lo, hi], 'any', 'nonzero' (value & mask != 0), 'raw' (RAW word)."""
    kind: str
    value: int = 0
    mask: int = 0xFFFFFFFF
    a: int = None
    b: int = None
    hi: int = 0

    def describe(self):
        if self.kind == "exact":
            return f"{self.value:08x}" + (f" (mask {self.mask:08x})" if self.mask != 0xFFFFFFFF else "")
        if self.kind == "range":
            return f"{self.value}..{self.hi}"
        return self.kind


@dataclass
class Capture:
    """LOG or RAW capture state (spec 6, LOG_CTRL / RAW_CTRL)."""
    armed: bool = False
    done: bool = False
    mode: int = 0          # LOG: [1] TRIG_FS [2] STOP_FE; RAW: [1] NOW
    started: bool = False
    count: int = 0
    wptr: int = 0
    burst: object = None   # RAW: burst captured
    pending: bool = False  # ARM written, byte clock not yet seen


ST = {"11": 3, "10": 2, "01": 1, "00": 0}

# event -> (counter, ERR_STATUS bit)
EVENTS = {
    "fs": ("frame", None), "fe": (None, None), "pkt": ("pkt", None), "line": ("line", None),
    "ecc_corr": ("ecc_corr", "ecc_corr"), "ecc_err": ("ecc_err", "ecc_err"), "crc": ("crc", "crc"),
    "trunc": ("trunc", "trunc"), "sot0": ("sot0", "sot"), "sot1": ("sot1", "sot"),
    "drop": ("drop", None), "ovf": ("ovf", "ovf"), "hs0": ("hs0", None), "hs1": ("hs1", None),
    "hsclk": ("hsclk", None), "lp": ("lp", "lp"), "skew": ("misc", "skew"),
    "format": ("misc", "format"), "frame_err": ("misc", "frame"),
}
CNT_MAX = {"frame": 0xFFFFFFFF, "pkt": 0xFFFFFFFF, "line": 0xFFFFFFFF, "lp": 255, "misc": 255}


class Receiver:
    """Behaviour of bow_csi2rx as seen from its ports, step by step over the
    commands of stim.txt (the testbench executes the same commands)."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.dut_lanes = cfg["dut_lanes"]
        self.ctrl = 0x2B00 | (CTRL_LANES if self.dut_lanes == 2 else 0)
        self.phy_cfg = PHY_CFG_RESET
        self.irq_en = self.irq = self.err = 0
        self.cnt = dict.fromkeys(["frame", "pkt", "line", "ecc_corr", "ecc_err", "crc", "trunc",
                                  "sot0", "sot1", "drop", "ovf", "hs0", "hs1", "hsclk", "lp",
                                  "misc"], 0)
        self.frame_info = self.line_info = self.frame_sum = 0
        self.fs_prev = None            # burst index of the previous FS (reference)
        self.frame_time = (None, None)  # bursts of the interval latched in FRAME_TIME
        self.lt_ref = None
        self.line_time = (None, None)
        self.items = []
        self.frames = []               # complete frames: dict(info, sum, id, seg)
        self.log_ram = [0] * 64
        self.log = Capture()
        self.raw = Capture()
        self.dly = [0, 0]
        self.dly_out = [0, 0]
        self.fsm = ["off"] * 3         # data lane 0, data lane 1, clock lane
        self.pin = ["00" if cfg["lp00"] else "11"] * 3
        self.contclk = cfg["contclk"]
        self.clk_running = False
        self.lp00_hold = bool(cfg["lp00"])     # lanes at LP-00 until the first TX item
        self.t_clk_post = cfg["t_clk_post"]
        self.fs_prev_exact = self.lt_ref_exact = True
        self.burst_idx = 0
        self.seg = 0
        self.frame_id = -1
        self.fuzzy_frames = set()
        self.blind = False             # 'nocheck all': bursts are not modelled
        self.out_blocked = False       # 'nocheck ovf': m_axis tready held low
        self.fifo_used = 0
        self.blind_segs = set()
        self.seg_expect = {0: {}}      # invariant expectations per segment
        self.seg_filter = {0: 2}       # largest LP_FILTER per segment
        self.unknown = set()           # registers not predictable since a blind segment
        tr_bytes = -(-(cfg["t_hs_trail"] + 100) * 1000 // cfg["byte_ps"]) + 6
        self.garbage_max = tr_bytes * cfg["lanes"]
        self.reset_datapath()

    # ------------------------------------------------------------ helpers
    @property
    def phy_en(self):
        return bool(self.ctrl & CTRL_PHY_EN)

    @property
    def rx_on(self):
        return self.ctrl & (CTRL_PHY_EN | CTRL_RX_EN) == CTRL_PHY_EN | CTRL_RX_EN

    @property
    def lanes(self):
        return 2 if self.ctrl & CTRL_LANES else 1

    @property
    def force(self):
        return self.phy_en and bool(self.ctrl & CTRL_CLK_FORCE)

    def vc_match(self, vc):
        return bool(self.ctrl & CTRL_VC_ANY) or vc == (self.ctrl >> 5) & 3

    def reset_datapath(self):
        self.in_frame = self.frame_synced = False
        self.lines = self.fsum = self.fnum = 0
        self.sof_pending = False

    def ev(self, name):
        """Receiver event: counter, ERR_STATUS bit, IRQ_STATUS bit."""
        ctr, err = EVENTS[name]
        if ctr:
            self.cnt[ctr] = min(self.cnt[ctr] + 1, CNT_MAX.get(ctr, 0xFFFF))
        if err:
            self.err |= 1 << ERR[err]
            self.irq |= IRQ_ERR
        if name == "fs":
            self.irq |= IRQ_FS

    # ---------------------------------------------------------------- PHY
    def lane_en(self, i):
        return self.phy_en and (i != 1 or (self.dut_lanes == 2 and self.lanes == 2))

    def update_en(self):
        for i in range(3):
            if i == 1 and self.dut_lanes == 1:
                continue
            if not self.lane_en(i):
                self.fsm[i] = "off"
            elif self.fsm[i] == "off":
                self.fsm[i] = "waitstop"
                self.see(i, self.pin[i])

    def see(self, i, st):
        """The (filtered) LP state of lane i becomes st (spec 5.1)."""
        self.pin[i] = st
        f = self.fsm[i]
        if f == "waitstop" and st == "11":
            self.fsm[i] = "stop"
        elif f == "stop" and st == "01":
            self.fsm[i] = "hsrqst"
        elif f == "stop" and st in ("10", "00"):
            self.ev("lp")
            self.fsm[i] = "waitstop"
        elif f == "hsrqst" and st == "00":
            self.fsm[i] = "hs"
            self.ev("hsclk" if i == 2 else f"hs{i}")
        elif f == "hsrqst" and st == "11":
            self.fsm[i] = "stop"
        elif f == "hsrqst" and st == "10":
            self.ev("lp")
            self.fsm[i] = "waitstop"
        elif f == "hs" and st == "11":
            self.fsm[i] = "stop"

    def clock_on(self):
        """The TX starts its continuous clock (LP-11, LP-01, LP-00, HS)."""
        self.lp00_hold = False
        if not self.clk_running:
            for st in ("11", "01", "00"):
                self.see(2, st)
            self.clk_running = True

    def clock_off(self):
        if self.clk_running:
            self.clk_running = False
            self.see(2, "11")

    def byte_clock(self):
        """The byte clock runs: IDELAY loads, pending capture requests."""
        if self.phy_en:
            for l in range(self.dut_lanes):
                self.dly_out[l] = self.dly[l]
            for cap in (self.log, self.raw):
                if cap.pending:
                    cap.pending = False
                    cap.started = not (cap is self.log and cap.mode & 2)

    def timing_exact(self):
        """Event times are known (end of the packet) unless CLK-POST is below
        the D-PHY minimum (60 ns + 52 UI): the byte clock may then stop before
        the receiver has finished a packet, which completes at the next burst."""
        return bool(self.contclk) or self.t_clk_post * 8000 >= 480_000 + 52 * self.cfg["byte_ps"]

    def clk_burst(self):
        """'clkburst': the clock lane alone runs for a while (no data lane)."""
        self.lp00_hold = False
        if self.contclk:
            self.idle()
            return
        for i in range(2):
            self.see(i, "11")
        for st in ("11", "01", "00"):
            self.see(2, st)
        if self.byte_clock_ok():
            self.byte_clock()
            raw = self.raw
            if raw.armed and not raw.pending and raw.mode & 2:
                raw.burst = None
                self.cap_done(raw, IRQ_RAW)
        self.see(2, "11")

    def byte_clock_ok(self):
        if self.force:
            return True
        return self.fsm[2] == "hs"

    def lp_item(self, mask, st, ns):
        self.lp00_hold = False
        steps = max(1, (ns * 1000 + self.cfg["byte_ps"] // 2) // self.cfg["byte_ps"])
        filt = max(1, (self.phy_cfg >> 8) & 0xF)
        if steps * self.cfg["byte_ps"] < (filt - 1) * self.cfg["vid_ps"]:
            return                             # shorter than the LP filter: not seen
        for i in range(3):
            if mask >> i & 1:
                self.see(i, st)
            elif i < 2 or not self.clk_running:
                self.see(i, "11")
        if st == "00" and ns * 1000 > (1 << 20) * self.cfg["vid_ps"] + 400_000:
            for i in range(2):
                if mask >> i & 1 and self.fsm[i] == "hs":
                    self.ev("lp")              # HS watchdog
                    self.fsm[i] = "waitstop"

    def idle(self):
        """TX idle: data lanes LP-11 (and the clock lane unless it runs);
        LP-00 everywhere while the sensor has not streamed yet."""
        if self.lp00_hold:
            return
        for i in range(2):
            self.see(i, "11")
        if not self.clk_running:
            self.see(2, "11")
        if self.clk_running and self.byte_clock_ok():
            self.byte_clock()

    # -------------------------------------------------------------- bursts
    def burst(self, b, stop=False):
        """'pkt': one HS burst on the TX lanes (clock lane entry first unless
        the continuous clock runs). stop: RX_EN/PHY_EN is cleared during it."""
        self.lp00_hold = False
        idx = self.burst_idx
        self.burst_idx += 1
        tx = self.cfg["lanes"]
        if self.contclk:
            self.clock_on()
        else:
            for st in ("11", "01", "00"):
                self.see(2, st)
        clk_ok = self.byte_clock_ok()
        for l in range(tx):
            for st in ("11", "01", "00"):
                self.see(l, st)
        armed = [self.fsm[l] == "hs" for l in range(self.lanes)]
        if clk_ok:
            self.byte_clock()
            raw = self.raw
            if raw.armed and not raw.pending and (raw.mode & 2 or armed[0]):
                raw.burst = None if raw.mode & 2 else b
                self.cap_done(raw, IRQ_RAW)
            if self.rx_on and not self.blind:
                if stop:
                    self.stop_line(b)
                else:
                    self.receive(b, idx, armed)
        for l in range(tx):
            self.see(l, "11")
        if not self.contclk:
            self.see(2, "11")

    def receive(self, b, idx, armed):
        if not any(armed):
            return
        res = burst_receive(b, self.lanes)
        if not all(armed):
            for l in res.sot_err:
                if armed[l]:
                    self.ev(f"sot{l}")
            if any(armed[l] and l not in res.sot_err for l in range(self.lanes)):
                self.ev("skew")
            return
        problem = burst_problem(self, b, res)
        if problem:
            raise NotDeterministic(problem)
        for l in res.sot_err:
            self.ev(f"sot{l}")
        if res.skew:
            self.ev("skew")
        elif res.merged is not None:
            self.packet(res.merged, res.real, idx)

    def packet(self, m, real, idx):
        """Packet layer (spec 5.4) on the merged bytes of one burst; `real`
        leading bytes are certain, the receiver may see up to garbage_max more."""
        st, di, wc = ecc_decode(m[:4])
        vc, dt = di >> 6, di & 0x3F
        entry = dt | vc << 6 | wc << 8 | st << 24
        if st == ECC_ERR:
            self.ev("ecc_err")
            self.log_push(entry, False, False)
            return
        self.ev("pkt")
        if st == ECC_CORR:
            self.ev("ecc_corr")
        sel = self.vc_match(vc)
        if dt < 0x10:
            self.log_push(entry, sel and dt == DT_FS, sel and dt == DT_FE)
            if sel and dt == DT_FS:
                self.frame_start(wc, idx)
            elif sel and dt == DT_FE:
                self.frame_end()
            return
        acc = sel and dt == (self.ctrl >> 8) & 0x3F and dt in (DT_RAW8, DT_RAW10)
        fmt = acc and ((dt == DT_RAW10 and wc % 5 != 0) or (dt == DT_RAW8 and wc == 0))
        need = 4 + wc + 2
        if fmt:
            self.ev("format")
        elif not acc:
            self.ev("drop")
        entry |= int(acc) << 28
        if real >= need:
            pay = m[4:4 + wc]
            crc_err = crc16(pay) != (m[4 + wc] | m[5 + wc] << 8)
            if crc_err:
                self.ev("crc")
            ovf = acc and self.fifo_push(unpack(dt, pay))
            if ovf:
                self.ev("ovf")
            self.log_push(entry | int(crc_err) << 26 | int(ovf) << 29, False, False)
            if acc:
                self.ev("line")
                self.line_info = wc | dt << 16 | vc << 22
                self.lines += 1
                self.unknown.discard("line")
                exact = self.timing_exact()
                if self.lt_ref is not None:
                    self.line_time = (self.lt_ref, idx)
                    if exact and self.lt_ref_exact:
                        self.unknown.discard("line_time")
                    else:
                        self.unknown.add("line_time")
                self.lt_ref, self.lt_ref_exact = idx, exact
                self.pixels(dt, pay, "")
        else:
            self.ev("trunc")
            self.log_push(entry | 1 << 27, False, False)
            self.pixels(dt, m[4:real], "trunc")

    def fifo_push(self, px):
        """'nocheck ovf' segment (tready held low): groups beyond the FIFO
        depth + the two output registers are dropped -> True (ev_ovf)."""
        if not self.out_blocked:
            return False
        groups = -(-len(px) // 4)
        cap = self.cfg["fifo_depth"] + 2
        if self.fifo_used + groups > cap:
            self.fifo_used = cap
            return True
        self.fifo_used += groups
        return False

    def pixels(self, dt, data, fuzzy):
        px = unpack(dt, data)
        if not px:
            return
        frame = self.frame_id if self.in_frame else -1
        self.items.append(LineOut(px, self.sof_pending, fuzzy, frame))
        self.sof_pending = False
        self.fsum = (self.fsum + sum(px)) & 0xFFFFFFFF
        if fuzzy and frame >= 0:
            self.fuzzy_frames.add(frame)

    def frame_start(self, wc, idx):
        if self.in_frame:
            self.ev("frame_err")
        self.in_frame = self.frame_synced = True
        self.lines = self.fsum = 0
        self.sof_pending = True
        self.fnum = wc
        self.frame_id += 1
        self.ev("fs")
        exact = self.timing_exact()
        if self.fs_prev is not None:
            self.frame_time = (self.fs_prev, idx)
            if exact and self.fs_prev_exact:
                self.unknown.discard("frame_time")
            else:
                self.unknown.add("frame_time")
        self.fs_prev, self.fs_prev_exact = idx, exact
        self.lt_ref = None

    def frame_end(self):
        if self.in_frame:
            self.frame_info = self.lines | self.fnum << 16
            self.frame_sum = self.fsum
            self.unknown.discard("frame")
            self.frames.append({"info": self.frame_info, "id": self.frame_id, "seg": self.seg,
                                "sum": None if self.out_blocked else self.frame_sum})
            self.ev("fe")              # IRQ_STATUS.FE is cleared by the testbench poller
        elif self.frame_synced:
            self.ev("frame_err")
        self.in_frame = False

    # ------------------------------------------------------------ captures
    def log_push(self, entry, is_fs, is_fe):
        cap = self.log
        if not cap.armed or cap.pending:
            return
        if not cap.started:
            if not is_fs:
                return
            cap.started = True
        self.log_ram[cap.wptr] = entry
        cap.wptr = (cap.wptr + 1) % 64
        cap.count += 1
        trig, stop = cap.mode & 2, cap.mode & 4
        if (stop and is_fe) or (cap.count == 64 and not (stop and not trig)):
            self.cap_done(cap, IRQ_LOG)

    def cap_done(self, cap, irq):
        cap.armed = False
        cap.done = True
        self.irq |= irq

    def arm(self, cap, mode):
        cap.armed, cap.done, cap.pending = True, False, True
        cap.mode, cap.started, cap.count, cap.wptr, cap.burst = mode, False, 0, 0, None
        if self.clk_running and self.byte_clock_ok():
            self.byte_clock()

    def stop_line(self, b):
        """Line burst during which RX_EN/PHY_EN is cleared ('waitbyte'): any
        prefix of its pixels may be output, without tlast."""
        res = burst_receive(b, self.lanes)
        if res.merged is None or not b.is_long or ecc_decode(res.merged[:4])[0] == ECC_ERR:
            raise NotDeterministic("stop test needs an accepted line")
        frame = self.frame_id if self.in_frame else -1
        self.items.append(LineOut(unpack(b.dt, b.payload), self.sof_pending, "stop", frame))

    def stop_burst(self, b):
        self.burst(b, stop=True)

    # ----------------------------------------------------------- registers
    def write(self, a, d):
        if a == REG["CTRL"]:
            was_on = self.rx_on
            self.ctrl = d & 0x3F7F
            if self.dut_lanes == 1:
                self.ctrl &= ~CTRL_LANES
            if was_on and not self.rx_on:
                self.reset_datapath()
                self.fs_prev = None            # FRAME_TIME/LINE_TIME references dropped,
                self.lt_ref = None             # the registers keep their values
            self.update_en()
            if self.clk_running and self.byte_clock_ok():
                self.byte_clock()
        elif a == REG["PHY_CFG"]:
            self.phy_cfg = d & 0xFFFF0FFF
            filt = max(1, (self.phy_cfg >> 8) & 0xF)
            self.seg_filter[self.seg] = max(self.seg_filter.get(self.seg, 1), filt)
        elif a == REG["IRQ_STATUS"]:
            self.irq &= ~d
        elif a == REG["IRQ_EN"]:
            self.irq_en = d & 0x1F
        elif a == REG["ERR_STATUS"]:
            self.err &= ~d
        elif a == REG["CNT_CLR"] and d & 1:
            for k in self.cnt:
                self.cnt[k] = 0
        elif a in (REG["DLY0"], REG["DLY1"]):
            lane = (a - REG["DLY0"]) >> 2
            if lane < self.dut_lanes:
                self.dly[lane] = d & 0x1FF
                if self.clk_running and self.byte_clock_ok():
                    self.byte_clock()
        elif a == REG["LOG_CTRL"] and d & 1:
            self.arm(self.log, d & 6)
        elif a == REG["RAW_CTRL"] and d & 1:
            self.arm(self.raw, d & 2)

    def read(self, a, hint=""):
        """Expected value of a register read at this point of the stimulus."""
        if hint in ("nz", "any"):
            return Expect("nonzero" if hint == "nz" else "any")
        if 0x400 <= a < 0x500:
            return Expect("exact", self.log_ram[(a - 0x400) >> 2])
        if 0x800 <= a < 0x900:
            return Expect("raw", (a - 0x800) >> 2, a=self.raw.burst, b=self.lanes)
        c, two = self.cnt, self.dut_lanes == 2
        n = REG_NAME.get(a)
        if n == "ID":
            v = ID_VALUE
        elif n == "INFO":
            v = self.dut_lanes | 1 << 4 | round(self.cfg["phy_hz"] / 1e6) << 8 | self.cfg["fifo_depth"] << 16
        elif n == "CTRL":
            v = self.ctrl
        elif n == "PHY_CFG":
            v = self.phy_cfg
        elif n == "STATUS":
            clk_pin = "00" if self.clk_running else self.pin[2]
            v = ST[clk_pin] | ST[self.pin[0]] << 2 | (ST[self.pin[1]] << 4 if two else 0)
            v |= int(self.fsm[2] == "hs" or self.force) << 8 | int(self.fsm[0] == "hs") << 9
            v |= int(two and self.fsm[1] == "hs") << 10
            v |= int((self.fsm[2] == "hs" and self.clk_running) or self.force) << 11
            v |= int(self.in_frame and self.rx_on) << 12
            return Expect("exact", v, 0x1FFF if two else 0x1BCF)
        elif n == "IRQ_STATUS":
            v = self.irq
        elif n == "IRQ_EN":
            v = self.irq_en
        elif n == "ERR_STATUS":
            v = self.err
        elif n == "CNT_FRAME":
            v = c["frame"]
        elif n == "CNT_PKT":
            v = c["pkt"]
        elif n == "CNT_LINE":
            v = c["line"]
        elif n == "CNT_ECC":
            v = c["ecc_corr"] | c["ecc_err"] << 16
        elif n == "CNT_CRC":
            v = c["crc"] | c["trunc"] << 16
        elif n == "CNT_SOT":
            v = c["sot0"] | c["sot1"] << 16
        elif n == "CNT_DROP":
            v = c["drop"] | c["ovf"] << 16
        elif n == "CNT_BURST":
            v = c["hs0"] | c["hs1"] << 16
        elif n == "CNT_MISC":
            v = c["hsclk"] | c["lp"] << 16 | c["misc"] << 24
        elif n in ("FRAME_INFO", "FRAME_SUM"):
            if "frame" in self.unknown:
                return Expect("any")
            v = self.frame_info if n == "FRAME_INFO" else self.frame_sum
            if n == "FRAME_SUM" and self.frames and self.frames[-1]["id"] in self.fuzzy_frames:
                return Expect("framesum", self.frames[-1]["id"])
        elif n == "LINE_INFO":
            if "line" in self.unknown:
                return Expect("any")
            v = self.line_info
        elif n == "FRAME_TIME":
            if "frame_time" in self.unknown:
                return Expect("any")
            if self.frame_time[0] is None:
                v = 0
            else:
                return Expect("time", a=self.frame_time[0], b=self.frame_time[1])
        elif n == "LINE_TIME":
            if "line_time" in self.unknown:
                return Expect("any")
            if self.line_time[0] is None:
                v = 0
            else:
                return Expect("time", a=self.line_time[0], b=self.line_time[1])
        elif n == "BYTECLK":
            if self.cfg.get("byteclk"):
                d = 256 * 20000 * 1000 // self.cfg["byte_ps"] // 1000
                return Expect("range", 256 * (d - 2), hi=256 * (d + 2))
            return Expect("any")
        elif n in ("DLY0", "DLY1"):
            lane = (a - REG["DLY0"]) >> 2
            v = self.dly[lane] | self.dly_out[lane] << 16 if lane < self.dut_lanes else 0
        elif n == "LOG_CTRL":
            cap = self.log
            oldest = cap.wptr if cap.mode == 4 and cap.count >= 64 else 0
            v = int(cap.armed) | cap.mode | int(cap.done) << 8 | oldest << 16
        elif n == "RAW_CTRL":
            v = int(self.raw.armed) | self.raw.mode | int(self.raw.done) << 8
        else:
            v = 0
        return Expect("exact", v)

    def mark(self, n):
        self.items.append(Mark(n))
        self.seg = n
        self.seg_expect[n] = {}
        self.seg_filter[n] = max(1, (self.phy_cfg >> 8) & 0xF)
        self.blind = False
        self.out_blocked = False
        self.fifo_used = 0

    def nocheck(self, what):
        self.items.append(Unchecked(what))
        if what == "all":
            self.blind = True
            self.blind_segs.add(self.seg)
            self.unknown |= {"frame", "line", "line_time", "frame_time"}
        elif what == "ovf":
            self.out_blocked = True


def stop_points(lines):
    """Bursts stopped by 'waitbyte <burst> <byte>' + a CTRL write."""
    return {int(f[1]) for f in (ln.split() for ln in lines) if f and f[0] == "waitbyte"}


def run_stim(cfg, lines, rx=None):
    """Feed the commands of stim.txt to a Receiver; returns (rx, expectations)
    with one Expect per 'rd'/'poll' in order."""
    rx = rx or Receiver(cfg)
    stops = stop_points(lines)
    exps = []
    for ln in lines:
        f = ln.split()
        if not f or f[0].startswith("#"):
            continue
        op = f[0]
        if op == "wr":
            rx.write(int(f[1], 16), int(f[2], 16))
        elif op in ("rd", "poll"):
            a = int(f[1], 16)
            exps.append((a, rx.read(a, f[2] if op == "rd" and len(f) > 2 else "")))
        elif op == "pkt":
            b = Burst.parse(f[1:])
            if rx.burst_idx in stops:
                rx.stop_burst(b)
            else:
                rx.burst(b)
        elif op == "lp":
            rx.lp_item(int(f[1]), f[2], int(f[3]))
        elif op == "idle":
            rx.lp00_hold = False
            rx.idle()
        elif op == "wait":
            rx.idle()
        elif op == "clkburst":
            rx.clk_burst()
        elif op == "knob" and f[1] == "t_clk_post":
            rx.t_clk_post = int(f[2])
        elif op == "clkon":
            rx.clock_on()
            if rx.byte_clock_ok():
                rx.byte_clock()
        elif op == "knob" and f[1] == "contclk":
            rx.contclk = int(f[2])
            if not rx.contclk:
                rx.clock_off()
        elif op == "mark":
            rx.mark(int(f[1]))
        elif op == "nocheck":
            rx.nocheck(f[1])
        elif op == "expect":
            rx.seg_expect[rx.seg][f[1]] = f[2]
    return rx, exps


# ---------------------------------------------------------------- generator
DEFAULT_CFG = {
    "test": "random", "seed": 1, "lanes": 2, "dut_lanes": 2, "contclk": 0, "byte_ps": 8772,
    "vid_ps": 5000, "cpu_ps": 20000, "phy_hz": 200_000_000, "fifo_depth": 256,
    "lp00": 0, "runt": 0, "byteclk": 0,
    "t_lpx": 60, "t_hs_prepare": 60, "t_hs_zero": 150, "t_hs_trail": 70, "t_hs_exit": 110,
    "t_clk_prepare": 60, "t_clk_zero": 300, "t_clk_pre": 20, "t_clk_post": 120,
    "t_clk_trail": 70, "t_lp11_next": 120,
    "eye0_lo": 0, "eye0_hi": 511, "eye1_lo": 0, "eye1_hi": 511,
}

DUMP_REGS = ["ID", "INFO", "CTRL", "PHY_CFG", "STATUS", "IRQ_STATUS", "IRQ_EN", "ERR_STATUS",
             "CNT_FRAME", "CNT_PKT", "CNT_LINE", "CNT_ECC", "CNT_CRC", "CNT_SOT", "CNT_DROP",
             "CNT_BURST", "CNT_MISC", "FRAME_INFO", "LINE_INFO", "FRAME_SUM", "FRAME_TIME",
             "LINE_TIME", "BYTECLK", "DLY0", "DLY1", "LOG_CTRL", "RAW_CTRL"]


class Gen:
    """Writes stim.txt while feeding every command to a Receiver, so that each
    burst can be checked for determinism (and re-rolled) before it is used."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.rnd = random.Random(f"{cfg['test']}/{cfg['seed']}/{cfg['lanes']}/{cfg['dut_lanes']}/"
                                 f"{cfg['contclk']}/{cfg.get('raw8', 0)}/{cfg.get('errors', 0)}")
        self.lines = []
        self.rx = Receiver(cfg)
        self.ecc_bit = (8 * cfg["seed"]) % 32
        self.marks = 0
        self.queued = False            # TX items queued since the last wait
        self.dirty = False             # bursts since the last clock-only burst

    # ------------------------------------------------------------ commands
    def emit(self, line):
        op = line.split()[0]
        if op in ("pkt", "lp", "idle", "clkon", "clkburst"):
            self.queued = True
        elif op == "wait":
            self.queued = False
        if op == "clkburst":
            self.dirty = False
        self.lines.append(line)
        run_stim(self.cfg, [line], self.rx)

    def sync(self, now=False):
        """Register accesses act on the state after the queued TX items,
        unless `now` (deliberately during an item). After bursts, a clock-only
        burst lets the receiver finish work the stopped byte clock deferred."""
        if now:
            return
        if self.dirty and not self.rx.contclk:
            self.emit("clkburst 800")
        self.dirty = False
        if self.queued:
            self.emit("wait")

    def wr(self, name, v, now=False):
        self.sync(now)
        self.emit(f"wr {REG[name]:03x} {v:08x}")

    def rd(self, name, hint="", now=False):
        self.sync(now)
        a = REG[name] if isinstance(name, str) else name
        self.emit(f"rd {a:03x}" + (f" {hint}" if hint else ""))

    def mark(self):
        self.sync()
        self.marks += 1
        self.emit(f"mark {self.marks}")

    def dump(self, log=True, raw=False):
        """Clock-only burst (deferred end-of-burst work), then read everything."""
        self.sync()
        for n in DUMP_REGS:
            self.rd(n)
        for a in (0x048, 0x0FC, 0x300):      # unmapped offsets read 0
            self.rd(a)
        if log:
            for i in range(64):
                self.rd(REG["LOG"] + 4 * i)
        if raw:
            for i in range(64):
                self.rd(REG["RAW"] + 4 * i)

    # ------------------------------------------------------------- packets
    def knobs(self, b):
        r = self.rnd
        b.phase = (r.randrange(8), r.randrange(8))
        b.zeros = (r.randrange(5), r.randrange(5))
        b.zero_ns = r.randrange(65)
        return b

    def short(self, vc, dt, data):
        return self.knobs(Burst(vc, dt, data))

    def long(self, vc, dt, payload):
        return self.knobs(Burst(vc, dt, len(payload), list(payload)))

    def line(self, vc, dt, w, fill=None):
        """Pixel line of w pixels (RAW10 needs w % 4 == 0)."""
        r = self.rnd
        if dt == DT_RAW10:
            px = [fill if fill is not None else r.randrange(1024) for _ in range(w)]
            return self.long(vc, dt, raw10_pack(px))
        return self.long(vc, dt, [fill >> 2 if fill is not None else r.randrange(256)
                                  for _ in range(w)])

    def pkt(self, b, stop=False):
        """Emit burst b if its outcome is deterministic (else nothing, False)."""
        if burst_problem(self.rx, b):
            return False
        self.queued = self.dirty = True
        self.lines.append(b.stim())
        if stop:
            self.rx.stop_burst(b)
        else:
            self.rx.burst(b)
        return True

    def corrupt(self, b, kind):
        """Copy of b with one error of the given kind, or None."""
        r = self.rnd
        c = replace(b)
        lanes = self.cfg["lanes"]
        if kind == "ecc1":
            c.hflip = (self.ecc_bit, -1)
            self.ecc_bit = (self.ecc_bit + 1) % 32
        elif kind == "ecc2":
            c.hflip = tuple(r.sample(range(30), 2))
        elif kind == "crc":
            if not b.is_long:
                return None
            c.pflip = r.randrange(8 * (b.wc + 2))
        elif kind == "trunc":
            hi = 4 + b.wc + 2 - self.rx.garbage_max - 1
            lo = 4 + 5
            if not b.is_long or hi < lo:
                return None
            c.trunc = r.randint(lo, hi)
        elif kind == "sync":
            lane = r.randrange(lanes)
            bad = SYNC ^ (1 << r.randrange(8)) if r.random() < 0.6 else r.choice(
                [x for x in range(256) if x != SYNC])
            c.sync = tuple(bad if l == lane else SYNC for l in range(2))
        elif kind == "skew":
            if lanes != 2:
                return None
            lane = r.randrange(2)
            c.zeros = tuple(12 + r.randrange(9) if l == lane else r.randrange(2) for l in range(2))
        return c

    def send(self, b, errors=None):
        """Emit b, with the next scheduled error when one applies (errors is a
        list consumed from the front)."""
        if errors and self.rnd.random() < 0.5:
            for _ in range(4):
                c = self.corrupt(b, errors[0])
                if c is not None and self.pkt(c):
                    errors.pop(0)
                    return
            errors.append(errors.pop(0))     # does not fit this packet: try it later
        if not self.pkt(b):
            raise RuntimeError(f"clean burst not deterministic: {burst_problem(self.rx, b)}")


def gen_random(g):
    """Frames of a random size with embedded data, LS/LE, packets of other
    VCs/DTs, generic short packets, odd WC; --errors adds ECC 1/2 bit, CRC,
    truncation, bad sync, skew and frame errors."""
    cfg, r = g.cfg, g.rnd
    lanes, raw8, errors = cfg["lanes"], cfg.get("raw8", 0), cfg.get("errors", 0)
    dt = DT_RAW8 if raw8 else DT_RAW10
    vc_any = r.random() < 0.2
    vc = r.randrange(4)
    ctrl = CTRL_PHY_EN | CTRL_RX_EN | (CTRL_LANES if lanes == 2 else 0) | \
        (CTRL_VC_ANY if vc_any else 0) | vc << 5 | dt << 8
    for n in ("ID", "INFO", "CTRL", "PHY_CFG"):
        g.rd(n)                                    # reset values
    g.wr("PHY_CFG", PHY_CFG_RESET)
    g.wr("IRQ_EN", 0x1F)
    g.wr("CTRL", ctrl)
    log_mode = r.choice([None, 0, 2, 4, 6])
    if log_mode is not None:
        g.wr("LOG_CTRL", 1 | log_mode)
    g.emit(f"tready {cfg['tready']}")

    w = 4 * (r.randrange(16, 25) if errors else r.randrange(2, 17))   # errors: room for truncations
    h = r.randrange(2, 7)
    frames = r.randrange(2, 4)
    fnum_mode = r.randrange(3)
    errs = []
    if errors:
        errs = ["ecc1"] * 8 + ["ecc2"] * 3 + ["crc"] * 3 + ["trunc"] * 3 + ["sync"] * 3
        errs += ["skew"] * 2 if lanes == 2 else []
        r.shuffle(errs)

    def other():
        k = r.randrange(11)
        ovc = r.randrange(4)
        if k == 0:
            g.send(g.short(ovc, 0x08 + r.randrange(8), r.randrange(0x10000)), errs)
        elif k == 1:
            g.send(g.short(ovc, r.choice([DT_LS, DT_LE, 4, 5, 6, 7]), r.randrange(0x10000)), errs)
        elif k == 2:
            g.send(g.long(ovc, r.choice([DT_NULL, DT_BLANK, 0x30, 0x37]),
                          [r.randrange(256) for _ in range(r.randrange(0, 24))]), errs)
        elif k == 3:
            g.send(g.long(ovc, DT_EMB, [r.randrange(256) for _ in range(w)]), errs)
        elif k == 4:
            g.send(g.line((vc + 1 + r.randrange(3)) & 3, dt, w), errs)       # other VC
        elif k == 5:
            g.send(g.line(vc, DT_RAW10 if raw8 else DT_RAW8, w), errs)       # other DT
        elif k == 6:                                                        # odd WC
            n = r.choice([1, 2, 3, 4, 6, 7, 9, 11, 13]) + (5 * r.randrange(4) if not raw8 else 0)
            g.send(g.long(vc, dt, [r.randrange(256) for _ in range(n)]), errs)
        elif k == 7:
            g.send(g.long(vc, dt, []), errs)                                 # WC = 0
        elif k == 8 and errors:
            g.send(g.short(vc, DT_FE, 0), errs)                              # FE without FS
        elif k == 9 and errors:
            g.send(g.short(vc, DT_FS, 0x55), errs)                           # FS in a frame
        else:
            g.send(g.short(ovc, r.choice([DT_FS, DT_FE]), r.randrange(4)), errs)

    f = 0
    while f < frames or (errs and f < frames + 8):    # until all scheduled errors are used
        fnum = [0, 1 + f % 4, f + 1][fnum_mode]
        if r.random() < 0.5:
            other()
        g.send(g.short(vc, DT_FS, fnum), errs)
        if r.random() < 0.6:
            for _ in range(2):
                g.send(g.long(vc, DT_EMB, [r.randrange(256) for _ in range(w)]), errs)
        for y in range(h):
            ls = r.random() < 0.3
            if ls:
                g.send(g.short(vc, DT_LS, y + 1), errs)
            g.send(g.line(vc, dt, w), errs)
            if ls:
                g.send(g.short(vc, DT_LE, y + 1), errs)
            if r.random() < 0.3:
                other()
        g.send(g.short(vc, DT_FE, fnum), errs)
        if f == 0 and r.random() < 0.4:
            g.emit("wait")
            k = r.randrange(3)
            if k == 0:
                g.wr("CNT_CLR", 1)
                g.wr("ERR_STATUS", 0x3FF)
                g.wr("IRQ_STATUS", 0x1F)
            elif k == 1:
                g.wr("CTRL", ctrl & ~CTRL_RX_EN)       # RX off/on between frames
                g.wr("CTRL", ctrl)
            elif log_mode is not None:
                g.wr("LOG_CTRL", 1 | r.choice([0, 2, 4, 6]))   # restart the capture
        f += 1
    g.injected = len(errs)
    g.dump(log=log_mode is not None)


def frame(g, vc, dt, w, h, fnum=1, emb=False):
    g.send(g.short(vc, DT_FS, fnum))
    if emb:
        for _ in range(2):
            g.send(g.long(vc, DT_EMB, [g.rnd.randrange(256) for _ in range(w)]))
    for _ in range(h):
        g.send(g.line(vc, dt, w))
    g.send(g.short(vc, DT_FE, fnum))


def on(g, extra=0):
    ctrl = CTRL_PHY_EN | CTRL_RX_EN | (CTRL_LANES if g.cfg["lanes"] == 2 else 0) | DT_RAW10 << 8
    g.wr("CTRL", ctrl | extra)
    return ctrl | extra


def gen_lp(g):
    """LP state machines: escape entry, LP-00 from Stop, LP-10 after an HS
    request, aborted request, LP filter, held states in STATUS, clock lane."""
    ctrl = on(g)
    g.emit("tready 100")
    g.emit("wait")
    g.rd("STATUS")                                   # sensor not streamed yet: LP-00
    g.emit("idle 300")
    g.emit("wait")
    g.rd("STATUS")
    for st in ("10", "00", "01", "00"):              # escape mode entry: Stop + LP-10
        g.emit(f"lp 1 {st} 100")
    g.emit("wait")
    g.rd("CNT_MISC")
    g.rd("ERR_STATUS")
    g.emit(f"lp {2 if g.cfg['lanes'] == 2 else 1} 00 200")   # LP-00 from Stop
    g.emit("wait")
    g.emit("lp 1 01 100")                            # HS request, then LP-10
    g.emit("lp 1 10 100")
    g.emit("wait")
    g.emit("lp 1 01 100")                            # aborted request: back to Stop
    g.emit("wait")
    g.emit("lp 4 10 100")                            # clock lane: Stop + LP-10
    g.emit("wait")
    g.rd("CNT_MISC")
    g.rd("CNT_BURST")
    g.emit("lp 1 01 3000")                           # held LP-01 in STATUS
    g.emit("delay 1500")
    g.rd("STATUS", now=True)
    g.emit("wait")
    g.emit("lp 1 01 100")                            # HS entry without clock: HS on in STATUS
    g.emit("lp 1 00 3000")
    g.emit("delay 1700")
    g.rd("STATUS", now=True)
    g.emit("wait")
    g.rd("CNT_BURST")
    g.wr("CTRL", 0)                                  # LP filter 4: one-step glitches ignored
    g.wr("PHY_CFG", PHY_CFG_RESET & ~0xF00 | 4 << 8)
    g.wr("CTRL", ctrl)
    g.mark()
    for _ in range(3):
        g.emit("lp 1 10 9")
        g.emit("idle 200")
    g.emit("wait")
    g.rd("CNT_MISC")
    frame(g, 0, DT_RAW10, 16, 3)
    g.wr("CTRL", 0)
    g.wr("PHY_CFG", PHY_CFG_RESET)
    g.wr("CTRL", ctrl)
    g.mark()
    frame(g, 0, DT_RAW10, 24, 3, fnum=2)
    g.dump(log=False)


def gen_watchdog(g):
    """Data lane stuck in HS (LP-00 > 2^20 video cycles): watchdog LP error."""
    on(g)
    g.emit("tready 100")
    g.emit("wait")
    g.emit("lp 1 01 100")
    g.emit(f"lp 1 00 {(1 << 20) * g.cfg['vid_ps'] // 1000 + 300_000}")
    g.emit("wait")
    g.rd("CNT_MISC")
    g.rd("CNT_BURST")
    g.rd("ERR_STATUS")
    g.rd("CNT_SOT")
    frame(g, 0, DT_RAW10, 16, 2)
    g.dump(log=False)


def gen_clk(g):
    """Clock lane gate: CE only while static (checked by the testbench on
    every step), clock miss, CLK_MISS = 0 backstop, short CLK-POST (deferred
    end of burst), continuous clock started before PHY_EN + CLK_FORCE."""
    ctrl = on(g)
    g.emit("tready 100")
    frame(g, 0, DT_RAW10, 32, 3)
    g.emit("wait")
    g.wr("CTRL", 0)
    g.wr("PHY_CFG", PHY_CFG_RESET & 0x00FFFFFF)      # CLK_MISS = 0: LP-11 backstop
    g.wr("CTRL", ctrl)
    g.mark()
    g.emit("expect ce_bad nz")
    g.emit("expect runts nz")
    g.emit("knob runt 1")                            # runt byte clock edges while CE is open in LP-11
    frame(g, 0, DT_RAW10, 32, 3, fnum=2)
    g.emit("wait")
    g.emit("knob runt 0")
    g.wr("CTRL", 0)
    g.wr("PHY_CFG", PHY_CFG_RESET)
    g.wr("CTRL", ctrl)
    g.mark()
    g.emit("knob t_clk_post 10")                     # clock stops before the arm fall
    g.send(g.short(0, DT_FS, 3))
    b = g.line(0, DT_RAW10, 32)
    c = g.corrupt(b, "sync")
    if c is None or not g.pkt(c):
        g.send(b)
    for _ in range(3):
        g.send(g.line(0, DT_RAW10, 32))
    g.send(g.short(0, DT_FE, 3))
    g.sync()
    g.emit("knob t_clk_post 120")
    g.wr("CTRL", 0)                                  # continuous clock before PHY_EN
    g.emit("knob contclk 1")
    g.emit("clkon")
    g.emit("wait")
    g.wr("CTRL", ctrl)
    g.mark()
    g.emit("expect ce_rise_toggle any")
    g.send(g.short(0, DT_FS, 4))                     # no byte clock: nothing received
    g.send(g.line(0, DT_RAW10, 32))
    g.emit("wait")
    g.rd("STATUS")
    g.rd("CNT_BURST")
    g.rd("CNT_PKT")
    g.wr("CTRL", 0)
    g.wr("CTRL", ctrl | CTRL_CLK_FORCE)
    g.emit("wait")
    g.rd("STATUS")
    frame(g, 0, DT_RAW10, 32, 3, fnum=5)
    g.dump(log=False)


def gen_cmd(g):
    """CPU -> byte domain commands while the byte clock is stopped (LOG ARM
    twice, RAW ARM, DLY write), then traffic; all LOG modes; RAW NOW."""
    on(g)
    g.emit("tready 100")
    g.emit("wait")
    g.wr("LOG_CTRL", 1 | 2)                          # TRIG_FS ...
    g.rd("LOG_CTRL")
    g.wr("LOG_CTRL", 1 | 4)                          # ... restarted: STOP_FE (circular)
    g.rd("LOG_CTRL")
    g.wr("RAW_CTRL", 1)
    g.rd("RAW_CTRL")
    g.wr("DLY0", 0x123)
    if g.cfg["dut_lanes"] == 2:
        g.wr("DLY1", 0x0A5)
    g.rd("DLY0")
    g.rd("DLY1")
    g.send(g.long(1, DT_EMB, [g.rnd.randrange(256) for _ in range(160)]))
    frame(g, 0, DT_RAW10, 48, 4, emb=True)
    g.emit("wait")
    g.emit(f"poll {REG['LOG_CTRL']:03x} 00000100 00000100 200")
    g.emit(f"poll {REG['RAW_CTRL']:03x} 00000100 00000100 200")
    g.rd("DLY0")
    g.rd("DLY1")
    g.rd("IRQ_STATUS")
    for i in range(64):
        g.rd(REG["RAW"] + 4 * i)
    for i in range(16):
        g.rd(REG["LOG"] + 4 * i)
    g.wr("IRQ_STATUS", IRQ_LOG | IRQ_RAW)
    g.wr("LOG_CTRL", 1)                              # plain: the next 64 packets
    for i in range(70):
        g.send(g.short(g.rnd.randrange(4), 0x08 + i % 8, i))
    g.emit("wait")
    g.emit(f"poll {REG['LOG_CTRL']:03x} 00000100 00000100 200")
    for i in range(64):
        g.rd(REG["LOG"] + 4 * i)
    g.wr("LOG_CTRL", 1 | 2 | 4)                      # TRIG_FS | STOP_FE: one frame
    g.send(g.short(0, DT_FE, 9))
    frame(g, 0, DT_RAW10, 16, 5, fnum=7)
    g.emit("wait")
    g.emit(f"poll {REG['LOG_CTRL']:03x} 00000100 00000100 200")
    g.wr("RAW_CTRL", 1 | 2)                          # NOW
    g.send(g.long(2, DT_NULL, [0x5A] * 160))
    g.emit("wait")
    g.emit(f"poll {REG['RAW_CTRL']:03x} 00000100 00000100 200")
    g.dump(log=True)


def gen_ovf(g):
    """m_axis held off: FIFO overflow in the middle of a frame, then resume."""
    on(g)
    g.wr("LOG_CTRL", 1 | 2 | 4)
    g.emit("tready 0")
    g.emit("nocheck ovf")
    frame(g, 0, DT_RAW10, 64, 20)
    g.emit("wait")
    g.emit("tready 100")
    g.emit("delay 20000")
    g.mark()
    frame(g, 0, DT_RAW10, 64, 4, fnum=2)
    g.dump(log=True)


def gen_stop(g):
    """RX_EN, then PHY_EN cleared in the middle of a line burst; restart
    (counters cleared): no stale packet, line, group or frame state."""
    ctrl = on(g)
    g.emit("tready 100")
    for off in (ctrl & ~CTRL_RX_EN, 0):
        g.send(g.short(0, DT_FS, 1))
        g.send(g.line(0, DT_RAW10, 64))
        n = g.rx.burst_idx
        b = g.line(0, DT_RAW10, 64)
        g.pkt(b, stop=True)
        g.emit(f"waitbyte {n} {g.rnd.randrange(24, 4 + b.wc + 2 - 24)}")
        g.wr("CTRL", off, now=True)
        g.emit("wait")
        g.mark()
        g.wr("CNT_CLR", 1)
        g.wr("ERR_STATUS", 0x3FF)
        g.wr("IRQ_STATUS", 0x1F)
        g.wr("CTRL", ctrl)
        g.send(g.line(0, DT_RAW10, 64))             # rest of the old frame: FE ignored
        g.send(g.short(0, DT_FE, 1))
        frame(g, 0, DT_RAW10, 64, 3, fnum=2)
        g.emit("wait")
        for n in ("CNT_FRAME", "CNT_PKT", "CNT_LINE", "ERR_STATUS", "CNT_MISC", "FRAME_INFO"):
            g.rd(n)
    g.dump(log=False)


def gen_byteclk(g):
    """BYTECLK with a continuous clock (needs 2 x 65536 CPU cycles)."""
    on(g)
    g.emit("tready 100")
    g.emit("clkon")
    g.emit("delay 2800000")
    g.rd("BYTECLK")
    g.rd("STATUS")
    frame(g, 0, DT_RAW10, 16, 2)
    g.dump(log=False)


def gen_eye(g):
    """IDELAY taps: outside the eye (TX knob) the link fails; after loading
    good taps (needs a burst) and a restart it is clean."""
    ctrl = on(g)
    g.emit("tready 100")
    g.emit("nocheck all")
    g.emit("expect flips nz")
    for f in range(2):
        frame(g, 0, DT_RAW10, 32, 3, fnum=f)
    g.rd("CNT_SOT", "nz")
    g.wr("CTRL", ctrl & ~CTRL_RX_EN)
    taps = [(g.cfg["eye0_lo"] + g.cfg["eye0_hi"]) // 2, (g.cfg["eye1_lo"] + g.cfg["eye1_hi"]) // 2]
    g.wr("DLY0", taps[0])
    if g.cfg["dut_lanes"] == 2:
        g.wr("DLY1", taps[1])
    g.rd("DLY0")
    g.send(g.short(0, 0x08, 0))                      # loads the taps (RX off)
    g.emit("wait")
    g.rd("DLY0")
    g.rd("DLY1")
    g.wr("CNT_CLR", 1)
    g.wr("ERR_STATUS", 0x3FF)
    g.wr("IRQ_STATUS", 0x1F)
    g.mark()
    g.wr("CTRL", ctrl)
    frame(g, 0, DT_RAW10, 32, 4, fnum=5)
    g.dump(log=False)


TESTS = {"random": gen_random, "lp": gen_lp, "watchdog": gen_watchdog, "clk": gen_clk,
         "cmd": gen_cmd, "ovf": gen_ovf, "stop": gen_stop, "byteclk": gen_byteclk, "eye": gen_eye}


# ------------------------------------------------------------------ checker
def read_cfg(path):
    cfg = dict(DEFAULT_CFG)
    for ln in Path(path).read_text().splitlines():
        f = ln.split()
        if len(f) >= 2 and not f[0].startswith("#"):
            cfg[f[0]] = f[1] if f[0] == "test" else int(f[1], 0)
    return cfg


def read_out(path):
    """out.txt: '<pixel hex> <tuser> <tlast>' per transfer, 'mark <n>'."""
    out = []
    for ln in Path(path).read_text().splitlines():
        f = ln.split()
        if not f:
            continue
        if f[0] == "mark":
            out.append(("mark", int(f[1])))
        else:
            out.append(("px", int(f[0], 16), int(f[1]), int(f[2])))
    return out


def read_regs(path):
    """regs.txt: rd/poll results, fe records, marks, invariants, burst times."""
    rds, fes, inv, tend, seg, ended = [], [], {}, {}, 0, False
    for ln in Path(path).read_text().splitlines():
        f = ln.split()
        if not f:
            continue
        if f[0] in ("rd", "poll"):
            rds.append((int(f[1], 16), int(f[2], 16)))
        elif f[0] == "fe":
            fes.append((seg, int(f[1], 16), int(f[2], 16)))
        elif f[0] == "mark":
            seg = int(f[1])
        elif f[0] == "inv":
            inv.setdefault(int(f[1]), {})[f[2]] = int(f[3])
        elif f[0] == "tend":
            tend[int(f[1])] = int(f[2])
        elif f[0] == "end":
            ended = True
    return rds, fes, inv, tend, ended


def fmt_out(e):
    return f"mark {e[1]}" if e[0] == "mark" else f"{e[1]:03x} tuser {e[2]} tlast {e[3]}"


def match_output(items, out, errs, max_extra):
    """Compare the m_axis transfers with the predicted lines; returns the sum
    of the received pixels per frame id (FRAME_SUM with truncated lines)."""
    sums, pos, i = {}, 0, 0
    while i < len(items):
        it = items[i]
        if isinstance(it, Mark):
            if pos < len(out) and out[pos] == ("mark", it.n):
                pos += 1
            else:
                got = fmt_out(out[pos]) if pos < len(out) else "end of output"
                errs.append(f"output entry {pos}: expected mark {it.n}, got {got}")
                return sums
            i += 1
            continue
        if isinstance(it, Unchecked):
            while pos < len(out) and out[pos][0] != "mark":
                pos += 1
            i += 1
            while i < len(items) and not isinstance(items[i], Mark):
                i += 1
            continue
        got, ended = [], False
        for k, v in enumerate(it.px):
            if pos >= len(out) or out[pos][0] != "px":
                if it.fuzzy == "stop":
                    break
                errs.append(f"output entry {pos}: line {i} pixel {k}: expected {v:03x}, got "
                            f"{fmt_out(out[pos]) if pos < len(out) else 'end of output'}")
                return sums
            _, gv, gu, gl = out[pos]
            last = k == len(it.px) - 1
            eu = int(it.sof and k == 0)
            bad_last = gl and not (last and it.fuzzy in ("", "trunc")) or (last and not it.fuzzy and not gl)
            if gv != v or gu != eu or bad_last:
                if it.fuzzy == "stop" and gu == eu and not gl and gv != v:
                    errs.append(f"output entry {pos}: stopped line {i} pixel {k}: got {gv:03x} "
                                f"expected {v:03x}")
                else:
                    exp = f"{v:03x} tuser {eu} tlast {int(last and not it.fuzzy)}"
                    kind = f"{len(it.px)} px" + (f", {it.fuzzy}" if it.fuzzy else "")
                    errs.append(f"output entry {pos}: line {i} ({kind}) pixel {k}: "
                                f"got {fmt_out(out[pos])}, expected {exp}")
                return sums
            got.append(gv)
            pos += 1
            if gl:
                ended = True
                break
        if it.fuzzy == "trunc" and not ended:
            while True:
                if pos >= len(out) or out[pos][0] != "px":
                    errs.append(f"output entry {pos}: truncated line {i} has no tlast")
                    return sums
                _, gv, gu, gl = out[pos]
                pos += 1
                got.append(gv)
                if gu:
                    errs.append(f"output entry {pos - 1}: tuser inside truncated line {i}")
                if gl:
                    break
                if len(got) > len(it.px) + max_extra:
                    errs.append(f"output entry {pos}: truncated line {i}: more than {max_extra} extra pixels")
                    return sums
        if it.frame >= 0:
            sums[it.frame] = (sums.get(it.frame, 0) + sum(got)) & 0xFFFFFFFF
        i += 1
    if pos < len(out):
        errs.append(f"output: {len(out) - pos} entries after the predicted end, first: {fmt_out(out[pos])}")
    return sums


def check_raw(group, errs):
    """RAW capture of the first burst after ARM: on every lane the sync is
    followed by the bytes of that lane."""
    burst, lanes = group[0][0].a, group[0][0].b
    if burst is None:
        return
    per = lane_split(burst.sent(), lanes)
    for l in range(lanes):
        words = [(v >> (8 * l)) & 0xFF for _, v in group]
        need = min(len(per[l]), 24)
        n = find_lane_bytes(words, per[l])
        if n < need:
            errs.append(f"RAW lane {l}: sync followed by the {need} first bytes of the burst not found "
                        f"(words {' '.join(f'{w:02x}' for w in words[:24])} ...)")


def check(d):
    cfg = read_cfg(d / "cfg.txt")
    lines = (d / "stim.txt").read_text().splitlines()
    rx, exps = run_stim(cfg, lines)
    errs = []
    rds, fes, inv, tend, ended = read_regs(d / "regs.txt")
    if not ended:
        errs.append("regs.txt: testbench did not finish (no 'end')")
    out = read_out(d / "out.txt")
    sums = match_output(rx.items, out, errs, 4 * rx.garbage_max)

    if len(rds) != len(exps):
        errs.append(f"regs.txt: {len(rds)} reads, stim.txt has {len(exps)}")
    raw = []
    for k, ((a, e), (ga, gv)) in enumerate(zip(exps, rds)):
        if ga != a:
            errs.append(f"read {k}: address {ga:03x}, stim.txt says {a:03x}")
            break
        ok = True
        if e.kind == "exact":
            ok = (gv & e.mask) == (e.value & e.mask)
        elif e.kind == "time":
            if e.a in tend and e.b in tend:
                cyc = (tend[e.b] - tend[e.a]) / cfg["cpu_ps"]
                ok = abs(gv - cyc) <= 3
                e = Expect("exact", round(cyc))
            else:
                ok = False
        elif e.kind == "range":
            ok = e.value <= gv <= e.hi
        elif e.kind == "nonzero":
            ok = gv != 0
        elif e.kind == "framesum":
            exp = sums.get(e.value, 0)
            ok = gv == exp
            e = Expect("exact", exp)
        elif e.kind == "raw":
            raw.append((e, gv))
            if len(raw) == 64:
                check_raw(raw, errs)
                raw = []
        if not ok:
            name = REG_NAME.get(a, "LOG[%d]" % ((a - 0x400) >> 2) if 0x400 <= a < 0x500 else f"{a:03x}")
            errs.append(f"read {k} {name}: got {gv:08x}, expected {e.describe()}")

    exp_fe = [f for f in rx.frames if f["seg"] not in rx.blind_segs]
    got_fe = [f for f in fes if f[0] not in rx.blind_segs]
    if len(exp_fe) != len(got_fe):
        errs.append(f"frame ends: {len(got_fe)} recorded, expected {len(exp_fe)}")
    for n, (e, (_, info, fsum)) in enumerate(zip(exp_fe, got_fe)):
        esum = sums.get(e["id"], 0) if e["id"] in rx.fuzzy_frames else e["sum"]
        if info != e["info"] or (esum is not None and fsum != esum):
            errs.append(f"frame end {n}: FRAME_INFO {info:08x} FRAME_SUM {fsum:08x}, expected "
                        f"{e['info']:08x} {'-' if esum is None else f'{esum:08x}'}")

    for seg, vals in sorted(inv.items()):
        exp = rx.seg_expect.get(seg, {})
        bound = (4 + max(2, rx.seg_filter.get(seg, 2))) * cfg["vid_ps"] + 100
        for name, v in sorted(vals.items()):
            cond = exp.get(name, "lat" if name.startswith(("lat", "off")) else "0")
            if cond == "lat" and v > bound:
                errs.append(f"segment {seg}: {name} {v} ps > {bound} ps")
            elif cond == "0" and v != 0:
                errs.append(f"segment {seg}: {name} = {v}, expected 0")
            elif cond == "nz" and v == 0:
                errs.append(f"segment {seg}: {name} = 0, expected > 0")
    npx = sum(1 for e in out if e[0] == "px")
    return errs, f"{npx} pixels, {len(rds)} reads, {len(got_fe)} frames"


# ---------------------------------------------------------------------- CLI
def cmd_gen(args):
    out = Path(args.dir)
    out.mkdir(parents=True, exist_ok=True)
    cfg = dict(DEFAULT_CFG)
    cfg.update(test=args.test, seed=args.seed, lanes=args.lanes,
               dut_lanes=args.dut_lanes or args.lanes, contclk=int(args.contclk),
               raw8=int(args.raw8), errors=int(args.errors), tready=100)
    if cfg["lanes"] > cfg["dut_lanes"]:
        raise SystemExit("--lanes must not exceed --dut-lanes")
    r = random.Random(f"cfg/{args.test}/{args.seed}/{args.lanes}/{args.contclk}")
    if args.test == "random":
        cfg["byte_ps"] = r.choice([8772, 8772, 7600, 10400])
        cfg["t_clk_post"] = 130 if args.contclk else r.choice([130, 130, 30])
        cfg["lp00"] = r.randrange(2)
        cfg["tready"] = 100 if args.seed % 3 == 0 else r.randrange(72, 100)
    elif args.test == "byteclk":
        cfg.update(contclk=1, byteclk=1)
    elif args.test == "eye":
        cfg.update(eye0_lo=100, eye0_hi=300, eye1_lo=180, eye1_hi=400)
    elif args.test == "lp":
        cfg["lp00"] = 1
    g = Gen(cfg)
    TESTS[args.test](g)
    (out / "cfg.txt").write_text("".join(f"{k} {v}\n" for k, v in cfg.items()))
    head = f"# csi2_model.py gen --test {args.test} --seed {args.seed} --lanes {cfg['lanes']}\n"
    (out / "stim.txt").write_text(head + "".join(ln + "\n" for ln in g.lines))
    for f in ("out.txt", "regs.txt"):
        (out / f).unlink(missing_ok=True)
    print(f"{out}: test {args.test} seed {args.seed}, {cfg['lanes']}/{cfg['dut_lanes']} lanes, "
          f"{'continuous' if cfg['contclk'] else 'non-continuous'} clock, {g.rx.burst_idx} bursts, "
          f"{len(g.rx.items)} output items" +
          (f", {getattr(g, 'injected', 0)} scheduled errors not used" if cfg["errors"] else ""))


def cmd_check(args):
    d = Path(args.dir)
    errs, summary = check(d)
    if errs:
        print(f"{d}: FAIL")
        for e in errs[:25]:
            print("  " + e)
        if len(errs) > 25:
            print(f"  ... {len(errs) - 25} more")
        return 1
    print(f"{d}: PASS ({summary})")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("gen", help="generate a test case")
    p.add_argument("dir")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--lanes", type=int, choices=(1, 2), default=2, help="lanes used (CTRL.LANES)")
    p.add_argument("--dut-lanes", type=int, choices=(1, 2), help="Lanes parameter (default --lanes)")
    p.add_argument("--errors", action="store_true", help="inject link and protocol errors")
    p.add_argument("--raw8", action="store_true", help="RAW8 lines (CTRL.DT 0x2A)")
    p.add_argument("--contclk", action="store_true", help="continuous clock lane")
    p.add_argument("--test", choices=sorted(TESTS), default="random")
    p = sub.add_parser("check", help="compare the testbench dumps in DIR with the model")
    p.add_argument("dir")
    args = ap.parse_args()
    return {"gen": cmd_gen, "check": cmd_check}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
