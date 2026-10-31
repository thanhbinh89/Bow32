// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// CSI-2 packet layer (byte clock domain): one packet per HS burst.
//
// The first 4 bytes after sop are the packet header {ECC, WC MSB, WC LSB, DI}.
// The header is decoded in a pipeline beside the byte stream:
//   H  header complete (stage 0)
//   P1 ECC syndrome
//   P2 single bit correction, corrected header (or raw, if uncorrectable)
//   P3 decisions: short / long, VC and DT filter, frame state, events,
//      LOG entry of the packets that end with the header
// The stream is delayed by 3 cycles ("stage D") so that the decisions are
// known when the first byte after the header (or the eob) reaches stage D.
//
// * Short packets (DT 0x00..0x0F) of the selected VC (CTRL.VC, or any VC):
//   FS starts a frame (FS inside a frame is a frame error), FE completes it
//   (FE without FS is a frame error, except before the first FS after an RX
//   start). Other short packets are only counted and logged.
// * Long packets: WC payload bytes, then the CRC (LS byte first). Accepted =
//   VC match and DT == CTRL.DT, DT in {RAW8, RAW10}: the payload goes to the
//   unpacker (px_*). All long packets are CRC checked; the others are
//   dropped (ev_drop). The packet ends when header + WC + 2 bytes have been
//   received, never at eob; later bytes are ignored until the next sop.
//   Pixels are forwarded before the CRC is known.
// * Uncorrectable header: the rest of the burst is ignored.
// * eob (or sop) while a packet is open: truncated (ev_trunc; the unpacker
//   ends the line).
// * One LOG entry per packet with a decoded header, written when it ends.
//   For long packets it is written 3 cycles after the end so that the
//   FIFO overflow flag of the unpacker (px_ovf_i) includes the last group:
//   the unpacker pushes the last group at most one cycle after it sees
//   px_eol_o, and px_ovf_i shows the result one cycle after the push.
// Everything here is reset by the datapath reset (RX off).

