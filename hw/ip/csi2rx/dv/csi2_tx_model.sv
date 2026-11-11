// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MIPI D-PHY / CSI-2 transmitter model for the Bow32 CSI-2 receiver
// testbenches (hw/ip/csi2rx/dv/tb_bow_csi2rx.sv, sim/tb/tb_bow32.sv).
//
// The model replaces the sensor AND the board level receive I/O: its ports
// are the D-PHY side of bow_mipi_rx with the names of the PHY wrappers
// (without the pads). Two PHY flavours (knob `versal`):
//   versal = 0  hw/fpga/common/rtl/bow_dphy_io_xusp.sv (UltraScale+): a word
//               on every byte clock (rx_valid_o = '1), IDELAY taps loaded on
//               byte clock edges, phy_rdy_o = 1.
//   versal = 1  hw/fpga/common/rtl/bow_dphy_io_versal.sv (XPHY in native
//               mode, receiver built with DlyVid = 1), see "Versal PHY".
//
//   * byte_clk_o toggles (period byte_ns) only while the clock lane toggles
//     AND byte_ce_i = 1 (BUFGCE CE_TYPE SYNC). With runt = 1, CE = 1 while
//     the clock lane is in an LP state gives short runt pulses.
//   * rx_data_o: the serial stream of every lane cut into words at a random
//     (or given) bit phase per burst, bit 0 first, updated just after the
//     byte_clk_o rising edge. 0 while hs_en_i[l] = 0 or (versal = 0)
//     byte_rst_i = 1. Random bits during HS-PREPARE, zeros in HS-ZERO, then
//     the sync byte, the bytes of the lane, HS-TRAIL (inverted last bit),
//     and that constant until the receiver drops hs_en.
//   * versal = 0: the bits keep flowing while the byte clock is gated: they
//     are lost, not delayed. IDELAY: dly_tap_i is loaded on byte_clk_o
//     edges with dly_load_i, dly_tap_o is the loaded value.
//   * Eye model: while the tap of a lane is outside [eye_lo, eye_hi], every
//     received bit flips with probability 1/4.
//   * One burst carries one packet (byte i on lane i % lanes). The clock lane
//     does its own HS entry before every burst (LP-11, LP-01, LP-00,
//     HS-0 CLK-ZERO, CLK-PRE) and its exit after it (CLK-POST, HS-0
//     CLK-TRAIL, LP-11), unless contclk = 1 (one entry, then it toggles
//     forever). Data lanes: LP-11 (HS-EXIT), LP-01 (T_LPX), LP-00
//     HS-PREPARE, HS-ZERO, data, HS-TRAIL, LP-11.
//
// Versal PHY (versal = 1; byte clock = BUFGCE of the strobe nibble FIFO_WR_CLK):
//   * phy_rdy_o rises t_phy_rdy ns after time 0 (XPLL lock + BISC); before
//     that there is no byte clock at all. phy_reinit = 1 (knob, e.g. the
//     reinit input of bow_dphy_io_versal) holds the PHY in its init: no
//     PHY_RDY, no byte clock, FIFOs empty, loaded taps forgotten; on release
//     PHY_RDY rises t_reinit ns later with the BISC taps again.
//   * Per lane an 8 word RX FIFO, written with the word of every step in which
//     the clock lane toggles while its HS receiver is on (clk_hs_en_i = 1:
//     HSRX_DISABLE = ~clk_hs_en, no strobe otherwise), whether or not the byte
//     clock gate is open; read on byte_clk_o edges: rx_valid_o[l] = 1 when a
//     word was read, else rx_data_o[l] is garbage. A word is read once the
//     FIFO holds more than vlat[l] words (0..2: FIFO_EMPTY lags the write
//     pointer), drawn when the FIFOs restart, one value for all lanes
//     (v_lat_lane = 0, AMD's XPHY model shows the same latency on every
//     nibble) or one per lane (v_lat_lane = 1). Write and read clock are the
//     same strobe, so the number of words in a FIFO never shrinks: the words
//     left at the end of a burst come out first in the next one (stale words,
//     before the SoT), and every word written while the gate is closed adds
//     one word of latency for good. A 9th word overwrites the oldest unread
//     one: the write pointer laps the read pointer and the reader jumps over
//     the 8 oldest words (v_wraps, words lost).
//   * BurstRxRst (v_burst_rst): 0 (the shipped default) = the FIFOs restart
//     only at the PHY init; then the opening of the byte clock gate adds one
//     garbage word to every FIFO with probability v_glitch_pct % (strobe
//     glitches at the HS entry and exit of the clock lane, while the gate is
//     closed), so the latency drifts up and wraps. 1 = the FIFOs are held in
//     reset while the gate is closed (glitch words dropped) and restart at
//     every opening (new vlat).
//   * A byte clock without a read on all lanes (FIFO_EMPTY seen for one more
//     cycle) comes with probability v_gap_pm per mille, only while every FIFO
//     is at its minimum (vlat[l] + 1 words before the read): one extra word
//     of latency, at most one per restart or wrap.
//   * Input delays in the ctrl_clk_i domain (CTRL_CLK = video clock of the
//     receiver): after phy_rdy_o, dly_tap_o[l] = bisc[l] (BISC result) until
//     a load. A load (dly_load_i one cycle with dly_tap_i) shows in
//     dly_tap_o 10 cycles later for the first load of a lane, else 2 cycles
//     later; loads before phy_rdy_o are ignored. Contract checks (counters):
//     dly_bad = dly_load_i longer than one cycle or dly_tap_i not stable
//     from 1 cycle before until 8 cycles after the load, dly_drop = a load
//     while the previous one of the lane is pending; dly_loads[l] = loads.
//   * byte_rst_i is not used.
//
// API: functions without delays (Verilator inlines tasks with delays at every
// call site); one timed driver process plays the queue in order.
//   push_short(vc, dt, data, f)   short packet (ECC computed here)
//   push_long(vc, dt, payload, f) long packet (header, ECC and CRC computed here)
//   push_burst(bytes, f)          one burst of raw packet bytes
//   push_lp(mask, lp, ns)         LP state lp ({P, N}) for ns on the lanes in mask
//                                 (bit l: data lane l, bit 4: clock lane), others LP-11
//   idle(ns)                      LP-11 for ns (the continuous clock keeps toggling)
//   clk_on()                      start the continuous clock now (needs contclk = 1)
//   push_clk_burst(ns)            clock lane HS burst only, the clock toggles for ns
//                                 (lets the receiver finish deferred work; idle(ns)
//                                 with contclk = 1)
//   busy()                        1 while items are queued or being played
// Durations are rounded to whole byte clock periods (at least one).
// f = csi2_flags() means no error; its fields (see csi2_flags_t):
//   hdr_flip_a/b  header bit to flip (bit j of header byte i = 8 * i + j), -1 none
//   pay_flip      payload/CRC bit to flip (bit 0 = bit 0 of the first payload byte)
//   trunc         packet bytes sent before the trail, -1 all
//   sync[l]       sync byte of lane l (8'hB8)
//   zeros[l]      extra HS-zero bytes on lane l (lane skew)
//   phase[l]      bit phase of lane l, 0..7 (8 or more: random)
//   zero_ns       extra HS-zero time, -1: random 0..64 ns
// Knobs (variables, change them while !busy()): byte_ns, lanes, contclk,
// lp00 (all lanes at LP-00 until the first item: sensor not streamed yet),
// runt, eye_lo[l] / eye_hi[l], and the timings in ns: t_lpx, t_hs_prepare,
// t_hs_zero, t_hs_trail, t_hs_exit, t_clk_prepare, t_clk_zero, t_clk_pre,
// t_clk_post, t_clk_trail, t_lp11_next (clock lane LP-11 between bursts);
// Versal PHY: versal, t_phy_rdy, bisc[l], v_lat_lane, v_glitch_pct, v_gap_pm
// (set these at time 0), v_burst_rst, phy_reinit, t_reinit (any time: run
// time inputs of the PHY).
// Status for checks (times in ns from csi2_now()):
//   bursts, bursts_done           bursts started / finished
//   cur_burst, cur_byte           burst being sent (-1: none), its packet bytes sent so far
//   t_end[]                       per burst: last packet byte sent on all lanes (versal:
//                                 read from the FIFOs of all lanes)
//   t_lp00[], t_lp11[]            per lane ([4] = clock lane): last LP-01 -> LP-00,
//                                 last change to LP-11
//   ce_bad, t_ce_bad              steps with CE open while the clock lane is in an
//                                 LP state, time of the first one
//   ce_rise_toggle, runts, flips  CE opened while the clock toggled, runt pulses,
//                                 bits flipped by the eye model
//   dly_loads[], dly_bad, dly_drop   Versal PHY delay contract (above)
//   v_wraps[], v_glitches, v_gaps, v_occ_max   Versal PHY FIFOs: wraps per lane (8
//                                 words lost each), glitch words, read gaps, most
//                                 words seen in a FIFO before a read
// Package csi2_tx_pkg: csi2_flags(), csi2_header(vc, dt, wc), csi2_ecc(d24),
// csi2_crc(bytes), csi2_raw10(pixels), csi2_now(). Examples:
//   csi2_tx_model #(.Lanes(2)) u_tx (.byte_clk_o (dphy_byte_clk), ...);
//   csi2_tx_model #(.Lanes(4)) u_tx (..., .rx_valid_o (dphy_rx_valid), .ctrl_clk_i (vid_clk),
//                                   .phy_rdy_o (dphy_phy_rdy));   // u_tx.versal = 1 at time 0
//   u_tx.push_short(0, 8'h00, 1, csi2_flags());             // FS, frame 1
//   u_tx.push_long(0, 8'h2B, csi2_raw10(px), csi2_flags()); // one RAW10 line

