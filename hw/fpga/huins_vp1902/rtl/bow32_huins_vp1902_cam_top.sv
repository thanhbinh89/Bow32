// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 + camera on the Huins MFP-VP1902-S Versal platform (AMD Versal Premium
// xcvp1902-vsva6865-2MP-e-S): Leopard LI-IMX274MIPI-FMC (Sony IMX274) on the Huins camera
// adapter on FMC+01 -> Bow32 MIPI CSI-2 receiver (4 lanes x 1440 Mbit/s) -> Bow32 ISP ->
// capture buffer / H.264 encoder. No vendor CSI-2 or D-PHY IP: the pins go to
// bow_dphy_io_versal (IBUFDS_DPHY, XPHY, XPLL, BUFGCE), the LP state machines, the byte
// alignment and the CSI-2 layer are bow_mipi_rx inside the SoC (CSI2RX registers at
// 0x4000_8000), as on the KV260 (docs/camera_kv260.md). Board preparation, build and use:
// docs/camera_huins.md. Only the PL is used: Vivado adds a default PS wizard (PMC) to the
// device image, loaded over the board's USB JTAG.
//
// The Huins documents are confidential: no FPGA ball number is in the repo.
// tools/huins_pins.py writes the pin XDC from the board netlist and constr/pins.txt
// ([all] + [card=cam], FMC_SITE 1) at build time.
//
// Camera pins (all in XPIO bank 705 through the adapter, VCCIO = SW192 at 1.2 V):
//   mipi_clk_*      CLK0_M2C  clock lane = XPHY strobe
//   mipi_data_*[0]  LA10      data lanes, in the XPHY nibbles the strobe reaches (its own,
//   mipi_data_*[1]  CLK1_M2C    inter-nibble, inter-byte). Which nibble and slice each pair
//   mipi_data_*[2]  LA08        is in is board data: the nibble plan of u_dphy (parameters
//   mipi_data_*[3]  LA06        Dphy*) comes from the pins at build time, see u_dphy below
//   cam_scl_io / cam_sda_io  LA26_P / LA26_N  sensor I2C = I2C0 (IMX274 at 0x1A, no switch)
//   cam_xclr_o      LA22_N    FMC_RST -> sensor XCLR (0 = reset) = PA7
//   cam_xce_o       LA27_P    FMC_SPI_CS_N -> sensor XCE: 1 (I2C mode)
//   cam_flash_o     LA16_N    FMC_FLASH: 1 (as AMD's designs drive it)
//   fmc_prsnt_n_i   PRSNT_M2C_L of FMC+01 (bank 703, pull-up to the site VCCIO): PB5
// The FMC+10 pads of the RAM card build are not used here (unconstrained: the card's
// level shifters isolate themselves); the RAM card may stay on FMC+10 (SW196 at 1.5 V).
//
// Clocks (bow32_huins_vp1902_cam_clk, from the fixed 200 MHz board oscillator, bank 718):
//   clk_sys   50 MHz   SoC (MMCME5 VCO 3200 MHz / 64)
//   clk_vid   200 MHz  ISP, H.264, CSI-2 LP state machines and PHY control, XPHY CTRL_CLK
//                      (the receiver's tap logic runs in this domain: CsiDlyVid = 1)
//   XPLL      200 MHz input (own BUFG) x 15 / 2 = 1500 MHz PLL_CLK of the bank 705 XPHYs
//   byte clk  180 MHz  D-PHY byte clock (clock lane / 4), runs during HS bursts only
// Reset: USER_RESET_N (front panel H_RESET, active low) and the MMCM locked: SoC reset =
// rst_n_i & locked (bow_rstmgr inside the SoC), video domain and PHY reset = the same,
// synchronised to clk_vid (the PHY then runs XPLL lock + BISC again, phy_rdy after ~40 us
// in simulation, AM010: up to 1.3 ms). Software can re-initialise the PHY alone with PA4.
//
// UARTs: as the RAM card build (CP2102N "UART0" = Bow32 UART0, "UART1" = PB0 / PB1).
// GPIO (PA4 / PA5 / PB6 / PB7: the D-PHY knobs and status of bow_dphy_io_versal, for the
// bring-up questions only the silicon answers; after reset every PA pin is an input, so
// both knobs are 0 = the AMD-like behaviour):
//   PA0..PA3  F_LED1..4  outputs: lit while the pin is an output driving 1
//   PA4       D-PHY re-init (u_dphy reinit_i): output 1 holds the PHY in its init reset
//             (XPLL and XPHY resets, CSI2RX STATUS.PHY_RDY = 0, loaded DLYn taps lost); 0 or
//             input: XPLL lock, BISC and VT tracking run again (~40 us in simulation, AM010:
//             up to 1.3 ms). Hold 1 for >= 10 us (synchronised in clk_vid)
//   PA5       D-PHY per-burst reset (u_dphy burst_rst_en_i): output 1 = RX_RST of the data
//             slices while the byte clock gate is closed (FIFOs drained before every burst);
//             0 or input = no per-burst reset (AMD's choice)
//   PA6       no pin
//             (IN of PA0..PA7 reads back the driven level)
//   PA7       sensor XCLR: output 1 = sensor running; input (reset state) or 0 = sensor
//             held in reset (the KV260 "PA7 = 1 -> camera on"); F_LED8 shows it
//   PB0       XIO_RX_OUT1 bidirectional pad (pull-up), UART1 TX after reset
//   PB1       XIO_TX_IN1  input only, UART1 RX after reset
//   PB2..PB4  F_PB1..3    push buttons, input only, IN = 1 while pressed
//   PB5       PRSNT_M2C_L of FMC+01, IN = 0 while the camera module is fitted (the raw
//             level, unlike the RAM card build where PB5 = 1 means "card fitted")
//   PB6       D-PHY PHY_RDY of all XPHY nibbles, input only: the raw XPHY status (not gated
//             by the init sequencer like STATUS.PHY_RDY, which also needs XPLL LOCKED)
//   PB7       D-PHY DLY_RDY of all XPHY nibbles, input only (BISC delay calibration done;
//             PB7 = 1 while PB6 stays 0: the calibration finished, PHY_RDY did not follow)
//   (PB6 / PB7 cross clk_vid -> clk_sys in the GPIO input synchronisers)
// Status LEDs (not GPIO):
//   F_LED5    D-PHY byte clock seen in the last ~84 ms (clock lane HS bursts)
//   F_LED6    frame activity: toggles every 8 frames at the ISP output
//   F_LED7    XPLL of the D-PHY bank locked
//   F_LED8    PA7 (sensor out of reset)
//   F_LED9    heartbeat (1.5 Hz while the SoC is out of reset)
//   F_LED10   D-PHY ready (XPLL locked, BISC done: CSI2RX STATUS.PHY_RDY)
//   F_LED11   camera module fitted (PRSNT_M2C_L = 0)
//   F_LED12   MMCM locked (SoC and video clocks)
//
// No DDR, no HyperRAM (DdrEn = HrEn = 0: stubs, as on the KV260), no AXI4-Lite device
// (the bridge times out), no video output (the ISP stream feeds the H.264 encoder).

