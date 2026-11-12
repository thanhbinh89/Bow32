// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 on the Arm MPS4 FPGA prototyping board (HBI0376B, AMD Virtex
// UltraScale+ XCVU13P-FHGA2104-1-E, no processing system).
//
// The board controller (MCC) configures the FPGA from the microSD card
// (MB/HBI0376B/BOW32/bow32.bit, see sdcard/) and programs the oscillators of
// sdcard/bow32.txt before it releases the resets:
//   OSCCLKA[2]   100 MHz (OSC2)  -> bow_ddr_clk_xusp: three MMCME4_ADV
//                                     clk_sys     50 MHz       SoC clock
//                                     ddr_clk     133.333 MHz  CK, commands, DFI adapter, PHY
//                                     ddr_sys_clk 33.333 MHz   LiteDRAM controller (CK / 4, same
//                                                              MMCM, edges on ddr_clk edges)
//                                     ddr_wclk / ddr_wclk90    DQS / DQ write clocks (write phase)
//                                     ddr_rd_clk  133.333 MHz  read capture (read phase)
//   IOFPGA_nRST  MCC reset of the FPGA PLLs: holds the MMCMs in reset
//   CB_nPOR      cold reset of the FPGA image
//   CB_nRST      warm reset, released last ("Releasing CB_nRST") and pulsed by
//                the MCC RESET command: SoC reset = CB_nPOR & CB_nRST & MMCM_A
//                locked. Without CB_nRST the SoC starts while the MCC has not
//                yet switched its UART multiplexer: the RX line is low, the
//                boot ROM sees a BREAK and waits in the loader (measured).
// UARTs (FT4232H on the USB-C debug port; its port 0 is the MCC console). With
// config.txt UARTMODE: 0 (Arm default) the MCC routes, measured on the board:
//   Bow32 UART0 (console, boot loader) = FPGA UART0  UART_TX_F<0>/UART_RX_F<0>  FT4232H port 1
//   PB0/PB1 (UART1 TX/RX after reset)  = FPGA UART2  UART_TX_F<2>/UART_RX_F<2>  FT4232H port 2
// (_F names are seen from the FPGA: TX_F = FPGA output; UART_x_F<1> reaches no
// port in this mode.)
// User components on GPIO (pad = *_oe ? *_o : Z, like the PMOD pins of the
// KV260 top; the inputs are synchronised inside the SoC):
//   PA0..PA7  USER_nLED[0..7]  outputs: the LED is lit while the pin is an
//             output driving 1; IN reads back the driven level (0 when input)
//   PB0       UART_TX_F<2>     bidirectional pad (pull-up)
//   PB1       UART_RX_F<2>     input only (driven by the FT4232H), IN = pin
//   PB2/PB3   USER_nPB[0]/[1]  push buttons, input only, IN = 0 while pressed
//   PB4..PB7  USER_SW[0..3]    switches, input only, IN = 1 when on
//   USER_SW[4..7] are not connected. Status LEDs (not GPIO):
//   USER_nLED[8] blinks (1.5 Hz) while the SoC is out of reset,
//   USER_nLED[9] lit while all five MMCMs are locked (DDR and HyperRAM clocks running).
// TRM "minimum RTL" (Table 3-2): MMB_IDCLK, MMB_SCK, QSPI_SCLK,
// IOFPGA_SYSWDT, WDOG_RREQ, CFG_DATAOUT, AUD_RST, USD_CLK, SH_nRST, PEX_nPERST
// low; QSPI_nCS, SMBM_nWAIT high (bow32.txt: FPGA_SCC/SMB/DDR FALSE).
//
// DDR2 memory system (bow_ddr in u_soc: LiteDRAM controller with the DDR2
// core of the card, DdrMem = 2, CSRs at 0x4000_C000; Bow32 PHY and bus
// bridges, registers at 0x4000_E000; window 0x8000_0000, 64 MiB) with its
// pads (bow_ddr_io_xilinx, constr/ddr_loopback.xdc or ddr_card.xdc):
//   DdrLoopback = 1  pads on unconnected balls of banks 64/65, read data from
//                    the on-chip DRAM emulator bow_ddr_lb (4 MiB of UltraRAM)
//                    come back through the pads (Makefile DDR_LOOPBACK=1,
//                    default)
//   DdrLoopback = 0  FMC+_DDR2_HyperRam card on the FMC+ connector (FMC VADJ
//                    1.5 V), build only until the card exists
//
// HyperRAM (bow_hyperram in u_soc: HyperBus master for the S80KS2562 of the
// same card, registers at 0x4000_F000, window 0x6000_0000, 32 MiB) with its
// clocks (bow_hyperram_clk_xusp: hr_clk 100 MHz, write clock with fine phase
// shift, read capture clock with fine phase shift, fed by the oscillator
// IBUF of u_clk (clk_ibuf_o) through its own BUFGCE: one BUFGCE drives at most
// three MMCMs and the DDR clocking has three, see mps4.xdc) and pads
// (bow_hyperram_io_xilinx, constr/hyperram_*.xdc):
//   HrLoopback = 1  pads on unconnected balls of bank 65, read data from the
//                   on-chip HyperRAM emulator bow_hyperram_dev (1 MiB of
//                   UltraRAM) come back through the pads (Makefile
//                   HR_LOOPBACK=1, the default)
//   HrLoopback = 0  the card's S80KS2562 behind its TXV0108 level shifters
//                   (FMC HB / LA pins, VADJ 1.5 V)
//
// No camera, no video and no AXI4-Lite device (as on hw/fpga/kv260): the
// ISP and the CSI-2 receiver run on the SoC clock with the D-PHY inputs tied
// to LP-11, the AXI4-Lite window answers with a bus error after the timeout.

