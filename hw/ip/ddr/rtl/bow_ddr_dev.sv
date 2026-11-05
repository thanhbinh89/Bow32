// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Cycle level model of ONE JEDEC DDR2 (JESD79-2) or DDR3 (JESD79-3) SDRAM
// device. It is the core of the Verilator pin model (hw/ip/ddr/dv/
// ddr_mem_model.sv, Sparse = 1) and of the on-chip loopback emulator
// (bow_ddr_lb, UltraRAM / block RAM storage). Synthesizable, except the
// Sparse storage and the messages (both `ifndef SYNTHESIS).
//
// Interface ("core cycle t" = the clk_i posedge that is CK rising edge t.
// A posedge with ck_en_i = 0 is not a CK edge: nothing advances, timers stop):
//   cke_i .. a_i       the pins as latched at CK edge t (reset_n_i = DDR3
//                      RESET#, sampled at CK edges like the others)
//   wr_dq_i / wr_dm_i  the two write beats of edge t-1 (DQS rising edge at
//                      edge t-1 and the next falling edge), one cycle late;
//                      wr_dm_i 1 = byte masked
//   wr_v_i             1: the strobes of those beats were seen (all lanes)
//   wr_expect_o        (registered at edge t) the beats of edge t are expected
//   rd_dq_o, rd_oe_o,  (registered at edge t) what the device drives for edge
//   rd_pre_o           t+1 (one cycle early): rd_oe_o = data cycle, beat
//                      rd_dq_o[0] from the DQS rising edge at t+1, rd_dq_o[1]
//                      from its falling edge (the read postamble is the low
//                      half of the last data cycle); rd_pre_o = DQS preamble
//                      cycle (DQS driven low, DQ not driven)
//   err_count_o        violations (each one counts, saturating); err_code_o
//   err_code_o           / err_cycle_o = the first one (cycle = CK edge index,
//   err_cycle_o          0 = first CK edge after rst_ni)
//   init_done_o        the init sequence is complete (1 with CheckInit = 0)
//
// Latencies come only from the mode register words received with MRS (with
// CheckInit = 0 the registers start with Mr0Init .. Mr3Init):
//   DDR2: RL = AL + CL, WL = RL - 1. DDR3: RL = AL + CL, WL = AL + CWL.
//   RD at edge m: preamble cycle = edge D-1, data at edges D .. D+3 with D =
//   m + RL (DLL on) or m + RL - 1 (DDR3 DLL-off, MR1 A0 = 1; tDQSCK(DLL_off)
//   is added by the pin model). WR at m: beats at edges m+WL .. m+WL+3.
//   Bursts are BL8 only, never interrupted, column A[2:0] = 0 (aligned).
//
// Storage: one word per burst, burst index {row, bank, column[ColBits-1:3]};
// MemBytes (power of two) of storage, addresses alias above it (bow_ddr_lb
// flags rows beyond RowBits, so nothing aliases). UseUram: (* ram_style =
// "ultra" *). Words hold data ^ 0xA5.. so that never written bytes (RAM
// contents 0 after configuration) read 0xA5. Sparse (simulation only): an
// associative array of the full capacity; reads of never written bytes return
// 0xA5 and are counted in g_sparse.unwritten (not an error).
// Read pipeline: RAM array read at edge m + RLe - 3 (RLe = data start
// latency >= 3; for RLe = 3 the read address comes combinationally from the
// command pins), RAM output register, rd_dq_o register. The RAM write of a
// burst happens one edge after the edge that brings its fourth pair (WR edge
// + WL + 5, registered inputs for the UltraRAM cascade); a RAM read at that
// same edge gets the burst through a bypass, so a RD needs tWTR >= 1 (RD >=
// WR + WL + 5, always true for JEDEC parts) to see the new data.
//
// Checks (each violation: err_count_o += 1; `ifndef SYNTHESIS also $error
// with a readable message, or $fatal when FatalOnError; Verilator stops at
// the first $error unless run with +verilator+error+limit+<n>):
//
//   code  name         violation
//   0x00  -            none
//   ---- initialisation (CheckInit = 1)
//   0x01  INIT_ORDER   command out of the JEDEC init order (DDR2: PREA, EMRS2,
//                      EMRS3, EMRS1, MRS DLL reset, PREA, >= 2 REF, MRS, EMRS1
//                      OCD default, EMRS1 OCD exit; DDR3: MR2, MR3, MR1, MR0,
//                      ZQCL), or any other command before init done (NOP, DES
//                      and PRE / PREA after the first command are accepted).
//                      DDR2 EMRS2 / EMRS3 may come in either order (JESD79-2
//                      lists EMRS2 first, LiteDRAM's init issues EMRS3 first;
//                      the two registers are independent)
//   0x02  INIT_TIME    DDR2: CKE high before tINIT (TInit edges of running
//                      clock with CKE low); DDR3: RESET# high before tRESET
//   0x03  INIT_NOP     a command within 400 ns (TInitNop) of CKE high (DDR2)
//                      or within tXPR (DDR3), or a command at the CKE high edge
//   0x04  INIT_CKE     DDR3: CKE not low >= 10 ns (TCkeRst) before RESET#
//                      high, CKE high < tCKE_LOW after RESET# high, CKE low
//                      during init, CKE high again after a CKE low without a
//                      new RESET#
//   0x05  INIT_CK      DDR3: CK not running for TCkRun edges before CKE high
//   0x06  INIT_ODT     DDR2: ODT high before EMRS1; DDR3: ODT high at CKE high
//   0x07  INIT_MR      DDR2: EMRS1 of the init with DLL off or OCD != exit,
//                      first MRS without / second MRS with DLL reset, OCD
//                      default / exit words wrong; DDR3 DLL on: MR0 of the init
//                      without DLL reset
//   0x08  OCD_EARLY    DDR2: EMRS1 OCD default < 200 nCK (TDllk) after the
//                      DLL reset
//   0x09  DLLK         RD < TDllk after a DLL reset (DDR2; DDR3 with DLL on)
//   ---- bank state, addressing
//   0x10  ACT_OPEN     ACT to an open bank
//   0x11  BANK_CLOSED  RD / WR to a closed bank
//   0x12  BANK_OPEN    REF / MRS / ZQ while a bank is open
//   0x13  AUTO_PRE     RD / WR with A10 = 1 (auto precharge: not supported)
//   0x14  BANK_RANGE   BA beyond BankBits (ACT, RD, WR, PRE)
//   0x15  ROW_RANGE    ACT row beyond RowBits
//   0x16  COL_RANGE    RD / WR column beyond ColBits, A[2:0] != 0 (unaligned
//                      burst: not supported), other address bits set (A11,
//                      A13.., A12 in DDR2)
//   0x17  MRS_BUSY     MRS while a read or write burst is in flight
//   0x18  ZQ_DDR2      ZQ encoding (CS# RAS# CAS# WE# = L H H L) in DDR2
//   ---- timing (cycles = CK edges between the two commands)
//   0x20  TRCD         RD / WR < tRCD after ACT (same bank)
//   0x21  TRAS         PRE (or PREA) < tRAS after ACT
//   0x22  TRC          ACT < tRC after ACT (same bank)
//   0x23  TRP          ACT < tRP after PRE (same bank; tRPA after PREA),
//                      REF / MRS / ZQ < tRP after any PRE
//   0x24  TRRD         ACT < tRRD after ACT (other bank)
//   0x25  TFAW         fifth ACT within tFAW (TFaw != 0)
//   0x26  TWR          PRE < WL + 4 + tWR after WR
//   0x27  TRTP         PRE < RD-to-PRE after RD (DDR2 AL + 2 + max(tRTP, 2),
//                      DDR3 AL + max(tRTP, 4))
//   0x28  TCCD         RD < 4 after RD, WR < 4 after WR (BL8, no interrupt)
//   0x29  TWTR         RD < WL + 4 + tWTR after WR
//   0x2A  TRTW         WR < RD-to-WR after RD (DDR2 BL/2 + 2 = 6, DDR3
//                      RL + 6 - WL)
//   0x2B  TMRD         any command (DDR2) / MRS (DDR3) < tMRD after MRS
//   0x2C  TMOD         DDR3: non-MRS command < tMOD after MRS
//   0x2D  TRFC         any command < tRFC after REF
//   0x2E  TZQ          any command < tZQinit (init ZQCL) / tZQoper / tZQCS
//   0x2F  TRAS_MAX     a bank open longer than tRAS(max)
//   0x30  REF_STARVE   no REF for more than 9 * tREFI after init done
//   ---- mode register values
//   0x38  MR_BL        burst length != 8 (DDR2 MR A2:0 != 011, DDR3 MR0
//                      A1:0 != 00)
//   0x39  MR_CL        CAS latency not supported (DDR2 3..7, DDR3 5..11)
//   0x3A  MR_AL        additive latency != 0
//   0x3B  MR_DLL       DDR2 EMR1 A0 = 1 (DLL disabled)
//   0x3C  MR_RDQS      DDR2 EMR1 A11 = 1 (RDQS) with RdqsTied or x16
//   0x3D  MR_DLLOFF    DDR3 DLL-off with CL / CWL != 6, RTT_Nom / RTT_WR != 0,
//                      or the ODT pin high
//   0x3E  MR_UNSUP     other unsupported / reserved bits: DDR2 MR A7 (test),
//                      WR 0 / 7, EMR1 A12 (Qoff), OCD adjust modes; DDR3 MR0
//                      A7, MR1 A7 (write levelling) / A11 (TDQS) / A12 (Qoff)
//                      / A8 / A10, MR2 CWL > 10 / A8, MR3 A2 (MPR) / A15:3;
//                      MRS with BA2 = 1 or A15:13 != 0
//   ---- data
//   0x40  WR_DATA      write beats expected but no strobes (wr_v_i = 0); not at
//                      an edge that resets the device (the burst is dropped)
//   ---- pin level (only from ddr_mem_model, listed here to keep one table)
//   0x50  PIN_TIS      command / address / CKE / ODT setup to CK < tIS
//   0x51  PIN_TIH      command / address / CKE / ODT hold from CK < tIH
//   0x52  PIN_TDQSS    first DQS rising edge of a pair outside CK +- tDQSS
//   0x53  PIN_TDSS     DQS falling edge setup to the next CK < tDSS
//   0x54  PIN_TDSH     DQS falling edge hold from CK < tDSH
//   0x55  PIN_TDS      DQ / DM setup to DQS < tDS
//   0x56  PIN_TDH      DQ / DM hold from DQS < tDH
//   0x57  PIN_WPRE     write preamble < tWPRE
//   0x58  PIN_WPST     write postamble < tWPST
//   0x59  PIN_DQS_PW   DQS high / low pulse in a burst < 0.35 tCK
//   0x5A  PIN_FLOAT    write DQ / DQS / DM not driven at the DRAM pins
//   0x5B  PIN_TCK      CK period != TckPs or outside the range of the mode
//   0x5C  PIN_CK_RUN   CK not running max(5 tCK, 10 ns) before CKE high
//
// Not modelled: power down, self refresh, burst chop, burst interrupt,
// auto precharge, OCD adjust, write levelling, MPR, data loss on refresh or
// tRAS / tWR violations (flagged only). CKE low after init is accepted as a
// DDR2 CKE-low reset (a new init is required, no error); in DDR3 it needs
// RESET# low before CKE may go high again. ColBits <= 10.

