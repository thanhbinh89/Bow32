// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 SoC top level (technology independent).
//
//   Ibex (instr) --+                          +--> ROM    8 KiB
//                  +--> main xbar (2 x 6) ----+--> FLASH  128 KiB (memory window)
//   Ibex (data) ---+                          +--> SRAM   16 KiB
//                                             +--> ISP capture buffer -------------+
//                                             +--> AXI4-Lite bridge --> m_axil_*   |
//                                             +--> periph xbar (1 x 8)             |
//                                                    +--> SYSCTRL (+ reset manager)|
//                                                    +--> FLASH_CTRL               |
//                                                    +--> UART0                    |
//                                                    +--> UART1 --(alternate function)--+
//                                                    +--> GPIOA  8 pins            |    |
//                                                    +--> GPIOB  8 pins, PB0/PB1 <-+----+
//                                                    +--> ISP registers ------+    |
//                                                    +--> I2C0 --> scl/sda    |    |
//                                                                             |    |
//   cam_* (RAW10 AXI4-Stream, vid_clk_i) --> ISP (bow_isp) <------------------+----+
//                                             +--> isp_* (RGB888/YUV444 AXI4-Stream)
//
// Addresses and port numbers come from bow32_memmap_pkg (generated from
// hw/top/data/bow32_memmap.yaml). See docs/architecture.md.

