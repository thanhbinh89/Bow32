#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Mutation check of the whole receiver bench and of the AFE unit tests (`make mutants-rx`,
not in `make test`).

As mutants_ppi.py, for logic that only the whole receiver (bow_mipi_rx: the D-PHY and the
controller, tb_bow_csi2rx.sv with csi2_tx_model.sv) exercises: the RAW capture of the D-PHY
(bow_dphy_raw in bow_dphy_rx, step 4 of docs/ip/mipi_rx_arch.md: no PPI bench sees it), the
controller's gate of the aligners' PPI events (ErrSotSyncHS, RxSkewCalHS) while its
datapath is off, and the AFE interface of step 5: des_rst, OWN, lprx_en, lane_pd, the reset
values and the AFE status of the D-PHY (bow_afe_chk in every bench, the D-PHY's unit test
tb_dphy_afe.sv), the delay and receive path reset logic of the two FPGA adapters
(csi2_tx_model runs it, the unit test tb_afe_dly.sv checks it against models of the
primitives); since step 7 the controller's work after a burst whose clock lane stops right
after it (test tclkpost: the transmitter's T_CLK-POST of 10 ns, the D-PHY's own RxActiveHS).
Each mutant is a copy of hw/ip/dphy_rx/rtl, hw/ip/csi2rx/rtl and the adapters' logic with one
text substitution; it must make one case fail. The unit tests run first (the
Makefile's afe target: a few seconds each), then the whole receiver cases (simulation or
model check), generated once with tools/csi2/csi2_model.py. Everything first runs on the RTL
as it is.

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
DPHY_FILES = ["bow_ppi_err_tx.sv", "bow_dphy_lp.sv", "bow_dphy_align.sv", "bow_dphy_raw.sv",
              "bow_dphy_rx_regs.sv", "bow_dphy_rx.sv"]
AFE_FILES = ["bow_dphy_dly_xusp.sv", "bow_dphy_dly_xphy.sv"]
FILES = [(DPHY_RTL, f) for f in DPHY_FILES] + \
        [(CSI_RTL, f) for f in ("bow_csi2rx_pkg.sv", "bow_ppi_err_rx.sv", "bow_csi2_lane_merge.sv",
                                 "bow_csi2_packet.sv", "bow_csi2_unpack.sv", "bow_csi2rx_out.sv",
                                 "bow_csi2_capture.sv", "bow_csi2rx_regs.sv", "bow_csi2rx.sv",
                                 "bow_mipi_rx.sv")] + \
        [(AFE_RTL, f) for f in AFE_FILES]
# as PARAMS_* of the Makefile: Lanes = 4 is the Huins receiver (Versal PHY model)
PARAMS = {1: ["-GLanes=1"], 2: ["-GLanes=2"],
          4: ["-GLanes=4", "-GAfeKind=2", "-GFifoDepth=512"]}
DPHY, CTRL = "bow_dphy_rx.sv", "bow_csi2rx.sv"
LP, REGS = "bow_dphy_lp.sv", "bow_dphy_rx_regs.sv"
XUSP, XPHY = "bow_dphy_dly_xusp.sv", "bow_dphy_dly_xphy.sv"
COMMON_F = os.path.join(REPO, "hw", "ip", "common", "common.f")
BUS_F = os.path.join(REPO, "hw", "ip", "bus", "bus.f")
AFE_CHK = os.path.join(REPO, "hw", "ip", "dphy_rx", "dv", "bow_afe_chk.sv")

# AFE unit tests (the Makefile's afe target): name, top, parameters, the RTL files of the
# mutant it needs, other sources before the testbench, the testbench; seed 1, pass =
# "<top>: PASS" in the log
UNITS = [("afe_dly", "tb_afe_dly", [], AFE_FILES, [], "tb_afe_dly.sv"),
         ("dphy_afe_asic", "tb_dphy_afe",
          ["-GLanes=4", "-GAfeKind=0", "-GAfePdRst=1", "-GTrimW=32"], DPHY_FILES, [AFE_CHK],
          "tb_dphy_afe.sv"),
         ("dphy_afe_fpga", "tb_dphy_afe",
          ["-GLanes=2", "-GAfeKind=1", "-GAfePdRst=0", "-GTrimW=64"], DPHY_FILES, [AFE_CHK],
          "tb_dphy_afe.sv")]

