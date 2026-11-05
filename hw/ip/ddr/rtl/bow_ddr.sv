// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 DDR2/DDR3 SDRAM IP (docs/ip/ddr.md): the LiteDRAM controller core
// (hw/ip/ddr/litedram/generated, DdrMem = 2: litedram_ddr2, 3: litedram_ddr3)
// on Bow32's own PHY behind a DFI adapter. Three bus ports:
//   mem_* memory window on the main crossbar (0x8000_0000, 512 MiB decode,
//         MemBytes of DRAM) -> LiteDRAM native port (bow_ddr_win)
//   csr_* LiteDRAM CSRs (DFII, BIST, init status) on the peripheral bus
//         (0x4000_C000, 8 KiB) -> Wishbone wb_ctrl (bow_ddr_csr)
//   reg_* PHY / bridge registers on the peripheral bus (0x4000_E000,
//         bow_ddr_regs)
// irq_o goes to irq_fast[11]. bow_ddr_stub has the same ports (DdrEn = 0).
//
//  clk_i:       bow_ddr_regs (registers, command channel, STATUS / IRQ,
//               CLK_OK), clk_i sides of bow_ddr_win and bow_ddr_csr
//  ddr_sys_clk: LiteDRAM core (bank machines, refresh, DFII, BIST, native
//               port, CSRs), ddr_sys sides of the two bridges, DFI capture
//               of bow_ddr_dfi
//  ddr_clk:     bow_ddr_dfi (DFI phases -> one PHY command per CK, read
//               return, command executor: APPLY, PS / WPS steppers,
//               RFIFO_SYNC, CAP_ARM, statistics), bow_ddr_phy (pads, read
//               FIFO write side in rd_clk)
//
//   bus ---> bow_ddr_win ----native----+
//   bus ---> bow_ddr_csr ---wb_ctrl---> litedram_ddr<2|3> --DFI 1:4--> bow_ddr_dfi
//   bus ---> bow_ddr_regs --cmd chan------------------------------------^   |
//                                                     ddr_io_* <-- bow_ddr_phy
//
// Clocks and resets: clk_i / rst_ni = SoC clock and sys_rst_n;
// ddr_sys_clk_i = controller clock CK / 4 from the same MMCM as ddr_clk_i
// (CK, 0 deg), every ddr_sys_clk_i rising edge is a ddr_clk_i rising edge;
// ddr_rd_clk_i = read capture clock (same frequency as CK, fine phase shift
// of its MMCM: ddr_ps_*); the write phase (wclk / wclk90, ddr_wps_*) is only
// seen by the pad wrapper. ddr_rst_ni = the MMCMs are locked (asynchronous).
// The link reset ddr_rst_ni & rst_ni is synchronised into each domain
// (lnk_sys_n, lnk_dsys_n, lnk_ddr_n, lnk_rd_n): it resets every CDC flop on
// both sides and the whole ddr_sys / ddr_clk / rd_clk logic, so a ddr-only
// reset (MMCM lock lost) leaves no half-done transfer behind; the register
// file keeps its values (sys_rst_n only). The bridge reset = link reset or
// CTRL.CORE_RST (bri_sys_n, bri_dsys_n) holds both bridges and the LiteDRAM
// core (synchronous reset rst = !bri_dsys_n) in reset. The MMCM phase
// steppers (read and write phase counters) use ddr_rst_ni alone (mmcm_ddr_n):
// the board resets the MMCMs only with their lock, so a SoC reset must not
// clear counters whose MMCM phases stay where they are.
//
// The pads: ddr_io_o (ddr_clk domain) and ddr_io_i (rd_clk domain) carry the
// timing contract of bow_ddr_pkg to the technology wrapper
// (hw/fpga/common/rtl/bow_ddr_io_xilinx.sv, hw/ip/ddr/dv/bow_ddr_io_sim.sv).
// ddr_dbg_i is a status word of the board (loopback emulator), asynchronous.
//
// Static timing: ddr_sys_clk <-> ddr_clk paths are synchronous (same MMCM,
// timed). clk_i <-> ddr_sys_clk (bridges: 4-phase handshakes through
// bow_sync, quasi-static payloads and results; init_done / init_error /
// user_rst levels) and clk_i <-> ddr_clk (command channel, bow_sync levels,
// the raw capture buffer read by the register file after CAP_DONE) are
// asynchronous (set_max_delay -datapath_only).

