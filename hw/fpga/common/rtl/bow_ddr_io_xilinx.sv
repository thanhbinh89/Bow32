// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// DDR2/DDR3 pads of the Bow32 DDR IP (bow_ddr) on AMD UltraScale+ (component
// mode I/O primitives, no memory IP): the board level half of bow_ddr_phy.
// The behavioural twin for Verilator is hw/ip/ddr/dv/bow_ddr_io_sim.sv.
//
//   clk_i (ddr_clk) -----> ODDRE1 D1=ck_en  D2=0 ------------------> OBUF ---> CK_P (CK_N: ~)
//   cmd[j-1], cmd[j] ----> ODDRE1 D1=prev  D2=cur (C = clk_i) -----> OBUF ---> CKE ODT CS# RAS#
//                                                                              CAS# WE# BA A (RESET#)
//   dqs[j] --(lb mux)-> FDRE (~clk_i) -> ODDRE1 D1=dqs[0] D2=dqs[1] (C = wclk) -> IOBUF <--> DQS_P (N: ~)
//   dq[j], dm[j] (lb mux)> ODDRE1 D1=dq[0] D2=dq[1] (C = ~wclk90) -> IOBUF <--> DQ, DM (OBUFT)
//   dq_oe, dqs_oe -------> FDRE (clk_i, one per pad) ----------------> IOBUF.T
//   ls_oe_n, ls_dir_* ---> ODDRE1 D1=D2=value (C = clk_i) ----------> OBUF ---> OE#, DIR (shifters)
//   io_i.dq/dqs <-------- IDDRE1 SAME_EDGE_PIPELINED (C = rd_clk, CB = ~rd_clk) <-- IOBUF.O
//
// Timing contract (bow_ddr_pkg header, T = CK period, write phase 0; DQS, DQ
// and DM move with the write phase of wclk_i/wclk90_i):
//   * ODDRE1 (UltraScale+) samples D1/D2 at the rising edge of C and drives D1
//     while C is high, D2 while C is low, no extra latency. A value presented
//     by the PHY in ddr_clk cycle j (launched at jT) is sampled at (j+1)T.
//   * ck_en, dqs, dqs_oe, dq, dm, dq_oe, ls_*: on the pins in pin cycle j+1
//     = [(j+1)T, (j+2)T). CK_P = ck_en in the first half, 0 in the second.
//   * DQS: the value is first taken by flops on the falling edge of clk_i
//     ((j+0.5)T, a T/2 path from the PHY, DQS_N flops hold the complement),
//     the ODDRE1 on wclk_i samples them at (j+1)T + write phase. Without this
//     stage the PHY -> ODDR path would have to stay between T/4 (hold at write
//     phase +T/4) and 3T/4 (setup at -T/4) over all process corners, which
//     place and route cannot meet (route delays differ ~2x between corners):
//     the flop -> ODDR path is now T/2 + write phase (T/4 at -T/4) and needs
//     no minimum delay. A write phase of up to about +-T/2 still samples the
//     right DQS value; static timing covers +-T/4 (board XDC: clock
//     uncertainty T/4 from ddr_clk to the write clocks). DQ (below) leaves
//     its window above about +T/4 + PHY register delay.
//     With TFromOddr (Versal) this stage (data and T) runs on the falling edge
//     of wclk_i instead ((j+0.5)T + write phase): on the xcvp1902 a fabric
//     flop sees its clock ~1 ns (after pessimism removal) later than the XPIO
//     ODDR, which left the flop -> ODDR crossing with its T/4 write phase
//     uncertainty 0.5..0.75 ns short (Huins build, 2026-11-09). Now the
//     crossing with the uncertainty is PHY register -> stage, between fabric
//     flops (a path of at most T/4, the ddr_clk / ddr_wclk trees balanced by
//     the board XDC), and stage -> ODDR is a T/2 path within ddr_wclk.
//   * DQ/DM: C = wclk90_i inverted (IS_C_INVERTED), i.e. sampled at (j+0.75)T
//     straight from the PHY registers (a 3T/4 path, no retiming flop):
//     dq[0] is on the pin during [(j+0.75)T, (j+1.25)T), centred on the DQS
//     rising edge (j+1)T, dq[1] during [(j+1.25)T, (j+1.75)T).
//   * cke, rst_n, odt, cs_n, ras_n, cas_n, we_n, ba, a: D1 = value of cycle
//     j-1 (cmd_prev_q), D2 = value of cycle j, so the value of cycle j is on
//     the pin from (j+1.5)T to (j+2.5)T, centred on CK rising edge j+2.
//   * Output enables (TFromOddr = 0, UltraScale+): an ODDRE1 driving IOBUF.T
//     is not placed at the pin on UltraScale+, so T comes from fabric flops on
//     clk_i (KEEP: one per DQ / DM pad, one per DQS pair, each next to its
//     I/O): the driver switches at the start of pin cycle j+1 plus the flop ->
//     pad delay (MPS4 card, LVCMOS15: ~5.4 ns, ~2.5 ns more than the ODDR data
//     path); the PHY keeps oe = 1 from the preamble through the postamble.
//   * Output enables (TFromOddr = 1, Versal XPIO): T must come from a TDDR in
//     the site of the pad (DRC PDCN-2749), which shares the clock of the
//     pad's data ODDR: one more ODDRE1 per pad (u_toddr*) drives IOBUF.T
//     (SRVAL = 1: not driving after configuration).
//       DQ / DM: C = ~wclk90_i like the data, D1 = ~oe of cycle j-1 (one
//       flop on clk_i), D2 = ~oe of cycle j: the driver switches at
//       (j+1.25)T + write phase, half a beat into the data slot of cycle j
//       (0.5T before the first beat after the preamble cycle; the release
//       after the postamble comes 1.5T after the last beat).
//       DQS_P / DQS_N: C = wclk_i, D1 = D2 = ~dqs_oe retimed on the falling
//       edge of wclk_i (like the DQS data): the driver switches at (j+1)T +
//       write phase, with the first DQS value of the cycle.
//     Against the level shifter windows (DIR moves at (j+1)T + pad delay):
//     the release comes (OE_PRE - 0.25)T - write phase before DIR turns to
//     read, the drive returns (OE_POST + 0.25)T + write phase after DIR turns
//     back (DQS: OE_PRE * T - phase, OE_POST * T + phase). With the card
//     defaults (OE_PRE 1, OE_POST 2) and the write phase limit +-T/4, at least
//     0.5T / 2T (DQ) and 0.75T / 1.75T (DQS).
//   * Read capture: IDDRE1 SAME_EDGE_PIPELINED on rd_clk_i (CB = rd_clk_i
//     with IS_CB_INVERTED, an unconnected CB freezes Q2): io_i_o.dq[0] = sample
//     at rd_clk rising edge k, dq[1] = sample at the following falling edge,
//     both after rising edge k+1. DQS_P is captured the same way (io_i_o.dqs).
// Idle levels: every ODDRE1 has SR = 0 and SRVAL = the idle level, which the
// pin keeps after configuration until the clock runs: CS#, RAS#, CAS#, WE#,
// CK_N, DQS_N, OE# 1; CK_P, CKE, ODT, RESET#, BA, A, DQ, DQS_P, DM 0; DIR the
// write level. The T flops (T ODDRs) start at 1 (not driving).
//
// Loopback = 1 (on-chip DRAM emulator bow_ddr_lb behind the pads): DQ/DQS/DM
// are always driven (T = 0); while lb_en_i the ODDR data come from lb_dq_i /
// lb_dqs_i (same timing as io_o_i) and the IDDRs read them back through the
// pads; OE# is held at 1 and DIR at the write level. In loopback DQ lags DQS
// by T/4 (both use the write clocks).
// LsDirReadLevel: level of the shifter DIR pins in the read direction
// (io_o_i.ls_dir_* = 1); 1 for the FMC+_DDR2_HyperRam card (TXV0108 DIR = H:
// A -> B = DRAM -> FPGA).
// CkSingleEnded = 1: CK_P/CK_N are two single ended outputs (the card goes
// through level shifters); 0: one ODDRE1 into an OBUFDS.
// Unused pads of a configuration (dm_o without HasDm, rst_n_o without
// HasResetN, ls_*_o without HasLs) are tied to their idle level without a
// buffer: leave them unconnected in the board top.
// IO standards and pins are set in the board XDC (MPS4: constr/ddr_*.xdc,
// Huins VP1902: hw/fpga/huins_vp1902/constr/ddr_card.xdc).
// UltraScale+: Vivado implements ODDRE1 as OSERDESE3 (XDC filters: REF_NAME
// == OSERDESE3); Versal keeps ODDRE1 / IDDRE1 (XPIOLOGIC sites). Instance
// names u_oddr*, u_toddr*, u_iddr, g_t_phy.*_t_q are used by the XDC.
// SimDevice: SIM_DEVICE of the ODDRE1s ("ULTRASCALE_PLUS"; Versal Premium:
// "VERSAL_PREMIUM").

