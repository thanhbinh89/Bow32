// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSR bridge of bow_ddr: the peripheral-bus slot ddr_ctrl (0x4000_C000,
// 8 KiB) to the Wishbone CSR port (wb_ctrl) of the LiteDRAM controller core
// in the ddr_sys_clk domain. Bus offset = CSR offset of the LiteDRAM map
// (csr.csv: ddrctrl 0x0000, sdram / DFII 0x0800, sdram_checker 0x1000,
// sdram_generator 0x1800). docs/ip/ddr.md.
//
// clk_i side: unknown-latency slave like bow_ddr_win (gnt held low while the
// access runs, Grant cycle, rvalid one cycle after gnt).
//   Idle:  a request while !avail_i (!CLK_OK, CTRL.CORE_RST or its reset
//          still in progress, the core in reset), in the bridge reset
//          (!bri_ni) or dead: Grant with err, csr_err_o. Otherwise, once the
//          previous handshake has returned to zero, {we, be, offset[12:2],
//          wdata} is staged, req_q rises, timer = Timeout -> Wait.
//   Wait:  ack seen high -> Grant (rdata, err = Wishbone err -> csr_err_o);
//          abort_i -> Grant(err), csr_err_o: with !CLK_OK also timeout_o,
//          and dead when the link is still up; CORE_RST and the link reset
//          reset the channel themselves (not dead); timer 0 -> Grant(err),
//          csr_err_o, timeout_o, dead.
// Dead (dead_o, STATUS.BROKEN): refuse every access (csr_err_o) until the
// bridge reset bri_ni (link reset or CORE_RST) clears both sides. Only a
// timeout or a DDR clock lost with the link up makes it dead: an abort by
// CORE_RST or the link reset is that reset itself.
// Handshake: four phases (req_q rises, ack rises, req_q falls, ack falls),
// bow_sync on each side; the payload and the results are quasi-static.
//
// ddr_sys side: one classic Wishbone cycle (cyc = stb = 1, adr = offset[12:2],
// sel = be, cti = bte = 0) until ack or err, then the 4-phase ack. The core's
// interconnect answers unmapped addresses inside its CSR region with 0.
// Reset domains: the bus FSM uses rst_ni (sys_rst_n), the channel flops of
// each side the bridge reset of that side.

