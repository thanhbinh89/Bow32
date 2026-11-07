// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Synthesizable HyperRAM 2.0 device (Infineon S80KS2562 behaviour) at the
// level of the PHY's pin register: the HyperRAM of the MPS4 loopback build
// (and of the system simulation), behind the pad wrapper's loopback: its
// outputs replace the controller's DQ / RWDS ODDR data (lb_*) and the read
// IDDRs take them back through the pads. hr_clk domain. docs/ip/hyperram.md,
// "Emulator".
//
// io_i is the PHY register (bow_hyperram_pkg contract: the value of cycle J
// is on the pins in pin cycle J+1); lb_* of cycle J replace io_i.dq / rwds of
// the same cycle, so the emulator answers in the timing of the pins:
//   * transaction: cs_n falls (t = 0); CA bytes on the first three ck_en
//     cycles (t = 1..3); t_D = 4 for a register write, else L + 3 or 2L + 3
//     (L = CR0 latency; 2x when CR0[3] = 1, or for a refresh collision drawn
//     at random (RefreshPct16 / 16) in variable latency mode);
//   * RWDS (lb_rwds_en): the latency indication in t = 1..3 (every
//     transaction), low from t = 4 in reads, then high / low with byte A / B
//     of every word (t >= t_D), low after the last word;
//   * read data (lb_dq_en from t_D - 1): memory words (linear, wrapped 16 /
//     32 / 64 / 128 bytes per CR0[1:0], hybrid when CR0[2] = 0) or the
//     register (big endian: byte A = [15:8]); t_D - 1 drives 0;
//   * memory write: word t - t_D in t >= t_D, byte not written when its RWDS
//     bit is 1; register write: CR0 / CR1 at t = 4 (CR1[1:0] read only);
//   * CR0[15] = 0 -> deep power down, CR1[5] = 1 -> hybrid sleep; a CS# low
//     pulse without CK (length in WakeMinCycles .. WakeMaxCycles) wakes the
//     device after WaitCycles (DPD: registers to their defaults); RESET# low
//     (>= TrpCycles) resets the registers and needs TrhCycles before CS#.
// Memory: MemBytes, 8 bytes per row with byte write enables, 3 cycle read
// latency (UltraRAM with UseUram, else whatever the tool picks; the third
// register is a fabric flop, so that the lb_* outputs, which go straight to
// the pad ODDRs, start at a flop and not after the cascade of a deep UltraRAM
// array; the first word of a read is fetched at t_D - 3 >= 3, from the CA of
// that cycle when t_D = 6); addresses
// above MemBytes wrap and are flagged.
// Checks (dbg_o = {err, 1'b0, power[1:0], 4'b0, first code[7:0], count[15:0]}):
//   01 CA reserved bits [15:3] not 0       02 register write: not linear / ID
//   03 FPGA drives RWDS while the device does (t <= 3, reads, register writes)
//   04 FPGA drives DQ while the device does (reads from t_D - 1)
//   05 memory write: no RWDS preamble at t_D - 1 or no mask in a data cycle
//   06 register read longer than one word  07 CS# low longer than TcsmCycles
//   08 CS# high shorter than CshiCycles     09 access in DPD / HS / wake / reset wait
//   0A memory address beyond MemBytes       0B RESET# pulse too short / CS# too soon after it
//   0C reserved latency code written to CR0 0D wake pulse length out of range
//   0E CS# rose before the CA was complete  0F CK while CS# high

