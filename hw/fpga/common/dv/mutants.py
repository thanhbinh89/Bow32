#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Mutation check of the DDR pad / clock tests (`make mutants`, not in `make test`).

Each mutant is a copy of bow_ddr_io_xilinx.sv or bow_ddr_clk_xusp.sv with one
deliberate bug (a text substitution of the current file, so the mutants follow
the RTL). It is built and run with the run-ddr-io / run-ddr-clk targets of the
Makefile in its own directory (DDR_IO_DIR / DDR_CLK_DIR = <build>/<name>, the
copy given as DDR_IO_RTL / DDR_CLK_RTL) and must FAIL: a mutant that passes
means a hole in the testbench.

    mutants.py --build <dir> [--jobs N] [name ...]

Exit code 0 when every selected mutant was killed (its test printed FAIL).
"""
import argparse
import concurrent.futures
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, "..", "rtl"))
FILES = {"io": "bow_ddr_io_xilinx.sv", "clk": "bow_ddr_clk_xusp.sv"}
TESTS = {"io": ("run-ddr-io", "IO_CFG", "tb_bow_ddr_io_xilinx"),
         "clk": ("run-ddr-clk", "CLK_CFG", "tb_bow_ddr_clk_xusp")}

# name, testbench (io | clk), configuration, file (io | clk), old text, new
# text, occurrence of old text to replace (1 = first)
MUTANTS = [
    ("io_cmd_noprev", "io", "card", "io",
     ".D1 (cmd_prev_q[i]),", ".D1 (cmd_cur[i]),", 1),
    ("io_cmd_idle_cs", "io", "card", "io",
     "{BankPins{1'b0}}, 4'b1111, 2'b00}", "{BankPins{1'b0}}, 4'b1110, 2'b00}", 1),
    ("io_dq_noinv", "io", "card", "io",
     ".IS_C_INVERTED (1'b1),", ".IS_C_INVERTED (1'b0),", 1),
    ("io_iddr_same_edge", "io", "card", "io",
     '.DDR_CLK_EDGE   ("SAME_EDGE_PIPELINED"),', '.DDR_CLK_EDGE   ("SAME_EDGE"),', 1),
    ("io_dqsn_noinv", "io", "card", "io",
     "dqs_n_q <= ~dqs_d[l];", "dqs_n_q <= dqs_d[l];", 1),
    ("io_dq_t_late", "io", "card", "io",
     "dq_t_q  <= {DqBits{~io_o_i.dq_oe}};", "dq_t_q  <= {DqBits{~io_o_i.dq_oe}} | dq_t_q;", 1),
    ("io_dqs_t_from_dq", "io", "card", "io",
     "dqs_t_q <= ~io_o_i.dqs_oe[Lanes-1:0];", "dqs_t_q <= {Lanes{~io_o_i.dq_oe}};", 1),
    ("io_dqs_wrong_clk", "io", "card", "io",
     ".C  (wclk_i),", ".C  (clk_i),", 1),
    ("io_dqs_posedge_retime", "io", "card", "io",
     "always_ff @(negedge clk_i) begin", "always_ff @(posedge clk_i) begin", 1),
    ("io_ls_polarity", "io", "x16", "io",
     "io_o_i.ls_dir_dqs ^ DirWrite, io_o_i.ls_dir_dq ^ DirWrite",
     "io_o_i.ls_dir_dqs, io_o_i.ls_dir_dq", 1),
    ("io_lb_sel", "io", "lb", "io",
     "assign lb_sel = Loopback && lb_en_i;", "assign lb_sel = Loopback;", 1),
    ("io_lb_dm", "io", "lb16", "io",
     "assign dm1 = io_o_i.dm[0][l] & ~lb_sel;", "assign dm1 = io_o_i.dm[0][l];", 1),
    ("clk_wclk90_phase", "clk", "133", "clk",
     ".CLKOUT1_PHASE        (90.0),", ".CLKOUT1_PHASE        (0.0),", 1),
    ("clk_ps_port_swap", "clk", "133", "clk",
     ".PSEN         (ps_en_i),", ".PSEN         (wps_en_i),", 1),
    ("clk_ddr_clk_moves", "clk", "133", "clk",
     '.CLKOUT1_USE_FINE_PS  ("FALSE"),', '.CLKOUT1_USE_FINE_PS  ("TRUE"),', 1),
    ("clk_locked_glitch", "clk", "133", "clk",
     "assign locked_ddr_o = locked_a & locked_w & locked_b;",
     "assign locked_ddr_o = locked_a & locked_w & locked_b & ~wps_done_o;", 1),
    # controller clock (CK / 4): off the ddr_clk edges, wrong divide, moves
    # with the write phase (45 deg = T/2; 90 deg = T would still be legal)
    ("clk_sys_phase", "clk", "133", "clk",
     ".CLKOUT3_PHASE        (0.0),", ".CLKOUT3_PHASE        (45.0),", 1),
    ("clk_sys_divide", "clk", "133", "clk",
     "localparam int unsigned DdrSysDivide = 4 * DdrDivide;",
     "localparam int unsigned DdrSysDivide = 2 * DdrDivide;", 1),
    ("clk_sys_fine_ps", "clk", "125", "clk",
     '.CLKOUT3_USE_FINE_PS  ("FALSE"),', '.CLKOUT3_USE_FINE_PS  ("TRUE"),', 1),
]


def make_mutant(path, old, new, nth):
    """Copy of the RTL file with the nth occurrence of old replaced by new."""
    with open(os.path.join(RTL, FILES[path])) as fh:
        text = fh.read()
    pos = -1
    for _ in range(nth):
        pos = text.find(old, pos + 1)
        if pos < 0:
            return None
    return text[:pos] + new + text[pos + len(old):]


def run(build, mutant):
    name, tb, cfg, path, old, new, nth = mutant
    target, cfg_var, top = TESTS[tb]
    mdir = os.path.join(build, name)
    os.makedirs(mdir, exist_ok=True)
    text = make_mutant(path, old, new, nth)
    if text is None:
        return name, "ERROR", "the mutation does not apply to the current RTL"
    src = os.path.join(mdir, FILES[path])
    with open(src, "w") as fh:
        fh.write(text)
    var = "DDR_IO_RTL" if path == "io" else "DDR_CLK_RTL"
    cmd = ["make", "-C", HERE, "--no-print-directory", target, cfg_var + "=" + cfg, "SEED=1",
           "DDR_IO_DIR=" + mdir, "DDR_CLK_DIR=" + mdir, var + "=" + src]
    env = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
    with open(os.path.join(mdir, "make.log"), "w") as log:
        rc = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
    sim_log = os.path.join(mdir, cfg, "seed1" if tb == "io" else "run", "sim.log")
    result = ""
    if os.path.exists(sim_log):
        with open(sim_log) as fh:
            for line in fh:
                if line.startswith(top + ": PASS") or line.startswith(top + ": FAIL"):
                    result = line.strip()
    if rc != 0 and ": FAIL" in result:
        return name, "killed", result
    if rc == 0 and ": PASS" in result:
        return name, "SURVIVED", result
    return name, "ERROR", "no result, see " + os.path.join(mdir, "make.log")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--build", required=True, help="output directory")
    ap.add_argument("--jobs", type=int, default=4, help="mutants run in parallel")
    ap.add_argument("names", nargs="*", help="mutants to run (default: all)")
    args = ap.parse_args()
    sel = [m for m in MUTANTS if not args.names or m[0] in args.names]
    unknown = set(args.names) - {m[0] for m in MUTANTS}
    if unknown or not sel:
        print("unknown mutant(s): %s; known: %s" % (" ".join(sorted(unknown)),
                                                    " ".join(m[0] for m in MUTANTS)))
        return 2
    build = os.path.abspath(args.build)
    bad = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        for name, verdict, detail in ex.map(lambda m: run(build, m), sel):
            print("%-24s %-8s %s" % (name, verdict, detail))
            sys.stdout.flush()
            if verdict != "killed":
                bad += 1
    print("mutants: %d of %d killed" % (len(sel) - bad, len(sel)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
