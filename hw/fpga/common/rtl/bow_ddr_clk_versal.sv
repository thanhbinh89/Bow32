// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Clocks of Bow32 and its DDR2/DDR3 memory system (bow_ddr: LiteDRAM
// controller + Bow32 PHY) on AMD Versal: two MMCME5 fed by one clock input
// (single ended or differential). The Versal twin of bow_ddr_clk_xusp, with
// the same ports, outputs and phase contract.
//
//   clk_pad_i -IBUF(DS)-BUFG-+-> MMCM_A CLKOUT0 /SysDivide -BUFG-> clk_sys_o      SoC (clk_i)
//                            |          CLKOUT1 /DdrDivide -BUFG-> ddr_clk_o      DFI adapter, PHY,
//                            |                                                    CK, commands, PSCLK
//                            |          CLKOUT3 /(4 DdrDivide) -BUFG-> ddr_sys_clk_o  LiteDRAM
//                            |                                                    controller (CK / 4)
//                            |          CLKOUT2 /DdrDivide, fine PS -BUFG-> ddr_wclk_o    DQS ODDR
//                            |          CLKOUT4 /DdrDivide, 90 deg + fine PS -BUFG-> ddr_wclk90_o
//                            |                                                    DQ / DM ODDR
//                            +-> MMCM_B CLKOUT0 /DdrDivide, fine PS -BUFG-> ddr_rd_clk_o  IDDR capture
//
//   VCO = 1000 / ClkInPeriodNs * VcoMult / InDivide MHz (MMCME5: 2160..4320
//   MHz, phase detector 10..550 MHz). Huins VP1902 defaults: 200 MHz * 16 / 1
//   = 3200 MHz (or 100 MHz * 32), clk_sys /64 = 50 MHz, DDR clocks /24 =
//   133.333 MHz (tCK 7.5 ns), controller clock /96 = 33.333 MHz: the MPS4
//   frequencies.
//
// Why two MMCMs (bow_ddr_clk_xusp needs three):
//   * MMCME5 selects the dynamic fine phase shift per output (CLKOUTn_PHASE_CTRL
//     = 2'b10), and a fine-PS output may keep a static phase as well
//     (UltraScale+: DRC AVAL-152 forbids it). ddr_wclk_o (0 deg) and
//     ddr_wclk90_o (+90 deg) are two fine-PS outputs of MMCM_A: they move
//     together, a quarter period apart, while clk_sys_o, ddr_clk_o and
//     ddr_sys_clk_o (no fine PS) never move. One VCO and one counter start for
//     all of them: at write phase 0 ddr_wclk_o has the edges of ddr_clk_o and
//     ddr_wclk90_o lags by T/4 (the static 90 deg; Vivado models it as clock
//     latency, which keeps the default edge pairs of the ddr_clk -> wclk90
//     paths right).
//   * ddr_sys_clk_o (CK / 4) is another output of MMCM_A at phase 0: every
//     rising edge of it is a rising edge of ddr_clk_o (as in bow_ddr_clk_xusp,
//     the DFI between LiteDRAM and the adapter is timed as synchronous).
//   * The read capture clock is calibrated over a full period, so MMCM_B (its
//     own fine PS, independent of the write phase) may lock at any phase.
//
// Dynamic fine phase shift (both ports in the ddr_clk_o domain, PSCLK =
// ddr_clk_o inside this module):
//   * one step = VCO period / 32 (9.77 ps at 3200 MHz), PsSteps = 32 *
//     DdrDivide steps per DDR clock period (768); the phase wraps;
//   * *_en_i high for one ddr_clk_o cycle with *_inc_i valid (1 = later,
//     0 = earlier), then wait for *_done_o before the next step. MMCME5
//     answers 12..13 PSCLK cycles after PSEN (aligned to the phase detector)
//     and, in the AMD simulation model, repeats PSDONE every 32 PSCLK cycles
//     until the next PSEN: bow_mmcm_ps counts a PSDONE only in its wait state
//     after a PSEN, and its timeout (64) is above the repeat period;
//   * use the ports only while locked_ddr_o = 1 (MMCME5 ignores PSEN before
//     its own lock);
//   * ps_* moves ddr_rd_clk_o only; wps_* moves ddr_wclk_o and ddr_wclk90_o
//     together; clk_sys_o, ddr_clk_o and ddr_sys_clk_o never move;
//   * rst_i returns both phases to 0, and so does a loss of lock of either
//     MMCM (both are reset then, see "Lock-loss reset"): locked_ddr_o falls
//     whenever the phases return to 0.
//
// locked_sys_o (MMCM_A) is enough for the SoC clock; locked_ddr_o needs both
// MMCMs. Both are asynchronous (bow_rst_sync / bow_rstmgr behind them).
// The board XDC names the generated clocks after the MMCM output pins (Huins:
// clk_sys = u_mmcm_a/CLKOUT0, ddr_clk = CLKOUT1, ddr_wclk = CLKOUT2, ddr_sys =
// CLKOUT3, ddr_wclk90 = CLKOUT4, ddr_rd_clk = u_mmcm_b/CLKOUT0).
//
// Input clock: DiffIn = 1 takes a differential pair (IBUFDS, clk_pad_n_i),
// DiffIn = 0 a single ended pin (IBUF, clk_pad_n_i unused). The IO standard
// and termination are set in the board XDC. clk_ibuf_o is the input after its
// buffer, not a global clock: other clock modules (bow_hyperram_clk_versal)
// add their own BUFG.

