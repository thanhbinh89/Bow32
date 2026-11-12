// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 system level testbench (Verilator --binary --timing).
//
// The testbench plays the role of the host PC: it watches both UART TX lines,
// can type on both RX lines, and implements the boot ROM loader protocol to
// download an image over UART0 exactly like tools/bow32_flash.py.
//
// It also models the camera side of the KV260 camera build: the I2C devices
// (TCA9546A switch + IMX219 sensor registers), the MIPI CSI-2 stream of the
// IMX219 on the D-PHY ports of the receiver (hw/ip/csi2rx/dv/csi2_tx_model.sv
// replaces the sensor and the receive I/O of the board) and a device on the
// AXI4-Lite master port.
//
// Parameter Imx274 = 1 (sim/Makefile: model directory build/sim/obj-imx274)
// turns the camera side into the Huins MFP-VP1902 camera build instead: the
// Leopard LI-IMX274MIPI-FMC module on the Huins camera adapter. The SoC gets
// the receiver of that build (CsiLanes = 4, CsiFifoDepth = 512, CsiAfeKind =
// 2, video clock 200 MHz), csi2_tx_model runs with 4 lanes in its Versal
// XPHY mode (byte clock 180 MHz = 1440 Mbit/s per lane, PHY_RDY, BISC
// delays, RX FIFOs with hs_valid; BurstRxRst from the D-PHY's des_rst, 0
// while its CTRL.DES_RST_DIS = 1, through the Versal adapter's logic; with
// BurstRxRst = 0 the FIFO latency drifts with glitch words and wraps; one
// latency for all lanes) and an IMX274 model (I2C 0x1A, XCLR on PA7, standby
// cancel sequence, readout modes and crop, HMAX/VMAX line timing, REGHOLD,
// test patterns; see "IMX274" below) replaces the TCA9546A + IMX219.
// PRSNT_M2C_L of the camera site (PB5) reads 0; the D-PHY's AFE interface
// drives the PHY model as in the camera top (step 5 of
// docs/ip/mipi_rx_arch.md): cal_start (CMD.REINIT) and pd (AFE_CTRL.PD) its
// re-init, des_rst its BurstRxRst, and AFE_STATUS[11:8] (dphy_status_i) reads
// {PHY_RDY, DLY_RDY of every nibble, XPLL LOCKED_FB, LOCKED} = {PHY_RDY,
// PHY_RDY, 1, 1} of the model (GPIO PA4 / PA5 / PB6 / PB7 before step 4: PB6 /
// PB7 read 0 now). The other tests run on the default build only.
//
// The SoC has its DDR2 memory system (DdrEn = 1, DdrMem = 2: LiteDRAM DDR2
// controller + Bow32 PHY) wired like the MPS4 loopback build: DDR clock model
// (hw/ip/ddr/dv/ddr_clk_model.sv: CK, the controller clock CK / 4 with its
// rising edges on CK rising edges, write and read clocks with MMCM fine phase
// shift), pad model (hw/ip/ddr/dv/bow_ddr_io_sim.sv, Loopback) and the DRAM
// emulator bow_ddr_lb (4 MiB of the 64 MiB DDR2 address space). The DDR
// clocks run only in the ddr test, from the moment the boot ROM starts the
// application (the clock and pad models slow the simulation down); elsewhere
// the DDR side sees no clock (CLK_OK = 0, the window and the LiteDRAM CSRs
// answer bus errors).
//
// The SoC also has its HyperRAM (HrEn = 1) wired like the MPS4 loopback
// build: clock model (hw/ip/hyperram/dv/hyperram_clk_model.sv: CK, the write
// clock and the read capture clock with MMCM fine phase shift), pad model
// (hw/ip/hyperram/dv/bow_hyperram_io_sim.sv, Loopback) and the HyperRAM
// emulator bow_hyperram_dev (1 MiB of the 32 MiB S80KS2562). Its clocks run
// only in the hyperram test, from the application start.
//
// Plusargs:
//   +TEST=<name>      boot | load | break | flash | irq | gpio | camera | csi2 | h264 | mkv | ddr |
//                     hyperram; camera274 | csi2_274 | video274 | geo274 (Imx274 = 1 build only)
//                     (see run_test below)
//   +ROM=<vmem>       boot ROM image (required)
//   +FLASH=<vmem>     image preloaded into the flash (backdoor)
//   +IMAGE=<vmem>     image downloaded over UART by the 'load' test
//   +TIMEOUT=<cycles> abort after this many cycles (default 20M, 40M in the Imx274 build)
//   +S274_CONTCLK=<0|1> IMX274 clock lane: 1 = HS from FS to FE, 0 = HS per
//                     burst (default: 1 in camera274 and video274, 0 in csi2_274)
//   +DPHY_CORNER=<n>  IMX274 build: D-PHY timing at the limits of the
//                     specification (s274_dphy_corner): 1 = longest
//                     HS-PREPARE (default in csi2_274), 2 = shortest (default
//                     in video274); 0 = typical (camera274)
//   +S274_BURSTRST=<0|1>  IMX274 build: BurstRxRst of the PHY model, whatever
//                     the receiver says. Default: the D-PHY's des_rst (0 while
//                     its CTRL.DES_RST_DIS = 1; DES_RST_DIS is 0 from reset)
//   +S274_DESRST=<0|1> +S274_SETTLE=<ns>  csi2_274: the receive path reset
//                     (1: on, DES_RST_DIS = 0) and data lane SETTLE the
//                     firmware must have set at its receiver starts (default
//                     1 and 95 ns; sim/Makefile FW=brst0: 0, 115 ns, a
//                     model-only variant: the reset off fails on silicon)
//   +S274_VMAX_RST=<hex> IMX274 build: VMAX after reset (default 906, the
//                     value of the Huins board; video274: 905, the datasheet's)
//   +S274_GLITCH=<pct> IMX274 build: % of byte clock gate openings that add a
//                     glitch word to the PHY model's RX FIFOs (default 20)
//   +S274_GEO=<mode>  geo274: csi2_test mode to start (default 1080p)
//   +ppi_chk_report   print the counts of the PPI v1 checker of the receiver's
//                     D-PHY at the end (bow_ppi_chk; it checks in every test)
//   +WAVES            dump waves to build/sim/waves.fst (needs WAVES=1 build)

