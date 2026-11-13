// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Checker of the PPI v1.x outputs of bow_dphy_rx (docs/ip/mipi_rx_arch.md, sections 4.9, 5.2,
// 5.3; step 6 of section 10) that the CSI-2 controller does not check itself, against the
// inputs of the LP state machines: their filtered LP levels, their synchronised enables, the
// applied configuration (CTRL.CLK_CONT, CTRL.ULPS_EN, TIM2.T_INIT) and the REINIT pulse of
// the lp domain. A testbench binds it into every bow_dphy_rx:
//
//   bind bow_dphy_rx bow_ppi_chk #(.Lanes (Lanes)) u_ppi_chk (
//     .lp_clk_i, .lp_rst_ni (lrst_n), .byte_clk_i, .byte_rst_ni (brst_n),
//     .ppi_hs_i (ppi_hs_o), .ppi_lp_i (ppi_lp_o), .ppi_lp_clk_i (ppi_lp_clk_o),
//     .lane_en_i (lane_en), .lp_i (lp_st), .clk_force_i (clk_force), .byte_ce_i (byte_ce),
//     .tinit_i (cfg_lp_q.tinit), .ulps_en_i (cfg_lp_q.ulps_en), .force_wait_i (force_wait));
//
// Properties, on every lp clock edge from the second one after a reset; t = the cycle
// that ends at the edge, [0] = clock lane, [1 + l] = data lane l:
//   Stopstate[l], StopstateClk
//     * Stopstate(t) only if the lane was enabled and in LP-11 at t-1 (clock lane: LP-11 at
//       t-1, t-2 or t-3, the two cycles of Exit after LP-11 in HS; staying in Stop: LP-11 at
//       t-1). So it rises only with LP-11 on an enabled lane and falls at any other LP state
//       (LP-01: HS request) and when the lane is disabled.
//     * an enabled lane that was in LP-11 for 12 cycles (12 + T_INIT: T_INIT may be due) is
//       in Stop (the longest way there is Disable, 8 cycles, then Off and WaitStop); a lane
//       that leaves Stop in LP-11 (CMD.REINIT, READY rising with T_INIT) starts counting again.
//   ErrControl[l], ErrControlClk, ErrEsc[l] (2 bit gray counters, v1.x): a change is one
//     step forward (00 01 11 10 00), at least 16 cycles after the step before; ErrControl[l]
//     and ErrEsc[l] only step while the lane's Enable was high, ErrControlClk never while
//     CTRL.CLK_CONT; ErrSyncEsc stays 0 (no LPDT).
//   ULPS levels (the public PPI's order): in ULPS = RxUlpsEsc[l] high / RxUlpsClkNot low,
//     from the ULPS command until the wake-up ends; ULPS active = UlpsActiveNot[l] /
//     UlpsActiveNotClk low, from the command until the wake-up mark:
//     * ULPS active only while in ULPS; in ULPS never with Stopstate, only on an enabled
//       lane;
//     * ULPS active rises only after LP-00 (the command's last space, the clock lane's
//       LP-00, a wake-up mark that ended without LP-11) and falls only after the wake-up
//       mark LP-10 or LP-11;
//     * in ULPS but not active (waking up) only while the line shows the mark (LP-10, or
//       LP-01 that the state machine ignores there), never after LP-00 or LP-11;
//     * in ULPS falls only after LP-11 (the end of the wake-up);
//     the falls also when the lane was disabled, ULPS_EN was 0 or a REINIT came the cycle
//     before.
//   RxClkActiveHS: equals the byte clock gate (byte_ce_o); only on an enabled clock lane;
//     together with StopstateClk only under CLK_CONT (the gate, section 5.3).
// Byte domain: ErrSotHS 0 (v2); RxSkewCalHS (v1.x) rises at most once per burst (RxActiveHS
// high) and stays high only while RxActiveHS is high (its first cycle may come with the fall
// of RxActiveHS: the aligner's deskew pulse of the last word).
// The first violation ends the simulation ($fatal). Report = 1 (or the plusarg
// +ppi_chk_report) prints the counts at the end of the simulation.