module bow_ddr_clk_versal #(
  parameter real         ClkInPeriodNs = 5.0,   // CLKIN1_PERIOD of both MMCMs
  parameter bit          DiffIn        = 1'b1,  // differential input pair (IBUFDS)
  parameter int unsigned InDivide      = 1,     // DIVCLK_DIVIDE
  parameter int unsigned VcoMult       = 16,    // CLKFBOUT_MULT
  parameter int unsigned SysDivide     = 64,    // clk_sys_o = VCO / SysDivide
  parameter int unsigned DdrDivide     = 24     // DDR clocks = VCO / DdrDivide (4 * DdrDivide <= 511)
) (
  input  wire  clk_pad_i,      // clock input (P of the pair when DiffIn)
  input  wire  clk_pad_n_i,    // N of the pair (DiffIn), else unused
  input  logic rst_i,          // MMCM reset, active high, asynchronous

  output logic clk_sys_o,
  output logic ddr_clk_o,
  output logic ddr_sys_clk_o,  // ddr_clk_o / 4, rising edges on ddr_clk_o rising edges
  output logic ddr_wclk_o,
  output logic ddr_wclk90_o,
  output logic ddr_rd_clk_o,
  output logic clk_ibuf_o,     // the input after its IBUF(DS) (not buffered)
  output logic locked_sys_o,   // MMCM_A locked: clk_sys_o, ddr_clk_o, ddr_sys_clk_o, write clocks
  output logic locked_ddr_o,   // MMCM_A and MMCM_B locked

  // read capture phase (MMCM_B), ddr_clk_o domain
  input  logic ps_en_i,
  input  logic ps_inc_i,
  output logic ps_done_o,
  // write phase (MMCM_A CLKOUT2 / CLKOUT4), ddr_clk_o domain
  input  logic wps_en_i,
  input  logic wps_inc_i,
  output logic wps_done_o
);

  // controller clock: DFI 1:4 of LiteDRAM
  localparam int unsigned DdrSysDivide = 4 * DdrDivide;