// Package time unit 1 ps: csi2_now() reads $time in ps. (In Verilator 5.022
// $realtime used inside an expression is truncated to the time unit.)
`timescale 1ps / 1ps

/* verilator lint_off DECLFILENAME */
package csi2_tx_pkg;

  // Simulation time in ns, exact to the ps
  function automatic realtime csi2_now();
    return real'($time) / 1000.0;
  endfunction

  typedef byte unsigned csi2_bytes_t [$];

  // Per lane fields for up to 4 data lanes
  typedef struct packed {
    logic signed [7:0]  hdr_flip_a;
    logic signed [7:0]  hdr_flip_b;
    logic signed [31:0] pay_flip;
    logic signed [31:0] trunc;
    logic [3:0][7:0]    sync;
    logic [3:0][7:0]    zeros;
    logic [3:0][3:0]    phase;
    logic signed [15:0] zero_ns;
  } csi2_flags_t;

  function automatic csi2_flags_t csi2_flags();
    csi2_flags_t f;
    f.hdr_flip_a = -8'sd1;
    f.hdr_flip_b = -8'sd1;
    f.pay_flip   = -1;
    f.trunc      = -1;
    f.sync       = {4{8'hB8}};
    f.zeros      = '0;
    f.phase      = {4{4'd8}};
    f.zero_ns    = -16'sd1;
    return f;
  endfunction

  // CSI-2 v1.x header ECC: column of every data bit D0..D23 (bit i = P_i)
  localparam logic [23:0][5:0] EccCol = {
    6'h3B, 6'h37, 6'h2F, 6'h1F, 6'h38, 6'h34, 6'h32, 6'h31, 6'h2C, 6'h2A, 6'h29, 6'h26,
    6'h25, 6'h23, 6'h1C, 6'h1A, 6'h19, 6'h16, 6'h15, 6'h13, 6'h0E, 6'h0D, 6'h0B, 6'h07};

  function automatic logic [7:0] csi2_ecc(logic [23:0] d);
    logic [5:0] p;
    p = '0;
    for (int i = 0; i < 24; i++) begin
      if (d[i]) p ^= EccCol[i];
    end
    return {2'b00, p};
  endfunction

  // Payload CRC: x^16+x^12+x^5+1 reflected (0x8408), init 0xFFFF
  function automatic logic [15:0] csi2_crc(csi2_bytes_t b);
    logic [15:0] c;
    c = 16'hFFFF;
    foreach (b[i]) begin
      c ^= 16'(b[i]);
      for (int k = 0; k < 8; k++) c = c[0] ? (c >> 1) ^ 16'h8408 : c >> 1;
    end
    return c;
  endfunction

  // Packet header: DI, WC LSB, WC MSB, ECC
  function automatic csi2_bytes_t csi2_header(int unsigned vc, int unsigned dt, int unsigned wc);
    csi2_bytes_t b;
    logic [23:0] h;
    h = {wc[15:0], vc[1:0], dt[5:0]};
    b.delete();
    b.push_back(h[7:0]);
    b.push_back(h[15:8]);
    b.push_back(h[23:16]);
    b.push_back(csi2_ecc(h));
    return b;
  endfunction

  // RAW10: 4 pixels -> 5 bytes (P0..P3 [9:2], then the 2 LSBs of each)
  function automatic csi2_bytes_t csi2_raw10(logic [9:0] px [$]);
    csi2_bytes_t b;
    b.delete();
    for (int i = 0; i + 3 < px.size(); i += 4) begin
      for (int k = 0; k < 4; k++) b.push_back(px[i + k][9:2]);
      b.push_back({px[i + 3][1:0], px[i + 2][1:0], px[i + 1][1:0], px[i][1:0]});
    end
    return b;
  endfunction

endpackage
/* verilator lint_on DECLFILENAME */

`timescale 1ns / 1ps

