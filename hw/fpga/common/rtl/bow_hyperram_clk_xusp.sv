// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Clocks of the Bow32 HyperRAM IP (bow_hyperram) on AMD UltraScale+: two
// MMCME4_ADV behind their own BUFGCE, fed by the IBUF output of a global
// clock-capable input (MPS4: the oscillator pin, shared with bow_ddr_clk_xusp).
//
//   clk_in_i -BUFG-+-> MMCM_H CLKOUT0 /HrDivide, phase 270 deg -BUFG-> hr_clk_o    controller, PHY,
//                  |                                                        CK / CS# / RESET# / DIR /
//                  |                                                        OE pads, PSCLK of both
//                  |     CLKOUT1 /HrDivide, fine PS -------BUFG-> hr_wclk_o   DQ / RWDS output ODDRs
//                  |                                                        (inverted: hr_clk + 3T/4)
//                  +-> MMCM_R CLKOUT0 /HrDivide, fine PS --BUFG-> hr_rd_clk_o read IDDRs
//
//   VCO = 1000 / ClkInPeriodNs * VcoMult / InDivide MHz (MMCME4, speed grade
//   -1: 800..1600 MHz). MPS4: 100 MHz * 12 / 1 = 1200 MHz, HyperRAM clocks /12
//   = 100 MHz (tCK 10 ns).
//
// Why the 270 deg: an output with CLKOUTn_USE_FINE_PS = TRUE must have
// CLKOUTn_PHASE = 0 (Vivado DRC AVAL-152), but the write clock must lead the
// CK pad by a quarter period less than the controller clock: with hr_clk_o at
// 270 deg and hr_wclk_o at 0 deg (+ fine PS) of the same VCO, hr_wclk_o =
// hr_clk_o + T/4 at write phase 0 (bow_hyperram_pkg contract), and the
// controller -> ODDR paths are synchronous (timed by STA: setup 3T/4, hold
// T/4 at write phase 0; the board XDC needs set_multicycle_path -setup 2, as
// Vivado models the 270 deg as clock latency, and an uncertainty of 3T/16 for
// the write phase range of bow_hyperram_ctrl).
// The read capture clock is calibrated over a full period: MMCM_R may lock at
// any phase.
//
// Placement: u_in_bufg sits in the clock region of the input pin. When that
// pin also feeds other MMCMs (MPS4: MMCM_A / MMCM_B / MMCM_W of the DDR clocks
// fill the pin's region and the regions next to it), the board XDC lets the
// net of u_in_bufg reach MMCMs further up or down the same CMT column
// (CLOCK_DEDICATED_ROUTE SAME_CMT_COLUMN). Only the insertion delay of the
// oscillator to the two MMCMs changes, and nothing here depends on it: the
// HyperRAM clocks are asynchronous to every other clock (the board XDC), the
// write clock comes from the same MMCM as hr_clk_o, the read clock is
// calibrated.
//
// Dynamic fine phase shift (PSCLK = hr_clk_o inside this module):
//   * one step = VCO period / 56 (14.88 ps at 1200 MHz), PsSteps = 56 *
//     HrDivide steps per CK period (672); the phase wraps;
//   * *_en_i high for one hr_clk_o cycle with *_inc_i valid (1 = later), then
//     wait for *_done_o before the next step (bow_mmcm_ps does);
//   * ps_* moves hr_rd_clk_o, wps_* moves hr_wclk_o; hr_clk_o never moves;
//   * rst_i, or a loss of lock of either MMCM after both were locked (both
//     are then reset for LockRstCycles input cycles, as bow_ddr_clk_xusp
//     does: UG572 asks for a reset after LOCKED falls, and the phase counters
//     of bow_hyperram restart at 0 with hr_rst_ni = locked_o), returns both
//     phases to 0.
// locked_o: both MMCMs locked (bow_hyperram hr_rst_ni). The board XDC names
// the generated clocks after the MMCM output pins (MPS4: hr_clk, hr_wclk,
// hr_rd_clk).

