// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 MIPI CSI-2 controller (bow_csi2rx) with flat PPI ports, for a standard D-PHY (a
// vendor's PHY with the PPI of PG202 / PG435 / Lattice) in place of the D-PHY of Bow32
// (docs/ip/mipi_rx_arch.md, section 5.5: the PPI profile of the controller). Not part of the
// Bow32 SoC (bow_mipi_rx joins the controller with bow_dphy_rx) and not in csi2rx.f: a build
// that uses it adds this file after csi2rx.f. Checked in simulation by
// hw/ip/csi2rx/dv/tb_csi2rx_ppi.sv with bow_ppi_bfm in the timing of a standard PHY.
//
// Ports: those of bow_csi2rx without the PPI structures and the D-PHY interrupt, plus the
// receive side signals of the public PPI under their names in snake case, 8 bits per lane:
//   byte domain (rx_byte_clk_hs_i)  rx_data_hs_i, rx_valid_hs_i, rx_active_hs_i, rx_sync_hs_i,
//                                   rx_skew_cal_hs_i, err_sot_hs_i, err_sot_sync_hs_i
//   lp domain (lp_clk_i: the PHY's  stopstate_i, ulps_active_not_i, rx_ulps_esc_i,
//   clock of these signals)         err_control_i, err_esc_i, err_sync_esc_i; clock lane:
//                                   stopstate_clk_i, rx_clk_active_hs_i, ulps_active_not_clk_i,
//                                   rx_ulps_clk_not_i
//   enable_o, enable_clk_o          Enable[l], EnableClk (CPU domain flops of the controller)
//
// What the wrapper adds (needs of the controller that a standard PHY does not meet):
//   * Byte domain: every signal one byte clock later, except that RxActiveHS rises at once
//     and falls 2 byte clocks later. The lane merge of the controller starts a burst at the
//     rise of RxActiveHS and takes a lane's bytes from the next cycle on, and it takes the
//     last word one cycle after its last byte, while RxActiveHS is still high: a PHY that
//     raises RxActiveHS together with RxSyncHS (PG202, PG435) would lose the sync and so the
//     burst, one that drops RxActiveHS right after its last byte the last word. Costs: the
//     PHY must keep RxActiveHS low >= 3 byte clocks between bursts, and its byte clock must
//     run 2 cycles longer after the fall than the controller needs (step 7: 4 edges after
//     the edge at which the PHY drops its last RxActiveHS, 2 of them for the controller).
//   * RxSkewCalHS: one byte clock later like the rest (since step 6 the controller counts
//     its rising edge, so a level as in PG202 counts once; up to step 5 the wrapper made a
//     one cycle pulse of the edge).
//   * ErrControl: the one cycle pulses of lp_clk_i step a 2 bit gray counter per lane in
//     lp_clk_i (bow_ppi_err_tx, at most one step every 16 lp cycles: pulses closer together
//     are merged), the form of the Bow32 PPI since step 6 (section 4.11 of the spec), which
//     the controller samples on csi_clk_i: LpClkHz is at most 32 x PhyClkHz (up to step 5 a
//     pulse synchroniser per lane made pulses of its clock of them). The controller takes their
//     OR for the lost burst marking: like the D-PHY of Bow32 since step 4, the PHY reports
//     errors of the lanes it has enabled only.
// Tied off (no counterpart on the PPI of a standard PHY) and what that means:
//   ErrControlClk 0      LP errors of the clock lane do not mark lost bursts (nor set
//                        ERR_STATUS.LP)
//   irq_i 0              IRQ_STATUS[5] reads 0: the PHY's interrupt is its own
//   ErrEsc, ErrSyncEsc   not used by the v1 controller (escape mode), the ports only
// The PHY registers (LP / HS state, counters of HS entries and LP errors, byte clock meter,
// delays, RAW) are the PHY's own; INFO[6] reads 0 (no D-PHY of Bow32 at 0xC00). Resets: the
// byte and lp clock domains of this wrapper synchronise rst_ni & csi_rst_ni on their own.
// Clocks: csi_clk_i is the controller's continuous clock (step 7 of the spec), at least the
// PHY's highest byte clock ByteClkHz (no default: every build states it; checked at
// elaboration).

