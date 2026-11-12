// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 on the Huins MFP-VP1902-S Versal platform (AMD Versal Premium
// xcvp1902-vsva6865-2MP-e-S), with the FMC+_DDR2_HyperRam card on an FMC+ site
// (FMC+10 by default). Only the PL is used: Vivado adds a default PS wizard
// (PMC) to the device image, loaded over the board's USB JTAG (boot mode
// JTAG, docs/ddr_huins.md).
//
// The Huins documents are confidential: no FPGA ball number is in the repo.
// tools/huins_pins.py writes the pin XDC from the board netlist (local copy in
// docs/fpga/Huins_MFP-VP1902/, gitignored) and constr/pins.txt (port -> board
// net) at build time.
//
// Clocks (bow_ddr_clk_versal: two MMCME5; bow_hyperram_clk_versal: two more):
//   clk_p_i / clk_n_i  CLK_SRC = ref200 (default): the fixed 200 MHz MEMS
//                      oscillator of the board (C2_DDR4_SYS_CLK, bank 718,
//                      terminated and biased on the board), VCO 200 * 16;
//                      CLK_SRC = site (refused by tcl/build.tcl for now,
//                      constr/clk_site.xdc): the PL clock of the FMC+ site (clock
//                      module CLK0, set to 100 MHz by its DIP switches, AC
//                      coupled LVDS), VCO 100 * 32
//     clk_sys     50 MHz        SoC clock
//     ddr_clk     133.333 MHz   CK, commands, DFI adapter, PHY
//     ddr_sys_clk 33.333 MHz    LiteDRAM controller (CK / 4, same MMCM)
//     ddr_wclk / ddr_wclk90     DQS / DQ write clocks (write phase)
//     ddr_rd_clk  133.333 MHz   read capture (read phase)
//     hr_clk      100 MHz       HyperRAM (+ hr_wclk, hr_rd_clk)
//   The MPS4 frequencies: every XDC period and firmware constant carries over.
//   Fine phase steps per CK: 32 x divide (MMCME5): 768 (DDR), 1024 (HyperRAM).
// Reset: USER_RESET_N (front panel H_RESET through a TPS3808 supervisor,
// active low, ~130 ms) and MMCM_A locked: SoC reset = rst_n_i & locked_sys.
// The MMCMs start after configuration and relock by themselves (lock-loss
// reset inside the clock modules).
// UARTs: two CP2102N USB-UART bridges on the front panel (HDIO bank 408,
// 1.8 V; net names from the board's point of view of the bridge):
//   Bow32 UART0 (console, boot loader) = "UART0": FPGA TX XIO_RX_OUT0, RX XIO_TX_IN0
//   PB0 / PB1 (UART1 TX / RX after reset) = "UART1": XIO_RX_OUT1 / XIO_TX_IN1
// User components (active high on this board):
//   PA0..PA7  F_LED1..8   outputs: lit while the pin is an output driving 1;
//             IN reads back the driven level
//   PB0       XIO_RX_OUT1 bidirectional pad (pull-up)
//   PB1       XIO_TX_IN1  input only, IN = pin
//   PB2..PB4  F_PB1..3    push buttons, input only, IN = 1 while pressed
//   PB5       FMC+ site PRSNT_M2C_L, IN = 1 while a card is fitted
//   PB6, PB7  0
//   Status LEDs (not GPIO): F_LED9 heartbeat (1.5 Hz while the SoC is out of
//   reset), F_LED10 all four MMCMs locked, F_LED11 card present, F_LED12
//   MMCM_A locked (SoC clock).
//
// DDR2 memory system (bow_ddr in u_soc, DdrMem = 2: the LiteDRAM DDR2 core of
// the card, IS43DR86400E x8; window 0x8000_0000, 64 MiB) and HyperRAM
// (bow_hyperram in u_soc, S80KS2562 32 MiB, window 0x6000_0000), with their
// pads on the card's 53 pins (bow_ddr_io_xilinx / bow_hyperram_io_xilinx,
// TFromOddr: Versal XPIO takes T from an ODDRE1 in the pad site):
//   DdrLoopback / HrLoopback = 0 (default): the card's DRAM and HyperRAM
//   DdrLoopback / HrLoopback = 1: the on-chip emulators (bow_ddr_lb, 4 MiB;
//     bow_hyperram_dev, 1 MiB of UltraRAM) answer through the same pads, with
//     the level shifters isolated (OE# = 1): a bring-up build that does not
//     need the memories (the pads only drive the shifters' disabled B ports).
//
// No camera, no video and no AXI4-Lite device (as on the MPS4): the ISP and
// the CSI-2 receiver run on the SoC clock with the D-PHY inputs tied to
// LP-11, the AXI4-Lite window answers with a bus error after the timeout.

