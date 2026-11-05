// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Memory window of bow_ddr: the main-bus slave at 0x8000_0000 (512 MiB
// decode, MemBytes of DRAM) and a bridge to the native user port of the
// LiteDRAM controller (ddr_sys_clk domain). docs/ip/ddr.md, "Cửa sổ bộ nhớ".
//
// clk_i side: unknown-latency slave in the shape of bow_axil_bridge: gnt is
// held low while the access runs in the ddr_sys domain and is given in the
// cycle after the result is in (state Grant), so rvalid comes exactly one
// cycle after gnt; the crossbar keeps the request stable until gnt.
//   Idle:  a request while !READY (ready_i), in the bridge reset (!bri_ni)
//          or dead: Grant with err, not_ready_o; offset (addr[28:0]) >=
//          MemBytes: Grant with err, range_o; nothing is launched.
//          Otherwise, once the previous handshake has returned to zero (ack
//          seen low), the request {we, be, offset, wdata, masked_i} is
//          staged, req_q rises and the timer is loaded with WinTimeout ->
//          Wait.
//   Wait:  ack seen high -> Grant (rdata of the ddr side, stable since before
//          the ack), req_q falls; abort_i -> Grant(err): timeout_o and dead
//          when the DDR clock is lost with the link up (!CLK_OK,
//          clk_lost_i), not_ready_o for CTRL.CORE_RST (which resets the
//          channel itself: not dead), timeout_o after a link reset (not
//          dead either); timer 0 -> Grant(err), timeout_o, dead.
//   Every access answered with err stores its address in err_addr_o.
// Dead (dead_o, STATUS.BROKEN): after a timeout, or an abort by a DDR clock
// lost while the link stays up, the bridge does not know whether the ddr
// side will still do the access (a write may land late, a late answer must
// never be taken for the next request): every access is refused with
// not_ready_o until the bridge reset bri_ni (link reset or CTRL.CORE_RST)
// clears the whole channel on both sides. An abort by CORE_RST or by the
// link reset is itself that reset: dead_q (bri_ni domain) stays 0.
//
// Handshake: four phases (req_q rises, ack rises, req_q falls, ack falls),
// bow_sync on each side; the payload and the results are quasi-static.
//
// ddr_sys side, one access at a time (native word = BL8 burst = NatBytes,
// native address = offset / NatBytes, 32-bit lane = offset[LaneBits+1:2]):
//   read:  one native read, the lane of the word.
//   write, be = 0: nothing (ok).
//   write, masked_i (HasDm and applied DM_EN): one native write, the word
//          replicated on all lanes, we = be << 4 * lane.
//   write, !masked_i: read-modify-write of the native word (the be bytes
//          merged, we = all ones). Atomic as long as the window is the only
//          user of the data it touches: the LiteDRAM BIST has its own
//          crossbar ports, so BIST and window traffic must not overlap.
// The native write data are stable from the command on: LiteDRAM takes them
// when it issues the WRITE (wdata_ready, which may come cycles after
// cmd_ready) without looking at wdata_valid. rdata_ready is always 1 (the
// controller has no read back-pressure). st_rd_o / st_wr_o / st_rmw_o pulse
// (clk_i) per access that did a native read / write / both.
// Reset domains: the bus FSM and err_addr_o use rst_ni (sys_rst_n), the
// channel flops of each side the bridge reset of that side, except the
// native command payload of the ddr_sys side (no reset: a write the core has
// accepted keeps its data while CORE_RST takes effect).

