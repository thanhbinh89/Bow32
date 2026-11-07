// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Clocks of Bow32 and its DDR2/DDR3 memory system (bow_ddr: LiteDRAM
// controller + Bow32 PHY) on AMD UltraScale+: three MMCME4_ADV fed by one
// single ended oscillator input.
//
//   clk_pad_i -IBUF-BUFG-+-> MMCM_A CLKOUT0 /SysDivide -BUFG-> clk_sys_o     SoC (clk_i)
//                        |          CLKOUT1 /DdrDivide -BUFG-> ddr_clk_o     DFI adapter, PHY, CK,
//                        |                                                   commands, PSCLK
//                        |          CLKOUT3 /(4 DdrDivide) -BUFG-> ddr_sys_clk_o  LiteDRAM
//                        |                                                   controller (CK / 4)
//                        |          CLKOUT2 /DdrDivide -BUFG-> wps_clk  (fine PS: wps_*)
//                        |                                       |
//                        |              MMCM_W <-----------------+
//                        |              CLKOUT0 /DdrDivide -BUFG-> ddr_wclk_o    DQS ODDR
//                        |              CLKOUT1 /DdrDivide -BUFG-> ddr_wclk90_o  DQ/DM ODDR (+90 deg)
//                        +-> MMCM_B CLKOUT0 /DdrDivide -BUFG-> ddr_rd_clk_o  IDDR capture, fine PS: ps_*
//
//   VCO = 1000 / ClkInPeriodNs * VcoMult / InDivide MHz (MMCME4, speed grade -1:
//   800..1600 MHz) in MMCM_A and MMCM_B; MMCM_W runs its VCO at the same
//   frequency (input = DDR clock, multiply by DdrDivide). MPS4 defaults:
//   100 MHz * 12 / 1 = 1200 MHz, clk_sys /24 = 50 MHz, DDR clocks /9 =
//   133.333 MHz (tCK 7.5 ns), controller clock /36 = 33.333 MHz.
//
// Why three MMCMs:
//   * An output with CLKOUTn_USE_FINE_PS = TRUE must have CLKOUTn_PHASE = 0
//     (Vivado DRC AVAL-152), and all fine-PS outputs of an MMCM move together.
//     The write clocks need a fixed +90 deg between them and a common
//     adjustable phase, so MMCM_A shifts one clock (wps_clk) and MMCM_W
//     derives ddr_wclk_o (0 deg) and ddr_wclk90_o (+90 deg, static) from it.
//     MMCM_W follows each 15 ps step of its input within its loop bandwidth.
//   * ddr_clk_o and wps_clk share the VCO and divider of MMCM_A: an MMCM
//     output whose frequency is not a multiple of the phase detector
//     frequency (133.33 vs 100 MHz) has no fixed phase to the input (its
//     edges meet every third input edge, which one depends on the lock), so
//     two MMCMs fed by the oscillator could put their 133 MHz outputs 0, 2.5
//     or 5 ns apart. MMCM_W multiplies the 133 MHz clock itself (feedback =
//     input frequency), its outputs have a fixed phase to wps_clk; the BUFG in
//     its feedback (BUF_IN compensation) aligns them to its input.
//   * The read capture clock is calibrated over a full period, so MMCM_B (its
//     own fine PS, independent of the write phase) may lock at any phase.
//   * ddr_sys_clk_o (CK / 4, the clock of the LiteDRAM controller and its DFI
//     1:4) is another output of MMCM_A, not of a fourth MMCM (no fixed phase,
//     as above): same VCO as ddr_clk_o, both at phase 0, and the output
//     counters start together at lock, so every rising edge of ddr_sys_clk_o
//     is a rising edge of ddr_clk_o. The paths between the two clocks are
//     synchronous (timed by STA, no synchronizer); the DFI adapter finds the
//     phase (0..3) of each ddr_clk_o cycle from a ddr_sys_clk_o toggle flop
//     sampled in ddr_clk_o.
//
// Dynamic fine phase shift (both ports in the ddr_clk_o domain, PSCLK =
// ddr_clk_o inside this module):
//   * one step = VCO period / 56 (14.88 ps at 1200 MHz), PsSteps = 56 *
//     DdrDivide steps per DDR clock period (504); the phase wraps;
//   * *_en_i high for one ddr_clk_o cycle with *_inc_i valid (1 = later,
//     0 = earlier), then wait for *_done_o (a one cycle pulse 12 cycles after
//     the enable) before the next step;
//   * use the ports only while locked_ddr_o = 1 (the PHY's reset is released
//     by it): MMCM_B steps while its PSCLK runs even before its own lock;
//   * ps_* moves ddr_rd_clk_o only; wps_* moves ddr_wclk_o and ddr_wclk90_o
//     together (MMCM_W tracks wps_clk); clk_sys_o, ddr_clk_o and
//     ddr_sys_clk_o never move;
//   * rst_i returns both phases to 0, and so does a loss of lock of any MMCM
//     (all three are reset then, see "Lock-loss reset"): locked_ddr_o falls
//     whenever the phases return to 0.
// At write phase 0, ddr_wclk_o has the edges of ddr_clk_o (+ the static
// offset of the MMCM_W cascade, timed by STA) and ddr_wclk90_o is
// ddr_wclk_o delayed by a quarter period.
//
// locked_sys_o (MMCM_A) is enough for the SoC clock; locked_ddr_o needs all
// three MMCMs. Both are asynchronous (bow_rst_sync / bow_rstmgr behind them).
// The board XDC names the generated clocks after the MMCM output pins (MPS4:
// clk_sys, ddr_clk, ddr_sys = CLKOUT3 of u_mmcm_a, ddr_wps_clk, ddr_wclk,
// ddr_wclk90, ddr_rd_clk).

