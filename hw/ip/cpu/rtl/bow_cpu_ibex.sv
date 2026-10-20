// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CPU wrapper around lowRISC Ibex (hw/vendor/lowrisc_ibex).
//
// The rest of the SoC only sees this wrapper: two Bow32 bus host ports and
// the interrupt lines. All Ibex specific configuration and the tie-off of
// features Bow32 does not use (CHERIoT, TRVK, lockstep, scrambling, debug)
// are kept here, so an Ibex upgrade usually only touches this file and
// hw/vendor/lowrisc_ibex.f (see docs/ip_upgrade.md).
//
// Default configuration = Ibex "small": RV32IMC, 2-stage pipeline,
// 3-cycle multiplier, no PMP, no caches.

module bow_cpu_ibex import bow_bus_pkg::*; #(
  parameter logic [31:0]        BootAddr  = 32'h0000_0000,
  parameter ibex_pkg::regfile_e RegFile   = ibex_pkg::RegFileFF,
  parameter ibex_pkg::rv32m_e   RV32M     = ibex_pkg::RV32MFast,
  parameter ibex_pkg::rv32b_e   RV32B     = ibex_pkg::RV32BNone,
  parameter ibex_pkg::rv32zc_e  RV32ZC    = ibex_pkg::RV32Zca,
  parameter logic [31:0]        MimpId    = 32'h0
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Instruction fetch port (read only)
  output bus_req_t    instr_req_o,
  input  bus_rsp_t    instr_rsp_i,
  // Load / store port
  output bus_req_t    data_req_o,
  input  bus_rsp_t    data_rsp_i,

  input  logic        irq_software_i,
  input  logic        irq_timer_i,
  input  logic        irq_external_i,
  input  logic [14:0] irq_fast_i,

  output logic        core_sleep_o
);

  logic        instr_req;
  logic [31:0] instr_addr;
  logic        data_req, data_we;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata;

  ibex_top #(
    .BaseIsa          (ibex_pkg::BaseIsaRV32I),
    .PMPEnable        (1'b0),
    .MHPMCounterNum   (0),
    .RV32E            (1'b0),
    .RV32M            (RV32M),
    .RV32B            (RV32B),
    .RV32ZC           (RV32ZC),
    .RegFile          (RegFile),
    .BranchTargetALU  (1'b0),
    .WritebackStage   (1'b0),
    .ICache           (1'b0),
    .ICacheECC        (1'b0),
    .BranchPredictor  (1'b0),
    .DbgTriggerEn     (1'b0),
    .SecureIbex       (1'b0),
    .ICacheScramble   (1'b0),
    .CsrMvendorId     (32'h0),
    .CsrMimpId        (MimpId)
  ) u_ibex (
    .clk_i,
    .rst_ni,

    .test_en_i               (1'b0),
    .scan_rst_ni             (1'b1),
    .ram_cfg_icache_tag_i    ('{default: prim_ram_1p_pkg::RAM_1P_CFG_REQ_DEFAULT}),
    .ram_cfg_icache_tag_o    (),
    .ram_cfg_icache_data_i   ('{default: prim_ram_1p_pkg::RAM_1P_CFG_REQ_DEFAULT}),
    .ram_cfg_icache_data_o   (),

    .cheriot_enable_i        (ibex_pkg::IbexMuBiOff),
    .hart_id_i               (32'h0),
    .boot_addr_i             (BootAddr),
    .trvk_heap_base_addr_i   (32'h0),

    .instr_req_o             (instr_req),
    .instr_gnt_i             (instr_rsp_i.gnt),
    .instr_rvalid_i          (instr_rsp_i.rvalid),
    .instr_addr_o            (instr_addr),
    .instr_rdata_i           (instr_rsp_i.rdata),
    .instr_rdata_intg_i      (7'h0),
    .instr_err_i             (instr_rsp_i.err),

    .data_req_o              (data_req),
    .data_gnt_i              (data_rsp_i.gnt),
    .data_rvalid_i           (data_rsp_i.rvalid),
    .data_we_o               (data_we),
    .data_be_o               (data_be),
    .data_addr_o             (data_addr),
    .data_wdata_o            (data_wdata),
    .data_wdata_intg_o       (),
    .data_tag_o              (),
    .data_rdata_i            (data_rsp_i.rdata),
    .data_rdata_intg_i       (7'h0),
    .data_tag_i              (1'b0),
    .data_err_i              (data_rsp_i.err),

    .trvk_revbm_req_o        (),
    .trvk_revbm_gnt_i        (1'b0),
    .trvk_revbm_rvalid_i     (1'b0),
    .trvk_revbm_addr_o       (),
    .trvk_revbm_rdata_i      (32'h0),
    .trvk_revbm_rdata_intg_i (7'h0),
    .trvk_revbm_err_i        (1'b0),

    .irq_software_i,
    .irq_timer_i,
    .irq_external_i,
    .irq_fast_i,
    .irq_nm_i                (1'b0),

    .scramble_key_valid_i    (1'b0),
    .scramble_key_i          ('0),
    .scramble_nonce_i        ('0),
    .scramble_req_o          (),

    .debug_req_i             (1'b0),
    .crash_dump_o            (),
    .double_fault_seen_o     (),

    .fetch_enable_i          (ibex_pkg::IbexMuBiOn),
    .mcounteren_writable_i   (ibex_pkg::IbexMuBiOn),
    .alert_minor_o           (),
    .alert_major_internal_o  (),
    .alert_major_bus_o       (),
    .core_sleep_o,

    .lockstep_cmp_en_o       (),
    .data_req_shadow_o       (),
    .data_we_shadow_o        (),
    .data_be_shadow_o        (),
    .data_addr_shadow_o      (),
    .data_wdata_shadow_o     (),
    .data_wdata_intg_shadow_o(),
    .instr_req_shadow_o      (),
    .instr_addr_shadow_o     ()
  );

  always_comb begin
    instr_req_o       = BUS_REQ_DEFAULT;
    instr_req_o.req   = instr_req;
    instr_req_o.we    = 1'b0;
    instr_req_o.be    = 4'b1111;
    instr_req_o.addr  = instr_addr;

    data_req_o        = BUS_REQ_DEFAULT;
    data_req_o.req    = data_req;
    data_req_o.we     = data_we;
    data_req_o.be     = data_be;
    data_req_o.addr   = data_addr;
    data_req_o.wdata  = data_wdata;
  end

endmodule
