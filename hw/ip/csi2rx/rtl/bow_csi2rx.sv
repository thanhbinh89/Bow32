// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI CSI-2 receiver, controller: the CSI-2 protocol layer behind a PPI
// (bow_ppi_pkg), with a RAW10 AXI4-Stream output (1 pixel/clock) for the ISP and the
// register file of the controller (bow_csi2rx_regs, CSI2RX at 0x000..0xBFF). bow_mipi_rx
// joins it with the digital D-PHY (bow_dphy_rx, its registers at 0xC00: step 4 of
// docs/ip/mipi_rx_arch.md, section 10); the PHY I/O contract is described there.
//
//   PPI ppi_hs_i (RxActiveHS, RxValidHS, RxDataHS, RxSyncHS of each lane, byte domain)
//     -> bow_csi2_lane_merge (two clock FIFO: byte clock -> csi_clk_i, with the end of burst
//        marker and the aligner events in order with the words)
//     -> bow_csi2_packet -> bow_csi2_unpack -> bow_fifo_ram (pixel FIFO) -> bow_csi2rx_out
//     -> m_axis, all on csi_clk_i
//   PPI ppi_lp_i, ppi_lp_clk_i (ErrControl, ErrControlClk) -> ERR_STATUS.LP and the lost
//     burst marking (lpl_*), on csi_clk_i
//   bow_csi2rx_regs (u_regs) -> enable_o, enable_clk_o (PPI Enable, EnableClk)
//
// Lanes = 1, 2 or 4 data lanes (CTRL.LANES / LANES4 select 1, 2 or 4 of
// them at run time): the byte domain takes 8 * Lanes bits per byte clock.
//
// m_axis_tuser_o[0] = first pixel of a frame (pixel 0 of its first line: a
// frame whose first line cannot be output is skipped, ERR_STATUS.SKIP),
// [1] = line error, with tlast: the line has a CRC or format error, was
// truncated or cut by a FIFO overflow, or an earlier line of the frame was
// lost (FIFO full, no pixel group, or its burst was lost: uncorrectable
// header, sync error, lane skew, a dropped packet cut short, packets after
// EXTRA, an HS entry refused at the LP level). Lines lost after the last
// output line of a frame cannot be flagged on the stream: FRAME_ERR (the
// error flags of each frame, latched at FE) holds them.
//
// PPI (v1.x, bow_ppi_pkg; step 6 of docs/ip/mipi_rx_arch.md, section 10): the byte domain
// runs on rx_byte_clk_hs_i (RxByteClkHS). The lp domain signals belong to the PHY's lp clock;
// ErrControl / ErrControlClk are 2 bit gray counters there (section 4.11 of the spec; v1: one
// cycle pulses of the controller's clock), sampled here on csi_clk_i (bow_ppi_err_rx, u_lperr):
// every change is at least one LP error. The PHY steps a counter at most once every 16 of its
// lp cycles, so nothing is lost while csi_clk_i >= lp_clk / 32: PpiLpClkHz (the PHY's lp clock
// frequency) has no default, every instantiation states it, and elaboration fails above 32 x
// PhyClkHz (bow_mipi_rx runs the D-PHY's lp_clk_i on the controller's clock itself).
// Since step 7 the controller works on its own continuous clock csi_clk_i (csi_clk of the
// spec, section 6.5; vid_clk on the FPGAs): only the lane merge runs on the byte clock, and a
// two clock FIFO right after it carries the words, the end of every burst and the aligner
// events in order to csi_clk_i. The FIFO is read one entry per csi_clk_i cycle and written at
// most one per byte clock: csi_clk_i must be at least the PHY's highest RxByteClkHS.
// PpiByteClkHz (that byte clock) has no default either, and elaboration fails above PhyClkHz
// (bow_csi2_lane_merge: the FIFO depth and this rule). The byte clock is needed during a
// burst and for two edges after the edge at which the last RxActiveHS falls (the end of the
// burst then is in the FIFO); everything else (packets, FS / FE, lines, pixels, interrupts,
// counters, FRAME_TIME / LINE_TIME, LOG) happens on csi_clk_i without it.
// Used here: RxActiveHS, RxValidHS, RxDataHS, RxSyncHS, ErrSotSyncHS of every lane,
// RxSkewCalHS of lane 0 (its rising edge: a level from the deskew recognition to the end of
// the burst in v1.x, a pulse in v1, both count once), ErrControl of every lane and
// ErrControlClk: the D-PHY masks them (a disabled lane, the clock lane with CLK_CONT), the
// controller takes their OR. The other PPI signals are not used yet. Since step 4 the
// controller has no PHY registers, no temporary band and no shared resets: irq_i is the
// D-PHY's interrupt (IRQ_STATUS[5]).
//
// Clock domains:
//   clk_i            CPU: registers, counters, LOG read (bow_csi2rx_regs)
//   csi_clk_i        the controller's continuous clock (step 7; vid_clk_i up to step 6, which
//                    in bow_mipi_rx it still is, also the D-PHY's lp clock): the read side of
//                    the lane merge's FIFO, packet layer, unpack, pixel FIFO, output, LOG
//                    capture, the PPI lp error counters' samples, the LP error release and
//                    the lost burst marking (lpl_*)
//   rx_byte_clk_hs_i byte clock = HS clock / 4, runs only while the clock lane is in HS
//                    (non-continuous clock: HS bursts only): the lane merge and the write side
//                    of its FIFO, the gate of the aligner events (stale_q); tied off without
//                    a PHY (HasPhy = 0), the lane merge then runs on csi_clk_i, without input
// Resets (asynchronous assertion, synchronous release):
//   crst_n      csi hard reset (csi_rst_ni & rst_ni): event toggles, LOG capture
//   brst_n      byte hard reset: the configuration of the lane merge
//   drst_n      byte datapath (lane merge, FIFO write side) and
//   cdrst_n     csi datapath (FIFO read side .. output): asserted while RX is off
//               (rx_on = CTRL.PHY_EN & RX_EN, a CPU flop), so a stop drops partial
//               packets, lines, the frame state and the FIFOs. drst_n is released by
//               the first byte clocks of a burst. It also gates the aligner events of
//               the PPI (ErrSotSyncHS, RxSkewCalHS: stale_q, below), since step 4 the
//               aligners are not reset with it.
// Clock domain crossings: configuration through one bow_sync per bit (quasi-static), the
// lane merge's words, ends of burst and aligner events through its two clock FIFO (gray
// pointers), events to the CPU through one bow_cdc_pulse per kind, the LOG commands as gray
// request / ack counters. See bow_csi2rx_regs for the register map.
//
// xsim 2025.2 (hw/fpga/common/dv) mis-simulates "q[l] <= 0; if (c) q[l] <= 1;"
// in a loop of an always_ff and indices from constant functions: new
// per-lane state here is computed in always_comb and registered whole.

