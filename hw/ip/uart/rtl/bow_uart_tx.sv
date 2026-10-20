// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// UART transmitter, 8N1, LSB first. One bit lasts `baud_div_i` clock cycles.

module bow_uart_tx (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [15:0] baud_div_i,

  input  logic        valid_i,   // a byte is available
  input  logic [7:0]  data_i,
  output logic        ready_o,   // byte accepted in this cycle (when valid_i)
  output logic        busy_o,    // frame in progress

  output logic        tx_o
);

  logic [9:0]  shift_q;      // {stop, data[7:0], start}
  logic [3:0]  bits_left_q;  // bits still to be sent (incl. the current one)
  logic [15:0] cnt_q;

  assign busy_o  = (bits_left_q != '0);
  assign ready_o = !busy_o;
  assign tx_o    = busy_o ? shift_q[0] : 1'b1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      shift_q     <= '1;
      bits_left_q <= '0;
      cnt_q       <= '0;
    end else if (!busy_o) begin
      if (valid_i) begin
        shift_q     <= {1'b1, data_i, 1'b0};
        bits_left_q <= 4'd10;
        cnt_q       <= baud_div_i - 16'd1;
      end
    end else if (cnt_q != '0) begin
      cnt_q <= cnt_q - 16'd1;
    end else begin
      shift_q     <= {1'b1, shift_q[9:1]};
      bits_left_q <= bits_left_q - 4'd1;
      cnt_q       <= baud_div_i - 16'd1;
    end
  end

endmodule
