// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// I2C master, one byte per command (docs/ip/i2c.md).
//
// Register map:
//   0x00 CTRL    RW: [0] EN  [1] IE (interrupt when a command is done)
//                    [31:16] DIV: quarter SCL period in clock cycles
//                    (SCL = clk / (4 * DIV); 400 kHz @ 50 MHz: DIV = 31)
//   0x04 CMD     W : [7:0] data to send  [8] START (or repeated start)
//                    [9] STOP after the byte  [10] WRITE  [11] READ
//                    [12] NACK: answer the read byte with NACK (last byte)
//                    STOP alone (no WRITE/READ) just sends a stop condition.
//   0x08 STATUS  R : [0] BUSY  [1] NACK (the last written byte was not
//                    acknowledged)  [2] DONE (W1C)  [15:8] received byte
//
// SCL and SDA are open drain: *_oe_o = 1 pulls the line low, 0 releases it
// (pull-up resistors on the board). Clock stretching by the slave is
// supported. There is no multi-master arbitration.

module bow_i2c import bow_bus_pkg::*; (
  input  logic     clk_i,
  input  logic     rst_ni,

  input  bus_req_t bus_req_i,
  output bus_rsp_t bus_rsp_o,

  input  logic     scl_i,
  output logic     scl_oe_o,
  input  logic     sda_i,
  output logic     sda_oe_o,

  output logic     irq_o
);

  // ------------------------------------------------------------- registers
  logic [11:0] a;
  logic        we, re;
  logic [31:0] wd;

  assign a  = {bus_req_i.addr[11:2], 2'b00};
  assign we = bus_req_i.req &  bus_req_i.we;
  assign re = bus_req_i.req & ~bus_req_i.we;
  assign wd = bus_req_i.wdata;

  logic        en_q, ie_q, done_q, nack_q;
  logic [15:0] div_q;
  logic [7:0]  rx_q;
  logic        busy;

  // Command latched for the engine. A CMD write while BUSY is ignored.
  logic cmd_go;
  logic c_stop_q, c_write_q, c_read_q, c_nack_q;

  assign cmd_go = we && (a == 12'h004) && en_q && !busy;

  // --------------------------------------------------------------- engine
  typedef enum logic [2:0] {
    Idle,
    Start,
    Bit,
    Stop
  } state_e;

  state_e      state_q;
  logic [1:0]  phase_q;     // quarter of the current bit / condition
  logic [15:0] tick_q;
  logic [3:0]  bit_q;       // 8 data bits + acknowledge
  logic [7:0]  sh_q;
  logic        scl_s, sda_s;

  bow_sync #(.ResetValue (1'b1)) u_sync_scl (.clk_i, .rst_ni, .d_i (scl_i), .q_o (scl_s));
  bow_sync #(.ResetValue (1'b1)) u_sync_sda (.clk_i, .rst_ni, .d_i (sda_i), .q_o (sda_s));

  assign busy = (state_q != Idle);

  // Every bit and condition is four quarters long; the line changes at the
  // end of a quarter. SCL is released at the end of quarter 1, so in quarter
  // 2 the timer waits until SCL really is high: clock stretching by the
  // slave (and the input synchroniser delay) lengthen the high time.
  logic quarter_done, stretch;
  assign stretch      = (phase_q == 2'd2) && !scl_oe_o && !scl_s;
  assign quarter_done = (tick_q == '0) && !stretch;

  logic is_ack_bit;
  assign is_ack_bit = (bit_q == 4'd8);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q  <= Idle;
      phase_q  <= '0;
      tick_q   <= '0;
      bit_q    <= '0;
      sh_q     <= '0;
      c_stop_q  <= 1'b0;
      c_write_q <= 1'b0;
      c_read_q  <= 1'b0;
      c_nack_q  <= 1'b0;
      scl_oe_o <= 1'b0;
      sda_oe_o <= 1'b0;
      nack_q   <= 1'b0;
      rx_q     <= '0;
      done_q   <= 1'b0;
    end else begin
      if (we && a == 12'h008 && wd[2]) done_q <= 1'b0;

      if (!en_q) begin
        state_q  <= Idle;
        scl_oe_o <= 1'b0;
        sda_oe_o <= 1'b0;
      end else if (state_q == Idle) begin
        if (cmd_go) begin
          c_stop_q  <= wd[9];
          c_write_q <= wd[10];
          c_read_q  <= wd[11];
          c_nack_q  <= wd[12];
          nack_q    <= 1'b0;
          sh_q    <= wd[7:0];
          bit_q   <= '0;
          phase_q <= '0;
          tick_q  <= div_q;
          done_q  <= 1'b0;
          state_q <= wd[8] ? Start : (wd[10] || wd[11]) ? Bit : wd[9] ? Stop : Idle;
          if (!(wd[8] || wd[9] || wd[10] || wd[11])) done_q <= 1'b1;
        end
      end else if (!quarter_done) begin
        if (!stretch) tick_q <= tick_q - 16'd1;
      end else begin
        tick_q  <= div_q;
        phase_q <= phase_q + 2'd1;
        unique case (state_q)
          // (repeated) start: SDA high, SCL high, SDA low, SCL low
          Start: begin
            unique case (phase_q)
              2'd0: sda_oe_o <= 1'b0;
              2'd1: scl_oe_o <= 1'b0;
              2'd2: sda_oe_o <= 1'b1;
              default: begin
                scl_oe_o <= 1'b1;
                state_q  <= (c_write_q || c_read_q) ? Bit : c_stop_q ? Stop : Idle;
                if (!(c_write_q || c_read_q || c_stop_q)) done_q <= 1'b1;
              end
            endcase
          end
          // one bit: set SDA with SCL low, SCL high, sample, SCL low
          Bit: begin
            unique case (phase_q)
              2'd0: begin
                scl_oe_o <= 1'b1;
                if (is_ack_bit) sda_oe_o <= c_read_q && !c_nack_q;   // ACK from us
                else            sda_oe_o <= !c_read_q && !sh_q[7];
              end
              2'd1: scl_oe_o <= 1'b0;
              2'd2: begin
                if (is_ack_bit) begin
                  if (!c_read_q) nack_q <= sda_s;
                end else begin
                  sh_q <= {sh_q[6:0], sda_s};
                end
              end
              default: begin
                scl_oe_o <= 1'b1;
                // SDA is left as it is: the next command sets it in its
                // first quarter, while SCL is low.
                if (is_ack_bit) begin
                  if (c_read_q) rx_q <= sh_q;
                  state_q <= c_stop_q ? Stop : Idle;
                  if (!c_stop_q) done_q <= 1'b1;
                end
                bit_q <= bit_q + 4'd1;
              end
            endcase
          end
          // stop: SDA low, SCL high, SDA high
          Stop: begin
            unique case (phase_q)
              2'd0: begin
                scl_oe_o <= 1'b1;
                sda_oe_o <= 1'b1;
              end
              2'd1: scl_oe_o <= 1'b0;
              2'd2: sda_oe_o <= 1'b0;
              default: begin
                state_q <= Idle;
                done_q  <= 1'b1;
              end
            endcase
          end
          default: state_q <= Idle;
        endcase
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      en_q  <= 1'b0;
      ie_q  <= 1'b0;
      div_q <= 16'd125;    // 100 kHz at 50 MHz
    end else if (we && a == 12'h000) begin
      en_q  <= wd[0];
      ie_q  <= wd[1];
      div_q <= (wd[31:16] == '0) ? 16'd1 : wd[31:16];
    end
  end

  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q;

  always_comb begin
    unique case (a)
      12'h000: rdata_d = {div_q, 14'h0, ie_q, en_q};
      12'h008: rdata_d = {16'h0, rx_q, 5'h0, done_q, nack_q, busy};
      default: rdata_d = '0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else begin
      rvalid_q <= bus_req_i.req;
      if (re) rdata_q <= rdata_d;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = rdata_q;

  assign irq_o = ie_q && done_q;

  logic unused;
  assign unused = ^{bus_req_i.addr[31:12], bus_req_i.addr[1:0], bus_req_i.be, wd[15:13]};

endmodule