module bow_hyperram_dev import bow_hyperram_pkg::*; #(
  parameter int unsigned MemBytes      = 4 << 20,
  parameter bit          UseUram       = 1'b0,
  parameter logic [15:0] Id0           = 16'h0E86,   // S80KS2562
  parameter logic [15:0] Id1           = 16'h0001,   // HyperRAM 2.0
  parameter logic [1:0]  Cr1Ro         = 2'b01,      // CR1[1:0]: 01 4 us
  parameter int unsigned TcsmCycles    = 400,        // 4 us at 100 MHz
  parameter int unsigned CshiCycles    = 1,
  parameter int unsigned RefreshPct16  = 4,          // variable latency: P(2x) = n / 16
  parameter int unsigned TrpCycles     = 20,         // 200 ns at 100 MHz
  parameter int unsigned TrhCycles     = 20,
  parameter int unsigned WakeMinCycles = 20,         // CS# pulse 200 ns (DPD; HS needs 60 ns)
  parameter int unsigned WakeMaxCycles = 300,        // 3 us
  parameter int unsigned WaitCycles    = 10000       // tEXTDPD 150 us / tEXTHS 100 us, scaled
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  hr_io_out_t       io_i,
  output logic             lb_dq_en_o,
  output logic [1:0][7:0]  lb_dq_o,
  output logic             lb_rwds_en_o,
  output logic [1:0]       lb_rwds_o,
  output logic [31:0]      dbg_o
);

  localparam int unsigned Rows  = MemBytes / 8;
  localparam int unsigned RowAw = $clog2(Rows);
  localparam int unsigned WAw   = RowAw + 2;            // word address bits

  // ===========================================================================
  // Device registers and power state
  // ===========================================================================
  logic [15:0] cr0_q, cr1_q;
  pwr_e        pwr_q;
  logic [2:0]  lat_l;
  assign lat_l = cr0_lat(cr0_q[7:4]);

  // ===========================================================================
  // Memory: 8 bytes per row, byte write enables, read latency 3
  // ===========================================================================
  logic [RowAw-1:0] m_raddr, m_waddr;
  logic [7:0]       m_we;
  logic [63:0]      m_wdata, m_q1, m_q2;
  (* dont_touch = "true" *) logic [63:0] m_q3;   // fabric flop (see the header)

  always_ff @(posedge clk_i) m_q3 <= m_q2;

  if (UseUram) begin : g_uram
    (* ram_style = "ultra" *) logic [63:0] mem [Rows];
    always_ff @(posedge clk_i) begin
      for (int unsigned b = 0; b < 8; b++) if (m_we[b]) mem[m_waddr][8*b +: 8] <= m_wdata[8*b +: 8];
      m_q1 <= mem[m_raddr];
      m_q2 <= m_q1;
    end
  end else begin : g_ram
    logic [63:0] mem [Rows];