module bow_csi2rx_ppi_flat import bow_bus_pkg::*; import bow_ppi_pkg::*; #(
  parameter int unsigned Lanes     = 2,            // data lanes: 1, 2 or 4
  parameter int unsigned PhyClkHz  = 200_000_000,  // csi_clk_i frequency (INFO)
  parameter int unsigned CpuClkHz  = 0,            // clk_i frequency (0: not checked)
  parameter int unsigned FifoDepth = 256,          // pixel FIFO entries (4 px each), power of 2
  parameter int unsigned LpClkHz   = PhyClkHz,     // lp_clk_i frequency (<= 32 x PhyClkHz)
  parameter int unsigned ByteClkHz = 0             // the PHY's highest rx_byte_clk_hs_i, no
                                                   // default (<= PhyClkHz)
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  bus_req_t              bus_req_i,
  output bus_rsp_t              bus_rsp_o,
  output logic                  irq_o,
  input  logic                  csi_clk_i,          // the controller's clock
  input  logic                  csi_rst_ni,
  output logic                  m_axis_tvalid_o,
  input  logic                  m_axis_tready_i,
  output logic [9:0]            m_axis_tdata_o,
  output logic [1:0]            m_axis_tuser_o,     // [0] start of frame, [1] line error (tlast)
  output logic                  m_axis_tlast_o,     // end of line

  // PPI, byte domain
  input  logic                  rx_byte_clk_hs_i,   // RxByteClkHS
  input  logic [Lanes-1:0][7:0] rx_data_hs_i,       // RxDataHS
  input  logic [Lanes-1:0]      rx_valid_hs_i,      // RxValidHS
  input  logic [Lanes-1:0]      rx_active_hs_i,     // RxActiveHS
  input  logic [Lanes-1:0]      rx_sync_hs_i,       // RxSyncHS
  input  logic [Lanes-1:0]      rx_skew_cal_hs_i,   // RxSkewCalHS (pulse or level)
  input  logic [Lanes-1:0]      err_sot_hs_i,       // ErrSotHS
  input  logic [Lanes-1:0]      err_sot_sync_hs_i,  // ErrSotSyncHS
  // PPI, lp domain of the PHY
  input  logic                  lp_clk_i,           // clock of the PHY's lp domain signals
  input  logic [Lanes-1:0]      stopstate_i,        // Stopstate
  input  logic [Lanes-1:0]      ulps_active_not_i,  // UlpsActiveNot
  input  logic [Lanes-1:0]      rx_ulps_esc_i,      // RxUlpsEsc
  input  logic [Lanes-1:0]      err_control_i,      // ErrControl (one cycle pulses of lp_clk_i)
  input  logic [Lanes-1:0]      err_esc_i,          // ErrEsc (not used, v1)
  input  logic [Lanes-1:0]      err_sync_esc_i,     // ErrSyncEsc (not used, v1)
  input  logic                  stopstate_clk_i,    // StopstateClk
  input  logic                  rx_clk_active_hs_i, // RxClkActiveHS
  input  logic                  ulps_active_not_clk_i,  // UlpsActiveNotClk
  input  logic                  rx_ulps_clk_not_i,  // RxUlpsClkNot
  output logic [Lanes-1:0]      enable_o,           // Enable (CPU domain flops)
  output logic                  enable_clk_o        // EnableClk (CPU domain flop)
);

  // the controller checks the byte clock against csi_clk_i (PpiByteClkHz); this message names
  // the parameter of the wrapper (the initial copy stops simulations built with -Wno-fatal)
  if (ByteClkHz == 0) begin : g_no_byte_clk
    $fatal(1, "bow_csi2rx_ppi_flat: ByteClkHz not set (the PHY's highest byte clock, at most csi_clk_i %0d Hz)",
           PhyClkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_csi2rx_ppi_flat: ByteClkHz not set (the PHY's highest byte clock, at most csi_clk_i %0d Hz)",
                   PhyClkHz);
`endif
  end

  // ---------------------------------------------------------------- resets
  logic brst_n;

  bow_rst_sync u_brst (
    .clk_i  (rx_byte_clk_hs_i),
    .rst_ni (rst_ni & csi_rst_ni),
    .rst_no (brst_n)
  );

  // ---------------------------------------------------------------- byte domain
  // RxActiveHS: rises at once, falls 2 byte clocks late; the rest one byte clock late
  ppi_hs_t [Lanes-1:0]   ppi_hs;
  logic [Lanes-1:0]      act_q, act_q2, valid_q, sync_q, skew_q, sot_q, sot_sync_q;
  logic [Lanes-1:0][7:0] data_q;

  always_ff @(posedge rx_byte_clk_hs_i or negedge brst_n) begin
    if (!brst_n) begin
      act_q       <= '0;
      act_q2      <= '0;
      valid_q     <= '0;
      data_q      <= '0;
      sync_q      <= '0;
      skew_q      <= '0;
      sot_q       <= '0;
      sot_sync_q  <= '0;
    end else begin
      act_q       <= rx_active_hs_i;
      act_q2      <= act_q;
      valid_q     <= rx_valid_hs_i;
      data_q      <= rx_data_hs_i;
      sync_q      <= rx_sync_hs_i;
      skew_q      <= rx_skew_cal_hs_i;
      sot_q       <= err_sot_hs_i;
      sot_sync_q  <= err_sot_sync_hs_i;
    end
  end

  for (genvar l = 0; l < Lanes; l++) begin : g_ppi_hs
    assign ppi_hs[l].rx_active_hs    = rx_active_hs_i[l] | act_q[l] | act_q2[l];
    assign ppi_hs[l].rx_valid_hs     = valid_q[l];
    assign ppi_hs[l].rx_data_hs      = data_q[l];
    assign ppi_hs[l].rx_sync_hs      = sync_q[l];
    assign ppi_hs[l].rx_skew_cal_hs  = skew_q[l];
    assign ppi_hs[l].err_sot_hs      = sot_q[l];
    assign ppi_hs[l].err_sot_sync_hs = sot_sync_q[l];
  end

  // ---------------------------------------------------------------- lp domain
  // ErrControl: the pulses of the PHY's lp clock as a gray counter per lane (the PHY only
  // reports errors of the lanes it has enabled)
  logic                  lprst_n;
  logic [Lanes-1:0][1:0] err_gray;

  bow_rst_sync u_lp_rst (
    .clk_i  (lp_clk_i),
    .rst_ni (rst_ni & csi_rst_ni),
    .rst_no (lprst_n)
  );

  bow_ppi_err_tx #(
    .N (Lanes)
  ) u_err (
    .clk_i  (lp_clk_i),
    .rst_ni (lprst_n),
    .ev_i   (err_control_i),
    .en_i   ('1),
    .gray_o (err_gray)
  );

  ppi_lp_t [Lanes-1:0] ppi_lp;
  ppi_lp_clk_t         ppi_lp_clk;

  for (genvar l = 0; l < Lanes; l++) begin : g_ppi_lp
    assign ppi_lp[l].stopstate       = stopstate_i[l];
    assign ppi_lp[l].ulps_active_not = ulps_active_not_i[l];
    assign ppi_lp[l].rx_ulps_esc     = rx_ulps_esc_i[l];
    assign ppi_lp[l].err_control     = err_gray[l];
    assign ppi_lp[l].err_esc         = 2'b00;
    assign ppi_lp[l].err_sync_esc    = 2'b00;
  end

  assign ppi_lp_clk.stopstate        = stopstate_clk_i;
  assign ppi_lp_clk.rx_clk_active_hs = rx_clk_active_hs_i;
  assign ppi_lp_clk.ulps_active_not  = ulps_active_not_clk_i;
  assign ppi_lp_clk.rx_ulps_clk_not  = rx_ulps_clk_not_i;
  assign ppi_lp_clk.err_control      = 2'b00;          // no ErrControlClk on a standard PPI

  // ---------------------------------------------------------------- controller
  bow_csi2rx #(
    .Lanes        (Lanes),
    .PhyClkHz     (PhyClkHz),
    .CpuClkHz     (CpuClkHz),
    .HasPhy       (1'b1),
    .FifoDepth    (FifoDepth),
    .DphyWin      (1'b0),                      // the PHY's registers are its own
    .PpiLpClkHz   (LpClkHz),                   // the gray counters' clock (above)
    .PpiByteClkHz (ByteClkHz)
  ) u_csi2rx (
    .clk_i,
    .rst_ni,
    .bus_req_i,
    .bus_rsp_o,
    .irq_o,
    .csi_clk_i,
    .csi_rst_ni,
    .m_axis_tvalid_o,
    .m_axis_tready_i,
    .m_axis_tdata_o,
    .m_axis_tuser_o,
    .m_axis_tlast_o,
    .rx_byte_clk_hs_i,
    .ppi_hs_i            (ppi_hs),
    .ppi_lp_i            (ppi_lp),
    .ppi_lp_clk_i        (ppi_lp_clk),
    .enable_o,
    .enable_clk_o,
    .irq_i               (1'b0)                // no D-PHY of Bow32
  );

  logic unused;
  assign unused = ^{err_esc_i, err_sync_esc_i};

endmodule
