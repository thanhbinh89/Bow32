// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// HyperRAM pads of the Bow32 HyperRAM IP (bow_hyperram) on AMD UltraScale+
// (component mode I/O primitives): the board half of bow_hyperram_phy. The
// behavioural twin for Verilator / xsim is hw/ip/hyperram/dv/bow_hyperram_io_sim.sv.
//
//   clk_i (hr_clk) ----> ODDRE1 D1=ck_en  D2=0 ---------------------> OBUF ---> CK_P (CK_N: ~)
//   cs_n, rst_n -------> ODDRE1 D1=D2=value (C = clk_i) ------------> OBUF ---> CS#, RESET#
//   dq[j], rwds[j] (lb mux) > ODDRE1 D1=[0] D2=[1] (C = ~wclk_i) ---> IOBUF <--> DQ[7:0], RWDS
//   dq_oe, rwds_oe ----> FDRE (clk_i, one per pad) -----------------> IOBUF.T
//   ls_oe_n, ls_dir_* -> ODDRE1 D1=D2=value (C = clk_i) ------------> OBUF ---> OE#, DIR (shifters)
//   io_i_o.dq / rwds <-- IDDRE1 SAME_EDGE_PIPELINED (C = rd_clk_i, CB = ~rd_clk_i) <-- IOBUF.O
//   rwds_pad_o <-------- IOBUF.O of RWDS (asynchronous: latency indication)
//
// Timing contract (bow_hyperram_pkg header; T = CK period, write phase 0):
//   * ODDRE1 (UltraScale+) samples D1/D2 at the rising edge of C, drives D1
//     while C is high, D2 while C is low. A value of PHY cycle j (launched at
//     jT on clk_i) is sampled at (j+1)T: CK_P high during [(j+1)T, (j+1.5)T)
//     when ck_en, CS# / RESET# / DIR / OE# during [(j+1)T, (j+2)T).
//   * DQ / RWDS: C = wclk_i inverted (IS_C_INVERTED); wclk_i = clk_i + T/4 at
//     write phase 0 (bow_hyperram_clk_xusp), so the ODDRE1 samples at (j+0.75)T,
//     a 3T/4 path from the PHY register: dq[0] on the pin during
//     [(j+0.75)T, (j+1.25)T), centred on the CK rising edge of pin cycle j+1,
//     dq[1] during [(j+1.25)T, (j+1.75)T). The write phase (the controller's
//     limit +-3T/16) moves the sample point within 9T/16 .. 15T/16: the board
//     XDC adds 3T/16 of uncertainty on the clk_i -> wclk_i paths (at +-T/4 the
//     hold margin at the ODDRE1 would be zero).
//   * Output enables: an ODDRE1 on IOBUF.T is not placed at the pin on
//     UltraScale+, so T comes from fabric flops on clk_i (KEEP, one per pad):
//     the driver switches at (j+1)T plus the flop -> pad delay.
//   * Read capture: IDDRE1 SAME_EDGE_PIPELINED on rd_clk_i (CB = rd_clk_i with
//     IS_CB_INVERTED): io_i_o.*[0] = sample at rd_clk rising edge k, *[1] =
//     sample at the following falling edge, both after rising edge k+1.
// Idle levels: every ODDRE1 has SR = 0 and SRVAL = the idle level, kept after
// configuration until the clock runs: CS#, CK_N, RESET#, OE# 1; CK_P, DQ, RWDS,
// DIR 0. The T flops start at 1 (not driving).
//
// Loopback = 1 (on-chip HyperRAM emulator bow_hyperram_dev behind the pads):
// DQ / RWDS always driven (T = 0); the DQ ODDR data come from lb_dq_i while
// lb_dq_en_i, the RWDS ODDR data from lb_rwds_i while lb_rwds_en_i (same
// timing as io_o_i), and the IDDRs read them back through the pads; OE# held
// at 1, DIR at 0.
// HasLs = 0 (direct board): the level shifter outputs are constants (OE# 1,
// DIR 0); leave them unconnected in the board top.
// IO standards and pins are set in the board XDC (MPS4: constr/hyperram_*.xdc).
// Vivado implements ODDRE1 as OSERDESE3 (XDC filters: REF_NAME == OSERDESE3).

