#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Mutation check of the D-PHY bench (`make -C hw/ip/dphy_rx/dv mutants`, not in `make test`).

As hw/ip/csi2rx/dv/mutants_rx.py, for the D-PHY v1.x functions of step 6 of
docs/ip/mipi_rx_arch.md (section 4.12): each mutant is a copy of the D-PHY's RTL
(hw/ip/dphy_rx/rtl) and of the controller's sampler of the PPI error counters
(hw/ip/csi2rx/rtl/bow_ppi_err_rx.sv) with one text substitution; built into tb_bow_dphy_rx.sv
it must make one of the bench's tests fail (its self-checks, or bow_ppi_chk / bow_afe_chk). The
tests first run on the RTL as it is (they must pass). Each mutant is built with 2 lanes and,
when no test fails there, with 4 lanes (events of more lanes in one cycle; --every: always
both). Every function of step 6 has at least one mutant here, and so has every fix of its
review; the controller's side (its use of the gray counters and of RxSkewCalHS) has its
mutants in mutants_ppi.py and mutants_rx.py.

    mutants_dphy.py --build <dir> [--jobs N] [--every] [name ...]

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
DPHY_RTL = os.path.join(REPO, "hw", "ip", "dphy_rx", "rtl")
CSI_RTL = os.path.join(REPO, "hw", "ip", "csi2rx", "rtl")
VERILATOR = os.environ.get("VERILATOR", "verilator")
TIMEOUT = 600    # seconds per run
# dphy_rx.f in order, then the controller's sampler
DPHY_FILES = ["bow_ppi_err_tx.sv", "bow_dphy_lp.sv", "bow_dphy_align.sv", "bow_dphy_raw.sv",
              "bow_dphy_rx_regs.sv", "bow_dphy_rx.sv"]
FILES = [(DPHY_RTL, f) for f in DPHY_FILES] + [(CSI_RTL, "bow_ppi_err_rx.sv")]
LP, RX, REGS, TX, ERRRX = ("bow_dphy_lp.sv", "bow_dphy_rx.sv", "bow_dphy_rx_regs.sv",
                           "bow_ppi_err_tx.sv", "bow_ppi_err_rx.sv")

# tests: (test, plusargs), seed 1 (as the Makefile's run), on each build of LANES
TESTS = [("basic", ""), ("apply", ""), ("tinit", ""), ("hstmo", ""), ("esctmo", ""),
         ("ulps", ""), ("hsrx", ""), ("missoff", ""), ("clklost", ""), ("lateeot", ""),
         ("gray", ""), ("gray", "+BUS_PS=49870"), ("togdiv", "+LP_PS=20000 +BYTE_PS=10037")]
LANES = (2, 4)