`timescale 1ns / 1ps

module tb_bow32 #(
  // camera build: 0 = KV260 (IMX219, 2 lanes, UltraScale+ D-PHY),
  // 1 = Huins MFP-VP1902 (IMX274, 4 lanes, Versal XPHY)
  parameter bit Imx274 = 1'b0
);
  import csi2_tx_pkg::*;

  // ---------------------------------------------------------------- config
  localparam int unsigned ClkFreqHz   = 50_000_000;
  localparam int unsigned Baud        = 1_000_000;          // fast UART for simulation
  localparam int unsigned BitCycles   = ClkFreqHz / Baud;   // 50
  localparam int unsigned BreakCycles = 2000;               // 40 us instead of 10 ms
  localparam real         ClkPeriodNs = 1.0e9 / ClkFreqHz;

  localparam byte unsigned SofReq = 8'hA5;
  localparam byte unsigned SofRsp = 8'hB5;
  localparam int unsigned  FlashBase = 32'h0800_0000;

  string test, rom_file, flash_file, image_file;

  // ----------------------------------------------------------- clock/reset
  logic clk = 1'b0;
  logic rst_n = 1'b1;  // pulsed low at the start of the test
  always #(ClkPeriodNs / 2) clk = ~clk;

  // Video clock of the ISP and of the CSI-2 receiver PHY logic, unrelated to
  // the CPU clock (200 MHz on the KV260 and the Huins board; slower in the
  // KV260 simulation, 200 MHz in the IMX274 build, whose 180 MHz byte clock
  // the clock lane miss detector of the receiver samples in this domain)
  localparam real         VidPeriodNs = Imx274 ? 5.0 : 9.3;
  localparam int unsigned VidClkHz    = Imx274 ? 200_000_000 : 107_526_882;  // 1 / 9.3 ns
  logic vclk = 1'b0;
  always #(VidPeriodNs / 2) vclk = ~vclk;

  // CSI-2 receiver of the camera build
  localparam int unsigned CsiLanes     = Imx274 ? 4 : 2;
  localparam int unsigned CsiFifoDepth = Imx274 ? 512 : 256;

  longint unsigned cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  // DDR2 (LiteDRAM core litedram_ddr2) at 133.33 MHz, controller clock CK / 4,
  // 504 fine phase steps per CK (MPS4 loopback build)
  localparam int unsigned DdrMem      = 2;
  localparam int unsigned DdrTckPs    = 7500;
  localparam int unsigned DdrClkHz    = 133_333_333;
  localparam int unsigned DdrPsSteps  = 504;
  localparam int unsigned DdrEmuBytes = 4 << 20;
  logic ddr_en = 1'b0;   // DDR clocks on (ddr test, from the application start)

  // HyperRAM (S80KS2562 through the loopback emulator) at 100 MHz, 672 fine
  // phase steps per CK (MPS4 loopback build), 1 MiB of emulator storage
  localparam int unsigned HrTckPs    = 10000;
  localparam int unsigned HrClkHz    = 100_000_000;
  localparam int unsigned HrPsSteps  = 672;
  localparam int unsigned HrEmuBytes = 1 << 20;
  logic hr_en = 1'b0;    // HyperRAM clocks on (hyperram test, from the application start)

  // ------------------------------------------------------------------- DUT
  logic       uart0_rx = 1'b1, uart0_tx;
  logic       uart1_rx = 1'b1;  // UART1 is the alternate function of PB0 (TX) / PB1 (RX)
  logic       sys_rst_n, core_sleep;
  logic [7:0] gpioa_o, gpioa_oe, gpiob_o, gpiob_oe;
  wire  [7:0] pad_a, pad_b;

  // I2C: open drain with pull-ups, pulled low by the DUT or a device model
  logic       i2c_scl_oe, i2c_sda_oe;
  logic       slv_scl_low = 1'b0, slv_sda_low = 1'b0;
  wire        i2c_scl = !(i2c_scl_oe || slv_scl_low);
  wire        i2c_sda = !(i2c_sda_oe || slv_sda_low);

  // AFE interface of the CSI-2 receiver's D-PHY (csi2_tx_model below) and ISP
  // output. hs_valid and ready come from the model in the IMX274 build
  // (Versal PHY), else they are those of the UltraScale+ adapter (as the model
  // drives them then too).
  logic                     dphy_hs_byte_clk, dphy_clk_gate_en, dphy_des_rst;
  logic                     dphy_clk_lprx_en, dphy_clk_hsrx_en, dphy_clk_term_en;
  logic                     dphy_pd, dphy_ready, dphy_cal_start;
  logic [1:0]               dphy_clk_lp;
  logic [CsiLanes-1:0]      dphy_lprx_en, dphy_hsrx_en, dphy_term_en, dphy_dly_own, dphy_hs_valid;
  logic [CsiLanes-1:0][1:0] dphy_lp;
  logic [CsiLanes-1:0][7:0] dphy_hs_data;
  logic [CsiLanes-1:0][8:0] dphy_dly_code, dphy_dly_q;
  wire  [CsiLanes-1:0]      dut_hs_valid = Imx274 ? dphy_hs_valid : '1;
  wire                      dut_ready    = Imx274 ? dphy_ready : 1'b1;
  // AFE_STATUS[15:8] of the D-PHY: the Versal PHY's {PHY_RDY, DLY_RDY of every nibble,
  // LOCKED_FB, LOCKED}; the model has PHY_RDY only (and no XPLL). KV260: none.
  wire  [7:0]               dut_status = Imx274 ? {4'h0, {2{dphy_ready}}, 2'b11} : 8'h00;
  logic                     isp_tvalid, isp_tuser, isp_tlast;
  logic [23:0]              isp_tdata;

  // AXI4-Lite window
  logic [15:0] axil_awaddr, axil_araddr;
  logic [2:0]  axil_awprot, axil_arprot;
  logic        axil_awvalid, axil_wvalid, axil_bready, axil_arvalid, axil_rready;
  logic [31:0] axil_wdata;
  logic [3:0]  axil_wstrb;
  logic        axil_awready = 1'b0, axil_wready = 1'b0, axil_bvalid = 1'b0;
  logic        axil_arready = 1'b0, axil_rvalid = 1'b0;
  logic [1:0]  axil_bresp = 2'b00, axil_rresp = 2'b00;
  logic [31:0] axil_rdata = '0;

  // DDR memory system <-> clock model, pad model and DRAM emulator
  logic ddr_sys_clk, ddr_clk, ddr_wclk, ddr_wclk90, ddr_rd_clk, ddr_locked;
  logic ddr_ps_en, ddr_ps_inc, ddr_ps_done, ddr_wps_en, ddr_wps_inc, ddr_wps_done;
  bow_ddr_pkg::ddr_io_out_t ddr_io_o;
  bow_ddr_pkg::ddr_io_in_t  ddr_io_i;
  logic [31:0] ddr_dbg;

  // HyperRAM <-> clock model, pad model and emulator
  logic hr_clk, hr_wclk, hr_rd_clk, hr_locked;
  logic hr_ps_en, hr_ps_inc, hr_ps_done, hr_wps_en, hr_wps_inc, hr_wps_done;
  bow_hyperram_pkg::hr_io_out_t hr_io_o;
  bow_hyperram_pkg::hr_io_in_t  hr_io_i;
  logic        hr_rwds_pad;
  logic [31:0] hr_dbg;

  bow32_top #(
    .ClkFreqHz   (ClkFreqHz),
    .BootBaud    (Baud),
    .BootWaitMs  (1),
    .BreakCycles (BreakCycles),
    .CsiLanes    (CsiLanes),
    .CsiPhy      (1'b1),
    .VidClkHz    (VidClkHz),
    .CsiFifoDepth (CsiFifoDepth),
    .CsiAfeKind  (Imx274 ? 2 : 1),
    .DdrEn       (1'b1),
    .DdrMem      (DdrMem),
    .DdrClkHz    (DdrClkHz),
    .DdrPsSteps  (DdrPsSteps),
    .DdrPhyKind  (2),
    .DdrEmuBytes (DdrEmuBytes),
    .HrEn        (1'b1),
    .HrClkHz     (HrClkHz),
    .HrPsSteps   (HrPsSteps),
    .HrPhyKind   (2),
    .HrHasLs     (1'b0),
    .HrMemBytes  (32 << 20),
    .HrEmuBytes  (HrEmuBytes)
  ) dut (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .uart0_rx_i   (uart0_rx),
    .uart0_tx_o   (uart0_tx),
    .gpioa_i      (pad_a),
    .gpioa_o      (gpioa_o),
    .gpioa_oe_o   (gpioa_oe),
    .gpiob_i      (pad_b),
    .gpiob_o      (gpiob_o),
    .gpiob_oe_o   (gpiob_oe),
    .i2c0_scl_i   (i2c_scl),
    .i2c0_scl_oe_o(i2c_scl_oe),
    .i2c0_sda_i   (i2c_sda),
    .i2c0_sda_oe_o(i2c_sda_oe),
    .vid_clk_i    (vclk),
    .vid_rst_ni   (rst_n),
    .isp_tvalid_o (isp_tvalid),
    .isp_tready_i (1'b1),
    .isp_tdata_o  (isp_tdata),
    .isp_tuser_o  (isp_tuser),
    .isp_tlast_o  (isp_tlast),
    .dphy_hs_byte_clk_i (dphy_hs_byte_clk),
    .dphy_hs_data_i     (dphy_hs_data),
    .dphy_hs_valid_i    (dut_hs_valid),
    .dphy_clk_gate_en_o (dphy_clk_gate_en),
    .dphy_des_rst_o     (dphy_des_rst),
    .dphy_clk_lp_i      (dphy_clk_lp),
    .dphy_lp_i          (dphy_lp),
    .dphy_clk_lprx_en_o (dphy_clk_lprx_en),
    .dphy_lprx_en_o     (dphy_lprx_en),
    .dphy_clk_hsrx_en_o (dphy_clk_hsrx_en),
    .dphy_hsrx_en_o     (dphy_hsrx_en),
    .dphy_clk_term_en_o (dphy_clk_term_en),
    .dphy_term_en_o     (dphy_term_en),
    .dphy_dly_code_o    (dphy_dly_code),
    .dphy_dly_own_o     (dphy_dly_own),
    .dphy_dly_q_i       (dphy_dly_q),
    .dphy_pd_o          (dphy_pd),
    .dphy_ready_i       (dut_ready),
    .dphy_cal_start_o   (dphy_cal_start),
    .dphy_status_i      (dut_status),
    .m_axil_awaddr_o  (axil_awaddr),
    .m_axil_awprot_o  (axil_awprot),
    .m_axil_awvalid_o (axil_awvalid),
    .m_axil_awready_i (axil_awready),
    .m_axil_wdata_o   (axil_wdata),
    .m_axil_wstrb_o   (axil_wstrb),
    .m_axil_wvalid_o  (axil_wvalid),
    .m_axil_wready_i  (axil_wready),
    .m_axil_bresp_i   (axil_bresp),
    .m_axil_bvalid_i  (axil_bvalid),
    .m_axil_bready_o  (axil_bready),
    .m_axil_araddr_o  (axil_araddr),
    .m_axil_arprot_o  (axil_arprot),
    .m_axil_arvalid_o (axil_arvalid),
    .m_axil_arready_i (axil_arready),
    .m_axil_rdata_i   (axil_rdata),
    .m_axil_rresp_i   (axil_rresp),
    .m_axil_rvalid_i  (axil_rvalid),
    .m_axil_rready_o  (axil_rready),
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
    .core_sleep_o (core_sleep)
  );

  // ------------------------------------------------------------------ DDR
  // MPS4 loopback build: MMCMs (ddr_clk, the LiteDRAM controller clock
  // sys_clk = CK / 4, write clocks, read capture clock with fine phase
  // shift), pads driven by the PHY and read back through the IDDRs, the DRAM
  // emulator answering on the pad wrapper's loopback inputs.
  ddr_clk_model #(
    .TckPs   (DdrTckPs),
    .PsSteps (DdrPsSteps)
  ) u_ddr_clk (
    .en_i       (ddr_en),
    .ddr_clk_o  (ddr_clk),
    .sys_clk_o  (ddr_sys_clk),
    .wclk_o     (ddr_wclk),
    .wclk90_o   (ddr_wclk90),
    .rd_clk_o   (ddr_rd_clk),
    .locked_o   (ddr_locked),
    .ps_en_i    (ddr_ps_en),
    .ps_inc_i   (ddr_ps_inc),
    .ps_done_o  (ddr_ps_done),
    .wps_en_i   (ddr_wps_en),
    .wps_inc_i  (ddr_wps_inc),
    .wps_done_o (ddr_wps_done)
  );

  logic                                         ddr_lb_en, ddr_lb_rst_n;
  logic [1:0][bow_ddr_pkg::MaxDq-1:0]           ddr_lb_dq;
  logic [bow_ddr_pkg::MaxLanes-1:0][1:0]        ddr_lb_dqs;

  bow_ddr_io_sim #(
    .DqBits   (8),
    .Lanes    (1),
    .AddrPins (14),
    .BankPins (2),
    .Loopback (1'b1)
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
    .ck_p_o       (),
    .ck_n_o       (),
    .cke_o        (),
    .rst_n_o      (),
    .odt_o        (),
    .cs_n_o       (),
    .ras_n_o      (),
    .cas_n_o      (),
    .we_n_o       (),
    .ba_o         (),
    .a_o          (),
    .dq_o         (),
    .dq_oe_o      (),
    .dq_i         ('0),
    .dqs_p_o      (),
    .dqs_n_o      (),
    .dqs_oe_o     (),
    .dqs_p_i      ('0),
    .dqs_n_i      ('1),
    .dm_o         (),
    .ls_oe_n_o    (),
    .ls_dir_dq_o  (),
    .ls_dir_dqs_o ()
  );

  bow_rst_sync u_ddr_lb_rst (
    .clk_i  (ddr_clk),
    .rst_ni (ddr_locked),
    .rst_no (ddr_lb_rst_n)
  );

  // 4 MiB x8: RowBits = 22 - 10 - 2 = 10, i.e. the first 4 MiB of the 64 MiB
  // DDR2 window (LiteDRAM row/bank/column mapping, byte address [25:12] =
  // row); the app limits its tests to EMU bytes, an ACT to a higher row is a
  // DBG error of the emulator
  bow_ddr_lb #(
    .Ddr3     (1'b0),
    .DqBits   (8),
    .BankBits (2),
    .RowBits  (10),
    .ColBits  (10),
    .MemBytes (DdrEmuBytes),
    .UseUram  (1'b0)
  ) u_ddr_lb (
    .clk_i    (ddr_clk),
    .rst_ni   (ddr_lb_rst_n),
    .io_i     (ddr_io_o),
    .lb_en_o  (ddr_lb_en),
    .lb_dq_o  (ddr_lb_dq),
    .lb_dqs_o (ddr_lb_dqs),
    .dbg_o    (ddr_dbg)
  );

  // -------------------------------------------------------------- HyperRAM
  // MPS4 loopback build: MMCMs (hr_clk, write clock, read capture clock with
  // fine phase shift), pads driven by the ODDRs and read back through the
  // IDDRs, the HyperRAM emulator answering on the pad wrapper's loopback
  // inputs (bow_hyperram_dev checks every transaction: DBG).
  hyperram_clk_model #(
    .TckPs   (HrTckPs),
    .PsSteps (HrPsSteps)
  ) u_hr_clk (
    .en_i       (hr_en),
    .hr_clk_o   (hr_clk),
    .wclk_o     (hr_wclk),
    .rd_clk_o   (hr_rd_clk),
    .locked_o   (hr_locked),
    .ps_en_i    (hr_ps_en),
    .ps_inc_i   (hr_ps_inc),
    .ps_done_o  (hr_ps_done),
    .wps_en_i   (hr_wps_en),
    .wps_inc_i  (hr_wps_inc),
    .wps_done_o (hr_wps_done)
  );

  logic                                  hr_lb_dq_en, hr_lb_rwds_en, hr_lb_rst_n;
  logic [1:0][7:0]                       hr_lb_dq;
  logic [1:0]                            hr_lb_rwds;

  bow_hyperram_io_sim #(
    .Loopback (1'b1),
    .HasLs    (1'b0)
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
    .ck_p_o        (),
    .ck_n_o        (),
    .cs_n_o        (),
    .rst_n_o       (),
    .dq_o          (),
    .dq_oe_o       (),
    .dq_i          ('0),
    .rwds_o        (),
    .rwds_oe_o     (),
    .rwds_i        (1'b0),
    .ls_oe_n_o     (),
    .ls_dir_dq_o   (),
    .ls_dir_rwds_o ()
  );

  bow_rst_sync u_hr_lb_rst (
    .clk_i  (hr_clk),
    .rst_ni (hr_locked),
    .rst_no (hr_lb_rst_n)
  );

  bow_hyperram_dev #(
    .MemBytes (HrEmuBytes),
    .UseUram  (1'b0)
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

  // ------------------------------------------------------------- GPIO pads
  // Every pad has a pull-up, like the PMOD pins on the KV260. A pad is driven
  // by the chip when *_oe = 1, else by the "external circuit" of a test
  // (ext_*_en / ext_*_val), else it floats high. The UART host below drives
  // PB1 (UART1 RX) and listens to PB0 (UART1 TX).
  logic [7:0] ext_a_en = '0, ext_a_val = '0;
  logic [7:0] ext_b_en = 8'h02, ext_b_val = '0;
  wire  [7:0] ext_b = {ext_b_val[7:2], uart1_rx, ext_b_val[0]};
  wire        uart1_tx = pad_b[0];

  assign pad_a = (gpioa_oe & gpioa_o) | (~gpioa_oe & ~(ext_a_en & ~ext_a_val));
  assign pad_b = (gpiob_oe & gpiob_o) | (~gpiob_oe & ~(ext_b_en & ~ext_b));

  always @(posedge clk) begin
    if ((gpioa_oe & ext_a_en) != 0 || (gpiob_oe & ext_b_en) != 0) begin
      $fatal(1, "GPIO pad driven by the chip and the testbench at the same time");
    end
  end

  // ------------------------------------------------------------- helpers
  function automatic bit contains(string hay, string needle);
    int n;
    n = needle.len();
    for (int i = 0; i + n <= hay.len(); i++) begin
      if (hay.substr(i, i + n - 1) == needle) return 1'b1;
    end
    return 1'b0;
  endfunction

  // -------------------------------------------------------- UART monitors
  byte unsigned rxq0[$];          // bytes received from UART0 (protocol)
  string        log0 = "", log1 = "";
  string        line0 = "", line1 = "";

  // csi2 / csi2_274 test: a failed check of the firmware, or a command
  // answered with "error" (every command of this test must succeed, except a
  // margin check that is meant to fail), stops the simulation at once;
  // camera274: an error message or a trap, except for the commands that must
  // fail (err_ok)
  bit csi2_expect_error = 1'b0;
  bit err_ok = 1'b0;

  function automatic void check_line0(string line);
    if ((test == "csi2" || test == "csi2_274") &&
        (contains(line, "[FAIL]") || contains(line, "csi2_test: FAIL") ||
         (!csi2_expect_error && line.len() >= 5 && line.substr(0, 4) == "error"))) begin
      $fatal(1, "csi2_test reported a failure: %s", line);
    end
    if (test == "camera274" && !err_ok &&
        ((line.len() >= 5 && line.substr(0, 4) == "error") || contains(line, "[trap]") ||
         contains(line, "calibration failed"))) begin
      $fatal(1, "the camera app reported a failure: %s", line);
    end
    // video274: every command must succeed, the encoder must not drop pixels
    if (test == "video274" &&
        ((line.len() >= 5 && line.substr(0, 4) == "error") || contains(line, "[trap]") ||
         contains(line, "warning") || contains(line, "calibration failed"))) begin
      $fatal(1, "the video app reported a failure: %s", line);
    end
    if (test == "mkv" && (contains(line, " FAIL") || contains(line, "mkv: FAIL") ||
                          (line.len() >= 5 && line.substr(0, 4) == "error"))) begin
      $fatal(1, "the mkv app reported a failure: %s", line);
    end
    if (test == "ddr" && (contains(line, " FAIL") || contains(line, "ddr: FAIL") ||
                          contains(line, "[trap]") ||
                          (line.len() >= 5 && line.substr(0, 4) == "error"))) begin
      $fatal(1, "the ddr app reported a failure: %s", line);
    end
    if (test == "hyperram" && (contains(line, " FAIL") || contains(line, "hyperram: FAIL") ||
                               contains(line, "[trap]") || contains(line, "failed") ||
                               (line.len() >= 5 && line.substr(0, 4) == "error"))) begin
      $fatal(1, "the hyperram app reported a failure: %s", line);
    end
  endfunction

  function automatic void log_char(int unsigned port, byte unsigned b);
    string s;
    if (b == 8'h0d) return;
    if (b == 8'h0a) begin
      if (port == 0) begin
        $display("[%0t] uart0| %s", $time, line0);
        check_line0(line0);
        line0 = "";
      end else begin
        $display("[%0t] uart1| %s", $time, line1);
        line1 = "";
      end
    end
    if (b < 8'h20 || b > 8'h7e) b = 8'h0a;  // keep binary data out of the logs
    s = string'(b);
    if (port == 0) begin
      log0 = {log0, s};
      if (b != 8'h0a) line0 = {line0, s};
    end else begin
      log1 = {log1, s};
      if (b != 8'h0a) line1 = {line1, s};
    end
  endfunction

  task automatic uart_monitor(int unsigned port);
    byte unsigned b;
    forever begin
      if (port == 0) @(negedge uart0_tx); else @(negedge uart1_tx);
      repeat (BitCycles / 2) @(posedge clk);
      for (int i = 0; i < 8; i++) begin
        repeat (BitCycles) @(posedge clk);
        b[i] = (port == 0) ? uart0_tx : uart1_tx;
      end
      repeat (BitCycles) @(posedge clk);  // stop bit
      if (port == 0) rxq0.push_back(b);
      log_char(port, b);
    end
  endtask

  initial uart_monitor(0);
  initial uart_monitor(1);

  // ------------------------------------------------------------ UART host
  // Bytes to send are queued by functions; one driver process per line
  // serialises them. Keeping the timing in a few processes keeps the C++
  // model small, because tasks with delays are inlined at every call site.
  byte unsigned txq0[$], txq1[$];
  int unsigned  brk_req = 0;  // > 0: hold UART0 RX low (BREAK) for this many cycles

  function automatic void uart_send(int unsigned port, byte unsigned b);
    if (port == 0) txq0.push_back(b);
    else txq1.push_back(b);
  endfunction

  function automatic void uart_send_str(int unsigned port, string s);
    for (int i = 0; i < s.len(); i++) uart_send(port, s[i]);
  endfunction

  task automatic uart_driver(int unsigned port);
    logic [9:0] frame;
    forever begin
      @(posedge clk);
      if (port == 0 && brk_req != 0) begin
        uart0_rx = 1'b0;
        repeat (brk_req) @(posedge clk);
        uart0_rx = 1'b1;
        repeat (BitCycles * 2) @(posedge clk);
        brk_req = 0;
      end else if ((port == 0 && txq0.size() != 0) || (port == 1 && txq1.size() != 0)) begin
        frame = {1'b1, (port == 0) ? txq0.pop_front() : txq1.pop_front(), 1'b0};
        for (int i = 0; i < 10; i++) begin
          if (port == 0) uart0_rx = frame[i];
          else uart1_rx = frame[i];
          repeat (BitCycles) @(posedge clk);
        end
      end
    end
  endtask

  initial uart_driver(0);
  initial uart_driver(1);

  task automatic uart0_break(int unsigned cycles);
    brk_req = cycles;
    while (brk_req != 0) @(posedge clk);
  endtask

  // Wait until `text` shows up on the UART (port 0/1), starting at log offset `from`.
  task automatic expect_text(int unsigned port, string text, int unsigned from = 0);
    string tail;
    forever begin
      tail = (port == 0) ? log0 : log1;
      if (from < tail.len()) tail = tail.substr(from, tail.len() - 1); else tail = "";
      if (contains(tail, text)) break;
      repeat (1000) @(posedge clk);
    end
    $display("[%0t] tb   | seen on uart%0d: \"%s\"", $time, port, text);
  endtask

  // Rest of the UART0 line that starts with `text` (first one from log
  // offset `from`), "" if there is none.
  function automatic string log0_line(string text, int unsigned from);
    int n, j;
    n = text.len();
    for (int i = from; i + n <= log0.len(); i++) begin
      if (log0.substr(i, i + n - 1) == text) begin
        j = i + n;
        while (j < log0.len() && log0[j] != 8'h0a) j++;
        return (j > i + n) ? log0.substr(i + n, j - 1) : "";
      end
    end
    return "";
  endfunction

  function automatic logic [31:0] crc32(byte unsigned data[$]);
    logic [31:0] crc;
    crc = 32'hFFFF_FFFF;
    foreach (data[i]) begin
      crc ^= {24'h0, data[i]};
      for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (32'hEDB8_8320 & {32{crc[0]}});
    end
    return ~crc;
  endfunction

  function automatic void push32(ref byte unsigned q[$], input logic [31:0] v);
    for (int i = 0; i < 4; i++) q.push_back(v[8*i +: 8]);
  endfunction

  // --------------------------------------------------- loader protocol
  function automatic void boot_send(byte unsigned cmd, byte unsigned payload[$]);
    byte unsigned body[$];
    logic [31:0]  crc;
    body.delete();  // locals are not re-initialised reliably in Verilator
    body.push_back(cmd);
    body.push_back(payload.size() & 8'hFF);
    body.push_back((payload.size() >> 8) & 8'hFF);
    foreach (payload[i]) body.push_back(payload[i]);
    crc = crc32(body);
    uart_send(0, SofReq);
    foreach (body[i]) uart_send(0, body[i]);
    for (int i = 0; i < 4; i++) uart_send(0, crc[8*i +: 8]);
  endfunction

  // Receive one response frame from UART0: returns STATUS, payload in `data`.
  task automatic boot_recv(output byte unsigned status, output byte unsigned data[$]);
    byte unsigned frame[$];  // STATUS LEN[2] PAYLOAD CRC[4]
    byte unsigned b;
    bit           started = 1'b0;
    int unsigned  need = 3;
    logic [31:0]  crc;
    frame.delete();
    started = 1'b0;
    need = 3;
    forever begin
      while (rxq0.size() == 0) @(posedge clk);
      b = rxq0.pop_front();
      if (!started) begin
        started = (b == SofRsp);
      end else begin
        frame.push_back(b);
        if (frame.size() == 3) need = 3 + {frame[2], frame[1]} + 4;
        if (frame.size() == need) break;
      end
    end
    for (int i = 0; i < 4; i++) crc[8*i +: 8] = frame[need - 4 + i];
    for (int i = 0; i < 4; i++) void'(frame.pop_back());
    if (crc != crc32(frame)) $fatal(1, "loader response CRC mismatch");
    status = frame[0];
    data = frame[3:$];
  endtask

  task automatic boot_cmd(byte unsigned cmd, byte unsigned payload[$], output byte unsigned data[$]);
    byte unsigned status;
    rxq0.delete();
    boot_send(cmd, payload);
    boot_recv(status, data);
    if (status != 0) $fatal(1, "loader command 0x%02x failed with status %0d", cmd, status);
  endtask

  // ------------------------------------------------------------ backdoor
  logic [31:0] image [32768];

  task automatic load_image_bytes(string file, output byte unsigned bytes[$]);
    int unsigned total;
    for (int i = 0; i < 32768; i++) image[i] = 32'hFFFF_FFFF;
    $readmemh(file, image);
    total = 32 + image[2];  // header + payload size
    bytes.delete();
    for (int i = 0; i < total; i++) bytes.push_back(image[i / 4][8 * (i % 4) +: 8]);
  endtask


  // ======================================================== camera board models
  // ------------------------------------------------------ IMX274 registers
  // Imx274 build: the Sony IMX274 of the LI-IMX274MIPI-FMC module, register
  // map of the datasheet (multi-byte registers LSB first, at the lower
  // address). XCLR = PA7 driven high: low puts every register back to its
  // default (among them the probe signature of the driver: MDSEL1..4 = 03 31
  // 00 09, HMAX 0x0104, VMAX 0x00906 as on the Huins board (the datasheet
  // says 0x00905: video274 runs with that, +S274_VMAX_RST=<hex>), BLKLEVEL
  // 0x32) and holds the I2C interface; the first access must come >= 20 us
  // after XCLR rises.
  // Standby cancel sequence, checked:
  //   step 1  0x3000 = 0x12, PLRD1..5, 0x310B = 0 (PLLs on, last)
  //   step 2  0x3000 = 0x00 >= 10 ms after the PLL start (+ SYS_MODE 0x303E)
  //   step 3  0x30F4 = 0 (XMSTA) >= 7 ms after step 2: the stream starts,
  //           its first frame is not output
  // 0x3000 bit 0 = 1 (STANDBY) stops the stream at once; the next start
  // must replay step 1. The waits are checked divided by s274_tdiv (64 after
  // `simfast on`, which divides the driver's waits by 64). The lanes are
  // LP-00 in reset and standby (also during step 1), LP-11 from step 2 on
  // (between bursts). Stopping the stream (standby, reset) while the CSI-2
  // receiver is enabled is an error: the drop to LP-00 is an LP error there,
  // the driver stops the receiver first.
  logic [7:0]  s274_reg [65536];
  logic [15:0] s274_ptr = '0;
  int unsigned s274_tdiv = 1;
  int unsigned s274_vmax_rst = 'h906; // VMAX after reset (board 0x906, datasheet 0x905)
  realtime     s274_t_xclr = 0.0;     // XCLR rising edge
  realtime     s274_t_pll = -1.0;     // step 1: PLLs started (-1: not since the last stop)
  realtime     s274_t_step2 = -1.0;   // step 2
  bit          s274_run = 1'b0;       // streaming: step 3 done, no standby / reset since
  int unsigned s274_ctrl_tp = 0;      // PGC / SHR writes while streaming a test pattern (AE)
  int unsigned s274_starts = 0, s274_stops = 0;
  wire         s274_xclr = gpioa_oe[7] && gpioa_o[7];

  function automatic void s274_defaults();
    for (int i = 0; i < 65536; i++) s274_reg[i] = 8'h00;
    s274_reg[16'h3000] = 8'h13;   // STANDBY, STBLOGIC, STBDV
    s274_reg[16'h3004] = 8'h03;   // MDSEL1..4 (readout mode 5, no crop)
    s274_reg[16'h3005] = 8'h31;
    s274_reg[16'h3007] = 8'h09;
    s274_reg[16'h300C] = 8'h08;   // SHR
    s274_reg[16'h3018] = 8'hA3;   // SYNCDRV
    s274_reg[16'h303E] = 8'h02;   // SYS_MODE
    s274_reg[16'h3045] = 8'h32;   // BLKLEVEL
    s274_reg[16'h304C] = 8'h10;   // PLSTMG01
    s274_reg[16'h306B] = 8'h07;   // MDPLS17
    s274_reg[16'h30F4] = 8'h01;   // XMSTA
    s274_reg[16'h30F6] = 8'h04;   // HMAX 0x0104
    s274_reg[16'h30F7] = 8'h01;
    s274_reg[16'h30F8] = 8'(s274_vmax_rst);        // VMAX 0x00906 (s274_vmax_rst)
    s274_reg[16'h30F9] = 8'(s274_vmax_rst >> 8);
    s274_reg[16'h30FA] = 8'(s274_vmax_rst >> 16);
    s274_reg[16'h310B] = 8'h11;   // STBPL_IF, STBPL_AD: PLLs off
    s274_reg[16'h3120] = 8'h80;   // PLRD1..5
    s274_reg[16'h3122] = 8'h03;
    s274_reg[16'h3129] = 8'h0D;
    s274_reg[16'h312D] = 8'h03;
    s274_reg[16'h3130] = 8'hE2;   // WRITE_VSIZE 738
    s274_reg[16'h3131] = 8'h02;
    s274_reg[16'h3132] = 8'hDE;   // Y_OUT_SIZE 734
    s274_reg[16'h3133] = 8'h02;
    s274_reg[16'h3A41] = 8'h04;   // MDSEL5
  endfunction

  // n byte register at a, LSB first
  function automatic int unsigned s274_le(int unsigned a, int unsigned n);
    int unsigned v;
    v = 0;
    for (int i = int'(n) - 1; i >= 0; i--) v = (v << 8) | 32'(s274_reg[a + 32'(i)]);
    return v;
  endfunction

  // lanes LP-11 between bursts (all standby bits clear), else LP-00
  function automatic bit s274_lp11();
    return s274_xclr && s274_reg[16'h3000] == 8'h00;
  endfunction

  function automatic void s274_stop(string why);
    s274_run = 1'b0;
    s274_stops++;
    if (dut.u_csi2rx.u_csi2rx.cfg.phy_en) begin
      $fatal(1, "IMX274: %s while the CSI-2 receiver is enabled (the lanes drop to LP-00: LP error)",
             why);
    end
    $display("[%0t] tb   | IMX274 %s: stream stopped", $time, why);
  endfunction

  function automatic void s274_start();
    if (s274_le(16'h3120, 2) != 32'h00F0 || s274_reg[16'h3122] != 8'h02 ||
        s274_reg[16'h3129] != 8'h9C || s274_reg[16'h312A] != 8'h02 || s274_reg[16'h312D] != 8'h02) begin
      $fatal(1, "IMX274: PLRD1..5 not set for INCK 24 MHz at the stream start");
    end
    if (s274_reg[16'h303E] != 8'h02) begin
      $fatal(1, "IMX274: SYS_MODE (0x303E) = %0d, the lanes run at 1440 Mbit/s with 2",
             s274_reg[16'h303E]);
    end
    s274_run = 1'b1;
    s274_starts++;
    $display("[%0t] tb   | IMX274 streaming (start %0d)", $time, s274_starts);
  endfunction

  function automatic void s274_write(logic [15:0] a, logic [7:0] v);
    realtime now;
    now = csi2_now();
    s274_reg[a] = v;
    case (a)
      16'h3000: begin
        if (v[0]) begin                                  // STANDBY: at once
          if (s274_run) s274_stop("standby");
          s274_t_pll   = -1.0;
          s274_t_step2 = -1.0;
        end else if (v == 8'h00) begin                   // step 2
          if (s274_t_pll < 0.0) begin
            $fatal(1, "IMX274: standby cancel step 2 (0x3000 = 0) without step 1 (PLLs off)");
          end
          if (now - s274_t_pll < 10.0e6 / real'(s274_tdiv)) begin
            $fatal(1, "IMX274: step 2 %0.1f us after the PLL start, needs >= %0.1f us",
                   (now - s274_t_pll) / 1000.0, 10.0e3 / real'(s274_tdiv));
          end
          if (s274_t_step2 < 0.0) s274_t_step2 = now;
          $display("[%0t] tb   | IMX274 standby cancel step 2", $time);
        end
      end
      16'h310B: begin                                    // PLLs on (step 1, after 0x3000 = 0x12)
        if (v == 8'h00 && s274_reg[16'h3000] == 8'h12) s274_t_pll = now;
      end
      16'h300A, 16'h300B, 16'h300C, 16'h300D: begin      // PGC, SHR: AE of the firmware
        if (s274_run && s274_reg[16'h303C] == 8'h11) s274_ctrl_tp++;
      end
      16'h30F4: begin                                    // XMSTA = 0: master start (step 3)
        if (!v[0]) begin
          if (s274_t_step2 < 0.0 || s274_reg[16'h3000] != 8'h00) begin
            $fatal(1, "IMX274: step 3 (0x30F4 = 0) before step 2 (0x3000 = 0)");
          end
          if (now - s274_t_step2 < 7.0e6 / real'(s274_tdiv)) begin
            $fatal(1, "IMX274: step 3 %0.1f us after step 2, needs >= %0.1f us",
                   (now - s274_t_step2) / 1000.0, 7.0e3 / real'(s274_tdiv));
          end
          if (!s274_run) s274_start();
        end
      end
      default: ;
    endcase
  endfunction

  // XCLR high for 20 us: the I2C interface answers (an earlier access is a
  // driver error)
  function automatic bit s274_i2c_ready();
    if (!s274_xclr) return 1'b0;
    if (csi2_now() - s274_t_xclr < 20_000.0) begin
      $fatal(1, "IMX274: I2C access %0.1f us after XCLR rose, needs >= 20 us",
             (csi2_now() - s274_t_xclr) / 1000.0);
    end
    return 1'b1;
  endfunction

  // I2C bytes: 16 bit index (MSB first), then data with auto increment
  function automatic logic [7:0] s274_read();
    logic [7:0] b;
    b = s274_reg[s274_ptr];
    s274_ptr++;
    return b;
  endfunction

  function automatic void s274_rx_byte(int unsigned n, logic [7:0] b);
    if (n == 0) begin
      s274_ptr[15:8] = b;
    end else if (n == 1) begin
      s274_ptr[7:0] = b;
    end else begin
      s274_write(s274_ptr, b);
      s274_ptr++;
    end
  endfunction

  initial if (Imx274) s274_defaults();

  // XCLR: reset (stream cut, registers at their defaults) while low
  bit s274_xclr_q = 1'b0;

  always @(posedge clk) begin
    if (Imx274 && s274_xclr != s274_xclr_q) begin
      s274_xclr_q = s274_xclr;
      if (s274_xclr) begin
        s274_t_xclr = csi2_now();
      end else begin
        if (s274_run) s274_stop("reset (XCLR low)");
        s274_defaults();
        s274_t_pll   = -1.0;
        s274_t_step2 = -1.0;
      end
    end
  end

  // ------------------------------------------------------------- I2C devices
  // KV260: TCA9546A switch at 0x74 (one control byte = channel enables) and,
  // behind its channel 2, the IMX219 at 0x10: 16 bit register address, then
  // data bytes with auto increment. The sensor only answers when it is powered
  // (PA7 = RPI_ENABLE driven high). The sensor stretches SCL now and then.
  // Imx274 build: only the IMX274 at 0x1A (no switch), same protocol, while
  // XCLR (PA7) has been high for 20 us (s274_* above).
  localparam logic [6:0] TcaAddr  = 7'h74;
  localparam logic [6:0] ImxAddr  = 7'h10;
  localparam logic [6:0] S274Addr = 7'h1A;

  typedef enum int {I2cIdle, I2cAddr, I2cAckA, I2cRx, I2cAckRx, I2cTx, I2cAckTx} i2c_state_e;

  logic [7:0]  imx_reg [65536];
  logic [7:0]  tca_ctrl = 8'h00;
  i2c_state_e  i2c_st = I2cIdle;
  logic        scl_q = 1'b1, sda_q = 1'b1;
  int unsigned i2c_bit = 0, i2c_nbytes = 0, i2c_stretch = 0, i2c_dev = 0;
  logic [7:0]  i2c_sh = '0;
  bit          i2c_rw = 1'b0, i2c_nack = 1'b0;
  logic [15:0] imx_ptr = '0;
  int unsigned imx_starts = 0;   // stream-on writes (0x0100 bit 0: 0 -> 1)

  wire cam_powered = gpioa_oe[7] && gpioa_o[7];

  initial begin
    for (int i = 0; i < 65536; i++) imx_reg[i] = 8'h00;
    imx_reg[16'h0000] = 8'h02;   // chip id 0x0219
    imx_reg[16'h0001] = 8'h19;
  end

  function automatic logic [7:0] i2c_tx_byte();
    logic [7:0] b;
    if (i2c_dev == 1) return tca_ctrl;
    if (i2c_dev == 3) return s274_read();
    b = imx_reg[imx_ptr];
    imx_ptr++;
    return b;
  endfunction

  function automatic void i2c_rx_byte(logic [7:0] b);
    if (i2c_dev == 1) begin
      tca_ctrl = b;
    end else if (i2c_dev == 3) begin
      s274_rx_byte(i2c_nbytes, b);
    end else if (i2c_nbytes == 0) begin
      imx_ptr[15:8] = b;
    end else if (i2c_nbytes == 1) begin
      imx_ptr[7:0] = b;
    end else begin
      if (imx_ptr == 16'h0100 && imx_reg[16'h0100][0] != b[0]) begin
        if (b[0]) begin
          imx_starts++;
          $display("[%0t] tb   | IMX219 streaming", $time);
        end else begin
          $display("[%0t] tb   | IMX219 standby", $time);
        end
      end
      imx_reg[imx_ptr] = b;
      imx_ptr++;
    end
    i2c_nbytes++;
  endfunction

  // Sampled with the CPU clock: an I2C quarter bit is >= 30 cycles.
  always @(posedge clk) begin
    logic [7:0] b;
    if (i2c_stretch != 0) begin
      i2c_stretch--;
      if (i2c_stretch == 0) slv_scl_low = 1'b0;
    end
    if (i2c_scl && scl_q && sda_q && !i2c_sda) begin            // (repeated) START
      i2c_st      = I2cAddr;
      i2c_bit     = 0;
      i2c_nbytes  = 0;
      slv_sda_low = 1'b0;
    end else if (i2c_scl && scl_q && !sda_q && i2c_sda) begin   // STOP
      i2c_st      = I2cIdle;
      slv_sda_low = 1'b0;
    end else if (!scl_q && i2c_scl) begin                        // SCL rising: sample
      case (i2c_st)
        I2cAddr, I2cRx: begin
          i2c_sh = {i2c_sh[6:0], i2c_sda};
          i2c_bit++;
        end
        I2cTx:    i2c_bit++;
        I2cAckTx: i2c_nack = i2c_sda;
        default: ;
      endcase
    end else if (scl_q && !i2c_scl) begin                        // SCL falling: drive
      case (i2c_st)
        I2cAddr: if (i2c_bit == 8) begin
          i2c_rw  = i2c_sh[0];
          if (!Imx274) begin
            i2c_dev = (i2c_sh[7:1] == TcaAddr) ? 1 :
                      (i2c_sh[7:1] == ImxAddr && tca_ctrl[2] && cam_powered) ? 2 : 0;
          end else begin
            i2c_dev = (i2c_sh[7:1] == S274Addr && s274_i2c_ready()) ? 3 : 0;
          end
          if (i2c_dev != 0) begin
            slv_sda_low = 1'b1;                                   // ACK
            i2c_st      = I2cAckA;
          end else begin
            i2c_st = I2cIdle;                                     // NACK: not for us
          end
        end
        I2cAckA, I2cAckTx: begin
          if (i2c_st == I2cAckTx && i2c_nack) begin
            slv_sda_low = 1'b0;
            i2c_st      = I2cIdle;
          end else if (i2c_rw) begin
            b           = i2c_tx_byte();
            i2c_sh      = b;
            slv_sda_low = !b[7];
            i2c_bit     = 0;
            i2c_st      = I2cTx;
          end else begin
            slv_sda_low = 1'b0;
            i2c_bit     = 0;
            i2c_st      = I2cRx;
          end
        end
        I2cRx: if (i2c_bit == 8) begin
          i2c_rx_byte(i2c_sh);
          slv_sda_low = 1'b1;
          i2c_st      = I2cAckRx;
        end
        I2cAckRx: begin
          slv_sda_low = 1'b0;
          i2c_bit     = 0;
          i2c_st      = I2cRx;
          if (i2c_dev == 2 && (i2c_nbytes % 4) == 3) begin       // clock stretching
            slv_scl_low = 1'b1;
            i2c_stretch = 150;
          end
        end
        I2cTx: begin
          if (i2c_bit == 8) begin
            slv_sda_low = 1'b0;                                   // master ACK/NACK
            i2c_st      = I2cAckTx;
          end else begin
            slv_sda_low = !i2c_sh[7 - i2c_bit];
          end
        end
        default: ;
      endcase
    end
    scl_q = i2c_scl;
    sda_q = i2c_sda;
  end

  // ------------------------------------------------------ AXI4-Lite device
  // A device of the FPGA block design behind the AXI4-Lite window, with
  // random ready/response delays: 1024 read/write words (aliased up to
  // 0x3FFF), offset 0x0004 reads 0x00000009 (fixed); offsets 0x4000-0x7FFF
  // answer SLVERR, 0x8000-0xFFFF never answer (bridge timeout).
  logic [31:0] axil_mem [1024];

  initial for (int i = 0; i < 1024; i++) axil_mem[i] = '0;

  function automatic logic [31:0] axil_read(logic [15:0] a);
    return (a[11:2] == 10'd1) ? 32'h0000_0009 : axil_mem[a[11:2]];
  endfunction

  function automatic void axil_write(logic [15:0] a, logic [31:0] d, logic [3:0] strb);
    for (int i = 0; i < 4; i++) begin
      if (strb[i]) axil_mem[a[11:2]][8*i +: 8] = d[8*i +: 8];
    end
  endfunction

  initial begin : axil_model
    logic [15:0] a;
    forever begin
      @(posedge clk);
      #1;
      if (axil_awvalid && axil_wvalid) begin
        a = axil_awaddr;
        if (a >= 16'h8000) begin
          while (axil_awvalid) @(posedge clk);          // no answer
        end else begin
          repeat ($urandom % 4) @(posedge clk);
          #1;
          axil_awready = 1'b1;
          axil_wready  = 1'b1;
          @(posedge clk);
          #1;
          axil_awready = 1'b0;
          axil_wready  = 1'b0;
          if (a < 16'h4000) axil_write(a, axil_wdata, axil_wstrb);
          repeat ($urandom % 4) @(posedge clk);
          #1;
          axil_bresp  = (a >= 16'h4000) ? 2'b10 : 2'b00;
          axil_bvalid = 1'b1;
          do @(posedge clk); while (!axil_bready);
          #1;
          axil_bvalid = 1'b0;
        end
      end else if (axil_arvalid) begin
        a = axil_araddr;
        if (a >= 16'h8000) begin
          while (axil_arvalid) @(posedge clk);
        end else begin
          repeat ($urandom % 4) @(posedge clk);
          #1;
          axil_arready = 1'b1;
          @(posedge clk);
          #1;
          axil_arready = 1'b0;
          repeat ($urandom % 4) @(posedge clk);
          #1;
          axil_rdata  = (a >= 16'h4000) ? 32'hDEAD_BEEF : axil_read(a);
          axil_rresp  = (a >= 16'h4000) ? 2'b10 : 2'b00;
          axil_rvalid = 1'b1;
          do @(posedge clk); while (!axil_rready);
          #1;
          axil_rvalid = 1'b0;
        end
      end
    end
  end

  // ------------------------------------------------------ IMX219 CSI-2 stream
  // csi2_tx_model plays the sensor and the D-PHY receive I/O of the board
  // (2 data lanes). The sensor:
  //   * keeps all lanes at LP-00 after power-up until the first stream-on
  //     (0x0100 = 1), then LP-11 whenever it does not stream;
  //   * takes the output format (0x018c) and size (0x016c..0x016f) at
  //     stream-on, the test pattern and its colour, exposure, analog gain
  //     and orientation at every frame start;
  //   * sends per frame: FS (frame number 1..4), 2 embedded data lines (DT
  //     0x12, WC = width), the lines RAW10 (DT 0x2B) or RAW8 (DT 0x2A), FE;
  //     one packet per HS burst, the data lanes go to LP-11 after every
  //     burst; the clock lane enters HS before the FS and goes back to LP-11
  //     after the FE (vertical blanking), like the real IMX219;
  //   * finishes the current frame after a stream-off.
  // The timing is compressed: bursts back to back and a short vertical
  // blanking, not the line / frame length of 0x0160 / 0x0162. A stream-on
  // with output size 0 (the probe of the firmware, power-up registers)
  // sends no frame. Pixels: cam_pixel().
  localparam int unsigned VblankNs = 20_000;
  localparam logic [7:0]  BadSync  = 8'hB9;      // sync byte with its first bit flipped

  // (Imx274 build: 4 lanes, Versal PHY mode, delays in the video clock domain)
  csi2_tx_model #(.Lanes(CsiLanes)) u_csi (
    .hs_byte_clk_o (dphy_hs_byte_clk),
    .hs_data_o     (dphy_hs_data),
    .hs_valid_o    (dphy_hs_valid),
    .clk_gate_en_i (dphy_clk_gate_en),
    .des_rst_i     (dphy_des_rst),
    .clk_lp_o      (dphy_clk_lp),
    .lp_o          (dphy_lp),
    .clk_hsrx_en_i (dphy_clk_hsrx_en),
    .hsrx_en_i     (dphy_hsrx_en),
    .clk_term_en_i (dphy_clk_term_en),
    .term_en_i     (dphy_term_en),
    .dly_code_i    (dphy_dly_code),
    .dly_own_i     (dphy_dly_own),
    .dly_q_o       (dphy_dly_q),
    .pd_i          (dphy_pd),
    .cal_start_i   (dphy_cal_start),
    .ready_o       (dphy_ready),
    .ctrl_clk_i    (Imx274 ? vclk : 1'b0),
    .ctrl_rst_ni   (rst_n)
  );

  // The PPI v1 outputs of the receiver's D-PHY that its controller does not use, checked on
  // every lp clock edge (hw/ip/dphy_rx/dv/bow_ppi_chk.sv): silent unless one fails, which
  // stops the test; +ppi_chk_report prints the counts at the end
  bind bow_dphy_rx bow_ppi_chk #(.Lanes (Lanes)) u_ppi_chk (
    .lp_clk_i     (lp_clk_i),
    .lp_rst_ni    (lrst_n),
    .byte_clk_i   (afe_hs_byte_clk_i),
    .byte_rst_ni  (brst_n),
    .ppi_hs_i     (ppi_hs_o),
    .ppi_lp_i     (ppi_lp_o),
    .ppi_lp_clk_i (ppi_lp_clk_o),
    .lane_en_i    (lane_en),
    .lp_i         (lp_st),
    .clk_force_i  (clk_force),
    .byte_ce_i    (byte_ce)
  );

  // The AFE v1 outputs of the receiver's D-PHY (hw/ip/dphy_rx/dv/bow_afe_chk.sv), the same
  // way: des_rst = ~gate at the same lp clock edge, term_en = hsrx_en, lprx_en / lane_pd,
  // OWN only while ready, the tie-offs, the reset values while reset is asserted;
  // +afe_chk_report prints the counts at the end
  bind bow_dphy_rx bow_afe_chk #(
    .Lanes (Lanes), .TrimW (TrimW), .AfePdRst (AfePdRst)
  ) u_afe_chk (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .lp_clk_i       (lp_clk_i),
    .lp_rst_ni      (lrst_n),
    .gate_i         (afe_clk_gate_en_o),
    .des_rst_i      (afe_des_rst_o),
    .des_rst_en_i   (des_rst_en),
    .clk_hsrx_en_i  (afe_clk_hsrx_en_o),
    .hsrx_en_i      (afe_hsrx_en_o),
    .clk_term_en_i  (afe_clk_term_en_o),
    .term_en_i      (afe_term_en_o),
    .pd_i           (afe_pd_o),
    .clk_lprx_en_i  (afe_clk_lprx_en_o),
    .lprx_en_i      (afe_lprx_en_o),
    .clk_lane_pd_i  (afe_clk_lane_pd_o),
    .lane_pd_i      (afe_lane_pd_o),
    .ready_i        (phy_rdy_sys),
    .dly_own_i      (afe_dly_own_o),
    .clk_dly_code_i (afe_clk_dly_code_o),
    .clk_dly_own_i  (afe_clk_dly_own_o),
    .mon_en_i       (afe_mon_en_o),
    .mon_code_i     (afe_mon_code_o),
    .trim_i         (afe_trim_o),
    .tst_mode_i     (afe_tst_mode_o),
    .tst_data_i     (afe_tst_data_o),
    .atb_sel_i      (afe_atb_sel_o)
  );

  // Frame format of the stream (stream-on) and of the frame (frame start)
  int unsigned cf_w = 0, cf_h = 0, cf_bits = 10, cf_num = 0;
  int unsigned cf_tp = 0, cf_exp = 0, cf_again = 0;
  logic [1:0]  cf_orient = '0;
  logic [9:0]  cf_colour [4] = '{0, 0, 0, 0};    // test pattern 1: R, Gr, B, Gb
  int unsigned cam_frames = 0;

  // Error injection into the line packets of the next frame (csi2 test):
  // line 8 with a header bit flipped (the ECC corrects it), line 16 with a
  // payload bit flipped (CRC error), and from line 24 on the first line on
  // which a bad sync byte on lane 1 cannot lead to a later false lock (lane
  // 1 sync error; skew: only lane 0 locked, the burst is dropped).
  bit inj_req = 1'b0, inj_frame = 1'b0, inj_sent = 1'b0;
  // camera test knobs ("!mute" / "!unmute", "!fe" / "!nofe" steps): the
  // sensor takes its registers but sends nothing; an FE without FS after
  // every frame (FRAME error, not a sampling problem)
  bit imx_mute = 1'b0, imx_fe_extra = 1'b0;
  // frame timing of the IMX219 model: LP-11 after every line, vertical blanking
  int unsigned imx_gap_ns = 0, imx_vblank_ns = VblankNs;

  function automatic bit imx_streaming();
    return imx_reg[16'h0100][0] && cam_powered && !imx_mute;
  endfunction

  // Pixels: colour bars (0x0600 = 2), a solid colour (1), else a smooth
  // scene whose level follows exposure x analog gain, with a colour cast
  // (R 5/8, B 13/16).
  function automatic logic [9:0] cam_pixel(int unsigned x, int unsigned y);
    int unsigned c, bar;
    longint unsigned lin, v;
    bit on;
    c = {y[0] ^ cf_orient[1], x[0] ^ cf_orient[0]};     // 0 R, 1 Gr, 2 Gb, 3 B
    if (cf_tp == 1) return cf_colour[(c == 2) ? 3 : (c == 3) ? 2 : c];
    if (cf_tp == 2) begin
      bar = (x * 8) / cf_w;
      on  = (c == 0) ? (bar inside {0, 1, 4, 5}) : (c == 3) ? (bar inside {0, 2, 4, 6}) : (bar < 4);
      return on ? 10'h3C0 : 10'h040;
    end
    lin = 32 + (x * 192) / cf_w + (y * 32) / cf_h;
    if (c == 0) lin = lin * 5 / 8;
    if (c == 3) lin = lin * 13 / 16;
    v = lin * cf_exp * (65536 / (256 - cf_again)) / (256 * 512);
    return 10'(64 + (v > 959 ? 959 : v));
  endfunction

  // Payload of line y in the output format of the stream
  function automatic csi2_bytes_t line_payload(int unsigned y);
    logic [9:0]  px [$];
    csi2_bytes_t b;
    px.delete();
    b.delete();
    for (int unsigned x = 0; x < cf_w; x++) px.push_back(cam_pixel(x, y));
    if (cf_bits == 10) return csi2_raw10(px);
    foreach (px[i]) b.push_back(px[i][9:2]);
    return b;
  endfunction

  // Embedded data line: format code 0x0A, the frame number, filler 0x07
  function automatic csi2_bytes_t emb_payload();
    csi2_bytes_t b;
    b.delete();
    for (int unsigned i = 0; i < cf_w; i++) begin
      b.push_back((i == 0) ? 8'h0A : (i == 1) ? 8'(cf_num) : 8'h07);
    end
    return b;
  endfunction

  // Would the sync search of the receiver (a zero byte, then 0xB8, at any
  // bit offset; bow_dphy_align) lock on lane 1 of a burst with this packet
  // although the lane's sync byte is `sync`? Bits after the HS-zero: the
  // sync byte, the packet bytes of lane 1 (1, 1 + lanes, ...), then the
  // HS-trail constant.
  function automatic bit lane1_locks(csi2_bytes_t pkt, logic [7:0] sync, int unsigned lanes = 2);
    byte unsigned lane [$];
    logic [15:0]  w;
    logic         trail;
    lane.delete();
    lane.push_back(sync);
    for (int unsigned k = 1; k < pkt.size(); k += lanes) lane.push_back(pkt[k]);
    w = '0;
    foreach (lane[i]) begin
      for (int j = 0; j < 8; j++) begin
        w = {lane[i][j], w[15:1]};          // w[15] = newest bit
        if (w == 16'hB800) return 1'b1;
      end
    end
    trail = ~lane[lane.size() - 1][7];
    for (int j = 0; j < 16; j++) begin
      w = {trail, w[15:1]};
      if (w == 16'hB800) return 1'b1;
    end
    return 1'b0;
  endfunction

  // Queue one frame in the TX model (with the injected errors if requested)
  function automatic void push_frame();
    csi2_flags_t f, fl;
    csi2_bytes_t pay, pkt;
    int unsigned dt;
    bit          bad_done;
    logic [15:0] crc;
    f         = csi2_flags();
    dt        = (cf_bits == 8) ? 32'h2A : 32'h2B;
    inj_frame = inj_req;
    inj_req   = 1'b0;
    bad_done  = 1'b0;
    u_csi.push_short(0, 8'h00, cf_num, f);                              // FS
    for (int unsigned i = 0; i < 2; i++) u_csi.push_long(0, 8'h12, emb_payload(), f);
    for (int unsigned y = 0; y < cf_h; y++) begin
      pay = line_payload(y);
      fl  = f;
      if (inj_frame && y == 8) fl.hdr_flip_a = 8'sd9;                   // WC bit 1
      if (inj_frame && y == 16) fl.pay_flip = 3;
      if (inj_frame && y >= 24 && !bad_done) begin
        pkt = csi2_header(0, dt, pay.size());
        foreach (pay[i]) pkt.push_back(pay[i]);
        crc = csi2_crc(pay);
        pkt.push_back(crc[7:0]);
        pkt.push_back(crc[15:8]);
        if (!lane1_locks(pkt, BadSync)) begin
          fl.sync[1] = BadSync;
          bad_done   = 1'b1;
        end
      end
      u_csi.push_long(0, dt, pay, fl);
      if (imx_gap_ns != 0) u_csi.idle(imx_gap_ns);
    end
    u_csi.push_short(0, 8'h01, cf_num, f);                              // FE
    if (imx_fe_extra) u_csi.push_short(0, 8'h01, cf_num, f);           // FE without FS
    if (inj_frame && !bad_done) $fatal(1, "IMX219: no line for the bad sync byte");
  endfunction

  // Registers taken at stream-on
  function automatic void stream_setup();
    cf_w    = {imx_reg[16'h016c], imx_reg[16'h016d]};
    cf_h    = {imx_reg[16'h016e], imx_reg[16'h016f]};
    cf_bits = (imx_reg[16'h018c] == 8'h08) ? 8 : 10;
    cf_num  = 0;
  endfunction

  // Registers taken at every frame start
  function automatic void frame_setup();
    cf_tp     = {imx_reg[16'h0600], imx_reg[16'h0601]};
    cf_exp    = {imx_reg[16'h015a], imx_reg[16'h015b]};
    cf_again  = imx_reg[16'h0157] > 232 ? 232 : imx_reg[16'h0157];
    cf_orient = imx_reg[16'h0172][1:0];
    for (int i = 0; i < 4; i++) begin
      cf_colour[i] = {imx_reg[16'h0602 + 2 * i][1:0], imx_reg[16'h0603 + 2 * i]};
    end
    cf_num    = cf_num % 4 + 1;
  endfunction

  // The firmware must have programmed a consistent frame format.
  function automatic void check_sensor_setup();
    int unsigned x0, x1, y0, y1, fmt, fll, exposure;
    x0 = {imx_reg[16'h0164], imx_reg[16'h0165]};
    x1 = {imx_reg[16'h0166], imx_reg[16'h0167]};
    y0 = {imx_reg[16'h0168], imx_reg[16'h0169]};
    y1 = {imx_reg[16'h016a], imx_reg[16'h016b]};
    if (x1 - x0 + 1 != cf_w || y1 - y0 + 1 != cf_h || x0[0] || y0[0]) begin
      $fatal(1, "IMX219: crop %0d..%0d x %0d..%0d does not match output %0dx%0d", x0, x1, y0, y1,
             cf_w, cf_h);
    end
    // CSI_DATA_FORMAT_A (0x018c/0x018d) and OPPXCK_DIV (0x0309) = bits per pixel
    fmt = imx_reg[16'h018c];
    if (!(fmt inside {8, 10}) || imx_reg[16'h018d] != fmt || imx_reg[16'h0309] != fmt) begin
      $fatal(1, "IMX219: output format 0x018c/0x018d/0x0309 = %0d/%0d/%0d, not RAW10 or RAW8", fmt,
             imx_reg[16'h018d], imx_reg[16'h0309]);
    end
    if (imx_reg[16'h0114] != 8'h01 || imx_reg[16'h030d] != 8'h72) begin
      $fatal(1, "IMX219: 2 lane / PLL setup missing");
    end
    // the sensor would stretch the frame to exposure + 4 lines
    fll      = {imx_reg[16'h0160], imx_reg[16'h0161]};
    exposure = {imx_reg[16'h015a], imx_reg[16'h015b]};
    if (exposure + 4 > fll) $fatal(1, "IMX219: exposure %0d > frame length %0d - 4", exposure, fll);
    $display("[%0t] tb   | IMX219 stream %0dx%0d RAW%0d crop (%0d,%0d) FLL %0d exp %0d", $time,
             cf_w, cf_h, cf_bits, x0, y0, fll, exposure);
  endfunction

  // The sensor: standby, stream-on (format), frames until a stream-off. The
  // clock lane stays in HS during a frame: continuous clock mode of the TX
  // model for the frame, back to bursts (clock exit) after the FE.
  int unsigned imx_cur_start = 0;
  bit          imx_powered_up = 1'b0;

  initial begin : imx_stream
    if (!Imx274) forever begin
      while (!imx_streaming()) #1000;
      if (!imx_powered_up) begin
        u_csi.idle(1000);              // the lanes leave LP-00
        imx_powered_up = 1'b1;
      end
      imx_cur_start = imx_starts;
      stream_setup();
      if (cf_w == 0 || cf_h == 0) begin
        while (imx_streaming() && imx_starts == imx_cur_start) #1000;
      end else begin
        check_sensor_setup();
        while (imx_streaming() && imx_starts == imx_cur_start) begin
          frame_setup();
          while (u_csi.busy()) #100;
          u_csi.contclk = 1'b1;
          push_frame();
          while (u_csi.busy()) #100;
          u_csi.contclk = 1'b0;
          cam_frames++;
          if (inj_frame) inj_sent = 1'b1;
          #(imx_vblank_ns);
        end
      end
    end
  end

  // ------------------------------------------------------ IMX274 CSI-2 stream
  // Imx274 build: csi2_tx_model (4 lanes, Versal PHY mode) plays the sensor
  // and the XPHY receive I/O; the lanes are LP-00 / LP-11 as above. While
  // streaming, the sensor latches the frame format at every frame start
  // (s274_latch: readout mode, crop, timing, controls; REGHOLD keeps the
  // last; SHR takes effect one frame later than the others) and sends, one
  // packet per HS burst, in real time: FS (frame number 1, 2, ...), then one
  // CSI-2 line slot of 2 HMAX periods (72 MHz) per packet, starting 1 HMAX
  // after the FS: the embedded data line (DT 0x12), WRITE_VSIZE - Y_OUT_SIZE
  // optical black lines (DT 0x37, BLKLEVEL) and Y_OUT_SIZE RAW10 lines (DT
  // 0x2B), FE after the last line; the next FS comes HMAX x VMAX after this
  // one. A change of readout mode, vertical crop or flip (mode transition)
  // and the first frame after a start are not output (blank frame period).
  // The clock lane stays in HS from the FS to the FE (s274_contclk = 1, like
  // the IMX219) or enters HS for every burst (0). A stop (standby, reset)
  // lets the burst in progress end, cuts the frame (no FE), then the lanes
  // drop to LP-00.
  int unsigned f274_mode = 5, f274_hbin = 3, f274_w = 0, f274_h = 0, f274_ob = 0;
  int unsigned f274_hmax = 260, f274_vmax = 2309, f274_tp = 0;
  int unsigned f274_pgc = 0, f274_dgain = 0, f274_black = 50, f274_exp = 4, f274_exp_q = 4;
  bit          f274_vflip = 1'b0;
  logic [79:0] f274_sig = '0;          // registers of a mode transition, last frame
  int unsigned f274_num = 0;           // FS frame number
  int unsigned s274_frames = 0, s274_late = 0;
  bit          s274_contclk = 1'b1;
  // csi2_274: one CRC error (a payload bit of image line 0) in the n-th frame
  // output after the next stream start (0: none); cleared when sent
  int unsigned s274_crc_frame = 0, s274_crc_sent = 0;

  localparam logic [9:0] S274On  = 10'h3C0;   // colour bars, as the IMX219 model
  localparam logic [9:0] S274Off = 10'h040;

  // Latch the frame format (frame start; first: the first frame after a
  // start) and check that the driver programmed a consistent readout mode,
  // crop and timing. Returns 1 when this frame is not output: a mode
  // transition, or an inconsistent format while streaming (a frame start
  // between two register writes of the driver; counted in s274_bad). An
  // inconsistent format at the stream start is an error, and so is one
  // while streaming outside a window around a `mode` command (s274_win_cmd
  // while the test waits for its answer, then s274_win more frame starts).
  // The driver restarts the stream for a new mode, and writes a flip under
  // REGHOLD (held registers stay out of the frame format until it is
  // cleared), so none is expected even there: flips get no window.
  int unsigned s274_bad = 0, s274_win = 0, s274_latched = 0;   // latched: stream starts checked
  bit          s274_win_cmd = 1'b0;

  function automatic bit s274_latch(bit first);
    int unsigned mode, hbin, hstep, veff, ob, base4, vcutm, md5, hmax_min, shr_min;
    int unsigned x0, x1, w, vcut, kept, start, wsize, ysize, vmax_min, hmax, vmax, shr, pgc;
    logic [11:0] pos;
    logic [79:0] sig;
    bit          hcrop, vcrop, vflip, trans, win;
    string       err;
    win = s274_win_cmd || s274_win != 0;
    if (!first && !s274_win_cmd && s274_win != 0) s274_win--;
    if (s274_reg[16'h302D][0] && !first) return 1'b0;               // REGHOLD
    err  = "";
    mode = 5; hbin = 3; hstep = 12; veff = 734; ob = 4; base4 = 'h09; vcutm = 3; md5 = 'h04;
    hmax_min = 260; shr_min = 8;
    case ({s274_reg[16'h3004], s274_reg[16'h3005], s274_reg[16'h3006]})
      24'h033100: ;
      24'h022100: begin mode = 3; hbin = 2; hstep = 24; veff = 1094; ob = 8; base4 = 'h11;
                        vcutm = 2; md5 = 'h08; end
      24'h010100: begin mode = 1; hbin = 1; hstep = 12; veff = 2174; ob = 8; base4 = 'h02;
                        vcutm = 1; md5 = 'h08; hmax_min = 263; shr_min = 12; end
      default: err = $sformatf("MDSEL1..3 = %02x %02x %02x is not readout mode 1, 3 or 5",
                               s274_reg[16'h3004], s274_reg[16'h3005], s274_reg[16'h3006]);
    endcase
    if (err == "" && (s274_reg[16'h30E2] != 8'(vcutm) || s274_reg[16'h3A41] != 8'(md5) ||
                      s274_reg[16'h306B] != 8'h05 || s274_reg[16'h30EE] != 8'h01)) begin
      err = $sformatf("VCUTMODE / MDSEL5 / MDPLS17 / PSMOVEN %02x %02x %02x %02x do not match mode %0d",
                      s274_reg[16'h30E2], s274_reg[16'h3A41], s274_reg[16'h306B], s274_reg[16'h30EE],
                      mode);
    end
    // horizontal: HTRIMMING in pixels before binning, whole steps
    hcrop = s274_reg[16'h3037][0];
    x0    = s274_le(16'h3038, 2) & 32'h1FFF;
    x1    = s274_le(16'h303A, 2) & 32'h1FFF;
    if (err == "" && hcrop && (x0 % hstep != 0 || x1 % hstep != 0 || x1 > 3864 || x1 < x0 + 144 ||
                               (x1 - x0) % hbin != 0)) begin
      err = $sformatf("HTRIMMING %0d..%0d (mode %0d: steps of %0d, END <= 3864, >= 144 wide)", x0,
                      x1, mode, hstep);
    end
    w = hcrop ? (x1 - x0) / hbin : 3864 / hbin;
    if (err == "" && w % 4 != 0) err = $sformatf("%0d pixels per line, RAW10 needs a multiple of 4", w);
    // vertical: VWIDCUT lines cut on both sides, window start 2 x VWINPOS
    // (two's complement, negative with the vertical flip)
    vflip = s274_reg[16'h301A][0];
    vcrop = s274_reg[16'h30DD][0];
    vcut  = s274_le(16'h30DE, 2) & 32'h7FF;
    pos   = 12'(s274_le(16'h30E0, 2));
    kept  = veff;
    if (vcrop) begin
      start = 2 * ((pos[11] ? 32'(-pos) : 32'(pos)) & 32'hFFF);
      kept  = (2 * vcut < veff) ? veff - 2 * vcut : 0;
      if (err == "" && (kept == 0 || start + kept > veff || (pos != 0 && pos[11] != vflip))) begin
        err = $sformatf("vertical crop VWIDCUT %0d VWINPOS %03x (flip %0d) outside the %0d lines of mode %0d",
                        vcut, pos, vflip, veff, mode);
      end
    end
    if (err == "" && s274_reg[16'h3007] != 8'(base4 | (vcrop ? 'hA0 : 0))) begin
      err = $sformatf("MDSEL4 = %02x, mode %0d %s crop needs %02x", s274_reg[16'h3007], mode,
                      vcrop ? "with" : "without", base4 | (vcrop ? 'hA0 : 0));
    end
    wsize = s274_le(16'h3130, 2) & 32'h1FFF;
    ysize = s274_le(16'h3132, 2) & 32'h1FFF;
    if (err == "" && (ysize != kept || wsize != ysize + ob)) begin
      err = $sformatf("WRITE_VSIZE %0d / Y_OUT_SIZE %0d, expected %0d / %0d (mode %0d, %0d OB lines)",
                      wsize, ysize, kept + ob, kept, mode, ob);
    end
    // timing and controls
    hmax = s274_le(16'h30F6, 2);
    vmax = s274_le(16'h30F8, 3) & 32'hFFFFF;
    if (mode == 1 && hcrop && (x1 - x0 + 15) / 16 + 22 > hmax_min) hmax_min = (x1 - x0 + 15) / 16 + 22;
    vmax_min = 2 * (1 + wsize) + 13;
    if (err == "" && (hmax < hmax_min || vmax < vmax_min)) begin
      err = $sformatf("HMAX %0d / VMAX %0d below the minimum %0d / %0d", hmax, vmax, hmax_min,
                      vmax_min);
    end
    shr = s274_le(16'h300C, 2);
    if (err == "" && (shr < shr_min || shr + 4 > vmax || s274_le(16'h300E, 2) != 0)) begin
      err = $sformatf("SHR %0d outside %0d..VMAX - 4 = %0d, or SVR %0d != 0", shr, shr_min, vmax - 4,
                      s274_le(16'h300E, 2));
    end
    pgc = s274_le(16'h300A, 2) & 32'h7FF;
    if (err == "" && (pgc > 1957 || s274_reg[16'h3012] > 8'd6)) begin
      err = $sformatf("PGC %0d (max 1957) / DGAIN %0d (max 6)", pgc, s274_reg[16'h3012]);
    end
    if (err == "" && (!(s274_reg[16'h303C] inside {8'h00, 8'h11}) || s274_reg[16'h303D] > 8'd11)) begin
      err = $sformatf("test pattern registers 0x303C/D = %02x %02x", s274_reg[16'h303C],
                      s274_reg[16'h303D]);
    end
    if (err != "") begin
      if (first) $fatal(1, "IMX274 at the stream start: %s", err);
      if (!win) begin
        $fatal(1, "IMX274: frame start between two register writes of the driver (outside a mode command; flips go under REGHOLD): %s",
               err);
      end
      s274_bad++;
      $display("[%0t] tb   | IMX274: frame not output: %s", $time, err);
      return 1'b1;
    end
    sig   = {8'(mode), s274_reg[16'h3007], 7'(0), vflip, 7'(0), vcrop, 16'(vcut), 4'(0), pos,
             16'(wsize)};
    trans = !first && sig != f274_sig;
    f274_sig   = sig;
    f274_mode  = mode;
    f274_hbin  = hbin;
    f274_w     = w;
    f274_h     = ysize;
    f274_ob    = ob;
    f274_hmax  = hmax;
    f274_vmax  = vmax;
    f274_vflip = vflip;
    f274_tp    = (s274_reg[16'h303C] == 8'h11) ? 32'(s274_reg[16'h303D]) + 1 : 0;
    f274_pgc   = pgc;
    f274_dgain = s274_reg[16'h3012];
    f274_black = s274_reg[16'h3045];
    // SHR (frame latched *2): the value written in frame n counts from n + 2
    f274_exp   = first ? vmax - shr : f274_exp_q;
    f274_exp_q = vmax - shr;
    if (first || trans) begin
      $display("[%0t] tb   | IMX274 %s %0dx%0d RAW10, mode %0d, columns %0d..%0d, lines %0d (flip %0d), %0d OB lines, HMAX %0d VMAX %0d, test pattern %0d",
               $time, first ? "stream" : "mode transition:", f274_w, f274_h, mode, hcrop ? x0 : 0,
               hcrop ? x1 : 3864, kept, vflip, ob, hmax, vmax, f274_tp);
    end
    if (first) s274_latched++;
    return trans;
  endfunction

  // RAW10 pixel x of line y. RGGB at the top left; the vertical flip reverses
  // the order of the line pairs and keeps the colour phase (line 0 shows
  // line H - 2, line 1 line H - 1: still RGGB, as measured on the Huins
  // board on 2026-11-10). Test patterns (0x303D +
  // 1, the menu of the Linux driver, 12 bit values >> 2, no black level):
  // 1..4 solid 000h/FFFh/555h/AAAh, 5..10 stripes of 2 columns (555h/AAAh,
  // AAAh/555h, 000h/555h, 555h/000h, 000h/FFFh, FFFh/000h), 11 vertical and
  // 12 horizontal colour bars (white yellow cyan green magenta red blue
  // black). Off: a smooth scene whose level follows exposure x analog x
  // digital gain, with a colour cast (R 5/8, B 13/16), on top of BLKLEVEL.
  function automatic logic [9:0] s274_pixel(int unsigned x, int unsigned y);
    int unsigned yy, c, bar;
    longint unsigned lin, v;
    bit on, odd;
    yy  = f274_vflip ? f274_h - 2 - (y & ~32'd1) + (y & 32'd1) : y;
    c   = {yy[0], x[0]};                                   // 0 R, 1 Gr, 2 Gb, 3 B
    odd = x[1];
    case (f274_tp)
      1: return 10'h000;
      2: return 10'h3FF;
      3: return 10'h155;
      4: return 10'h2AA;
      5: return odd ? 10'h2AA : 10'h155;
      6: return odd ? 10'h155 : 10'h2AA;
      7: return odd ? 10'h155 : 10'h000;
      8: return odd ? 10'h000 : 10'h155;
      9: return odd ? 10'h3FF : 10'h000;
      10: return odd ? 10'h000 : 10'h3FF;
      11, 12: begin
        bar = (f274_tp == 11) ? (x * 8) / f274_w : (yy * 8) / f274_h;
        on  = (c == 0) ? (bar inside {0, 1, 4, 5}) : (c == 3) ? (bar inside {0, 2, 4, 6}) : (bar < 4);
        return on ? S274On : S274Off;
      end
      default: ;
    endcase
    lin = 32 + (x * 192) / f274_w + (yy * 32) / f274_h;
    if (c == 0) lin = lin * 5 / 8;
    if (c == 3) lin = lin * 13 / 16;
    v = lin * f274_exp * (524288 / (2048 - f274_pgc)) * (64'd1 << f274_dgain) / (256 * 48);
    if (v > 1023 - f274_black) v = 1023 - f274_black;
    return 10'(f274_black + v);
  endfunction

  function automatic csi2_bytes_t s274_line(int unsigned y);
    logic [9:0] px [$];
    px.delete();
    for (int unsigned x = 0; x < f274_w; x++) px.push_back(s274_pixel(x, y));
    return csi2_raw10(px);
  endfunction

  // optical black line: BLKLEVEL everywhere
  function automatic csi2_bytes_t s274_ob_line();
    logic [9:0] px [$];
    px.delete();
    for (int unsigned x = 0; x < f274_w; x++) px.push_back(10'(f274_black));
    return csi2_raw10(px);
  endfunction

  // embedded data line, as long as a pixel line, RAW10 packing (every 5th
  // byte a 0x55 dummy): format code 0x0A, frame number, PGC, SHR, DGAIN,
  // BLKLEVEL, end code 0x07, then 0x55 padding
  function automatic csi2_bytes_t s274_emb_line();
    csi2_bytes_t b;
    byte unsigned e [$];
    int unsigned  k;
    b.delete();
    e.delete();
    e.push_back(8'h0A);
    e.push_back(8'(f274_num));
    e.push_back(8'(f274_pgc));
    e.push_back(8'(f274_pgc >> 8));
    e.push_back(8'(f274_vmax - f274_exp_q));
    e.push_back(8'((f274_vmax - f274_exp_q) >> 8));
    e.push_back(8'(f274_dgain));
    e.push_back(8'(f274_black));
    e.push_back(8'h07);
    k = 0;
    for (int unsigned i = 0; i < f274_w * 5 / 4; i++) begin
      if (i % 5 == 4) begin
        b.push_back(8'h55);
      end else begin
        b.push_back((k < e.size()) ? e[k] : 8'h55);
        k++;
      end
    end
    return b;
  endfunction

  initial begin : s274_stream
    csi2_flags_t f, fl;
    csi2_bytes_t pay, pkt;
    realtime     t0, tw, hmax_ns;
    int unsigned d, k, y, nslot, nout;
    bit          bad_done, crc_frame;
    logic [15:0] crc;
    if (Imx274) forever begin
      // reset, standby, start sequence: LP-00 / LP-11, clock lane LP
      while (!s274_run) begin
        if (!u_csi.busy() && !u_csi.clk_running) u_csi.lp00 = !s274_lp11();
        #1000;
      end
      void'(s274_latch(1'b1));
      nout = 0;                                                          // frames output
      // the first frame after the start is not output
      t0 = csi2_now();
      tw = t0 + real'(f274_hmax) * real'(f274_vmax) * 1000.0 / 72.0;
      while (s274_run && csi2_now() < tw) begin
        d = int'(tw - csi2_now());
        #((d > 1000) ? 1000 : (d == 0) ? 1 : d);
      end
      while (s274_run) begin
        t0 = csi2_now();
        if (!s274_latch(1'b0)) begin
          hmax_ns   = real'(f274_hmax) * 1000.0 / 72.0;
          f         = csi2_flags();
          f274_num  = f274_num % 65535 + 1;
          inj_frame = inj_req;
          inj_req   = 1'b0;
          bad_done  = 1'b0;
          nout++;
          crc_frame = (s274_crc_frame != 0 && nout == s274_crc_frame);
          u_csi.contclk = s274_contclk;
          u_csi.push_short(0, 8'h00, f274_num, f);                       // FS
          nslot = 1 + f274_ob + f274_h;
          k = 0;
          while (k < nslot && s274_run) begin
            tw = t0 + real'(2 * k + 1) * hmax_ns;                         // line slot
            while (s274_run && csi2_now() < tw) begin
              d = int'(tw - csi2_now());
              #((d > 1000) ? 1000 : (d == 0) ? 1 : d);
            end
            if (!s274_run) break;
            if (u_csi.busy()) s274_late++;
            if (k == 0) begin
              u_csi.push_long(0, 8'h12, s274_emb_line(), f);
            end else if (k <= f274_ob) begin
              u_csi.push_long(0, 8'h37, s274_ob_line(), f);
            end else begin
              // error injection as in the IMX219 model (csi2_274 test)
              y   = k - 1 - f274_ob;
              pay = s274_line(y);
              fl  = f;
              if (inj_frame && y == 8) fl.hdr_flip_a = 8'sd9;
              if (inj_frame && y == 16) fl.pay_flip = 3;
              if (crc_frame && y == 0) begin
                fl.pay_flip    = 5;
                s274_crc_frame = 0;
                s274_crc_sent++;
              end
              if (inj_frame && y >= 24 && !bad_done) begin
                pkt = csi2_header(0, 32'h2B, pay.size());
                foreach (pay[i]) pkt.push_back(pay[i]);
                crc = csi2_crc(pay);
                pkt.push_back(crc[7:0]);
                pkt.push_back(crc[15:8]);
                if (!lane1_locks(pkt, BadSync, CsiLanes)) begin
                  fl.sync[1] = BadSync;
                  bad_done   = 1'b1;
                end
              end
              u_csi.push_long(0, 8'h2B, pay, fl);
            end
            k++;
          end
          while (s274_run && u_csi.busy()) #100;
          if (s274_run) begin
            u_csi.push_short(0, 8'h01, f274_num, f);                     // FE
            while (u_csi.busy()) #100;
            s274_frames++;
            if (inj_frame) begin
              if (!bad_done) $fatal(1, "IMX274: no line for the bad sync byte");
              inj_sent = 1'b1;
            end
          end
          u_csi.contclk = 1'b0;                                          // LP in the blanking
        end
        tw = t0 + real'(f274_hmax) * real'(f274_vmax) * 1000.0 / 72.0;  // next FS
        while (s274_run && csi2_now() < tw) begin
          d = int'(tw - csi2_now());
          #((d > 1000) ? 1000 : (d == 0) ? 1 : d);
        end
      end
      // stopped: the burst in progress ends, the clock lane leaves HS, then
      // the lanes drop to LP-00 (frame cut, no FE)
      while (u_csi.busy()) #100;
      u_csi.contclk = 1'b0;
      #100;
      while (u_csi.busy()) #100;
    end
  end

  // The AFE controls of the Versal PHY in the camera top (bow32_huins_vp1902_cam_top) drive
  // the PHY model directly (its ports): cal_start (CMD.REINIT, a 32 cycle pulse) and pd
  // (AFE_CTRL.PD) its re-init, des_rst its BurstRxRst (through the Versal adapter's logic in
  // the model). +S274_BURSTRST=<0|1>: BurstRxRst = 0 / 1 whatever the receiver says (the
  // model's v_brst_force). cal_start pulses are counted here.
  int          s274_brst_force = -1;      // -1: the D-PHY's des_rst
  int unsigned s274_reinits = 0;          // cal_start pulses seen
  logic        s274_cal_q = 1'b0;

  always @(posedge clk) begin
    if (Imx274) begin
      if (dphy_cal_start && !s274_cal_q) s274_reinits++;
      s274_cal_q         = dphy_cal_start;
      u_csi.v_brst_force = s274_brst_force;
    end
  end

  // ------------------------------------------------------ ISP output monitor
  // Every line of a frame must have the same length; remembers the geometry
  // of the last complete frame.
  int unsigned out_x = 0, out_y = 0, out_line_w = 0, out_w = 0, out_h = 0, out_frames = 0;

  always @(posedge vclk) begin
    if (isp_tvalid) begin
      if (isp_tuser) begin
        if (out_x != 0) $fatal(1, "ISP output: start of frame inside a line");
        if (out_y != 0) begin
          out_w = out_line_w;
          out_h = out_y;
          out_frames++;
        end
        out_y = 0;
      end
      out_x++;
      if (isp_tlast) begin
        if (out_y != 0 && out_x != out_line_w) begin
          $fatal(1, "ISP output: line %0d has %0d pixels, expected %0d", out_y, out_x, out_line_w);
        end
        out_line_w = out_x;
        out_x = 0;
        out_y++;
      end
    end
  end

  // ---------------------------------------------------------------- tests
  task automatic test_load();
    byte unsigned img[$], p[$], rsp[$], none[$];
    logic [31:0]  dev_crc;
    int unsigned  off;
    if (!$value$plusargs("IMAGE=%s", image_file)) $fatal(1, "+IMAGE=<vmem> required");
    load_image_bytes(image_file, img);
    $display("[%0t] tb   | downloading %s (%0d bytes)", $time, image_file, img.size());

    expect_text(0, "UART loader ready");
    boot_cmd(8'h01, none, rsp);  // INFO
    $display("[%0t] tb   | INFO: chip id %02x%02x%02x%02x", $time, rsp[3], rsp[2], rsp[1], rsp[0]);

    p.delete(); push32(p, FlashBase); push32(p, img.size());
    boot_cmd(8'h02, p, rsp);   // ERASE

    // Loop variables live at task scope (safer across the delays inside
    // boot_cmd() with Verilator's coroutines).
    off = 0;
    while (off < img.size()) begin
      p.delete(); push32(p, FlashBase + off);
      for (int i = off; i < off + 256 && i < img.size(); i++) p.push_back(img[i]);
      while (p.size() % 4) p.push_back(8'hFF);
      boot_cmd(8'h03, p, rsp); // WRITE
      $display("[%0t] tb   | WRITE %08x: %0d bytes", $time, FlashBase + off, p.size() - 4);
      off += 256;
    end

    p.delete(); push32(p, FlashBase); push32(p, img.size());
    boot_cmd(8'h05, p, rsp);   // CRC
    dev_crc = {rsp[3], rsp[2], rsp[1], rsp[0]};
    if (dev_crc != crc32(img)) $fatal(1, "verify failed: %08x != %08x", dev_crc, crc32(img));
    $display("[%0t] tb   | verify OK (crc %08x)", $time, dev_crc);

    boot_cmd(8'h06, none, rsp);  // BOOT
    expect_text(0, "Hello from Bow32!");
  endtask

  // GPIO test: commands for sw/apps/gpio_demo on UART0. gpio_check() runs
  // after each answer: it looks at the pads and plays the external circuit.
  string gpio_cmd[$], gpio_rsp[$];

  function automatic void gpio_add(string cmd, string rsp = "ok\n> ");
    gpio_cmd.push_back(cmd);
    gpio_rsp.push_back(rsp);
  endfunction

  function automatic void gpio_setup();
    gpio_cmd.delete();
    gpio_rsp.delete();
    gpio_add("d a 0f");                // 0  PA0..PA3 outputs
    gpio_add("o a 05");                // 1
    gpio_add("t a 0f");                // 2  then drive PA7..PA4 = 1001
    gpio_add("r");                     // 3  IN
    gpio_add("i a 10 f");              // 4  falling edge on PA4, then pull PA4 low
    gpio_add("", "irq A: pins=10");    // 5
    gpio_add("m a 08");                // 6  open-drain PA3, OUT = 1: released
    gpio_add("c a 08");                // 7  OUT = 0: driven low
    gpio_add("f b 00");                // 8  PB0/PB1: UART1 -> GPIO
    gpio_add("o b 01");                // 9
    gpio_add("d b 01");                // 10 PB0 drives 1
    gpio_add("c b 01");                // 11 PB0 drives 0
    gpio_add("f b 03");                // 12 back to UART1
    gpio_add("u", "hello from PB0");   // 13 on UART1
  endfunction

  function automatic void gpio_expect(bit ok, string what);
    if (!ok) begin
      $fatal(1, "GPIO: %s failed (PA=%02x oe=%02x  PB=%02x oe=%02x)", what, pad_a, gpioa_oe,
             pad_b, gpiob_oe);
    end
    $display("[%0t] tb   | GPIO %s", $time, what);
  endfunction

  function automatic void gpio_check(int unsigned step, int unsigned from);
    string answer;
    answer = log0.substr(from, log0.len() - 1);
    case (step)
      0: gpio_expect(gpioa_oe == 8'h0f, "PA0..PA3 outputs");
      1: gpio_expect(pad_a == 8'hf5, "PA = f5 (PA7..PA4 pulled up)");
      2: begin
        gpio_expect(pad_a == 8'hfa, "toggle: PA = fa");
        ext_a_en[7:4]  = 4'hf;
        ext_a_val[7:4] = 4'h9;
      end
      3: gpio_expect(contains(answer, "A: in=9a"), "IN reads the driven pins");
      4: ext_a_val[4] = 1'b0;
      5: gpio_expect(1'b1, "falling edge interrupt on PA4");
      6: gpio_expect(gpioa_oe == 8'h07 && pad_a[3], "open-drain 1: PA3 released");
      7: gpio_expect(gpioa_oe == 8'h0f && !pad_a[3], "open-drain 0: PA3 driven low");
      8: gpio_expect(gpiob_oe == 8'h00 && pad_b[1:0] == 2'b11, "AF off: PB0/PB1 inputs");
      10: gpio_expect(gpiob_oe == 8'h01 && pad_b[0], "PB0 as GPIO = 1");
      11: gpio_expect(!pad_b[0], "PB0 as GPIO = 0");
      12: gpio_expect(gpiob_oe == 8'h01 && pad_b[0], "AF on: PB0 = UART1 TX (idle)");
      13: gpio_expect(1'b1, "UART1 works again on PB0");
      default: ;
    endcase
  endfunction


  // Camera test: commands for sw/apps/camera on UART0 and the text expected
  // in the answer (rsp, then rsp2 after it if not empty). "dump" receives and
  // checks an image; "" only waits; isp = 1: the ISP output must be 64x48.
  string cam_cmd[$], cam_rsp[$], cam_rsp2[$];
  bit    cam_isp[$];

  function automatic void cam_add(string cmd, string rsp = "ok\n> ", string rsp2 = "", bit isp = 1'b0);
    cam_cmd.push_back(cmd);
    cam_rsp.push_back(rsp);
    cam_rsp2.push_back(rsp2);
    cam_isp.push_back(isp);
  endfunction

  function automatic void cam_setup();
    cam_cmd.delete();
    cam_rsp.delete();
    cam_rsp2.delete();
    cam_isp.delete();
    cam_add("rd 50008000", "bus error");          // AXI device does not answer: timeout
    cam_add("rd 50004000", "bus error");          // SLVERR
    cam_add("wr 50004000 1", "bus error");        // SLVERR on a write
    cam_add("rd 50000004", "50000004: 00000009"); // fixed register of the AXI device
    cam_add("wr 50000010 a5c3e1f0");
    cam_add("rd 50000010", "50000010: a5c3e1f0"); // written through the bridge
    cam_add("mode 64 48");                        // small frames for the simulation
    cam_add("tp 2");                              // sensor colour bars
    // first start: eye calibration (step 16, every tap good in this test)
    // then the margin check (8 frames at the taps and at +-eye/4)
    cam_add("cam", {"csi2rx: calibrated taps 248/248 eye 512/512\n",
                    "csi2rx: margin ok +-128/+-128 taps: 0 errors in 5 x 8 frames, BER < "},
            "streaming 64x48 RGGB");
    cam_add("stat", "in 64x48", "", 1'b1);
    cam_add("csi", "csi2rx: link ok\n", "lines/frame 48 wc 80 dt 2b");
    cam_add("margin 0 2", "csi2rx: margin ok +-128/+-128 taps: 0 errors in 5 x 2 frames");
    // restarts with the calibrated taps: the link check passes (taps kept);
    // a link error that a tap cannot fix (FRAME) keeps the taps
    cam_add("cam", "streaming 64x48 RGGB");
    cam_add("!fe");
    cam_add("cam", "csi2rx: link errors (ERR_STATUS 100), not a sampling problem: taps kept",
            "streaming 64x48 RGGB");
    cam_add("!nofe");
    cam_add("cap 0 0 32 24 1", "captured 32x24");
    cam_add("dump", "END\nok\n> ");               // RGB colour bars
    cam_add("tp 0");                              // scene with a colour cast
    cam_add("ae on");
    cam_add("awb on");
    cam_add("", "ae: locked");
    cam_add("", "awb: locked");
    cam_add("flip 1 1");                          // BGGR
    cam_add("stat", "in 64x48", "", 1'b1);
    cam_add("awb off");
    cam_add("tpg 0", "tpg 0 64x48");              // ISP test pattern (stream stops)
    cam_add("fmt yuv");
    cam_add("cap 0 0 32 24 1", "captured 32x24");
    cam_add("dump", "END\nok\n> ");               // YUV colour bars
    // no data at all (the sensor takes its registers, sends nothing): the
    // link check (2.4 frames of the sensor configuration) times out, the
    // calibration fails without a byte clock; then a restart (taps kept)
    cam_add("!mute");
    cam_add("cam", "no link error: calibrating", "csi2rx: calibration failed\nerror\n> ");
    cam_add("!unmute");
    cam_add("cam", "streaming 64x48 BGGR");
  endfunction

  // Image transfer of `dump`: "IMG <w> <h> <fmt> <len> <crc>" line + raw bytes.
  byte unsigned img_px[$];
  int unsigned  img_w, img_h;
  string        img_fmt;

  task automatic receive_image();
    string        line;
    int unsigned  len, n;
    logic [31:0]  crc;
    byte unsigned b;
    line = "";
    img_px.delete();
    forever begin
      while (rxq0.size() == 0) @(posedge clk);
      b = rxq0.pop_front();
      if (b == 8'h0a) begin
        if (line.len() > 4 && line.substr(0, 3) == "IMG ") break;
        line = "";
      end else if (b != 8'h0d) begin
        line = {line, string'(b)};
      end
    end
    n = $sscanf(line, "IMG %d %d %s %d %h", img_w, img_h, img_fmt, len, crc);
    if (n != 5 || len != 3 * img_w * img_h) $fatal(1, "bad image header '%s'", line);
    while (img_px.size() < len) begin
      while (rxq0.size() == 0) @(posedge clk);
      img_px.push_back(rxq0.pop_front());
    end
    if (crc32(img_px) != crc) $fatal(1, "image CRC mismatch");
    $display("[%0t] tb   | received %0dx%0d %s image, crc %08x ok", $time, img_w, img_h, img_fmt, crc);
  endtask

  // Colour bars white yellow cyan green magenta red blue black: centre pixel of
  // every bar in the middle row. RGB: each component on/off; YUV: the luma.
  function automatic void check_bars();
    int unsigned i;
    int c0, c1, c2, yexp;
    bit r, g, b, ok;
    for (int k = 0; k < 8; k++) begin
      i  = 3 * ((img_h / 2) * img_w + k * img_w / 8 + img_w / 16);
      c0 = img_px[i];
      c1 = img_px[i + 1];
      c2 = img_px[i + 2];
      r  = k inside {0, 1, 4, 5};
      g  = k < 4;
      b  = k inside {0, 2, 4, 6};
      if (img_fmt == "rgb") begin
        ok = (r ? c0 > 160 : c0 < 80) && (g ? c1 > 160 : c1 < 80) && (b ? c2 > 160 : c2 < 80);
      end else begin
        yexp = (54 * r + 183 * g + 19 * b) * 255 / 256;
        ok = (c0 > yexp - 24) && (c0 < yexp + 24);
        if (k == 0 || k == 7) ok = ok && (c1 > 112) && (c1 < 144) && (c2 > 112) && (c2 < 144);
      end
      if (!ok) $fatal(1, "colour bar %0d wrong: %0d %0d %0d (%s)", k, c0, c1, c2, img_fmt);
    end
    $display("[%0t] tb   | %s colour bars ok", $time, img_fmt);
  endfunction

  // csi2 test: eye of the TX model lane 0 100..300, lane 1 180..400; with
  // calibration step 32 the firmware finds taps 208/288 and eyes 192/224.
  function automatic void check_calibration(int unsigned from);
    string       s;
    int unsigned t0, t1, e0, e1;
    s = log0_line("[PASS] calibrate taps ", from);
    if ($sscanf(s, "%d/%d eye %d/%d", t0, t1, e0, e1) != 4) $fatal(1, "no calibration result");
    if (t0 < 192 || t0 > 224 || t1 < 272 || t1 > 304 || e0 < 160 || e0 > 224 || e1 < 192 ||
        e1 > 256) begin
      $fatal(1, "calibrated taps %0d/%0d eye %0d/%0d, expected about 208/288 eye 192/224", t0, t1,
             e0, e1);
    end
    $display("[%0t] tb   | calibration: taps %0d/%0d eye %0d/%0d ok", $time, t0, t1, e0, e1);
  endfunction

  // margin check: k = eye / 4 = 48/56 with the calibration above
  function automatic void check_margin(int unsigned from);
    string s;
    s = log0_line("[PASS] margin ", from);
    if (s.len() < 30 || s.substr(0, 28) != "+-48/+-56 taps: 0 errors in 5") begin
      $fatal(1, "margin check '%s', expected +-48/+-56 taps, 0 errors at 5 points", s);
    end
    $display("[%0t] tb   | margin check: %s", $time, s);
  endfunction

  // One point line of 'margin': errors 0 (or not 0)
  // want_frames != 0: a clean point must have counted that many frames
  function automatic void check_margin_point(string point, bit bad, int unsigned from,
                                             int unsigned want_frames = 0);
    string s;
    int unsigned frames, errors;
    s = log0_line({"margin ", point, ": "}, from);
    if ($sscanf(s, "%d frames, %d errors", frames, errors) != 2) begin
      $fatal(1, "no margin line for '%s'", point);
    end
    if (bad ? errors == 0 : errors != 0) begin
      $fatal(1, "margin %s: %0d errors, expected %s", point, errors, bad ? "some" : "none");
    end
    if (!bad && want_frames != 0 && frames != want_frames) begin
      $fatal(1, "margin %s: %0d frames, expected %0d", point, frames, want_frames);
    end
    $display("[%0t] tb   | margin %s: %0d frames, %0d errors ok", $time, point, frames, errors);
  endfunction

  task automatic inject_errors();
    longint unsigned t0;
    inj_sent = 1'b0;
    inj_req  = 1'b1;
    t0 = cycle;
    while (!inj_sent) begin
      if (cycle - t0 > 100_000) $fatal(1, "no frame with the injected errors (not streaming?)");
      @(posedge clk);
    end
    repeat (500) @(posedge clk);   // the last events reach the CPU domain
    $display("[%0t] tb   | injected: header bit flip, payload bit flip, bad sync on lane 1", $time);
  endtask

  // Byte clock gate of the receiver (TX model status): it opens and closes
  // only while the clock lane is in its static HS-0 (CLK-ZERO, CLK-TRAIL),
  // never in an LP state or while the clock toggles, with the PHY timing
  // that the driver computes for this video clock. ce_bad counts from the
  // end of the reset (the gate starts open in a two-state simulation, see
  // bow_dphy_lp).
  int unsigned ce_bad0 = 0;

  function automatic void check_dphy_gate();
    if (u_csi.ce_bad != ce_bad0 || u_csi.ce_rise_toggle != 0 || u_csi.runts != 0) begin
      $fatal(1, "D-PHY byte clock gate: open in LP %0d x, opened while toggling %0d x, runts %0d",
             u_csi.ce_bad - ce_bad0, u_csi.ce_rise_toggle, u_csi.runts);
    end
    $display("[%0t] tb   | D-PHY byte clock gate ok (%0d bursts)", $time, u_csi.bursts_done);
  endfunction

  // The 'stat' answer after inject_errors(): exactly these error counts
  function automatic void check_error_counters(int unsigned from);
    string       s;
    int unsigned ecc0, ecc1, crc, trunc, sot0, sot1, ovf, misc, extra, drop;
    s = log0_line("  errors: ", from);
    if ($sscanf(s, "ecc %d/%d crc %d trunc %d sot %d/%d ovf %d misc %d extra %d (dropped by DT/VC %d)",
                ecc0, ecc1, crc, trunc, sot0, sot1, ovf, misc, extra, drop) != 10) begin
      $fatal(1, "no error counters in the 'stat' answer");
    end
    if (ecc0 != 1 || ecc1 != 0 || crc != 1 || trunc != 0 || sot0 != 0 || sot1 != 1 || ovf != 0 ||
        misc < 1 || extra != 0) begin
      $fatal(1, "error counters '%s', expected ecc 1/0 crc 1 trunc 0 sot 0/1 ovf 0 misc >= 1 extra 0",
             s);
    end
    $display("[%0t] tb   | error counters ok: %s", $time, s);
  endfunction

  // H.264 test: one command of sw/apps/video and the text expected after it
  task automatic video_cmd(string cmd, string rsp);
    int unsigned mark;
    mark = log0.len();
    rxq0.delete();
    uart_send_str(0, {cmd, "\r"});
    expect_text(0, rsp, mark);
  endtask

  // Rate control of `rec n skip kbytes` (video app): the lines "frame k:
  // <bytes> bytes, QP <qp>, ..." of all n frames; the QP must move at least
  // once and never against the size error (no lower QP after a frame more
  // than 12 % above the target, no higher one after a frame more than 12 %
  // below it), and the second half of the frames within -50 %..+25 % of the
  // target.
  function automatic void check_rc(int unsigned from, int unsigned n, int unsigned target);
    int unsigned b [$], q [$], bytes, qp, moved;
    string       s;
    for (int unsigned k = 1; k <= n; k++) begin
      s = log0_line($sformatf("frame %0d: ", k), from);
      if ($sscanf(s, "%d bytes, QP %d", bytes, qp) != 2) $fatal(1, "rate control: no line for frame %0d", k);
      b.push_back(bytes);
      q.push_back(qp);
    end
    moved = 0;
    for (int unsigned k = 0; k + 1 < n; k++) begin
      if (q[k + 1] != q[k]) moved++;
      if ((b[k] * 8 > target * 9 && q[k + 1] < q[k]) || (b[k] * 8 < target * 7 && q[k + 1] > q[k])) begin
        $fatal(1, "rate control: frame %0d %0d bytes at QP %0d, next QP %0d (target %0d)", k + 1,
               b[k], q[k], q[k + 1], target);
      end
    end
    for (int unsigned k = n / 2; k < n; k++) begin
      if (b[k] * 2 < target || b[k] * 4 > target * 5) begin
        $fatal(1, "rate control: frame %0d %0d bytes at QP %0d, target %0d", k + 1, b[k], q[k], target);
      end
    end
    if (moved == 0) $fatal(1, "rate control: the QP never moved");
    $display("[%0t] tb   | rate control: %0d frames, QP %0d..%0d, last %0d bytes (target %0d)", $time,
             n, q[0], q[n - 1], b[n - 1], target);
  endfunction

  // Stream transfer of `send`: "H264 <bytes> <crc> <frames> <w> <h> <num> <den>"
  // line + raw bytes, a stream of ew x eh; written to build/sim/<file> for the
  // decoder check of sim/Makefile (tools/h264/h264_model.py decode --bars).
  task automatic receive_h264(output int unsigned frames, input int unsigned ew = 64,
                              input int unsigned eh = 48, input string file = "h264.hex");
    string        line;
    int unsigned  len, w, h, num, den, fd;
    logic [31:0]  crc;
    byte unsigned b, data[$];
    line = "";
    data.delete();
    forever begin
      while (rxq0.size() == 0) @(posedge clk);
      b = rxq0.pop_front();
      if (b == 8'h0a) begin
        if (line.len() > 5 && line.substr(0, 4) == "H264 ") break;
        line = "";
      end else if (b != 8'h0d) begin
        line = {line, string'(b)};
      end
    end
    if ($sscanf(line, "H264 %d %h %d %d %d %d %d", len, crc, frames, w, h, num, den) != 7) begin
      $fatal(1, "bad stream header '%s'", line);
    end
    while (data.size() < len) begin
      while (rxq0.size() == 0) @(posedge clk);
      data.push_back(rxq0.pop_front());
    end
    if (crc32(data) != crc) $fatal(1, "H.264 stream CRC mismatch");
    if (w != ew || h != eh) $fatal(1, "H.264 stream of %0dx%0d, expected %0dx%0d", w, h, ew, eh);
    fd = $fopen(file, "w");
    foreach (data[i]) $fdisplay(fd, "%02x", data[i]);
    $fclose(fd);
    $display("[%0t] tb   | received H.264 stream: %0d bytes, %0d frames %0dx%0d @ %0d/%0d fps, crc %08x ok%s",
             $time, len, frames, w, h, num, den, crc, file == "h264.hex" ? "" : {" (", file, ")"});
  endtask

  // ------------------------------------------------------- IMX274 tests
  // Eyes of the data lanes (TX model delay taps, BISC 97/112/88/120):
  //   camera274 (calibration step 16): every BISC delay inside its eye, so the
  //     firmware walks each lane outward from it: taps 112/128/88/144, eyes
  //     144/144/128/144;
  //   csi2_274 (step 32): lane 2's BISC delay (88) outside its eye, so the
  //     firmware first sweeps all lanes together (common eye 160..320, centre
  //     240), then walks each lane: taps 192/224/272/256, eyes 288/288/256/288.
  int unsigned eye274_lo [4], eye274_hi [4];

  // Send one shell command; returns the log offset to look for its answer.
  function automatic int unsigned send_cmd(string cmd);
    int unsigned mark;
    mark = log0.len();
    rxq0.delete();
    uart_send_str(0, {cmd, "\r"});
    return mark;
  endfunction

  // "<prefix>t0/t1/t2/t3 eye w0/w1/w2/w3": every tap inside its eye, at most
  // one step from its centre, every eye width the eye of the model +- 2 steps
  function automatic void check_cal274(string prefix, int unsigned from, int unsigned step);
    string       s;
    int unsigned t [4], w [4], c, e;
    s = log0_line(prefix, from);
    if ($sscanf(s, "%d/%d/%d/%d eye %d/%d/%d/%d", t[0], t[1], t[2], t[3], w[0], w[1], w[2],
                w[3]) != 8) begin
      $fatal(1, "no 4 lane calibration result after '%s'", prefix);
    end
    for (int l = 0; l < 4; l++) begin
      c = (eye274_lo[l] + eye274_hi[l]) / 2;
      e = eye274_hi[l] - eye274_lo[l];
      if (t[l] < eye274_lo[l] || t[l] > eye274_hi[l] || t[l] + step < c || t[l] > c + step ||
          w[l] + 2 * step < e || w[l] > e + 2 * step) begin
        $fatal(1, "lane %0d: calibrated tap %0d eye %0d, model eye %0d..%0d", l, t[l], w[l],
               eye274_lo[l], eye274_hi[l]);
      end
    end
    $display("[%0t] tb   | 4 lane calibration: taps %0d/%0d/%0d/%0d eye %0d/%0d/%0d/%0d ok", $time,
             t[0], t[1], t[2], t[3], w[0], w[1], w[2], w[3]);
  endfunction

  // margin check of `test quick` on 4 lanes (sensor pattern AAAh): k = eye / 4
  // = 72/72/64/72 with the calibration above, 9 points (centre, +-k per lane)
  function automatic void check_margin274(int unsigned from);
    string s, want;
    want = "+-72/+-72/+-64/+-72 taps: 0 errors in 9 x 4 frames";
    s = log0_line("[PASS] margin ", from);
    if (s.len() < want.len() || s.substr(0, want.len() - 1) != want) begin
      $fatal(1, "4 lane margin check '%s', expected '%s'", s, want);
    end
    $display("[%0t] tb   | 4 lane margin check: %s", $time, s);
  endfunction

  // The 'stat' / 'csi' answer of a 4 lane stream: error counters, the ones
  // of the injected errors (inj = 1) or none
  function automatic void check_counters274(int unsigned from, bit inj);
    string       s;
    int unsigned ecc0, ecc1, crc, trunc, sot [4], ovf, misc, extra, drop;
    s = log0_line("  errors: ", from);
    if ($sscanf(s, "ecc %d/%d crc %d trunc %d sot %d/%d/%d/%d ovf %d misc %d extra %d (dropped by DT/VC %d)",
                ecc0, ecc1, crc, trunc, sot[0], sot[1], sot[2], sot[3], ovf, misc, extra,
                drop) != 12) begin
      $fatal(1, "no 4 lane error counters in the answer: '%s'", s);
    end
    if (inj ? (ecc0 != 1 || ecc1 != 0 || crc != 1 || trunc != 0 || sot[0] != 0 || sot[1] != 1 ||
               sot[2] != 0 || sot[3] != 0 || ovf != 0 || misc < 1 || extra != 0)
            : (ecc0 + ecc1 + crc + trunc + sot[0] + sot[1] + sot[2] + sot[3] + ovf + misc +
               extra != 0)) begin
      $fatal(1, "error counters '%s', expected %s", s,
             inj ? "ecc 1/0 crc 1 trunc 0 sot 0/1/0/0 ovf 0 misc >= 1 extra 0" : "no error");
    end
    $display("[%0t] tb   | error counters ok: %s", $time, s);
  endfunction

  // D-PHY timing of the IMX274 at the limits of the D-PHY specification at
  // 1440 Mbit/s (UI 0.694 ns; the IMX274's own values are not documented),
  // in whole byte clock periods (5.556 ns) at or just beyond each limit: the
  // longest (corner 1: 85 ns + 6 UI = 88.9) or the shortest (corner 2: 40 ns
  // + 4 UI = 44.4) HS-PREPARE with the shortest HS-PREPARE + HS-ZERO (145 ns
  // + 10 UI: 155.6; the TX model adds 0..64 ns), the shortest T_LPX (50.0),
  // HS-TRAIL (60 ns + 4 UI: 66.7), HS-EXIT (100.0), CLK-POST (60 ns + 52 UI:
  // 100.0), CLK-TRAIL (61.1), the longest CLK-PREPARE (94.4) with the
  // shortest CLK-PREPARE + CLK-ZERO (300.0)
  function automatic void s274_dphy_corner(int unsigned corner);
    u_csi.t_lpx         = 50;
    u_csi.t_hs_prepare  = (corner == 2) ? 44 : 89;
    u_csi.t_hs_zero     = (corner == 2) ? 111 : 65;
    u_csi.t_hs_trail    = 64;
    u_csi.t_hs_exit     = 100;
    u_csi.t_clk_prepare = 95;
    u_csi.t_clk_zero    = 205;
    u_csi.t_clk_post    = 100;
    u_csi.t_clk_trail   = 60;
  endfunction

  // End of an IMX274 test: frames sent on time, the delay load contract of
  // the Versal PHY (one cycle pulses, stable taps, no load while one is
  // pending; loads = 1: every lane calibrated), the byte clock gate. The
  // RX FIFO figures of the PHY model (glitch words, wraps: 8 words lost
  // each, all stale ones between bursts when the latency is the same on
  // every lane) are reported; data lost to them would show in the counters.
  function automatic void check_s274_end(bit loads = 1'b1);
    $display("[%0t] tb   | IMX274: %0d starts, %0d stops, %0d frames (%0d not output: format between two register writes), ISP output frames %0d (%0dx%0d), D-PHY bursts %0d, late line slots %0d",
             $time, s274_starts, s274_stops, s274_frames, s274_bad, out_frames, out_w, out_h,
             u_csi.bursts_done, s274_late);
    $display("[%0t] tb   | Versal PHY: delay loads %0d/%0d/%0d/%0d, bit flips outside the eye %0d; RX FIFOs (BurstRxRst %0d at the end): %0d glitch words, %0d read gaps, at most %0d words, wraps %0d/%0d/%0d/%0d",
             $time, u_csi.dly_loads[0], u_csi.dly_loads[1], u_csi.dly_loads[2], u_csi.dly_loads[3],
             u_csi.flips, u_csi.v_burst_rst, u_csi.v_glitches, u_csi.v_gaps, u_csi.v_occ_max,
             u_csi.v_wraps[0], u_csi.v_wraps[1], u_csi.v_wraps[2], u_csi.v_wraps[3]);
    if (s274_frames == 0 || s274_late != 0) $fatal(1, "IMX274: no frame, or line bursts late");
    if (u_csi.dly_bad != 0 || u_csi.dly_drop != 0) begin
      $fatal(1, "Versal PHY delay contract: %0d bad loads, %0d dropped loads", u_csi.dly_bad,
             u_csi.dly_drop);
    end
    for (int l = 0; l < 4; l++) begin
      if (loads && u_csi.dly_loads[l] == 0) $fatal(1, "Versal PHY: no delay load on lane %0d", l);
    end
    check_dphy_gate();
  endfunction

  task automatic run_test();
    byte unsigned rsp[$], none[$];
    int unsigned  mark, mark1, step;
    case (test)
      // ROM finds a valid image in flash, waits 1 ms, starts it.
      "boot": begin
        expect_text(0, "boot: starting image");
        expect_text(0, "Hello from Bow32!");
        expect_text(1, "Hello from Bow32 on UART1!");
        mark = log0.len();
        uart_send_str(0, "xyz");
        expect_text(0, "xyz", mark);
      end
      // Empty flash: download the image through the UART loader.
      "load": test_load();
      // A BREAK on UART0 resets the running application into the loader.
      "break": begin
        expect_text(0, "Hello from Bow32!");
        mark = log0.len();
        uart0_break(BreakCycles + 500);
        expect_text(0, "boot: UART break", mark);
        expect_text(0, "UART loader ready", mark);
        boot_cmd(8'h01, none, rsp);
        $display("[%0t] tb   | loader answered INFO after break", $time);
      end
      // Flash programming from the application + software reset.
      "flash": begin
        expect_text(0, "boot count = 1 (record 0, ok)");
        expect_text(0, "-> error");
        expect_text(0, "press 'r'");
        mark = log0.len();
        uart_send(0, "r");
        expect_text(0, "boot count = 2 (record 1, ok)", mark);
      end
      // Interrupt driven echo on UART1.
      "irq": begin
        expect_text(1, "uart_irq ready");
        mark = log1.len();
        uart_send_str(1, "bow32\n");
        expect_text(1, "BOW32", mark);
        expect_text(0, "irqs=");
      end
      // GPIO ports: outputs, inputs, edge interrupt, open-drain, alternate function.
      "gpio": begin
        gpio_setup();
        expect_text(0, "type h for help");
        step = 0;
        while (step < gpio_cmd.size()) begin
          mark  = log0.len();
          mark1 = log1.len();
          uart_send_str(0, {gpio_cmd[step], "\r"});
          if (step == 13) expect_text(1, gpio_rsp[step], mark1);
          else expect_text(0, gpio_rsp[step], mark);
          gpio_check(step, mark);
          step++;
        end
      end
      // Camera path: I2C sensor control, AXI4-Lite device, IMX219 -> CSI-2
      // receiver (eye calibration) -> ISP -> capture -> image over UART,
      // AE/AWB loops.
      "camera": begin
        cam_setup();
        expect_text(0, "camera: IMX219 found (id 0219)");
        expect_text(0, "csi2rx: Bow32 receiver, 2 lanes, PHY clock 108 MHz");
        expect_text(0, "> ");
        step = 0;
        mark = log0.len();
        while (step < cam_cmd.size()) begin
          // "!..." sets a testbench knob
          if (cam_cmd[step].len() > 1 && cam_cmd[step].substr(0, 0) == "!") begin
            case (cam_cmd[step])
              "!mute":   imx_mute = 1'b1;
              "!unmute": imx_mute = 1'b0;
              "!fe":     imx_fe_extra = 1'b1;
              "!nofe":   imx_fe_extra = 1'b0;
              default:   $fatal(1, "unknown testbench step '%s'", cam_cmd[step]);
            endcase
            $display("[%0t] tb   | camera knob %s", $time, cam_cmd[step]);
            step++;
            continue;
          end
          // an empty command waits for more text after the previous command
          if (cam_cmd[step] != "") begin
            mark = log0.len();
            rxq0.delete();
            uart_send_str(0, {cam_cmd[step], "\r"});
          end
          if (cam_cmd[step] == "dump") begin
            receive_image();
            check_bars();
          end
          expect_text(0, cam_rsp[step], mark);
          if (cam_rsp2[step] != "") expect_text(0, cam_rsp2[step], mark);
          if (cam_isp[step] && (out_w != 64 || out_h != 48)) begin
            $fatal(1, "ISP output frame %0dx%0d, expected 64x48", out_w, out_h);
          end
          step++;
        end
        $display("[%0t] tb   | camera frames %0d, ISP output frames %0d (%0dx%0d), D-PHY bursts %0d",
                 $time, cam_frames, out_frames, out_w, out_h, u_csi.bursts_done);
        check_dphy_gate();
      end
      // MIPI CSI-2 receiver with sw/apps/csi2_test: 'test quick' (every check
      // on 64x48 frames), then errors injected into line packets of the
      // running stream must show up exactly in the counters of 'stat'.
      "csi2": begin
        expect_text(0, "csi2_test: Bow32 MIPI CSI-2 receiver test");
        expect_text(0, "camera: IMX219 found (id 0219)");
        expect_text(0, "csi2rx: Bow32 receiver, 2 lanes, PHY clock 108 MHz");
        expect_text(0, "type h for help\n> ");
        mark = log0.len();
        uart_send_str(0, "test quick\r");
        expect_text(0, "csi2_test: PASS (12/12)\nok\n> ", mark);
        check_calibration(mark);
        check_margin(mark);
        // the PHY timing of the firmware's receiver starts: TIM0 of the D-PHY
        // (0x4000_8C24) in lp clock cycles of 108 MHz (INFO[17:8] of the
        // simulation's 107.5 MHz video clock): SETTLE 9 (the SETTLE formula
        // with the INFO2 of the UltraScale+ PHY, 107 ns + 24 UI at 912 Mbit/s,
        // = settle_cycles() of the driver before step 4), LP_FILTER 2,
        // CLK_SETTLE 16 (150 ns), CLK_MISS 4 (one byte clock + 3 cycles)
        mark = send_cmd("rd 40008c24");
        expect_text(0, "40008c24: 04100209\nok\n> ", mark);
        inject_errors();
        mark = log0.len();
        uart_send_str(0, "stat\r");
        expect_text(0, "ok\n> ", mark);
        check_error_counters(mark);
        // drift: the eye of lane 0 now ends at tap 240, so only lane 0 + 48
        // (tap 256) has errors and the points after it are clean again; the
        // taps stay 208/288 and the link is clean once the eye is back
        u_csi.eye_hi[0] = 240;
        csi2_expect_error = 1'b1;
        mark = log0.len();
        uart_send_str(0, "margin 0 4\r");
        expect_text(0, "csi2rx: margin low +-48/+-56 taps: lane 0 +48 (tap 256): ", mark);
        expect_text(0, "error\n> ", mark);
        csi2_expect_error = 1'b0;
        check_margin_point("centre taps 208/288", 1'b0, mark);
        check_margin_point("lane0 -48 tap 160", 1'b0, mark);
        check_margin_point("lane0 +48 tap 256", 1'b1, mark);
        check_margin_point("lane1 -56 tap 232", 1'b0, mark);
        check_margin_point("lane1 +56 tap 344", 1'b0, mark);
        u_csi.eye_hi[0] = 300;
        // the same with the frame timing of a real sensor (LP-11 after every
        // line, vertical blanking: a ~3 ms frame against the 4 ms tap timeout,
        // as 1080p30 against 42 ms), lane 0 - 48 (tap 160, the second point)
        // outside the eye: it may lose the FS of its frame, whose FE then does
        // not count; the points after it must still be measured
        imx_gap_ns    = 47_500;
        imx_vblank_ns = 555_000;
        u_csi.eye_lo[0] = 170;
        csi2_expect_error = 1'b1;
        mark = log0.len();
        uart_send_str(0, "margin 0 4\r");
        expect_text(0, "csi2rx: margin low +-48/+-56 taps: lane 0 -48 (tap 160): ", mark);
        expect_text(0, "error\n> ", mark);
        csi2_expect_error = 1'b0;
        check_margin_point("centre taps 208/288", 1'b0, mark, 4);
        check_margin_point("lane0 -48 tap 160", 1'b1, mark);
        check_margin_point("lane0 +48 tap 256", 1'b0, mark, 4);
        check_margin_point("lane1 -56 tap 232", 1'b0, mark, 4);
        check_margin_point("lane1 +56 tap 344", 1'b0, mark, 4);
        u_csi.eye_lo[0] = 100;
        imx_gap_ns    = 0;
        imx_vblank_ns = VblankNs;
        mark = log0.len();
        uart_send_str(0, "margin 0 4\r");
        expect_text(0, "csi2rx: margin ok +-48/+-56 taps: 0 errors in 5 x 4 frames", mark);
        expect_text(0, "ok\n> ", mark);
        mark = log0.len();
        uart_send_str(0, "stat\r");
        expect_text(0, "csi2rx: link ok", mark);
        expect_text(0, "delay 208/288", mark);
        expect_text(0, "ok\n> ", mark);
        $display("[%0t] tb   | camera frames %0d, D-PHY bursts %0d, bit flips outside the eye %0d",
                 $time, cam_frames, u_csi.bursts_done, u_csi.flips);
        check_dphy_gate();
      end
      // Video path with sw/apps/video: DMA memory to memory copies, ISP test
      // pattern -> H.264 encoder -> DMA -> video RAM -> stream over UART0
      // (decoded and checked by sim/Makefile after the simulation).
      "h264": begin
        int unsigned frames;
        expect_text(0, "h264: Bow32 encoder, max width 2048, 4 strips; DMA 2 channels; video RAM 1024 KiB");
        expect_text(0, "> ");
        video_cmd("dmatest", "dma: 2 x 256 bytes copied, bus error detected\nok\n> ");
        video_cmd("mode 64 48", "ok\n> ");
        video_cmd("tpg 0", "tpg 0 64x48");
        video_cmd("qp 26", "ok\n> ");
        mark = log0.len();
        video_cmd("rec 3", "rec: 3 frames, ");
        expect_text(0, "ok\n> ", mark);
        mark = log0.len();
        rxq0.delete();
        uart_send_str(0, "send\r");
        receive_h264(frames);
        expect_text(0, "END\nok\n> ", mark);
        if (frames != 3) $fatal(1, "%0d frames in the stream, expected 3", frames);
        video_cmd("stat", "record 3 frames");
        // rate control (bow_h264_rc_*): 8 frames of the checker pattern at
        // 1 KiB each, the first QP from the frame size (qp auto); the QP
        // follows the frame sizes, all 8 frames are recorded and the stream
        // decodes (sim/Makefile: h264_rc.hex). 3 frames skipped after each
        // coded one: the test pattern runs at ~4000 fps, faster than the app
        // prints a line at 1 Mbaud (the new QP must also come before the
        // next coded frame starts)
        video_cmd("tpg 2", "tpg 2 64x48");
        video_cmd("qp auto", "ok\n> ");
        mark = log0.len();
        video_cmd("rec 8 3 1", "rec: 8 frames, ");
        expect_text(0, "ok\n> ", mark);
        check_rc(mark, 8, 1024);
        mark = log0.len();
        rxq0.delete();
        uart_send_str(0, "send\r");
        receive_h264(frames, 64, 48, "h264_rc.hex");
        expect_text(0, "END\nok\n> ", mark);
        if (frames != 8) $fatal(1, "%0d frames in the rate control stream, expected 8", frames);
      end
      // MKV block cipher with sw/apps/mkv: Annex A of TCVN 14263:2024 on
      // the IP and in software, IP vs software, ECB, errors, CLEAR, the
      // interrupt line; then one block through the shell commands of
      // tools/bow32_mkv.py (expected value: tools/mkv/mkv_model.py enc 128 ...)
      "mkv": begin
        expect_text(0, "mkv: Bow32 MKV IP, MKV-128 + MKV-256, 4 cycles per round with fault detection");
        expect_text(0, "mkv: power-on self-test PASS");
        expect_text(0, "> ");
        video_cmd("test quick", "mkv: PASS (19/19)\nok\n> ");
        video_cmd("key 128 000102030405060708090a0b0c0d0e0f", "key MKV-128/128 R=7 (114 cycles)\nok\n> ");
        video_cmd("enc 00112233445566778899aabbccddeeff", "out c098d0b88df6c0f81a906eef34e0c43a\nok\n> ");
        video_cmd("dec c098d0b88df6c0f81a906eef34e0c43a", "out 00112233445566778899aabbccddeeff\nok\n> ");
      end
      // DDR2 (LiteDRAM controller + Bow32 PHY) with sw/apps/ddr on the
      // loopback emulator: probe, JEDEC init through LiteDRAM's DFII, read
      // calibration (phase sweep over the MMCM model), hand over to the
      // controller, window loads / stores with read-modify-write, LiteDRAM
      // BIST, the error paths and the interrupt line ("test quick", every
      // item must pass); then the window from the shell, at both ends of the
      // emulator's 4 MiB. The emulator checks every command against the JEDEC
      // rules (DBG): no error may be left, and it must have seen the init.
      "ddr": begin
        string ddr_pass;
        int    ddr_ok, ddr_all;
        expect_text(0, "boot: starting image");
        ddr_en = 1'b1;
        expect_text(0, {"ddr: Bow32 DDR2 x8 (LiteDRAM controller), PHY loopback, 133 MHz (133333333 Hz), ",
                        "504 phase steps, emulator 4096 KiB"});
        expect_text(0, "> ");
        mark = log0.len();
        video_cmd("test quick", "ddr: PASS (");
        expect_text(0, "\nok\n> ", mark);
        ddr_pass = log0_line("ddr: PASS (", mark);
        if ($sscanf(ddr_pass, "%d/%d)", ddr_ok, ddr_all) != 2 || ddr_ok != ddr_all || ddr_all == 0) begin
          $fatal(1, "ddr self-test result 'ddr: PASS (%s', expected (n/n)", ddr_pass);
        end
        video_cmd("wr 80001234 cafef00d", "ok\n> ");
        video_cmd("wr 803ffffc 12345678", "ok\n> ");
        video_cmd("rd 80001234", "80001234: cafef00d\nok\n> ");
        video_cmd("rd 803ffffc", "803ffffc: 12345678\nok\n> ");
        if (ddr_dbg[31] || !ddr_dbg[30]) begin
          $fatal(1, "DRAM emulator: DBG %08x (JEDEC rule errors or init not done)", ddr_dbg);
        end
      end
      // HyperRAM (bow_hyperram) with sw/apps/hyperram on the loopback
      // emulator: probe, enable, RESET#, read calibration (ID0 eye, then the
      // memory pattern eye over the MMCM model), device configuration, window
      // loads / stores (byte masks, read buffer, posted writes), BIST,
      // variable latency, hybrid sleep, deep power down, limits and the
      // interrupt line ("test quick", every item must pass); then the window
      // from the shell at both ends of the emulator's 1 MiB. The emulator
      // checks every transaction against the HyperBus rules (DBG).
      "hyperram": begin
        string hr_pass;
        int    hr_ok, hr_all;
        expect_text(0, "boot: starting image");
        hr_en = 1'b1;
        expect_text(0, {"hyperram: Bow32 HyperRAM 32 MiB x8, PHY loopback, 100 MHz (100000000 Hz), ",
                        "672 phase steps, emulator 1024 KiB"});
        expect_text(0, "> ");
        mark = log0.len();
        video_cmd("test quick", "hyperram: PASS (");
        expect_text(0, "\nok\n> ", mark);
        hr_pass = log0_line("hyperram: PASS (", mark);
        if ($sscanf(hr_pass, "%d/%d)", hr_ok, hr_all) != 2 || hr_ok != hr_all || hr_all == 0) begin
          $fatal(1, "hyperram self-test result 'hyperram: PASS (%s', expected (n/n)", hr_pass);
        end
        video_cmd("wr 60001234 cafef00d", "ok\n> ");
        video_cmd("wr 600ffffc 12345678", "ok\n> ");
        video_cmd("rd 60001234", "60001234: cafef00d\nok\n> ");
        video_cmd("rd 600ffffc", "600ffffc: 12345678\nok\n> ");
        if (hr_dbg[31]) begin
          $fatal(1, "HyperRAM emulator: DBG %08x (HyperBus rule errors)", hr_dbg);
        end
      end
      // IMX274 camera path (Imx274 build) with sw/apps/camera: detection
      // (XCLR reset, reset default signature, 100 kHz I2C), a start before
      // the D-PHY is ready (gives up after 10 ms), then PHY_RDY 1 ms after
      // the next start. The first start calibrates (on the Huins board the
      // BISC delays sit at the early edge of the eyes): here lane 0 has no
      // eye at first, the calibration fails and the lanes keep the BISC
      // delays (loaded back); `margin` then measures around the delays in
      // use (no calibration: never tap 0). With the eye back the next `cam`
      // calibrates (walk of the 4 lanes from the delays in use), `cal` again.
      // AE and AWB are on with a target and a white balance the colour bars
      // cannot meet: they must not step while the sensor test pattern is on
      // (no SHR / PGC write, white balance kept). Sensor colour bars ->
      // CSI-2 receiver -> ISP -> capture -> image over UART (RGGB, also
      // after the vertical flip, written under REGHOLD: no frame with half
      // of it), AE/AWB on the scene, a 1920 pixel wide window (readout mode
      // 3 at HMAX 384: receiver FIFO and ISP at the line rate of the IMX274),
      // stream stop with the receiver stopped before the sensor standby.
      // Clock lane in HS for a whole frame.
      "camera274": begin
        expect_text(0, "Bow32 camera demo (ISP + IMX274), type h for help");
        expect_text(0, "camera: IMX274 found (id 0274)");
        expect_text(0, "csi2rx: Bow32 receiver, 4 lanes, PHY clock 200 MHz");
        expect_text(0, "> ");
        s274_tdiv = 64;
        video_cmd("simfast on", "ok\n> ");
        video_cmd("sr 3004", "sensor[3004] = 03\nok\n> ");
        mark = send_cmd("mode 64 48 0");
        expect_text(0, "note: 64x48 is below the IMX274 minimum window (simulation only)", mark);
        expect_text(0, "mode 64x48 @1992 fps (HMAX 260 VMAX 139)\nok\n> ", mark);
        video_cmd("tp 11", "ok\n> ");
        video_cmd("wb 280 230", "ok\n> ");
        video_cmd("ae 1000", "ok\n> ");
        video_cmd("awb on", "ok\n> ");
        s274_ctrl_tp = 0;
        // D-PHY not ready (XPLL lock + BISC still running)
        video_cmd("csi", ", PHY not ready\nok\n> ");
        err_ok = 1'b1;
        video_cmd("cam", "error: D-PHY not ready (AFE_STATUS.READY = 0)\nerror\n> ");
        u_csi.t_phy_rdy = 32'(longint'(csi2_now())) + 1_000_000;
        // the first start calibrates; lane 0 without an eye: it fails, the
        // lanes keep (load) the BISC delays, the stream runs
        u_csi.eye_lo[0] = 600;
        mark = send_cmd("cam");
        expect_text(0, "csi2rx: calibration failed\nerror\n> ", mark);
        err_ok = 1'b0;
        u_csi.eye_lo[0] = eye274_lo[0];
        for (int l = 0; l < 4; l++) begin
          if (u_csi.dly_loads[l] == 0) $fatal(1, "camera: the first start did not calibrate lane %0d", l);
        end
        mark = send_cmd("margin 0 2");
        expect_text(0, "ok\n> ", mark);
        expect_text(0, "csi2rx: not calibrated: margin around the delays in use 97/112/88/120 (loading them ends the VT tracking)",
                    mark);
        expect_text(0, "margin centre taps 97/112/88/120: 2 frames, 0 errors", mark);
        expect_text(0, "csi2rx: margin ok +-40/+-40/+-40/+-40 taps: 0 errors in 9 x 2 frames", mark);
        // not calibrated yet: the next start calibrates, from the delays in use
        mark = send_cmd("cam");
        expect_text(0, "streaming 64x48 RGGB\nok\n> ", mark);
        check_cal274("csi2rx: calibrated taps ", mark, 16);
        expect_text(0, "csi2rx: margin ok +-40/+-40/+-40/+-40 taps: 0 errors in 9 x 8 frames", mark);
        mark = send_cmd("cal");
        expect_text(0, "ok\n> ", mark);
        check_cal274("csi2rx: calibrated taps ", mark, 16);
        // the margin check after the calibration, 4 lanes: k = eye / 4 = 36/36/32/36
        // is below the minimum 40
        expect_text(0, "csi2rx: margin ok +-40/+-40/+-40/+-40 taps: 0 errors in 9 x 8 frames", mark);
        mark = send_cmd("stat");
        expect_text(0, "ok\n> ", mark);
        if (log0_line("frame ", mark) == "" || out_w != 64 || out_h != 48) begin
          $fatal(1, "ISP: no statistics, or output frame %0dx%0d, expected 64x48", out_w, out_h);
        end
        mark = send_cmd("csi");
        expect_text(0, "csi2rx: link ok\n", mark);
        expect_text(0, "lines/frame 48 wc 80 dt 2b", mark);
        expect_text(0, "ok\n> ", mark);
        check_counters274(mark, 1'b0);
        video_cmd("sr 3045", "sensor[3045] = 32\nok\n> ");
        // colour bars in the middle rows: RGGB, also with the vertical flip
        // (ISP BAYER stays 0)
        for (int i = 0; i < 2; i++) begin
          if (i == 1) video_cmd("flip 0 1", "ok\n> ");
          video_cmd("rd 40006028", "40006028: 00000000\nok\n> ");
          video_cmd("cap 0 22 64 4 0", "captured 64x4 (scale 0)\nok\n> ");
          if (f274_vflip != (i == 1)) $fatal(1, "IMX274: vertical flip %0d at the capture", f274_vflip);
          mark = send_cmd("dump");
          receive_image();
          check_bars();
          expect_text(0, "END\nok\n> ", mark);
        end
        err_ok = 1'b1;
        video_cmd("flip 1 0", "error: the IMX274 has no horizontal mirror\nerror\n> ");
        err_ok = 1'b0;
        video_cmd("flip 0 0", "ok\n> ");
        // AE / AWB did not step during the test pattern: no exposure / gain
        // write, the white balance as set
        if (s274_ctrl_tp != 0) begin
          $fatal(1, "IMX274: %0d exposure / gain writes while a test pattern streamed (AE ran)",
                 s274_ctrl_tp);
        end
        mark = send_cmd("info");
        expect_text(0, "ae on (target 1000)  awb on (r 280 b 230)  source camera", mark);
        expect_text(0, "ok\n> ", mark);
        // scene: auto exposure (SHR) and gray world white balance
        video_cmd("tp 0", "ok\n> ");
        mark = log0.len();
        video_cmd("ae 180", "ok\n> ");
        video_cmd("awb on", "ok\n> ");
        expect_text(0, "ae: locked", mark);
        expect_text(0, "awb: locked", mark);
        mark = send_cmd("info");
        expect_text(0, "mode   64x48, HMAX 260, VMAX 139 = 1992 fps", mark);
        expect_text(0, "ok\n> ", mark);
        video_cmd("awb off", "ok\n> ");
        video_cmd("ae off", "ok\n> ");
        // full width line of the 1080p mode: 2400 byte bursts at 720 MB/s
        // into the receiver FIFO, 1 pixel per video clock out of it
        s274_win_cmd = 1'b1;
        mark = send_cmd("mode 1920 8 0");
        expect_text(0, "note: 1920x8 is below the IMX274 minimum window (simulation only)", mark);
        expect_text(0, "(HMAX 384 VMAX 67)", mark);
        expect_text(0, "streaming 1920x8 RGGB\nok\n> ", mark);
        s274_win     = 2;
        s274_win_cmd = 1'b0;
        mark = send_cmd("stat");
        expect_text(0, "ok\n> ", mark);
        if (log0_line("frame ", mark) == "" || out_w != 1920 || out_h != 8) begin
          $fatal(1, "ISP: no statistics, or output frame %0dx%0d, expected 1920x8", out_w, out_h);
        end
        mark = send_cmd("csi");
        expect_text(0, "csi2rx: link ok\n", mark);
        expect_text(0, "lines/frame 8 wc 2400 dt 2b", mark);
        expect_text(0, "ok\n> ", mark);
        check_counters274(mark, 1'b0);
        // stop: frame end, receiver off, sensor standby (s274_stop checks)
        mark = s274_stops;
        video_cmd("tpg 0", "tpg 0 1920x8\nok\n> ");
        if (s274_stops != mark + 1 || s274_run) $fatal(1, "IMX274: not stopped by 'tpg 0'");
        check_s274_end();
      end
      // MIPI CSI-2 receiver with sw/apps/csi2_test and the IMX274 (Imx274
      // build): the PHY knobs of the D-PHY's registers through `phy` (status
      // with AFE_STATUS, a re-init with CMD.REINIT: one reinit_i pulse, READY
      // drops and comes back with the BISC delays), then 'test quick' (every check on
      // 64x48 frames: phy-idle in standby LP-00, link-up, calibration with a
      // BISC delay outside the eye, integrity with solid 555h/AAAh, packets
      // FS/EMB/OB/lines/FE, timing, ISP colour bars, VC filter, 3 restarts
      // with the standby cancel sequence, FS interrupts), injected errors in
      // the counters of 'stat', raw PHY words of the 4 lanes, then a 1920
      // pixel wide window (stream restarted by 'mode', then 'stop' and
      // 'start'). Clock lane in HS for every burst, D-PHY timing at the
      // limits of the specification with the longest HS-PREPARE (corner 1),
      // byte clocks without a FIFO read in the Versal PHY model. Every
      // receiver start of the firmware leaves the receive path reset on
      // (BurstRxRst, the D-PHY's DES_RST_DIS = 0) with SETTLE 95 ns (TIM0 of
      // the D-PHY), checked after 'test quick' (+S274_DESRST, +S274_SETTLE): with
      // BurstRxRst = 0 the glitch words let the FIFO latency drift up to 8
      // words, which moves the sync search back into the longest HS-PREPARE
      // at SETTLE 95 ns (false syncs, lost lines; +S274_BURSTRST=0 shows it).
      // make -C sim test-extra also runs the firmware built for the other
      // setting, BurstRxRst = 0 with SETTLE 115 ns (sim/Makefile FW=brst0):
      // model only, on the Huins board BurstRxRst = 0 broke at the first receiver
      // re-enable during a stream. Then 'margin' at the taps in use of every
      // lane (lane 2 moved by 'delay'), 'stat' with the receiver off after
      // 'stop' (the 4 lanes of the build), and the link check of 'start' over
      // 16 whole frames: one CRC error in the 6th frame (s274_crc_frame)
      // fails it with the hint to run cal, a clean start passes after 16.
      "csi2_274": begin
        int unsigned us, desrst, settle, tq [4], fr0;
        string       dl, crc_at;
        expect_text(0, "csi2_test: Bow32 MIPI CSI-2 receiver test");
        expect_text(0, "camera: IMX274 found (id 0274)");
        expect_text(0, "csi2rx: Bow32 receiver, 4 lanes, PHY clock 200 MHz");
        expect_text(0, "type h for help\n> ");
        s274_tdiv = 64;
        video_cmd("simfast on", "ok\n> ");
        mark = send_cmd("phy");
        expect_text(0, {"phy: READY 1, every nibble PHY_RDY 1 DLY_RDY 1, XPLL LOCKED 1 LOCKED_FB 1 ",
                        "(AFE_STATUS 00000f01), DES_RST_DIS 0"}, mark);
        expect_text(0, "delays in use 97/112/88/120\nok\n> ", mark);
        mark = send_cmd("phy reinit");
        expect_text(0, "ok\n> ", mark);
        if ($sscanf(log0_line("phy: READY ", mark), "%d us after CMD.REINIT", us) != 1 ||
            s274_reinits != 1 || us + 2 < u_csi.t_reinit / 1000 || us > u_csi.t_reinit / 1000 + 50) begin
          $fatal(1, "PHY re-init: %0d reinit_i pulses, READY after '%s'", s274_reinits,
                 log0_line("phy: READY ", mark));
        end
        expect_text(0, "delays in use 97/112/88/120", mark);
        mark = send_cmd("test quick");
        expect_text(0, "csi2_test: PASS (11/11)\nok\n> ", mark);
        if (log0_line("[PASS] phy-idle all lanes LP-00", mark) == "") begin
          $fatal(1, "phy-idle: the IMX274 lanes must be LP-00 in standby");
        end
        check_cal274("[PASS] calibrate taps ", mark, 32);
        check_margin274(mark);
        void'($sscanf(log0_line("[PASS] calibrate taps ", mark), "%d/%d/%d/%d", tq[0], tq[1], tq[2],
                      tq[3]));
        dl = $sformatf("%0d/%0d/240/%0d", tq[0], tq[1], tq[3]);   // after 'delay 2 240'
        // the PHY setting of the firmware's receiver starts: the receive path
        // reset (BurstRxRst of the model: ~CTRL.DES_RST_DIS of the D-PHY) and
        // SETTLE = TIM0 [7:0] of the D-PHY in 5 ns cycles (0x4000_8C24:
        // CLK_MISS 5, CLK_SETTLE 30, LP_FILTER 2; 0x13 = 95 ns, the SETTLE
        // formula with the INFO2 of the Versal PHY)
        if (!$value$plusargs("S274_DESRST=%d", desrst)) desrst = 1;
        if (!$value$plusargs("S274_SETTLE=%d", settle)) settle = 95;
        if (dut.u_csi2rx.u_dphy_rx.u_regs.burst_rst_en_q != (desrst != 0)) begin
          $fatal(1, "csi2_test: receive path reset %0d after the receiver starts, expected %0d",
                 dut.u_csi2rx.u_dphy_rx.u_regs.burst_rst_en_q, desrst);
        end
        mark = send_cmd("rd 40008c24");
        expect_text(0, $sformatf("40008c24: 051e02%02x\nok\n> ", (settle * 200 + 500) / 1000), mark);
        $display("[%0t] tb   | csi2_274: receiver starts with DES_RST_DIS %0d, SETTLE %0d ns, PHY model BurstRxRst %0d",
                 $time, !dut.u_csi2rx.u_dphy_rx.u_regs.burst_rst_en_q, settle, u_csi.v_burst_rst);
        // margin at the taps in use of every lane: lane 2 moved by hand stays
        // there (centre 240, side points 208 / 272), not back at its
        // calibrated tap
        video_cmd("delay 2 240", "lane 2 tap 240: in use\nok\n> ");
        mark = send_cmd("margin 32 1");
        expect_text(0, "ok\n> ", mark);
        expect_text(0, {"margin centre taps ", dl, ": 1 frames, 0 errors"}, mark);
        expect_text(0, "margin lane2 -32 tap 208: 1 frames, 0 errors", mark);
        expect_text(0, "margin lane2 +32 tap 272: 1 frames, 0 errors", mark);
        expect_text(0, "csi2rx: margin ok +-32/+-32/+-32/+-32 taps: 0 errors in 9 x 1 frames", mark);
        inject_errors();
        mark = send_cmd("stat");
        expect_text(0, "ok\n> ", mark);
        expect_text(0, {", delay ", dl, "\n"}, mark);
        check_counters274(mark, 1'b1);
        mark = send_cmd("raw");
        expect_text(0, "lane 3:", mark);
        expect_text(0, "ok\n> ", mark);
        s274_win_cmd = 1'b1;
        mark = send_cmd("mode 1920 8 0");
        expect_text(0, "mode 1920x8, HMAX 384 VMAX 67 = frame 357 us\nok\n> ", mark);
        s274_win     = 2;
        s274_win_cmd = 1'b0;
        video_cmd("stop", "ok\n> ");
        if (s274_run) $fatal(1, "IMX274: still streaming after 'stop'");
        // receiver off: the lane lists of 'stat' have the 4 lanes of the build
        mark = send_cmd("stat");
        expect_text(0, " sot 0/0/0/0 ovf ", mark);
        expect_text(0, " d3 ", mark);
        expect_text(0, {", delay ", dl, "\nok\n> "}, mark);
        // the link check of 'start' takes 16 whole frames: a CRC error in
        // the 6th frame, after the 64 packets (19 per 1920x8 frame) it took
        // before, fails it with the hint to run cal; a clean one passes only
        // after 16 frames. The check counts the frames that start after it
        // clears the counters: with 357 us frames the first one can start
        // during the I2C write after the sensor's master start (SYNCDRV,
        // ~0.4 ms), so the error is in frame 5 or 6 of the check.
        s274_crc_frame = 6;
        mark = send_cmd("start");
        expect_text(0, "ok\n> ", mark);
        crc_at = log0_line("  errors in frame ", mark);
        if (s274_crc_sent != 1 ||
            log0_line("streaming 1920x8 RAW10, link check ", mark) != "failed (ERR_STATUS 008), try cal" ||
            (crc_at != {"5 of 16 at the delays in use ", dl, ": after a PDI load or"} &&
             crc_at != {"6 of 16 at the delays in use ", dl, ": after a PDI load or"}) ||
            log0_line("  phy reinit these are the BISC delays", mark) !=
              ", early in the eye; cal loads the eye centres") begin
          $fatal(1, "csi2_test: 'start' with a CRC error in its 6th frame (%0d sent) answered '%s'",
                 s274_crc_sent, log0.substr(mark, log0.len() - 1));
        end
        fr0 = s274_frames;
        video_cmd("start", "streaming 1920x8 RAW10, link check ok\nok\n> ");
        if (s274_frames - fr0 < 16) begin
          $fatal(1, "csi2_test: 'start' said 'link check ok' after %0d frames, expected 16",
                 s274_frames - fr0);
        end
        $display("[%0t] tb   | csi2_274: start link check: CRC error of sensor frame 6 found (frame %s), clean after %0d frames",
                 $time, crc_at.substr(0, 6), s274_frames - fr0);
        mark = send_cmd("irq");
        expect_text(0, "FS interrupts in 4 frames\nok\n> ", mark);
        mark = send_cmd("stat");
        expect_text(0, "csi2rx: link ok\n", mark);
        expect_text(0, "lines/frame 8 wc 2400 dt 2b", mark);
        expect_text(0, "ok\n> ", mark);
        check_counters274(mark, 1'b0);
        check_s274_end();
      end
      // Video path with sw/apps/video on the IMX274 (Imx274 build): the
      // sensor model with the datasheet's VMAX reset value 0x905 (the others
      // run with the board's 0x906), the camera start of the video app with
      // the real standby cancel waits (the app has no `simfast`) and its
      // calibration, the IMX274 timing it programs for the H.264 encoder,
      // sensor colour bars -> CSI-2 receiver -> ISP (YUV) -> H.264 encoder at
      // the 200 MHz video clock -> DMA -> video RAM -> stream over UART0,
      // decoded by sim/Makefile (h264_274a.hex, h264_274b.hex:
      // tools/h264/h264_model.py decode --bars). A 64x48 window, then
      // 1920x32 at the line length the app sets for the encoder (the stream
      // restarts): no dropped pixel, 3 frames each, then `stop` (receiver off
      // before the sensor standby). AE and AWB stay on (the default) with a
      // target the colour bars cannot meet: no exposure / gain write while
      // the test pattern is on. Clock lane in HS for a whole frame, D-PHY
      // timing at the shortest HS-PREPARE (corner 2).
      "video274": begin
        int unsigned frames, coded, w, h, fps, hmax, vmax, load;
        longint      mbc;
        string       s;
        expect_text(0, "camera: IMX274 found (id 0274)");
        expect_text(0, "csi2rx: Bow32 receiver, 4 lanes, PHY clock 200 MHz");
        expect_text(0, "h264: Bow32 encoder, max width 2048, 4 strips; DMA 2 channels; video RAM 1024 KiB");
        expect_text(0, "> ");
        // AE / AWB on (the default), AE with a target the bars cannot meet:
        // while the sensor test pattern is on neither steps (else AE would
        // write the sensor every 3 frames at 100 kHz, which also keeps the
        // CPU away from the shell long enough to lose bytes of a typed
        // command in the 16 byte UART FIFO)
        video_cmd("ae 1000", "ok\n> ");
        video_cmd("tp 11", "ok\n> ");
        video_cmd("qp 26", "ok\n> ");
        s274_ctrl_tp = 0;
        for (int k = 0; k < 2; k++) begin
          // 64x48 at the shortest frame (sensor minimum HMAX), then 1920x32
          // at the encoder line length with a short frame (VMAX)
          s274_win_cmd = 1'b1;
          w    = (k == 0) ? 64 : 1920;
          mark = send_cmd((k == 0) ? "mode 64 48 2000" : "mode 1920 32 900");
          expect_text(0, "ok\n> ", mark);
          s = log0_line($sformatf("mode %0dx", w), mark);      // (not the echo of the command)
          if ($sscanf(s, "%d @%d fps (HMAX %d VMAX %d)", h, fps, hmax, vmax) != 4 ||
              h != ((k == 0) ? 48 : 32)) begin
            $fatal(1, "video app: 'mode' answered 'mode %0dx%s'", w, s);
          end
          if (k == 0) begin
            mark = send_cmd("cam");
            expect_text(0, "ok\n> ", mark);
          end
          if (log0_line($sformatf("streaming %0dx%0d @", w, h), mark) == "") begin
            $fatal(1, "video app: no stream of %0dx%0d", w, h);
          end
          s274_win     = 2;
          s274_win_cmd = 1'b0;
          if (!s274_run || f274_w != w || f274_h != h || f274_hmax != hmax || f274_vmax != vmax) begin
            $fatal(1, "IMX274: streaming %0d, %0dx%0d HMAX %0d VMAX %0d, the app said %0dx%0d HMAX %0d VMAX %0d",
                   s274_run, f274_w, f274_h, f274_hmax, f274_vmax, w, h, hmax, vmax);
          end
          mark = send_cmd("rec 3");
          expect_text(0, "rec: 3 frames, ", mark);
          expect_text(0, "ok\n> ", mark);
          rxq0.delete();
          mark = send_cmd("send");
          receive_h264(frames, w, h, (k == 0) ? "h264_274a.hex" : "h264_274b.hex");
          expect_text(0, "END\nok\n> ", mark);
          if (frames != 3) $fatal(1, "%0d frames in the stream, expected 3", frames);
          // encoder load at this line length: a strip of 16 lines (32 HMAX at
          // 72 MHz) against W / 16 macroblocks, at the cycles per macroblock
          // the engine took (MB_CYCLES of the recording / coded macroblocks)
          mark = send_cmd("stat");
          expect_text(0, "record 3 frames", mark);
          expect_text(0, "ok\n> ", mark);
          if ($sscanf(log0_line(" frames ", mark), "%d", coded) != 1 || coded == 0 ||
              $sscanf(log0_line("engine cycles ", mark), "%d", mbc) != 1 || mbc == 0) begin
            $fatal(1, "video app: no frame count or engine cycles in 'stat'");
          end
          mbc  = mbc / (longint'(coded) * (w / 16) * (h / 16));
          load = 32'((longint'(w / 16) * mbc * 72_000_000 * 100) / (longint'(VidClkHz) * 32 * hmax));
          $display("[%0t] tb   | video274: %0dx%0d HMAX %0d VMAX %0d, %0d cycles per macroblock: H.264 load %0d %%",
                   $time, w, h, hmax, vmax, mbc, load);
          if (load > 100) $fatal(1, "video app: HMAX %0d is too short for the encoder (%0d %%)", hmax, load);
        end
        if (s274_ctrl_tp != 0) begin
          $fatal(1, "IMX274: %0d exposure / gain writes while a test pattern streamed (AE ran)",
                 s274_ctrl_tp);
        end
        // stop: frame end, receiver off, sensor standby (s274_stop checks)
        mark = s274_stops;
        video_cmd("stop", "ok\n> ");
        if (s274_stops != mark + 1 || s274_run) $fatal(1, "IMX274: not stopped by 'stop'");
        check_s274_end();
      end
      // Optional (sim/Makefile test-extra): csi2_test starts the IMX274 in a
      // full size mode (+S274_GEO, default 1080p; 720p...): the sensor model
      // checks the register set of the driver when it latches the format at
      // the stream start (readout mode, crop, timing). Ends there.
      "geo274": begin
        string md;
        if (!$value$plusargs("S274_GEO=%s", md)) md = "1080p";
        expect_text(0, "type h for help\n> ");
        s274_tdiv = 64;
        video_cmd("simfast on", "ok\n> ");
        mark = send_cmd({"mode ", md});
        expect_text(0, "ok\n> ", mark);
        mark = s274_latched;
        void'(send_cmd("start"));
        while (s274_latched == mark) @(posedge clk);
        $display("[%0t] tb   | geo274 %s: %0dx%0d, readout mode %0d (binning %0d), %0d OB lines, HMAX %0d VMAX %0d",
                 $time, md, f274_w, f274_h, f274_mode, f274_hbin, f274_ob, f274_hmax, f274_vmax);
      end
      default: $fatal(1, "unknown +TEST=%s", test);
    endcase
  endtask

  // ------------------------------------------------------------------ main
  initial begin
    longint unsigned timeout = Imx274 ? 40_000_000 : 20_000_000;
    int unsigned     contclk;
    int unsigned     corner;
    if (!$value$plusargs("TEST=%s", test)) test = "boot";
    if (test == "camera") timeout = 30_000_000;   // + a link check without data
    if (!$value$plusargs("ROM=%s", rom_file)) $fatal(1, "+ROM=<vmem> required");
    void'($value$plusargs("TIMEOUT=%d", timeout));
    if ($test$plusargs("WAVES")) begin
      $dumpfile("waves.fst");
      $dumpvars(0, tb_bow32);
    end

    // camera274, csi2_274, video274 and geo274 need the IMX274 build, the
    // other tests the default one
    if (Imx274 != (test == "camera274" || test == "csi2_274" || test == "video274" ||
                   test == "geo274")) begin
      $fatal(1, "test '%s' runs on the %s build of the testbench (sim/Makefile picks it)", test,
             Imx274 ? "default (Imx274 = 0)" : "IMX274 (Imx274 = 1)");
    end

    // Eye of the data lanes (IDELAY taps): every tap good, except in the
    // csi2 test (and there the reset tap 0 is bad on both lanes)
    if (test == "csi2") begin
      u_csi.eye_lo[0] = 100;
      u_csi.eye_lo[1] = 180;
      u_csi.eye_hi[0] = 300;
      u_csi.eye_hi[1] = 400;
    end

    // IMX274 build: Versal PHY mode of the TX model (set at time 0; its RX
    // FIFOs as in the shipped build: BurstRxRst from the D-PHY's
    // DES_RST_DIS, one latency for all lanes, 20 % glitch words per HS entry
    // of the clock lane), byte clock 180 MHz (1440 Mbit/s per lane), PHY_RDY
    // 40 us after the start and 40 us after a re-init (camera274: only when
    // the test says so), eyes of the 4 lanes (see "IMX274 tests"), clock
    // lane mode, D-PHY corner, PRSNT_M2C_L (PB5) = 0: module fitted, PB6 /
    // PB7 = 0 (no longer wired in the camera top)
    if (Imx274) begin
      u_csi.versal       = 1'b1;
      u_csi.byte_ns      = 1.0e3 / 180.0;
      u_csi.t_phy_rdy    = (test == "camera274") ? 32'hFFFF_FFFF : 40_000;
      u_csi.t_reinit     = 40_000;
      u_csi.v_glitch_pct = 20;
      // VMAX after reset: the board's 0x906, the datasheet's 0x905 in video274
      s274_vmax_rst = (test == "video274") ? 'h905 : 'h906;
      if ($value$plusargs("S274_VMAX_RST=%h", contclk)) s274_vmax_rst = contclk;
      s274_defaults();
      if (test == "camera274" || test == "video274") begin
        eye274_lo = '{40, 60, 30, 70};
        eye274_hi = '{180, 200, 150, 220};
        s274_contclk = 1'b1;
      end else begin
        eye274_lo = '{64, 96, 160, 128};
        eye274_hi = '{320, 352, 400, 384};
        s274_contclk = 1'b0;
        u_csi.v_gap_pm = 2;
      end
      if ($value$plusargs("S274_CONTCLK=%d", contclk)) s274_contclk = contclk != 0;
      if ($value$plusargs("S274_BURSTRST=%d", contclk)) s274_brst_force = (contclk != 0) ? 1 : 0;
      if ($value$plusargs("S274_GLITCH=%d", contclk)) u_csi.v_glitch_pct = contclk;
      corner = (test == "csi2_274") ? 1 : (test == "video274") ? 2 : 0;
      void'($value$plusargs("DPHY_CORNER=%d", corner));
      if (corner != 0) s274_dphy_corner(corner);
      for (int l = 0; l < 4; l++) begin
        u_csi.eye_lo[l] = eye274_lo[l];
        u_csi.eye_hi[l] = eye274_hi[l];
      end
      ext_b_en[5]    = 1'b1;
      ext_b_val[5]   = 1'b0;
      ext_b_en[7:6]  = 2'b11;
    end

    fork
      begin
        while (cycle < timeout) @(posedge clk);
        $fatal(1, "TIMEOUT after %0d cycles (test %s)", timeout, test);
      end
    join_none

    // Assert reset with a real falling edge (see bow_rstmgr), then
    // backdoor-load the memories after their own initial blocks ran.
    #1;
    rst_n = 1'b0;
    $readmemh(rom_file, dut.u_rom.u_rom.mem);
    if ($value$plusargs("FLASH=%s", flash_file)) begin
      $readmemh(flash_file, dut.u_flash.u_array.mem);
    end

    $display("[%0t] tb   | test '%s'  rom=%s  flash=%s", $time, test, rom_file,
             flash_file == "" ? "<erased>" : flash_file);
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
    ce_bad0 = u_csi.ce_bad;

    run_test();

    repeat (100) @(posedge clk);
    $display("[%0t] tb   | TEST PASSED: %s (%0d cycles)", $time, test, cycle);
    $finish;
  end

endmodule
