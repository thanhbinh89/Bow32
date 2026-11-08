// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Register block of bow_hyperram (clk_i domain, peripheral slot, 4 KiB):
// registers, STATUS / IRQ, the clk_i side of the command channel to
// bow_hyperram_ctrl (hr_clk) and the synchronisers of its state.
// docs/ip/hyperram.md, "Thanh ghi"; offsets and bits in bow_hyperram_pkg.
//
// CMD: exactly one bit per write, refused (STATUS.CMD_ERR) while a command
// runs (STATUS.BUSY), when several bits are set, or (commands for the hr
// side) while the link is down / CLK_OK = 0. FLUSH and INVAL act on the
// window at once (CMD_DONE); an INVAL is also sent by itself when a WAKE or a
// HW_RESET is done and at the end of every BIST run (the read buffer must not
// serve lines the array behind it no longer holds). The others are carried to the controller by a
// four phase handshake (req -> bow_sync -> ack -> bow_sync); their arguments
// (configuration for APPLY: CTRL / LAT / TIM0 / TRST / TWAKE; PS_TARGET,
// WPS_TARGET, REG_SEL, REG_DATA, BIST_*) are copied when CMD is written and
// stay stable until the ack. The ack brings err / code / REG_RD data
// (quasi-static); then CMD_DONE or CMD_ERR (ERR_CODE: the reason). A command
// without an ack within CmdTimeout cycles fails (CMD_ERR) and the channel
// stays busy until CORE_RST or a link reset clears it.
// State of the controller: CR0 / CR1 shadows, power state, PS_NOW, WPS_NOW
// each bit through bow_sync, taken when two consecutive samples agree (they
// only move during commands); APPLIED, BIST_BUSY, RFIFO_BROKEN, channel idle
// through bow_sync; events through bow_cdc_pulse; BIST results, statistics,
// ERR_CODE and the capture buffer are quasi-static (read after the event that
// fixed them).
// CLK_OK: a hr_clk / 16 toggle seen moving within the last 64 cycles, with
// the hr side of the link out of reset.

