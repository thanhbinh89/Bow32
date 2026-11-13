// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 receiver register file, controller (CPU clock domain). Since step 4 of
// docs/ip/mipi_rx_arch.md the PHY registers are in the D-PHY's window at 0xC00
// (bow_dphy_rx_regs, docs/ip/dphy_rx.md); their old offsets here read 0, there is no alias.
//
//   0x000 ID          R    0x43533201
//   0x004 INFO        R    [3:0] lanes [4] PHY [5] 0 (was DLY_VID) [6] the D-PHY's
//                          registers are at 0xC00 (DphyWin: 1 in bow_mipi_rx) [15:8] MHz of
//                          the controller's clock (csi_clk since step 7, vid_clk before; the
//                          video clock on the FPGAs), saturating at 255 [31:16] FIFO depth
//   0x008 CTRL        RW   [0] PHY_EN [1] RX_EN [2] LANES (2 lanes) [3] 0 (was CLK_FORCE)
//                          [4] VC_ANY [6:5] VC [7] LANES4 (4 lanes, wins over LANES)
//                          [13:8] DT [23:16] EXTRA (64, 0 = off)
//   0x010 STATUS      R    [12] IN_FRAME (the PHY bits: LANE_LP, LANE_HS, AFE_STATUS of the
//                          D-PHY)
//   0x014 IRQ_STATUS  W1C  [0] FS [1] FE [2] ERR [3] LOG_DONE; [5] PHY (R: the D-PHY's
//                          interrupt line, cleared in the D-PHY)
//   0x018 IRQ_EN      RW   [3:0], [5] as IRQ_STATUS, irq_o = |(IRQ_STATUS & IRQ_EN)
//   0x01C ERR_STATUS  W1C  [0] SOT [1] ECC_CORR [2] ECC_ERR [3] CRC [4] TRUNC [5] OVF
//                          [6] SKEW [7] FORMAT [8] FRAME [9] LP [10] EXTRA [11] SKIP
//   0x020 CNT_CLR     W    [0] clear the counters 0x024..0x048, 0x068
//   0x024..0x048      R    counters (saturating); 0x044 CNT_MISC: [31:24] skew + format +
//                          frame errors + skips ([23:0] 0: the D-PHY's CNT_CLK, CNT_LPERR);
//                          0x048 CNT_EXT: [15:0] bursts with more than EXTRA bytes after the
//                          packet, [31:16] deskew bursts
//   0x04C FRAME_ERR   R    [11:0] ERR_STATUS events of the last complete frame: from the
//                          FE before it (or the RX start) to its FE, latched at FE
//   0x050..0x060      R    FRAME_INFO, LINE_INFO, FRAME_SUM, FRAME_TIME, LINE_TIME
//   0x068 CNT_SOT23   R    counter: sync errors, lane 2 in [15:0], lane 3 in [31:16]
//   0x080 LOG_CTRL    RW   W [0] ARM [1] TRIG_FS [2] STOP_FE; R [0] ARMED [2:1] modes
//                          [8] DONE [21:16] WPTR
//   0x400..0x4FC      R    LOG[64]
//   0x00C, 0x040, 0x064, 0x06C, 0x070..0x07C, 0x084, 0x800..0x8FC: the PHY registers
//   before step 4 (PHY_CFG, CNT_BURST, BYTECLK, CNT_BURST23, DLYn, RAW_CTRL, RAW): read 0.
// Unmapped offsets read 0, writes to them are ignored. Writes honour the
// byte enables (commands and CNT_CLR are in byte 0). In W1C registers a
// hardware set wins over a clear in the same cycle. Fields of lanes above
// the Lanes parameter (CTRL.LANES with Lanes = 1, CTRL.LANES4 with Lanes < 4,
// counter fields) read 0 and ignore writes.
//
// Software changes CTRL.LANES/LANES4/VC/VC_ANY/DT/EXTRA only while RX_EN = 0:
// the other clock domains take them through one synchroniser per bit.
// rx_on_o (= PHY_EN & RX_EN) is a flop: it is the source of the datapath
// resets.
//
// LOG commands: every ARM increments a 4 bit gray request counter; the byte
// clock domain acknowledges by copying it (ack). ARMED = request != ack,
// DONE is set when the ack reaches the request after an ARM (cleared by the
// next ARM). ARM while a capture is pending restarts it (the counter does not
// advance onto the ack: at most 15 requests in flight).
//
// FRAME_TIME = CPU cycles between the last two FS; LINE_TIME = CPU cycles
// between the last two accepted line ends of one frame (the reference is
// reset by FS). Both references are reset while RX is off.

