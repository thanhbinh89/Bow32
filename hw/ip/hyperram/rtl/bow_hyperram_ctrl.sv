// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// HyperBus transaction controller of bow_hyperram (hr_clk domain).
// docs/ip/hyperram.md, "Controller".
//
// Sources of work, in priority order, one at a time:
//   1. the command executor (registers -> four phase handshake hc_*): APPLY,
//      PS_GO / WPS_GO (fine phase steppers), RFIFO_SYNC, CAP_ARM, HW_RESET,
//      REG_RD / REG_WR (HyperRAM register space), WAKE, BIST_GO / STOP, SNAP,
//      CLR_STATS. A pending command stops the arbiter from starting window or
//      BIST transactions; commands that touch the pins or the read path wait
//      until the engine and the read aligner are idle.
//   2. the bus window (command FIFO from bow_hyperram_win: line fills, word
//      reads, write blocks; write data are staged before the transaction) and
//   3. the BIST bursts (bow_hyperram_bist), round robin between 2 and 3.
//   A transaction starts only when the PHY's read aligner is idle (the data
//   of the previous read are in), so responses leave in command order.
//
// Transaction schedule (t = transaction cycle; this module computes the pin
// intent of cycle t while its counter c_q = t + 2; bow_hyperram_phy registers
// it; L = CR0 latency of the shadow, fixed = CR0[3]):
//   t = -2        rwds_oe = 0 (release RWDS: the device drives it in the CA phase)
//   t = -1        ls_dir_rwds = 1
//   t = 0         cs_n = 0 (t = 0 .. t_C - 1), DQ driven (0); t_C = t_E, or
//                 t_E + rd_hold for reads (CS# held low with CK stopped: the
//                 device keeps the last byte on DQ until CS# rises)
//   t = 1..3      ck_en, DQ = CA (CK runs for 1 <= t < t_E)
//   t = lat_smp   variable latency: lat2x = synchronised RWDS (taken at most at
//                 L + 2, so that a 1x data cycle is never missed)
//   t_D           first data word: register write 4; else 2L + 3 (fixed or
//                 RWDS high) or L + 3; t_E = t_D + N
//   memory write  data and RWDS mask in t_D .. t_E - 1; ls_dir_rwds back to 0
//                 at rw_dir and RWDS driven low (preamble) from rw_oe (both
//                 clamped: 4 <= rw_dir <= rw_oe, 5 <= rw_oe <= t_D - 1)
//   reads         dq_oe = 0 from t_rdoff = max(4, D - rdir_lead - oe_pre) (D =
//                 2L + 3 when fixed, L + 3 otherwise: the earliest the device
//                 may answer), ls_dir_dq = 1 from t_rdoff + oe_pre, both back
//                 after CS# rises: ls_dir_* at t_C + 1 + rdir_tail, the FPGA
//                 drives again oe_post cycles later; RWDS likewise (never
//                 driven by the FPGA in reads, register writes and WAKE)
//   aligner arm   at t = max(4, D - arm_lead) with N words (bow_hyperram_phy)
//   end           the next transaction's t = -2 comes when every window is
//                 back to idle and its t = 0 is at least cshi cycles after t_C.
// A transaction whose CS# low time (2L + 3 + N (+ rd_hold) cycles in the worst case) is
// above TCSM is refused (ErrTcsm); a refused or failed window read answers
// WrespErr, a refused posted write raises ev_wr_err. Every window write, posted
// or not, is answered (WrespWdone at the end of its transaction, WrespErr when
// refused): the window counts its posted blocks in flight with these.
//
// Device state kept here, reset only by the board reset brd_rst_ni (the
// HyperRAM keeps its registers and data through a SoC reset): the CR0 / CR1
// shadows (CR0 latency and fixed latency drive the schedule), the power state
// (REG_WR CR0[15] = 0 -> deep power down, CR1[5] = 1 -> hybrid sleep; WAKE or
// HW_RESET -> recovery wait -> active) and the two phase steppers.

