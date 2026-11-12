// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 receiver debug capture (byte clock domain, hard reset): packet LOG into a 64 entry
// RAM that the CPU reads. (The RAW lane words moved into the D-PHY in step 4 of
// docs/ip/mipi_rx_arch.md: bow_dphy_raw.)
//
// Commands come from the CPU as a 4 bit gray request counter (synchronised
// per bit; incremented by every ARM). A capture (re)starts whenever the
// request differs from the one being served, samples the mode bits two
// cycles later (they were written with the request), and when it is
// complete sets ack = request, two cycles after its last RAM write so that
// the RAM and log_wptr_o are stable before the CPU sees the ack. Requests
// are levels: they work with a stopped byte clock (served when it runs).
//
// LOG modes (one entry per packet, from bow_csi2_packet):
//   -                 the next 64 entries
//   TRIG_FS           64 entries from the next FS of the selected VC
//   STOP_FE           circular, stop after an FE of the selected VC was
//                     logged; log_wptr_o = index of the oldest entry (0 if
//                     the buffer did not wrap)
//   TRIG_FS | STOP_FE from the FS until the FE, at most 64 entries

module bow_csi2_capture (
  input  logic        clk_i,
  input  logic        rst_ni,          // byte clock, hard reset

  input  logic [3:0]  log_req_i,       // synchronised
  input  logic        log_trig_fs_i,
  input  logic        log_stop_fe_i,
  output logic [3:0]  log_ack_o,
  output logic [5:0]  log_wptr_o,
  input  logic        log_we_i,        // packet LOG entry
  input  logic [29:0] log_entry_i,
  input  logic        log_fs_i,
  input  logic        log_fe_i,

  input  logic        rclk_i,          // CPU clock: RAM read port
  input  logic        log_re_i,
  input  logic [5:0]  raddr_i,
  output logic [29:0] log_rdata_o
);

  typedef enum logic [1:0] {
    CapIdle,
    CapWait,    // mode bits not yet synchronised
    CapRun,
    CapFin      // done, ack in 2 cycles
  } cap_e;

  // ===================================================================== LOG
  cap_e       logst_q;
  logic [3:0] lcur_q;
  logic       lwait_q, ltrig_q, lstop_q, lgo_q, lwrap_q;
  logic [5:0] lwptr_q;
  logic [6:0] lcnt_q;            // entries written, saturates at 64
  logic       lnew, lwe, lend;

  assign lnew = (log_req_i != lcur_q);
  assign lwe  = !lnew && (logst_q == CapRun) && log_we_i && (lgo_q || !ltrig_q || log_fs_i);
  assign lend = (lstop_q && log_fe_i) || ((!lstop_q || ltrig_q) && (lcnt_q == 7'd63));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      logst_q    <= CapIdle;
      lcur_q     <= '0;
      lwait_q    <= 1'b0;
      ltrig_q    <= 1'b0;
      lstop_q    <= 1'b0;
      lgo_q      <= 1'b0;
      lwrap_q    <= 1'b0;
      lwptr_q    <= '0;
      lcnt_q     <= '0;
      log_ack_o  <= '0;
      log_wptr_o <= '0;
    end else begin
      log_wptr_o <= lwrap_q ? lwptr_q : 6'd0;
      if (lnew) begin
        lcur_q  <= log_req_i;
        logst_q <= CapWait;
        lwait_q <= 1'b1;
        lgo_q   <= 1'b0;
        lwrap_q <= 1'b0;
        lwptr_q <= '0;
        lcnt_q  <= '0;
      end else begin
        unique case (logst_q)
          CapWait: begin
            if (lwait_q) begin
              lwait_q <= 1'b0;
            end else begin
              ltrig_q <= log_trig_fs_i;
              lstop_q <= log_stop_fe_i;
              logst_q <= CapRun;
            end
          end
          CapRun: begin
            if (lwe) begin
              lgo_q   <= 1'b1;
              lwptr_q <= lwptr_q + 6'd1;
              if (lwptr_q == 6'd63) lwrap_q <= 1'b1;
              if (lcnt_q != 7'd64)  lcnt_q  <= lcnt_q + 7'd1;
              if (lend) begin
                logst_q <= CapFin;
                lwait_q <= 1'b1;
              end
            end
          end
          CapFin: begin
            if (lwait_q) begin
              lwait_q <= 1'b0;
            end else begin
              log_ack_o <= lcur_q;
              logst_q   <= CapIdle;
            end
          end
          default: ;
        endcase
      end
    end
  end

  bow_ram_sdp #(
    .Width (30),
    .Depth (64)
  ) u_log_ram (
    .wclk_i  (clk_i),
    .we_i    (lwe),
    .waddr_i (lwptr_q),
    .wdata_i (log_entry_i),
    .rclk_i  (rclk_i),
    .re_i    (log_re_i),
    .raddr_i (raddr_i),
    .rdata_o (log_rdata_o)
  );

endmodule