module bow_csi2rx_regs import bow_bus_pkg::*; import bow_csi2rx_pkg::*; #(
  parameter int unsigned Lanes     = 2,
  parameter int unsigned PhyClkHz  = 200_000_000,
  parameter bit          HasPhy    = 1'b1,
  parameter int unsigned FifoDepth = 256,
  parameter bit          DphyWin   = 1'b1   // INFO[6]: the D-PHY's registers are at 0xC00
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

  // LOG capture commands
  output logic [3:0]            log_req_o,      // gray
  output logic                  log_trig_fs_o,
  output logic                  log_stop_fe_o,
  input  logic [3:0]            log_ack_i,      // synchronised
  input  logic [5:0]            log_wptr_i,     // synchronised
  output logic                  log_re_o,       // RAM read port (data one cycle later)
  output logic [5:0]            ram_addr_o,
  input  logic [29:0]           log_rdata_i,

  // events (synchronised one cycle pulses) and the data that goes with them
  // (held by the source until the next event of the same kind)
  input  csi2_ev_t              ev_i,
  input  logic [15:0]           frame_lines_i,  // with ev_i.pl.fe
  input  logic [15:0]           frame_num_i,
  input  logic [31:0]           frame_sum_i,
  input  logic [15:0]           line_wc_i,      // with ev_i.pl.line
  input  logic [5:0]            line_dt_i,
  input  logic [1:0]            line_vc_i,

  // status (synchronised) and the D-PHY's interrupt (bus clock domain)
  input  logic                  in_frame_i,
  input  logic                  irq_i
);

  localparam int unsigned VidMhzR = (PhyClkHz + 500_000) / 1_000_000;
  localparam logic [7:0]  VidMhz  = (VidMhzR > 255) ? 8'd255 : 8'(VidMhzR);

  localparam int unsigned IrqFs  = 0;
  localparam int unsigned IrqFe  = 1;
  localparam int unsigned IrqErr = 2;
  localparam int unsigned IrqLog = 3;
  localparam int unsigned IrqPhy = 5;

  logic [11:0] a;
  logic        we, re, we0;
  logic [31:0] wd, bm;

  assign a   = {bus_req_i.addr[11:2], 2'b00};
  assign we  = bus_req_i.req &  bus_req_i.we;
  assign re  = bus_req_i.req & ~bus_req_i.we;
  assign wd  = bus_req_i.wdata;
  assign bm  = {{8{bus_req_i.be[3]}}, {8{bus_req_i.be[2]}},
                {8{bus_req_i.be[1]}}, {8{bus_req_i.be[0]}}};
  assign we0 = we && bus_req_i.be[0];          // byte 0 written (commands)

  // register value after a write with byte enables
  function automatic logic [31:0] wmerge(logic [31:0] old, logic [31:0] d, logic [31:0] m);
    return (old & ~m) | (d & m);
  endfunction

  // ---------------------------------------------------------- configuration
  csi2_cfg_t              cfg_q;
  logic                   rx_on_q;
  logic [Lanes:0]         lane_en_q;
  logic [2:0]             nact;
  logic [31:0]            ctrl_rd, ctrl_w;

  assign nact    = active_lanes(Lanes, cfg_q.lanes2, cfg_q.lanes4);
  assign ctrl_rd = {8'h0, cfg_q.extra, 2'b00, cfg_q.dt, cfg_q.lanes4, cfg_q.vc, cfg_q.vc_any,
                    1'b0, cfg_q.lanes2, cfg_q.rx_en, cfg_q.phy_en};
  assign ctrl_w  = wmerge(ctrl_rd, wd, bm);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cfg_q            <= '0;
      cfg_q.lanes2     <= (Lanes == 2);
      cfg_q.lanes4     <= (Lanes == 4);
      cfg_q.dt         <= DtRaw10;
      cfg_q.extra      <= 8'd64;
      rx_on_q          <= 1'b0;
      lane_en_q        <= '0;
    end else begin
      if (we && (a == 12'h008)) begin
        cfg_q.phy_en    <= ctrl_w[0];
        cfg_q.rx_en     <= ctrl_w[1];
        cfg_q.lanes2    <= ctrl_w[2] && (Lanes >= 2);
        cfg_q.vc_any    <= ctrl_w[4];
        cfg_q.vc        <= ctrl_w[6:5];
        cfg_q.lanes4    <= ctrl_w[7] && (Lanes == 4);
        cfg_q.dt        <= ctrl_w[13:8];
        cfg_q.extra     <= ctrl_w[23:16];
      end

      rx_on_q <= cfg_q.phy_en && cfg_q.rx_en;
      for (int unsigned l = 0; l <= Lanes; l++) begin
        lane_en_q[l] <= cfg_q.phy_en && ((l == 0) || (l <= 32'(nact)));
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

  // -------------------------------------------------------- LOG commands
  logic [3:0] log_req_q, log_req_n;
  logic       log_trig_q, log_stop_q, log_wait_q, log_done_q;
  logic       log_arm, log_fin;

  // The request never steps onto the ack: 16 ARMs before the capture side
  // answers would otherwise look like a completed capture.
  assign log_req_n = gray_inc4(log_req_q);

  assign log_arm = we0 && (a == 12'h080) && wd[0];
  assign log_fin = log_wait_q && (log_ack_i == log_req_q) && !log_arm;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      log_req_q  <= '0;
      log_trig_q <= 1'b0;
      log_stop_q <= 1'b0;
      log_wait_q <= 1'b0;
      log_done_q <= 1'b0;
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
    end
  end

  assign log_req_o     = log_req_q;
  assign log_trig_fs_o = log_trig_q;
  assign log_stop_fe_o = log_stop_q;

  // ------------------------------------------------- interrupts and errors
  // IRQ_STATUS[3:0]: W1C flags of the controller; [5] PHY: the D-PHY's interrupt line (a
  // level, cleared in the D-PHY); [4] (RAW_DONE before step 4) reads 0
  logic [3:0]  irq_set, irq_status_q;
  logic [5:0]  irq_en_q, irq_status;
  logic [31:0] irq_en_w;
  logic [11:0] err_set, err_status_q, ferr_q, frame_err_q;
  logic [1:0]  fe_dly_q;

  assign err_set = {ev_i.skip, ev_i.pl.extra, ev_i.lp, ev_i.pl.frame_err, ev_i.pl.fmt,
                    ev_i.skew, ev_i.pl.ovf, ev_i.pl.trunc, ev_i.pl.crc_err, ev_i.pl.ecc_err,
                    ev_i.pl.ecc_corr, |ev_i.sot};

  always_comb begin
    irq_set         = '0;
    irq_set[IrqFs]  = ev_i.pl.fs;
    irq_set[IrqFe]  = ev_i.pl.fe;
    irq_set[IrqErr] = (err_set != '0);
    irq_set[IrqLog] = log_fin;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      irq_status_q <= '0;
      irq_en_q     <= '0;
      err_status_q <= '0;
    end else begin
      irq_status_q <= (irq_status_q & ~(wd[3:0] & bm[3:0] & {4{we && (a == 12'h014)}})) | irq_set;
      err_status_q <= (err_status_q & ~(wd[11:0] & bm[11:0] & {12{we && (a == 12'h01C)}})) |
                      err_set;
      if (we && (a == 12'h018)) irq_en_q <= irq_en_w[5:0] & 6'b10_1111;
    end
  end

  always_comb begin
    irq_status         = {2'b00, irq_status_q};
    irq_status[IrqPhy] = irq_i;
  end

  // FRAME_ERR: the error events of one frame, collected from the previous
  // FE (or the RX start) and latched at its FE together with FRAME_INFO.
  // Errors between frames (vertical blanking) count for the next frame:
  // the lost burst may have been its FS or one of its lines. Events of the
  // FE packet itself (a corrected header) leave the csi clock domain in the same
  // cycle as FE but may arrive one CPU cycle later (separate pulse
  // synchronisers): the 2 cycles after FE still go to the frame that ended.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ferr_q      <= '0;
      frame_err_q <= '0;
      fe_dly_q    <= '0;
    end else begin
      fe_dly_q <= {fe_dly_q[0], ev_i.pl.fe};
      if (!rx_on_q || ev_i.pl.fe) ferr_q <= '0;
      else if (fe_dly_q == '0)    ferr_q <= ferr_q | err_set;
      if (ev_i.pl.fe)           frame_err_q <= ferr_q | err_set;
      else if (fe_dly_q != '0)  frame_err_q <= frame_err_q | err_set;
    end
  end

  assign irq_en_w = wmerge({26'h0, irq_en_q}, wd, bm);
  assign irq_o    = |(irq_status & irq_en_q);

  // --------------------------------------------------------------- counters
  function automatic logic [31:0] inc32(logic [31:0] c, logic e);
    return (e && (c != '1)) ? c + 32'd1 : c;
  endfunction

  function automatic logic [15:0] inc16(logic [15:0] c, logic e);
    return (e && (c != '1)) ? c + 16'd1 : c;
  endfunction

  function automatic logic [7:0] add8(logic [7:0] c, logic [2:0] n);
    logic [8:0] s;
    s = {1'b0, c} + {6'd0, n};
    return s[8] ? 8'hFF : s[7:0];
  endfunction

  logic [31:0]               cnt_frame_q, cnt_pkt_q, cnt_line_q;
  logic [15:0]               cnt_corr_q, cnt_uncorr_q, cnt_crc_q, cnt_trunc_q, cnt_drop_q, cnt_ovf_q;
  logic [15:0]               cnt_extra_q, cnt_deskew_q;
  logic [MaxLanes-1:0][15:0] cnt_sot_q;
  logic [7:0]                cnt_misc_q;
  logic [2:0]                n_misc;
  logic                      cnt_clr;

  assign cnt_clr = we0 && (a == 12'h020) && wd[0];
  assign n_misc  = 3'(ev_i.skew) + 3'(ev_i.pl.fmt) + 3'(ev_i.pl.frame_err) + 3'(ev_i.skip);

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
      cnt_extra_q  <= '0;
      cnt_deskew_q <= '0;
      cnt_sot_q    <= '0;
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
      cnt_extra_q  <= '0;
      cnt_deskew_q <= '0;
      cnt_sot_q    <= '0;
      cnt_misc_q   <= '0;
    end else begin
      cnt_frame_q  <= inc32(cnt_frame_q, ev_i.pl.fs);
      cnt_pkt_q    <= inc32(cnt_pkt_q, ev_i.pl.pkt);
      cnt_line_q   <= inc32(cnt_line_q, ev_i.pl.line);
      cnt_corr_q   <= inc16(cnt_corr_q, ev_i.pl.ecc_corr);
      cnt_uncorr_q <= inc16(cnt_uncorr_q, ev_i.pl.ecc_err);
      cnt_crc_q    <= inc16(cnt_crc_q, ev_i.pl.crc_err);
      cnt_trunc_q  <= inc16(cnt_trunc_q, ev_i.pl.trunc);
      cnt_drop_q   <= inc16(cnt_drop_q, ev_i.pl.drop);
      cnt_ovf_q    <= inc16(cnt_ovf_q, ev_i.pl.ovf);
      cnt_extra_q  <= inc16(cnt_extra_q, ev_i.pl.extra);
      cnt_deskew_q <= inc16(cnt_deskew_q, ev_i.deskew);
      cnt_misc_q   <= add8(cnt_misc_q, n_misc);
      for (int unsigned l = 0; l < MaxLanes; l++) begin
        cnt_sot_q[l] <= inc16(cnt_sot_q[l], ev_i.sot[l]);
      end
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

  // --------------------------------------------------------------- read data
  logic [31:0] rdata_d, rdata_q;
  logic        rvalid_q, sel_log_q;

  always_comb begin
    unique case (a)
      12'h000: rdata_d = Csi2rxId;
      12'h004: rdata_d = {16'(FifoDepth), VidMhz, 1'b0, DphyWin, 1'b0, HasPhy, 4'(Lanes)};
      12'h008: rdata_d = ctrl_rd;
      12'h010: rdata_d = {19'h0, in_frame_i, 12'h0};
      12'h014: rdata_d = {26'h0, irq_status};
      12'h018: rdata_d = {26'h0, irq_en_q};
      12'h01C: rdata_d = {20'h0, err_status_q};
      12'h024: rdata_d = cnt_frame_q;
      12'h028: rdata_d = cnt_pkt_q;
      12'h02C: rdata_d = cnt_line_q;
      12'h030: rdata_d = {cnt_uncorr_q, cnt_corr_q};
      12'h034: rdata_d = {cnt_trunc_q, cnt_crc_q};
      12'h038: rdata_d = {cnt_sot_q[1], cnt_sot_q[0]};
      12'h03C: rdata_d = {cnt_ovf_q, cnt_drop_q};
      12'h044: rdata_d = {cnt_misc_q, 24'h0};
      12'h048: rdata_d = {cnt_deskew_q, cnt_extra_q};
      12'h04C: rdata_d = {20'h0, frame_err_q};
      12'h050: rdata_d = frame_info_q;
      12'h054: rdata_d = line_info_q;
      12'h058: rdata_d = frame_sum_q;
      12'h05C: rdata_d = frame_time_q;
      12'h060: rdata_d = line_time_q;
      12'h068: rdata_d = {cnt_sot_q[3], cnt_sot_q[2]};
      12'h080: rdata_d = {10'h0, log_wptr_i, 7'h0, log_done_q, 5'h0, log_stop_q, log_trig_q,
                          (log_req_q != log_ack_i)};
      default: rdata_d = '0;
    endcase
  end

  // LOG RAM: registered read port, selected in the response cycle
  assign log_re_o   = re && (a[11:8] == 4'h4);
  assign ram_addr_o = a[7:2];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q  <= 1'b0;
      rdata_q   <= '0;
      sel_log_q <= 1'b0;
    end else begin
      rvalid_q  <= bus_req_i.req;
      sel_log_q <= log_re_o;
      if (re) rdata_q <= rdata_d;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = sel_log_q ? 32'(log_rdata_i) : rdata_q;

  logic unused_bus;
  assign unused_bus = ^{bus_req_i.addr[31:12], bus_req_i.addr[1:0], ctrl_w[31:24], ctrl_w[15:14],
                        ctrl_w[3], irq_en_w[31:6]};

endmodule
