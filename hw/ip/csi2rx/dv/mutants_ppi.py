#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Mutation check of the PPI bench (`make mutants-ppi`, not in `make test`).

Each mutant is a copy of hw/ip/csi2rx/rtl with one change to the controller (bow_csi2rx and
its blocks) or to the flat-port wrapper (bow_csi2rx_ppi_flat): text substitutions of the
current files, so the mutants follow the RTL. It is built with tb_csi2rx_ppi.sv and
bow_ppi_bfm.sv and must make one PPI case fail (simulation or model check) in at least one
timing: a mutant that passes every case means a hole in the bench. The cases are generated
once with tools/csi2/csi2_model.py and first run on the RTL as it is (they must all pass).

    mutants_ppi.py --build <dir> [--jobs N] [--every] [name ...]

Exit code 0 when every selected mutant was killed.
"""
import argparse
import concurrent.futures
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
RTL = os.path.join(REPO, "hw", "ip", "csi2rx", "rtl")
MODEL = os.path.join(REPO, "tools", "csi2", "csi2_model.py")
VERILATOR = os.environ.get("VERILATOR", "verilator")
TIMEOUT = 300    # seconds per simulation
# csi2rx.f in order, then the wrapper (not in csi2rx.f)
FILES = ["bow_csi2rx_pkg.sv", "bow_ppi_err_rx.sv", "bow_csi2_lane_merge.sv", "bow_csi2_packet.sv",
         "bow_csi2_unpack.sv", "bow_csi2rx_out.sv", "bow_csi2_capture.sv",
         "bow_csi2rx_regs.sv", "bow_csi2rx.sv", "bow_mipi_rx.sv", "bow_csi2rx_ppi_flat.sv"]
PARAMS = {1: ["-GLanes=1"], 2: ["-GLanes=2"], 4: ["-GLanes=4", "-GFifoDepth=512"]}
MERGE, PACKET, CTRL, FLAT = ("bow_csi2_lane_merge.sv", "bow_csi2_packet.sv", "bow_csi2rx.sv",
                             "bow_csi2rx_ppi_flat.sv")
ERRRX = "bow_ppi_err_rx.sv"

# PPI cases: (timing, test, lanes, Lanes parameter, extra options), seed 1
CASES = [(m, t, l, d, o) for m in ("bow", "std") for t, l, d, o in
         [("skew", 2, 2, ()), ("skew", 4, 4, ()), ("loss", 1, 1, ()), ("loss", 2, 2, ()),
          ("loss", 4, 4, ()), ("deskew", 2, 2, ()), ("deskew", 4, 4, ()),
          ("random", 2, 2, ("--errors",)), ("random", 4, 4, ("--errors",)), ("clkstop", 2, 2, ()),
          ("lpmask", 2, 2, ())]] + \
        [("bow", "gaps", 2, 2, ()), ("bow", "lpmask", 1, 1, ())]

# name, [(file, old text, new text, occurrences)]: every old text must occur that often
MUTANTS = [
    # lane merge: the limit of the lane skew (6 byte clocks merged, 7 SKEW) one lower: the
    # overflow check before the first word takes a lane FIFO with 7 bytes as full
    ("merge_limit_5", [(MERGE, "  logic [Lanes-1:0]      act, arm_q, sot_q, push, full, empty;",
                        "  logic [Lanes-1:0]      act, arm_q, sot_q, push, full, empty, almost;\n"
                        "  logic [Lanes-1:0][3:0] lvl;", 1),
                       (MERGE, "  assign ovf     = |(push & full) && !started_q;",
                        "  assign ovf     = |(push & almost) && !started_q;", 1),
                       (MERGE, "    assign push[l] = act[l] && in_burst_q && valid_i[l] && (sot_q[l] || sot_i[l]);",
                        "    assign push[l] = act[l] && in_burst_q && valid_i[l] && (sot_q[l] || sot_i[l]);\n"
                        "    assign almost[l] = (lvl[l] >= 4'd7);", 1),
                       (MERGE, "      .level_o ()", "      .level_o (lvl[l])", 1)]),
    ("merge_fifo_16", [(MERGE, "      .Depth (8)", "      .Depth (16)", 1)]),
    ("merge_valid_ignored", [(MERGE, "in_burst_q && valid_i[l] && (sot_q[l] || sot_i[l]);",
                              "in_burst_q && (sot_q[l] || sot_i[l]);", 1)]),
    ("merge_eob_any_lane", [(MERGE, "assign all_low = ~|(arm_i & act);",
                             "assign all_low = ~&(arm_i | ~act);", 1)]),
    ("merge_rise_all_lanes", [(MERGE, "assign rise    = |(arm_i & ~arm_q & act);",
                               "assign rise    = &((arm_i & ~arm_q) | ~act);", 1)]),
    # packet layer: the CRC byte count of a long packet; no CRC error flag (tuser[1]) when the
    # last word holds payload bytes (4 lanes, WC mod 4 = 1 or 2: test loss)
    ("crc_one_byte", [(PACKET, "rem_q      <= {1'b0, wc} + 17'd2;",
                       "rem_q      <= {1'b0, wc} + 17'd1;", 2)]),
    ("crc_err_lpay_off", [(PACKET, "err_dly_q <= acc_q && ((crc_n != '0) || fmt_q);",
                           "err_dly_q <= acc_q && fmt_q;", 1)]),
    # no EXTRA event (bytes after a packet: test clkstop). Small enough for Verilator's
    # single-file build with Lanes = 1, which runs python3 (VERILATOR_ENV below)
    ("extra_off", [(PACKET, "if ((extra_i != '0) && !xev_q && (xcnt_q > {1'b0, extra_i})) begin",
                    "if (1'b0) begin", 1)]),
    # lost burst marking at the LP level: the OR of the changes of the ErrControl /
    # ErrControlClk gray counters on the PPI (step 6; the D-PHY masks them since step 4):
    # without ErrControlClk, lane 0 only, masked by the controller's own enables again (lpmask:
    # an error on a lane CTRL disabled)
    ("lost_burst_no_clk", [(CTRL, "    lperr_gray[0] = ppi_lp_clk_i.err_control;",
                            "    lperr_gray[0] = 2'b00;", 1)]),
    ("lost_burst_lane0_only", [(CTRL, "lperr_gray[1 + l] = ppi_lp_i[l].err_control;",
                                "lperr_gray[1 + l] = ppi_lp_i[0].err_control;", 1)]),
    ("lost_burst_lane_mask", [(CTRL, "  assign lp_err = |lperr_ev;",
                               "  assign lp_err = |(lperr_ev & lane_en_sys);", 1)]),
    ("lost_burst_off", [(CTRL, "    else if (lpl_ev && (lpl_req_q == lpl_ack_s))   lpl_req_q <= ~lpl_req_q;",
                         "    else if (1'b0)                                 lpl_req_q <= ~lpl_req_q;", 1)]),
    # the pending loss cleared by an end of burst, not by the next packet start (test loss:
    # LP loss, a deskew burst on every lane, then the line)
    ("lost_burst_pending_cleared_at_eob", [(CTRL, "    else if (lm_sop)                  lpl_pend_q <= 1'b0;",
                                            "    else if (lm_eob)                  lpl_pend_q <= 1'b0;", 1)]),
    ("sync_error_no_drop", [(CTRL, "lm_skew || (|al_sync_err) ||", "lm_skew ||", 1)]),
    ("deskew_counted_on_last_lane", [(CTRL, "  assign dsk_ev = al_deskew[0] & ~dsk_last_q & ~stale_q[0];",
                                      "  assign dsk_ev = al_deskew[Lanes-1] & ~stale_q[Lanes-1];", 1)]),
    # RxSkewCalHS counted in every cycle it is high, not at its rising edge (step 6: a level
    # from the D-PHY of Bow32 and from a PG202 like PHY)
    ("deskew_level_counted", [(CTRL, "  assign dsk_ev = al_deskew[0] & ~dsk_last_q & ~stale_q[0];",
                               "  assign dsk_ev = al_deskew[0] & ~stale_q[0];", 1)]),
    # the PPI error counters' sampler (bow_ppi_err_rx): a change of bit 0 only taken as an
    # error (the steps 01 -> 11 and 10 -> 00 are lost)
    ("lp_err_bit0_only", [(ERRRX, "      ev_o[i]    = (gray_s[i] != last_q[i]);",
                           "      ev_o[i]    = (gray_s[i][0] != last_q[i][0]);", 1)]),
    # flat wrapper (standard PHY)
    ("flat_no_byte_delay", [(FLAT, "    assign ppi_hs[l].rx_valid_hs     = valid_q[l];",
                             "    assign ppi_hs[l].rx_valid_hs     = rx_valid_hs_i[l];", 1),
                            (FLAT, "    assign ppi_hs[l].rx_data_hs      = data_q[l];",
                             "    assign ppi_hs[l].rx_data_hs      = rx_data_hs_i[l];", 1),
                            (FLAT, "    assign ppi_hs[l].rx_sync_hs      = sync_q[l];",
                             "    assign ppi_hs[l].rx_sync_hs      = rx_sync_hs_i[l];", 1)]),
    ("flat_no_active_hold", [(FLAT, "rx_active_hs_i[l] | act_q[l] | act_q2[l];",
                              "rx_active_hs_i[l];", 1)]),
    # the wrapper's ErrControl gray counters: lane 0's for every lane (std lpmask, loss)
    ("flat_err_lane0_only", [(FLAT, "    .ev_i   (err_control_i),",
                              "    .ev_i   ({Lanes{err_control_i[0]}}),", 1)]),
]


# Verilator gets the environment without the Python settings of this interpreter: a python3
# wrapper (one that sets PYTHONHOME / PYTHONPATH for its own Python) would otherwise hand
# them to the python3 that verilated.mk runs for a single-file build (verilator_includer),
# which then fails on a stdlib of another version
VERILATOR_ENV = {k: v for k, v in os.environ.items() if k not in ("PYTHONHOME", "PYTHONPATH")}


def run(cmd, log, timeout=None, cwd=None, env=None):
    with open(log, "w") as fh:
        try:
            return subprocess.call(cmd, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout,
                                   cwd=cwd, env=env)
        except subprocess.TimeoutExpired:
            return "timeout"


def case_name(c):
    m, t, l, d, o = c
    return f"{m}_{t}_l{l}of{d}{''.join(x.strip('-')[0] for x in o)}"


def gen_cases(build):
    """Generate every case once."""
    d0 = os.path.join(build, "cases")
    os.makedirs(d0, exist_ok=True)
    for c in CASES:
        m, t, l, d, o = c
        argv = [sys.executable, MODEL, "gen", os.path.join(d0, case_name(c)), "--ppi", m,
                "--test", t, "--seed", "1", "--lanes", str(l), "--dut-lanes", str(d), *o]
        if d == 4:
            argv += ["--fifo-depth", "512"]
        if run(argv, os.path.join(d0, case_name(c) + ".gen.log")) != 0:
            raise SystemExit(f"cannot generate {case_name(c)} (see {d0})")
    return d0


def build_tb(d, lanes, files):
    """The PPI bench with the RTL files of a mutant, for one Lanes parameter."""
    obj = os.path.join(d, f"obj_l{lanes}")
    cmd = [VERILATOR, "--binary", "--timing", "-j", "4", "-O2", "-Wno-fatal", "-Wno-lint",
           "-Wno-style", "-Wno-TIMESCALEMOD", "+define+BOW_CDC_JITTER",
           "--top-module", "tb_csi2rx_ppi", *PARAMS[lanes], "-Mdir", obj, "-o", "Vtb_csi2rx_ppi",
           "-F", os.path.join(REPO, "hw", "ip", "common", "common.f"),
           "-F", os.path.join(REPO, "hw", "ip", "bus", "bus.f"),
           "-F", os.path.join(REPO, "hw", "ip", "dphy_rx", "dphy_rx.f"), *files,
           *[os.path.join(REPO, "hw", "fpga", "common", "rtl", f)
             for f in ("bow_dphy_dly_xusp.sv", "bow_dphy_dly_xphy.sv")],
           os.path.join(HERE, "csi2_tx_model.sv"), os.path.join(HERE, "bow_ppi_bfm.sv"),
           os.path.join(HERE, "tb_csi2rx_ppi.sv")]
    # one retry: under load Verilator 5.020 can abort at its exit ("attempted to destroy locked
    # Thread Pool") after a good build; a real build error fails twice
    for _ in range(2):
        if run(cmd, os.path.join(d, f"build_l{lanes}.log"), env=VERILATOR_ENV) == 0:
            return os.path.join(obj, "Vtb_csi2rx_ppi")
    return None


def one(mutant, build, cases, every=False):
    """Build the mutant and run the cases until one fails (every: all of them). Returns
    (name, result)."""
    name, subs = mutant
    d = os.path.join(build, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "rtl"))
    for f in FILES:
        with open(os.path.join(RTL, f)) as fh:
            text = fh.read()
        for sf, old, new, n in subs:
            if sf == f:
                if text.count(old) != n:
                    return name, f"BAD: text found {text.count(old)} times in {f}, not {n}"
                text = text.replace(old, new)
        with open(os.path.join(d, "rtl", f), "w") as fh:
            fh.write(text)
    files = [os.path.join(d, "rtl", f) for f in FILES]
    bins = {}
    for lanes in sorted({c[3] for c in CASES}):
        bins[lanes] = build_tb(d, lanes, files)
        if bins[lanes] is None:
            return name, f"BAD: does not build (see {d}/build_l{lanes}.log)"
    killers = []
    for c in CASES:
        cd = os.path.join(d, case_name(c))
        shutil.copytree(os.path.join(cases, case_name(c)), cd)
        rc = run([bins[c[3]], "+DIR=" + cd, "+verilator+seed+1"], os.path.join(cd, "sim.log"),
                 TIMEOUT)
        if rc != 0 or run([sys.executable, MODEL, "check", cd], os.path.join(cd, "check.log")) != 0:
            killers.append(case_name(c) + (" (timeout)" if rc == "timeout" else ""))
            if not every:
                break
    if not killers:
        return name, "SURVIVED"
    if not every:
        return name, f"killed by {killers[0]}"
    modes = [m for m in ("bow", "std") if any(k.startswith(m) for k in killers)]
    return name, f"killed in {' and '.join(modes)}: {len(killers)} cases ({', '.join(killers)})"


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
    # the RTL as it is must pass every case
    name, res = one(("none", []), args.build, cases)
    if res != "SURVIVED":
        print(f"mutants_ppi: the unchanged RTL fails: {res}")
        return 1
    print(f"mutants_ppi: unchanged RTL passes {len(CASES)} cases; {len(sel)} mutants")
    killed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for name, res in ex.map(lambda m: one(m, args.build, cases, args.every), sel):
            print(f"  {name:32s} {res}")
            killed += res.startswith("killed")
    print(f"mutants_ppi: {killed}/{len(sel)} killed")
    return 0 if killed == len(sel) else 1


if __name__ == "__main__":
    sys.exit(main())
