// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Unit test of the AFE adapters' logic without primitives (step 5 of docs/ip/mipi_rx_arch.md,
// sections 3.5 and 3.7; make -C hw/ip/csi2rx/dv afe, part of test-rx and CI):
// bow_dphy_dly_xusp (UltraScale+ adapter, KV260) and bow_dphy_dly_xphy (Versal adapter,
// Huins), each against a model of the primitives it drives, driven as the D-PHY drives the
// AFE interface: the delay code and OWN of a lane change in one bus clock cycle, at any phase
// of the adapter's clock, each bit arriving up to SkewNs later (below one period of that
// clock: the bound of the board XDC's set_bus_skew, so its edges see mixes of old and new
// bits for one cycle at most), the gate and des_rst are lp clock flops changed at the same
// edge, ready is a CTRL_CLK flop of the Versal adapter. The whole receiver bench runs the
// same modules (csi2_tx_model) but cannot reach several of the rules below; mutants_rx.py
// has their mutants.
//
// UltraScale+ (2 lanes; byte clock 114 MHz, gated as BUFGCE_DIV with CE_TYPE SYNC):
//   * ISERDESE3 RST: 1 while des_rst is 1, so whenever the gate opens after des_rst, and at
//     the first two byte clock edges after des_rst fell (the gate opened), 0 from the third;
//     with DES_RST_DIS (des_rst held at 0) not set again;
//   * IDELAYE3 LOAD: every LOAD changes the tap, to a target (OWN ? code : 0) the lane had
//     since the last check point (never a mix of two codes); at every check point the loads
//     of each lane since the last one (one per change of the target while the byte clock
//     runs: none for a rewrite of the code in use, none for a code change while OWN = 0,
//     none while the byte clock is stopped, until it runs) and the taps (= targets);
//   * random writes, gate openings and DES_RST_DIS, then the taps.
// Versal (4 lanes, VtcWait 12, LdGap 4, CTRL_CLK = lp clock 200 MHz):
//   * RX_RST = ready & des_rst of the cycle before (one flop): 0 while the PHY is not ready;
//   * after a cycle with ready = 0: RX_EN_VTC = 1 on every lane, no LD (state cleared);
//   * the XPHY load contract: LD one cycle, RX_EN_VTC 0 for >= VtcWait cycles before it,
//     LDs of a lane >= LdGap cycles apart, CNTVALUEIN a code the lane had since the last
//     check point;
//   * per check point the LDs of each lane and the XPHY delay of the lanes with OWN: OWN
//     rises (also with the code it had before) -> one LD; a code change while OWN -> one;
//     the code in use written again -> none; codes written during the VtcWait -> one LD
//     of the newest; OWN falls -> none, user mode stays; OWN rises again -> one LD of the
//     same code; ready falls and rises with OWN still 1 (an AFE restart the D-PHY did not
//     see yet) -> the code of every OWN lane loaded again (the XPHY lost it);
//   * random writes, restarts (with OWN cleared after READY falls, as the D-PHY does, or
//     kept) and des_rst changes, then the delays of the OWN lanes.
// Prints "tb_afe_dly: PASS (<n> checks)" or "tb_afe_dly: FAIL (<n> errors)".