# name, [(file, old text, new text, occurrences)]: every old text must occur that often
MUTANTS = [
    # T_INIT: ignored; counted to half; due again at every Enable; not due at a READY rise;
    # CMD.REINIT not sending the lanes to WaitStop
    ("tinit_ignored", [(LP, "  assign tinit_cnt   = pend_q && (tinit_i != 20'd0);",
                        "  assign tinit_cnt   = 1'b0;", 1)]),
    ("tinit_half", [(LP, "            else if (tmr_q >= tinit_i - 20'd1) state_d = Stop;",
                     "            else if (tmr_q >= (tinit_i >> 1)) state_d = Stop;", 1)]),
    ("tinit_on_enable", [(LP, "  assign pend_d = tinit_set_i || (pend_q && (state_d != Stop));",
                          "  assign pend_d = tinit_set_i || (state_q == Off) || (pend_q && (state_d != Stop));", 1)]),
    ("tinit_no_ready_rise", [(RX, "  assign tinit_set  = reinit_lp || rdy_up_lp;",
                              "  assign tinit_set  = reinit_lp;", 1),
                             (RX, "  assign force_wait = reinit_lp || (rdy_up_lp && (cfg_lp_q.tinit != 20'd0));",
                              "  assign force_wait = reinit_lp;", 1)]),
    ("reinit_no_force", [(RX, "  assign force_wait = reinit_lp || (rdy_up_lp && (cfg_lp_q.tinit != 20'd0));",
                          "  assign force_wait = rdy_up_lp && (cfg_lp_q.tinit != 20'd0);", 1)]),
    # HS_TMO: one cycle late; not an LP error any more (v1 counted the watchdog as one); its
    # reset value not the v1 watchdog
    ("hstmo_late", [(LP, "({tmr_hi_q, tmr_q} >= hs_tmo_i - 24'd1);", "({tmr_hi_q, tmr_q} >= hs_tmo_i);", 1)]),
    ("hstmo_not_lp_error", [(LP, "            state_d  = WaitStop;     // watchdog (HS_TMO)\n"
                                 "            ev_err_d = 1'b1;\n",
                             "            state_d  = WaitStop;     // watchdog (HS_TMO)\n", 1)]),
    ("hstmo_reset_0", [(REGS, "      hs_tmo_q       <= 24'h10_0000;", "      hs_tmo_q       <= 24'h0;", 1)]),
    # ESC_TMO: in 32 cycle units; ignored
    ("esctmo_unit_32", [(LP, "(tmr_q >= {2'b00, esc_tmo_i, 6'd0} - 20'd1);",
                         "(tmr_q >= {3'b000, esc_tmo_i, 5'd0} - 20'd1);", 1)]),
    ("esctmo_ignored", [(LP, "  assign esc_tmo_hit = (esc_tmo_i != 12'd0) &&",
                         "  assign esc_tmo_hit = 1'b0 &&", 1)]),
    # ULPS: the command bits in the other order; lane_pd not following ULPS; lane_pd kept
    # through the wake-up mark; ULPS_EN ignored; another command not an escape error
    ("ulps_cmd_reversed", [(LP, "  localparam logic [7:0] EscUlps = 8'b0001_1110;",
                            "  localparam logic [7:0] EscUlps = 8'b0111_1000;", 1)]),
    ("ulps_no_lane_pd", [(REGS, "      lane_pdl_q <= {(Lanes + 1){lane_pd_d}} | ulps_act_i;",
                          "      lane_pdl_q <= {(Lanes + 1){lane_pd_d}};", 1)]),
    ("ulps_lane_pd_wake", [(LP, "  assign ulps_act_o  = (state_q == Ulps);",
                            "  assign ulps_act_o  = (state_q == Ulps) || (state_q == UlpsExit);", 1)]),
    ("ulps_en_ignored", [(LP, "          end else if ((lp_q == Lp10) && ulps_en_i) begin",
                          "          end else if (lp_q == Lp10) begin", 1)]),
    ("esc_cmd_no_error", [(LP, "                    state_d  = EscWait;\n"
                               "                    ev_esc_d = 1'b1;\n",
                           "                    state_d  = EscWait;\n", 1)]),
    # HSRX_EARLY: ignored; the termination early too
    ("hsrx_early_ignored", [(LP, " || (hsrx_early_i && (state_d == HsRqst));", ";", 1)]),
    ("hsrx_early_term", [(LP, "    term_d   = hs_on || ((state_d == Disable) && term_q);",
                          "    term_d   = hs_on || ((state_d == Disable) && term_q) || (hsrx_early_i && (state_d == HsRqst));", 1)]),
    # CLK_MISS_OFF ignored
    ("missoff_ignored", [(LP, "    trail_on = !(ClockLane && miss_off_i);", "    trail_on = 1'b1;", 1)]),
    # RxSkewCalHS a pulse (v1)
    ("skewcal_pulse", [(RX, "    assign ppi_hs_o[l].rx_skew_cal_hs  = al_deskew[l] | (dsk_lvl_q[l] & arm[l]);",
                        "    assign ppi_hs_o[l].rx_skew_cal_hs  = al_deskew[l];", 1)]),
    # CLK_TOG_DIV ignored
    ("togdiv_ignored", [(RX, "  assign tog_lim = 15'((16'd1 << tog_div) - 16'd1);",
                         "  assign tog_lim = 15'd0;", 1)]),
    # PPI error counters: binary, not gray; steps 8 cycles apart; ErrControlClk not masked
    # while CLK_CONT; the sampler counting changes, not steps
    ("ppi_counter_binary", [(TX, "        if (step[i])                gray_q[i] <= {gray_q[i][0], ~gray_q[i][1]};",
                             "        if (step[i])                gray_q[i] <= gray_q[i] + 2'd1;", 1)]),
    ("ppi_hold_8", [(TX, "  parameter int unsigned Hold = 16 ", "  parameter int unsigned Hold = 8 ", 1)]),
    ("ppi_clk_cont_unmasked", [(RX, "    .en_i   (!clk_force),", "    .en_i   (1'b1),", 1)]),
    ("ppi_rx_changes_only", [(ERRRX, "      steps_o[i] = bin2(gray_s[i]) - bin2(last_q[i]);",
                              "      steps_o[i] = {1'b0, (gray_s[i] != last_q[i])};", 1)]),
    # bus side event counters: one count per change, not the difference; binary counters;
    # simultaneous events of several lanes counted once
    ("evc_change_only", [(REGS, "      d_err[i] = g2b(evc_err_i[i]) - g2b(err_last_q[i]);",
                          "      d_err[i] = EvcW'(evc_err_i[i] != err_last_q[i]);", 1)]),
    ("evc_binary", [(RX, "        if (evc_step[i]) evc_gray_q[i] <= gray_inc(evc_gray_q[i]);",
                     "        if (evc_step[i]) evc_gray_q[i] <= evc_gray_q[i] + 1'b1;", 1)]),
    ("evc_agg_no_pending", [(RX, "        agg_pend_q[k] <= !agg_step[k] ? 4'd0 : (agg_sum[k] > 5'd16) ? 4'd15 : 4'(agg_sum[k] - 5'd1);",
                             "        agg_pend_q[k] <= 4'd0;", 1)]),
    # shadow + APPLY: copied every cycle; CMD not reading the pending APPLY; an APPLY while
    # pending lost
    ("apply_always", [(RX, "  assign apply_take = apply_first_q || (apply_s != apply_seen_q);",
                       "  assign apply_take = 1'b1;", 1)]),
    ("apply_pend_reads_0", [(REGS, "      10'h010: rdata_d = {dirty_q, 30'h0, apply_pend};",
                             "      10'h010: rdata_d = {dirty_q, 31'h0};", 1)]),
    ("apply_again_lost", [(REGS, "      apply_again_q <= apply_again_q || apply_cmd;",
                           "      apply_again_q <= apply_again_q;", 1)]),
    # CLK_LOST: CLK_LOST_EN ignored; not on the PPI
    ("clklost_always", [(RX, "    assign clk_lost[l] = cfg_lp_q.clk_lost_en && hs_act[1 + l] && !act_last_q[l] &&",
                         "    assign clk_lost[l] = hs_act[1 + l] && !act_last_q[l] &&", 1)]),
    ("clklost_not_ppi", [(RX, "    .ev_i   (ev_lp_err[Lanes:1] | clk_lost),", "    .ev_i   (ev_lp_err[Lanes:1]),", 1)]),
    # LATE_EOT: reported once only; also when Enable closed the gate; also for CMD.REINIT
    ("late_once_only", [(RX, "      late_done_q <= late | (late_done_q & arm_lp);",
                         "      late_done_q <= late | late_done_q;", 1)]),
    ("late_on_enable", [(RX, "ce_last_q && !byte_ce && lane_en[0] && !force_q}", "ce_last_q && !byte_ce && !force_q}", 1)]),
    ("late_on_reinit", [(RX, "ce_last_q && !byte_ce && lane_en[0] && !force_q}", "ce_last_q && !byte_ce && lane_en[0]}", 1)]),
    # ---- review of step 6
    # S6-01, the ULPS levels of the PPI in the order of step 6 before the review (UlpsActiveNot
    # until Stop, RxUlpsEsc / RxUlpsClkNot only until the wake-up mark); the wake-up mark
    # that ends in LP-00 left for good; the exit event at the mark
    ("ulps_order_step6", [(RX, "    assign ppi_lp_o[l].ulps_active_not = !ulps_act[1 + l];\n"
                               "    assign ppi_lp_o[l].rx_ulps_esc     = ulps[1 + l];",
                           "    assign ppi_lp_o[l].ulps_active_not = !ulps[1 + l];\n"
                           "    assign ppi_lp_o[l].rx_ulps_esc     = ulps_act[1 + l];", 1)]),
    ("ulps_clk_order_step6", [(RX, "  assign ppi_lp_clk_o.ulps_active_not  = !ulps_act[0];\n"
                                   "  assign ppi_lp_clk_o.rx_ulps_clk_not  = !ulps[0];",
                               "  assign ppi_lp_clk_o.ulps_active_not  = !ulps[0];\n"
                               "  assign ppi_lp_clk_o.rx_ulps_clk_not  = !ulps_act[0];", 1)]),
    ("ulps_exit_no_return", [(LP, "            state_d = Ulps;          // the mark ended without LP-11: still in ULPS",
                              "            state_d = UlpsExit;", 1)]),
    ("ulps_wake_at_mark", [(LP, "            state_d = UlpsExit;      // wake-up mark: the HS part powers up again",
                            "            state_d = UlpsExit;      // wake-up mark: the HS part powers up again\n"
                            "            ev_wake_d = 1'b1;", 1)]),
    # S6-02, the PPI sampler: its reset value 11 (a change seen right after the reset)
    ("lperr_rx_last_reset", [(ERRRX, "    if (!rst_ni) last_q <= '0;", "    if (!rst_ni) last_q <= '1;", 1)]),
    # S6-03, CMD.REINIT turns the clock lane's receiver off with the gate (no Exit)
    ("reinit_clk_at_once", [(LP, "      if (ClockLane && ((state_q == Hs) || (state_q == Exit))) begin",
                             "      if (1'b0) begin", 1)]),
    # S6-05, DIRTY never set; not cleared by an APPLY
    ("dirty_never", [(REGS, "      10'h010: rdata_d = {dirty_q, 30'h0, apply_pend};",
                      "      10'h010: rdata_d = {1'b0, 30'h0, apply_pend};", 1)]),
    ("dirty_kept", [(REGS, "    else if (apply_send) dirty_q <= 1'b0;", "    else if (1'b0) dirty_q <= 1'b0;", 1)]),
    # S6-06, the register map version of steps 4 and 5
    ("id_version_1", [(REGS, "  localparam logic [31:0] DphyId   = 32'h4450_5202;",
                       "  localparam logic [31:0] DphyId   = 32'h4450_5201;", 1)]),
    # S6-07, the timeouts compared with == (a lower value applied while counting: the 24 bit
    # wrap first)
    ("hstmo_equal", [(LP, "({tmr_hi_q, tmr_q} >= hs_tmo_i - 24'd1);", "({tmr_hi_q, tmr_q} == hs_tmo_i - 24'd1);", 1)]),
    ("esctmo_equal", [(LP, "(tmr_q >= {2'b00, esc_tmo_i, 6'd0} - 20'd1);",
                       "(tmr_q == {2'b00, esc_tmo_i, 6'd0} - 20'd1);", 1)]),
    # S6-13, the mutants of the review that survived: CMD[0] 0 between the ack of an APPLY and
    # the APPLY written while it was pending; the copy taken from the toggle before its
    # synchroniser; an error waiting for its step kept while the lane is disabled; an
    # aggregate count saturating at 1 pending (4 lanes: more events in one cycle); one more:
    # the hold of the PPI counters one cycle short
    ("apply_pend_no_again", [(REGS, "  assign apply_pend = (apply_q != apply_ack_i) || apply_again_q;",
                              "  assign apply_pend = (apply_q != apply_ack_i);", 1)]),
    ("apply_take_unsync", [(RX, "  assign apply_take = apply_first_q || (apply_s != apply_seen_q);",
                            "  assign apply_take = apply_first_q || (apply_req_sys != apply_seen_q);", 1)]),
    ("ppi_pend_kept_disabled", [(TX, "        pend_q[i] <= en_i[i] && (pend_q[i] || ev_i[i]) && !step[i];",
                                 "        pend_q[i] <= (pend_q[i] || ev_i[i]) && !step[i];", 1)]),
    ("evc_agg_sat_1", [(RX, "(agg_sum[k] > 5'd16) ? 4'd15 : 4'(agg_sum[k] - 5'd1);",
                        "(agg_sum[k] > 5'd2) ? 4'd1 : 4'(agg_sum[k] - 5'd1);", 1)]),
    ("ppi_hold_15", [(TX, "        if (step[i])                hold_q[i] <= HoldW'(Hold - 1);",
                      "        if (step[i])                hold_q[i] <= HoldW'(Hold - 2);", 1)]),
    # the AFE invariants of the bench (section 8.3): the termination of a data lane only once
    # the sync search starts (after SETTLE: far over the T_D-TERM-EN budget); the clock miss
    # 6 cycles early (the gate closes while the clock runs)
    ("term_after_settle", [(LP, "    term_d   = hs_on || ((state_d == Disable) && term_q);",
                            "    term_d   = (hs_on && (ClockLane || (state_d != Settle))) || ((state_d == Disable) && term_q);", 1)]),
    ("clk_miss_early", [(LP, "              if (tmr_q <= 20'd1) state_d = Trail;", "              if (tmr_q <= 20'd7) state_d = Trail;", 1)]),
]