module bow_ddr_win import bow_bus_pkg::*; #(
  parameter int unsigned NatBytes   = 8,           // native word: 8 (DDR2 x8) or 16 (DDR3 x16)
  parameter int unsigned MemBytes   = 64 << 20,    // DRAM size, power of two
  parameter int unsigned WinTimeout = 1 << 20      // clk_i cycles
) (
  // ---- clk_i domain
  input  logic                  clk_i,
  input  logic                  rst_ni,            // sys_rst_n
  input  logic                  bri_ni,            // bridge reset, clk_i side

  input  bus_req_t              mem_req_i,
  output bus_rsp_t              mem_rsp_o,

  input  logic                  ready_i,           // STATUS.READY
  input  logic                  clk_lost_i,        // !CLK_OK: an abort is a dead clock
  input  logic                  abort_i,           // !CLK_OK or CTRL.CORE_RST
  input  logic                  masked_i,          // HasDm and applied DM_EN
  output logic                  dead_o,            // level
  output logic                  not_ready_o,       // one-cycle pulses
  output logic                  range_o,
  output logic                  timeout_o,
  output logic [31:0]           err_addr_o,
  output logic                  st_rd_o,
  output logic                  st_wr_o,
  output logic                  st_rmw_o,

  // ---- ddr_sys_clk domain: LiteDRAM native port
  input  logic                  sys_clk_i,
  input  logic                  sys_rst_ni,        // bridge reset, ddr_sys side
  output logic                  nat_cmd_valid_o,
  input  logic                  nat_cmd_ready_i,
  output logic                  nat_cmd_we_o,
  output logic [$clog2(MemBytes)-$clog2(NatBytes)-1:0] nat_cmd_addr_o,   // offset / NatBytes
  output logic                  nat_wdata_valid_o,
  input  logic                  nat_wdata_ready_i,
  output logic [8*NatBytes-1:0] nat_wdata_o,
  output logic [NatBytes-1:0]   nat_wdata_we_o,
  input  logic                  nat_rdata_valid_i,
  output logic                  nat_rdata_ready_o,
  input  logic [8*NatBytes-1:0] nat_rdata_i
);

  localparam int unsigned MemLog2  = $clog2(MemBytes);
  localparam int unsigned NatLog2  = $clog2(NatBytes);
  localparam int unsigned NatAw    = MemLog2 - NatLog2;
  localparam int unsigned LaneBits = NatLog2 - 2;
  localparam int unsigned NLanes   = NatBytes / 4;
  localparam int unsigned TW       = $clog2(WinTimeout + 1);

  // =========================================================================
  // clk_i side
  // =========================================================================
  typedef enum logic [1:0] {
    Idle,
    Wait,     // access in the ddr_sys domain
    Grant     // result in: grant the request now, answer next cycle
  } state_e;

  // ------------------------------------------------- channel (bridge reset)
  logic        req_q, ack_s, dead_q, we_q, masked_q;
  logic [3:0]  be_q;
  logic [28:0] off_q;
  logic [31:0] wdata_q;
  logic        ack_d;                  // ddr side ack_q
  logic [31:0] res_rdata;              // ddr side results (quasi-static)
  logic        res_rd, res_wr;

  bow_sync u_sync_ack (
    .clk_i,
    .rst_ni (bri_ni),
    .d_i    (ack_d),
    .q_o    (ack_s)
  );

  // ------------------------------------------------------------------- FSM
  state_e        state_q;
  logic [TW-1:0] timer_q;
  logic          err_q, rvalid_q;
  logic [31:0]   rdata_q, err_addr_q;
  logic          beyond, refuse, launch, done, tmo, abort, nrdy_q, rng_q, tmo_q;
  logic          strd_q, stwr_q;

  assign beyond = mem_req_i.addr[28:MemLog2] != '0;
  assign refuse = (state_q == Idle) && mem_req_i.req && (!ready_i || dead_q || !bri_ni);
  assign launch = (state_q == Idle) && mem_req_i.req && ready_i && !dead_q && bri_ni && !beyond &&
                  !ack_s;
  assign done   = (state_q == Wait) && !abort_i && ack_s;
  assign abort  = (state_q == Wait) && abort_i;
  assign tmo    = (state_q == Wait) && !abort_i && !ack_s && (timer_q == '0);

  always_ff @(posedge clk_i or negedge bri_ni) begin
    if (!bri_ni) begin
      req_q    <= 1'b0;
      dead_q   <= 1'b0;
      we_q     <= 1'b0;
      masked_q <= 1'b0;
      be_q     <= '0;
      off_q    <= '0;
      wdata_q  <= '0;
    end else begin
      if (launch) begin
        req_q    <= 1'b1;
        we_q     <= mem_req_i.we;
        masked_q <= masked_i;
        be_q     <= mem_req_i.be;
        off_q    <= mem_req_i.addr[28:0];
        wdata_q  <= mem_req_i.wdata;
      end else if (done) begin
        req_q <= 1'b0;
      end
      if (tmo || abort) dead_q <= 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= Idle;
      timer_q    <= '0;
      err_q      <= 1'b0;
      rdata_q    <= '0;
      err_addr_q <= '0;
      nrdy_q     <= 1'b0;
      rng_q      <= 1'b0;
      tmo_q      <= 1'b0;
      strd_q     <= 1'b0;
      stwr_q     <= 1'b0;
    end else begin
      nrdy_q <= 1'b0;
      rng_q  <= 1'b0;
      tmo_q  <= 1'b0;
      strd_q <= 1'b0;
      stwr_q <= 1'b0;
      unique case (state_q)
        Idle: begin
          if (refuse) begin
            err_q      <= 1'b1;
            rdata_q    <= '0;
            err_addr_q <= mem_req_i.addr;
            nrdy_q     <= 1'b1;
            state_q    <= Grant;
          end else if (mem_req_i.req && beyond) begin
            err_q      <= 1'b1;
            rdata_q    <= '0;
            err_addr_q <= mem_req_i.addr;
            rng_q      <= 1'b1;
            state_q    <= Grant;
          end else if (launch) begin
            timer_q <= TW'(WinTimeout);
            state_q <= Wait;
          end
        end

        Wait: begin
          if (abort || tmo) begin
            err_q      <= 1'b1;
            rdata_q    <= '0;
            err_addr_q <= mem_req_i.addr;
            nrdy_q     <= abort && !clk_lost_i;
            tmo_q      <= tmo || (abort && clk_lost_i);
            state_q    <= Grant;
          end else if (done) begin
            err_q   <= 1'b0;
            rdata_q <= res_rdata;
            strd_q  <= res_rd;
            stwr_q  <= res_wr;
            state_q <= Grant;
          end else begin
            timer_q <= timer_q - TW'(1);
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
      rvalid_q <= (state_q == Grant) && mem_req_i.req;
    end
  end

  assign mem_rsp_o.gnt    = (state_q == Grant);
  assign mem_rsp_o.rvalid = rvalid_q;
  assign mem_rsp_o.err    = rvalid_q && err_q;
  assign mem_rsp_o.rdata  = rdata_q;

  assign dead_o      = dead_q;
  assign not_ready_o = nrdy_q;
  assign range_o     = rng_q;
  assign timeout_o   = tmo_q;
  assign err_addr_o  = err_addr_q;
  assign st_rd_o     = strd_q;
  assign st_wr_o     = stwr_q;
  assign st_rmw_o    = strd_q && stwr_q;

  // =========================================================================
  // ddr_sys side
  // =========================================================================
  typedef enum logic [2:0] {
    SIdle,
    SRdCmd,       // read: command presented
    SRdWait,      // read: waiting for the data
    SRmwCmd,      // RMW: read command presented
    SRmwWait,     // RMW: waiting for the data
    SWrCmd,       // write command presented (data stable)
    SWrData,      // waiting for the controller to take the data
    SAck          // result registered: ack high until req falls
  } sstate_e;

  logic                  req_s, ack_q;
  sstate_e               sstate_q;
  logic [NatAw-1:0]      naddr_q;
  logic [LaneBits-1:0]   lane_q;
  logic [8*NatBytes-1:0] wdat_q;
  logic [NatBytes-1:0]   wwe_q;
  logic [31:0]           rres_q;
  logic                  rd_did_q, wr_did_q;

  bow_sync u_sync_req (
    .clk_i  (sys_clk_i),
    .rst_ni (sys_rst_ni),
    .d_i    (req_q),
    .q_o    (req_s)
  );

  logic [LaneBits-1:0] lane;
  assign lane = off_q[LaneBits+1:2];

  // the native word with the be bytes of the request merged into lane l
  function automatic logic [8*NatBytes-1:0] merge(logic [8*NatBytes-1:0] old, logic [31:0] d,
                                                  logic [3:0] be, logic [LaneBits-1:0] l);
    logic [8*NatBytes-1:0] r;
    r = old;
    for (int unsigned b = 0; b < 4; b++) begin
      if (be[b]) r[32 * l + 8 * b +: 8] = d[8 * b +: 8];
    end
    return r;
  endfunction

  logic load, merge_rd;

  // the payload is stable: staged before req_q rose, held until the next
  // launch (after this handshake has returned to zero)
  assign load     = (sstate_q == SIdle) && req_s && !ack_q;
  assign merge_rd = (sstate_q == SRmwWait) && nat_rdata_valid_i;

  // Native command payload (address, write data, byte enables): NO reset.
  // The bridge reset (CTRL.CORE_RST) clears this side at once, while the
  // LiteDRAM core resets synchronously one or two ddr_sys cycles later: a
  // write it has already accepted may still be issued in those cycles, and
  // it takes nat_wdata_o then (without looking at wdata_valid). Cleared data
  // would write zeros into the DRAM (the whole word without a DM pin).
  always_ff @(posedge sys_clk_i) begin
    if (load) begin
      naddr_q <= off_q[MemLog2-1:NatLog2];
      wdat_q  <= {NLanes{wdata_q}};
      wwe_q   <= NatBytes'(be_q) << (4 * lane);
    end else if (merge_rd) begin
      wdat_q  <= merge(nat_rdata_i, wdata_q, be_q, lane_q);
      wwe_q   <= '1;
    end
  end

  always_ff @(posedge sys_clk_i or negedge sys_rst_ni) begin
    if (!sys_rst_ni) begin
      sstate_q <= SIdle;
      ack_q    <= 1'b0;
      lane_q   <= '0;
      rres_q   <= '0;
      rd_did_q <= 1'b0;
      wr_did_q <= 1'b0;
    end else begin
      unique case (sstate_q)
        SIdle: begin
          if (load) begin
            lane_q   <= lane;
            rd_did_q <= 1'b0;
            wr_did_q <= 1'b0;
            rres_q   <= '0;
            if (!we_q) begin
              sstate_q <= SRdCmd;
            end else if (be_q == 4'h0) begin
              ack_q    <= 1'b1;
              sstate_q <= SAck;
            end else if (masked_q) begin
              sstate_q <= SWrCmd;
            end else begin
              sstate_q <= SRmwCmd;
            end
          end
        end

        SRdCmd:  if (nat_cmd_ready_i) sstate_q <= SRdWait;

        SRdWait: begin
          if (nat_rdata_valid_i) begin
            rres_q   <= nat_rdata_i[32 * lane_q +: 32];
            rd_did_q <= 1'b1;
            ack_q    <= 1'b1;
            sstate_q <= SAck;
          end
        end

        SRmwCmd: if (nat_cmd_ready_i) sstate_q <= SRmwWait;

        SRmwWait: begin
          if (merge_rd) begin
            rd_did_q <= 1'b1;
            sstate_q <= SWrCmd;
          end
        end

        SWrCmd: begin
          if (nat_cmd_ready_i) begin
            if (nat_wdata_ready_i) begin
              wr_did_q <= 1'b1;
              ack_q    <= 1'b1;
              sstate_q <= SAck;
            end else begin
              sstate_q <= SWrData;
            end
          end
        end

        SWrData: begin
          if (nat_wdata_ready_i) begin
            wr_did_q <= 1'b1;
            ack_q    <= 1'b1;
            sstate_q <= SAck;
          end
        end

        default: begin    // SAck
          if (!req_s) begin
            ack_q    <= 1'b0;
            sstate_q <= SIdle;
          end
        end
      endcase
    end
  end

  assign nat_cmd_valid_o   = (sstate_q == SRdCmd) || (sstate_q == SRmwCmd) || (sstate_q == SWrCmd);
  assign nat_cmd_we_o      = (sstate_q == SWrCmd);
  assign nat_cmd_addr_o    = naddr_q;
  assign nat_wdata_valid_o = (sstate_q == SWrCmd) || (sstate_q == SWrData);
  assign nat_wdata_o       = wdat_q;
  assign nat_wdata_we_o    = wwe_q;
  assign nat_rdata_ready_o = 1'b1;

  assign ack_d     = ack_q;
  assign res_rdata = rres_q;
  assign res_rd    = rd_did_q;
  assign res_wr    = wr_did_q;

  logic unused;
  assign unused = ^{mem_req_i.addr[31:29], mem_req_i.addr[1:0], off_q[1:0],
                    off_q[28:MemLog2]};

`ifndef SYNTHESIS
  if (NatBytes != 8 && NatBytes != 16) begin : g_bad_nat
    initial $fatal(1, "bow_ddr_win: NatBytes must be 8 or 16");
  end
  if (MemLog2 > 28 || (1 << MemLog2) != MemBytes) begin : g_bad_mem
    initial $fatal(1, "bow_ddr_win: MemBytes must be a power of two below 512 MiB");
  end
`endif

endmodule
