#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Mutation check of the whole receiver bench (`make mutants-rx`, not in `make test`).

As mutants_ppi.py, for logic that only the whole receiver (bow_mipi_rx: the D-PHY and the
controller, tb_bow_csi2rx.sv with csi2_tx_model.sv) exercises: the RAW capture of the D-PHY
(bow_dphy_raw in bow_dphy_rx, step 4 of docs/ip/mipi_rx_arch.md: no PPI bench sees it), the
controller's gate of the aligners' PPI events (ErrSotSyncHS, RxSkewCalHS) while its
datapath is off, and the AFE interface of step 5 (des_rst, OWN, lprx_en of the D-PHY; the
delay logic of the two FPGA adapters that csi2_tx_model runs: bow_afe_chk and the model's
delay checks must see them). Each mutant is a copy of hw/ip/dphy_rx/rtl, hw/ip/csi2rx/rtl
and the adapters' delay modules with one text substitution; it must make one case fail
(simulation or model check). The cases are generated once with tools/csi2/csi2_model.py and
first run on the RTL as it is.

    mutants_rx.py --build <dir> [--jobs N] [--every] [name ...]

Exit code 0 when every selected mutant was killed.
"""
import argparse
import concurrent.futures
import os
import shutil
import sys

from mutants_ppi import MODEL, REPO, TIMEOUT, VERILATOR, VERILATOR_ENV, run

HERE = os.path.dirname(os.path.abspath(__file__))
DPHY_RTL = os.path.join(REPO, "hw", "ip", "dphy_rx", "rtl")
CSI_RTL = os.path.join(REPO, "hw", "ip", "csi2rx", "rtl")
AFE_RTL = os.path.join(REPO, "hw", "fpga", "common", "rtl")
# dphy_rx.f, then csi2rx.f, in order, then the AFE adapters' logic that csi2_tx_model runs (as
# AFE_DLY of the Makefile)
FILES = [(DPHY_RTL, f) for f in ("bow_dphy_lp.sv", "bow_dphy_align.sv", "bow_dphy_raw.sv",
                                  "bow_dphy_rx_regs.sv", "bow_dphy_rx.sv")] + \
        [(CSI_RTL, f) for f in ("bow_csi2rx_pkg.sv", "bow_csi2_lane_merge.sv",
                                 "bow_csi2_packet.sv", "bow_csi2_unpack.sv", "bow_csi2rx_out.sv",
                                 "bow_csi2_capture.sv", "bow_csi2rx_regs.sv", "bow_csi2rx.sv",
                                 "bow_mipi_rx.sv")] + \
        [(AFE_RTL, f) for f in ("bow_dphy_dly_xusp.sv", "bow_dphy_dly_xphy.sv")]
# as PARAMS_* of the Makefile: Lanes = 4 is the Huins receiver (Versal PHY model)
PARAMS = {1: ["-GLanes=1"], 2: ["-GLanes=2"],
          4: ["-GLanes=4", "-GAfeKind=2", "-GFifoDepth=512"]}
DPHY, CTRL = "bow_dphy_rx.sv", "bow_csi2rx.sv"
LP, REGS = "bow_dphy_lp.sv", "bow_dphy_rx_regs.sv"
XUSP, XPHY = "bow_dphy_dly_xusp.sv", "bow_dphy_dly_xphy.sv"

# whole receiver cases: (test, lanes, Lanes parameter), seed 1, BurstRxRst 0 (as test-rx)
CASES = [("raw", 4, 4), ("rxoff", 2, 2), ("rxoff", 4, 4), ("rxoff", 1, 1), ("dly", 4, 4),
         ("be", 2, 2)]

# name, [(file, old text, new text, occurrences)]: every old text must occur that often
MUTANTS = [
    # RAW of the D-PHY: every PHY word taken, not only the valid ones (raw: a read gap of the
    # Versal PHY a few words after the sync); the capture started by the rise of any lane's
    # RxActiveHS (raw: lane 0 enters HS after the other lanes, its first word is noise then)
    ("raw_valid_ignored", [(DPHY, "    .rx_vld0_i   (rxv_q[0]),", "    .rx_vld0_i   (1'b1),", 1)]),
    ("raw_trigger_any_lane", [(DPHY, "    .arm0_i      (arm[0]),", "    .arm0_i      (|arm),", 1)]),
    # the controller's gate of the aligner events (rxoff): none (SoT errors and deskew bursts
    # counted while RX is off and at a stop in the sync search); in the datapath reset only
    # (the burst a lane was in when RX came on counted); deskew bursts not gated
    ("aligner_events_ungated", [(CTRL, "  assign sot_ev = al_sync_err & ~stale_q;",
                                 "  assign sot_ev = al_sync_err;", 1),
                                (CTRL, "  assign dsk_ev = al_deskew[0] & ~stale_q[0];",
                                 "  assign dsk_ev = al_deskew[0];", 1)]),
    ("aligner_events_reset_only", [(CTRL, "      stale_q  <= stale_q & ~arm_lo_q;",
                                    "      stale_q  <= '0;", 1)]),
    ("aligner_deskew_ungated", [(CTRL, "  assign dsk_ev = al_deskew[0] & ~stale_q[0];",
                                 "  assign dsk_ev = al_deskew[0];", 1)]),
    # step 5, the AFE interface: des_rst one lp cycle after the gate (from its flop, not its
    # next state); des_rst not held off by CTRL.DES_RST_DIS; OWN kept when READY falls (a
    # restart of the AFE would keep a code it lost); lprx_en not following AFE_CTRL.PD
    ("des_rst_late", [(LP, "      else         des_rst_q <= !ce_d && des_rst_en_i;",
                       "      else         des_rst_q <= !ce_q && des_rst_en_i;", 1)]),
    ("des_rst_dis_ignored", [(LP, "      else         des_rst_q <= !ce_d && des_rst_en_i;",
                              "      else         des_rst_q <= !ce_d;", 1)]),
    ("own_kept_not_ready", [(REGS, "    own_d      = ready_i ? own_q : '0;",
                             "    own_d      = own_q;", 1)]),
    ("lprx_en_without_pd", [(REGS, "      lprx_en_q <= !pd_d;", "      lprx_en_q <= 1'b1;", 1)]),
    # the adapters' delay logic: the XPHY sequencer without the wait after RX_EN_VTC 1 -> 0,
    # loading the code in use again (every stable cycle of an OWN lane); the IDELAYE3 loader
    # never loading
    ("xphy_no_vtc_wait", [(XPHY, "              wait_d[l] = 5'(VtcWait);",
                           "              wait_d[l] = 5'd0;", 1)]),
    ("xphy_reload_same_code", [(XPHY, "        req[l]    = stable[l] && own_s[l] && "
                                "(!app_own_q[l] || (code_s[l] != app_code_q[l]));",
                                "        req[l]    = stable[l] && own_s[l];", 1)]),
    ("xusp_no_load", [(XUSP, "        load_d[l]   = 1'b1;", "        load_d[l]   = 1'b0;", 1)]),
]


def case_name(c):
    t, l, d = c
    return f"{t}_l{l}of{d}"


def gen_cases(build):
    """Generate every case once (the options of the Makefile's run)."""
    d0 = os.path.join(build, "cases")
    os.makedirs(d0, exist_ok=True)
    for c in CASES:
        t, l, d = c
        argv = [sys.executable, MODEL, "gen", os.path.join(d0, case_name(c)), "--test", t,
                "--seed", "1", "--lanes", str(l), "--dut-lanes", str(d)]
        if d == 4:
            argv += ["--versal", "--fifo-depth", "512", "--burst-rst", "0"]
        if run(argv, os.path.join(d0, case_name(c) + ".gen.log")) != 0:
            raise SystemExit(f"cannot generate {case_name(c)} (see {d0})")
    return d0


def build_tb(d, lanes, files):
    """The whole receiver bench with the RTL files of a mutant, for one Lanes parameter."""
    obj = os.path.join(d, f"obj_l{lanes}")
    cmd = [VERILATOR, "--binary", "--timing", "-j", "4", "-O2", "-Wno-fatal", "-Wno-lint",
           "-Wno-style", "-Wno-TIMESCALEMOD", "+define+BOW_CDC_JITTER",
           "--top-module", "tb_bow_csi2rx", *PARAMS[lanes], "-Mdir", obj, "-o", "Vtb_bow_csi2rx",
           "-F", os.path.join(REPO, "hw", "ip", "common", "common.f"),
           "-F", os.path.join(REPO, "hw", "ip", "bus", "bus.f"), *files,
           os.path.join(HERE, "csi2_tx_model.sv"),
           os.path.join(REPO, "hw", "ip", "dphy_rx", "dv", "bow_ppi_chk.sv"),
           os.path.join(REPO, "hw", "ip", "dphy_rx", "dv", "bow_afe_chk.sv"),
           os.path.join(HERE, "tb_bow_csi2rx.sv")]
    # one retry, as mutants_ppi.py (Verilator 5.020 can abort at its exit after a good build)
    for _ in range(2):
        if run(cmd, os.path.join(d, f"build_l{lanes}.log"), env=VERILATOR_ENV) == 0:
            return os.path.join(obj, "Vtb_bow_csi2rx")
    return None


def one(mutant, build, cases, every=False):
    """Build the mutant and run the cases until one fails (every: all of them)."""
    name, subs = mutant
    d = os.path.join(build, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "rtl"))
    files = []
    for src, f in FILES:
        with open(os.path.join(src, f)) as fh:
            text = fh.read()
        for sf, old, new, n in subs:
            if sf == f:
                if text.count(old) != n:
                    return name, f"BAD: text found {text.count(old)} times in {f}, not {n}"
                text = text.replace(old, new)
        files.append(os.path.join(d, "rtl", f))
        with open(files[-1], "w") as fh:
            fh.write(text)
    bins = {}
    for lanes in sorted({c[2] for c in CASES}):
        bins[lanes] = build_tb(d, lanes, files)
        if bins[lanes] is None:
            return name, f"BAD: does not build (see {d}/build_l{lanes}.log)"
    killers = []
    for c in CASES:
        cd = os.path.join(d, case_name(c))
        shutil.copytree(os.path.join(cases, case_name(c)), cd)
        rc = run([bins[c[2]], "+DIR=" + cd, "+verilator+seed+1"], os.path.join(cd, "sim.log"),
                 TIMEOUT)
        if rc != 0 or run([sys.executable, MODEL, "check", cd], os.path.join(cd, "check.log")) != 0:
            killers.append(case_name(c) + (" (timeout)" if rc == "timeout" else ""))
            if not every:
                break
    if not killers:
        return name, "SURVIVED"
    return name, f"killed by {', '.join(killers)}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--every", action="store_true", help="run every case (which ones kill it)")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    sel = [m for m in MUTANTS if not args.names or m[0] in args.names]
    unknown = set(args.names) - {m[0] for m in MUTANTS}
    if unknown:
        raise SystemExit(f"unknown mutants: {' '.join(sorted(unknown))}")
    os.makedirs(args.build, exist_ok=True)
    cases = gen_cases(args.build)
    name, res = one(("none", []), args.build, cases)
    if res != "SURVIVED":
        print(f"mutants_rx: the unchanged RTL fails: {res}")
        return 1
    print(f"mutants_rx: unchanged RTL passes {len(CASES)} cases; {len(sel)} mutants")
    killed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for name, res in ex.map(lambda m: one(m, args.build, cases, args.every), sel):
            print(f"  {name:32s} {res}")
            killed += res.startswith("killed")
    print(f"mutants_rx: {killed}/{len(sel)} killed")
    return 0 if killed == len(sel) else 1


if __name__ == "__main__":
    sys.exit(main())
