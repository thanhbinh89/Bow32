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
// (TCA9546A switch + IMX219 sensor registers), the RAW10 stream of the MIPI
// CSI-2 receiver and the receiver's AXI4-Lite registers.
//
// Plusargs:
//   +TEST=<name>      boot | load | break | flash | irq | gpio | camera   (see run_test below)
//   +ROM=<vmem>       boot ROM image (required)
//   +FLASH=<vmem>     image preloaded into the flash (backdoor)
//   +IMAGE=<vmem>     image downloaded over UART by the 'load' test
//   +TIMEOUT=<cycles> abort after this many cycles (default 20M)
//   +WAVES            dump waves to build/sim/waves.fst (needs WAVES=1 build)

`timescale 1ns / 1ps

module tb_bow32;

  // ---------------------------------------------------------------- config
  localparam int unsigned ClkFreqHz   = 50_000_000;
  localparam int unsigned Baud        = 1_000_000;          // fast UART for simulation
  localparam int unsigned BitCycles   = ClkFreqHz / Baud;   // 50
  localparam int unsigned BreakCycles = 2000;               // 40 us instead of 10 ms
  localparam real         ClkPeriodNs = 1.0e9 / ClkFreqHz;

  localparam byte unsigned SofReq = 8'hA5;
  localparam byte unsigned SofRsp = 8'hB5;
  localparam int unsigned  FlashBase = 32'h0800_0000;

  // ----------------------------------------------------------- clock/reset
  logic clk = 1'b0;
  logic rst_n = 1'b1;  // pulsed low at the start of the test
  always #(ClkPeriodNs / 2) clk = ~clk;

  // Video clock of the ISP, unrelated to the CPU clock (200 MHz on the KV260)
  localparam real VidPeriodNs = 9.3;
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

  // Camera stream (CSI-2 receiver output) and ISP output
  logic       cam_tvalid = 1'b0, cam_tuser = 1'b0, cam_tlast = 1'b0, cam_tready;
  logic [9:0] cam_tdata = '0;
  logic       isp_tvalid, isp_tuser, isp_tlast;
  logic [23:0] isp_tdata;

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
    .BreakCycles (BreakCycles)
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
    .cam_tvalid_i (cam_tvalid),
    .cam_tready_o (cam_tready),
    .cam_tdata_i  (cam_tdata),
    .cam_tuser_i  (cam_tuser),
    .cam_tlast_i  (cam_tlast),
    .isp_tvalid_o (isp_tvalid),
    .isp_tready_i (1'b1),
    .isp_tdata_o  (isp_tdata),
    .isp_tuser_o  (isp_tuser),
    .isp_tlast_o  (isp_tlast),
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

  // -------------------------------------------------------- UART monitors
  byte unsigned rxq0[$];          // bytes received from UART0 (protocol)
  string        log0 = "", log1 = "";
  string        line0 = "", line1 = "";

  function automatic void log_char(int unsigned port, byte unsigned b);
    string s;
    if (b == 8'h0d) return;
    if (b == 8'h0a) begin
      if (port == 0) begin
        $display("[%0t] uart0| %s", $time, line0);
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

  // ------------------------------------------------------------- helpers
  function automatic bit contains(string hay, string needle);
    int n;
    n = needle.len();
    for (int i = 0; i + n <= hay.len(); i++) begin
      if (hay.substr(i, i + n - 1) == needle) return 1'b1;
    end
    return 1'b0;
  endfunction

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
        if (b[0]) $display("[%0t] tb   | IMX219 streaming", $time);
        else $display("[%0t] tb   | IMX219 standby", $time);
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

  // ------------------------------------------------ CSI-2 RX register model
  // AXI4-Lite device with random ready/response delays. Registers of the
  // AMD MIPI CSI-2 RX subsystem that the firmware uses (PG232); offsets
  // 0x4000-0x7FFF answer SLVERR, 0x8000-0xFFFF never answer (bridge timeout).
  logic [31:0] csi_ccr = '0, csi_isr = '0, csi_pkt = '0;
  logic [31:0] csi_mem [1024];
  int unsigned cf_w = 0, cf_h = 0;   // current camera frame size

  initial for (int i = 0; i < 1024; i++) csi_mem[i] = '0;

  function automatic logic [31:0] csi_read(logic [15:0] a);
    case (a & 16'h1FFC)
      16'h0000: return csi_ccr;
      16'h0004: return 32'h0000_0009;                 // 2 active lanes, 2 max
      16'h0010: return {csi_pkt[15:0], 16'h0000};     // packet count, no reset pending
      16'h0024: return csi_isr;
      16'h0060: return {16'(cf_h), 16'(cf_w * 10 / 8)};
      16'h0064: return 32'h0000_002B;                 // RAW10
      default:  return csi_mem[a[11:2]];
    endcase
  endfunction

  function automatic void csi_write(logic [15:0] a, logic [31:0] d);
    case (a & 16'h1FFC)
      16'h0000: csi_ccr = d;
      16'h0024: csi_isr = csi_isr & ~d;
      default:  csi_mem[a[11:2]] = d;
    endcase
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
          if (a < 16'h4000) csi_write(a, axil_wdata);
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
          axil_rdata  = (a >= 16'h4000) ? 32'hDEAD_BEEF : csi_read(a);
          axil_rresp  = (a >= 16'h4000) ? 2'b10 : 2'b00;
          axil_rvalid = 1'b1;
          do @(posedge clk); while (!axil_rready);
          #1;
          axil_rvalid = 1'b0;
        end
      end
    end
  end

  // ------------------------------------------------------ camera stream model
  // Output of the CSI-2 receiver while the sensor streams (0x0100 = 1) and
  // the receiver is enabled (CCR.EN): RAW10 frames of x/y_output_size
  // pixels, tuser = start of frame, tlast = end of line, random gaps,
  // back-pressure from the ISP honoured. Pixels: colour bars when the
  // sensor test pattern is on (0x0600 = 2), else a smooth scene whose level
  // follows exposure x analog gain, with a colour cast (R 5/8, B 13/16).
  int unsigned cf_tp = 0, cf_exp = 0, cf_again = 0;
  logic [1:0]  cf_orient = '0;
  int unsigned cam_frames = 0;

  function automatic logic [9:0] cam_pixel(int unsigned x, int unsigned y);
    int unsigned c, bar;
    longint unsigned lin, v;
    bit on;
    c = {y[0] ^ cf_orient[1], x[0] ^ cf_orient[0]};     // 0 R, 1 Gr, 2 Gb, 3 B
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

  initial begin : cam_model
    int unsigned x, y, gap;
    forever begin
      @(posedge vclk);
      if (imx_reg[16'h0100][0] && csi_ccr[0] && cam_powered) begin
        cf_w      = {imx_reg[16'h016c], imx_reg[16'h016d]};
        cf_h      = {imx_reg[16'h016e], imx_reg[16'h016f]};
        cf_tp     = {imx_reg[16'h0600], imx_reg[16'h0601]};
        cf_exp    = {imx_reg[16'h015a], imx_reg[16'h015b]};
        cf_again  = imx_reg[16'h0157] > 232 ? 232 : imx_reg[16'h0157];
        cf_orient = imx_reg[16'h0172][1:0];
        if (cam_frames == 0) check_sensor_setup();
        y = 0;
        while (y < cf_h) begin
          x = 0;
          while (x < cf_w) begin
            #0.5;
            cam_tvalid = 1'b1;
            cam_tdata  = cam_pixel(x, y);
            cam_tuser  = (x == 0) && (y == 0);
            cam_tlast  = (x == cf_w - 1);
            do @(posedge vclk); while (!cam_tready);
            #0.5;
            cam_tvalid = 1'b0;
            gap = ($urandom % 8 == 0) ? 1 + $urandom % 2 : 0;
            repeat (gap) @(posedge vclk);
            x++;
          end
          repeat (40) @(posedge vclk);       // horizontal blanking
          y++;
        end
        cam_frames++;
        csi_isr[31] = 1'b1;                  // frame received
        csi_pkt     = csi_pkt + cf_h + 2;
        repeat (2500) @(posedge vclk);       // vertical blanking
      end
    end
  end

  // The firmware must have programmed a consistent frame format.
  function automatic void check_sensor_setup();
    int unsigned x0, x1, y0, y1;
    x0 = {imx_reg[16'h0164], imx_reg[16'h0165]};
    x1 = {imx_reg[16'h0166], imx_reg[16'h0167]};
    y0 = {imx_reg[16'h0168], imx_reg[16'h0169]};
    y1 = {imx_reg[16'h016a], imx_reg[16'h016b]};
    if (x1 - x0 + 1 != cf_w || y1 - y0 + 1 != cf_h || x0[0] || y0[0]) begin
      $fatal(1, "IMX219: crop %0d..%0d x %0d..%0d does not match output %0dx%0d", x0, x1, y0, y1,
             cf_w, cf_h);
    end
    if (imx_reg[16'h018c] != 8'h0a || imx_reg[16'h0114] != 8'h01 || imx_reg[16'h030d] != 8'h72) begin
      $fatal(1, "IMX219: RAW10 / 2 lane / PLL setup missing");
    end
    $display("[%0t] tb   | IMX219 frame %0dx%0d crop (%0d,%0d) exp %0d gain %0d tp %0d orient %0d",
             $time, cf_w, cf_h, x0, y0, cf_exp, cf_again, cf_tp, cf_orient);
  endfunction

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
  string test, rom_file, flash_file, image_file;

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
  // in the answer. "dump" receives and checks an image; "" only waits.
  string cam_cmd[$], cam_rsp[$];

  function automatic void cam_add(string cmd, string rsp = "ok\n> ");
    cam_cmd.push_back(cmd);
    cam_rsp.push_back(rsp);
  endfunction

  function automatic void cam_setup();
    cam_cmd.delete();
    cam_rsp.delete();
    cam_add("rd 50008000", "bus error");          // 0  AXI device does not answer: timeout
    cam_add("rd 50004000", "bus error");          // 1  SLVERR
    cam_add("rd 50000004", "50000004: 00000009"); // 2  CSI-2 RX PCR: 2 lanes
    cam_add("mode 64 48");                        // 3  small frames for the simulation
    cam_add("tp 2");                              // 4  sensor colour bars
    cam_add("cam", "streaming 64x48 RGGB");       // 5
    cam_add("stat", "in 64x48");                  // 6
    cam_add("csi", "frame received");             // 7
    cam_add("cap 0 0 32 24 1", "captured 32x24"); // 8
    cam_add("dump", "END\nok\n> ");               // 9  RGB colour bars
    cam_add("tp 0");                              // 10 scene with a colour cast
    cam_add("ae on");                             // 11
    cam_add("awb on");                            // 12
    cam_add("", "ae: locked");                    // 13
    cam_add("", "awb: locked");                   // 14
    cam_add("flip 1 1");                          // 15 BGGR
    cam_add("stat", "in 64x48");                  // 16
    cam_add("awb off");                           // 17
    cam_add("tpg 0", "tpg 0 64x48");              // 18 ISP test pattern
    cam_add("fmt yuv");                           // 19
    cam_add("cap 0 0 32 24 1", "captured 32x24"); // 20
    cam_add("dump", "END\nok\n> ");               // 21 YUV colour bars
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
      // Camera path: I2C sensor control, CSI-2 RX registers over AXI4-Lite,
      // camera stream -> ISP -> capture -> image over UART, AE/AWB loops.
      "camera": begin
        cam_setup();
        expect_text(0, "camera: IMX219 found (id 0219)");
        expect_text(0, "csi2rx: found (2 lanes)");
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
          if (step == 6 && (out_w != 64 || out_h != 48)) begin
            $fatal(1, "ISP output frame %0dx%0d, expected 64x48", out_w, out_h);
          end
          step++;
        end
        $display("[%0t] tb   | camera frames %0d, ISP output frames %0d (%0dx%0d)", $time,
                 cam_frames, out_frames, out_w, out_h);
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

    run_test();

    repeat (100) @(posedge clk);
    $display("[%0t] tb   | TEST PASSED: %s (%0d cycles)", $time, test, cycle);
    $finish;
  end

endmodule
