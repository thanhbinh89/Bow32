// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// DFI adapter between the LiteDRAM controller core (DFI 1:4, BL8, read
// latency ReadLatency) and the Bow32 PHY (bow_ddr_phy, one command per CK),
// plus the ddr_clk side of the command channel of bow_ddr_regs (APPLY, phase
// steppers, RFIFO_SYNC, CAP_ARM, statistics). docs/ip/ddr.md.
//
// Clocks: sys_clk_i = LiteDRAM controller clock (CK / 4) and clk_i = ddr_clk
// (CK) come from the same MMCM; every sys_clk_i rising edge is a clk_i rising
// edge. Paths between the two domains are synchronous (timed by STA, no
// synchronisers). "Controller cycle T" = sys_clk_i cycle T = ddr cycles
// 4T .. 4T+3; DFI phase n of cycle T belongs to DRAM clock 4T+n.
//
// Phase tracking: tgl_q toggles in every sys cycle; sampled twice in clk_i it
// changes (s1_q != s2_q) in the second ddr cycle of each sys cycle (phase 1),
// which reloads ph_q (= the phase of the current ddr cycle). The player is
// locked once a reload finds ph_q already right (a stale first sample after
// the link reset can not lock it); before that every DFI command is dropped.
//
// Command path (fixed delay of 8 CK): dfi_q (sys flops) holds the DFI phases
// of cycle T during sys cycle T+1. In ddr cycle 4T+4+n phase n is decoded
// (cs_n = 0: {ras_n, cas_n, we_n} 000 MRS, 001 REF, 010 PRE, 011 ACT, 100 WR,
// 101 RD, 110 ZQ, 111 NOP = no command; cs_n = 1: no command) into cmd_q,
// which drives the PHY in ddr cycle 4T+5+n: the PHY presents it in PHY cycle
// 4T+6+n and the DRAM latches it at CK edge 4T+8+n. A WR carries the burst
// of its controller cycle (write_latency 0): byte (2n+h)*Lanes+l = lane l of
// wrdata[h] of phase n, enable = !wrdata_mask; wrdata_en / rddata_en are not
// looked at (every WR sends a burst, every RD expects one). CTRL.EN = 0:
// every command is dropped (deselect). A RD while CAP_ARM is pending carries
// cap_i (raw capture) and consumes the arm.
// Pins: cke = EN & cke of phase 0, rst_n = EN & reset_n of phase 0, odt = EN
// & ODT_EN & odt of phase 0 (the PHY's cfg_i.cke / rst_n / odt), updated in
// step with the phase 0 commands.
// Refresh rate: the core issues a REF every CoreTRefi controller cycles
// (trefi_ns 3900: the JEDEC rate for a case temperature of 85..95 C), every
// 2 x CoreTRefi with CTRL.REF_NORM (its refresh timer, bow_ddr.sv); here
// REF_NORM (ref_norm_i, synchronised) only sets the monitor's limit.
//
// Read return: LiteDRAM takes the DFI rddata of all phases exactly
// ReadLatency controller cycles after the cycle with the RD (it does not look
// at rddata_valid; the DFII phase injectors latch rddata on rddata_valid).
// Every RD decoded in cycle T is a token of that cycle (two RDs in one cycle
// make one token and an extra burst). Tokens shift once per sys cycle; at
// the last ddr cycle of sys cycle T+ReadLatency-1 the output registers
// (clk_i flops that change only at sys_clk_i edges) are loaded: rddata =
// the head of the return FIFO (16 bursts, pushed by the PHY's rd_v_o) and
// rddata_valid = 1 on all phases, for exactly sys cycle T+ReadLatency.
//   RD_LATE: the FIFO is empty at that point (or the RD was dropped by EN =
//            0): rddata_valid with garbage; the late burst of a RD that did
//            reach the PHY is discarded when it arrives.
//   RD_EXTRA: a PHY burst with no read in flight at the PHY (or a full FIFO):
//            discarded.
// RD budget: a RD on phase n of cycle T comes back from the PHY in ddr cycle
// 4T + 12 + n + RL + RD_DLY + RD_SLIP and must be in the FIFO in ddr cycle
// 4T + 4*ReadLatency - 1, so RL + RD_DLY + RD_SLIP <= 4*ReadLatency - 14 - n:
// ReadLatency 12, LiteDRAM's RD phase n = 2: RL + RD_DLY + RD_SLIP <= 32
// (DDR2 CL3: RD_DLY + RD_SLIP <= 29; DDR3 CL6: <= 26); a DFII RD on phase 3
// has one cycle less.
//
// Command channel (ddr side; bow_ddr_regs is the clk_i side): cmd_req_i is a
// toggle of the clk_i domain, synchronised here; a command is pending while
// req != ack. Its kind and payload (staging flops of bow_ddr_regs) are
// stable until the ack. The results (res_*, the phase counters, the
// statistics snapshot) are registered at least one cycle before ack_q
// copies the request and stay until the next command.
//   0 APPLY     wait until the PHY is idle (no read / write / capture token,
//               no command entering it) and copy cmd_cfg_i into the applied
//               configuration (cfg_q); not idle within ApplyWait cycles:
//               res_err, nothing applied. The read FIFO is not touched.
//   1 PS_GO     read-phase stepper (ddr_ps_*) to the target; refused (err)
//               when |target - phase at the last RFIFO_SYNC| > 2 * PsSteps.
//   2 CAP_ARM   the next RD carries cap_i (raw capture); ack at once, the
//               capture is reported by cap_done_o.
//   4 RFIFO_SYNC  one-cycle rfifo_sync_o to the PHY (flush + restart), the
//               read phase is recorded as the reference of PS_GO, ack after
//               32 cycles (the restart of the FIFO is done by then).
//   5 SNAP      copy the ACT / REF counters and the longest REF interval
//               into res_st_o.
//   6 CLR_STATS zero them and res_st_o.
//   7 WPS_GO    write-phase stepper (ddr_wps_*); refused (err) when
//               |target| > PsSteps / 4.
// The two steppers (and so the phase counters) are reset by ps_rst_ni only,
// the MMCM lock: they count the MMCM phases, which a SoC reset (the link
// reset of this domain) does not move. After a link reset the executor waits
// until both are idle (a move started before the reset finishes), then
// restarts the read FIFO there (an internal RFIFO_SYNC: the PHY's FIFO
// restarted at the reset release, while the move was still running) and
// takes that read phase as the PS_GO reference.
// Statistics (32-bit saturating): ACT and REF commands passed to the PHY;
// the longest REF interval (below).
// Refresh monitor (CTRL.REF_MON, ref_mon_i synchronised): while it is 1, a
// 16-bit counter (saturating) counts the ddr cycles since the last REF that
// reached the PHY (or since REF_MON rose). When it reaches RefLim = 8 x the
// expected interval (4 * CoreTRefi ddr cycles, twice that with REF_NORM),
// ref_starve_o toggles once (STATUS.REF_STARVE): eight REFs missed, one
// before the JEDEC limit (8 postponed). The largest count seen while REF_MON
// = 1 is the third statistic (ST_RGAP: the longest REF interval minus one, in
// ddr cycles), zeroed by CLR_STATS. REF_MON = 0 stops and clears the counter:
// the firmware clears it around DFII software sections (no refresh there).
// Status to the clk_i side: ddr_up_o (1 once this domain is out of reset),
// ddr_div_o (ddr_clk / 8 square wave, CLK_OK monitor), toggles per event:
// rfifo_err_o, cap_done_o, rd_late_o, rd_extra_o, ref_starve_o.