VERILATOR_ENV = {k: v for k, v in os.environ.items() if k not in ("PYTHONHOME", "PYTHONPATH")}


def run(cmd, log, timeout=None):
    with open(log, "w") as fh:
        try:
            return subprocess.call(cmd, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout,
                                   env=VERILATOR_ENV)
        except subprocess.TimeoutExpired:
            return "timeout"


def build_tb(d, files, lanes):
    """The D-PHY bench with the RTL files of a mutant (one retry, as the Makefile)."""
    obj = os.path.join(d, f"obj_l{lanes}")
    cmd = [VERILATOR, "--binary", "--timing", "-j", "4", "-O2", "-Wno-fatal", "-Wno-lint",
           "-Wno-style", "-Wno-TIMESCALEMOD", "+define+BOW_CDC_JITTER", "+define+BOW_SYNC_JITTER",
           "--top-module", "tb_bow_dphy_rx", f"-GLanes={lanes}", "-Mdir", obj, "-o", "Vtb_bow_dphy_rx",
           "-F", os.path.join(REPO, "hw", "ip", "common", "common.f"),
           "-F", os.path.join(REPO, "hw", "ip", "bus", "bus.f"), *files,
           os.path.join(REPO, "hw", "fpga", "common", "rtl", "bow_dphy_dly_xusp.sv"),
           os.path.join(REPO, "hw", "fpga", "common", "rtl", "bow_dphy_dly_xphy.sv"),
           os.path.join(REPO, "hw", "ip", "csi2rx", "dv", "csi2_tx_model.sv"),
           os.path.join(HERE, "bow_ppi_chk.sv"), os.path.join(HERE, "bow_afe_chk.sv"),
           os.path.join(HERE, "tb_bow_dphy_rx.sv")]
    for _ in range(2):
        if run(cmd, os.path.join(d, f"build_l{lanes}.log")) == 0:
            return os.path.join(obj, "Vtb_bow_dphy_rx")
    return None