module bow_hyperram_clk_xusp #(
  parameter real         ClkInPeriodNs = 10.0,
  parameter int unsigned InDivide      = 1,
  parameter real         VcoMult       = 12.0,
  parameter int unsigned HrDivide      = 12     // HyperRAM clocks = VCO / HrDivide
) (
  input  logic clk_in_i,      // input clock: IBUF output of a clock-capable pin (not a BUFG)
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
  localparam real VcoMhz = 1000.0 / ClkInPeriodNs * VcoMult / real'(InDivide);
  initial begin
    if (VcoMhz < 800.0 || VcoMhz > 1600.0) begin
      $error("bow_hyperram_clk_xusp: VCO %f MHz outside 800..1600 MHz", VcoMhz);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input clock buffer (see "Placement")
  // ---------------------------------------------------------------------------
  logic clk_in;

  BUFG u_in_bufg (.I (clk_in_i), .O (clk_in));

  // ---------------------------------------------------------------------------
  // Lock-loss reset (see bow_ddr_clk_xusp)
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

  MMCME4_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .CLKIN1_PERIOD        (ClkInPeriodNs),
    .DIVCLK_DIVIDE        (InDivide),
    .CLKFBOUT_MULT_F      (VcoMult),
    .CLKFBOUT_PHASE       (0.0),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKOUT0_DIVIDE_F     (real'(HrDivide)),
    .CLKOUT0_PHASE        (270.0),
    .CLKOUT0_DUTY_CYCLE   (0.5),
    .CLKOUT0_USE_FINE_PS  ("FALSE"),
    .CLKOUT1_DIVIDE       (HrDivide),
    .CLKOUT1_PHASE        (0.0),
    .CLKOUT1_DUTY_CYCLE   (0.5),
    .CLKOUT1_USE_FINE_PS  ("TRUE"),
    .COMPENSATION         ("AUTO"),
    .STARTUP_WAIT         ("FALSE")
  ) u_mmcm_h (
    .CLKIN1       (clk_in),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clkfb_h),
    .CLKFBOUT     (clkfb_h),
    .CLKFBOUTB    (),
    .CLKOUT0      (hr_clk_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (hr_wclk_mmcm),
    .CLKOUT1B     (),
    .CLKOUT2      (),
    .CLKOUT2B     (),
    .CLKOUT3      (),
    .CLKOUT3B     (),
    .CLKOUT4      (),
    .CLKOUT5      (),
    .CLKOUT6      (),
    .LOCKED       (locked_h),
    .CLKFBSTOPPED (),
    .CLKINSTOPPED (),
    .RST          (rst_i | lk_rst),
    .PWRDWN       (1'b0),
    .PSCLK        (hr_clk_o),
    .PSEN         (wps_en_i),
    .PSINCDEC     (wps_inc_i),
    .PSDONE       (wps_done_o),
    .CDDCREQ      (1'b0),
    .CDDCDONE     (),
    .DCLK         (1'b0),
    .DEN          (1'b0),
    .DWE          (1'b0),
    .DADDR        (7'h00),
    .DI           (16'h0000),
    .DO           (),
    .DRDY         ()
  );

  BUFG u_hr_bufg  (.I (hr_clk_mmcm),  .O (hr_clk_o));
  BUFG u_hrw_bufg (.I (hr_wclk_mmcm), .O (hr_wclk_o));

  // ---------------------------------------------------------------------------
  // MMCM_R: read capture clock (fine PS)
  // ---------------------------------------------------------------------------
  logic clkfb_r, hr_rd_clk_mmcm;

  MMCME4_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .CLKIN1_PERIOD        (ClkInPeriodNs),
    .DIVCLK_DIVIDE        (InDivide),
    .CLKFBOUT_MULT_F      (VcoMult),
    .CLKFBOUT_PHASE       (0.0),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKOUT0_DIVIDE_F     (real'(HrDivide)),
    .CLKOUT0_PHASE        (0.0),
    .CLKOUT0_DUTY_CYCLE   (0.5),
    .CLKOUT0_USE_FINE_PS  ("TRUE"),
    .COMPENSATION         ("AUTO"),
    .STARTUP_WAIT         ("FALSE")
  ) u_mmcm_r (
    .CLKIN1       (clk_in),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clkfb_r),
    .CLKFBOUT     (clkfb_r),
    .CLKFBOUTB    (),
    .CLKOUT0      (hr_rd_clk_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (),
    .CLKOUT1B     (),
    .CLKOUT2      (),
    .CLKOUT2B     (),
    .CLKOUT3      (),
    .CLKOUT3B     (),
    .CLKOUT4      (),
    .CLKOUT5      (),
    .CLKOUT6      (),
    .LOCKED       (locked_r),
    .CLKFBSTOPPED (),
    .CLKINSTOPPED (),
    .RST          (rst_i | lk_rst),
    .PWRDWN       (1'b0),
    .PSCLK        (hr_clk_o),
    .PSEN         (ps_en_i),
    .PSINCDEC     (ps_inc_i),
    .PSDONE       (ps_done_o),
    .CDDCREQ      (1'b0),
    .CDDCDONE     (),
    .DCLK         (1'b0),
    .DEN          (1'b0),
    .DWE          (1'b0),
    .DADDR        (7'h00),
    .DI           (16'h0000),
    .DO           (),
    .DRDY         ()
  );

  BUFG u_hrr_bufg (.I (hr_rd_clk_mmcm), .O (hr_rd_clk_o));

  assign locked_o = locked_h & locked_r;

endmodule
