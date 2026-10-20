// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 internal flash (emulated with block RAM).
//
// The storage behaves like NOR flash so that firmware is written exactly as
// for a real MCU:
//   * erased state is all ones (0xFFFFFFFF);
//   * programming can only clear bits: new = old & wdata (per enabled byte);
//   * erase works on pages (PageBytes) or on the whole array (mass erase);
//   * program/erase require unlocking with a key and setting PG/PER/MER.
//
// Two bus ports:
//   mem_*  memory window on the main bus (instruction fetch / data reads,
//          programming writes while CTRL.PG = 1). Busy cycles (program write
//          phase, erase) stall the bus by holding gnt low.
//   reg_*  control registers on the peripheral bus:
//     0x00 KEY       W : write UnlockKey to unlock, any other value locks
//     0x04 CTRL      RW: [0] PG  [1] PER  [2] MER  [4] EOPIE
//                        [8] STRT (W, starts PER/MER erase, reads 0)
//                        [31] LOCK (R: 1 = locked, W 1: lock again)
//     0x08 ADDR      RW: address inside the page to erase (PER)
//     0x0C STATUS    R : [0] BUSY  W1C: [1] EOP  [2] WRPERR  [3] PGERR
//     0x10 SIZE      R : flash size in bytes
//     0x14 PAGESIZE  R : page size in bytes
//
// The contents survive SoC resets but, being block RAM, not a reconfiguration
// of the FPGA. MemInitFile can preload an image (simulation or bitstream).

