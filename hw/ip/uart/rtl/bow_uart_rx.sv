// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// UART receiver, 8N1, LSB first. Bits are sampled once in the middle of the
// bit period. After a frame error (e.g. a BREAK, the line held low) the
// receiver waits for the line to return to idle before looking for the next
// start bit; the same happens after reset, so a line that is low while the
// SoC comes out of reset does not produce garbage.

module bow_uart_rx (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [15:0] baud_div_i,
  input  logic        enable_i,

  input  logic        rx_i,          // already synchronised to clk_i

  output logic        valid_o,       // one cycle pulse: data_o is a new byte
  output logic [7:0]  data_o,
  output logic        frame_err_o    // one cycle pulse: stop bit was 0
);

  typedef enum logic [2:0] {
    WaitIdle,
    Idle,
    Start,
    Data,
    Stop
  } state_e;

  state_e      state_q;
  logic [15:0] cnt_q;
  logic [2:0]  bit_idx_q;
  logic [7:0]  shift_q;
  logic        rx_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= WaitIdle;
      cnt_q       <= '0;
      bit_idx_q   <= '0;
      shift_q     <= '0;
      rx_q        <= 1'b1;
      valid_o     <= 1'b0;
      frame_err_o <= 1'b0;
    end else begin
      rx_q        <= rx_i;
      valid_o     <= 1'b0;
      frame_err_o <= 1'b0;

      if (!enable_i) begin
        state_q <= WaitIdle;
      end else begin
        unique case (state_q)
          WaitIdle: begin
            if (rx_i) state_q <= Idle;
          end

          Idle: begin
            // Falling edge = start bit; first sample in the middle of it.
            if (rx_q && !rx_i) begin
              state_q <= Start;
              cnt_q   <= {1'b0, baud_div_i[15:1]};
            end
          end

          Start: begin
            if (cnt_q != '0) begin
              cnt_q <= cnt_q - 16'd1;
            end else if (rx_i) begin
              state_q <= Idle;        // glitch, not a real start bit
            end else begin
              state_q   <= Data;
              bit_idx_q <= '0;
              cnt_q     <= baud_div_i - 16'd1;
            end
          end

          Data: begin
            if (cnt_q != '0) begin
              cnt_q <= cnt_q - 16'd1;
            end else begin
              shift_q <= {rx_i, shift_q[7:1]};
              cnt_q   <= baud_div_i - 16'd1;
              if (bit_idx_q == 3'd7) begin
                state_q <= Stop;
              end
              bit_idx_q <= bit_idx_q + 3'd1;
            end
          end

          Stop: begin
            if (cnt_q != '0) begin
              cnt_q <= cnt_q - 16'd1;
            end else if (rx_i) begin
              valid_o <= 1'b1;
              state_q <= Idle;
            end else begin
              frame_err_o <= 1'b1;
              state_q     <= WaitIdle;
            end
          end

          default: state_q <= WaitIdle;
        endcase
      end
    end
  end

  assign data_o = shift_q;

endmodule
