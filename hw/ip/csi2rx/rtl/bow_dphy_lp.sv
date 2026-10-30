// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// MIPI D-PHY receive lane, LP side (video clock domain, one per lane):
// synchronises and filters the two LP receiver levels and runs the HS
// entry / exit state machine that switches the HS receiver and its 100 ohm
// termination (hs_en_o) and, for the clock lane, the byte clock gate (ce_o).
//
//   Off --en--> WaitStop --LP-11--> Stop --LP-01--> HsRqst --LP-00--> Settle --settle_i--> Hs
//                  ^                 |  ^             |  |              |                   |
//                  +---- LP-10/00 ---+  +---- LP-11 --+  |              +--- LP-11: Stop ---+
//                  +------------------------- LP-10 -----+
//
// * hs_en_o is on from the LP-00 that follows LP-01 (Settle) until LP-11.
//   LP-01 / LP-10 while in HS are ignored (the LP receivers see LP-00).
// * Data lane: hs_active_o (search for the sync byte) in Hs. A lane longer
//   than 2^20 cycles in Hs is an error (watchdog), the receiver turns off
//   and waits for LP-11.
// * Clock lane (ClockLane = 1): Settle counts settle_i (CLK_SETTLE), then
//   the byte clock gate opens (ce_o = hs_active_o = 1) while the lane is in
//   the static HS-0 of T_CLK-ZERO. Once a byte clock edge was seen
//   (clk_edge_i), miss_i cycles without one (CLK_MISS, 0 = never) close the
//   gate during the static HS-0 of T_CLK-TRAIL: state Trail, receiver still
//   on, until LP-11. LP-11 with the gate open (backstop) closes the gate
//   first and turns the receiver off two cycles later. force_hs_i
//   (continuous clock) keeps hs_en_o = ce_o = 1 whatever the state while
//   en_i = 1. There is no watchdog on the clock lane.
// * en_i = 0: the gate closes at once, the receiver 8 cycles later (Off).
//
// Glitch filter: lp_o takes a new level once it was seen filter_i
// consecutive cycles (0 counts as 1). LP-00 at the pin -> hs_en_o takes
// 2 (synchroniser) + filter_i + 1 (state machine) cycles.
// All outputs are flops.

module bow_dphy_lp #(
  parameter bit ClockLane = 1'b0
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       en_i,         // PHY_EN (and lane in use), synchronised
  input  logic       force_hs_i,   // CLK_FORCE (clock lane only)
  input  logic [7:0] settle_i,     // data: PHY_CFG.SETTLE, clock: PHY_CFG.CLK_SETTLE
  input  logic [3:0] filter_i,     // PHY_CFG.LP_FILTER
  input  logic [7:0] miss_i,       // clock lane: PHY_CFG.CLK_MISS
  input  logic       clk_edge_i,   // clock lane: a byte clock edge was seen this cycle
  input  logic [1:0] lp_i,         // {P, N}, asynchronous
  output logic [1:0] lp_o,         // filtered LP state
  output logic       hs_en_o,
  output logic       hs_active_o,
  output logic       ce_o,
  output logic       ev_hs_o,      // pulse: HS entry
  output logic       ev_err_o      // pulse: unexpected LP sequence / watchdog
);

  localparam logic [1:0] Lp00 = 2'b00;
  localparam logic [1:0] Lp01 = 2'b01;
  localparam logic [1:0] Lp10 = 2'b10;
  localparam logic [1:0] Lp11 = 2'b11;

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
  typedef enum logic [3:0] {
    Off,
    WaitStop,
    Stop,
    HsRqst,
    Settle,
    Hs,
    Trail,     // clock lane: clock stopped, gate closed, receiver still on
    Exit,      // clock lane: LP-11 with the gate open, receiver off 2 cycles later
    Disable    // en_i = 0: gate closed, receiver off 8 cycles later
  } state_e;

  state_e      state_q, state_d;
  logic [19:0] tmr_q, tmr_d;     // down counter (Settle, Exit, Disable, clock miss) or watchdog
  logic        seen_q, seen_d;   // clock lane: a byte clock edge was seen in this Hs
  logic        hs_en_q, ce_q, act_q;
  logic        hs_en_d, ce_d, act_d;
  logic        ev_hs_d, ev_err_d;
  logic        force_hs;

  assign force_hs = ClockLane && force_hs_i && en_i;

  always_comb begin
    state_d  = state_q;
    tmr_d    = tmr_q;
    seen_d   = seen_q;
    ev_hs_d  = 1'b0;
    ev_err_d = 1'b0;

    if (!en_i && (state_q != Off) && (state_q != Disable)) begin
      state_d = hs_en_q ? Disable : Off;
      tmr_d   = 20'd7;
    end else begin
      unique case (state_q)
        Off: begin
          if (en_i) state_d = WaitStop;
        end
        WaitStop: begin
          if (lp_q == Lp11) state_d = Stop;
        end
        Stop: begin
          if (lp_q == Lp01) begin
            state_d = HsRqst;
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
          end else if (&tmr_q) begin
            state_d  = WaitStop;     // watchdog
            ev_err_d = 1'b1;
          end else begin
            tmr_d = tmr_q + 20'd1;
          end
        end
        Trail: begin
          if (lp_q == Lp11) state_d = Stop;
        end
        Exit, Disable: begin
          if (tmr_q == 20'd0) state_d = (state_q == Exit) ? Stop : Off;
          else                tmr_d   = tmr_q - 20'd1;
        end
        default: state_d = Off;
      endcase
    end

    // Moore outputs of the next state: the output flops have no extra stage
    hs_en_d = force_hs || (state_d inside {Settle, Hs, Trail, Exit, Disable});
    ce_d    = ClockLane && (force_hs || (state_d == Hs));
    act_d   = ClockLane ? ce_d : (state_d == Hs);
  end

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

  assign hs_en_o     = hs_en_q;
  assign ce_o        = ce_q;
  assign hs_active_o = act_q;

`ifdef VERILATOR
  // Two-state simulators (see bow_rstmgr): the clock lane starts with the
  // gate open (and so the receiver on) until the reset pulse, which then
  // gives the ISERDES reset synchroniser in bow_csi2rx (asynchronous input =
  // gate open) a real falling edge.
  initial begin
    ce_q    = ClockLane;
    hs_en_q = ClockLane;
  end
`endif

endmodule
