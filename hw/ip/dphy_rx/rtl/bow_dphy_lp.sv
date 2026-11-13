// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MIPI D-PHY receive lane, LP side (lp clock domain, one per lane): synchronises and filters
// the two LP receiver levels and runs the lane state machine of docs/ip/mipi_rx_arch.md
// (sections 4.2, 4.3, 4.4, 4.8): HS entry and exit, which switch the HS receiver (hs_en_o)
// and the 100 ohm termination (term_en_o) and, for the clock lane, the byte clock gate
// (ce_o); since step 6 (v1.x) also T_INIT, the programmable HS watchdog, escape mode entry
// with the ULPS command, and ULPS.
//
//   Off --en--> WaitStop --LP-11--> Stop --LP-01--> HsRqst --LP-00--> Settle --settle_i--> Hs
//                  ^                 |  ^             |  |              |                   |
//                  +---- LP-10/00 ---+  +---- LP-11 --+  |              +--- LP-11: Stop ---+
//                  +------------------------- LP-10 -----+
//   v1.x, ulps_en_i = 1 (CTRL.ULPS_EN; else LP-10 in Stop is an LP error as before):
//     data lane   Stop --LP-10--> EscRqst --LP-00--> EscGo --LP-01--> EscCmd (8 command bits)
//                 --ULPS--> Ulps --LP-10--> UlpsExit --LP-11--> Stop (LP-00: back to Ulps);
//                 another command: EscWait --LP-11--> Stop
//     clock lane  Stop --LP-10--> EscRqst --LP-00--> Ulps --LP-10--> UlpsExit --LP-11--> Stop
//
// * HS receiver and termination: on from the LP-00 that follows LP-01 (Settle) until LP-11.
//   LP-01 / LP-10 while in HS are ignored (the LP receivers see LP-00). hsrx_early_i
//   (CTRL.HSRX_EARLY, v1.x): the HS receiver already from HS-Rqst (LP-01), for an AFE whose
//   HS receiver starts slowly; the termination still from LP-00.
// * Data lane: hs_active_o (search for the sync byte) in Hs. HS watchdog (HS_TMO, v1.x):
//   a lane hs_tmo_i cycles in Hs (TIM1.HS_TMO, reset 2^20 = the fixed watchdog of v1; 0 =
//   none) is an LP error (ev_err_o, as in v1) and an HS timeout (ev_tmo_o); the receiver
//   turns off and waits for LP-11.
// * Clock lane (ClockLane = 1): Settle counts settle_i (CLK_SETTLE), then the byte clock
//   gate opens (ce_o = hs_active_o = 1) while the lane is in the static HS-0 of
//   T_CLK-ZERO. Once a byte clock edge was seen (clk_edge_i), miss_i cycles without one
//   (CLK_MISS, 0 = never) close the gate during the static HS-0 of T_CLK-TRAIL: state
//   Trail, receiver still on until LP-11, or, with miss_off_i (CTRL.CLK_MISS_OFF, v1.x),
//   receiver and termination off at once with the gate (T_CLK-MISS). LP-11 with the gate
//   open (backstop) closes the gate first and turns the receiver off two cycles later.
//   force_hs_i (continuous clock) keeps hs_en_o = term_en_o = ce_o = 1 whatever the state
//   while en_i = 1. There is no watchdog on the clock lane.
// * en_i = 0: the gate closes at once, the receiver 8 cycles later (Off).
// * The receiver of the clock lane never turns off before the gate (the HS receiver output of
//   an AFE may stop at once, cutting a byte clock pulse that the synchronous gate has not
//   closed on yet): only after it (Exit, Disable) or together with it once the clock stopped
//   (the clock miss of CLK_MISS_OFF).
// * T_INIT (v1.x): tinit_set_i (the AFE's ready rose, or CMD.REINIT) makes T_INIT due once:
//   the next time the lane goes from WaitStop to Stop, the line must have been LP-11 for
//   tinit_i cycles in a row (TIM2.T_INIT; 0 = at once, as in v1). An HS request in WaitStop
//   is ignored (no error), so a sensor that holds LP-11 shorter than that loses its first
//   burst. It is due once only: Enable alone (stop / start) never makes it due again.
//   force_wait_i (CMD.REINIT, or ready rising while T_INIT != 0) sends an enabled lane back
//   to WaitStop from any state; a clock lane in Hs (gate open: its clock may still run)
//   goes there through Exit (the gate closes first, the receiver two cycles later;
//   exit_wait_q: then WaitStop, not Stop), one in Exit finishes it first.
// * Escape mode and ULPS (v1.x, ulps_en_i): the entry LP-11, LP-10, LP-00, LP-01, LP-00, then
//   8 command bits in spaced one-hot code (each bit a mark, LP-01 for 0, LP-10 for 1,
//   followed by a space, LP-00; first bit on the wire first) [S18]. Command ULPS (EscUlps):
//   the lane is in ULPS (ulps_o: PPI RxUlpsEsc, ~RxUlpsClkNot) until LP-11 ends the wake-up
//   (Stop). ulps_act_o (ULPS active: PPI ~UlpsActiveNot, and the AFE's lane_pd) falls at the
//   wake-up mark LP-10 (the AFE's HS part powers up while the transmitter holds the mark for
//   at least T_WAKEUP) and rises again if the mark ends in LP-00 instead of LP-11 (a stray
//   LP-10: the lane is still in ULPS). Another command
//   (LPDT, triggers: not supported) is an escape error (ev_esc_o); the lane waits for LP-11.
//   LP-11 during the entry or the command cancels the escape mode without an error. A wrong
//   LP sequence in it (LP-01 right after LP-10, LP-10 after LP-10 LP-00, a mark followed by
//   the other mark instead of a space) is an LP error (ev_err_o). ESC_TMO (esc_tmo_i,
//   TIM2[31:20] in 64 cycle units, 0 = none): from LP-10 until the command is decoded at most
//   that long, else an escape timeout (ev_esc_tmo_o) and back to WaitStop. The clock lane
//   enters ULPS with LP-10, LP-00 (no command) and leaves it like a data lane. ulps_en_i = 0
//   while a lane is in one of these states sends it to Off (then WaitStop: a fresh LP-11).
//   ev_ulps_o at the ULPS entry, ev_wake_o at the LP-11 that ends it.
// * des_rst_o (clock lane, AFE des_rst, docs/ip/mipi_rx_arch.md section 3.2): the
//   inverse of the gate, a flop of its own that changes at the same edge as ce_o (1 when
//   the gate closes or at reset, 0 at the edge that opens it); held at 0 while
//   des_rst_en_i = 0 (CTRL.DES_RST_DIS = 1, a test bit). Data lanes: always 1, no flop.
//
// Glitch filter: lp_o takes a new level once it was seen filter_i
// consecutive cycles (0 counts as 1). LP-00 at the pin -> hs_en_o takes
// 2 (synchroniser) + filter_i + 1 (state machine) cycles.
// All outputs are flops, except stop_o (PPI Stopstate), ulps_o and ulps_act_o, decoded
// from the state register: levels for logic on clk_i only.
//
// Every v1.x input at its reset value (hsrx_early_i, miss_off_i, ulps_en_i 0, hs_tmo_i 2^20,
// esc_tmo_i, tinit_i 0, tinit_set_i, force_wait_i 0) gives the state machine of v1 (step 5):
// the registers of v1 have the same next state functions (Formality, hw/ip/dphy_rx/fm,
// STEP=6), the new ones (term_q, the upper timer bits, the escape decoder, the T_INIT flag,
// exit_wait_q and the new event flops) only add outputs.

