// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 system controller.
//
// Register map (see docs/ip/sysctrl.md):
//   0x00 CHIP_ID    R  : chip identification (memory map 'chip_id')
//   0x04 CLK_FREQ   R  : system clock frequency in Hz
//   0x08 RST_CAUSE  R/W1C: [0] POR  [1] SW  [2] BREAK (UART0 break)
//   0x0C RST_CTRL   W  : write ResetKey to request a system reset
//   0x10 BOOT_FLAG  RW : scratch register that survives system resets, used by
//                        firmware to ask the boot ROM for a boot mode
//   0x14 BOOT_WAIT  R  : [15:0] time (ms) the ROM waits for the host
//   0x18 BOOT_BAUD  R  : baud rate used by the boot ROM on UART0
//   0x1C BRK_CTRL   RW : [0] reset the SoC when a BREAK is seen on UART0 RX
//
// All registers live in the POR reset domain (rst_ni = por_rst_n) so they
// keep their value across system resets.
//
// BREAK detection: when UART0 RX stays low for BreakCycles clock cycles the
// controller requests a system reset and sets RST_CAUSE.BREAK. The boot ROM
// then enters the UART loader, which lets a host tool always take control of
// the chip without a reset button. The detector re-arms once the line is high.

module bow_sysctrl import bow_bus_pkg::*; #(
  parameter logic [31:0] ChipId      = 32'h0,
  parameter int unsigned ClkFreqHz   = 50_000_000,
  parameter int unsigned BootBaud    = 115_200,
  parameter int unsigned BootWaitMs  = 300,
  parameter int unsigned BreakCycles = ClkFreqHz / 100,   // 10 ms
  parameter logic [31:0] ResetKey    = 32'h5253_5421        // "RST!"
) (
  input  logic     clk_i,
  input  logic     rst_ni,          // POR domain reset

  input  bus_req_t bus_req_i,
  output bus_rsp_t bus_rsp_o,

  input  logic     uart0_rx_i,      // asynchronous pin, for BREAK detection
  output logic     sys_rst_req_o    // to bow_rstmgr
);

  localparam logic [11:0] RegChipId   = 12'h000;
  localparam logic [11:0] RegClkFreq  = 12'h004;
  localparam logic [11:0] RegRstCause = 12'h008;
  localparam logic [11:0] RegRstCtrl  = 12'h00C;
  localparam logic [11:0] RegBootFlag = 12'h010;
  localparam logic [11:0] RegBootWait = 12'h014;
  localparam logic [11:0] RegBootBaud = 12'h018;
  localparam logic [11:0] RegBrkCtrl  = 12'h01C;

  localparam int unsigned BrkCntWidth = $clog2(BreakCycles + 1);

  logic [11:0] reg_addr;
  logic        reg_we, reg_re;
  logic [31:0] wdata;

  assign reg_addr = {bus_req_i.addr[11:2], 2'b00};
  assign reg_we   = bus_req_i.req &  bus_req_i.we;
  assign reg_re   = bus_req_i.req & ~bus_req_i.we;
  assign wdata    = bus_req_i.wdata;

  // ---------------------------------------------------------------------------
  // UART break detector
  // ---------------------------------------------------------------------------
  logic                   rx_sync;
  logic [BrkCntWidth-1:0] brk_cnt_q;
  logic                   brk_armed_q;
  logic                   brk_en_q;
  logic                   brk_trigger;

  bow_sync #(
    .ResetValue (1'b1)
  ) u_rx_sync (
    .clk_i,
    .rst_ni,
    .d_i (uart0_rx_i),
    .q_o (rx_sync)
  );

  assign brk_trigger = brk_en_q && brk_armed_q && !rx_sync &&
                       (brk_cnt_q == BrkCntWidth'(BreakCycles - 1));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      brk_cnt_q   <= '0;
      brk_armed_q <= 1'b0;
    end else begin
      if (rx_sync) begin
        brk_cnt_q   <= '0;
        brk_armed_q <= 1'b1;
      end else begin
        if (brk_cnt_q != BrkCntWidth'(BreakCycles)) brk_cnt_q <= brk_cnt_q + 1'b1;
        if (brk_trigger) brk_armed_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic [2:0]  rst_cause_q;
  logic [31:0] boot_flag_q;
  logic        sw_rst_req;
  logic        sys_rst_req_q;

  assign sw_rst_req = reg_we && (reg_addr == RegRstCtrl) && (wdata == ResetKey);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rst_cause_q   <= 3'b001;     // POR
      boot_flag_q   <= '0;
      brk_en_q      <= 1'b1;
      sys_rst_req_q <= 1'b0;
    end else begin
      if (reg_we && reg_addr == RegRstCause) rst_cause_q <= rst_cause_q & ~wdata[2:0];
      if (reg_we && reg_addr == RegBootFlag) boot_flag_q <= wdata;
      if (reg_we && reg_addr == RegBrkCtrl)  brk_en_q    <= wdata[0];
      if (sw_rst_req)  rst_cause_q[1] <= 1'b1;
      if (brk_trigger) rst_cause_q[2] <= 1'b1;
      sys_rst_req_q <= sw_rst_req | brk_trigger;
    end
  end

  assign sys_rst_req_o = sys_rst_req_q;

  // Read data
  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q;

  always_comb begin
    rdata_d = '0;
    unique case (reg_addr)
      RegChipId:   rdata_d = ChipId;
      RegClkFreq:  rdata_d = ClkFreqHz;
      RegRstCause: rdata_d = {29'h0, rst_cause_q};
      RegBootFlag: rdata_d = boot_flag_q;
      RegBootWait: rdata_d = BootWaitMs;
      RegBootBaud: rdata_d = BootBaud;
      RegBrkCtrl:  rdata_d = {31'h0, brk_en_q};
      default:     rdata_d = '0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else begin
      rvalid_q <= bus_req_i.req;
      if (reg_re) rdata_q <= rdata_d;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = rdata_q;

  logic unused_bus;
  assign unused_bus = ^{bus_req_i.addr[31:12], bus_req_i.addr[1:0], bus_req_i.be};

endmodule