module bow_flash import bow_bus_pkg::*; #(
  parameter int unsigned SizeBytes   = 128 * 1024,
  parameter int unsigned PageBytes   = 1024,
  parameter              MemInitFile = "",
  parameter logic [31:0] UnlockKey   = 32'hB032_F1A5
) (
  input  logic     clk_i,
  input  logic     rst_ni,

  input  bus_req_t mem_req_i,
  output bus_rsp_t mem_rsp_o,

  input  bus_req_t reg_req_i,
  output bus_rsp_t reg_rsp_o,

  output logic     irq_o
);

  localparam int unsigned Depth     = SizeBytes / 4;
  localparam int unsigned AddrWidth = $clog2(Depth);
  localparam int unsigned PageWords = PageBytes / 4;
  localparam int unsigned PageWidth = $clog2(PageWords);

  localparam logic [11:0] RegKey      = 12'h000;
  localparam logic [11:0] RegCtrl     = 12'h004;
  localparam logic [11:0] RegAddr     = 12'h008;
  localparam logic [11:0] RegStatus   = 12'h00C;
  localparam logic [11:0] RegSize     = 12'h010;
  localparam logic [11:0] RegPageSize = 12'h014;

  typedef enum logic [1:0] {
    Idle,
    ProgWrite,
    Erase
  } state_e;

  state_e state_q, state_d;

  // Control / status registers
  logic        lock_q, pg_q, per_q, mer_q, eopie_q;
  logic [31:0] addr_q;
  logic        eop_q, wrperr_q, pgerr_q;
  logic        erase_pend_q;

  // Program / erase engine
  logic [AddrWidth-1:0] prog_addr_q;
  logic [31:0]          prog_wdata_q;
  logic [3:0]           prog_be_q;
  logic [AddrWidth-1:0] erase_ptr_q, erase_end_q;

  logic busy;
  assign busy = (state_q != Idle) || erase_pend_q;

  // ---------------------------------------------------------------------------
  // Memory port
  // ---------------------------------------------------------------------------
  logic mem_gnt, mem_xfer, prog_allowed, mem_prog, mem_bad_wr;

  assign mem_gnt      = (state_q == Idle) && !erase_pend_q;
  assign mem_xfer     = mem_req_i.req && mem_gnt;
  assign prog_allowed = !lock_q && pg_q && !per_q && !mer_q;
  assign mem_prog     = mem_xfer &&  mem_req_i.we && prog_allowed;
  assign mem_bad_wr   = mem_xfer &&  mem_req_i.we && !prog_allowed;

  // Block RAM port multiplexer
  logic                 ram_req, ram_we;
  logic [3:0]           ram_be;
  logic [AddrWidth-1:0] ram_addr;
  logic [31:0]          ram_wdata, ram_rdata;

  always_comb begin
    ram_req   = 1'b0;
    ram_we    = 1'b0;
    ram_be    = 4'b0000;
    ram_addr  = mem_req_i.addr[AddrWidth+1:2];
    ram_wdata = '1;
    unique case (state_q)
      // Reads and the read phase of a program operation.
      Idle:      ram_req = mem_xfer && (!mem_req_i.we || prog_allowed);
      // Write phase: flash semantics, bits can only go from 1 to 0.
      ProgWrite: begin
        ram_req   = 1'b1;
        ram_we    = 1'b1;
        ram_be    = prog_be_q;
        ram_addr  = prog_addr_q;
        ram_wdata = ram_rdata & prog_wdata_q;
      end
      Erase: begin
        ram_req   = 1'b1;
        ram_we    = 1'b1;
        ram_be    = 4'b1111;
        ram_addr  = erase_ptr_q;
      end
      default: ;
    endcase
  end

  bow_ram_1p #(
    .Depth       (Depth),
    .MemInitFile (MemInitFile),
    .InitValue   (32'hFFFF_FFFF)
  ) u_array (
    .clk_i,
    .req_i   (ram_req),
    .we_i    (ram_we),
    .be_i    (ram_be),
    .addr_i  (ram_addr),
    .wdata_i (ram_wdata),
    .rdata_o (ram_rdata)
  );

  logic mem_rvalid_q, mem_err_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_rvalid_q <= 1'b0;
      mem_err_q    <= 1'b0;
    end else begin
      mem_rvalid_q <= mem_xfer;
      mem_err_q    <= mem_bad_wr;
    end
  end

  assign mem_rsp_o.gnt    = mem_gnt;
  assign mem_rsp_o.rvalid = mem_rvalid_q;
  assign mem_rsp_o.err    = mem_err_q;
  assign mem_rsp_o.rdata  = ram_rdata;

  // ---------------------------------------------------------------------------
  // Register port
  // ---------------------------------------------------------------------------
  logic [11:0] reg_addr;
  logic        reg_we, reg_re;
  logic [31:0] wdata;

  assign reg_addr = {reg_req_i.addr[11:2], 2'b00};
  assign reg_we   = reg_req_i.req &  reg_req_i.we;
  assign reg_re   = reg_req_i.req & ~reg_req_i.we;
  assign wdata    = reg_req_i.wdata;

  logic ctrl_we, strt_req, ctrl_wrperr;
  assign ctrl_we     = reg_we && (reg_addr == RegCtrl) && !wdata[31];
  // A start request with PER or MER set while unlocked and idle.
  assign strt_req    = ctrl_we && !lock_q && wdata[8] && (wdata[1] || wdata[2]) && !busy;
  // Trying to enable an operation while the flash is locked.
  assign ctrl_wrperr = ctrl_we && lock_q && (|{wdata[8], wdata[2:0]});

  // Program / erase engine.
  logic [AddrWidth-1:0] page_first;
  assign page_first = {addr_q[AddrWidth+1:PageWidth+2], {PageWidth{1'b0}}};

  logic prog_err;
  assign prog_err = |(((ram_rdata & prog_wdata_q) ^ prog_wdata_q) &
                      {{8{prog_be_q[3]}}, {8{prog_be_q[2]}}, {8{prog_be_q[1]}}, {8{prog_be_q[0]}}});

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      Idle: begin
        if (erase_pend_q)  state_d = Erase;
        else if (mem_prog) state_d = ProgWrite;
      end
      ProgWrite: state_d = Idle;
      Erase:     if (erase_ptr_q == erase_end_q) state_d = Idle;
      default:   state_d = Idle;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= Idle;
      lock_q       <= 1'b1;
      pg_q         <= 1'b0;
      per_q        <= 1'b0;
      mer_q        <= 1'b0;
      eopie_q      <= 1'b0;
      addr_q       <= '0;
      eop_q        <= 1'b0;
      wrperr_q     <= 1'b0;
      pgerr_q      <= 1'b0;
      erase_pend_q <= 1'b0;
      prog_addr_q  <= '0;
      prog_wdata_q <= '0;
      prog_be_q    <= '0;
      erase_ptr_q  <= '0;
      erase_end_q  <= '0;
    end else begin
      state_q <= state_d;

      // ---- KEY / CTRL / ADDR / STATUS writes ----
      if (reg_we && reg_addr == RegKey) begin
        lock_q <= (wdata != UnlockKey);
      end
      if (reg_we && reg_addr == RegCtrl) begin
        eopie_q <= wdata[4];
        if (wdata[31]) begin
          lock_q <= 1'b1;
          pg_q   <= 1'b0;
          per_q  <= 1'b0;
          mer_q  <= 1'b0;
        end else if (!lock_q) begin
          pg_q  <= wdata[0];
          per_q <= wdata[1];
          mer_q <= wdata[2];
        end
      end
      if (reg_we && reg_addr == RegAddr) begin
        addr_q <= wdata;
      end
      if (reg_we && reg_addr == RegStatus) begin
        if (wdata[1]) eop_q    <= 1'b0;
        if (wdata[2]) wrperr_q <= 1'b0;
        if (wdata[3]) pgerr_q  <= 1'b0;
      end

      // ---- Error flags ----
      if (ctrl_wrperr || mem_bad_wr) wrperr_q <= 1'b1;

      // ---- Erase start ----
      if (strt_req) begin
        erase_pend_q <= 1'b1;
        if (wdata[2]) begin           // mass erase
          erase_ptr_q <= '0;
          erase_end_q <= AddrWidth'(Depth - 1);
        end else begin                // page erase
          erase_ptr_q <= page_first;
          erase_end_q <= page_first + AddrWidth'(PageWords - 1);
        end
      end

      // ---- Engine ----
      unique case (state_q)
        Idle: begin
          if (erase_pend_q) begin
            erase_pend_q <= 1'b0;
          end else if (mem_prog) begin
            prog_addr_q  <= mem_req_i.addr[AddrWidth+1:2];
            prog_wdata_q <= mem_req_i.wdata;
            prog_be_q    <= mem_req_i.be;
          end
        end
        ProgWrite: begin
          eop_q <= 1'b1;
          if (prog_err) pgerr_q <= 1'b1;
        end
        Erase: begin
          erase_ptr_q <= erase_ptr_q + 1'b1;
          if (erase_ptr_q == erase_end_q) eop_q <= 1'b1;
        end
        default: ;
      endcase
    end
  end

  // Read data multiplexer
  logic [31:0] reg_rdata_d, reg_rdata_q;
  logic        reg_rvalid_q;

  always_comb begin
    reg_rdata_d = '0;
    unique case (reg_addr)
      RegCtrl:     reg_rdata_d = {lock_q, 26'h0, eopie_q, 1'b0, mer_q, per_q, pg_q};
      RegAddr:     reg_rdata_d = addr_q;
      RegStatus:   reg_rdata_d = {28'h0, pgerr_q, wrperr_q, eop_q, busy};
      RegSize:     reg_rdata_d = SizeBytes;
      RegPageSize: reg_rdata_d = PageBytes;
      default:     reg_rdata_d = '0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reg_rvalid_q <= 1'b0;
      reg_rdata_q  <= '0;
    end else begin
      reg_rvalid_q <= reg_req_i.req;
      if (reg_re) reg_rdata_q <= reg_rdata_d;
    end
  end

  assign reg_rsp_o.gnt    = 1'b1;
  assign reg_rsp_o.rvalid = reg_rvalid_q;
  assign reg_rsp_o.err    = 1'b0;
  assign reg_rsp_o.rdata  = reg_rdata_q;

  assign irq_o = eop_q & eopie_q;

  logic unused_bus;
  assign unused_bus = ^{mem_req_i.addr[31:AddrWidth+2], mem_req_i.addr[1:0],
                        reg_req_i.addr[31:12], reg_req_i.addr[1:0], reg_req_i.be,
                        addr_q[31:AddrWidth+2], addr_q[PageWidth+1:0]};

endmodule
