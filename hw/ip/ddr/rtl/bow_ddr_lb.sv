// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Loopback DRAM emulator (spec 7.2): bow_ddr_dev + a frame adapter that
// connects it to the PHY side of the pad wrapper. It sits next to
// bow_ddr_io_xilinx (Loopback = 1) on the board that has no DRAM: the PHY
// drives the real pads, the emulator answers through lb_en / lb_dq / lb_dqs,
// and the read data come back through the pads, IOBs and IDDRs.
//
// All ports are in the ddr_clk domain with the io_o timing of bow_ddr_pkg
// ("PHY cycle j" = the ddr_clk cycle in which a value is presented; the pad
// wrapper puts it on the pins in pin cycle j+1):
//   * command pins (cke, rst_n, odt, cs_n, ras_n, cas_n, we_n, ba, a) of PHY
//     cycle n -> device CK edge n+2: one register here plus the device's own
//     input sampling.
//   * CK edge e exists when io_i.ck_en of PHY cycle e-1 is 1: that is the
//     device clock enable (no register).
//   * the unregistered command pins (the next edge's command) go to the
//     device's lookahead inputs (Lookahead = 1): a RD with RL = 3 starts its
//     UltraRAM read one edge early, which gives the read data path a third
//     register stage (timing at 133.33 MHz).
//   * write beats: io_i.dq / io_i.dm of PHY cycle e-1 belong to CK edge e
//     (DQS rising edge at e); one register, so the device sees them one cycle
//     late (core cycle e+1) as its interface wants. The strobes count as seen
//     when every lane has dqs_oe = 1 and dqs = (1,0) ({second, first half} =
//     2'b01) in that PHY cycle.
//   * read beats: the device presents the beats of edge e in core cycle e-1;
//     they drive lb_dq_o in PHY cycle e-1 (lb_dq_o[0] = beat on the DQS rising
//     edge, [1] = beat on the falling edge). lb_dqs_o = (1,0) in data cycles,
//     (0,0) in the preamble cycle; lb_en_o covers the preamble cycle and the
//     data cycles (the postamble is the low half of the last data cycle).
//   * dbg_o = {err_count != 0, init_done, 6'b0, err_code[7:0], err_count[15:0]}
//     (registered, to ddr_dbg_i; STATUS.DBG_ERR = bit 31).
// The device checks the JEDEC command rules and the init sequence exactly as
// the simulation pin model does (see bow_ddr_dev for the error codes). Its
// timing parameters are the card's DDR2 at 133.33 MHz (DDR3 DLL-off at 125
// MHz when Ddr3 = 1).
//
// Storage: MemBytes (power of two; MPS4: 4 MiB in UltraRAM, UseUram = 1),
// RowBits = log2(MemBytes) - L - ColBits - BankBits (4 MiB x8: 22 - 0 - 10 -
// 2 = 10). The LiteDRAM core maps the window offset as {row, bank, column}
// (DDR2 x8: row = offset[25:12]), so the emulator holds the first MemBytes of
// the window (EMU register); rows beyond RowBits are flagged as errors by the
// device (software keeps to EMU).

