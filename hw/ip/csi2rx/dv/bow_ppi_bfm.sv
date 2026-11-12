// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// PPI bus functional model: the PHY of the CSI-2 controller in its bench
// (hw/ip/csi2rx/dv/tb_csi2rx_ppi.sv). It plays the PPI lines of a test case of
// `tools/csi2/csi2_model.py gen --ppi bow|std` (their format: the PPI section of the model)
// on the PPI of bow_ppi_pkg and the temporary band of v1, in one of two timings (knob std):
//   std = 0  the D-PHY of Bow32 (bow_dphy_rx v1, the controller bow_csi2rx itself):
//            ErrControl / ErrControlClk and the band's HS entries are one cycle pulses of
//            vid_clk_i (the D-PHY's lp clock); band_lane_en_lp / band_clk_force_lp are
//            Enable / CTRL.CLK_FORCE through 2 vid_clk_i flops reset by band_lp_rst_ni, as
//            u_sync_vcfg of the D-PHY (so an error in the last cycle before a lane's mask
//            applies marks a lost burst, one in the first cycle after does not); RAW words
//            with a valid common to all lanes (the XPHY's FIFOs are read in step), low where
//            lane 0's RxValidHS has a gap 2 cycles later: other words before RxActiveHS
//            rises, then per valid cycle the lane's raw stream (00 words, B8 3 cycles before
//            RxSyncHS when no gap delays it, the lane's bytes without the gaps), other words
//            in the cycles without a valid; STATUS: LP-11, HS receivers off, CE =
//            RxClkActiveHS through 2 clk_i flops, PHY ready; byte clock meter and DLYn 0
//   std = 1  a standard PHY, to the flat wrapper bow_csi2rx_ppi_flat: ErrControl pulses on
//            its own lp clock (lp_clk_o, period lp_ns), no ErrControlClk, no band
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
//   push_ev(hs, err)                         lp domain pulses ('ppev': bit l data lane l,
//                                            bit 4 clock lane)
//   push_clk(ns), push_on(), push_off(), push_idle(ns)   'ppclk', 'ppon', 'ppoff', 'ppidle'
//   lp_error(mask, at)                       'lperr' (call while !busy()): pulses now (at
//                                            0), or in the first cycle in which the
//                                            controller's mask of the lane applies (at 1),
//                                            or in the last one in which it does not (2):
//                                            data lane: band_lane_en_lp falls; clock lane:
//                                            band_clk_force_lp rises
//   busy()                                   items queued or playing, or an lp_error waiting
// Status for the testbench: bursts_done, cur_burst / cur_byte (bytes driven so far, all
// lanes), t_end[n] (burst n: the edge after its cycle TEND, when the lane merge has the last
// byte; also in a later run when the clock stopped before it; the start of the burst
// without TEND), rx_clk_active (RxClkActiveHS), overlaps (a lane's burst starts before the
// events of its previous burst are over: a rendering error); report() prints what the run
// covered (cov_*: bursts by the byte clock edges after the one at which the last RxActiveHS
// falls, RxActiveHS before / with RxSyncHS, gap cycles, ErrSotSyncHS after the fall / early,
// RxSkewCalHS pulse / level, ErrSotHS, bytes with RxActiveHS low, lp pulses, mask edges,
// cycles without a RAW word).

