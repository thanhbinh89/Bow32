// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// PHY and bridge registers of bow_ddr (peripheral slot ddr_phy, 0x4000_E000,
// clk_i domain) and the clk_i side of the command channel to bow_ddr_dfi.
// The LiteDRAM controller has its own CSRs (slot ddr_ctrl, bow_ddr_csr).
// docs/ip/ddr.md, "Bản đồ thanh ghi".
//
//   0x000 ID          R     0x44445202 ("DDR", version 2: LiteDRAM controller)
//   0x004 INFO        R     [4:0] DQ bits [6:5] lanes-1 [10:7] address pins-1
//                           [12:11] bank pins-1 [13] DM pin [15:14] PHY kind
//                           (1 pins, 2 loopback emulator) [23:16] CK MHz
//                           (rounded) [24] DdrEn = 1 [25] RESET# pin [26] DDR3
//                           core [31:27] DFI read latency
//   0x008 CTRL        RW    [0] EN [4] DM_EN [5] DDR3 [6] IDLE_DRIVE [7] LS_EN
//                           [10] ODT_EN [11] CK_EN [12] CORE_RST [13] REF_NORM
//                           [14] REF_MON [15] LOCK                        (0x40)
//   0x00C CMD         W     exactly one bit per write: [0] APPLY [1] PS_GO
//                           [4] RFIFO_SYNC [5] SNAP [6] CLR_STATS [7] WPS_GO
//                           [8] CAP_ARM
//   0x010 STATUS      R/W1C [0] BUSY (R) [1] READY (R) [2] CLK_OK (R) [3] APPLIED
//                           [5] PS_DONE [6] CAP_DONE [9] CMD_ERR [10] RFIFO_ERR
//                           [11] BUS_TIMEOUT [12] DBG_ERR (R) [13] LINK (R)
//                           [14] PS_ERR [15] RFIFO_BROKEN (R) [16] INIT_DONE (R)
//                           [17] INIT_ERROR (R) [18] RD_LATE [19] RD_EXTRA
//                           [20] NOT_READY [21] RANGE [22] CSR_ERR [23] BROKEN (R)
//                           [24] REF_STARVE [25] LOCK_ERR
//   0x014 IRQ_EN      RW    the W1C bits: irq_o = |(STATUS & IRQ_EN)
//   0x01C LAT         RW    [5:0] RL [11:6] WL [16:12] RD_DLY [17] RD_SLIP
//                           [19:18] OE_PRE [23:20] RDIR_LEAD [27:24] RDIR_TAIL
//                           [31:28] OE_POST                           (0x22240083)
//   0x030 PS_TARGET   RW    [15:0] signed read phase target
//   0x034 PS_NOW      R     [15:0] signed read phase [31:16] PsSteps
//   0x054 WPS_TARGET  RW    [15:0] signed write phase target
//   0x058 WPS_NOW     R     [15:0] signed write phase
//   0x098 EMU         R     [4:0] log2(EmuBytes), 0 = no emulator
//   0x09C CLK_HZ      R     ClkHz
//   0x0A0..0x0B0      R     ST_RD, ST_WR, ST_ACT, ST_REF, ST_RMW (SNAP copies)
//   0x0B4 DBG         R     ddr_dbg_i, synchronised per bit (read until stable)
//   0x0B8 ERR_ADDR    R     bus address of the last window access answered
//                           with a bus error
//   0x0BC ST_RGAP     R     longest REF interval while REF_MON = 1, in CK
//                           cycles minus one (SNAP copy)
//   0x100..0x17C CAP[0..31]  R  raw DQ capture of stream cycle i: x8 [7:0] rise,
//                           [15:8] fall; x16 [15:0] rise, [31:16] fall
//   0x180..0x1FC CAPS[0..31] R  raw DQS capture: [1:0] lane 0 {fall, rise},
//                           [3:2] lane 1
// Unmapped offsets read 0, writes to them are ignored; the port never stalls
// and never answers with an error. Writes honour the byte enables. In W1C
// registers a hardware set wins over a clear in the same cycle.
//
// CTRL.CORE_RST acts at once (not through APPLY): while 1 the LiteDRAM core
// and both bridges (window, CSR) are held in reset; it also clears BROKEN.
// REF_NORM and REF_MON act at once too (levels synchronised by bow_ddr):
// REF_NORM = 1 makes the LiteDRAM core refresh every 7.8 us (case
// temperature <= 85 C; 0 = every 3.9 us, Tc <= 95 C; from the next reload of
// its refresh timer); REF_MON = 1
// runs the refresh monitor (REF_STARVE after 8 x the expected interval
// without a REF at the PHY, ST_RGAP). The other CTRL bits and LAT reach the
// ddr_clk domain with APPLY.
// LOCK (written 1, cleared only by sys_rst_n) freezes the configuration:
// writes to CTRL (except clearing REF_NORM, the safe direction), LAT,
// PS_TARGET and WPS_TARGET are ignored, CMD accepts only SNAP and CLR_STATS
// (the others: CMD_ERR), and bow_ddr_csr refuses every LiteDRAM CSR write
// (bus error, CSR_ERR; reads still work). Each refused change sets LOCK_ERR
// (a write of the value a register already has is not one). IRQ_EN, the W1C
// bits of STATUS and the memory window stay writable.
// STATUS: READY = CLK_OK, !CORE_RST (and the core seen in and out of reset
// since the last CORE_RST), LiteDRAM init_done, !init_error and !BROKEN (the
// window serves accesses only then); BROKEN = a bridge timed out, or lost
// its DDR clock with the link up, during an access (cleared only by CORE_RST
// or the link reset); INIT_DONE / INIT_ERROR = the LiteDRAM ddrctrl CSRs,
// synchronised.
// Events: NOT_READY / RANGE (window access refused or aborted by CORE_RST),
// BUS_TIMEOUT (window or CSR bridge timeout, or the DDR clock lost during an
// access), CSR_ERR (CSR access refused, Wishbone err or timeout),
// RD_LATE / RD_EXTRA (bow_ddr_dfi read return), RFIFO_ERR (PHY read FIFO),
// CAP_DONE (raw capture finished), DBG_ERR = ddr_dbg_i[31] (emulator error),
// REF_STARVE (refresh monitor), LOCK_ERR (a change refused by LOCK).
// Statistics: ST_RD / ST_WR = native reads / writes done by the window (an
// RMW counts in both), ST_RMW = read-modify-writes (window counters, clk_i),
// ST_ACT / ST_REF = ACT / REF commands sent to the DRAM (bow_ddr_dfi), ST_RGAP
// = the longest REF interval of the refresh monitor (bow_ddr_dfi); SNAP
// copies all six, CLR_STATS zeroes them, the counters are 32-bit saturating.
//
// Commands (CMD) cross into the ddr_clk domain through a request / ack copy
// channel (bow_csi2rx_regs idiom): the clk_i side loads the staging flops
// (kind, a snapshot of CTRL / LAT, the phase target) and toggles cmd_req_o in
// the same cycle; BUSY = a command in flight (req != synchronised ack, until
// its outcome is in STATUS); the results are taken when the ack arrives
// (stable on the ddr side by then). Refused at once with CMD_ERR, nothing
// sent: a CMD write with not exactly one known bit, any command while
// !CLK_OK or BUSY. The ddr side answers APPLY with CMD_ERR (instead of
// APPLIED) when the PHY did not become idle, PS_GO / WPS_GO with PS_DONE +
// PS_ERR when refused or not acknowledged by the MMCM. A command lost to a
// link reset (pending when the link goes down) sets CMD_ERR. CAP_ARM is
// acknowledged at once; CAP_DONE comes with the raw capture of the next RD.
// BUSY falls in the cycle in which the W1C bits and the results of the
// command are updated, so the STATUS word that shows BUSY = 0 also shows the
// outcome of that command.
//
// Reset domains: the registers software writes, the W1C bits, the result
// copies and the window counters use rst_ni (sys_rst_n); the channel, the
// applied DM_EN, PS_NOW / WPS_NOW, the synchronisers and the CLK_OK monitor
// use lnk_ni (the link reset). PS_NOW / WPS_NOW follow the steppers of the
// ddr side, which keep their phase through a SoC reset (the MMCMs do): the
// result of a PS_GO / WPS_GO, otherwise (no command running) the counter
// itself, each bit through bow_sync and taken when two consecutive samples
// agree (a counter changes at most once per 13 ddr_clk cycles). LINK = the ddr side is out of the link reset
// (synchronised level); CLK_OK = LINK and the ddr_clk / 8 toggle changed
// within the last 64 clk_i cycles.

