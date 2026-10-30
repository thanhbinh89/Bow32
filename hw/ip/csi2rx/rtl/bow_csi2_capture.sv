// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 receiver debug captures (byte clock domain, hard reset): packet LOG
// and RAW lane words, each into a 64 entry RAM that the CPU reads.
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
// RAW: 64 consecutive words {lane 1, lane 0} from the cycle in which lane 0
// arm (hs_active) rises, or at once (NOW).

module bow_csi2_capture #(
  parameter int unsigned Lanes = 2
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,          // byte clock, hard reset

  input  logic [3:0]            log_req_i,       // synchronised
  input  logic                  log_trig_fs_i,
  input  logic                  log_stop_fe_i,
  output logic [3:0]            log_ack_o,
  output logic [5:0]            log_wptr_o,
  input  logic                  log_we_i,        // packet LOG entry
  input  logic [29:0]           log_entry_i,
  input  logic                  log_fs_i,
  input  logic                  log_fe_i,

  input  logic [3:0]            raw_req_i,       // synchronised
  input  logic                  raw_now_i,
  output logic [3:0]            raw_ack_o,
  input  logic                  arm0_i,          // lane 0 hs_active, synchronised
  input  logic [Lanes-1:0][7:0] rx_i,            // registered ISERDES words

  input  logic                  rclk_i,          // CPU clock: RAM read ports
  input  logic                  log_re_i,
  input  logic                  raw_re_i,
  input  logic [5:0]            raddr_i,
  output logic [29:0]           log_rdata_o,
  output logic [8*Lanes-1:0]    raw_rdata_o
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

  // ===================================================================== RAW
  cap_e       rawst_q;
  logic [3:0] rcur_q;
  logic       rwait_q, rnow_q, rgo_q, arm0_q;
  logic [5:0] ridx_q;
  logic       rnew, rwe;

  assign rnew = (raw_req_i != rcur_q);
  assign rwe  = !rnew && (rawst_q == CapRun) && (rgo_q || rnow_q || (arm0_i && !arm0_q));

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
            if (rwe) begin
              rgo_q  <= 1'b1;
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
