#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Mutation check of the IP testbench against the fixes of the PR #6 reviews
(`make mutants`, not in `make test`: 18 builds).

Each mutant is a copy of hw/ip/{hyperram,common,bus} with one fix undone (a
text substitution of the current RTL, so the mutants follow it). It is built
and run in one configuration with this directory's Makefile (`build`, then
`c/<cfg>.1`, in the copy, BUILD = <build>/<name>/out) and must FAIL: a mutant
that passes means a check of tb_bow_hyperram (mostly section 9b) no longer
guards its fix.

    mutants.py --build <dir> [--jobs N] [name ...]

Exit code 0 when every selected mutant was killed (its run printed FAIL).
"""
import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
CTRL = "rtl/bow_hyperram_ctrl.sv"
REGS = "rtl/bow_hyperram_regs.sv"
WIN = "rtl/bow_hyperram_win.sv"

# name, configuration, edits [(file under hw/ip/hyperram, old text, new text)]
MUTANTS = [
    ("stage_race", "direct", [(CTRL, "    if (est_q == EStage) begin", "    if (est_q == EStage && !x_sel) begin")]),
    ("bist_faddr", "direct", [("rtl/bow_hyperram_bist.sv", "faddr_q <= chk_a_q;", "faddr_q <= base_q + chk_a_q;")]),
    ("bist_go_code", "direct", [(CTRL, "                  xcode_err_q <= ErrArg;     // a run is in progress\n", "")]),
    ("ps_code", "direct", [(CTRL, "? ErrNone : (xps_ran_q ? ErrPs : ErrArg);", "? ErrNone : ErrNone;")]),
    ("cr1_hw_reset", "direct", [(CTRL, "        cr1_q      <= {Cr1Default[15:2], cr1_q[1:0]};", "        cr1_q      <= Cr1Default;")]),
    ("cr1_dpd_wake", "direct", [(CTRL, "          cr1_q <= {Cr1Default[15:2], cr1_q[1:0]};", "          cr1_q <= Cr1Default;")]),
    ("done_before_recovery", "direct", [(CTRL, "end else if (est_q == EIdle && pwr_q != PwrWait) begin",
                                         "end else if (est_q == EIdle) begin")]),
    ("wake_at_pulse_start", "lb", [(CTRL, "      end else if (is_wake && at_end) begin",
                                    "      end else if (run && is_wake && c_q == 16'd2) begin")]),
    ("wr_err_posted", "lb", [(WIN, "  assign ev_wr_err_o  = post_refused;", "  assign ev_wr_err_o  = 1'b0;")]),
    ("posted_refusal_line", "direct", [(WIN, "      if (inval_i || post_refused) begin", "      if (inval_i) begin")]),
    ("inval_deferred", "lb", [
        (WIN, "  logic                             flush_pend_q;\n",
         "  logic                             flush_pend_q;\n  logic                             inval_pend_q;\n"),
        (WIN, "      flush_pend_q <= 1'b0;\n      pout_q", "      flush_pend_q <= 1'b0;\n      inval_pend_q <= 1'b0;\n      pout_q"),
        (WIN, "      if (inval_i || post_refused) begin\n        lv_q <= '0;\n        wv_q <= '0;\n      end\n",
         "      if (inval_i) inval_pend_q <= 1'b1;\n      if (post_refused) begin\n        lv_q <= '0;\n        wv_q <= '0;\n      end\n"),
        (WIN, "      // an abort by a lost clock while the link is up: dead as well\n",
         "      if (inval_pend_q && !fill_q && !start_rd) begin\n        lv_q <= '0;\n        wv_q <= '0;\n"
         "        inval_pend_q <= 1'b0;\n      end\n      // an abort by a lost clock while the link is up: dead as well\n"),
    ]),
    ("not_ready_on_reset", "direct", [("rtl/bow_hyperram.sv", ".clk_lost_i     (!clk_ok && lnk_up),", ".clk_lost_i     (!clk_ok),")]),
    ("cmd_in_reset_dropped", "direct", [(REGS, "ev_set[StCmdErr]     = cerr_ev || cmd_dead_ev;", "ev_set[StCmdErr]     = cerr_ev;")]),
    ("err_code_in_reset", "direct", [(REGS, "(lnk_up_q && !dead_code_q) ? ecode_q : ErrDisable}", "ecode_q}")]),
    ("err_code_after_reset", "direct", [(REGS, "      if (cmd_wr) dead_code_q <= !lnk_up_q;", "      dead_code_q <= 1'b0;")]),
    ("cmd_first_cycle", "direct", [(REGS, "      if (cmd_wr && lnk_up_q) begin", "      if (cmd_wr) begin")]),
    ("power_sync_reset", "direct", [
        (REGS, "      q_val_q  <= {32'd0, 2'd3, Cr1Default, Cr0Default};", "      q_val_q  <= {32'd0, 2'd0, Cr1Default, Cr0Default};"),
        (REGS, "      if (qwarm_q != 2'd3)       qwarm_q <= qwarm_q + 2'd1;\n      else if (q_prev_q == q_s)  q_val_q <= q_s;",
         "      if (q_prev_q == q_s)  q_val_q <= q_s;"),
    ]),
    ("phy_reset_drives", "card", [("rtl/bow_hyperram_phy.sv", "      io_q <= HR_IO_OUT_RST;", "      io_q <= HR_IO_OUT_IDLE;")]),
]


def run(build, mutant):
    name, cfg, edits = mutant
    root = os.path.join(build, name)
    shutil.rmtree(root, ignore_errors=True)   # no stale log may decide the verdict
    for d in ("hyperram", "common", "bus"):
        shutil.copytree(os.path.join(REPO, "hw", "ip", d), os.path.join(root, "hw", "ip", d),
                        ignore=shutil.ignore_patterns("build", "obj_*"))
    for f, old, new in edits:
        p = os.path.join(root, "hw", "ip", "hyperram", f)
        with open(p) as fh:
            text = fh.read()
        if text.count(old) != 1:
            return name, cfg, "ERROR", f"{f}: the mutation does not apply to the current RTL"
        with open(p, "w") as fh:
            fh.write(text.replace(old, new))
    out = os.path.join(root, "out")
    dv = os.path.join(root, "hw", "ip", "hyperram", "dv")
    env = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
    with open(os.path.join(root, "make.log"), "w") as log:
        rc = subprocess.call(["make", "-C", dv, "--no-print-directory", "build", "IP_CONFIGS=" + cfg,
                              "BUILD=" + out], stdout=log, stderr=subprocess.STDOUT, env=env)
        if rc != 0:
            return name, cfg, "ERROR", "build failed, see " + os.path.join(root, "make.log")
        subprocess.call(["make", "-C", dv, "--no-print-directory", f"c/{cfg}.1", "BUILD=" + out],
                        stdout=log, stderr=subprocess.STDOUT, env=env)
    sim_log = os.path.join(out, f"{cfg}_s1", "sim.log")
    verdict, first = "", ""
    if os.path.exists(sim_log):
        with open(sim_log) as fh:
            for line in fh:
                if not first and "ERROR" in line:
                    first = re.sub(r"^.*?ERROR\s*", "", line.strip())[:110]
                if line.startswith("tb_bow_hyperram: PASS"):
                    verdict = "SURVIVED"
                elif line.startswith("tb_bow_hyperram: FAIL"):
                    verdict = "killed"
    if not verdict:
        return name, cfg, "ERROR", "no result, see " + os.path.join(root, "make.log")
    return name, cfg, verdict, first


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--build", required=True, help="output directory")
    ap.add_argument("--jobs", type=int, default=4, help="mutants run in parallel")
    ap.add_argument("names", nargs="*", help="mutants to run (default: all)")
    args = ap.parse_args()
    sel = [m for m in MUTANTS if not args.names or m[0] in args.names]
    unknown = set(args.names) - {m[0] for m in MUTANTS}
    if unknown or not sel:
        print("unknown mutant(s): %s; known: %s" % (" ".join(sorted(unknown)), " ".join(m[0] for m in MUTANTS)))
        return 2
    build = os.path.abspath(args.build)
    bad = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        for name, cfg, verdict, detail in ex.map(lambda m: run(build, m), sel):
            print("%-22s %-7s %-8s %s" % (name, cfg, verdict, detail))
            sys.stdout.flush()
            if verdict != "killed":
                bad += 1
    print("hyperram_dv mutants: %d of %d killed" % (len(sel) - bad, len(sel)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