`timescale 1ns / 1ps

module tb_afe_dly;

  localparam int unsigned XL = 2;                 // UltraScale+ lanes (KV260)
  localparam int unsigned VL = 4;                 // Versal lanes (Huins)
  localparam int unsigned VtcWait = 12, LdGap = 4;
  localparam realtime     TBus = 20.0, TLp = 5.0, TByte = 8.772;
  localparam realtime     XSkewNs = 8.0, VSkewNs = 4.5;

  int unsigned errors = 0, checks = 0;

  function automatic void err(string msg);
    errors++;
    if (errors <= 30) $display("[%0t] ERROR: %s", $time, msg);
  endfunction

  logic clk = 1'b0, lpclk = 1'b0, hs_bclk = 1'b0;
  initial begin
    #3;
    forever #(TBus / 2) clk = ~clk;
  end
  always #(TLp / 2) lpclk = ~lpclk;
  initial begin
    #1.3;
    forever #(TByte / 2) hs_bclk = ~hs_bclk;
  end

  // ===================================================================== UltraScale+
  logic               x_gate = 1'b0, x_des_rst = 1'b0, x_des_rst_en = 1'b1, x_ce = 1'b0;
  logic [XL-1:0][8:0] x_code = '0;
  logic [XL-1:0]      x_own = '0;
  logic               x_iserdes_rst, bclk;
  logic [XL-1:0][8:0] x_cntin;
  logic [XL-1:0]      x_load;

  // BUFGCE_DIV, CE_TYPE SYNC: the gate takes effect while the clock is low (no runt)
  always @(negedge hs_bclk) x_ce <= x_gate;
  assign bclk = hs_bclk & x_ce;

  bow_dphy_dly_xusp #(
    .Lanes (XL)
  ) u_xusp (
    .byte_clk_i    (bclk),
    .des_rst_i     (x_des_rst),
    .iserdes_rst_o (x_iserdes_rst),
    .dly_code_i    (x_code),
    .dly_own_i     (x_own),
    .cntvaluein_o  (x_cntin),
    .load_o        (x_load)
  );

  // bench side: the target of every lane as written, the targets since the last check point
  logic [XL-1:0][8:0]   x_tgt = '0;
  logic [XL-1:0][511:0] x_legal = '0;
  // IDELAYE3 model, loads per lane, byte clock edges since the gate opened
  logic [XL-1:0][8:0]   x_tap = '0;
  int unsigned          x_nload [XL] = '{default: 0};
  int unsigned          x_rcnt = 2, x_rst_edges = 0;   // byte clock edges since des_rst fell

  initial for (int l = 0; l < int'(XL); l++) x_legal[l][0] = 1'b1;

  always @(posedge bclk) begin
    checks++;
    // ISERDESE3 RST (bow_rst_sync on des_rst): 1 at once while des_rst is 1, then at the
    // first two byte clock edges after des_rst fell (a gate opening), 0 from the third; with
    // DES_RST_DIS (des_rst 0) never set again
    if (x_iserdes_rst !== (x_des_rst || x_rcnt < 2)) begin
      err($sformatf("ISERDESE3 RST %b at a byte clock edge: des_rst %b, %0d edges since it fell",
                    x_iserdes_rst, x_des_rst, x_rcnt));
    end
    if (x_iserdes_rst) x_rst_edges++;
    if (!x_des_rst && x_rcnt < 2) x_rcnt++;
    for (int l = 0; l < int'(XL); l++) begin
      if (x_load[l]) begin
        x_nload[l]++;
        if (x_cntin[l] == x_tap[l]) err($sformatf("lane %0d: LOAD of the tap in use %0d", l, x_tap[l]));
        if (!x_legal[l][x_cntin[l]]) begin
          err($sformatf("lane %0d: LOAD of %0d, not a target of the lane (a mix?)", l, x_cntin[l]));
        end
        x_tap[l] = x_cntin[l];
      end
    end
  end

  // byte clock edges at which the inputs show a mix of two writes (a target that is neither
  // the old nor the new one): the skewed writes must make some
  logic [XL-1:0][8:0] x_tgt_old = '0;
  int unsigned        x_mixes = 0;
  always @(posedge bclk) begin
    for (int l = 0; l < int'(XL); l++) begin
      if ((x_own[l] ? x_code[l] : 9'd0) != x_tgt[l] &&
          (x_own[l] ? x_code[l] : 9'd0) != x_tgt_old[l]) x_mixes++;
    end
  end

  // des_rst and the gate: lp clock flops of the D-PHY, set at the same edge
  task automatic x_gate_set(input bit open);
    @(posedge lpclk);
    #0.1;
    if (open) begin
      checks++;
      if (x_des_rst && (x_iserdes_rst !== 1'b1)) err("gate opens while the ISERDESE3 is out of reset");
    end
    x_gate    = open;
    x_des_rst = !open && x_des_rst_en;
  endtask

  always @(posedge lpclk) begin
    if (x_des_rst && x_iserdes_rst !== 1'b1) err("ISERDESE3 RST 0 while des_rst is 1");
  end

  always @(posedge x_des_rst) x_rcnt = 0;


  // A write of DLYn as the D-PHY's register file makes it: code and OWN of the lane in one
  // bus clock cycle. skew: the bus clock edge at any phase of the byte clock (the clocks are
  // asynchronous) and each bit arriving 0 .. XSkewNs after it, so that byte clock edges see
  // mixes of old and new bits
  task automatic x_write(input int l, input logic [8:0] code, input bit own, input bit skew);
    logic [9:0] v;
    realtime    base;
    @(posedge clk);
    #0.1;
    v    = {own, code};
    base = skew ? real'($urandom_range(0, 999)) / 1000.0 * TByte : 0.0;
    x_tgt_old[l] = x_tgt[l];
    x_tgt[l]     = own ? code : 9'd0;
    x_legal[l][x_tgt[l]] = 1'b1;
    for (int b = 0; b < 10; b++) begin
      automatic int      bb = b;
      automatic int      ll = l;
      automatic logic    vb = v[b];
      automatic realtime d  = skew ? base + real'($urandom_range(0, 1000)) / 1000.0 * XSkewNs : 0.0;
      fork
        begin
          if (d > 0.0) #(d);
          if (bb < 9) x_code[ll][bb] = vb;
          else        x_own[ll] = vb;
        end
      join_none
    end
  endtask

  task automatic x_bytes(input int n);           // n byte clock periods (no #0: Verilator
    if (n > 0) #(n * TByte);                      // 5.020 can hang on two in a row)
  endtask

  // check point: loads of every lane since the last one (-1: any), the taps (byte clock
  // running long enough), then only the targets of now are legal
  int unsigned x_nload0 [XL] = '{default: 0};
  string       x_last = "start";
  task automatic x_check(input string what, input int exp0, input int exp1 = 0);
    int exp [XL];
    x_last = what;
    exp[0] = exp0;
    if (XL > 1) exp[1] = exp1;
    for (int l = 0; l < int'(XL); l++) begin
      checks++;
      if (exp[l] >= 0 && x_nload[l] - x_nload0[l] != exp[l]) begin
        err($sformatf("%s: lane %0d: %0d LOADs, want %0d", what, l, x_nload[l] - x_nload0[l], exp[l]));
      end
      if (x_gate && x_tap[l] != x_tgt[l]) begin
        err($sformatf("%s: lane %0d: tap %0d, want %0d (OWN %b code %0d)", what, l, x_tap[l],
                      x_tgt[l], x_own[l], x_code[l]));
      end
      x_nload0[l] = x_nload[l];
      x_legal[l]  = '0;
      x_legal[l][x_tgt[l]] = 1'b1;
    end
  endtask

  task automatic run_xusp();
    int unsigned bursts = 0;
    #1;
    x_des_rst = 1'b1;                             // as after the D-PHY's reset (a real edge)
    #20;
    x_gate_set(1'b1);
    x_bytes(30);
    x_check("after start, OWN 0", 0, 0);
    x_write(0, 9'd100, 1'b1, 1'b0);               // OWN rises: one load
    x_bytes(10);
    x_check("lane 0 OWN + code 100", 1, 0);
    x_write(0, 9'd100, 1'b1, 1'b0);               // the code in use: none
    x_bytes(10);
    x_check("lane 0 code 100 again", 0, 0);
    x_gate_set(1'b0);                             // byte clock stopped
    x_write(1, 9'd37, 1'b1, 1'b0);
    #200;
    x_check("lane 1 written, byte clock stopped", 0, -1);
    if (x_nload[1] != x_nload0[1]) err("lane 1 loaded without a byte clock");
    x_gate_set(1'b1);                             // next burst: loaded
    x_bytes(10);
    x_check("lane 1 code 37 at the next burst", 0, 1);
    x_write(0, 9'd200, 1'b1, 1'b0);
    x_bytes(10);
    x_check("lane 0 code 200", 1, 0);
    x_write(0, 9'd200, 1'b0, 1'b0);               // OWN falls: tap 0
    x_bytes(10);
    x_check("lane 0 OWN falls", 1, 0);
    x_write(0, 9'd300, 1'b0, 1'b0);               // code change while OWN 0: none
    x_bytes(10);
    x_check("lane 0 code 300, OWN 0", 0, 0);
    x_write(0, 9'd300, 1'b1, 1'b0);               // OWN rises: the code
    x_bytes(10);
    x_check("lane 0 OWN rises with 300", 1, 0);
    x_write(1, 9'd0, 1'b1, 1'b0);                 // code 0 with OWN: tap 0
    x_bytes(10);
    x_check("lane 1 code 0", 0, 1);
    x_write(1, 9'd0, 1'b0, 1'b0);                 // OWN falls, tap 0 already: none
    x_bytes(10);
    x_check("lane 1 OWN falls on tap 0", 0, 0);
    // codes and OWN with their bits skewed (one byte clock at most): never a mix
    for (int i = 0; i < 40; i++) begin
      automatic int          l = i % int'(XL);
      automatic logic [8:0]  c = 9'($urandom_range(1, 511));
      automatic logic [8:0]  t0 = x_tgt[l];
      automatic bit          o = (i % 7 != 3);
      x_write(l, c, o, 1'b1);
      x_bytes(12);
      x_check($sformatf("skewed write %0d", i), (l == 0) ? int'((o ? c : 9'd0) != t0) : 0,
              (l == 1) ? int'((o ? c : 9'd0) != t0) : 0);
    end
    // two writes one bus cycle apart: the first may be loaded or not, the last is
    x_write(0, 9'd11, 1'b1, 1'b0);
    x_write(0, 9'd12, 1'b1, 1'b0);
    x_bytes(12);
    if (x_nload[0] - x_nload0[0] < 1 || x_nload[0] - x_nload0[0] > 2) err("two close writes: loads");
    x_check("two close writes", -1, 0);
    // gate openings with and without DES_RST_DIS
    for (int i = 0; i < 12; i++) begin
      automatic int unsigned w = $urandom_range(20, 300);
      x_des_rst_en = (i % 4 != 2);
      x_gate_set(1'b0);
      #(w);
      x_gate_set(1'b1);
      bursts++;
      x_bytes($urandom_range(3, 40));
    end
    x_des_rst_en = 1'b1;
    x_check("gate openings", 0, 0);
    // random: writes with the clock running or stopped, skewed or not
    for (int i = 0; i < 300; i++) begin
      unique case ($urandom_range(0, 9))
        0: begin
          x_gate_set(!x_gate);
          if (x_gate) bursts++;
        end
        1: x_des_rst_en = !x_des_rst_en;
        default: x_write($urandom_range(0, XL - 1), 9'($urandom_range(0, 511)),
                         $urandom_range(0, 3) != 0, $urandom_range(0, 1));
      endcase
      x_bytes($urandom_range(0, 6));
      if (i % 25 == 24) begin                      // check point: clock running
        if (!x_gate) begin
          x_gate_set(1'b1);
          bursts++;
        end
        x_bytes(12);
        x_check($sformatf("random %0d", i), -1, -1);
      end
    end
    x_des_rst_en = 1'b1;
    if (!x_gate) x_gate_set(1'b1);
    x_bytes(12);
    x_check("random end", -1, -1);
    $display("tb_afe_dly: UltraScale+: %0d / %0d IDELAYE3 loads, %0d gate openings, %0d byte clock edges with ISERDESE3 RST, %0d with a mix of two writes at the inputs",
             x_nload[0], x_nload[1], bursts + 2, x_rst_edges, x_mixes);
  endtask

  // ========================================================================= Versal
  logic               v_rst_n = 1'b0, v_ready = 1'b0, v_des_rst = 1'b1;
  logic [VL-1:0][8:0] v_code = '0;
  logic [VL-1:0]      v_own = '0;
  logic               v_rx_rst;
  logic [VL-1:0]      v_vtc, v_ld;
  logic [VL-1:0][8:0] v_cntin;

  bow_dphy_dly_xphy #(
    .Lanes   (VL),
    .VtcWait (VtcWait),
    .LdGap   (LdGap)
  ) u_xphy (
    .clk_i        (lpclk),
    .rst_ni       (v_rst_n),
    .ready_i      (v_ready),
    .des_rst_i    (v_des_rst),
    .rx_rst_o     (v_rx_rst),
    .dly_code_i   (v_code),
    .dly_own_i    (v_own),
    .rx_en_vtc_o  (v_vtc),
    .ld_o         (v_ld),
    .cntvaluein_o (v_cntin)
  );

  // XPHY model: the delay of each lane (BISC after a restart, the code of an LD), the
  // contract counters; bench side: the codes since the last check point
  logic [VL-1:0][8:0]   v_tap = '0, v_bisc = {9'd120, 9'd88, 9'd112, 9'd97};
  logic [VL-1:0][511:0] v_legal = '0;
  logic [VL-1:0]        v_ld_q = '0;
  logic                 v_ready_q = 1'b0, v_des_rst_q = 1'b0, v_armed = 1'b0;
  int unsigned          v_nld [VL] = '{default: 0}, v_nld0 [VL] = '{default: 0};
  int unsigned          v_vtc_cnt [VL] = '{default: 0}, v_gap [VL] = '{default: 99};
  int unsigned          v_restarts = 0;

  always @(posedge lpclk) begin
    if (v_armed) begin
      checks++;
      if (v_rx_rst !== (v_ready_q && v_des_rst_q)) begin
        err($sformatf("RX_RST %b, want ready %b & des_rst %b of the cycle before", v_rx_rst,
                      v_ready_q, v_des_rst_q));
      end
      if (!v_ready_q && (v_vtc !== '1)) err($sformatf("RX_EN_VTC %b after a cycle with ready 0", v_vtc));
      if (!v_ready_q && (v_ld !== '0)) err($sformatf("LD %b after a cycle with ready 0", v_ld));
      for (int l = 0; l < int'(VL); l++) begin
        if (v_vtc[l]) v_vtc_cnt[l] = 0;
        else if (v_vtc_cnt[l] < 99) v_vtc_cnt[l]++;
        if (v_gap[l] < 99) v_gap[l]++;
        if (v_ld[l]) begin
          v_nld[l]++;
          if (v_ld_q[l]) err($sformatf("lane %0d: LD longer than one cycle", l));
          if (v_vtc[l] || v_vtc_cnt[l] < VtcWait) begin
            err($sformatf("lane %0d: LD %0d cycles after RX_EN_VTC fell (RX_EN_VTC %b, want >= %0d)",
                          l, v_vtc_cnt[l], v_vtc[l], VtcWait));
          end
          if (v_gap[l] < LdGap) err($sformatf("lane %0d: LD %0d cycles after the previous one", l, v_gap[l]));
          if (!v_legal[l][v_cntin[l]]) err($sformatf("lane %0d: LD of %0d, not a code of the lane", l, v_cntin[l]));
          v_tap[l] = v_cntin[l];
          v_gap[l] = 0;
        end
      end
    end
    if (!v_ready) v_tap = v_bisc;                    // PHY in its init: the loaded codes are lost
    v_ready_q   <= v_ready;
    v_des_rst_q <= v_des_rst;
    v_ld_q      <= v_ld;
  end

  logic [VL-1:0][8:0] v_code_old = '0, v_code_new = '0;
  int unsigned        v_mixes = 0;
  always @(posedge lpclk) begin
    for (int l = 0; l < int'(VL); l++) begin
      if (v_code[l] != v_code_new[l] && v_code[l] != v_code_old[l]) v_mixes++;
    end
  end

  task automatic v_write(input int l, input logic [8:0] code, input bit own, input bit skew);
    logic [9:0] v;
    realtime    base;
    @(posedge clk);
    #0.1;
    v    = {own, code};
    base = skew ? real'($urandom_range(0, 999)) / 1000.0 * TLp : 0.0;   // as x_write
    v_code_old[l] = v_code_new[l];
    v_code_new[l] = code;
    v_legal[l][code] = 1'b1;
    for (int b = 0; b < 10; b++) begin
      automatic int      bb = b;
      automatic int      ll = l;
      automatic logic    vb = v[b];
      automatic realtime d  = skew ? base + real'($urandom_range(0, 1000)) / 1000.0 * VSkewNs : 0.0;
      fork
        begin
          if (d > 0.0) #(d);
          if (bb < 9) v_code[ll][bb] = vb;
          else        v_own[ll] = vb;
        end
      join_none
    end
  endtask

  task automatic v_cycles(input int n);
    repeat (n) @(posedge lpclk);
  endtask

  task automatic v_set_ready(input bit r);              // a CTRL_CLK flop of the adapter
    @(posedge lpclk);
    #0.1;
    if (!r) begin
      v_restarts++;
      for (int l = 0; l < int'(VL); l++) v_bisc[l] = 9'($urandom_range(60, 180));
    end
    v_ready = r;
  endtask

  task automatic v_set_des_rst(input bit d);            // an lp clock flop of the D-PHY
    @(posedge lpclk);
    #0.1;
    v_des_rst = d;
  endtask

  // check point: LDs of every lane since the last one (-1: any) and, while ready, the delay
  // of every lane with OWN = its code; then only the codes of now are legal
  string v_last = "start";
  task automatic v_check(input string what, input int e0, input int e1, input int e2, input int e3);
    int exp [VL];
    v_last = what;
    exp = '{e0, e1, e2, e3};
    for (int l = 0; l < int'(VL); l++) begin
      checks++;
      if (exp[l] >= 0 && v_nld[l] - v_nld0[l] != exp[l]) begin
        err($sformatf("%s: lane %0d: %0d LDs, want %0d", what, l, v_nld[l] - v_nld0[l], exp[l]));
      end
      if (v_ready && v_own[l] && v_tap[l] != v_code[l]) begin
        err($sformatf("%s: lane %0d: XPHY delay %0d, want the code %0d (OWN 1)", what, l,
                      v_tap[l], v_code[l]));
      end
      v_nld0[l]  = v_nld[l];
      v_legal[l] = '0;
      v_legal[l][v_code[l]] = 1'b1;
    end
  endtask

  task automatic run_versal();
    int unsigned i_own;
    v_cycles(4);
    v_rst_n = 1'b1;
    v_armed = 1'b1;
    v_cycles(20);
    v_check("reset, not ready (des_rst 1)", 0, 0, 0, 0);
    v_set_ready(1'b1);
    v_cycles(40);
    v_check("ready, OWN 0", 0, 0, 0, 0);
    if (v_vtc !== '1) err("RX_EN_VTC not 1 with OWN 0");
    v_write(0, 9'd100, 1'b1, 1'b0);               // OWN rises: user mode, VtcWait, one LD
    v_cycles(40);
    v_check("lane 0 OWN + code 100", 1, 0, 0, 0);
    if (v_vtc !== 4'b1110) err($sformatf("RX_EN_VTC %b, want 1110", v_vtc));
    v_write(0, 9'd100, 1'b1, 1'b0);               // the code in use: none
    v_cycles(40);
    v_check("lane 0 code 100 again", 0, 0, 0, 0);
    v_write(0, 9'd101, 1'b1, 1'b0);               // code change in user mode: one
    v_cycles(40);
    v_check("lane 0 code 101", 1, 0, 0, 0);
    v_write(1, 9'd50, 1'b1, 1'b0);                // two codes during the VtcWait: one LD, newest
    v_write(1, 9'd60, 1'b1, 1'b0);
    v_cycles(40);
    v_check("lane 1 codes 50, 60 during the wait", 0, 1, 0, 0);
    v_write(2, 9'd5, 1'b1, 1'b0);
    v_cycles(40);
    v_check("lane 2 code 5", 0, 0, 1, 0);
    v_write(2, 9'd6, 1'b1, 1'b0);                 // three codes one bus cycle apart
    v_write(2, 9'd7, 1'b1, 1'b0);
    v_write(2, 9'd8, 1'b1, 1'b0);
    v_cycles(40);
    if (v_nld[2] - v_nld0[2] < 1 || v_nld[2] - v_nld0[2] > 3) err("lane 2: LDs of three close codes");
    v_check("lane 2 codes 6, 7, 8", 0, 0, -1, 0);
    v_write(3, 9'd200, 1'b1, 1'b0);
    v_cycles(40);
    v_check("lane 3 code 200", 0, 0, 0, 1);
    v_write(3, 9'd200, 1'b0, 1'b0);               // OWN falls: the lane keeps the code
    v_cycles(40);
    v_check("lane 3 OWN falls", 0, 0, 0, 0);
    if (v_vtc[3] !== 1'b0 || v_tap[3] != 9'd200) err("lane 3: user mode or code lost at the OWN fall");
    v_write(3, 9'd200, 1'b1, 1'b0);               // OWN rises again: the same code loads
    v_cycles(40);
    v_check("lane 3 OWN rises again", 0, 0, 0, 1);
    v_write(3, 9'd201, 1'b0, 1'b0);               // code change while OWN 0: none
    v_cycles(40);
    v_check("lane 3 code 201, OWN 0", 0, 0, 0, 0);
    v_write(3, 9'd201, 1'b1, 1'b0);
    v_cycles(40);
    v_check("lane 3 OWN with 201", 0, 0, 0, 1);
    v_set_des_rst(1'b0);                          // RX_RST follows des_rst while ready
    v_cycles(5);
    v_set_des_rst(1'b1);
    v_cycles(5);
    // restart with OWN still 1 on every lane (the D-PHY has not seen READY fall yet): every
    // lane with OWN loads its code again once ready
    v_set_ready(1'b0);
    v_cycles(30);
    v_check("restart, OWN kept", 0, 0, 0, 0);
    v_set_ready(1'b1);
    v_cycles(40);
    v_check("ready again with OWN 1", 1, 1, 1, 1);
    // restart as the D-PHY sees it: OWN cleared a few bus cycles after ready fell
    v_set_ready(1'b0);
    repeat (3) @(posedge clk);
    for (int l = 0; l < int'(VL); l++) v_write(l, v_code[l], 1'b0, 1'b0);
    v_cycles(30);
    v_set_ready(1'b1);
    v_cycles(40);
    v_check("restart, OWN cleared", 0, 0, 0, 0);
    if (v_vtc !== '1) err($sformatf("RX_EN_VTC %b after the restart with OWN 0", v_vtc));
    for (int l = 0; l < int'(VL); l++) v_write(l, v_code[l], 1'b1, 1'b0);   // same codes, OWN
    v_cycles(40);
    v_check("OWN rises after the restart", 1, 1, 1, 1);
    // skewed bits (less than one CTRL_CLK period): never a mix
    for (int i = 0; i < 40; i++) begin
      automatic int         l = i % int'(VL);
      automatic logic [8:0] c = 9'($urandom_range(0, 511));
      automatic int         e [VL] = '{default: 0};
      e[l] = int'(c != v_code[l]);
      v_write(l, c, 1'b1, 1'b1);
      v_cycles(40);
      v_check($sformatf("skewed write %0d", i), e[0], e[1], e[2], e[3]);
    end
    // random: writes, restarts (OWN cleared as the D-PHY does, or kept), des_rst
    for (int i = 0; i < 400; i++) begin
      unique case ($urandom_range(0, 11))
        0: begin
          v_set_ready(1'b0);
          v_cycles($urandom_range(1, 30));
          if ($urandom_range(0, 2) != 0) begin
            for (int l = 0; l < int'(VL); l++) v_write(l, v_code[l], 1'b0, 1'b0);
          end
          v_set_ready(1'b1);
        end
        1: v_set_des_rst(!v_des_rst);
        default: v_write($urandom_range(0, VL - 1), 9'($urandom_range(0, 511)),
                         $urandom_range(0, 4) != 0, $urandom_range(0, 1));
      endcase
      v_cycles($urandom_range(0, 8));
      if (i % 25 == 24) begin
        if (!v_ready) v_set_ready(1'b1);
        v_cycles(60);
        v_check($sformatf("random %0d", i), -1, -1, -1, -1);
      end
    end
    if (!v_ready) v_set_ready(1'b1);
    v_cycles(60);
    v_check("random end", -1, -1, -1, -1);
    for (int l = 0; l < int'(VL); l++) v_write(l, 9'($urandom_range(0, 511)), 1'b1, 1'b1);
    v_cycles(60);
    v_check("every lane with OWN at the end", -1, -1, -1, -1);
    i_own = 0;
    for (int l = 0; l < int'(VL); l++) i_own += v_own[l];
    $display("tb_afe_dly: Versal: %0d / %0d / %0d / %0d LDs, %0d restarts, %0d CTRL_CLK edges with a mix of two codes at the inputs, %0d lanes with OWN at the end",
             v_nld[0], v_nld[1], v_nld[2], v_nld[3], v_restarts, v_mixes, i_own);
  endtask

  // ------------------------------------------------------------------------------- main
  // two processes, not a fork / join of the two tasks (Verilator 5.020 splits that coroutine
  // into a function without co_return)
  bit x_done = 1'b0, v_done = 1'b0;

  initial begin
    run_xusp();
    x_done = 1'b1;
  end

  initial begin
    run_versal();
    v_done = 1'b1;
  end

  initial begin
    wait (x_done && v_done);
    #50;
    if (errors == 0) $display("tb_afe_dly: PASS (%0d checks, %0.1f us)", checks, $realtime / 1000.0);
    else             $display("tb_afe_dly: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("tb_afe_dly: FAIL (timeout; UltraScale+ part %s after '%s', Versal part %s after '%s')",
             x_done ? "done" : "stuck", x_last, v_done ? "done" : "stuck", v_last);
    $finish;
  end

endmodule