module bow_csi2rx
  import bow_bus_pkg::*; import bow_csi2rx_pkg::*; import bow_ppi_pkg::*;
#(
  parameter int unsigned Lanes      = 2,            // physical data lanes: 1, 2 or 4
  parameter int unsigned PhyClkHz   = 200_000_000,  // csi_clk_i frequency (INFO[15:8])
  parameter int unsigned CpuClkHz   = 0,            // clk_i frequency (0: not checked)
  parameter bit          HasPhy     = 1'b1,         // INFO.PHY: a D-PHY is connected (0: no
                                                    // byte clock, the lane merge on csi_clk_i)
  parameter int unsigned FifoDepth  = 256,          // pixel FIFO entries (4 px each), power of 2
  parameter bit          DphyWin    = 1'b1,         // INFO[6]: the D-PHY's registers are at 0xC00
                                                    // (bow_mipi_rx; 0: a PHY of its own)
  parameter int unsigned PpiLpClkHz = 0,            // the PHY's lp clock (PPI lp domain), no
                                                    // default: at most 32 x PhyClkHz (above)
  parameter int unsigned PpiByteClkHz = 0           // the PHY's highest RxByteClkHS, no
                                                    // default: at most PhyClkHz (above)
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  bus_req_t              bus_req_i,
  output bus_rsp_t              bus_rsp_o,
  output logic                  irq_o,
  input  logic                  csi_clk_i,        // the controller's clock (vid_clk on the FPGAs)
  input  logic                  csi_rst_ni,
  output logic                  m_axis_tvalid_o,  // m_axis: csi_clk_i
  input  logic                  m_axis_tready_i,
  output logic [9:0]            m_axis_tdata_o,
  output logic [1:0]            m_axis_tuser_o,   // [0] start of frame, [1] line error (tlast)
  output logic                  m_axis_tlast_o,   // end of line

  // PPI (bow_ppi_pkg)
  input  logic                  rx_byte_clk_hs_i,     // RxByteClkHS
  input  ppi_hs_t [Lanes-1:0]   ppi_hs_i,             // byte domain
  input  ppi_lp_t [Lanes-1:0]   ppi_lp_i,             // lp domain (sampled on csi_clk_i)
  input  ppi_lp_clk_t           ppi_lp_clk_i,         // lp domain (sampled on csi_clk_i)
  output logic [Lanes-1:0]      enable_o,             // Enable[l] (CPU domain flops)
  output logic                  enable_clk_o,         // EnableClk (CPU domain flop)
  // D-PHY interrupt (bus clock domain level, |(IRQ_STATUS & IRQ_EN) of bow_dphy_rx_regs)
  input  logic                  irq_i
);

  if ((Lanes != 1) && (Lanes != 2) && (Lanes != 4)) begin : g_bad_lanes
    $error("bow_csi2rx: Lanes must be 1, 2 or 4, not %0d", Lanes);
  end

  // PPI v1.x: the lp domain errors are gray counters of the PHY's lp clock, sampled on
  // csi_clk_i (see above), which must be at least lp_clk / 32. As below, the initial copy
  // stops simulations that build with -Wno-fatal.
  if (PpiLpClkHz == 0) begin : g_no_lp_clk
    $fatal(1, "bow_csi2rx: PpiLpClkHz not set (the PHY's lp clock, at most 32 x csi_clk_i %0d Hz)",
           PhyClkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_csi2rx: PpiLpClkHz not set (the PHY's lp clock, at most 32 x csi_clk_i %0d Hz)",
                   PhyClkHz);
`endif
  end else if (64'(PpiLpClkHz) > 64'(PhyClkHz) * 64'd32) begin : g_bad_lp_clk
    $fatal(1, "bow_csi2rx: PPI lp clock %0d Hz > 32 x csi_clk_i %0d Hz (PPI error counters lap)",
           PpiLpClkHz, PhyClkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_csi2rx: PPI lp clock %0d Hz > 32 x csi_clk_i %0d Hz (PPI error counters lap)",
                   PpiLpClkHz, PhyClkHz);
`endif
  end

  // Step 7: the two clock FIFO of the lane merge is read one entry per csi_clk_i cycle and
  // written at most one per byte clock, so csi_clk_i must be at least the PHY's highest
  // RxByteClkHS (bow_csi2_lane_merge sizes the FIFO for that ratio)
  if (PpiByteClkHz == 0) begin : g_no_byte_clk
    $fatal(1, "bow_csi2rx: PpiByteClkHz not set (the PHY's highest byte clock, at most csi_clk_i %0d Hz)",
           PhyClkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_csi2rx: PpiByteClkHz not set (the PHY's highest byte clock, at most csi_clk_i %0d Hz)",
                   PhyClkHz);
`endif
  end else if (PpiByteClkHz > PhyClkHz) begin : g_bad_byte_clk
    $fatal(1, "bow_csi2rx: PPI byte clock %0d Hz > csi_clk_i %0d Hz (the lane merge FIFO overflows)",
           PpiByteClkHz, PhyClkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_csi2rx: PPI byte clock %0d Hz > csi_clk_i %0d Hz (the lane merge FIFO overflows)",
                   PpiByteClkHz, PhyClkHz);
`endif
  end

  localparam int unsigned NumPktEv = $bits(csi2_pkt_ev_t);
  localparam int unsigned NumBEv   = NumPktEv + 3 + Lanes;   // packet, skew, deskew, skip, sot per lane

  // The LP error release below (one pulse every 16 csi_clk_i cycles) needs 3 CPU
  // cycles per pulse: csi_clk_i <= 16/3 x clk_i. The elaboration
  // $fatal stops lint and synthesis, the initial copy stops simulations whose
  // build turns USERFATAL into a warning (-Wno-fatal).
  if ((CpuClkHz != 0) && (64'(PhyClkHz) * 64'd3 > 64'(CpuClkHz) * 64'd16)) begin : g_bad_clk
    $fatal(1, "bow_csi2rx: csi_clk_i %0d Hz > 16/3 x clk_i %0d Hz (LP event pulses merge)",
           PhyClkHz, CpuClkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_csi2rx: csi_clk_i %0d Hz > 16/3 x clk_i %0d Hz (LP event pulses merge)",
                   PhyClkHz, CpuClkHz);
`endif
  end

  // =========================================================================
  // Resets
  // =========================================================================
  logic rst_src_n, rx_on;
  logic crst_n, brst_n, drst_n, cdrst_n;

  assign rst_src_n = csi_rst_ni & rst_ni;

  bow_rst_sync u_crst (
    .clk_i  (csi_clk_i),
    .rst_ni (rst_src_n),
    .rst_no (crst_n)
  );

  bow_rst_sync u_brst (
    .clk_i  (rx_byte_clk_hs_i),
    .rst_ni (rst_src_n),
    .rst_no (brst_n)
  );

  bow_rst_sync u_drst (
    .clk_i  (rx_byte_clk_hs_i),
    .rst_ni (rst_src_n & rx_on),
    .rst_no (drst_n)
  );

  bow_rst_sync u_cdrst (
    .clk_i  (csi_clk_i),
    .rst_ni (rst_src_n & rx_on),
    .rst_no (cdrst_n)
  );

  // =========================================================================
  // CPU domain: registers
  // =========================================================================
  csi2_cfg_t             cfg;
  csi2_ev_t              ev_sys;
  logic [Lanes:0]        lane_en_sys;
  logic [3:0]            log_req_sys, log_ack, log_ack_sys;
  logic                  log_trig_sys, log_stop_sys;
  logic [5:0]            log_wptr, log_wptr_sys, ram_addr;
  logic                  log_re;
  logic [29:0]           log_rdata;
  logic [15:0]           frame_lines, frame_num, line_wc;
  logic [31:0]           frame_sum;
  logic [5:0]            line_dt;
  logic [1:0]            line_vc;
  logic                  in_frame, in_frame_sys;

  bow_csi2rx_regs #(
    .Lanes     (Lanes),
    .PhyClkHz  (PhyClkHz),
    .HasPhy    (HasPhy),
    .FifoDepth (FifoDepth),
    .DphyWin   (DphyWin)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .bus_req_i,
    .bus_rsp_o,
    .irq_o,
    .cfg_o         (cfg),
    .rx_on_o       (rx_on),
    .lane_en_o     (lane_en_sys),
    .log_req_o     (log_req_sys),
    .log_trig_fs_o (log_trig_sys),
    .log_stop_fe_o (log_stop_sys),
    .log_ack_i     (log_ack_sys),
    .log_wptr_i    (log_wptr_sys),
    .log_re_o      (log_re),
    .ram_addr_o    (ram_addr),
    .log_rdata_i   (log_rdata),
    .ev_i          (ev_sys),
    .frame_lines_i (frame_lines),
    .frame_num_i   (frame_num),
    .frame_sum_i   (frame_sum),
    .line_wc_i     (line_wc),
    .line_dt_i     (line_dt),
    .line_vc_i     (line_vc),
    .in_frame_i    (in_frame_sys),
    .irq_i
  );

  // =========================================================================
  // PPI
  // =========================================================================
  // Enable[l] / EnableClk: the lane enables of the register file (CPU domain flops; the
  // D-PHY synchronises them with the rest of its configuration)
  assign enable_clk_o = lane_en_sys[0];
  assign enable_o     = lane_en_sys[Lanes:1];

  // byte domain, per data lane
  logic [Lanes-1:0][7:0] al_data;
  logic [Lanes-1:0]      arm, al_valid, al_sot, al_sync_err, al_deskew;

  for (genvar l = 0; l < Lanes; l++) begin : g_ppi_hs
    assign arm[l]         = ppi_hs_i[l].rx_active_hs;
    assign al_valid[l]    = ppi_hs_i[l].rx_valid_hs;
    assign al_data[l]     = ppi_hs_i[l].rx_data_hs;
    assign al_sot[l]      = ppi_hs_i[l].rx_sync_hs;
    assign al_sync_err[l] = ppi_hs_i[l].err_sot_sync_hs;
    assign al_deskew[l]   = ppi_hs_i[l].rx_skew_cal_hs;
  end

  // lp domain: ErrControl of every data lane and ErrControlClk, gray counters as the D-PHY
  // sends them (masked there by the lane's synchronised Enable and, for the clock lane, by
  // CTRL.CLK_CONT), sampled on csi_clk_i (u_lperr: a change is at least one error). Their
  // OR sets ERR_STATUS.LP and marks a lost burst.
  logic [Lanes:0][1:0] lperr_gray;
  logic [Lanes:0]      lperr_ev;
  logic                lp_err;

  always_comb begin
    lperr_gray[0] = ppi_lp_clk_i.err_control;
    for (int unsigned l = 0; l < Lanes; l++) lperr_gray[1 + l] = ppi_lp_i[l].err_control;
  end

  bow_ppi_err_rx #(
    .N (Lanes + 1)
  ) u_lperr (
    .clk_i   (csi_clk_i),
    .rst_ni  (crst_n),
    .gray_i  (lperr_gray),
    .ev_o    (lperr_ev),
    .steps_o ()
  );

  assign lp_err = |lperr_ev;

  // LP errors -> CPU (ERR_STATUS.LP). Released at most every 16 csi_clk_i cycles, so the
  // pulse synchroniser never merges two pulses (needs csi_clk_i <= 16/3 x clk_i, checked with
  // CpuClkHz); real D-PHY sequences are much slower (T_LPX >= 50 ns per LP state).
  logic lp_pend_q, lp_fire, lp_sys;
  logic [3:0] vdiv_q;

  assign lp_fire = (vdiv_q == 4'd0) && lp_pend_q;

  always_ff @(posedge csi_clk_i or negedge crst_n) begin
    if (!crst_n) begin
      vdiv_q    <= '0;
      lp_pend_q <= 1'b0;
    end else begin
      vdiv_q    <= vdiv_q + 4'd1;
      lp_pend_q <= (lp_pend_q & ~lp_fire) | lp_err;
    end
  end

  bow_cdc_pulse u_cdc_lp (
    .src_clk_i   (csi_clk_i),
    .src_rst_ni  (crst_n),
    .src_pulse_i (lp_fire),
    .dst_clk_i   (clk_i),
    .dst_rst_ni  (rst_ni),
    .dst_pulse_o (lp_sys)
  );

  // =========================================================================
  // Byte domain: aligned bytes -> lane merge -> two clock FIFO
  // =========================================================================
  // The lane merge's configuration (CTRL.LANES, LANES4; quasi-static: changed only while
  // RX_EN = 0, when the datapath is in reset)
  logic mlanes2, mlanes4;

  bow_sync_bus #(
    .Width (2)
  ) u_sync_mcfg (
    .clk_i  (rx_byte_clk_hs_i),
    .rst_ni (brst_n),
    .d_i    ({cfg.lanes2, cfg.lanes4}),
    .q_o    ({mlanes2, mlanes4})
  );

  // The aligner events of the PPI (ErrSotSyncHS of every lane, RxSkewCalHS of lane 0) count
  // only for a burst the controller saw start: not while the datapath is in reset (drst_n:
  // RX off, asserted at once when CTRL clears RX_EN or PHY_EN, before RxActiveHS can fall),
  // and not for the burst a lane was already in (RxActiveHS high) when drst_n was released,
  // which the lane merge does not take either. Up to step 3 drst_n reset the aligners; since
  // step 4 they have the D-PHY's own reset and keep running while RX is off, and this gate
  // keeps CNT_SOT, ERR_STATUS.SOT, CNT_EXT[31:16] and IRQ_STATUS.ERR as they were: none for
  // bursts while RX_EN = 0 and PHY_EN = 1, none for the burst in progress when RX comes on,
  // no SoT error for a burst cut by a stop in its sync search. A stop ends the clock lane's
  // HS state too (the same Enable), so the byte clock usually stops before RxActiveHS of the
  // cut burst falls in this domain: it falls, and the sync error comes, with the first byte
  // clocks of the next burst, after a restart released drst_n (and cleared the counters),
  // on a lane that was still high at the release. stale_q[l]: set by drst_n, cleared one
  // cycle after RxActiveHS of lane l was seen low (ErrSotSyncHS of a burst comes in the
  // cycle after its RxActiveHS fell). A PHY event without RxActiveHS (a standard PHY,
  // section 5.5 of the spec) counts from the second cycle after the release.
  // RxSkewCalHS counts at its rising edge (dsk_last_q): one per deskew burst, a pulse (v1,
  // a standard PHY) or a level until the burst ends (the D-PHY of Bow32 since step 6).
  // Since step 7 the gated events go through the lane merge's FIFO in order with the words
  // and ends of burst (the lost burst marking of the packet layer needs that order), to the
  // counters and to the drop of the unpacker on csi_clk_i. The FIFO's write side is reset with
  // drst_n as well, so the events while RX is off stop there too; the gate is still what keeps
  // out the burst in progress when RX comes on (DV rxoff).
  logic [Lanes-1:0] arm_lo_q, stale_q, sot_ev;
  logic             dsk_ev, dsk_last_q;

  always_ff @(posedge rx_byte_clk_hs_i or negedge drst_n) begin
    if (!drst_n) begin
      arm_lo_q   <= '0;
      stale_q    <= '1;
      dsk_last_q <= 1'b0;
    end else begin
      arm_lo_q   <= ~arm;
      stale_q    <= stale_q & ~arm_lo_q;
      dsk_last_q <= al_deskew[0];
    end
  end

  assign sot_ev = al_sync_err & ~stale_q;
  assign dsk_ev = al_deskew[0] & ~dsk_last_q & ~stale_q[0];

  // The lane merge (byte domain) and its two clock FIFO: from here on csi_clk_i. Without a
  // PHY (HasPhy = 0: bow32_top's CsiPhy, the builds without a camera) the byte clock is tied
  // off, and the lane merge runs on csi_clk_i, reset with the csi datapath and without
  // input, so that no flop is left on a constant clock: on the byte clock, the DONT_TOUCH
  // gray write pointer of its FIFO (bow_fifo_async) kept the write side's pointer flops and
  // drst_n there, and check_timing found a constant clock at their pins (the Huins RAM card
  // build; review of step 7 of docs/ip/mipi_rx_arch.md).
  logic                  lm_valid, lm_sop, lm_eob, lm_skew, lm_dsk;
  logic [Lanes-1:0][7:0] lm_data;
  logic [Lanes-1:0]      lm_sot;
  logic                  lm_clk, lm_rst_n;

  if (HasPhy) begin : g_merge_byte_clk
    assign lm_clk   = rx_byte_clk_hs_i;
    assign lm_rst_n = drst_n;
  end else begin : g_merge_csi_clk
    assign lm_clk   = csi_clk_i;
    assign lm_rst_n = cdrst_n;
  end

  bow_csi2_lane_merge #(
    .Lanes (Lanes)
  ) u_lane_merge (
    .clk_i      (lm_clk),
    .rst_ni     (lm_rst_n),
    .lanes2_i   (HasPhy && mlanes2),
    .lanes4_i   (HasPhy && mlanes4),
    .arm_i      (HasPhy ? arm : '0),
    .valid_i    (HasPhy ? al_valid : '0),
    .data_i     (HasPhy ? al_data : '0),
    .sot_i      (HasPhy ? al_sot : '0),
    .ev_sot_i   (HasPhy ? sot_ev : '0),
    .ev_dsk_i   (HasPhy && dsk_ev),
    .csi_clk_i,
    .csi_rst_ni (cdrst_n),
    .valid_o    (lm_valid),
    .data_o     (lm_data),
    .sop_o      (lm_sop),
    .eob_o      (lm_eob),
    .ev_skew_o  (lm_skew),
    .ev_sot_o   (lm_sot),
    .ev_dsk_o   (lm_dsk)
  );

  // =========================================================================
  // csi_clk_i: packets -> pixel groups -> pixel FIFO -> m_axis
  // =========================================================================
  // The packet layer's configuration (quasi-static, as above)
  logic       lanes2, lanes4, vc_any;
  logic [1:0] vc;
  logic [5:0] dt;
  logic [7:0] extra;
  logic [2:0] lm_nbytes;

  bow_sync_bus #(
    .Width (19)
  ) u_sync_ccfg (
    .clk_i  (csi_clk_i),
    .rst_ni (crst_n),
    .d_i    ({cfg.lanes2, cfg.lanes4, cfg.vc_any, cfg.vc, cfg.dt, cfg.extra}),
    .q_o    ({lanes2, lanes4, vc_any, vc, dt, extra})
  );

  // bytes per word of the lane merge: the active lanes (constant while RX is on)
  assign lm_nbytes = active_lanes(Lanes, lanes2, lanes4);

  csi2_pkt_ev_t          pkt_ev;
  logic                  px_sol, px_raw10, px_eol, px_err, px_ovf, fs, fe;
  logic [Lanes-1:0]      px_valid;
  logic [Lanes-1:0][7:0] px_data;
  logic                  log_we, log_fs, log_fe;
  logic [29:0]           log_entry;

  bow_csi2_packet #(
    .Bytes (Lanes)
  ) u_packet (
    .clk_i         (csi_clk_i),
    .rst_ni        (cdrst_n),
    .vc_i          (vc),
    .vc_any_i      (vc_any),
    .dt_i          (dt),
    .extra_i       (extra),
    .valid_i       (lm_valid),
    .data_i        (lm_data),
    .nbytes_i      (lm_nbytes),
    .sop_i         (lm_sop),
    .eob_i         (lm_eob),
    .px_sol_o      (px_sol),
    .px_raw10_o    (px_raw10),
    .px_valid_o    (px_valid),
    .px_data_o     (px_data),
    .px_eol_o      (px_eol),
    .px_err_o      (px_err),
    .px_ovf_i      (px_ovf),
    .fs_o          (fs),
    .fe_o          (fe),
    .in_frame_o    (in_frame),
    .frame_lines_o (frame_lines),
    .frame_num_o   (frame_num),
    .line_wc_o     (line_wc),
    .line_dt_o     (line_dt),
    .line_vc_o     (line_vc),
    .log_we_o      (log_we),
    .log_entry_o   (log_entry),
    .log_fs_o      (log_fs),
    .log_fe_o      (log_fe),
    .ev_o          (pkt_ev)
  );

  logic              grp_push, fifo_full, fifo_afull, fifo_empty, fifo_pop, px_drop, px_skip;
  logic [GroupW-1:0] grp_wdata, grp_rdata;
  logic              lpl_ev, lpl_pend_q;

  // HS entries refused at the LP level (lpl_ev: an LP error that reached the controller)
  // lose a burst that the packet layer never sees: counted as a lost burst at the next
  // packet start (drop of the unpacker, only inside a frame). Since step 7 the packet layer
  // runs on the clock that samples the LP errors: no request / acknowledge into the byte
  // domain any more; the flag waits here for the next sop out of the lane merge's FIFO
  // (errors while one is pending merge into it, none while RX is off).
  assign lpl_ev = lp_err;

  always_ff @(posedge csi_clk_i or negedge cdrst_n) begin
    if (!cdrst_n)    lpl_pend_q <= 1'b0;
    else if (lpl_ev) lpl_pend_q <= 1'b1;
    else if (lm_sop) lpl_pend_q <= 1'b0;
  end

  // a burst of the frame was lost before the unpacker: the next line gets
  // tuser[1], or the frame is skipped if its first line has not started.
  // A truncation that did not end an accepted line (cut in the header, or a
  // dropped packet cut short) may have been a line with a corrupted header.
  assign px_drop = in_frame && (pkt_ev.ecc_err || pkt_ev.extra || lm_skew || (|lm_sot) ||
                                (pkt_ev.trunc && !px_eol) || (lpl_pend_q && lm_sop));

  bow_csi2_unpack #(
    .Bytes (Lanes)
  ) u_unpack (
    .clk_i       (csi_clk_i),
    .rst_ni      (cdrst_n),
    .sol_i       (px_sol),
    .raw10_i     (px_raw10),
    .valid_i     (px_valid),
    .data_i      (px_data),
    .eol_i       (px_eol),
    .err_i       (px_err),
    .fs_i        (fs),
    .fe_i        (fe),
    .drop_i      (px_drop),
    .push_o      (grp_push),
    .group_o     (grp_wdata),
    .full_i      (fifo_full),
    .afull_i     (fifo_afull),
    .ovf_o       (px_ovf),
    .skip_o      (px_skip),
    .frame_sum_o (frame_sum)
  );

  // pixel FIFO: the bursts' rate against the output's 1 pixel per clock (step 7: one clock,
  // the byte -> video crossing of steps 1-6 is the lane merge's FIFO now)
  bow_fifo_ram #(
    .Width (GroupW),
    .Depth (FifoDepth)
  ) u_fifo (
    .clk_i   (csi_clk_i),
    .rst_ni  (cdrst_n),
    .push_i  (grp_push),
    .wdata_i (grp_wdata),
    .full_o  (fifo_full),
    .afull_o (fifo_afull),
    .pop_i   (fifo_pop),
    .rdata_o (grp_rdata),
    .empty_o (fifo_empty),
    .level_o ()
  );

  bow_csi2rx_out u_out (
    .clk_i    (csi_clk_i),
    .rst_ni   (cdrst_n),
    .empty_i  (fifo_empty),
    .group_i  (grp_rdata),
    .pop_o    (fifo_pop),
    .tvalid_o (m_axis_tvalid_o),
    .tready_i (m_axis_tready_i),
    .tdata_o  (m_axis_tdata_o),
    .tuser_o  (m_axis_tuser_o),
    .tlast_o  (m_axis_tlast_o)
  );

  bow_sync u_sync_in_frame (
    .clk_i,
    .rst_ni,
    .d_i (in_frame),
    .q_o (in_frame_sys)
  );

  // Events -> CPU. Each kind comes at most once per packet or burst; a new burst needs the
  // LP-11 -> LP-01 -> LP-00 -> SETTLE sequence of the lane FSMs (>= 370 ns with D-PHY
  // timing), and the lane merge's FIFO keeps that distance (it is read as fast as it is
  // written), far more than the 3 CPU cycles a pulse synchroniser needs. The data that goes
  // with ev fe / line is held in the packet layer and unpacker until the next event of the
  // kind. Deskew bursts are counted on lane 0 (the other lanes then deskew too, or the burst
  // is a skew or sync error).
  logic [NumBEv-1:0] bev, bev_sys;

  assign bev = {lm_sot, px_skip, lm_dsk, lm_skew, pkt_ev};

  for (genvar i = 0; i < NumBEv; i++) begin : g_cdc_bev
    bow_cdc_pulse u_cdc (
      .src_clk_i   (csi_clk_i),
      .src_rst_ni  (crst_n),
      .src_pulse_i (bev[i]),
      .dst_clk_i   (clk_i),
      .dst_rst_ni  (rst_ni),
      .dst_pulse_o (bev_sys[i])
    );
  end

  always_comb begin
    ev_sys                 = '0;
    ev_sys.pl              = bev_sys[NumPktEv-1:0];
    ev_sys.skew            = bev_sys[NumPktEv];
    ev_sys.deskew          = bev_sys[NumPktEv + 1];
    ev_sys.skip            = bev_sys[NumPktEv + 2];
    ev_sys.sot[Lanes-1:0]  = bev_sys[NumBEv-1 -: Lanes];
    ev_sys.lp              = lp_sys;
  end

  // =========================================================================
  // csi_clk_i: LOG capture
  // =========================================================================
  // Commands in (gray request counter + mode bits), acknowledges (gray) and the LOG write
  // pointer (quasi-static) out. (RAW: in the D-PHY since step 4, bow_dphy_raw.) Since step 7
  // the capture runs on csi_clk_i: an ARM is taken at once and DONE comes without a byte
  // clock.
  logic [3:0] log_req;
  logic       log_trig, log_stop;

  bow_sync_bus #(
    .Width (4)
  ) u_sync_log_req (
    .clk_i  (csi_clk_i),
    .rst_ni (crst_n),
    .d_i    (log_req_sys),
    .q_o    (log_req)
  );

  bow_sync_bus #(
    .Width (2)
  ) u_sync_mode (
    .clk_i  (csi_clk_i),
    .rst_ni (crst_n),
    .d_i    ({log_trig_sys, log_stop_sys}),
    .q_o    ({log_trig, log_stop})
  );

  bow_csi2_capture u_capture (
    .clk_i         (csi_clk_i),
    .rst_ni        (crst_n),
    .log_req_i     (log_req),
    .log_trig_fs_i (log_trig),
    .log_stop_fe_i (log_stop),
    .log_ack_o     (log_ack),
    .log_wptr_o    (log_wptr),
    .log_we_i      (log_we),
    .log_entry_i   (log_entry),
    .log_fs_i      (log_fs),
    .log_fe_i      (log_fe),
    .rclk_i        (clk_i),
    .log_re_i      (log_re),
    .raddr_i       (ram_addr),
    .log_rdata_o   (log_rdata)
  );

  bow_sync_bus #(
    .Width (4)
  ) u_sync_log_ack (
    .clk_i,
    .rst_ni,
    .d_i (log_ack),
    .q_o (log_ack_sys)
  );

  bow_sync_bus #(
    .Width (6)
  ) u_sync_log_wptr (
    .clk_i,
    .rst_ni,
    .d_i (log_wptr),
    .q_o (log_wptr_sys)
  );

  // PPI signals not used (yet): ErrSotHS (v2), RxSkewCalHS of lanes 1.. (deskew bursts are
  // counted on lane 0), Stopstate*, RxClkActiveHS, the ULPS and escape signals (the D-PHY's
  // registers report them)
  logic unused, unused_ppi;

  always_comb begin
    unused_ppi = ^{ppi_lp_clk_i.stopstate, ppi_lp_clk_i.rx_clk_active_hs,
                   ppi_lp_clk_i.ulps_active_not, ppi_lp_clk_i.rx_ulps_clk_not};
    for (int unsigned l = 0; l < Lanes; l++) begin
      unused_ppi ^= ^{ppi_hs_i[l].err_sot_hs, ppi_lp_i[l].stopstate, ppi_lp_i[l].ulps_active_not,
                      ppi_lp_i[l].rx_ulps_esc, ppi_lp_i[l].err_esc, ppi_lp_i[l].err_sync_esc};
    end
  end

  assign unused = ^{cfg.phy_en, cfg.rx_en, al_deskew, unused_ppi};

endmodule
