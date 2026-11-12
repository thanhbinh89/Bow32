// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Fabric logic of the Versal AFE adapter bow_dphy_io_versal (XPHY, native strobe mode),
// without a primitive (step 5 of docs/ip/mipi_rx_arch.md, sections 3.5, 3.7 and 10): the
// input delay control of the XPHY data slices and the receive path reset, in the CTRL_CLK
// domain. The tests of the receiver run it in Verilator (csi2_tx_model instantiates it),
// xsim with the XPHY model (hw/fpga/common/dv/tb_bow_dphy_io_versal.sv).
//
// Input delays (AFE interface: dly_code / dly_own static levels, the AFE applies a change
// by itself; the delay in use, dly_q, is CNTVALUEOUT of the XPHY, outside this module):
//   * dly_code_i / dly_own_i are flops of the D-PHY's register file (bus clock): one
//     synchroniser per bit (u_sync_code, u_sync_own) and a value is taken once it was the
//     same in two consecutive cycles. The bits of a lane are written in one bus cycle and
//     the board XDC bounds their skew to one CTRL_CLK period (set_bus_skew): a mix of old
//     and new bits shows for one cycle at most and is never taken.
//   * A lane loads when its dly_own rises (also with the code it had) or its code changes
//     while dly_own = 1, and only while ready_i (a load before the PHY is ready would be
//     lost; the D-PHY clears OWN while READY = 0, so the first code after a restart comes
//     with a rise of OWN). The first load of a lane after ready puts its slice into user
//     mode (RX_EN_VTC = 0, "PL updates" in AM010) and happens VtcWait cycles later; then
//     LD = 1 for one cycle with CNTVALUEIN = the code (CE = INC = RXTX_SEL = 0 in the
//     adapter). Loads of a lane are >= LdGap cycles apart (AM010: >= 3); a change that
//     arrives while a load is pending replaces its code (the newest one is loaded).
//   * dly_own 1 -> 0 (OWN released): the XPHY cannot give a lane its BISC delay back
//     (INFO[30] = 0 of the D-PHY): the lane keeps the code it has and stays in user mode;
//     the next rise of dly_own loads again, also the same code. Only a restart of the PHY
//     (ready_i falls: pd / cal_start, or a loss of XPLL lock) ends user mode on every lane:
//     VT tracking again from the new BISC delay.
//   * Against step 4 (the D-PHY's g_dly_vid made one load request per DLYn write, 16 lp
//     cycles apart, and bow_dphy_io_versal ran this sequencer on the requests): the same
//     codes reach the XPHY with the same VtcWait / LdGap sequence, ~4 CTRL_CLK cycles sooner
//     after the bus write (no request counter, no 16 cycle spacing); a write of the code in
//     use (OWN already 1) no longer loads it again.
// Receive path reset (des_rst): rx_rst_o = ready_i & des_rst_i, registered: RX_RST of the
// data slices (with the init reset in the adapter) from the cycle after the byte clock gate
// closed until the cycle after it opened, while the clock lane is static (PA5 = 1 of the
// board runs): the burst_rst_q of step 4, which took ~CTRL.DES_RST_DIS and the gate. des_rst
// is a flop of the receiver's lp domain, and CTRL_CLK must be that clock (the Huins camera
// top: clk_vid): it is used without a synchroniser, as the gate was before step 5. No
// release on byte clock edges: holding RX_RST of the strobe slice could stop FIFO_WR_CLK
// itself (docs/ip/mipi_rx_arch.md section 3.7, unverified).