module bow_dphy_lp #(
  parameter bit ClockLane = 1'b0
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        en_i,          // PHY_EN (and lane in use), synchronised
  input  logic        force_hs_i,    // CLK_CONT (clock lane only)
  input  logic [7:0]  settle_i,      // data: TIM0.SETTLE, clock: TIM0.CLK_SETTLE
  input  logic [3:0]  filter_i,      // TIM0.LP_FILTER
  input  logic [7:0]  miss_i,        // clock lane: TIM0.CLK_MISS
  input  logic        clk_edge_i,    // clock lane: a byte clock edge was seen this cycle
  input  logic        des_rst_en_i,  // clock lane: des_rst_o follows the gate (~CTRL.DES_RST_DIS)
  input  logic        hsrx_early_i,  // CTRL.HSRX_EARLY: HS receiver from HS-Rqst (v1.x)
  input  logic        miss_off_i,    // clock lane: CTRL.CLK_MISS_OFF (v1.x)
  input  logic        ulps_en_i,     // CTRL.ULPS_EN: escape mode entry, ULPS (v1.x)
  input  logic [23:0] hs_tmo_i,      // data lane: TIM1.HS_TMO, cycles in Hs (0: none)
  input  logic [11:0] esc_tmo_i,     // TIM2.ESC_TMO, 64 cycle units (0: none)
  input  logic [19:0] tinit_i,       // TIM2.T_INIT, cycles of LP-11 (0: none)
  input  logic        tinit_set_i,   // pulse: T_INIT due again (ready rose, CMD.REINIT)
  input  logic        force_wait_i,  // pulse: back to WaitStop (CMD.REINIT)
  input  logic [1:0]  lp_i,          // {P, N}, asynchronous
  output logic [1:0]  lp_o,          // filtered LP state
  output logic        hs_en_o,       // HS receiver
  output logic        term_en_o,     // termination
  output logic        hs_active_o,
  output logic        ce_o,
  output logic        des_rst_o,     // clock lane: ~ce_o (same edge) while des_rst_en_i, else 0
  output logic        ev_hs_o,       // pulse: HS entry
  output logic        ev_err_o,      // pulse: unexpected LP sequence / HS watchdog
  output logic        ev_tmo_o,      // pulse: HS watchdog (HS_TMO; with ev_err_o)
  output logic        ev_esc_o,      // pulse: escape command other than ULPS
  output logic        ev_esc_tmo_o,  // pulse: escape timeout (ESC_TMO)
  output logic        ev_ulps_o,     // pulse: ULPS entered
  output logic        ev_wake_o,     // pulse: ULPS left (the LP-11 after the wake-up mark)
  output logic        stop_o,        // the lane is in Stop (PPI Stopstate)
  output logic        ulps_o,        // the lane is in ULPS, until LP-11 (RxUlpsEsc, ~RxUlpsClkNot)
  output logic        ulps_act_o     // ... before the wake-up mark (~UlpsActiveNot, lane_pd)
);

  localparam logic [1:0] Lp00 = 2'b00;
  localparam logic [1:0] Lp01 = 2'b01;
  localparam logic [1:0] Lp10 = 2'b10;
  localparam logic [1:0] Lp11 = 2'b11;

  // escape mode entry command of ULPS, first bit on the wire in bit 7 [S18]
  localparam logic [7:0] EscUlps = 8'b0001_1110;

  // ---------------------------------------------------------- LP levels
  logic [1:0] lp_s, lp_last_q, lp_q;
  logic [3:0] run_q, run, flt;

  bow_sync #(.ResetValue (1'b1)) u_sync_p (.clk_i, .rst_ni, .d_i (lp_i[1]), .q_o (lp_s[1]));
  bow_sync #(.ResetValue (1'b1)) u_sync_n (.clk_i, .rst_ni, .d_i (lp_i[0]), .q_o (lp_s[0]));

  // run: number of consecutive cycles in which lp_s had its current value
  assign flt = (filter_i == 4'd0) ? 4'd1 : filter_i;
  assign run = (lp_s != lp_last_q) ? 4'd1 : (run_q == 4'hF) ? 4'hF : run_q + 4'd1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lp_last_q <= Lp11;
      run_q     <= 4'hF;
      lp_q      <= Lp11;
    end else begin
      lp_last_q <= lp_s;
      run_q     <= run;
      if (run >= flt) lp_q <= lp_s;
    end
  end

  assign lp_o = lp_q;

  // ------------------------------------------------------ state machine
  // (the values of the v1 states are those of v1: Off .. Disable)
  typedef enum logic [3:0] {
    Off,
    WaitStop,
    Stop,
    HsRqst,
    Settle,
    Hs,
    Trail,     // clock lane: clock stopped, gate closed, receiver on (off with CLK_MISS_OFF)
    Exit,      // clock lane: LP-11 with the gate open, receiver off 2 cycles later
    Disable,   // en_i = 0: gate closed, receiver off 8 cycles later
    EscRqst,   // v1.x: LP-10 seen in Stop (escape mode or, clock lane, ULPS request)
    EscGo,     // data lane: LP-00 after LP-10, waiting for LP-01
    EscCmd,    // data lane: the 8 command bits (marks and spaces)
    EscWait,   // data lane: a command other than ULPS, waiting for LP-11
    Ulps,      // ULPS
    UlpsExit   // ULPS wake-up mark (LP-10), waiting for LP-11
  } state_e;

  state_e      state_q, state_d;
  logic [19:0] tmr_q, tmr_d;     // down counter (Settle, Exit, Disable, clock miss) or up
                                 // counter (HS watchdog, T_INIT, escape timeout)
  logic [3:0]  tmr_hi_q, tmr_hi_d;   // HS watchdog: bits 23:20 of the counter (v1.x)
  logic        seen_q, seen_d;   // clock lane: a byte clock edge was seen in this Hs
  logic        hs_en_q, ce_q, act_q, term_q;
  logic        hs_en_d, ce_d, act_d, term_d, hs_on, trail_on;
  logic        exit_wait_q, exit_wait_d;   // clock lane: Exit ends in WaitStop (CMD.REINIT)
  logic        ev_hs_d, ev_err_d, ev_tmo_d, ev_esc_d, ev_esc_tmo_d, ev_ulps_d, ev_wake_d;
  logic        force_hs;
  logic        pend_q, pend_d;   // T_INIT due (tinit_set_i), until the next Stop
  logic        tinit_cnt, tmo_hit, esc_tmo_hit;
  logic [7:0]  esc_sr_q, esc_sr_d;     // command bits received, first one in bit 7
  logic [3:0]  esc_cnt_q, esc_cnt_d;   // command bits received
  logic        esc_mark_q, esc_mark_d; // in a mark (the entry's LP-01 or a command bit)
  logic [1:0]  mark_lp;

  assign force_hs    = ClockLane && force_hs_i && en_i;
  assign tinit_cnt   = pend_q && (tinit_i != 20'd0);
  // (>=: a timeout that CMD.APPLY lowers below the running count fires at once)
  assign tmo_hit     = (hs_tmo_i != 24'd0) && ({tmr_hi_q, tmr_q} >= hs_tmo_i - 24'd1);
  assign esc_tmo_hit = (esc_tmo_i != 12'd0) && (tmr_q >= {2'b00, esc_tmo_i, 6'd0} - 20'd1);
  // the LP state of the mark in progress: the entry's LP-01, or the last command bit
  assign mark_lp     = (esc_cnt_q == 4'd0) ? Lp01 : (esc_sr_q[0] ? Lp10 : Lp01);

  always_comb begin
    state_d      = state_q;
    tmr_d        = tmr_q;
    tmr_hi_d     = tmr_hi_q;
    seen_d       = seen_q;
    ev_hs_d      = 1'b0;
    ev_err_d     = 1'b0;
    ev_tmo_d     = 1'b0;
    ev_esc_d     = 1'b0;
    ev_esc_tmo_d = 1'b0;
    ev_ulps_d    = 1'b0;
    ev_wake_d    = 1'b0;
    esc_sr_d     = esc_sr_q;
    esc_cnt_d    = esc_cnt_q;
    esc_mark_d   = esc_mark_q;
    exit_wait_d  = exit_wait_q && (state_q == Exit);

    if (!en_i && (state_q != Off) && (state_q != Disable)) begin
      state_d = hs_en_q ? Disable : Off;
      tmr_d   = 20'd7;
    end else if (force_wait_i && (state_q != Off) && (state_q != Disable)) begin
      // CMD.REINIT (v1.x): back to WaitStop; a clock lane with the gate open (its clock may
      // still run) through Exit: the gate closes first, the receiver two cycles later
      if (ClockLane && ((state_q == Hs) || (state_q == Exit))) begin
        state_d     = Exit;
        exit_wait_d = 1'b1;
        if (state_q != Exit) tmr_d = 20'd1;
      end else begin
        state_d = WaitStop;
      end
    end else begin
      unique case (state_q)
        Off: begin
          if (en_i) state_d = WaitStop;
        end
        WaitStop: begin
          if (tinit_cnt) begin
            // T_INIT (v1.x): tinit_i cycles of LP-11 in a row (tmr_q: those before this one)
            if (lp_q != Lp11)                  tmr_d   = 20'd0;
            else if (tmr_q >= tinit_i - 20'd1) state_d = Stop;
            else                               tmr_d   = tmr_q + 20'd1;
          end else if (lp_q == Lp11) begin
            state_d = Stop;
          end
        end
        Stop: begin
          if (lp_q == Lp01) begin
            state_d = HsRqst;
          end else if ((lp_q == Lp10) && ulps_en_i) begin
            state_d = EscRqst;       // escape mode entry (v1.x)
            tmr_d   = 20'd0;
          end else if (lp_q != Lp11) begin
            state_d  = WaitStop;     // escape mode entry, or LP-00 without request
            ev_err_d = 1'b1;
          end
        end
        HsRqst: begin
          if (lp_q == Lp00) begin
            state_d = Settle;
            tmr_d   = 20'(settle_i);
            ev_hs_d = 1'b1;
          end else if (lp_q == Lp11) begin
            state_d = Stop;
          end else if (lp_q == Lp10) begin
            state_d  = WaitStop;
            ev_err_d = 1'b1;
          end
        end
        Settle: begin
          if (lp_q == Lp11) begin
            state_d = Stop;
          end else if (tmr_q <= 20'd1) begin
            state_d = Hs;
            tmr_d   = ClockLane ? 20'(miss_i) : 20'd0;
            seen_d  = 1'b0;
            if (!ClockLane) tmr_hi_d = 4'd0;
          end else begin
            tmr_d = tmr_q - 20'd1;
          end
        end
        Hs: begin
          if (lp_q == Lp11) begin
            state_d = ClockLane ? Exit : Stop;
            tmr_d   = 20'd1;
          end else if (ClockLane) begin
            // clock miss: miss_i cycles without a byte clock edge
            if (clk_edge_i) begin
              seen_d = 1'b1;
              tmr_d  = 20'(miss_i);
            end else if (seen_q && (miss_i != 8'd0)) begin
              if (tmr_q <= 20'd1) state_d = Trail;
              else                tmr_d   = tmr_q - 20'd1;
            end
          end else if (tmo_hit) begin
            state_d  = WaitStop;     // watchdog (HS_TMO)
            ev_err_d = 1'b1;
            ev_tmo_d = 1'b1;
          end else begin
            {tmr_hi_d, tmr_d} = {tmr_hi_q, tmr_q} + 24'd1;
          end
        end
        Trail: begin
          if (lp_q == Lp11) state_d = Stop;
        end
        Exit, Disable: begin
          if (tmr_q == 20'd0) state_d = (state_q != Exit) ? Off : exit_wait_q ? WaitStop : Stop;
          else                tmr_d   = tmr_q - 20'd1;
        end
        // ---- v1.x: escape mode entry and ULPS (ulps_en_i; without it these states are
        // left for Off, as the unused state values of v1)
        EscRqst: begin
          if (!ulps_en_i) begin
            state_d = Off;
          end else if (lp_q == Lp11) begin
            state_d = Stop;          // cancelled
          end else if (esc_tmo_hit) begin
            state_d      = WaitStop;
            ev_esc_tmo_d = 1'b1;
          end else begin
            tmr_d = tmr_q + 20'd1;
            if (lp_q == Lp00) begin
              if (ClockLane) begin
                state_d   = Ulps;    // clock lane ULPS: LP-10, LP-00
                ev_ulps_d = 1'b1;
              end else begin
                state_d = EscGo;
              end
            end else if (lp_q == Lp01) begin
              state_d  = WaitStop;
              ev_err_d = 1'b1;
            end
          end
        end
        EscGo: begin
          if (!ulps_en_i) begin
            state_d = Off;
          end else if (lp_q == Lp11) begin
            state_d = Stop;
          end else if (esc_tmo_hit) begin
            state_d      = WaitStop;
            ev_esc_tmo_d = 1'b1;
          end else begin
            tmr_d = tmr_q + 20'd1;
            if (lp_q == Lp01) begin
              state_d    = EscCmd;   // the entry's mark: its space starts the command
              esc_cnt_d  = 4'd0;
              esc_mark_d = 1'b1;
            end else if (lp_q == Lp10) begin
              state_d  = WaitStop;
              ev_err_d = 1'b1;
            end
          end
        end
        EscCmd: begin
          if (!ulps_en_i) begin
            state_d = Off;
          end else if (lp_q == Lp11) begin
            state_d = Stop;          // escape mode left before the end of the command
          end else if (esc_tmo_hit) begin
            state_d      = WaitStop;
            ev_esc_tmo_d = 1'b1;
          end else begin
            tmr_d = tmr_q + 20'd1;
            if (esc_mark_q) begin
              if (lp_q == Lp00) begin
                esc_mark_d = 1'b0;   // the space after a mark
                if (esc_cnt_q == 4'd8) begin
                  if (esc_sr_q == EscUlps) begin
                    state_d   = Ulps;
                    ev_ulps_d = 1'b1;
                  end else begin
                    state_d  = EscWait;
                    ev_esc_d = 1'b1;
                  end
                end
              end else if (lp_q != mark_lp) begin
                state_d  = WaitStop; // a mark followed by the other one, no space
                ev_err_d = 1'b1;
              end
            end else if ((lp_q == Lp01) || (lp_q == Lp10)) begin
              esc_sr_d   = {esc_sr_q[6:0], (lp_q == Lp10)};
              esc_cnt_d  = esc_cnt_q + 4'd1;
              esc_mark_d = 1'b1;
            end
          end
        end
        EscWait: begin
          if (!ulps_en_i)        state_d = Off;
          else if (lp_q == Lp11) state_d = Stop;
        end
        Ulps: begin
          if (!ulps_en_i) begin
            state_d = Off;
          end else if (lp_q == Lp10) begin
            state_d = UlpsExit;      // wake-up mark: the HS part powers up again
          end else if (lp_q == Lp11) begin
            state_d   = Stop;
            ev_wake_d = 1'b1;
          end
        end
        UlpsExit: begin
          if (!ulps_en_i) begin
            state_d = Off;
          end else if (lp_q == Lp11) begin
            state_d   = Stop;        // the end of the wake-up
            ev_wake_d = 1'b1;
          end else if (lp_q == Lp00) begin
            state_d = Ulps;          // the mark ended without LP-11: still in ULPS
          end
        end
        default: state_d = Off;
      endcase
    end

    // T_INIT (v1.x): the count starts at 0 whenever a lane that has to count enters WaitStop
    // or is told to count again there
    if ((tinit_i != 20'd0) && (state_d == WaitStop) &&
        ((state_q != WaitStop) || tinit_set_i)) begin
      tmr_d = 20'd0;
    end

    // Moore outputs of the next state: the output flops have no extra stage
    trail_on = !(ClockLane && miss_off_i);
    hs_on    = force_hs || (state_d inside {Settle, Hs, Exit}) || ((state_d == Trail) && trail_on);
    hs_en_d  = hs_on || (state_d == Disable) || (hsrx_early_i && (state_d == HsRqst));
    term_d   = hs_on || ((state_d == Disable) && term_q);
    ce_d     = ClockLane && (force_hs || (state_d == Hs));
    act_d    = ClockLane ? ce_d : (state_d == Hs);
  end

  // T_INIT due from tinit_set_i until the lane reaches Stop
  assign pend_d = tinit_set_i || (pend_q && (state_d != Stop));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q  <= Off;
      tmr_q    <= '0;
      seen_q   <= 1'b0;
      hs_en_q  <= 1'b0;
      ce_q     <= 1'b0;
      act_q    <= 1'b0;
      ev_hs_o  <= 1'b0;
      ev_err_o <= 1'b0;
    end else begin
      state_q  <= state_d;
      tmr_q    <= tmr_d;
      seen_q   <= seen_d;
      hs_en_q  <= hs_en_d;
      ce_q     <= ce_d;
      act_q    <= act_d;
      ev_hs_o  <= ev_hs_d;
      ev_err_o <= ev_err_d;
    end
  end

  // v1.x registers
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tmr_hi_q     <= '0;
      term_q       <= 1'b0;
      exit_wait_q  <= 1'b0;
      pend_q       <= 1'b0;
      esc_sr_q     <= '0;
      esc_cnt_q    <= '0;
      esc_mark_q   <= 1'b0;
      ev_tmo_o     <= 1'b0;
      ev_esc_o     <= 1'b0;
      ev_esc_tmo_o <= 1'b0;
      ev_ulps_o    <= 1'b0;
      ev_wake_o    <= 1'b0;
    end else begin
      tmr_hi_q     <= tmr_hi_d;
      term_q       <= term_d;
      exit_wait_q  <= ClockLane && exit_wait_d;
      pend_q       <= pend_d;
      esc_sr_q     <= esc_sr_d;
      esc_cnt_q    <= esc_cnt_d;
      esc_mark_q   <= esc_mark_d;
      ev_tmo_o     <= ev_tmo_d;
      ev_esc_o     <= ev_esc_d;
      ev_esc_tmo_o <= ev_esc_tmo_d;
      ev_ulps_o    <= ev_ulps_d;
      ev_wake_o    <= ev_wake_d;
    end
  end

  assign hs_en_o     = hs_en_q;
  assign term_en_o   = term_q;
  assign ce_o        = ce_q;
  assign hs_active_o = act_q;
  assign stop_o      = (state_q == Stop);
  assign ulps_o      = (state_q == Ulps) || (state_q == UlpsExit);
  assign ulps_act_o  = (state_q == Ulps);

  // AFE des_rst: a Moore output of the next state too, so it falls at the very edge that
  // opens the gate and rises at the one that closes it
  if (ClockLane) begin : g_des_rst
    logic des_rst_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) des_rst_q <= 1'b1;
      else         des_rst_q <= !ce_d && des_rst_en_i;
    end

    assign des_rst_o = des_rst_q;

`ifdef VERILATOR
    // with the gate open until the reset pulse (below): des_rst then rises with a real
    // edge, which the receive path reset synchroniser of an adapter (asynchronous input)
    // needs in a two-state simulator
    initial des_rst_q = 1'b0;
`endif
  end else begin : g_no_des_rst
    assign des_rst_o = 1'b1;

    logic unused_des_rst;
    assign unused_des_rst = des_rst_en_i ^ miss_off_i;
  end

`ifdef VERILATOR
  // Two-state simulators (see bow_rstmgr): the clock lane starts with the
  // gate open (and so the receiver on) until the reset pulse, which then
  // gives the receive path reset synchroniser of the AFE adapter (des_rst_o,
  // asynchronous input) a real edge.
  initial begin
    ce_q    = ClockLane;
    hs_en_q = ClockLane;
    term_q  = ClockLane;
  end
`endif

endmodule