# whole receiver cases: (test, lanes, Lanes parameter), seed 1, BurstRxRst 0 (as test-rx)
CASES = [("raw", 4, 4), ("rxoff", 2, 2), ("rxoff", 4, 4), ("rxoff", 1, 1), ("dly", 4, 4),
         ("be", 2, 2), ("tclkpost", 2, 2), ("tclkpost", 1, 1)]

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
                                (CTRL, "  assign dsk_ev = al_deskew[0] & ~dsk_last_q & ~stale_q[0];",
                                 "  assign dsk_ev = al_deskew[0] & ~dsk_last_q;", 1)]),
    ("aligner_events_reset_only", [(CTRL, "      stale_q    <= stale_q & ~arm_lo_q;",
                                    "      stale_q    <= '0;", 1)]),
    ("aligner_deskew_ungated", [(CTRL, "  assign dsk_ev = al_deskew[0] & ~dsk_last_q & ~stale_q[0];",
                                 "  assign dsk_ev = al_deskew[0] & ~dsk_last_q;", 1)]),
    # step 5, the AFE interface: des_rst one lp cycle after the gate (from its flop, not its
    # next state); des_rst not held off by CTRL.DES_RST_DIS; des_rst 0 in reset (section 3.6:
    # 1); OWN kept when READY falls (a restart of the AFE would keep a code it lost); OWN set
    # by a DLYn write while READY = 0; lprx_en not following AFE_CTRL.PD; lane_pd falling on
    # any READY (the stale one of the synchroniser after a short PD pulse: the bug of the
    # first version of step 5), on a READY seen 0 at any time (not since PD rose), or without
    # one; CAL_DONE / CAL_ERR swapped in AFE_STATUS
    ("des_rst_late", [(LP, "      else         des_rst_q <= !ce_d && des_rst_en_i;",
                       "      else         des_rst_q <= !ce_q && des_rst_en_i;", 1)]),
    ("des_rst_dis_ignored", [(LP, "      else         des_rst_q <= !ce_d && des_rst_en_i;",
                              "      else         des_rst_q <= !ce_d;", 1)]),
    ("des_rst_reset_0", [(LP, "      if (!rst_ni) des_rst_q <= 1'b1;",
                          "      if (!rst_ni) des_rst_q <= 1'b0;", 1)]),
    ("own_kept_not_ready", [(REGS, "    own_d      = ready_i ? own_q : '0;",
                             "    own_d      = own_q;", 1)]),
    ("own_set_not_ready", [(REGS, "        if (ready_i) own_d[l] = 1'b1;",
                            "        own_d[l] = 1'b1;", 1)]),
    ("lprx_en_without_pd", [(REGS, "      lprx_en_q  <= !pd_d;", "      lprx_en_q  <= 1'b1;", 1)]),
    ("lane_pd_stale_ready", [(REGS, "  assign lane_pd_d   = pd_d || (lane_pd_q && !(ready_i && rdy_low_q));",
                              "  assign lane_pd_d   = pd_d || (lane_pd_q && !ready_i);", 1)]),
    ("lane_pd_low_kept", [(REGS, "      rdy_low_q  <= (pd_d && !pd_q) ? 1'b0 : (rdy_low_q || !ready_i);",
                           "      rdy_low_q  <= rdy_low_q || !ready_i;", 1)]),
    ("lane_pd_ignores_ready", [(REGS, "  assign lane_pd_d   = pd_d || (lane_pd_q && !(ready_i && rdy_low_q));",
                                "  assign lane_pd_d   = pd_d;", 1)]),
    # step 6: CMD.REINIT (the state machines) also starting the AFE's re-calibration, which
    # is CMD.AFE_CAL now (tb_dphy_afe)
    ("reinit_starts_cal", [(REGS, "      if (cmd_w && wd[2]) begin",
                            "      if (cmd_w && (wd[2] || wd[1])) begin", 1)]),
    ("cal_bits_swapped", [(DPHY, "    .d_i ({afe_cal_err_i, afe_cal_done_i}),",
                           "    .d_i ({afe_cal_done_i, afe_cal_err_i}),", 1)]),
    # the adapters' delay logic: the XPHY sequencer without the wait after RX_EN_VTC 1 -> 0,
    # loading the code in use again (every stable cycle of an OWN lane); the IDELAYE3 loader
    # never loading
    ("xphy_no_vtc_wait", [(XPHY, "              wait_d[l] = 5'(VtcWait);",
                           "              wait_d[l] = 5'd0;", 1)]),
    ("xphy_reload_same_code", [(XPHY, "        req[l]    = stable[l] && own_s[l] && "
                                "(!app_own_q[l] || (code_s[l] != app_code_q[l]));",
                                "        req[l]    = stable[l] && own_s[l];", 1)]),
    ("xusp_no_load", [(XUSP, "        load_d[l]   = 1'b1;", "        load_d[l]   = 1'b0;", 1)]),
    # ... and the rules only the unit test sees (step 5 review): XPHY user mode kept when the
    # PHY restarts (RX_EN_VTC not back to 1); RX_RST from des_rst while the PHY is not ready;
    # nothing cleared while not ready; the lane's code not taken for the next comparison; an
    # OWN fall not releasing the lane (the next rise does not load); a value taken without
    # being the same in two cycles (a mix of old and new bits loaded). UltraScale+: the
    # ISERDESE3 never reset; the tap ignoring OWN; a LOAD in every stable cycle; a tap loaded
    # without being the same in two cycles
    ("xphy_user_kept_over_restart", [(XPHY, "        user_d    = '0;\n", "        user_d    = user_q;\n", 1)]),
    ("xphy_rx_rst_not_ready", [(XPHY, "    else         burst_rst_q <= ready_i & des_rst_i;",
                                "    else         burst_rst_q <= des_rst_i;", 1)]),
    ("xphy_ready_ignored", [(XPHY, "      if (!ready_i) begin", "      if (1'b0) begin", 1)]),
    ("xphy_app_code_stale", [(XPHY, "            app_code_d[l] = code_s[l];",
                              "            app_code_d[l] = app_code_q[l];", 1)]),
    ("xphy_no_release", [(XPHY, "            app_own_d[l] = 1'b0;                  // released: the next rise loads again",
                          "            app_own_d[l] = app_own_q[l];", 1)]),
    ("xphy_no_stable_check", [(XPHY, "        stable[l] = (code_s[l] == code_last_q[l]) && (own_s[l] == own_last_q[l]);",
                               "        stable[l] = 1'b1;", 1)]),
    ("xusp_no_iserdes_rst", [(XUSP, "    .rst_ni (!des_rst_i),", "    .rst_ni (1'b1),", 1)]),
    ("xusp_own_ignored", [(XUSP, "      tap_s[l] = own_s[l] ? code_s[l] : 9'd0;",
                           "      tap_s[l] = code_s[l];", 1)]),
    ("xusp_load_every_cycle", [(XUSP, "      if ((tap_s[l] == tap_last_q[l]) && (tap_s[l] != tap_ld_q[l])) begin",
                                "      if (tap_s[l] == tap_last_q[l]) begin", 1)]),
    ("xusp_no_stable_check", [(XUSP, "      if ((tap_s[l] == tap_last_q[l]) && (tap_s[l] != tap_ld_q[l])) begin",
                               "      if (tap_s[l] != tap_ld_q[l]) begin", 1)]),
    # step 7: the controller's events to the CPU (FE, lines, errors) and its LOG capture still
    # on the byte clock, as up to step 6: FE, its interrupt and LOG DONE wait for the byte
    # clock of the next burst when the clock lane stops right after a burst (tclkpost; the
    # events' csi_clk pulses sampled on the byte clock also get lost: raw, rxoff, dly, be)
    ("events_on_byte_clock", [(CTRL, "      .src_clk_i   (csi_clk_i),\n      .src_rst_ni  (crst_n),\n      .src_pulse_i (bev[i]),",
                               "      .src_clk_i   (rx_byte_clk_hs_i),\n      .src_rst_ni  (crst_n),\n      .src_pulse_i (bev[i]),", 1)]),
    ("log_on_byte_clock", [(CTRL, "  bow_csi2_capture u_capture (\n    .clk_i         (csi_clk_i),",
                            "  bow_csi2_capture u_capture (\n    .clk_i         (rx_byte_clk_hs_i),", 1)]),
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