`ifndef SYNTHESIS
    initial for (int unsigned i = 0; i < Rows; i++) mem[i] = '0;
`endif
    always_ff @(posedge clk_i) begin
      for (int unsigned b = 0; b < 8; b++) if (m_we[b]) mem[m_waddr][8*b +: 8] <= m_wdata[8*b +: 8];
      m_q1 <= mem[m_raddr];
      m_q2 <= m_q1;
    end
  end

  // ===========================================================================
  // Transaction tracking
  // ===========================================================================
  typedef enum logic [2:0] {
    DIdle,      // CS# high
    DCa,        // CA bytes
    DRun,       // latency / data
    DIgnore,    // CS# low, transaction not answered (power state, error)
    DWake       // CS# low pulse while asleep
  } dstate_e;

  dstate_e     st_q;
  logic [15:0] t_q;              // transaction cycle of io_i (valid while CS# low)
  logic [1:0]  ca_n_q;           // CA bytes taken (cycles)
  logic [47:0] ca_q;
  logic        lat2x_q;
  logic [15:0] td_q;             // first data cycle
  logic        rd_q, reg_q, lin_q;
  logic [31:0] wa_q;             // start word address
  logic [15:0] csl_q;            // CS# low cycles
  logic [15:0] csh_q;            // CS# high cycles
  logic [15:0] wait_q;           // wake / reset recovery left
  logic [15:0] rst_low_q, rst_high_q;
  logic        rst_prev_q;
  logic [3:0]  lfsr_q;           // refresh collision draw

  logic        err_q;
  logic [7:0]  ecode_q;
  logic [15:0] ecnt_q;
  logic        e_v;
  logic [7:0]  e_c;

  logic cs, ck;
  assign cs = !io_i.cs_n;
  assign ck = io_i.ck_en;

  // ---- burst address of data word n
  logic [6:0]  grp;               // wrap group in words - 1
  always_comb begin
    unique case (cr0_q[1:0])
      2'b00:   grp = 7'd63;       // 128 B
      2'b01:   grp = 7'd31;       // 64 B
      2'b10:   grp = 7'd7;        // 16 B
      default: grp = 7'd15;       // 32 B
    endcase
  end

  function automatic logic [31:0] baddr(logic [31:0] a0, logic [15:0] n, logic linear,
                                        logic hybrid, logic [6:0] g);
    logic [31:0] base, m;
    m    = {25'd0, g};
    base = a0 & ~m;
    if (linear)                         return a0 + 32'(n);
    if (hybrid && 32'(n) > m)           return base + 32'(n);
    return base | ((a0 + 32'(n)) & m);
  endfunction

  // data word index of this cycle, and the one to fetch (three cycles ahead;
  // in the last CA cycle from the CA of that cycle, see the header)
  logic        in_run;
  logic        ca_done;           // the third CA byte is in this cycle
  logic [47:0] ca_new;
  logic [15:0] td_new;            // first data cycle of the CA in ca_new
  logic [15:0] dn, fn, td_f;
  logic [31:0] faddr, wa_f;
  logic        lin_f;
  assign in_run = (st_q == DRun) && cs;
  assign td_new = (!ca_new[47] && ca_new[46]) ? 16'd4
                : (lat2x_q ? {12'd0, lat_l, 1'b0} : {13'd0, lat_l}) + 16'd3;
  assign td_f   = ca_done ? td_new : td_q;
  assign wa_f   = ca_done ? {ca_new[44:16], ca_new[2:0]} : wa_q;
  assign lin_f  = ca_done ? ca_new[45] : lin_q;
  assign dn     = t_q - td_q;
  assign fn     = t_q + 16'd3 - td_f;
  assign faddr  = baddr(wa_f, fn, lin_f, !cr0_q[2], grp);

  // lane pipeline of the fetched words (memory read latency 3)
  logic [1:0] lane1_q, lane2_q, lane3_q;
  assign m_raddr = faddr[WAw-1:2];

  always_ff @(posedge clk_i) begin
    lane1_q <= faddr[1:0];
    lane2_q <= lane1_q;
    lane3_q <= lane2_q;
  end

  logic [15:0] mword;             // {B, A} of the word fetched three cycles ago
  assign mword = m_q3[16*lane3_q +: 16];

  // register value of a register read
  logic [15:0] rval;
  always_comb begin
    unique case ({wa_q[11], wa_q[0]})
      2'b00:   rval = Id0;
      2'b01:   rval = Id1;
      2'b10:   rval = cr0_q;
      default: rval = cr1_q;
    endcase
  end

  // ---- address of the data word of this cycle (memory write, range check)
  logic [31:0] waddr;
  logic        wbeyond;
  assign waddr   = baddr(wa_q, dn, lin_q, !cr0_q[2], grp);
  assign wbeyond = (waddr >> WAw) != 32'd0;
  always_comb begin
    m_we    = '0;
    m_waddr = waddr[WAw-1:2];
    m_wdata = {4{io_i.dq[1], io_i.dq[0]}};
    if (in_run && !rd_q && !reg_q && ck && t_q >= td_q) begin
      m_we[2 * waddr[1:0]]     = !io_i.rwds[0];   // byte A
      m_we[2 * waddr[1:0] + 1] = !io_i.rwds[1];   // byte B
    end
  end

  // ---- outputs (answers for the pins of this cycle)
  always_comb begin
    lb_dq_en_o   = 1'b0;
    lb_dq_o      = '0;
    lb_rwds_en_o = 1'b0;
    lb_rwds_o    = 2'b00;
    if (cs && (st_q == DCa || st_q == DRun) && t_q >= 16'd1 && t_q <= 16'd3) begin
      lb_rwds_en_o = 1'b1;
      lb_rwds_o    = {2{lat2x_q}};
    end
    if (in_run && rd_q) begin
      lb_rwds_en_o = 1'b1;               // low during the latency
      if (t_q + 16'd1 >= td_q) lb_dq_en_o = 1'b1;
      if (t_q >= td_q && ck) begin
        lb_rwds_o = 2'b01;               // high with byte A, low with byte B
        if (reg_q) lb_dq_o = {rval[7:0], rval[15:8]};
        else       lb_dq_o = {mword[15:8], mword[7:0]};
      end
    end
  end

  // ---- checks and state
  always_comb begin
    e_v = 1'b0;
    e_c = 8'h00;
    if (st_q == DIdle && !cs && ck) begin
      e_v = 1'b1; e_c = 8'h0F;
    end
    // the device drives RWDS in t <= 3; the FPGA never drives it in reads
    // and register writes
    if (cs && (st_q == DCa || st_q == DRun) && io_i.rwds_oe &&
        (t_q <= 16'd3 || (st_q == DRun && (rd_q || reg_q)))) begin
      e_v = 1'b1; e_c = 8'h03;
    end
    if (in_run && rd_q && t_q + 16'd1 >= td_q && io_i.dq_oe) begin
      e_v = 1'b1; e_c = 8'h04;
    end
    if (in_run && !rd_q && !reg_q && t_q + 16'd1 == td_q && !(io_i.rwds_oe && io_i.rwds == 2'b00)) begin
      e_v = 1'b1; e_c = 8'h05;
    end
    if (in_run && !rd_q && !reg_q && t_q >= td_q && ck && !io_i.rwds_oe) begin
      e_v = 1'b1; e_c = 8'h05;
    end
    if (in_run && rd_q && reg_q && ck && t_q > td_q) begin
      e_v = 1'b1; e_c = 8'h06;
    end
    if (cs && csl_q > 16'(TcsmCycles)) begin
      e_v = 1'b1; e_c = 8'h07;
    end
    if (in_run && !reg_q && ck && t_q >= td_q && wbeyond) begin
      e_v = 1'b1; e_c = 8'h0A;           // data word beyond the emulated memory
    end
  end

  assign ca_done = (st_q == DCa) && cs && ck && (ca_n_q == 2'd2);
  assign ca_new  = {ca_q[31:0], io_i.dq[0], io_i.dq[1]};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cr0_q      <= Cr0Default;
      cr1_q      <= {Cr1Default[15:2], Cr1Ro};
      pwr_q      <= PwrActive;
      st_q       <= DIdle;
      t_q        <= '0;
      ca_n_q     <= '0;
      ca_q       <= '0;
      lat2x_q    <= 1'b1;
      td_q       <= '0;
      rd_q       <= 1'b0;
      reg_q      <= 1'b0;
      lin_q      <= 1'b1;
      wa_q       <= '0;
      csl_q      <= '0;
      csh_q      <= 16'hFFFF;
      wait_q     <= '0;
      rst_low_q  <= '0;
      rst_high_q <= 16'hFFFF;
      rst_prev_q <= 1'b1;
      lfsr_q     <= 4'h9;
      err_q      <= 1'b0;
      ecode_q    <= '0;
      ecnt_q     <= '0;
    end else begin
      lfsr_q <= {lfsr_q[2:0], lfsr_q[3] ^ lfsr_q[2]};
      if (cs) begin
        t_q   <= t_q + 16'd1;
        csl_q <= csl_q + 16'd1;
      end
      if (!cs && csh_q != 16'hFFFF) csh_q <= csh_q + 16'd1;
      if (wait_q != '0) begin
        wait_q <= wait_q - 16'd1;
        if (wait_q == 16'd1 && pwr_q == PwrWait) pwr_q <= PwrActive;
      end

      // RESET#: registers to their defaults, transactions ignored
      rst_prev_q <= io_i.rst_n;
      if (!io_i.rst_n) begin
        if (rst_low_q != 16'hFFFF) rst_low_q <= rst_low_q + 16'd1;
        rst_high_q <= '0;
        cr0_q      <= Cr0Default;
        cr1_q      <= {Cr1Default[15:2], Cr1Ro};
        pwr_q      <= PwrActive;
        wait_q     <= '0;
        st_q       <= DIdle;
      end else begin
        if (!rst_prev_q && rst_low_q < 16'(TrpCycles)) e_err(8'h0B);
        if (!rst_prev_q) rst_low_q <= '0;
        if (rst_high_q != 16'hFFFF) rst_high_q <= rst_high_q + 16'd1;
      end

      if (io_i.rst_n) unique case (st_q)
        DIdle: begin
          if (cs && io_i.rst_n) begin
            t_q   <= 16'd1;
            csl_q <= 16'd1;
            if (csh_q < 16'(CshiCycles)) begin
              e_err(8'h08);
            end
            if (rst_high_q < 16'(TrhCycles)) begin
              e_err(8'h0B);
            end
            if (pwr_q == PwrDpd || pwr_q == PwrHs) begin
              st_q <= DWake;
            end else if (pwr_q == PwrWait) begin
              e_err(8'h09);
              st_q <= DIgnore;
            end else begin
              st_q    <= DCa;
              ca_n_q  <= '0;
              lat2x_q <= cr0_q[3] || (32'(lfsr_q) < RefreshPct16);
            end
          end
        end
        DCa: begin
          if (!cs) begin
            e_err(8'h0E);
            st_q  <= DIdle;
            csh_q <= '0;
          end else if (ck) begin
            ca_q   <= ca_new;
            ca_n_q <= ca_n_q + 2'd1;
            if (ca_done) begin
              st_q  <= DRun;
              rd_q  <= ca_new[47];
              reg_q <= ca_new[46];
              lin_q <= ca_new[45];
              wa_q  <= {ca_new[44:16], ca_new[2:0]};
              if (ca_new[15:3] != '0) e_err(8'h01);
              td_q  <= td_new;
              if (!ca_new[47] && ca_new[46] && (!ca_new[45] || ca_new[24] == 1'b0)) e_err(8'h02);
            end
          end
        end
        DRun: begin
          if (!cs) begin
            st_q  <= DIdle;
            csh_q <= '0;
          end else if (reg_q && !rd_q && ck && t_q == 16'd4) begin
            // register write: {A, B} = {[15:8], [7:0]}
            if (wa_q[0]) begin
              cr1_q <= {io_i.dq[0], io_i.dq[1][7:2], Cr1Ro};
              if (io_i.dq[1][5]) pwr_q <= PwrHs;
            end else begin
              cr0_q <= {io_i.dq[0], io_i.dq[1]};
              if (!cr0_lat_valid(io_i.dq[1][7:4])) e_err(8'h0C);
              if (!io_i.dq[0][7]) pwr_q <= PwrDpd;
            end
          end
        end
        DWake: begin
          if (ck) e_err(8'h09);
          if (!cs) begin
            st_q  <= DIdle;
            csh_q <= '0;
            if (csl_q < 16'(WakeMinCycles) || csl_q > 16'(WakeMaxCycles)) e_err(8'h0D);
            if (pwr_q == PwrDpd) begin
              cr0_q <= Cr0Default;
              cr1_q <= {Cr1Default[15:2], Cr1Ro};
            end else begin
              cr1_q[5] <= 1'b0;
            end
            pwr_q  <= PwrWait;
            wait_q <= 16'(WaitCycles);
          end
        end
        default: begin                    // DIgnore
          if (!cs) begin
            st_q  <= DIdle;
            csh_q <= '0;
          end
        end
      endcase

      if (e_v) e_err(e_c);
    end
  end

  // record an error (first code, saturating count)
  task automatic e_err(logic [7:0] c);
    if (!err_q) ecode_q <= c;
    err_q <= 1'b1;
    if (ecnt_q != 16'hFFFF) ecnt_q <= ecnt_q + 16'd1;
  endtask

  assign dbg_o = {err_q, 1'b0, pwr_q, 4'd0, ecode_q, ecnt_q};

  logic unused;
  assign unused = ^{io_i.ls_oe_n, io_i.ls_dir_dq, io_i.ls_dir_rwds, faddr[31:WAw], waddr[31:WAw],
                    m_q2, ca_q[47:32], io_i.dq_oe};

`ifndef SYNTHESIS
  if ((1 << $clog2(MemBytes)) != MemBytes || MemBytes < 64) begin : g_bad_mem
    initial $fatal(1, "bow_hyperram_dev: MemBytes must be a power of two >= 64");
  end
`endif

endmodule
