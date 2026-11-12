// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Checker of the PPI v1 outputs of bow_dphy_rx that the CSI-2 controller does not use yet
// (docs/ip/mipi_rx_arch.md, sections 4.9, 5.2, 5.3), against the inputs of the LP state
// machines: their filtered LP levels, their synchronised enables and CLK_CONT. Neither the
// equivalence check (no reference has these outputs) nor the controller's tests see them;
// step 3 and later build on them. A testbench binds it into every bow_dphy_rx:
//
//   bind bow_dphy_rx bow_ppi_chk #(.Lanes (Lanes)) u_ppi_chk (
//     .lp_clk_i, .lp_rst_ni (lrst_n), .byte_clk_i, .byte_rst_ni (brst_n),
//     .ppi_hs_i (ppi_hs_o), .ppi_lp_i (ppi_lp_o), .ppi_lp_clk_i (ppi_lp_clk_o),
//     .lane_en_i (lane_en), .lp_i (lp_st), .clk_force_i (clk_force), .byte_ce_i (byte_ce));
//
// Properties, on every lp clock edge from the second one after a reset; t = the cycle
// that ends at the edge, [0] = clock lane, [1 + l] = data lane l:
//   Stopstate[l], StopstateClk
//     * Stopstate(t) only if the lane was enabled and in LP-11 at t-1 (clock lane: LP-11 at
//       t-1, t-2 or t-3, the two cycles of Exit after LP-11 in HS; staying in Stop: LP-11 at
//       t-1). So it rises only with LP-11 on an enabled lane and falls at any other LP state
//       (LP-01: HS request) and when the lane is disabled.
//     * an enabled lane that was in LP-11 for 12 cycles is in Stop (the longest way there
//       is Disable, 8 cycles, then Off and WaitStop).
//   ErrControl[l], ErrControlClk: bit 0 is a one cycle pulse, only on a lane that was
//     enabled and not in LP-11 the cycle before, never with Stopstate; bit 1 is 0. The
//     D-PHY's masks (step 4): ErrControl[l] only while the lane's Enable is high,
//     ErrControlClk never while CTRL.CLK_CONT.
//   RxClkActiveHS: equals the byte clock gate (byte_ce_o); only on an enabled clock lane;
//     together with StopstateClk only under CLK_CONT (v1: the gate, section 5.3).
//   Idle values (v1): UlpsActiveNot, UlpsActiveNotClk, RxUlpsClkNot 1; RxUlpsEsc 0;
//     ErrEsc, ErrSyncEsc 0; ErrSotHS 0 (byte domain).
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
  input logic                clk_force_i,   // synchronised CTRL.CLK_CONT (CLK_FORCE before step 4)
  input logic                byte_ce_i      // byte clock gate (byte_ce_o)
);

  localparam int unsigned N = Lanes + 1;
  localparam int unsigned StopRun = 12;

  logic [N-1:0] stop, err, en, lp11;
  logic         act;

  always_comb begin
    stop[0] = ppi_lp_clk_i.stopstate;
    err[0]  = ppi_lp_clk_i.err_control[0];
    for (int unsigned l = 0; l < Lanes; l++) begin
      stop[1 + l] = ppi_lp_i[l].stopstate;
      err[1 + l]  = ppi_lp_i[l].err_control[0];
    end
    en  = lane_en_i;
    act = ppi_lp_clk_i.rx_clk_active_hs;
    for (int unsigned i = 0; i < N; i++) lp11[i] = (lp_i[i] == 2'b11);
  end

  // values of the cycles before: _q = t-1, _q2 = t-2, _q3 = t-3
  logic [N-1:0]      en_q, lp11_q, lp11_q2, lp11_q3, stop_q, err_q;
  logic [N-1:0][4:0] run_q;           // cycles in a row enabled in LP-11, up to t-1
  logic              force_q, valid_q;
  logic              armed_q = 1'b0;  // a reset was seen (two-state simulators start
                                      // with the reset already low, without an edge)

  int unsigned n_cycles = 0, n_live = 0, n_act = 0, n_forced = 0;
  int unsigned n_stop [N], n_err [N];
  initial begin
    for (int unsigned i = 0; i < N; i++) begin
      n_stop[i] = 0;
      n_err[i]  = 0;
    end
  end

  function automatic string lane_name(int unsigned i);
    return (i == 0) ? "clock lane" : $sformatf("data lane %0d", i - 1);
  endfunction

  function automatic void fail(string what);
    $fatal(1, "PPI v1 check failed: %s", what);
  endfunction

  always @(posedge lp_clk_i or negedge lp_rst_ni) begin
    if (!lp_rst_ni) begin
      armed_q <= 1'b1;
      valid_q <= 1'b0;
      en_q    <= '0;
      lp11_q  <= '0;
      lp11_q2 <= '0;
      lp11_q3 <= '0;
      stop_q  <= '0;
      err_q   <= '0;
      run_q   <= '0;
      force_q <= 1'b0;
    end else begin
      valid_q <= armed_q;
      if (valid_q) begin
        n_cycles++;
        for (int unsigned i = 0; i < N; i++) begin
          if (stop[i] && !stop_q[i]) n_stop[i]++;
          if (err[i]) n_err[i]++;
          // Stopstate
          if (stop[i] && !en_q[i]) begin
            fail($sformatf("Stopstate of the %s, which was disabled", lane_name(i)));
          end
          if (stop[i] && !lp11_q[i] && (i != 0 || stop_q[i] || !(lp11_q2[i] || lp11_q3[i]))) begin
            fail($sformatf("Stopstate of the %s without LP-11", lane_name(i)));
          end
          if (run_q[i] >= 5'(StopRun)) begin
            n_live++;
            if (!stop[i]) begin
              fail($sformatf("no Stopstate of the %s after %0d cycles enabled in LP-11",
                             lane_name(i), StopRun));
            end
          end
          // ErrControl, ErrControlClk
          if (err[i] && (err_q[i] || !en_q[i] || lp11_q[i] || stop[i])) begin
            fail($sformatf("ErrControl of the %s: not a single pulse after a wrong LP state of an enabled lane (pulse at t-1 %0d, enabled %0d, LP-11 %0d, Stopstate %0d)",
                           lane_name(i), err_q[i], en_q[i], lp11_q[i], stop[i]));
          end
          // the D-PHY's masks (step 4): a data lane's error only while it is enabled
          if (i != 0 && err[i] && !en[i]) begin
            fail($sformatf("ErrControl of the %s while its Enable is low", lane_name(i)));
          end
        end
        if (err[0] && clk_force_i) fail("ErrControlClk while CTRL.CLK_CONT");
        // RxClkActiveHS
        if (act) n_act++;
        if (act && stop[0]) n_forced++;
        if (act != byte_ce_i) fail("RxClkActiveHS is not the byte clock gate");
        if (act && !en_q[0]) fail("RxClkActiveHS on a disabled clock lane");
        if (act && stop[0] && !force_q) fail("RxClkActiveHS with StopstateClk without CLK_CONT");
        // bit 1 of the error signals and the idle values
        if (ppi_lp_clk_i.err_control[1] || !ppi_lp_clk_i.ulps_active_not ||
            !ppi_lp_clk_i.rx_ulps_clk_not) begin
          fail("ErrControlClk[1], UlpsActiveNotClk or RxUlpsClkNot not at its v1 value");
        end
        for (int unsigned l = 0; l < Lanes; l++) begin
          if (ppi_lp_i[l].err_control[1] || !ppi_lp_i[l].ulps_active_not ||
              ppi_lp_i[l].rx_ulps_esc || (ppi_lp_i[l].err_esc != 2'b00) ||
              (ppi_lp_i[l].err_sync_esc != 2'b00)) begin
            fail($sformatf("ErrControl[1], ULPS or escape signal of data lane %0d not at its v1 value", l));
          end
        end
      end
      en_q    <= en;
      lp11_q  <= lp11;
      lp11_q2 <= lp11_q;
      lp11_q3 <= lp11_q2;
      stop_q  <= stop;
      err_q   <= err;
      force_q <= clk_force_i;
      for (int unsigned i = 0; i < N; i++) begin
        run_q[i] <= !(en[i] && lp11[i]) ? 5'd0 : (run_q[i] == 5'd31) ? 5'd31 : run_q[i] + 5'd1;
      end
    end
  end

  // byte domain: ErrSotHS (v2)
  always @(posedge byte_clk_i) begin
    if (armed_q && byte_rst_ni) begin
      for (int unsigned l = 0; l < Lanes; l++) begin
        if (ppi_hs_i[l].err_sot_hs) fail($sformatf("ErrSotHS of data lane %0d (v1: 0)", l));
      end
    end
  end

  string per_lane;

  final begin
    if (Report || $test$plusargs("ppi_chk_report")) begin
      per_lane = "";
      for (int unsigned i = 0; i < N; i++) begin
        per_lane = {per_lane, $sformatf(", %s %0d Stopstate / %0d ErrControl", lane_name(i),
                                        n_stop[i], n_err[i])};
      end
      $display("%m: PPI v1 checks passed: %0d lp clock cycles (%0d lane cycles 12 or more in LP-11 and enabled: in Stop), RxClkActiveHS %0d cycles (%0d with StopstateClk)%s",
               n_cycles, n_live, n_act, n_forced, per_lane);
    end
  end

endmodule
