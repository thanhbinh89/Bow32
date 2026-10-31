// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 receiver register file (CPU clock domain).
//
//   0x000 ID          R    0x43533201
//   0x004 INFO        R    [3:0] lanes [4] PHY [15:8] video clock MHz [31:16] FIFO depth
//   0x008 CTRL        RW   [0] PHY_EN [1] RX_EN [2] LANES (2 lanes) [3] CLK_FORCE
//                          [4] VC_ANY [6:5] VC [13:8] DT
//   0x00C PHY_CFG     RW   [7:0] SETTLE [11:8] LP_FILTER [23:16] CLK_SETTLE [31:24] CLK_MISS
//   0x010 STATUS      R    [5:0] LP {P,N} clock, lane 0, lane 1 [10:8] HS on (same order)
//                          [11] CE [12] IN_FRAME [13] BYTECLK_OK
//   0x014 IRQ_STATUS  W1C  [0] FS [1] FE [2] ERR [3] LOG_DONE [4] RAW_DONE
//   0x018 IRQ_EN      RW   same bits, irq_o = |(IRQ_STATUS & IRQ_EN)
//   0x01C ERR_STATUS  W1C  [0] SOT [1] ECC_CORR [2] ECC_ERR [3] CRC [4] TRUNC [5] OVF
//                          [6] SKEW [7] FORMAT [8] FRAME [9] LP
//   0x020 CNT_CLR     W    [0] clear the counters 0x024..0x044
//   0x024..0x044      R    counters (saturating)
//   0x050..0x064      R    FRAME_INFO, LINE_INFO, FRAME_SUM, FRAME_TIME, LINE_TIME, BYTECLK
//   0x070, 0x074      RW   DLY0, DLY1: [8:0] tap, R [24:16] CNTVALUEOUT
//   0x080 LOG_CTRL    RW   W [0] ARM [1] TRIG_FS [2] STOP_FE; R [0] ARMED [2:1] modes
//                          [8] DONE [21:16] WPTR
//   0x084 RAW_CTRL    RW   W [0] ARM [1] NOW; R [0] ARMED [1] NOW [8] DONE
//   0x400..0x4FC      R    LOG[64]
//   0x800..0x8FC      R    RAW[64]
// Unmapped offsets read 0, writes to them are ignored. In W1C registers a
// hardware set wins over a clear in the same cycle.
//
// Software changes CTRL.LANES/VC/VC_ANY/DT only while RX_EN = 0 and
// PHY_CFG/CLK_FORCE only while PHY_EN = 0: the other clock domains take them
// through one synchroniser per bit. rx_on_o (= PHY_EN & RX_EN) is a flop: it
// is the source of the datapath resets.
//
// LOG/RAW commands: every ARM increments a 4 bit gray request counter; the
// byte clock domain acknowledges by copying it (ack). ARMED = request != ack,
// DONE is set when the ack reaches the request after an ARM (cleared by the
// next ARM). ARM while a capture is pending restarts it (the counter does not
// advance onto the ack: at most 15 requests in flight). RAW starts with ARM
// or NOW.
//
// BYTECLK: every 256 cycles the byte clock meter delta (mod 2^20) is taken;
// the maximum of 256 such windows, times 256, is BYTECLK = byte clock cycles
// per 65536 CPU cycles while the clock runs. FRAME_TIME = CPU cycles between
// the last two FS; LINE_TIME = CPU cycles between the last two accepted line
// ends of one frame (the reference is reset by FS). Both references are
// reset while RX is off.