module bow32_top import bow_bus_pkg::*; import bow32_memmap_pkg::*; #(
  parameter int unsigned        ClkFreqHz     = 50_000_000,
  // Boot configuration exposed to the ROM through SYSCTRL
  parameter int unsigned        BootBaud      = 115_200,
  parameter int unsigned        BootWaitMs    = 300,
  // UART0 RX low for this many cycles resets the SoC into the bootloader
  parameter int unsigned        BreakCycles   = ClkFreqHz / 100,
  // Memory initialisation ($readmemh, one 32 bit word per line)
  parameter                     RomInitFile   = "",
  parameter                     FlashInitFile = "",
  // CPU options
  parameter ibex_pkg::regfile_e IbexRegFile   = ibex_pkg::RegFileFF,
  // ISP: maximum line width and capture buffer size (24 bit words, the
  // isp_buf window of the memory map holds up to 32768)
  parameter int unsigned        IspMaxWidth   = 2048,
  parameter int unsigned        IspBufWords   = 32768,
  // AXI4-Lite window: address bits passed to the AXI device
  parameter int unsigned        AxilAddrWidth = 16
) (
  input  logic clk_i,
  input  logic rst_ni,        // asynchronous board reset, active low

  input  logic       uart0_rx_i,
  output logic       uart0_tx_o,

  // GPIO pads: pad = *_oe_o ? *_o : Z, *_i = pad level. After reset all pins
  // are inputs except PB0/PB1, which carry UART1 TX/RX (GPIOB.AF = 0x03).
  input  logic [7:0] gpioa_i,
  output logic [7:0] gpioa_o,
  output logic [7:0] gpioa_oe_o,
  input  logic [7:0] gpiob_i,
  output logic [7:0] gpiob_o,
  output logic [7:0] gpiob_oe_o,

  // I2C0 pads, open drain: *_oe_o = 1 pulls the line low, *_i = line level
  input  logic       i2c0_scl_i,
  output logic       i2c0_scl_oe_o,
  input  logic       i2c0_sda_i,
  output logic       i2c0_sda_oe_o,

  // Video clock domain: camera input (RAW10, tuser = start of frame,
  // tlast = end of line) and ISP output (UG934 order: RGB {R,B,G},
  // YUV444 {V,U,Y}). The ISP output must accept one pixel per clock.
  input  logic        vid_clk_i,
  input  logic        vid_rst_ni,
  input  logic        cam_tvalid_i,
  output logic        cam_tready_o,
  input  logic [9:0]  cam_tdata_i,
  input  logic        cam_tuser_i,
  input  logic        cam_tlast_i,
  output logic        isp_tvalid_o,
  input  logic        isp_tready_i,
  output logic [23:0] isp_tdata_o,
  output logic        isp_tuser_o,
  output logic        isp_tlast_o,

  // AXI4-Lite master (axil window of the memory map, clk_i domain)
  output logic [AxilAddrWidth-1:0] m_axil_awaddr_o,
  output logic [2:0]               m_axil_awprot_o,
  output logic                     m_axil_awvalid_o,
  input  logic                     m_axil_awready_i,
  output logic [31:0]              m_axil_wdata_o,
  output logic [3:0]               m_axil_wstrb_o,
  output logic                     m_axil_wvalid_o,
  input  logic                     m_axil_wready_i,
  input  logic [1:0]               m_axil_bresp_i,
  input  logic                     m_axil_bvalid_i,
  output logic                     m_axil_bready_o,
  output logic [AxilAddrWidth-1:0] m_axil_araddr_o,
  output logic [2:0]               m_axil_arprot_o,
  output logic                     m_axil_arvalid_o,
  input  logic                     m_axil_arready_i,
  input  logic [31:0]              m_axil_rdata_i,
  input  logic [1:0]               m_axil_rresp_i,
  input  logic                     m_axil_rvalid_i,
  output logic                     m_axil_rready_o,

  // Status (for LEDs / debug)
  output logic       sys_rst_no,
  output logic       core_sleep_o
);

  // ---------------------------------------------------------------------------
  // Clock and reset
  // ---------------------------------------------------------------------------
  logic por_rst_n, sys_rst_n, sys_rst_req;

  bow_rstmgr u_rstmgr (
    .clk_i,
    .por_ni        (rst_ni),
    .sys_rst_req_i (sys_rst_req),
    .por_rst_no    (por_rst_n),
    .sys_rst_no    (sys_rst_n)
  );

  assign sys_rst_no = sys_rst_n;

  // ---------------------------------------------------------------------------
  // Interrupts
  // ---------------------------------------------------------------------------
  logic        uart0_irq, uart1_irq, flash_irq, gpioa_irq, gpiob_irq, isp_irq, i2c0_irq;
  logic [14:0] irq_fast;

  always_comb begin
    irq_fast               = '0;
    irq_fast[IrqFastUart0] = uart0_irq;
    irq_fast[IrqFastUart1] = uart1_irq;
    irq_fast[IrqFastFlash] = flash_irq;
    irq_fast[IrqFastGpioa] = gpioa_irq;
    irq_fast[IrqFastGpiob] = gpiob_irq;
    irq_fast[IrqFastIsp]   = isp_irq;
    irq_fast[IrqFastI2c0]  = i2c0_irq;
  end

  // ---------------------------------------------------------------------------
  // CPU
  // ---------------------------------------------------------------------------
  localparam int unsigned HostInstr = 0;
  localparam int unsigned HostData  = 1;
  localparam int unsigned NumHosts  = 2;

  bus_req_t [NumHosts-1:0] host_req;
  bus_rsp_t [NumHosts-1:0] host_rsp;

  bow_cpu_ibex #(
    .BootAddr (BootAddr),
    .RegFile  (IbexRegFile)
  ) u_cpu (
    .clk_i,
    .rst_ni         (sys_rst_n),
    .instr_req_o    (host_req[HostInstr]),
    .instr_rsp_i    (host_rsp[HostInstr]),
    .data_req_o     (host_req[HostData]),
    .data_rsp_i     (host_rsp[HostData]),
    .irq_software_i (1'b0),
    .irq_timer_i    (1'b0),
    .irq_external_i (1'b0),
    .irq_fast_i     (irq_fast),
    .core_sleep_o
  );

  // ---------------------------------------------------------------------------
  // Main crossbar
  // ---------------------------------------------------------------------------
  bus_req_t [MainNumDevices-1:0] main_req;
  bus_rsp_t [MainNumDevices-1:0] main_rsp;

  bow_bus_xbar #(
    .NumHosts   (NumHosts),
    .NumDevices (MainNumDevices),
    .DevBase    (MainDevBase),
    .DevMask    (MainDevMask)
  ) u_main_xbar (
    .clk_i,
    .rst_ni     (sys_rst_n),
    .host_req_i (host_req),
    .host_rsp_o (host_rsp),
    .dev_req_o  (main_req),
    .dev_rsp_i  (main_rsp)
  );

  bow_rom #(
    .SizeBytes   (RomSize),
    .MemInitFile (RomInitFile)
  ) u_rom (
    .clk_i,
    .rst_ni    (sys_rst_n),
    .bus_req_i (main_req[MainDevRom]),
    .bus_rsp_o (main_rsp[MainDevRom])
  );

  bow_sram #(
    .SizeBytes (SramSize)
  ) u_sram (
    .clk_i,
    .rst_ni    (sys_rst_n),
    .bus_req_i (main_req[MainDevSram]),
    .bus_rsp_o (main_rsp[MainDevSram])
  );

  // ---------------------------------------------------------------------------
  // Peripheral bus
  // ---------------------------------------------------------------------------
  bus_req_t [PeriphNumDevices-1:0] periph_req;
  bus_rsp_t [PeriphNumDevices-1:0] periph_rsp;

  bow_bus_xbar #(
    .NumHosts   (1),
    .NumDevices (PeriphNumDevices),
    .DevBase    (PeriphDevBase),
    .DevMask    (PeriphDevMask)
  ) u_periph_xbar (
    .clk_i,
    .rst_ni     (sys_rst_n),
    .host_req_i (main_req[MainDevPeriph]),
    .host_rsp_o (main_rsp[MainDevPeriph]),
    .dev_req_o  (periph_req),
    .dev_rsp_i  (periph_rsp)
  );

  bow_sysctrl #(
    .ChipId      (ChipId),
    .ClkFreqHz   (ClkFreqHz),
    .BootBaud    (BootBaud),
    .BootWaitMs  (BootWaitMs),
    .BreakCycles (BreakCycles)
  ) u_sysctrl (
    .clk_i,
    .rst_ni        (por_rst_n),
    .bus_req_i     (periph_req[PeriphDevSysctrl]),
    .bus_rsp_o     (periph_rsp[PeriphDevSysctrl]),
    .uart0_rx_i,
    .sys_rst_req_o (sys_rst_req)
  );

  bow_flash #(
    .SizeBytes   (FlashSize),
    .MemInitFile (FlashInitFile)
  ) u_flash (
    .clk_i,
    .rst_ni    (sys_rst_n),
    .mem_req_i (main_req[MainDevFlash]),
    .mem_rsp_o (main_rsp[MainDevFlash]),
    .reg_req_i (periph_req[PeriphDevFlashCtrl]),
    .reg_rsp_o (periph_rsp[PeriphDevFlashCtrl]),
    .irq_o     (flash_irq)
  );

  localparam logic [15:0] BootBaudDiv = 16'((ClkFreqHz + BootBaud / 2) / BootBaud);

  bow_uart #(
    .ResetBaudDiv (BootBaudDiv)
  ) u_uart0 (
    .clk_i,
    .rst_ni    (sys_rst_n),
    .bus_req_i (periph_req[PeriphDevUart0]),
    .bus_rsp_o (periph_rsp[PeriphDevUart0]),
    .rx_i      (uart0_rx_i),
    .tx_o      (uart0_tx_o),
    .irq_o     (uart0_irq)
  );

  logic uart1_rx, uart1_tx;

  bow_uart #(
    .ResetBaudDiv (BootBaudDiv)
  ) u_uart1 (
    .clk_i,
    .rst_ni    (sys_rst_n),
    .bus_req_i (periph_req[PeriphDevUart1]),
    .bus_rsp_o (periph_rsp[PeriphDevUart1]),
    .rx_i      (uart1_rx),
    .tx_o      (uart1_tx),
    .irq_o     (uart1_irq)
  );

  // ---------------------------------------------------------------------------
  // GPIO ports (IOPAD). UART1 is the alternate function of PB0 (TX) and PB1 (RX).
  // ---------------------------------------------------------------------------
  bow_gpio #(
    .Width (8)
  ) u_gpioa (
    .clk_i,
    .rst_ni    (sys_rst_n),
    .bus_req_i (periph_req[PeriphDevGpioa]),
    .bus_rsp_o (periph_rsp[PeriphDevGpioa]),
    .gpio_i    (gpioa_i),
    .gpio_o    (gpioa_o),
    .gpio_oe_o (gpioa_oe_o),
    .af_out_i  ('0),
    .af_oe_i   ('0),
    .af_in_o   (),
    .irq_o     (gpioa_irq)
  );

  logic [7:0] gpiob_af_in;

  bow_gpio #(
    .Width   (8),
    .AfMask  (8'h03),
    .AfReset (8'h03)
  ) u_gpiob (
    .clk_i,
    .rst_ni    (sys_rst_n),
    .bus_req_i (periph_req[PeriphDevGpiob]),
    .bus_rsp_o (periph_rsp[PeriphDevGpiob]),
    .gpio_i    (gpiob_i),
    .gpio_o    (gpiob_o),
    .gpio_oe_o (gpiob_oe_o),
    .af_out_i  ({7'h0, uart1_tx}),
    .af_oe_i   (8'h01),
    .af_in_o   (gpiob_af_in),
    .irq_o     (gpiob_irq)
  );

  assign uart1_rx = gpiob_af_in[1];

  logic unused_af;
  assign unused_af = ^{gpiob_af_in[7:2], gpiob_af_in[0]};

  // ---------------------------------------------------------------------------
  // Camera path: ISP (registers on the peripheral bus, capture buffer on the
  // main bus) and I2C0 for the sensor control
  // ---------------------------------------------------------------------------
  bow_isp #(
    .MaxWidth (IspMaxWidth),
    .BufWords (IspBufWords)
  ) u_isp (
    .clk_i,
    .rst_ni          (sys_rst_n),
    .reg_req_i       (periph_req[PeriphDevIsp]),
    .reg_rsp_o       (periph_rsp[PeriphDevIsp]),
    .buf_req_i       (main_req[MainDevIspBuf]),
    .buf_rsp_o       (main_rsp[MainDevIspBuf]),
    .irq_o           (isp_irq),
    .vid_clk_i,
    .vid_rst_ni,
    .s_axis_tvalid_i (cam_tvalid_i),
    .s_axis_tready_o (cam_tready_o),
    .s_axis_tdata_i  (cam_tdata_i),
    .s_axis_tuser_i  (cam_tuser_i),
    .s_axis_tlast_i  (cam_tlast_i),
    .m_axis_tvalid_o (isp_tvalid_o),
    .m_axis_tready_i (isp_tready_i),
    .m_axis_tdata_o  (isp_tdata_o),
    .m_axis_tuser_o  (isp_tuser_o),
    .m_axis_tlast_o  (isp_tlast_o)
  );

  bow_i2c u_i2c0 (
    .clk_i,
    .rst_ni    (sys_rst_n),
    .bus_req_i (periph_req[PeriphDevI2c0]),
    .bus_rsp_o (periph_rsp[PeriphDevI2c0]),
    .scl_i     (i2c0_scl_i),
    .scl_oe_o  (i2c0_scl_oe_o),
    .sda_i     (i2c0_sda_i),
    .sda_oe_o  (i2c0_sda_oe_o),
    .irq_o     (i2c0_irq)
  );

  // ---------------------------------------------------------------------------
  // AXI4-Lite window (devices of the FPGA block design)
  // ---------------------------------------------------------------------------
  bow_axil_bridge #(
    .AddrWidth (AxilAddrWidth)
  ) u_axil (
    .clk_i,
    .rst_ni    (sys_rst_n),
    .bus_req_i (main_req[MainDevAxil]),
    .bus_rsp_o (main_rsp[MainDevAxil]),
    .m_axil_awaddr_o,
    .m_axil_awprot_o,
    .m_axil_awvalid_o,
    .m_axil_awready_i,
    .m_axil_wdata_o,
    .m_axil_wstrb_o,
    .m_axil_wvalid_o,
    .m_axil_wready_i,
    .m_axil_bresp_i,
    .m_axil_bvalid_i,
    .m_axil_bready_o,
    .m_axil_araddr_o,
    .m_axil_arprot_o,
    .m_axil_arvalid_o,
    .m_axil_arready_i,
    .m_axil_rdata_i,
    .m_axil_rresp_i,
    .m_axil_rvalid_i,
    .m_axil_rready_o
  );

endmodule