module bow32_huins_vp1902_top import bow_ddr_pkg::*; #(
  parameter              RomInitFile   = "",
  parameter              FlashInitFile = "",
  parameter real         ClkInPeriodNs = 5.0,   // 200 MHz (CLK_SRC ref200); 10.0: site clock 100 MHz
  parameter int unsigned VcoMult       = 16,    // VCO 3200 MHz (32 with the 100 MHz site clock)
  parameter bit          DdrLoopback   = 1'b0,
  parameter bit          HrLoopback    = 1'b0
) (
  input  wire        clk_p_i,          // clock input pair (see header)
  input  wire        clk_n_i,
  input  logic       rst_n_i,          // USER_RESET_N, active low

  output logic       uart0_tx_o,       // XIO_RX_OUT0
  input  logic       uart0_rx_i,       // XIO_TX_IN0
  inout  wire        uart1_tx_io,      // XIO_RX_OUT1 = PB0
  input  logic       uart1_rx_i,       // XIO_TX_IN1 = PB1

  output logic [11:0] led_o,           // F_LED1..12, active high
  input  logic [2:0]  pb_i,            // F_PB1..3, active high
  input  logic        fmc_prsnt_n_i,   // PRSNT_M2C_L of the FMC+ site, 0 = card fitted

  // DDR2 pads
  output wire        ddr_ck_p_o,
  output wire        ddr_ck_n_o,
  output wire        ddr_cke_o,
  output wire        ddr_cs_n_o,
  output wire        ddr_ras_n_o,
  output wire        ddr_cas_n_o,
  output wire        ddr_we_n_o,
  output wire [1:0]  ddr_ba_o,
  output wire [13:0] ddr_a_o,
  output wire        ddr_odt_o,
  inout  wire [7:0]  ddr_dq_io,
  inout  wire        ddr_dqs_p_io,
  inout  wire        ddr_dqs_n_io,
  output wire        ddr_ls_oe_n_o,    // level shifters OE# (card: OE_N)
  output wire        ddr_ls_dir_dq_o,  // DQ_DIR
  output wire        ddr_ls_dir_dqs_o, // DQS_DIR

  // HyperRAM pads
  output wire        hr_ck_p_o,
  output wire        hr_ck_n_o,
  output wire        hr_cs_n_o,
  output wire        hr_rst_n_o,
  inout  wire [7:0]  hr_dq_io,
  inout  wire        hr_rwds_io,
  output wire        hr_ls_oe_n_o,     // level shifters OE# (card: FMC_HB_OE_N)
  output wire        hr_ls_dir_dq_o,   // FMC_HB_DIR
  output wire        hr_ls_dir_rwds_o  // FMC_HB_RWDS_DIR
);

  localparam int unsigned SysClkHz  = 50_000_000;
  localparam int unsigned SysDivide = 64;                      // VCO 3200 MHz / 64
  localparam              SimDevice = "VERSAL_PREMIUM";

  // DDR configuration (bow32_top parameters, docs/ip/ddr.md): DDR2 x8 of the
  // card, as on the MPS4 (hw/fpga/mps4/rtl/bow32_mps4_top.sv).
  localparam int unsigned DdrMem       = 2;
  localparam int unsigned DdrDqBits    = (DdrMem == 3) ? 16 : 8;
  localparam int unsigned DdrAddrPins  = (DdrMem == 3) ? 13 : 14;
  localparam int unsigned DdrBankPins  = (DdrMem == 3) ? 3 : 2;
  localparam bit          DdrHasDm     = (DdrMem == 3);   // card: DM ball tied to GND
  localparam bit          DdrHasResetN = (DdrMem == 3);   // DDR2: no RESET#
  localparam int unsigned DdrDivide    = 24;                       // VCO 3200 MHz / 24
  localparam int unsigned DdrClkHz     = 133_333_333;
  localparam int unsigned DdrPsSteps   = 32 * DdrDivide;           // 768 fine steps per tCK
  localparam int unsigned DdrPhyKind   = DdrLoopback ? 2 : 1;      // 2 = loopback emulator
  localparam int unsigned DdrEmuBytes  = DdrLoopback ? (4 << 20) : 0;   // 4 MiB of UltraRAM

  // HyperRAM configuration (docs/ip/hyperram.md): CK 100 MHz (VCO 3200 MHz /
  // 32), 1024 fine phase steps per CK, S80KS2562 32 MiB
  localparam int unsigned HrDivide    = 32;
  localparam int unsigned HrClkHz     = 100_000_000;
  localparam int unsigned HrPsSteps   = 32 * HrDivide;
  localparam int unsigned HrPhyKind   = HrLoopback ? 2 : 1;
  localparam int unsigned HrEmuBytes  = HrLoopback ? (1 << 20) : 0;    // 1 MiB of UltraRAM

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic clk_sys, ddr_clk, ddr_sys_clk, ddr_wclk, ddr_wclk90, ddr_rd_clk, clk_in_ibuf;
  logic locked_sys, ddr_locked;
  logic ddr_ps_en, ddr_ps_inc, ddr_ps_done, ddr_wps_en, ddr_wps_inc, ddr_wps_done;

  // constr/huins_vp1902.xdc names the generated clocks after the pins of u_clk
  bow_ddr_clk_versal #(
    .ClkInPeriodNs (ClkInPeriodNs),
    .DiffIn        (1'b1),
    .InDivide      (1),
    .VcoMult       (VcoMult),
    .SysDivide     (SysDivide),
    .DdrDivide     (DdrDivide)
  ) u_clk (
    .clk_pad_i    (clk_p_i),
    .clk_pad_n_i  (clk_n_i),
    .rst_i        (1'b0),
    .clk_sys_o    (clk_sys),
    .ddr_clk_o    (ddr_clk),
    .ddr_sys_clk_o(ddr_sys_clk),
    .ddr_wclk_o   (ddr_wclk),
    .ddr_wclk90_o (ddr_wclk90),
    .ddr_rd_clk_o (ddr_rd_clk),
    .clk_ibuf_o   (clk_in_ibuf),
    .locked_sys_o (locked_sys),
    .locked_ddr_o (ddr_locked),
    .ps_en_i      (ddr_ps_en),
    .ps_inc_i     (ddr_ps_inc),
    .ps_done_o    (ddr_ps_done),
    .wps_en_i     (ddr_wps_en),
    .wps_inc_i    (ddr_wps_inc),
    .wps_done_o   (ddr_wps_done)
  );

  // HyperRAM clocks: constr/huins_vp1902.xdc names them after the pins of u_hr_clk
  logic hr_clk, hr_wclk, hr_rd_clk, hr_locked;
  logic hr_ps_en, hr_ps_inc, hr_ps_done, hr_wps_en, hr_wps_inc, hr_wps_done;

  bow_hyperram_clk_versal #(
    .ClkInPeriodNs (ClkInPeriodNs),
    .InDivide      (1),
    .VcoMult       (VcoMult),
    .HrDivide      (HrDivide)
  ) u_hr_clk (
    .clk_in_i    (clk_in_ibuf),
    .rst_i       (1'b0),
    .hr_clk_o    (hr_clk),
    .hr_wclk_o   (hr_wclk),
    .hr_rd_clk_o (hr_rd_clk),
    .locked_o    (hr_locked),
    .ps_en_i     (hr_ps_en),
    .ps_inc_i    (hr_ps_inc),
    .ps_done_o   (hr_ps_done),
    .wps_en_i    (hr_wps_en),
    .wps_inc_i   (hr_wps_inc),
    .wps_done_o  (hr_wps_done)
  );

  // Asynchronous, released through bow_rstmgr inside the SoC.
  logic rst_n;
  assign rst_n = rst_n_i & locked_sys;

  // ---------------------------------------------------------------------------
  // SoC
  // ---------------------------------------------------------------------------
  logic [7:0] gpioa_i, gpioa_o, gpioa_oe;
  logic [7:0] gpiob_i, gpiob_o, gpiob_oe;
  logic       sys_rst_n;

  ddr_io_out_t ddr_io_o;   // PHY -> pads, ddr_clk domain
  ddr_io_in_t  ddr_io_i;   // pads -> PHY, ddr_rd_clk domain
  logic [31:0] ddr_dbg;    // emulator status -> bow_ddr DBG register

  bow_hyperram_pkg::hr_io_out_t hr_io_o;   // PHY -> pads, hr_clk domain
  bow_hyperram_pkg::hr_io_in_t  hr_io_i;   // pads -> PHY, hr_rd_clk domain
  logic                         hr_rwds_pad;
  logic [31:0]                  hr_dbg;    // emulator status -> bow_hyperram DBG register

  bow32_top #(
    .ClkFreqHz     (SysClkHz),
    .BootBaud      (115_200),
    .BootWaitMs    (300),
    .RomInitFile   (RomInitFile),
    .FlashInitFile (FlashInitFile),
    .IbexRegFile   (ibex_pkg::RegFileFPGA),
    .CsiPhy        (1'b0),
    .VidClkHz      (SysClkHz),
    .DdrEn         (1'b1),
    .DdrMem        (DdrMem),
    .DdrClkHz      (DdrClkHz),
    .DdrPsSteps    (DdrPsSteps),
    .DdrPhyKind    (DdrPhyKind),
    .DdrEmuBytes   (DdrEmuBytes),
    .HrEn          (1'b1),
    .HrClkHz       (HrClkHz),
    .HrPsSteps     (HrPsSteps),
    .HrPhyKind     (HrPhyKind),
    .HrHasLs       (!HrLoopback),
    .HrMemBytes    (32 << 20),
    .HrEmuBytes    (HrEmuBytes)
  ) u_soc (
    .clk_i        (clk_sys),
    .rst_ni       (rst_n),
    .uart0_rx_i,
    .uart0_tx_o,
    .gpioa_i,
    .gpioa_o,
    .gpioa_oe_o   (gpioa_oe),
    .gpiob_i,
    .gpiob_o,
    .gpiob_oe_o   (gpiob_oe),
    // no I2C device: lines idle high
    .i2c0_scl_i   (1'b1),
    .i2c0_scl_oe_o(),
    .i2c0_sda_i   (1'b1),
    .i2c0_sda_oe_o(),
    // no camera: ISP and CSI-2 receiver on the SoC clock, output sink
    .vid_clk_i    (clk_sys),
    .vid_rst_ni   (rst_n),
    .isp_tvalid_o (),
    .isp_tready_i (1'b1),
    .isp_tdata_o  (),
    .isp_tuser_o  (),
    .isp_tlast_o  (),
    // no D-PHY: no byte clock, all lanes in LP-11
    .dphy_byte_clk_i  (1'b0),
    .dphy_byte_ce_o   (),
    .dphy_byte_rst_o  (),
    .dphy_clk_lp_i    (2'b11),
    .dphy_clk_hs_en_o (),
    .dphy_lp_i        ('1),
    .dphy_hs_en_o     (),
    .dphy_rx_data_i   ('0),
    .dphy_rx_valid_i  ('1),
    .dphy_phy_rdy_i   (1'b1),
    .dphy_phy_status_i ('0),
    .dphy_reinit_o    (),
    .dphy_burst_rst_en_o (),
    .dphy_dly_tap_o   (),
    .dphy_dly_load_o  (),
    .dphy_dly_tap_i   ('0),
    // no AXI4-Lite device: the bridge times out
    .m_axil_awaddr_o  (),
    .m_axil_awprot_o  (),
    .m_axil_awvalid_o (),
    .m_axil_awready_i (1'b0),
    .m_axil_wdata_o   (),
    .m_axil_wstrb_o   (),
    .m_axil_wvalid_o  (),
    .m_axil_wready_i  (1'b0),
    .m_axil_bresp_i   (2'b00),
    .m_axil_bvalid_i  (1'b0),
    .m_axil_bready_o  (),
    .m_axil_araddr_o  (),
    .m_axil_arprot_o  (),
    .m_axil_arvalid_o (),
    .m_axil_arready_i (1'b0),
    .m_axil_rdata_i   ('0),
    .m_axil_rresp_i   (2'b00),
    .m_axil_rvalid_i  (1'b0),
    .m_axil_rready_o  (),
    // DDR: clocks and phase steps of u_clk, pad bundle of u_ddr_io
    .ddr_sys_clk_i  (ddr_sys_clk),
    .ddr_clk_i      (ddr_clk),
    .ddr_rst_ni     (ddr_locked),
    .ddr_rd_clk_i   (ddr_rd_clk),
    .ddr_ps_en_o    (ddr_ps_en),
    .ddr_ps_inc_o   (ddr_ps_inc),
    .ddr_ps_done_i  (ddr_ps_done),
    .ddr_wps_en_o   (ddr_wps_en),
    .ddr_wps_inc_o  (ddr_wps_inc),
    .ddr_wps_done_i (ddr_wps_done),
    .ddr_io_o       (ddr_io_o),
    .ddr_io_i       (ddr_io_i),
    .ddr_dbg_i      (ddr_dbg),
    // HyperRAM: clocks and phase steps of u_hr_clk, pad bundle of u_hr_io
    .hr_clk_i       (hr_clk),
    .hr_rst_ni      (hr_locked),
    .hr_rd_clk_i    (hr_rd_clk),
    .hr_ps_en_o     (hr_ps_en),
    .hr_ps_inc_o    (hr_ps_inc),
    .hr_ps_done_i   (hr_ps_done),
    .hr_wps_en_o    (hr_wps_en),
    .hr_wps_inc_o   (hr_wps_inc),
    .hr_wps_done_i  (hr_wps_done),
    .hr_io_o        (hr_io_o),
    .hr_io_i        (hr_io_i),
    .hr_rwds_pad_i  (hr_rwds_pad),
    .hr_dbg_i       (hr_dbg),
    .sys_rst_no   (sys_rst_n),
    .core_sleep_o ()
  );

  // ---------------------------------------------------------------------------
  // DDR2: pads (+ loopback DRAM emulator)
  // ---------------------------------------------------------------------------
  logic                     ddr_lb_en;    // emulator -> pads, ddr_clk domain
  logic [1:0][MaxDq-1:0]    ddr_lb_dq;
  logic [MaxLanes-1:0][1:0] ddr_lb_dqs;

  if (DdrLoopback) begin : g_ddr_lb
    logic ddr_lb_rst_n;

    bow_rst_sync u_ddr_lb_rst (
      .clk_i  (ddr_clk),
      .rst_ni (ddr_locked),
      .rst_no (ddr_lb_rst_n)
    );

    // 4 MiB x8: RowBits = log2(DdrEmuBytes) - ColBits - BankBits = 22 - 10 - 2
    // = 10 (as on the MPS4: software keeps to the first DdrEmuBytes)
    bow_ddr_lb #(
      .Ddr3     (DdrMem == 3),
      .DqBits   (DdrDqBits),
      .BankBits (DdrBankPins),
      .RowBits  (10),
      .ColBits  (10),
      .MemBytes (DdrEmuBytes),
      .UseUram  (1'b1)
    ) u_ddr_lb (
      .clk_i    (ddr_clk),
      .rst_ni   (ddr_lb_rst_n),
      .io_i     (ddr_io_o),
      .lb_en_o  (ddr_lb_en),
      .lb_dq_o  (ddr_lb_dq),
      .lb_dqs_o (ddr_lb_dqs),
      .dbg_o    (ddr_dbg)
    );
  end else begin : g_ddr_card
    assign ddr_lb_en  = 1'b0;
    assign ddr_lb_dq  = '0;
    assign ddr_lb_dqs = '0;
    assign ddr_dbg    = '0;
  end

  // constr/huins_vp1902.xdc and constr/ddr_card.xdc refer to the instance name u_ddr_io
  bow_ddr_io_xilinx #(
    .DqBits         (DdrDqBits),
    .Lanes          (DdrDqBits / 8),
    .AddrPins       (DdrAddrPins),
    .BankPins       (DdrBankPins),
    .HasDm          (DdrHasDm),
    .HasResetN      (DdrHasResetN),
    .HasLs          (1'b1),           // DQ_DIR, DQS_DIR, OE_N
    .CkSingleEnded  (1'b1),           // CK through level shifters
    .Loopback       (DdrLoopback),
    .LsDirReadLevel (1'b1),           // TXV0108 DIR = H: DRAM -> FPGA
    .TFromOddr      (1'b1),           // Versal XPIO: T from the pad site
    .SimDevice      (SimDevice)
  ) u_ddr_io (
    .clk_i        (ddr_clk),
    .wclk_i       (ddr_wclk),
    .wclk90_i     (ddr_wclk90),
    .rd_clk_i     (ddr_rd_clk),
    .io_o_i       (ddr_io_o),
    .io_i_o       (ddr_io_i),
    .lb_en_i      (ddr_lb_en),
    .lb_dq_i      (ddr_lb_dq),
    .lb_dqs_i     (ddr_lb_dqs),
    .ck_p_o       (ddr_ck_p_o),
    .ck_n_o       (ddr_ck_n_o),
    .cke_o        (ddr_cke_o),
    .rst_n_o      (),
    .odt_o        (ddr_odt_o),
    .cs_n_o       (ddr_cs_n_o),
    .ras_n_o      (ddr_ras_n_o),
    .cas_n_o      (ddr_cas_n_o),
    .we_n_o       (ddr_we_n_o),
    .ba_o         (ddr_ba_o),
    .a_o          (ddr_a_o),
    .dq_io        (ddr_dq_io),
    .dqs_p_io     (ddr_dqs_p_io),
    .dqs_n_io     (ddr_dqs_n_io),
    .dm_o         (),
    .ls_oe_n_o    (ddr_ls_oe_n_o),
    .ls_dir_dq_o  (ddr_ls_dir_dq_o),
    .ls_dir_dqs_o (ddr_ls_dir_dqs_o)
  );

  // ---------------------------------------------------------------------------
  // HyperRAM: pads (+ loopback emulator)
  // ---------------------------------------------------------------------------
  logic            hr_lb_dq_en, hr_lb_rwds_en;
  logic [1:0][7:0] hr_lb_dq;
  logic [1:0]      hr_lb_rwds;

  if (HrLoopback) begin : g_hr_lb
    logic hr_lb_rst_n;

    bow_rst_sync u_hr_lb_rst (
      .clk_i  (hr_clk),
      .rst_ni (hr_locked),
      .rst_no (hr_lb_rst_n)
    );

    bow_hyperram_dev #(
      .MemBytes   (HrEmuBytes),
      .UseUram    (1'b1),
      .TcsmCycles (400),          // 4 us at 100 MHz (CR1[1:0] = 01)
      .WaitCycles (10000)         // 100 us: below the driver's 150 us wake-up wait
    ) u_hr_dev (
      .clk_i        (hr_clk),
      .rst_ni       (hr_lb_rst_n),
      .io_i         (hr_io_o),
      .lb_dq_en_o   (hr_lb_dq_en),
      .lb_dq_o      (hr_lb_dq),
      .lb_rwds_en_o (hr_lb_rwds_en),
      .lb_rwds_o    (hr_lb_rwds),
      .dbg_o        (hr_dbg)
    );
  end else begin : g_hr_card
    assign hr_lb_dq_en   = 1'b0;
    assign hr_lb_dq      = '0;
    assign hr_lb_rwds_en = 1'b0;
    assign hr_lb_rwds    = '0;
    assign hr_dbg        = '0;
  end

  // In loopback (HasLs = 0) the level shifter outputs of the wrapper are
  // constants: OE# = 1 (the card's shifters isolated), DIR = 0.
  bow_hyperram_io_xilinx #(
    .Loopback  (HrLoopback),
    .HasLs     (!HrLoopback),         // TXV0108 DIR / OE on the card
    .TFromOddr (1'b1),                // Versal XPIO: T from the pad site
    .SimDevice (SimDevice)
  ) u_hr_io (
    .clk_i         (hr_clk),
    .wclk_i        (hr_wclk),
    .rd_clk_i      (hr_rd_clk),
    .io_o_i        (hr_io_o),
    .io_i_o        (hr_io_i),
    .rwds_pad_o    (hr_rwds_pad),
    .lb_dq_en_i    (hr_lb_dq_en),
    .lb_dq_i       (hr_lb_dq),
    .lb_rwds_en_i  (hr_lb_rwds_en),
    .lb_rwds_i     (hr_lb_rwds),
    .ck_p_o        (hr_ck_p_o),
    .ck_n_o        (hr_ck_n_o),
    .cs_n_o        (hr_cs_n_o),
    .rst_n_o       (hr_rst_n_o),
    .dq_io         (hr_dq_io),
    .rwds_io       (hr_rwds_io),
    .ls_oe_n_o     (hr_ls_oe_n_o),
    .ls_dir_dq_o   (hr_ls_dir_dq_o),
    .ls_dir_rwds_o (hr_ls_dir_rwds_o)
  );

  // ---------------------------------------------------------------------------
  // GPIO and user components
  // ---------------------------------------------------------------------------
  // PA0..PA7: LEDs F_LED1..8 (output only)
  assign led_o[7:0] = gpioa_oe & gpioa_o;
  assign gpioa_i    = gpioa_oe & gpioa_o;

  // PB0: UART1 TX after reset, a real pad (the CP2102N input has no driver)
  IOBUF u_pad_pb0 (
    .I  (gpiob_o[0]),
    .T  (~gpiob_oe[0]),
    .O  (gpiob_i[0]),
    .IO (uart1_tx_io)
  );

  // PB1..PB7: input only; the outputs of these pins never reach a pad, so no
  // pin can drive against the CP2102N or a button
  assign gpiob_i[1]   = uart1_rx_i;
  assign gpiob_i[4:2] = pb_i;
  assign gpiob_i[5]   = ~fmc_prsnt_n_i;
  assign gpiob_i[7:6] = 2'b00;

  // Status LEDs
  logic [24:0] heartbeat_q;
  always_ff @(posedge clk_sys or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      heartbeat_q <= '0;
    end else begin
      heartbeat_q <= heartbeat_q + 1'b1;
    end
  end
  assign led_o[8]  = heartbeat_q[24];
  assign led_o[9]  = ddr_locked & hr_locked;
  assign led_o[10] = ~fmc_prsnt_n_i;
  assign led_o[11] = locked_sys;

  logic unused;
  assign unused = ^{gpiob_o[7:1], gpiob_oe[7:1]};

endmodule
