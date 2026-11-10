// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// Bow32 HyperRAM IP: HyperBus master for HyperRAM 2.0 devices (Infineon
// S80KS2562 256 Mb x8 1.8 V on the FMC+_DDR2_HyperRam card), behind TI TXV0108
// level shifters or wired directly. docs/ip/hyperram.md.
//
//   clk_i (SoC)                                   hr_clk (CK)                     pads
//   main bus --window--> bow_hyperram_win ==cmd FIFO==> bow_hyperram_ctrl --pin intent--> bow_hyperram_phy --> hr_io_o
//                        (read buffer,     <=resp FIFO==  (executor, arbiter,          (pin register,
//                         write buffer)                    engine, BIST, shadows,       read FIFO <-- hr_rd_clk
//   periph --0x4000_F000--> bow_hyperram_regs ==handshake==>  phase steppers)            aligner, capture) <-- hr_io_i
//
// Clocks: clk_i (SoC), hr_clk_i (CK rate: controller, PHY register, PSCLK of
// both MMCMs), hr_rd_clk_i (read capture: same frequency, fine phase shift
// hr_ps_*), and the write clock of the pad wrapper (DQ / RWDS, fine phase
// shift hr_wps_*; not used inside the IP). hr_rst_ni: asynchronous, low while
// the MMCMs are not locked.
// Resets: board = hr_rst_ni (the controller's CR0 / CR1 shadows, power state
// and phase steppers: the HyperRAM keeps its state through a SoC reset);
// channel = hr_rst_ni & rst_ni & !CTRL.CORE_RST, released per clock domain:
// window channel side, FIFOs, command handshake, controller, PHY. The bus
// slaves (window, registers) use rst_ni.

