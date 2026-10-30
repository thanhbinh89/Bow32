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
// Plusargs:
//   +TEST=<name>      boot | load | break | flash | irq | gpio | camera | csi2 (see run_test below)
//   +ROM=<vmem>       boot ROM image (required)
//   +FLASH=<vmem>     image preloaded into the flash (backdoor)
//   +IMAGE=<vmem>     image downloaded over UART by the 'load' test
//   +TIMEOUT=<cycles> abort after this many cycles (default 20M)
//   +WAVES            dump waves to build/sim/waves.fst (needs WAVES=1 build)

`timescale 1ns / 1ps

module tb_bow32;
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
  // the CPU clock (200 MHz on the KV260)
  localparam real         VidPeriodNs = 9.3;
  localparam int unsigned VidClkHz    = 107_526_882;        // 1 / 9.3 ns
  logic vclk = 1'b0;
  always #(VidPeriodNs / 2) vclk = ~vclk;

  longint unsigned cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

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

  // D-PHY receive I/O of the CSI-2 receiver (csi2_tx_model below) and ISP output
  logic            dphy_byte_clk, dphy_byte_ce, dphy_byte_rst, dphy_clk_hs_en;
  logic [1:0]      dphy_clk_lp, dphy_hs_en, dphy_dly_load;
  logic [1:0][1:0] dphy_lp;
  logic [1:0][7:0] dphy_rx_data;
  logic [1:0][8:0] dphy_dly_tap, dphy_dly_tap_rb;
  logic            isp_tvalid, isp_tuser, isp_tlast;
  logic [23:0]     isp_tdata;

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

  bow32_top #(
    .ClkFreqHz   (ClkFreqHz),
    .BootBaud    (Baud),
    .BootWaitMs  (1),
    .BreakCycles (BreakCycles),
    .CsiLanes    (2),
    .CsiPhy      (1'b1),
    .VidClkHz    (VidClkHz)
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
    .dphy_byte_clk_i  (dphy_byte_clk),
    .dphy_byte_ce_o   (dphy_byte_ce),
    .dphy_byte_rst_o  (dphy_byte_rst),
    .dphy_clk_lp_i    (dphy_clk_lp),
    .dphy_clk_hs_en_o (dphy_clk_hs_en),
    .dphy_lp_i        (dphy_lp),
    .dphy_hs_en_o     (dphy_hs_en),
    .dphy_rx_data_i   (dphy_rx_data),
    .dphy_dly_tap_o   (dphy_dly_tap),
    .dphy_dly_load_o  (dphy_dly_load),
    .dphy_dly_tap_i   (dphy_dly_tap_rb),
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
    .sys_rst_no   (sys_rst_n),
    .core_sleep_o (core_sleep)
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

  // csi2 test: a failed check of the firmware, or a command answered with
  // "error" (every command of this test must succeed), stops the simulation
  // at once
  function automatic void check_line0(string line);
    if (test == "csi2" && (contains(line, "[FAIL]") || contains(line, "csi2_test: FAIL") ||
                           (line.len() >= 5 && line.substr(0, 4) == "error"))) begin
      $fatal(1, "csi2_test reported a failure: %s", line);
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
  // ------------------------------------------------------------- I2C devices
  // TCA9546A switch at 0x74 (one control byte = channel enables) and, behind
  // its channel 2, the IMX219 at 0x10: 16 bit register address, then data
  // bytes with auto increment. The sensor only answers when it is powered
  // (PA7 = RPI_ENABLE driven high). The sensor stretches SCL now and then.
  localparam logic [6:0] TcaAddr = 7'h74;
  localparam logic [6:0] ImxAddr = 7'h10;

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
    b = imx_reg[imx_ptr];
    imx_ptr++;
    return b;
  endfunction

  function automatic void i2c_rx_byte(logic [7:0] b);
    if (i2c_dev == 1) begin
      tca_ctrl = b;
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
          i2c_dev = (i2c_sh[7:1] == TcaAddr) ? 1 :
                    (i2c_sh[7:1] == ImxAddr && tca_ctrl[2] && cam_powered) ? 2 : 0;
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

  csi2_tx_model #(.Lanes(2)) u_csi (
    .byte_clk_o  (dphy_byte_clk),
    .byte_ce_i   (dphy_byte_ce),
    .byte_rst_i  (dphy_byte_rst),
    .clk_lp_o    (dphy_clk_lp),
    .clk_hs_en_i (dphy_clk_hs_en),
    .lp_o        (dphy_lp),
    .hs_en_i     (dphy_hs_en),
    .rx_data_o   (dphy_rx_data),
    .dly_tap_i   (dphy_dly_tap),
    .dly_load_i  (dphy_dly_load),
    .dly_tap_o   (dphy_dly_tap_rb)
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

  function automatic bit imx_streaming();
    return imx_reg[16'h0100][0] && cam_powered;
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
  // sync byte, the odd packet bytes, then the HS-trail constant.
  function automatic bit lane1_locks(csi2_bytes_t pkt, logic [7:0] sync);
    byte unsigned lane [$];
    logic [15:0]  w;
    logic         trail;
    lane.delete();
    lane.push_back(sync);
    for (int unsigned k = 1; k < pkt.size(); k += 2) lane.push_back(pkt[k]);
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
    end
    u_csi.push_short(0, 8'h01, cf_num, f);                              // FE
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
    forever begin
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
          #(VblankNs);
        end
      end
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
    cam_add("cam", "csi2rx: calibrated taps 248/248 eye 512/512\nstreaming 64x48 RGGB");
    cam_add("stat", "in 64x48", "", 1'b1);
    cam_add("csi", "csi2rx: link ok\n", "lines/frame 48 wc 80 dt 2b");
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
    int unsigned ecc0, ecc1, crc, trunc, sot0, sot1, drop, ovf, misc;
    s = log0_line("  errors: ", from);
    if ($sscanf(s, "ecc %d/%d crc %d trunc %d sot %d/%d drop %d ovf %d misc %d", ecc0, ecc1, crc,
                trunc, sot0, sot1, drop, ovf, misc) != 9) begin
      $fatal(1, "no error counters in the 'stat' answer");
    end
    if (ecc0 != 1 || ecc1 != 0 || crc != 1 || trunc != 0 || sot0 != 0 || sot1 != 1 || ovf != 0 ||
        misc < 1) begin
      $fatal(1, "error counters '%s', expected ecc 1/0 crc 1 trunc 0 sot 0/1 ovf 0 misc >= 1", s);
    end
    $display("[%0t] tb   | error counters ok: %s", $time, s);
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
        expect_text(0, "csi2_test: PASS (11/11)\nok\n> ", mark);
        check_calibration(mark);
        inject_errors();
        mark = log0.len();
        uart_send_str(0, "stat\r");
        expect_text(0, "ok\n> ", mark);
        check_error_counters(mark);
        $display("[%0t] tb   | camera frames %0d, D-PHY bursts %0d, bit flips outside the eye %0d",
                 $time, cam_frames, u_csi.bursts_done, u_csi.flips);
        check_dphy_gate();
      end
      default: $fatal(1, "unknown +TEST=%s", test);
    endcase
  endtask

  // ------------------------------------------------------------------ main
  initial begin
    longint unsigned timeout = 20_000_000;
    if (!$value$plusargs("TEST=%s", test)) test = "boot";
    if (!$value$plusargs("ROM=%s", rom_file)) $fatal(1, "+ROM=<vmem> required");
    void'($value$plusargs("TIMEOUT=%d", timeout));
    if ($test$plusargs("WAVES")) begin
      $dumpfile("waves.fst");
      $dumpvars(0, tb_bow32);
    end

    // Eye of the data lanes (IDELAY taps): every tap good, except in the
    // csi2 test (and there the reset tap 0 is bad on both lanes)
    if (test == "csi2") begin
      u_csi.eye_lo = '{100, 180};
      u_csi.eye_hi = '{300, 400};
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
