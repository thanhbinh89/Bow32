// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// PPI bus functional model: the PHY of the CSI-2 controller in its bench
// (hw/ip/csi2rx/dv/tb_csi2rx_ppi.sv). It plays the PPI lines of a test case of
// `tools/csi2/csi2_model.py gen --ppi bow|std` (their format: the PPI section of the model)
// on the PPI of bow_ppi_pkg, in one of two timings (knob std):
//   std = 0  the D-PHY of Bow32 (bow_dphy_rx v1.x, to the controller bow_csi2rx itself):
//            ErrControl / ErrControlClk are 2 bit gray counters of vid_clk_i (the D-PHY's lp
//            clock) that step once per error (one cycle pulses up to step 5; errors here at
//            least 20 cycles apart, the D-PHY's at least 16); RxSkewCalHS a level until
//            RxActiveHS falls (the model renders it). Since step 4 of
//            docs/ip/mipi_rx_arch.md the D-PHY masks them (a lane's
//            Enable, its CTRL.CLK_CONT) and has the PHY's registers, RAW, the HS entry
//            counters and the status; the controller takes the OR of the errors: the model
//            renders the errors that the D-PHY passes on, the BFM plays them as they come
//            (Enable / EnableClk are not used here)
//   std = 1  a standard PHY, to the flat wrapper bow_csi2rx_ppi_flat: ErrControl pulses on
//            its own lp clock (lp_clk_o, period lp_ns; the wrapper makes the gray counters),
//            no ErrControlClk, RxSkewCalHS a pulse or a level
// Both: RxClkActiveHS = the byte clock runs, StopstateClk its inverse, Stopstate[l] = no
// burst event on lane l in the cycle; UlpsActiveNot* = 1, RxUlpsClkNot = 1, RxUlpsEsc = 0,
// ErrEsc = ErrSyncEsc = 0 (v1). Everything of a burst (RxActiveHS, RxSyncHS and the bytes
// with their gaps, ErrSotSyncHS, RxSkewCalHS, ErrSotHS, the byte clock run) comes from the
// test case: the model renders it in the chosen timing.
//
// Byte clock: period byte_ns, generated here while the driver runs it (non-continuous
// clock: one run per burst or clock-only burst; continuous: from ppon to ppoff). The values
// of cycle c of a burst (c byte clocks after the first edge of its run) change 0.1 period
// after edge c, as flop outputs, and are sampled by the controller at edge c + 1. The cycle
// count only advances on edges: lane events after the last edge of a run (the clock stopped
// early) happen when the clock runs again, as with the flops of a real PHY.
//
// API (functions, no delays: Verilator inlines tasks with delays at every call site; one
// timed driver process plays the items in order):
//   add_lane(l, a, f, s, e, k, kl, h, bytes)  lane l of the next burst ('ppl' line)
//   push_burst(n, gap_ns, stop, tend)        the burst ('ppb' line), with the lanes added
//   push_ev(err)                             lp domain pulses ('ppev', 'lperr': bit l data
//                                            lane l, bit 4 clock lane)
//   push_clk(ns), push_on(), push_off(), push_idle(ns)   'ppclk', 'ppon', 'ppoff', 'ppidle'
//   busy()                                   items queued or playing
// Status for the testbench: bursts_done, cur_burst / cur_byte (bytes driven so far, all
// lanes), t_end[n] (burst n: the edge after its cycle TEND, when the lane merge has the last
// byte; also in a later run when the clock stopped before it; the start of the burst
// without TEND), rx_clk_active (RxClkActiveHS), overlaps (a lane's burst starts before the
// events of its previous burst are over: a rendering error); report() prints what the run
// covered (cov_*: bursts by the byte clock edges after the one at which the last RxActiveHS
// falls, RxActiveHS before / with RxSyncHS, gap cycles, ErrSotSyncHS after the fall / early,
// RxSkewCalHS pulse / level, ErrSotHS, bytes with RxActiveHS low, lp pulses).