`ifndef SYNTHESIS
  localparam real VcoMhz = 1000.0 / ClkInPeriodNs * real'(VcoMult) / real'(InDivide);
  localparam real PfdMhz = 1000.0 / ClkInPeriodNs / real'(InDivide);
  initial begin
    if (VcoMhz < 2160.0 || VcoMhz > 4320.0) begin
      $error("bow_ddr_clk_versal: VCO %f MHz outside 2160..4320 MHz", VcoMhz);
    end
    if (PfdMhz < 10.0 || PfdMhz > 550.0) begin
      $error("bow_ddr_clk_versal: phase detector %f MHz outside 10..550 MHz", PfdMhz);
    end
    if (DdrSysDivide > 511 || SysDivide > 511 || DdrDivide < 2 || SysDivide < 2) begin
      $error("bow_ddr_clk_versal: output divide out of 2..511 (Sys %0d, Ddr %0d)",
             SysDivide, DdrDivide);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input clock
  // ---------------------------------------------------------------------------
  logic clk_in_ibuf, clk_in;

  if (DiffIn) begin : g_in_diff
    IBUFDS u_clk_ibuf (
      .I  (clk_pad_i),
      .IB (clk_pad_n_i),
      .O  (clk_in_ibuf)
    );
  end else begin : g_in_se
    IBUF u_clk_ibuf (
      .I (clk_pad_i),
      .O (clk_in_ibuf)
    );
  end

  BUFG u_clk_in_bufg (
    .I (clk_in_ibuf),
    .O (clk_in)
  );

  assign clk_ibuf_o = clk_in_ibuf;

  // ---------------------------------------------------------------------------
  // Lock-loss reset (as bow_ddr_clk_xusp): an MMCM keeps its fine phase shift
  // until RST, also through a loss of lock, while bow_ddr clears its phase
  // counters whenever locked_ddr_o falls. So a fall of either LOCKED after
  // both were locked resets both MMCMs for LockRstCycles input clock cycles:
  // phases and counters return to 0 together. Clocked by the input clock,
  // which runs while the MMCMs are down. MMCM_A also makes clk_sys: on a board
  // whose SoC reset includes locked_sys_o, these lock losses reset the SoC.
  // ---------------------------------------------------------------------------
  localparam int unsigned LockRstCycles = 64;

  (* ASYNC_REG = "TRUE" *) logic [1:0] lk_sync_q;
  logic       lk_was_q, lk_rst;
  logic [6:0] lk_cnt_q;
  logic       locked_a, locked_b;

  always_ff @(posedge clk_in or posedge rst_i) begin
    if (rst_i) begin
      lk_sync_q <= '0;
      lk_was_q  <= 1'b0;
      lk_cnt_q  <= '0;
    end else begin
      lk_sync_q <= {lk_sync_q[0], locked_a & locked_b};
      if (lk_cnt_q != '0) begin
        lk_cnt_q <= lk_cnt_q - 7'd1;
      end else if (lk_sync_q[1]) begin
        lk_was_q <= 1'b1;
      end else if (lk_was_q) begin
        lk_was_q <= 1'b0;
        lk_cnt_q <= 7'(LockRstCycles);
      end
    end
  end

  assign lk_rst = (lk_cnt_q != '0);

  // ---------------------------------------------------------------------------
  // MMCM_A: SoC clock, DDR clock, controller clock, write clocks
  // ---------------------------------------------------------------------------
  logic clkfb_a;
  logic clk_sys_mmcm, ddr_clk_mmcm, ddr_sys_clk_mmcm, ddr_wclk_mmcm, ddr_wclk90_mmcm;

  // Internal feedback (CLKFBOUT -> CLKFBIN): no output has to be aligned to
  // the input, all DDR timing is relative to ddr_clk_o.
  MMCME5 #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKIN1_PERIOD      (ClkInPeriodNs),
    .DIVCLK_DIVIDE      (InDivide),
    .CLKFBOUT_MULT      (VcoMult),
    .CLKFBOUT_FRACT     (0),
    .CLKFBOUT_PHASE     (0.0),
    .CLKOUT0_DIVIDE     (SysDivide),
    .CLKOUT0_PHASE      (0.0),
    .CLKOUT0_DUTY_CYCLE (0.5),
    .CLKOUT0_PHASE_CTRL (2'b00),
    .CLKOUT1_DIVIDE     (DdrDivide),
    .CLKOUT1_PHASE      (0.0),
    .CLKOUT1_DUTY_CYCLE (0.5),
    .CLKOUT1_PHASE_CTRL (2'b00),
    .CLKOUT2_DIVIDE     (DdrDivide),
    .CLKOUT2_PHASE      (0.0),
    .CLKOUT2_DUTY_CYCLE (0.5),
    .CLKOUT2_PHASE_CTRL (2'b10),      // fine PS: write phase
    .CLKOUT3_DIVIDE     (DdrSysDivide),
    .CLKOUT3_PHASE      (0.0),
    .CLKOUT3_DUTY_CYCLE (0.5),
    .CLKOUT3_PHASE_CTRL (2'b00),
    .CLKOUT4_DIVIDE     (DdrDivide),
    .CLKOUT4_PHASE      (90.0),
    .CLKOUT4_DUTY_CYCLE (0.5),
    .CLKOUT4_PHASE_CTRL (2'b10),      // fine PS: write phase (+90 deg static)
    .COMPENSATION       ("AUTO"),
    .LOCK_WAIT          ("FALSE")
  ) u_mmcm_a (
    .CLKIN1         (clk_in),
    .CLKIN2         (1'b0),
    .CLKINSEL       (1'b1),
    .CLKFBIN        (clkfb_a),
    .CLKFBOUT       (clkfb_a),
    .CLKOUT0        (clk_sys_mmcm),
    .CLKOUT1        (ddr_clk_mmcm),
    .CLKOUT2        (ddr_wclk_mmcm),
    .CLKOUT3        (ddr_sys_clk_mmcm),
    .CLKOUT4        (ddr_wclk90_mmcm),
    .CLKOUT5        (),
    .CLKOUT6        (),
    .LOCKED         (locked_a),
    .LOCKED1_DESKEW (),
    .LOCKED2_DESKEW (),
    .LOCKED_FB      (),
    .CLKFBSTOPPED   (),
    .CLKINSTOPPED   (),
    .CLKIN1_DESKEW  (1'b0),
    .CLKFB1_DESKEW  (1'b0),
    .CLKIN2_DESKEW  (1'b0),
    .CLKFB2_DESKEW  (1'b0),
    .RST            (rst_i | lk_rst),
    .PWRDWN         (1'b0),
    .PSCLK          (ddr_clk_o),
    .PSEN           (wps_en_i),
    .PSINCDEC       (wps_inc_i),
    .PSDONE         (wps_done_o),
    .DCLK           (1'b0),
    .DEN            (1'b0),
    .DWE            (1'b0),
    .DADDR          (7'h00),
    .DI             (16'h0000),
    .DO             (),
    .DRDY           ()
  );

  BUFG u_sys_bufg     (.I (clk_sys_mmcm),     .O (clk_sys_o));
  BUFG u_ddr_bufg     (.I (ddr_clk_mmcm),     .O (ddr_clk_o));
  BUFG u_ddr_sys_bufg (.I (ddr_sys_clk_mmcm), .O (ddr_sys_clk_o));
  BUFG u_ddr_wclk_bufg (.I (ddr_wclk_mmcm),   .O (ddr_wclk_o));
  BUFG u_ddr_w90_bufg (.I (ddr_wclk90_mmcm),  .O (ddr_wclk90_o));

  // ---------------------------------------------------------------------------
  // MMCM_B: read capture clock
  // ---------------------------------------------------------------------------
  logic clkfb_b, ddr_rd_clk_mmcm;

  MMCME5 #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKIN1_PERIOD      (ClkInPeriodNs),
    .DIVCLK_DIVIDE      (InDivide),
    .CLKFBOUT_MULT      (VcoMult),
    .CLKFBOUT_FRACT     (0),
    .CLKFBOUT_PHASE     (0.0),
    .CLKOUT0_DIVIDE     (DdrDivide),
    .CLKOUT0_PHASE      (0.0),
    .CLKOUT0_DUTY_CYCLE (0.5),
    .CLKOUT0_PHASE_CTRL (2'b10),      // fine PS: read phase
    .COMPENSATION       ("AUTO"),
    .LOCK_WAIT          ("FALSE")
  ) u_mmcm_b (
    .CLKIN1         (clk_in),
    .CLKIN2         (1'b0),
    .CLKINSEL       (1'b1),
    .CLKFBIN        (clkfb_b),
    .CLKFBOUT       (clkfb_b),
    .CLKOUT0        (ddr_rd_clk_mmcm),
    .CLKOUT1        (),
    .CLKOUT2        (),
    .CLKOUT3        (),
    .CLKOUT4        (),
    .CLKOUT5        (),
    .CLKOUT6        (),
    .LOCKED         (locked_b),
    .LOCKED1_DESKEW (),
    .LOCKED2_DESKEW (),
    .LOCKED_FB      (),
    .CLKFBSTOPPED   (),
    .CLKINSTOPPED   (),
    .CLKIN1_DESKEW  (1'b0),
    .CLKFB1_DESKEW  (1'b0),
    .CLKIN2_DESKEW  (1'b0),
    .CLKFB2_DESKEW  (1'b0),
    .RST            (rst_i | lk_rst),
    .PWRDWN         (1'b0),
    .PSCLK          (ddr_clk_o),
    .PSEN           (ps_en_i),
    .PSINCDEC       (ps_inc_i),
    .PSDONE         (ps_done_o),
    .DCLK           (1'b0),
    .DEN            (1'b0),
    .DWE            (1'b0),
    .DADDR          (7'h00),
    .DI             (16'h0000),
    .DO             (),
    .DRDY           ()
  );

  BUFG u_ddr_rd_bufg (.I (ddr_rd_clk_mmcm), .O (ddr_rd_clk_o));

  assign locked_sys_o = locked_a;
  assign locked_ddr_o = locked_a & locked_b;

endmodule
