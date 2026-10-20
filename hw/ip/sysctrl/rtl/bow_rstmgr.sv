// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Reset manager.
//
// Two reset domains:
//   por_rst_no  power-on / board reset. Only resets logic that has to survive
//               a system reset (reset cause, boot flag, break detector).
//   sys_rst_no  everything else (CPU, bus, memories controllers, UARTs).
//               Asserted during POR and for StretchCycles after a request from
//               sysctrl (software reset, UART break).
//
// Both resets are asserted asynchronously and released synchronously to clk_i.

module bow_rstmgr #(
  parameter int unsigned StretchCycles = 32
) (
  input  logic clk_i,
  input  logic por_ni,          // asynchronous board reset, active low
  input  logic sys_rst_req_i,   // synchronous request from bow_sysctrl
  output logic por_rst_no,
  output logic sys_rst_no
);

  localparam int unsigned CntWidth = $clog2(StretchCycles + 1);

  // POR: asynchronous assertion, synchronous de-assertion.
  logic [1:0] por_sync_q;

  always_ff @(posedge clk_i or negedge por_ni) begin
    if (!por_ni) begin
      por_sync_q <= '0;
    end else begin
      por_sync_q <= {por_sync_q[0], 1'b1};
    end
  end

  assign por_rst_no = por_sync_q[1];

  // System reset: held for StretchCycles after POR or after a request.
  logic [CntWidth-1:0] cnt_q;
  logic                sys_rst_q;

  always_ff @(posedge clk_i or negedge por_rst_no) begin
    if (!por_rst_no) begin
      cnt_q     <= CntWidth'(StretchCycles);
      sys_rst_q <= 1'b0;
    end else begin
      if (sys_rst_req_i) begin
        cnt_q <= CntWidth'(StretchCycles);
      end else if (cnt_q != '0) begin
        cnt_q <= cnt_q - 1'b1;
      end
      sys_rst_q <= (cnt_q == '0) && !sys_rst_req_i;
    end
  end

  assign sys_rst_no = sys_rst_q;

`ifdef VERILATOR
  // Two-state simulators (Verilator): a reset that is low from time 0 has
  // no negative edge, so flops with an asynchronous reset on a gated clock
  // (inside Ibex) would never be reset. Starting with the resets released
  // lets the testbench reset pulse propagate as real edges. On an FPGA the
  // registers power up as 0 (reset asserted), which is what we want there.
  initial begin
    por_sync_q = 2'b11;
    sys_rst_q  = 1'b1;
  end
`endif

endmodule