module bow_ddr_regs import bow_bus_pkg::*; import bow_ddr_pkg::*; #(
  parameter int unsigned DqBits      = 8,
  parameter int unsigned AddrPins    = 14,
  parameter int unsigned BankPins    = 2,
  parameter bit          HasDm       = 1'b0,
  parameter bit          HasResetN   = 1'b0,
  parameter bit          Ddr3Core    = 1'b0,
  parameter int unsigned ClkHz       = 133_333_333,
  parameter int unsigned PsSteps     = 504,
  parameter int unsigned PhyKind     = 1,
  parameter int unsigned EmuBytes    = 0,
  parameter int unsigned ReadLatency = 12
) (
  input  logic        clk_i,
  input  logic        rst_ni,          // sys_rst_n
  input  logic        lnk_ni,          // link reset, synchronised to clk_i

  input  bus_req_t    reg_req_i,
  output bus_rsp_t    reg_rsp_o,
  output logic        irq_o,

  // bridges (bow_ddr_win, bow_ddr_csr)
  output logic        ready_o,         // STATUS.READY
  output logic        csr_avail_o,     // CLK_OK, !CORE_RST, LiteDRAM core out of reset
  output logic        abort_o,         // !CLK_OK or CORE_RST
  output logic        clk_lost_o,      // !CLK_OK (the abort is a dead clock)
  output logic        core_rst_o,      // CTRL.CORE_RST
  output logic        ref_norm_o,      // CTRL.REF_NORM (level, synchronised by the users)
  output logic        ref_mon_o,       // CTRL.REF_MON  (level, synchronised by bow_ddr_dfi)
  output logic        wlock_o,         // CTRL.LOCK: bow_ddr_csr refuses CSR writes
  output logic        masked_o,        // HasDm and applied DM_EN
  input  logic        win_dead_i,
  input  logic        csr_dead_i,
  input  logic        win_not_ready_i, // one-cycle pulses
  input  logic        win_range_i,
  input  logic        win_timeout_i,
  input  logic        csr_err_i,
  input  logic        csr_timeout_i,
  input  logic        csr_lock_err_i,  // one-cycle pulse: a CSR write refused by LOCK
  input  logic [31:0] win_err_addr_i,
  input  logic        win_st_rd_i,     // one-cycle pulses
  input  logic        win_st_wr_i,
  input  logic        win_st_rmw_i,

  // LiteDRAM core (ddr_sys_clk domain levels, synchronised here)
  input  logic        init_done_i,
  input  logic        init_error_i,
  input  logic        core_busy_i,     // the core is in reset (user_rst)

  // command channel, clk_i side
  output logic        cmd_req_o,       // toggle
  output logic [2:0]  cmd_kind_o,
  output cfg_t        cmd_cfg_o,
  output logic [15:0] cmd_target_o,
  input  logic        cmd_ack_i,       // toggle, ddr_clk domain

  // results (ddr_clk domain, stable when the ack arrives)
  input  logic        res_err_i,
  input  logic [15:0] res_ps_now_i,
  input  logic [15:0] res_wps_now_i,
  input  logic [2:0][31:0] res_st_i,   // ST_ACT, ST_REF, ST_RGAP

  // ddr_clk domain status, synchronised here
  input  logic        ddr_up_i,
  input  logic        ddr_div_i,
  input  logic        rfifo_err_i,     // toggle per event
  input  logic        rfifo_broken_i,
  input  logic        cap_done_i,      // toggle per event
  input  logic        rd_late_i,       // toggle per event
  input  logic        rd_extra_i,      // toggle per event
  input  logic        ref_starve_i,    // toggle per event

  // raw capture buffer of the PHY (quasi-static after CAP_DONE)
  input  logic [31:0][2*MaxDq-1:0]    cap_dq_i,    // [i] = CAP[i] (register layout)
  input  logic [31:0][2*MaxLanes-1:0] cap_dqs_i,   // [i] = CAPS[i][3:0]

  input  logic [31:0] dbg_i            // ddr_dbg_i, asynchronous
);

  localparam logic [2:0] KApply = 3'd0, KPs = 3'd1, KCap = 3'd2, KRfifo = 3'd4, KSnap = 3'd5,
                         KClr = 3'd6, KWps = 3'd7;

  localparam logic [11:0] RegId = 12'h000, RegInfo = 12'h004, RegCtrl = 12'h008,
                          RegCmd = 12'h00C, RegStatus = 12'h010, RegIrqEn = 12'h014,
                          RegLat = 12'h01C, RegPsTarget = 12'h030, RegPsNow = 12'h034,
                          RegWpsTarget = 12'h054, RegWpsNow = 12'h058, RegEmu = 12'h098,
                          RegClkHz = 12'h09C, RegDbg = 12'h0B4, RegErrAddr = 12'h0B8,
                          RegRgap = 12'h0BC;

  localparam int unsigned Lanes = DqBits / 8;

  localparam logic [7:0]  Mhz       = 8'((ClkHz + 500_000) / 1_000_000);
  localparam logic [31:0] InfoValue = {5'(ReadLatency), Ddr3Core, HasResetN, 1'b1, Mhz,
                                       2'(PhyKind), HasDm, 2'(BankPins - 1), 4'(AddrPins - 1),
                                       2'(Lanes - 1), 5'(DqBits)};
  localparam logic [31:0] EmuValue  = (EmuBytes == 0) ? 32'd0 : 32'($clog2(EmuBytes));

  // STATUS bits
  localparam int unsigned SBusy = 0, SReady = 1, SClkOk = 2, SApplied = 3, SPsDone = 5,
                          SCapDone = 6, SCmdErr = 9, SRfifoErr = 10, SBusTimeout = 11,
                          SDbgErr = 12, SLink = 13, SPsErr = 14, SRfifoBroken = 15,
                          SInitDone = 16, SInitError = 17, SRdLate = 18, SRdExtra = 19,
                          SNotReady = 20, SRange = 21, SCsrErr = 22, SBroken = 23,
                          SRefStarve = 24, SLockErr = 25;
  localparam int unsigned SW = 26;                    // STATUS / IRQ_EN width
  localparam logic [SW-1:0] W1cMask = 26'h37C_4E68;  // [25:24], [22:18], [14], [11:9], [6:5], [3]

  // CTRL: the defined bits, REF_NORM (may still be cleared under LOCK)
  localparam logic [15:0] CtrlBits = 16'hFCF1;
  localparam logic [15:0] CtrlNorm = 16'h2000;

  // ------------------------------------------------------------ bus decode
  logic [11:0] a;
  logic        we, re;
  logic [31:0] wd, bm, wdm;
  logic [31:0] rdata_d;          // current value of the addressed register
  logic [31:0] wm;               // ... merged with the written bytes
  logic [31:0] rd_q;
  logic [SW-1:0] status;

  assign a   = {reg_req_i.addr[11:2], 2'b00};
  assign we  = reg_req_i.req &  reg_req_i.we;
  assign re  = reg_req_i.req & ~reg_req_i.we;
  assign wd  = reg_req_i.wdata;
  assign bm  = {{8{reg_req_i.be[3]}}, {8{reg_req_i.be[2]}}, {8{reg_req_i.be[1]}},
                {8{reg_req_i.be[0]}}};
  assign wdm = wd & bm;

  // register words of the configuration
  logic [31:0] w_ctrl, w_lat;
  cfg_t        rcfg_q;           // CTRL and LAT as written
  logic        core_rst_q;       // CTRL.CORE_RST
  logic        ref_norm_q;       // CTRL.REF_NORM
  logic        ref_mon_q;        // CTRL.REF_MON
  logic        lock_q;           // CTRL.LOCK

  assign w_ctrl = {16'h0, lock_q, ref_mon_q, ref_norm_q, core_rst_q, rcfg_q.ck_en, rcfg_q.odt_en,
                   2'b00, rcfg_q.ls_en, rcfg_q.idle_drive, rcfg_q.ddr3, rcfg_q.dm_en, 3'b000,
                   rcfg_q.en};
  assign w_lat  = {rcfg_q.oe_post, rcfg_q.rdir_tail, rcfg_q.rdir_lead, rcfg_q.oe_pre,
                   rcfg_q.rd_slip, rcfg_q.rd_dly, rcfg_q.wl, rcfg_q.rl};

  // ------------------------------------------------------ synchronisers
  logic        ack_s, up_s, div_s, rfe_s, brk_s, capd_s, late_s, extra_s, rstv_s;
  logic        idone_s, ierr_s, cbusy_s;
  logic [31:0] dbg_s;

  bow_sync u_sync_ack   (.clk_i, .rst_ni(lnk_ni), .d_i(cmd_ack_i),      .q_o(ack_s));
  bow_sync u_sync_up    (.clk_i, .rst_ni(lnk_ni), .d_i(ddr_up_i),       .q_o(up_s));
  bow_sync u_sync_div   (.clk_i, .rst_ni(lnk_ni), .d_i(ddr_div_i),      .q_o(div_s));
  bow_sync u_sync_rfe   (.clk_i, .rst_ni(lnk_ni), .d_i(rfifo_err_i),    .q_o(rfe_s));
  bow_sync u_sync_brk   (.clk_i, .rst_ni(lnk_ni), .d_i(rfifo_broken_i), .q_o(brk_s));
  bow_sync u_sync_capd  (.clk_i, .rst_ni(lnk_ni), .d_i(cap_done_i),     .q_o(capd_s));
  bow_sync u_sync_late  (.clk_i, .rst_ni(lnk_ni), .d_i(rd_late_i),      .q_o(late_s));
  bow_sync u_sync_extra (.clk_i, .rst_ni(lnk_ni), .d_i(rd_extra_i),     .q_o(extra_s));
  bow_sync u_sync_rstv  (.clk_i, .rst_ni(lnk_ni), .d_i(ref_starve_i),   .q_o(rstv_s));
  bow_sync u_sync_idone (.clk_i, .rst_ni(lnk_ni), .d_i(init_done_i),    .q_o(idone_s));
  bow_sync u_sync_ierr  (.clk_i, .rst_ni(lnk_ni), .d_i(init_error_i),   .q_o(ierr_s));

  logic [15:0] psn_s, wpsn_s;
  for (genvar i = 0; i < 16; i++) begin : g_psn
    bow_sync u_sync_psn  (.clk_i, .rst_ni(lnk_ni), .d_i(res_ps_now_i[i]),  .q_o(psn_s[i]));
    bow_sync u_sync_wpsn (.clk_i, .rst_ni(lnk_ni), .d_i(res_wps_now_i[i]), .q_o(wpsn_s[i]));
  end

  bow_sync #(
    .ResetValue (1'b1)
  ) u_sync_cbusy (
    .clk_i,
    .rst_ni (lnk_ni),
    .d_i    (core_busy_i),
    .q_o    (cbusy_s)
  );

  for (genvar i = 0; i < 32; i++) begin : g_dbg
    bow_sync u_sync_dbg (.clk_i, .rst_ni(lnk_ni), .d_i(dbg_i[i]), .q_o(dbg_s[i]));
  end

  // ------------------------------------------------- registers (sys_rst_n)
  logic [SW-1:0]    irq_en_q, w1c_q;
  logic [15:0]      ps_tgt_q, wps_tgt_q;
  logic             inflight_q;
  logic [4:0][31:0] st_q;
  logic [31:0]      st_rgap_q;
  logic [31:0]      wrd_q, wwr_q, wrmw_q;   // window counters

  // ----------------------------------------------- channel (link reset)
  logic        req_q, pend_q, div_q, rfe_q, capd_q, late_q, extra_q, rstv_q;
  logic [6:0]  wd_q;             // clk_i cycles since the ddr_clk / 8 toggle changed
  logic [2:0]  kind_q;
  cfg_t        stg_cfg_q;
  logic [15:0] tgt_q;
  logic        app_dm_q;
  logic [15:0] ps_now_q, wps_now_q, psn_p_q, wpsn_p_q;

  logic pending, busy, ack_evt, link, clk_ok, broken, ready;

  // CORE_RST pending: from CORE_RST = 1 until the core has been seen in reset
  // (cbusy_s) and out of it again. The synchronised init_done / user_rst lag
  // the reset by a few cycles: without this, READY and csr_avail_o stay 1 for
  // a moment after a short CORE_RST pulse while the bridges are still in
  // reset or the core has dropped init_done, and an access launched then
  // would never be answered (window / CSR timeout, BROKEN).
  // Fallback: when the DDR clocks were stopped during the pulse, the core's
  // reset lasts only two ddr_sys cycles after they restart, which a clk_i
  // slower than ddr_sys / 2 can miss; 127 clk_i cycles with CLK_OK and the
  // core out of reset (cbusy_s = 0) also end the pending state (with the
  // clocks running the core is seen in reset within a few cycles).
  logic       rst_pend_q, rst_seen_q;
  logic [6:0] rst_wait_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rst_pend_q <= 1'b0;
      rst_seen_q <= 1'b0;
      rst_wait_q <= '0;
    end else if (core_rst_q) begin
      rst_pend_q <= 1'b1;
      rst_seen_q <= 1'b0;
      rst_wait_q <= '0;
    end else if (rst_pend_q) begin
      if (cbusy_s) rst_seen_q <= 1'b1;
      else if (rst_seen_q || rst_wait_q == 7'd127) rst_pend_q <= 1'b0;
      if (!clk_ok || cbusy_s) rst_wait_q <= '0;
      else if (rst_wait_q != 7'd127) rst_wait_q <= rst_wait_q + 7'd1;
    end
  end
  cfg_t snap_cfg;                // what APPLY sends (DM_EN only with a DM pin)

  always_comb begin
    snap_cfg       = rcfg_q;
    snap_cfg.dm_en = rcfg_q.dm_en && HasDm;
  end
  assign pending = req_q ^ ack_s;
  assign ack_evt = pend_q && !pending;
  // BUSY covers the cycle of the ack (and of an abort by the link reset): it
  // drops together with the update of the W1C bits and the result copies,
  // so a STATUS read that shows BUSY = 0 also shows the outcome
  assign busy    = pending || inflight_q;
  assign link    = up_s;
  assign clk_ok  = link && (wd_q < 7'd64);
  assign broken  = win_dead_i || csr_dead_i;
  assign ready   = clk_ok && !core_rst_q && !rst_pend_q && idone_s && !ierr_s && !broken;

  // ------------------------------------------------------- command checks
  logic       cmd_wr, c_known, c_refuse, c_launch;
  logic [2:0] c_kind;

  assign cmd_wr = we && (a == RegCmd);

  always_comb begin
    c_known = 1'b1;
    c_kind  = KApply;
    unique case (wdm)
      32'h0000_0001: c_kind = KApply;
      32'h0000_0002: c_kind = KPs;
      32'h0000_0010: c_kind = KRfifo;
      32'h0000_0020: c_kind = KSnap;
      32'h0000_0040: c_kind = KClr;
      32'h0000_0080: c_kind = KWps;
      32'h0000_0100: c_kind = KCap;
      default:       c_known = 1'b0;
    endcase
  end

  // LOCK: only SNAP / CLR_STATS (statistics) may still run
  logic c_locked;
  assign c_locked = lock_q && (c_kind != KSnap) && (c_kind != KClr);

  assign c_refuse = !c_known || !clk_ok || busy || c_locked;
  assign c_launch = cmd_wr && !c_refuse;

  // LOCK_ERR: a write under LOCK that would change the configuration (or a
  // refused command); clearing REF_NORM stays allowed
  logic lock_viol;
  always_comb begin
    lock_viol = 1'b0;
    if (lock_q && we) begin
      if (a == RegCtrl) begin
        lock_viol = ((wm[15:0] & CtrlBits & ~CtrlNorm) != (w_ctrl[15:0] & CtrlBits & ~CtrlNorm)) ||
                    (wm[13] && !ref_norm_q);
      end else if (a == RegLat) begin
        lock_viol = (wm != w_lat);
      end else if (a == RegPsTarget) begin
        lock_viol = (wm[15:0] != ps_tgt_q);
      end else if (a == RegWpsTarget) begin
        lock_viol = (wm[15:0] != wps_tgt_q);
      end else if (a == RegCmd) begin
        lock_viol = c_known && c_locked;
      end
    end
  end

  // ------------------------------------------------------------ the channel
  always_ff @(posedge clk_i or negedge lnk_ni) begin
    if (!lnk_ni) begin
      req_q     <= 1'b0;
      pend_q    <= 1'b0;
      div_q     <= 1'b0;
      rfe_q     <= 1'b0;
      capd_q    <= 1'b0;
      late_q    <= 1'b0;
      extra_q   <= 1'b0;
      rstv_q    <= 1'b0;
      wd_q      <= 7'd64;
      kind_q    <= KApply;
      stg_cfg_q <= CFG_RESET;
      tgt_q     <= '0;
      app_dm_q  <= CFG_RESET.dm_en;
      ps_now_q  <= '0;
      wps_now_q <= '0;
      psn_p_q   <= '0;
      wpsn_p_q  <= '0;
    end else begin
      pend_q  <= pending;
      div_q   <= div_s;
      rfe_q   <= rfe_s;
      capd_q  <= capd_s;
      late_q  <= late_s;
      extra_q <= extra_s;
      rstv_q  <= rstv_s;
      if (div_s != div_q)     wd_q <= '0;
      else if (wd_q != 7'd64) wd_q <= wd_q + 7'd1;

      // staging: loaded with the request toggle, never while pending
      if (c_launch) begin
        req_q     <= !req_q;
        kind_q    <= c_kind;
        stg_cfg_q <= snap_cfg;
        tgt_q     <= (c_kind == KWps) ? wps_tgt_q : ps_tgt_q;
      end

      psn_p_q  <= psn_s;
      wpsn_p_q <= wpsn_s;
      if (ack_evt) begin
        if (kind_q == KApply && !res_err_i) app_dm_q <= stg_cfg_q.dm_en;
        if (kind_q == KPs)  ps_now_q  <= res_ps_now_i;
        if (kind_q == KWps) wps_now_q <= res_wps_now_i;
      end else if (!busy) begin
        if (psn_s == psn_p_q)   ps_now_q  <= psn_s;
        if (wpsn_s == wpsn_p_q) wps_now_q <= wpsn_s;
      end
    end
  end

  // --------------------------------------------------- status and results
  logic [SW-1:0] st_set, st_clr;
  logic          abort;

  // a command pending when the link went down is lost
  assign abort  = inflight_q && !pending && !ack_evt;
  assign st_clr = (we && a == RegStatus) ? wdm[SW-1:0] : '0;

  always_comb begin
    st_set              = '0;
    st_set[SCmdErr]     = (cmd_wr && c_refuse) || abort;
    st_set[SRfifoErr]   = (rfe_s != rfe_q);
    st_set[SCapDone]    = (capd_s != capd_q);
    st_set[SRdLate]     = (late_s != late_q);
    st_set[SRdExtra]    = (extra_s != extra_q);
    st_set[SBusTimeout] = win_timeout_i || csr_timeout_i;
    st_set[SNotReady]   = win_not_ready_i;
    st_set[SRange]      = win_range_i;
    st_set[SCsrErr]     = csr_err_i;
    st_set[SRefStarve]  = (rstv_s != rstv_q);
    st_set[SLockErr]    = lock_viol || csr_lock_err_i;
    if (ack_evt) begin
      unique case (kind_q)
        KApply: begin
          if (res_err_i) st_set[SCmdErr]  = 1'b1;
          else           st_set[SApplied] = 1'b1;
        end
        KPs, KWps: begin
          st_set[SPsDone] = 1'b1;
          st_set[SPsErr]  = res_err_i;
        end
        default: ;
      endcase
    end
  end

  function automatic logic [31:0] inc32(logic [31:0] c, logic e);
    return (e && (c != '1)) ? c + 32'd1 : c;
  endfunction

  logic clr_stats;
  assign clr_stats = ack_evt && (kind_q == KClr);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rcfg_q     <= CFG_RESET;
      core_rst_q <= 1'b0;
      ref_norm_q <= 1'b0;
      ref_mon_q  <= 1'b0;
      lock_q     <= 1'b0;
      irq_en_q   <= '0;
      w1c_q      <= '0;
      ps_tgt_q   <= '0;
      wps_tgt_q  <= '0;
      inflight_q <= 1'b0;
      st_q       <= '0;
      st_rgap_q  <= '0;
      wrd_q      <= '0;
      wwr_q      <= '0;
      wrmw_q     <= '0;
    end else begin
      // software writes (wm = the addressed register merged with the written bytes)
      if (we) begin
        if (a == RegCtrl && !lock_q) begin
          rcfg_q.en         <= wm[0];
          rcfg_q.dm_en      <= wm[4];
          rcfg_q.ddr3       <= wm[5];
          rcfg_q.idle_drive <= wm[6];
          rcfg_q.ls_en      <= wm[7];
          rcfg_q.odt_en     <= wm[10];
          rcfg_q.ck_en      <= wm[11];
          core_rst_q        <= wm[12];
          ref_norm_q        <= wm[13];
          ref_mon_q         <= wm[14];
          lock_q            <= wm[15];
        end else if (a == RegCtrl) begin
          ref_norm_q        <= ref_norm_q & wm[13];   // LOCK: only towards 3.9 us
        end
        if (a == RegLat && !lock_q) begin
          {rcfg_q.oe_post, rcfg_q.rdir_tail, rcfg_q.rdir_lead, rcfg_q.oe_pre, rcfg_q.rd_slip,
           rcfg_q.rd_dly, rcfg_q.wl, rcfg_q.rl} <= wm;
        end
        if (a == RegIrqEn)                 irq_en_q  <= wm[SW-1:0] & W1cMask;
        if (a == RegPsTarget  && !lock_q)  ps_tgt_q  <= wm[15:0];
        if (a == RegWpsTarget && !lock_q)  wps_tgt_q <= wm[15:0];
      end

      if (c_launch)                inflight_q <= 1'b1;
      else if (ack_evt || abort)   inflight_q <= 1'b0;

      // W1C bits: a hardware set wins over a clear
      w1c_q <= ((w1c_q & ~st_clr) | st_set) & W1cMask;

      // window counters (live), cleared by CLR_STATS
      if (clr_stats) begin
        wrd_q  <= '0;
        wwr_q  <= '0;
        wrmw_q <= '0;
      end else begin
        wrd_q  <= inc32(wrd_q, win_st_rd_i);
        wwr_q  <= inc32(wwr_q, win_st_wr_i);
        wrmw_q <= inc32(wrmw_q, win_st_rmw_i);
      end

      // statistics snapshot
      if (ack_evt && kind_q == KSnap) begin
        st_q      <= {wrmw_q, res_st_i[1], res_st_i[0], wwr_q, wrd_q};
        st_rgap_q <= res_st_i[2];
      end
      if (clr_stats) begin
        st_q      <= '0;
        st_rgap_q <= '0;
      end
    end
  end

  assign irq_o = |(w1c_q & irq_en_q);

  // -------------------------------------------------------------- read data
  logic        rvalid_q;
  logic [4:0]  ci;

  always_comb begin
    status               = w1c_q;
    status[SBusy]        = busy;
    status[SReady]       = ready;
    status[SClkOk]       = clk_ok;
    status[SDbgErr]      = dbg_s[31];
    status[SLink]        = link;
    status[SRfifoBroken] = brk_s;
    status[SInitDone]    = idone_s;
    status[SInitError]   = ierr_s;
    status[SBroken]      = broken;
  end
  assign wm = (rdata_d & ~bm) | (wd & bm);
  assign ci = a[6:2];

  always_comb begin
    rdata_d = '0;
    if (a[11:7] == 5'b00010) begin
      rdata_d = cap_dq_i[ci];
    end else if (a[11:7] == 5'b00011) begin
      rdata_d = {28'h0, cap_dqs_i[ci]};
    end else if (a[11:4] == 8'h0A) begin
      rdata_d = st_q[a[3:2]];
    end else begin
      case (a)
        RegId:        rdata_d = IdValue;
        RegInfo:      rdata_d = InfoValue;
        RegCtrl:      rdata_d = w_ctrl;
        RegStatus:    rdata_d = {6'h0, status};
        RegIrqEn:     rdata_d = {6'h0, irq_en_q};
        RegLat:       rdata_d = w_lat;
        RegPsTarget:  rdata_d = {16'h0, ps_tgt_q};
        RegPsNow:     rdata_d = {16'(PsSteps), ps_now_q};
        RegWpsTarget: rdata_d = {16'h0, wps_tgt_q};
        RegWpsNow:    rdata_d = {16'h0, wps_now_q};
        RegEmu:       rdata_d = EmuValue;
        RegClkHz:     rdata_d = ClkHz;
        12'h0B0:      rdata_d = st_q[4];
        RegDbg:       rdata_d = dbg_s;
        RegErrAddr:   rdata_d = win_err_addr_i;
        RegRgap:      rdata_d = st_rgap_q;
        default:      rdata_d = '0;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rd_q     <= '0;
    end else begin
      rvalid_q <= reg_req_i.req;
      if (re) rd_q <= rdata_d;
    end
  end

  assign reg_rsp_o.gnt    = 1'b1;
  assign reg_rsp_o.rvalid = rvalid_q;
  assign reg_rsp_o.err    = 1'b0;
  assign reg_rsp_o.rdata  = rd_q;

  // ---------------------------------------------------------------- outputs
  assign ready_o      = ready;
  assign csr_avail_o  = clk_ok && !core_rst_q && !rst_pend_q && !cbusy_s;
  assign abort_o      = !clk_ok || core_rst_q;
  assign clk_lost_o   = !clk_ok;
  assign core_rst_o   = core_rst_q;
  assign ref_norm_o   = ref_norm_q;
  assign ref_mon_o    = ref_mon_q;
  assign wlock_o      = lock_q;
  assign masked_o     = HasDm && app_dm_q;
  assign cmd_req_o    = req_q;
  assign cmd_kind_o   = kind_q;
  assign cmd_cfg_o    = stg_cfg_q;
  assign cmd_target_o = tgt_q;

  // cke / rst_n / odt of the configuration are pins (bow_ddr_dfi), not bits
  logic unused;
  assign unused = ^{reg_req_i.addr[31:12], reg_req_i.addr[1:0], rcfg_q.cke, rcfg_q.rst_n,
                    rcfg_q.odt};

endmodule