`timescale 1ns / 1ps

module bow_ppi_bfm import bow_ppi_pkg::*; import csi2_tx_pkg::csi2_now; #(
  parameter int unsigned Lanes = 2
) (
  input  logic                  clk_i,               // CPU clock (band status)
  input  logic                  vid_clk_i,           // video clock: the lp clock of std = 0
  output logic                  lp_clk_o,            // std = 1: the PHY's lp clock

  output logic                  rx_byte_clk_hs_o,    // RxByteClkHS
  output ppi_hs_t [Lanes-1:0]   ppi_hs_o,
  output ppi_lp_t [Lanes-1:0]   ppi_lp_o,            // std 0: vid_clk_i, 1: lp_clk_o
  output ppi_lp_clk_t           ppi_lp_clk_o,
  input  logic [Lanes-1:0]      enable_i,            // Enable (controller)
  input  logic                  enable_clk_i,        // EnableClk

  // temporary band of v1 (std = 0)
  input  logic                  band_lp_rst_ni,      // the controller's vrst_n
  input  logic                  band_clk_force_i,    // CTRL.CLK_FORCE (CPU domain)
  output logic [Lanes:0][1:0]   band_lp_sys_o,
  output logic [Lanes:0]        band_hs_en_sys_o,
  output logic                  band_ce_sys_o,
  output logic                  band_phy_rdy_sys_o,
  output logic [19:0]           band_meter_sys_o,
  output logic [Lanes-1:0][8:0] band_dly_sys_o,
  output logic [Lanes:0]        band_ev_hs_o,        // [0] clock lane, [1 + l] data lane l
  output logic [Lanes-1:0]      band_lane_en_lp_o,
  output logic                  band_clk_force_lp_o,
  output logic [Lanes-1:0][7:0] band_raw_data_o,
  output logic [Lanes-1:0]      band_raw_valid_o
);

  localparam int unsigned N = Lanes + 1;              // lp kinds: [0] clock lane, [1 + l] lane l
  localparam int unsigned HoldVid = 20;               // video clocks between pulses of a kind
  localparam int unsigned HoldLp = 6;                 // std: lp clocks between pulses of a lane
  localparam int unsigned PF = 14;                    // ints per lane program in pstore

  // -------------------------------------------------------------- coverage
  int unsigned cov_runs = 0, cov_post4 = 0, cov_post_more = 0, cov_post_short = 0, cov_post_before = 0;
  int unsigned cov_act_early = 0, cov_act_sync = 0, cov_no_act = 0, cov_bytes = 0, cov_gaps = 0;
  int unsigned cov_err_late = 0, cov_err_early = 0, cov_skew_pulse = 0, cov_skew_level = 0;
  int unsigned cov_err_sot = 0, cov_low_bytes = 0, cov_hs = 0, cov_lp = 0, cov_edge1 = 0, cov_edge2 = 0;
  int unsigned cov_raw_gaps = 0;

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
  // starts), A, F, S, E, K, KL, H, OFF / LEN of its bytes in bstore (-1: a gap), ROFF / RLEN
  // of the bytes without gaps in rstore (RAW words), LAST / FIRST (its last / first event
  // cycle)
  int pstore [$];
  int bstore [$];
  int rstore [$];
  int progs [4][$];                        // per lane: programs, oldest first (4 entries:
                                           // with 1, a variable index does not compile
                                           // in Verilator 5.020)
  int pend_l [$], pend_p [$];              // lanes added for the next push_burst

  typedef enum logic [2:0] {ItEv, ItBurst, ItClk, ItOn, ItOff, ItIdle} kind_e;

  typedef struct packed {
    kind_e       kind;
    logic [31:0] a;      // burst: index; ev: HS mask; clk / idle: ns
    logic [31:0] b;      // burst: LP time (ns); ev: error mask
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
    pstore.push_back(rstore.size());
    pstore.push_back(0);
    pstore.push_back(last);
    pstore.push_back(first);
    for (int i = 0; i < n; i++) begin
      if (b.substr(2 * i, 2 * i + 1) == "--") begin
        bstore.push_back(-1);
      end else begin
        bstore.push_back(hex2(b, 2 * i));
        rstore.push_back(hex2(b, 2 * i));
      end
    end
    pstore[p + 11] = rstore.size() - pstore[p + 10];
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

  function automatic void push_ev(int hs, int err);
    push_item(ItEv, hs, err, 0, 0, 0);
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

  int rprog [4], rpos [4];                // RAW: the program of the lane's raw stream, its position

  initial for (int l = 0; l < 4; l++) rprog[l] = -1;

  // values of cycle g on every lane
  function automatic void drive(int g);
    ppi_hs_t [Lanes-1:0]   hs;
    logic [Lanes-1:0][7:0] raw;
    logic [Lanes-1:0]      stop;
    logic                  rv;
    int p, c, i, v, q, n00;
    hs   = '0;
    raw  = '0;
    stop = '1;
    // drop the programs whose events are over
    for (int l = 0; l < int'(Lanes); l++) begin
      while (progs[l].size() != 0) begin
        p = progs[l][0];
        if (pstore[p] + pstore[p + 12] >= g) break;
        void'(progs[l].pop_front());
      end
    end
    // RAW (std = 0): the XPHY's FIFOs of all lanes are read in step, so one valid for every
    // lane: low where lane 0's RxValidHS has a gap 2 cycles later (the aligner's latency)
    rv = 1'b1;
    if (progs[0].size() != 0) begin
      p = progs[0][0];
      i = g + 2 - pstore[p] - pstore[p + 3];
      if (g >= pstore[p] && pstore[p + 3] >= 0 && i >= 0 && i < pstore[p + 9]) begin
        rv = (bstore[pstore[p + 8] + i] >= 0);
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
      // RAW words (std = 0): other words before RxActiveHS rises; from it on, one word of
      // the lane's raw stream per valid cycle (00 words, B8 3 cycles before RxSyncHS when
      // no gap delays it, then the bytes without the gaps, then 00), other words where the
      // raw valid is low
      if (rprog[l] != p) begin
        rprog[l] = p;
        rpos[l]  = 0;
      end
      if (std) begin
        // no RAW words on the PPI of a standard PHY
      end else if (pstore[p + 1] >= 0 && c < pstore[p + 1]) begin
        raw[l] = 8'($urandom_range(255, 1));
      end else if (pstore[p + 3] >= 0 && pstore[p + 1] >= 0) begin
        if (!rv) begin
          raw[l] = 8'($urandom_range(255, 1));
        end else begin
          n00 = pstore[p + 3] - 3 - pstore[p + 1];
          q   = rpos[l];
          rpos[l]++;
          if (q == n00)                                     raw[l] = 8'hB8;
          else if (q > n00 && q - n00 - 1 < pstore[p + 11]) raw[l] = 8'(rstore[pstore[p + 10] + q - n00 - 1]);
        end
      end
    end
    while (tq_g.size() != 0) begin
      if (tq_g[0] > g) break;
      t_end[tq_n[0]] = csi2_now();
      void'(tq_g.pop_front());
      void'(tq_n.pop_front());
    end
    ppi_hs_o         = hs;
    band_raw_data_o  = raw;
    band_raw_valid_o = std ? '0 : {Lanes{rv}};
    stop_q           = stop;
    if (!std && !rv) cov_raw_gaps++;
  endfunction

  initial begin : clock
    rx_byte_clk_hs_o = 1'b0;
    ppi_hs_o         = '0;
    band_raw_data_o  = '0;
    band_raw_valid_o = '0;
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
  // Pulse requests of the driver (written at falling edges, merged at rising edges), the
  // pulses still to emit (written by the emitters only), the lp_error edges armed. The
  // emitters only wake while they have something to do.
  logic [N-1:0]     req_hs = '0, req_err = '0, pend_hs = '0, pend_err = '0;
  logic [N-1:0]     watch1 = '0, watch2 = '0;  // lp_error edge 1 / 2 armed
  logic [Lanes-1:0] req_std = '0, pend_std = '0;
  logic [N-1:0]     ev_hs_q = '0, err_q = '0;
  logic [Lanes-1:0] err_std_q = '0;
  logic [Lanes-1:0] en_s1 = '0, en_s2 = '0;
  logic             cf_s1 = 1'b0, cf_s2 = 1'b0;

  // std = 0, video clock = the D-PHY's lp clock: Enable and CLK_FORCE through 2 flops (as
  // u_sync_vcfg of the D-PHY); one cycle pulses, one of a kind at most every HoldVid
  // cycles; the lp_error edges, from the masks of the next two cycles (en_s1 / cf_s1 in the
  // cycle after this edge, the sampled input in the one after that). One static process:
  // the flops are read before this edge updates them; the rest only runs while there is
  // something to do.
  int unsigned hold_hs [N], hold_err [N];
  bit          vid_more = 1'b0;

  initial begin
    for (int i = 0; i < int'(N); i++) begin
      hold_hs[i]  = 0;
      hold_err[i] = 0;
    end
  end

  always @(posedge vid_clk_i or negedge band_lp_rst_ni) begin
    logic [N-1:0] hs, err;
    if (!band_lp_rst_ni) begin
      en_s1   <= '0;
      en_s2   <= '0;
      cf_s1   <= 1'b0;
      cf_s2   <= 1'b0;
      ev_hs_q <= '0;
      err_q   <= '0;
    end else begin
      if (vid_more || req_hs != '0 || req_err != '0 || watch1 != '0 || watch2 != '0) begin
        pend_hs  = pend_hs | req_hs;
        pend_err = pend_err | req_err;
        req_hs   = '0;
        req_err  = '0;
        hs       = '0;
        err      = '0;
        vid_more = 1'b0;
        for (int i = 0; i < int'(N); i++) begin
          if (hold_hs[i] != 0) hold_hs[i]--;
          else if (pend_hs[i]) begin
            hs[i]      = 1'b1;
            pend_hs[i] = 1'b0;
            hold_hs[i] = HoldVid;
          end
          if (hold_err[i] != 0) hold_err[i]--;
          else if (pend_err[i]) begin
            err[i]      = 1'b1;
            pend_err[i] = 1'b0;
            hold_err[i] = HoldVid;
          end
          if (hold_hs[i] != 0 || hold_err[i] != 0) vid_more = 1'b1;
        end
        for (int l = 0; l < int'(Lanes); l++) begin
          if (watch2[1 + l] && en_s1[l] && !enable_i[l]) begin   // last cycle enabled
            err[1 + l]    = 1'b1;
            watch2[1 + l] = 1'b0;
            cov_edge2++;
          end
          if (watch1[1 + l] && !en_s1[l] && en_s2[l]) begin      // first cycle disabled
            err[1 + l]    = 1'b1;
            watch1[1 + l] = 1'b0;
            cov_edge1++;
          end
        end
        if (watch2[0] && !cf_s1 && band_clk_force_i) begin       // last cycle without
          err[0]    = 1'b1;                                     // CLK_FORCE
          watch2[0] = 1'b0;
          cov_edge2++;
        end
        if (watch1[0] && cf_s1 && !cf_s2) begin                   // first cycle with it
          err[0]    = 1'b1;
          watch1[0] = 1'b0;
          cov_edge1++;
        end
        ev_hs_q <= std ? '0 : hs;
        err_q   <= std ? '0 : err;
        if (!std) begin
          cov_hs += $countones(hs);
          cov_lp += $countones(err);
        end
        if (hs != '0 || err != '0 || pend_hs != '0 || pend_err != '0) vid_more = 1'b1;
      end
      en_s1 <= enable_i;
      en_s2 <= en_s1;
      cf_s1 <= band_clk_force_i;
      cf_s2 <= cf_s1;
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

  // CE of STATUS: RxClkActiveHS through 2 CPU clock flops (as the D-PHY's byte clock gate)
  logic ce_s1 = 1'b0, ce_s2 = 1'b0;
  always @(posedge clk_i) begin
    ce_s1 <= rx_clk_active;
    ce_s2 <= ce_s1;
  end

  always_comb begin
    for (int l = 0; l < int'(Lanes); l++) begin
      ppi_lp_o[l].stopstate       = stop_q[l];
      ppi_lp_o[l].ulps_active_not = 1'b1;
      ppi_lp_o[l].rx_ulps_esc     = 1'b0;
      ppi_lp_o[l].err_control     = {1'b0, std ? err_std_q[l] : err_q[1 + l]};
      ppi_lp_o[l].err_esc         = 2'b00;
      ppi_lp_o[l].err_sync_esc    = 2'b00;
    end
    ppi_lp_clk_o.stopstate        = !rx_clk_active;
    ppi_lp_clk_o.rx_clk_active_hs = rx_clk_active;
    ppi_lp_clk_o.ulps_active_not  = 1'b1;
    ppi_lp_clk_o.rx_ulps_clk_not  = 1'b1;
    ppi_lp_clk_o.err_control      = {1'b0, err_q[0]};
  end

  assign band_lp_sys_o       = '1;
  assign band_hs_en_sys_o    = '0;
  assign band_ce_sys_o       = ce_s2;
  assign band_phy_rdy_sys_o  = 1'b1;
  assign band_meter_sys_o    = '0;
  assign band_dly_sys_o      = '0;
  assign band_ev_hs_o        = ev_hs_q;
  assign band_lane_en_lp_o   = en_s2;
  assign band_clk_force_lp_o = cf_s2;

  // lp_error: pulses now (an ev item), or armed for the next mask edge of each lane (call
  // at a falling edge of vid_clk_i)
  function automatic void lp_error(int mask, int at);
    logic [N-1:0] m;
    m = '0;
    for (int l = 0; l < int'(Lanes); l++) m[1 + l] = mask[l];
    m[0] = mask[4];
    if (at == 1)      watch1 = watch1 | m;
    else if (at == 2) watch2 = watch2 | m;
    else              push_ev(0, mask);
  endfunction

  function automatic void report();
    $display("bow_ppi_bfm: %s timing, %0d bursts (byte clock edges after the last fall of RxActiveHS: %0d stop 4 byte clocks after it, %0d more, %0d 0..3, %0d before it), lanes: %0d RxActiveHS before RxSyncHS, %0d with it, %0d without RxActiveHS; %0d bytes, %0d gap cycles, %0d bytes with RxActiveHS low; ErrSotSyncHS %0d after the fall, %0d early; RxSkewCalHS %0d pulses, %0d levels; ErrSotHS %0d; lp domain pulses: %0d HS entries, %0d ErrControl / ErrControlClk (mask edges: %0d last unmasked, %0d first masked cycle); %0d cycles without a RAW word",
             std ? "standard PHY" : "D-PHY of Bow32", bursts_done, cov_post4, cov_post_more,
             cov_post_short, cov_post_before, cov_act_early, cov_act_sync, cov_no_act, cov_bytes,
             cov_gaps, cov_low_bytes, cov_err_late, cov_err_early, cov_skew_pulse, cov_skew_level,
             cov_err_sot, cov_hs, cov_lp, cov_edge2, cov_edge1, cov_raw_gaps);
  endfunction

  function automatic bit busy();
    return items.size() != 0 || busy_q || watch1 != '0 || watch2 != '0;
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
            req_std = req_std | it.b[Lanes-1:0];
            wait (req_std == '0 && pend_std == '0);
          end else begin
            @(negedge vid_clk_i);
            req_hs  = req_hs | {it.a[Lanes-1:0], it.a[4]};
            req_err = req_err | {it.b[Lanes-1:0], it.b[4]};
            wait (req_hs == '0 && req_err == '0 && pend_hs == '0 && pend_err == '0);
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
              if (pstore[q] + pstore[q + 12] >= g0 + pstore[p + 13]) overlaps++;
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