module bow_ddr_dfi import bow_ddr_pkg::*; #(
  parameter int unsigned DqBits      = 8,
  parameter int unsigned PsSteps     = 504,
  parameter int unsigned ReadLatency = 12,     // LiteDRAM PhySettings.read_latency
  parameter int unsigned ApplyWait   = 4096,   // ddr_clk cycles
  parameter int unsigned CoreTRefi   = 129     // controller cycles between REFs of the core
) (
  // ---- ddr_sys_clk domain (LiteDRAM controller)
  input  logic                    sys_clk_i,
  input  logic                    sys_rst_ni,          // lnk_dsys_n
  input  dfi_phase_t [3:0]        dfi_i,               // DFI phases 0..3 (controller -> PHY)
  output logic [3:0][2*MaxDq-1:0] dfi_rddata_o,        // clk_i flops, change at sys_clk_i edges
  output logic [3:0]              dfi_rddata_valid_o,

  // ---- ddr_clk domain
  input  logic                    clk_i,
  input  logic                    rst_ni,              // lnk_ddr_n

  // command channel, ddr side
  input  logic                    ps_rst_ni,           // MMCM phase reset (steppers), clk_i domain
  input  logic                    cmd_req_i,           // toggle, clk_i domain of bow_ddr_regs
  input  logic [2:0]              cmd_kind_i,
  input  cfg_t                    cmd_cfg_i,
  input  logic [15:0]             cmd_target_i,
  output logic                    cmd_ack_o,           // toggle
  output logic                    res_err_o,
  output logic [15:0]             res_ps_now_o,
  output logic [15:0]             res_wps_now_o,
  output logic [2:0][31:0]        res_st_o,            // SNAP copies: [0] ST_ACT, [1] ST_REF,
                                                       // [2] ST_RGAP

  // refresh controls (CTRL bits, clk_i domain of bow_ddr_regs: synchronised here)
  input  logic                    ref_norm_i,          // REF_NORM: the core refreshes at 2 x CoreTRefi
  input  logic                    ref_mon_i,           // REF_MON: refresh monitor on

  // status to the clk_i side
  output logic                    ddr_up_o,
  output logic                    ddr_div_o,
  output logic                    rfifo_err_o,         // toggle per read FIFO error
  output logic                    cap_done_o,          // toggle per finished raw capture
  output logic                    rd_late_o,           // toggle per RD_LATE event
  output logic                    rd_extra_o,          // toggle per RD_EXTRA event
  output logic                    ref_starve_o,        // toggle per refresh starvation event

  // PHY (bow_ddr_phy)
  output cfg_t                    phy_cfg_o,
  output logic                    phy_cmd_v_o,
  output cmd_e                    phy_cmd_code_o,
  output logic [2:0]              phy_cmd_ba_o,
  output logic [15:0]             phy_cmd_a_o,
  output burst_t                  phy_wr_bytes_o,
  output be_t                     phy_wr_be_o,
  output logic                    phy_cap_o,
  input  logic                    phy_rd_v_i,
  input  burst_t                  phy_rd_bytes_i,
  input  logic                    phy_cap_done_i,
  input  logic                    phy_idle_i,
  output logic                    phy_rfifo_sync_o,
  input  logic                    phy_rfifo_err_i,

  // MMCM fine phase shift (PSCLK = clk_i)
  output logic                    ps_en_o,
  output logic                    ps_inc_o,
  input  logic                    ps_done_i,
  output logic                    wps_en_o,
  output logic                    wps_inc_o,
  input  logic                    wps_done_i
);

  localparam int unsigned Lanes = DqBits / 8;
  localparam int unsigned BB    = 8 * Lanes;            // burst bytes
  localparam int unsigned DlLen = ReadLatency - 2;      // token stages (sys cycles T+2 ..)
  localparam int unsigned AW    = $clog2(ApplyWait + 1);

  localparam logic [2:0] KApply = 3'd0, KPs = 3'd1, KCap = 3'd2, KRfifo = 3'd4, KSnap = 3'd5,
                         KClr = 3'd6, KWps = 3'd7;

  // =========================================================================
  // sys_clk domain: DFI capture and the phase toggle
  // =========================================================================
  dfi_phase_t [3:0] dfi_q;
  logic             tgl_q;

  always_ff @(posedge sys_clk_i or negedge sys_rst_ni) begin
    if (!sys_rst_ni) begin
      tgl_q <= 1'b0;
      for (int unsigned n = 0; n < 4; n++) begin
        dfi_q[n]       <= '0;
        dfi_q[n].cs_n  <= 1'b1;
        dfi_q[n].ras_n <= 1'b1;
        dfi_q[n].cas_n <= 1'b1;
        dfi_q[n].we_n  <= 1'b1;
      end
    end else begin
      tgl_q <= !tgl_q;
      dfi_q <= dfi_i;
    end
  end

  // =========================================================================
  // ddr_clk domain: phase of the current ddr cycle in the sys cycle
  // =========================================================================
  logic       s1_q, s2_q, lock_q, edge1;
  logic [1:0] ph_q;

  assign edge1 = s1_q ^ s2_q;       // this ddr cycle is phase 1

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_q   <= 1'b0;
      s2_q   <= 1'b0;
      ph_q   <= 2'd0;
      lock_q <= 1'b0;
    end else begin
      s1_q <= tgl_q;
      s2_q <= s1_q;
      ph_q <= edge1 ? 2'd2 : ph_q + 2'd1;
      if (edge1 && ph_q == 2'd1) lock_q <= 1'b1;
    end
  end

  // =========================================================================
  // Command player
  // =========================================================================
  cfg_t       cfg_q;              // applied configuration (APPLY)
  dfi_phase_t slot;
  cmd_e       code;
  logic       is_cmd, is_rd, is_wr;
  burst_t     wbytes;
  be_t        wbe;

  assign slot = dfi_q[ph_q];

  always_comb begin
    unique case ({slot.ras_n, slot.cas_n, slot.we_n})
      3'b000:  code = CmdMrs;
      3'b001:  code = CmdRef;
      3'b010:  code = CmdPre;
      3'b011:  code = CmdAct;
      3'b100:  code = CmdWr;
      3'b101:  code = CmdRd;
      3'b110:  code = CmdZq;
      default: code = CmdNop;
    endcase
  end

  assign is_cmd = lock_q && !slot.cs_n && (code != CmdNop);
  assign is_rd  = is_cmd && (code == CmdRd);
  assign is_wr  = is_cmd && (code == CmdWr);

  // refresh controls (CTRL, clk_i domain of bow_ddr_regs)
  logic ref_norm, ref_mon;

  bow_sync u_sync_norm (
    .clk_i,
    .rst_ni,
    .d_i    (ref_norm_i),
    .q_o    (ref_norm)
  );

  bow_sync u_sync_mon (
    .clk_i,
    .rst_ni,
    .d_i    (ref_mon_i),
    .q_o    (ref_mon)
  );


  // the burst of the controller cycle in address order (write_latency 0)
  always_comb begin
    wbytes = '0;
    wbe    = '0;
    for (int unsigned n = 0; n < 4; n++) begin
      for (int unsigned h = 0; h < 2; h++) begin
        for (int unsigned l = 0; l < Lanes; l++) begin
          wbytes[(2 * n + h) * Lanes + l] = dfi_q[n].wrdata[h * DqBits + 8 * l +: 8];
          wbe[(2 * n + h) * Lanes + l]    = !dfi_q[n].wrdata_mask[h * Lanes + l];
        end
      end
    end
  end

  logic       cmd_v_q, cap_q, cap_armed_q, cap_arm;
  cmd_e       code_q;
  logic [2:0] ba_q;
  logic [15:0] a_q;
  burst_t     wr_bytes_q;
  be_t        wr_be_q;
  logic       cke_q, rstn_q, odt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cmd_v_q     <= 1'b0;
      code_q      <= CmdNop;
      ba_q        <= '0;
      a_q         <= '0;
      wr_bytes_q  <= '0;
      wr_be_q     <= '0;
      cap_q       <= 1'b0;
      cap_armed_q <= 1'b0;
      cke_q       <= 1'b0;
      rstn_q      <= 1'b0;
      odt_q       <= 1'b0;
    end else begin
      cmd_v_q <= is_cmd && cfg_q.en;
      cap_q   <= is_rd && cfg_q.en && cap_armed_q;
      if (is_cmd) begin
        code_q <= code;
        ba_q   <= slot.bank;
        a_q    <= slot.address;
      end
      if (is_wr) begin
        wr_bytes_q <= wbytes;
        wr_be_q    <= wbe;
      end
      if (cap_arm)                                  cap_armed_q <= 1'b1;
      else if (is_rd && cfg_q.en && cap_armed_q)    cap_armed_q <= 1'b0;
      cke_q  <= cfg_q.en && dfi_q[0].cke;
      rstn_q <= cfg_q.en && dfi_q[0].reset_n;
      odt_q  <= cfg_q.en && cfg_q.odt_en && dfi_q[0].odt;
    end
  end

  always_comb begin
    phy_cfg_o       = cfg_q;
    phy_cfg_o.cke   = cke_q;
    phy_cfg_o.rst_n = rstn_q;
    phy_cfg_o.odt   = odt_q;
  end

  assign phy_cmd_v_o    = cmd_v_q;
  assign phy_cmd_code_o = code_q;
  assign phy_cmd_ba_o   = ba_q;
  assign phy_cmd_a_o    = a_q;
  assign phy_wr_bytes_o = wr_bytes_q;
  assign phy_wr_be_o    = wr_be_q;
  assign phy_cap_o      = cap_q;

  // =========================================================================
  // Read return
  // =========================================================================
  // token = {RD reached the PHY, RD decoded}
  logic [1:0]             tok_now, tok_acc_q;
  logic [DlLen-1:0][1:0]  dl_q;
  logic                   deadline, dl_sent;

  assign tok_now  = {is_rd && cfg_q.en, is_rd};
  assign deadline = (ph_q == 2'd3) && dl_q[DlLen-1][0];
  assign dl_sent  = dl_q[DlLen-1][1];

  // return FIFO (bursts of reads that reached the PHY, in order)
  logic              rf_push, rf_pop, rf_full, rf_empty;
  logic [8*BB-1:0]   rf_wdata, rf_rdata;
  logic [5:0]        infl_q;      // reads in the PHY whose burst did not come yet
  logic [5:0]        drop_q;      // late reads whose burst must still be discarded
  logic [5:0]        pend_drop;
  logic              arrive, keep, extra, late, discard;
  logic              rd_valid_q;
  logic [8*BB-1:0]   rd_data_q;

  assign late      = deadline && (!dl_sent || rf_empty);
  assign pend_drop = drop_q + 6'(late && dl_sent);           // incl. the read late right now
  assign arrive    = phy_rd_v_i && (infl_q != '0);           // burst of a read in flight
  assign discard   = arrive && (pend_drop != '0);            // ... that came too late
  assign keep      = arrive && (pend_drop == '0);
  assign extra     = (phy_rd_v_i && (infl_q == '0)) || (keep && rf_full);
  assign rf_push   = keep && !rf_full;
  assign rf_pop    = deadline && dl_sent && !rf_empty;
  assign rf_wdata  = phy_rd_bytes_i[BB-1:0];

  bow_fifo_sync #(
    .Width (8 * BB),
    .Depth (16)
  ) u_rfifo (
    .clk_i,
    .rst_ni,
    .clr_i   (1'b0),
    .push_i  (rf_push),
    .wdata_i (rf_wdata),
    .pop_i   (rf_pop),
    .rdata_o (rf_rdata),
    .full_o  (rf_full),
    .empty_o (rf_empty),
    .level_o ()
  );

  logic rd_issue;
  assign rd_issue = cmd_v_q && (code_q == CmdRd);

  logic late_tgl_q, extra_tgl_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tok_acc_q   <= '0;
      dl_q        <= '0;
      infl_q      <= '0;
      drop_q      <= '0;
      rd_valid_q  <= 1'b0;
      rd_data_q   <= '0;
      late_tgl_q  <= 1'b0;
      extra_tgl_q <= 1'b0;
    end else begin
      // tokens: accumulated over the four slots of a controller cycle, then
      // one shift per sys cycle (at the ddr edge that is a sys_clk edge)
      if (ph_q == 2'd3) begin
        dl_q      <= {dl_q[DlLen-2:0], tok_acc_q | tok_now};
        tok_acc_q <= '0;
        // output registers: change only at sys_clk edges
        rd_valid_q <= dl_q[DlLen-1][0];
        if (deadline) rd_data_q <= rf_rdata;
      end else begin
        tok_acc_q <= tok_acc_q | tok_now;
      end
      infl_q <= infl_q + 6'(rd_issue) - 6'(arrive);
      drop_q <= pend_drop - 6'(discard);
      if (late)  late_tgl_q  <= !late_tgl_q;
      if (extra) extra_tgl_q <= !extra_tgl_q;
    end
  end

  always_comb begin
    dfi_rddata_o = '0;
    for (int unsigned n = 0; n < 4; n++) begin
      dfi_rddata_o[n][2*DqBits-1:0] = rd_data_q[16 * Lanes * n +: 16 * Lanes];
    end
  end
  assign dfi_rddata_valid_o = {4{rd_valid_q}};

  // =========================================================================
  // Command channel (ddr side) and executor
  // =========================================================================
  typedef enum logic [2:0] {
    EIdle,
    EApply,       // APPLY: waiting for the PHY to be idle
    EPs,          // a phase stepper running
    EWait,        // RFIFO_SYNC: restart time
    EAck          // results registered: copy the request into the ack
  } estate_e;

  logic req_s, ack_q;

  bow_sync u_sync_req (
    .clk_i,
    .rst_ni,
    .d_i    (cmd_req_i),
    .q_o    (req_s)
  );

  // ------------------------------------------------------------- steppers
  logic        ps_go_q, wps_go_q, ps_busy, wps_busy, ps_done, wps_done, ps_err, wps_err;
  logic [15:0] sync_ref_q, ps_now, wps_now;

  bow_ddr_ps #(
    .Limit   (2 * PsSteps),
    .Timeout (64)
  ) u_ps_rd (
    .clk_i,
    .rst_ni    (ps_rst_ni),
    .go_i      (ps_go_q),
    .target_i  (cmd_target_i),
    .ref_i     (sync_ref_q),
    .busy_o    (ps_busy),
    .done_o    (ps_done),
    .err_o     (ps_err),
    .now_o     (ps_now),
    .ps_en_o   (ps_en_o),
    .ps_inc_o  (ps_inc_o),
    .ps_done_i (ps_done_i)
  );

  bow_ddr_ps #(
    .Limit   (PsSteps / 4),
    .Timeout (64)
  ) u_ps_wr (
    .clk_i,
    .rst_ni    (ps_rst_ni),
    .go_i      (wps_go_q),
    .target_i  (cmd_target_i),
    .ref_i     (16'h0000),
    .busy_o    (wps_busy),
    .done_o    (wps_done),
    .err_o     (wps_err),
    .now_o     (wps_now),
    .ps_en_o   (wps_en_o),
    .ps_inc_o  (wps_inc_o),
    .ps_done_i (wps_done_i)
  );

  // ------------------------------------------------------------ executor
  estate_e         state_q;
  logic            res_err_q, sync_q, wps_q, ref_ok_q;
  logic [4:0]      ref_wait_q;
  logic [AW-1:0]   tmr_q;
  logic [1:0][31:0] st_q;
  logic [2:0][31:0] snap_q;
  logic [15:0]      gap_max_q;     // longest REF interval while REF_MON (statistics)

  // The steppers keep running through a link reset (SoC reset, MMCMs still
  // locked): after it, a command waits until both are idle and the read FIFO
  // has been restarted at the read phase reached (ref_ok_q).
  logic new_cmd;
  assign new_cmd = (state_q == EIdle) && (req_s != ack_q) && ref_ok_q;
  assign cap_arm = new_cmd && (cmd_kind_i == KCap);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= EIdle;
      ack_q      <= 1'b0;
      res_err_q  <= 1'b0;
      cfg_q      <= CFG_RESET;
      sync_q     <= 1'b0;
      ps_go_q    <= 1'b0;
      wps_go_q   <= 1'b0;
      wps_q      <= 1'b0;
      sync_ref_q <= '0;
      ref_ok_q   <= 1'b0;
      ref_wait_q <= '0;
      tmr_q      <= '0;
      snap_q     <= '0;
    end else begin
      sync_q   <= 1'b0;
      ps_go_q  <= 1'b0;
      wps_go_q <= 1'b0;
      // after a link reset: once both steppers are idle (a move started
      // before the reset runs on, past the phase the read FIFO restarted
      // at), restart the read FIFO there and take that phase as the PS_GO
      // reference; commands wait for the restart (32 cycles, as RFIFO_SYNC)
      if (!ref_ok_q) begin
        if (ref_wait_q != '0) begin
          ref_wait_q <= ref_wait_q - 5'd1;
          if (ref_wait_q == 5'd1) ref_ok_q <= 1'b1;
        end else if (!ps_busy && !wps_busy) begin
          sync_q     <= 1'b1;
          sync_ref_q <= ps_now;
          ref_wait_q <= 5'd31;
        end
      end

      unique case (state_q)
        EIdle: begin
          if (new_cmd) begin
            res_err_q <= 1'b0;
            unique case (cmd_kind_i)
              KApply: begin
                tmr_q   <= AW'(ApplyWait);
                state_q <= EApply;
              end
              KPs, KWps: begin
                ps_go_q  <= (cmd_kind_i == KPs);
                wps_go_q <= (cmd_kind_i == KWps);
                wps_q    <= (cmd_kind_i == KWps);
                state_q  <= EPs;
              end
              KRfifo: begin
                sync_q     <= 1'b1;
                sync_ref_q <= ps_now;
                tmr_q      <= AW'(31);
                state_q    <= EWait;
              end
              KSnap: begin
                snap_q  <= {32'(gap_max_q), st_q};
                state_q <= EAck;
              end
              KClr: begin
                snap_q  <= '0;
                state_q <= EAck;
              end
              default: state_q <= EAck;   // KCap (armed by cap_arm), unused codes
            endcase
          end
        end

        EApply: begin
          // nothing in flight in the PHY and no command entering it: a
          // command of the next cycle sees the new configuration only
          if (phy_idle_i && !cmd_v_q) begin
            cfg_q   <= cmd_cfg_i;
            state_q <= EAck;
          end else if (tmr_q == '0) begin
            res_err_q <= 1'b1;
            state_q   <= EAck;
          end else begin
            tmr_q <= tmr_q - AW'(1);
          end
        end

        EPs: begin
          if (wps_q ? wps_done : ps_done) begin
            res_err_q <= wps_q ? wps_err : ps_err;
            state_q   <= EAck;
          end
        end

        EWait: begin
          tmr_q <= tmr_q - AW'(1);
          if (tmr_q == '0) state_q <= EAck;
        end

        default: begin   // EAck
          ack_q   <= req_s;
          state_q <= EIdle;
        end
      endcase
    end
  end

  // ------------------------------------------------- statistics, status
  function automatic logic [31:0] inc32(logic [31:0] c, logic e);
    return (e && (c != '1)) ? c + 32'd1 : c;
  endfunction

  logic       clr, up_q, rfe_q, capd_q;
  logic [2:0] div_q;
  assign clr = new_cmd && (cmd_kind_i == KClr);

  // refresh monitor: ddr cycles since the last REF at the PHY (REF_MON)
  localparam int unsigned RefLim = 32 * CoreTRefi;   // 8 x 4 ddr cycles x CoreTRefi

  logic        ref_sent, starve_tgl_q;
  logic [15:0] gap_q, gap_lim;
  assign ref_sent = cmd_v_q && (code_q == CmdRef);
  assign gap_lim  = ref_norm ? 16'(2 * RefLim) : 16'(RefLim);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q         <= '0;
      up_q         <= 1'b0;
      div_q        <= '0;
      rfe_q        <= 1'b0;
      capd_q       <= 1'b0;
      gap_q        <= '0;
      gap_max_q    <= '0;
      starve_tgl_q <= 1'b0;
    end else begin
      up_q  <= 1'b1;
      div_q <= div_q + 3'd1;
      if (phy_rfifo_err_i) rfe_q  <= !rfe_q;
      if (phy_cap_done_i)  capd_q <= !capd_q;
      if (clr) begin
        st_q <= '0;
      end else begin
        st_q[0] <= inc32(st_q[0], cmd_v_q && (code_q == CmdAct));
        st_q[1] <= inc32(st_q[1], cmd_v_q && (code_q == CmdRef));
      end

      if (!ref_mon || ref_sent) gap_q <= '0;
      else if (gap_q != '1)     gap_q <= gap_q + 16'd1;
      if (ref_mon && !ref_sent && (gap_q == gap_lim - 16'd1)) starve_tgl_q <= !starve_tgl_q;
      if (clr)                                   gap_max_q <= '0;
      else if (ref_mon && (gap_q > gap_max_q))   gap_max_q <= gap_q;
    end
  end

  // ---------------------------------------------------------------- outputs
  assign cmd_ack_o        = ack_q;
  assign res_err_o        = res_err_q;
  assign res_ps_now_o     = ps_now;
  assign res_wps_now_o    = wps_now;
  assign res_st_o         = snap_q;
  assign ddr_up_o         = up_q;
  assign ddr_div_o        = div_q[2];
  assign rfifo_err_o      = rfe_q;
  assign cap_done_o       = capd_q;
  assign rd_late_o        = late_tgl_q;
  assign rd_extra_o       = extra_tgl_q;
  assign ref_starve_o     = starve_tgl_q;
  assign phy_rfifo_sync_o = sync_q;

  // wrdata_en / rddata_en (every WR / RD command carries / expects a burst),
  // cke / odt / reset_n of phases 1..3, DFI and burst bits beyond DqBits
  logic unused;
  assign unused = ^{phy_rd_bytes_i, dfi_q, slot};

  // =========================================================================
  // Simulation checks
  // =========================================================================
`ifndef SYNTHESIS
  if (DqBits != 8 && DqBits != 16) begin : g_bad_dq
    initial $fatal(1, "bow_ddr_dfi: DqBits must be 8 or 16");
  end
  if (ReadLatency < 4 || ReadLatency > 31) begin : g_bad_rl
    initial $fatal(1, "bow_ddr_dfi: ReadLatency must be 4..31");
  end
  if (CoreTRefi < 64 || CoreTRefi > 1023) begin : g_bad_refi
    initial $fatal(1, "bow_ddr_dfi: CoreTRefi must be 64..1023 (16-bit refresh monitor)");
  end

  always @(posedge clk_i) begin
    if (lock_q && edge1 && ph_q != 2'd1) begin   // (lock_q is 0 in reset)
      $error("bow_ddr_dfi: ddr_sys_clk / ddr_clk phase lost (edges not aligned?)");
    end
  end
`endif

endmodule
