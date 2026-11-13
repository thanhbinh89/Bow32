// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Checker of the AFE interface outputs of bow_dphy_rx, v1.x (docs/ip/mipi_rx_arch.md, sections
// 3.2 and 3.6; steps 5 and 6 of section 10), against the D-PHY's own state. The equivalence check
// cannot see these (the reference of step 4 has no AFE interface), the adapters only use some
// of them, so a testbench binds this into every bow_dphy_rx:
//
//   bind bow_dphy_rx bow_afe_chk #(.Lanes (Lanes), .TrimW (TrimW), .AfePdRst (AfePdRst))
//     u_afe_chk (.clk_i, .rst_ni, .lp_clk_i, .lp_rst_ni (lrst_n), .gate_i (afe_clk_gate_en_o),
//                .des_rst_i (afe_des_rst_o), .des_rst_en_i (des_rst_en), ... );
//
// Properties, lp clock domain (every edge from the second one after a reset):
//   * des_rst = ~gate & DES_RST enable of the cycle before: both are flops set at the same
//     lp clock edge (the gate opens at the edge that releases des_rst, closes at the one
//     that sets it); held at 0 while CTRL.DES_RST_DIS = 1 (its synchronised enable);
//   * the termination of a lane is never on without its HS receiver; both are equal once
//     CTRL.HSRX_EARLY (applied) has been 0 for 16 cycles (v1: one flop; HSRX_EARLY turns the
//     HS receiver on from HS-Rqst, CLK_MISS_OFF turns both off together).
// Bus clock domain:
//   * lprx_en = ~pd for every lane;
//   * lane_pd of every lane in every cycle as section 3.6 says: 1 while pd; after PD = 1 (or
//     a reset) it falls only on a fresh READY, i.e. READY (synchronised, as the register file
//     sees it) 0 in a cycle since PD rose, then 1 with PD = 0; once 0 it stays 0 until PD;
//     and 1 the cycle after the lane was in ULPS before its wake-up mark (synchronised, v1.x).
//     A reference model of those cycles: lane_pd falling on the stale READY right after a
//     short PD pulse fails, and so does a lane_pd that never falls;
//   * dly_own of a lane only while READY is 1 (it falls with READY, one bus clock later);
//   * the v1 tie-offs: clock lane delay, monitor sampler, trim, test hooks at 0.
// While reset is asserted (section 3.6, two reset domains), from its second clock edge: every
// bus clock edge in rst_ni sees pd = AfePdRst, lprx_en = ~AfePdRst, lane_pd = 1, dly_own = 0;
// every lp clock edge in the lp reset (lp_rst_ni, which rst_ni asserts) the gate 0, des_rst
// 1, hsrx_en = term_en = 0. (Verilator: before the first reset the D-PHY starts with the gate
// open on purpose.)
// The first violation ends the simulation ($fatal). Silent otherwise; Report = 1 or the
// plusarg +afe_chk_report prints the counts at the end.

