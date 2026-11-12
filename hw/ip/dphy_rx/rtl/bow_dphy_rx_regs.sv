// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// D-PHY receiver register file, v1 (bus clock domain): steps 4 and 5 of
// docs/ip/mipi_rx_arch.md (section 10), the registers of section 4.10 that the D-PHY has in
// v1; docs/ip/dphy_rx.md is the map with the reset values and the fields of later steps.
// Offsets in the D-PHY window (bow_mipi_rx: 0xC00 of CSI2RX, 0x4000_8C00):
//
//   0x000 ID          R    0x44505201
//   0x004 INFO        R    [3:0] lanes [4] PPI 16 bit (0) [7:5] AfeKind [17:8] lp_clk MHz
//                          [21:18] DlyW (9) [22] clock lane delay (0) [23] AFE self-calibrated
//                          delay (AfeKind = 2, Versal BISC)
//   0x008 INFO2       R    [7:0] SETTLE_NS [15:8] SETTLE_UI [23:16] AFE trail bytes per lane
//   0x00C CTRL        RW   [1] CLK_CONT [6] DES_RST_DIS
//   0x010 CMD         W    [1] REINIT (cal_start_o for ReinitCycles cycles) [3] CNT_CLR
//   0x014 AFE_CTRL    RW   [0] PD (AfePdRst): pd_o, lprx_en_o = ~PD, lane_pd_o
//   0x018 AFE_STATUS  R    [0] READY [1] CAL_DONE [2] CAL_ERR [15:8] raw AFE status
//   0x024 TIM0        RW   [7:0] SETTLE [11:8] LP_FILTER [23:16] CLK_SETTLE [31:24] CLK_MISS
//   0x030 LANE_LP     R    filtered LP {P, N}: [1:0] clock lane, [2l+3:2l+2] data lane l
//   0x034 LANE_HS     R    [0] clock lane HS receiver, [l+1] data lane l, [16] byte clock gate,
//                          [17] RxClkActiveHS (v1: the gate) [18] BYTECLK_OK
//   0x03C IRQ_STATUS  W1C  [0] ERR [3] RAW_DONE
//   0x040 IRQ_EN      RW   same bits, irq_o = |(IRQ_STATUS & IRQ_EN)
//   0x044 ERR_STATUS  W1C  [2] CONTROL (LP sequence error / HS watchdog, any lane)
//   0x048 ERR_LANE    W1C  [8+l] CONTROL of data lane l, [16] CONTROL of the clock lane
//   0x04C BYTECLK     R    [19:0] byte clocks per 65536 bus cycles
//   0x050..0x05C      R    CNT_BURST0..3: HS entries of data lane l (32 bit, saturating)
//   0x070 CNT_CLK     R    HS entries of the clock lane
//   0x074 CNT_LPERR   R    LP errors (CONTROL) of every lane
//   0x080..0x08C      RW   DLY0..3: [8:0] CODE [15] PEND [24:16] dly_q (CNTVALUEOUT) [31] OWN
//   0x100 RAW_CTRL    RW   W [0] ARM [1] NOW; R [0] ARMED [1] NOW [8] DONE
//   0x200..0x3FC      R    RAW[64]: 0x200 + 8i lanes 0..3 (byte k = lane k), 0x204 + 8i 0
// Unmapped offsets (and the registers of later steps) read 0, writes to them are ignored.
// Writes honour the byte enables (commands need byte 0; a DLYn write that leaves out bytes
// 0 and 1 changes nothing). In W1C registers a hardware set wins over a clear in the same
// cycle. Fields of lanes above the Lanes parameter read 0 and ignore writes.
//
// Every output is a bus clock flop: CTRL.CLK_CONT, TIM0 and des_rst_en_o = ~DES_RST_DIS
// (held in a flop of its own, reset 1: the receive path reset of the AFE is on by default)
// go to bow_dphy_rx, which synchronises them into the lp domain (u_sync_vcfg, quasi-static,
// changed only while the PHY is off); the RAW commands to its byte domain. The AFE controls
// of the register file go to the AFE as they are (docs/ip/mipi_rx_arch.md section 3.1: the
// AFE takes every control as asynchronous): the DLYn codes and OWN (dly_code_o, dly_own_o),
// pd_o, lprx_en_o, lane_pd_o and cal_start_o. v1 keeps them in the bus domain, where their
// only owner (the software) writes them; the lp domain copy of the codes comes with the
// second owner, the deskew engine (step 8).
//
// AFE_CTRL.PD (v1: bit 0 only; TST_MODE and ATB_SEL later): pd_o = PD, lprx_en_o = ~PD (a flop
// of its own), lane_pd_o = 1 from reset and while PD = 1, 0 once AFE_STATUS.READY was seen
// with PD = 0 (section 3.6 of the spec; v1 has no LANE_EN and no ULPS, so every lane).
//
// CMD.REINIT (v1): cal_start_o high for ReinitCycles cycles, the AFE's re-calibration (Versal
// adapter: XPLL, BISC and VT tracking again); its other meaning (the state machines back to
// WaitStop) and the split into CMD.AFE_CAL come with step 6.
//
// DLYn (v1): CODE is the code the software asked for: dly_code_o, a static level (the AFE
// applies a new code by itself; docs/ip/mipi_rx_arch.md section 3.5). Every write with byte 0
// or 1 sets CODE and, while AFE_STATUS.READY = 1, OWN (dly_own_o: the lane uses CODE). OWN is
// 0 while READY = 0 (an AFE restart loses the loaded codes; the next write raises OWN again
// and so reloads, also the same code). PEND = OWN and the AFE's delay [24:16] (dly_q) differs
// from CODE: not applied yet. Software is the only owner of the code in v1 (no deskew
// engine, no release), so this is all it needs.
//
// BYTECLK: every 256 cycles the byte clock meter delta (mod 2^20) is taken; the maximum of 256
// such windows, times 256, is BYTECLK = byte clock cycles per 65536 bus cycles while the clock
// runs (as it was in the CSI-2 controller before step 4).
//
// RAW commands: every ARM increments a 4 bit gray request counter; the byte clock domain
// acknowledges by copying it (ack). ARMED = request != ack, DONE is set when the ack reaches
// the request after an ARM (cleared by the next ARM). ARM while a capture is pending restarts
// it (the counter does not advance onto the ack: at most 15 requests in flight).