module bow_hyperram_io_xilinx import bow_hyperram_pkg::*; #(
  parameter bit Loopback  = 1'b0,
  parameter bit HasLs     = 1'b1,
  parameter     SimDevice = "ULTRASCALE_PLUS"
) (
  input  logic            clk_i,       // hr_clk
  input  logic            wclk_i,      // write clock (DQ / RWDS ODDRs on ~wclk_i)
  input  logic            rd_clk_i,    // read capture clock
  input  hr_io_out_t      io_o_i,      // from bow_hyperram_phy, clk_i domain
  output hr_io_in_t       io_i_o,      // to bow_hyperram_phy, rd_clk_i domain
  output logic            rwds_pad_o,  // RWDS pad level (asynchronous)
  // loopback emulator (Loopback = 1), clk_i domain, io_o_i timing
  input  logic            lb_dq_en_i,
  input  logic [1:0][7:0] lb_dq_i,
  input  logic            lb_rwds_en_i,
  input  logic [1:0]      lb_rwds_i,
  // pads
  output wire             ck_p_o,
  output wire             ck_n_o,
  output wire             cs_n_o,
  output wire             rst_n_o,
  inout  wire  [7:0]      dq_io,
  inout  wire             rwds_io,
  output wire             ls_oe_n_o,
  output wire             ls_dir_dq_o,
  output wire             ls_dir_rwds_o
);

  // ---------------------------------------------------------------------------
  // CK: ODDRE1 on clk_i, D1 = ck_en, D2 = 0; CK_N the complement
  // ---------------------------------------------------------------------------
  logic ck_p_q, ck_n_q;

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

  OBUF u_ck_p_obuf (.I (ck_p_q), .O (ck_p_o));
  OBUF u_ck_n_obuf (.I (ck_n_q), .O (ck_n_o));

  // ---------------------------------------------------------------------------
  // CS#, RESET#: ODDRE1 on clk_i, D1 = D2
  // ---------------------------------------------------------------------------
  logic cs_n_q, rst_n_q;

  ODDRE1 #(
    .SIM_DEVICE (SimDevice),
    .SRVAL      (1'b1)
  ) u_cs_oddr (
    .C  (clk_i),
    .D1 (io_o_i.cs_n),
    .D2 (io_o_i.cs_n),
    .SR (1'b0),
    .Q  (cs_n_q)
  );

  ODDRE1 #(
    .SIM_DEVICE (SimDevice),
    .SRVAL      (1'b1)
  ) u_rst_oddr (
    .C  (clk_i),
    .D1 (io_o_i.rst_n),
    .D2 (io_o_i.rst_n),
    .SR (1'b0),
    .Q  (rst_n_q)
  );

  OBUF u_cs_obuf  (.I (cs_n_q),  .O (cs_n_o));
  OBUF u_rst_obuf (.I (rst_n_q), .O (rst_n_o));

  // ---------------------------------------------------------------------------
  // DQ / RWDS (+ loopback emulator mux)
  // ---------------------------------------------------------------------------
  logic            lb_dq, lb_rw;
  logic [1:0][7:0] dq_d;
  logic [1:0]      rw_d;

  assign lb_dq = Loopback && lb_dq_en_i;
  assign lb_rw = Loopback && lb_rwds_en_i;
  assign dq_d  = lb_dq ? lb_dq_i : io_o_i.dq;
  assign rw_d  = lb_rw ? lb_rwds_i : io_o_i.rwds;

  // T = 1 releases the pad; one flop per pad (each next to its I/O), 1 after
  // configuration
  logic [7:0] dq_t;
  logic       rw_t;

  if (Loopback) begin : g_t_lb
    assign dq_t = '0;
    assign rw_t = 1'b0;
  end else begin : g_t_phy
    (* keep = "true" *) logic [7:0] dq_t_q = '1;
    (* keep = "true" *) logic       rw_t_q = 1'b1;

    always_ff @(posedge clk_i) begin
      dq_t_q <= {8{~io_o_i.dq_oe}};
      rw_t_q <= ~io_o_i.rwds_oe;
    end

    assign dq_t = dq_t_q;
    assign rw_t = rw_t_q;
  end

  for (genvar i = 0; i < 8; i++) begin : g_dq
    logic q, din;

    ODDRE1 #(
      .IS_C_INVERTED (1'b1),
      .SIM_DEVICE    (SimDevice),
      .SRVAL         (1'b0)
    ) u_oddr (
      .C  (wclk_i),
      .D1 (dq_d[0][i]),
      .D2 (dq_d[1][i]),
      .SR (1'b0),
      .Q  (q)
    );

    IOBUF u_iobuf (
      .I  (q),
      .T  (dq_t[i]),
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

  if (1) begin : g_rwds      // (a named generate block: xvlog wants it conditional)
    logic q, din;

    ODDRE1 #(
      .IS_C_INVERTED (1'b1),
      .SIM_DEVICE    (SimDevice),
      .SRVAL         (1'b0)
    ) u_oddr (
      .C  (wclk_i),
      .D1 (rw_d[0]),
      .D2 (rw_d[1]),
      .SR (1'b0),
      .Q  (q)
    );

    IOBUF u_iobuf (
      .I  (q),
      .T  (rw_t),
      .O  (din),
      .IO (rwds_io)
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
      .Q1 (io_i_o.rwds[0]),
      .Q2 (io_i_o.rwds[1])
    );

    assign rwds_pad_o = din;
  end

  // ---------------------------------------------------------------------------
  // Level shifter control: ODDRE1 on clk_i with D1 = D2 (DIR = 1: HyperRAM ->
  // FPGA, the TXV0108 DIR = H direction of the card)
  // ---------------------------------------------------------------------------
  if (HasLs && !Loopback) begin : g_ls
    logic [2:0] ls_d, ls_q;
    wire  [2:0] ls_pad;
    localparam logic [2:0] LsIdle = 3'b001;   // {dir_rwds, dir_dq, oe_n}

    assign ls_d = {io_o_i.ls_dir_rwds, io_o_i.ls_dir_dq, io_o_i.ls_oe_n};

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

    assign ls_oe_n_o     = ls_pad[0];
    assign ls_dir_dq_o   = ls_pad[1];
    assign ls_dir_rwds_o = ls_pad[2];
  end else begin : g_ls_const
    assign ls_oe_n_o     = 1'b1;
    assign ls_dir_dq_o   = 1'b0;
    assign ls_dir_rwds_o = 1'b0;
  end

  logic unused;
  assign unused = ^{io_o_i.ls_oe_n, io_o_i.ls_dir_dq, io_o_i.ls_dir_rwds, io_o_i.dq_oe,
                    io_o_i.rwds_oe, lb_dq_en_i, lb_dq_i, lb_rwds_en_i, lb_rwds_i};

endmodule