def test_name(t):
    name, plus = t
    return name + "".join("_" + p.strip("+").split("=")[0].lower() for p in plus.split())


def one(mutant, build, every=False):
    """Build the mutant and run the tests until one fails, with 2 lanes, then 4 (every: all of
    them, both builds)."""
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
    killers = []
    for lanes in LANES:
        b = build_tb(d, files, lanes)
        if b is None:
            return name, f"BAD: does not build (see {d}/build_l{lanes}.log)"
        for t in TESTS:
            tn = f"{test_name(t)}_l{lanes}"
            log = os.path.join(d, tn + ".log")
            rc = run([b, "+TEST=" + t[0], *t[1].split(), "+verilator+seed+1"], log, TIMEOUT)
            with open(log, errors="replace") as fh:
                ok = "tb_bow_dphy_rx: PASS" in fh.read()
            if rc != 0 or not ok:
                killers.append(tn + (" (timeout)" if rc == "timeout" else ""))
                if not every:
                    break
        if killers and not every:
            break
    if not killers:
        return name, "SURVIVED"
    return name, f"killed by {', '.join(killers)}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--every", action="store_true", help="run every test (which ones kill it)")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    sel = [m for m in MUTANTS if not args.names or m[0] in args.names]
    unknown = set(args.names) - {m[0] for m in MUTANTS}
    if unknown:
        raise SystemExit(f"unknown mutants: {' '.join(sorted(unknown))}")
    os.makedirs(args.build, exist_ok=True)
    name, res = one(("none", []), args.build, every=True)
    if res != "SURVIVED":
        print(f"mutants_dphy: the unchanged RTL fails: {res}")
        return 1
    print(f"mutants_dphy: unchanged RTL passes {len(TESTS)} tests with {' and '.join(map(str, LANES))} lanes; "
          f"{len(sel)} mutants")
    killed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for name, res in ex.map(lambda m: one(m, args.build, args.every), sel):
            print(f"  {name:28s} {res}")
            killed += res.startswith("killed")
    print(f"mutants_dphy: {killed}/{len(sel)} killed")
    return 0 if killed == len(sel) else 1


if __name__ == "__main__":
    sys.exit(main())