module bow_ddr_dev import bow_ddr_pkg::*; #(
  parameter bit          Ddr3         = 1'b0,
  parameter int unsigned DqBits       = 8,            // 8 or 16
  parameter int unsigned BankBits     = 2,            // 2 or 3
  parameter int unsigned RowBits      = 14,           // 6 .. 16
  parameter int unsigned ColBits      = 10,           // 9 .. 10
  parameter int unsigned MemBytes     = 4 << 20,      // storage, power of two
  parameter bit          UseUram      = 1'b0,
  parameter bit          Sparse       = 1'b0,         // simulation only
  parameter bit          CheckInit    = 1'b1,
  parameter bit          FatalOnError = 1'b0,
  parameter bit          RdqsTied     = 1'b1,         // DM/RDQS ball tied: EMR1 A11 = 1 is an error
  parameter bit          Lookahead    = 1'b0,         // la_* carry the next edge's pins (emulator)
  // JEDEC timing in CK cycles. Defaults: DDR2 = the card's IS43DR86400E-25DBL
  // at 133.33 MHz; DDR3 = 1Gb x16 in DLL-off mode at 125 MHz.
  parameter int unsigned TRcd         = 2,
  parameter int unsigned TRp          = 2,
  parameter int unsigned TRpa         = TRp,          // PREA (8-bank DDR2: tRP + 1)
  parameter int unsigned TRas         = Ddr3 ? 5 : 6,
  parameter int unsigned TRc          = Ddr3 ? 7 : 8,
  parameter int unsigned TRrd         = Ddr3 ? 4 : 1,
  parameter int unsigned TFaw         = Ddr3 ? 7 : 0,  // 0 = no tFAW (4-bank DDR2)
  parameter int unsigned TWr          = Ddr3 ? 5 : 2,
  parameter int unsigned TRtp         = Ddr3 ? 4 : 1,
  parameter int unsigned TWtr         = Ddr3 ? 4 : 1,
  parameter int unsigned TRfc         = 14,
  parameter int unsigned TRefi        = Ddr3 ? 975 : 1040,   // 0 = no starvation check
  parameter int unsigned TMrd         = Ddr3 ? 4 : 2,
  parameter int unsigned TMod         = 12,           // DDR3
  parameter int unsigned TZqInit      = 512,          // DDR3
  parameter int unsigned TZqOper      = 256,          // DDR3
  parameter int unsigned TZqCs        = 64,           // DDR3
  parameter int unsigned TXpr         = 15,           // DDR3: max(5 nCK, tRFC + 10 ns)
  parameter int unsigned TInit        = 26_667,       // DDR2: 200 us of clock with CKE low
  parameter int unsigned TInitNop     = 54,           // DDR2: 400 ns after CKE high
  parameter int unsigned TReset       = 25_000,       // DDR3: 200 us RESET# low
  parameter int unsigned TCkeLow      = 62_500,       // DDR3: 500 us RESET# high -> CKE high
  parameter int unsigned TCkeRst      = 2,            // DDR3: CKE low 10 ns before RESET# high
  parameter int unsigned TCkRun       = 5,            // DDR3: CK edges before CKE high
  parameter int unsigned TDllk        = Ddr3 ? 512 : 200,
  parameter int unsigned TRasMax      = Ddr3 ? 8775 : 9333,  // 0 = no check
  // mode registers before the first MRS
  parameter logic [15:0] Mr0Init      = Ddr3 ? 16'h0220 : 16'h0233,
  parameter logic [15:0] Mr1Init      = Ddr3 ? 16'h0001 : 16'h0000,
  parameter logic [15:0] Mr2Init      = Ddr3 ? 16'h0008 : 16'h0000,
  parameter logic [15:0] Mr3Init      = 16'h0000
) (
  input  logic                     clk_i,      // one posedge per CK rising edge (ck_en_i)
  input  logic                     rst_ni,     // power-on reset of the model
  input  logic                     ck_en_i,    // 1: this posedge is a CK edge
  input  logic                     cke_i,
  input  logic                     reset_n_i,  // DDR3 RESET# (ignored by DDR2)
  input  logic                     odt_i,
  input  logic                     cs_n_i,
  input  logic                     ras_n_i,
  input  logic                     cas_n_i,
  input  logic                     we_n_i,
  input  logic [2:0]               ba_i,
  input  logic [15:0]              a_i,
  input  logic                     la_cs_n_i,  // Lookahead = 1: the pins of edge t+1, valid
  input  logic                     la_ras_n_i, // before posedge t (an earlier RAM read for
  input  logic                     la_cas_n_i, // RL 3); tie off with Lookahead = 0
  input  logic                     la_we_n_i,
  input  logic [2:0]               la_ba_i,
  input  logic [15:0]              la_a_i,
  input  logic [1:0][DqBits-1:0]   wr_dq_i,    // beats of edge t-1: [0] rise, [1] fall
  input  logic [1:0][DqBits/8-1:0] wr_dm_i,
  input  logic                     wr_v_i,
  output logic                     wr_expect_o,
  output logic [1:0][DqBits-1:0]   rd_dq_o,    // beats for edge t+1: [0] rise, [1] fall
  output logic                     rd_oe_o,
  output logic                     rd_pre_o,
  output logic [7:0]               err_code_o,
  output logic [15:0]              err_count_o,
  output logic [31:0]              err_cycle_o,
  output logic                     init_done_o
);

  localparam int unsigned Lanes      = DqBits / 8;
  localparam int unsigned BurstBytes = 8 * Lanes;
  localparam int unsigned BurstBits  = 8 * BurstBytes;
  localparam int unsigned BIdxW      = RowBits + BankBits + ColBits - 3;   // burst index
  localparam int unsigned StoreBytes = (MemBytes < (BurstBytes << BIdxW)) ? MemBytes
                                                                          : (BurstBytes << BIdxW);
  localparam int unsigned Depth      = StoreBytes / BurstBytes;
  localparam int unsigned RamAw      = (Depth > 1) ? $clog2(Depth) : 1;
  localparam int unsigned NBanks     = 1 << BankBits;
  localparam int unsigned SchDepth   = 16;      // read / write schedules (latency <= 18 / 16)
  localparam int unsigned RamLat     = Lookahead ? 3 : 2;   // RAM read: array + register(s)
  localparam logic [19:0] RefMax     = 20'(9 * TRefi);
  localparam logic [19:0] RasMax     = 20'(TRasMax);
  // address bits a RD / WR may carry: column[ColBits-1:3], A10 (AP, checked
  // separately), A12 (DDR3 BC#: don't care with BL8 fixed)
  localparam logic [15:0] ColOk      = (16'((32'd1 << ColBits) - 1) & 16'hFFF8) | 16'h0400 |
                                       (Ddr3 ? 16'h1000 : 16'h0000);
  localparam logic [BurstBits-1:0] A5s = {BurstBytes{8'hA5}};

  // ----------------------------------------------------------- error codes
  localparam int unsigned NE = 43;
  localparam int unsigned EInitOrder = 0,  EInitTime = 1,  EInitNop = 2,   EInitCke = 3,
                          EInitCk = 4,     EInitOdt = 5,   EInitMr = 6,    EOcdEarly = 7,
                          EDllk = 8,       EActOpen = 9,   EBankClosed = 10, EBankOpen = 11,
                          EAutoPre = 12,   EBankRange = 13, ERowRange = 14, EColRange = 15,
                          EMrsBusy = 16,   EZqDdr2 = 17,   ETrcd = 18,     ETras = 19,
                          ETrc = 20,       ETrp = 21,      ETrrd = 22,     ETfaw = 23,
                          ETwr = 24,       ETrtp = 25,     ETccd = 26,     ETwtr = 27,
                          ETrtw = 28,      ETmrd = 29,     ETmod = 30,     ETrfc = 31,
                          ETzq = 32,       ETrasMax = 33,  ERefStarve = 34, EMrBl = 35,
                          EMrCl = 36,      EMrAl = 37,     EMrDll = 38,    EMrRdqs = 39,
                          EMrDllOff = 40,  EMrUnsup = 41,  EWrData = 42;

  function automatic logic [7:0] code_of(int unsigned i);
    logic [7:0] c;
    unique case (i)
      EInitOrder:  c = 8'h01;
      EInitTime:   c = 8'h02;
      EInitNop:    c = 8'h03;
      EInitCke:    c = 8'h04;
      EInitCk:     c = 8'h05;
      EInitOdt:    c = 8'h06;
      EInitMr:     c = 8'h07;
      EOcdEarly:   c = 8'h08;
      EDllk:       c = 8'h09;
      EActOpen:    c = 8'h10;
      EBankClosed: c = 8'h11;
      EBankOpen:   c = 8'h12;
      EAutoPre:    c = 8'h13;
      EBankRange:  c = 8'h14;
      ERowRange:   c = 8'h15;
      EColRange:   c = 8'h16;
      EMrsBusy:    c = 8'h17;
      EZqDdr2:     c = 8'h18;
      ETrcd:       c = 8'h20;
      ETras:       c = 8'h21;
      ETrc:        c = 8'h22;
      ETrp:        c = 8'h23;
      ETrrd:       c = 8'h24;
      ETfaw:       c = 8'h25;
      ETwr:        c = 8'h26;
      ETrtp:       c = 8'h27;
      ETccd:       c = 8'h28;
      ETwtr:       c = 8'h29;
      ETrtw:       c = 8'h2A;
      ETmrd:       c = 8'h2B;
      ETmod:       c = 8'h2C;
      ETrfc:       c = 8'h2D;
      ETzq:        c = 8'h2E;
      ETrasMax:    c = 8'h2F;
      ERefStarve:  c = 8'h30;
      EMrBl:       c = 8'h38;
      EMrCl:       c = 8'h39;
      EMrAl:       c = 8'h3A;
      EMrDll:      c = 8'h3B;
      EMrRdqs:     c = 8'h3C;
      EMrDllOff:   c = 8'h3D;
      EMrUnsup:    c = 8'h3E;
      EWrData:     c = 8'h40;
      default:     c = 8'hFF;
    endcase
    return c;
  endfunction

  // ------------------------------------------------------- small helpers
  // down counter load for "the next command needs n cycles" (checked > 0)
  function automatic logic [7:0] ld8(int unsigned n);
    return (n == 0) ? 8'd0 : (n > 256) ? 8'd255 : 8'(n - 1);
  endfunction
  function automatic logic [9:0] ld10(int unsigned n);
    return (n == 0) ? 10'd0 : (n > 1024) ? 10'd1023 : 10'(n - 1);
  endfunction
  function automatic logic [7:0] dn8(logic [7:0] v);
    return (v != 8'd0) ? v - 8'd1 : 8'd0;
  endfunction
  function automatic logic [9:0] dn10(logic [9:0] v);
    return (v != 10'd0) ? v - 10'd1 : 10'd0;
  endfunction
  function automatic logic [19:0] up20(logic [19:0] v);
    return (v != 20'hFFFFF) ? v + 20'd1 : v;
  endfunction
  function automatic logic [7:0] up8(logic [7:0] v);
    return (v != 8'hFF) ? v + 8'd1 : v;
  endfunction

  // ------------------------------------------------- mode register decode
  typedef struct packed {
    logic [4:0] cl;        // CAS latency (DDR3 0 = reserved code)
    logic [4:0] cwl;       // DDR3 CAS write latency
    logic [4:0] al;        // additive latency
    logic       dll_off;   // DLL disabled (DDR2 EMR1 A0, DDR3 MR1 A0)
    logic       rdqs;      // DDR2 EMR1 A11
    logic [2:0] rtt_nom;   // DDR3 MR1 {A9, A6, A2}
    logic [1:0] rtt_wr;    // DDR3 MR2 A10:9
  } mrdec_t;

  function automatic mrdec_t mr_decode(logic [2:0][15:0] mr);
    mrdec_t d;
    d = '0;
    if (Ddr3) begin
      d.cl      = (mr[0][2] || mr[0][6:4] == 3'd0) ? 5'd0 : 5'd4 + {2'd0, mr[0][6:4]};
      d.cwl     = 5'd5 + {2'd0, mr[2][5:3]};
      unique case (mr[1][4:3])
        2'd1:    d.al = d.cl - 5'd1;
        2'd2:    d.al = d.cl - 5'd2;
        default: d.al = 5'd0;
      endcase
      d.dll_off = mr[1][0];
      d.rtt_nom = {mr[1][9], mr[1][6], mr[1][2]};
      d.rtt_wr  = mr[2][10:9];
    end else begin
      d.cl      = {2'd0, mr[0][6:4]};
      d.al      = {2'd0, mr[1][5:3]};
      d.dll_off = mr[1][0];
      d.rdqs    = mr[1][11];
    end
    return d;
  endfunction

  // value checks of one MRS: {UNSUP, RDQS, DLL, AL, CL, BL}
  // latencies of the reset mode registers (constant)
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [23:0] lat_init();
    mrdec_t     d;
    logic [5:0] r, w, e, p, t;
    d = mr_decode({Mr2Init, Mr1Init, Mr0Init});
    r = {1'b0, d.al} + {1'b0, d.cl};
    w = Ddr3 ? ({1'b0, d.al} + {1'b0, d.cwl}) : r - 6'd1;
    e = (Ddr3 && d.dll_off) ? r - 6'd1 : r;
    if (e < 6'd3)  e = 6'd3;
    if (e > 6'd18) e = 6'd18;
    if (w < 6'd1)  w = 6'd1;
    if (w > 6'd16) w = 6'd16;
    p = Ddr3 ? {1'b0, d.al} + ((TRtp > 4) ? 6'(TRtp) : 6'd4)
             : {1'b0, d.al} + 6'd2 + ((TRtp > 2) ? 6'(TRtp) : 6'd2);
    t = Ddr3 ? r + 6'd6 - w : 6'd6;
    return {w, e, p, t};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  localparam logic [23:0] LatInit = lat_init();

  function automatic logic [5:0] mr_check(logic [1:0] r, logic [15:0] v);
    logic bl, cl, al, dll, rdqs, uns;
    {bl, cl, al, dll, rdqs, uns} = '0;
    if (Ddr3) begin
      unique case (r)
        2'd0: begin
          bl  = (v[1:0] != 2'b00);
          cl  = v[2] || (v[6:4] == 3'd0);
          uns = v[7] || (v[15:13] != 3'd0);
        end
        2'd1: begin
          al  = (v[4:3] != 2'b00);
          uns = v[7] || v[8] || v[10] || v[11] || v[12] || (v[15:13] != 3'd0);
        end
        2'd2:    uns = (v[5:3] > 3'd5) || v[8] || (v[15:11] != 5'd0);
        default: uns = v[2] || (v[15:3] != 13'd0);
      endcase
    end else begin
      unique case (r)
        2'd0: begin
          bl  = (v[2:0] != 3'b011);
          cl  = (v[6:4] < 3'd3);
          uns = v[7] || (v[11:9] == 3'd0) || (v[11:9] == 3'd7) || (v[15:13] != 3'd0);
        end
        2'd1: begin
          dll  = v[0];
          al   = (v[5:3] != 3'd0);
          rdqs = v[11] && (RdqsTied || DqBits != 8);
          uns  = v[12] || (v[9:7] != 3'b000 && v[9:7] != 3'b111) || (v[15:13] != 3'd0);
        end
        default: ;
      endcase
    end
    return {uns, rdqs, dll, al, cl, bl};
  endfunction

  // ------------------------------------------------------------- state
  typedef enum logic [4:0] {
    IPwr, INop, IEmr2, IEmr3, IEmr2b, IEmr1, IMrDll, IPrea2, IRef, IMr, IOcdDef,     // DDR2
    IOcdExit,
    IRst, ICkeL, IXpr, IMr3, IMr1, IMr0, IZqcl, IPdn,                                  // DDR3
    IDone
  } ist_e;

  ist_e                         ist_q, ist_d;
  logic [19:0]                  icnt_q;        // edges in the current init state
  logic [7:0]                   ckel_q;        // consecutive edges with CKE low
  logic [7:0]                   ckrun_q;       // consecutive CK edges (ck_en_i)
  logic                         nref_q;        // DDR2 init: first REF seen
  logic                         pdn_err_q;     // DDR3: CKE-high-without-RESET# reported
  logic [31:0]                  cyc_q;
  logic                         cke_q, odt_q;
  logic [3:0][15:0]             mr_q;
  logic [7:0]                   open_q;
  logic [7:0][RowBits-1:0]      row_q;
  logic [7:0][7:0]              t_rcd_q, t_ras_q, t_rc_q, t_rp_q, t_wtp_q, t_rtp_q;
  logic [7:0][19:0]             age_q;
  logic [7:0]                   t_rrd_q, t_rd2rd_q, t_wr2wr_q, t_wtr_q, t_rtw_q, t_mrd_q, t_mod_q;
  logic [9:0]                   t_rfc_q, t_zq_q, t_dllk_q;
  logic [3:0][7:0]              t_faw_q;
  logic [1:0]                   faw_ptr_q;
  logic [19:0]                  ref_gap_q;
  // bursts
  logic [SchDepth-1:0]             rs_v_q, rs_v_d, ws_v_q, ws_v_d, pt_v_q, pt_v_d;
  logic [SchDepth-1:0][BIdxW-1:0]  rs_a_q, rs_a_d, ws_a_q, ws_a_d;
  logic [4:0]                      rsh_q;      // [k]: the read's data start D = (this edge - k) + 3
  logic [BurstBits-2*DqBits-1:0]   rbuf_q;     // pairs 1..3 of the burst being read
  logic                            wexp_q;
  logic [1:0]                      wcnt_q;
  logic [BIdxW-1:0]                wcur_q;
  logic [2:0][2*DqBits-1:0]        wbuf_q;     // pairs 0..2 of the burst being written
  logic [2:0][2*Lanes-1:0]         wbe_q;
  logic                            ram_we;     // RAM write, one edge after the fourth pair
  logic [BIdxW-1:0]                ram_wa;
  logic [BurstBits-1:0]            ram_wd;
  logic [BurstBytes-1:0]           ram_wbe;
  logic                            wfull;      // the fourth pair arrives at this edge
  logic                            byp_hit_w;  // the RAM read at this edge misses the write in progress
  logic                            byp_hit_f;  // ... or the burst completed at this edge
  logic [RamLat-1:0]               byp_v_q;    // [k]: the RAM read k + 1 edges ago missed a write
  logic [RamLat-1:0][BurstBits-1:0]  byp_d_q;
  logic [RamLat-1:0][BurstBytes-1:0] byp_be_q;
  logic [BurstBits-1:0]            rd_burst;   // ram_rd with the bypassed write merged
  logic [BIdxW-1:0]                ram_ra;
  logic [BurstBits-1:0]            ram_rd;     // actual data of the read issued 2 cycles ago
  logic [1:0][DqBits-1:0]          rd_dq_q;
  logic                            rd_oe_q, rd_pre_q;
  // errors
  logic [NE-1:0]                   ev;
  logic [7:0]                      err_code_q;
  logic [15:0]                     err_count_q;
  logic [31:0]                     err_cycle_q;
  logic                            live_q;     // out of reset (messages)

  // ------------------------------------------------------------ decode
  cmd_e   kind;
  logic   is_cmd, awake, cmd_ok, zq2;
  logic   rd_now, wr_now, issue_now, imm_rd, la_rd, tok_now, dev_clr, busy, any_open, any_rp;
  logic [2:0] cb, la_cb;
  logic [BIdxW-1:0] cmd_bidx, la_bidx;
  logic [RowBits-1:0] la_row;
  mrdec_t dec, dec_new;
  logic [5:0] wl, rle, rd2pre, rd2wr;                 // registered (one edge after an MRS)
  logic [5:0] rl_c, wl_c, rle_c, rd2pre_c, rd2wr_c;  // decoded from the mode registers
  logic [3:0] rs_slot, ws_slot, pt_slot;
  logic [5:0] mrc;
  logic       dll_bad, dll_bad_new;   // DDR3 DLL-off constraints violated (now / after this MRS)

  always_comb begin
    unique case ({ras_n_i, cas_n_i, we_n_i})
      3'b000:  kind = CmdMrs;
      3'b001:  kind = CmdRef;
      3'b010:  kind = CmdPre;
      3'b011:  kind = CmdAct;
      3'b100:  kind = CmdWr;
      3'b101:  kind = CmdRd;
      3'b110:  kind = CmdZq;
      default: kind = CmdNop;
    endcase
  end

  assign cb      = ba_i & 3'(NBanks - 1);
  assign is_cmd  = !cs_n_i && (kind != CmdNop);
  assign awake   = !(ist_q inside {IPwr, IRst, ICkeL, IPdn});
  // a command registered by the device (CKE high at this and the previous edge)
  assign zq2     = !Ddr3 && kind == CmdZq;
  assign cmd_ok  = ck_en_i && is_cmd && cke_i && cke_q && awake && (!Ddr3 || reset_n_i) && !zq2;
  assign rd_now  = cmd_ok && kind == CmdRd;
  assign wr_now  = cmd_ok && kind == CmdWr;
  assign cmd_bidx = {row_q[cb], cb[BankBits-1:0], a_i[ColBits-1:3]};
  // lookahead RD (pins of the next edge; an ACT to that bank at this edge gives the row)
  assign la_cb    = la_ba_i & 3'(NBanks - 1);
  assign la_row   = (!cs_n_i && kind == CmdAct && cb == la_cb) ? a_i[RowBits-1:0] : row_q[la_cb];
  assign la_bidx  = {la_row, la_cb[BankBits-1:0], la_a_i[ColBits-1:3]};
  assign la_rd    = Lookahead && !la_cs_n_i && ({la_ras_n_i, la_cas_n_i, la_we_n_i} == 3'b101) &&
                    (rle == 6'd3);
  assign any_open = (open_q & 8'((32'd1 << NBanks) - 1)) != 8'd0;

  always_comb begin
    any_rp = 1'b0;
    for (int unsigned b = 0; b < NBanks; b++) any_rp |= (t_rp_q[b] != 8'd0);
  end

  // latencies from the mode registers
  always_comb begin
    logic [2:0][15:0] mrn;
    logic [5:0]       rl_raw;
    dec    = mr_decode(mr_q[2:0]);
    rl_raw = {1'b0, dec.al} + {1'b0, dec.cl};
    rl_c   = rl_raw;
    wl_c   = Ddr3 ? ({1'b0, dec.al} + {1'b0, dec.cwl}) : rl_raw - 6'd1;
    rle_c  = (Ddr3 && dec.dll_off) ? rl_raw - 6'd1 : rl_raw;
    if (rle_c < 6'd3)  rle_c = 6'd3;
    if (rle_c > 6'd18) rle_c = 6'd18;
    if (wl_c < 6'd1)   wl_c = 6'd1;
    if (wl_c > 6'd16)  wl_c = 6'd16;
    rd2pre_c = Ddr3 ? {1'b0, dec.al} + ((TRtp > 4) ? 6'(TRtp) : 6'd4)
                    : {1'b0, dec.al} + 6'd2 + ((TRtp > 2) ? 6'(TRtp) : 6'd2);
    rd2wr_c  = Ddr3 ? rl_c + 6'd6 - wl_c : 6'd6;
    rs_slot  = 4'(rle - 6'd2 - 6'(RamLat));   // RAM array read at D - 1 - RamLat
    pt_slot  = 4'(rle - 6'd4);                 // data start token at D - 3
    ws_slot  = 4'(wl - 6'd1);
    // mode registers after this MRS
    mrn = mr_q[2:0];
    for (int unsigned r = 0; r < 3; r++) begin
      if (ba_i[1:0] == 2'(r)) mrn[r] = a_i;
    end
    dec_new = mr_decode(mrn);
    mrc     = mr_check(ba_i[1:0], a_i);
    dll_bad     = Ddr3 && dec.dll_off && (dec.cl != 5'd6 || dec.cwl != 5'd6 ||
                                          dec.rtt_nom != 3'd0 || dec.rtt_wr != 2'd0);
    dll_bad_new = Ddr3 && dec_new.dll_off && (dec_new.cl != 5'd6 || dec_new.cwl != 5'd6 ||
                                              dec_new.rtt_nom != 3'd0 || dec_new.rtt_wr != 2'd0);
  end

  logic unused_dec;   // MR3 (only checked when written), decode fields of no use here,
                      // lookahead address bits outside the column, issue_now (Sparse only)
  assign unused_dec = ^{dec_new.al, dec_new.rdqs, mr_q[3], la_a_i, issue_now};

  assign busy = (rs_v_q != '0) || (pt_v_q != '0) || (rsh_q != '0) || rd_oe_q || rd_pre_q || (ws_v_q != '0) ||
                wexp_q;

  // ------------------------------------------------------------ checks
  always_comb begin
    ev    = '0;
    ist_d = ist_q;
    // ---------------- init sequence
    if (!CheckInit) begin
      ist_d = IDone;
    end else if (Ddr3 && !reset_n_i) begin
      ist_d = IRst;
    end else begin
      unique case (ist_q)
        IPwr: if (cke_i) begin
          if (icnt_q < 20'(TInit)) ev[EInitTime] = 1'b1;
          if (is_cmd)              ev[EInitNop]  = 1'b1;
          ist_d = INop;
        end
        IRst: begin                                 // RESET# rising edge
          if (icnt_q < 20'(TReset))                ev[EInitTime] = 1'b1;
          if (cke_i || ckel_q < 8'(TCkeRst))       ev[EInitCke]  = 1'b1;
          ist_d = ICkeL;
        end
        ICkeL: if (cke_i) begin
          if (icnt_q < 20'(TCkeLow))  ev[EInitCke] = 1'b1;
          if (ckrun_q < 8'(TCkRun))   ev[EInitCk]  = 1'b1;
          if (odt_i)                  ev[EInitOdt] = 1'b1;
          if (is_cmd)                 ev[EInitNop] = 1'b1;
          ist_d = IXpr;
        end
        IPdn:  if (cke_i && !cke_q && !pdn_err_q) ev[EInitCke] = 1'b1;
        IDone: if (!cke_i) ist_d = Ddr3 ? IPdn : IPwr;
        default: begin                              // command driven init states
          if (!cke_i) begin
            if (Ddr3) begin
              ev[EInitCke] = 1'b1;
              ist_d        = IPdn;
            end else begin
              ist_d = IPwr;
            end
          end else if (cmd_ok) begin
            unique case (ist_q)
              INop: begin
                if (icnt_q < 20'(TInitNop)) ev[EInitNop] = 1'b1;
                if (kind == CmdPre && a_i[10]) ist_d = IEmr2;
                else                           ev[EInitOrder] = 1'b1;
              end
              // EMRS2 and EMRS3 in either order: IEmr3 = EMRS2 seen, EMRS3
              // due; IEmr2b = EMRS3 seen, EMRS2 due
              IEmr2: if (kind == CmdMrs && ba_i == 3'd2)      ist_d = IEmr3;
                     else if (kind == CmdMrs && ba_i == 3'd3) ist_d = IEmr2b;
                     else if (kind != CmdPre)                 ev[EInitOrder] = 1'b1;
              IEmr3: if (kind == CmdMrs && ba_i == 3'd3) ist_d = IEmr1;
                     else if (kind != CmdPre)            ev[EInitOrder] = 1'b1;
              IEmr2b: if (kind == CmdMrs && ba_i == 3'd2) ist_d = IEmr1;
                      else if (kind != CmdPre)            ev[EInitOrder] = 1'b1;
              IEmr1: if (kind == CmdMrs && ba_i == 3'd1) begin
                       if (a_i[0] || a_i[9:7] != 3'b000) ev[EInitMr] = 1'b1;
                       ist_d = IMrDll;
                     end else if (kind != CmdPre) ev[EInitOrder] = 1'b1;
              IMrDll: if (kind == CmdMrs && ba_i == 3'd0) begin
                       if (!a_i[8]) ev[EInitMr] = 1'b1;
                       ist_d = IPrea2;
                     end else if (kind != CmdPre) ev[EInitOrder] = 1'b1;
              IPrea2: if (kind == CmdPre && a_i[10]) ist_d = IRef;
                      else if (kind != CmdPre)       ev[EInitOrder] = 1'b1;
              IRef:  if (kind == CmdRef) begin
                       if (nref_q) ist_d = IMr;
                     end else if (kind != CmdPre) ev[EInitOrder] = 1'b1;
              IMr:   if (kind == CmdMrs && ba_i == 3'd0) begin
                       if (a_i[8]) ev[EInitMr] = 1'b1;
                       ist_d = IOcdDef;
                     end else if (kind != CmdPre && kind != CmdRef) ev[EInitOrder] = 1'b1;
              IOcdDef: if (kind == CmdMrs && ba_i == 3'd1) begin
                       if (a_i[9:7] != 3'b111) ev[EInitMr]   = 1'b1;
                       if (t_dllk_q != 10'd0)  ev[EOcdEarly] = 1'b1;
                       ist_d = IOcdExit;
                     end else if (kind != CmdPre) ev[EInitOrder] = 1'b1;
              IOcdExit: if (kind == CmdMrs && ba_i == 3'd1) begin
                       if (a_i[9:7] != 3'b000) ev[EInitMr] = 1'b1;
                       ist_d = IDone;
                     end else if (kind != CmdPre) ev[EInitOrder] = 1'b1;
              IXpr: begin
                if (icnt_q < 20'(TXpr)) ev[EInitNop] = 1'b1;
                if (kind == CmdMrs && ba_i == 3'd2) ist_d = IMr3;
                else if (kind != CmdPre)            ev[EInitOrder] = 1'b1;
              end
              IMr3:  if (kind == CmdMrs && ba_i == 3'd3) ist_d = IMr1;
                     else if (kind != CmdPre)            ev[EInitOrder] = 1'b1;
              IMr1:  if (kind == CmdMrs && ba_i == 3'd1) ist_d = IMr0;
                     else if (kind != CmdPre)            ev[EInitOrder] = 1'b1;
              IMr0:  if (kind == CmdMrs && ba_i == 3'd0) begin
                       if (!dec.dll_off && !a_i[8]) ev[EInitMr] = 1'b1;
                       ist_d = IZqcl;
                     end else if (kind != CmdPre) ev[EInitOrder] = 1'b1;
              IZqcl: if (kind == CmdZq && a_i[10]) ist_d = IDone;
                     else if (kind != CmdPre)      ev[EInitOrder] = 1'b1;
              default: ;
            endcase
          end
        end
      endcase
      // ODT: DDR2 low until EMRS1; DDR3 DLL-off: low after init
      if (!Ddr3 && odt_i && !odt_q && (ist_q inside {IPwr, INop, IEmr2, IEmr3, IEmr2b, IEmr1})) begin
        ev[EInitOdt] = 1'b1;
      end
    end

    // ---------------- DDR3 DLL-off constraints (at init done, MRS, ODT rising)
    if (Ddr3 && ist_d == IDone && ist_q != IDone && CheckInit &&
        (dll_bad || (dec.dll_off && odt_i))) begin
      ev[EMrDllOff] = 1'b1;
    end
    if (Ddr3 && ist_q == IDone && dec.dll_off && odt_i && !odt_q) ev[EMrDllOff] = 1'b1;

    // ---------------- commands
    if (ck_en_i && is_cmd && cke_i && cke_q && awake && zq2) ev[EZqDdr2] = 1'b1;
    if (cmd_ok) begin
      unique case (kind)
        CmdAct: begin
          if ((ba_i >> BankBits) != 3'd0)        ev[EBankRange] = 1'b1;
          if ((32'(a_i) >> RowBits) != 32'd0)    ev[ERowRange]  = 1'b1;
          if (open_q[cb])                        ev[EActOpen]   = 1'b1;
          if (t_rp_q[cb] != 8'd0)                ev[ETrp]       = 1'b1;
          if (t_rc_q[cb] != 8'd0)                ev[ETrc]       = 1'b1;
          if (t_rrd_q != 8'd0)                   ev[ETrrd]      = 1'b1;
          if (TFaw != 0 && t_faw_q[faw_ptr_q] != 8'd0) ev[ETfaw] = 1'b1;
        end
        CmdRd, CmdWr: begin
          if ((ba_i >> BankBits) != 3'd0)        ev[EBankRange]  = 1'b1;
          if (a_i[10])                           ev[EAutoPre]    = 1'b1;
          if ((a_i & ~ColOk) != 16'd0)           ev[EColRange]   = 1'b1;
          if (!open_q[cb])                       ev[EBankClosed] = 1'b1;
          if (t_rcd_q[cb] != 8'd0)               ev[ETrcd]       = 1'b1;
          if (kind == CmdRd) begin
            if (t_rd2rd_q != 8'd0)               ev[ETccd] = 1'b1;
            if (t_wtr_q != 8'd0)                 ev[ETwtr] = 1'b1;
            if (t_dllk_q != 10'd0 && !dec.dll_off) ev[EDllk] = 1'b1;
          end else begin
            if (t_wr2wr_q != 8'd0)               ev[ETccd] = 1'b1;
            if (t_rtw_q != 8'd0)                 ev[ETrtw] = 1'b1;
          end
        end
        CmdPre: begin
          if (a_i[10]) begin
            for (int unsigned b = 0; b < NBanks; b++) begin
              if (open_q[b]) begin
                if (t_ras_q[b] != 8'd0) ev[ETras] = 1'b1;
                if (t_wtp_q[b] != 8'd0) ev[ETwr]  = 1'b1;
                if (t_rtp_q[b] != 8'd0) ev[ETrtp] = 1'b1;
              end
            end
          end else begin
            if ((ba_i >> BankBits) != 3'd0) ev[EBankRange] = 1'b1;
            if (open_q[cb]) begin
              if (t_ras_q[cb] != 8'd0) ev[ETras] = 1'b1;
              if (t_wtp_q[cb] != 8'd0) ev[ETwr]  = 1'b1;
              if (t_rtp_q[cb] != 8'd0) ev[ETrtp] = 1'b1;
            end
          end
        end
        CmdRef, CmdZq: begin
          if (any_open) ev[EBankOpen] = 1'b1;
          if (any_rp)   ev[ETrp]      = 1'b1;
        end
        CmdMrs: begin
          if (any_open) ev[EBankOpen] = 1'b1;
          if (any_rp)   ev[ETrp]      = 1'b1;
          if (busy)     ev[EMrsBusy]  = 1'b1;
          if (ba_i[2])  ev[EMrUnsup]  = 1'b1;
          if (mrc[0])   ev[EMrBl]     = 1'b1;
          if (mrc[1])   ev[EMrCl]     = 1'b1;
          if (mrc[2])   ev[EMrAl]     = 1'b1;
          if (mrc[3])   ev[EMrDll]    = 1'b1;
          if (mrc[4])   ev[EMrRdqs]   = 1'b1;
          if (mrc[5])   ev[EMrUnsup]  = 1'b1;
          if (ist_q == IDone && dll_bad_new) ev[EMrDllOff] = 1'b1;
        end
        default: ;
      endcase
      // command spacing that applies to every command
      if (Ddr3) begin
        if (kind == CmdMrs) begin
          if (t_mrd_q != 8'd0) ev[ETmrd] = 1'b1;
        end else if (t_mod_q != 8'd0) begin
          ev[ETmod] = 1'b1;
        end
      end else if (t_mrd_q != 8'd0) begin
        ev[ETmrd] = 1'b1;
      end
      if (t_rfc_q != 10'd0) ev[ETrfc] = 1'b1;
      if (t_zq_q != 10'd0)  ev[ETzq]  = 1'b1;
    end

    // ---------------- per edge
    // (a burst cut by a device reset at this edge is dropped, not missing:
    // the controller was reset in the middle of it; same condition as dev_clr)
    if (wexp_q && !wr_v_i &&
        !(CheckInit && ((Ddr3 && !reset_n_i) || ((ist_d == IPwr || ist_d == IPdn) && ist_q != ist_d)))) begin
      ev[EWrData] = 1'b1;
    end
    if (TRasMax != 0) begin
      for (int unsigned b = 0; b < NBanks; b++) begin
        if (open_q[b] && age_q[b] == RasMax) ev[ETrasMax] = 1'b1;
      end
    end
    if (TRefi != 0 && ist_q == IDone && ref_gap_q == RefMax) ev[ERefStarve] = 1'b1;
    if (!ck_en_i) ev = '0;
  end

  // the state the device returns to: RESET# low, CKE-low reset, power down
  assign dev_clr = CheckInit && ((Ddr3 && !reset_n_i) ||
                                 ((ist_d == IPwr || ist_d == IPdn) && ist_q != ist_d));

  // ------------------------------------------------------------ schedules
  // rs_*[k] / ws_*[k] in cycle c: event at the posedge c + 1 + k
  //   read:  RAM array read (data start = that posedge + 3)
  //   write: first expected pair (wr_expect_o from that posedge)
  always_comb begin
    rs_v_d = rs_v_q >> 1;
    rs_a_d = rs_a_q >> BIdxW;
    pt_v_d = pt_v_q >> 1;
    ws_v_d = ws_v_q >> 1;
    ws_a_d = ws_a_q >> BIdxW;
    if (rd_now && rle > 6'(RamLat + 1)) begin
      rs_v_d[rs_slot] = 1'b1;
      rs_a_d[rs_slot] = cmd_bidx;
    end
    if (rd_now && rle > 6'd3) pt_v_d[pt_slot] = 1'b1;
    if (wr_now) begin
      ws_v_d[ws_slot] = 1'b1;
      ws_a_d[ws_slot] = cmd_bidx;
    end
    if (dev_clr) begin
      rs_v_d = '0;
      pt_v_d = '0;
      ws_v_d = '0;
    end
  end

  // RAM write one edge after the edge that brings the fourth pair (registered
  // inputs: the UltraRAM cascade gets a full cycle). A RAM read at the same
  // edge as that write returns the old data: the write is merged into it on
  // the way out (bypass), so a RD at WR edge + WL + 5 (tWTR = 1) sees the burst.
  assign wfull     = ck_en_i && wexp_q && (wcnt_q == 2'd3) && !dev_clr;
  assign byp_hit_w = ram_we && (ram_wa == ram_ra);
  assign byp_hit_f = wfull && (wcur_q == ram_ra);      // RamLat 3: read before the RAM write
  always_comb begin
    rd_burst = ram_rd;
    for (int unsigned b = 0; b < BurstBytes; b++) begin
      if (byp_v_q[RamLat-1] && byp_be_q[RamLat-1][b]) rd_burst[8 * b +: 8] = byp_d_q[RamLat-1][8 * b +: 8];
    end
  end

  // RAM array read at this posedge: a scheduled read, a RD now (RLe = RamLat + 1)
  // or the lookahead RD of the next edge (RLe = 3, RamLat = 3). The data start
  // token (rsh) is set at D - 3 by the RD itself (RLe = 3) or by pt.
  assign imm_rd    = rd_now && (rle == 6'(RamLat + 1));
  assign issue_now = !dev_clr && (rs_v_q[0] || imm_rd || la_rd);
  assign ram_ra    = rs_v_q[0] ? rs_a_q[0] : la_rd ? la_bidx : cmd_bidx;
  assign tok_now   = !dev_clr && (pt_v_q[0] || (rd_now && rle == 6'd3));

  // ------------------------------------------------------- sequential
  function automatic int unsigned first_set(logic [NE-1:0] v);
    int unsigned r;
    r = 0;
    for (int i = NE - 1; i >= 0; i--) begin
      if (v[i]) r = i;
    end
    return r;
  endfunction

  function automatic logic [15:0] count_set(logic [NE-1:0] v);
    logic [15:0] n;
    n = '0;
    for (int unsigned i = 0; i < NE; i++) n += {15'd0, v[i]};
    return n;
  endfunction

  logic [2*DqBits-1:0] wpair;
  logic [2*Lanes-1:0]  wpbe;
  always_comb begin
    wpair = {wr_dq_i[1], wr_dq_i[0]};
    for (int unsigned k = 0; k < 2; k++) begin
      for (int unsigned l = 0; l < Lanes; l++) begin
        wpbe[k * Lanes + l] = wr_v_i && (!wr_dm_i[k][l] || (!Ddr3 && dec.rdqs && !RdqsTied));
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ist_q       <= CheckInit ? (Ddr3 ? IRst : IPwr) : IDone;
      icnt_q      <= '0;
      ckel_q      <= '0;
      ckrun_q     <= '0;
      {wl, rle, rd2pre, rd2wr} <= LatInit;
      nref_q      <= 1'b0;
      pdn_err_q   <= 1'b0;
      cyc_q       <= '0;
      cke_q       <= 1'b0;
      odt_q       <= 1'b0;
      mr_q        <= {Mr3Init, Mr2Init, Mr1Init, Mr0Init};
      open_q      <= '0;
      row_q       <= '0;
      t_rcd_q     <= '0;
      t_ras_q     <= '0;
      t_rc_q      <= '0;
      t_rp_q      <= '0;
      t_wtp_q     <= '0;
      t_rtp_q     <= '0;
      age_q       <= '0;
      t_rrd_q     <= '0;
      t_rd2rd_q   <= '0;
      t_wr2wr_q   <= '0;
      t_wtr_q     <= '0;
      t_rtw_q     <= '0;
      t_mrd_q     <= '0;
      t_mod_q     <= '0;
      t_rfc_q     <= '0;
      t_zq_q      <= '0;
      t_dllk_q    <= '0;
      t_faw_q     <= '0;
      faw_ptr_q   <= '0;
      ref_gap_q   <= '0;
      rs_v_q      <= '0;
      rs_a_q      <= '0;
      pt_v_q      <= '0;
      ws_v_q      <= '0;
      ws_a_q      <= '0;
      rsh_q       <= '0;
      rbuf_q      <= '0;
      ram_we      <= 1'b0;
      ram_wa      <= '0;
      ram_wd      <= '0;
      ram_wbe     <= '0;
      byp_v_q     <= '0;
      byp_d_q     <= '0;
      byp_be_q    <= '0;
      wexp_q      <= 1'b0;
      wcnt_q      <= '0;
      wcur_q      <= '0;
      wbuf_q      <= '0;
      wbe_q       <= '0;
      rd_dq_q     <= '0;
      rd_oe_q     <= 1'b0;
      rd_pre_q    <= 1'b0;
      err_code_q  <= '0;
      err_count_q <= '0;
      err_cycle_q <= '0;
      live_q      <= 1'b0;
    end else begin
      live_q  <= 1'b1;
      ckrun_q <= ck_en_i ? up8(ckrun_q) : 8'd0;
      if (ck_en_i) begin
        cyc_q     <= cyc_q + 32'd1;
        {wl, rle, rd2pre, rd2wr} <= {wl_c, rle_c, rd2pre_c, rd2wr_c};
        cke_q     <= cke_i;
        odt_q     <= odt_i;
        ckel_q    <= cke_i ? 8'd0 : up8(ckel_q);
        ist_q     <= ist_d;
        icnt_q    <= (ist_d != ist_q) ? 20'd1 : up20(icnt_q);
        if (ist_d == IRef && ist_q != IRef)                  nref_q <= 1'b0;
        else if (ist_q == IRef && cmd_ok && kind == CmdRef)  nref_q <= 1'b1;
        if (ist_d == IRst)                                       pdn_err_q <= 1'b0;
        else if (ist_q == IPdn && ev[EInitCke])                  pdn_err_q <= 1'b1;

        // ---------------- timers count down / up
        for (int unsigned b = 0; b < 8; b++) begin
          t_rcd_q[b] <= dn8(t_rcd_q[b]);
          t_ras_q[b] <= dn8(t_ras_q[b]);
          t_rc_q[b]  <= dn8(t_rc_q[b]);
          t_rp_q[b]  <= dn8(t_rp_q[b]);
          t_wtp_q[b] <= dn8(t_wtp_q[b]);
          t_rtp_q[b] <= dn8(t_rtp_q[b]);
          if (open_q[b]) age_q[b] <= up20(age_q[b]);
        end
        for (int unsigned k = 0; k < 4; k++) t_faw_q[k] <= dn8(t_faw_q[k]);
        t_rrd_q   <= dn8(t_rrd_q);
        t_rd2rd_q <= dn8(t_rd2rd_q);
        t_wr2wr_q <= dn8(t_wr2wr_q);
        t_wtr_q   <= dn8(t_wtr_q);
        t_rtw_q   <= dn8(t_rtw_q);
        t_mrd_q   <= dn8(t_mrd_q);
        t_mod_q   <= dn8(t_mod_q);
        t_rfc_q   <= dn10(t_rfc_q);
        t_zq_q    <= dn10(t_zq_q);
        t_dllk_q  <= dn10(t_dllk_q);
        if (ist_q == IDone) ref_gap_q <= up20(ref_gap_q);
        if (ist_d == IDone && ist_q != IDone) ref_gap_q <= '0;

        // ---------------- commands
        if (dev_clr) begin
          open_q <= '0;
          if (Ddr3 && !reset_n_i) mr_q <= {Mr3Init, Mr2Init, Mr1Init, Mr0Init};
        end else if (cmd_ok) begin
          unique case (kind)
            CmdAct: begin
              open_q[cb]  <= 1'b1;
              row_q[cb]   <= a_i[RowBits-1:0];
              age_q[cb]   <= '0;
              t_rcd_q[cb] <= ld8(TRcd);
              t_ras_q[cb] <= ld8(TRas);
              t_rc_q[cb]  <= ld8(TRc);
              t_rrd_q     <= ld8(TRrd);
              if (TFaw != 0) begin
                t_faw_q[faw_ptr_q] <= ld8(TFaw);
                faw_ptr_q          <= faw_ptr_q + 2'd1;
              end
            end
            CmdRd: begin
              t_rtp_q[cb] <= 8'(rd2pre) - 8'd1;
              t_rd2rd_q   <= 8'd3;
              t_rtw_q     <= 8'(rd2wr) - 8'd1;
            end
            CmdWr: begin
              t_wtp_q[cb] <= 8'(wl) + 8'd3 + 8'(TWr);
              t_wr2wr_q   <= 8'd3;
              t_wtr_q     <= 8'(wl) + 8'd3 + 8'(TWtr);
            end
            CmdPre: begin
              if (a_i[10]) begin
                for (int unsigned b = 0; b < NBanks; b++) begin
                  if (open_q[b]) begin
                    open_q[b]  <= 1'b0;
                    t_rp_q[b]  <= ld8(TRpa);
                  end
                end
              end else if (open_q[cb]) begin
                open_q[cb] <= 1'b0;
                t_rp_q[cb] <= ld8(TRp);
              end
            end
            CmdRef: begin
              t_rfc_q   <= ld10(TRfc);
              ref_gap_q <= '0;
            end
            CmdMrs: begin
              mr_q[ba_i[1:0]] <= a_i;
              t_mrd_q         <= ld8(TMrd);
              t_mod_q         <= ld8(Ddr3 ? TMod : TMrd);
              if (ba_i[1:0] == 2'd0 && a_i[8] && !dec.dll_off) t_dllk_q <= ld10(TDllk);
            end
            CmdZq: t_zq_q <= ld10((ist_q == IZqcl) ? TZqInit : a_i[10] ? TZqOper : TZqCs);
            default: ;
          endcase
        end

        // ---------------- bursts
        rs_v_q <= rs_v_d;
        rs_a_q <= rs_a_d;
        pt_v_q <= pt_v_d;
        ws_v_q <= ws_v_d;
        ws_a_q <= ws_a_d;
        rsh_q  <= dev_clr ? 5'd0 : {rsh_q[3:0], tok_now};
        // read data for edge t+1: preamble, pair 0 straight from the RAM, pairs 1..3
        rd_oe_q  <= !dev_clr && (rsh_q[4:1] != 4'd0);
        rd_pre_q <= !dev_clr && rsh_q[0] && (rsh_q[4:1] == 4'd0);
        if (rsh_q[1]) begin
          rbuf_q  <= rd_burst[BurstBits-1:2*DqBits];
          rd_dq_q <= {rd_burst[DqBits +: DqBits], rd_burst[0 +: DqBits]};
        end else if (rsh_q[2]) begin
          rd_dq_q <= {rbuf_q[1 * DqBits +: DqBits], rbuf_q[0 * DqBits +: DqBits]};
        end else if (rsh_q[3]) begin
          rd_dq_q <= {rbuf_q[3 * DqBits +: DqBits], rbuf_q[2 * DqBits +: DqBits]};
        end else if (rsh_q[4]) begin
          rd_dq_q <= {rbuf_q[5 * DqBits +: DqBits], rbuf_q[4 * DqBits +: DqBits]};
        end else begin
          rd_dq_q <= '0;
        end
        // write: expectations, pairs 0..2, then the burst to the RAM write registers
        if (wexp_q && wcnt_q != 2'd3) begin
          wbuf_q[wcnt_q] <= wpair;
          wbe_q[wcnt_q]  <= wpbe;
        end
        ram_we <= wfull;
        if (wfull) begin
          ram_wa  <= wcur_q;
          ram_wd  <= {wpair, wbuf_q[2], wbuf_q[1], wbuf_q[0]};
          ram_wbe <= {wpbe, wbe_q[2], wbe_q[1], wbe_q[0]};
        end
        // bypass: follows the RAM read pipeline (array read, output register)
        byp_v_q[0]  <= byp_hit_w || byp_hit_f;
        byp_d_q[0]  <= byp_hit_f ? {wpair, wbuf_q[2], wbuf_q[1], wbuf_q[0]} : ram_wd;
        byp_be_q[0] <= byp_hit_f ? {wpbe, wbe_q[2], wbe_q[1], wbe_q[0]} : ram_wbe;
        for (int unsigned k = 1; k < RamLat; k++) begin
          byp_v_q[k]  <= byp_v_q[k-1];
          byp_d_q[k]  <= byp_d_q[k-1];
          byp_be_q[k] <= byp_be_q[k-1];
        end
        if (dev_clr) begin
          wexp_q <= 1'b0;
        end else if (ws_v_q[0]) begin
          wexp_q <= 1'b1;
          wcnt_q <= 2'd0;
          wcur_q <= ws_a_q[0];
        end else if (wexp_q) begin
          if (wcnt_q == 2'd3) wexp_q <= 1'b0;
          wcnt_q <= wcnt_q + 2'd1;
        end

        // ---------------- errors
        if (ev != '0) begin
          err_count_q <= (err_count_q > 16'hFFFF - count_set(ev)) ? 16'hFFFF
                                                                    : err_count_q + count_set(ev);
          if (err_count_q == 16'd0) begin
            err_code_q  <= code_of(first_set(ev));
            err_cycle_q <= cyc_q;
          end
        end
      end
    end
  end

  assign wr_expect_o = wexp_q;
  assign rd_dq_o     = rd_dq_q;
  assign rd_oe_o     = rd_oe_q;
  assign rd_pre_o    = rd_pre_q;
  assign err_code_o  = err_code_q;
  assign err_count_o = err_count_q;
  assign err_cycle_o = err_cycle_q;
  assign init_done_o = (ist_q == IDone);

  // ------------------------------------------------------------ storage
  // write port: ram_we / ram_wa / ram_wd / ram_wbe (byte enables), at a CK edge;
  // read port: array read at a CK edge with ram_ra, then RamLat - 1 output
  // registers (CK edges): ram_rd = data of the read issued RamLat edges before.
`ifndef SYNTHESIS
  /* verilator lint_off BLKSEQ */
  if (Sparse) begin : g_sparse
    logic [BurstBits-1:0]  sp_mem [int unsigned];
    logic [BurstBytes-1:0] sp_wr  [int unsigned];
    logic [RamLat-1:0][BurstBits-1:0] q;
    int unsigned           unwritten = 0;   // bytes read that were never written

    function automatic logic [BurstBits-1:0] sp_read(logic [BIdxW-1:0] a);
      logic [BurstBits-1:0]  d;
      logic [BurstBytes-1:0] w;
      d = A5s;
      w = '0;
      if (sp_mem.exists(32'(a)) != 0) begin
        d = sp_mem[32'(a)];
        w = sp_wr[32'(a)];
      end
      for (int unsigned b = 0; b < BurstBytes; b++) begin
        if (!w[b]) d[8 * b +: 8] = 8'hA5;
      end
      return d;
    endfunction

    always @(posedge clk_i) begin
      logic [BurstBits-1:0]  d;
      logic [BurstBytes-1:0] w;
      if (ck_en_i) begin
        q <= {q[RamLat-2:0], sp_read(ram_ra)};
        if (issue_now) begin
          w = (sp_mem.exists(32'(ram_ra)) != 0) ? sp_wr[32'(ram_ra)] : '0;
          if (w != '1) begin
            if (unwritten == 0) begin
              $display("%m: note: edge %0d: read of never written bytes (0xA5), counted in %m.unwritten",
                       cyc_q);
            end
            unwritten += BurstBytes - $countones(w);
          end
        end
      end
      if (ram_we) begin
        d = (sp_mem.exists(32'(ram_wa)) != 0) ? sp_mem[32'(ram_wa)] : A5s;
        w = (sp_mem.exists(32'(ram_wa)) != 0) ? sp_wr[32'(ram_wa)] : '0;
        for (int unsigned b = 0; b < BurstBytes; b++) begin
          if (ram_wbe[b]) d[8 * b +: 8] = ram_wd[8 * b +: 8];
        end
        sp_mem[32'(ram_wa)] = d;
        sp_wr[32'(ram_wa)]  = w | ram_wbe;
      end
    end
    assign ram_rd = q[RamLat-1];
  end else
  /* verilator lint_on BLKSEQ */
`endif
  if (UseUram) begin : g_uram
    (* ram_style = "ultra" *) logic [BurstBits-1:0] mem [Depth];
    logic [RamLat-1:0][BurstBits-1:0] q;
`ifndef SYNTHESIS
    initial begin
      for (int unsigned i = 0; i < Depth; i++) mem[i] = '0;
    end
`endif
    always_ff @(posedge clk_i) begin
      if (ram_we) begin
        for (int unsigned b = 0; b < BurstBytes; b++) begin
          if (ram_wbe[b]) mem[ram_wa[RamAw-1:0]][8 * b +: 8] <= ram_wd[8 * b +: 8] ^ 8'hA5;
        end
      end
      if (ck_en_i) begin
        q <= {q[RamLat-2:0], mem[ram_ra[RamAw-1:0]]};
      end
    end
    assign ram_rd = q[RamLat-1] ^ A5s;
    logic unused_hi;   // burst index bits above the storage alias
    assign unused_hi = ^{ram_ra >> RamAw, ram_wa >> RamAw};
  end else begin : g_bram
    logic [BurstBits-1:0] mem [Depth];
    logic [RamLat-1:0][BurstBits-1:0] q;
`ifndef SYNTHESIS
    initial begin
      for (int unsigned i = 0; i < Depth; i++) mem[i] = '0;
    end
`endif
    always_ff @(posedge clk_i) begin
      if (ram_we) begin
        for (int unsigned b = 0; b < BurstBytes; b++) begin
          if (ram_wbe[b]) mem[ram_wa[RamAw-1:0]][8 * b +: 8] <= ram_wd[8 * b +: 8] ^ 8'hA5;
        end
      end
      if (ck_en_i) begin
        q <= {q[RamLat-2:0], mem[ram_ra[RamAw-1:0]]};
      end
    end
    assign ram_rd = q[RamLat-1] ^ A5s;
    logic unused_hi;   // burst index bits above the storage alias
    assign unused_hi = ^{ram_ra >> RamAw, ram_wa >> RamAw};
  end

  // ------------------------------------------------------------ messages
`ifdef SYNTHESIS
  logic unused_sim;
  assign unused_sim = ^{Sparse, FatalOnError, live_q};
`else
  function automatic string cmd_name(cmd_e k);
    unique case (k)
      CmdMrs:  return "MRS";
      CmdRef:  return "REF";
      CmdPre:  return a_i[10] ? "PREA" : "PRE";
      CmdAct:  return "ACT";
      CmdWr:   return "WR";
      CmdRd:   return "RD";
      CmdZq:   return Ddr3 ? (a_i[10] ? "ZQCL" : "ZQCS") : "ZQ(reserved)";
      default: return "NOP";
    endcase
  endfunction

  function automatic string err_text(int unsigned i);
    unique case (i)
      EInitOrder:  return $sformatf("init order: %s not expected in init state %s", cmd_name(kind),
                                    ist_q.name());
      EInitTime:   return Ddr3 ? $sformatf("RESET# high after %0d edges < tRESET %0d", icnt_q, TReset)
                               : $sformatf("CKE high after %0d edges of clock < tINIT %0d", icnt_q,
                                           TInit);
      EInitNop:    return $sformatf("%s %0d edges after CKE high (< %0d) or at the CKE edge",
                                    cmd_name(kind), icnt_q, Ddr3 ? TXpr : TInitNop);
      EInitCke:    return (ist_q == IRst) ? $sformatf("CKE not low %0d edges before RESET# high (%0d)",
                                                      TCkeRst, ckel_q)
                        : (ist_q == ICkeL) ? $sformatf("CKE high %0d edges after RESET# (< tCKE_LOW %0d)",
                                                       icnt_q, TCkeLow)
                        : "CKE low during init or CKE high again without RESET#";
      EInitCk:     return $sformatf("CK running %0d edges before CKE high (< %0d)", ckrun_q, TCkRun);
      EInitOdt:    return Ddr3 ? "ODT high at CKE high" : "ODT high before EMRS1";
      EInitMr:     return $sformatf("init mode register word BA %0d A 0x%04h not the required one",
                                    ba_i, a_i);
      EOcdEarly:   return $sformatf("EMRS1 OCD default %0d edges too early after the DLL reset (200 nCK)",
                                    t_dllk_q);
      EDllk:       return $sformatf("RD %0d edges too early after the DLL reset (tDLLK %0d)", t_dllk_q,
                                    TDllk);
      EActOpen:    return $sformatf("ACT to open bank %0d (row 0x%0h)", cb, row_q[cb]);
      EBankClosed: return $sformatf("%s to closed bank %0d", cmd_name(kind), cb);
      EBankOpen:   return $sformatf("%s with bank(s) open (0x%02h)", cmd_name(kind), open_q);
      EAutoPre:    return $sformatf("%s with A10 = 1 (auto precharge not supported)", cmd_name(kind));
      EBankRange:  return $sformatf("bank %0d beyond BankBits %0d", ba_i, BankBits);
      ERowRange:   return $sformatf("row 0x%04h beyond RowBits %0d", a_i, RowBits);
      EColRange:   return $sformatf("%s address 0x%04h: column beyond ColBits %0d, unaligned or stray bits",
                                    cmd_name(kind), a_i, ColBits);
      EMrsBusy:    return "MRS while a read / write burst is in flight";
      EZqDdr2:     return "ZQ encoding is reserved in DDR2";
      ETrcd:       return $sformatf("tRCD: bank %0d needs %0d more edge(s)", cb, t_rcd_q[cb]);
      ETras:       return "tRAS: PRE too early after ACT";
      ETrc:        return $sformatf("tRC: bank %0d needs %0d more edge(s)", cb, t_rc_q[cb]);
      ETrp:        return (kind == CmdAct) ? $sformatf("tRP: bank %0d needs %0d more edge(s)", cb,
                                                       t_rp_q[cb])
                                           : $sformatf("tRP: %s while a bank is precharging",
                                                       cmd_name(kind));
      ETrrd:       return $sformatf("tRRD: %0d more edge(s)", t_rrd_q);
      ETfaw:       return $sformatf("tFAW: fifth ACT %0d edge(s) early", t_faw_q[faw_ptr_q]);
      ETwr:        return "tWR: PRE too early after WR (WL + 4 + tWR)";
      ETrtp:       return "RD to PRE too early";
      ETccd:       return $sformatf("%s < 4 edges after the previous %s (BL8)", cmd_name(kind),
                                    cmd_name(kind));
      ETwtr:       return $sformatf("WR to RD: %0d more edge(s) (WL + 4 + tWTR)", t_wtr_q);
      ETrtw:       return $sformatf("RD to WR: %0d more edge(s)", t_rtw_q);
      ETmrd:       return $sformatf("tMRD: %s %0d edge(s) early after MRS", cmd_name(kind), t_mrd_q);
      ETmod:       return $sformatf("tMOD: %s %0d edge(s) early after MRS", cmd_name(kind), t_mod_q);
      ETrfc:       return $sformatf("tRFC: %s %0d edge(s) early after REF", cmd_name(kind), t_rfc_q);
      ETzq:        return $sformatf("tZQ: %s %0d edge(s) early after ZQ", cmd_name(kind), t_zq_q);
      ETrasMax:    return "tRAS(max): a bank stayed open too long";
      ERefStarve:  return $sformatf("refresh starvation: no REF for %0d edges (9 * tREFI)", RefMax);
      EMrBl:       return $sformatf("MRS BA %0d A 0x%04h: burst length is not 8", ba_i, a_i);
      EMrCl:       return $sformatf("MRS BA %0d A 0x%04h: CAS latency not supported", ba_i, a_i);
      EMrAl:       return $sformatf("MRS BA %0d A 0x%04h: additive latency != 0", ba_i, a_i);
      EMrDll:      return "EMRS1 A0 = 1: DLL disabled (not supported in DDR2)";
      EMrRdqs:     return RdqsTied ? "EMRS1 A11 = 1: RDQS enabled but the DM/RDQS ball is tied"
                                   : "EMRS1 A11 = 1: RDQS not available on x16";
      EMrDllOff:   return $sformatf("DLL-off mode needs CL = CWL = 6, RTT off and ODT low (CL %0d CWL %0d)",
                                    dec_new.cl, dec_new.cwl);
      EMrUnsup:    return $sformatf("MRS BA %0d A 0x%04h: unsupported or reserved value", ba_i, a_i);
      EWrData:     return "write beats expected but no DQS strobes seen";
      default:     return "?";
    endcase
  endfunction

  always @(posedge clk_i) begin
    if (live_q && ck_en_i && ev != '0) begin
      for (int unsigned i = 0; i < NE; i++) begin
        if (ev[i]) begin
          if (FatalOnError) begin
            $fatal(1, "%m: edge %0d: [0x%02h] %s", cyc_q, code_of(i), err_text(i));
          end else begin
            $error("%m: edge %0d: [0x%02h] %s", cyc_q, code_of(i), err_text(i));
          end
        end
      end
    end
  end
`endif

endmodule