module csi2_tx_model import csi2_tx_pkg::*; #(
  parameter int unsigned Lanes = 2     // data lanes 1..4
) (
  output logic                  byte_clk_o,
  input  logic                  byte_ce_i,
  input  logic                  byte_rst_i,
  output logic [1:0]            clk_lp_o,
  input  logic                  clk_hs_en_i,
  output logic [Lanes-1:0][1:0] lp_o,
  input  logic [Lanes-1:0]      hs_en_i,
  output logic [Lanes-1:0][7:0] rx_data_o,
  output logic [Lanes-1:0]      rx_valid_o,   // versal = 0: '1
  input  logic [Lanes-1:0][8:0] dly_tap_i,
  input  logic [Lanes-1:0]      dly_load_i,
  output logic [Lanes-1:0][8:0] dly_tap_o,
  input  logic                  ctrl_clk_i,   // versal = 1: delay control clock (receiver video clock)
  output logic                  phy_rdy_o     // versal = 0: 1
);

  localparam int unsigned ML   = 4;                       // lanes of the internal arrays
  localparam int unsigned CL   = ML;                      // clock lane index (masks, pins, t_lp*)
  localparam int unsigned NEye = (Lanes > 2) ? Lanes : 2;
  localparam int unsigned VDepth = 8;                     // XPHY RX FIFO words

  // ------------------------------------------------------------------ knobs
  realtime     byte_ns = 8.772;
  int unsigned lanes   = Lanes;
  bit          contclk = 1'b0;
  bit          lp00    = 1'b1;
  bit          runt    = 1'b0;
  int unsigned eye_lo [NEye] = '{default: 0};
  int unsigned eye_hi [NEye] = '{default: 511};
  int unsigned t_lpx = 60, t_hs_prepare = 60, t_hs_zero = 150, t_hs_trail = 70, t_hs_exit = 110;
  int unsigned t_clk_prepare = 60, t_clk_zero = 300, t_clk_pre = 20, t_clk_post = 120;
  int unsigned t_clk_trail = 70, t_lp11_next = 120;
  bit          versal = 1'b0;
  int unsigned t_phy_rdy = 2000, t_reinit = 20_000;
  int unsigned bisc [ML] = '{97, 112, 88, 120};
  bit          v_burst_rst = 1'b0, v_lat_lane = 1'b0, phy_reinit = 1'b0;
  int unsigned v_glitch_pct = 20, v_gap_pm = 0;

  // ----------------------------------------------------------------- status
  int unsigned bursts = 0, bursts_done = 0;
  int          cur_burst = -1;
  int unsigned cur_byte = 0;
  realtime     t_end [$];
  realtime     t_lp00 [ML + 1] = '{default: 0.0};
  realtime     t_lp11 [ML + 1] = '{default: 0.0};
  int unsigned ce_bad = 0, ce_rise_toggle = 0, runts = 0, flips = 0;
  realtime     t_ce_bad = -1.0;       // first step counted in ce_bad
  int unsigned dly_loads [ML] = '{default: 0};
  int unsigned dly_bad = 0, dly_drop = 0;
  int unsigned v_wraps [ML] = '{default: 0};
  int unsigned v_glitches = 0, v_gaps = 0, v_occ_max = 0;

  // ------------------------------------------------------------ item queue
  typedef enum logic [2:0] {ItBurst, ItLp, ItIdle, ItClkOn, ItClkBurst} kind_e;

  typedef struct packed {
    kind_e       kind;
    logic [31:0] n;       // burst: bytes in data_q; LP / idle: ns
    logic [ML:0] mask;    // [l] data lane l, [CL] clock lane
    logic [1:0]  lp;
    csi2_flags_t f;
  } item_t;

  item_t        items [$];
  byte unsigned data_q [$];

  function automatic void push_burst(csi2_bytes_t b, csi2_flags_t f);
    item_t it;
    it      = '0;
    it.kind = ItBurst;
    it.n    = b.size();
    it.f    = f;
    foreach (b[i]) data_q.push_back(b[i]);
    items.push_back(it);
  endfunction

  function automatic void push_short(int unsigned vc, int unsigned dt, int unsigned data,
                                     csi2_flags_t f);
    push_burst(csi2_header(vc, dt, data), f);
  endfunction

  function automatic void push_long(int unsigned vc, int unsigned dt, csi2_bytes_t payload,
                                    csi2_flags_t f);
    csi2_bytes_t b;
    logic [15:0] c;
    b = csi2_header(vc, dt, payload.size());
    foreach (payload[i]) b.push_back(payload[i]);
    c = csi2_crc(payload);
    b.push_back(c[7:0]);
    b.push_back(c[15:8]);
    push_burst(b, f);
  endfunction

  function automatic void push_lp(int unsigned mask, logic [1:0] lp, int unsigned ns);
    item_t it;
    it      = '0;
    it.kind = ItLp;
    it.mask = mask[ML:0];
    it.lp   = lp;
    it.n    = ns;
    items.push_back(it);
  endfunction

  function automatic void idle(int unsigned ns);
    item_t it;
    it      = '0;
    it.kind = ItIdle;
    it.n    = ns;
    items.push_back(it);
  endfunction

  function automatic void clk_on();
    item_t it;
    it      = '0;
    it.kind = ItClkOn;
    items.push_back(it);
  endfunction

  function automatic void push_clk_burst(int unsigned ns);
    item_t it;
    it      = '0;
    it.kind = ItClkBurst;
    it.n    = ns;
    items.push_back(it);
  endfunction

  // --------------------------------------------------------- step program
  // The driver plays one step per byte clock period.
  typedef enum logic [1:0] {ClkLp, ClkHs0, ClkToggle} clk_e;

  typedef struct packed {
    clk_e               clk;
    logic [1:0]         clk_lp;   // clock lane LP state when clk = ClkLp
    logic [ML-1:0]      hs;       // data lane l in HS (LP receivers see LP-00)
    logic [ML-1:0][1:0] lp;       // data lane LP state when not in HS
    logic [ML-1:0][7:0] word;     // HS bits of the step, bit 0 first
    logic               tend;     // last packet byte complete on all lanes
    logic               done;     // last step of a burst
    logic [15:0]        nbyte;    // packet bytes sent after this step
  } step_t;

  step_t prog [$];
  bit    clk_running = 1'b0;

  function automatic int unsigned nsteps(int unsigned ns);
    int unsigned n;
    n = int'(real'(ns) / byte_ns);          // a real to int cast rounds
    return (n == 0) ? 1 : n;
  endfunction

  function automatic step_t idle_step();
    step_t s;
    s        = '0;
    s.clk    = clk_running ? ClkToggle : ClkLp;
    s.clk_lp = lp00 ? 2'b00 : 2'b11;
    s.lp     = lp00 ? '0 : '1;
    return s;
  endfunction

  function automatic void push_steps(int unsigned n, step_t s);
    for (int unsigned i = 0; i < n; i++) prog.push_back(s);
  endfunction

  // Clock lane HS entry (LP-11, LP-01, LP-00, HS-0) and the first CLK-PRE
  function automatic void clock_entry();
    step_t s;
    s = idle_step();
    s.clk = ClkLp;
    s.clk_lp = 2'b11;
    push_steps(nsteps(t_lp11_next), s);
    s.clk_lp = 2'b01;
    push_steps(nsteps(t_lpx), s);
    s.clk_lp = 2'b00;
    push_steps(nsteps(t_clk_prepare), s);
    s.clk = ClkHs0;
    push_steps(nsteps(t_clk_zero), s);
    s.clk = ClkToggle;
    push_steps(nsteps(t_clk_pre), s);
    clk_running = 1'b1;
  endfunction

  // Clock lane exit: CLK-POST, then HS-0 CLK-TRAIL (LP-11 follows)
  function automatic void clock_exit();
    step_t s;
    s = idle_step();
    s.clk = ClkToggle;
    push_steps(nsteps(t_clk_post), s);
    s.clk = ClkHs0;
    push_steps(nsteps(t_clk_trail), s);
    clk_running = 1'b0;
  endfunction

  function automatic void build_burst(item_t it);
    csi2_bytes_t b;
    int unsigned n, nl [ML], rb [ML], sb [ML], db [ML], de [ML], hs_steps [ML], ph [ML];
    int unsigned p_zero, nhs, tstep, klast, i, idx, cnt;
    logic        trail [ML];
    step_t       s;
    b.delete();
    for (int unsigned k = 0; k < it.n; k++) b.push_back(data_q.pop_front());
    if (it.f.hdr_flip_a >= 0) b[it.f.hdr_flip_a >> 3] ^= 8'(1 << (it.f.hdr_flip_a & 7));
    if (it.f.hdr_flip_b >= 0) b[it.f.hdr_flip_b >> 3] ^= 8'(1 << (it.f.hdr_flip_b & 7));
    if (it.f.pay_flip >= 0) b[4 + (it.f.pay_flip >> 3)] ^= 8'(1 << (it.f.pay_flip & 7));
    if (it.f.trunc >= 0) begin
      while (b.size() > it.f.trunc) void'(b.pop_back());
    end
    n = b.size();
    p_zero = nsteps(t_hs_zero + ((it.f.zero_ns >= 0) ? int'(it.f.zero_ns) : $urandom_range(64)));
    for (int l = 0; l < int'(ML); l++) begin
      nl[l] = (l < lanes && n > l) ? (n - l + lanes - 1) / lanes : 0;
      // (random phases of lanes 0/1 drawn even if unused: same draws as with 2 lanes)
      if (it.f.phase[l] < 8)          ph[l] = 32'(it.f.phase[l]);
      else if (l < 2 || l < lanes)    ph[l] = $urandom_range(7);
      else                            ph[l] = 0;
      rb[l] = 8 * nsteps(t_hs_prepare) + ph[l];
      sb[l] = rb[l] + 8 * (p_zero + 32'(it.f.zeros[l]));
      db[l] = sb[l] + 8;
      de[l] = db[l] + 8 * nl[l];
      hs_steps[l] = (de[l] + 8 * nsteps(t_hs_trail) + 7) / 8;
      trail[l] = (nl[l] != 0) ? ~b[(nl[l] - 1) * lanes + l][7] : ~it.f.sync[l][7];
    end
    // the merge outputs packet byte n - 1 once every lane has its byte klast
    klast = (n == 0) ? 0 : (n - 1) / lanes;
    tstep = 0;
    nhs = 0;
    for (int l = 0; l < int'(lanes); l++) begin
      if ((db[l] + 8 * klast + 7) / 8 > tstep) tstep = (db[l] + 8 * klast + 7) / 8;
      if (hs_steps[l] > nhs) nhs = hs_steps[l];
    end

    cur_burst = int'(bursts);
    bursts++;
    if (!contclk) begin
      if (clk_running) clock_exit();
      clock_entry();
    end else if (!clk_running) begin
      clock_entry();
    end
    s = idle_step();
    s.clk = ClkToggle;
    s.lp = '1;
    if (contclk) push_steps(nsteps(t_hs_exit), s);
    for (int l = 0; l < int'(lanes); l++) s.lp[l] = 2'b01;
    push_steps(nsteps(t_lpx), s);
    for (int unsigned k = 0; k < nhs; k++) begin
      s = idle_step();
      s.clk = ClkToggle;
      s.lp = '1;
      cnt = 0;
      for (int l = 0; l < int'(lanes); l++) begin
        if (k < hs_steps[l]) begin
          s.hs[l] = 1'b1;
          for (int j = 0; j < 8; j++) begin
            i = 8 * k + j;
            if (i < rb[l]) s.word[l][j] = 1'($urandom_range(1));
            else if (i < sb[l]) s.word[l][j] = 1'b0;
            else if (i < db[l]) s.word[l][j] = it.f.sync[l][i - sb[l]];
            else if (i < de[l]) begin
              idx = ((i - db[l]) / 8) * lanes + l;
              s.word[l][j] = b[idx][(i - db[l]) % 8];
            end else s.word[l][j] = trail[l];
          end
        end
        if (8 * (k + 1) > db[l]) cnt += ((8 * (k + 1) - db[l]) / 8 < nl[l]) ? (8 * (k + 1) - db[l]) / 8 : nl[l];
      end
      s.nbyte = 16'(cnt);
      s.tend  = (k == tstep);
      prog.push_back(s);
    end
    s = idle_step();
    s.clk = ClkToggle;
    s.lp = '1;
    s.nbyte = 16'(n);
    if (!contclk) begin
      push_steps(nsteps(t_clk_post), s);
      s.clk = ClkHs0;
      push_steps(nsteps(t_clk_trail), s);
      clk_running = 1'b0;
    end
    s = prog.pop_back();
    s.done = 1'b1;
    prog.push_back(s);
  endfunction

  // Next queued item -> steps; with an empty queue nothing (idle step)
  function automatic void next_item();
    item_t it;
    step_t s;
    if (items.size() == 0) begin
      if (!contclk && clk_running) clock_exit();
      return;
    end
    it = items.pop_front();
    lp00 = 1'b0;
    case (it.kind)
      ItBurst: build_burst(it);
      ItLp: begin
        if (it.mask[CL]) clk_running = 1'b0;
        s = idle_step();
        if (it.mask[CL]) s.clk_lp = it.lp;
        for (int l = 0; l < int'(ML); l++) if (it.mask[l]) s.lp[l] = it.lp;
        push_steps(nsteps(it.n), s);
      end
      ItIdle: push_steps(nsteps(it.n), idle_step());
      ItClkBurst: begin
        if (!contclk) begin
          if (!clk_running) clock_entry();
          s = idle_step();
          push_steps(nsteps(it.n), s);
          clock_exit();
        end else begin
          push_steps(nsteps(it.n), idle_step());
        end
      end
      default: if (!clk_running) clock_entry();
    endcase
  endfunction

  function automatic bit busy();
    return items.size() != 0 || prog.size() != 0;
  endfunction

  // ----------------------------------------------------- input delay models
  // versal = 0: IDELAY loaded on byte clock edges
  logic [ML-1:0][8:0] tap_k = '0;

  always @(posedge byte_clk_o) begin
    if (!versal) begin
      for (int l = 0; l < int'(Lanes); l++) begin
        if (dly_load_i[l]) tap_k[l] <= dly_tap_i[l];
      end
    end
  end

  // versal = 1: XPHY delays, CTRL_CLK domain
  logic [ML-1:0][8:0] tap_v = '0, vval = '0, tap_prev = '0, hold_tap = '0;
  logic [ML-1:0]      vpend = '0, vfirst = '1, ld_prev = '0;
  int unsigned        vcnt [ML] = '{default: 0};
  int unsigned        hold_cnt [ML] = '{default: 0};
  bit                 rdy_q = 1'b0;

  always @(posedge ctrl_clk_i) begin
    if (versal) begin
      if (phy_rdy_o && !rdy_q) begin
        for (int l = 0; l < int'(ML); l++) if (!vpend[l]) tap_v[l] = 9'(bisc[l]);
      end
      if (!phy_rdy_o && rdy_q) begin           // PHY re-init: loaded taps and pending loads gone
        vpend  = '0;
        vfirst = '1;
      end
      rdy_q = phy_rdy_o;
      for (int l = 0; l < int'(Lanes); l++) begin
        if (vpend[l]) begin
          if (vcnt[l] == 0) begin
            tap_v[l] = vval[l];
            vpend[l] = 1'b0;
          end else begin
            vcnt[l]--;
          end
        end
        if (dly_load_i[l]) begin
          dly_loads[l]++;
          if (ld_prev[l] || dly_tap_i[l] != tap_prev[l]) dly_bad++;
          if (phy_rdy_o) begin
            if (vpend[l]) begin
              dly_drop++;
            end else begin
              vpend[l]  = 1'b1;
              vcnt[l]   = vfirst[l] ? 9 : 1;
              vval[l]   = dly_tap_i[l];
              vfirst[l] = 1'b0;
            end
          end
          hold_cnt[l] = 8;
          hold_tap[l] = dly_tap_i[l];
        end else if (hold_cnt[l] != 0) begin
          hold_cnt[l]--;
          if (dly_tap_i[l] != hold_tap[l]) dly_bad++;
        end
        tap_prev[l] = dly_tap_i[l];
        ld_prev[l]  = dly_load_i[l];
      end
    end
  end

  always_comb begin
    for (int l = 0; l < int'(Lanes); l++) begin
      dly_tap_o[l] = !versal ? tap_k[l] : (phy_rdy_o ? tap_v[l] : 9'd0);
    end
  end

  function automatic logic [8:0] tap_of(int l);
    return versal ? tap_v[l] : tap_k[l];
  endfunction

  // ----------------------------------------------------------------- driver
  logic [ML:0][1:0]   pin_q = '0;        // LP state of the lanes, [CL] = clock lane
  logic [ML-1:0][7:0] idle_word = '0;    // HS receiver output outside HS (trail constant)
  bit                 ce_q = 1'b0;

  // Pins of a step, timestamps, burst progress
  function automatic void apply(step_t s);
    logic [ML:0][1:0] pin;
    for (int l = 0; l < int'(ML); l++) pin[l] = s.hs[l] ? 2'b00 : s.lp[l];
    pin[CL] = (s.clk == ClkLp) ? s.clk_lp : 2'b00;
    for (int l = 0; l <= int'(ML); l++) begin
      if (pin_q[l] == 2'b01 && pin[l] == 2'b00) t_lp00[l] = csi2_now();
      if (pin_q[l] != 2'b11 && pin[l] == 2'b11) t_lp11[l] = csi2_now();
    end
    for (int l = 0; l < int'(ML); l++) begin
      if (!s.hs[l]) idle_word[l] = (s.lp[l] == 2'b11) ? idle_word[l] : (s.lp[l] == 2'b10) ? 8'hFF : 8'h00;
      else idle_word[l] = {8{s.word[l][7]}};
    end
    pin_q = pin;
    clk_lp_o = pin[CL];
    for (int l = 0; l < int'(Lanes); l++) lp_o[l] = pin[l];
    if (cur_burst >= 0) cur_byte = 32'(s.nbyte);
    if (s.tend && !versal) t_end.push_back(csi2_now());
    if (s.done) begin
      bursts_done++;
      cur_burst = -1;
    end
    if (byte_ce_i && s.clk == ClkLp) begin
      if (ce_bad == 0) t_ce_bad = csi2_now();
      ce_bad++;
    end
    if (byte_ce_i && !ce_q && s.clk == ClkToggle) ce_rise_toggle++;
  endfunction

  // HS receiver output of lane l in a step, with the eye model
  function automatic logic [7:0] hs_word(step_t s, int l, bit gate);
    logic [7:0] w, e;
    w = s.hs[l] ? s.word[l] : idle_word[l];
    if (!hs_en_i[l] || gate) begin
      w = '0;
    end else if (32'(tap_of(l)) < eye_lo[l] || 32'(tap_of(l)) > eye_hi[l]) begin
      e = 8'($urandom) & 8'($urandom);
      w ^= e;
      flips += $countones(e);
    end
    return w;
  endfunction

  // versal = 0: ISERDES output of a step
  function automatic void rx_word(step_t s);
    for (int l = 0; l < int'(Lanes); l++) rx_data_o[l] = hs_word(s, l, byte_rst_i);
  endfunction

  // versal = 1: XPHY RX FIFOs. vtend[l]: burst ends (last packet byte of a
  // burst) read or lost on lane l; t_end gets one entry per burst once every
  // lane has passed it.
  typedef struct packed {
    logic [7:0] w;
    logic       tend;
  } vword_t;

  vword_t      vq [ML][$];
  int unsigned vlat [ML] = '{default: 0};
  int unsigned vtend [ML] = '{default: 0};
  int unsigned vtend_done = 0;
  bit          vhold = 1'b0;            // BurstRxRst = 1: FIFOs in reset (gate closed)
  realtime     t_reinit_end = -1.0;     // end of the last PHY re-init

  function automatic void v_tend_check();
    int unsigned m;
    m = vtend[0];
    for (int l = 1; l < int'(Lanes); l++) if (vtend[l] < m) m = vtend[l];
    while (vtend_done < m) begin
      t_end.push_back(csi2_now());
      vtend_done++;
    end
  endfunction

  // a burst end that no FIFO will deliver (no PHY, no strobe, FIFOs in reset)
  function automatic void v_tend_lost();
    for (int l = 0; l < int'(Lanes); l++) vtend[l]++;
    v_tend_check();
  endfunction

  // every FIFO emptied (reset, PHY re-init): the burst ends in them are lost
  function automatic void v_flush();
    for (int l = 0; l < int'(Lanes); l++) begin
      while (vq[l].size() != 0) begin
        if (vq[l][0].tend) vtend[l]++;
        void'(vq[l].pop_front());
      end
    end
    v_tend_check();
  endfunction

  // the FIFOs restart empty: FIFO_EMPTY latency, one for all lanes or per lane
  function automatic void v_restart();
    int unsigned lat;
    lat = $urandom_range(2);
    for (int l = 0; l < int'(ML); l++) vlat[l] = v_lat_lane ? $urandom_range(2) : lat;
  endfunction

  // one word into the FIFO of lane l: a 9th unread word laps the read
  // pointer, the reader jumps over the 8 oldest words
  function automatic void v_push(int l, vword_t v);
    if (vq[l].size() >= VDepth) begin
      for (int i = 0; i < int'(VDepth); i++) begin
        if (vq[l][0].tend) vtend[l]++;
        void'(vq[l].pop_front());
      end
      v_wraps[l]++;
    end
    vq[l].push_back(v);
    if (vq[l].size() > v_occ_max) v_occ_max = vq[l].size();
  endfunction

  // BurstRxRst: FIFOs held in reset while the byte clock gate is closed
  // (v_burst_rst = 1, a level: may change at any time); else a glitch word
  // in every FIFO when the gate opens
  function automatic void v_gate();
    bit     rst;
    vword_t v;
    rst = v_burst_rst && !byte_ce_i;
    if (rst && !vhold) begin
      vhold = 1'b1;
      v_flush();
    end else if (!rst && vhold) begin
      vhold = 1'b0;
      v_restart();
    end else if (!vhold && !ce_q && byte_ce_i && clk_hs_en_i && v_glitch_pct != 0 &&
                 $urandom_range(99) < v_glitch_pct) begin
      v_glitches++;
      for (int l = 0; l < int'(Lanes); l++) begin
        v.w    = 8'($urandom);
        v.tend = 1'b0;
        v_push(l, v);
      end
      v_tend_check();
    end
  endfunction

  // the strobe toggles: one word into every FIFO, unless the HS receiver of
  // the clock lane is off (no strobe) or the FIFOs are held in reset
  function automatic void v_write(step_t s);
    vword_t v;
    if (vhold || !clk_hs_en_i) begin
      if (s.tend) v_tend_lost();
      return;
    end
    for (int l = 0; l < int'(Lanes); l++) begin
      v.w    = hs_word(s, l, 1'b0);
      v.tend = s.tend;
      v_push(l, v);
    end
    v_tend_check();
  endfunction

  // byte clock edge: FIFO reads (FIFO_RDEN = ~FIFO_EMPTY); a gap only while
  // every FIFO is at its minimum (FIFO_EMPTY can only be seen late there)
  function automatic void v_read();
    bit     gap;
    vword_t v;
    gap = (v_gap_pm != 0) && ($urandom_range(999) < v_gap_pm);
    for (int l = 0; l < int'(Lanes); l++) begin
      if (vq[l].size() != vlat[l] + 1) gap = 1'b0;
    end
    if (gap) v_gaps++;
    for (int l = 0; l < int'(Lanes); l++) begin
      if (!gap && vq[l].size() > vlat[l]) begin
        v = vq[l].pop_front();
        rx_data_o[l]  = v.w;
        rx_valid_o[l] = 1'b1;
        if (v.tend) vtend[l]++;
      end else begin
        rx_data_o[l]  = 8'($urandom);
        rx_valid_o[l] = 1'b0;
      end
    end
    v_tend_check();
  endfunction

  initial begin : driver
    step_t s;
    bit    up, have;
    byte_clk_o = 1'b0;
    rx_data_o  = '0;
    rx_valid_o = '1;
    phy_rdy_o  = 1'b1;
    clk_lp_o   = lp00 ? 2'b00 : 2'b11;
    for (int l = 0; l < int'(Lanes); l++) lp_o[l] = clk_lp_o;
    pin_q = {(ML + 1){clk_lp_o}};
    forever begin
      // The size test goes into a variable first: Verilator 5.020 turns the
      // if / else into a conditional and, step_t being wider than 64 bits,
      // calls pop_front() before evaluating an inline size test.
      if (prog.size() == 0) next_item();
      have = (prog.size() != 0);
      if (have) s = prog.pop_front();
      else      s = idle_step();
      if (versal) begin
        // PHY_RDY: t_phy_rdy after time 0, t_reinit after the end of a re-init
        if (phy_reinit) t_reinit_end = csi2_now();
        up = !phy_reinit && csi2_now() >= real'(t_phy_rdy) &&
             (t_reinit_end < 0.0 || csi2_now() >= t_reinit_end + real'(t_reinit));
        if (up != phy_rdy_o) begin
          v_flush();
          vhold = 1'b0;
          if (up) v_restart();
        end
        phy_rdy_o = up;
      end
      apply(s);
      if (versal && phy_rdy_o) v_gate();
      if (versal && !phy_rdy_o && s.tend) v_tend_lost();  // no PHY: the burst is lost
      ce_q = byte_ce_i;
      if (s.clk == ClkToggle && (!versal || phy_rdy_o)) begin
        if (versal) v_write(s);
        if (byte_ce_i) begin
          byte_clk_o = 1'b1;
          #(byte_ns * 0.1);
          if (versal) v_read();
          else        rx_word(s);
          #(byte_ns * 0.4);
          byte_clk_o = 1'b0;
          #(byte_ns * 0.5);
        end else begin
          #(byte_ns);
        end
      end else if (runt && byte_ce_i && clk_hs_en_i && s.clk == ClkLp) begin
        runts++;
        if (versal) rx_valid_o = '0;
        byte_clk_o = 1'b1;
        #0.4;
        byte_clk_o = 1'b0;
        #(byte_ns - 0.4);
      end else begin
        #(byte_ns);
      end
    end
  end

endmodule
