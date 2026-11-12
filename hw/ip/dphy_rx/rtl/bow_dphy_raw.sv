// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// D-PHY receiver debug capture (byte clock domain, hard reset): RAW lane words into a 64
// entry RAM that the bus reads. The RAW half of the CSI-2 receiver's bow_csi2_capture,
// moved into the D-PHY in step 4 of docs/ip/mipi_rx_arch.md (section 10); the behaviour is
// the one RAW had there.
//
// Commands come from the bus as a 4 bit gray request counter (synchronised per bit;
// incremented by every ARM). A capture (re)starts whenever the request differs from the one
// being served, samples the mode bit (NOW) two cycles later (it was written with the
// request), and when it is complete sets ack = request, two cycles after its last RAM
// write so that the RAM is stable before the bus side sees the ack. Requests are levels:
// they work with a stopped byte clock (served when it runs).
//
// RAW: 64 consecutive words {lane Lanes-1, .., lane 0} (8 * Lanes bits, byte k = lane k)
// from the cycle in which lane 0 arm (RxActiveHS of the PPI) rises, or at once (NOW). Only
// cycles with a valid word on lane 0 (rx_vld0_i, registered rx_valid of the PHY) are
// written, the other lanes are sampled in the same cycles (the Versal XPHY FIFOs of all
// lanes are read in step once a burst runs; bow_dphy_io_xusp has a word in every cycle).

module bow_dphy_raw #(
  parameter int unsigned Lanes = 2
) (
  input  logic                  clk_i,           // byte clock
  input  logic                  rst_ni,          // byte clock, hard reset

  input  logic [3:0]            raw_req_i,       // synchronised
  input  logic                  raw_now_i,
  output logic [3:0]            raw_ack_o,
  input  logic                  arm0_i,          // lane 0 hs_active, synchronised
  input  logic                  rx_vld0_i,       // rx_i[0] is a new word (registered rx_valid)
  input  logic [Lanes-1:0][7:0] rx_i,            // registered PHY words

  input  logic                  rclk_i,          // bus clock: RAM read port
  input  logic                  raw_re_i,
  input  logic [5:0]            raddr_i,
  output logic [8*Lanes-1:0]    raw_rdata_o
);

  typedef enum logic [1:0] {
    CapIdle,
    CapWait,    // mode bit not yet synchronised
    CapRun,
    CapFin      // done, ack in 2 cycles
  } cap_e;

  cap_e       rawst_q;
  logic [3:0] rcur_q;
  logic       rwait_q, rnow_q, rgo_q, arm0_q;
  logic [5:0] ridx_q;
  logic       rnew, rtrig, rwe;

  // started (rgo_q), NOW, or the rising edge of lane 0 arm (also in a cycle
  // without a valid word: the capture then starts with the next one)
  assign rnew  = (raw_req_i != rcur_q);
  assign rtrig = rgo_q || rnow_q || (arm0_i && !arm0_q);
  assign rwe   = !rnew && (rawst_q == CapRun) && rtrig && rx_vld0_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rawst_q   <= CapIdle;
      rcur_q    <= '0;
      rwait_q   <= 1'b0;
      rnow_q    <= 1'b0;
      rgo_q     <= 1'b0;
      arm0_q    <= 1'b1;     // a rising edge needs arm0 low first
      ridx_q    <= '0;
      raw_ack_o <= '0;
    end else begin
      arm0_q <= arm0_i;
      if (rnew) begin
        rcur_q  <= raw_req_i;
        rawst_q <= CapWait;
        rwait_q <= 1'b1;
        rgo_q   <= 1'b0;
        ridx_q  <= '0;
      end else begin
        unique case (rawst_q)
          CapWait: begin
            if (rwait_q) begin
              rwait_q <= 1'b0;
            end else begin
              rnow_q  <= raw_now_i;
              rawst_q <= CapRun;
            end
          end
          CapRun: begin
            if (rtrig) rgo_q <= 1'b1;
            if (rwe) begin
              ridx_q <= ridx_q + 6'd1;
              if (ridx_q == 6'd63) begin
                rawst_q <= CapFin;
                rwait_q <= 1'b1;
              end
            end
          end
          CapFin: begin
            if (rwait_q) begin
              rwait_q <= 1'b0;
            end else begin
              raw_ack_o <= rcur_q;
              rawst_q   <= CapIdle;
            end
          end
          default: ;
        endcase
      end
    end
  end

  bow_ram_sdp #(
    .Width (8 * Lanes),
    .Depth (64)
  ) u_raw_ram (
    .wclk_i  (clk_i),
    .we_i    (rwe),
    .waddr_i (ridx_q),
    .wdata_i (rx_i),
    .rclk_i  (rclk_i),
    .re_i    (raw_re_i),
    .raddr_i (raddr_i),
    .rdata_o (raw_rdata_o)
  );

endmodule