module bow_ddr_lb import bow_ddr_pkg::*; #(
  parameter bit          Ddr3     = 1'b0,
  parameter int unsigned DqBits   = 8,
  parameter int unsigned BankBits = 2,
  parameter int unsigned RowBits  = 10,
  parameter int unsigned ColBits  = 10,
  parameter int unsigned MemBytes = 4 << 20,
  parameter bit          UseUram  = 1'b1
) (
  input  logic                         clk_i,      // ddr_clk
  input  logic                         rst_ni,
  input  ddr_io_out_t                  io_i,       // the PHY output (as fed to the pad wrapper)
  output logic                         lb_en_o,
  output logic [1:0][MaxDq-1:0]        lb_dq_o,
  output logic [MaxLanes-1:0][1:0]     lb_dqs_o,
  output logic [31:0]                  dbg_o
);

  localparam int unsigned Lanes = DqBits / 8;

  // ------------------------------------------------- PHY -> device (1 stage)
  logic                   cke_q, rst_n_q, odt_q, cs_n_q, ras_n_q, cas_n_q, we_n_q;
  logic [2:0]             ba_q;
  logic [15:0]            a_q;
  logic [1:0][DqBits-1:0] dq_q;
  logic [1:0][Lanes-1:0]  dm_q;
  logic                   strobe_q;
  logic                   strobe;

  always_comb begin
    strobe = 1'b1;
    for (int unsigned l = 0; l < Lanes; l++) begin
      strobe &= io_i.dqs_oe[l] && (io_i.dqs[l] == 2'b01);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cke_q    <= DDR_IO_OUT_DEFAULT.cke;      // deselect, CKE / RESET# / ODT low
      rst_n_q  <= DDR_IO_OUT_DEFAULT.rst_n;
      odt_q    <= DDR_IO_OUT_DEFAULT.odt;
      cs_n_q   <= DDR_IO_OUT_DEFAULT.cs_n;
      ras_n_q  <= DDR_IO_OUT_DEFAULT.ras_n;
      cas_n_q  <= DDR_IO_OUT_DEFAULT.cas_n;
      we_n_q   <= DDR_IO_OUT_DEFAULT.we_n;
      ba_q     <= DDR_IO_OUT_DEFAULT.ba;
      a_q      <= DDR_IO_OUT_DEFAULT.a;
      dq_q     <= '0;
      dm_q     <= '0;
      strobe_q <= 1'b0;
    end else begin
      cke_q    <= io_i.cke;
      rst_n_q  <= io_i.rst_n;
      odt_q    <= io_i.odt;
      cs_n_q   <= io_i.cs_n;
      ras_n_q  <= io_i.ras_n;
      cas_n_q  <= io_i.cas_n;
      we_n_q   <= io_i.we_n;
      ba_q     <= io_i.ba;
      a_q      <= io_i.a;
      for (int unsigned k = 0; k < 2; k++) begin
        dq_q[k] <= io_i.dq[k][DqBits-1:0];
        dm_q[k] <= io_i.dm[k][Lanes-1:0];
      end
      strobe_q <= strobe;
    end
  end

  // ---------------------------------------------------------------- device
  logic                   wr_expect, rd_oe, rd_pre, init_done;
  logic [1:0][DqBits-1:0] rd_dq;
  logic [7:0]             err_code;
  logic [15:0]            err_count;
  logic [31:0]            err_cycle;

  bow_ddr_dev #(
    .Ddr3      (Ddr3),
    .DqBits    (DqBits),
    .BankBits  (BankBits),
    .RowBits   (RowBits),
    .ColBits   (ColBits),
    .MemBytes  (MemBytes),
    .UseUram   (UseUram),
    .Sparse    (1'b0),
    .CheckInit (1'b1),
    .Lookahead (1'b1)
  ) u_dev (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .ck_en_i     (io_i.ck_en),
    .hot_i       (1'b0),          // REF_STARVE at the Tc <= 85 C rate
    .cke_i       (cke_q),
    .reset_n_i   (rst_n_q),
    .odt_i       (odt_q),
    .cs_n_i      (cs_n_q),
    .ras_n_i     (ras_n_q),
    .cas_n_i     (cas_n_q),
    .we_n_i      (we_n_q),
    .ba_i        (ba_q),
    .a_i         (a_q),
    .la_cs_n_i   (io_i.cs_n),
    .la_ras_n_i  (io_i.ras_n),
    .la_cas_n_i  (io_i.cas_n),
    .la_we_n_i   (io_i.we_n),
    .la_ba_i     (io_i.ba),
    .la_a_i      (io_i.a),
    .wr_dq_i     (dq_q),
    .wr_dm_i     (dm_q),
    .wr_v_i      (strobe_q),
    .wr_expect_o (wr_expect),
    .rd_dq_o     (rd_dq),
    .rd_oe_o     (rd_oe),
    .rd_pre_o    (rd_pre),
    .err_code_o  (err_code),
    .err_count_o (err_count),
    .err_cycle_o (err_cycle),
    .init_done_o (init_done)
  );

  // ------------------------------------------------ device -> pad wrapper
  always_comb begin
    lb_en_o  = rd_oe || rd_pre;
    lb_dq_o  = '0;
    lb_dqs_o = '0;
    for (int unsigned k = 0; k < 2; k++) lb_dq_o[k][DqBits-1:0] = rd_dq[k];
    for (int unsigned l = 0; l < Lanes; l++) lb_dqs_o[l] = rd_oe ? 2'b01 : 2'b00;
  end

  // registered: ddr_dbg_i enters the SoC clock bit by bit through bow_sync
  // (bow_ddr_regs), so no logic may sit in front of it (err_count != 0 could
  // glitch low while the count steps); the count itself may read torn for a
  // cycle when it changes during a DBG read (debug only)
  logic [31:0] dbg_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dbg_q <= '0;
    end else begin
      dbg_q <= {err_count != 16'd0, init_done, 6'd0, err_code, err_count};
    end
  end

  assign dbg_o = dbg_q;

  // the rest of the PHY bundle is not used by a DRAM model (shifter control,
  // output enables) or not wired (bits above DqBits / Lanes)
  logic unused;
  assign unused = ^{io_i, wr_expect, err_cycle};

endmodule
