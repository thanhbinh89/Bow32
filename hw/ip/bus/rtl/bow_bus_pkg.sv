// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 on-chip bus definitions.
//
// The bus is a subset of OBI and is identical to the Ibex native memory
// interface, so the core connects to the interconnect without any adapter.
//
// Handshake rules (see docs/bus.md):
//  * A host raises `req` together with `we/be/addr/wdata` and holds them
//    stable until the device answers with `gnt` (a transfer happens in every
//    cycle in which req && gnt).
//  * A device may raise `gnt` in the same cycle as `req` (combinational).
//  * Exactly ONE cycle after the transfer, the device returns `rvalid` with
//    `rdata` (reads) and `err`. Devices that need more time apply backpressure
//    by holding `gnt` low instead of delaying `rvalid`.
//
// The fixed single cycle response latency keeps the interconnect trivial
// (no reorder buffers or outstanding transaction counters) while still
// allowing one transfer per cycle per host.
package bow_bus_pkg;

  localparam int unsigned BusAddrWidth = 32;
  localparam int unsigned BusDataWidth = 32;
  localparam int unsigned BusBeWidth   = BusDataWidth / 8;

  // Host -> device
  typedef struct packed {
    logic                    req;
    logic                    we;
    logic [BusBeWidth-1:0]   be;
    logic [BusAddrWidth-1:0] addr;
    logic [BusDataWidth-1:0] wdata;
  } bus_req_t;

  // Device -> host
  typedef struct packed {
    logic                    gnt;
    logic                    rvalid;
    logic                    err;
    logic [BusDataWidth-1:0] rdata;
  } bus_rsp_t;

  localparam bus_req_t BUS_REQ_DEFAULT = '0;
  localparam bus_rsp_t BUS_RSP_DEFAULT = '0;

endpackage