module bow_ddr_clk_xusp #(
  parameter real         ClkInPeriodNs = 10.0,  // CLKIN1_PERIOD of MMCM_A and MMCM_B
  parameter int unsigned InDivide      = 1,     // DIVCLK_DIVIDE
  parameter real         VcoMult       = 12.0,  // CLKFBOUT_MULT_F
  parameter int unsigned SysDivide     = 24,    // clk_sys_o = VCO / SysDivide
  parameter int unsigned DdrDivide     = 9      // DDR clocks = VCO / DdrDivide (<= 32)
) (
  input  wire  clk_pad_i,      // oscillator pad (clock capable pin)
  input  logic rst_i,          // MMCM reset, active high, asynchronous

  output logic clk_sys_o,
  output logic ddr_clk_o,
  output logic ddr_sys_clk_o,  // ddr_clk_o / 4, rising edges on ddr_clk_o rising edges
  output logic ddr_wclk_o,
  output logic ddr_wclk90_o,
  output logic ddr_rd_clk_o,
  output logic clk_ibuf_o,     // the oscillator after its IBUF (not buffered): other clock
                               // modules with their own BUFGCE (HyperRAM), see "Input clock"
  output logic locked_sys_o,   // MMCM_A locked: clk_sys_o, ddr_clk_o, ddr_sys_clk_o
  output logic locked_ddr_o,   // MMCM_A, MMCM_W and MMCM_B locked

  // read capture phase (MMCM_B), ddr_clk_o domain
  input  logic ps_en_i,
  input  logic ps_inc_i,
  output logic ps_done_o,
  // write phase (MMCM_A wps_clk -> MMCM_W), ddr_clk_o domain
  input  logic wps_en_i,
  input  logic wps_inc_i,
  output logic wps_done_o
);

  localparam real DdrPeriodNs = ClkInPeriodNs * real'(InDivide) * real'(DdrDivide) / VcoMult;
  // controller clock: DFI 1:4 of LiteDRAM (CLKOUT3_DIVIDE 1..128)
  localparam int unsigned DdrSysDivide = 4 * DdrDivide;