module bow_ppi_chk import bow_ppi_pkg::*; #(
  parameter int unsigned Lanes  = 2,
  parameter bit          Report = 1'b0
) (
  input logic                lp_clk_i,
  input logic                lp_rst_ni,
  input logic                byte_clk_i,
  input logic                byte_rst_ni,
  input ppi_hs_t [Lanes-1:0] ppi_hs_i,
  input ppi_lp_t [Lanes-1:0] ppi_lp_i,
  input ppi_lp_clk_t         ppi_lp_clk_i,
  input logic [Lanes:0]      lane_en_i,     // synchronised enables, [0] clock lane
  input logic [Lanes:0][1:0] lp_i,          // filtered LP {P, N}, [0] clock lane
  input logic                clk_force_i,   // applied CTRL.CLK_CONT
  input logic                byte_ce_i,     // byte clock gate (byte_ce_o)
  input logic [19:0]         tinit_i,       // applied TIM2.T_INIT
  input logic                ulps_en_i,     // applied CTRL.ULPS_EN
  input logic                force_wait_i   // the lanes back to WaitStop (CMD.REINIT), lp
);

  localparam int unsigned N = Lanes + 1;
  localparam int unsigned StopRun = 12;
  localparam int unsigned Hold = 16;        // minimum cycles between two counter steps

  logic [N-1:0]      stop, en, lp11, lp10, lp00, ulps, ulps_act;
  logic [N-1:0][1:0] err;                   // ErrControl, [0] ErrControlClk
  logic [N-1:0][1:0] esc;                   // ErrEsc, [0] unused (0)
  logic              act;

  always_comb begin
    stop[0]    = ppi_lp_clk_i.stopstate;
    err[0]     = ppi_lp_clk_i.err_control;
    esc[0]     = 2'b00;
    ulps[0]     = !ppi_lp_clk_i.rx_ulps_clk_not;
    ulps_act[0] = !ppi_lp_clk_i.ulps_active_not;
    for (int unsigned l = 0; l < Lanes; l++) begin
      stop[1 + l]    = ppi_lp_i[l].stopstate;
      err[1 + l]     = ppi_lp_i[l].err_control;
      esc[1 + l]     = ppi_lp_i[l].err_esc;
      ulps[1 + l]     = ppi_lp_i[l].rx_ulps_esc;
      ulps_act[1 + l] = !ppi_lp_i[l].ulps_active_not;
    end
    en  = lane_en_i;
    act = ppi_lp_clk_i.rx_clk_active_hs;
    for (int unsigned i = 0; i < N; i++) begin
      lp11[i] = (lp_i[i] == 2'b11);
      lp10[i] = (lp_i[i] == 2'b10);
      lp00[i] = (lp_i[i] == 2'b00);
    end
  end

  function automatic logic [1:0] gray_next(logic [1:0] g);
    return {g[0], ~g[1]};
  endfunction

  // values of the cycles before: _q = t-1, _q2 = t-2, _q3 = t-3
  logic [N-1:0]       en_q, lp11_q, lp11_q2, lp11_q3, lp10_q, lp00_q, stop_q, ulps_q, ulps_act_q;
  logic [N-1:0][1:0]  err_q, esc_q;
  logic [N-1:0][20:0] run_q;           // cycles in a row enabled in LP-11, up to t-1
  logic [N-1:0][5:0]  err_age_q, esc_age_q;   // cycles since the last step (saturating)
  logic               force_q, valid_q, ulps_en_q, force_wait_q;
  logic [19:0]        tinit_q;
  logic               armed_q = 1'b0;  // a reset was seen (two-state simulators start
                                       // with the reset already low, without an edge)

  int unsigned n_cycles = 0, n_live = 0, n_act = 0, n_forced = 0, n_ulps = 0, n_wake = 0;
  int unsigned n_stop [N], n_err [N], n_esc [N];
  initial begin
    for (int unsigned i = 0; i < N; i++) begin
      n_stop[i] = 0;
      n_err[i]  = 0;
      n_esc[i]  = 0;
    end
  end

  function automatic string lane_name(int unsigned i);
    return (i == 0) ? "clock lane" : $sformatf("data lane %0d", i - 1);
  endfunction

  function automatic void fail(string what);
    $fatal(1, "PPI v1.x check failed: %s", what);
  endfunction

  // a gray counter: a step forward, Hold cycles after the one before, while allowed
  function automatic void check_step(string what, int unsigned i, logic [1:0] g, logic [1:0] g_q,
                                     logic [5:0] age, logic allowed);
    if (g != g_q) begin
      if (g != gray_next(g_q)) begin
        fail($sformatf("%s of the %s: %b after %b is not one gray step", what, lane_name(i), g,
                       g_q));
      end
      if (age < 6'(Hold - 1)) begin
        fail($sformatf("%s of the %s stepped %0d cycles after its step before (at least %0d)",
                       what, lane_name(i), age + 1, Hold));
      end
      if (!allowed) begin
        fail($sformatf("%s of the %s stepped while it must not (lane disabled or CLK_CONT)",
                       what, lane_name(i)));
      end
    end
  endfunction

  always @(posedge lp_clk_i or negedge lp_rst_ni) begin
    if (!lp_rst_ni) begin
      armed_q   <= 1'b1;
      valid_q   <= 1'b0;
      en_q      <= '0;
      lp11_q    <= '0;
      lp11_q2   <= '0;
      lp11_q3   <= '0;
      lp10_q    <= '0;
      lp00_q    <= '0;
      stop_q    <= '0;
      ulps_q    <= '0;
      ulps_act_q <= '0;
      ulps_en_q <= 1'b0;
      force_wait_q <= 1'b0;
      err_q     <= '0;
      esc_q     <= '0;
      run_q     <= '0;
      err_age_q <= '1;
      esc_age_q <= '1;
      force_q   <= 1'b0;
      tinit_q   <= '0;
    end else begin
      valid_q <= armed_q;
      if (valid_q) begin
        n_cycles++;
        for (int unsigned i = 0; i < N; i++) begin
          if (stop[i] && !stop_q[i]) n_stop[i]++;
          if (err[i] != err_q[i]) n_err[i]++;
          if (esc[i] != esc_q[i]) n_esc[i]++;
          if (ulps[i]) n_ulps++;
          // Stopstate
          if (stop[i] && !en_q[i]) begin
            fail($sformatf("Stopstate of the %s, which was disabled", lane_name(i)));
          end
          if (stop[i] && !lp11_q[i] && (i != 0 || stop_q[i] || !(lp11_q2[i] || lp11_q3[i]))) begin
            fail($sformatf("Stopstate of the %s without LP-11", lane_name(i)));
          end
          if (run_q[i] >= 21'(StopRun) + 21'(tinit_q)) begin
            n_live++;
            if (!stop[i] && !stop_q[i]) begin       // (stop_q: a forced exit, counting again)
              fail($sformatf("no Stopstate of the %s after %0d cycles enabled in LP-11 (T_INIT %0d)",
                             lane_name(i), run_q[i], tinit_q));
            end
          end
          // the error counters (v1.x): the D-PHY's masks (step 4) at the cycle of the step
          check_step(i == 0 ? "ErrControlClk" : "ErrControl", i, err[i], err_q[i], err_age_q[i],
                     (i == 0) ? !force_q : en_q[i]);
          if (i != 0) check_step("ErrEsc", i, esc[i], esc_q[i], esc_age_q[i], en_q[i]);
          // ULPS levels (the public PPI's order: active until the wake-up mark, in ULPS until
          // its end)
          if (ulps_act[i] && !ulps[i]) begin
            fail($sformatf("UlpsActiveNot of the %s low while not in ULPS (RxUlps%s)", lane_name(i),
                           (i == 0) ? "ClkNot high" : "Esc low"));
          end
          if (ulps[i] && stop[i]) fail($sformatf("ULPS and Stopstate of the %s", lane_name(i)));
          if (ulps[i] && !en_q[i]) fail($sformatf("ULPS of the %s, which was disabled", lane_name(i)));
          if (ulps_act[i] && !ulps_act_q[i] && !lp00_q[i]) begin
            fail($sformatf("ULPS of the %s active without LP-00 the cycle before", lane_name(i)));
          end
          if (ulps[i] && !ulps_act[i]) begin
            n_wake++;
            if (lp00_q[i] || lp11_q[i]) begin
              fail($sformatf("the %s still waking up from ULPS after LP-%s", lane_name(i),
                             lp00_q[i] ? "00" : "11"));
            end
          end
          if ((ulps_act_q[i] && !ulps_act[i] && !(lp10_q[i] || lp11_q[i])) ||
              (ulps_q[i] && !ulps[i] && !lp11_q[i])) begin
            if (en_q[i] && ulps_en_q && !force_wait_q) begin
              fail($sformatf("%s of the %s ended without %s", ulps_q[i] && !ulps[i] ? "ULPS" :
                             "active ULPS", lane_name(i), ulps_q[i] && !ulps[i] ? "LP-11" :
                             "the wake-up mark (LP-10) or LP-11"));
            end
          end
        end
        // RxClkActiveHS
        if (act) n_act++;
        if (act && stop[0]) n_forced++;
        if (act != byte_ce_i) fail("RxClkActiveHS is not the byte clock gate");
        if (act && !en_q[0]) fail("RxClkActiveHS on a disabled clock lane");
        if (act && stop[0] && !force_q) fail("RxClkActiveHS with StopstateClk without CLK_CONT");
        // ErrSyncEsc: no LPDT
        for (int unsigned l = 0; l < Lanes; l++) begin
          if (ppi_lp_i[l].err_sync_esc != 2'b00) begin
            fail($sformatf("ErrSyncEsc of data lane %0d is not 0 (no LPDT)", l));
          end
        end
      end
      en_q    <= en;
      lp11_q  <= lp11;
      lp11_q2 <= lp11_q;
      lp11_q3 <= lp11_q2;
      lp10_q  <= lp10;
      lp00_q  <= lp00;
      stop_q  <= stop;
      ulps_q  <= ulps;
      ulps_act_q <= ulps_act;
      ulps_en_q <= ulps_en_i;
      force_wait_q <= force_wait_i;
      err_q   <= err;
      esc_q   <= esc;
      force_q <= clk_force_i;
      tinit_q <= tinit_i;
      for (int unsigned i = 0; i < N; i++) begin
        run_q[i]     <= (!(en[i] && lp11[i]) || (stop_q[i] && !stop[i])) ? 21'd0 :
                        (&run_q[i]) ? run_q[i] : run_q[i] + 21'd1;
        err_age_q[i] <= (err[i] != err_q[i]) ? 6'd0 : (&err_age_q[i]) ? err_age_q[i] : err_age_q[i] + 6'd1;
        esc_age_q[i] <= (esc[i] != esc_q[i]) ? 6'd0 : (&esc_age_q[i]) ? esc_age_q[i] : esc_age_q[i] + 6'd1;
      end
    end
  end

  // byte domain: ErrSotHS (v2), RxSkewCalHS (v1.x: a level, once per burst)
  logic [Lanes-1:0] skew_q, skew_seen_q;
  int unsigned      n_skew = 0;

  always @(posedge byte_clk_i or negedge byte_rst_ni) begin
    if (!byte_rst_ni) begin
      skew_q      <= '0;
      skew_seen_q <= '0;
    end else begin
      for (int unsigned l = 0; l < Lanes; l++) begin
        if (armed_q) begin
          if (ppi_hs_i[l].err_sot_hs) fail($sformatf("ErrSotHS of data lane %0d (v1.x: 0)", l));
          if (ppi_hs_i[l].rx_skew_cal_hs && !skew_q[l]) begin
            n_skew++;
            if (skew_seen_q[l]) begin
              fail($sformatf("RxSkewCalHS of data lane %0d rose twice in one burst", l));
            end
          end
          if (ppi_hs_i[l].rx_skew_cal_hs && skew_q[l] && !ppi_hs_i[l].rx_active_hs) begin
            fail($sformatf("RxSkewCalHS of data lane %0d still high after RxActiveHS fell", l));
          end
        end
        skew_q[l]      <= ppi_hs_i[l].rx_skew_cal_hs;
        skew_seen_q[l] <= ppi_hs_i[l].rx_active_hs &&
                          (skew_seen_q[l] || (ppi_hs_i[l].rx_skew_cal_hs && !skew_q[l]));
      end
    end
  end

  string per_lane;

  final begin
    if (Report || $test$plusargs("ppi_chk_report")) begin
      per_lane = "";
      for (int unsigned i = 0; i < N; i++) begin
        per_lane = {per_lane, $sformatf(", %s %0d Stopstate / %0d ErrControl / %0d ErrEsc steps",
                                        lane_name(i), n_stop[i], n_err[i], n_esc[i])};
      end
      $display("%m: PPI v1.x checks passed: %0d lp clock cycles (%0d lane cycles enabled in LP-11 past the Stop bound: in Stop; %0d lane cycles in ULPS, %0d of them waking up), RxClkActiveHS %0d cycles (%0d with StopstateClk), RxSkewCalHS %0d rises%s",
               n_cycles, n_live, n_ulps, n_wake, n_act, n_forced, n_skew, per_lane);
    end
  end

endmodule
