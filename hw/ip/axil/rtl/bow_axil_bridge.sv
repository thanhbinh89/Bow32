// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 bus -> AXI4-Lite master bridge (docs/ip/axil_bridge.md).
//
// Opens a window of the Bow32 address space to AXI4-Lite devices outside the
// SoC (e.g. the AMD MIPI CSI-2 RX subsystem in the Vivado block design).
//
//  * One transaction at a time. The bridge holds `gnt` low while the AXI
//    transaction runs and grants the bus request in the cycle after the AXI
//    response, so the usual Bow32 rule "rvalid exactly one cycle after gnt"
//    still holds (the arbiter of the crossbar keeps the grant stable).
//  * Address = bus address modulo 2^AddrWidth (offset inside the window).
//  * SLVERR/DECERR (resp[1] = 1) -> bus error (load/store access fault).
//  * Timeout: if the AXI device does not answer within TimeoutCycles the
//    bridge drops the transaction and answers with a bus error, so that a
//    missing or unclocked AXI device cannot hang the CPU. This violates the
//    AXI rule that a VALID stays high until READY; it is a safety net for
//    a broken system, not a normal operating mode.

module bow_axil_bridge import bow_bus_pkg::*; #(
  parameter int unsigned AddrWidth     = 16,
  parameter int unsigned TimeoutCycles = 1024
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  input  bus_req_t             bus_req_i,
  output bus_rsp_t             bus_rsp_o,

  // AXI4-Lite master
  output logic [AddrWidth-1:0] m_axil_awaddr_o,
  output logic [2:0]           m_axil_awprot_o,
  output logic                 m_axil_awvalid_o,
  input  logic                 m_axil_awready_i,
  output logic [31:0]          m_axil_wdata_o,
  output logic [3:0]           m_axil_wstrb_o,
  output logic                 m_axil_wvalid_o,
  input  logic                 m_axil_wready_i,
  input  logic [1:0]           m_axil_bresp_i,
  input  logic                 m_axil_bvalid_i,
  output logic                 m_axil_bready_o,
  output logic [AddrWidth-1:0] m_axil_araddr_o,
  output logic [2:0]           m_axil_arprot_o,
  output logic                 m_axil_arvalid_o,
  input  logic                 m_axil_arready_i,
  input  logic [31:0]          m_axil_rdata_i,
  input  logic [1:0]           m_axil_rresp_i,
  input  logic                 m_axil_rvalid_i,
  output logic                 m_axil_rready_o
);

  localparam int unsigned TW = $clog2(TimeoutCycles + 1);

  typedef enum logic [1:0] {
    Idle,
    Write,    // AW and W issued, waiting for B
    Read,     // AR issued, waiting for R
    Grant     // AXI done: grant the bus request now, answer next cycle
  } state_e;

  state_e          state_q;
  logic [TW-1:0]   timer_q;
  logic            err_q, rvalid_q;
  logic [31:0]     rdata_q;

  assign m_axil_awprot_o = 3'b000;
  assign m_axil_arprot_o = 3'b000;
  assign m_axil_bready_o = (state_q == Write);
  assign m_axil_rready_o = (state_q == Read);

  logic timeout;
  assign timeout = (timer_q == '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= Idle;
      timer_q          <= '0;
      err_q            <= 1'b0;
      rdata_q          <= '0;
      m_axil_awaddr_o  <= '0;
      m_axil_awvalid_o <= 1'b0;
      m_axil_wdata_o   <= '0;
      m_axil_wstrb_o   <= '0;
      m_axil_wvalid_o  <= 1'b0;
      m_axil_araddr_o  <= '0;
      m_axil_arvalid_o <= 1'b0;
    end else begin
      if (state_q != Idle && state_q != Grant) timer_q <= timer_q - TW'(1);

      unique case (state_q)
        Idle: begin
          if (bus_req_i.req) begin
            timer_q <= TW'(TimeoutCycles);
            if (bus_req_i.we) begin
              m_axil_awaddr_o  <= bus_req_i.addr[AddrWidth-1:0];
              m_axil_awvalid_o <= 1'b1;
              m_axil_wdata_o   <= bus_req_i.wdata;
              m_axil_wstrb_o   <= bus_req_i.be;
              m_axil_wvalid_o  <= 1'b1;
              state_q          <= Write;
            end else begin
              m_axil_araddr_o  <= bus_req_i.addr[AddrWidth-1:0];
              m_axil_arvalid_o <= 1'b1;
              state_q          <= Read;
            end
          end
        end

        Write: begin
          if (m_axil_awready_i) m_axil_awvalid_o <= 1'b0;
          if (m_axil_wready_i)  m_axil_wvalid_o  <= 1'b0;
          if (m_axil_bvalid_i) begin
            err_q   <= m_axil_bresp_i[1];
            rdata_q <= '0;
            state_q <= Grant;
          end else if (timeout) begin
            m_axil_awvalid_o <= 1'b0;
            m_axil_wvalid_o  <= 1'b0;
            err_q            <= 1'b1;
            rdata_q          <= '0;
            state_q          <= Grant;
          end
        end

        Read: begin
          if (m_axil_arready_i) m_axil_arvalid_o <= 1'b0;
          if (m_axil_rvalid_i) begin
            err_q   <= m_axil_rresp_i[1];
            rdata_q <= m_axil_rdata_i;
            state_q <= Grant;
          end else if (timeout) begin
            m_axil_arvalid_o <= 1'b0;
            err_q            <= 1'b1;
            rdata_q          <= '0;
            state_q          <= Grant;
          end
        end

        default: state_q <= Idle;    // Grant
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
    end else begin
      rvalid_q <= (state_q == Grant) && bus_req_i.req;
    end
  end

  assign bus_rsp_o.gnt    = (state_q == Grant);
  assign bus_rsp_o.rvalid = rvalid_q;
  assign bus_rsp_o.err    = rvalid_q && err_q;
  assign bus_rsp_o.rdata  = rdata_q;

  logic unused;
  assign unused = ^{bus_req_i.addr[31:AddrWidth], m_axil_bresp_i[0], m_axil_rresp_i[0]};

endmodule
