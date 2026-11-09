// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Clocks of the Bow32 HyperRAM IP (bow_hyperram) on AMD Versal: two MMCME5
// behind their own BUFG, fed by the buffered input of a clock-capable pin
// (Huins VP1902: clk_ibuf_o of bow_ddr_clk_versal). The Versal twin of
// bow_hyperram_clk_xusp, with the same ports and phase contract.
//
//   clk_in_i -BUFG-+-> MMCM_H CLKOUT0 /HrDivide, phase 270 deg -BUFG-> hr_clk_o    controller, PHY,
//                  |                                                        CK / CS# / RESET# / DIR /
//                  |                                                        OE pads, PSCLK of both
//                  |     CLKOUT1 /HrDivide, fine PS -------BUFG-> hr_wclk_o   DQ / RWDS output ODDRs
//                  |                                                        (inverted: hr_clk + 3T/4)
//                  +-> MMCM_R CLKOUT0 /HrDivide, fine PS --BUFG-> hr_rd_clk_o read IDDRs
//
//   VCO = 1000 / ClkInPeriodNs * VcoMult / InDivide MHz (MMCME5: 2160..4320
//   MHz, phase detector 10..550 MHz). Huins VP1902: 200 MHz * 16 / 1 = 3200
//   MHz, HyperRAM clocks /32 = 100 MHz (tCK 10 ns).
//
// The 270 deg: the write clock must lead the CK pad by a quarter period less
// than the controller clock (bow_hyperram_pkg contract): hr_clk_o at 270 deg
// and hr_wclk_o at 0 deg (+ fine PS) of the same VCO give hr_wclk_o =
// hr_clk_o + T/4 at write phase 0, and the controller -> ODDR paths are
// synchronous (Vivado models the 270 deg as clock latency: the board XDC needs
// set_multicycle_path -setup 2 from hr_clk to hr_wclk and an uncertainty of
// 3T/16 for the write phase range, as on the MPS4). The read capture clock is
// calibrated over a full period: MMCM_R may lock at any phase.
//
// Dynamic fine phase shift (PSCLK = hr_clk_o inside this module):
//   * one step = VCO period / 32 (9.77 ps at 3200 MHz), PsSteps = 32 *
//     HrDivide steps per CK period (1024); the phase wraps;
//   * *_en_i high for one hr_clk_o cycle with *_inc_i valid (1 = later), then
//     wait for *_done_o before the next step (bow_mmcm_ps does; MMCME5 answers
//     after 12..13 PSCLK cycles and, in the AMD simulation model, repeats
//     PSDONE every 32 cycles until the next PSEN, see bow_ddr_clk_versal);
//   * ps_* moves hr_rd_clk_o, wps_* moves hr_wclk_o; hr_clk_o never moves;
//   * rst_i, or a loss of lock of either MMCM after both were locked (both
//     are then reset for LockRstCycles input cycles), returns both phases to 0.
// locked_o: both MMCMs locked (bow_hyperram hr_rst_ni). The board XDC names
// the generated clocks after the MMCM output pins (hr_clk, hr_wclk, hr_rd_clk).

module bow_hyperram_clk_versal #(
  parameter real         ClkInPeriodNs = 5.0,
  parameter int unsigned InDivide      = 1,
  parameter int unsigned VcoMult       = 16,
  parameter int unsigned HrDivide      = 32     // HyperRAM clocks = VCO / HrDivide
) (
  input  logic clk_in_i,      // input clock: IBUF(DS) output of a clock-capable pin (not a BUFG)
  input  logic rst_i,         // MMCM reset, active high, asynchronous

  output logic hr_clk_o,
  output logic hr_wclk_o,
  output logic hr_rd_clk_o,
  output logic locked_o,

  input  logic ps_en_i,       // read phase (MMCM_R), hr_clk_o domain
  input  logic ps_inc_i,
  output logic ps_done_o,
  input  logic wps_en_i,      // write phase (MMCM_H CLKOUT1), hr_clk_o domain
  input  logic wps_inc_i,
  output logic wps_done_o
);