module bow_csi2_packet import bow_csi2rx_pkg::*; (
  input  logic         clk_i,
  input  logic         rst_ni,          // byte clock, datapath reset

  input  logic [1:0]   vc_i,            // configuration (static while RX is on)
  input  logic         vc_any_i,
  input  logic [5:0]   dt_i,

  input  logic         valid_i,         // from the lane merge
  input  logic [15:0]  data_i,
  input  logic [1:0]   nbytes_i,
  input  logic         sop_i,
  input  logic         eob_i,

  output logic         px_sol_o,        // an accepted line starts (before its first byte)
  output logic         px_raw10_o,      // format of the line, from px_sol_o to px_eol_o
  output logic [1:0]   px_valid_o,      // payload bytes: [0] byte 0, [1] byte 1 (only with [0])
  output logic [15:0]  px_data_o,
  output logic         px_eol_o,        // end of the line (in a cycle without bytes)
  input  logic         px_ovf_i,        // unpacker: a group of the line was dropped

  output logic         fs_o,            // FS of the selected VC (frame sum = 0, sof pending)
  output logic         fe_o,            // FE that completes a frame (latch the frame sum)
  output logic         in_frame_o,
  output logic [15:0]  frame_lines_o,   // held from one complete frame to the next
  output logic [15:0]  frame_num_o,
  output logic [15:0]  line_wc_o,       // held from one accepted line to the next
  output logic [5:0]   line_dt_o,
  output logic [1:0]   line_vc_o,

  output logic         log_we_o,        // LOG entry
  output logic [29:0]  log_entry_o,
  output logic         log_fs_o,        //   is an FS of the selected VC
  output logic         log_fe_o,        //   is an FE of the selected VC

  output csi2_pkt_ev_t ev_o
);

  // =========================================================================
  // Stage 0: header bytes
  // =========================================================================
  logic            two;
  logic [2:0]      base, hcnt_q, hcnt_n;
  logic [1:0]      base1;
  logic [3:0][7:0] hdr_q;
  logic            hv_q;

  assign two    = (nbytes_i == 2'd2);
  assign base   = sop_i ? 3'd0 : hcnt_q;
  assign base1  = base[1:0] + 2'd1;
  assign hcnt_n = base + (two ? 3'd2 : 3'd1);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hcnt_q <= 3'd4;        // no packet
      hdr_q  <= '0;
      hv_q   <= 1'b0;
    end else begin
      hv_q <= 1'b0;
      if (valid_i && (base < 3'd4)) begin
        hdr_q[base[1:0]] <= data_i[7:0];
        if (two && (base < 3'd3)) hdr_q[base1] <= data_i[15:8];
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
  assign fmt       = accept && (raw10 ? !mod5_zero(wc) : (wc == '0));

  // =========================================================================
  // Stage D: packet body
  // =========================================================================
  typedef enum logic [1:0] {
    Idle,     // no packet, or the packet has ended: bytes are ignored
    Hdr,      // header bytes, waiting for P3
    Body      // payload and CRC bytes of a long packet
  } dstate_e;

  dstate_e          dst_q;
  logic [2:0]       dv_q, dsop_q, deob_q, dtwo_q;
  logic [2:0][15:0] ddat_q;
  logic             sv, ssop, seob, stwo;
  logic [15:0]      sdat;
  logic [16:0]      rem_q;           // body bytes (payload + CRC) still to come
  logic [15:0]      crc_q;
  logic             acc_q;           // the long packet is accepted
  logic             body, b1, p0, p1, last, trunc;

  assign sv   = dv_q[2];
  assign ssop = dsop_q[2];
  assign seob = deob_q[2];
  assign stwo = dtwo_q[2];
  assign sdat = ddat_q[2];

  // rem_q >= 1 in Body. Byte 0 of a body word is always a body byte.
  assign body  = (dst_q == Body) && sv && !ssop;
  assign b1    = body && stwo && (rem_q >= 17'd2);
  assign p0    = body && (rem_q >= 17'd3);
  assign p1    = body && stwo && (rem_q >= 17'd4);
  assign last  = body && ((rem_q == 17'd1) || (stwo && (rem_q == 17'd2)));
  assign trunc = (seob || ssop) && (dst_q != Idle);

  // =========================================================================
  // Frame state, events, LOG entries
  // =========================================================================
  logic        in_frame_q, synced_q;    // synced: an FS was seen since the RX start
  logic [15:0] lines_q, fnum_q;
  logic        done_q;                  // cycle after the last body byte: CRC result in crc_q
  logic [2:0]  lend_q;                  // a long packet ended (delay for px_ovf_i)
  logic        crc_err_q, trunc_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dv_q          <= '0;
      dsop_q        <= '0;
      deob_q        <= '0;
      dtwo_q        <= '0;
      ddat_q        <= '0;
      dst_q         <= Idle;
      rem_q         <= '0;
      crc_q         <= 16'hFFFF;
      acc_q         <= 1'b0;
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
      fs_o       <= 1'b0;
      fe_o       <= 1'b0;
      log_we_o   <= 1'b0;
      done_q     <= 1'b0;
      lend_q     <= {lend_q[1:0], 1'b0};

      dv_q   <= {dv_q[1:0], valid_i};
      dsop_q <= {dsop_q[1:0], sop_i};
      deob_q <= {deob_q[1:0], eob_i};
      dtwo_q <= {dtwo_q[1:0], two};
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
          log_we_o    <= 1'b1;
          log_entry_o <= {4'b0000, ecc_q, wc, di};
          log_fs_o    <= is_fs;
          log_fe_o    <= is_fe;
        end
        if (dst_q == Hdr) begin
          dst_q      <= long_pkt ? Body : Idle;
          rem_q      <= {1'b0, wc} + 17'd2;
          acc_q      <= accept;
          px_raw10_o <= raw10;
          px_sol_o   <= accept;
        end
      end

      // ---- stage D
      if (body) begin
        rem_q      <= rem_q - (b1 ? 17'd2 : 17'd1);
        crc_q      <= b1 ? crc16_byte(crc16_byte(crc_q, sdat[7:0]), sdat[15:8])
                         : crc16_byte(crc_q, sdat[7:0]);
        px_valid_o <= {p1, p0} & {2{acc_q}};
        px_data_o  <= sdat;
      end
      if (last) begin
        dst_q     <= Idle;
        done_q    <= 1'b1;
        px_eol_o  <= acc_q;
        lend_q[0] <= 1'b1;
        trunc_q   <= 1'b0;
      end
      if (trunc) begin
        ev_o.trunc <= 1'b1;
        dst_q      <= Idle;
        if (dst_q == Body) begin
          px_eol_o  <= acc_q;
          lend_q[0] <= 1'b1;
          trunc_q   <= 1'b1;
          crc_err_q <= 1'b0;
        end
      end
      if (ssop) begin
        dst_q <= Hdr;
        crc_q <= 16'hFFFF;
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
