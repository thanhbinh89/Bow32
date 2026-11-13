// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 packet layer (the controller's clock csi_clk; the byte clock domain up to step 6 of
// docs/ip/mipi_rx_arch.md): one packet per HS burst. The words come from the lane merge's
// two clock FIFO, with gaps between them (gaps change nothing here).
//
// The words of the lane merge carry 1, 2 or 4 bytes (active lanes, constant
// within a burst), so the 4 byte header always fills whole words and the
// body starts at byte 0 of a word. The first 4 bytes after sop are the
// packet header {ECC, WC MSB, WC LSB, DI}. The header is decoded in a
// pipeline beside the byte stream:
//   H  header complete (stage 0)
//   P1 ECC syndrome
//   P2 single bit correction, corrected header (or raw, if uncorrectable)
//   P3 decisions: short / long, VC and DT filter, frame state, events,
//      LOG entry of the packets that end with the header
// The stream is delayed by 3 cycles ("stage D") so that the decisions are
// known when the first byte after the header (or the eob) reaches stage D.
// With 4 bytes per word the header is the sop word itself: P3 comes in the
// cycle in which that word is in stage D, and the next word is body.
//
// * Short packets (DT 0x00..0x0F) of the selected VC (CTRL.VC, or any VC):
//   FS starts a frame (FS inside a frame is a frame error), FE completes it
//   (FE without FS is a frame error, except before the first FS after an RX
//   start). Other short packets are only counted and logged.
// * Long packets: WC payload bytes, then the CRC (LS byte first). Accepted =
//   VC match and DT == CTRL.DT, DT in {RAW8, RAW10}: the payload goes to the
//   unpacker (px_*). All long packets are CRC checked; the others (e.g.
//   embedded data 0x12, optical black lines 0x37) are dropped (ev_drop). The
//   packet ends when header + WC + 2 bytes have been received, never at eob;
//   later bytes are ignored until the next sop. Pixels are forwarded before
//   the CRC is known.
// * Uncorrectable header: the rest of the burst is ignored.
// * eob (or sop) while a packet is open: truncated (ev_trunc; the unpacker
//   ends the line).
// * px_eol_o comes in a cycle without payload bytes: after the last body
//   word, or one cycle later when that word also carries payload bytes
//   (possible with 4 bytes per word: CRC in bytes 1-2 or 2-3).
// * px_err_o comes with px_eol_o: the line has a CRC error, a format error
//   or was truncated (m_axis tuser[1] at tlast).
// * Bytes that follow a complete packet (short or long) in the same burst
//   are counted until eob (also the bytes after the CRC in the last word of
//   a long packet); more than extra_i (CTRL.EXTRA, 0 = off) is ev_extra,
//   once per burst: the burst most likely holds further packets, which this
//   layer drops. The trail of the burst also gives some bytes (up to ~30
//   per lane at 1 Gbit/s, times the active lanes), so extra_i must be above
//   that.
// * One LOG entry per packet with a decoded header, written when it ends.
//   For long packets it is written 3 cycles after px_eol_o so that the
//   FIFO overflow flag of the unpacker (px_ovf_i) includes the last group:
//   the unpacker pushes the last group at most one cycle after it sees
//   px_eol_o, and px_ovf_i shows the result one cycle after the push.
// * CRC: 1, 2, 3 or 4 bytes per cycle (the body bytes of the word), the
//   candidates after every byte count in parallel, then a select.
// Everything here is reset by the datapath reset (RX off).

