// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Pin level test of the KV260 D-PHY receive I/O (Vivado simulator with the
// UltraScale+ unisim models, `make -C hw/fpga/common/dv test`):
//
//   bit-serial D-PHY transmitter -> pads -> bow_dphy_io_xusp -> bow_csi2rx -> m_axis
//                                           (IBUFDS_DPHY, IDELAYE3,
//                                            ISERDESE3, BUFGCE_DIV)
//
// Transmitter: 2 data lanes at 912 Mbit/s (UI 1.096 ns) with the HS clock
// centre aligned (DDR), non-continuous clock lane, one CSI-2 packet per HS
// burst: clock LP-11 -> LP-01 -> LP-00 -> HS-0 (CLK-ZERO) -> clock (CLK-PRE),
// data LP-01 -> LP-00 (HS-PREPARE, random receiver output in its second
// half) -> HS-ZERO -> sync byte -> packet -> HS-TRAIL -> LP-11, then
// CLK-POST, CLK-TRAIL (HS-0), LP-11. HS-ZERO has a random number of bits per
// burst (random bit phase of the sync byte) and a small random skew between
// the lanes. LP levels are driven strong and HS levels with pull strength:
// the IBUFDS_DPHY model treats a lane as LP only when both lines are strong
// (its LP receivers then read LP-00 during HS, as on the device).
//
// Checks:
//  * PHY: in every byte clock burst the ISERDESE3 words (Q[0] = first bit)
//    hold, at some bit offset, HS-zero + sync byte + exactly the bytes sent on
//    that lane; the byte clock (/4) and the HS clock (/1) have no runt pulses
//    and every byte clock edge comes with an HS clock edge, 4 HS cycles
//    apart, also across the gaps (CE freezes both dividers); BUFGCE_DIV CE
//    changes only while the clock lane is static in HS-0; the ISERDES RST is
//    high whenever the gate opens and is released once per burst while the
//    clock runs, at least 20 byte clocks before the sync byte; a DLY write
//    reaches IDELAYE3 CNTVALUEOUT at the next burst and reads back.
//  * receiver: RAW10 pixels on m_axis with tuser/tlast (random tready), ID,
//    INFO, PHY_CFG, STATUS, counters, FRAME_INFO, LINE_INFO, FRAME_SUM,
//    ERR_STATUS after each frame, raw capture (RAW_CTRL ARM) of a burst.
// The test prints "tb_bow_dphy_io_xusp: PASS" or "... FAIL (<n> errors)".