module bow_hyperram_ctrl import bow_hyperram_pkg::*; #(
  parameter int unsigned PsSteps = 672
) (
  input  logic              clk_i,         // hr_clk
  input  logic              rst_ni,        // link reset (hr side)
  input  logic              brd_rst_ni,    // board reset (MMCMs), hr side

  // ---- configuration and command channel (from bow_hyperram_regs)
  input  cfg_t              cfg_src_i,     // quasi-static, taken by APPLY
  input  logic              hc_req_i,      // synchronised level, four phase
  input  logic [3:0]        hc_code_i,     // hcmd_e, stable with hc_req_i
  input  logic [15:0]       ps_tgt_i,
  input  logic [15:0]       wps_tgt_i,
  input  logic [1:0]        reg_sel_i,
  input  logic [15:0]       reg_wdata_i,
  input  logic [2:0]        bist_mode_i,
  input  logic [7:0]        bist_burst_i,
  input  logic [31:0]       bist_addr_i,
  input  logic [31:0]       bist_len_i,
  input  logic [31:0]       bist_seed_i,
  output logic              hc_ack_o,      // level
  output logic              hc_err_o,      // stable with hc_ack_o
  output logic [7:0]        hc_code_o,     // error code, stable with hc_ack_o
  output logic [15:0]       hc_rdata_o,    // REG_RD result, stable with hc_ack_o

  // ---- state (quasi-static / levels, to the register block)
  output cfg_t              cfg_o,
  output logic              applied_o,     // configuration with EN = 1 applied
  output logic [15:0]       cr0_o,
  output logic [15:0]       cr1_o,
  output logic [1:0]        pwr_o,
  output logic [15:0]       ps_now_o,
  output logic [15:0]       wps_now_o,
  output logic              bist_busy_o,
  output logic [31:0]       bist_errs_o,
  output logic [31:0]       bist_faddr_o,
  output logic [31:0]       bist_fdata_o,  // {got, expected}
  output logic [31:0]       bist_cycles_o,
  output logic [7:0][31:0]  st_o,          // statistics snapshot (SNAP)
  output logic [7:0]        err_code_o,    // last transaction error code

  // ---- events (one cycle pulses)
  output logic              ev_rd_err_o,
  output logic              ev_wr_err_o,
  output logic              ev_tcsm_o,
  output logic              ev_bist_done_o,
  output logic              ev_bist_err_o,

  // ---- window channel
  input  logic              wc_empty_i,
  input  logic [WcmdW-1:0]  wc_rdata_i,
  output logic              wc_pop_o,
  input  logic              wr_full_i,
  output logic              wr_push_o,
  output logic [WrespW-1:0] wr_wdata_o,
  output logic              chan_idle_o,   // no window command queued or in progress (a flop)

  // ---- PHY
  output hr_io_out_t        pin_d_o,
  output logic              txn_start_o,
  output logic              arm_o,
  output logic [7:0]        arm_n_o,
  input  logic              rd_busy_i,
  input  logic              rd_v_i,
  input  logic [7:0]        rd_a_i,
  input  logic [7:0]        rd_b_i,
  input  logic              rd_done_i,
  input  logic              rd_err_i,
  input  logic [7:0]        rd_code_i,
  output logic              rfifo_sync_o,
  output logic              cap_arm_o,
  input  logic              rwds_lvl_i,

  // ---- MMCM fine phase shift (PSCLK = hr_clk)
  output logic              ps_en_o,
  output logic              ps_inc_o,
  input  logic              ps_done_i,
  output logic              wps_en_o,
  output logic              wps_inc_o,
  input  logic              wps_done_i
);

  // ===========================================================================
  // Configuration (APPLY) and device shadows
  // ===========================================================================
  cfg_t cfg_q;
  logic applied_q;

  localparam cfg_t CfgReset = '{
    idle_drive: 1'b1, strict: 1'b1, rdir_lead: 4'd2, rdir_tail: 4'd2, oe_pre: 2'd1,
    oe_post: 2'd1, rw_dir: 4'd5, rw_oe: 4'd6, arm_lead: 4'd3, rd_tmo: 4'd12, lat_smp: 4'd6,
    cshi: 4'd4, tcsm: 12'd95, rd_hold: 2'd1, default: '0
  };

  logic [15:0] cr0_q, cr1_q;
  pwr_e        pwr_q;

  logic [2:0]  lat_l;            // L of the shadow
  logic        lat_fixed;
  assign lat_l     = cr0_lat(cr0_q[7:4]);
  assign lat_fixed = cr0_q[3];

  // ===========================================================================
  // Phase steppers (board reset only)
  // ===========================================================================
  logic        ps_go, wps_go, ps_busy, wps_busy, ps_done, wps_done, ps_err, wps_err;
  logic [15:0] ps_now, wps_now, ps_ref_q;

  bow_mmcm_ps #(
    .Limit   (2 * PsSteps),
    .Timeout (64)
  ) u_ps (
    .clk_i,
    .rst_ni    (brd_rst_ni),
    .go_i      (ps_go),
    .target_i  (ps_tgt_i),
    .ref_i     (ps_ref_q),
    .busy_o    (ps_busy),
    .done_o    (ps_done),
    .err_o     (ps_err),
    .now_o     (ps_now),
    .ps_en_o,
    .ps_inc_o,
    .ps_done_i
  );

  // write phase: +-3T/16. The PHY register -> DQ / RWDS ODDR paths have 3T/4
  // of setup and T/4 of hold at phase 0 (bow_hyperram_pkg), so a write phase
  // near +T/4 would leave no hold margin; the board XDC times the paths with
  // a 3T/16 uncertainty, the whole range of this knob.
  bow_mmcm_ps #(
    .Limit   ((3 * PsSteps) / 16),
    .Timeout (64)
  ) u_wps (
    .clk_i,
    .rst_ni    (brd_rst_ni),
    .go_i      (wps_go),
    .target_i  (wps_tgt_i),
    .ref_i     (16'd0),
    .busy_o    (wps_busy),
    .done_o    (wps_done),
    .err_o     (wps_err),
    .now_o     (wps_now),
    .ps_en_o   (wps_en_o),
    .ps_inc_o  (wps_inc_o),
    .ps_done_i (wps_done_i)
  );

  // ===========================================================================
  // BIST
  // ===========================================================================
  logic        bist_start, bist_stop, bist_req, bist_req_wr, bist_take, bist_wnext;
  logic        bist_rv, bist_bdone, bist_berr, bist_busy, bist_done, bist_failed, bist_aborted;
  logic [31:0] bist_req_addr, bist_errs, bist_faddr, bist_cycles;
  logic [7:0]  bist_req_n;
  logic [15:0] bist_wdata, bist_fexp, bist_fgot;

  bow_hyperram_bist u_bist (
    .clk_i,
    .rst_ni,
    .start_i    (bist_start),
    .stop_i     (bist_stop),
    .mode_i     (bist_mode_i),
    .burst_i    (bist_burst_i),
    .addr_i     (bist_addr_i),
    .len_i      (bist_len_i),
    .seed_i     (bist_seed_i),
    .req_o      (bist_req),
    .req_wr_o   (bist_req_wr),
    .req_addr_o (bist_req_addr),
    .req_n_o    (bist_req_n),
    .take_i     (bist_take),
    .wnext_i    (bist_wnext),
    .wdata_o    (bist_wdata),
    .rv_i       (bist_rv),
    .rdata_i    ({rd_b_i, rd_a_i}),
    .bdone_i    (bist_bdone),
    .berr_i     (bist_berr),
    .busy_o     (bist_busy),
    .done_o     (bist_done),
    .failed_o   (bist_failed),
    .aborted_o  (bist_aborted),
    .errs_o     (bist_errs),
    .faddr_o    (bist_faddr),
    .fexp_o     (bist_fexp),
    .fgot_o     (bist_fgot),
    .cycles_o   (bist_cycles)
  );

  assign ev_bist_done_o = bist_done;
  assign ev_bist_err_o  = bist_done && (bist_failed || bist_errs != 32'd0);
  assign bist_errs_o    = bist_errs;
  assign bist_faddr_o   = bist_faddr;
  assign bist_fdata_o   = {bist_fgot, bist_fexp};
  assign bist_cycles_o  = bist_cycles;

  // ===========================================================================
  // Transaction engine
  // ===========================================================================
  typedef enum logic [2:0] {
    EIdle,
    EStage,    // window write: data entries -> staging buffer
    ERun,      // transaction cycles (c_q = t + 2)
    ERst,      // RESET# low
    EWait      // recovery time after a reset or a wake-up
  } estate_e;

  typedef enum logic [2:0] {
    KMemRd,
    KMemWr,
    KRegRd,
    KRegWr,
    KWake
  } kind_e;

  typedef enum logic [1:0] {
    SrcWin,
    SrcBist,
    SrcExec
  } src_e;

  estate_e     est_q;
  logic        win_txn;          // a window command is being executed
  logic [15:0] c_q;              // t + 2 (ERun), cycle counter (ERst / EWait)
  logic        rd_src_win_q, rd_src_bist_q, rd_src_x_q;   // owner of the read in flight
  logic        pair_q;           // window read: first word of a bus word pair held
  logic [15:0] pair_w_q;
  kind_e       k_q;
  src_e        src_q;
  logic [47:0] ca_q;
  logic [7:0]  n_q;              // words
  logic        fixed_q;          // 2x latency known from the start
  logic        lat2x_q;
  logic [15:0] cd_q;             // c of the first data word (t_D + 2)
  logic [15:0] cd1_q, cd2_q;     // 1x / 2x candidates
  logic [15:0] crdoff_q, cdiron_q, carm_q, csmp_q, crwoe_q, crwdir_q;
  logic [15:0] regd_q;           // register write data / REG_RD result
  logic        posted_q;
  logic        wrapped_q;        // window read: wrapped order
  logic [15:0] wake_cs_q;        // KWake: CS# low cycles
  pwr_e        wake_from_q;

  // staging buffer of a window write: 16 HyperRAM words {maskB, maskA, B, A}
  logic [15:0][17:0] stg_q;
  logic [3:0]        stg_wr_q;   // next bus word slot (0..7) being filled
  logic [3:0]        stg_left_q; // bus words still to pop
  whdr_t             hdr_q;

  // derived values of the running transaction
  logic        is_rd, is_memwr, is_regwr, is_wake;
  logic [15:0] ce, ccs, cdiroff, crdon, cend;
  logic [3:0]  post_c;

  assign is_rd    = (k_q == KMemRd) || (k_q == KRegRd);
  assign is_memwr = (k_q == KMemWr);
  assign is_regwr = (k_q == KRegWr);
  assign is_wake  = (k_q == KWake);
  assign post_c   = {2'b00, cfg_q.oe_post};
  assign ce       = is_wake ? wake_cs_q + 16'd2 : cd_q + 16'(n_q);
  assign ccs      = is_rd ? ce + 16'(cfg_q.rd_hold) : ce;    // CS# rises (t_C + 2)
  assign cdiroff  = ccs + 16'd1 + 16'(cfg_q.rdir_tail);
  assign crdon    = cdiroff + 16'(post_c);

  // the next transaction's t = -2: windows idle and CS# high for >= cshi
  always_comb begin
    logic [15:0] chi;
    chi = (16'(cfg_q.cshi) >= 16'd2) ? ccs + 16'(cfg_q.cshi) - 16'd2 : ccs;
    if (is_memwr) cend = chi;
    else          cend = (crdon > chi) ? crdon : chi;
  end

  // ---- pin intent -----------------------------------------------------------
  hr_io_out_t pin;
  logic [3:0] widx;                // data word index of this cycle
  logic       in_data;

  assign in_data = (est_q == ERun) && (is_memwr || is_regwr) && (c_q >= cd_q) && (c_q < ce);
  assign widx    = 4'(c_q - cd_q);

  always_comb begin
    logic [17:0] sw;
    pin             = HR_IO_OUT_IDLE;
    pin.dq_oe       = cfg_q.idle_drive;
    pin.rwds_oe     = cfg_q.idle_drive;
    pin.ls_oe_n     = !cfg_q.ls_en;
    sw              = stg_q[widx];
    unique case (est_q)
      ERst: pin.rst_n = 1'b0;
      ERun: begin
        pin.cs_n  = !((c_q >= 16'd2) && (c_q < ccs));
        pin.ck_en = !is_wake && (c_q >= 16'd3) && (c_q < ce);
        if (c_q >= 16'd2 && c_q < ce) pin.dq_oe = 1'b1;
        unique case (c_q)
          16'd3:   pin.dq = {ca_q[39:32], ca_q[47:40]};
          16'd4:   pin.dq = {ca_q[23:16], ca_q[31:24]};
          16'd5:   pin.dq = {ca_q[7:0],   ca_q[15:8]};
          default: ;
        endcase
        if (in_data) begin
          if (is_regwr) begin
            pin.dq = {regd_q[7:0], regd_q[15:8]};
          end else if (src_q == SrcBist) begin
            pin.dq   = {bist_wdata[15:8], bist_wdata[7:0]};
            pin.rwds = 2'b00;
          end else begin
            pin.dq   = {sw[15:8], sw[7:0]};
            pin.rwds = sw[17:16];
          end
        end
        if (is_rd) begin
          if (c_q >= crdoff_q && c_q < crdon) pin.dq_oe = 1'b0;
          pin.ls_dir_dq = (c_q >= cdiron_q) && (c_q < cdiroff);
        end
        if (is_memwr) begin
          pin.rwds_oe     = (c_q >= crwoe_q) ? ((c_q < ce) ? 1'b1 : cfg_q.idle_drive) : 1'b0;
          pin.ls_dir_rwds = (c_q >= 16'd1) && (c_q < crwdir_q);
        end else begin
          pin.rwds_oe     = (c_q >= crdon) ? cfg_q.idle_drive : 1'b0;
          pin.ls_dir_rwds = (c_q >= 16'd1) && (c_q < cdiroff);
        end
      end
      default: ;
    endcase
    if (!cfg_q.en) begin
      pin             = HR_IO_OUT_IDLE;
      pin.dq_oe       = cfg_q.idle_drive;
      pin.rwds_oe     = cfg_q.idle_drive;
      pin.ls_oe_n     = !cfg_q.ls_en;
    end
  end

  assign pin_d_o = pin;

  // ---- per cycle events of the running transaction
  logic run, at_start, at_smp, at_arm, at_end;
  assign run      = (est_q == ERun);
  assign at_start = run && (c_q == 16'd2);
  assign at_smp   = run && (c_q == csmp_q) && !fixed_q && (k_q != KRegWr) && !is_wake;
  assign at_arm   = run && is_rd && (c_q == carm_q);
  assign at_end   = run && (c_q == cend - 16'd1);

  assign txn_start_o = at_start && !is_wake;
  assign arm_o       = at_arm;
  assign arm_n_o     = n_q;
  assign bist_wnext  = in_data && (src_q == SrcBist);

  // ===========================================================================
  // Starting a transaction
  // ===========================================================================
  // set up the descriptor of a memory / register transaction
  typedef struct packed {
    kind_e       k;
    src_e        src;
    logic        linear;
    logic [31:0] waddr;
    logic [7:0]  n;
  } txn_t;

  txn_t        nx;              // the transaction the arbiter starts this cycle
  logic        go;              // start nx
  logic        tcsm_ok;
  logic [15:0] nx_cd1, nx_cd2, nx_dfirst, nx_crdoff, nx_carm, nx_csmp;
  logic [15:0] nx_crwoe, nx_crwdir;
  logic [3:0]  l16;

  assign l16     = {1'b0, lat_l};
  assign nx_cd1  = 16'(l16) + 16'd5;                 // t_D + 2, 1x
  assign nx_cd2  = 16'(2 * l16) + 16'd5;             // 2x
  assign nx_dfirst = lat_fixed ? nx_cd2 : nx_cd1;    // earliest data
  assign tcsm_ok = (nx.k == KRegWr) ? (16'd5 <= 16'(cfg_q.tcsm))
                                    : (nx_cd2 - 16'd2 + 16'(nx.n) +
                                       ((nx.k == KMemWr) ? 16'd0 : 16'(cfg_q.rd_hold))
                                       <= 16'(cfg_q.tcsm));

  always_comb begin
    logic [15:0] lp;
    lp        = 16'(cfg_q.rdir_lead) + 16'(cfg_q.oe_pre);
    nx_crdoff = (nx_dfirst >= lp + 16'd6) ? nx_dfirst - lp : 16'd6;
    nx_carm   = (nx_dfirst >= 16'(cfg_q.arm_lead) + 16'd6) ? nx_dfirst - 16'(cfg_q.arm_lead) : 16'd6;
    nx_csmp   = ((16'(cfg_q.lat_smp) < 16'(l16) + 16'd2) ? 16'(cfg_q.lat_smp) : 16'(l16) + 16'd2) + 16'd2;
    // memory write RWDS turnaround: 5 <= rw_oe <= t_D - 1, 4 <= rw_dir <= rw_oe
    // (t_D here is the earliest data cycle)
    nx_crwoe  = 16'(cfg_q.rw_oe) + 16'd2;
    if (nx_crwoe > nx_dfirst - 16'd1) nx_crwoe = nx_dfirst - 16'd1;
    if (nx_crwoe < 16'd7) nx_crwoe = 16'd7;
    nx_crwdir = 16'(cfg_q.rw_dir) + 16'd2;
    if (nx_crwdir > nx_crwoe) nx_crwdir = nx_crwoe;
    if (nx_crwdir < 16'd6) nx_crwdir = 16'd6;
  end

  // ===========================================================================
  // Command executor
  // ===========================================================================
  typedef enum logic [2:0] {
    XIdle,
    XWait,     // waiting for an idle engine / aligner
    XPs,       // phase stepper running
    XRfs,      // RFIFO_SYNC settling
    XEng,      // engine op (reset, wake, register access) running
    XAck
  } xstate_e;

  xstate_e     xst_q;
  hcmd_e       xcode_q;
  logic        ack_q, xerr_q;
  logic [7:0]  xcode_err_q;
  logic [15:0] xrdata_q;
  logic [4:0]  rfs_cnt_q;
  logic        eng_idle;        // nothing on the pins, nothing in the read path
  logic        x_needs_txn;     // REG_RD / REG_WR: a register transaction
  logic        x_sel;           // the executor waits for a register transaction
  logic        x_go;            // ... and starts it now
  logic        x_tcsm_ok;       // its CS# low time fits TCSM
  logic [7:0]  pair_x_a_q, pair_x_b_q;
  logic        est_n_idle;      // EWait ends this cycle

  assign eng_idle    = (est_q == EIdle) && !rd_busy_i;
  assign x_needs_txn = (xcode_q == HcRegRd) || (xcode_q == HcRegWr);
  assign x_sel       = (xst_q == XWait) && x_needs_txn;
  // register read: 1 word at 2x latency at most (+ rd_hold); register write: t_E = 5
  assign x_tcsm_ok   = (xcode_q == HcRegWr) ? (12'd5 <= cfg_q.tcsm)
                                            : (12'(2 * lat_l) + 12'd4 + 12'(cfg_q.rd_hold)
                                               <= cfg_q.tcsm);

  // ===========================================================================
  // Arbiter: window and BIST (only when the executor has nothing pending)
  // ===========================================================================
  whdr_t       wh;
  logic        wc_hdr;
  logic        rr_q;            // 1: BIST first
  logic        pick_win, pick_bist;
  logic        win_ok, bist_ok;

  assign wh      = whdr_t'(wc_rdata_i[$bits(whdr_t)-1:0]);   // 36 bits
  assign wc_hdr  = !wc_empty_i && wc_rdata_i[WcmdW-1];
  assign win_ok  = (xst_q == XIdle) && eng_idle && wc_hdr;
  assign bist_ok = (xst_q == XIdle) && eng_idle && bist_req;
  assign pick_win  = win_ok && (!bist_ok || !rr_q);
  assign pick_bist = bist_ok && !pick_win;

  // descriptor of what would start
  always_comb begin
    nx = '{k: KMemRd, src: SrcWin, linear: 1'b1, waddr: '0, n: 8'd2};
    if (x_sel) begin
      nx.src    = SrcExec;
      nx.k      = (xcode_q == HcRegWr) ? KRegWr : KRegRd;
      nx.linear = 1'b1;
      nx.waddr  = hr_reg_waddr(reg_sel_i);
      nx.n      = 8'd1;
    end else if (pick_bist) begin
      nx.src    = SrcBist;
      nx.k      = bist_req_wr ? KMemWr : KMemRd;
      nx.linear = 1'b1;
      nx.waddr  = bist_req_addr;
      nx.n      = bist_req_n;
    end else begin
      // window (from the header, or the staged header in EStage)
      nx.src = SrcWin;
      if (est_q == EStage) begin
        nx.k      = KMemWr;
        nx.linear = 1'b1;
        nx.waddr  = 32'({hdr_q.line, hdr_q.first, 1'b0});
        nx.n      = {3'd0, 4'({1'b0, hdr_q.last} - {1'b0, hdr_q.first}) + 4'd1, 1'b0};
      end else if (wop_e'(wh.op) == WopRdLine) begin
        nx.k      = KMemRd;
        nx.linear = !(wh.wrap && cr0_q[1:0] == 2'b11);
        nx.waddr  = 32'({wh.line, (nx.linear ? 3'd0 : wh.crit), 1'b0});
        nx.n      = 8'd16;
      end else begin
        nx.k      = KMemRd;
        nx.linear = 1'b1;
        nx.waddr  = 32'({wh.line, wh.crit, 1'b0});
        nx.n      = 8'd2;
      end
    end
  end

  // ===========================================================================
  // Engine state machine
  // ===========================================================================
  logic        ready_dev;          // device can take a transaction
  logic        stage_done;         // last write data entry popped this cycle
  logic        win_start, win_refuse, wr_pop_hdr, wr_pop_data;
  logic        bist_start_txn, bist_refuse;
  logic        x_eng_start;
  logic [7:0]  refuse_code;

  assign ready_dev   = cfg_q.en && (pwr_q == PwrActive);
  assign refuse_code = !cfg_q.en ? ErrDisable : ((pwr_q != PwrActive) ? ErrPower : ErrTcsm);

  // window header popped in EIdle; write data popped in EStage
  assign wr_pop_hdr  = (est_q == EIdle) && pick_win;
  assign wr_pop_data = (est_q == EStage) && (stg_left_q != 4'd0) && !wc_empty_i && !wc_rdata_i[WcmdW-1];
  assign stage_done  = (est_q == EStage) && (stg_left_q == 4'd0);
  assign wc_pop_o    = wr_pop_hdr || wr_pop_data;

  // reads start from EIdle, writes after staging
  logic win_rd_now;
  assign win_rd_now = wr_pop_hdr && (wop_e'(wh.op) != WopWr);
  assign win_start  = (win_rd_now || stage_done) && ready_dev && tcsm_ok;
  assign win_refuse = (win_rd_now || stage_done) && !(ready_dev && tcsm_ok);

  assign bist_start_txn = (est_q == EIdle) && pick_bist && ready_dev && tcsm_ok;
  assign bist_refuse    = (est_q == EIdle) && pick_bist && !(ready_dev && tcsm_ok);
  assign bist_take      = bist_start_txn || bist_refuse;

  // executor engine ops
  assign x_go        = x_sel && eng_idle && ready_dev && x_tcsm_ok &&
                       !(xcode_q == HcRegWr && !reg_sel_i[1]);
  assign x_eng_start = x_go;
  assign go          = win_start || bist_start_txn || x_eng_start;


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      est_q      <= EIdle;
      c_q        <= '0;
      k_q        <= KMemRd;
      src_q      <= SrcWin;
      ca_q       <= '0;
      n_q        <= '0;
      fixed_q    <= 1'b1;
      lat2x_q    <= 1'b1;
      cd_q       <= '0;
      cd1_q      <= '0;
      cd2_q      <= '0;
      crdoff_q   <= '0;
      cdiron_q   <= '0;
      carm_q     <= '0;
      csmp_q     <= '0;
      crwoe_q    <= '0;
      crwdir_q   <= '0;
      regd_q     <= '0;
      posted_q   <= 1'b0;
      wrapped_q  <= 1'b0;
      wake_cs_q  <= '0;
      wake_from_q <= PwrActive;
      stg_wr_q   <= '0;
      stg_left_q <= '0;
      hdr_q      <= '0;
      rr_q       <= 1'b0;
    end else begin
      unique case (est_q)
        EIdle: begin
          if (wr_pop_hdr) begin
            hdr_q     <= wh;
            posted_q  <= wh.posted;
            rr_q      <= 1'b1;
            if (wop_e'(wh.op) == WopWr) begin
              est_q      <= EStage;
              stg_wr_q   <= 4'd0;
              stg_left_q <= {1'b0, wh.last} - {1'b0, wh.first} + 4'd1;
            end
          end else if (pick_bist) begin
            rr_q <= 1'b0;
          end
        end
        EStage: begin
          if (wr_pop_data) begin
            stg_left_q <= stg_left_q - 4'd1;
            stg_wr_q   <= stg_wr_q + 4'd1;
          end
          if (stage_done) est_q <= EIdle;    // ERun below when started
        end
        ERun: begin
          c_q <= c_q + 16'd1;
          if (at_smp) begin
            lat2x_q <= rwds_lvl_i;
            cd_q    <= rwds_lvl_i ? cd2_q : cd1_q;
          end
          if (at_end) begin
            if (is_wake) begin
              est_q <= EWait;
              c_q   <= '0;
            end else begin
              est_q <= EIdle;
            end
          end
        end
        ERst: begin
          c_q <= c_q + 16'd1;
          if (c_q + 16'd1 >= cfg_q.trst_low) begin
            est_q <= EWait;
            c_q   <= '0;
          end
        end
        EWait: begin
          c_q <= c_q + 16'd1;
          if (c_q + 16'd1 >= (xcode_q == HcWake ? cfg_q.twake_wait : cfg_q.trst_wait)) begin
            est_q <= EIdle;
          end
        end
        default: est_q <= EIdle;
      endcase

      // start of a transaction (memory / register)
      if (go) begin
        est_q     <= ERun;
        c_q       <= '0;
        k_q       <= nx.k;
        src_q     <= nx.src;
        ca_q      <= hr_ca((nx.k == KMemRd) || (nx.k == KRegRd), (nx.k == KRegRd) || (nx.k == KRegWr),
                           nx.linear, nx.waddr);
        n_q       <= nx.n;
        fixed_q   <= lat_fixed;
        lat2x_q   <= lat_fixed;
        cd1_q     <= nx_cd1;
        cd2_q     <= nx_cd2;
        cd_q      <= (nx.k == KRegWr) ? 16'd6 : nx_dfirst;
        crdoff_q  <= nx_crdoff;
        cdiron_q  <= nx_crdoff + 16'(cfg_q.oe_pre);
        carm_q    <= nx_carm;
        csmp_q    <= nx_csmp;
        crwoe_q   <= nx_crwoe;
        crwdir_q  <= nx_crwdir;
        regd_q    <= reg_wdata_i;
        wrapped_q <= !nx.linear;
      end

      // window write: stage the data entries (bus word k -> HyperRAM words 2k, 2k+1)
      if (wr_pop_data) begin
        stg_q[2 * stg_wr_q[2:0]]     <= {!wc_rdata_i[33], !wc_rdata_i[32], wc_rdata_i[15:8], wc_rdata_i[7:0]};
        stg_q[2 * stg_wr_q[2:0] + 1] <= {!wc_rdata_i[35], !wc_rdata_i[34], wc_rdata_i[31:24], wc_rdata_i[23:16]};
      end

      // executor: reset pulse / wake pulse (pseudo transaction)
      if ((xst_q == XWait) && eng_idle && xcode_q == HcHwReset && cfg_q.en) begin
        est_q <= ERst;
        c_q   <= '0;
      end
      if ((xst_q == XWait) && eng_idle && xcode_q == HcWake && cfg_q.en) begin
        est_q       <= ERun;
        c_q         <= '0;
        k_q         <= KWake;
        src_q       <= SrcExec;
        n_q         <= '0;
        fixed_q     <= 1'b1;
        cd_q        <= 16'd2;
        wake_cs_q   <= cfg_q.twake_cs;
        wake_from_q <= pwr_q;
        crdoff_q    <= '1;
        cdiron_q    <= '1;
        carm_q      <= '1;
        csmp_q      <= '1;
      end
    end
  end

  // staging buffer slots of words not written by this block: masked
  // (stg_q only holds words first..last; the transaction covers exactly those)

  // window busy: header taken, the transaction or its read data not finished
  assign win_txn = ((est_q == EStage) || (run && src_q == SrcWin)) || (rd_busy_i && rd_src_win_q);

  // ===========================================================================
  // Read data routing and completion
  // ===========================================================================
  logic resp_push;
  logic [WrespW-1:0] resp_data;
  logic ev_rd_err_q, ev_wr_err_q, ev_tcsm_q;
  logic [7:0] err_code_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_src_win_q      <= 1'b0;
      rd_src_bist_q     <= 1'b0;
      rd_src_x_q        <= 1'b0;
      pair_q            <= 1'b0;
      pair_w_q          <= '0;
    end else begin
      if (at_arm) begin
        rd_src_win_q      <= (src_q == SrcWin);
        rd_src_bist_q     <= (src_q == SrcBist);
        rd_src_x_q        <= (src_q == SrcExec);
        pair_q            <= 1'b0;
        end
      if (rd_v_i && rd_src_win_q) begin
        pair_q   <= !pair_q;
        pair_w_q <= {rd_b_i, rd_a_i};
      end
      if (rd_done_i) begin
        rd_src_win_q  <= 1'b0;
        rd_src_bist_q <= 1'b0;
        rd_src_x_q    <= 1'b0;
      end
    end
  end

  // responses to the window: data pairs, read errors, write done / refusals
  always_comb begin
    resp_push = 1'b0;
    resp_data = '0;
    if (rd_v_i && rd_src_win_q && pair_q) begin
      resp_push = 1'b1;
      resp_data = {(wrapped_q ? WrespDataW : WrespData), rd_b_i, rd_a_i, pair_w_q};
    end else if (rd_done_i && rd_err_i && rd_src_win_q) begin
      resp_push = 1'b1;
      resp_data = {WrespErr, 24'd0, rd_code_i};
    end else if (win_refuse) begin
      resp_push = 1'b1;              // posted blocks too: the window counts them
      resp_data = {WrespErr, 24'd0, refuse_code};
    end else if (at_end && src_q == SrcWin && is_memwr) begin
      resp_push = 1'b1;              // posted or not (posted: the data are in the device)
      resp_data = {WrespWdone, 32'd0};
    end
  end

  assign wr_push_o  = resp_push;
  assign wr_wdata_o = resp_data;

  // BIST: read words, end of each transaction
  assign bist_rv    = rd_v_i && rd_src_bist_q;
  assign bist_bdone = (at_end && src_q == SrcBist && is_memwr) || (rd_done_i && rd_src_bist_q) ||
                      bist_refuse;
  assign bist_berr  = (rd_done_i && rd_src_bist_q && rd_err_i) || bist_refuse;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ev_rd_err_q <= 1'b0;
      ev_wr_err_q <= 1'b0;
      ev_tcsm_q   <= 1'b0;
      err_code_q  <= ErrNone;
    end else begin
      ev_rd_err_q <= rd_done_i && rd_err_i && (rd_src_win_q || rd_src_bist_q);
      ev_wr_err_q <= win_refuse && (est_q == EStage) && posted_q;
      ev_tcsm_q   <= ((win_refuse || bist_refuse) && refuse_code == ErrTcsm) ||
                     (x_sel && eng_idle && ready_dev && !x_tcsm_ok);
      if (rd_done_i && rd_err_i) err_code_q <= rd_code_i;
      else if (win_refuse || bist_refuse) err_code_q <= refuse_code;
    end
  end

  assign ev_rd_err_o = ev_rd_err_q;
  assign ev_wr_err_o = ev_wr_err_q;
  assign ev_tcsm_o   = ev_tcsm_q;
  assign err_code_o  = err_code_q;

  // ===========================================================================
  // Command executor
  // ===========================================================================
  // engine op completion for the executor
  logic x_rd_done;
  assign x_rd_done = rd_done_i && rd_src_x_q;

  // the REG_RD data word and rd_done_i come in the same cycle: take it from
  // the inputs then
  logic [15:0] reg_rd_word;
  assign reg_rd_word = rd_v_i ? {rd_a_i, rd_b_i} : {pair_x_a_q, pair_x_b_q};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      xst_q       <= XIdle;
      xcode_q     <= HcApply;
      ack_q       <= 1'b0;
      xerr_q      <= 1'b0;
      xcode_err_q <= ErrNone;
      xrdata_q    <= '0;
      rfs_cnt_q   <= '0;
      cfg_q       <= CfgReset;
      applied_q   <= 1'b0;
      bist_start  <= 1'b0;
      bist_stop   <= 1'b0;
      cap_arm_o   <= 1'b0;
      rfifo_sync_o <= 1'b0;
      ps_go       <= 1'b0;
      wps_go      <= 1'b0;
    end else begin
      bist_start   <= 1'b0;
      bist_stop    <= 1'b0;
      cap_arm_o    <= 1'b0;
      rfifo_sync_o <= 1'b0;
      ps_go        <= 1'b0;
      wps_go       <= 1'b0;
      unique case (xst_q)
        XIdle: begin
          if (hc_req_i && !ack_q) begin
            xcode_q     <= hcmd_e'(hc_code_i);
            xerr_q      <= 1'b0;
            xcode_err_q <= ErrNone;
            unique case (hcmd_e'(hc_code_i))
              HcCapArm: begin
                cap_arm_o <= 1'b1;
                xst_q     <= XAck;
              end
              HcBistGo: begin
                if (bist_busy) begin
                  xerr_q <= 1'b1;
                end else begin
                  bist_start <= 1'b1;
                end
                xst_q <= XAck;
              end
              HcBistStop: begin
                bist_stop <= 1'b1;
                xst_q     <= XAck;
              end
              HcSnap, HcClrStats: xst_q <= XAck;     // statistics block below
              HcApply, HcPsGo, HcWpsGo, HcRfifoSync, HcHwReset, HcRegRd, HcRegWr, HcWake:
                xst_q <= XWait;
              default: begin
                xerr_q <= 1'b1;
                xst_q  <= XAck;
              end
            endcase
          end
        end

        XWait: begin
          if (eng_idle) begin
            unique case (xcode_q)
              HcApply: begin
                cfg_q     <= cfg_src_i;
                applied_q <= cfg_src_i.en;
                xst_q     <= XAck;
              end
              HcPsGo: begin
                ps_go <= 1'b1;
                xst_q <= XPs;
              end
              HcWpsGo: begin
                wps_go <= 1'b1;
                xst_q  <= XPs;
              end
              HcRfifoSync: begin
                rfifo_sync_o <= 1'b1;
                rfs_cnt_q    <= 5'd20;
                xst_q        <= XRfs;
              end
              HcHwReset, HcWake: begin
                if (!cfg_q.en) begin
                  xerr_q      <= 1'b1;
                  xcode_err_q <= ErrDisable;
                  xst_q       <= XAck;
                end else begin
                  xst_q <= XEng;           // the engine starts this cycle
                end
              end
              HcRegRd, HcRegWr: begin
                if (xcode_q == HcRegWr && !reg_sel_i[1]) begin
                  xerr_q <= 1'b1;          // ID0 / ID1 are read only
                  xst_q  <= XAck;
                end else if (!(ready_dev && x_tcsm_ok)) begin
                  xerr_q      <= 1'b1;
                  xcode_err_q <= !cfg_q.en ? ErrDisable : ((pwr_q != PwrActive) ? ErrPower : ErrTcsm);
                  xst_q       <= XAck;
                end else begin
                  xst_q <= XEng;           // x_go: the transaction starts this cycle
                end
              end
              default: xst_q <= XAck;
            endcase
          end
        end

        XPs: begin
          if ((xcode_q == HcPsGo && ps_done) || (xcode_q == HcWpsGo && wps_done)) begin
            xerr_q <= (xcode_q == HcPsGo) ? ps_err : wps_err;
            xst_q  <= XAck;
          end
        end

        XRfs: begin
          rfs_cnt_q <= rfs_cnt_q - 5'd1;
          if (rfs_cnt_q == 5'd1) xst_q <= XAck;
        end

        XEng: begin
          if (xcode_q == HcRegRd) begin
            if (x_rd_done) begin
              xerr_q      <= rd_err_i;
              xcode_err_q <= rd_code_i;
              xrdata_q    <= rd_err_i ? 16'd0 : reg_rd_word;
              xst_q       <= XAck;
            end
          end else if (est_q == EIdle) begin
            xst_q <= XAck;               // reset / wake / register write finished
          end
        end

        default: begin                   // XAck
          ack_q <= 1'b1;
          if (ack_q && !hc_req_i) begin
            ack_q <= 1'b0;
            xst_q <= XIdle;
          end
        end
      endcase
    end
  end

  // REG_RD: the word as it arrives (register space is big endian: A = [15:8])
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pair_x_a_q <= '0;
      pair_x_b_q <= '0;
    end else if (rd_v_i && rd_src_x_q) begin
      pair_x_a_q <= rd_a_i;
      pair_x_b_q <= rd_b_i;
    end
  end


  assign hc_ack_o   = ack_q;            // a flop (bow_sync in the register block)
  assign hc_err_o   = xerr_q;
  assign hc_code_o  = xcode_err_q;
  assign hc_rdata_o = xrdata_q;

  // ===========================================================================
  // Device shadows and power state (board reset)
  // ===========================================================================
  logic reg_wr_done;
  assign reg_wr_done = at_end && is_regwr;

  always_ff @(posedge clk_i or negedge brd_rst_ni) begin
    if (!brd_rst_ni) begin
      cr0_q    <= Cr0Default;
      cr1_q    <= Cr1Default;
      pwr_q    <= PwrActive;
      ps_ref_q <= '0;
    end else begin
      if (est_q == ERst && c_q == 16'd0) begin
        cr0_q <= Cr0Default;
        cr1_q <= Cr1Default;
        pwr_q <= PwrWait;
      end
      if (run && is_wake && c_q == 16'd2) pwr_q <= PwrWait;
      if (est_q == EWait && est_n_idle) begin
        pwr_q <= PwrActive;
        if (xcode_q == HcWake && wake_from_q == PwrDpd) begin
          cr0_q <= Cr0Default;          // out of deep power down: power-on state
          cr1_q <= Cr1Default;
        end else if (xcode_q == HcWake) begin
          cr1_q[5] <= 1'b0;             // out of hybrid sleep
        end
      end
      // CR1[1:0] (distributed refresh interval) is read only and depends on the
      // device's temperature grade: a REG_RD of CR1 brings it into the shadow
      // (CR0 stays what was written: it sets the latency of every transaction)
      if (xst_q == XEng && xcode_q == HcRegRd && x_rd_done && !rd_err_i && reg_sel_i == 2'd3) begin
        cr1_q[1:0] <= reg_rd_word[1:0];
      end
      if (reg_wr_done) begin
        if (ca_q[0]) begin              // CR1
          cr1_q <= {regd_q[15:2], cr1_q[1:0]};   // [1:0] read only
          if (regd_q[5]) pwr_q <= PwrHs;
        end else begin                  // CR0
          cr0_q <= regd_q;
          if (!regd_q[15]) pwr_q <= PwrDpd;
        end
      end
      if (xst_q == XRfs && rfs_cnt_q == 5'd1) ps_ref_q <= ps_now;
    end
  end

  assign est_n_idle = (c_q + 16'd1 >= (xcode_q == HcWake ? cfg_q.twake_wait : cfg_q.trst_wait));

  assign cfg_o     = cfg_q;
  assign applied_o = applied_q;
  assign cr0_o     = cr0_q;
  assign cr1_o     = cr1_q;
  assign pwr_o     = pwr_q;
  assign ps_now_o  = ps_now;
  assign wps_now_o = wps_now;

  // levels that cross to clk_i leave from flops (no logic before bow_sync)
  logic bist_busy_q, chan_idle_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bist_busy_q <= 1'b0;
      chan_idle_q <= 1'b1;
    end else begin
      bist_busy_q <= bist_busy;
      chan_idle_q <= wc_empty_i && !win_txn;
    end
  end
  assign bist_busy_o    = bist_busy_q;
  assign chan_idle_o    = chan_idle_q;

  // ===========================================================================
  // Statistics: 0 read transactions, 1 write transactions, 2 words read,
  // 3 words written, 4 transactions with 2x latency, 5 register accesses,
  // 6 failed / refused transactions, 7 BIST transactions
  // ===========================================================================
  logic [7:0][31:0] cnt_q, snap_q;
  logic             snap_now, clr_now;

  assign snap_now = (xst_q == XIdle) && hc_req_i && !ack_q && hcmd_e'(hc_code_i) == HcSnap;
  assign clr_now  = (xst_q == XIdle) && hc_req_i && !ack_q && hcmd_e'(hc_code_i) == HcClrStats;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cnt_q  <= '0;
      snap_q <= '0;
    end else begin
      if (at_start && k_q == KMemRd) cnt_q[0] <= cnt_q[0] + 32'd1;
      if (at_start && k_q == KMemWr) cnt_q[1] <= cnt_q[1] + 32'd1;
      if (rd_v_i && !rd_src_x_q)     cnt_q[2] <= cnt_q[2] + 32'd1;
      if (in_data && is_memwr)       cnt_q[3] <= cnt_q[3] + 32'd1;
      if (at_end && lat2x_q && !is_regwr && !is_wake) cnt_q[4] <= cnt_q[4] + 32'd1;
      if (at_start && (k_q == KRegRd || k_q == KRegWr)) cnt_q[5] <= cnt_q[5] + 32'd1;
      if ((rd_done_i && rd_err_i) || win_refuse || bist_refuse) cnt_q[6] <= cnt_q[6] + 32'd1;
      if (at_start && src_q == SrcBist) cnt_q[7] <= cnt_q[7] + 32'd1;
      if (snap_now) snap_q <= cnt_q;
      if (clr_now)  cnt_q  <= '0;
    end
  end

  assign st_o = snap_q;

  // The response FIFO cannot overflow: one read in flight at a time (16 words =
  // 8 entries), a non-posted write answers one entry, the FIFO has 16.
  logic unused;
  assign unused = ^{wr_full_i, ps_busy, wps_busy, bist_aborted, hdr_q.op, hdr_q.posted, hdr_q.wrap,
                    hdr_q.crit};

endmodule