module bow_hyperram import bow_bus_pkg::*; import bow_hyperram_pkg::*; #(
  parameter int unsigned ClkHz      = 100_000_000,  // CK
  parameter int unsigned PsSteps    = 672,          // MMCM fine steps per CK
  parameter int unsigned PhyKind    = 1,            // 1 pads, 2 loopback emulator (INFO)
  parameter bit          HasLs      = 1'b1,         // level shifter controls on the pads (INFO)
  parameter int unsigned MemBytes   = 32 << 20,     // device size (S80KS2562: 32 MiB)
  parameter int unsigned WinBits    = 28,           // window decode: 256 MiB
  parameter int unsigned Lines      = 4,            // read buffer lines (32 B)
  parameter int unsigned EmuBytes   = 0,            // loopback emulator storage (EMU)
  parameter int unsigned WinTimeout = 1 << 18       // clk_i cycles
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  bus_req_t    mem_req_i,       // window
  output bus_rsp_t    mem_rsp_o,
  input  bus_req_t    reg_req_i,       // registers
  output bus_rsp_t    reg_rsp_o,
  output logic        irq_o,

  input  logic        hr_clk_i,
  input  logic        hr_rst_ni,       // asynchronous, active low (MMCMs locked)
  input  logic        hr_rd_clk_i,
  output logic        hr_ps_en_o,      // read phase (PSCLK = hr_clk_i)
  output logic        hr_ps_inc_o,
  input  logic        hr_ps_done_i,
  output logic        hr_wps_en_o,     // write phase (PSCLK = hr_clk_i)
  output logic        hr_wps_inc_o,
  input  logic        hr_wps_done_i,
  output hr_io_out_t  hr_io_o,         // hr_clk_i domain
  input  hr_io_in_t   hr_io_i,         // hr_rd_clk_i domain
  input  logic        hr_rwds_pad_i,   // asynchronous
  input  logic [31:0] hr_dbg_i         // board debug word (loopback emulator), any domain
);

  // ===========================================================================
  // Resets
  // ===========================================================================
  logic core_rst, chn_src_n, chn_sys_n, chn_hr_n, chn_rd_n, brd_hr_n;

  assign chn_src_n = hr_rst_ni & rst_ni & ~core_rst;

  bow_rst_sync u_rst_sys (.clk_i,                  .rst_ni (chn_src_n), .rst_no (chn_sys_n));
  bow_rst_sync u_rst_hr  (.clk_i (hr_clk_i),       .rst_ni (chn_src_n), .rst_no (chn_hr_n));
  bow_rst_sync u_rst_rd  (.clk_i (hr_rd_clk_i),    .rst_ni (chn_src_n), .rst_no (chn_rd_n));
  bow_rst_sync u_rst_brd (.clk_i (hr_clk_i),       .rst_ni (hr_rst_ni), .rst_no (brd_hr_n));

  // ===========================================================================
  // Registers
  // ===========================================================================
  cfg_t        cfg_src, cfg;
  logic        ready, rbuf_en, wrap_fill, wpost, flush, inval, clk_ok, lnk_up;
  logic [15:0] wb_tmo;
  logic        hc_req, hc_req_s, hc_ack, hc_err;
  logic [3:0]  hc_code;
  logic [7:0]  hc_ecode;
  logic [15:0] hc_rdata, ps_tgt, wps_tgt, reg_wdata, cr0, cr1, ps_now, wps_now;
  logic [1:0]  reg_sel, pwr;
  logic [2:0]  bist_mode;
  logic [7:0]  bist_burst, err_code;
  logic [31:0] bist_addr, bist_len, bist_seed, bist_errs, bist_faddr, bist_fdata, bist_cycles;
  logic [7:0][31:0]  st;
  logic [63:0][17:0] cap;
  logic        applied, bist_busy, rfifo_broken, chan_idle;
  logic        ev_rd_err, ev_wr_err, ev_tcsm, ev_bist_done, ev_bist_err, ev_rfifo_err, ev_cap_done;
  logic        win_idle, win_dead, win_nrdy, win_range, win_tmo, win_rderr, win_wrerr, win_hit, win_miss,
               win_flush;
  logic [31:0] win_err_addr;

  bow_hyperram_regs #(
    .ClkHz    (ClkHz),
    .PsSteps  (PsSteps),
    .PhyKind  (PhyKind),
    .HasLs    (HasLs),
    .MemBytes (MemBytes),
    .Lines    (Lines),
    .EmuBytes (EmuBytes)
  ) u_regs (
    .clk_i,
    .rst_ni,
    .lnk_ni          (chn_sys_n),
    .bus_req_i       (reg_req_i),
    .bus_rsp_o       (reg_rsp_o),
    .irq_o,
    .ready_o         (ready),
    .core_rst_o      (core_rst),
    .rbuf_en_o       (rbuf_en),
    .wrap_fill_o     (wrap_fill),
    .wpost_o         (wpost),
    .wb_tmo_o        (wb_tmo),
    .flush_o         (flush),
    .inval_o         (inval),
    .clk_ok_o        (clk_ok),
    .win_idle_i      (win_idle),
    .win_dead_i      (win_dead),
    .win_nrdy_i      (win_nrdy),
    .win_range_i     (win_range),
    .win_tmo_i       (win_tmo),
    .win_rderr_i     (win_rderr),
    .win_wrerr_i     (win_wrerr),
    .lnk_up_o        (lnk_up),
    .win_err_addr_i  (win_err_addr),
    .win_hit_i       (win_hit),
    .win_miss_i      (win_miss),
    .win_flush_i     (win_flush),
    .cfg_o           (cfg_src),
    .hc_req_o        (hc_req),
    .hc_code_o       (hc_code),
    .ps_tgt_o        (ps_tgt),
    .wps_tgt_o       (wps_tgt),
    .reg_sel_o       (reg_sel),
    .reg_wdata_o     (reg_wdata),
    .bist_mode_o     (bist_mode),
    .bist_burst_o    (bist_burst),
    .bist_addr_o     (bist_addr),
    .bist_len_o      (bist_len),
    .bist_seed_o     (bist_seed),
    .hc_ack_i        (hc_ack),
    .hc_err_i        (hc_err),
    .hc_ecode_i      (hc_ecode),
    .hc_rdata_i      (hc_rdata),
    .hr_clk_i,
    .hr_lnk_ni       (chn_hr_n),
    .applied_i       (applied),
    .cr0_i           (cr0),
    .cr1_i           (cr1),
    .pwr_i           (pwr),
    .ps_now_i        (ps_now),
    .wps_now_i       (wps_now),
    .bist_busy_i     (bist_busy),
    .rfifo_broken_i  (rfifo_broken),
    .chan_idle_i     (chan_idle),
    .bist_errs_i     (bist_errs),
    .bist_faddr_i    (bist_faddr),
    .bist_fdata_i    (bist_fdata),
    .bist_cycles_i   (bist_cycles),
    .st_i            (st),
    .err_code_i      (err_code),
    .cap_i           (cap),
    .ev_rd_err_i     (ev_rd_err),
    .ev_wr_err_i     (ev_wr_err),
    .ev_tcsm_i       (ev_tcsm),
    .ev_bist_done_i  (ev_bist_done),
    .ev_bist_err_i   (ev_bist_err),
    .ev_rfifo_err_i  (ev_rfifo_err),
    .ev_cap_done_i   (ev_cap_done),
    .dbg_i           (hr_dbg_i)
  );

  bow_sync u_sync_req (
    .clk_i  (hr_clk_i),
    .rst_ni (chn_hr_n),
    .d_i    (hc_req),
    .q_o    (hc_req_s)
  );

  // ===========================================================================
  // Window and its FIFOs
  // ===========================================================================
  logic              wc_push, wc_full, wc_pop, wc_empty;
  logic [WcmdW-1:0]  wc_wdata, wc_rdata;
  logic              wr_push, wr_full, wr_pop, wr_empty;
  logic [WrespW-1:0] wr_wdata, wr_rdata;

  bow_hyperram_win #(
    .MemBytes   (MemBytes),
    .WinBits    (WinBits),
    .Lines      (Lines),
    .WinTimeout (WinTimeout)
  ) u_win (
    .clk_i,
    .rst_ni,
    .chn_rst_ni     (chn_sys_n),
    .mem_req_i,
    .mem_rsp_o,
    .ready_i        (ready),
    .abort_i        (!clk_ok || core_rst),
    .clk_lost_i     (!clk_ok && lnk_up),      // CORE_RST / link down: NOT_READY, not a timeout
    .rbuf_en_i      (rbuf_en),
    .wrap_fill_i    (wrap_fill),
    .wpost_i        (wpost),
    .wb_tmo_i       (wb_tmo),
    .flush_i        (flush),
    .inval_i        (inval),
    .idle_o         (win_idle),
    .dead_o         (win_dead),
    .ev_not_ready_o (win_nrdy),
    .ev_range_o     (win_range),
    .ev_timeout_o   (win_tmo),
    .ev_rd_err_o    (win_rderr),
    .ev_wr_err_o    (win_wrerr),
    .err_addr_o     (win_err_addr),
    .st_hit_o       (win_hit),
    .st_miss_o      (win_miss),
    .st_flush_o     (win_flush),
    .wc_push_o      (wc_push),
    .wc_wdata_o     (wc_wdata),
    .wc_full_i      (wc_full),
    .wr_empty_i     (wr_empty),
    .wr_rdata_i     (wr_rdata),
    .wr_pop_o       (wr_pop)
  );

  bow_fifo_async #(
    .Width (WcmdW),
    .Depth (16)
  ) u_cmd_fifo (
    .wclk_i  (clk_i),
    .wrst_ni (chn_sys_n),
    .push_i  (wc_push),
    .wdata_i (wc_wdata),
    .full_o  (wc_full),
    .afull_o (),
    .rclk_i  (hr_clk_i),
    .rrst_ni (chn_hr_n),
    .pop_i   (wc_pop),
    .rdata_o (wc_rdata),
    .empty_o (wc_empty)
  );

  bow_fifo_async #(
    .Width (WrespW),
    .Depth (16)
  ) u_resp_fifo (
    .wclk_i  (hr_clk_i),
    .wrst_ni (chn_hr_n),
    .push_i  (wr_push),
    .wdata_i (wr_wdata),
    .full_o  (wr_full),
    .afull_o (),
    .rclk_i  (clk_i),
    .rrst_ni (chn_sys_n),
    .pop_i   (wr_pop),
    .rdata_o (wr_rdata),
    .empty_o (wr_empty)
  );

  // ===========================================================================
  // Controller and PHY (hr_clk)
  // ===========================================================================
  hr_io_out_t pin_d;
  logic       txn_start, arm, rd_busy, rd_v, rd_done, rd_err, rfifo_sync, cap_arm, rwds_lvl;
  logic [7:0] arm_n, rd_a, rd_b, rd_code;

  bow_hyperram_ctrl #(
    .PsSteps (PsSteps)
  ) u_ctrl (
    .clk_i          (hr_clk_i),
    .rst_ni         (chn_hr_n),
    .brd_rst_ni     (brd_hr_n),
    .cfg_src_i      (cfg_src),
    .hc_req_i       (hc_req_s),
    .hc_code_i      (hc_code),
    .ps_tgt_i       (ps_tgt),
    .wps_tgt_i      (wps_tgt),
    .reg_sel_i      (reg_sel),
    .reg_wdata_i    (reg_wdata),
    .bist_mode_i    (bist_mode),
    .bist_burst_i   (bist_burst),
    .bist_addr_i    (bist_addr),
    .bist_len_i     (bist_len),
    .bist_seed_i    (bist_seed),
    .hc_ack_o       (hc_ack),
    .hc_err_o       (hc_err),
    .hc_code_o      (hc_ecode),
    .hc_rdata_o     (hc_rdata),
    .cfg_o          (cfg),
    .applied_o      (applied),
    .cr0_o          (cr0),
    .cr1_o          (cr1),
    .pwr_o          (pwr),
    .ps_now_o       (ps_now),
    .wps_now_o      (wps_now),
    .bist_busy_o    (bist_busy),
    .bist_errs_o    (bist_errs),
    .bist_faddr_o   (bist_faddr),
    .bist_fdata_o   (bist_fdata),
    .bist_cycles_o  (bist_cycles),
    .st_o           (st),
    .err_code_o     (err_code),
    .ev_rd_err_o    (ev_rd_err),
    .ev_wr_err_o    (ev_wr_err),
    .ev_tcsm_o      (ev_tcsm),
    .ev_bist_done_o (ev_bist_done),
    .ev_bist_err_o  (ev_bist_err),
    .wc_empty_i     (wc_empty),
    .wc_rdata_i     (wc_rdata),
    .wc_pop_o       (wc_pop),
    .wr_full_i      (wr_full),
    .wr_push_o      (wr_push),
    .wr_wdata_o     (wr_wdata),
    .chan_idle_o    (chan_idle),
    .pin_d_o        (pin_d),
    .txn_start_o    (txn_start),
    .arm_o          (arm),
    .arm_n_o        (arm_n),
    .rd_busy_i      (rd_busy),
    .rd_v_i         (rd_v),
    .rd_a_i         (rd_a),
    .rd_b_i         (rd_b),
    .rd_done_i      (rd_done),
    .rd_err_i       (rd_err),
    .rd_code_i      (rd_code),
    .rfifo_sync_o   (rfifo_sync),
    .cap_arm_o      (cap_arm),
    .rwds_lvl_i     (rwds_lvl),
    .ps_en_o        (hr_ps_en_o),
    .ps_inc_o       (hr_ps_inc_o),
    .ps_done_i      (hr_ps_done_i),
    .wps_en_o       (hr_wps_en_o),
    .wps_inc_o      (hr_wps_inc_o),
    .wps_done_i     (hr_wps_done_i)
  );

  bow_hyperram_phy u_phy (
    .clk_i          (hr_clk_i),
    .rst_ni         (chn_hr_n),
    .rd_clk_i       (hr_rd_clk_i),
    .rd_rst_ni      (chn_rd_n),
    .cfg_i          (cfg),
    .pin_d_i        (pin_d),
    .txn_start_i    (txn_start),
    .arm_i          (arm),
    .arm_n_i        (arm_n),
    .rd_busy_o      (rd_busy),
    .rd_v_o         (rd_v),
    .rd_a_o         (rd_a),
    .rd_b_o         (rd_b),
    .rd_done_o      (rd_done),
    .rd_err_o       (rd_err),
    .rd_code_o      (rd_code),
    .rfifo_sync_i   (rfifo_sync),
    .rfifo_err_o    (ev_rfifo_err),
    .rfifo_broken_o (rfifo_broken),
    .cap_arm_i      (cap_arm),
    .cap_done_o     (ev_cap_done),
    .cap_o          (cap),
    .rwds_lvl_o     (rwds_lvl),
    .io_o           (hr_io_o),
    .io_i           (hr_io_i),
    .rwds_pad_i     (hr_rwds_pad_i)
  );

endmodule
