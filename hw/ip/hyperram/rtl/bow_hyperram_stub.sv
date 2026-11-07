// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// bow_hyperram replacement for a SoC without HyperRAM (bow32_top HrEn = 0):
// the window answers every access with a bus error, the register slot reads
// ID and INFO (INFO[3] HR_EN = 0, PHY kind 0) and 0 elsewhere and ignores
// writes; no interrupt; pads idle; no phase step. Same ports as bow_hyperram.

module bow_hyperram_stub import bow_bus_pkg::*; import bow_hyperram_pkg::*; (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  bus_req_t    mem_req_i,
  output bus_rsp_t    mem_rsp_o,
  input  bus_req_t    reg_req_i,
  output bus_rsp_t    reg_rsp_o,
  output logic        irq_o,
  input  logic        hr_clk_i,
  input  logic        hr_rst_ni,
  input  logic        hr_rd_clk_i,
  output logic        hr_ps_en_o,
  output logic        hr_ps_inc_o,
  input  logic        hr_ps_done_i,
  output logic        hr_wps_en_o,
  output logic        hr_wps_inc_o,
  input  logic        hr_wps_done_i,
  output hr_io_out_t  hr_io_o,
  input  hr_io_in_t   hr_io_i,
  input  logic        hr_rwds_pad_i,
  input  logic [31:0] hr_dbg_i
);

  logic        mem_rvalid_q, reg_rvalid_q;
  logic [31:0] reg_rdata_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_rvalid_q <= 1'b0;
      reg_rvalid_q <= 1'b0;
      reg_rdata_q  <= '0;
    end else begin
      mem_rvalid_q <= mem_req_i.req;
      reg_rvalid_q <= reg_req_i.req;
      if (reg_req_i.req && !reg_req_i.we) begin
        unique case ({reg_req_i.addr[11:2], 2'b00})
          RegIdOff:   reg_rdata_q <= IdValue;
          RegInfoOff: reg_rdata_q <= 32'd0;          // HR_EN = 0
          default:    reg_rdata_q <= 32'd0;
        endcase
      end
    end
  end

  assign mem_rsp_o = '{gnt: 1'b1, rvalid: mem_rvalid_q, err: mem_rvalid_q, rdata: 32'd0};
  assign reg_rsp_o = '{gnt: 1'b1, rvalid: reg_rvalid_q, err: 1'b0, rdata: reg_rdata_q};
  assign irq_o        = 1'b0;
  assign hr_ps_en_o   = 1'b0;
  assign hr_ps_inc_o  = 1'b0;
  assign hr_wps_en_o  = 1'b0;
  assign hr_wps_inc_o = 1'b0;
  assign hr_io_o      = HR_IO_OUT_IDLE;

  logic unused;
  assign unused = ^{mem_req_i.we, mem_req_i.be, mem_req_i.addr, mem_req_i.wdata, reg_req_i.we,
                    reg_req_i.be, reg_req_i.addr[31:12], reg_req_i.addr[1:0], reg_req_i.wdata,
                    hr_clk_i, hr_rst_ni, hr_rd_clk_i, hr_ps_done_i, hr_wps_done_i, hr_io_i,
                    hr_rwds_pad_i, hr_dbg_i};

endmodule