module bow_dphy_dly_xphy #(
  parameter int unsigned Lanes   = 4,
  parameter int unsigned VtcWait = 12,    // CTRL_CLK cycles from RX_EN_VTC 1 -> 0 to the first LD
  parameter int unsigned LdGap   = 4      // minimum distance of two LD of a lane (AM010: >= 3)
) (
  input  logic                  clk_i,          // CTRL_CLK = the D-PHY's lp clock
  input  logic                  rst_ni,         // asynchronous assertion, release on clk_i
  input  logic                  ready_i,        // PHY ready (init sequencer flop, clk_i domain)
  // receive path reset
  input  logic                  des_rst_i,      // AFE des_rst: lp domain flop (= clk_i)
  output logic                  rx_rst_o,       // burst part of RX_RST of the data slices
  // delays
  input  logic [Lanes-1:0][8:0] dly_code_i,     // AFE dly_code: asynchronous, static
  input  logic [Lanes-1:0]      dly_own_i,      // AFE dly_own: asynchronous
  output logic [Lanes-1:0]      rx_en_vtc_o,    // RX_EN_VTC of the lane's P slice (0: user mode)
  output logic [Lanes-1:0]      ld_o,           // LD of the lane's P slice, one cycle
  output logic [Lanes-1:0][8:0] cntvaluein_o    // CNTVALUEIN of the lane's P slice
);

  if ((VtcWait > 31) || (LdGap < 1) || (LdGap > 32)) begin : g_bad_wait
    $error("bow_dphy_dly_xphy: VtcWait %0d (<= 31), LdGap %0d (1..32)", VtcWait, LdGap);
  end

  // ---------------------------------------------------------------- receive path reset
  logic burst_rst_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) burst_rst_q <= 1'b0;
    else         burst_rst_q <= ready_i & des_rst_i;
  end

  assign rx_rst_o = burst_rst_q;

  // ---------------------------------------------------------------- input delays
  logic [Lanes-1:0][8:0] code_s;
  logic [Lanes-1:0]      own_s;

  bow_sync_bus #(
    .Width (9 * Lanes)
  ) u_sync_code (
    .clk_i,
    .rst_ni,
    .d_i (dly_code_i),
    .q_o (code_s)
  );

  bow_sync_bus #(
    .Width (Lanes)
  ) u_sync_own (
    .clk_i,
    .rst_ni,
    .d_i (dly_own_i),
    .q_o (own_s)
  );

  // Per lane: code_last_q / own_last_q = the synchronised values of the cycle before,
  // app_own_q / app_code_q = the lane uses the D-PHY's code (a load done or pending since the
  // last rise of dly_own) and which one, user_q = user mode (RX_EN_VTC = 0), pend_q = a load
  // is waiting, wait_q = cycles until it may happen, cntin_q = the code of the next / last
  // load. Next state in blocking variables, one non-blocking write per register (xsim note
  // in bow_dphy_io_versal).
  logic [Lanes-1:0][8:0] code_last_q, app_code_q, cntin_q;
  logic [Lanes-1:0]      own_last_q, app_own_q, user_q, pend_q, ld_q;
  logic [Lanes-1:0][4:0] wait_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    logic [Lanes-1:0]      stable, req, app_own_d, user_d, pend_d, ld_d;
    logic [Lanes-1:0][8:0] app_code_d, cntin_d;
    logic [Lanes-1:0][4:0] wait_d;
    if (!rst_ni) begin
      code_last_q <= '0;
      own_last_q  <= '0;
      app_own_q   <= '0;
      app_code_q  <= '0;
      user_q      <= '0;
      pend_q      <= '0;
      ld_q        <= '0;
      cntin_q     <= '0;
      wait_q      <= '0;
    end else begin
      app_own_d  = app_own_q;
      app_code_d = app_code_q;
      user_d     = user_q;
      pend_d     = pend_q;
      ld_d       = '0;
      cntin_d    = cntin_q;
      wait_d     = wait_q;
      for (int unsigned l = 0; l < Lanes; l++) begin
        stable[l] = (code_s[l] == code_last_q[l]) && (own_s[l] == own_last_q[l]);
        req[l]    = stable[l] && own_s[l] && (!app_own_q[l] || (code_s[l] != app_code_q[l]));
      end
      if (!ready_i) begin
        app_own_d = '0;
        user_d    = '0;
        pend_d    = '0;
        wait_d    = '0;
      end else begin
        for (int unsigned l = 0; l < Lanes; l++) begin
          if (wait_q[l] != 5'd0) wait_d[l] = wait_q[l] - 5'd1;
          if (pend_q[l] && (wait_q[l] == 5'd0)) begin
            ld_d[l]   = 1'b1;                     // XPHY samples LD and cntin_q next edge
            pend_d[l] = 1'b0;
            wait_d[l] = 5'(LdGap - 1);
          end
          if (req[l]) begin                       // the newest code wins
            cntin_d[l]    = code_s[l];
            pend_d[l]     = 1'b1;
            app_own_d[l]  = 1'b1;
            app_code_d[l] = code_s[l];
            if (!user_q[l]) begin
              user_d[l] = 1'b1;                   // RX_EN_VTC -> 0 first
              wait_d[l] = 5'(VtcWait);
            end
          end else if (stable[l] && !own_s[l]) begin
            app_own_d[l] = 1'b0;                  // released: the next rise loads again
          end
        end
      end
      code_last_q <= code_s;
      own_last_q  <= own_s;
      app_own_q   <= app_own_d;
      app_code_q  <= app_code_d;
      user_q      <= user_d;
      pend_q      <= pend_d;
      ld_q        <= ld_d;
      cntin_q     <= cntin_d;
      wait_q      <= wait_d;
    end
  end

  assign rx_en_vtc_o  = ~user_q;
  assign ld_o         = ld_q;
  assign cntvaluein_o = cntin_q;

endmodule