module bow_afe_chk #(
  parameter int unsigned Lanes    = 2,
  parameter int unsigned TrimW    = 64,
  parameter bit          AfePdRst = 1'b0,      // the D-PHY's AFE_CTRL.PD after reset
  parameter bit          Report   = 1'b0
) (
  input logic                       clk_i,           // bus clock
  input logic                       rst_ni,
  input logic                       lp_clk_i,
  input logic                       lp_rst_ni,       // the D-PHY's lp reset (lrst_n)
  input logic                       gate_i,          // afe_clk_gate_en_o
  input logic                       des_rst_i,       // afe_des_rst_o
  input logic                       des_rst_en_i,    // applied ~CTRL.DES_RST_DIS
  input logic                       hsrx_early_i,    // applied CTRL.HSRX_EARLY (v1.x)
  input logic                       clk_hsrx_en_i,
  input logic [Lanes-1:0]           hsrx_en_i,
  input logic                       clk_term_en_i,
  input logic [Lanes-1:0]           term_en_i,
  input logic                       pd_i,
  input logic                       clk_lprx_en_i,
  input logic [Lanes-1:0]           lprx_en_i,
  input logic                       clk_lane_pd_i,
  input logic [Lanes-1:0]           lane_pd_i,
  input logic                       ready_i,         // synchronised AFE ready (bus clock)
  input logic [Lanes:0]             ulps_act_i,      // synchronised ULPS before wake-up, [0]
                                                     // clock lane (bus clock, v1.x)
  input logic [Lanes-1:0]           dly_own_i,
  input logic [8:0]                 clk_dly_code_i,
  input logic                       clk_dly_own_i,
  input logic [Lanes-1:0]           mon_en_i,
  input logic [Lanes-1:0][8:0]      mon_code_i,
  input logic [TrimW-1:0]           trim_i,
  input logic [2:0]                 tst_mode_i,
  input logic [Lanes-1:0][7:0]      tst_data_i,
  input logic [7:0]                 atb_sel_i
);

  int unsigned n_lp = 0, n_bus = 0, n_des_rst = 0, n_gate = 0, n_ready = 0, n_own = 0;
  int unsigned n_lp_rst = 0, n_bus_rst = 0, n_pd_rise = 0, n_lane_pd_fall = 0;

  function automatic void fail(string what);
    $fatal(1, "AFE v1.x check failed: %s", what);
  endfunction

  // ---------------------------------------------------------------- lp domain
  logic       armed_q = 1'b0, valid_q, en_q, gate_q;
  logic [4:0] early_off_q;   // cycles since HSRX_EARLY was last 1 (saturating at 16)

  always @(posedge lp_clk_i or negedge lp_rst_ni) begin
    if (!lp_rst_ni) begin
      armed_q <= 1'b1;
      valid_q <= 1'b0;
      en_q    <= 1'b1;
      gate_q  <= 1'b0;
      early_off_q <= '0;
    end else begin
      valid_q <= armed_q;
      if (valid_q) begin
        n_lp++;
        if (des_rst_i !== (!gate_i && en_q)) begin
          fail($sformatf("des_rst %b with the gate %b and the des_rst enable %b of the cycle before",
                         des_rst_i, gate_i, en_q));
        end
        if (gate_i && !gate_q) n_gate++;
        if (des_rst_i) n_des_rst++;
        if ((clk_term_en_i && !clk_hsrx_en_i) || ((term_en_i & ~hsrx_en_i) != '0)) begin
          fail($sformatf("termination without the HS receiver: clock lane %b / %b, data lanes %b / %b",
                         clk_hsrx_en_i, clk_term_en_i, hsrx_en_i, term_en_i));
        end
        if ((early_off_q >= 5'd16) &&
            ((clk_hsrx_en_i !== clk_term_en_i) || (hsrx_en_i !== term_en_i))) begin
          fail($sformatf("HS receiver and termination enables differ without HSRX_EARLY: clock lane %b / %b, data lanes %b / %b",
                         clk_hsrx_en_i, clk_term_en_i, hsrx_en_i, term_en_i));
        end
      end
      en_q   <= des_rst_en_i;
      gate_q <= gate_i;
      early_off_q <= hsrx_early_i ? 5'd0 : (early_off_q == 5'd16) ? 5'd16 : early_off_q + 5'd1;
    end
  end

  // the lp clock flops while the lp reset is asserted, from its second lp clock edge (a reset
  // asserted from time 0 has no falling edge: the flops take it at the first clock edge)
  logic lp_in_rst_q = 1'b0;

  always @(posedge lp_clk_i) begin
    if (!lp_rst_ni) begin
      if (lp_in_rst_q) begin
        n_lp_rst++;
        if ((gate_i !== 1'b0) || (des_rst_i !== 1'b1) || (clk_hsrx_en_i !== 1'b0) ||
            (hsrx_en_i !== '0) || (clk_term_en_i !== 1'b0) || (term_en_i !== '0)) begin
          fail($sformatf("in the lp reset: gate %b des_rst %b hsrx_en %b / %b term_en %b / %b (want 0 1 0 0)",
                         gate_i, des_rst_i, clk_hsrx_en_i, hsrx_en_i, clk_term_en_i, term_en_i));
        end
      end
      lp_in_rst_q <= 1'b1;
    end else begin
      lp_in_rst_q <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- bus domain
  // lane_pd reference: pd_l, rdy_l = pd and READY sampled at the edge before, lpd_l = the
  // reference's lane_pd rule then, low_l = READY 0 in a cycle since PD rose, as the D-PHY had
  // it then (1 from reset); ulps_l = the lanes in ULPS before their wake-up mark at the edge
  // before (v1.x)
  logic           barmed_q = 1'b0, bvalid_q, ready_q, pd_l, rdy_l, lpd_l, low_l;
  logic           exp_rule, low_n;
  logic [Lanes:0] ulps_l, exp_lane_pd, lane_pd;

  always_comb begin
    exp_rule    = pd_i || (lpd_l && !(rdy_l && low_l));
    exp_lane_pd = {(Lanes + 1){exp_rule}} | ulps_l;
    lane_pd     = {lane_pd_i, clk_lane_pd_i};
    low_n       = (pd_i && !pd_l) ? 1'b0 : (low_l || !rdy_l);
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      barmed_q <= 1'b1;
      bvalid_q <= 1'b0;
      ready_q  <= 1'b0;
      pd_l     <= AfePdRst;
      rdy_l    <= 1'b0;
      lpd_l    <= 1'b1;
      low_l    <= 1'b1;
      ulps_l   <= '0;
    end else begin
      bvalid_q <= barmed_q;
      if (bvalid_q) begin
        n_bus++;
        if (ready_i) n_ready++;
        if (dly_own_i != '0) n_own++;
        if (pd_i && !pd_l) n_pd_rise++;
        if (lpd_l && !exp_rule) n_lane_pd_fall++;
        if ((clk_lprx_en_i !== !pd_i) || (lprx_en_i !== {Lanes{!pd_i}})) begin
          fail($sformatf("lprx_en %b / %b with pd %b", clk_lprx_en_i, lprx_en_i, pd_i));
        end
        if (lane_pd !== exp_lane_pd) begin
          fail($sformatf("lane_pd %b ([0] clock lane), want %b: pd %b; the cycle before lane_pd %b, READY %b, READY 0 since PD rose %b, ULPS %b%s",
                         lane_pd, exp_lane_pd, pd_i, lpd_l, rdy_l, low_l, ulps_l,
                         (!exp_rule && rdy_l && !low_l) ? " (a stale READY)" : ""));
        end
        if ((dly_own_i != '0) && !ready_i && !ready_q) begin
          fail($sformatf("dly_own %b while the AFE is not ready", dly_own_i));
        end
        if ((clk_dly_code_i != '0) || clk_dly_own_i || (mon_en_i != '0) || (mon_code_i != '0) ||
            (trim_i != '0) || (tst_mode_i != '0) || (tst_data_i != '0) || (atb_sel_i != '0)) begin
          fail("a v1 tie-off (clock lane delay, monitor, trim, test hooks) is not 0");
        end
      end
      ready_q <= ready_i;
      pd_l    <= pd_i;
      rdy_l   <= ready_i;
      lpd_l   <= exp_rule;
      low_l   <= low_n;
      ulps_l  <= ulps_act_i;
    end
  end

  // the bus clock flops while rst_ni is asserted, from its second bus clock edge (as above)
  logic bus_in_rst_q = 1'b0;

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      if (bus_in_rst_q) begin
        n_bus_rst++;
        if ((pd_i !== AfePdRst) || (clk_lprx_en_i !== !AfePdRst) ||
            (lprx_en_i !== {Lanes{!AfePdRst}}) || (clk_lane_pd_i !== 1'b1) ||
            (lane_pd_i !== '1) || (dly_own_i !== '0)) begin
          fail($sformatf("in reset: pd %b lprx_en %b / %b lane_pd %b / %b dly_own %b (AfePdRst %b)",
                         pd_i, clk_lprx_en_i, lprx_en_i, clk_lane_pd_i, lane_pd_i, dly_own_i,
                         AfePdRst));
        end
      end
      bus_in_rst_q <= 1'b1;
    end else begin
      bus_in_rst_q <= 1'b0;
    end
  end

  final begin
    if (Report || $test$plusargs("afe_chk_report")) begin
      $display("%m: AFE v1.x checks passed: %0d lp clock cycles (%0d with des_rst, %0d gate openings, %0d in reset), %0d bus clock cycles (%0d ready, %0d with a dly_own, %0d PD rises, %0d lane_pd falls, %0d in reset)",
               n_lp, n_des_rst, n_gate, n_lp_rst, n_bus, n_ready, n_own, n_pd_rise,
               n_lane_pd_fall, n_bus_rst);
    end
  end

endmodule
