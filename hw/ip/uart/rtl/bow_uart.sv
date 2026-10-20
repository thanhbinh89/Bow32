// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 UART: 8N1, programmable baud divider, TX/RX FIFOs, one interrupt.
//
// Register map (32 bit registers, see docs/ip/uart.md):
//   0x00 DATA    W : [7:0] byte pushed into the TX FIFO (dropped when full)
//                R : [7:0] byte popped from the RX FIFO, [31] RX_EMPTY
//                    (when RX_EMPTY = 1 nothing is popped and [7:0] = 0)
//   0x04 STATUS  R : [0] TX_FULL  [1] TX_EMPTY  [2] TX_IDLE  [3] RX_VALID
//                    [4] RX_FULL  [5] RX_OVERRUN  [6] RX_FRAME_ERR
//                W1C: [5] RX_OVERRUN  [6] RX_FRAME_ERR
//   0x08 CTRL    RW: [0] TX_EN  [1] RX_EN  [2] RX_IE  [3] TX_IE
//                W : [4] RX_FLUSH  [5] TX_FLUSH   (self clearing)
//   0x0C BAUD    RW: [15:0] clock cycles per bit (clk_hz / baud), min 16
//
// irq_o = (RX_IE & RX_VALID) | (TX_IE & TX_EMPTY)