module bow_ddr_csr import bow_bus_pkg::*; #(
  parameter int unsigned Timeout = 1 << 20      // clk_i cycles
) (
  // ---- clk_i domain
  input  logic        clk_i,
  input  logic        rst_ni,           // sys_rst_n
  input  logic        bri_ni,           // bridge reset, clk_i side

  input  bus_req_t    csr_req_i,
  output bus_rsp_t    csr_rsp_o,

  input  logic        avail_i,          // CLK_OK, !CORE_RST, core out of reset
  input  logic        abort_i,          // !CLK_OK or CTRL.CORE_RST
  input  logic        clk_lost_i,       // !CLK_OK: an abort is a dead clock
  output logic        dead_o,           // level
  output logic        csr_err_o,        // one-cycle pulses
  output logic        timeout_o,

  // ---- ddr_sys_clk domain: LiteDRAM wb_ctrl (Wishbone slave)
  input  logic        sys_clk_i,
  input  logic        sys_rst_ni,       // bridge reset, ddr_sys side
  output logic [29:0] wb_adr_o,
  output logic [31:0] wb_dat_w_o,
  input  logic [31:0] wb_dat_r_i,
  output logic [3:0]  wb_sel_o,
  output logic        wb_cyc_o,
  output logic        wb_stb_o,
  input  logic        wb_ack_i,
  output logic        wb_we_o,
  output logic [2:0]  wb_cti_o,
  output logic [1:0]  wb_bte_o,
  input  logic        wb_err_i
);

  localparam int unsigned TW = $clog2(Timeout + 1);

  // =========================================================================
  // clk_i side
  // =========================================================================
  typedef enum logic [1:0] {
    Idle,
    Wait,     // access in the ddr_sys domain
    Grant     // result in: grant the request now, answer next cycle
  } state_e;

  logic        req_q, ack_s, dead_q, we_q;
  logic [3:0]  be_q;
  logic [10:0] adr_q;
  logic [31:0] wdata_q;
  logic        ack_d;                  // ddr side ack_q
  logic [31:0] res_rdata;              // ddr side results (quasi-static)
  logic        res_err;

  bow_sync u_sync_ack (
    .clk_i,
    .rst_ni (bri_ni),
    .d_i    (ack_d),
    .q_o    (ack_s)
  );

  state_e        state_q;
  logic [TW-1:0] timer_q;
  logic          err_q, rvalid_q, cerr_q, tmo_q;
  logic [31:0]   rdata_q;
  logic          refuse, launch, done, tmo, abort;

  assign refuse = (state_q == Idle) && csr_req_i.req && (!avail_i || dead_q || !bri_ni);
  assign launch = (state_q == Idle) && csr_req_i.req && avail_i && !dead_q && bri_ni && !ack_s;
  assign done   = (state_q == Wait) && !abort_i && ack_s;
  assign abort  = (state_q == Wait) && abort_i;
  assign tmo    = (state_q == Wait) && !abort_i && !ack_s && (timer_q == '0);

  always_ff @(posedge clk_i or negedge bri_ni) begin
    if (!bri_ni) begin
      req_q   <= 1'b0;
      dead_q  <= 1'b0;
      we_q    <= 1'b0;
      be_q    <= '0;
      adr_q   <= '0;
      wdata_q <= '0;
    end else begin
      if (launch) begin
        req_q   <= 1'b1;
        we_q    <= csr_req_i.we;
        be_q    <= csr_req_i.be;
        adr_q   <= csr_req_i.addr[12:2];
        wdata_q <= csr_req_i.wdata;
      end else if (done) begin
        req_q <= 1'b0;
      end
      if (tmo || abort) dead_q <= 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Idle;
      timer_q <= '0;
      err_q   <= 1'b0;
      rdata_q <= '0;
      cerr_q  <= 1'b0;
      tmo_q   <= 1'b0;
    end else begin
      cerr_q <= 1'b0;
      tmo_q  <= 1'b0;
      unique case (state_q)
        Idle: begin
          if (refuse) begin
            err_q   <= 1'b1;
            rdata_q <= '0;
            cerr_q  <= 1'b1;
            state_q <= Grant;
          end else if (launch) begin
            timer_q <= TW'(Timeout);
            state_q <= Wait;
          end
        end

        Wait: begin
          if (abort || tmo) begin
            err_q   <= 1'b1;
            rdata_q <= '0;
            cerr_q  <= 1'b1;
            tmo_q   <= tmo || (abort && clk_lost_i);
            state_q <= Grant;
          end else if (done) begin
            err_q   <= res_err;
            rdata_q <= res_err ? '0 : res_rdata;
            cerr_q  <= res_err;
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
      rvalid_q <= (state_q == Grant) && csr_req_i.req;
    end
  end

  assign csr_rsp_o.gnt    = (state_q == Grant);
  assign csr_rsp_o.rvalid = rvalid_q;
  assign csr_rsp_o.err    = rvalid_q && err_q;
  assign csr_rsp_o.rdata  = rdata_q;

  assign dead_o    = dead_q;
  assign csr_err_o = cerr_q;
  assign timeout_o = tmo_q;

  // =========================================================================
  // ddr_sys side
  // =========================================================================
  typedef enum logic [1:0] {
    SIdle,
    SBus,         // Wishbone cycle
    SAck          // result registered: ack high until req falls
  } sstate_e;

  logic        req_s, ack_q, rerr_q;
  sstate_e     sstate_q;
  logic [31:0] rdat_q;

  bow_sync u_sync_req (
    .clk_i  (sys_clk_i),
    .rst_ni (sys_rst_ni),
    .d_i    (req_q),
    .q_o    (req_s)
  );

  always_ff @(posedge sys_clk_i or negedge sys_rst_ni) begin
    if (!sys_rst_ni) begin
      sstate_q <= SIdle;
      ack_q    <= 1'b0;
      rdat_q   <= '0;
      rerr_q   <= 1'b0;
    end else begin
      unique case (sstate_q)
        SIdle: if (req_s && !ack_q) sstate_q <= SBus;

        SBus: begin
          if (wb_ack_i || wb_err_i) begin
            rdat_q   <= wb_dat_r_i;
            rerr_q   <= wb_err_i;
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

  // the payload (we_q, be_q, adr_q, wdata_q) is stable during the cycle
  assign wb_cyc_o   = (sstate_q == SBus);
  assign wb_stb_o   = (sstate_q == SBus);
  assign wb_we_o    = we_q;
  assign wb_adr_o   = {19'h0, adr_q};
  assign wb_sel_o   = be_q;
  assign wb_dat_w_o = wdata_q;
  assign wb_cti_o   = 3'b000;
  assign wb_bte_o   = 2'b00;

  assign ack_d     = ack_q;
  assign res_rdata = rdat_q;
  assign res_err   = rerr_q;

  logic unused;
  assign unused = ^{csr_req_i.addr[31:13], csr_req_i.addr[1:0]};

endmodule
