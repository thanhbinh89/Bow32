// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Stand-in of bow_ddr for SoCs without DDR (DdrEn = 0, e.g. KV260): the same
// parameters and ports, no logic in the ddr_sys_clk / ddr_clk / rd_clk
// domains.
//   mem_*  every access is granted at once (gnt = req) and answered in the
//          next cycle with err = 1 (load / store access fault).
//   csr_*  the same (no LiteDRAM CSRs).
//   reg_*  ID = 0x44445202, INFO = 0 (INFO[24] = 0: no controller, the
//          driver's probe returns false), every other offset reads 0, writes
//          are ignored, never an error.
//   irq_o = 0, the phase-shift requests are 0, ddr_io_o = DDR_IO_OUT_DEFAULT
//   (deselect, level shifters isolated, everything else 0).

module bow_ddr_stub import bow_bus_pkg::*; import bow_ddr_pkg::*; #(
  parameter int unsigned DdrMem     = 2,
  parameter int unsigned ClkHz      = 133_333_333,
  parameter int unsigned PsSteps    = 504,
  parameter int unsigned PhyKind    = 1,
  parameter int unsigned EmuBytes   = 0,
  parameter int unsigned WinTimeout = 1 << 20
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  bus_req_t    mem_req_i,
  output bus_rsp_t    mem_rsp_o,
  input  bus_req_t    csr_req_i,
  output bus_rsp_t    csr_rsp_o,
  input  bus_req_t    reg_req_i,
  output bus_rsp_t    reg_rsp_o,
  output logic        irq_o,

  input  logic        ddr_sys_clk_i,
  input  logic        ddr_clk_i,
  input  logic        ddr_rst_ni,
  input  logic        ddr_rd_clk_i,
  output logic        ddr_ps_en_o,
  output logic        ddr_ps_inc_o,
  input  logic        ddr_ps_done_i,
  output logic        ddr_wps_en_o,
  output logic        ddr_wps_inc_o,
  input  logic        ddr_wps_done_i,
  output ddr_io_out_t ddr_io_o,
  input  ddr_io_in_t  ddr_io_i,
  input  logic [31:0] ddr_dbg_i
);

  logic        mem_rvalid_q, csr_rvalid_q, reg_rvalid_q;
  logic [31:0] reg_rdata_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_rvalid_q <= 1'b0;
      csr_rvalid_q <= 1'b0;
      reg_rvalid_q <= 1'b0;
      reg_rdata_q  <= '0;
    end else begin
      mem_rvalid_q <= mem_req_i.req;
      csr_rvalid_q <= csr_req_i.req;
      reg_rvalid_q <= reg_req_i.req;
      if (reg_req_i.req && !reg_req_i.we) begin
        reg_rdata_q <= (reg_req_i.addr[11:2] == 10'h000) ? IdValue : 32'h0;
      end
    end
  end

  assign mem_rsp_o.gnt    = mem_req_i.req;
  assign mem_rsp_o.rvalid = mem_rvalid_q;
  assign mem_rsp_o.err    = mem_rvalid_q;
  assign mem_rsp_o.rdata  = '0;

  assign csr_rsp_o.gnt    = csr_req_i.req;
  assign csr_rsp_o.rvalid = csr_rvalid_q;
  assign csr_rsp_o.err    = csr_rvalid_q;
  assign csr_rsp_o.rdata  = '0;

  assign reg_rsp_o.gnt    = 1'b1;
  assign reg_rsp_o.rvalid = reg_rvalid_q;
  assign reg_rsp_o.err    = 1'b0;
  assign reg_rsp_o.rdata  = reg_rdata_q;

  assign irq_o         = 1'b0;
  assign ddr_ps_en_o   = 1'b0;
  assign ddr_ps_inc_o  = 1'b0;
  assign ddr_wps_en_o  = 1'b0;
  assign ddr_wps_inc_o = 1'b0;
  assign ddr_io_o      = DDR_IO_OUT_DEFAULT;

  logic unused;
  assign unused = ^{mem_req_i.we, mem_req_i.be, mem_req_i.addr, mem_req_i.wdata,
                    csr_req_i.we, csr_req_i.be, csr_req_i.addr, csr_req_i.wdata,
                    reg_req_i.be, reg_req_i.addr[31:12], reg_req_i.addr[1:0], reg_req_i.wdata,
                    ddr_sys_clk_i, ddr_clk_i, ddr_rst_ni, ddr_rd_clk_i, ddr_ps_done_i,
                    ddr_wps_done_i, ddr_io_i, ddr_dbg_i,
                    // parameters of bow_ddr that the stub does not need
                    32'(DdrMem), 32'(ClkHz), 32'(PsSteps), 32'(PhyKind), 32'(EmuBytes),
                    32'(WinTimeout)};

endmodule