def vbuild(cmd, log):
    """One Verilator build, once more if it fails (Verilator 5.020 can abort at its exit
    after a good build, as the Makefile says)."""
    for _ in range(2):
        if run(cmd, log, env=VERILATOR_ENV) == 0:
            return True
    return False


def build_tb(d, lanes, files):
    """The whole receiver bench with the RTL files of a mutant, for one Lanes parameter."""
    obj = os.path.join(d, f"obj_l{lanes}")
    cmd = [VERILATOR, "--binary", "--timing", "-j", "4", "-O2", "-Wno-fatal", "-Wno-lint",
           "-Wno-style", "-Wno-TIMESCALEMOD", "+define+BOW_CDC_JITTER", "+define+BOW_SYNC_JITTER",
           "--top-module", "tb_bow_csi2rx", *PARAMS[lanes], "-Mdir", obj, "-o", "Vtb_bow_csi2rx",
           "-F", COMMON_F, "-F", BUS_F, *files,
           os.path.join(HERE, "csi2_tx_model.sv"),
           os.path.join(REPO, "hw", "ip", "dphy_rx", "dv", "bow_ppi_chk.sv"), AFE_CHK,
           os.path.join(HERE, "tb_bow_csi2rx.sv")]
    if vbuild(cmd, os.path.join(d, f"build_l{lanes}.log")):
        return os.path.join(obj, "Vtb_bow_csi2rx")
    return None


