// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// D-PHY receiver register file (bus clock domain): steps 4 to 6 of docs/ip/mipi_rx_arch.md
// (section 10), the registers of section 4.10 that the D-PHY has up to v1.x;
// docs/ip/dphy_rx.md is the map with the reset values and the fields of later steps.
// Offsets in the D-PHY window (bow_mipi_rx: 0xC00 of CSI2RX, 0x4000_8C00):
//
//   0x000 ID          R    0x44505202 ([7:0]: the version of this map, 2 since step 6)
//   0x004 INFO        R    [3:0] lanes [4] PPI 16 bit (0) [7:5] AfeKind [17:8] lp_clk MHz
//                          [21:18] DlyW (9) [22] clock lane delay (0) [23] AFE self-calibrated
//                          delay (AfeKind = 2, Versal BISC) [27] ULPS (1)
//   0x008 INFO2       R    [7:0] SETTLE_NS [15:8] SETTLE_UI [23:16] AFE trail bytes per lane
//   0x00C CTRL        RW*  [1] CLK_CONT [2] ULPS_EN [3] HSRX_EARLY [6] DES_RST_DIS
//                          [7] CLK_LOST_EN [16] CLK_MISS_OFF
//   0x010 CMD         W    [0] APPLY [1] REINIT [2] AFE_CAL (cal_start_o for ReinitCycles
//                          cycles) [3] CNT_CLR; R [0] APPLY pending [31] DIRTY
//   0x014 AFE_CTRL    RW   [0] PD (AfePdRst): pd_o, lprx_en_o = ~PD, lane_pd_o
//   0x018 AFE_STATUS  R    [0] READY [1] CAL_DONE [2] CAL_ERR [15:8] raw AFE status
//   0x024 TIM0        RW*  [7:0] SETTLE [11:8] LP_FILTER [23:16] CLK_SETTLE [31:24] CLK_MISS
//   0x028 TIM1        RW*  [23:0] HS_TMO (0x100000) [27:24] CLK_TOG_DIV
//   0x02C TIM2        RW*  [19:0] T_INIT [31:20] ESC_TMO (64 lp cycles)
//   0x030 LANE_LP     R    filtered LP {P, N}: [1:0] clock lane, [2l+3:2l+2] data lane l
//   0x034 LANE_HS     R    [0] clock lane HS receiver, [l+1] data lane l, [16] byte clock gate,
//                          [17] RxClkActiveHS (the gate) [18] BYTECLK_OK
//   0x038 LANE_STOP   R    [0] StopstateClk [l+1] Stopstate[l]; [16] ULPS clock lane,
//                          [l+17] ULPS data lane l
//   0x03C IRQ_STATUS  W1C  [0] ERR [1] ULPS (entry or exit) [3] RAW_DONE
//   0x040 IRQ_EN      RW   same bits, irq_o = |(IRQ_STATUS & IRQ_EN)
//   0x044 ERR_STATUS  W1C  [2] CONTROL (LP sequence error / HS watchdog, any lane) [3] HS_TMO
//                          [4] ESC [6] CLK_LOST [7] LATE_EOT [10] ESC_TMO
//   0x048 ERR_LANE    W1C  [8+l] CONTROL of data lane l, [16] CONTROL of the clock lane
//   0x04C BYTECLK     R    [19:0] byte clocks per 65536 bus cycles
//   0x050..0x05C      R    CNT_BURST0..3: HS entries of data lane l (32 bit, saturating)
//   0x070 CNT_CLK     R    HS entries of the clock lane
//   0x074 CNT_LPERR   R    LP errors (CONTROL) of every lane
//   0x078 CNT_DSK     R    [31:16] ULPS entries of every lane (16 bit, saturating)
//   0x07C CNT_MISC    R    [31:16] HS_TMO + CLK_LOST + LATE_EOT + ESC_TMO (16 bit, saturating)
//   0x080..0x08C      RW   DLY0..3: [8:0] CODE [15] PEND [24:16] dly_q (CNTVALUEOUT) [31] OWN
//   0x100 RAW_CTRL    RW   W [0] ARM [1] NOW; R [0] ARMED [1] NOW [8] DONE
//   0x200..0x3FC      R    RAW[64]: 0x200 + 8i lanes 0..3 (byte k = lane k), 0x204 + 8i 0
// Unmapped offsets (and the registers of later steps) read 0, writes to them are ignored.
// Writes honour the byte enables (commands need byte 0; a DLYn write that leaves out bytes
// 0 and 1 changes nothing). In W1C registers a hardware set wins over a clear in the same
// cycle. Fields of lanes above the Lanes parameter read 0 and ignore writes.
//
// * Shadow registers (RW*, v1.x): CTRL and TIM0..2 are written and read here; the lp domain
//   takes all of them at once when CMD.APPLY toggles apply_req_o and acknowledges through
//   apply_ack_i (bow_dphy_rx). CMD reads [0] = 1 from the APPLY until the acknowledge; an
//   APPLY while one is pending is done after it (the latest shadow). Software writes no
//   shadow register while CMD[0] reads 1. CMD[31] DIRTY reads 1 from a write to one of them
//   (at least one byte, the same value too) until an APPLY is sent: the shadow may differ
//   from what the lp domain uses. CMD reads 0 when the lp domain uses the shadow as it reads
//   (CTRL, TIM0..2 read back the shadow, not the applied copy). Reset values: those of v1
//   (TIM0 0x081E020E, TIM1 0x00100000, TIM2 0, CTRL 0), which the lp domain also has from
//   its reset.
// * Every output is a bus clock flop: the shadow fields go to bow_dphy_rx (the copy into the
//   lp domain), the RAW commands to its byte domain. The AFE controls of the register file go
//   to the AFE as they are (docs/ip/mipi_rx_arch.md section 3.1: the AFE takes every control
//   as asynchronous): the DLYn codes and OWN (dly_code_o, dly_own_o), pd_o, lprx_en_o,
//   lane_pd_o and cal_start_o. They stay in the bus domain, where their only owner (the
//   software) writes them; the lp domain copy of the codes comes with the second owner, the
//   deskew engine (step 8).
// * AFE_CTRL.PD (bit 0 only; TST_MODE and ATB_SEL later): pd_o = PD, lprx_en_o = ~PD (a flop
//   of its own), lane_pd_o[i] (one flop per lane, [0] clock lane) = 1 from reset and while PD
//   = 1, 0 once a fresh AFE_STATUS.READY was seen with PD = 0: READY 0 at least once since PD
//   last rose (or since reset), then 1 (section 3.6 of the spec); and 1 while the lane is in
//   ULPS before its wake-up mark (ulps_act_i, v1.x).
// * CMD.AFE_CAL (v1.x; CMD.REINIT up to step 5): cal_start_o high for ReinitCycles cycles, the
//   AFE's re-calibration (Versal adapter: XPLL, BISC and VT tracking again). CMD.REINIT
//   (v1.x): reinit_o, one cycle: the lane state machines back to WaitStop and T_INIT due
//   again (bow_dphy_rx). rdy_up_o: one cycle when READY rises (T_INIT due again).
// * DLYn: CODE is the code the software asked for: dly_code_o, a static level (the AFE
//   applies a new code by itself; docs/ip/mipi_rx_arch.md section 3.5). Every write with byte
//   0 or 1 sets CODE and, while AFE_STATUS.READY = 1, OWN (dly_own_o: the lane uses CODE). OWN
//   is 0 while READY = 0 (an AFE restart loses the loaded codes; the next write raises OWN
//   again and so reloads, also the same code). PEND = OWN and the AFE's delay [24:16] (dly_q)
//   differs from CODE: not applied yet. Software is the only owner of the code (no deskew
//   engine, no release yet), so this is all it needs.
// * Event counters (v1.x): the lp domain counts its events in 4 bit gray counters (evc_*_i,
//   synchronised per bit); every bus cycle the difference to the value of the cycle before
//   is added to CNT_BURSTn / CNT_CLK (HS entries), CNT_LPERR (LP errors), CNT_MISC and CNT_DSK
//   and sets the ERR_STATUS / ERR_LANE / IRQ_STATUS bits of the kinds (v1: one pulse
//   synchroniser per kind, an event at most every 16 lp cycles).
// * BYTECLK: every 256 cycles the byte clock meter delta (mod 2^20) is taken; the maximum of
//   256 such windows, times 256, is BYTECLK = byte clock cycles per 65536 bus cycles while
//   the clock runs (as it was in the CSI-2 controller before step 4).
// * RAW commands: every ARM increments a 4 bit gray request counter; the byte clock domain
//   acknowledges by copying it (ack). ARMED = request != ack, DONE is set when the ack reaches
//   the request after an ARM (cleared by the next ARM). ARM while a capture is pending
//   restarts it (the counter does not advance onto the ack: at most 15 requests in flight).

