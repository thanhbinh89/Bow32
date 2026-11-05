// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 DDR2/DDR3 PHY, technology independent part: command / write / read
// window timing towards the pad wrapper (bow_ddr_io_xilinx, bow_ddr_io_sim)
// and the read stream back from it. ddr_clk domain, except the write side of
// the read FIFO (rd_clk). Bytes <-> beats is done only here.
//
// "PHY cycle j" = the ddr_clk cycle in which io_o carries a value (io_o is a
// register). A command taken from bow_ddr_dfi (the DFI adapter of the
// LiteDRAM controller) in cycle n-1 (cmd_v_i) is in io_o in PHY cycle n and
// latched by the DRAM at CK edge m = n + 2 (bow_ddr_pkg header). Every time
// below is relative to n.
//
// Command pins: cmd_pins(code), ba (BankPins), a (AddrPins); no command ->
//   deselect (cs_n = ras_n = cas_n = we_n = 1, ba / a keep their value).
//   ck_en, cke, odt, rst_n (only with HasResetN, else 0), ls_oe_n = !ls_en
//   come from cfg_i (cke / odt / rst_n: the DFI values, set by bow_ddr_dfi).
// Write (WR at n, WL = cfg_i.wl):
//   n+WL      preamble: dqs = (0,0), dqs_oe = dq_oe = 1; DDR2 with
//             IDLE_DRIVE = 0 also n+WL-1 (2 tCK preamble, tWPRES = 0)
//   n+WL+1+i  data cycle i = 0..3: dqs = (1,0) (rising edge on CK edge
//             m+WL+i), dq[0] = beat 2i, dq[1] = beat 2i+1, dm = !be of the
//             beat's bytes when HasDm and DM_EN (else 0)
//   n+WL+5    postamble: dqs = (0,0), oe = 1 (a following back-to-back
//             burst replaces it by its data: DQS keeps toggling)
//   beat k = bytes k*Lanes .. k*Lanes+Lanes-1 (x8: byte k; x16: {2k+1, 2k}).
//   The burst bytes wait in a 4 deep FIFO (pushed with the WR, popped in the
//   cycle before the first data cycle): needs WL + 1 <= 4 * tCCD (LiteDRAM:
//   at most one RD / WR per controller cycle, tCCD >= 4).
//   Idle (no write, no read window): IDLE_DRIVE = 1 -> dq_oe = dqs_oe = 1,
//   dq = 0, dqs = (0,0), dm = 0; IDLE_DRIVE = 0 -> dq_oe = dqs_oe = 0.
// Read window, level shifters (RD at n; LEAD/TAIL/PRE/POST = RDIR_LEAD,
//   RDIR_TAIL, OE_PRE, OE_POST):
//   dir_on  = n + max(0, RL - LEAD)          first cycle ls_dir_dq/dqs = 1
//   oe_off  = n + max(0, RL - LEAD - PRE)    first cycle dq_oe = dqs_oe = 0
//   dir_off = n + RL + 6 + TAIL              first cycle ls_dir = 0 again
//   oe_on   = dir_off + POST                 first cycle the FPGA may drive
//   Windows of several reads merge (union, the later read ends later). A read
//   OE-off window wins over a write: oe stays 0 (no contention with the
//   shifters). Simulation flags RL < LEAD + PRE and any overlap of a write
//   drive window (n+WL .. n+WL+5) with a read OE-off window (the controller's
//   READ -> WRITE / WRITE -> READ distance too short for these LAT values,
//   see docs).
// Read stream: io_i is registered once on rd_clk and pushed every rd_clk
//   cycle into bow_fifo_async (Depth 16, {dqs fall, dqs rise, dq fall,
//   dq rise}); the ddr side pops every cycle from the 5th cycle after
//   empty_o is first seen low. The popped head is registered into st_q[0]
//   and shifted through st_q[1..4]: "stream cycle s" = the cycle in which
//   that entry is in st_q[0] (r_s / f_s = its rise / fall DQ sample).
//   A pop while empty or a push while full: rfifo_err_o (one pulse) and
//   rfifo_broken_o until rfifo_sync_i. rfifo_sync_i: flush for 8 cycles,
//   ORed into the reset of both FIFO sides (asserted together, released by
//   one bow_rst_sync per clock), then the start rule again. The stream keeps
//   running while broken, so read bursts still return (garbage).
// Read data: RD at n -> stream cycles c0 = n + RL + 2 + RD_DLY .. c0+3,
//   beats r_c0, f_c0, r_c0+1, .. f_c0+3 (RD_SLIP = 1: f_c0, r_c0+1, ..
//   r_c0+4). rd_v_o / rd_bytes_o one cycle after the last stream cycle used,
//   in order (one pulse per RD).
// Raw capture (cap_i with a RD): stream cycles n+RL-2 .. n+RL+29 into
//   cap_dq_o / cap_dqs_o [0..31]; cap_done_o pulses when the 32nd is in.
//   cap_dq_o[i]  = {fall, rise} of DqBits each, zero extended (= the CAP
//   register: x8 [7:0] rise [15:8] fall, x16 [15:0] rise [31:16] fall);
//   cap_dqs_o[i] = {lane 1 {fall, rise}, lane 0 {fall, rise}}. Quasi-static
//   outside a capture.
// idle_o: no command token, write burst, read window, read burst or capture
//   in progress (the FIFO is not part of it: APPLY never touches the FIFO).

