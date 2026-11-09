// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Shared definitions of the Bow32 DDR2/DDR3 IP (bow_ddr: LiteDRAM controller,
// DFI adapter, Bow32 PHY).
//
// The I/O bundles below are the only interface between the technology
// independent IP (hw/ip/ddr) and the board specific pad wrapper
// (hw/fpga/common/rtl/bow_ddr_io_xilinx.sv, or the behavioural twin
// hw/ip/ddr/dv/bow_ddr_io_sim.sv in simulation). They are sized for the
// largest supported configuration; a board ties or ignores the unused bits.
//
// Timing contract of ddr_io_out_t (T = CK period, "PHY cycle j" = the ddr_clk
// cycle in which the PHY presents a value, "pin cycle k" = [kT, (k+1)T) that
// starts with CK rising edge k):
//   * ck_en, dqs, dqs_oe, dq, dm, dq_oe, ls_*: the value of PHY cycle j is on
//     the pins during pin cycle j+1. dqs[l] = {second half, first half} of
//     DQS_P (DQS_N is the complement). dq[0] is centred on the DQS rising edge
//     of pin cycle j+1 (time (j+1)T), dq[1] on its falling edge ((j+1.5)T).
//     Output enables on Versal XPIO (bow_ddr_io_xilinx TFromOddr = 1: T from
//     an ODDR in the pad site): dq_oe / dm drive during [(j+1.25)T,
//     (j+2.25)T), dqs_oe during [(j+1)T, (j+2)T), both moved by the write
//     phase (the wrapper header has the margins against the shifter windows).
//   * cke, rst_n, odt, cs_n, ras_n, cas_n, we_n, ba, a: the value of PHY cycle
//     j is on the pins from (j+1.5)T to (j+2.5)T, i.e. centred on CK rising
//     edge j+2: a command presented in PHY cycle j is latched by the DRAM at
//     CK edge j+2.
// ddr_io_in_t is in the read-capture clock domain (rd_clk = ddr_clk delayed by
// the calibrated phase): dq[0] is the sample taken at rd_clk rising edge k,
// dq[1] the sample at the following falling edge; both are presented after
// rd_clk rising edge k+1 (IDDRE1 SAME_EDGE_PIPELINED).
//
// Bursts between bow_ddr_dfi and bow_ddr_phy are carried as 16 bytes in
// ADDRESS order (burst_t, byte k = byte k of the BL8 burst = byte k of the
// LiteDRAM native-port word) with byte enables (be_t, 1 = write the byte).
// x8 uses bytes 0..7, x16 bytes 0..15. Only the PHY converts bytes to beats:
// x8 beat i = byte i, x16 beat i = {byte 2i+1, byte 2i}.
package bow_ddr_pkg;

  localparam int unsigned MaxDq    = 16;   // DQ pins (x8 or x16)
  localparam int unsigned MaxLanes = 2;    // byte lanes = DQS / DM pins
  localparam int unsigned MaxAddr  = 16;   // A[15:0]
  localparam int unsigned MaxBank  = 3;    // BA[2:0]

  localparam logic [31:0] IdValue = 32'h4444_5202;   // "DDR" version 2 (LiteDRAM controller)

  typedef logic [15:0][7:0] burst_t;
  typedef logic [15:0]      be_t;

  // DRAM command codes (bow_ddr_dfi -> bow_ddr_phy, DRAM models).
  typedef enum logic [2:0] {
    CmdNop = 3'd0,   // NOP (cs_n 0, ras/cas/we 1)
    CmdMrs = 3'd1,   // MRS / EMRS: BA = mode register index
    CmdRef = 3'd2,   // auto refresh
    CmdPre = 3'd3,   // precharge, A10 = 1: all banks
    CmdAct = 3'd4,   // activate (bank, row)
    CmdWr  = 3'd5,   // write burst (BL8)
    CmdRd  = 3'd6,   // read burst (BL8)
    CmdZq  = 3'd7    // DDR3 ZQ calibration: A10 = 1 ZQCL, 0 ZQCS
  } cmd_e;

  // {cs_n, ras_n, cas_n, we_n} of each command (JESD79-2/-3 truth table).
  function automatic logic [3:0] cmd_pins(cmd_e c);
    unique case (c)
      CmdMrs:  return 4'b0000;
      CmdRef:  return 4'b0001;
      CmdPre:  return 4'b0010;
      CmdAct:  return 4'b0011;
      CmdWr:   return 4'b0100;
      CmdRd:   return 4'b0101;
      CmdZq:   return 4'b0110;
      default: return 4'b0111;   // NOP
    endcase
  endfunction

  // Configuration of the ddr clock domain: the copy of the registers CTRL and
  // LAT taken by the APPLY command (bow_ddr_regs -> bow_ddr_dfi). The pin
  // values cke, rst_n and odt are not register bits: bow_ddr_dfi fills them
  // from the DFI (gated by EN and ODT_EN) before the structure reaches the PHY.
  typedef struct packed {
    // CTRL
    logic        en;          // DFI commands and CKE / ODT / RESET# reach the pins
    logic        dm_en;       // drive DM from the byte enables (HasDm only)
    logic        ddr3;
    logic        idle_drive;  // drive DQ/DQS/DM outside read windows
    logic        ls_en;       // level shifter OE# low
    logic        odt_en;      // ODT pin may follow the DFI
    logic        ck_en;
    // pins (bow_ddr_dfi)
    logic        cke;
    logic        rst_n;       // DDR3 RESET#
    logic        odt;
    // LAT
    logic [5:0]  rl;
    logic [5:0]  wl;
    logic [4:0]  rd_dly;
    logic        rd_slip;
    logic [1:0]  oe_pre;      // FPGA releases DQ/DQS this many cycles before DIR -> read
    logic [3:0]  rdir_lead;
    logic [3:0]  rdir_tail;
    logic [3:0]  oe_post;     // FPGA drives again this many cycles after DIR -> write
  } cfg_t;

  // Register reset values = the RAM card's DDR2 at 133.33 MHz, CL3 (see
  // docs/ip/ddr.md): CTRL 0x40 (IDLE_DRIVE), LAT 0x22240083.
  localparam cfg_t CFG_RESET = '{
    idle_drive: 1'b1,
    rl: 6'd3, wl: 6'd2, oe_pre: 2'd1, rdir_lead: 4'd2, rdir_tail: 4'd2, oe_post: 4'd2,
    default: '0
  };

  // One DFI phase of the LiteDRAM controller (controller -> PHY side), sized
  // for the largest core: bow_ddr zero-extends the DDR2 core's narrower
  // fields. wrdata = {beat on the DQS falling edge, beat on the rising edge}
  // (DqBits each), wrdata_mask: 1 = byte not written, bit h * Lanes + l =
  // lane l of beat h.
  typedef struct packed {
    logic                  cs_n;
    logic                  ras_n;
    logic                  cas_n;
    logic                  we_n;
    logic [MaxBank-1:0]    bank;
    logic [MaxAddr-1:0]    address;
    logic                  cke;
    logic                  odt;
    logic                  reset_n;
    logic [2*MaxDq-1:0]    wrdata;
    logic                  wrdata_en;
    logic [2*MaxLanes-1:0] wrdata_mask;
    logic                  rddata_en;
  } dfi_phase_t;

  // PHY -> pads (ddr_clk domain), see the header for the timing contract.
  typedef struct packed {
    logic                     ck_en;      // 1: CK toggles, 0: CK low / CK# high
    logic                     cke;
    logic                     rst_n;      // DDR3 RESET#
    logic                     odt;
    logic                     cs_n;
    logic                     ras_n;
    logic                     cas_n;
    logic                     we_n;
    logic [MaxBank-1:0]       ba;
    logic [MaxAddr-1:0]       a;
    logic [MaxLanes-1:0][1:0] dqs;        // per lane {second half, first half}
    logic [MaxLanes-1:0]      dqs_oe;     // drive DQS_P / DQS_N
    logic [1:0][MaxDq-1:0]    dq;         // {beat on DQS fall, beat on DQS rise}
    logic [1:0][MaxLanes-1:0] dm;         // same layout as dq, 1 = masked
    logic                     dq_oe;      // drive DQ and DM
    logic                     ls_oe_n;    // level shifter OE#
    logic                     ls_dir_dq;  // level shifter DIR of DQ/DM: 1 = DRAM -> FPGA
    logic                     ls_dir_dqs; // level shifter DIR of DQS:   1 = DRAM -> FPGA
  } ddr_io_out_t;

  // Pads -> PHY (read-capture clock domain).
  typedef struct packed {
    logic [1:0][MaxDq-1:0]    dq;         // {falling-edge sample, rising-edge sample}
    logic [1:0][MaxLanes-1:0] dqs;
  } ddr_io_in_t;

  // State of the pads before the first APPLY and in the stub (deselect,
  // level shifters isolated).
  localparam ddr_io_out_t DDR_IO_OUT_DEFAULT = '{
    cs_n: 1'b1, ras_n: 1'b1, cas_n: 1'b1, we_n: 1'b1, ls_oe_n: 1'b1, default: '0
  };

endpackage