module bow_dphy_rx_regs import bow_bus_pkg::*; #(
  parameter int unsigned Lanes        = 2,
  parameter int unsigned LpClkHz      = 200_000_000,
  parameter int unsigned AfeKind      = 1,
  parameter int unsigned AfeSettleNs  = 107,
  parameter int unsigned AfeSettleUi  = 24,
  parameter int unsigned AfeTrailB    = 0,
  parameter bit          AfePdRst     = 1'b0,         // AFE_CTRL.PD after reset
  parameter int unsigned ReinitCycles = 32            // cal_start_o pulse, bus clock cycles
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  input  bus_req_t              bus_req_i,
  output bus_rsp_t              bus_rsp_o,
  output logic                  irq_o,

  // configuration and commands (bus clock flops)
  output logic                  clk_cont_o,       // CTRL.CLK_CONT
  output logic                  des_rst_en_o,     // ~CTRL.DES_RST_DIS
  output logic [7:0]            settle_o,         // TIM0
  output logic [3:0]            lp_filter_o,
  output logic [7:0]            clk_settle_o,
  output logic [7:0]            clk_miss_o,
  // AFE controls (bus clock flops, asynchronous for the AFE)
  output logic                  cal_start_o,      // CMD.REINIT pulse
  output logic                  pd_o,             // AFE_CTRL.PD
  output logic                  lprx_en_o,        // ~AFE_CTRL.PD
  output logic                  lane_pd_o,        // PD, or READY not yet seen since PD = 0
  output logic [Lanes-1:0][8:0] dly_code_o,       // DLYn CODE
  output logic [Lanes-1:0]      dly_own_o,        // DLYn OWN
  output logic [3:0]            raw_req_o,        // gray
  output logic                  raw_now_o,
  input  logic [3:0]            raw_ack_i,        // synchronised
  output logic                  raw_re_o,         // RAW RAM read port (data one cycle later)
  output logic [5:0]            raw_addr_o,
  input  logic [8*Lanes-1:0]    raw_rdata_i,

  // events (synchronised one cycle pulses): [0] clock lane, [1 + l] data lane l
  input  logic [Lanes:0]        ev_hs_i,          // HS entry
  input  logic [Lanes:0]        ev_err_i,         // LP sequence error / HS watchdog

  // status (synchronised)
  input  logic [Lanes:0][1:0]   lp_i,             // filtered LP {P, N}, same order
  input  logic [Lanes:0]        hs_en_i,          // HS receivers on, same order
  input  logic                  ce_i,             // byte clock gate open
  input  logic                  ready_i,          // AFE ready
  input  logic                  cal_done_i,       // AFE internal calibration done
  input  logic                  cal_err_i,        // ... and failed
  input  logic [7:0]            afe_status_i,     // raw AFE status
  input  logic [19:0]           meter_i,          // byte clock cycle counter, gray
  input  logic [Lanes-1:0][8:0] dly_q_i           // AFE dly_q: the delays in use
);

  localparam int unsigned MaxLanes = 4;
  localparam int unsigned DlyW     = 9;
  localparam logic [31:0] DphyId   = 32'h4450_5201;   // "DPR", version 1

  if (Lanes > MaxLanes) begin : g_bad_lanes
    $error("bow_dphy_rx_regs: Lanes %0d > %0d", Lanes, MaxLanes);
  end
  if ((ReinitCycles == 0) || (ReinitCycles > 32)) begin : g_bad_reinit
    $error("bow_dphy_rx_regs: ReinitCycles %0d not in 1..32", ReinitCycles);
  end

  localparam int unsigned LpMhzR = (LpClkHz + 500_000) / 1_000_000;
  localparam logic [9:0]  LpMhz  = (LpMhzR > 1023) ? 10'd1023 : 10'(LpMhzR);
  localparam logic [31:0] Info   = {8'h00, (AfeKind == 2), 1'b0, 4'(DlyW), LpMhz, 3'(AfeKind),
                                    1'b0, 4'(Lanes)};
  localparam logic [31:0] Info2  = {8'h00, 8'(AfeTrailB), 8'(AfeSettleUi), 8'(AfeSettleNs)};

  localparam int unsigned IrqErr = 0;
  localparam int unsigned IrqRaw = 3;

  logic [9:0]  a;
  logic        we, re, we0;
  logic [31:0] wd, bm;

  assign a   = {bus_req_i.addr[9:2], 2'b00};
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

  function automatic logic [3:0] gray_inc4(logic [3:0] g);
    logic [3:0] b;
    b[3] = g[3];
    for (int i = 2; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
    b = b + 4'd1;
    return b ^ (b >> 1);
  endfunction

  function automatic logic [19:0] gray2bin20(logic [19:0] g);
    logic [19:0] b;
    b[19] = g[19];
    for (int i = 18; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
    return b;
  endfunction

  // --------------------------------------------------------- CTRL, CMD, TIM0
  logic        clk_cont_q, burst_rst_en_q, reinit_q;
  logic [4:0]  reinit_cnt_q;
  logic [7:0]  settle_q, clk_settle_q, clk_miss_q;
  logic [3:0]  lp_filter_q;
  logic [31:0] ctrl_rd, tim0_rd, ctrl_w, tim0_w;
  logic        cnt_clr;

  localparam logic [4:0] ReinitLast = 5'(ReinitCycles - 1);

  assign ctrl_rd = {25'h0, ~burst_rst_en_q, 4'h0, clk_cont_q, 1'b0};
  assign tim0_rd = {clk_miss_q, clk_settle_q, 4'h0, lp_filter_q, settle_q};
  assign ctrl_w  = wmerge(ctrl_rd, wd, bm);
  assign tim0_w  = wmerge(tim0_rd, wd, bm);
  assign cnt_clr = we0 && (a == 10'h010) && wd[3];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      clk_cont_q     <= 1'b0;
      burst_rst_en_q <= 1'b1;
      reinit_q       <= 1'b0;
      reinit_cnt_q   <= '0;
      settle_q       <= 8'd14;
      lp_filter_q    <= 4'd2;
      clk_settle_q   <= 8'd30;
      clk_miss_q     <= 8'd8;
    end else begin
      if (we && (a == 10'h00C)) begin
        clk_cont_q     <= ctrl_w[1];
        burst_rst_en_q <= ~ctrl_w[6];
      end
      if (we && (a == 10'h024)) begin
        settle_q     <= tim0_w[7:0];
        lp_filter_q  <= tim0_w[11:8];
        clk_settle_q <= tim0_w[23:16];
        clk_miss_q   <= tim0_w[31:24];
      end
      // REINIT: cal_start_o high for ReinitCycles cycles (a new REINIT restarts it)
      if (we0 && (a == 10'h010) && wd[1]) begin
        reinit_q     <= 1'b1;
        reinit_cnt_q <= ReinitLast;
      end else if (reinit_cnt_q != 5'd0) begin
        reinit_cnt_q <= reinit_cnt_q - 5'd1;
      end else begin
        reinit_q <= 1'b0;
      end
    end
  end

  assign clk_cont_o     = clk_cont_q;
  assign des_rst_en_o   = burst_rst_en_q;
  assign cal_start_o    = reinit_q;
  assign settle_o       = settle_q;
  assign lp_filter_o    = lp_filter_q;
  assign clk_settle_o   = clk_settle_q;
  assign clk_miss_o     = clk_miss_q;

  // ----------------------------------------------------------------- AFE_CTRL
  // PD (pd_o), lprx_en_o = ~PD and lane_pd_o, three flops (every AFE control comes from a
  // flop, no logic after it)
  logic        pd_q, pd_d, lprx_en_q, lane_pd_q;
  logic [31:0] afe_ctrl_rd, afe_ctrl_w;

  assign afe_ctrl_rd = {31'h0, pd_q};
  assign afe_ctrl_w  = wmerge(afe_ctrl_rd, wd, bm);
  assign pd_d        = (we && (a == 10'h014)) ? afe_ctrl_w[0] : pd_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pd_q      <= AfePdRst;
      lprx_en_q <= !AfePdRst;
      lane_pd_q <= 1'b1;
    end else begin
      pd_q      <= pd_d;
      lprx_en_q <= !pd_d;
      lane_pd_q <= pd_d || (lane_pd_q && !ready_i);   // 0 once READY was seen without PD
    end
  end

  assign pd_o      = pd_q;
  assign lprx_en_o = lprx_en_q;
  assign lane_pd_o = lane_pd_q;

  // --------------------------------------------------------------------- DLYn
  // CODE and OWN per lane (next state computed here, one non-blocking write per register:
  // see the xsim note in bow_csi2rx)
  logic [Lanes-1:0][DlyW-1:0] dly_code_q, dly_code_d;
  logic [Lanes-1:0]           own_q, own_d;
  logic [Lanes-1:0][31:0]     dly_w;

  for (genvar l = 0; l < Lanes; l++) begin : g_dly_w
    assign dly_w[l] = wmerge({23'h0, dly_code_q[l]}, wd, bm);
  end

  always_comb begin
    dly_code_d = dly_code_q;
    own_d      = ready_i ? own_q : '0;
    for (int unsigned l = 0; l < Lanes; l++) begin
      if (we && (a == 10'(32'h080 + 4 * l)) && (bus_req_i.be[1:0] != 2'b00)) begin
        dly_code_d[l] = dly_w[l][DlyW-1:0];
        if (ready_i) own_d[l] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dly_code_q <= '0;
      own_q      <= '0;
    end else begin
      dly_code_q <= dly_code_d;
      own_q      <= own_d;
    end
  end

  assign dly_code_o = dly_code_q;
  assign dly_own_o  = own_q;

  // ------------------------------------------------------------- RAW commands
  logic [3:0] raw_req_q, raw_req_n;
  logic       raw_now_q, raw_wait_q, raw_done_q, raw_arm, raw_fin;

  // The request never steps onto the ack: 16 ARMs while the byte clock is stopped would
  // otherwise look like a completed capture.
  assign raw_req_n = gray_inc4(raw_req_q);
  assign raw_arm   = we0 && (a == 10'h100) && (wd[0] || wd[1]);
  assign raw_fin   = raw_wait_q && (raw_ack_i == raw_req_q) && !raw_arm;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      raw_req_q  <= '0;
      raw_now_q  <= 1'b0;
      raw_wait_q <= 1'b0;
      raw_done_q <= 1'b0;
    end else if (raw_arm) begin
      if (raw_req_n != raw_ack_i) raw_req_q <= raw_req_n;
      raw_now_q  <= wd[1];
      raw_wait_q <= 1'b1;
      raw_done_q <= 1'b0;
    end else if (raw_fin) begin
      raw_wait_q <= 1'b0;
      raw_done_q <= 1'b1;
    end
  end

  assign raw_req_o = raw_req_q;
  assign raw_now_o = raw_now_q;

  // ----------------------------------------------------- interrupts and errors
  logic [3:0]  irq_set, irq_status_q, irq_en_q;
  logic [31:0] irq_en_w;
  logic        err_set, err_status_q;
  logic [MaxLanes:0] lane_err, err_lane_q;     // [0] clock lane, [1 + l] data lane l
  logic [31:0] err_lane_rd, err_lane_clr;

  always_comb begin
    lane_err = '0;
    for (int unsigned i = 0; i <= Lanes; i++) lane_err[i] = ev_err_i[i];
  end

  assign err_set = |ev_err_i;

  always_comb begin
    irq_set         = '0;
    irq_set[IrqErr] = err_set;
    irq_set[IrqRaw] = raw_fin;
  end

  // ERR_LANE: [8 + l] data lane l, [16] clock lane
  assign err_lane_rd  = {15'h0, err_lane_q[0], 4'h0, err_lane_q[MaxLanes:1], 8'h00};
  assign err_lane_clr = wd & bm & {32{we && (a == 10'h048)}};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      irq_status_q <= '0;
      irq_en_q     <= '0;
      err_status_q <= 1'b0;
      err_lane_q   <= '0;
    end else begin
      irq_status_q <= (irq_status_q & ~(wd[3:0] & bm[3:0] & {4{we && (a == 10'h03C)}})) |
                      irq_set;
      err_status_q <= (err_status_q & ~(wd[2] & bm[2] & we && (a == 10'h044))) | err_set;
      err_lane_q   <= (err_lane_q & ~{err_lane_clr[11:8], err_lane_clr[16]}) | lane_err;
      if (we && (a == 10'h040)) irq_en_q <= irq_en_w[3:0] & 4'b1001;
    end
  end

  assign irq_en_w = wmerge({28'h0, irq_en_q}, wd, bm);
  assign irq_o    = |(irq_status_q & irq_en_q);

  // ------------------------------------------------------------------ counters
  function automatic logic [31:0] add32(logic [31:0] c, logic [2:0] n);
    logic [32:0] s;
    s = {1'b0, c} + {30'd0, n};
    return s[32] ? 32'hFFFF_FFFF : s[31:0];
  endfunction

  logic [MaxLanes-1:0][31:0] cnt_burst_q;
  logic [31:0]               cnt_clk_q, cnt_lperr_q;
  logic [2:0]                n_err;

  always_comb begin
    n_err = '0;
    for (int unsigned i = 0; i <= Lanes; i++) n_err = n_err + 3'(ev_err_i[i]);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cnt_burst_q <= '0;
      cnt_clk_q   <= '0;
      cnt_lperr_q <= '0;
    end else if (cnt_clr) begin
      cnt_burst_q <= '0;
      cnt_clk_q   <= '0;
      cnt_lperr_q <= '0;
    end else begin
      cnt_clk_q   <= add32(cnt_clk_q, 3'(ev_hs_i[0]));
      cnt_lperr_q <= add32(cnt_lperr_q, n_err);
      for (int unsigned l = 0; l < Lanes; l++) begin
        cnt_burst_q[l] <= add32(cnt_burst_q[l], 3'(ev_hs_i[1 + l]));
      end
    end
  end

  // -------------------------------------------------------- byte clock meter
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

  // ----------------------------------------------------------------- read data
  // Lane fields padded to MaxLanes: absent lanes read 0
  logic [MaxLanes:0][1:0]      lp5;
  logic [MaxLanes:0]           hs5;
  logic [MaxLanes-1:0][31:0]   dly_rd;
  logic [31:0]                 rdata_d, rdata_q;
  logic                        rvalid_q, sel_raw_q;

  always_comb begin
    lp5    = '0;
    hs5    = '0;
    dly_rd = '0;
    for (int unsigned l = 0; l <= Lanes; l++) begin
      lp5[l] = lp_i[l];
      hs5[l] = hs_en_i[l];
    end
    for (int unsigned l = 0; l < Lanes; l++) begin
      dly_rd[l] = {own_q[l], 6'h0, dly_q_i[l], own_q[l] && (dly_q_i[l] != dly_code_q[l]), 6'h0,
                   dly_code_q[l]};
    end
  end

  always_comb begin
    unique case (a)
      10'h000: rdata_d = DphyId;
      10'h004: rdata_d = Info;
      10'h008: rdata_d = Info2;
      10'h00C: rdata_d = ctrl_rd;
      10'h014: rdata_d = afe_ctrl_rd;
      10'h018: rdata_d = {16'h0, afe_status_i, 5'h0, cal_err_i, cal_done_i, ready_i};
      10'h024: rdata_d = tim0_rd;
      10'h030: rdata_d = {22'h0, lp5};
      10'h034: rdata_d = {13'h0, (byteclk_q != '0), ce_i, ce_i, 11'h0, hs5};
      10'h03C: rdata_d = {28'h0, irq_status_q};
      10'h040: rdata_d = {28'h0, irq_en_q};
      10'h044: rdata_d = {29'h0, err_status_q, 2'b00};
      10'h048: rdata_d = err_lane_rd;
      10'h04C: rdata_d = {12'h0, byteclk_q};
      10'h050: rdata_d = cnt_burst_q[0];
      10'h054: rdata_d = cnt_burst_q[1];
      10'h058: rdata_d = cnt_burst_q[2];
      10'h05C: rdata_d = cnt_burst_q[3];
      10'h070: rdata_d = cnt_clk_q;
      10'h074: rdata_d = cnt_lperr_q;
      10'h080: rdata_d = dly_rd[0];
      10'h084: rdata_d = dly_rd[1];
      10'h088: rdata_d = dly_rd[2];
      10'h08C: rdata_d = dly_rd[3];
      10'h100: rdata_d = {23'h0, raw_done_q, 6'h0, raw_now_q, (raw_req_q != raw_ack_i)};
      default: rdata_d = '0;
    endcase
  end

  // RAW RAM: registered read port, selected in the response cycle (0x200 + 8i: lanes
  // 0..3; 0x204 + 8i, lanes 4..7, reads 0)
  assign raw_re_o   = re && a[9] && !a[2];
  assign raw_addr_o = a[8:3];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q  <= 1'b0;
      rdata_q   <= '0;
      sel_raw_q <= 1'b0;
    end else begin
      rvalid_q  <= bus_req_i.req;
      sel_raw_q <= raw_re_o;
      if (re) rdata_q <= rdata_d;
    end
  end

  assign bus_rsp_o.gnt    = 1'b1;
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = 1'b0;
  assign bus_rsp_o.rdata  = sel_raw_q ? 32'(raw_rdata_i) : rdata_q;

  logic unused_bus, unused_dly;
  assign unused_bus = ^{bus_req_i.addr[31:10], bus_req_i.addr[1:0], ctrl_w[31:7], ctrl_w[5:2],
                        ctrl_w[0], tim0_w[15:12], irq_en_w[31:4], err_lane_clr[31:17],
                        err_lane_clr[15:12], err_lane_clr[7:0], afe_ctrl_w[31:1], unused_dly};

  always_comb begin
    unused_dly = 1'b0;
    for (int unsigned l = 0; l < Lanes; l++) unused_dly ^= ^dly_w[l][31:DlyW];
  end

endmodule
