#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Mutation check of the MKV countermeasures (`make mutants`, not in `make test`).

Each mutant is a copy of hw/ip/mkv/rtl with one countermeasure (or one point
of the standard) taken out: a text substitution of the current file, so the
mutants follow the RTL. It is built with tb_bow_mkv and tb_mkv_review and
must make one of them FAIL (or the model check of tb_bow_mkv's output): a
mutant that passes means a hole in the testbenches.

    mutants.py --build <dir> [--jobs N] [name ...]

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
RTL = os.path.join(REPO, "hw", "ip", "mkv", "rtl")
MODEL = os.path.join(REPO, "tools", "mkv", "mkv_model.py")
FILES = ["bow_mkv_tables_pkg.sv", "bow_mkv_pkg.sv", "bow_mkv_core.sv", "bow_mkv.sv"]
PKG, CORE, REG = "bow_mkv_pkg.sv", "bow_mkv_core.sv", "bow_mkv.sv"
VERILATOR = os.environ.get("VERILATOR", "verilator")
TIMEOUT = 900   # seconds per simulation: a mutant that hangs a testbench is killed

# name, file, old text (must occur once), new text. Not mutants, because the
# other checks still catch every such fault (defence in depth, no visible
# difference): a dense state code (a state one bit from another is caught by
# the cycle count of the state it lands in); no code check in Decrypt (every
# ENC / DEC reads every round key again in its Encrypt pass, which checks it).
MUTANTS = [
    # the standard
    ("std_no_rotation", PKG,
     "y8[64*c +: 64] = col_mul8(rot8(x[64*c +: 64], 2 * c), M8);",
     "y8[64*c +: 64] = col_mul8(x[64*c +: 64], M8);"),
    ("std_no_const", CORE,
     "assign sched_const = ks_const(wide_q, left_q) ^",
     "assign sched_const = state_t'(0) ^"),
    ("std_draft_rounds", CORE,
     "assign rounds_d = 4'd7 + ((klen_i == 2'd3) ? 4'd2 : {2'b00, klen_i});",
     "assign rounds_d = 4'd6 + ((klen_i == 2'd3) ? 4'd2 : {2'b00, klen_i});"),
    # round key RAM code (E2, E3)
    ("rk_code_off", CORE,
     "assign edc_err  = (rk_edc(rk_rdata, rk_raddr) != rk_rchk);",
     "assign edc_err  = 1'b0;"),
    ("rk_code_no_address", PKG,
     "p = (i < 5) ? addr[i] : 1'b0;",
     "p = 1'b0;"),
    # result register copy (E1)
    ("dout_copy_off", CORE,
     "assign dout_bad = (dout_q != ~dout_n_q);",
     "assign dout_bad = 1'b0;"),
    ("dout_copy_not_while_valid", CORE,
     "                    (dout_ok && dout_bad);",
     "                    1'b0;"),
    # checked wipe (E4, E5)
    ("clear_no_read_back", CORE,
     "((cnt_q != ClearCycles - 8'({vfy_q, step_q})) || (vfy_q && zero_err));",
     "(cnt_q != ClearCycles - 8'({vfy_q, step_q}));"),
    ("clear_no_count", CORE,
     "((cnt_q != ClearCycles - 8'({vfy_q, step_q})) || (vfy_q && zero_err));",
     "(vfy_q && zero_err);"),
    ("key_no_stale_read_back", CORE,
     "assign stale_chk = (fsm_q == KeySched) && chk && (half_q != 2'd3) && (step_q != 5'd0);",
     "assign stale_chk = 1'b0;"),
    # FSM, flags, KEY_VALID (E6)
    ("flags_unchecked", CORE,
     "assign flag_err = mubi4_invalid(chk_q) || mubi4_invalid(op_key_q) ||\n"
     "                    mubi4_invalid(ks_valid_q) || mubi4_invalid(dout_ok_q);",
     "assign flag_err = 1'b0;"),
    ("key_valid_unchecked", CORE,
     "assign kv_err   = key_valid_i && !ks_valid;",
     "assign kv_err   = 1'b0;"),
    ("fsm_unchecked", CORE,
     "assign fsm_err  = !(fsm_q inside {Idle, KeySched, Encrypt, Decrypt, Clear, Check});",
     "assign fsm_err  = 1'b0;"),
    # two comparators
    ("res_comparator_b_off", CORE,
     "assign res_eq_b = &(st_q ^ in_n_q);",
     "assign res_eq_b = 1'b1;"),
    ("ks_comparator_b_off", CORE,
     "assign ks_eq_b  = (rk_wchk == rk_rchk);",
     "assign ks_eq_b  = 1'b1;"),
    # checks of version 2 that stay
    ("no_cycle_count", CORE,
     "assign check_ok  = !fault_q && (cnt_q == 8'd1) && ok_a && ok_b &&",
     "assign check_ok  = !fault_q && ok_a && ok_b &&"),
    ("no_version_complement", CORE,
     "assign cfg_err  = (rounds_q != ~rounds_n_q) || (wide_q != ~wide_n_q);",
     "assign cfg_err  = 1'b0;"),
    ("no_lost_check", CORE,
     "assign lost     = (fsm_q == Idle) && run_q;",
     "assign lost     = 1'b0;"),
    ("fault_no_wipe", CORE,
     "      if (fault_now) begin                   // release nothing, wipe everything\n        fsm_q      <= Clear;",
     "      if (fault_now) begin                   // release nothing, wipe everything\n        fsm_q      <= Idle;"),
    # TEST (F6)
    ("test_no_corruption", CORE,
     "assign tvec = {255'd0, tst_q};",
     "assign tvec = '0;"),
    ("test_counted", REG,
     "assign fault_cnt  = core_fault && !test_run_q;",
     "assign fault_cnt  = core_fault;"),
    # fault counter, LOCKED (E8)
    ("no_lockout", REG,
     "      if (lock_event) locked_q <= MuBi4True;",
     "      if (1'b0) locked_q <= MuBi4True;"),
    ("lockout_system_reset", REG,
     "  always_ff @(posedge clk_i or negedge por_rst_ni) begin\n    if (!por_rst_ni) begin\n      fcnt_q",
     "  always_ff @(posedge clk_i or negedge rst_ni) begin\n    if (!rst_ni) begin\n      fcnt_q"),
    ("counter_unchecked", REG,
     "  assign lock_event = !locked && ((fault_cnt && (fcnt_inc >= 4'(FaultLimit))) || test_bad ||\n                                  (fcnt_q != ~fcnt_n_q));",
     "  assign lock_event = !locked && ((fault_cnt && (fcnt_inc >= 4'(FaultLimit))) || test_bad);"),
    ("lock_keeps_key", REG,
     "  assign lock_wipe = locked && !core_busy && (core_ks_valid || core_dout_valid);",
     "  assign lock_wipe = 1'b0;"),
    ("locked_still_stalls", REG,
     "  assign stall   = bus_req_i.req && blocked && !nostall_q && !locked;",
     "  assign stall   = bus_req_i.req && blocked && !nostall_q;"),
    # register block (K2, K3, K4, P3)
    ("no_nostall", REG,
     "  assign stall   = bus_req_i.req && blocked && !nostall_q && !locked;",
     "  assign stall   = bus_req_i.req && blocked && !locked;"),
    ("no_key_lock", REG,
     "  assign key_wr  = wr && sel_key && !locked && !key_lock_q;",
     "  assign key_wr  = wr && sel_key && !locked;"),
    ("no_dec_policy", REG,
     "          if (blocked || locked || !key_valid_q || no_dec_q) cmd_err = 1'b1;",
     "          if (blocked || locked || !key_valid_q) cmd_err = 1'b1;"),
    ("no_wipe_on_key_valid_loss", REG,
     "  assign kv_drop = key_valid_q && (key_wr || (ctrl_wr && !key_lock_q && ver_change));",
     "  assign kv_drop = 1'b0;"),
    ("refused_key_kept", REG,
     "      if (key_refused) begin     // a refused KEY leaves no key behind",
     "      if (1'b0) begin     // a refused KEY leaves no key behind"),
    ("din_readable", REG,
     "                    (a == RegIrqEn) || (a == RegCycles) || sel_dout;",
     "                    (a == RegIrqEn) || (a == RegCycles) || sel_dout || sel_din;"),
    ("key_valid_not_and", REG,
     "  assign key_valid = key_valid_q && core_ks_valid;",
     "  assign key_valid = key_valid_q;"),
]


def run(cmd, log, timeout=None):
    with open(log, "w") as fh:
        try:
            return subprocess.call(cmd, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout)
        except subprocess.TimeoutExpired:
            return "timeout"


def one(mutant, build, case):
    name, fname, old, new = mutant
    d = os.path.join(build, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "rtl"))
    for f in FILES:
        with open(os.path.join(RTL, f)) as fh:
            text = fh.read()
        if f == fname:
            if text.count(old) != 1:
                return name, f"BAD: text found {text.count(old)} times in {f}"
            text = text.replace(old, new)
        with open(os.path.join(d, "rtl", f), "w") as fh:
            fh.write(text)
    with open(os.path.join(d, "mkv.f"), "w") as fh:
        fh.write("".join(os.path.join(d, "rtl", f) + "\n" for f in FILES))
    for top in ("tb_bow_mkv", "tb_mkv_review"):
        rc = run([VERILATOR, "--binary", "--timing", "--assert", "-j", "4", "-O2", "-Wno-fatal", "-Wno-lint",
                  "-Wno-style", "-Wno-TIMESCALEMOD", "--top-module", top, "-Mdir", os.path.join(d, top),
                  "-o", "V" + top, "-F", os.path.join(REPO, "hw", "ip", "bus", "bus.f"),
                  "-F", os.path.join(d, "mkv.f"), os.path.join(HERE, top + ".sv")],
                 os.path.join(d, top + ".build.log"))
        if rc != 0:
            return name, f"BAD: {top} does not build (see {d}/{top}.build.log)"
    shutil.copytree(case, os.path.join(d, "case"))
    rc = run([os.path.join(d, "tb_bow_mkv", "Vtb_bow_mkv"), "+DIR=" + os.path.join(d, "case"), "+SEED=1"],
             os.path.join(d, "tb_bow_mkv.log"), TIMEOUT)
    if rc != 0:
        return name, "killed by tb_bow_mkv" + (" (timeout)" if rc == "timeout" else "")
    rc = run([sys.executable, MODEL, "check", os.path.join(d, "case")], os.path.join(d, "check.log"))
    if rc != 0:
        return name, "killed by the model check"
    rc = run([os.path.join(d, "tb_mkv_review", "Vtb_mkv_review")], os.path.join(d, "tb_mkv_review.log"), TIMEOUT)
    if rc != 0:
        return name, "killed by tb_mkv_review" + (" (timeout)" if rc == "timeout" else "")
    return name, "SURVIVED"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    selected = [m for m in MUTANTS if not args.names or m[0] in args.names]
    unknown = set(args.names) - {m[0] for m in MUTANTS}
    if unknown:
        sys.exit(f"no such mutant: {', '.join(sorted(unknown))}")
    os.makedirs(args.build, exist_ok=True)
    case = os.path.join(args.build, "case")
    shutil.rmtree(case, ignore_errors=True)
    subprocess.check_call([sys.executable, MODEL, "gen", case, "--seed", "1", "--count", "20"],
                          stdout=subprocess.DEVNULL)
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for name, verdict in ex.map(lambda m: one(m, args.build, case), selected):
            print(f"{name:28s} {verdict}", flush=True)
            results.append(verdict)
    bad = sum(1 for v in results if not v.startswith("killed"))
    print(f"mutants: {len(results) - bad}/{len(results)} killed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
