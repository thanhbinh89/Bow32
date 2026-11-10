// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Shared definitions of the Bow32 HyperRAM IP (bow_hyperram: HyperBus master
// for HyperRAM 2.0, e.g. Infineon S80KS2562 256 Mb x8 1.8 V). docs/ip/hyperram.md.
//
// Pad bundles: the only interface between the technology independent IP
// (hw/ip/hyperram) and the board pad wrapper (hw/fpga/common/rtl/
// bow_hyperram_io_xilinx.sv, or the behavioural twin hw/ip/hyperram/dv/
// bow_hyperram_io_sim.sv in simulation).
//
// Timing contract of hr_io_out_t (T = CK period; "PHY cycle j" = the hr_clk
// cycle in which the PHY register holds a value; "pin cycle j+1" = [(j+1)T,
// (j+2)T), which starts with the CK rising edge of that cycle when ck_en):
//   * ck_en: CK_P high during [(j+1)T, (j+1.5)T), low otherwise; CK_N = ~CK_P.
//   * cs_n, rst_n, ls_oe_n, ls_dir_dq, ls_dir_rwds: on the pins during pin
//     cycle j+1.
//   * dq / rwds at write phase 0: dq[0] (byte A, first byte of the word) on
//     the pins during [(j+0.75)T, (j+1.25)T), centred on the CK rising edge of
//     pin cycle j+1; dq[1] (byte B) during [(j+1.25)T, (j+1.75)T), centred on
//     its falling edge. A write phase of w fine steps delays DQ and RWDS by
//     w * T / PsSteps (|w| <= 3 * PsSteps / 16, bow_hyperram_ctrl).
//   * dq_oe / rwds_oe: 1 = the FPGA drives the pads, from (j+1)T (Versal XPIO,
//     bow_hyperram_io_xilinx TFromOddr = 1: during [(j+1.25)T, (j+2.25)T) +
//     write phase, T from an ODDR in the pad site).
// hr_io_in_t is in the read capture clock domain (hr_rd_clk, same frequency,
// calibrated phase): dq[0] / rwds[0] = sample at hr_rd_clk rising edge k,
// dq[1] / rwds[1] = sample at the following falling edge, both presented
// after rising edge k+1. The RWDS pad level (latency indication of the CA
// phase) also reaches the core as an asynchronous wire (bow_hyperram rwds_pad_i).
//
// HyperBus transaction cycles (bow_hyperram_ctrl, docs): t = 0 is the first
// PHY cycle with cs_n = 0; the device's CK cycle k is PHY cycle t = k. CA in
// t = 1..3, the first data word of a read / memory write in t_D = L + 3 (1x
// latency) or 2L + 3 (2x), of a register write in t = 4.
//
// Data order: memory space is little endian on the bus (bus byte 2n = byte A
// of HyperRAM word n, 2n+1 = byte B); register space is big endian (byte A =
// register bits [15:8]), as the HyperBus specification defines.
package bow_hyperram_pkg;

  localparam logic [31:0] IdValue = 32'h4852_4D01;   // "HRM", version 1

  // ---------------------------------------------------------------------------
  // Pads
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic            cs_n;
    logic            ck_en;        // CK pulse in this pin cycle
    logic            rst_n;
    logic [1:0][7:0] dq;           // [0] byte A (CK rising), [1] byte B (CK falling)
    logic            dq_oe;
    logic [1:0]      rwds;         // [0] A, [1] B (write data mask: 1 = byte not written)
    logic            rwds_oe;
    logic            ls_oe_n;      // level shifters OE# (all packages)
    logic            ls_dir_dq;    // 1: HyperRAM -> FPGA
    logic            ls_dir_rwds;  // 1: HyperRAM -> FPGA
  } hr_io_out_t;

  typedef struct packed {
    logic [1:0][7:0] dq;           // [0] rising edge sample, [1] following falling edge
    logic [1:0]      rwds;
  } hr_io_in_t;

  // Pads after reset / with the PHY disabled: CS# high, CK low, RESET# high,
  // DQ / RWDS driven low (no floating inputs behind the shifters), shifters
  // isolated, DIR = FPGA -> HyperRAM.
  localparam hr_io_out_t HR_IO_OUT_IDLE = '{
    cs_n: 1'b1, rst_n: 1'b1, dq_oe: 1'b1, rwds_oe: 1'b1, ls_oe_n: 1'b1, default: '0
  };
  // The PHY register in the channel reset: the same, but DQ / RWDS released.
  // A reset can cut a read whose data the level shifters still drive towards
  // the FPGA (DIR = HyperRAM -> FPGA): OE# and DIR change at the first edge of
  // the reset, the FPGA drives again only after the reset, at least one cycle
  // later (the shifters' outputs are off by then: no drive overlap). Meanwhile
  // the board keeps the released lines at a valid level (MPS4 card build: FPGA
  // pull-downs, constr/hyperram_card.xdc).
  localparam hr_io_out_t HR_IO_OUT_RST = '{
    cs_n: 1'b1, rst_n: 1'b1, ls_oe_n: 1'b1, default: '0
  };

  // ---------------------------------------------------------------------------
  // HyperBus protocol
  // ---------------------------------------------------------------------------
  // Command / address word (48 bits, CA[47:40] first). waddr = word address.
  function automatic logic [47:0] hr_ca(logic rd, logic reg_space, logic linear,
                                        logic [31:0] waddr);
    return {rd, reg_space, linear, waddr[31:3], 13'd0, waddr[2:0]};
  endfunction

  // Register space (CA bits 46 = 1): word address of ID0, ID1, CR0, CR1.
  typedef enum logic [1:0] {
    RegId0 = 2'd0,
    RegId1 = 2'd1,
    RegCr0 = 2'd2,
    RegCr1 = 2'd3
  } hr_reg_e;

  function automatic logic [31:0] hr_reg_waddr(logic [1:0] sel);
    return {20'd0, sel[1], 8'd0, 2'd0, sel[0]};    // CR*: system address bit 11
  endfunction

  // CR0 initial latency field [7:4] -> clocks (3..7). Reserved codes read as 7
  // (the default, valid at every frequency the device supports).
  function automatic logic [2:0] cr0_lat(logic [3:0] code);   // code = CR0[7:4]
    unique case (code)
      4'b1110: return 3'd3;
      4'b1111: return 3'd4;
      4'b0000: return 3'd5;
      4'b0001: return 3'd6;
      default: return 3'd7;
    endcase
  endfunction

  function automatic logic cr0_lat_valid(logic [3:0] code);   // code = CR0[7:4]
    return code inside {4'b1110, 4'b1111, 4'b0000, 4'b0001, 4'b0010};
  endfunction

  // Register values after power-up / hardware reset (S80KS2562 datasheet,
  // tables 7-12). CR1[1:0] (read only, distributed refresh interval) is 01
  // (4 us, industrial) or 10 (1 us, +105 / +125 C parts) on a real device.
  localparam logic [15:0] Cr0Default = 16'h8F2F;   // normal, 34 ohm, 7 clk, fixed, legacy, 32 B
  localparam logic [15:0] Cr1Default = 16'hFFC1;   // single ended CK, full refresh, 4 us

  // ---------------------------------------------------------------------------
  // Configuration of the hr_clk domain (registers CTRL / LAT / TIM / TRST /
  // TWAKE copied by APPLY; docs: register map)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic        en;          // transactions allowed, pins out of the disabled state
    logic        ls_en;       // level shifters enabled (OE# low)
    logic        idle_drive;  // FPGA drives DQ / RWDS low between transactions
    logic        strict;      // read aligner: RWDS must toggle every half cycle
    logic [3:0]  rdir_lead;   // read: ls_dir_dq = 1 this many cycles before the data
    logic [3:0]  rdir_tail;   // read: ls_dir_* back to 0 this many cycles after CS# rises
    logic [1:0]  oe_pre;      // read: FPGA releases DQ this many cycles before ls_dir_dq
    logic [1:0]  oe_post;     // FPGA drives again this many cycles after ls_dir_* fell
    logic [3:0]  rw_dir;      // memory write: t at which ls_dir_rwds returns to 0
    logic [3:0]  rw_oe;       // memory write: t from which the FPGA drives RWDS
    logic [3:0]  arm_lead;    // read aligner armed this many cycles before the data
    logic [4:0]  rd_dly;      // stream delay (PHY cycle -> read stream cycle)
    logic [3:0]  rd_tmo;      // aligner: data must start within arm_lead + rd_tmo
    logic [3:0]  lat_smp;     // t at which the CA-phase RWDS level is taken
    logic [3:0]  cshi;        // minimum CS# high cycles between transactions
    logic [11:0] tcsm;        // maximum CS# low cycles of a transaction
    logic [1:0]  rd_hold;     // read: CS# stays low this many cycles after the last
                              // word, CK stopped (the device holds byte B until CS#
                              // rises: margin for the last byte, tOZ has no minimum)
    logic [15:0] trst_low;    // HW_RESET: RESET# low cycles
    logic [15:0] trst_wait;   // HW_RESET: cycles after RESET# rises
    logic [15:0] twake_cs;    // WAKE: CS# low cycles
    logic [15:0] twake_wait;  // WAKE: cycles after CS# rises
  } cfg_t;

  // ---------------------------------------------------------------------------
  // Window <-> controller channel (async FIFOs, clk_i <-> hr_clk)
  // ---------------------------------------------------------------------------
  // Line / write block = 32 bytes = 8 bus words = 16 HyperRAM words.
  localparam int unsigned LineBytes = 32;
  localparam int unsigned LineAw    = 23;               // line index bits (byte address >> 5): 256 MiB

  typedef enum logic [1:0] {
    WopRdLine = 2'd0,   // fill a line (16 HyperRAM words; wrapped if wrap and CR0 allows)
    WopRdWord = 2'd1,   // one bus word (2 HyperRAM words), uncached read
    WopWr     = 2'd2    // bus words first..last of a block, byte enables per word
  } wop_e;

  // Command entry (36 payload bits + header flag): a header (36 bits), then for WopWr
  // (last - first + 1) data entries {be, data}.
  typedef struct packed {
    logic [1:0]        op;       // wop_e
    logic              posted;   // WopWr: no WDONE response (errors go to STATUS)
    logic              wrap;     // WopRdLine: wrapped burst, critical word first
    logic [2:0]        crit;     // WopRdLine / WopRdWord: bus word index
    logic [2:0]        first;    // WopWr: first bus word index of the block
    logic [2:0]        last;     // WopWr: last bus word index
    logic [LineAw-1:0] line;     // line / block index (byte address >> 5)
  } whdr_t;

  localparam int unsigned WcmdW = 37;   // {is_hdr, payload[35:0]}

  typedef enum logic [1:0] {
    WrespData  = 2'd0,   // next bus word of a line fill / word read, in linear order
    WrespDataW = 2'd1,   // same, wrapped order (critical word first)
    WrespWdone = 2'd2,   // non-posted write done
    WrespErr   = 2'd3    // the read / write failed (data = error code)
  } wresp_e;

  localparam int unsigned WrespW = 34;  // {kind[1:0], data[31:0]}

  // Error codes of WrespErr / ERR_CODE
  localparam logic [7:0] ErrNone    = 8'd0;
  localparam logic [7:0] ErrRdTmo   = 8'd1;   // read data did not start in time
  localparam logic [7:0] ErrRwds    = 8'd2;   // RWDS did not toggle as a strobe (strict)
  localparam logic [7:0] ErrTcsm    = 8'd3;   // transaction longer than TCSM: refused
  localparam logic [7:0] ErrPower   = 8'd4;   // device in deep power down / hybrid sleep
  localparam logic [7:0] ErrDisable = 8'd5;   // EN = 0, no CLK_OK, channel in reset
  localparam logic [7:0] ErrRfifo   = 8'd6;   // read FIFO broken
  localparam logic [7:0] ErrArg     = 8'd7;   // argument refused: malformed CMD, ID0 / ID1 write,
                                              // reserved CR0 latency code, phase step beyond its
                                              // limit, BIST_GO during a run
  localparam logic [7:0] ErrPs      = 8'd8;   // phase step: no PSDONE from the MMCM (the phase
                                              // moved by the steps acknowledged so far)

  // ---------------------------------------------------------------------------
  // Command channel (bow_hyperram_regs -> bow_hyperram_ctrl), one at a time
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    HcApply     = 4'd0,
    HcPsGo      = 4'd1,
    HcWpsGo     = 4'd2,
    HcRfifoSync = 4'd3,
    HcCapArm    = 4'd4,
    HcHwReset   = 4'd5,
    HcRegRd     = 4'd6,
    HcRegWr     = 4'd7,
    HcWake      = 4'd8,
    HcBistGo    = 4'd9,
    HcBistStop  = 4'd10,
    HcSnap      = 4'd11,
    HcClrStats  = 4'd12
  } hcmd_e;

  // Device power state (STATUS.POWER)
  typedef enum logic [1:0] {
    PwrActive = 2'd0,
    PwrDpd    = 2'd1,   // deep power down: data lost, WAKE or HW_RESET
    PwrHs     = 2'd2,   // hybrid sleep: data kept, WAKE or HW_RESET
    PwrWait   = 2'd3    // reset / wake recovery time running
  } pwr_e;

  // ---------------------------------------------------------------------------
  // Register map (peripheral slot, 4 KiB)
  // ---------------------------------------------------------------------------
  localparam logic [11:0] RegIdOff     = 12'h000;
  localparam logic [11:0] RegInfoOff   = 12'h004;
  localparam logic [11:0] RegCtrlOff   = 12'h008;
  localparam logic [11:0] RegCmdOff    = 12'h00C;
  localparam logic [11:0] RegStatusOff = 12'h010;
  localparam logic [11:0] RegIrqEnOff  = 12'h014;
  localparam logic [11:0] RegLatOff    = 12'h018;
  localparam logic [11:0] RegTim0Off   = 12'h01C;
  localparam logic [11:0] RegTrstOff   = 12'h020;
  localparam logic [11:0] RegTwakeOff  = 12'h024;
  localparam logic [11:0] RegSelOff    = 12'h028;
  localparam logic [11:0] RegDataOff   = 12'h02C;
  localparam logic [11:0] RegCr0Off    = 12'h030;
  localparam logic [11:0] RegCr1Off    = 12'h034;
  localparam logic [11:0] RegPsTgtOff  = 12'h038;
  localparam logic [11:0] RegPsNowOff  = 12'h03C;
  localparam logic [11:0] RegWpsTgtOff = 12'h040;
  localparam logic [11:0] RegWpsNowOff = 12'h044;
  localparam logic [11:0] RegClkHzOff  = 12'h048;
  localparam logic [11:0] RegErrAdOff  = 12'h04C;
  localparam logic [11:0] RegEmuOff    = 12'h050;
  localparam logic [11:0] RegDbgOff    = 12'h054;
  localparam logic [11:0] RegErrCdOff  = 12'h058;
  localparam logic [11:0] RegWbTmoOff  = 12'h05C;
  localparam logic [11:0] RegBCtrlOff  = 12'h060;
  localparam logic [11:0] RegBAddrOff  = 12'h064;
  localparam logic [11:0] RegBLenOff   = 12'h068;
  localparam logic [11:0] RegBSeedOff  = 12'h06C;
  localparam logic [11:0] RegBCycOff   = 12'h070;
  localparam logic [11:0] RegBErrsOff  = 12'h074;
  localparam logic [11:0] RegBFAddrOff = 12'h078;
  localparam logic [11:0] RegBFDataOff = 12'h07C;
  localparam logic [11:0] RegStOff     = 12'h080;   // 0x080..0x0BC: 16 statistics
  localparam logic [11:0] RegCapOff    = 12'h100;   // 0x100..0x1FC: 64 capture words

  // CTRL bits
  localparam int unsigned CtrlEn        = 0;   // hr (APPLY)
  localparam int unsigned CtrlLsEn      = 1;   // hr (APPLY)
  localparam int unsigned CtrlIdleDrive = 2;   // hr (APPLY)
  localparam int unsigned CtrlStrict    = 3;   // hr (APPLY)
  localparam int unsigned CtrlInitDone  = 8;   // window open (with STATUS.READY)
  localparam int unsigned CtrlRbufEn    = 9;   // read buffer (line fills)
  localparam int unsigned CtrlWrapFill  = 10;  // fills as wrapped bursts (critical word first)
  localparam int unsigned CtrlWpost     = 11;  // posted writes, write combining
  localparam int unsigned CtrlCoreRst   = 12;  // reset the controller + window channel (immediate)
  localparam logic [31:0] CtrlReset     = 32'h0000_060C;   // IDLE_DRIVE STRICT RBUF_EN WRAP_FILL

  // CMD bits (exactly one per write)
  localparam int unsigned CmdApply     = 0;
  localparam int unsigned CmdPsGo      = 1;
  localparam int unsigned CmdWpsGo     = 2;
  localparam int unsigned CmdRfifoSync = 3;
  localparam int unsigned CmdCapArm    = 4;
  localparam int unsigned CmdHwReset   = 5;
  localparam int unsigned CmdRegRd     = 6;
  localparam int unsigned CmdRegWr     = 7;
  localparam int unsigned CmdWake      = 8;
  localparam int unsigned CmdFlush     = 9;
  localparam int unsigned CmdInval     = 10;
  localparam int unsigned CmdBistGo    = 11;
  localparam int unsigned CmdBistStop  = 12;
  localparam int unsigned CmdSnap      = 13;
  localparam int unsigned CmdClrStats  = 14;
  localparam int unsigned CmdBits      = 15;

  // STATUS bits (R = read only, else write 1 to clear)
  localparam int unsigned StBusy       = 0;    // R  command running
  localparam int unsigned StReady      = 1;    // R  window open
  localparam int unsigned StClkOk      = 2;    // R  hr_clk running, link up
  localparam int unsigned StApplied    = 3;    // R  an APPLY with EN = 1 is in effect
  localparam int unsigned StPwr0       = 4;    // R  [5:4] power state (pwr_e)
  localparam int unsigned StBistBusy   = 6;    // R
  localparam int unsigned StBroken     = 7;    // R  window dead after a timeout (CORE_RST)
  localparam int unsigned StCmdDone    = 8;
  localparam int unsigned StCmdErr     = 9;
  localparam int unsigned StCapDone    = 10;
  localparam int unsigned StBistDone   = 11;
  localparam int unsigned StRdErr      = 12;   // a read transaction failed
  localparam int unsigned StWrErr      = 13;   // a posted write failed
  localparam int unsigned StRfifoErr   = 14;
  localparam int unsigned StBusTimeout = 15;
  localparam int unsigned StNotReady   = 16;
  localparam int unsigned StRange      = 17;
  localparam int unsigned StBistErr    = 18;
  localparam int unsigned StTcsmErr    = 19;
  localparam int unsigned StDbgErr     = 20;   // R  board debug word flags an error
  localparam int unsigned StRfifoBrk   = 21;   // R  read FIFO broken until RFIFO_SYNC
  localparam int unsigned StWinIdle    = 22;   // R  window: no fill, no posted data, channel empty
  localparam logic [31:0] StatusRoMask = 32'h0070_00FF;

endpackage