module bow_ddr import bow_bus_pkg::*; import bow_ddr_pkg::*; #(
  parameter int unsigned DdrMem     = 2,             // 2: litedram_ddr2, 3: litedram_ddr3
  parameter int unsigned ClkHz      = 133_333_333,   // CK
  parameter int unsigned PsSteps    = 504,           // MMCM fine phase steps per CK period
  parameter int unsigned PhyKind    = 1,             // 1 pins, 2 loopback emulator (INFO)
  parameter int unsigned EmuBytes   = 0,             // emulator storage (EMU), 0 = none
  parameter int unsigned WinTimeout = 1 << 20        // clk_i cycles (window, CSR bridge)
) (
  input  logic        clk_i,
  input  logic        rst_ni,           // sys_rst_n

  input  bus_req_t    mem_req_i,
  output bus_rsp_t    mem_rsp_o,
  input  bus_req_t    csr_req_i,
  output bus_rsp_t    csr_rsp_o,
  input  bus_req_t    reg_req_i,
  output bus_rsp_t    reg_rsp_o,
  output logic        irq_o,

  input  logic        ddr_sys_clk_i,    // controller clock CK / 4, edges on ddr_clk_i edges
  input  logic        ddr_clk_i,        // CK-rate clock, 0 deg
  input  logic        ddr_rst_ni,       // asynchronous, active low (MMCMs locked)
  input  logic        ddr_rd_clk_i,     // read capture clock (fine phase shift)
  output logic        ddr_ps_en_o,      // read-phase MMCM PSEN (PSCLK = ddr_clk_i)
  output logic        ddr_ps_inc_o,     // read-phase MMCM PSINCDEC
  input  logic        ddr_ps_done_i,    // read-phase MMCM PSDONE
  output logic        ddr_wps_en_o,     // write-phase MMCM PSEN (PSCLK = ddr_clk_i)
  output logic        ddr_wps_inc_o,    // write-phase MMCM PSINCDEC
  input  logic        ddr_wps_done_i,   // write-phase MMCM PSDONE
  output ddr_io_out_t ddr_io_o,         // ddr_clk domain
  input  ddr_io_in_t  ddr_io_i,         // ddr_rd_clk_i domain
  input  logic [31:0] ddr_dbg_i         // board debug word, asynchronous
);

  // Parameters of the generated cores (litedram_ddr<2|3>_pkg, written by the
  // generator from hw/ip/ddr/litedram/ddr<2|3>.yml):
  //   DDR2: IS43DR86400E x8, 4 banks, 14 row / 10 column bits, 64 MiB, no DM / RESET#
  //   DDR3: MT41K64M16 x16, 8 banks, 13 row / 10 column bits, 128 MiB, DM, RESET#
  // Native port: one BL8 burst per word (NatBytes), address = offset / NatBytes.
  localparam bit          Ddr3        = (DdrMem == 3);
  localparam int unsigned DqBits      = Ddr3 ? litedram_ddr3_pkg::DqBits : litedram_ddr2_pkg::DqBits;
  localparam int unsigned Lanes       = DqBits / 8;
  localparam int unsigned AddrPins    = Ddr3 ? litedram_ddr3_pkg::AddrPins : litedram_ddr2_pkg::AddrPins;
  localparam int unsigned BankPins    = Ddr3 ? litedram_ddr3_pkg::BankPins : litedram_ddr2_pkg::BankPins;
  localparam bit          HasDm       = Ddr3 ? litedram_ddr3_pkg::HasDm : litedram_ddr2_pkg::HasDm;
  localparam bit          HasResetN   = Ddr3 ? litedram_ddr3_pkg::HasResetN : litedram_ddr2_pkg::HasResetN;
  localparam int unsigned NatBytes    = Ddr3 ? litedram_ddr3_pkg::NatBytes : litedram_ddr2_pkg::NatBytes;
  localparam int unsigned MemBytes    = Ddr3 ? litedram_ddr3_pkg::MemBytes : litedram_ddr2_pkg::MemBytes;
  localparam int unsigned NatAw       = Ddr3 ? litedram_ddr3_pkg::NatAw : litedram_ddr2_pkg::NatAw;
  localparam int unsigned ReadLatency = Ddr3 ? litedram_ddr3_pkg::ReadLatency :
                                               litedram_ddr2_pkg::ReadLatency;
  localparam int unsigned WriteLat    = Ddr3 ? litedram_ddr3_pkg::WriteLatency :
                                               litedram_ddr2_pkg::WriteLatency;
  localparam int unsigned CoreCkHz    = Ddr3 ? litedram_ddr3_pkg::CkHz : litedram_ddr2_pkg::CkHz;
  localparam int unsigned CoreTRefi   = Ddr3 ? litedram_ddr3_pkg::TRefi : litedram_ddr2_pkg::TRefi;

  // Elaboration checks (they stop lint and synthesis; the initial copies stop
  // simulations whose build turns USERFATAL into a warning, -Wno-fatal):
  //  * the adapter needs the write data with the WRITE (write_latency 0) and
  //    the geometry must fit bow_ddr_pkg's pad bundles;
  //  * the core counts its timings in controller cycles (CK / 4). A slower CK
  //    stretches them, which only the refresh interval cannot take: CoreTRefi
  //    cycles must stay <= 7.8 us (DDR2 core: CK >= 132.8 MHz). A faster CK
  //    shortens them: at most 1 % above the CK the core was generated for.
  if (WriteLat != 0 || DqBits != 8 * Lanes || NatBytes != 8 * Lanes ||
      DqBits > MaxDq || AddrPins > MaxAddr || BankPins > MaxBank ||
      MemBytes != (NatBytes << NatAw)) begin : g_bad_core
    $fatal(1, "bow_ddr: litedram_ddr%0d_pkg does not fit bow_ddr", DdrMem);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_ddr: litedram_ddr%0d_pkg does not fit bow_ddr", DdrMem);