module bow_dphy_rx_regs import bow_bus_pkg::*; #(
  parameter int unsigned Lanes        = 2,
  parameter int unsigned LpClkHz      = 200_000_000,
  parameter int unsigned AfeKind      = 1,
  parameter int unsigned AfeSettleNs  = 107,
  parameter int unsigned AfeSettleUi  = 24,
  parameter int unsigned AfeTrailB    = 0,
  parameter bit          AfePdRst     = 1'b0,         // AFE_CTRL.PD after reset
  parameter int unsigned ReinitCycles = 32,           // cal_start_o pulse, bus clock cycles
  parameter int unsigned EvcW         = 4,            // bits of the event counters
  parameter int unsigned NumAgg       = 7             // event kinds summed over the lanes
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  input  bus_req_t              bus_req_i,
  output bus_rsp_t              bus_rsp_o,
  output logic                  irq_o,

  // configuration (shadow registers, bus clock flops) and its copy into the lp domain
  output logic                  clk_cont_o,       // CTRL.CLK_CONT
  output logic                  des_rst_en_o,     // ~CTRL.DES_RST_DIS
  output logic                  ulps_en_o,        // CTRL.ULPS_EN
  output logic                  hsrx_early_o,     // CTRL.HSRX_EARLY
  output logic                  clk_lost_en_o,    // CTRL.CLK_LOST_EN
  output logic                  miss_off_o,       // CTRL.CLK_MISS_OFF
  output logic [7:0]            settle_o,         // TIM0
  output logic [3:0]            lp_filter_o,
  output logic [7:0]            clk_settle_o,
  output logic [7:0]            clk_miss_o,
  output logic [23:0]           hs_tmo_o,         // TIM1
  output logic [3:0]            tog_div_o,
  output logic [19:0]           tinit_o,          // TIM2
  output logic [11:0]           esc_tmo_o,
  output logic                  apply_req_o,      // toggle: CMD.APPLY
  input  logic                  apply_ack_i,      // synchronised acknowledge (toggle)
  output logic                  reinit_o,         // pulse: CMD.REINIT
  output logic                  rdy_up_o,         // pulse: READY rose
  // AFE controls (bus clock flops, asynchronous for the AFE)
  output logic                  cal_start_o,      // CMD.AFE_CAL pulse
  output logic                  pd_o,             // AFE_CTRL.PD
  output logic                  lprx_en_o,        // ~AFE_CTRL.PD
  output logic [Lanes:0]        lane_pd_o,        // [0] clock lane, [1 + l] data lane l
  output logic [Lanes-1:0][8:0] dly_code_o,       // DLYn CODE
  output logic [Lanes-1:0]      dly_own_o,        // DLYn OWN
  output logic [3:0]            raw_req_o,        // gray
  output logic                  raw_now_o,
  input  logic [3:0]            raw_ack_i,        // synchronised
  output logic                  raw_re_o,         // RAW RAM read port (data one cycle later)
  output logic [5:0]            raw_addr_o,
  input  logic [8*Lanes-1:0]    raw_rdata_i,

  // event counters of the lp domain (gray, synchronised): [0] clock lane, [1 + l] data lane l
  input  logic [Lanes:0][EvcW-1:0]  evc_hs_i,     // HS entries
  input  logic [Lanes:0][EvcW-1:0]  evc_err_i,    // LP sequence errors / HS watchdog
  input  logic [NumAgg-1:0][EvcW-1:0] evc_agg_i,  // HS_TMO, ESC, ESC_TMO, CLK_LOST, LATE_EOT,
                                                  // ULPS entries, ULPS exits

  // status (synchronised)
  input  logic [Lanes:0][1:0]   lp_i,             // filtered LP {P, N}, same order
  input  logic [Lanes:0]        hs_en_i,          // HS receivers on, same order
  input  logic                  ce_i,             // byte clock gate open
  input  logic [Lanes:0]        stop_i,           // Stopstate, same order
  input  logic [Lanes:0]        ulps_i,           // in ULPS until LP-11 (RxUlpsEsc), same order
  input  logic [Lanes:0]        ulps_act_i,       // ULPS before the wake-up mark, same order
  input  logic                  ready_i,          // AFE ready
  input  logic                  cal_done_i,       // AFE internal calibration done
  input  logic                  cal_err_i,        // ... and failed
  input  logic [7:0]            afe_status_i,     // raw AFE status
  input  logic [19:0]           meter_i,          // byte clock cycle counter, gray
  input  logic [Lanes-1:0][8:0] dly_q_i           // AFE dly_q: the delays in use
);

  localparam int unsigned MaxLanes = 4;
  localparam int unsigned DlyW     = 9;
  // "DPR" and the version of the register map in [7:0]: 1 in steps 4 and 5, 2 since step 6
  // (CMD[1] became REINIT, CTRL / TIM0 need CMD.APPLY): the driver refuses another version
  localparam logic [31:0] DphyId   = 32'h4450_5202;

  if (Lanes > MaxLanes) begin : g_bad_lanes
    $error("bow_dphy_rx_regs: Lanes %0d > %0d", Lanes, MaxLanes);
  end
  if ((ReinitCycles == 0) || (ReinitCycles > 32)) begin : g_bad_reinit
    $error("bow_dphy_rx_regs: ReinitCycles %0d not in 1..32", ReinitCycles);
  end
  if (NumAgg != 7) begin : g_bad_agg
    $error("bow_dphy_rx_regs: NumAgg %0d, the map has 7 summed event kinds", NumAgg);
  end

  localparam int unsigned AggTmo = 0, AggEsc = 1, AggEscTmo = 2, AggLost = 3, AggLate = 4,
                          AggUlps = 5, AggWake = 6;

  localparam int unsigned LpMhzR = (LpClkHz + 500_000) / 1_000_000;
  localparam logic [9:0]  LpMhz  = (LpMhzR > 1023) ? 10'd1023 : 10'(LpMhzR);
  localparam logic [31:0] Info   = {4'h0, 1'b1, 3'h0, (AfeKind == 2), 1'b0, 4'(DlyW), LpMhz,
                                    3'(AfeKind), 1'b0, 4'(Lanes)};
  localparam logic [31:0] Info2  = {8'h00, 8'(AfeTrailB), 8'(AfeSettleUi), 8'(AfeSettleNs)};

  localparam int unsigned IrqErr  = 0;
  localparam int unsigned IrqUlps = 1;
  localparam int unsigned IrqRaw  = 3;
  localparam logic [3:0]  IrqMask = 4'b1011;

  // ERR_STATUS bits
  localparam int unsigned ErrControl = 2, ErrHsTmo = 3, ErrEsc = 4, ErrClkLost = 6,
                          ErrLateEot = 7, ErrEscTmo = 10;
  localparam logic [10:0] ErrMask = 11'b100_1101_1100;

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

  function automatic logic [EvcW-1:0] g2b(logic [EvcW-1:0] g);
    logic [EvcW-1:0] b;
    b[EvcW-1] = g[EvcW-1];
    for (int i = EvcW - 2; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
    return b;
  endfunction

  // ------------------------------------------- CTRL, CMD, TIM0..2 (shadow registers)
  logic        clk_cont_q, burst_rst_en_q, ulps_en_q, hsrx_early_q, clk_lost_en_q, miss_off_q;
  logic        reinit_q, reinit_cmd_q;
  logic [4:0]  reinit_cnt_q;
  logic [7:0]  settle_q, clk_settle_q, clk_miss_q;
  logic [3:0]  lp_filter_q, tog_div_q;
  logic [23:0] hs_tmo_q;
  logic [19:0] tinit_q;
  logic [11:0] esc_tmo_q;
  logic [31:0] ctrl_rd, tim0_rd, tim1_rd, tim2_rd, ctrl_w, tim0_w, tim1_w, tim2_w;
  logic        cnt_clr, cmd_w;

  localparam logic [4:0] ReinitLast = 5'(ReinitCycles - 1);

  assign ctrl_rd = {15'h0, miss_off_q, 8'h00, clk_lost_en_q, ~burst_rst_en_q, 2'b00,
                    hsrx_early_q, ulps_en_q, clk_cont_q, 1'b0};
  assign tim0_rd = {clk_miss_q, clk_settle_q, 4'h0, lp_filter_q, settle_q};
  assign tim1_rd = {4'h0, tog_div_q, hs_tmo_q};
  assign tim2_rd = {esc_tmo_q, tinit_q};
  assign ctrl_w  = wmerge(ctrl_rd, wd, bm);
  assign tim0_w  = wmerge(tim0_rd, wd, bm);
  assign tim1_w  = wmerge(tim1_rd, wd, bm);
  assign tim2_w  = wmerge(tim2_rd, wd, bm);
  assign cmd_w   = we0 && (a == 10'h010);
  assign cnt_clr = cmd_w && wd[3];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      clk_cont_q     <= 1'b0;
      burst_rst_en_q <= 1'b1;
      ulps_en_q      <= 1'b0;
      hsrx_early_q   <= 1'b0;
      clk_lost_en_q  <= 1'b0;
      miss_off_q     <= 1'b0;
      reinit_q       <= 1'b0;
      reinit_cnt_q   <= '0;
      reinit_cmd_q   <= 1'b0;
      settle_q       <= 8'd14;
      lp_filter_q    <= 4'd2;
      clk_settle_q   <= 8'd30;
      clk_miss_q     <= 8'd8;
      hs_tmo_q       <= 24'h10_0000;
      tog_div_q      <= 4'd0;
      tinit_q        <= 20'd0;
      esc_tmo_q      <= 12'd0;
    end else begin
      if (we && (a == 10'h00C)) begin
        clk_cont_q     <= ctrl_w[1];
        ulps_en_q      <= ctrl_w[2];
        hsrx_early_q   <= ctrl_w[3];
        burst_rst_en_q <= ~ctrl_w[6];
        clk_lost_en_q  <= ctrl_w[7];
        miss_off_q     <= ctrl_w[16];
      end
      if (we && (a == 10'h024)) begin
        settle_q     <= tim0_w[7:0];
        lp_filter_q  <= tim0_w[11:8];
        clk_settle_q <= tim0_w[23:16];
        clk_miss_q   <= tim0_w[31:24];
      end
      if (we && (a == 10'h028)) begin
        hs_tmo_q  <= tim1_w[23:0];
        tog_div_q <= tim1_w[27:24];
      end
      if (we && (a == 10'h02C)) begin
        tinit_q   <= tim2_w[19:0];
        esc_tmo_q <= tim2_w[31:20];
      end
      // AFE_CAL: cal_start_o high for ReinitCycles cycles (a new AFE_CAL restarts it)
      if (cmd_w && wd[2]) begin
        reinit_q     <= 1'b1;
        reinit_cnt_q <= ReinitLast;
      end else if (reinit_cnt_q != 5'd0) begin
        reinit_cnt_q <= reinit_cnt_q - 5'd1;
      end else begin
        reinit_q <= 1'b0;
      end
      // REINIT: one cycle towards the lp domain
      reinit_cmd_q <= cmd_w && wd[1];
    end
  end

  assign clk_cont_o    = clk_cont_q;
  assign des_rst_en_o  = burst_rst_en_q;
  assign ulps_en_o     = ulps_en_q;
  assign hsrx_early_o  = hsrx_early_q;
  assign clk_lost_en_o = clk_lost_en_q;
  assign miss_off_o    = miss_off_q;
  assign cal_start_o   = reinit_q;
  assign reinit_o      = reinit_cmd_q;
  assign settle_o      = settle_q;
  assign lp_filter_o   = lp_filter_q;
  assign clk_settle_o  = clk_settle_q;
  assign clk_miss_o    = clk_miss_q;
  assign hs_tmo_o      = hs_tmo_q;
  assign tog_div_o     = tog_div_q;
  assign tinit_o       = tinit_q;
  assign esc_tmo_o     = esc_tmo_q;

  // APPLY: toggle towards the lp domain; pending until its acknowledge comes back; an APPLY
  // while pending is done after it (apply_again_q). DIRTY (dirty_q): a shadow register was
  // written since the last APPLY toggle (the write wins over a toggle in the same cycle).
  logic apply_q, apply_again_q, apply_pend, apply_cmd, apply_send, dirty_q, shadow_w;

  assign apply_pend = (apply_q != apply_ack_i) || apply_again_q;
  assign apply_cmd  = cmd_w && wd[0];
  assign apply_send = (apply_q == apply_ack_i) && (apply_cmd || apply_again_q);
  assign shadow_w   = we && (bus_req_i.be != 4'b0000) &&
                      ((a == 10'h00C) || (a == 10'h024) || (a == 10'h028) || (a == 10'h02C));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      apply_q       <= 1'b0;
      apply_again_q <= 1'b0;
    end else if (apply_q != apply_ack_i) begin
      apply_again_q <= apply_again_q || apply_cmd;
    end else if (apply_cmd || apply_again_q) begin
      apply_q       <= ~apply_q;
      apply_again_q <= 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         dirty_q <= 1'b0;
    else if (shadow_w)   dirty_q <= 1'b1;
    else if (apply_send) dirty_q <= 1'b0;
  end

  assign apply_req_o = apply_q;

  // READY rising: T_INIT due again
  logic ready_last_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ready_last_q <= 1'b0;
    else         ready_last_q <= ready_i;
  end

  assign rdy_up_o = ready_i && !ready_last_q;

  // ----------------------------------------------------------------- AFE_CTRL
  // PD (pd_o), lprx_en_o = ~PD and lane_pd_o, flops (every AFE control comes from a flop, no
  // logic after it). lane_pd falls only on a fresh READY: READY seen 0 since PD last rose
  // (rdy_low_q; 1 from reset), then READY 1 with PD = 0 (lane_pd_q, the rule). ready_i comes
  // through two flops and still reads 1 for a few cycles after PD rises: a PD pulse that
  // short must not release lane_pd on that stale READY, the AFE restarts after any PD pulse
  // (section 3.6 of the spec). An AFE that keeps ready at 1 through pd (against section 3.2:
  // the UltraScale+ adapter, which has neither pd nor lane_pd) leaves lane_pd at 1 after a PD
  // pulse. Per lane (lane_pdl_q), lane_pd is also 1 while the lane is in ULPS before its
  // wake-up mark (v1.x).
  logic           pd_q, pd_d, lprx_en_q, lane_pd_q, lane_pd_d, rdy_low_q;
  logic [Lanes:0] lane_pdl_q;
  logic [31:0]    afe_ctrl_rd, afe_ctrl_w;

  assign afe_ctrl_rd = {31'h0, pd_q};
  assign afe_ctrl_w  = wmerge(afe_ctrl_rd, wd, bm);
  assign pd_d        = (we && (a == 10'h014)) ? afe_ctrl_w[0] : pd_q;
  assign lane_pd_d   = pd_d || (lane_pd_q && !(ready_i && rdy_low_q));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pd_q       <= AfePdRst;
      lprx_en_q  <= !AfePdRst;
      lane_pd_q  <= 1'b1;
      lane_pdl_q <= '1;
      rdy_low_q  <= 1'b1;
    end else begin
      pd_q       <= pd_d;
      lprx_en_q  <= !pd_d;
      rdy_low_q  <= (pd_d && !pd_q) ? 1'b0 : (rdy_low_q || !ready_i);   // PD rises: wait again
      lane_pd_q  <= lane_pd_d;
      lane_pdl_q <= {(Lanes + 1){lane_pd_d}} | ulps_act_i;
    end
  end

  assign pd_o      = pd_q;
  assign lprx_en_o = lprx_en_q;
  assign lane_pd_o = lane_pdl_q;

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

  // ------------------------------------------------- event counters of the lp domain
  // The difference of each gray counter to its value of the cycle before (the counter
  // steps at most once per lp cycle and fewer than 16 times per bus cycle)
  logic [Lanes:0][EvcW-1:0]    hs_last_q, err_last_q, d_hs, d_err;
  logic [NumAgg-1:0][EvcW-1:0] agg_last_q, d_agg;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hs_last_q  <= '0;
      err_last_q <= '0;
      agg_last_q <= '0;
    end else begin
      hs_last_q  <= evc_hs_i;
      err_last_q <= evc_err_i;
      agg_last_q <= evc_agg_i;
    end
  end

  always_comb begin
    for (int unsigned i = 0; i <= Lanes; i++) begin
      d_hs[i]  = g2b(evc_hs_i[i]) - g2b(hs_last_q[i]);
      d_err[i] = g2b(evc_err_i[i]) - g2b(err_last_q[i]);
    end
    for (int unsigned k = 0; k < NumAgg; k++) d_agg[k] = g2b(evc_agg_i[k]) - g2b(agg_last_q[k]);
  end

  // ----------------------------------------------------- interrupts and errors
  logic [3:0]        irq_set, irq_status_q, irq_en_q;
  logic [31:0]       irq_en_w;
  logic [10:0]       err_set, err_status_q;
  logic [MaxLanes:0] lane_err, err_lane_q;     // [0] clock lane, [1 + l] data lane l
  logic [31:0]       err_lane_rd, err_lane_clr;

  always_comb begin
    lane_err = '0;
    for (int unsigned i = 0; i <= Lanes; i++) lane_err[i] = (d_err[i] != '0);
    err_set             = '0;
    err_set[ErrControl] = |lane_err;
    err_set[ErrHsTmo]   = (d_agg[AggTmo] != '0);
    err_set[ErrEsc]     = (d_agg[AggEsc] != '0);
    err_set[ErrClkLost] = (d_agg[AggLost] != '0);
    err_set[ErrLateEot] = (d_agg[AggLate] != '0);
    err_set[ErrEscTmo]  = (d_agg[AggEscTmo] != '0);
    irq_set             = '0;
    irq_set[IrqErr]     = |err_set;
    irq_set[IrqUlps]    = (d_agg[AggUlps] != '0) || (d_agg[AggWake] != '0);
    irq_set[IrqRaw]     = raw_fin;
  end

  // ERR_LANE: [8 + l] data lane l, [16] clock lane
  assign err_lane_rd  = {15'h0, err_lane_q[0], 4'h0, err_lane_q[MaxLanes:1], 8'h00};
  assign err_lane_clr = wd & bm & {32{we && (a == 10'h048)}};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      irq_status_q <= '0;
      irq_en_q     <= '0;
      err_status_q <= '0;
      err_lane_q   <= '0;
    end else begin
      irq_status_q <= (irq_status_q & ~(wd[3:0] & bm[3:0] & {4{we && (a == 10'h03C)}})) |
                      irq_set;
      err_status_q <= (err_status_q & ~(wd[10:0] & bm[10:0] & {11{we && (a == 10'h044)}})) |
                      err_set;
      err_lane_q   <= (err_lane_q & ~{err_lane_clr[11:8], err_lane_clr[16]}) | lane_err;
      if (we && (a == 10'h040)) irq_en_q <= irq_en_w[3:0] & IrqMask;
    end
  end

  assign irq_en_w = wmerge({28'h0, irq_en_q}, wd, bm);
  assign irq_o    = |(irq_status_q & irq_en_q);

  // ------------------------------------------------------------------ counters
  function automatic logic [31:0] add32(logic [31:0] c, logic [7:0] n);
    logic [32:0] s;
    s = {1'b0, c} + {25'd0, n};
    return s[32] ? 32'hFFFF_FFFF : s[31:0];
  endfunction

  function automatic logic [15:0] add16(logic [15:0] c, logic [7:0] n);
    logic [16:0] s;
    s = {1'b0, c} + {9'd0, n};
    return s[16] ? 16'hFFFF : s[15:0];
  endfunction

  logic [MaxLanes-1:0][31:0] cnt_burst_q;
  logic [31:0]               cnt_clk_q, cnt_lperr_q;
  logic [15:0]               cnt_misc_q, cnt_ulps_q;
  logic [7:0]                n_err, n_misc;

  always_comb begin
    n_err = '0;
    for (int unsigned i = 0; i <= Lanes; i++) n_err = n_err + 8'(d_err[i]);
    n_misc = 8'(d_agg[AggTmo]) + 8'(d_agg[AggLost]) + 8'(d_agg[AggLate]) +
             8'(d_agg[AggEscTmo]);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cnt_burst_q <= '0;
      cnt_clk_q   <= '0;
      cnt_lperr_q <= '0;
      cnt_misc_q  <= '0;
      cnt_ulps_q  <= '0;
    end else if (cnt_clr) begin
      cnt_burst_q <= '0;
      cnt_clk_q   <= '0;
      cnt_lperr_q <= '0;
      cnt_misc_q  <= '0;
      cnt_ulps_q  <= '0;
    end else begin
      cnt_clk_q   <= add32(cnt_clk_q, 8'(d_hs[0]));
      cnt_lperr_q <= add32(cnt_lperr_q, n_err);
      cnt_misc_q  <= add16(cnt_misc_q, n_misc);
      cnt_ulps_q  <= add16(cnt_ulps_q, 8'(d_agg[AggUlps]));
      for (int unsigned l = 0; l < Lanes; l++) begin
        cnt_burst_q[l] <= add32(cnt_burst_q[l], 8'(d_hs[1 + l]));
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
  logic [MaxLanes:0]           hs5, stop5, ulps5;
  logic [MaxLanes-1:0][31:0]   dly_rd;
  logic [31:0]                 rdata_d, rdata_q;
  logic                        rvalid_q, sel_raw_q;

  always_comb begin
    lp5    = '0;
    hs5    = '0;
    stop5  = '0;
    ulps5  = '0;
    dly_rd = '0;
    for (int unsigned l = 0; l <= Lanes; l++) begin
      lp5[l]   = lp_i[l];
      hs5[l]   = hs_en_i[l];
      stop5[l] = stop_i[l];
      ulps5[l] = ulps_i[l];
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
      10'h010: rdata_d = {dirty_q, 30'h0, apply_pend};
      10'h014: rdata_d = afe_ctrl_rd;
      10'h018: rdata_d = {16'h0, afe_status_i, 5'h0, cal_err_i, cal_done_i, ready_i};
      10'h024: rdata_d = tim0_rd;
      10'h028: rdata_d = tim1_rd;
      10'h02C: rdata_d = tim2_rd;
      10'h030: rdata_d = {22'h0, lp5};
      10'h034: rdata_d = {13'h0, (byteclk_q != '0), ce_i, ce_i, 11'h0, hs5};
      10'h038: rdata_d = {11'h0, ulps5, 11'h0, stop5};
      10'h03C: rdata_d = {28'h0, irq_status_q};
      10'h040: rdata_d = {28'h0, irq_en_q};
      10'h044: rdata_d = {21'h0, err_status_q & ErrMask};
      10'h048: rdata_d = err_lane_rd;
      10'h04C: rdata_d = {12'h0, byteclk_q};
      10'h050: rdata_d = cnt_burst_q[0];
      10'h054: rdata_d = cnt_burst_q[1];
      10'h058: rdata_d = cnt_burst_q[2];
      10'h05C: rdata_d = cnt_burst_q[3];
      10'h070: rdata_d = cnt_clk_q;
      10'h074: rdata_d = cnt_lperr_q;
      10'h078: rdata_d = {cnt_ulps_q, 16'h0};
      10'h07C: rdata_d = {cnt_misc_q, 16'h0};
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
  assign unused_bus = ^{bus_req_i.addr[31:10], bus_req_i.addr[1:0], ctrl_w[31:17],
                        ctrl_w[15:8], ctrl_w[5:4], ctrl_w[0], tim0_w[15:12], tim1_w[31:28],
                        irq_en_w[31:4], err_lane_clr[31:17], err_lane_clr[15:12],
                        err_lane_clr[7:0], afe_ctrl_w[31:1], unused_dly};

  always_comb begin
    unused_dly = 1'b0;
    for (int unsigned l = 0; l < Lanes; l++) unused_dly ^= ^dly_w[l][31:DlyW];
  end

endmodule