def build_unit(d, unit, rtl):
    """An AFE unit test with the RTL files of a mutant (rtl: name -> path)."""
    name, top, params, files, extra, tb = unit
    obj = os.path.join(d, f"obj_{name}")
    cmd = [VERILATOR, "--binary", "--timing", "-j", "4", "-Wno-fatal", "-Wno-lint", "-Wno-style",
           "-Wno-TIMESCALEMOD", "--top-module", top, *params, "-Mdir", obj, "-o", f"V{top}",
           "-F", COMMON_F, "-F", BUS_F, *[rtl[f] for f in files], *extra, os.path.join(HERE, tb)]
    if vbuild(cmd, os.path.join(d, f"build_{name}.log")):
        return os.path.join(obj, f"V{top}")
    return None


def one(mutant, build, cases, every=False):
    """Build the mutant and run the unit tests, then the cases, until one fails (every: all
    of them)."""
    name, subs = mutant
    d = os.path.join(build, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "rtl"))
    files, rtl = [], {}
    for src, f in FILES:
        with open(os.path.join(src, f)) as fh:
            text = fh.read()
        for sf, old, new, n in subs:
            if sf == f:
                if text.count(old) != n:
                    return name, f"BAD: text found {text.count(old)} times in {f}, not {n}"
                text = text.replace(old, new)
        files.append(os.path.join(d, "rtl", f))
        rtl[f] = files[-1]
        with open(files[-1], "w") as fh:
            fh.write(text)
    killers = []
    for unit in UNITS:
        b = build_unit(d, unit, rtl)
        if b is None:
            return name, f"BAD: {unit[0]} does not build (see {d}/build_{unit[0]}.log)"
        log = os.path.join(d, f"{unit[0]}.log")
        rc = run([b, "+verilator+seed+1"], log, TIMEOUT)
        with open(log, errors="replace") as fh:
            ok = f"{unit[1]}: PASS" in fh.read()
        if rc != 0 or not ok:
            killers.append(unit[0] + (" (timeout)" if rc == "timeout" else ""))
            if not every:
                return name, f"killed by {', '.join(killers)}"
    bins = {}
    for lanes in sorted({c[2] for c in CASES}):
        bins[lanes] = build_tb(d, lanes, files)
        if bins[lanes] is None:
            return name, f"BAD: does not build (see {d}/build_l{lanes}.log)"
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
    print(f"mutants_rx: unchanged RTL passes {len(UNITS)} unit tests and {len(CASES)} cases;"
          f" {len(sel)} mutants")
    killed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for name, res in ex.map(lambda m: one(m, args.build, cases, args.every), sel):
            print(f"  {name:32s} {res}")
            killed += res.startswith("killed")
    print(f"mutants_rx: {killed}/{len(sel)} killed")
    return 0 if killed == len(sel) else 1


if __name__ == "__main__":
    sys.exit(main())
