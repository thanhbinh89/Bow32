// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 system level testbench (Verilator --binary --timing).
//
// The testbench plays the role of the host PC: it watches both UART TX lines,
// can type on both RX lines, and implements the boot ROM loader protocol to
// download an image over UART0 exactly like tools/bow32_flash.py.
//
// Plusargs:
//   +TEST=<name>      boot | load | break | flash | irq | gpio   (see run_test below)
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

  longint unsigned cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  // ------------------------------------------------------------------- DUT
  logic       uart0_rx = 1'b1, uart0_tx;
  logic       uart1_rx = 1'b1;  // UART1 is the alternate function of PB0 (TX) / PB1 (RX)
  logic       sys_rst_n, core_sleep;
  logic [7:0] gpioa_o, gpioa_oe, gpiob_o, gpiob_oe;
  wire  [7:0] pad_a, pad_b;

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
