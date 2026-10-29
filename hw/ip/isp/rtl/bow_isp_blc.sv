// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Black level correction: p' = enable ? max(p - black, 0) : p.
// Sensors add an offset (IMX219: 64 at 10 bit) so that noise around black is
// not clipped; it has to be removed before any gain is applied.
// Latency: 1 cycle.

module bow_isp_blc import bow_isp_pkg::*; (
  input  logic            clk_i,
  input  logic            rst_ni,
  input  logic            enable_i,
  input  logic [PixW-1:0] black_i,

  input  logic            valid_i,
  input  logic [PixW-1:0] data_i,
  input  logic            sof_i,

  output logic            valid_o,
  output logic [PixW-1:0] data_o,
  output logic            sof_o
);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_o <= 1'b0;
      data_o  <= '0;
      sof_o   <= 1'b0;
    end else begin
      valid_o <= valid_i;
      sof_o   <= sof_i;
      if (enable_i) begin
        data_o <= (data_i > black_i) ? data_i - black_i : '0;
      end else begin
        data_o <= data_i;
      end
    end
  end

endmodule