module bow_uart import bow_bus_pkg::*; #(
  parameter int unsigned  FifoDepth   = 16,
  parameter logic [15:0]  ResetBaudDiv = 16'd434   // 115200 baud @ 50 MHz
) (
  input  logic     clk_i,
  input  logic     rst_ni,

  input  bus_req_t bus_req_i,
  output bus_rsp_t bus_rsp_o,

  input  logic     rx_i,      // asynchronous pin
  output logic     tx_o,
  output logic     irq_o
);

  localparam logic [11:0] RegData   = 12'h000;
  localparam logic [11:0] RegStatus = 12'h004;
  localparam logic [11:0] RegCtrl   = 12'h008;
  localparam logic [11:0] RegBaud   = 12'h00C;

  // ---------------------------------------------------------------------------
  // Register interface
  // ---------------------------------------------------------------------------
  logic [11:0] reg_addr;
  logic        reg_we, reg_re;

  assign reg_addr = {bus_req_i.addr[11:2], 2'b00};
  assign reg_we   = bus_req_i.req &  bus_req_i.we;
  assign reg_re   = bus_req_i.req & ~bus_req_i.we;

  logic        tx_en_q, rx_en_q, rx_ie_q, tx_ie_q;
  logic [15:0] baud_div_q;
  logic        overrun_q, frame_err_q;

  // FIFO signals
  logic       tx_fifo_push, tx_fifo_pop, tx_fifo_full, tx_fifo_empty;
  logic [7:0] tx_fifo_rdata;
  logic       rx_fifo_push, rx_fifo_pop, rx_fifo_full, rx_fifo_empty;
  logic [7:0] rx_fifo_rdata;
  logic       tx_flush, rx_flush;

  // Engine signals
  logic       tx_ready, tx_busy;
  logic       rx_valid, rx_frame_err;
  logic [7:0] rx_data;
  logic       rx_sync;

  assign tx_fifo_push = reg_we && (reg_addr == RegData) && !tx_fifo_full;
  assign rx_fifo_pop  = reg_re && (reg_addr == RegData);
  assign tx_flush     = reg_we && (reg_addr == RegCtrl) && bus_req_i.wdata[5];
  assign rx_flush     = reg_we && (reg_addr == RegCtrl) && bus_req_i.wdata[4];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_en_q     <= 1'b1;
      rx_en_q     <= 1'b1;
      rx_ie_q     <= 1'b0;
      tx_ie_q     <= 1'b0;
      baud_div_q  <= ResetBaudDiv;
      overrun_q   <= 1'b0;
      frame_err_q <= 1'b0;
    end else begin
      if (reg_we && reg_addr == RegCtrl) begin
        tx_en_q <= bus_req_i.wdata[0];
        rx_en_q <= bus_req_i.wdata[1];
        rx_ie_q <= bus_req_i.wdata[2];
        tx_ie_q <= bus_req_i.wdata[3];
      end
      if (reg_we && reg_addr == RegBaud) begin
        baud_div_q <= (bus_req_i.wdata[15:0] < 16'd16) ? 16'd16 : bus_req_i.wdata[15:0];
      end
      // Sticky error flags: set by hardware, cleared by writing 1.
      if (reg_we && reg_addr == RegStatus && bus_req_i.wdata[5]) overrun_q <= 1'b0;
      if (reg_we && reg_addr == RegStatus && bus_req_i.wdata[6]) frame_err_q <= 1'b0;
      if (rx_valid && rx_fifo_full) overrun_q <= 1'b1;
      if (rx_frame_err)             frame_err_q <= 1'b1;
    end
  end

  // Read data multiplexer (registered: response comes one cycle after gnt).
  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q;

  always_comb begin
    rdata_d = '0;
    unique case (reg_addr)
      RegData:   rdata_d = rx_fifo_empty ? 32'h8000_0000 : {24'h0, rx_fifo_rdata};
      RegStatus: rdata_d = {25'h0, frame_err_q, overrun_q, rx_fifo_full, !rx_fifo_empty,
                            tx_fifo_empty && !tx_busy, tx_fifo_empty, tx_fifo_full};
      RegCtrl:   rdata_d = {28'h0, tx_ie_q, rx_ie_q, rx_en_q, tx_en_q};
      RegBaud:   rdata_d = {16'h0, baud_div_q};
      default:   rdata_d = '0;
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

  // ---------------------------------------------------------------------------
  // FIFOs
  // ---------------------------------------------------------------------------
  bow_fifo_sync #(
    .Width (8),
    .Depth (FifoDepth)
  ) u_tx_fifo (
    .clk_i,
    .rst_ni,
    .clr_i   (tx_flush),
    .push_i  (tx_fifo_push),
    .wdata_i (bus_req_i.wdata[7:0]),
    .pop_i   (tx_fifo_pop),
    .rdata_o (tx_fifo_rdata),
    .full_o  (tx_fifo_full),
    .empty_o (tx_fifo_empty),
    .level_o ()
  );

  assign rx_fifo_push = rx_valid && !rx_fifo_full;

  bow_fifo_sync #(
    .Width (8),
    .Depth (FifoDepth)
  ) u_rx_fifo (
    .clk_i,
    .rst_ni,
    .clr_i   (rx_flush),
    .push_i  (rx_fifo_push),
    .wdata_i (rx_data),
    .pop_i   (rx_fifo_pop),
    .rdata_o (rx_fifo_rdata),
    .full_o  (rx_fifo_full),
    .empty_o (rx_fifo_empty),
    .level_o ()
  );

  // ---------------------------------------------------------------------------
  // Serial engines
  // ---------------------------------------------------------------------------
  assign tx_fifo_pop = tx_en_q && !tx_fifo_empty && tx_ready;

  bow_uart_tx u_tx (
    .clk_i,
    .rst_ni,
    .baud_div_i (baud_div_q),
    .valid_i    (tx_en_q && !tx_fifo_empty),
    .data_i     (tx_fifo_rdata),
    .ready_o    (tx_ready),
    .busy_o     (tx_busy),
    .tx_o
  );

  bow_sync #(
    .ResetValue (1'b1)
  ) u_rx_sync (
    .clk_i,
    .rst_ni,
    .d_i (rx_i),
    .q_o (rx_sync)
  );

  bow_uart_rx u_rx (
    .clk_i,
    .rst_ni,
    .baud_div_i  (baud_div_q),
    .enable_i    (rx_en_q),
    .rx_i        (rx_sync),
    .valid_o     (rx_valid),
    .data_o      (rx_data),
    .frame_err_o (rx_frame_err)
  );

  assign irq_o = (rx_ie_q && !rx_fifo_empty) || (tx_ie_q && tx_fifo_empty);

  logic unused_bus;
  assign unused_bus = ^{bus_req_i.addr[31:12], bus_req_i.addr[1:0], bus_req_i.be,
                        bus_req_i.wdata[31:8]};

endmodule