module bow_ddr_phy import bow_ddr_pkg::*; #(
  parameter int unsigned DqBits = 8, Lanes = DqBits / 8, AddrPins = 14, BankPins = 2,
  parameter bit HasDm = 1'b0, HasResetN = 1'b0
) (
  input  logic clk_i, rst_ni,            // ddr_clk, lnk_ddr_n
  input  logic rd_clk_i, rd_rst_ni,      // rd_clk, lnk_rd_n
  input  cfg_t cfg_i,
  // DFI-lite from bow_ddr_dfi
  input  logic cmd_v_i, input cmd_e cmd_code_i, input logic [2:0] cmd_ba_i,
  input  logic [15:0] cmd_a_i, input burst_t wr_bytes_i, input be_t wr_be_i, input logic cap_i,
  output logic rd_v_o, output burst_t rd_bytes_o, output logic cap_done_o, output logic idle_o,
  // read FIFO control / status (bow_ddr_dfi command executor)
  input  logic rfifo_sync_i,             // 1-cycle pulse: flush + restart (4.6)
  output logic rfifo_err_o,              // 1-cycle pulse
  output logic rfifo_broken_o,           // level
  // raw capture buffer (quasi-static after cap_done)
  output logic [31:0][2*MaxDq-1:0]   cap_dq_o,   // [i] = {fall, rise} of stream cycle i
  output logic [31:0][2*MaxLanes-1:0] cap_dqs_o,
  // pads
  output ddr_io_out_t io_o,
  input  ddr_io_in_t  io_i                // rd_clk domain
);

  localparam int unsigned FifoW = 2 * DqBits + 2 * Lanes;   // one stream cycle
  localparam int unsigned RdSr  = 101;   // RD token: up to RL 63 + 5 + RD_DLY 31 + SLIP
  localparam int unsigned CapSr = 66;    // CAP token: up to RL 63 + 2
  localparam int unsigned WrSr  = 64;    // WR token: up to WL 63 (+1 via wv)

  localparam logic [BankPins-1:0] BankMask = '1;
  localparam logic [AddrPins-1:0] AddrMask = '1;

  // io_o in reset = idle with CFG_RESET (deselect, CKE / CK / ODT / RESET#
  // low, shifters isolated, IDLE_DRIVE = 1: DQ / DQS driven low)
  function automatic ddr_io_out_t io_reset();
    ddr_io_out_t v;
    v         = DDR_IO_OUT_DEFAULT;
    v.ck_en   = CFG_RESET.ck_en;
    v.cke     = CFG_RESET.cke;
    v.rst_n   = HasResetN && CFG_RESET.rst_n;
    v.odt     = CFG_RESET.odt;
    v.dq_oe   = CFG_RESET.idle_drive;
    v.ls_oe_n = !CFG_RESET.ls_en;
    for (int unsigned l = 0; l < MaxLanes; l++) v.dqs_oe[l] = (l < Lanes) && CFG_RESET.idle_drive;
    return v;
  endfunction

  // =========================================================================
  // Command tokens
  // =========================================================================
  logic rd_in, wr_in, cap_in;
  assign rd_in  = cmd_v_i && (cmd_code_i == CmdRd);
  assign wr_in  = cmd_v_i && (cmd_code_i == CmdWr);
  assign cap_in = rd_in && cap_i;

  // token shift registers: bit k = 1 in cycle n + k
  logic [RdSr-1:0]  rd_sr_q;
  logic [CapSr-1:0] cap_sr_q;
  logic [WrSr-1:0]  wr_sr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_sr_q  <= '0;
      cap_sr_q <= '0;
      wr_sr_q  <= '0;
    end else begin
      rd_sr_q  <= {rd_sr_q[RdSr-2:0], rd_in};
      cap_sr_q <= {cap_sr_q[CapSr-2:0], cap_in};
      wr_sr_q  <= {wr_sr_q[WrSr-2:0], wr_in};
    end
  end

  // "next cycle" views: bit k = a command is at position k in the next cycle
  logic [WrSr:0] wv;
  logic [63:0]   rv;
  assign wv = {wr_sr_q, wr_in};
  assign rv = {rd_sr_q[62:0], rd_in};

  // =========================================================================
  // Write path
  // =========================================================================
  localparam int unsigned WfW = $bits(burst_t) + $bits(be_t);

  logic           wf_pop, wf_full, wf_empty;
  logic [WfW-1:0] wf_rdata;
  burst_t         wf_bytes;
  be_t            wf_be;

  bow_fifo_sync #(
    .Width (WfW),
    .Depth (4)
  ) u_wfifo (
    .clk_i,
    .rst_ni,
    .clr_i   (1'b0),
    .push_i  (wr_in),
    .wdata_i ({wr_be_i, wr_bytes_i}),
    .pop_i   (wf_pop),
    .rdata_o (wf_rdata),
    .full_o  (wf_full),
    .empty_o (wf_empty),
    .level_o ()
  );

  assign {wf_be, wf_bytes} = wf_rdata;

  logic [6:0] wl;
  logic       w_first, w_pre, w_pre2;
  assign wl      = {1'b0, cfg_i.wl};
  assign w_first = wv[wl + 7'd1];                         // next cycle: data cycle 0
  assign w_pre   = wv[wl];                                // next cycle: preamble
  assign w_pre2  = (cfg_i.wl != 6'd0) && !cfg_i.ddr3 && !cfg_i.idle_drive &&
                   wv[wl - 7'd1];                         // next cycle: early preamble
  assign wf_pop  = w_first;

  logic [2:0] wph_q, wph_d;     // data cycle (1..4 = data cycle 0..3) of io_q, 0 = none
  burst_t     wcur_q;           // burst being sent (data cycles 1..3)
  be_t        wcur_be_q;
  burst_t     wsrc;
  be_t        wsrc_be;
  logic [1:0] wdc;              // data cycle of the next cycle
  logic       w_post, wdrv, wdrv_must;

  always_comb begin
    wph_d   = 3'd0;
    wsrc    = wcur_q;
    wsrc_be = wcur_be_q;
    wdc     = 2'd0;
    if (w_first) begin
      wph_d   = 3'd1;
      wsrc    = wf_bytes;
      wsrc_be = wf_be;
    end else if (wph_q != 3'd0 && wph_q != 3'd4) begin
      wph_d = wph_q + 3'd1;
      wdc   = wph_q[1:0];
    end
  end

  assign w_post    = (wph_q == 3'd4) && !w_first;               // next cycle: postamble
  assign wdrv_must = w_pre || (wph_d != 3'd0) || w_post;        // write drive window
  assign wdrv      = wdrv_must || w_pre2;

  // beats 2*wdc and 2*wdc+1 of wsrc, DM = !be
  logic [1:0][DqBits-1:0] wbeat;
  logic [1:0][Lanes-1:0]  wdm;
  always_comb begin
    for (int unsigned h = 0; h < 2; h++) begin
      for (int unsigned l = 0; l < Lanes; l++) begin
        wbeat[h][8*l +: 8] = wsrc[(2 * wdc + h) * Lanes + l];
        wdm[h][l]          = !wsrc_be[(2 * wdc + h) * Lanes + l];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wph_q     <= 3'd0;
      wcur_q    <= '0;
      wcur_be_q <= '0;
    end else begin
      wph_q <= wph_d;
      if (w_first) begin
        wcur_q    <= wf_bytes;
        wcur_be_q <= wf_be;
      end
    end
  end

  // =========================================================================
  // Read window: level shifter direction and output enable
  // =========================================================================
  logic [5:0] p_on, p_off;      // window starts, relative to n
  logic [6:0] dir_len, oe_len;  // window lengths
  logic [6:0] lead_pre;
  logic [6:0] dir_cnt_q, dir_cnt_d, oe_cnt_q, oe_cnt_d;
  logic       ev_dir, ev_oe;

  assign lead_pre = 7'(cfg_i.rdir_lead) + 7'(cfg_i.oe_pre);
  assign p_on     = (7'(cfg_i.rl) >= 7'(cfg_i.rdir_lead)) ? cfg_i.rl - 6'(cfg_i.rdir_lead) : 6'd0;
  assign p_off    = (7'(cfg_i.rl) >= lead_pre) ? 6'(7'(cfg_i.rl) - lead_pre) : 6'd0;
  assign dir_len  = 7'(cfg_i.rl) + 7'd6 + 7'(cfg_i.rdir_tail) - 7'(p_on);
  assign oe_len   = 7'(cfg_i.rl) + 7'd6 + 7'(cfg_i.rdir_tail) + 7'(cfg_i.oe_post) - 7'(p_off);
  assign ev_dir   = rv[p_on];
  assign ev_oe    = rv[p_off];

  assign dir_cnt_d = ev_dir ? dir_len : ((dir_cnt_q != 7'd0) ? dir_cnt_q - 7'd1 : 7'd0);
  assign oe_cnt_d  = ev_oe  ? oe_len  : ((oe_cnt_q  != 7'd0) ? oe_cnt_q  - 7'd1 : 7'd0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dir_cnt_q <= 7'd0;
      oe_cnt_q  <= 7'd0;
    end else begin
      dir_cnt_q <= dir_cnt_d;
      oe_cnt_q  <= oe_cnt_d;
    end
  end

  // =========================================================================
  // io_o
  // =========================================================================
  ddr_io_out_t io_d, io_q;
  logic        drive, data_nxt;

  assign data_nxt = (wph_d != 3'd0);
  assign drive    = (cfg_i.idle_drive || wdrv) && (oe_cnt_d == 7'd0);

  always_comb begin
    io_d = DDR_IO_OUT_DEFAULT;
    io_d.ck_en = cfg_i.ck_en;
    io_d.cke   = cfg_i.cke;
    io_d.rst_n = HasResetN && cfg_i.rst_n;
    io_d.odt   = cfg_i.odt;
    if (cmd_v_i) begin
      {io_d.cs_n, io_d.ras_n, io_d.cas_n, io_d.we_n} = cmd_pins(cmd_code_i);
      io_d.ba = MaxBank'(BankMask) & cmd_ba_i;
      io_d.a  = MaxAddr'(AddrMask) & cmd_a_i;
    end else begin
      io_d.ba = io_q.ba;
      io_d.a  = io_q.a;
    end
    for (int unsigned l = 0; l < Lanes; l++) begin
      io_d.dqs[l]    = data_nxt ? 2'b01 : 2'b00;     // {second half, first half}
      io_d.dqs_oe[l] = drive;
    end
    if (data_nxt) begin
      for (int unsigned h = 0; h < 2; h++) begin
        io_d.dq[h][DqBits-1:0] = wbeat[h];
        if (HasDm && cfg_i.dm_en) io_d.dm[h][Lanes-1:0] = wdm[h];
      end
    end
    io_d.dq_oe      = drive;
    io_d.ls_oe_n    = !cfg_i.ls_en;
    io_d.ls_dir_dq  = (dir_cnt_d != 7'd0);
    io_d.ls_dir_dqs = (dir_cnt_d != 7'd0);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      io_q <= io_reset();
    end else begin
      io_q <= io_d;
    end
  end

  assign io_o = io_q;

  // =========================================================================
  // Read FIFO (rd_clk -> ddr_clk)
  // =========================================================================
  logic [2:0] flush_cnt_q;
  logic       flush_q;      // RFIFO_SYNC flush, 8 cycles (a flop: reset source)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      flush_q     <= 1'b0;
      flush_cnt_q <= 3'd0;
    end else if (rfifo_sync_i) begin
      flush_q     <= 1'b1;
      flush_cnt_q <= 3'd7;
    end else if (flush_cnt_q != 3'd0) begin
      flush_cnt_q <= flush_cnt_q - 3'd1;
    end else begin
      flush_q <= 1'b0;
    end
  end

  // both FIFO sides reset by the link reset or the flush (asserted together),
  // each released synchronously to its own clock
  logic wrst_n, rrst_n;

  bow_rst_sync u_wrst (
    .clk_i  (rd_clk_i),
    .rst_ni (rd_rst_ni & ~flush_q),
    .rst_no (wrst_n)
  );

  bow_rst_sync u_rrst (
    .clk_i  (clk_i),
    .rst_ni (rst_ni & ~flush_q),
    .rst_no (rrst_n)
  );

  // ---- write side (rd_clk): one register, push every cycle
  logic [FifoW-1:0] in_q;
  logic             rf_full, ovf_q;

  always_ff @(posedge rd_clk_i) begin
    in_q <= {io_i.dqs[1][Lanes-1:0], io_i.dqs[0][Lanes-1:0],
             io_i.dq[1][DqBits-1:0], io_i.dq[0][DqBits-1:0]};
  end

  always_ff @(posedge rd_clk_i or negedge wrst_n) begin
    if (!wrst_n) begin
      ovf_q <= 1'b0;
    end else if (rf_full) begin
      ovf_q <= 1'b1;        // pushed while full: the stream lost a cycle
    end
  end

  // ---- read side (ddr_clk)
  logic             rf_empty, rf_pop, ovf_s;
  logic [FifoW-1:0] rf_rdata;

  bow_fifo_async #(
    .Width (FifoW),
    .Depth (16)
  ) u_rfifo (
    .wclk_i  (rd_clk_i),
    .wrst_ni (wrst_n),
    .push_i  (1'b1),
    .wdata_i (in_q),
    .full_o  (rf_full),
    .rclk_i  (clk_i),
    .rrst_ni (rrst_n),
    .pop_i   (rf_pop),
    .rdata_o (rf_rdata),
    .empty_o (rf_empty)
  );

  bow_sync u_ovf_sync (
    .clk_i,
    .rst_ni (rrst_n),
    .d_i    (ovf_q),
    .q_o    (ovf_s)
  );

  logic [2:0] strt_q;       // cycles since empty_o was first seen low
  logic       run_q, broken_q, err_q, rf_bad;

  assign rf_pop = run_q;
  assign rf_bad = (run_q && rf_empty) || ovf_s;

  always_ff @(posedge clk_i or negedge rrst_n) begin
    if (!rrst_n) begin
      strt_q   <= 3'd0;
      run_q    <= 1'b0;
      broken_q <= 1'b0;
      err_q    <= 1'b0;
    end else begin
      if (!run_q && (strt_q != 3'd0 || !rf_empty)) strt_q <= strt_q + 3'd1;
      if (!run_q && strt_q == 3'd3) run_q <= 1'b1;   // first pop: 5th cycle
      err_q <= rf_bad && !broken_q;
      if (rf_bad) broken_q <= 1'b1;
    end
  end

  assign rfifo_err_o    = err_q;
  assign rfifo_broken_o = broken_q;

  // stream cycles s .. s-4; st_q[0] takes the FIFO RAM read data (written in
  // rd_clk): keep it a flop for the CDC tools (no SRL)
  (* shreg_extract = "no" *) logic [4:0][FifoW-1:0] st_q;

  always_ff @(posedge clk_i) begin
    st_q <= {st_q[3:0], rf_rdata};
  end

  // =========================================================================
  // Read data
  // =========================================================================
  logic [6:0]             ext_tap;
  logic                   ev_ext;
  logic [7:0][DqBits-1:0] rbeat;
  burst_t                 rbytes;
  logic                   rd_v_q;
  burst_t                 rd_bytes_q;

  assign ext_tap = 7'(cfg_i.rl) + 7'd5 + 7'(cfg_i.rd_dly) + 7'(cfg_i.rd_slip);
  assign ev_ext  = rd_sr_q[ext_tap];

  // r / f of stream cycle s - i
  function automatic logic [DqBits-1:0] st_r(logic [4:0][FifoW-1:0] st, int unsigned i);
    return st[i][DqBits-1:0];
  endfunction
  function automatic logic [DqBits-1:0] st_f(logic [4:0][FifoW-1:0] st, int unsigned i);
    return st[i][2*DqBits-1:DqBits];
  endfunction

  always_comb begin
    for (int unsigned i = 0; i < 4; i++) begin
      if (!cfg_i.rd_slip) begin       // c0 = s - 3: r_c0, f_c0, .. f_c0+3
        rbeat[2*i]     = st_r(st_q, 3 - i);
        rbeat[2*i + 1] = st_f(st_q, 3 - i);
      end else begin                  // c0 = s - 4: f_c0, r_c0+1, .. r_c0+4
        rbeat[2*i]     = st_f(st_q, 4 - i);
        rbeat[2*i + 1] = st_r(st_q, 3 - i);
      end
    end
    rbytes = '0;
    for (int unsigned k = 0; k < 8; k++) begin
      for (int unsigned l = 0; l < Lanes; l++) rbytes[k * Lanes + l] = rbeat[k][8*l +: 8];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_v_q     <= 1'b0;
      rd_bytes_q <= '0;
    end else begin
      rd_v_q <= ev_ext;
      if (ev_ext) rd_bytes_q <= rbytes;
    end
  end

  assign rd_v_o     = rd_v_q;
  assign rd_bytes_o = rd_bytes_q;

  // =========================================================================
  // Raw capture: 32 stream cycles from n + RL - 2 (= st_q[4] at n + RL + 2)
  // =========================================================================
  logic [6:0]             cap_tap;
  logic                   ev_cap, cap_act_q, cap_done_q;
  logic [4:0]             cap_idx_q;
  logic [31:0][FifoW-1:0] cap_q;

  assign cap_tap = 7'(cfg_i.rl) + 7'd2;
  assign ev_cap  = cap_sr_q[cap_tap];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cap_act_q  <= 1'b0;
      cap_idx_q  <= 5'd0;
      cap_done_q <= 1'b0;
    end else begin
      cap_done_q <= 1'b0;
      if (ev_cap) begin
        cap_act_q <= 1'b1;
        cap_idx_q <= 5'd1;
      end else if (cap_act_q) begin
        cap_idx_q <= cap_idx_q + 5'd1;
        if (cap_idx_q == 5'd31) begin
          cap_act_q  <= 1'b0;
          cap_done_q <= 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cap_q <= '0;
    end else begin
      for (int unsigned i = 0; i < 32; i++) begin
        if ((ev_cap && i == 0) || (!ev_cap && cap_act_q && cap_idx_q == 5'(i))) cap_q[i] <= st_q[4];
      end
    end
  end

  assign cap_done_o = cap_done_q;

  always_comb begin
    cap_dq_o  = '0;
    cap_dqs_o = '0;
    for (int unsigned i = 0; i < 32; i++) begin
      cap_dq_o[i][2*DqBits-1:0] = cap_q[i][2*DqBits-1:0];
      for (int unsigned l = 0; l < Lanes; l++) begin
        cap_dqs_o[i][2*l]     = cap_q[i][2*DqBits + l];           // rise
        cap_dqs_o[i][2*l + 1] = cap_q[i][2*DqBits + Lanes + l];   // fall
      end
    end
  end

  // =========================================================================
  // Status
  // =========================================================================
  assign idle_o = (rd_sr_q == '0) && (cap_sr_q == '0) && (wr_sr_q == '0) && wf_empty &&
                  (wph_q == 3'd0) && (dir_cnt_q == 7'd0) && (oe_cnt_q == 7'd0) &&
                  !cap_act_q && !cap_done_q && !rd_v_q;

  logic unused;
  assign unused = ^{cfg_i.en, cfg_i.odt_en, io_i, wf_full};   // en / odt_en: bow_ddr_dfi

  // =========================================================================
  // Simulation checks
  // =========================================================================
`ifndef SYNTHESIS
  if (DqBits != 8 && DqBits != 16) begin : g_bad_dq
    initial $fatal(1, "bow_ddr_phy: DqBits must be 8 or 16");
  end
  if (Lanes != DqBits / 8 || AddrPins > MaxAddr || BankPins > MaxBank) begin : g_bad_pins
    initial $fatal(1, "bow_ddr_phy: Lanes / AddrPins / BankPins out of range");
  end

  // (every term is 0 in reset)
  always @(posedge clk_i) begin
    if (rd_in && 7'(cfg_i.rl) < lead_pre) begin
      $error("bow_ddr_phy: RL %0d < RDIR_LEAD %0d + OE_PRE %0d", cfg_i.rl, cfg_i.rdir_lead,
             cfg_i.oe_pre);
    end
    if (wdrv_must && oe_cnt_d != 7'd0) begin
      $error("bow_ddr_phy: write burst overlaps a read OE-off window (turnaround too short for LAT)");
    end
    if (cmd_v_i && ((cmd_ba_i & ~MaxBank'(BankMask)) != '0 ||
                    (cmd_a_i & ~MaxAddr'(AddrMask)) != '0)) begin
      $error("bow_ddr_phy: BA %h / A %h beyond BankPins / AddrPins", cmd_ba_i, cmd_a_i);
    end
    if (wr_in && wf_full) $error("bow_ddr_phy: write FIFO overflow (WL + 1 > 4 * tCCD)");
    if (w_first && wf_empty) $error("bow_ddr_phy: write FIFO underflow");
  end
`endif

endmodule