`endif
  end
  if (64'(CoreTRefi) * 64'd4_000_000_000 > 64'(ClkHz) * 64'd7800) begin : g_bad_refi
    $fatal(1, "bow_ddr: ClkHz %0d too slow for litedram_ddr%0d (CK %0d Hz): %0d controller cycles between REF > 7.8 us",
           ClkHz, DdrMem, CoreCkHz, CoreTRefi);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_ddr: ClkHz %0d too slow for litedram_ddr%0d (refresh > 7.8 us)", ClkHz, DdrMem);
`endif
  end
  if (64'(ClkHz) * 100 > 64'(CoreCkHz) * 101) begin : g_bad_ck
    $fatal(1, "bow_ddr: ClkHz %0d more than 1 percent above the CK of litedram_ddr%0d (%0d Hz)",
           ClkHz, DdrMem, CoreCkHz);
`ifndef SYNTHESIS
    initial $fatal(1, "bow_ddr: ClkHz %0d more than 1 percent above the CK of litedram_ddr%0d", ClkHz,
                   DdrMem);
`endif
  end

  // ------------------------------------------------------------ link reset
  logic link_rst_n, bri_rst_n, core_rst;
  logic lnk_sys_n, lnk_dsys_n, lnk_ddr_n, lnk_rd_n, bri_sys_n, bri_dsys_n, mmcm_ddr_n;

  assign link_rst_n = ddr_rst_ni & rst_ni;
  assign bri_rst_n  = link_rst_n & ~core_rst;

  bow_rst_sync u_rst_sys (
    .clk_i  (clk_i),
    .rst_ni (link_rst_n),
    .rst_no (lnk_sys_n)
  );

  bow_rst_sync u_rst_dsys (
    .clk_i  (ddr_sys_clk_i),
    .rst_ni (link_rst_n),
    .rst_no (lnk_dsys_n)
  );

  bow_rst_sync u_rst_ddr (
    .clk_i  (ddr_clk_i),
    .rst_ni (link_rst_n),
    .rst_no (lnk_ddr_n)
  );

  bow_rst_sync u_rst_rd (
    .clk_i  (ddr_rd_clk_i),
    .rst_ni (link_rst_n),
    .rst_no (lnk_rd_n)
  );

  // the MMCM phases only return to 0 when the MMCMs are reset (lock lost):
  // the phase steppers use ddr_rst_ni alone, not the SoC reset
  bow_rst_sync u_rst_mmcm (
    .clk_i  (ddr_clk_i),
    .rst_ni (ddr_rst_ni),
    .rst_no (mmcm_ddr_n)
  );

  bow_rst_sync u_rst_bri_sys (
    .clk_i  (clk_i),
    .rst_ni (bri_rst_n),
    .rst_no (bri_sys_n)
  );

  bow_rst_sync u_rst_bri_dsys (
    .clk_i  (ddr_sys_clk_i),
    .rst_ni (bri_rst_n),
    .rst_no (bri_dsys_n)
  );

  // ------------------------------------------------------------- signals
  // LiteDRAM core
  logic                     core_rst_sys, core_busy, init_done, init_error;
  logic [3:0][AddrPins-1:0] dfi_address;
  logic [3:0][BankPins-1:0] dfi_bank;
  logic [3:0]               dfi_cs_n, dfi_ras_n, dfi_cas_n, dfi_we_n, dfi_cke, dfi_odt;
  logic [3:0]               dfi_reset_n, dfi_wrdata_en, dfi_rddata_en, dfi_rddata_valid;
  logic [3:0][2*DqBits-1:0] dfi_wrdata, dfi_rddata;
  logic [3:0][2*Lanes-1:0]  dfi_wrdata_mask;
  dfi_phase_t [3:0]         dfi;
  logic [3:0][2*MaxDq-1:0]  dfi_rddata_x;

  // native port (window)
  logic                     nat_cmd_valid, nat_cmd_ready, nat_cmd_we;
  logic [NatAw-1:0]         nat_cmd_addr;
  logic                     nat_wdata_valid, nat_wdata_ready, nat_rdata_valid, nat_rdata_ready;
  logic [8*NatBytes-1:0]    nat_wdata, nat_rdata;
  logic [NatBytes-1:0]      nat_wdata_we;

  // wb_ctrl (CSR bridge)
  logic [29:0]              wb_adr;
  logic [31:0]              wb_dat_w, wb_dat_r;
  logic [3:0]               wb_sel;
  logic                     wb_cyc, wb_stb, wb_ack, wb_we, wb_err;
  logic [2:0]               wb_cti;
  logic [1:0]               wb_bte;

  // registers <-> bridges
  logic        ready, csr_avail, abort, clk_lost, masked, win_dead, csr_dead;
  logic        win_nrdy, win_range, win_tmo, csr_err, csr_tmo, st_rd, st_wr, st_rmw;
  logic [31:0] err_addr;

  // registers <-> command executor (command channel)
  logic             cmd_req, cmd_ack, res_err;
  logic [2:0]       cmd_kind;
  cfg_t             cmd_cfg;
  logic [15:0]      cmd_target, ps_now, wps_now;
  logic [1:0][31:0] res_st;
  logic             ddr_up, ddr_div, rfifo_err_tgl, cap_done_tgl, rd_late_tgl, rd_extra_tgl;

  // adapter -> PHY
  cfg_t        phy_cfg;
  logic        phy_cmd_v, phy_cap, phy_rd_v, phy_cap_done, phy_idle;
  cmd_e        phy_cmd_code;
  logic [2:0]  phy_cmd_ba;
  logic [15:0] phy_cmd_a;
  burst_t      phy_wr_bytes, phy_rd_bytes;
  be_t         phy_wr_be;
  logic        rfifo_sync, rfifo_err, rfifo_broken;
  logic [31:0][2*MaxDq-1:0]    cap_dq;
  logic [31:0][2*MaxLanes-1:0] cap_dqs;

  // ---------------------------------------------------- LiteDRAM core
  assign core_rst_sys = !bri_dsys_n;

  if (Ddr3) begin : g_ddr3
    litedram_ddr3 u_core (
      .clk                            (ddr_sys_clk_i),
      .rst                            (core_rst_sys),
      .dfi_p0_address                 (dfi_address[0]),
      .dfi_p0_bank                    (dfi_bank[0]),
      .dfi_p0_cas_n                   (dfi_cas_n[0]),
      .dfi_p0_cke                     (dfi_cke[0]),
      .dfi_p0_cs_n                    (dfi_cs_n[0]),
      .dfi_p0_odt                     (dfi_odt[0]),
      .dfi_p0_ras_n                   (dfi_ras_n[0]),
      .dfi_p0_rddata                  (dfi_rddata[0]),
      .dfi_p0_rddata_en               (dfi_rddata_en[0]),
      .dfi_p0_rddata_valid            (dfi_rddata_valid[0]),
      .dfi_p0_reset_n                 (dfi_reset_n[0]),
      .dfi_p0_we_n                    (dfi_we_n[0]),
      .dfi_p0_wrdata                  (dfi_wrdata[0]),
      .dfi_p0_wrdata_en               (dfi_wrdata_en[0]),
      .dfi_p0_wrdata_mask             (dfi_wrdata_mask[0]),
      .dfi_p1_address                 (dfi_address[1]),
      .dfi_p1_bank                    (dfi_bank[1]),
      .dfi_p1_cas_n                   (dfi_cas_n[1]),
      .dfi_p1_cke                     (dfi_cke[1]),
      .dfi_p1_cs_n                    (dfi_cs_n[1]),
      .dfi_p1_odt                     (dfi_odt[1]),
      .dfi_p1_ras_n                   (dfi_ras_n[1]),
      .dfi_p1_rddata                  (dfi_rddata[1]),
      .dfi_p1_rddata_en               (dfi_rddata_en[1]),
      .dfi_p1_rddata_valid            (dfi_rddata_valid[1]),
      .dfi_p1_reset_n                 (dfi_reset_n[1]),
      .dfi_p1_we_n                    (dfi_we_n[1]),
      .dfi_p1_wrdata                  (dfi_wrdata[1]),
      .dfi_p1_wrdata_en               (dfi_wrdata_en[1]),
      .dfi_p1_wrdata_mask             (dfi_wrdata_mask[1]),
      .dfi_p2_address                 (dfi_address[2]),
      .dfi_p2_bank                    (dfi_bank[2]),
      .dfi_p2_cas_n                   (dfi_cas_n[2]),
      .dfi_p2_cke                     (dfi_cke[2]),
      .dfi_p2_cs_n                    (dfi_cs_n[2]),
      .dfi_p2_odt                     (dfi_odt[2]),
      .dfi_p2_ras_n                   (dfi_ras_n[2]),
      .dfi_p2_rddata                  (dfi_rddata[2]),
      .dfi_p2_rddata_en               (dfi_rddata_en[2]),
      .dfi_p2_rddata_valid            (dfi_rddata_valid[2]),
      .dfi_p2_reset_n                 (dfi_reset_n[2]),
      .dfi_p2_we_n                    (dfi_we_n[2]),
      .dfi_p2_wrdata                  (dfi_wrdata[2]),
      .dfi_p2_wrdata_en               (dfi_wrdata_en[2]),
      .dfi_p2_wrdata_mask             (dfi_wrdata_mask[2]),
      .dfi_p3_address                 (dfi_address[3]),
      .dfi_p3_bank                    (dfi_bank[3]),
      .dfi_p3_cas_n                   (dfi_cas_n[3]),
      .dfi_p3_cke                     (dfi_cke[3]),
      .dfi_p3_cs_n                    (dfi_cs_n[3]),
      .dfi_p3_odt                     (dfi_odt[3]),
      .dfi_p3_ras_n                   (dfi_ras_n[3]),
      .dfi_p3_rddata                  (dfi_rddata[3]),
      .dfi_p3_rddata_en               (dfi_rddata_en[3]),
      .dfi_p3_rddata_valid            (dfi_rddata_valid[3]),
      .dfi_p3_reset_n                 (dfi_reset_n[3]),
      .dfi_p3_we_n                    (dfi_we_n[3]),
      .dfi_p3_wrdata                  (dfi_wrdata[3]),
      .dfi_p3_wrdata_en               (dfi_wrdata_en[3]),
      .dfi_p3_wrdata_mask             (dfi_wrdata_mask[3]),
      .init_done                      (init_done),
      .init_error                     (init_error),
      .user_clk                       (),
      .user_rst                       (core_busy),
      .user_port_native_0_cmd_addr    (nat_cmd_addr),
      .user_port_native_0_cmd_ready   (nat_cmd_ready),
      .user_port_native_0_cmd_valid   (nat_cmd_valid),
      .user_port_native_0_cmd_we      (nat_cmd_we),
      .user_port_native_0_rdata_data  (nat_rdata),
      .user_port_native_0_rdata_ready (nat_rdata_ready),
      .user_port_native_0_rdata_valid (nat_rdata_valid),
      .user_port_native_0_wdata_data  (nat_wdata),
      .user_port_native_0_wdata_ready (nat_wdata_ready),
      .user_port_native_0_wdata_valid (nat_wdata_valid),
      .user_port_native_0_wdata_we    (nat_wdata_we),
      .wb_ctrl_ack                    (wb_ack),
      .wb_ctrl_adr                    (wb_adr),
      .wb_ctrl_bte                    (wb_bte),
      .wb_ctrl_cti                    (wb_cti),
      .wb_ctrl_cyc                    (wb_cyc),
      .wb_ctrl_dat_r                  (wb_dat_r),
      .wb_ctrl_dat_w                  (wb_dat_w),
      .wb_ctrl_err                    (wb_err),
      .wb_ctrl_sel                    (wb_sel),
      .wb_ctrl_stb                    (wb_stb),
      .wb_ctrl_we                     (wb_we)
    );
  end else begin : g_ddr2
    litedram_ddr2 u_core (
      .clk                            (ddr_sys_clk_i),
      .rst                            (core_rst_sys),
      .dfi_p0_address                 (dfi_address[0]),
      .dfi_p0_bank                    (dfi_bank[0]),
      .dfi_p0_cas_n                   (dfi_cas_n[0]),
      .dfi_p0_cke                     (dfi_cke[0]),
      .dfi_p0_cs_n                    (dfi_cs_n[0]),
      .dfi_p0_odt                     (dfi_odt[0]),
      .dfi_p0_ras_n                   (dfi_ras_n[0]),
      .dfi_p0_rddata                  (dfi_rddata[0]),
      .dfi_p0_rddata_en               (dfi_rddata_en[0]),
      .dfi_p0_rddata_valid            (dfi_rddata_valid[0]),
      .dfi_p0_reset_n                 (dfi_reset_n[0]),
      .dfi_p0_we_n                    (dfi_we_n[0]),
      .dfi_p0_wrdata                  (dfi_wrdata[0]),
      .dfi_p0_wrdata_en               (dfi_wrdata_en[0]),
      .dfi_p0_wrdata_mask             (dfi_wrdata_mask[0]),
      .dfi_p1_address                 (dfi_address[1]),
      .dfi_p1_bank                    (dfi_bank[1]),
      .dfi_p1_cas_n                   (dfi_cas_n[1]),
      .dfi_p1_cke                     (dfi_cke[1]),
      .dfi_p1_cs_n                    (dfi_cs_n[1]),
      .dfi_p1_odt                     (dfi_odt[1]),
      .dfi_p1_ras_n                   (dfi_ras_n[1]),
      .dfi_p1_rddata                  (dfi_rddata[1]),
      .dfi_p1_rddata_en               (dfi_rddata_en[1]),
      .dfi_p1_rddata_valid            (dfi_rddata_valid[1]),
      .dfi_p1_reset_n                 (dfi_reset_n[1]),
      .dfi_p1_we_n                    (dfi_we_n[1]),
      .dfi_p1_wrdata                  (dfi_wrdata[1]),
      .dfi_p1_wrdata_en               (dfi_wrdata_en[1]),
      .dfi_p1_wrdata_mask             (dfi_wrdata_mask[1]),
      .dfi_p2_address                 (dfi_address[2]),
      .dfi_p2_bank                    (dfi_bank[2]),
      .dfi_p2_cas_n                   (dfi_cas_n[2]),
      .dfi_p2_cke                     (dfi_cke[2]),
      .dfi_p2_cs_n                    (dfi_cs_n[2]),
      .dfi_p2_odt                     (dfi_odt[2]),
      .dfi_p2_ras_n                   (dfi_ras_n[2]),
      .dfi_p2_rddata                  (dfi_rddata[2]),
      .dfi_p2_rddata_en               (dfi_rddata_en[2]),
      .dfi_p2_rddata_valid            (dfi_rddata_valid[2]),
      .dfi_p2_reset_n                 (dfi_reset_n[2]),
      .dfi_p2_we_n                    (dfi_we_n[2]),
      .dfi_p2_wrdata                  (dfi_wrdata[2]),
      .dfi_p2_wrdata_en               (dfi_wrdata_en[2]),
      .dfi_p2_wrdata_mask             (dfi_wrdata_mask[2]),
      .dfi_p3_address                 (dfi_address[3]),
      .dfi_p3_bank                    (dfi_bank[3]),
      .dfi_p3_cas_n                   (dfi_cas_n[3]),
      .dfi_p3_cke                     (dfi_cke[3]),
      .dfi_p3_cs_n                    (dfi_cs_n[3]),
      .dfi_p3_odt                     (dfi_odt[3]),
      .dfi_p3_ras_n                   (dfi_ras_n[3]),
      .dfi_p3_rddata                  (dfi_rddata[3]),
      .dfi_p3_rddata_en               (dfi_rddata_en[3]),
      .dfi_p3_rddata_valid            (dfi_rddata_valid[3]),
      .dfi_p3_reset_n                 (dfi_reset_n[3]),
      .dfi_p3_we_n                    (dfi_we_n[3]),
      .dfi_p3_wrdata                  (dfi_wrdata[3]),
      .dfi_p3_wrdata_en               (dfi_wrdata_en[3]),
      .dfi_p3_wrdata_mask             (dfi_wrdata_mask[3]),
      .init_done                      (init_done),
      .init_error                     (init_error),
      .user_clk                       (),
      .user_rst                       (core_busy),
      .user_port_native_0_cmd_addr    (nat_cmd_addr),
      .user_port_native_0_cmd_ready   (nat_cmd_ready),
      .user_port_native_0_cmd_valid   (nat_cmd_valid),
      .user_port_native_0_cmd_we      (nat_cmd_we),
      .user_port_native_0_rdata_data  (nat_rdata),
      .user_port_native_0_rdata_ready (nat_rdata_ready),
      .user_port_native_0_rdata_valid (nat_rdata_valid),
      .user_port_native_0_wdata_data  (nat_wdata),
      .user_port_native_0_wdata_ready (nat_wdata_ready),
      .user_port_native_0_wdata_valid (nat_wdata_valid),
      .user_port_native_0_wdata_we    (nat_wdata_we),
      .wb_ctrl_ack                    (wb_ack),
      .wb_ctrl_adr                    (wb_adr),
      .wb_ctrl_bte                    (wb_bte),
      .wb_ctrl_cti                    (wb_cti),
      .wb_ctrl_cyc                    (wb_cyc),
      .wb_ctrl_dat_r                  (wb_dat_r),
      .wb_ctrl_dat_w                  (wb_dat_w),
      .wb_ctrl_err                    (wb_err),
      .wb_ctrl_sel                    (wb_sel),
      .wb_ctrl_stb                    (wb_stb),
      .wb_ctrl_we                     (wb_we)
    );
  end

  // DFI of the core, zero-extended to the bow_ddr_pkg phase layout
  always_comb begin
    for (int unsigned n = 0; n < 4; n++) begin
      dfi[n]             = '0;
      dfi[n].cs_n        = dfi_cs_n[n];
      dfi[n].ras_n       = dfi_ras_n[n];
      dfi[n].cas_n       = dfi_cas_n[n];
      dfi[n].we_n        = dfi_we_n[n];
      dfi[n].bank        = MaxBank'(dfi_bank[n]);
      dfi[n].address     = MaxAddr'(dfi_address[n]);
      dfi[n].cke         = dfi_cke[n];
      dfi[n].odt         = dfi_odt[n];
      dfi[n].reset_n     = dfi_reset_n[n];
      dfi[n].wrdata      = (2 * MaxDq)'(dfi_wrdata[n]);
      dfi[n].wrdata_en   = dfi_wrdata_en[n];
      dfi[n].wrdata_mask = (2 * MaxLanes)'(dfi_wrdata_mask[n]);
      dfi[n].rddata_en   = dfi_rddata_en[n];
      dfi_rddata[n]      = dfi_rddata_x[n][2*DqBits-1:0];
    end
  end

  // ------------------------------------------------------- clk_i domain
  bow_ddr_regs #(
    .DqBits      (DqBits),
    .AddrPins    (AddrPins),
    .BankPins    (BankPins),
    .HasDm       (HasDm),
    .HasResetN   (HasResetN),
    .Ddr3Core    (Ddr3),
    .ClkHz       (ClkHz),
    .PsSteps     (PsSteps),
    .PhyKind     (PhyKind),
    .EmuBytes    (EmuBytes),
    .ReadLatency (ReadLatency)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .lnk_ni          (lnk_sys_n),
    .reg_req_i,
    .reg_rsp_o,
    .irq_o,
    .ready_o         (ready),
    .csr_avail_o     (csr_avail),
    .abort_o         (abort),
    .clk_lost_o      (clk_lost),
    .core_rst_o      (core_rst),
    .masked_o        (masked),
    .win_dead_i      (win_dead),
    .csr_dead_i      (csr_dead),
    .win_not_ready_i (win_nrdy),
    .win_range_i     (win_range),
    .win_timeout_i   (win_tmo),
    .csr_err_i       (csr_err),
    .csr_timeout_i   (csr_tmo),
    .win_err_addr_i  (err_addr),
    .win_st_rd_i     (st_rd),
    .win_st_wr_i     (st_wr),
    .win_st_rmw_i    (st_rmw),
    .init_done_i     (init_done),
    .init_error_i    (init_error),
    .core_busy_i     (core_busy),
    .cmd_req_o       (cmd_req),
    .cmd_kind_o      (cmd_kind),
    .cmd_cfg_o       (cmd_cfg),
    .cmd_target_o    (cmd_target),
    .cmd_ack_i       (cmd_ack),
    .res_err_i       (res_err),
    .res_ps_now_i    (ps_now),
    .res_wps_now_i   (wps_now),
    .res_st_i        (res_st),
    .ddr_up_i        (ddr_up),
    .ddr_div_i       (ddr_div),
    .rfifo_err_i     (rfifo_err_tgl),
    .rfifo_broken_i  (rfifo_broken),
    .cap_done_i      (cap_done_tgl),
    .rd_late_i       (rd_late_tgl),
    .rd_extra_i      (rd_extra_tgl),
    .cap_dq_i        (cap_dq),
    .cap_dqs_i       (cap_dqs),
    .dbg_i           (ddr_dbg_i)
  );

  bow_ddr_win #(
    .NatBytes   (NatBytes),
    .MemBytes   (MemBytes),
    .WinTimeout (WinTimeout)
  ) u_win (
    .clk_i,
    .rst_ni,
    .bri_ni            (bri_sys_n),
    .mem_req_i,
    .mem_rsp_o,
    .ready_i           (ready),
    .abort_i           (abort),
    .clk_lost_i        (clk_lost),
    .masked_i          (masked),
    .dead_o            (win_dead),
    .not_ready_o       (win_nrdy),
    .range_o           (win_range),
    .timeout_o         (win_tmo),
    .err_addr_o        (err_addr),
    .st_rd_o           (st_rd),
    .st_wr_o           (st_wr),
    .st_rmw_o          (st_rmw),
    .sys_clk_i         (ddr_sys_clk_i),
    .sys_rst_ni        (bri_dsys_n),
    .nat_cmd_valid_o   (nat_cmd_valid),
    .nat_cmd_ready_i   (nat_cmd_ready),
    .nat_cmd_we_o      (nat_cmd_we),
    .nat_cmd_addr_o    (nat_cmd_addr),
    .nat_wdata_valid_o (nat_wdata_valid),
    .nat_wdata_ready_i (nat_wdata_ready),
    .nat_wdata_o       (nat_wdata),
    .nat_wdata_we_o    (nat_wdata_we),
    .nat_rdata_valid_i (nat_rdata_valid),
    .nat_rdata_ready_o (nat_rdata_ready),
    .nat_rdata_i       (nat_rdata)
  );

  bow_ddr_csr #(
    .Timeout (WinTimeout)
  ) u_csr (
    .clk_i,
    .rst_ni,
    .bri_ni     (bri_sys_n),
    .csr_req_i,
    .csr_rsp_o,
    .avail_i    (csr_avail),
    .abort_i    (abort),
    .clk_lost_i (clk_lost),
    .dead_o     (csr_dead),
    .csr_err_o  (csr_err),
    .timeout_o  (csr_tmo),
    .sys_clk_i  (ddr_sys_clk_i),
    .sys_rst_ni (bri_dsys_n),
    .wb_adr_o   (wb_adr),
    .wb_dat_w_o (wb_dat_w),
    .wb_dat_r_i (wb_dat_r),
    .wb_sel_o   (wb_sel),
    .wb_cyc_o   (wb_cyc),
    .wb_stb_o   (wb_stb),
    .wb_ack_i   (wb_ack),
    .wb_we_o    (wb_we),
    .wb_cti_o   (wb_cti),
    .wb_bte_o   (wb_bte),
    .wb_err_i   (wb_err)
  );

  // ----------------------------------------- ddr_sys / ddr_clk domains
  bow_ddr_dfi #(
    .DqBits      (DqBits),
    .PsSteps     (PsSteps),
    .ReadLatency (ReadLatency)
  ) u_dfi (
    .sys_clk_i          (ddr_sys_clk_i),
    .sys_rst_ni         (lnk_dsys_n),
    .dfi_i              (dfi),
    .dfi_rddata_o       (dfi_rddata_x),
    .dfi_rddata_valid_o (dfi_rddata_valid),
    .clk_i              (ddr_clk_i),
    .rst_ni             (lnk_ddr_n),
    .ps_rst_ni          (mmcm_ddr_n),
    .cmd_req_i          (cmd_req),
    .cmd_kind_i         (cmd_kind),
    .cmd_cfg_i          (cmd_cfg),
    .cmd_target_i       (cmd_target),
    .cmd_ack_o          (cmd_ack),
    .res_err_o          (res_err),
    .res_ps_now_o       (ps_now),
    .res_wps_now_o      (wps_now),
    .res_st_o           (res_st),
    .ddr_up_o           (ddr_up),
    .ddr_div_o          (ddr_div),
    .rfifo_err_o        (rfifo_err_tgl),
    .cap_done_o         (cap_done_tgl),
    .rd_late_o          (rd_late_tgl),
    .rd_extra_o         (rd_extra_tgl),
    .phy_cfg_o          (phy_cfg),
    .phy_cmd_v_o        (phy_cmd_v),
    .phy_cmd_code_o     (phy_cmd_code),
    .phy_cmd_ba_o       (phy_cmd_ba),
    .phy_cmd_a_o        (phy_cmd_a),
    .phy_wr_bytes_o     (phy_wr_bytes),
    .phy_wr_be_o        (phy_wr_be),
    .phy_cap_o          (phy_cap),
    .phy_rd_v_i         (phy_rd_v),
    .phy_rd_bytes_i     (phy_rd_bytes),
    .phy_cap_done_i     (phy_cap_done),
    .phy_idle_i         (phy_idle),
    .phy_rfifo_sync_o   (rfifo_sync),
    .phy_rfifo_err_i    (rfifo_err),
    .ps_en_o            (ddr_ps_en_o),
    .ps_inc_o           (ddr_ps_inc_o),
    .ps_done_i          (ddr_ps_done_i),
    .wps_en_o           (ddr_wps_en_o),
    .wps_inc_o          (ddr_wps_inc_o),
    .wps_done_i         (ddr_wps_done_i)
  );

  bow_ddr_phy #(
    .DqBits    (DqBits),
    .Lanes     (Lanes),
    .AddrPins  (AddrPins),
    .BankPins  (BankPins),
    .HasDm     (HasDm),
    .HasResetN (HasResetN)
  ) u_phy (
    .clk_i          (ddr_clk_i),
    .rst_ni         (lnk_ddr_n),
    .rd_clk_i       (ddr_rd_clk_i),
    .rd_rst_ni      (lnk_rd_n),
    .cfg_i          (phy_cfg),
    .cmd_v_i        (phy_cmd_v),
    .cmd_code_i     (phy_cmd_code),
    .cmd_ba_i       (phy_cmd_ba),
    .cmd_a_i        (phy_cmd_a),
    .wr_bytes_i     (phy_wr_bytes),
    .wr_be_i        (phy_wr_be),
    .cap_i          (phy_cap),
    .rd_v_o         (phy_rd_v),
    .rd_bytes_o     (phy_rd_bytes),
    .cap_done_o     (phy_cap_done),
    .idle_o         (phy_idle),
    .rfifo_sync_i   (rfifo_sync),
    .rfifo_err_o    (rfifo_err),
    .rfifo_broken_o (rfifo_broken),
    .cap_dq_o       (cap_dq),
    .cap_dqs_o      (cap_dqs),
    .io_o           (ddr_io_o),
    .io_i           (ddr_io_i)
  );

  // rddata_valid is ignored by the controller's read path (fixed read
  // latency) but latched by the DFII phase injectors; the native read data
  // are always taken (no back-pressure in LiteDRAM)
  logic unused;
  assign unused = ^{nat_rdata_ready};

`ifndef SYNTHESIS
  if (DdrMem != 2 && DdrMem != 3) begin : g_bad_mem
    initial $fatal(1, "bow_ddr: DdrMem must be 2 (litedram_ddr2) or 3 (litedram_ddr3)");
  end
  if (PhyKind != 1 && PhyKind != 2) begin : g_bad_phy
    initial $fatal(1, "bow_ddr: PhyKind must be 1 (pins) or 2 (loopback emulator)");
  end
`endif

endmodule