`timescale 1ns / 1ps

module bow_ppi_bfm import bow_ppi_pkg::*; import csi2_tx_pkg::csi2_now; #(
  parameter int unsigned Lanes = 2
) (
  input  logic                  vid_clk_i,           // video clock: the lp clock of std = 0
  output logic                  lp_clk_o,            // std = 1: the PHY's lp clock

  output logic                  rx_byte_clk_hs_o,    // RxByteClkHS
  output ppi_hs_t [Lanes-1:0]   ppi_hs_o,
  output ppi_lp_t [Lanes-1:0]   ppi_lp_o,            // std 0: vid_clk_i, 1: lp_clk_o
  output ppi_lp_clk_t           ppi_lp_clk_o,
  input  logic [Lanes-1:0]      enable_i,            // Enable (controller; not used)
  input  logic                  enable_clk_i         // EnableClk (not used)
);

  localparam int unsigned N = Lanes + 1;              // lp kinds: [0] clock lane, [1 + l] lane l
  localparam int unsigned HoldVid = 20;               // video clocks between pulses of a kind
  localparam int unsigned HoldLp = 6;                 // std: lp clocks between pulses of a lane
  localparam int unsigned PF = 12;                    // ints per lane program in pstore

  // -------------------------------------------------------------- coverage
  int unsigned cov_runs = 0, cov_post4 = 0, cov_post_more = 0, cov_post_short = 0, cov_post_before = 0;
  int unsigned cov_act_early = 0, cov_act_sync = 0, cov_no_act = 0, cov_bytes = 0, cov_gaps = 0;
  int unsigned cov_err_late = 0, cov_err_early = 0, cov_skew_pulse = 0, cov_skew_level = 0;
  int unsigned cov_err_sot = 0, cov_low_bytes = 0, cov_lp = 0;

  // ------------------------------------------------------------------ knobs
  bit      std = 1'b0;
  realtime byte_ns = 8.772;
  realtime lp_ns = 40.0;      // std: the PHY's lp clock (25 MHz: between escape and core clocks)

  // ----------------------------------------------------------------- status
  int unsigned bursts_done = 0, overlaps = 0;
  int          cur_burst = -1;
  int unsigned cur_byte = 0;
  realtime     t_end [int];
  logic        rx_clk_active = 1'b0;

  // ---------------------------------------------------------------- storage
  // A lane program: pstore[p + 0..PF-1] = G0 (first cycle of its run, set when the burst
  // starts), A, F, S, E, K, KL, H, OFF / LEN of its bytes in bstore (-1: a gap), LAST /
  // FIRST (its last / first event cycle)
  int pstore [$];
  int bstore [$];
  int progs [4][$];                        // per lane: programs, oldest first (4 entries:
                                           // with 1, a variable index does not compile
                                           // in Verilator 5.020)
  int pend_l [$], pend_p [$];              // lanes added for the next push_burst

  typedef enum logic [2:0] {ItEv, ItBurst, ItClk, ItOn, ItOff, ItIdle} kind_e;

  typedef struct packed {
    kind_e       kind;
    logic [31:0] a;      // burst: index; ev: error mask; clk / idle: ns
    logic [31:0] b;      // burst: LP time (ns)
    logic [31:0] c;      // burst: edges of the run
    logic [31:0] d;      // burst: t_end cycle (-1: none)
    logic [31:0] n;      // burst: lanes
  } item_t;

  item_t items [$];
  int    blane_l [$], blane_p [$];         // lanes of the queued bursts, in order
  bit    busy_q = 1'b0;

  function automatic int hex2(string s, int i);
    return s.substr(i, i + 1).atohex();
  endfunction

  function automatic void add_lane(int l, int a, int f, int s, int e, int k, int kl, int h,
                                   string b);
    int p, last, first, n;
    p = pstore.size();
    n = (b == "-") ? 0 : b.len() / 2;
    last = (a >= 0) ? f : -1;              // F only with RxActiveHS
    if (e > last) last = e;
    if (k + kl > last) last = k + kl;
    if (s + n > last) last = s + n;
    first = last;
    if (a >= 0 && a < first) first = a;
    if (s >= 0 && s < first) first = s;
    if (e >= 0 && e < first) first = e;
    if (k >= 0 && k < first) first = k;
    pstore.push_back(0);
    pstore.push_back(a);
    pstore.push_back(f);
    pstore.push_back(s);
    pstore.push_back(e);
    pstore.push_back(k);
    pstore.push_back(kl);
    pstore.push_back(h);
    pstore.push_back(bstore.size());
    pstore.push_back(n);
    pstore.push_back(last);
    pstore.push_back(first);
    for (int i = 0; i < n; i++) begin
      if (b.substr(2 * i, 2 * i + 1) == "--") bstore.push_back(-1);
      else                                     bstore.push_back(hex2(b, 2 * i));
    end
    pend_l.push_back(l);
    pend_p.push_back(p);
    if (a < 0)          cov_no_act++;
    else if (s > a)     cov_act_early++;
    else if (s == a)    cov_act_sync++;
    if (e >= 0) begin
      if (a >= 0 && e >= f) cov_err_late++;
      else                  cov_err_early++;
    end
    if (k >= 0) begin
      if (kl > 1) cov_skew_level++;
      else        cov_skew_pulse++;
    end
    if (h != 0 && s >= 0) cov_err_sot++;
    for (int i = 0; i < n; i++) begin
      if (bstore[pstore[p + 8] + i] < 0) cov_gaps++;
      else begin
        cov_bytes++;
        if (a >= 0 && s + i >= f) cov_low_bytes++;
      end
    end
  endfunction

  function automatic void push_item(kind_e kind, int a, int b, int c, int d, int n);
    item_t it;
    it      = '0;
    it.kind = kind;
    it.a    = a;
    it.b    = b;
    it.c    = c;
    it.d    = d;
    it.n    = n;
    items.push_back(it);
  endfunction

  function automatic void push_burst(int idx, int gap_ns, int stop, int tend);
    push_item(ItBurst, idx, gap_ns, stop, tend, pend_l.size());
    while (pend_l.size() != 0) begin
      blane_l.push_back(pend_l.pop_front());
      blane_p.push_back(pend_p.pop_front());
    end
  endfunction

  function automatic void push_ev(int err);
    push_item(ItEv, err, 0, 0, 0, 0);
  endfunction

  function automatic void push_clk(int ns);
    push_item(ItClk, ns, 0, 0, 0, 0);
  endfunction

  function automatic void push_on();
    push_item(ItOn, 0, 0, 0, 0, 0);
  endfunction

  function automatic void push_off();
    push_item(ItOff, 0, 0, 0, 0, 0);
  endfunction

  function automatic void push_idle(int ns);
    push_item(ItIdle, ns, 0, 0, 0, 0);
  endfunction

  // ------------------------------------------------------------ byte clock
  int               gcyc = 0;             // edges so far = number of the next cycle
  bit               run = 1'b0, cont = 1'b0;
  int               tq_g [$], tq_n [$];   // t_end due at the edge of cycle tq_g of burst tq_n
  logic [Lanes-1:0] stop_q = '1;          // Stopstate: no burst event on the lane

  // values of cycle g on every lane
  function automatic void drive(int g);
    ppi_hs_t [Lanes-1:0] hs;
    logic [Lanes-1:0]    stop;
    int p, c, i, v;
    hs   = '0;
    stop = '1;
    // drop the programs whose events are over
    for (int l = 0; l < int'(Lanes); l++) begin
      while (progs[l].size() != 0) begin
        p = progs[l][0];
        if (pstore[p] + pstore[p + 10] >= g) break;
        void'(progs[l].pop_front());
      end
    end
    for (int l = 0; l < int'(Lanes); l++) begin
      if (progs[l].size() == 0) continue;
      p = progs[l][0];
      c = g - pstore[p];
      if (c < 0) continue;
      stop[l] = 1'b0;
      hs[l].rx_active_hs = (pstore[p + 1] >= 0) && (c >= pstore[p + 1]) && (c < pstore[p + 2]);
      i = c - pstore[p + 3];
      if ((pstore[p + 3] >= 0) && (i >= 0) && (i < pstore[p + 9])) begin
        v = bstore[pstore[p + 8] + i];
        if (v >= 0) begin
          hs[l].rx_valid_hs = 1'b1;
          hs[l].rx_data_hs  = 8'(v);
          cur_byte++;
        end
      end
      if (!hs[l].rx_valid_hs) hs[l].rx_data_hs = 8'($urandom);   // not a byte: garbage
      hs[l].rx_sync_hs      = (c == pstore[p + 3]);
      hs[l].err_sot_hs      = (c == pstore[p + 3]) && (pstore[p + 7] != 0);
      hs[l].err_sot_sync_hs = (c == pstore[p + 4]);
      hs[l].rx_skew_cal_hs  = (pstore[p + 5] >= 0) && (c >= pstore[p + 5]) &&
                              (c < pstore[p + 5] + pstore[p + 6]);
    end
    while (tq_g.size() != 0) begin
      if (tq_g[0] > g) break;
      t_end[tq_n[0]] = csi2_now();
      void'(tq_g.pop_front());
      void'(tq_n.pop_front());
    end
    ppi_hs_o = hs;
    stop_q   = stop;
  endfunction

  initial begin : clock
    rx_byte_clk_hs_o = 1'b0;
    ppi_hs_o         = '0;
    forever begin
      if (run || cont) begin
        rx_byte_clk_hs_o = 1'b1;
        #(byte_ns * 0.1);
        drive(gcyc);
        gcyc++;
        #(byte_ns * 0.4);
        rx_byte_clk_hs_o = 1'b0;
        #(byte_ns * 0.5);
      end else begin
        wait (run || cont);
      end
    end
  end

  // ------------------------------------------------------------ lp domain
  // Pulse requests of the driver (written at falling edges, merged at rising edges) and the
  // pulses still to emit (written by the emitters only). The emitters only wake while they
  // have something to do.
  logic [N-1:0]     req_err = '0, pend_err = '0;
  logic [Lanes-1:0] req_std = '0, pend_std = '0;
  logic [N-1:0]     err_q = '0;
  logic [N-1:0][1:0] err_gray_q = '0;      // std = 0: the gray counters (v1.x)
  logic [Lanes-1:0] err_std_q = '0;

  // std = 0, video clock = the D-PHY's lp clock: one cycle pulses, one of a kind at most
  // every HoldVid cycles
  int unsigned hold_err [N];
  bit          vid_more = 1'b0;

  initial for (int i = 0; i < int'(N); i++) hold_err[i] = 0;

  always @(posedge vid_clk_i) begin
    logic [N-1:0] err;
    if (vid_more || req_err != '0) begin
      pend_err = pend_err | req_err;
      req_err  = '0;
      err      = '0;
      vid_more = 1'b0;
      for (int i = 0; i < int'(N); i++) begin
        if (hold_err[i] != 0) hold_err[i]--;
        else if (pend_err[i]) begin
          err[i]      = 1'b1;
          pend_err[i] = 1'b0;
          hold_err[i] = HoldVid;
        end
        if (hold_err[i] != 0) vid_more = 1'b1;
      end
      err_q <= std ? '0 : err;
      for (int i = 0; i < int'(N); i++) begin
        if (!std && err[i]) err_gray_q[i] <= {err_gray_q[i][0], ~err_gray_q[i][1]};
      end
      if (!std) cov_lp += $countones(err);
      if (err != '0 || pend_err != '0) vid_more = 1'b1;
    end
  end

  // std = 1: the PHY's lp clock (only then), its ErrControl pulses (one of a lane at most
  // every HoldLp cycles)
  initial begin : lp_clock
    lp_clk_o = 1'b0;
    forever begin
      wait (std);
      #(lp_ns / 2) lp_clk_o = ~lp_clk_o;
    end
  end

  int unsigned hold_std [Lanes];
  bit          std_more = 1'b0;

  initial for (int l = 0; l < int'(Lanes); l++) hold_std[l] = 0;

  always @(posedge lp_clk_o) begin
    logic [Lanes-1:0] err;
    if (std_more || req_std != '0) begin
      pend_std = pend_std | req_std;
      req_std  = '0;
      err      = '0;
      std_more = 1'b0;
      for (int l = 0; l < int'(Lanes); l++) begin
        if (hold_std[l] != 0) hold_std[l]--;
        else if (pend_std[l]) begin
          err[l]      = 1'b1;
          pend_std[l] = 1'b0;
          hold_std[l] = HoldLp;
        end
        if (hold_std[l] != 0) std_more = 1'b1;
      end
      err_std_q <= err;
      cov_lp += $countones(err);
      if (err != '0 || pend_std != '0) std_more = 1'b1;
    end
  end

  always_comb begin
    for (int l = 0; l < int'(Lanes); l++) begin
      ppi_lp_o[l].stopstate       = stop_q[l];
      ppi_lp_o[l].ulps_active_not = 1'b1;
      ppi_lp_o[l].rx_ulps_esc     = 1'b0;
      ppi_lp_o[l].err_control     = std ? {1'b0, err_std_q[l]} : err_gray_q[1 + l];
      ppi_lp_o[l].err_esc         = 2'b00;
      ppi_lp_o[l].err_sync_esc    = 2'b00;
    end
    ppi_lp_clk_o.stopstate        = !rx_clk_active;
    ppi_lp_clk_o.rx_clk_active_hs = rx_clk_active;
    ppi_lp_clk_o.ulps_active_not  = 1'b1;
    ppi_lp_clk_o.rx_ulps_clk_not  = 1'b1;
    ppi_lp_clk_o.err_control      = err_gray_q[0];
  end

  function automatic void report();
    $display("bow_ppi_bfm: %s timing, %0d bursts (byte clock edges after the last fall of RxActiveHS: %0d stop 4 byte clocks after it, %0d more, %0d 0..3, %0d before it), lanes: %0d RxActiveHS before RxSyncHS, %0d with it, %0d without RxActiveHS; %0d bytes, %0d gap cycles, %0d bytes with RxActiveHS low; ErrSotSyncHS %0d after the fall, %0d early; RxSkewCalHS %0d pulses, %0d levels; ErrSotHS %0d; lp domain pulses: %0d ErrControl / ErrControlClk",
             std ? "standard PHY" : "D-PHY of Bow32", bursts_done, cov_post4, cov_post_more,
             cov_post_short, cov_post_before, cov_act_early, cov_act_sync, cov_no_act, cov_bytes,
             cov_gaps, cov_low_bytes, cov_err_late, cov_err_early, cov_skew_pulse, cov_skew_level,
             cov_err_sot, cov_lp);
  endfunction

  function automatic bit busy();
    return items.size() != 0 || busy_q;
  endfunction

  // ---------------------------------------------------------------- driver
  initial begin : driver
    item_t it;
    bit    have;
    int    p, q, l, g0, maxf;
    forever begin
      // (size test into a variable: see csi2_tx_model's driver)
      have = (items.size() != 0);
      if (!have) begin
        wait (items.size() != 0);
        continue;
      end
      it = items.pop_front();
      busy_q = 1'b1;
      case (it.kind)
        ItEv: begin
          if (std) begin
            @(negedge lp_clk_o);
            req_std = req_std | it.a[Lanes-1:0];
            wait (req_std == '0 && pend_std == '0);
          end else begin
            @(negedge vid_clk_i);
            req_err = req_err | {it.a[Lanes-1:0], it.a[4]};
            wait (req_err == '0 && pend_err == '0);
          end
          #20;
        end
        ItBurst: begin
          #(real'(it.b));                         // LP time (a continuous clock keeps running)
          if (cont) @(negedge rx_byte_clk_hs_o);
          g0 = gcyc;
          maxf = -1;
          for (int i = 0; i < int'(it.n); i++) begin
            l = blane_l.pop_front();
            p = blane_p.pop_front();
            pstore[p] = g0;
            if (pstore[p + 1] >= 0 && pstore[p + 2] > maxf) maxf = pstore[p + 2];
            // the events of the lane's previous burst must be over before this one's start
            if (progs[l].size() != 0) begin
              q = progs[l][progs[l].size() - 1];
              if (pstore[q] + pstore[q + 10] >= g0 + pstore[p + 11]) overlaps++;
            end
            progs[l].push_back(p);
          end
          if ($signed(it.d) < 0) begin
            t_end[int'(it.a)] = csi2_now();
          end else begin
            tq_g.push_back(g0 + int'(it.d) + 1);
            tq_n.push_back(int'(it.a));
          end
          cur_burst = int'(it.a);
          cur_byte  = 0;
          // edges of the run after the one at which the last RxActiveHS falls (maxf)
          if (it.c != 0 && !cont && maxf >= 0) begin
            cov_runs++;
            if (int'(it.c) - 1 - maxf == 4)     cov_post4++;
            else if (int'(it.c) - 1 - maxf > 4) cov_post_more++;
            else if (int'(it.c) - 1 >= maxf)    cov_post_short++;
            else                                cov_post_before++;
          end
          if (it.c != 0) begin
            rx_clk_active = 1'b1;
            run = 1'b1;
            wait (gcyc >= g0 + int'(it.c));
            run = cont;
            rx_clk_active = cont;
          end
          bursts_done++;
          cur_burst = -1;
        end
        ItClk: begin
          rx_clk_active = 1'b1;
          run = 1'b1;
          #(real'(it.a));
          run = cont;
          rx_clk_active = cont;
        end
        ItOn: begin
          cont = 1'b1;
          rx_clk_active = 1'b1;
        end
        ItOff: begin
          cont = 1'b0;
          rx_clk_active = run;
        end
        ItIdle: #(real'(it.a));
        default: ;
      endcase
      busy_q = 1'b0;
    end
  end

endmodule
