// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Pin level test of the Versal D-PHY receive I/O (Vivado simulator with the unisim and
// secureip models of IBUFDS_DPHY, XPHY, XPLL and BUFGCE, `make -C hw/fpga/common/dv
// test-dphy-versal`; Verilator cannot simulate the encrypted XPHY model):
//
//   bit-serial D-PHY transmitter -> pads -> bow_dphy_io_versal -> rx_data_o / rx_valid_o
//                                           (IBUFDS_DPHY, XPHY strobe mode, XPLL, BUFGCE)
//
// Transmitter: non-continuous clock lane, 4 data lanes at 1440 Mbit/s (UI 694 ps), HS
// clock centre aligned (DDR), bursts
//   clock: LP-11 -> LP-01 -> LP-00 -> HS-0 (T_CLK_ZERO) -> clock (T_CLK_PRE) ... T_CLK_POST
//          -> HS-0 trail -> LP-11
//   data : LP-11 -> LP-01 -> LP-00 -> HS-0 zeros -> 0xB8 -> payload -> trail -> LP-11
// LP states are driven with strong strength, HS with weak strength: the IBUFDS_DPHY model
// tells LP from HS by the strength of both pads. A small LP state machine (like
// bow_dphy_lp) turns the HS receivers on in LP-00 and opens the byte clock gate CLK_SETTLE
// after the clock lane entered LP-00 (static HS-0); HsGate = 1 also waits for phy_rdy_o.
//
// Nibble plans (Plan, synthetic, no board's): instance order strobe first, as the Huins
// camera build derives it (hw/fpga/huins_vp1902/tcl/cam_plan.tcl)
//   0  the RTL defaults (repeated here): strobe nibble 4; D0 strobe local, D1 inter-nibble
//      (nibble 5), D2 inter-byte CLK_TO_UPPER (nibble 6), D3 inter-byte CLK_TO_LOWER
//      (nibble 2): one XPHY forwards both ways
//   1  two nibbles at the top of the bank: strobe nibble 7, nibble 6 inter-nibble; two
//      lanes strobe local, two inter-nibble
//   2  chains: strobe nibble 4 -> nibble 6 inter-byte (CLK_TO_UPPER) -> nibble 8 inter-byte
//      from an inter-byte receiver (6 -> 8, CLK_TO_LOWER) and nibble 7 inter-nibble from an
//      inter-byte receiver; D3 strobe local
//
// Checks:
//  * init: XPLL lock, DLY_RDY, PHY_RDY, phy_rdy_o within 3 ms; no input delay load
//    without a request; dly_tap_o = the BISC delay (not 0) on every lane;
//  * every burst and lane: HS-0 + sync byte + the payload somewhere in the received bit
//    stream (bit 0 of rx_data_o = first bit), at any bit offset;
//  * delay loads (DlyVid contract): one load per request, the readback, the newest of two
//    close requests wins, requests 16 cycles apart load each (MergeTest), a tap sweep
//    (DlySweep);
//  * run-time knobs: burst_rst_en_i (BurstRst from reset, or switched 0 -> 1 in the middle
//    of burst BurstRstAt while streaming): RX_RST pulses in the burst gaps exactly while it
//    is 1, every burst decodes; reinit_i (Reinit 1: after burst ReinitAfter with the clock
//    lane idle in LP-11, or toggling with ContClk = 1; Reinit 2: while the transmitter
//    toggles the clock lane in HS, BISC then runs with a toggling strobe; held 2 us, or
//    ReinitNs, e.g. the 640 ns pulse of CMD.REINIT): phy_rdy_o falls
//    within a few cycles and stays 0 while reinit_i = 1, the XPLL and the XPHYs are held in
//    reset, user mode ends, no load, phy_rdy_o comes back with the strobe at the XPHY
//    toggling (Reinit 2, ContClk 1) or static (Reinit 1) during the new BISC, the taps are
//    the BISC delays of the first init again (the loaded taps are gone), and the following
//    bursts decode.
// The test prints "tb_bow_dphy_io_versal: PASS" or "... FAIL (<n> errors)".
`timescale 1ps / 1ps

module tb_bow_dphy_io_versal #(
  parameter int Plan        = 0,      // nibble plan, see above
  parameter bit EnVtcEarly  = 1'b1,
  parameter bit RdenReg     = 1'b1,
  parameter bit BurstRst    = 1'b0,   // burst_rst_en_i from reset
  parameter int BurstRstAt  = -1,     // >= 0: burst_rst_en_i 0 -> 1 during this burst
  parameter int Bursts      = 3,
  parameter int Payload     = 48,     // bytes per burst and lane
  parameter int SkewPs      = 0,      // extra per lane skew step (lane l delayed by l * SkewPs)
  parameter bit DlyTest     = 1'b1,   // load taps between bursts 2 and 3
  parameter bit DlySweep    = 1'b0,   // after the bursts: one burst per tap value
  parameter int SweepFrom   = 0,
  parameter int SweepTo     = 511,
  parameter int SweepStep   = 64,
  parameter int GlitchClk   = 0,      // glitch pulses on the clock lane at the end of LP-00 (HS
                                      // receiver already on, gate still closed): comparator
                                      // noise before HS-0 (the IBUFDS_DPHY model has none)
  parameter int GlitchPs    = 200,    // width of one glitch pulse
  parameter bit MergeTest   = 1'b1,   // after burst 1: load semantics of the DlyVid contract
  parameter int ContClk     = 0,      // 0: clock lane stops between bursts; 1: continuous HS
                                      // clock from time 0, HS receiver on from reset (strobe
                                      // toggles during BISC); 2: continuous clock, HS receiver
                                      // and gate turned on only after phy_rdy
  parameter int Reinit      = 0,      // 1: reinit_i after burst ReinitAfter; 2: the same
                                      // while the clock lane toggles in HS (see Checks)
  parameter int ReinitAfter = 2,
  parameter int ReinitNs    = 0,      // > 0: reinit_i only this long (CMD.REINIT of the D-PHY:
                                      // 32 bus clock cycles, 640 ns at 50 MHz); 0: 2 us
  parameter bit HsGate      = 1'b1    // 1: HS receivers on only while phy_rdy_o (0: as
                                      // bow_dphy_lp, from the LP states alone)
);

  localparam int UI = 694;                      // ps, 1440.9 Mbit/s
  localparam int unsigned NumNib = (Plan == 1) ? 2 : 4;
  localparam logic [15:0] NibPhys   = (Plan == 0) ? 16'h2564 :
                                      (Plan == 1) ? 16'h0067 : 16'h6784;
  localparam logic [7:0]  NibRole   = (Plan == 0) ? 8'b10_01_10_00 :
                                      (Plan == 1) ? 8'b00_00_01_00 : 8'b10_01_10_00;
  localparam logic [7:0]  NibSrc    = (Plan == 0) ? 8'b00_00_00_00 :
                                      (Plan == 1) ? 8'b00_00_00_00 : 8'b00_11_11_00;
  localparam logic [7:0]  LaneNib   = (Plan == 0) ? 8'b11_01_10_00 :
                                      (Plan == 1) ? 8'b00_01_00_01 : 8'b00_11_10_01;
  localparam logic [11:0] LaneSlice = (Plan == 0) ? 12'b010_000_100_010 :
                                      (Plan == 1) ? 12'b010_100_100_000 : 12'b100_100_010_000;

  int errors = 0;

  function automatic void err(input string msg);
    errors++;
    $display("[%0t] ERROR: %s", $time, msg);
  endfunction

  // ---------------------------------------------------------------- clocks
  logic ctrl_clk = 1'b0;
  always #2500 ctrl_clk = ~ctrl_clk;            // 200 MHz CTRL_CLK and XPLL reference
  logic ctrl_rst_n = 1'b0;

  // ---------------------------------------------------------------- pads
  // index 0 = clock lane, 1..4 = data lanes 0..3
  logic [4:0] lp_mode = '1;                     // 1: LP (strong), 0: HS (weak)
  logic [4:0] lp_p = '1, lp_n = '1;
  logic [4:0] hs_v = '0;
  wire  [4:0] pad_p, pad_n;

  for (genvar i = 0; i < 5; i++) begin : g_pad
    assign (strong1, strong0) pad_p[i] = lp_mode[i] ? lp_p[i] : 1'bz;
    assign (strong1, strong0) pad_n[i] = lp_mode[i] ? lp_n[i] : 1'bz;
    assign (weak1, weak0)     pad_p[i] = lp_mode[i] ? 1'bz : hs_v[i];
    assign (weak1, weak0)     pad_n[i] = lp_mode[i] ? 1'bz : ~hs_v[i];
  end

  // ---------------------------------------------------------------- DUT
  logic            phy_rdy, byte_clk, byte_ce, clk_hs_en;
  logic            reinit = 1'b0, burst_rst_en = BurstRst;
  logic [3:0]      status, hs_en, rx_valid, dly_load;
  logic [1:0]      clk_lp;
  logic [3:0][1:0] lp;
  logic [3:0][7:0] rx_data;
  logic [7:0]      clk_q;
  logic [3:0][8:0] dly_tap, dly_tap_rb;

  bow_dphy_io_versal #(
    .Lanes      (4),
    .NumNib     (NumNib),
    .NibPhys    (NibPhys),
    .NibRole    (NibRole),
    .NibSrc     (NibSrc),
    .LaneNib    (LaneNib),
    .LaneSlice  (LaneSlice),
    .EnVtcEarly (EnVtcEarly),
    .RdenReg    (RdenReg)
  ) dut (
    .clk_p          (pad_p[0]),
    .clk_n          (pad_n[0]),
    .data_p         (pad_p[4:1]),
    .data_n         (pad_n[4:1]),
    .ctrl_clk_i     (ctrl_clk),
    .ctrl_rst_ni    (ctrl_rst_n),
    .pll_clkin_i    (ctrl_clk),
    .reinit_i       (reinit),
    .burst_rst_en_i (burst_rst_en),
    .phy_rdy_o      (phy_rdy),
    .phy_status_o   (status),
    .byte_clk_o     (byte_clk),
    .byte_ce_i      (byte_ce),
    .byte_rst_i     (1'b0),
    .clk_lp_o       (clk_lp),
    .clk_hs_en_i    (clk_hs_en),
    .lp_o           (lp),
    .hs_en_i        (hs_en),
    .rx_data_o      (rx_data),
    .rx_valid_o     (rx_valid),
    .clk_q_o        (clk_q),
    .dly_tap_i      (dly_tap),
    .dly_load_i     (dly_load),
    .dly_tap_o      (dly_tap_rb)
  );

  // ---------------------------------------------------------------- receiver LP state machine
  logic [1:0]      clk_lp_s1 = 2'b11, clk_lp_s2 = 2'b11;
  logic [3:0][1:0] lp_s1 = '1, lp_s2 = '1;
  int              settle = 0;
  localparam int   ClkSettle = 30;              // ctrl cycles (150 ns) after LP-00
  logic            ce_q = 1'b0, clk_hs_en_q = 1'b0;
  logic [3:0]      hs_en_q = '0;
  logic            hs_ok;

  assign hs_ok = phy_rdy || !HsGate;

  always @(posedge ctrl_clk) begin
    clk_lp_s1 <= clk_lp;
    clk_lp_s2 <= clk_lp_s1;
    lp_s1     <= lp;
    lp_s2     <= lp_s1;
    if (ContClk == 1)            clk_hs_en_q <= 1'b1;           // CLK_FORCE, from reset on
    else if (ContClk == 2)       clk_hs_en_q <= phy_rdy;        // CLK_FORCE after init
    else if (clk_lp_s2 == 2'b00) clk_hs_en_q <= hs_ok;
    else if (clk_lp_s2 == 2'b11) clk_hs_en_q <= 1'b0;
    if (!clk_hs_en_q) settle <= 0;
    else if (settle < ClkSettle) settle <= settle + 1;
    ce_q <= clk_hs_en_q && (settle == ClkSettle);
    for (int l = 0; l < 4; l++) begin
      if (lp_s2[l] == 2'b00)      hs_en_q[l] <= hs_ok;
      else if (lp_s2[l] == 2'b11) hs_en_q[l] <= 1'b0;
    end
  end

  assign clk_hs_en = clk_hs_en_q;
  assign hs_en     = hs_en_q;
  assign byte_ce   = ce_q;

  // ---------------------------------------------------------------- transmitter model
  int unsigned tick = 0;
  event        ev_tick;
  logic        clk_run = 1'b0;
  bit          q_bits [4][$];
  logic [3:0]  lane_hs_on = '0;

  always begin
    #(UI);
    tick++;
    -> ev_tick;
  end

  // clock lane: DDR clock, one edge per UI while running (HS-0 = low when stopped)
  always @(ev_tick) if (clk_run) hs_v[0] <= ~hs_v[0];

  // data lanes: centre aligned, a new bit UI/2 after every clock edge (+ lane skew)
  for (genvar l = 0; l < 4; l++) begin : g_tx
    always @(ev_tick) begin
      #(UI / 2 + l * SkewPs);
      if (lane_hs_on[l]) begin
        if (q_bits[l].size() > 0) hs_v[1 + l] <= q_bits[l].pop_front();
        else                      lane_hs_on[l] <= 1'b0;
      end
    end
  end

  task automatic set_lp(input int i, input logic [1:0] v);   // v = {P, N}
    lp_mode[i] = 1'b1;
    lp_p[i]    = v[1];
    lp_n[i]    = v[0];
  endtask

  task automatic push_byte(input int l, input logic [7:0] b);
    for (int k = 0; k < 8; k++) q_bits[l].push_back(b[k]);     // LSB first
  endtask

  function automatic logic [7:0] pay(input int burst, input int l, input int k);
    return 8'((burst * 37) + (l * 64) + k * 5 + 1) ^ 8'(k << 4);
  endfunction

  task automatic data_lane_burst(input int l, input int burst);
    set_lp(1 + l, 2'b01); #60ns;                // T_LPX
    set_lp(1 + l, 2'b00); #60ns;                // T_HS_PREPARE
    // HS-0 (T_HS_ZERO ~ 18 bytes = 100 ns), sync, payload, trail (inverted last bit, 96 UI)
    q_bits[l].delete();
    for (int k = 0; k < 18; k++) push_byte(l, 8'h00);
    push_byte(l, 8'hB8);
    for (int k = 0; k < Payload; k++) push_byte(l, pay(burst, l, k));
    begin
      bit last;
      last = q_bits[l][$];
      for (int k = 0; k < 96; k++) q_bits[l].push_back(~last);
    end
    hs_v[1 + l]       = 1'b0;
    lp_mode[1 + l]    = 1'b0;                   // HS, starts with HS-0
    lane_hs_on[l]     = 1'b1;
    wait (lane_hs_on[l] == 1'b0);
    set_lp(1 + l, 2'b11);                       // stop state
  endtask

  // clock lane LP-11 -> HS, clock running (with GlitchClk pulses at HS entry)
  task automatic clock_start();
    set_lp(0, 2'b01); #60ns;                    // T_LPX
    set_lp(0, 2'b00); #60ns;                    // T_CLK_PREPARE
    hs_v[0] = 1'b0;
    lp_mode[0] = 1'b0;                          // HS-0
    for (int g = 0; g < GlitchClk; g++) begin   // comparator noise right at HS entry
      #(300 + 137 * g);
      hs_v[0] = 1'b1;
      #(GlitchPs);
      hs_v[0] = 1'b0;
    end
    #260ns;                                     // T_CLK_ZERO
    @(ev_tick);
    clk_run = 1'b1;
  endtask

  // clock lane HS -> LP-11
  task automatic clock_stop();
    @(ev_tick);
    while (hs_v[0] != 1'b0) @(ev_tick);
    clk_run = 1'b0;                             // HS-0 trail
    #80ns;                                      // T_CLK_TRAIL
    set_lp(0, 2'b11);
  endtask

  // burst_rst_en_i 0 -> 1 in the middle of burst BurstRstAt (asynchronous to ctrl_clk)
  int brst_switch_burst = -1;
  task automatic knob_during_burst(input int b);
    if (b == BurstRstAt) begin
      #(1137ns + 59ps);
      burst_rst_en = 1'b1;
      brst_switch_burst = b;
      $display("[%0t] burst_rst_en_i 0 -> 1 during burst %0d", $time, b);
    end
  endtask

  task automatic burst(input int b);
    if (ContClk != 0) begin                     // clock lane stays in HS: data lanes only
      $display("[%0t] TX burst %0d (continuous clock)", $time, b);
      fork
        data_lane_burst(0, b);
        data_lane_burst(1, b);
        data_lane_burst(2, b);
        data_lane_burst(3, b);
        knob_during_burst(b);
      join
      #120ns;
      return;
    end
    $display("[%0t] TX burst %0d", $time, b);
    clock_start();
    #20ns;                                      // T_CLK_PRE (>= 8 UI)
    fork
      data_lane_burst(0, b);
      data_lane_burst(1, b);
      data_lane_burst(2, b);
      data_lane_burst(3, b);
      knob_during_burst(b);
    join
    #120ns;                                     // T_CLK_POST (>= 60 ns + 52 UI)
    clock_stop();
  endtask

  // ---------------------------------------------------------------- receive log
  logic [7:0] rx_log [4][$];
  bit         rv_log [4][$];
  int         byte_edges = 0;

  always @(posedge byte_clk) begin
    byte_edges++;
    for (int l = 0; l < 4; l++) begin
      rx_log[l].push_back(rx_data[l]);
      rv_log[l].push_back(rx_valid[l]);
    end
  end

  task automatic clear_log();
    for (int l = 0; l < 4; l++) begin
      rx_log[l].delete();
      rv_log[l].delete();
    end
  endtask

  // search the expected bytes (HS-0, sync, payload) in the received bit stream
  int found_off [4];

  task automatic check_burst(input int b);
    for (int l = 0; l < 4; l++) begin
      bit stream[$];
      bit exp[$];
      int hit, hit_rev, nvalid;
      logic [7:0] e;
      nvalid = 0;
      for (int i = 0; i < rx_log[l].size(); i++) begin
        for (int k = 0; k < 8; k++) stream.push_back(rx_log[l][i][k]);
        nvalid += rv_log[l][i];
      end
      for (int k = 0; k < 2 + Payload; k++) begin
        e = (k == 0) ? 8'h00 : (k == 1) ? 8'hB8 : pay(b, l, k - 2);
        for (int j = 0; j < 8; j++) exp.push_back(e[j]);
      end
      hit = -1;
      hit_rev = -1;
      for (int s = 0; s + exp.size() <= stream.size(); s++) begin
        bit ok, okr;
        ok = 1'b1;
        okr = 1'b1;
        for (int j = 0; j < exp.size(); j++) begin
          if (stream[s + j] != exp[j]) ok = 1'b0;
          // bit reversed within each byte (MSB first on the wire)
          if (stream[s + (j / 8) * 8 + 7 - (j % 8)] != exp[j]) okr = 1'b0;
          if (!ok && !okr) break;
        end
        if (ok && hit < 0) hit = s;
        if (okr && hit_rev < 0) hit_rev = s;
        if (hit >= 0) break;
      end
      found_off[l] = hit;
      if (hit >= 0) begin
        $display("[%0t] burst %0d lane %0d: OK, sync + %0d bytes at bit %0d (offset %0d), %0d words, %0d valid",
                 $time, b, l, Payload, hit, hit % 8, rx_log[l].size(), nvalid);
      end else begin
        string s;
        s = "";
        for (int i = 0; i < rx_log[l].size() && i < 40; i++)
          s = {s, $sformatf("%02x%s ", rx_log[l][i], rv_log[l][i] ? "" : "*")};
        err($sformatf("burst %0d lane %0d: payload not found (bit reversed match at %0d), %0d words, %0d valid; first words (* = rx_valid 0): %s",
                      b, l, hit_rev, rx_log[l].size(), nvalid, s));
      end
    end
    clear_log();
  endtask

  // ---------------------------------------------------------------- monitors
  always @(posedge status[0]) $display("[%0t] XPLL LOCKED", $time);
  always @(posedge status[2]) $display("[%0t] DLY_RDY (all nibbles)", $time);
  always @(posedge status[3]) $display("[%0t] PHY_RDY (all nibbles)", $time);
  always @(posedge phy_rdy)   $display("[%0t] phy_rdy_o = 1", $time);
  always @(negedge phy_rdy)   if ($time > 0) $display("[%0t] phy_rdy_o = 0", $time);

  // LD pulses per lane (dut.ld_q) and the tap the XPHY saw with each one
  int ld_count [4] = '{0, 0, 0, 0};
  logic [8:0] ld_tap [4];
  always @(posedge ctrl_clk) begin
    for (int l = 0; l < 4; l++) if (dut.ld_q[l]) begin
      ld_count[l]++;
      ld_tap[l] = dut.cntin_q[l];
    end
  end

  // per-burst RX_RST pulses (burst_rst_en_i)
  int brst_pulses = 0;
  always @(posedge dut.burst_rst_q) brst_pulses++;

  // ---------------------------------------------------------------- tasks of main
  task automatic wait_phy_rdy(input string what, output time took);
    time t0;
    t0 = $time;
    fork
      begin
        wait (phy_rdy == 1'b1);
      end
      begin
        #3ms;
      end
    join_any
    disable fork;
    took = $time - t0;
    if (!phy_rdy) begin
      err($sformatf("%s: no phy_rdy_o after 3 ms (status %b, sequencer state %0d)",
                    what, status, dut.seq_q));
      $display("tb_bow_dphy_io_versal: FAIL (%0d errors)", errors);
      $finish;
    end
    $display("[%0t] %s: phy_rdy_o after %0t", $time, what, took);
  endtask

  task automatic load_tap(input int l, input logic [8:0] tap);
    // (blocking writes: xsim 2025.2 mishandles loop-indexed NBAs across a suspension)
    @(posedge ctrl_clk);
    #1;
    dly_tap[l] = tap;
    dly_load   = 4'b0001 << l;
    @(posedge ctrl_clk);
    #1;
    dly_load   = 4'b0000;
  endtask

  // reinit_i pulse (Reinit), the checks of the knob
  logic [8:0] bisc0 [4];
  int         strobe_edges = 0;                 // edges of the clock lane at the XPHY (HSRX_O)
  always @(dut.clk_hs) strobe_edges++;

  task automatic do_reinit();
    int   ld0 [4];
    int   fall, e0;
    time  took;
    logic [8:0] prev [4];
    for (int l = 0; l < 4; l++) begin
      ld0[l]  = ld_count[l];
      prev[l] = dly_tap_rb[l];
    end
    if (Reinit == 2) begin
      $display("[%0t] clock lane to HS, toggling", $time);
      clock_start();
      #1us;
    end
    #(777ns + 31ps);                            // asynchronous to ctrl_clk
    $display("[%0t] reinit_i = 1 (taps %0d %0d %0d %0d, clock lane %s)", $time,
             prev[0], prev[1], prev[2], prev[3], clk_run ? "toggling" : "idle");
    reinit = 1'b1;
    fall = -1;
    for (int c = 0; c < ((ReinitNs > 0) ? ReinitNs / 5 : 400); c++) begin   // 2 us
      @(posedge ctrl_clk);
      if (!phy_rdy && fall < 0) fall = c;
      if (fall >= 0 && phy_rdy) err("phy_rdy_o 1 again while reinit_i = 1");
    end
    if (fall < 0 || fall > 5) err($sformatf("phy_rdy_o fell %0d cycles after reinit_i (want <= 5)", fall));
    else $display("[%0t] phy_rdy_o fell %0d cycles after reinit_i, XPLL LOCKED %b", $time, fall, status[0]);
    // held in the XPLL reset (sequencer state 0), user mode and pending loads cleared
    if (int'(dut.seq_q) != 0 || !dut.pll_rst_q || !dut.xphy_rst_q || dut.clkoutphyen_q)
      err($sformatf("reinit_i = 1: sequencer state %0d, XPLL RST %b, XPHY RST %b, CLKOUTPHYEN %b",
                    dut.seq_q, dut.pll_rst_q, dut.xphy_rst_q, dut.clkoutphyen_q));
    if (dut.user_q != '0 || dut.pend_q != '0)
      err($sformatf("user mode / pending load still on while reinit_i = 1 (user %b pend %b)",
                    dut.user_q, dut.pend_q));
    #(13ns + 7ps);
    reinit = 1'b0;
    $display("[%0t] reinit_i = 0", $time);
    e0 = strobe_edges;
    wait_phy_rdy("reinit", took);
    // the strobe during the new BISC: toggling (Reinit 2, continuous clock) or static
    e0 = strobe_edges - e0;
    $display("[%0t] %0d clock lane edges at the XPHY during the re-init", $time, e0);
    if ((Reinit == 2 || ContClk == 1) ? (e0 < 10000) : (e0 != 0))
      err($sformatf("%0d clock lane edges at the XPHY during the re-init, want %s", e0,
                    (Reinit == 2 || ContClk == 1) ? "a toggling strobe" : "none"));
    if (Reinit == 2) begin
      #500ns;
      clock_stop();
      $display("[%0t] clock lane back to LP-11", $time);
    end
    repeat (20) @(posedge ctrl_clk);
    for (int l = 0; l < 4; l++) begin
      if (ld_count[l] != ld0[l])
        err($sformatf("lane %0d: %0d loads during / after reinit_i without a request", l, ld_count[l] - ld0[l]));
      if (dly_tap_rb[l] != bisc0[l])
        err($sformatf("lane %0d: dly_tap_o %0d after reinit_i, the BISC delay of the first init was %0d (loaded before: %0d)",
                      l, dly_tap_rb[l], bisc0[l], prev[l]));
      else
        $display("[%0t] lane %0d dly_tap_o after reinit_i = %0d = BISC (was %0d)", $time, l, dly_tap_rb[l], prev[l]);
    end
    clear_log();
  endtask

  // ---------------------------------------------------------------- main
  initial begin
    time took;
    $timeformat(-9, 1, " ns", 12);
    if ((Reinit != 0) && (Bursts < ReinitAfter + 2))
      $fatal(1, "Reinit needs Bursts >= ReinitAfter + 2");
    if ((BurstRstAt >= 0) && (BurstRst || BurstRstAt + 1 >= Bursts))
      $fatal(1, "BurstRstAt needs BurstRst = 0 and a burst after it");
    dly_tap  = '0;
    dly_load = '0;
    if (ContClk != 0) begin                     // clock lane in HS and toggling from t = 0
      hs_v[0]    = 1'b0;
      lp_mode[0] = 1'b0;
      clk_run    = 1'b1;
    end
    #20ns;
    @(posedge ctrl_clk) ctrl_rst_n <= 1'b1;
    wait_phy_rdy("init", took);
    repeat (20) @(posedge ctrl_clk);
    for (int l = 0; l < 4; l++) begin
      bisc0[l] = dly_tap_rb[l];
      $display("[%0t] lane %0d dly_tap_o after init (BISC) = %0d", $time, l, dly_tap_rb[l]);
      if (ld_count[l] != 0) err($sformatf("lane %0d: %0d loads after reset without a request", l, ld_count[l]));
      if (dly_tap_rb[l] == 9'd0) err($sformatf("lane %0d: dly_tap_o = 0 after init (BISC delay expected)", l));
    end
    #200ns;
    clear_log();
    for (int b = 0; b < Bursts; b++) begin
      int p0;
      p0 = brst_pulses;
      burst(b);
      #400ns;
      $display("[%0t] after burst %0d: fifo_empty %b, %0d byte clock edges so far, %0d RX_RST burst pulses",
               $time, b, dut.fifo_empty, byte_edges, brst_pulses);
      check_burst(b);
      // RX_RST pulses only while burst_rst_en_i = 1 (one per closed gate, from the burst
      // after the switch on); none with the continuous clock (the gate never closes)
      if (!burst_rst_en && brst_pulses != 0)
        err($sformatf("%0d RX_RST burst pulses with burst_rst_en_i = 0", brst_pulses));
      if (burst_rst_en && ContClk == 0 && b > brst_switch_burst && brst_pulses == p0)
        err($sformatf("burst %0d: no RX_RST pulse with burst_rst_en_i = 1", b));
      if (DlyTest && b == 1) begin
        for (int l = 0; l < 4; l++) load_tap(l, dly_tap_rb[l] + 9'd16);
        repeat (40) @(posedge ctrl_clk);
        for (int l = 0; l < 4; l++) begin
          $display("[%0t] lane %0d dly_tap_o after a load of %0d = %0d (%0d LD)", $time, l,
                   dly_tap[l], dly_tap_rb[l], ld_count[l]);
          if (dly_tap_rb[l] != dly_tap[l] || ld_count[l] != 1)
            err($sformatf("lane %0d first request: tap %0d, %0d LD", l, dly_tap_rb[l], ld_count[l]));
        end
      end
      if (MergeTest && b == 1) begin
        int c0, c1;
        logic [8:0] t_a, t_b;
        // (a) two requests on lane 1 two cycles apart: the newest tap is loaded
        c1  = ld_count[1];
        t_a = dly_tap_rb[1] + 9'd5;
        t_b = dly_tap_rb[1] + 9'd9;
        @(posedge ctrl_clk); #1; dly_tap[1] = t_a; dly_load = 4'b0010;
        @(posedge ctrl_clk); #1; dly_load = 4'b0000;
        @(posedge ctrl_clk); #1; dly_tap[1] = t_b; dly_load = 4'b0010;
        @(posedge ctrl_clk); #1; dly_load = 4'b0000;
        repeat (30) @(posedge ctrl_clk);
        $display("[%0t] MERGE lane 1: requests %0d then %0d -> dly_tap_o %0d, %0d LD, last LD tap %0d",
                 $time, t_a, t_b, dly_tap_rb[1], ld_count[1] - c1, ld_tap[1]);
        // lane 1 in VT mode (DlyTest = 0): both requests fall into the VTC wait -> one LD
        if (dly_tap_rb[1] != t_b || ld_tap[1] != t_b || ld_count[1] - c1 < 1 || ld_count[1] - c1 > 2 ||
            (!DlyTest && ld_count[1] - c1 != 1))
          err($sformatf("merge: lane 1 ended at %0d (want %0d), %0d LD", dly_tap_rb[1], t_b, ld_count[1] - c1));
        // (b) three requests on lane 2, 16 cycles apart (the receiver's minimum): one LD each
        c0 = ld_count[2];
        for (int k = 0; k < 3; k++) begin
          @(posedge ctrl_clk); #1; dly_tap[2] = dly_tap_rb[2] + 9'd3; dly_load = 4'b0100;
          @(posedge ctrl_clk); #1; dly_load = 4'b0000;
          repeat (14) @(posedge ctrl_clk);
        end
        repeat (10) @(posedge ctrl_clk);
        $display("[%0t] SPACED lane 2: 3 requests -> %0d LD, dly_tap_o %0d (want %0d)",
                 $time, ld_count[2] - c0, dly_tap_rb[2], dly_tap[2]);
        if (ld_count[2] - c0 != 3 || dly_tap_rb[2] != dly_tap[2])
          err("spaced requests on lane 2");
        // the other lanes were not touched
        if (ld_count[0] != int'(DlyTest) || ld_count[3] != int'(DlyTest))
          err($sformatf("loads on untouched lanes: %0d %0d", ld_count[0], ld_count[3]));
      end
      if (Reinit != 0 && b == ReinitAfter) do_reinit();
      #500ns;
    end
    if (DlySweep) begin
      // same tap on every lane, one burst per value: where does the sampling point leave
      // the bit (the bit offset of the match moves) or the eye (no match)?
      for (int t = SweepFrom; t <= SweepTo; t += SweepStep) begin
        for (int l = 0; l < 4; l++) load_tap(l, 9'(t));
        repeat (40) @(posedge ctrl_clk);
        clear_log();
        burst(100 + t);
        #400ns;
        check_burst(100 + t);
        $display("[%0t] SWEEP tap %0d: dly_tap_o %0d %0d %0d %0d, match bit offsets %0d %0d %0d %0d",
                 $time, t, dly_tap_rb[0], dly_tap_rb[1], dly_tap_rb[2], dly_tap_rb[3],
                 found_off[0], found_off[1], found_off[2], found_off[3]);
        #500ns;
      end
    end
    if (BurstRstAt >= 0 && brst_switch_burst != BurstRstAt)
      err("burst_rst_en_i was not switched");
    $display("SUMMARY Plan=%0d EnVtcEarly=%0d RdenReg=%0d BurstRst=%0d BurstRstAt=%0d SkewPs=%0d ContClk=%0d Glitch=%0d Reinit=%0d: %0d errors, %0d RX_RST burst pulses",
             Plan, EnVtcEarly, RdenReg, BurstRst, BurstRstAt, SkewPs, ContClk, GlitchClk, Reinit,
             errors, brst_pulses);
    if (errors == 0) $display("tb_bow_dphy_io_versal: PASS");
    else             $display("tb_bow_dphy_io_versal: FAIL (%0d errors)", errors);
    $finish;
  end

  // watchdog
  initial begin
    #30ms;
    $display("tb_bow_dphy_io_versal: FAIL (timeout)");
    $finish;
  end

endmodule