module bow_hyperram_regs import bow_bus_pkg::*; import bow_hyperram_pkg::*; #(
  parameter int unsigned ClkHz      = 100_000_000,  // CK
  parameter int unsigned PsSteps    = 672,
  parameter int unsigned PhyKind    = 1,            // 1 pads, 2 loopback emulator
  parameter bit          HasLs      = 1'b1,         // level shifter controls
  parameter int unsigned MemBytes   = 32 << 20,
  parameter int unsigned Lines      = 4,
  parameter int unsigned EmuBytes   = 0,
  parameter int unsigned CmdTimeout = 1 << 20
) (
  input  logic              clk_i,
  input  logic              rst_ni,          // SoC reset
  input  logic              lnk_ni,          // channel reset, clk_i side (link and !CORE_RST): the
                                             // command channel and the synchronisers

  input  bus_req_t          bus_req_i,
  output bus_rsp_t          bus_rsp_o,
  output logic              irq_o,

  // window control
  output logic              ready_o,
  output logic              core_rst_o,      // CTRL.CORE_RST (level, a flop)
  output logic              rbuf_en_o,
  output logic              wrap_fill_o,
  output logic              wpost_o,
  output logic [15:0]       wb_tmo_o,
  output logic              flush_o,         // one cycle
  output logic              inval_o,         // one cycle
  output logic              clk_ok_o,
  input  logic              win_idle_i,
  input  logic              win_dead_i,
  input  logic              win_nrdy_i,      // event pulses of the window
  input  logic              win_range_i,
  input  logic              win_tmo_i,
  input  logic              win_rderr_i,
  input  logic              win_wrerr_i,     // a posted block refused (same cycle as the ack)
  output logic              lnk_up_o,        // the channel is out of reset (a flop: usable as data)
  input  logic [31:0]       win_err_addr_i,
  input  logic              win_hit_i,
  input  logic              win_miss_i,
  input  logic              win_flush_i,

  // command channel (to the hr side: quasi-static except hc_req_o)
  output cfg_t              cfg_o,
  output logic              hc_req_o,
  output logic [3:0]        hc_code_o,
  output logic [15:0]       ps_tgt_o,
  output logic [15:0]       wps_tgt_o,
  output logic [1:0]        reg_sel_o,
  output logic [15:0]       reg_wdata_o,
  output logic [2:0]        bist_mode_o,
  output logic [7:0]        bist_burst_o,
  output logic [31:0]       bist_addr_o,
  output logic [31:0]       bist_len_o,
  output logic [31:0]       bist_seed_o,
  input  logic              hc_ack_i,        // hr_clk domain level (synchronised here)
  input  logic              hc_err_i,        // quasi-static with the ack
  input  logic [7:0]        hc_ecode_i,
  input  logic [15:0]       hc_rdata_i,

  // controller state (hr_clk domain)
  input  logic              hr_clk_i,
  input  logic              hr_lnk_ni,       // channel reset, hr side (heartbeat, event pulses)
  input  logic              applied_i,
  input  logic [15:0]       cr0_i,
  input  logic [15:0]       cr1_i,
  input  logic [1:0]        pwr_i,
  input  logic [15:0]       ps_now_i,
  input  logic [15:0]       wps_now_i,
  input  logic              bist_busy_i,
  input  logic              rfifo_broken_i,
  input  logic              chan_idle_i,     // controller: no window command in progress or queued
  input  logic [31:0]       bist_errs_i,     // quasi-static
  input  logic [31:0]       bist_faddr_i,
  input  logic [31:0]       bist_fdata_i,
  input  logic [31:0]       bist_cycles_i,
  input  logic [7:0][31:0]  st_i,            // quasi-static (SNAP)
  input  logic [7:0]        err_code_i,      // quasi-static
  input  logic [63:0][17:0] cap_i,           // quasi-static (CAP_DONE)
  input  logic              ev_rd_err_i,     // hr_clk pulses
  input  logic              ev_wr_err_i,
  input  logic              ev_tcsm_i,
  input  logic              ev_bist_done_i,
  input  logic              ev_bist_err_i,
  input  logic              ev_rfifo_err_i,
  input  logic              ev_cap_done_i,
  input  logic [31:0]       dbg_i            // board debug word (any domain, bit-wise sync)
);

  // ===========================================================================
  // Reset values derived from the CK frequency
  // ===========================================================================
  // cycles of CK in t ns, rounded up
  function automatic int unsigned cyc(int unsigned ns);
    return int'((longint'(ns) * longint'(ClkHz) + 64'd999_999_999) / 64'd1_000_000_000);
  endfunction

  function automatic int unsigned sat(int unsigned v, int unsigned max);
    return (v > max) ? max : v;
  endfunction

  localparam int unsigned TcsmRst   = sat(cyc(1000) - 5, 4095);     // tCSM 1 us (+105/125 C parts)
  localparam int unsigned CshiRst   = sat(cyc(35), 15);             // tRWR 35 ns as CS# high time
  localparam int unsigned TrstLow   = sat(cyc(1000), 65535);        // RESET# low 1 us (tRP 200 ns)
  localparam int unsigned TrstWait  = sat(cyc(150_000), 65535);     // 150 us (tVCS, tRH)
  localparam int unsigned TwakeCs   = sat(cyc(400), 65535);         // CS# pulse 400 ns (DPD 200..3000 ns)
  localparam int unsigned TwakeWait = sat(cyc(150_000), 65535);     // tEXTDPD 150 us

  localparam logic [31:0] LatRst   = 32'h0036_5522;
  localparam logic [31:0] Tim0Rst  = {6'd0, 2'd1, 4'd12, 4'd6, 4'(CshiRst), 12'(TcsmRst)};
  localparam logic [31:0] TrstRst  = {16'(TrstWait), 16'(TrstLow)};
  localparam logic [31:0] TwakeRst = {16'(TwakeWait), 16'(TwakeCs)};
  localparam logic [15:0] WbTmoRst = 16'd64;

  localparam int unsigned MemLog2 = $clog2(MemBytes);
  localparam int unsigned EmuLog2 = (EmuBytes > 0) ? $clog2(EmuBytes) : 0;
  localparam logic [31:0] InfoValue = {7'd0, 1'b1, 4'd5, 1'b0, 3'(Lines - 1), 8'(ClkHz / 1_000_000),
                                       4'(MemLog2 - 16), 1'b1, HasLs, 2'(PhyKind)};

  // ===========================================================================
  // Registers
  // ===========================================================================
  logic [31:0] ctrl_q, irq_en_q, lat_q, tim0_q, trst_q, twake_q, data_q;
  logic [1:0]  sel_q;
  logic [15:0] ps_tgt_q, wps_tgt_q, wb_tmo_q;
  logic [31:0] bctrl_q, baddr_q, blen_q, bseed_q;
  logic [31:0] status_w1c_q;       // W1C part of STATUS

  // ---- bus access
  logic [11:0] ra;
  logic        wr, rd;
  assign ra = {bus_req_i.addr[11:2], 2'b00};
  assign wr = bus_req_i.req && bus_req_i.we;
  assign rd = bus_req_i.req && !bus_req_i.we;

  // byte enables on the RW registers
  function automatic logic [31:0] bew(logic [31:0] o, logic [31:0] d, logic [3:0] be);
    logic [31:0] r;
    r = o;
    for (int unsigned b = 0; b < 4; b++) if (be[b]) r[8*b +: 8] = d[8*b +: 8];
    return r;
  endfunction

  // ===========================================================================
  // Synchronisers of the controller state
  // ===========================================================================
  // bit-wise sync, value taken when two consecutive samples agree
  localparam int unsigned QW = 16 + 16 + 2 + 16 + 16;
  logic [QW-1:0] q_in, q_s, q_prev_q, q_val_q;
  assign q_in = {wps_now_i, ps_now_i, pwr_i, cr1_i, cr0_i};

  for (genvar i = 0; i < QW; i++) begin : g_qsync
    bow_sync u_sync (
      .clk_i,
      .rst_ni (lnk_ni),
      .d_i    (q_in[i]),
      .q_o    (q_s[i])
    );
  end

  // The synchroniser flops reset with the channel (to 0), so the value is
  // taken only once they have been out of the reset for 3 cycles: until then
  // (and during the reset) CR0 / CR1 read their defaults, PS_NOW / WPS_NOW 0
  // and POWER 3 (recovering): the board-domain state is not known yet, and a
  // 0 there would read "active" in the middle of a WAKE / RESET# recovery.
  logic [1:0] qwarm_q;
  always_ff @(posedge clk_i or negedge lnk_ni) begin
    if (!lnk_ni) begin
      q_prev_q <= '0;
      q_val_q  <= {32'd0, 2'd3, Cr1Default, Cr0Default};
      qwarm_q  <= '0;
    end else begin
      q_prev_q <= q_s;
      if (qwarm_q != 2'd3)       qwarm_q <= qwarm_q + 2'd1;
      else if (q_prev_q == q_s)  q_val_q <= q_s;
    end
  end

  logic [15:0] cr0_s, cr1_s, ps_now_s, wps_now_s;
  logic [1:0]  pwr_s;
  assign {wps_now_s, ps_now_s, pwr_s, cr1_s, cr0_s} = q_val_q;

  // levels
  logic applied_s, bist_busy_s, rfb_s, chan_idle_s, ack_s;
  bow_sync u_s_app  (.clk_i, .rst_ni (lnk_ni), .d_i (applied_i),      .q_o (applied_s));
  bow_sync u_s_bist (.clk_i, .rst_ni (lnk_ni), .d_i (bist_busy_i),    .q_o (bist_busy_s));
  bow_sync u_s_rfb  (.clk_i, .rst_ni (lnk_ni), .d_i (rfifo_broken_i), .q_o (rfb_s));
  bow_sync u_s_idle (.clk_i, .rst_ni (lnk_ni), .d_i (chan_idle_i),    .q_o (chan_idle_s));
  bow_sync u_s_ack  (.clk_i, .rst_ni (lnk_ni), .d_i (hc_ack_i),       .q_o (ack_s));

  logic [31:0] dbg_s;
  for (genvar i = 0; i < 32; i++) begin : g_dbg
    bow_sync u_sync (
      .clk_i,
      .rst_ni,
      .d_i    (dbg_i[i]),
      .q_o    (dbg_s[i])
    );
  end

  // events
  localparam int unsigned NEv = 7;
  logic [NEv-1:0] ev_hr, ev_s;
  assign ev_hr = {ev_cap_done_i, ev_rfifo_err_i, ev_bist_err_i, ev_bist_done_i, ev_tcsm_i,
                  ev_wr_err_i, ev_rd_err_i};

  for (genvar i = 0; i < NEv; i++) begin : g_ev
    bow_cdc_pulse u_pulse (
      .src_clk_i   (hr_clk_i),
      .src_rst_ni  (hr_lnk_ni),
      .src_pulse_i (ev_hr[i]),
      .dst_clk_i   (clk_i),
      .dst_rst_ni  (lnk_ni),
      .dst_pulse_o (ev_s[i])
    );
  end

  // CLK_OK: hr_clk / 16 toggle
  logic [3:0] hb_q;
  always_ff @(posedge hr_clk_i or negedge hr_lnk_ni) begin
    if (!hr_lnk_ni) hb_q <= '0;
    else            hb_q <= hb_q + 4'd1;
  end

  logic       hb_s, hb_prev_q, clk_ok_q;
  logic [5:0] hb_cnt_q;
  bow_sync u_s_hb (.clk_i, .rst_ni (lnk_ni), .d_i (hb_q[3]), .q_o (hb_s));

  always_ff @(posedge clk_i or negedge lnk_ni) begin
    if (!lnk_ni) begin
      hb_prev_q <= 1'b0;
      hb_cnt_q  <= '0;
      clk_ok_q  <= 1'b0;
    end else begin
      hb_prev_q <= hb_s;
      if (hb_s != hb_prev_q) begin
        hb_cnt_q <= '0;
        clk_ok_q <= 1'b1;
      end else if (hb_cnt_q == '1) begin
        clk_ok_q <= 1'b0;
      end else begin
        hb_cnt_q <= hb_cnt_q + 6'd1;
      end
    end
  end

  // ===========================================================================
  // Command FSM
  // ===========================================================================
  typedef enum logic [1:0] {
    CIdle,
    CReq,       // req high, waiting for the ack
    CRel        // req low, waiting for the ack to fall
  } cstate_e;

  cstate_e     cst_q;
  logic        req_q;
  logic [3:0]  code_q;
  cfg_t        acfg_q;
  logic [15:0] aps_q, awps_q, awdata_q;
  logic [1:0]  asel_q;
  logic [2:0]  abmode_q;
  logic [7:0]  abburst_q;
  logic [31:0] abaddr_q, ablen_q, abseed_q;
  logic [20:0] ctmo_q;
  logic        flush_q, inval_q;
  logic        cdone_ev, cerr_ev;
  logic [7:0]  ecode_q;
  logic        snap_local;

  // CTRL / LAT / TIM / TRST / TWAKE as a configuration
  function automatic cfg_t cfg_of(logic [3:0] ctrl, logic [28:0] lat, logic [25:0] tim0,
                                  logic [31:0] trst, logic [31:0] twake);
    cfg_t c;
    c.en         = ctrl[CtrlEn];
    c.ls_en      = ctrl[CtrlLsEn];
    c.idle_drive = ctrl[CtrlIdleDrive];
    c.strict     = ctrl[CtrlStrict];
    c.rdir_lead  = lat[3:0];
    c.rdir_tail  = lat[7:4];
    c.oe_pre     = lat[9:8];
    c.oe_post    = lat[11:10];
    c.rw_dir     = lat[15:12];
    c.rw_oe      = lat[19:16];
    c.arm_lead   = lat[23:20];
    c.rd_dly     = lat[28:24];
    c.tcsm       = tim0[11:0];
    c.cshi       = tim0[15:12];
    c.lat_smp    = tim0[19:16];
    c.rd_tmo     = tim0[23:20];
    c.rd_hold    = tim0[25:24];
    c.trst_low   = trst[15:0];
    c.trst_wait  = trst[31:16];
    c.twake_cs   = twake[15:0];
    c.twake_wait = twake[31:16];
    return c;
  endfunction

  logic        cmd_wr, one_hot, hr_cmd;
  logic [31:0] cmdv;
  logic [3:0]  hcode;
  assign cmd_wr  = wr && (ra == RegCmdOff);
  assign cmdv    = bus_req_i.wdata;
  assign one_hot = (cmdv != 32'd0) && ((cmdv & (cmdv - 32'd1)) == 32'd0) && (cmdv < (32'd1 << CmdBits));
  assign hr_cmd  = !(cmdv[CmdFlush] || cmdv[CmdInval]);

  always_comb begin
    hcode = HcApply;
    priority case (1'b1)   // evaluated for every register write: only a one-hot CMD write uses it
      cmdv[CmdApply]:     hcode = HcApply;
      cmdv[CmdPsGo]:      hcode = HcPsGo;
      cmdv[CmdWpsGo]:     hcode = HcWpsGo;
      cmdv[CmdRfifoSync]: hcode = HcRfifoSync;
      cmdv[CmdCapArm]:    hcode = HcCapArm;
      cmdv[CmdHwReset]:   hcode = HcHwReset;
      cmdv[CmdRegRd]:     hcode = HcRegRd;
      cmdv[CmdRegWr]:     hcode = HcRegWr;
      cmdv[CmdWake]:      hcode = HcWake;
      cmdv[CmdBistGo]:    hcode = HcBistGo;
      cmdv[CmdBistStop]:  hcode = HcBistStop;
      cmdv[CmdSnap]:      hcode = HcSnap;
      cmdv[CmdClrStats]:  hcode = HcClrStats;
      default:            hcode = HcApply;
    endcase
  end

  logic busy;
  assign busy = (cst_q != CIdle);

  // lnk_up_q: 0 in the channel reset (CORE_RST, link down), 1 from the first
  // clock edge after it (the reset net itself is not used as data). The command
  // FSM takes a CMD only with lnk_up_q = 1: a CMD in the first cycle after the
  // release is refused like one during the reset (cmd_dead_ev below), never
  // carried out and refused at the same time.
  logic lnk_up_q;
  always_ff @(posedge clk_i or negedge lnk_ni) begin
    if (!lnk_ni) lnk_up_q <= 1'b0;
    else         lnk_up_q <= 1'b1;
  end

  always_ff @(posedge clk_i or negedge lnk_ni) begin
    if (!lnk_ni) begin
      cst_q     <= CIdle;
      req_q     <= 1'b0;
      code_q    <= '0;
      acfg_q    <= cfg_of(CtrlReset[3:0], LatRst[28:0], Tim0Rst[25:0], TrstRst, TwakeRst);
      aps_q     <= '0;
      awps_q    <= '0;
      awdata_q  <= '0;
      asel_q    <= '0;
      abmode_q  <= '0;
      abburst_q <= '0;
      abaddr_q  <= '0;
      ablen_q   <= '0;
      abseed_q  <= '0;
      ctmo_q    <= '0;
      flush_q   <= 1'b0;
      inval_q   <= 1'b0;
      cdone_ev  <= 1'b0;
      cerr_ev   <= 1'b0;
      ecode_q   <= ErrNone;
      data_q    <= '0;
    end else begin
      flush_q  <= 1'b0;
      inval_q  <= 1'b0;
      cdone_ev <= 1'b0;
      cerr_ev  <= 1'b0;
      if (cmd_wr && lnk_up_q) begin
        if (busy || !one_hot || (hr_cmd && !clk_ok_q)) begin
          cerr_ev <= 1'b1;
          ecode_q <= busy ? ecode_q : (!one_hot ? ErrArg : ErrDisable);   // malformed / no CLK_OK
        end else if (!hr_cmd) begin
          flush_q  <= cmdv[CmdFlush];
          inval_q  <= cmdv[CmdInval];
          cdone_ev <= 1'b1;
        end else begin
          req_q     <= 1'b1;
          code_q    <= hcode;
          acfg_q    <= cfg_of(ctrl_q[3:0], lat_q[28:0], tim0_q[25:0], trst_q, twake_q);
          aps_q     <= ps_tgt_q;
          awps_q    <= wps_tgt_q;
          awdata_q  <= data_q[15:0];
          asel_q    <= sel_q;
          abmode_q  <= bctrl_q[2:0];
          abburst_q <= bctrl_q[15:8];
          abaddr_q  <= baddr_q;
          ablen_q   <= blen_q;
          abseed_q  <= bseed_q;
          ctmo_q    <= 21'(CmdTimeout);
          cst_q     <= CReq;
        end
      end
      // REG_DATA is written by software (write data of REG_WR) ...
      if (wr && ra == RegDataOff) data_q <= bew(data_q, bus_req_i.wdata, bus_req_i.be) & 32'h0000_FFFF;

      // The read buffer of the window is dropped after the transactions that
      // bypass it or change the array behind it: RESET#, WAKE (out of deep
      // power down the array is lost) and every BIST run.
      if (ev_s[3]) inval_q <= 1'b1;
      unique case (cst_q)
        CReq: begin
          if (ack_s) begin
            req_q   <= 1'b0;
            cst_q   <= CRel;
            ecode_q <= hc_ecode_i;
            if (code_q == HcWake || code_q == HcHwReset) inval_q <= 1'b1;
            if (hc_err_i) begin
              cerr_ev <= 1'b1;
            end else begin
              cdone_ev <= 1'b1;
              if (code_q == HcRegRd) data_q <= {16'd0, hc_rdata_i};   // ... and by REG_RD
            end
          end else if (ctmo_q == '0) begin
            cerr_ev <= 1'b1;            // no ack: the channel stays busy (CORE_RST)
            ecode_q <= ErrDisable;
            ctmo_q  <= '1;
          end else if (ctmo_q != '1) begin
            ctmo_q <= ctmo_q - 21'd1;
          end
        end
        CRel: if (!ack_s) cst_q <= CIdle;
        default: ;
      endcase
    end
  end

  assign snap_local = (cst_q == CReq) && ack_s && (code_q == HcSnap);

  assign cfg_o        = acfg_q;
  assign hc_req_o     = req_q;
  assign hc_code_o    = code_q;
  assign ps_tgt_o     = aps_q;
  assign wps_tgt_o    = awps_q;
  assign reg_sel_o    = asel_q;
  assign reg_wdata_o  = awdata_q;
  assign bist_mode_o  = abmode_q;
  assign bist_burst_o = abburst_q;
  assign bist_addr_o  = abaddr_q;
  assign bist_len_o   = ablen_q;
  assign bist_seed_o  = abseed_q;
  assign flush_o      = flush_q;
  assign inval_o      = inval_q;

  // ===========================================================================
  // Window statistics (clk_i): hits, misses, write buffer flushes
  // ===========================================================================
  logic [2:0][31:0] wst_q, wsnap_q;
  logic             clr_local;
  assign clr_local = (cst_q == CReq) && ack_s && (code_q == HcClrStats);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wst_q   <= '0;
      wsnap_q <= '0;
    end else begin
      if (win_hit_i)   wst_q[0] <= wst_q[0] + 32'd1;
      if (win_miss_i)  wst_q[1] <= wst_q[1] + 32'd1;
      if (win_flush_i) wst_q[2] <= wst_q[2] + 32'd1;
      if (snap_local)  wsnap_q  <= wst_q;
      if (clr_local)   wst_q    <= '0;
    end
  end

  // ===========================================================================
  // STATUS
  // ===========================================================================
  logic ready;
  assign ready = lnk_ni && clk_ok_q && applied_s && ctrl_q[CtrlInitDone] && !ctrl_q[CtrlCoreRst] &&
                 !win_dead_i && (pwr_s == PwrActive);

  logic [31:0] ev_set;

  // CMD while the channel is in reset (lnk_up_q = 0): the command FSM is held
  // in reset with it, so the refusal is raised here, in the rst_ni domain.
  // dead_code_q keeps ERR_CODE[7:0] at ErrDisable after such a refusal until
  // the next CMD, also once the reset is over (ecode_q was reset with the link).
  logic cmd_dead_ev, dead_code_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cmd_dead_ev <= 1'b0;
      dead_code_q <= 1'b0;
    end else begin
      cmd_dead_ev <= cmd_wr && !lnk_up_q;
      if (cmd_wr) dead_code_q <= !lnk_up_q;
    end
  end
  assign lnk_up_o = lnk_up_q;
  always_comb begin
    ev_set               = '0;
    ev_set[StCmdDone]    = cdone_ev;
    ev_set[StCmdErr]     = cerr_ev || cmd_dead_ev;
    ev_set[StCapDone]    = ev_s[6];
    ev_set[StBistDone]   = ev_s[3];
    ev_set[StRdErr]      = ev_s[0] || win_rderr_i;
    ev_set[StWrErr]      = ev_s[1] || win_wrerr_i;
    ev_set[StRfifoErr]   = ev_s[5];
    ev_set[StBusTimeout] = win_tmo_i;
    ev_set[StNotReady]   = win_nrdy_i;
    ev_set[StRange]      = win_range_i;
    ev_set[StBistErr]    = ev_s[4];
    ev_set[StTcsmErr]    = ev_s[2];
  end

  logic [31:0] status;
  always_comb begin
    status               = status_w1c_q;
    status[StBusy]       = busy;
    status[StReady]      = ready;
    status[StClkOk]      = clk_ok_q;
    status[StApplied]    = applied_s;
    status[StPwr0 +: 2]  = pwr_s;
    status[StBistBusy]   = bist_busy_s;
    status[StBroken]     = win_dead_i;
    status[StDbgErr]     = dbg_s[31];
    status[StRfifoBrk]   = rfb_s;
    status[StWinIdle]    = win_idle_i && chan_idle_s;
  end

  // ===========================================================================
  // Register writes
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_q       <= CtrlReset;
      irq_en_q     <= '0;
      lat_q        <= LatRst;
      tim0_q       <= Tim0Rst;
      trst_q       <= TrstRst;
      twake_q      <= TwakeRst;
      sel_q        <= '0;
      ps_tgt_q     <= '0;
      wps_tgt_q    <= '0;
      wb_tmo_q     <= WbTmoRst;
      bctrl_q      <= 32'h0000_1003;   // write + read, PRBS, 16 word bursts
      baddr_q      <= '0;
      blen_q       <= 32'd1024;
      bseed_q      <= 32'h1234_5678;
      status_w1c_q <= '0;
    end else begin
      status_w1c_q <= (status_w1c_q | ev_set) & ~StatusRoMask;
      if (wr) begin
        unique case (ra)
          RegCtrlOff:   ctrl_q    <= bew(ctrl_q, bus_req_i.wdata, bus_req_i.be) & 32'h0000_1F0F;
          RegStatusOff: status_w1c_q <= (status_w1c_q & ~(bus_req_i.wdata & ~StatusRoMask)) | ev_set;
          RegIrqEnOff:  irq_en_q  <= bew(irq_en_q, bus_req_i.wdata, bus_req_i.be) & ~StatusRoMask;
          RegLatOff:    lat_q     <= bew(lat_q, bus_req_i.wdata, bus_req_i.be) & 32'h1FFF_FFFF;
          RegTim0Off:   tim0_q    <= bew(tim0_q, bus_req_i.wdata, bus_req_i.be) & 32'h03FF_FFFF;
          RegTrstOff:   trst_q    <= bew(trst_q, bus_req_i.wdata, bus_req_i.be);
          RegTwakeOff:  twake_q   <= bew(twake_q, bus_req_i.wdata, bus_req_i.be);
          RegSelOff:    sel_q     <= bus_req_i.wdata[1:0];
          RegPsTgtOff:  ps_tgt_q  <= bus_req_i.wdata[15:0];
          RegWpsTgtOff: wps_tgt_q <= bus_req_i.wdata[15:0];
          RegWbTmoOff:  wb_tmo_q  <= bus_req_i.wdata[15:0];
          RegBCtrlOff:  bctrl_q   <= bus_req_i.wdata & 32'h0000_FF07;
          RegBAddrOff:  baddr_q   <= bus_req_i.wdata;
          RegBLenOff:   blen_q    <= bus_req_i.wdata;
          RegBSeedOff:  bseed_q   <= bus_req_i.wdata;
          default: ;
        endcase
      end
    end
  end

  // ===========================================================================
  // Register reads
  // ===========================================================================
  logic [31:0] rdata;
  logic [5:0]  cidx;
  logic [3:0]  sidx;
  assign cidx = bus_req_i.addr[7:2];
  assign sidx = bus_req_i.addr[5:2];

  always_comb begin
    rdata = '0;
    if (ra >= RegCapOff && ra < RegCapOff + 12'h100) begin
      rdata = {14'd0, cap_i[cidx]};
    end else if (ra >= RegStOff && ra < RegStOff + 12'h040) begin
      if (sidx < 4'd8)       rdata = st_i[sidx[2:0]];
      else if (sidx < 4'd11) rdata = wsnap_q[2'(sidx - 4'd8)];
    end else begin
      unique case (ra)
        RegIdOff:     rdata = IdValue;
        RegInfoOff:   rdata = InfoValue;
        RegCtrlOff:   rdata = ctrl_q;
        RegStatusOff: rdata = status;
        RegIrqEnOff:  rdata = irq_en_q;
        RegLatOff:    rdata = lat_q;
        RegTim0Off:   rdata = tim0_q;
        RegTrstOff:   rdata = trst_q;
        RegTwakeOff:  rdata = twake_q;
        RegSelOff:    rdata = {30'd0, sel_q};
        RegDataOff:   rdata = data_q;
        RegCr0Off:    rdata = {16'd0, cr0_s};
        RegCr1Off:    rdata = {16'd0, cr1_s};
        RegPsTgtOff:  rdata = {16'd0, ps_tgt_q};
        RegPsNowOff:  rdata = {16'(PsSteps), ps_now_s};
        RegWpsTgtOff: rdata = {16'd0, wps_tgt_q};
        RegWpsNowOff: rdata = {16'(PsSteps), wps_now_s};
        RegClkHzOff:  rdata = 32'(ClkHz);
        RegErrAdOff:  rdata = win_err_addr_i;
        RegEmuOff:    rdata = {27'd0, 5'(EmuLog2)};
        RegDbgOff:    rdata = dbg_s;
        RegErrCdOff:  rdata = {16'd0, err_code_i, (lnk_up_q && !dead_code_q) ? ecode_q : ErrDisable};
        RegWbTmoOff:  rdata = {16'd0, wb_tmo_q};
        RegBCtrlOff:  rdata = bctrl_q;
        RegBAddrOff:  rdata = baddr_q;
        RegBLenOff:   rdata = blen_q;
        RegBSeedOff:  rdata = bseed_q;
        RegBCycOff:   rdata = bist_cycles_i;
        RegBErrsOff:  rdata = bist_errs_i;
        RegBFAddrOff: rdata = bist_faddr_i;
        RegBFDataOff: rdata = bist_fdata_i;
        default:      rdata = '0;
      endcase
    end
  end

  logic        rvalid_q;
  logic [31:0] rdata_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else begin
      rvalid_q <= bus_req_i.req;
      if (rd) rdata_q <= rdata;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = rdata_q;

  assign irq_o       = |(status_w1c_q & irq_en_q);
  assign ready_o     = ready;
  assign core_rst_o  = ctrl_q[CtrlCoreRst];
  assign rbuf_en_o   = ctrl_q[CtrlRbufEn];
  assign wrap_fill_o = ctrl_q[CtrlWrapFill];
  assign wpost_o     = ctrl_q[CtrlWpost];
  assign wb_tmo_o    = wb_tmo_q;
  assign clk_ok_o    = clk_ok_q;

  logic unused;
  assign unused = ^{bus_req_i.addr[31:12], bus_req_i.addr[1:0], dbg_s[30:0], bctrl_q[31:16],
                    bctrl_q[7:3], wsnap_q};

endmodule