`timescale 1ps / 1ps

module tb_bow_dphy_io_xusp;
  import bow_bus_pkg::*;

  localparam int unsigned Lanes  = 2;
  localparam int unsigned Width  = 36;           // pixels per line (WC 45: odd packet length)
  localparam int unsigned Height = 4;
  localparam int unsigned Wc     = Width * 5 / 4;

  localparam time UI          = 1096;            // 912 Mbit/s
  localparam time TLpx        = 60_000;
  localparam time THsPrepare  = 60_000;
  localparam time THsZero     = 150_000;         // + 0..63 random bits
  localparam time THsTrail    = 70_000;
  localparam time TClkPrepare = 60_000;
  localparam time TClkZero    = 300_000;
  localparam time TClkPre     = 20_000;
  localparam time TClkPost    = 120_000;
  localparam time TClkTrail   = 70_000;
  localparam time TLp11       = 120_000;         // LP-11 between two bursts

  localparam logic [31:0] Base = 32'h4000_8000;

  // ---------------------------------------------------------------- clocks
  logic clk = 1'b0, vclk = 1'b0, rst_n = 1'b0, vrst_n = 1'b0;
  always #10_000 clk = ~clk;                     // 50 MHz CPU clock
  always #2_500 vclk = ~vclk;                    // 200 MHz video clock

  int unsigned errors = 0;

  // PHY <-> receiver
  logic                  byte_clk, byte_ce, byte_rst, clk_hs_en;
  logic [1:0]            clk_lp;
  logic [Lanes-1:0][1:0] lp;
  logic [Lanes-1:0]      hs_en, dly_load;
  logic [Lanes-1:0][7:0] rx_data;
  logic [Lanes-1:0][8:0] dly_tap, dly_tap_out;

  function automatic void err(input string msg);
    errors++;
    $display("%t ERROR: %s", $time, msg);
  endfunction

  // ------------------------------------------------------- D-PHY transmitter
  // Index Lanes is the clock lane. The pull driver always drives the HS level,
  // the strong driver overrides it in LP mode (no undriven state between).
  wire             clk_p, clk_n;
  wire [Lanes-1:0] data_p, data_n;

  // HS-0 during the first 10 ns: the HS output of the IBUFDS_DPHY model is X
  // until it has seen a differential level.
  logic [Lanes:0]      tx_lp_mode = '0;          // 1: LP drivers
  logic [Lanes:0][1:0] tx_lp      = '1;          // {P, N}
  logic [Lanes:0]      tx_hs      = '0;

  assign (pull0, pull1)     clk_p = tx_hs[Lanes];
  assign (pull0, pull1)     clk_n = ~tx_hs[Lanes];
  assign (strong0, strong1) clk_p = tx_lp_mode[Lanes] ? tx_lp[Lanes][1] : 1'bz;
  assign (strong0, strong1) clk_n = tx_lp_mode[Lanes] ? tx_lp[Lanes][0] : 1'bz;
  for (genvar l = 0; l < Lanes; l++) begin : g_pad
    assign (pull0, pull1)     data_p[l] = tx_hs[l];
    assign (pull0, pull1)     data_n[l] = ~tx_hs[l];
    assign (strong0, strong1) data_p[l] = tx_lp_mode[l] ? tx_lp[l][1] : 1'bz;
    assign (strong0, strong1) data_n[l] = tx_lp_mode[l] ? tx_lp[l][0] : 1'bz;
  end

  // HS clock: toggles every UI while clk_run is set and stops in HS-0. The
  // data lanes change on data_tick, half a UI before each clock edge.
  bit   clk_run = 1'b0, clk_busy = 1'b0;
  event data_tick;

  initial forever begin
    wait (clk_run);
    clk_busy = 1'b1;
    while (clk_run || tx_hs[Lanes]) begin
      #(UI / 2) -> data_tick;
      #(UI / 2) tx_hs[Lanes] = ~tx_hs[Lanes];
    end
    clk_busy = 1'b0;
  end

  // Bytes of every burst per lane, for the PHY monitor
  typedef struct {
    int unsigned  n [Lanes];
    byte unsigned b [Lanes][128];
  } burst_t;

  burst_t      exp_burst [$];
  int unsigned n_bursts = 0;
  bit          sync_sent = 1'b0;                 // a lane has started its sync byte in this burst
  time         rst_rel_time = 0;

  task automatic hs_bit(input int unsigned l, input bit v);
    @(data_tick);
    tx_hs[l]      = v;
    tx_lp_mode[l] = 1'b0;
  endtask

  task automatic lane_burst(input int unsigned l, input burst_t e, input int unsigned zero_bits);
    bit last;
    tx_lp[l] = 2'b01;                            // HS request
    #(TLpx);
    tx_lp[l] = 2'b00;                            // HS-PREPARE
    #(THsPrepare / 2);
    repeat (THsPrepare / 2 / UI) hs_bit(l, 1'($urandom));
    repeat (zero_bits) hs_bit(l, 1'b0);          // HS-ZERO
    @(data_tick);
    if (!sync_sent) begin
      sync_sent = 1'b1;
      if (byte_rst !== 1'b0) begin
        err("sync byte sent while the ISERDESE3 is in reset");
      end else if ($time - rst_rel_time < 20 * 8 * UI) begin
        err($sformatf("ISERDESE3 RST released only %0d ps before the sync byte",
                      $time - rst_rel_time));
      end
    end
    tx_hs[l] = 1'b0;                             // first sync bit (0xB8, LSB first)
    for (int i = 1; i < 8; i++) hs_bit(l, 1'((8'hB8 >> i) & 1));
    for (int k = 0; k < e.n[l]; k++) begin
      for (int i = 0; i < 8; i++) hs_bit(l, 1'((e.b[l][k] >> i) & 1));
    end
    last = tx_hs[l];
    repeat (THsTrail / UI) hs_bit(l, ~last);     // HS-TRAIL
    @(data_tick);
    #(UI / 2);
    tx_lp[l]      = 2'b11;
    tx_lp_mode[l] = 1'b1;
  endtask

  // One packet in one HS burst. Byte i goes to lane i % Lanes.
  task automatic send_packet(input byte unsigned pkt[$]);
    burst_t      e;
    int unsigned zero, done;
    for (int l = 0; l < Lanes; l++) e.n[l] = 0;
    foreach (pkt[i]) begin
      e.b[i % Lanes][e.n[i % Lanes]] = pkt[i];
      e.n[i % Lanes]++;
    end
    exp_burst.push_back(e);
    n_bursts++;
    sync_sent = 1'b0;
    zero = THsZero / UI + $urandom_range(0, 63);

    tx_lp[Lanes] = 2'b01;                        // clock lane: HS request
    #(TLpx);
    tx_lp[Lanes] = 2'b00;
    #(TClkPrepare);
    tx_hs[Lanes]      = 1'b0;                    // CLK-ZERO
    tx_lp_mode[Lanes] = 1'b0;
    #(TClkZero);
    clk_run = 1'b1;
    #(TClkPre);
    done = 0;
    for (int l = 0; l < Lanes; l++) begin
      automatic int unsigned ll = l;
      automatic int unsigned zz = zero + $urandom_range(0, 15);
      fork
        begin
          lane_burst(ll, e, zz);
          done++;
        end
      join_none
    end
    wait (done == Lanes);
    #(TClkPost);
    clk_run = 1'b0;
    wait (!clk_busy);                            // stopped in HS-0
    #(TClkTrail);
    tx_lp[Lanes]      = 2'b11;
    tx_lp_mode[Lanes] = 1'b1;
    #(TLp11);
  endtask

  // ------------------------------------------------------ CSI-2 packets
  localparam logic [5:0] EccCol [24] = '{
    6'h07, 6'h0B, 6'h0D, 6'h0E, 6'h13, 6'h15, 6'h16, 6'h19, 6'h1A, 6'h1C, 6'h23, 6'h25,
    6'h26, 6'h29, 6'h2A, 6'h2C, 6'h31, 6'h32, 6'h34, 6'h38, 6'h1F, 6'h2F, 6'h37, 6'h3B
  };

  function automatic byte unsigned ecc(input logic [7:0] di, input logic [15:0] wc);
    logic [23:0] d;
    logic [5:0]  e;
    d = {wc, di};
    e = '0;
    for (int i = 0; i < 24; i++) if (d[i]) e ^= EccCol[i];
    return {2'b00, e};
  endfunction

  function automatic logic [15:0] crc16(input byte unsigned p[$]);
    logic [15:0] c;
    c = 16'hFFFF;
    foreach (p[i]) begin
      c ^= {8'h00, p[i]};
      for (int k = 0; k < 8; k++) c = c[0] ? ((c >> 1) ^ 16'h8408) : (c >> 1);
    end
    return c;
  endfunction

  function automatic void short_pkt(input logic [7:0] di, input logic [15:0] wc,
                                    ref byte unsigned pkt[$]);
    pkt = {di, wc[7:0], wc[15:8], ecc(di, wc)};
  endfunction

  function automatic void long_pkt(input logic [7:0] di, input byte unsigned pl[$],
                                   ref byte unsigned pkt[$]);
    logic [15:0] wc, crc;
    wc  = 16'(pl.size());
    crc = crc16(pl);
    pkt = {di, wc[7:0], wc[15:8], ecc(di, wc)};
    foreach (pl[i]) pkt.push_back(pl[i]);
    pkt.push_back(crc[7:0]);
    pkt.push_back(crc[15:8]);
  endfunction

  // ------------------------------------------------------------- the DUT
  bow_dphy_io_xusp #(
    .Lanes (Lanes)
  ) u_phy (
    .clk_p       (clk_p),
    .clk_n       (clk_n),
    .data_p      (data_p),
    .data_n      (data_n),
    .byte_clk_o  (byte_clk),
    .byte_ce_i   (byte_ce),
    .byte_rst_i  (byte_rst),
    .clk_lp_o    (clk_lp),
    .clk_hs_en_i (clk_hs_en),
    .lp_o        (lp),
    .hs_en_i     (hs_en),
    .rx_data_o   (rx_data),
    .dly_tap_i   (dly_tap),
    .dly_load_i  (dly_load),
    .dly_tap_o   (dly_tap_out)
  );

  bus_req_t   bus_req = BUS_REQ_DEFAULT;
  bus_rsp_t   bus_rsp;
  logic       irq;
  logic       m_tvalid, m_tready = 1'b0, m_tuser, m_tlast;
  logic [9:0] m_tdata;

  bow_csi2rx #(
    .Lanes    (Lanes),
    .PhyClkHz (200_000_000),
    .HasPhy   (1'b1)
  ) u_rx (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .bus_req_i       (bus_req),
    .bus_rsp_o       (bus_rsp),
    .irq_o           (irq),
    .vid_clk_i       (vclk),
    .vid_rst_ni      (vrst_n),
    .m_axis_tvalid_o (m_tvalid),
    .m_axis_tready_i (m_tready),
    .m_axis_tdata_o  (m_tdata),
    .m_axis_tuser_o  (m_tuser),
    .m_axis_tlast_o  (m_tlast),
    .byte_clk_i      (byte_clk),
    .byte_ce_o       (byte_ce),
    .byte_rst_o      (byte_rst),
    .clk_lp_i        (clk_lp),
    .clk_hs_en_o     (clk_hs_en),
    .lp_i            (lp),
    .hs_en_o         (hs_en),
    .rx_data_i       (rx_data),
    .dly_tap_o       (dly_tap),
    .dly_load_o      (dly_load),
    .dly_tap_i       (dly_tap_out)
  );

  // ---------------------------------------------------------------- bus BFM
  task automatic bus_xfer(input bit we, input logic [11:0] off, input logic [31:0] wdata,
                          output logic [31:0] rdata);
    @(posedge clk);
    #1;
    bus_req.req   = 1'b1;
    bus_req.we    = we;
    bus_req.be    = 4'hF;
    bus_req.addr  = Base + 32'(off);
    bus_req.wdata = wdata;
    do @(posedge clk); while (!bus_rsp.gnt);
    #1;
    bus_req = BUS_REQ_DEFAULT;
    while (!bus_rsp.rvalid) @(posedge clk);
    rdata = bus_rsp.rdata;
  endtask

  task automatic reg_wr(input logic [11:0] off, input logic [31:0] d);
    logic [31:0] unused;
    bus_xfer(1'b1, off, d, unused);
  endtask

  task automatic reg_rd(input logic [11:0] off, output logic [31:0] d);
    bus_xfer(1'b0, off, '0, d);
  endtask

  task automatic reg_check(input string name, input logic [11:0] off, input logic [31:0] exp,
                           input logic [31:0] mask = '1);
    logic [31:0] d;
    reg_rd(off, d);
    if ((d & mask) !== (exp & mask)) begin
      err($sformatf("%s (0x%03h) = 0x%08h, expected 0x%08h (mask 0x%08h)",
                    name, off, d, exp, mask));
    end
  endtask

  // ---------------------------------------------------------- pixel monitor
  typedef struct packed {
    logic [9:0] data;
    logic       user;
    logic       last;
  } px_t;

  px_t         exp_px [$];
  int unsigned n_px = 0;

  always @(posedge vclk) m_tready <= ($urandom_range(0, 3) != 0);

  always @(posedge vclk) begin
    if (m_tvalid && m_tready) begin
      if (exp_px.size() == 0) begin
        err($sformatf("unexpected pixel 0x%03h user %0d last %0d", m_tdata, m_tuser, m_tlast));
      end else begin
        px_t e;
        e = exp_px.pop_front();
        if (m_tdata !== e.data || m_tuser !== e.user || m_tlast !== e.last) begin
          err($sformatf("pixel %0d: 0x%03h user %0d last %0d, expected 0x%03h user %0d last %0d",
                        n_px, m_tdata, m_tuser, m_tlast, e.data, e.user, e.last));
        end
      end
      n_px++;
    end
  end

  task automatic wait_pixels(input time tmo);
    time t0;
    t0 = $time;
    while (exp_px.size() != 0 && $time - t0 < tmo) @(posedge vclk);
    if (exp_px.size() != 0) begin
      err($sformatf("%0d pixels missing on m_axis", exp_px.size()));
      exp_px.delete();
    end
  endtask

  // ------------------------------------------------------------ PHY monitor
  // ISERDES words of the current byte clock burst; checked when the gate
  // closes (the receiver asserts the ISERDES RST again).
  logic [7:0]  mon_w [Lanes][512];
  int unsigned mon_n = 0;
  int unsigned offs_seen [Lanes];                // bit masks of the sync offsets (mod 8)

  always @(posedge byte_clk) begin
    if (byte_rst === 1'b0 && mon_n < 512) begin
      for (int l = 0; l < Lanes; l++) mon_w[l][mon_n] = rx_data[l];
      mon_n++;
    end
  end

  // Bit position after the sync byte, preceded by at least zmin zero bits, in
  // the bit stream of n words (bit i = word i / 8, Q[i % 8]); -1: not found.
  function automatic int find_sync(input logic [7:0] w [512], input int unsigned n,
                                   input int unsigned zmin);
    int unsigned zrun;
    zrun = 0;
    for (int i = 0; i + 8 <= 8 * n; i++) begin
      bit hit;
      hit = (zrun >= zmin);
      for (int k = 0; k < 8 && hit; k++) begin
        hit = (w[(i + k) / 8][(i + k) % 8] === 1'((8'hB8 >> k) & 1));
      end
      if (hit) return i + 8;
      zrun = (w[i / 8][i % 8] === 1'b0) ? zrun + 1 : 0;
    end
    return -1;
  endfunction

  // Compare the bytes after the sync with the sent ones (all: every byte must
  // have been captured). The sync search skips the HS-PREPARE garbage: the
  // words of a whole burst need a full HS-ZERO before the sync, a raw capture
  // starts after the settle time. Returns the number of matching bytes.
  function automatic int unsigned check_bytes(input string what, input logic [7:0] w [512],
                                              input int unsigned n, input int unsigned l,
                                              input burst_t e, input bit all);
    int pos;
    pos = find_sync(w, n, all ? 128 : 32);
    if (pos < 0) begin
      err($sformatf("%s lane %0d: no HS-zero + sync byte in %0d words", what, l, n));
      return 0;
    end
    offs_seen[l] |= 1 << ((pos - 8) % 8);
    for (int k = 0; k < e.n[l]; k++) begin
      logic [7:0] v;
      if (pos + 8 * k + 8 > 8 * n) begin
        if (all) err($sformatf("%s lane %0d: only %0d of %0d bytes", what, l, k, e.n[l]));
        return k;
      end
      for (int i = 0; i < 8; i++) v[i] = w[(pos + 8 * k + i) / 8][(pos + 8 * k + i) % 8];
      if (v !== e.b[l][k]) begin
        err($sformatf("%s lane %0d byte %0d: 0x%02h, sent 0x%02h", what, l, k, v, e.b[l][k]));
        return k;
      end
    end
    return e.n[l];
  endfunction

  task automatic check_phy_burst();
    burst_t e;
    if (exp_burst.size() == 0) begin
      err("byte clock burst without a transmitted packet");
      return;
    end
    e = exp_burst.pop_front();
    for (int l = 0; l < Lanes; l++) void'(check_bytes("ISERDES", mon_w[l], mon_n, l, e, 1'b1));
  endtask

  always @(posedge byte_rst) begin
    if (mon_n > 0) begin
      check_phy_burst();
      mon_n = 0;
    end
  end

  // Clock gate, dividers and ISERDES reset
  time         last_clk_edge = 0, hs_r = 0, hs_f = 0, bc_r = 0, bc_f = 0;
  time         close_min = 0, close_max = 0;     // gate close after the last HS clock edge
  int unsigned hs_cnt = 0, n_byte_clk = 0, n_ce_open = 0, n_rst_rel = 0;

  always @(u_phy.clk_hs) last_clk_edge = $time;

  always @(posedge u_phy.hs_clk) begin
    if (hs_f > 0 && $time - hs_f < UI - 2) err($sformatf("HS clock low for %0d ps", $time - hs_f));
    hs_r = $time;
    hs_cnt++;
  end

  always @(negedge u_phy.hs_clk) begin
    if (hs_r > 0) begin
      if ($time - hs_r < UI - 2) err($sformatf("HS clock high for %0d ps", $time - hs_r));
      hs_f = $time;
    end
  end

  always @(posedge byte_clk) begin
    if (bc_f > 0 && $time - bc_f < 4 * UI - 2) begin
      err($sformatf("byte clock low for %0d ps", $time - bc_f));
    end
    if (tx_lp_mode[Lanes]) err("byte clock edge while the clock lane is in LP");
    bc_r = $time;
    n_byte_clk++;
    #1;
    if (hs_r != $time - 1) err("byte clock edge without an HS clock edge");
    if (n_byte_clk > 1 && hs_cnt != 4) begin
      err($sformatf("%0d HS clock cycles in one byte clock cycle", hs_cnt));
    end
    hs_cnt = 0;
  end

  always @(negedge byte_clk) begin
    if (bc_r > 0) begin
      if ($time - bc_r < 4 * UI - 2) err($sformatf("byte clock high for %0d ps", $time - bc_r));
      bc_f = $time;
    end
  end

  always @(posedge byte_ce) begin
    n_ce_open++;
    if (byte_rst !== 1'b1) err("clock gate opened while the ISERDESE3 is out of reset");
    if (tx_lp_mode[Lanes] || clk_busy || $time - last_clk_edge < 10_000) begin
      err("clock gate opened while the clock lane was not static in HS-0");
    end
  end

  always @(negedge byte_ce) begin
    if (n_ce_open > 0) begin
      if (tx_lp_mode[Lanes] || clk_busy || $time - last_clk_edge < 10_000) begin
        err("clock gate closed while the clock lane was not static in HS-0");
      end
      if (close_min == 0 || $time - last_clk_edge < close_min) close_min = $time - last_clk_edge;
      if ($time - last_clk_edge > close_max) close_max = $time - last_clk_edge;
    end
  end

  always @(negedge byte_rst) begin
    if ($time > 0) begin
      n_rst_rel++;
      rst_rel_time = $time;
      if (!clk_busy) err("ISERDESE3 RST released while the HS clock is stopped");
      if (sync_sent) err("ISERDESE3 RST released after the sync byte of the burst");
      if (n_rst_rel != n_bursts) begin
        err($sformatf("ISERDESE3 RST release %0d in burst %0d", n_rst_rel, n_bursts));
      end
    end
  end

  // ------------------------------------------------------------- frames
  int unsigned frame_sum;

  task automatic send_frame(input logic [15:0] fnum);
    byte unsigned pkt[$], pl[$];
    logic [9:0]   px [Width];
    frame_sum = 0;
    short_pkt(8'h00, fnum, pkt);                 // FS
    send_packet(pkt);
    pl.delete();
    for (int i = 0; i < Width; i++) pl.push_back(8'($urandom));
    long_pkt(8'h12, pl, pkt);                    // embedded data: dropped by the DT filter
    send_packet(pkt);
    for (int y = 0; y < Height; y++) begin
      pl.delete();
      for (int x = 0; x < Width; x++) begin
        px[x] = 10'($urandom);
        frame_sum += px[x];
        exp_px.push_back('{data: px[x], user: (x == 0 && y == 0), last: (x == Width - 1)});
      end
      for (int x = 0; x < Width; x += 4) begin
        for (int i = 0; i < 4; i++) pl.push_back(px[x + i][9:2]);
        pl.push_back({px[x + 3][1:0], px[x + 2][1:0], px[x + 1][1:0], px[x][1:0]});
      end
      long_pkt(8'h2B, pl, pkt);                  // RAW10 line
      send_packet(pkt);
    end
    short_pkt(8'h01, fnum, pkt);                 // FE
    send_packet(pkt);
    wait_pixels(20_000_000);
  endtask

  task automatic check_frame(input logic [15:0] fnum);
    int unsigned pkts;
    pkts = Height + 3;                           // FS, embedded data, lines, FE
    reg_check("CNT_FRAME",  12'h024, 1);
    reg_check("CNT_PKT",    12'h028, pkts);
    reg_check("CNT_LINE",   12'h02C, Height);
    reg_check("CNT_ECC",    12'h030, 0);
    reg_check("CNT_CRC",    12'h034, 0);
    reg_check("CNT_SOT",    12'h038, 0);
    reg_check("CNT_DROP",   12'h03C, 1);
    reg_check("CNT_BURST",  12'h040, {16'(pkts), 16'(pkts)});
    reg_check("CNT_MISC",   12'h044, pkts);
    reg_check("ERR_STATUS", 12'h01C, 0);
    reg_check("FRAME_INFO", 12'h050, {fnum, 16'(Height)});
    reg_check("LINE_INFO",  12'h054, {8'h00, 2'b00, 6'h2B, 16'(Wc)}, 32'h00FF_FFFF);
    reg_check("FRAME_SUM",  12'h058, frame_sum);
    // all lanes LP-11, no HS receiver on, gate closed, not in a frame
    reg_check("STATUS",     12'h010, 32'h0000_003F, 32'h0000_1FFF);
  endtask

  // ------------------------------------------------------------- the test
  initial begin
    logic [31:0] d;
    byte unsigned pkt[$], pl[$];

    #10_000;
    tx_lp_mode = '1;                             // LP-11 on all lanes
    // CSI-2 reference values (spec section 5.4)
    if (ecc(8'h2B, 16'h0960) != 8'h1D || ecc(8'h00, 16'h0001) != 8'h1A ||
        ecc(8'h37, 16'h01F0) != 8'h3F) begin
      err("ECC reference values");
    end
    pl = {8'hFF, 8'h00, 8'h00, 8'h02, 8'hB9, 8'hDC, 8'hF3, 8'h72, 8'hBB, 8'hD4, 8'hB8, 8'h5A,
          8'hC8, 8'h75, 8'hC2, 8'h7C, 8'h81, 8'hF8, 8'h05, 8'hDF, 8'hFF, 8'h00, 8'h00, 8'h01};
    if (crc16(pl) != 16'h00F0) err("CRC reference value");

    #200_000;
    rst_n  = 1'b1;
    vrst_n = 1'b1;
    repeat (10) @(posedge clk);

    reg_check("ID",      12'h000, 32'h4353_3201);
    reg_check("INFO",    12'h004, {16'd256, 8'd200, 3'd0, 1'b1, 4'(Lanes)});
    reg_check("PHY_CFG", 12'h00C, 32'h081E_020E);
    reg_wr(12'h008, {18'd0, 6'h2B, 5'd0, 1'b1, 1'b1, 1'b1});     // DT 0x2B, 2 lanes, RX_EN, PHY_EN
    #1_000_000;
    reg_check("STATUS idle", 12'h010, 32'h0000_003F, 32'h0000_1FFF);
    if (n_byte_clk != 0) err("byte clock running before the first burst");

    $display("%t frame 1", $time);
    send_frame(16'd1);
    check_frame(16'd1);

    // IDELAY taps: loaded at the next burst (lane 1: more than one UI)
    reg_wr(12'h070, 32'd37);
    reg_wr(12'h074, 32'd300);
    reg_check("DLY0 before burst", 12'h070, 32'd37, 32'h01FF_01FF);
    reg_check("DLY1 before burst", 12'h074, 32'd300, 32'h01FF_01FF);
    reg_wr(12'h020, 32'h1);                      // CNT_CLR
    $display("%t frame 2 (taps 37/300)", $time);
    send_frame(16'd2);
    check_frame(16'd2);
    reg_check("DLY0", 12'h070, {7'd0, 9'd37, 7'd0, 9'd37});
    reg_check("DLY1", 12'h074, {7'd0, 9'd300, 7'd0, 9'd300});
    if (u_phy.g_lane[0].u_idelay.CNTVALUEOUT !== 9'd37 ||
        u_phy.g_lane[1].u_idelay.CNTVALUEOUT !== 9'd300) begin
      err("IDELAYE3 CNTVALUEOUT");
    end

    // Raw capture of the next burst (armed with a stopped byte clock). The
    // 64 words from the rise of lane 0 hs_active and the acknowledge need
    // byte clocks: the packet keeps the clock running well beyond them.
    $display("%t raw capture", $time);
    reg_wr(12'h084, 32'h1);
    reg_check("RAW_CTRL armed", 12'h084, 32'h1, 32'h101);
    pl.delete();
    for (int i = 0; i < 120; i++) pl.push_back(8'($urandom));
    long_pkt(8'h12, pl, pkt);
    send_packet(pkt);
    begin
      burst_t     e;
      logic [7:0] raw [Lanes][512];
      for (int l = 0; l < Lanes; l++) e.n[l] = 0;
      foreach (pkt[i]) begin
        e.b[i % Lanes][e.n[i % Lanes]] = pkt[i];
        e.n[i % Lanes]++;
      end
      d = '0;
      for (int t = 0; t < 100 && !d[8]; t++) reg_rd(12'h084, d);
      if (!d[8]) err("RAW_CTRL: no DONE");
      for (int w = 0; w < 64; w++) begin
        reg_rd(12'h800 + 12'(4 * w), d);
        for (int l = 0; l < Lanes; l++) raw[l][w] = d[8 * l +: 8];
      end
      for (int l = 0; l < Lanes; l++) begin
        int unsigned k;
        k = check_bytes("RAW", raw[l], 64, l, e, 1'b0);
        if (k < 32) err($sformatf("RAW lane %0d: only %0d bytes of the packet captured", l, k));
        $display("%t raw capture lane %0d: %0d bytes after the sync byte match", $time, l, k);
      end
    end

    // End of test
    #1_000_000;
    if (exp_burst.size() != 0) begin
      err($sformatf("%0d bursts not seen by the PHY monitor", exp_burst.size()));
    end
    if (n_ce_open != n_bursts) begin
      err($sformatf("clock gate opened %0d times for %0d bursts", n_ce_open, n_bursts));
    end
    if (n_rst_rel != n_bursts) begin
      err($sformatf("ISERDESE3 RST released %0d times for %0d bursts", n_rst_rel, n_bursts));
    end
    for (int l = 0; l < Lanes; l++) begin            // random bit phase: most offsets seen
      if ($countones(offs_seen[l]) < 4) begin
        err($sformatf("lane %0d: sync bit offsets 0x%02h", l, offs_seen[l]));
      end
    end
    $display("%t %0d bursts, %0d byte clocks, %0d pixels, sync offsets lane0 0x%02h lane1 0x%02h",
             $time, n_bursts, n_byte_clk, n_px, offs_seen[0], offs_seen[1]);
    $display("%t clock gate closed %0d..%0d ps after the HS clock stopped (CLK-TRAIL %0d ps)",
             $time, close_min, close_max, TClkTrail);
    if (errors == 0) $display("tb_bow_dphy_io_xusp: PASS");
    else             $display("tb_bow_dphy_io_xusp: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #(64'd5_000_000_000);                       // 5 ms
    $display("tb_bow_dphy_io_xusp: FAIL (timeout)");
    $finish;
  end

endmodule