`ifndef SYNTHESIS
  localparam real VcoMhz = 1000.0 / ClkInPeriodNs * real'(VcoMult) / real'(InDivide);
  localparam real PfdMhz = 1000.0 / ClkInPeriodNs / real'(InDivide);
  initial begin
    if (VcoMhz < 2160.0 || VcoMhz > 4320.0) begin
      $error("bow_hyperram_clk_versal: VCO %f MHz outside 2160..4320 MHz", VcoMhz);
    end
    if (PfdMhz < 10.0 || PfdMhz > 550.0) begin
      $error("bow_hyperram_clk_versal: phase detector %f MHz outside 10..550 MHz", PfdMhz);
    end
    if (HrDivide < 2 || HrDivide > 511) begin
      $error("bow_hyperram_clk_versal: HrDivide %0d outside 2..511", HrDivide);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input clock buffer
  // ---------------------------------------------------------------------------
  logic clk_in;

  BUFG u_in_bufg (.I (clk_in_i), .O (clk_in));

  // ---------------------------------------------------------------------------
  // Lock-loss reset (see bow_ddr_clk_versal)
  // ---------------------------------------------------------------------------
  localparam int unsigned LockRstCycles = 64;

  (* ASYNC_REG = "TRUE" *) logic [1:0] lk_sync_q;
  logic       lk_was_q, lk_rst;
  logic [6:0] lk_cnt_q;
  logic       locked_h, locked_r;

  always_ff @(posedge clk_in or posedge rst_i) begin
    if (rst_i) begin
      lk_sync_q <= '0;
      lk_was_q  <= 1'b0;
      lk_cnt_q  <= '0;
    end else begin
      lk_sync_q <= {lk_sync_q[0], locked_h & locked_r};
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
  // MMCM_H: controller clock (static 270 deg) and write clock (fine PS)
  // ---------------------------------------------------------------------------
  logic clkfb_h, hr_clk_mmcm, hr_wclk_mmcm;

  MMCME5 #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKIN1_PERIOD      (ClkInPeriodNs),
    .DIVCLK_DIVIDE      (InDivide),
    .CLKFBOUT_MULT      (VcoMult),
    .CLKFBOUT_FRACT     (0),
    .CLKFBOUT_PHASE     (0.0),
    .CLKOUT0_DIVIDE     (HrDivide),
    .CLKOUT0_PHASE      (270.0),
    .CLKOUT0_DUTY_CYCLE (0.5),
    .CLKOUT0_PHASE_CTRL (2'b00),
    .CLKOUT1_DIVIDE     (HrDivide),
    .CLKOUT1_PHASE      (0.0),
    .CLKOUT1_DUTY_CYCLE (0.5),
    .CLKOUT1_PHASE_CTRL (2'b10),      // fine PS: write phase
    .COMPENSATION       ("AUTO"),
    .LOCK_WAIT          ("FALSE")
  ) u_mmcm_h (
    .CLKIN1         (clk_in),
    .CLKIN2         (1'b0),
    .CLKINSEL       (1'b1),
    .CLKFBIN        (clkfb_h),
    .CLKFBOUT       (clkfb_h),
    .CLKOUT0        (hr_clk_mmcm),
    .CLKOUT1        (hr_wclk_mmcm),
    .CLKOUT2        (),
    .CLKOUT3        (),
    .CLKOUT4        (),
    .CLKOUT5        (),
    .CLKOUT6        (),
    .LOCKED         (locked_h),
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
    .PSCLK          (hr_clk_o),
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

  BUFG u_hr_bufg  (.I (hr_clk_mmcm),  .O (hr_clk_o));
  BUFG u_hrw_bufg (.I (hr_wclk_mmcm), .O (hr_wclk_o));

  // ---------------------------------------------------------------------------
  // MMCM_R: read capture clock (fine PS)
  // ---------------------------------------------------------------------------
  logic clkfb_r, hr_rd_clk_mmcm;

  MMCME5 #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKIN1_PERIOD      (ClkInPeriodNs),
    .DIVCLK_DIVIDE      (InDivide),
    .CLKFBOUT_MULT      (VcoMult),
    .CLKFBOUT_FRACT     (0),
    .CLKFBOUT_PHASE     (0.0),
    .CLKOUT0_DIVIDE     (HrDivide),
    .CLKOUT0_PHASE      (0.0),
    .CLKOUT0_DUTY_CYCLE (0.5),
    .CLKOUT0_PHASE_CTRL (2'b10),      // fine PS: read phase
    .COMPENSATION       ("AUTO"),
    .LOCK_WAIT          ("FALSE")
  ) u_mmcm_r (
    .CLKIN1         (clk_in),
    .CLKIN2         (1'b0),
    .CLKINSEL       (1'b1),
    .CLKFBIN        (clkfb_r),
    .CLKFBOUT       (clkfb_r),
    .CLKOUT0        (hr_rd_clk_mmcm),
    .CLKOUT1        (),
    .CLKOUT2        (),
    .CLKOUT3        (),
    .CLKOUT4        (),
    .CLKOUT5        (),
    .CLKOUT6        (),
    .LOCKED         (locked_r),
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
    .PSCLK          (hr_clk_o),
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

  BUFG u_hrr_bufg (.I (hr_rd_clk_mmcm), .O (hr_rd_clk_o));

  assign locked_o = locked_h & locked_r;

endmodule