`ifndef SYNTHESIS
  localparam real VcoMhz = 1000.0 / ClkInPeriodNs * VcoMult / real'(InDivide);
  initial begin
    if (VcoMhz < 800.0 || VcoMhz > 1600.0) begin
      $error("bow_ddr_clk_xusp: VCO %f MHz outside 800..1600 MHz", VcoMhz);
    end
    if (DdrSysDivide > 128) begin
      $error("bow_ddr_clk_xusp: DdrDivide %0d too large for the CK / 4 output", DdrDivide);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input clock
  // ---------------------------------------------------------------------------
  logic clk_in_ibuf, clk_in;

  IBUF u_clk_ibuf (
    .I (clk_pad_i),
    .O (clk_in_ibuf)
  );

  BUFG u_clk_in_bufg (
    .I (clk_in_ibuf),
    .O (clk_in)
  );

  // Other clock modules (MPS4: bow_hyperram_clk_xusp) take the IBUF output and
  // add their own BUFGCE, in the clock region of this pin like u_clk_in_bufg:
  // a BUFGCE driven by a clock-capable input reaches at most three MMCMs, in
  // its own and the vertically adjacent clock regions (MPS4: MMCM_B, MMCM_A,
  // then MMCM_W above MMCM_A for its cascade), so this tree stays as it is.
  assign clk_ibuf_o = clk_in_ibuf;

  // ---------------------------------------------------------------------------
  // Lock-loss reset. An MMCM keeps its fine phase shift until RST, also through
  // a loss of lock (UG572 asks for a reset after LOCKED falls anyway), while
  // bow_ddr clears its phase counters whenever locked_ddr_o falls. So a fall of
  // any LOCKED after all three were locked resets all three MMCMs for
  // LockRstCycles input clock cycles: phases and counters return to 0
  // together. Clocked by the input clock, which runs while the MMCMs are down
  // (without it nothing locks, and the reset comes when it returns). MMCM_A
  // also makes clk_sys: on a board whose SoC reset includes locked_sys_o
  // (MPS4), any of these lock losses resets the SoC as well.
  // ---------------------------------------------------------------------------
  localparam int unsigned LockRstCycles = 64;

  (* ASYNC_REG = "TRUE" *) logic [1:0] lk_sync_q;
  logic       lk_was_q, lk_rst;
  logic [6:0] lk_cnt_q;
  logic       locked_a, locked_w, locked_b;

  always_ff @(posedge clk_in or posedge rst_i) begin
    if (rst_i) begin
      lk_sync_q <= '0;
      lk_was_q  <= 1'b0;
      lk_cnt_q  <= '0;
    end else begin
      lk_sync_q <= {lk_sync_q[0], locked_a & locked_w & locked_b};
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
  // MMCM_A: SoC clock, DDR clock, controller clock, write phase source
  // ---------------------------------------------------------------------------
  logic clkfb_a;
  logic clk_sys_mmcm, ddr_clk_mmcm, ddr_sys_clk_mmcm, wps_clk_mmcm, wps_clk;

  // Internal feedback (CLKFBOUT -> CLKFBIN): no output has to be aligned to
  // the oscillator, all DDR timing is relative to ddr_clk_o.
  MMCME4_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .CLKIN1_PERIOD        (ClkInPeriodNs),
    .DIVCLK_DIVIDE        (InDivide),
    .CLKFBOUT_MULT_F      (VcoMult),
    .CLKFBOUT_PHASE       (0.0),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKOUT0_DIVIDE_F     (real'(SysDivide)),
    .CLKOUT0_PHASE        (0.0),
    .CLKOUT0_DUTY_CYCLE   (0.5),
    .CLKOUT0_USE_FINE_PS  ("FALSE"),
    .CLKOUT1_DIVIDE       (DdrDivide),
    .CLKOUT1_PHASE        (0.0),
    .CLKOUT1_DUTY_CYCLE   (0.5),
    .CLKOUT1_USE_FINE_PS  ("FALSE"),
    .CLKOUT2_DIVIDE       (DdrDivide),
    .CLKOUT2_PHASE        (0.0),
    .CLKOUT2_DUTY_CYCLE   (0.5),
    .CLKOUT2_USE_FINE_PS  ("TRUE"),
    .CLKOUT3_DIVIDE       (DdrSysDivide),
    .CLKOUT3_PHASE        (0.0),
    .CLKOUT3_DUTY_CYCLE   (0.5),
    .CLKOUT3_USE_FINE_PS  ("FALSE"),
    .COMPENSATION         ("AUTO"),
    .STARTUP_WAIT         ("FALSE")
  ) u_mmcm_a (
    .CLKIN1       (clk_in),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clkfb_a),
    .CLKFBOUT     (clkfb_a),
    .CLKFBOUTB    (),
    .CLKOUT0      (clk_sys_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (ddr_clk_mmcm),
    .CLKOUT1B     (),
    .CLKOUT2      (wps_clk_mmcm),
    .CLKOUT2B     (),
    .CLKOUT3      (ddr_sys_clk_mmcm),
    .CLKOUT3B     (),
    .CLKOUT4      (),
    .CLKOUT5      (),
    .CLKOUT6      (),
    .LOCKED       (locked_a),
    .CLKFBSTOPPED (),
    .CLKINSTOPPED (),
    .RST          (rst_i | lk_rst),
    .PWRDWN       (1'b0),
    .PSCLK        (ddr_clk_o),
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

  BUFG u_sys_bufg     (.I (clk_sys_mmcm),     .O (clk_sys_o));
  BUFG u_ddr_bufg     (.I (ddr_clk_mmcm),     .O (ddr_clk_o));
  BUFG u_ddr_sys_bufg (.I (ddr_sys_clk_mmcm), .O (ddr_sys_clk_o));
  BUFG u_wps_bufg     (.I (wps_clk_mmcm),     .O (wps_clk));

  // ---------------------------------------------------------------------------
  // MMCM_W: write clocks, 0 and +90 deg of wps_clk
  // ---------------------------------------------------------------------------
  logic clkfb_w_mmcm, clkfb_w, rst_w;
  logic ddr_wclk_mmcm, ddr_wclk90_mmcm;

  // Held in reset until its input clock runs.
  assign rst_w = rst_i | lk_rst | ~locked_a;

  MMCME4_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .CLKIN1_PERIOD        (DdrPeriodNs),
    .DIVCLK_DIVIDE        (1),
    .CLKFBOUT_MULT_F      (real'(DdrDivide)),
    .CLKFBOUT_PHASE       (0.0),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKOUT0_DIVIDE_F     (real'(DdrDivide)),
    .CLKOUT0_PHASE        (0.0),
    .CLKOUT0_DUTY_CYCLE   (0.5),
    .CLKOUT0_USE_FINE_PS  ("FALSE"),
    .CLKOUT1_DIVIDE       (DdrDivide),
    .CLKOUT1_PHASE        (90.0),
    .CLKOUT1_DUTY_CYCLE   (0.5),
    .CLKOUT1_USE_FINE_PS  ("FALSE"),
    .COMPENSATION         ("AUTO"),
    .STARTUP_WAIT         ("FALSE")
  ) u_mmcm_w (
    .CLKIN1       (wps_clk),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clkfb_w),
    .CLKFBOUT     (clkfb_w_mmcm),
    .CLKFBOUTB    (),
    .CLKOUT0      (ddr_wclk_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (ddr_wclk90_mmcm),
    .CLKOUT1B     (),
    .CLKOUT2      (),
    .CLKOUT2B     (),
    .CLKOUT3      (),
    .CLKOUT3B     (),
    .CLKOUT4      (),
    .CLKOUT5      (),
    .CLKOUT6      (),
    .LOCKED       (locked_w),
    .CLKFBSTOPPED (),
    .CLKINSTOPPED (),
    .RST          (rst_w),
    .PWRDWN       (1'b0),
    .PSCLK        (1'b0),
    .PSEN         (1'b0),
    .PSINCDEC     (1'b0),
    .PSDONE       (),
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

  BUFG u_wfb_bufg      (.I (clkfb_w_mmcm),    .O (clkfb_w));
  BUFG u_ddr_wclk_bufg (.I (ddr_wclk_mmcm),   .O (ddr_wclk_o));
  BUFG u_ddr_w90_bufg  (.I (ddr_wclk90_mmcm), .O (ddr_wclk90_o));

  // ---------------------------------------------------------------------------
  // MMCM_B: read capture clock
  // ---------------------------------------------------------------------------
  logic clkfb_b, ddr_rd_clk_mmcm;

  MMCME4_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .CLKIN1_PERIOD        (ClkInPeriodNs),
    .DIVCLK_DIVIDE        (InDivide),
    .CLKFBOUT_MULT_F      (VcoMult),
    .CLKFBOUT_PHASE       (0.0),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKOUT0_DIVIDE_F     (real'(DdrDivide)),
    .CLKOUT0_PHASE        (0.0),
    .CLKOUT0_DUTY_CYCLE   (0.5),
    .CLKOUT0_USE_FINE_PS  ("TRUE"),
    .COMPENSATION         ("AUTO"),
    .STARTUP_WAIT         ("FALSE")
  ) u_mmcm_b (
    .CLKIN1       (clk_in),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clkfb_b),
    .CLKFBOUT     (clkfb_b),
    .CLKFBOUTB    (),
    .CLKOUT0      (ddr_rd_clk_mmcm),
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
    .LOCKED       (locked_b),
    .CLKFBSTOPPED (),
    .CLKINSTOPPED (),
    .RST          (rst_i | lk_rst),
    .PWRDWN       (1'b0),
    .PSCLK        (ddr_clk_o),
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

  BUFG u_ddr_rd_bufg (.I (ddr_rd_clk_mmcm), .O (ddr_rd_clk_o));

  assign locked_sys_o = locked_a;
  assign locked_ddr_o = locked_a & locked_w & locked_b;

endmodule