module bow_csi2rx_regs import bow_bus_pkg::*; import bow_csi2rx_pkg::*; #(
  parameter int unsigned Lanes     = 2,
  parameter int unsigned PhyClkHz  = 200_000_000,
  parameter bit          HasPhy    = 1'b1,
  parameter int unsigned FifoDepth = 256
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  input  bus_req_t              bus_req_i,
  output bus_rsp_t              bus_rsp_o,
  output logic                  irq_o,

  // configuration
  output csi2_cfg_t             cfg_o,
  output logic                  rx_on_o,        // flop
  output logic [Lanes:0]        lane_en_o,      // flops: [0] clock lane, [1 + l] data lane l
  output logic [Lanes-1:0][8:0] dly_tap_o,

  // LOG / RAW capture commands
  output logic [3:0]            log_req_o,      // gray
  output logic                  log_trig_fs_o,
  output logic                  log_stop_fe_o,
  input  logic [3:0]            log_ack_i,      // synchronised
  input  logic [5:0]            log_wptr_i,     // synchronised
  output logic [3:0]            raw_req_o,      // gray
  output logic                  raw_now_o,
  input  logic [3:0]            raw_ack_i,      // synchronised
  output logic                  log_re_o,       // RAM read port (data one cycle later)
  output logic                  raw_re_o,
  output logic [5:0]            ram_addr_o,
  input  logic [29:0]           log_rdata_i,
  input  logic [8*Lanes-1:0]    raw_rdata_i,

  // events (synchronised one cycle pulses) and the data that goes with them
  // (held by the source until the next event of the same kind)
  input  csi2_ev_t              ev_i,
  input  logic [15:0]           frame_lines_i,  // with ev_i.pl.fe
  input  logic [15:0]           frame_num_i,
  input  logic [31:0]           frame_sum_i,
  input  logic [15:0]           line_wc_i,      // with ev_i.pl.line
  input  logic [5:0]            line_dt_i,
  input  logic [1:0]            line_vc_i,

  // status (synchronised)
  input  logic [Lanes:0][1:0]   lp_i,           // [0] clock lane, [1 + l] data lane l
  input  logic [Lanes:0]        hs_en_i,
  input  logic                  ce_i,
  input  logic                  in_frame_i,
  input  logic [19:0]           meter_i,        // byte clock cycle counter, gray
  input  logic [Lanes-1:0][8:0] dly_tap_i       // IDELAY CNTVALUEOUT
);

  localparam logic [7:0] VidMhz = 8'((PhyClkHz + 500_000) / 1_000_000);

  localparam int unsigned IrqFs  = 0;
  localparam int unsigned IrqFe  = 1;
  localparam int unsigned IrqErr = 2;
  localparam int unsigned IrqLog = 3;
  localparam int unsigned IrqRaw = 4;

  logic [11:0] a;
  logic        we, re;
  logic [31:0] wd;

  assign a  = {bus_req_i.addr[11:2], 2'b00};
  assign we = bus_req_i.req &  bus_req_i.we;
  assign re = bus_req_i.req & ~bus_req_i.we;
  assign wd = bus_req_i.wdata;

  // ---------------------------------------------------------- configuration
  csi2_cfg_t             cfg_q;
  logic                  rx_on_q;
  logic [Lanes:0]        lane_en_q;
  logic [Lanes-1:0][8:0] dly_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cfg_q            <= '0;
      cfg_q.lanes2     <= (Lanes == 2);
      cfg_q.dt         <= DtRaw10;
      cfg_q.settle     <= 8'd14;
      cfg_q.lp_filter  <= 4'd2;
      cfg_q.clk_settle <= 8'd30;
      cfg_q.clk_miss   <= 8'd8;
      dly_q            <= '0;
      rx_on_q          <= 1'b0;
      lane_en_q        <= '0;
    end else begin
      if (we && (a == 12'h008)) begin
        cfg_q.phy_en    <= wd[0];
        cfg_q.rx_en     <= wd[1];
        cfg_q.lanes2    <= wd[2] && (Lanes == 2);
        cfg_q.clk_force <= wd[3];
        cfg_q.vc_any    <= wd[4];
        cfg_q.vc        <= wd[6:5];
        cfg_q.dt        <= wd[13:8];
      end
      if (we && (a == 12'h00C)) begin
        cfg_q.settle     <= wd[7:0];
        cfg_q.lp_filter  <= wd[11:8];
        cfg_q.clk_settle <= wd[23:16];
        cfg_q.clk_miss   <= wd[31:24];
      end
      if (we && (a == 12'h070)) dly_q[0] <= wd[8:0];
      if (we && (a == 12'h074) && (Lanes == 2)) dly_q[Lanes-1] <= wd[8:0];

      rx_on_q <= cfg_q.phy_en && cfg_q.rx_en;
      for (int unsigned l = 0; l <= Lanes; l++) begin
        lane_en_q[l] <= cfg_q.phy_en && ((l < 2) || cfg_q.lanes2);
      end
    end
  end

`ifdef VERILATOR
  // Two-state simulators (see bow_rstmgr): start with RX on so that the
  // reset pulse gives the datapath reset synchronisers a real falling edge.
  initial rx_on_q = 1'b1;
`endif

  assign cfg_o     = cfg_q;
  assign rx_on_o   = rx_on_q;
  assign lane_en_o = lane_en_q;
  assign dly_tap_o = dly_q;

  // -------------------------------------------------- LOG / RAW commands
  logic [3:0] log_req_q, raw_req_q, log_req_n, raw_req_n;
  logic       log_trig_q, log_stop_q, log_wait_q, log_done_q;
  logic       raw_now_q, raw_wait_q, raw_done_q;
  logic       log_arm, raw_arm, log_fin, raw_fin;

  // The request never steps onto the ack: 16 ARMs while the byte clock is
  // stopped would otherwise look like a completed capture.
  assign log_req_n = gray_inc4(log_req_q);
  assign raw_req_n = gray_inc4(raw_req_q);

  assign log_arm = we && (a == 12'h080) && wd[0];
  assign raw_arm = we && (a == 12'h084) && (wd[0] || wd[1]);
  assign log_fin = log_wait_q && (log_ack_i == log_req_q) && !log_arm;
  assign raw_fin = raw_wait_q && (raw_ack_i == raw_req_q) && !raw_arm;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      log_req_q  <= '0;
      log_trig_q <= 1'b0;
      log_stop_q <= 1'b0;
      log_wait_q <= 1'b0;
      log_done_q <= 1'b0;
      raw_req_q  <= '0;
      raw_now_q  <= 1'b0;
      raw_wait_q <= 1'b0;
      raw_done_q <= 1'b0;
    end else begin
      if (log_arm) begin
        if (log_req_n != log_ack_i) log_req_q <= log_req_n;
        log_trig_q <= wd[1];
        log_stop_q <= wd[2];
        log_wait_q <= 1'b1;
        log_done_q <= 1'b0;
      end else if (log_fin) begin
        log_wait_q <= 1'b0;
        log_done_q <= 1'b1;
      end
      if (raw_arm) begin
        if (raw_req_n != raw_ack_i) raw_req_q <= raw_req_n;
        raw_now_q  <= wd[1];
        raw_wait_q <= 1'b1;
        raw_done_q <= 1'b0;
      end else if (raw_fin) begin
        raw_wait_q <= 1'b0;
        raw_done_q <= 1'b1;
      end
    end
  end

  assign log_req_o     = log_req_q;
  assign log_trig_fs_o = log_trig_q;
  assign log_stop_fe_o = log_stop_q;
  assign raw_req_o     = raw_req_q;
  assign raw_now_o     = raw_now_q;

  // ------------------------------------------------- interrupts and errors
  logic [4:0] irq_set, irq_status_q, irq_en_q;
  logic [9:0] err_set, err_status_q;

  assign err_set = {|ev_i.lp_err, ev_i.pl.frame_err, ev_i.pl.fmt, ev_i.skew, ev_i.pl.ovf,
                    ev_i.pl.trunc, ev_i.pl.crc_err, ev_i.pl.ecc_err, ev_i.pl.ecc_corr, |ev_i.sot};

  always_comb begin
    irq_set         = '0;
    irq_set[IrqFs]  = ev_i.pl.fs;
    irq_set[IrqFe]  = ev_i.pl.fe;
    irq_set[IrqErr] = (err_set != '0);
    irq_set[IrqLog] = log_fin;
    irq_set[IrqRaw] = raw_fin;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      irq_status_q <= '0;
      irq_en_q     <= '0;
      err_status_q <= '0;
    end else begin
      irq_status_q <= (irq_status_q & ~(wd[4:0] & {5{we && (a == 12'h014)}})) | irq_set;
      err_status_q <= (err_status_q & ~(wd[9:0] & {10{we && (a == 12'h01C)}})) | err_set;
      if (we && (a == 12'h018)) irq_en_q <= wd[4:0];
    end
  end

  assign irq_o = |(irq_status_q & irq_en_q);

  // --------------------------------------------------------------- counters
  function automatic logic [31:0] inc32(logic [31:0] c, logic e);
    return (e && (c != '1)) ? c + 32'd1 : c;
  endfunction

  function automatic logic [15:0] inc16(logic [15:0] c, logic e);
    return (e && (c != '1)) ? c + 16'd1 : c;
  endfunction

  function automatic logic [7:0] add8(logic [7:0] c, logic [1:0] n);
    logic [8:0] s;
    s = {1'b0, c} + {7'd0, n};
    return s[8] ? 8'hFF : s[7:0];
  endfunction

  logic [31:0]      cnt_frame_q, cnt_pkt_q, cnt_line_q;
  logic [15:0]      cnt_corr_q, cnt_uncorr_q, cnt_crc_q, cnt_trunc_q, cnt_drop_q, cnt_ovf_q;
  logic [15:0]      cnt_clk_q;
  logic [1:0][15:0] cnt_sot_q, cnt_burst_q;
  logic [7:0]       cnt_lp_q, cnt_misc_q;
  logic [1:0]       n_lp, n_misc;
  logic             cnt_clr;

  assign cnt_clr = we && (a == 12'h020) && wd[0];
  assign n_lp    = 2'(ev_i.lp_err[0]) + 2'(ev_i.lp_err[1]) + 2'(ev_i.lp_err[2]);
  assign n_misc  = 2'(ev_i.skew) + 2'(ev_i.pl.fmt) + 2'(ev_i.pl.frame_err);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cnt_frame_q  <= '0;
      cnt_pkt_q    <= '0;
      cnt_line_q   <= '0;
      cnt_corr_q   <= '0;
      cnt_uncorr_q <= '0;
      cnt_crc_q    <= '0;
      cnt_trunc_q  <= '0;
      cnt_drop_q   <= '0;
      cnt_ovf_q    <= '0;
      cnt_clk_q    <= '0;
      cnt_sot_q    <= '0;
      cnt_burst_q  <= '0;
      cnt_lp_q     <= '0;
      cnt_misc_q   <= '0;
    end else if (cnt_clr) begin
      cnt_frame_q  <= '0;
      cnt_pkt_q    <= '0;
      cnt_line_q   <= '0;
      cnt_corr_q   <= '0;
      cnt_uncorr_q <= '0;
      cnt_crc_q    <= '0;
      cnt_trunc_q  <= '0;
      cnt_drop_q   <= '0;
      cnt_ovf_q    <= '0;
      cnt_clk_q    <= '0;
      cnt_sot_q    <= '0;
      cnt_burst_q  <= '0;
      cnt_lp_q     <= '0;
      cnt_misc_q   <= '0;
    end else begin
      cnt_frame_q    <= inc32(cnt_frame_q, ev_i.pl.fs);
      cnt_pkt_q      <= inc32(cnt_pkt_q, ev_i.pl.pkt);
      cnt_line_q     <= inc32(cnt_line_q, ev_i.pl.line);
      cnt_corr_q     <= inc16(cnt_corr_q, ev_i.pl.ecc_corr);
      cnt_uncorr_q   <= inc16(cnt_uncorr_q, ev_i.pl.ecc_err);
      cnt_crc_q      <= inc16(cnt_crc_q, ev_i.pl.crc_err);
      cnt_trunc_q    <= inc16(cnt_trunc_q, ev_i.pl.trunc);
      cnt_drop_q     <= inc16(cnt_drop_q, ev_i.pl.drop);
      cnt_ovf_q      <= inc16(cnt_ovf_q, ev_i.pl.ovf);
      cnt_clk_q      <= inc16(cnt_clk_q, ev_i.hs[0]);
      cnt_sot_q[0]   <= inc16(cnt_sot_q[0], ev_i.sot[0]);
      cnt_sot_q[1]   <= inc16(cnt_sot_q[1], ev_i.sot[1]);
      cnt_burst_q[0] <= inc16(cnt_burst_q[0], ev_i.hs[1]);
      cnt_burst_q[1] <= inc16(cnt_burst_q[1], ev_i.hs[2]);
      cnt_lp_q       <= add8(cnt_lp_q, n_lp);
      cnt_misc_q     <= add8(cnt_misc_q, n_misc);
    end
  end

  // --------------------------------------------------------- frame / line
  logic [31:0] frame_info_q, line_info_q, frame_sum_q;
  logic [31:0] now_q, fs_ref_q, ln_ref_q, frame_time_q, line_time_q;
  logic        fs_ref_v_q, ln_ref_v_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      frame_info_q <= '0;
      line_info_q  <= '0;
      frame_sum_q  <= '0;
      now_q        <= '0;
      fs_ref_q     <= '0;
      ln_ref_q     <= '0;
      frame_time_q <= '0;
      line_time_q  <= '0;
      fs_ref_v_q   <= 1'b0;
      ln_ref_v_q   <= 1'b0;
    end else begin
      now_q <= now_q + 32'd1;
      if (ev_i.pl.fe) begin
        frame_info_q <= {frame_num_i, frame_lines_i};
        frame_sum_q  <= frame_sum_i;
      end
      if (ev_i.pl.line) line_info_q <= {8'h00, line_vc_i, line_dt_i, line_wc_i};

      if (!rx_on_q) begin
        fs_ref_v_q <= 1'b0;
        ln_ref_v_q <= 1'b0;
      end else begin
        if (ev_i.pl.fs) begin
          if (fs_ref_v_q) frame_time_q <= now_q - fs_ref_q;
          fs_ref_q   <= now_q;
          fs_ref_v_q <= 1'b1;
          ln_ref_v_q <= 1'b0;
        end else if (ev_i.pl.line) begin
          if (ln_ref_v_q) line_time_q <= now_q - ln_ref_q;
          ln_ref_q   <= now_q;
          ln_ref_v_q <= 1'b1;
        end
      end
    end
  end

  // ------------------------------------------------------ byte clock meter
  logic [19:0] mbin_q, mprev_q, mmax_q, byteclk_q, mdelta, mmax_n;
  logic [7:0]  mcyc_q, mwin_q;

  assign mdelta = mbin_q - mprev_q;
  assign mmax_n = (mdelta > mmax_q) ? mdelta : mmax_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mbin_q    <= '0;
      mprev_q   <= '0;
      mmax_q    <= '0;
      byteclk_q <= '0;
      mcyc_q    <= '0;
      mwin_q    <= '0;
    end else begin
      mbin_q <= gray2bin20(meter_i);
      mcyc_q <= mcyc_q + 8'd1;
      if (mcyc_q == 8'hFF) begin
        mprev_q <= mbin_q;
        mwin_q  <= mwin_q + 8'd1;
        if (mwin_q == 8'hFF) begin
          byteclk_q <= (mmax_n[19:12] != '0) ? 20'hFFFFF : {mmax_n[11:0], 8'h00};
          mmax_q    <= '0;
        end else begin
          mmax_q <= mmax_n;
        end
      end
    end
  end

  // --------------------------------------------------------------- read data
  logic [2:0][1:0] lp3;
  logic [2:0]      hs3;
  logic [1:0][8:0] tap2, out2;
  logic [31:0]     status, rdata_d, rdata_q;
  logic            rvalid_q, sel_log_q, sel_raw_q;

  always_comb begin
    lp3  = '0;
    hs3  = '0;
    tap2 = '0;
    out2 = '0;
    for (int unsigned l = 0; l <= Lanes; l++) begin
      lp3[l] = lp_i[l];
      hs3[l] = hs_en_i[l];
    end
    for (int unsigned l = 0; l < Lanes; l++) begin
      tap2[l] = dly_q[l];
      out2[l] = dly_tap_i[l];
    end
    status = {18'h0, (byteclk_q != '0), in_frame_i, ce_i, hs3, 2'b00, lp3};
  end

  always_comb begin
    unique case (a)
      12'h000: rdata_d = Csi2rxId;
      12'h004: rdata_d = {16'(FifoDepth), VidMhz, 3'b000, HasPhy, 4'(Lanes)};
      12'h008: rdata_d = {18'h0, cfg_q.dt, 1'b0, cfg_q.vc, cfg_q.vc_any, cfg_q.clk_force,
                          cfg_q.lanes2, cfg_q.rx_en, cfg_q.phy_en};
      12'h00C: rdata_d = {cfg_q.clk_miss, cfg_q.clk_settle, 4'h0, cfg_q.lp_filter, cfg_q.settle};
      12'h010: rdata_d = status;
      12'h014: rdata_d = {27'h0, irq_status_q};
      12'h018: rdata_d = {27'h0, irq_en_q};
      12'h01C: rdata_d = {22'h0, err_status_q};
      12'h024: rdata_d = cnt_frame_q;
      12'h028: rdata_d = cnt_pkt_q;
      12'h02C: rdata_d = cnt_line_q;
      12'h030: rdata_d = {cnt_uncorr_q, cnt_corr_q};
      12'h034: rdata_d = {cnt_trunc_q, cnt_crc_q};
      12'h038: rdata_d = {cnt_sot_q[1], cnt_sot_q[0]};
      12'h03C: rdata_d = {cnt_ovf_q, cnt_drop_q};
      12'h040: rdata_d = {cnt_burst_q[1], cnt_burst_q[0]};
      12'h044: rdata_d = {cnt_misc_q, cnt_lp_q, cnt_clk_q};
      12'h050: rdata_d = frame_info_q;
      12'h054: rdata_d = line_info_q;
      12'h058: rdata_d = frame_sum_q;
      12'h05C: rdata_d = frame_time_q;
      12'h060: rdata_d = line_time_q;
      12'h064: rdata_d = {12'h0, byteclk_q};
      12'h070: rdata_d = {7'h0, out2[0], 7'h0, tap2[0]};
      12'h074: rdata_d = {7'h0, out2[1], 7'h0, tap2[1]};
      12'h080: rdata_d = {10'h0, log_wptr_i, 7'h0, log_done_q, 5'h0, log_stop_q, log_trig_q,
                          (log_req_q != log_ack_i)};
      12'h084: rdata_d = {23'h0, raw_done_q, 6'h0, raw_now_q, (raw_req_q != raw_ack_i)};
      default: rdata_d = '0;
    endcase
  end

  // LOG / RAW RAMs: registered read port, selected in the response cycle
  assign log_re_o   = re && (a[11:8] == 4'h4);
  assign raw_re_o   = re && (a[11:8] == 4'h8);
  assign ram_addr_o = a[7:2];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q  <= 1'b0;
      rdata_q   <= '0;
      sel_log_q <= 1'b0;
      sel_raw_q <= 1'b0;
    end else begin
      rvalid_q  <= bus_req_i.req;
      sel_log_q <= log_re_o;
      sel_raw_q <= raw_re_o;
      if (re) rdata_q <= rdata_d;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = sel_log_q ? 32'(log_rdata_i) :
                            sel_raw_q ? 32'(raw_rdata_i) : rdata_q;

  logic unused_bus;
  assign unused_bus = ^{bus_req_i.addr[31:12], bus_req_i.addr[1:0], bus_req_i.be, wd[31:14]};

endmodule
