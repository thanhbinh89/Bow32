// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Checker of the AFE interface outputs of bow_dphy_rx, v1 (docs/ip/mipi_rx_arch.md, sections
// 3.2 and 3.6; step 5 of section 10), against the D-PHY's own state. The equivalence check
// cannot see these (the reference of step 4 has no AFE interface), the adapters only use some
// of them, so a testbench binds this into every bow_dphy_rx:
//
//   bind bow_dphy_rx bow_afe_chk #(.Lanes (Lanes), .TrimW (TrimW)) u_afe_chk (
//     .clk_i, .rst_ni, .lp_clk_i, .lp_rst_ni (lrst_n), .gate_i (afe_clk_gate_en_o),
//     .des_rst_i (afe_des_rst_o), .des_rst_en_i (des_rst_en), ... );
//
// Properties, lp clock domain (every edge from the second one after a reset):
//   * des_rst = ~gate & DES_RST enable of the cycle before: both are flops set at the same
//     lp clock edge (the gate opens at the edge that releases des_rst, closes at the one
//     that sets it); held at 0 while CTRL.DES_RST_DIS = 1 (its synchronised enable);
//   * the HS receiver and termination enables of every lane are equal (v1: one flop).
// Bus clock domain:
//   * lprx_en = ~pd for every lane; lane_pd = 1 while pd, and never 0 before the AFE was
//     seen ready (the synchronised READY of the register file);
//   * dly_own of a lane only while READY is 1 (it falls with READY, one bus clock later);
//   * the v1 tie-offs: clock lane delay, monitor sampler, trim, test hooks at 0.
// The first violation ends the simulation ($fatal). Silent otherwise; Report = 1 or the
// plusarg +afe_chk_report prints the counts at the end.

module bow_afe_chk #(
  parameter int unsigned Lanes  = 2,
  parameter int unsigned TrimW  = 64,
  parameter bit          Report = 1'b0
) (
  input logic                       clk_i,           // bus clock
  input logic                       rst_ni,
  input logic                       lp_clk_i,
  input logic                       lp_rst_ni,       // the D-PHY's lp reset (lrst_n)
  input logic                       gate_i,          // afe_clk_gate_en_o
  input logic                       des_rst_i,       // afe_des_rst_o
  input logic                       des_rst_en_i,    // synchronised ~CTRL.DES_RST_DIS
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

  function automatic void fail(string what);
    $fatal(1, "AFE v1 check failed: %s", what);
  endfunction

  // ---------------------------------------------------------------- lp domain
  logic armed_q = 1'b0, valid_q, en_q, gate_q;

  always @(posedge lp_clk_i or negedge lp_rst_ni) begin
    if (!lp_rst_ni) begin
      armed_q <= 1'b1;
      valid_q <= 1'b0;
      en_q    <= 1'b1;
      gate_q  <= 1'b0;
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
        if ((clk_hsrx_en_i !== clk_term_en_i) || (hsrx_en_i !== term_en_i)) begin
          fail($sformatf("HS receiver and termination enables differ: clock lane %b / %b, data lanes %b / %b",
                         clk_hsrx_en_i, clk_term_en_i, hsrx_en_i, term_en_i));
        end
      end
      en_q   <= des_rst_en_i;
      gate_q <= gate_i;
    end
  end

  // ---------------------------------------------------------------- bus domain
  logic barmed_q = 1'b0, bvalid_q, seen_ready_q, ready_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      barmed_q     <= 1'b1;
      bvalid_q     <= 1'b0;
      seen_ready_q <= 1'b0;
      ready_q      <= 1'b0;
    end else begin
      bvalid_q <= barmed_q;
      if (bvalid_q) begin
        n_bus++;
        if (ready_i) n_ready++;
        if (dly_own_i != '0) n_own++;
        if ((clk_lprx_en_i !== !pd_i) || (lprx_en_i !== {Lanes{!pd_i}})) begin
          fail($sformatf("lprx_en %b / %b with pd %b", clk_lprx_en_i, lprx_en_i, pd_i));
        end
        if (lane_pd_i !== {Lanes{clk_lane_pd_i}}) fail("lane_pd differs between the lanes");
        if (pd_i && !clk_lane_pd_i) fail("lane_pd 0 while pd");
        if (!clk_lane_pd_i && !seen_ready_q && !ready_i) fail("lane_pd 0 before the AFE was ready");
        if ((dly_own_i != '0) && !ready_i && !ready_q) begin
          fail($sformatf("dly_own %b while the AFE is not ready", dly_own_i));
        end
        if ((clk_dly_code_i != '0) || clk_dly_own_i || (mon_en_i != '0) || (mon_code_i != '0) ||
            (trim_i != '0) || (tst_mode_i != '0) || (tst_data_i != '0) || (atb_sel_i != '0)) begin
          fail("a v1 tie-off (clock lane delay, monitor, trim, test hooks) is not 0");
        end
      end
      if (pd_i) seen_ready_q <= 1'b0;
      else if (ready_i) seen_ready_q <= 1'b1;
      ready_q <= ready_i;
    end
  end

  final begin
    if (Report || $test$plusargs("afe_chk_report")) begin
      $display("%m: AFE v1 checks passed: %0d lp clock cycles (%0d with des_rst, %0d gate openings), %0d bus clock cycles (%0d ready, %0d with a dly_own)",
               n_lp, n_des_rst, n_gate, n_bus, n_ready, n_own);
    end
  end

endmodule