module bow32_huins_vp1902_cam_top #(
  parameter              RomInitFile   = "",
  parameter              FlashInitFile = "",
  parameter real         ClkInPeriodNs = 5.0,   // 200 MHz (CLK_SRC ref200)
  parameter int unsigned VcoMult       = 16,    // VCO 3200 MHz
  // XPHY nibble plan of the camera pins (bow_dphy_io_versal NumNib, NibPhys, NibRole,
  // NibSrc, LaneNib, LaneSlice; one bank). Board data: tcl/build.tcl sets them from the
  // plan tcl/cam_plan.tcl derives from the generated pin XDC. The defaults are the PHY's
  // synthetic plan (lint): a build with them stops in tcl/pre_opt_cam.tcl.
  parameter int unsigned DphyNumNib    = 4,
  parameter logic [15:0] DphyNibPhys   = 16'h2564,
  parameter logic [7:0]  DphyNibRole   = 8'b10_01_10_00,
  parameter logic [7:0]  DphyNibSrc    = 8'b00_00_00_00,
  parameter logic [7:0]  DphyLaneNib   = 8'b11_01_10_00,
  parameter logic [11:0] DphyLaneSlice = 12'b010_000_100_010
) (
  input  wire        clk_p_i,          // clock input pair (constr/clk_ref200.xdc)
  input  wire        clk_n_i,
  input  logic       rst_n_i,          // USER_RESET_N, active low

  output logic       uart0_tx_o,       // XIO_RX_OUT0
  input  logic       uart0_rx_i,       // XIO_TX_IN0
  inout  wire        uart1_tx_io,      // XIO_RX_OUT1 = PB0
  input  logic       uart1_rx_i,       // XIO_TX_IN1 = PB1

  output logic [11:0] led_o,           // F_LED1..12, active high
  input  logic [2:0]  pb_i,            // F_PB1..3, active high
  input  logic        fmc_prsnt_n_i,   // PRSNT_M2C_L of the camera site, 0 = module fitted

  // MIPI CSI-2 D-PHY of the camera (bank 705, MIPI_DPHY)
  input  wire        mipi_clk_p_i,
  input  wire        mipi_clk_n_i,
  input  wire [3:0]  mipi_data_p_i,
  input  wire [3:0]  mipi_data_n_i,

  // sensor control (bank 705, LVCMOS12)
  inout  wire        cam_scl_io,       // I2C0 SCL (open drain)
  inout  wire        cam_sda_io,       // I2C0 SDA (open drain)
  output logic       cam_xclr_o,       // sensor XCLR, 0 = reset (PA7)
  output logic       cam_xce_o,        // sensor XCE, 1
  output logic       cam_flash_o       // module FLASH, 1
);

  localparam int unsigned SysClkHz  = 50_000_000;
  localparam int unsigned VidClkHz  = 200_000_000;
  localparam int unsigned SysDivide = 64;                       // VCO 3200 MHz / 64
  localparam int unsigned VidDivide = 16;                       // VCO 3200 MHz / 16
  localparam int unsigned CsiLanes  = 4;
  localparam              SimDevice = "VERSAL_PREMIUM";

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic clk_sys, clk_vid, xpll_clk, locked;

  // constr/huins_vp1902_cam.xdc names the generated clocks after the pins of u_clk
  bow32_huins_vp1902_cam_clk #(
    .ClkInPeriodNs (ClkInPeriodNs),
    .InDivide      (1),
    .VcoMult       (VcoMult),
    .SysDivide     (SysDivide),
    .VidDivide     (VidDivide)
  ) u_clk (
    .clk_pad_i   (clk_p_i),
    .clk_pad_n_i (clk_n_i),
    .rst_i       (1'b0),
    .clk_sys_o   (clk_sys),
    .clk_vid_o   (clk_vid),
    .xpll_clk_o  (xpll_clk),
    .locked_o    (locked)
  );

  // SoC: asynchronous, released through bow_rstmgr inside the SoC. Video domain and PHY:
  // released synchronously to clk_vid.
  logic rst_n, vid_rst_n;
  assign rst_n = rst_n_i & locked;

  bow_rst_sync u_vid_rst (
    .clk_i  (clk_vid),
    .rst_ni (rst_n),
    .rst_no (vid_rst_n)
  );

  // ---------------------------------------------------------------------------
  // D-PHY receive I/O. The nibble plan (Dphy* parameters) is the one of the camera pins,
  // derived at build time (tcl/cam_plan.tcl) and checked against the placed pins before
  // opt_design (tcl/pre_opt_cam.tcl, tcl/cam_xphy.tcl). The XDC refers to the instance
  // name u_dphy. reinit_i / burst_rst_en_i: GPIO PA4 / PA5 (below).
  // ---------------------------------------------------------------------------
  logic                     dphy_byte_clk, dphy_byte_ce, dphy_byte_rst, dphy_clk_hs_en;
  logic                     dphy_phy_rdy, dphy_reinit_q, dphy_burst_rst_q;
  logic [3:0]               dphy_status;
  logic [1:0]               dphy_clk_lp;
  logic [CsiLanes-1:0][1:0] dphy_lp;
  logic [CsiLanes-1:0]      dphy_hs_en, dphy_rx_valid, dphy_dly_load;
  logic [CsiLanes-1:0][7:0] dphy_rx_data;
  logic [CsiLanes-1:0][8:0] dphy_dly_tap, dphy_dly_tap_out;

  bow_dphy_io_versal #(
    .Lanes         (CsiLanes),
    .NumNib        (DphyNumNib),
    .NibPhys       (DphyNibPhys),
    .NibBank       (8'h00),
    .NibRole       (DphyNibRole),
    .NibSrc        (DphyNibSrc),
    .LaneNib       (DphyLaneNib),
    .LaneSlice     (DphyLaneSlice),
    .NumPll        (1),
    .CheckPlan     (1'b1),
    .ClkInPeriodNs (ClkInPeriodNs),
    .SimDevice     (SimDevice)
  ) u_dphy (
    .clk_p          (mipi_clk_p_i),
    .clk_n          (mipi_clk_n_i),
    .data_p         (mipi_data_p_i),
    .data_n         (mipi_data_n_i),
    .ctrl_clk_i     (clk_vid),
    .ctrl_rst_ni    (vid_rst_n),
    .pll_clkin_i    (xpll_clk),
    .reinit_i       (dphy_reinit_q),
    .burst_rst_en_i (dphy_burst_rst_q),
    .phy_rdy_o      (dphy_phy_rdy),
    .phy_status_o   (dphy_status),
    .byte_clk_o     (dphy_byte_clk),
    .byte_ce_i      (dphy_byte_ce),
    .byte_rst_i     (dphy_byte_rst),
    .clk_lp_o       (dphy_clk_lp),
    .clk_hs_en_i    (dphy_clk_hs_en),
    .lp_o           (dphy_lp),
    .hs_en_i        (dphy_hs_en),
    .rx_data_o      (dphy_rx_data),
    .rx_valid_o     (dphy_rx_valid),
    .clk_q_o        (),
    .dly_tap_i      (dphy_dly_tap),
    .dly_load_i     (dphy_dly_load),
    .dly_tap_o      (dphy_dly_tap_out)
  );

  // ---------------------------------------------------------------------------
  // SoC
  // ---------------------------------------------------------------------------
  logic [7:0]  gpioa_i, gpioa_o, gpioa_oe;
  logic [7:0]  gpiob_i, gpiob_o, gpiob_oe;
  logic        scl_i, scl_oe, sda_i, sda_oe;
  logic        sys_rst_n;
  logic        isp_tvalid, isp_tuser;

  bow32_top #(
    .ClkFreqHz     (SysClkHz),
    .BootBaud      (115_200),
    .BootWaitMs    (300),
    .RomInitFile   (RomInitFile),
    .FlashInitFile (FlashInitFile),
    .IbexRegFile   (ibex_pkg::RegFileFPGA),
    .CsiLanes      (CsiLanes),
    .CsiPhy        (1'b1),
    .CsiFifoDepth  (512),                 // 2048 px: a 1080p line burst (receiver FIFO)
    .CsiDlyVid     (1'b1),                // tap control in clk_vid = XPHY CTRL_CLK
    .VidClkHz      (VidClkHz)
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
    .i2c0_scl_i   (scl_i),
    .i2c0_scl_oe_o(scl_oe),
    .i2c0_sda_i   (sda_i),
    .i2c0_sda_oe_o(sda_oe),
    .vid_clk_i    (clk_vid),
    .vid_rst_ni   (vid_rst_n),
    // no video output: the ISP stream feeds the H.264 encoder inside the SoC
    .isp_tvalid_o (isp_tvalid),
    .isp_tready_i (1'b1),
    .isp_tdata_o  (),
    .isp_tuser_o  (isp_tuser),
    .isp_tlast_o  (),
    .dphy_byte_clk_i  (dphy_byte_clk),
    .dphy_byte_ce_o   (dphy_byte_ce),
    .dphy_byte_rst_o  (dphy_byte_rst),
    .dphy_clk_lp_i    (dphy_clk_lp),
    .dphy_clk_hs_en_o (dphy_clk_hs_en),
    .dphy_lp_i        (dphy_lp),
    .dphy_hs_en_o     (dphy_hs_en),
    .dphy_rx_data_i   (dphy_rx_data),
    .dphy_rx_valid_i  (dphy_rx_valid),
    .dphy_phy_rdy_i   (dphy_phy_rdy),
    .dphy_dly_tap_o   (dphy_dly_tap),
    .dphy_dly_load_o  (dphy_dly_load),
    .dphy_dly_tap_i   (dphy_dly_tap_out),
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
    // no DDR in this build (DdrEn = 0: stub)
    .ddr_sys_clk_i  (1'b0),
    .ddr_clk_i      (1'b0),
    .ddr_rst_ni     (1'b0),
    .ddr_rd_clk_i   (1'b0),
    .ddr_ps_en_o    (),
    .ddr_ps_inc_o   (),
    .ddr_ps_done_i  (1'b0),
    .ddr_wps_en_o   (),
    .ddr_wps_inc_o  (),
    .ddr_wps_done_i (1'b0),
    .ddr_io_o       (),
    .ddr_io_i       ('0),
    .ddr_dbg_i      ('0),
    // no HyperRAM in this build (HrEn = 0: stub)
    .hr_clk_i       (1'b0),
    .hr_rst_ni      (1'b0),
    .hr_rd_clk_i    (1'b0),
    .hr_ps_en_o     (),
    .hr_ps_inc_o    (),
    .hr_ps_done_i   (1'b0),
    .hr_wps_en_o    (),
    .hr_wps_inc_o   (),
    .hr_wps_done_i  (1'b0),
    .hr_io_o        (),
    .hr_io_i        ('0),
    .hr_rwds_pad_i  (1'b0),
    .hr_dbg_i       ('0),
    .sys_rst_no   (sys_rst_n),
    .core_sleep_o ()
  );

  // ---------------------------------------------------------------------------
  // Sensor control pads (bank 705, LVCMOS12)
  // ---------------------------------------------------------------------------
  // I2C0, open drain. Versal XPIO: I and T of a bidirectional pad must come from flops in
  // the pad site (DRC PDCN-2749): an ODDRE1 drives I (constant 0), a second one T (both
  // halves ~oe, SRVAL 1 = released after configuration), clocked by clk_sys (as the
  // TFromOddr pads of the RAM card build). The line level goes to the controller's
  // synchronisers. constr/cam_pads.xdc: PULLUP, DRIVE 8.
  logic [1:0] i2c_oe, i2c_in;
  assign i2c_oe = {sda_oe, scl_oe};
  assign scl_i  = i2c_in[0];
  assign sda_i  = i2c_in[1];

  for (genvar k = 0; k < 2; k++) begin : g_i2c
    logic q, t;

    ODDRE1 #(
      .SIM_DEVICE (SimDevice),
      .SRVAL      (1'b0)
    ) u_oddr (
      .C  (clk_sys),
      .D1 (1'b0),
      .D2 (1'b0),
      .SR (1'b0),
      .Q  (q)
    );

    ODDRE1 #(
      .SIM_DEVICE (SimDevice),
      .SRVAL      (1'b1)
    ) u_toddr (
      .C  (clk_sys),
      .D1 (~i2c_oe[k]),
      .D2 (~i2c_oe[k]),
      .SR (1'b0),
      .Q  (t)
    );

    if (k == 0) begin : g_scl
      IOBUF u_iobuf (.I (q), .T (t), .O (i2c_in[k]), .IO (cam_scl_io));
    end else begin : g_sda
      IOBUF u_iobuf (.I (q), .T (t), .O (i2c_in[k]), .IO (cam_sda_io));
    end
  end

  // XCLR = PA7 (0 while PA7 is an input, i.e. after reset); XCE and FLASH fixed at 1
  logic xclr;
  assign xclr        = gpioa_oe[7] & gpioa_o[7];
  assign cam_xclr_o  = xclr;
  assign cam_xce_o   = 1'b1;
  assign cam_flash_o = 1'b1;

  // ---------------------------------------------------------------------------
  // GPIO and user components
  // ---------------------------------------------------------------------------
  // PA0..PA7: output only (LEDs F_LED1..4, D-PHY knobs on PA4 / PA5, XCLR on PA7), IN =
  // driven level
  assign gpioa_i = gpioa_oe & gpioa_o;

  // D-PHY knobs PA4 (reinit_i) and PA5 (burst_rst_en_i): one clk_sys flop each, so that
  // the PHY's synchronisers see a flop, not the AND of the GPIO OUT and OE registers
  always_ff @(posedge clk_sys or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      dphy_reinit_q    <= 1'b0;
      dphy_burst_rst_q <= 1'b0;
    end else begin
      dphy_reinit_q    <= gpioa_oe[4] & gpioa_o[4];
      dphy_burst_rst_q <= gpioa_oe[5] & gpioa_o[5];
    end
  end

  // PB0: UART1 TX after reset, a real pad (the CP2102N input has no driver)
  IOBUF u_pad_pb0 (
    .I  (gpiob_o[0]),
    .T  (~gpiob_oe[0]),
    .O  (gpiob_i[0]),
    .IO (uart1_tx_io)
  );

  // PB1..PB7: input only; their outputs never reach a pad. PB6 / PB7: the D-PHY status
  // (PHY_RDY and DLY_RDY of all nibbles, synchronised to clk_vid in u_dphy).
  assign gpiob_i[1]   = uart1_rx_i;
  assign gpiob_i[4:2] = pb_i;
  assign gpiob_i[5]   = fmc_prsnt_n_i;
  assign gpiob_i[6]   = dphy_status[3];
  assign gpiob_i[7]   = dphy_status[2];

  // ---------------------------------------------------------------------------
  // Status LEDs
  // ---------------------------------------------------------------------------
  // heartbeat: SoC out of reset
  logic [24:0] heartbeat_q;
  always_ff @(posedge clk_sys or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      heartbeat_q <= '0;
    end else begin
      heartbeat_q <= heartbeat_q + 1'b1;
    end
  end

  // Byte clock activity: the byte clock / 16 (a free running counter, only its toggling
  // matters, no reset in a domain that stops), synchronised to clk_vid; every edge
  // retriggers a 2^24 cycle (84 ms) monoflop.
  logic [3:0]  bclk_div_q = '0;
  logic        bclk_s, bclk_last_q;
  logic [23:0] bclk_alive_q;

  always_ff @(posedge dphy_byte_clk) bclk_div_q <= bclk_div_q + 4'd1;

  bow_sync u_sync_bclk (
    .clk_i  (clk_vid),
    .rst_ni (vid_rst_n),
    .d_i    (bclk_div_q[3]),
    .q_o    (bclk_s)
  );

  // Frame activity: start of frame at the ISP output (isp_tready_i = 1), 8 frames per
  // LED toggle
  logic [3:0] frame_q;

  always_ff @(posedge clk_vid or negedge vid_rst_n) begin
    if (!vid_rst_n) begin
      bclk_last_q  <= 1'b0;
      bclk_alive_q <= '0;
      frame_q      <= '0;
    end else begin
      bclk_last_q <= bclk_s;
      if (bclk_s != bclk_last_q) begin
        bclk_alive_q <= '1;
      end else if (bclk_alive_q != '0) begin
        bclk_alive_q <= bclk_alive_q - 24'd1;
      end
      if (isp_tvalid && isp_tuser) begin
        frame_q <= frame_q + 4'd1;
      end
    end
  end

  assign led_o[3:0] = gpioa_oe[3:0] & gpioa_o[3:0];
  assign led_o[4]   = (bclk_alive_q != '0);
  assign led_o[5]   = frame_q[3];
  assign led_o[6]   = dphy_status[0];          // XPLL LOCKED (synchronised to clk_vid)
  assign led_o[7]   = xclr;
  assign led_o[8]   = heartbeat_q[24];
  assign led_o[9]   = dphy_phy_rdy;
  assign led_o[10]  = ~fmc_prsnt_n_i;
  assign led_o[11]  = locked;

  logic unused;
  assign unused = ^{gpiob_o[7:1], gpiob_oe[7:1], dphy_status[1]};

endmodule