module bow_csi2_packet import bow_csi2rx_pkg::*; #(
  parameter int unsigned Bytes = 2      // bytes per word: Lanes of the receiver (1, 2 or 4)
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,          // csi clock, datapath reset

  input  logic [1:0]            vc_i,            // configuration (static while RX is on)
  input  logic                  vc_any_i,
  input  logic [5:0]            dt_i,
  input  logic [7:0]            extra_i,         // CTRL.EXTRA (static while RX is on)

  input  logic                  valid_i,         // from the lane merge
  input  logic [Bytes-1:0][7:0] data_i,          // byte k in [k]
  input  logic [2:0]            nbytes_i,        // 1, 2 or 4 bytes in data_i (the lowest)
  input  logic                  sop_i,
  input  logic                  eob_i,

  output logic                  px_sol_o,        // an accepted line starts (before its first byte)
  output logic                  px_raw10_o,      // format of the line, from px_sol_o to px_eol_o
  output logic [Bytes-1:0]      px_valid_o,      // payload bytes: [k] byte k (only with [k-1])
  output logic [Bytes-1:0][7:0] px_data_o,
  output logic                  px_eol_o,        // end of the line (in a cycle without bytes)
  output logic                  px_err_o,        // with px_eol_o: CRC / format error or truncated
  input  logic                  px_ovf_i,        // unpacker: a group of the line was dropped

  output logic                  fs_o,            // FS of the selected VC (frame sum = 0, sof pending)
  output logic                  fe_o,            // FE that completes a frame (latch the frame sum)
  output logic                  in_frame_o,
  output logic [15:0]           frame_lines_o,   // held from one complete frame to the next
  output logic [15:0]           frame_num_o,
  output logic [15:0]           line_wc_o,       // held from one accepted line to the next
  output logic [5:0]            line_dt_o,
  output logic [1:0]            line_vc_o,

  output logic                  log_we_o,        // LOG entry
  output logic [29:0]           log_entry_o,
  output logic                  log_fs_o,        //   is an FS of the selected VC
  output logic                  log_fe_o,        //   is an FE of the selected VC

  output csi2_pkt_ev_t          ev_o
);

  // =========================================================================
  // Stage 0: header bytes
  // =========================================================================
  logic [2:0]      base, hcnt_q, hcnt_n;
  logic [3:0][7:0] hdr_q, hdr_d;
  logic            hv_q;

  assign base   = sop_i ? 3'd0 : hcnt_q;
  assign hcnt_n = base + nbytes_i;

  always_comb begin
    hdr_d = hdr_q;
    for (int unsigned k = 0; k < Bytes; k++) begin
      if ((3'(k) < nbytes_i) && ((base + 3'(k)) < 3'd4)) hdr_d[2'(base + 3'(k))] = data_i[k];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hcnt_q <= 3'd4;        // no packet
      hdr_q  <= '0;
      hv_q   <= 1'b0;
    end else begin
      hv_q <= 1'b0;
      if (valid_i && (base < 3'd4)) begin
        hdr_q  <= hdr_d;
        hcnt_q <= (hcnt_n >= 3'd4) ? 3'd4 : hcnt_n;
        hv_q   <= (hcnt_n >= 3'd4);
      end
    end
  end

  // =========================================================================
  // P1, P2: ECC
  // =========================================================================
  logic [23:0] d24, mask, hd_q;
  logic [5:0]  syn_q;
  logic        p1_q, p2_q, single;
  logic [1:0]  ecc_st, ecc_q;

  assign d24 = {hdr_q[2], hdr_q[1], hdr_q[0]};

  always_comb begin
    for (int unsigned i = 0; i < 24; i++) begin
      mask[i] = (syn_q == EccCol[i]);
    end
    single = (syn_q != '0) && ((syn_q & (syn_q - 6'd1)) == '0);   // parity bit error
    if (syn_q == '0)                 ecc_st = EccOk;
    else if ((mask != '0) || single) ecc_st = EccCorr;
    else                             ecc_st = EccErr;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      p1_q  <= 1'b0;
      p2_q  <= 1'b0;
      syn_q <= '0;
      hd_q  <= '0;
      ecc_q <= EccOk;
    end else begin
      p1_q <= hv_q;
      p2_q <= p1_q;
      if (hv_q) syn_q <= ecc_parity(d24) ^ hdr_q[3][5:0];   // ECC[7:6] ignored
      if (p1_q) begin
        hd_q  <= d24 ^ mask;      // mask is 0 unless the syndrome is a data column
        ecc_q <= ecc_st;
      end
    end
  end

  // =========================================================================
  // P3: decisions
  // =========================================================================
  logic [7:0]  di;
  logic [15:0] wc;
  logic        ok, vc_hit, short_pkt, is_fs, is_fe, long_pkt, accept, raw10, fmt;

  assign di        = hd_q[7:0];
  assign wc        = hd_q[23:8];
  assign ok        = (ecc_q != EccErr);
  assign vc_hit    = vc_any_i || (di[7:6] == vc_i);
  assign short_pkt = (di[5:4] == 2'b00);
  assign is_fs     = ok && short_pkt && vc_hit && (di[5:0] == DtFs);
  assign is_fe     = ok && short_pkt && vc_hit && (di[5:0] == DtFe);
  assign long_pkt  = ok && !short_pkt;
  assign accept    = long_pkt && vc_hit && (di[5:0] == dt_i) &&
                     ((di[5:0] == DtRaw8) || (di[5:0] == DtRaw10));
  assign raw10     = (di[5:0] == DtRaw10);
  assign fmt       = accept && ((wc == '0) || (raw10 && !mod5_zero(wc)));

  // =========================================================================
  // Stage D: packet body
  // =========================================================================
  typedef enum logic [1:0] {
    Idle,     // no packet, or the packet has ended: bytes are ignored
    Hdr,      // header bytes, waiting for P3
    Body      // payload and CRC bytes of a long packet
  } dstate_e;

  dstate_e                    dst_q;
  logic [2:0]                 dv_q, dsop_q, deob_q;
  logic [2:0][2:0]            dnb_q;
  logic [2:0][Bytes-1:0][7:0] ddat_q;
  logic                       sv, ssop, seob;
  logic [2:0]                 snb, nbody;
  logic [Bytes-1:0][7:0]      sdat;
  logic [16:0]                rem_q;           // body bytes (payload + CRC) still to come
  logic [15:0]                crc_q, crc_n, crc_c;
  logic                       acc_q, fmt_q;    // the long packet is accepted / has a format error
  logic [Bytes-1:0]           pay;             // payload bytes of the word
  logic                       body, last, lpay, hdr4, trunc;

  assign sv   = dv_q[2];
  assign ssop = dsop_q[2];
  assign seob = deob_q[2];
  assign snb  = dnb_q[2];
  assign sdat = ddat_q[2];

  // rem_q >= 1 in Body. Byte 0 of a body word is always a body byte; byte k
  // is a body byte while k < rem_q and a payload byte while k + 2 < rem_q.
  assign body  = (dst_q == Body) && sv && !ssop;
  assign nbody = (rem_q < 17'(snb)) ? rem_q[2:0] : snb;
  assign last  = body && (rem_q <= 17'(snb));
  assign lpay  = last && (rem_q >= 17'd3);
  assign hdr4  = ssop && (snb == 3'd4);
  assign trunc = (seob || ssop) && (dst_q != Idle);

  for (genvar k = 0; k < Bytes; k++) begin : g_pay
    assign pay[k] = body && (k < 32'(snb)) && (rem_q >= 17'(k + 3));
  end

  // crc_c: CRC after bytes 0..k (a flat XOR function of crc_q and the
  // bytes for every k), crc_n: the one after the body bytes of the word
  always_comb begin
    crc_c = crc_q;
    crc_n = crc_q;
    for (int unsigned k = 0; k < Bytes; k++) begin
      crc_c = crc16_byte(crc_c, sdat[k]);
      if ((k == 0) || (nbody == 3'(k + 1))) crc_n = crc_c;
    end
  end

  // Bytes after a complete packet, until eob (the stage D stream): the
  // words of an ended packet, and the bytes after the CRC in its last word
  logic       ended_q, xev_q;
  logic [8:0] xcnt_q, xcnt_n, xlast;
  logic [2:0] xtail;                    // bytes of the word after the body (last word)

  assign xtail  = snb - nbody;
  assign xcnt_n = xcnt_q + ((sv && !ssop && (dst_q == Idle) && ended_q) ? 9'(snb) : 9'd0);
  assign xlast  = last ? {6'd0, xtail} : 9'd0;

  // =========================================================================
  // Frame state, events, LOG entries
  // =========================================================================
  logic        in_frame_q, synced_q;    // synced: an FS was seen since the RX start
  logic [15:0] lines_q, fnum_q;
  logic        done_q;                  // cycle after the last body byte: CRC result in crc_q
  logic        eol_dly_q;               // the line ends after a last word with payload bytes
  logic        err_dly_q;               //   with px_err_o
  logic [2:0]  lend_q;                  // a long packet ended (delay for px_ovf_i)
  logic        crc_err_q, trunc_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dv_q          <= '0;
      dsop_q        <= '0;
      deob_q        <= '0;
      dnb_q         <= '0;
      ddat_q        <= '0;
      dst_q         <= Idle;
      rem_q         <= '0;
      crc_q         <= 16'hFFFF;
      acc_q         <= 1'b0;
      fmt_q         <= 1'b0;
      ended_q       <= 1'b0;
      xev_q         <= 1'b0;
      xcnt_q        <= '0;
      px_err_o      <= 1'b0;
      px_raw10_o    <= 1'b0;
      px_sol_o      <= 1'b0;
      px_valid_o    <= '0;
      px_data_o     <= '0;
      px_eol_o      <= 1'b0;
      fs_o          <= 1'b0;
      fe_o          <= 1'b0;
      in_frame_q    <= 1'b0;
      synced_q      <= 1'b0;
      lines_q       <= '0;
      fnum_q        <= '0;
      frame_lines_o <= '0;
      frame_num_o   <= '0;
      line_wc_o     <= '0;
      line_dt_o     <= '0;
      line_vc_o     <= '0;
      done_q        <= 1'b0;
      eol_dly_q     <= 1'b0;
      err_dly_q     <= 1'b0;
      lend_q        <= '0;
      crc_err_q     <= 1'b0;
      trunc_q       <= 1'b0;
      log_we_o      <= 1'b0;
      log_entry_o   <= '0;
      log_fs_o      <= 1'b0;
      log_fe_o      <= 1'b0;
      ev_o          <= '0;
    end else begin
      ev_o       <= '0;
      px_sol_o   <= 1'b0;
      px_valid_o <= '0;
      px_eol_o   <= 1'b0;
      px_err_o   <= 1'b0;
      fs_o       <= 1'b0;
      fe_o       <= 1'b0;
      log_we_o   <= 1'b0;
      done_q     <= 1'b0;
      eol_dly_q  <= 1'b0;
      lend_q     <= {lend_q[1:0], 1'b0};

      dv_q   <= {dv_q[1:0], valid_i};
      dsop_q <= {dsop_q[1:0], sop_i};
      deob_q <= {deob_q[1:0], eob_i};
      dnb_q  <= {dnb_q[1:0], nbytes_i};
      ddat_q <= {ddat_q[1:0], data_i};

      // ---- P3 (always while stage D holds the header of the same packet)
      if (p2_q) begin
        ev_o.pkt      <= ok;
        ev_o.ecc_corr <= (ecc_q == EccCorr);
        ev_o.ecc_err  <= (ecc_q == EccErr);
        ev_o.drop     <= long_pkt && !accept;
        ev_o.fmt      <= fmt;
        if (is_fs) begin
          ev_o.fs        <= 1'b1;
          ev_o.frame_err <= in_frame_q;
          in_frame_q     <= 1'b1;
          synced_q       <= 1'b1;
          lines_q        <= '0;
          fnum_q         <= wc;
          fs_o           <= 1'b1;
        end
        if (is_fe) begin
          if (in_frame_q) begin
            ev_o.fe       <= 1'b1;
            frame_lines_o <= lines_q;
            frame_num_o   <= fnum_q;
            fe_o          <= 1'b1;
          end else if (synced_q) begin
            ev_o.frame_err <= 1'b1;
          end
          in_frame_q <= 1'b0;
        end
        if (!long_pkt) begin
          // short packet or uncorrectable header: the packet ends here
          ended_q     <= ok;
          log_we_o    <= 1'b1;
          log_entry_o <= {4'b0000, ecc_q, wc, di};
          log_fs_o    <= is_fs;
          log_fe_o    <= is_fe;
        end
        if (dst_q == Hdr) begin
          dst_q      <= long_pkt ? Body : Idle;
          rem_q      <= {1'b0, wc} + 17'd2;
          acc_q      <= accept;
          fmt_q      <= fmt;
          px_raw10_o <= raw10;
          px_sol_o   <= accept;
        end
      end

      // ---- stage D
      if (body) begin
        rem_q      <= rem_q - 17'(nbody);
        crc_q      <= crc_n;
        px_valid_o <= pay & {Bytes{acc_q}};
        px_data_o  <= sdat;
      end
      // crc_n of the last word covers the received CRC: 0 when it matches
      if (last) begin
        dst_q   <= Idle;
        done_q  <= 1'b1;
        trunc_q <= 1'b0;
        ended_q <= 1'b1;
        if (lpay) begin
          eol_dly_q <= 1'b1;
          err_dly_q <= acc_q && ((crc_n != '0) || fmt_q);
        end else begin
          px_eol_o  <= acc_q;
          px_err_o  <= acc_q && ((crc_n != '0) || fmt_q);
          lend_q[0] <= 1'b1;
        end
      end
      if (eol_dly_q) begin
        px_eol_o  <= acc_q;
        px_err_o  <= err_dly_q;
        lend_q[0] <= 1'b1;
      end
      if (trunc) begin
        ev_o.trunc <= 1'b1;
        dst_q      <= Idle;
        if (dst_q == Body) begin
          px_eol_o  <= acc_q;
          px_err_o  <= acc_q;
          lend_q[0] <= 1'b1;
          trunc_q   <= 1'b1;
          crc_err_q <= 1'b0;
        end
      end
      if (ssop) begin
        dst_q <= Hdr;
        crc_q <= 16'hFFFF;
        // 4 bytes per word: P3 of this header is in this cycle
        if (hdr4 && p2_q) begin
          dst_q      <= long_pkt ? Body : Idle;
          rem_q      <= {1'b0, wc} + 17'd2;
          acc_q      <= accept;
          fmt_q      <= fmt;
          px_raw10_o <= raw10;
          px_sol_o   <= accept;
        end
      end

      // ---- bytes after a complete packet (several packets in one burst),
      // saturating at 256. A sop (new burst) or eob restarts the count; with
      // 4 bytes per word the P3 of a short packet comes with its sop word.
      xcnt_q <= (xcnt_n[8] ? 9'h100 : xcnt_n) + xlast;
      if ((extra_i != '0) && !xev_q && (xcnt_q > {1'b0, extra_i})) begin
        ev_o.extra <= 1'b1;
        xev_q      <= 1'b1;
      end
      if (seob || ssop) begin
        ended_q <= hdr4 && p2_q && !long_pkt && ok;
        xev_q   <= 1'b0;
        xcnt_q  <= '0;
      end

      // ---- complete long packet: CRC result
      if (done_q) begin
        ev_o.crc_err <= (crc_q != '0);
        crc_err_q    <= (crc_q != '0);
        if (acc_q) begin
          ev_o.line <= 1'b1;
          if (lines_q != '1) lines_q <= lines_q + 16'd1;
          line_wc_o <= wc;
          line_dt_o <= di[5:0];
          line_vc_o <= di[7:6];
        end
      end

      // ---- LOG entry of a long packet (complete or truncated)
      if (lend_q[2]) begin
        log_we_o    <= 1'b1;
        log_entry_o <= {acc_q && px_ovf_i, acc_q, trunc_q, crc_err_q, ecc_q, wc, di};
        log_fs_o    <= 1'b0;
        log_fe_o    <= 1'b0;
        ev_o.ovf    <= acc_q && px_ovf_i;
      end
    end
  end

  assign in_frame_o = in_frame_q;

  logic unused_hdr;
  assign unused_hdr = ^hdr_q[3][7:6];

endmodule
