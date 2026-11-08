#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Mutation check of the DDR and HyperRAM pad / clock tests (`make mutants`, not
in `make test`).

Each mutant is a copy of bow_ddr_io_xilinx.sv, bow_ddr_clk_xusp.sv,
bow_hyperram_io_xilinx.sv or bow_hyperram_clk_xusp.sv with one deliberate bug
(a text substitution of the current file, so the mutants follow the RTL). It is
built and run with the run-ddr-io / run-ddr-clk / run-hr-io targets of the
Makefile in its own directory (DDR_IO_DIR / DDR_CLK_DIR / HR_IO_DIR =
<build>/<name>, the copy given as DDR_IO_RTL / DDR_CLK_RTL / HR_IO_RTL /
HR_CLK_RTL) and must FAIL: a mutant that passes means a hole in the testbench.
The HyperRAM mutants (hr_*) all run in tb_bow_hyperram_io_xilinx, which
instantiates both HyperRAM wrappers.

    mutants.py --build <dir> [--jobs N] [name ...]

Exit code 0 when every selected mutant was killed (its test printed FAIL).
"""
import argparse
import concurrent.futures
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, "..", "rtl"))
FILES = {"io": "bow_ddr_io_xilinx.sv", "clk": "bow_ddr_clk_xusp.sv",
         "hrio": "bow_hyperram_io_xilinx.sv", "hrclk": "bow_hyperram_clk_xusp.sv"}
RTL_VAR = {"io": "DDR_IO_RTL", "clk": "DDR_CLK_RTL", "hrio": "HR_IO_RTL", "hrclk": "HR_CLK_RTL"}
TESTS = {"io": ("run-ddr-io", "IO_CFG", "tb_bow_ddr_io_xilinx"),
         "clk": ("run-ddr-clk", "CLK_CFG", "tb_bow_ddr_clk_xusp"),
         "hr": ("run-hr-io", "HR_IO_CFG", "tb_bow_hyperram_io_xilinx")}

# name, testbench (io | clk | hr), configuration, file (io | clk | hrio |
# hrclk), old text, new text, occurrence of old text to replace (1 = first)
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
    # HyperRAM pads and clocks (tb_bow_hyperram_io_xilinx: card, direct, lb)
    ('hr_io_dq_noinv', "hr", 'card', 'hrio',
     ".IS_C_INVERTED (1'b1),", ".IS_C_INVERTED (1'b0),", 1),
    ('hr_io_rwds_noinv', "hr", 'card', 'hrio',
     ".IS_C_INVERTED (1'b1),", ".IS_C_INVERTED (1'b0),", 2),
    ('hr_io_dq_byte_b_twice', "hr", 'card', 'hrio',
     '.D1 (dq_d[0][i]),', '.D1 (dq_d[1][i]),', 1),
    ('hr_io_rwds_d_swap', "hr", 'card', 'hrio',
     '.D1 (rw_d[0]),', '.D1 (rw_d[1]),', 1),
    ('hr_io_dq_t_polarity', "hr", 'card', 'hrio',
     'dq_t_q <= {8{~io_o_i.dq_oe}};', 'dq_t_q <= {8{io_o_i.dq_oe}};', 1),
    ('hr_io_rw_t_from_dq', "hr", 'card', 'hrio',
     'rw_t_q <= ~io_o_i.rwds_oe;', 'rw_t_q <= ~io_o_i.dq_oe;', 1),
    ('hr_io_dq_t_sticky', "hr", 'card', 'hrio',
     'dq_t_q <= {8{~io_o_i.dq_oe}};', 'dq_t_q <= {8{~io_o_i.dq_oe}} | dq_t_q;', 1),
    ('hr_io_dq_t_init0', "hr", 'direct', 'hrio',
     "logic [7:0] dq_t_q = '1;", "logic [7:0] dq_t_q = '0;", 1),
    ('hr_io_ckn_d2', "hr", 'card', 'hrio',
     ".D2 (1'b1),", ".D2 (1'b0),", 1),
    ('hr_io_ck_free', "hr", 'card', 'hrio',
     '.D1 (io_o_i.ck_en),', ".D1 (1'b1),", 1),
    ('hr_io_ckn_srval', "hr", 'card', 'hrio',
     ".SRVAL      (1'b1)", ".SRVAL      (1'b0)", 1),
    ('hr_io_cs_srval', "hr", 'card', 'hrio',
     ".SRVAL      (1'b1)", ".SRVAL      (1'b0)", 2),
    ('hr_io_rst_srval', "hr", 'direct', 'hrio',
     ".SRVAL      (1'b1)", ".SRVAL      (1'b0)", 3),
    ('hr_io_dq_srval', "hr", 'lb', 'hrio',
     ".SRVAL         (1'b0)", ".SRVAL         (1'b1)", 1),
    ('hr_io_rst_d1_cs', "hr", 'card', 'hrio',
     '.D1 (io_o_i.rst_n),', '.D1 (io_o_i.cs_n),', 1),
    ('hr_io_ls_idle', "hr", 'card', 'hrio',
     "localparam logic [2:0] LsIdle = 3'b001;", "localparam logic [2:0] LsIdle = 3'b000;", 1),
    ('hr_io_ls_order', "hr", 'card', 'hrio',
     'assign ls_d = {io_o_i.ls_dir_rwds, io_o_i.ls_dir_dq, io_o_i.ls_oe_n};', 'assign ls_d = {io_o_i.ls_dir_dq, io_o_i.ls_dir_rwds, io_o_i.ls_oe_n};', 1),
    ('hr_io_ls_const_oe', "hr", 'direct', 'hrio',
     "assign ls_oe_n_o     = 1'b1;", "assign ls_oe_n_o     = 1'b0;", 1),
    ('hr_io_ls_on_lb', "hr", 'lb', 'hrio',
     'if (HasLs && !Loopback) begin : g_ls', 'if (1) begin : g_ls', 1),
    ('hr_io_lb_sel', "hr", 'lb', 'hrio',
     'assign lb_dq = Loopback && lb_dq_en_i;', 'assign lb_dq = Loopback;', 1),
    ('hr_io_lb_rw_en', "hr", 'lb', 'hrio',
     'assign lb_rw = Loopback && lb_rwds_en_i;', 'assign lb_rw = Loopback && lb_dq_en_i;', 1),
    ('hr_io_lb_rw_mux', "hr", 'lb', 'hrio',
     'assign rw_d  = lb_rw ? lb_rwds_i : io_o_i.rwds;', 'assign rw_d  = io_o_i.rwds;', 1),
    ('hr_io_lb_t', "hr", 'lb', 'hrio',
     "assign dq_t = '0;", "assign dq_t = '1;", 1),
    ('hr_io_lb_mux_nolb', "hr", 'card', 'hrio',
     'assign lb_dq = Loopback && lb_dq_en_i;', 'assign lb_dq = lb_dq_en_i;', 1),
    ('hr_io_iddr_same_edge', "hr", 'card', 'hrio',
     '.DDR_CLK_EDGE   ("SAME_EDGE_PIPELINED"),', '.DDR_CLK_EDGE   ("SAME_EDGE"),', 1),
    ('hr_io_iddr_rwds_cb', "hr", 'card', 'hrio',
     ".IS_CB_INVERTED (1'b1),", ".IS_CB_INVERTED (1'b0),", 2),
    ('hr_io_iddr_q_swap', "hr", 'lb', 'hrio',
     '.Q1 (io_i_o.dq[0][i]),', '.Q1 (io_i_o.dq[1][i]),', 1),
    ('hr_io_rwds_pad_q', "hr", 'card', 'hrio',
     'assign rwds_pad_o = din;', 'assign rwds_pad_o = q;', 1),
    ('hr_io_dq_on_hr_clk', "hr", 'card', 'hrio',
     '.C  (wclk_i),', '.C  (clk_i),', 1),
    ('hr_clk_hr_phase0', "hr", 'card', 'hrclk',
     '.CLKOUT0_PHASE        (270.0),', '.CLKOUT0_PHASE        (0.0),', 1),
    ('hr_clk_hr_phase180', "hr", 'lb', 'hrclk',
     '.CLKOUT0_PHASE        (270.0),', '.CLKOUT0_PHASE        (180.0),', 1),
    ('hr_clk_ps_port_swap', "hr", 'card', 'hrclk',
     '.PSEN         (ps_en_i),', '.PSEN         (wps_en_i),', 1),
    ('hr_clk_inc_swap', "hr", 'card', 'hrclk',
     '.PSINCDEC     (wps_inc_i),', '.PSINCDEC     (~wps_inc_i),', 1),
    ('hr_clk_wclk_nofps', "hr", 'card', 'hrclk',
     '.CLKOUT1_USE_FINE_PS  ("TRUE"),', '.CLKOUT1_USE_FINE_PS  ("FALSE"),', 1),
    ('hr_clk_lkrst_not_h', "hr", 'card', 'hrclk',
     '.RST          (rst_i | lk_rst),', '.RST          (rst_i),', 1),
    ('hr_clk_lk_ignores_r', "hr", 'card', 'hrclk',
     'lk_sync_q <= {lk_sync_q[0], locked_h & locked_r};', 'lk_sync_q <= {lk_sync_q[0], locked_h};', 1),
    ('hr_clk_locked_h_only', "hr", 'card', 'hrclk',
     'assign locked_o = locked_h & locked_r;', 'assign locked_o = locked_h;', 1),
    ('hr_clk_wclk_div', "hr", 'card', 'hrclk',
     '.CLKOUT1_DIVIDE       (HrDivide),', '.CLKOUT1_DIVIDE       (HrDivide + 1),', 1),
    ('hr_clk_lkrst_not_r', "hr", 'card', 'hrclk',
     '.RST          (rst_i | lk_rst),', '.RST          (rst_i),', 2),
    ('hr_clk_rst_not_r', "hr", 'card', 'hrclk',
     '.RST          (rst_i | lk_rst),', '.RST          (lk_rst),', 2),
    ('hr_clk_lk_ignores_h', "hr", 'card', 'hrclk',
     'lk_sync_q <= {lk_sync_q[0], locked_h & locked_r};', 'lk_sync_q <= {lk_sync_q[0], locked_r};', 1),
    ('hr_clk_locked_or', "hr", 'card', 'hrclk',
     'assign locked_o = locked_h & locked_r;', 'assign locked_o = locked_h | locked_r;', 1),
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
    shutil.rmtree(mdir, ignore_errors=True)   # no stale sim.log may decide the verdict
    os.makedirs(mdir, exist_ok=True)
    text = make_mutant(path, old, new, nth)
    if text is None:
        return name, "ERROR", "the mutation does not apply to the current RTL"
    src = os.path.join(mdir, FILES[path])
    with open(src, "w") as fh:
        fh.write(text)
    cmd = ["make", "-C", HERE, "--no-print-directory", target, cfg_var + "=" + cfg, "SEED=1",
           "DDR_IO_DIR=" + mdir, "DDR_CLK_DIR=" + mdir, "HR_IO_DIR=" + mdir,
           RTL_VAR[path] + "=" + src]
    env = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
    with open(os.path.join(mdir, "make.log"), "w") as log:
        rc = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
    sim_log = os.path.join(mdir, cfg, "run" if tb == "clk" else "seed1", "sim.log")
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
