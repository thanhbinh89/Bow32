// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Clocks of the Huins MFP-VP1902 camera build (bow32_huins_vp1902_cam_top): one MMCME5
// for the SoC and video clocks, and a buffered copy of the input for the XPLL of the
// D-PHY bank (bow_dphy_io_versal).
//
//   clk_pad_i -IBUFDS-+-BUFG u_in_bufg --> MMCM CLKOUT0 /SysDivide -BUFG-> clk_sys_o  SoC
//                     |                          CLKOUT1 /VidDivide -BUFG-> clk_vid_o  video
//                     +-BUFG u_xpll_bufg -----------------------------> xpll_clk_o  XPLL CLKIN
//
//   VCO = 1000 / ClkInPeriodNs * VcoMult / InDivide MHz (MMCME5: 2160..4320 MHz, phase
//   detector 10..550 MHz). Huins defaults: the fixed 200 MHz board oscillator, VCO 200 * 16
//   = 3200 MHz (as the RAM card build), clk_sys /64 = 50 MHz, clk_vid /16 = 200 MHz: ISP,
//   CSI-2 LP state machines and PHY control, H.264, CTRL_CLK of the XPHYs.
//
// The input is in another SLR than the camera bank on the Huins board (bank 718 = SLR3,
// bank 705 = SLR0): tcl/pre_place_cam.tcl moves the MMCM next to the camera and sets the
// clock routing overrides of the three input nets. The two input BUFGs stay separate
// (DONT_TOUCH): a BUFG with an input pin driver that drives a single XPLL has a placement
// rule of its own (rule_bufg_xpll_1load), the MMCM input BUFG has not.
//
// Lock-loss reset (as bow_ddr_clk_versal): a fall of LOCKED after the MMCM was locked
// resets it for LockRstCycles input clock cycles, so that it relocks by itself after the
// input clock comes back. locked_o is asynchronous (bow_rst_sync / bow_rstmgr behind it).
// The board XDC names the generated clocks after the MMCM output pins (clk_sys =
// u_mmcm/CLKOUT0, clk_vid = u_mmcm/CLKOUT1): keep the instance names.

module bow32_huins_vp1902_cam_clk #(
  parameter real         ClkInPeriodNs = 5.0,   // CLKIN1_PERIOD
  parameter int unsigned InDivide      = 1,     // DIVCLK_DIVIDE
  parameter int unsigned VcoMult       = 16,    // CLKFBOUT_MULT
  parameter int unsigned SysDivide     = 64,    // clk_sys_o = VCO / SysDivide
  parameter int unsigned VidDivide     = 16     // clk_vid_o = VCO / VidDivide
) (
  input  wire  clk_pad_i,      // differential clock input pair
  input  wire  clk_pad_n_i,
  input  logic rst_i,          // MMCM reset, active high, asynchronous

  output logic clk_sys_o,
  output logic clk_vid_o,
  output logic xpll_clk_o,     // the input clock through its own BUFG (XPLL CLKIN)
  output logic locked_o        // MMCM locked (clk_sys_o, clk_vid_o)
);

`ifndef SYNTHESIS
  localparam real VcoMhz = 1000.0 / ClkInPeriodNs * real'(VcoMult) / real'(InDivide);
  localparam real PfdMhz = 1000.0 / ClkInPeriodNs / real'(InDivide);
  initial begin
    if (VcoMhz < 2160.0 || VcoMhz > 4320.0) begin
      $error("bow32_huins_vp1902_cam_clk: VCO %f MHz outside 2160..4320 MHz", VcoMhz);
    end
    if (PfdMhz < 10.0 || PfdMhz > 550.0) begin
      $error("bow32_huins_vp1902_cam_clk: phase detector %f MHz outside 10..550 MHz", PfdMhz);
    end
    if (SysDivide > 511 || VidDivide > 511 || SysDivide < 2 || VidDivide < 2) begin
      $error("bow32_huins_vp1902_cam_clk: output divide out of 2..511 (Sys %0d, Vid %0d)",
             SysDivide, VidDivide);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input clock
  // ---------------------------------------------------------------------------
  logic clk_in_ibuf, clk_in;

  IBUFDS u_clk_ibuf (
    .I  (clk_pad_i),
    .IB (clk_pad_n_i),
    .O  (clk_in_ibuf)
  );

  (* DONT_TOUCH = "TRUE" *)
  BUFG u_in_bufg (
    .I (clk_in_ibuf),
    .O (clk_in)
  );

  (* DONT_TOUCH = "TRUE" *)
  BUFG u_xpll_bufg (
    .I (clk_in_ibuf),
    .O (xpll_clk_o)
  );

  // ---------------------------------------------------------------------------
  // Lock-loss reset, clocked by the input clock (runs while the MMCM is down)
  // ---------------------------------------------------------------------------
  localparam int unsigned LockRstCycles = 64;

  (* ASYNC_REG = "TRUE" *) logic [1:0] lk_sync_q;
  logic       lk_was_q, lk_rst, locked;
  logic [6:0] lk_cnt_q;

  always_ff @(posedge clk_in or posedge rst_i) begin
    if (rst_i) begin
      lk_sync_q <= '0;
      lk_was_q  <= 1'b0;
      lk_cnt_q  <= '0;
    end else begin
      lk_sync_q <= {lk_sync_q[0], locked};
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
  // MMCM: SoC and video clocks. Internal feedback (CLKFBOUT -> CLKFBIN): no output has
  // to be aligned to the input.
  // ---------------------------------------------------------------------------
  logic clkfb, clk_sys_mmcm, clk_vid_mmcm;

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
    .CLKOUT1_DIVIDE     (VidDivide),
    .CLKOUT1_PHASE      (0.0),
    .CLKOUT1_DUTY_CYCLE (0.5),
    .CLKOUT1_PHASE_CTRL (2'b00),
    .COMPENSATION       ("AUTO"),
    .LOCK_WAIT          ("FALSE")
  ) u_mmcm (
    .CLKIN1         (clk_in),
    .CLKIN2         (1'b0),
    .CLKINSEL       (1'b1),
    .CLKFBIN        (clkfb),
    .CLKFBOUT       (clkfb),
    .CLKOUT0        (clk_sys_mmcm),
    .CLKOUT1        (clk_vid_mmcm),
    .CLKOUT2        (),
    .CLKOUT3        (),
    .CLKOUT4        (),
    .CLKOUT5        (),
    .CLKOUT6        (),
    .LOCKED         (locked),
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
    .PSCLK          (1'b0),
    .PSEN           (1'b0),
    .PSINCDEC       (1'b0),
    .PSDONE         (),
    .DCLK           (1'b0),
    .DEN            (1'b0),
    .DWE            (1'b0),
    .DADDR          (7'h00),
    .DI             (16'h0000),
    .DO             (),
    .DRDY           ()
  );

  BUFG u_sys_bufg (.I (clk_sys_mmcm), .O (clk_sys_o));
  BUFG u_vid_bufg (.I (clk_vid_mmcm), .O (clk_vid_o));

  assign locked_o = locked;

endmodule