module bow32_mps4_top import bow_ddr_pkg::*; #(
  parameter     RomInitFile   = "",
  parameter     FlashInitFile = "",
  parameter bit DdrLoopback   = 1'b1,
  parameter bit HrLoopback    = 1'b1
) (
  input  wire        osc_clk_i,        // OSCCLKA[2], 100 MHz
  input  logic       iofpga_nrst_i,    // IOFPGA_nRST, active low
  input  logic       cb_npor_i,        // CB_nPOR, active low
  input  logic       cb_nrst_i,        // CB_nRST, active low

  output logic       uart0_tx_o,       // UART_TX_F<0>
  input  logic       uart0_rx_i,       // UART_RX_F<0>
  inout  wire        uart1_tx_io,      // UART_TX_F<2> = PB0
  input  logic       uart1_rx_i,       // UART_RX_F<2> = PB1

  output logic [9:0] led_n_o,          // USER_nLED[9:0], active low
  input  logic [1:0] pb_n_i,           // USER_nPB[1:0], active low
  input  logic [3:0] sw_i,             // USER_SW[3:0]

  // TRM minimum RTL tie-offs
  output logic       mmb_idclk_o,
  output logic       mmb_sck_o,
  output logic       qspi_ncs_o,
  output logic       qspi_sclk_o,
  output logic       iofpga_syswdt_o,
  output logic       wdog_rreq_o,
  output logic       smbm_nwait_o,
  output logic       cfg_dataout_o,
  output logic       aud_rst_o,
  output logic       usd_clk_o,
  output logic       sh_nrst_o,
  output logic       pex_nperst_o,

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

  localparam int unsigned SysClkHz = 50_000_000;

  // DDR configuration (bow32_top parameters, docs/ip/ddr.md). DdrMem selects
  // the LiteDRAM core (2: litedram_ddr2, IS43DR86400E x8, CK 133.33 MHz); the
  // pads follow from it like the localparams of bow_ddr (ddr2: x8, 14 address
  // and 2 bank pins, no DM, no RESET#). The ports and constr/ddr_*.xdc are
  // those of DDR2 x8.
  localparam int unsigned DdrMem       = 2;
  localparam int unsigned DdrDqBits    = (DdrMem == 3) ? 16 : 8;
  localparam int unsigned DdrAddrPins  = (DdrMem == 3) ? 13 : 14;
  localparam int unsigned DdrBankPins  = (DdrMem == 3) ? 3 : 2;
  localparam bit          DdrHasDm     = (DdrMem == 3);   // card: DM ball tied to GND
  localparam bit          DdrHasResetN = (DdrMem == 3);   // DDR2: no RESET#
  localparam int unsigned DdrDivide    = 9;                        // VCO 1200 MHz / 9
  localparam int unsigned DdrClkHz     = 133_333_333;
  localparam int unsigned DdrPsSteps   = 56 * DdrDivide;           // 504 fine steps per tCK
  localparam int unsigned DdrPhyKind   = DdrLoopback ? 2 : 1;      // 2 = loopback emulator
  localparam int unsigned DdrEmuBytes  = DdrLoopback ? (4 << 20) : 0;   // 4 MiB of UltraRAM

  // HyperRAM configuration (bow32_top parameters, docs/ip/hyperram.md): CK 100
  // MHz (VCO 1200 MHz / 12), 672 fine phase steps per CK, S80KS2562 32 MiB
  localparam int unsigned HrDivide    = 12;
  localparam int unsigned HrClkHz     = 100_000_000;
  localparam int unsigned HrPsSteps   = 56 * HrDivide;
  localparam int unsigned HrPhyKind   = HrLoopback ? 2 : 1;
  localparam int unsigned HrEmuBytes  = HrLoopback ? (1 << 20) : 0;    // 1 MiB: 32 UltraRAM (more
                                                                        // pushes the DDR loopback
                                                                        // logic away from its pads)

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic clk_sys, ddr_clk, ddr_sys_clk, ddr_wclk, ddr_wclk90, ddr_rd_clk, osc_ibuf;
  logic locked_sys, ddr_locked;
  logic ddr_ps_en, ddr_ps_inc, ddr_ps_done, ddr_wps_en, ddr_wps_inc, ddr_wps_done;

  // constr/mps4.xdc names the generated clocks after the pins of u_clk
  bow_ddr_clk_xusp #(
    .ClkInPeriodNs (10.0),
    .InDivide      (1),
    .VcoMult       (12.0),
    .SysDivide     (24),
    .DdrDivide     (DdrDivide)
  ) u_clk (
    .clk_pad_i    (osc_clk_i),
    .rst_i        (~iofpga_nrst_i),
    .clk_sys_o    (clk_sys),
    .ddr_clk_o    (ddr_clk),
    .ddr_sys_clk_o(ddr_sys_clk),
    .ddr_wclk_o   (ddr_wclk),
    .ddr_wclk90_o (ddr_wclk90),
    .ddr_rd_clk_o (ddr_rd_clk),
    .clk_ibuf_o   (osc_ibuf),
    .locked_sys_o (locked_sys),
    .locked_ddr_o (ddr_locked),
    .ps_en_i      (ddr_ps_en),
    .ps_inc_i     (ddr_ps_inc),
    .ps_done_o    (ddr_ps_done),
    .wps_en_i     (ddr_wps_en),
    .wps_inc_i    (ddr_wps_inc),
    .wps_done_o   (ddr_wps_done)
  );

  // HyperRAM clocks: constr/mps4.xdc names them after the pins of u_hr_clk
  logic hr_clk, hr_wclk, hr_rd_clk, hr_locked;
  logic hr_ps_en, hr_ps_inc, hr_ps_done, hr_wps_en, hr_wps_inc, hr_wps_done;

  bow_hyperram_clk_xusp #(
    .ClkInPeriodNs (10.0),
    .InDivide      (1),
    .VcoMult       (12.0),
    .HrDivide      (HrDivide)
  ) u_hr_clk (
    .clk_in_i    (osc_ibuf),
    .rst_i       (~iofpga_nrst_i),
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
  assign rst_n = cb_npor_i & cb_nrst_i & locked_sys;

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
    // no I2C device on this board: lines idle high
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

  // DRAM emulator of the loopback build (bow_ddr_lb): answers the PHY's
  // commands through the pads; the card build has the real DRAM instead.
  if (DdrLoopback) begin : g_ddr_lb
    logic ddr_lb_rst_n;

    bow_rst_sync u_ddr_lb_rst (
      .clk_i  (ddr_clk),
      .rst_ni (ddr_locked),
      .rst_no (ddr_lb_rst_n)
    );

    // 4 MiB x8: RowBits = log2(DdrEmuBytes) - ColBits - BankBits = 22 - 10 - 2
    // = 10. The LiteDRAM DDR2 core addresses 64 MiB (14 row bits, byte
    // address [25:12] = row); software keeps to the first DdrEmuBytes (EMU
    // register): the emulator flags an ACT to a row above 1023 (DBG).
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

  // constr/mps4.xdc refers to the instance name u_ddr_io
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
    .LsDirReadLevel (1'b1)            // TXV0108 DIR = H: DRAM -> FPGA
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

  // HyperRAM emulator of the loopback build (bow_hyperram_dev): answers the
  // PHY's transactions through the pads; the card build has the real
  // S80KS2562 instead. 4 MiB of the 32 MiB device: software keeps to the
  // first HrEmuBytes (EMU register), a word beyond is a DBG error.
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

  bow_hyperram_io_xilinx #(
    .Loopback (HrLoopback),
    .HasLs    (!HrLoopback)         // TXV0108 DIR / OE on the card
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
  // PA0..PA7: LEDs (output only)
  assign led_n_o[7:0] = ~(gpioa_oe & gpioa_o);
  assign gpioa_i      = gpioa_oe & gpioa_o;

  // PB0: UART1 TX after reset, a real pad (the FT4232H input has no driver)
  IOBUF u_pad_pb0 (
    .I  (gpiob_o[0]),
    .T  (~gpiob_oe[0]),
    .O  (gpiob_i[0]),
    .IO (uart1_tx_io)
  );

  // PB1..PB7: input only; the outputs of these pins never reach a pad, so no
  // pin can drive against the FT4232H, a button or a switch
  assign gpiob_i[1]   = uart1_rx_i;
  assign gpiob_i[3:2] = pb_n_i;
  assign gpiob_i[7:4] = sw_i;

  // Status LEDs
  logic [24:0] heartbeat_q;
  always_ff @(posedge clk_sys or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      heartbeat_q <= '0;
    end else begin
      heartbeat_q <= heartbeat_q + 1'b1;
    end
  end
  assign led_n_o[8] = ~heartbeat_q[24];
  assign led_n_o[9] = ~(ddr_locked & hr_locked);

  // ---------------------------------------------------------------------------
  // Minimum RTL tie-offs (MPS4 TRM Table 3-2)
  // ---------------------------------------------------------------------------
  assign mmb_idclk_o     = 1'b0;
  assign mmb_sck_o       = 1'b0;
  assign qspi_ncs_o      = 1'b1;
  assign qspi_sclk_o     = 1'b0;
  assign iofpga_syswdt_o = 1'b0;
  assign wdog_rreq_o     = 1'b0;
  assign smbm_nwait_o    = 1'b1;
  assign cfg_dataout_o   = 1'b0;
  assign aud_rst_o       = 1'b0;
  assign usd_clk_o       = 1'b0;
  assign sh_nrst_o       = 1'b0;
  assign pex_nperst_o    = 1'b0;

  logic unused;
  assign unused = ^{gpiob_o[7:1], gpiob_oe[7:1]};

endmodule