module bow_ddr_io_xilinx import bow_ddr_pkg::*; #(
  parameter int unsigned DqBits         = 8,
  parameter int unsigned Lanes          = DqBits / 8,
  parameter int unsigned AddrPins       = 14,
  parameter int unsigned BankPins       = 2,
  parameter bit          HasDm          = 1'b0,
  parameter bit          HasResetN      = 1'b0,
  parameter bit          HasLs          = 1'b1,
  parameter bit          CkSingleEnded  = 1'b1,
  parameter bit          Loopback       = 1'b0,
  parameter bit          LsDirReadLevel = 1'b1,
  parameter bit          TFromOddr      = 1'b0,   // 1: T from an ODDRE1 in the pad site (Versal)
  parameter              SimDevice      = "ULTRASCALE_PLUS"
) (
  input  logic                     clk_i,      // ddr_clk: CK, commands, T, level shifters
  input  logic                     wclk_i,     // write clock (DQS)
  input  logic                     wclk90_i,   // write clock + T/4 (DQ, DM; inverted)
  input  logic                     rd_clk_i,   // read capture clock
  input  ddr_io_out_t              io_o_i,     // from bow_ddr_phy, clk_i domain
  output ddr_io_in_t               io_i_o,     // to bow_ddr_phy, rd_clk_i domain
  // loopback emulator (Loopback = 1), clk_i domain, io_o_i timing
  input  logic                     lb_en_i,
  input  logic [1:0][MaxDq-1:0]    lb_dq_i,
  input  logic [MaxLanes-1:0][1:0] lb_dqs_i,
  // pads
  output wire                      ck_p_o,
  output wire                      ck_n_o,
  output wire                      cke_o,
  output wire                      rst_n_o,
  output wire                      odt_o,
  output wire                      cs_n_o,
  output wire                      ras_n_o,
  output wire                      cas_n_o,
  output wire                      we_n_o,
  output wire  [BankPins-1:0]      ba_o,
  output wire  [AddrPins-1:0]      a_o,
  inout  wire  [DqBits-1:0]        dq_io,
  inout  wire  [Lanes-1:0]         dqs_p_io,
  inout  wire  [Lanes-1:0]         dqs_n_io,
  output wire  [Lanes-1:0]         dm_o,
  output wire                      ls_oe_n_o,
  output wire                      ls_dir_dq_o,
  output wire                      ls_dir_dqs_o
);

  // ---------------------------------------------------------------------------
  // Command / address group: ODDRE1 on clk_i, D1 = previous, D2 = current
  // ---------------------------------------------------------------------------
  // Bit order of the group: {a, ba, we_n, cas_n, ras_n, cs_n, odt, cke}; RESET#
  // is a separate ODDRE1 (HasResetN).
  localparam int unsigned CmdBits = 6 + BankPins + AddrPins;
  localparam logic [CmdBits-1:0] CmdIdle = {{AddrPins{1'b0}}, {BankPins{1'b0}}, 4'b1111, 2'b00};

  logic [CmdBits-1:0] cmd_cur;
  logic [CmdBits-1:0] cmd_prev_q = CmdIdle;
  logic               rst_n_prev_q = 1'b0;
  wire  [CmdBits-1:0] cmd_pad;

  assign cmd_cur = {io_o_i.a[AddrPins-1:0], io_o_i.ba[BankPins-1:0], io_o_i.we_n, io_o_i.cas_n,
                    io_o_i.ras_n, io_o_i.cs_n, io_o_i.odt, io_o_i.cke};

  always_ff @(posedge clk_i) begin
    cmd_prev_q   <= cmd_cur;
    rst_n_prev_q <= io_o_i.rst_n;
  end

  for (genvar i = 0; i < CmdBits; i++) begin : g_cmd
    logic q;

    ODDRE1 #(
      .SIM_DEVICE (SimDevice),
      .SRVAL      (CmdIdle[i])
    ) u_oddr (
      .C  (clk_i),
      .D1 (cmd_prev_q[i]),
      .D2 (cmd_cur[i]),
      .SR (1'b0),
      .Q  (q)
    );

    OBUF u_obuf (
      .I (q),
      .O (cmd_pad[i])
    );
  end

  assign cke_o   = cmd_pad[0];
  assign odt_o   = cmd_pad[1];
  assign cs_n_o  = cmd_pad[2];
  assign ras_n_o = cmd_pad[3];
  assign cas_n_o = cmd_pad[4];
  assign we_n_o  = cmd_pad[5];
  assign ba_o    = cmd_pad[6 +: BankPins];
  assign a_o     = cmd_pad[6 + BankPins +: AddrPins];

  if (HasResetN) begin : g_rst_n
    logic q;

    ODDRE1 #(
      .SIM_DEVICE (SimDevice),
      .SRVAL      (1'b0)
    ) u_oddr (
      .C  (clk_i),
      .D1 (rst_n_prev_q),
      .D2 (io_o_i.rst_n),
      .SR (1'b0),
      .Q  (q)
    );

    OBUF u_obuf (
      .I (q),
      .O (rst_n_o)
    );
  end else begin : g_no_rst_n
    assign rst_n_o = 1'b0;
  end

  // ---------------------------------------------------------------------------
  // CK: ODDRE1 on clk_i, D1 = ck_en, D2 = 0
  // ---------------------------------------------------------------------------
  logic ck_p_q;

  ODDRE1 #(
    .SIM_DEVICE (SimDevice),
    .SRVAL      (1'b0)
  ) u_ck_p_oddr (
    .C  (clk_i),
    .D1 (io_o_i.ck_en),
    .D2 (1'b0),
    .SR (1'b0),
    .Q  (ck_p_q)
  );

  if (CkSingleEnded) begin : g_ck_se
    logic ck_n_q;

    ODDRE1 #(
      .SIM_DEVICE (SimDevice),
      .SRVAL      (1'b1)
    ) u_ck_n_oddr (
      .C  (clk_i),
      .D1 (~io_o_i.ck_en),
      .D2 (1'b1),
      .SR (1'b0),
      .Q  (ck_n_q)
    );

    OBUF u_ck_p_obuf (
      .I (ck_p_q),
      .O (ck_p_o)
    );

    OBUF u_ck_n_obuf (
      .I (ck_n_q),
      .O (ck_n_o)
    );
  end else begin : g_ck_diff
    OBUFDS u_ck_obufds (
      .I  (ck_p_q),
      .O  (ck_p_o),
      .OB (ck_n_o)
    );
  end

  // ---------------------------------------------------------------------------
  // Write data path (+ loopback emulator mux)
  // ---------------------------------------------------------------------------
  logic                     lb_sel;
  logic [1:0][MaxDq-1:0]    dq_d;
  logic [MaxLanes-1:0][1:0] dqs_d;

  assign lb_sel = Loopback && lb_en_i;
  assign dq_d   = lb_sel ? lb_dq_i  : io_o_i.dq;
  assign dqs_d  = lb_sel ? lb_dqs_i : io_o_i.dqs;

  // Output enables: T = 1 releases the pad. UltraScale+ (g_t_phy): one flop
  // per pad, kept apart so that each can sit next to its I/O (no equivalent
  // register merging); they start at 1 after configuration. Versal
  // (g_t_oddr): the T ODDRs of g_dq / g_dqs / g_dm, fed by dq_oe_prev (dq_oe
  // of the previous cycle) and io_o_i directly.
  logic [DqBits-1:0] dq_t;
  logic [Lanes-1:0]  dqs_t, dm_t;
  logic              dq_oe_prev;

  if (Loopback) begin : g_t_lb
    assign dq_t       = '0;
    assign dqs_t      = '0;
    assign dm_t       = '0;
    assign dq_oe_prev = 1'b0;
  end else if (TFromOddr) begin : g_t_oddr
    logic oe_prev_q = 1'b0;

    always_ff @(posedge clk_i) begin
      oe_prev_q <= io_o_i.dq_oe;
    end

    assign dq_oe_prev = oe_prev_q;
    assign dq_t       = '1;   // not used: the T ODDRs drive the pads
    assign dqs_t      = '1;
    assign dm_t       = '1;
  end else begin : g_t_phy
    (* keep = "true" *) logic [DqBits-1:0] dq_t_q  = '1;
    (* keep = "true" *) logic [Lanes-1:0]  dqs_t_q = '1;
    (* keep = "true" *) logic [Lanes-1:0]  dm_t_q  = '1;

    always_ff @(posedge clk_i) begin
      dq_t_q  <= {DqBits{~io_o_i.dq_oe}};
      dqs_t_q <= ~io_o_i.dqs_oe[Lanes-1:0];
      dm_t_q  <= {Lanes{~io_o_i.dq_oe}};
    end

    assign dq_t       = dq_t_q;
    assign dqs_t      = dqs_t_q;
    assign dm_t       = dm_t_q;
    assign dq_oe_prev = 1'b0;
  end

  // DQ: ODDRE1 on ~wclk90, IOBUF, IDDRE1 on rd_clk
  for (genvar i = 0; i < DqBits; i++) begin : g_dq
    logic q, din, t;

    ODDRE1 #(
      .IS_C_INVERTED (1'b1),
      .SIM_DEVICE    (SimDevice),
      .SRVAL         (1'b0)
    ) u_oddr (
      .C  (wclk90_i),
      .D1 (dq_d[0][i]),
      .D2 (dq_d[1][i]),
      .SR (1'b0),
      .Q  (q)
    );

    if (TFromOddr && !Loopback) begin : g_toddr
      // TDDR of the pad site: clocked like the data ODDR, D1 = previous oe
      ODDRE1 #(
        .IS_C_INVERTED (1'b1),
        .SIM_DEVICE    (SimDevice),
        .SRVAL         (1'b1)
      ) u_toddr (
        .C  (wclk90_i),
        .D1 (~dq_oe_prev),
        .D2 (~io_o_i.dq_oe),
        .SR (1'b0),
        .Q  (t)
      );
    end else begin : g_tfab
      assign t = dq_t[i];
    end

    IOBUF u_iobuf (
      .I  (q),
      .T  (t),
      .O  (din),
      .IO (dq_io[i])
    );

    IDDRE1 #(
      .DDR_CLK_EDGE   ("SAME_EDGE_PIPELINED"),
      .IS_CB_INVERTED (1'b1),
      .IS_C_INVERTED  (1'b0)
    ) u_iddr (
      .C  (rd_clk_i),
      .CB (rd_clk_i),
      .D  (din),
      .R  (1'b0),
      .Q1 (io_i_o.dq[0][i]),
      .Q2 (io_i_o.dq[1][i])
    );
  end

  if (DqBits < MaxDq) begin : g_dq_unused
    assign io_i_o.dq[0][MaxDq-1:DqBits] = '0;
    assign io_i_o.dq[1][MaxDq-1:DqBits] = '0;
  end

  // DQS: half cycle retiming flops (falling edge of clk_i; TFromOddr: of
  // wclk_i, see the header), ODDRE1 on wclk, DQS_N the complement; DQS_P
  // captured by an IDDRE1
  logic dqs_rt_clk;

  if (TFromOddr) begin : g_rt_wclk
    assign dqs_rt_clk = wclk_i;
  end else begin : g_rt_clk
    assign dqs_rt_clk = clk_i;
  end

  for (genvar l = 0; l < Lanes; l++) begin : g_dqs
    logic qp, qn, din, tp, tn;
    logic [1:0] dqs_p_q = 2'b00;
    logic [1:0] dqs_n_q = 2'b11;

    always_ff @(negedge dqs_rt_clk) begin
      dqs_p_q <= dqs_d[l];
      dqs_n_q <= ~dqs_d[l];
    end

    ODDRE1 #(
      .SIM_DEVICE (SimDevice),
      .SRVAL      (1'b0)
    ) u_oddr_p (
      .C  (wclk_i),
      .D1 (dqs_p_q[0]),
      .D2 (dqs_p_q[1]),
      .SR (1'b0),
      .Q  (qp)
    );

    ODDRE1 #(
      .SIM_DEVICE (SimDevice),
      .SRVAL      (1'b1)
    ) u_oddr_n (
      .C  (wclk_i),
      .D1 (dqs_n_q[0]),
      .D2 (dqs_n_q[1]),
      .SR (1'b0),
      .Q  (qn)
    );

    if (TFromOddr && !Loopback) begin : g_toddr
      // TDDRs of the two pad sites: ~dqs_oe through the falling edge stage of
      // the DQS data (wclk_i), then D1 = D2 on wclk
      logic t_q = 1'b1;

      always_ff @(negedge dqs_rt_clk) begin
        t_q <= ~io_o_i.dqs_oe[l];
      end

      ODDRE1 #(
        .SIM_DEVICE (SimDevice),
        .SRVAL      (1'b1)
      ) u_toddr_p (
        .C  (wclk_i),
        .D1 (t_q),
        .D2 (t_q),
        .SR (1'b0),
        .Q  (tp)
      );

      ODDRE1 #(
        .SIM_DEVICE (SimDevice),
        .SRVAL      (1'b1)
      ) u_toddr_n (
        .C  (wclk_i),
        .D1 (t_q),
        .D2 (t_q),
        .SR (1'b0),
        .Q  (tn)
      );
    end else begin : g_tfab
      assign tp = dqs_t[l];
      assign tn = dqs_t[l];
    end

    IOBUF u_iobuf_p (
      .I  (qp),
      .T  (tp),
      .O  (din),
      .IO (dqs_p_io[l])
    );

    IOBUF u_iobuf_n (
      .I  (qn),
      .T  (tn),
      .O  (),
      .IO (dqs_n_io[l])
    );

    IDDRE1 #(
      .DDR_CLK_EDGE   ("SAME_EDGE_PIPELINED"),
      .IS_CB_INVERTED (1'b1),
      .IS_C_INVERTED  (1'b0)
    ) u_iddr (
      .C  (rd_clk_i),
      .CB (rd_clk_i),
      .D  (din),
      .R  (1'b0),
      .Q1 (io_i_o.dqs[0][l]),
      .Q2 (io_i_o.dqs[1][l])
    );
  end

  if (Lanes < MaxLanes) begin : g_dqs_unused
    assign io_i_o.dqs[0][MaxLanes-1:Lanes] = '0;
    assign io_i_o.dqs[1][MaxLanes-1:Lanes] = '0;
  end

  // DM: like DQ, output only (driven together with DQ)
  if (HasDm) begin : g_dm
    for (genvar l = 0; l < Lanes; l++) begin : g_lane
      logic q, dm1, dm2, t;

      // the emulator never drives DM: 0 while it answers a read
      assign dm1 = io_o_i.dm[0][l] & ~lb_sel;
      assign dm2 = io_o_i.dm[1][l] & ~lb_sel;

      ODDRE1 #(
        .IS_C_INVERTED (1'b1),
        .SIM_DEVICE    (SimDevice),
        .SRVAL         (1'b0)
      ) u_oddr (
        .C  (wclk90_i),
        .D1 (dm1),
        .D2 (dm2),
        .SR (1'b0),
        .Q  (q)
      );

      if (TFromOddr && !Loopback) begin : g_toddr
        // TDDR of the pad site, like DQ
        ODDRE1 #(
          .IS_C_INVERTED (1'b1),
          .SIM_DEVICE    (SimDevice),
          .SRVAL         (1'b1)
        ) u_toddr (
          .C  (wclk90_i),
          .D1 (~dq_oe_prev),
          .D2 (~io_o_i.dq_oe),
          .SR (1'b0),
          .Q  (t)
        );
      end else begin : g_tfab
        assign t = dm_t[l];
      end

      OBUFT u_obuft (
        .I (q),
        .T (t),
        .O (dm_o[l])
      );
    end
  end else begin : g_no_dm
    assign dm_o = '0;
  end

  // ---------------------------------------------------------------------------
  // Level shifter control: ODDRE1 on clk_i with D1 = D2 (pin cycle j+1)
  // ---------------------------------------------------------------------------
  localparam logic DirWrite = ~LsDirReadLevel;

  if (HasLs && !Loopback) begin : g_ls
    logic [2:0] ls_d, ls_q;
    wire  [2:0] ls_pad;
    localparam logic [2:0] LsIdle = {DirWrite, DirWrite, 1'b1};

    assign ls_d = {io_o_i.ls_dir_dqs ^ DirWrite, io_o_i.ls_dir_dq ^ DirWrite, io_o_i.ls_oe_n};

    for (genvar i = 0; i < 3; i++) begin : g_pin
      ODDRE1 #(
        .SIM_DEVICE (SimDevice),
        .SRVAL      (LsIdle[i])
      ) u_oddr (
        .C  (clk_i),
        .D1 (ls_d[i]),
        .D2 (ls_d[i]),
        .SR (1'b0),
        .Q  (ls_q[i])
      );

      OBUF u_obuf (
        .I (ls_q[i]),
        .O (ls_pad[i])
      );
    end

    assign ls_oe_n_o    = ls_pad[0];
    assign ls_dir_dq_o  = ls_pad[1];
    assign ls_dir_dqs_o = ls_pad[2];
  end else begin : g_ls_const
    // Loopback: shifters isolated (OE# = 1), DIR at the write level.
    assign ls_oe_n_o    = 1'b1;
    assign ls_dir_dq_o  = DirWrite;
    assign ls_dir_dqs_o = DirWrite;
  end

  // ---------------------------------------------------------------------------
  // Unused inputs of a configuration
  // ---------------------------------------------------------------------------
  logic unused;
  assign unused = ^{io_o_i.a, io_o_i.ba, io_o_i.dq, io_o_i.dqs, io_o_i.dqs_oe, io_o_i.dm,
                    io_o_i.rst_n, io_o_i.ls_oe_n, io_o_i.ls_dir_dq, io_o_i.ls_dir_dqs,
                    io_o_i.dq_oe, lb_en_i, lb_dq_i, lb_dqs_i, dq_d, dqs_d, dm_t, rst_n_prev_q,
                    dq_t, dqs_t, dq_oe_prev};

endmodule
