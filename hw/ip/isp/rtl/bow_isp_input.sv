// Copyright Bow32 contributors.
// SPDX-License-Identifier: Apache-2.0
//
// ISP input stage: AXI4-Stream video (RAW10, 1 pixel/clock) -> internal
// pixel stream with guaranteed geometry.
//
// Downstream stages count pixels themselves, so every frame they see must be
// exactly width x height pixels. This stage enforces it:
//   * a frame starts with a pixel that has tuser (SOF); pixels before are dropped;
//   * tlast must come with pixel width-1 of every line, the frame ends after
//     height lines; pixels after that are dropped until the next SOF;
//   * any mismatch (early/late tlast, SOF inside a frame) aborts the frame:
//     abort_o resets the downstream stages and err_o reports the error.
// The geometry of the incoming stream is measured independently of the
// configuration (meas_width_o / meas_height_o, updated at every SOF), which
// tells the user what the camera really sends.
//
// s_tready_o is low while the pipeline cannot take a pixel (ready_i) or
// while hold_i is set (configuration update between two frames).

module bow_isp_input import bow_isp_pkg::*; (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              enable_i,
  input  logic [CoordW-1:0] width_i,
  input  logic [CoordW-1:0] height_i,
  input  logic              hold_i,
  input  logic              ready_i,     // downstream can accept a pixel

  input  logic              s_tvalid_i,
  output logic              s_tready_o,
  input  logic [PixW-1:0]   s_tdata_i,
  input  logic              s_tuser_i,
  input  logic              s_tlast_i,

  output logic              valid_o,
  output logic [PixW-1:0]   data_o,
  output logic              sof_o,
  output logic              abort_o,     // one cycle, resets the frame state downstream
  output logic              err_o,       // one cycle, geometry error
  output logic              active_o,    // inside a frame
  output logic [CoordW-1:0] meas_width_o,
  output logic [CoordW-1:0] meas_height_o
);

  logic              active_q;
  logic [CoordW-1:0] x_q, y_q;
  logic              xfer;
  logic              mid_sof;

  // A SOF inside a frame is not accepted in the cycle it shows up: the frame
  // is aborted first and the pixel is taken in the next cycle as a new frame.
  assign mid_sof    = active_q && s_tvalid_i && s_tuser_i;
  assign s_tready_o = !enable_i || (ready_i && !hold_i && !mid_sof);
  assign xfer       = enable_i && s_tvalid_i && s_tready_o;
  assign active_o   = active_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q <= 1'b0;
      x_q      <= '0;
      y_q      <= '0;
      valid_o  <= 1'b0;
      data_o   <= '0;
      sof_o    <= 1'b0;
      abort_o  <= 1'b0;
      err_o    <= 1'b0;
    end else begin
      valid_o <= 1'b0;
      sof_o   <= 1'b0;
      abort_o <= 1'b0;
      err_o   <= 1'b0;

      if (!enable_i) begin
        if (active_q) abort_o <= 1'b1;
        active_q <= 1'b0;
      end else if (mid_sof) begin
        active_q <= 1'b0;
        abort_o  <= 1'b1;
        err_o    <= 1'b1;
      end else if (xfer) begin
        if (!active_q) begin
          // Waiting for a start of frame
          // (width >= 2 is required, so the first pixel never ends a line)
          if (s_tuser_i && s_tlast_i) begin
            err_o <= 1'b1;
          end else if (s_tuser_i) begin
            active_q <= 1'b1;
            valid_o  <= 1'b1;
            sof_o    <= 1'b1;
            data_o   <= s_tdata_i;
            x_q      <= CoordW'(1);
            y_q      <= '0;
          end
        end else begin
          valid_o <= 1'b1;
          data_o  <= s_tdata_i;
          if (x_q == width_i - CoordW'(1)) begin
            if (!s_tlast_i) begin
              // line longer than configured
              active_q <= 1'b0;
              valid_o  <= 1'b0;
              abort_o  <= 1'b1;
              err_o    <= 1'b1;
            end else if (y_q == height_i - CoordW'(1)) begin
              active_q <= 1'b0;   // frame complete
            end else begin
              x_q <= '0;
              y_q <= y_q + CoordW'(1);
            end
          end else if (s_tlast_i) begin
            // line shorter than configured
            active_q <= 1'b0;
            valid_o  <= 1'b0;
            abort_o  <= 1'b1;
            err_o    <= 1'b1;
          end else begin
            x_q <= x_q + CoordW'(1);
          end
        end
      end
    end
  end

  // ------------------------------------------------------------------ measure
  // Width = pixels up to the first tlast of a frame, height = lines between
  // two start of frames (counted on every transferred pixel, also aborted
  // or dropped ones).
  logic [CoordW-1:0] mx_q, my_q;
  logic              first_line_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mx_q          <= '0;
      my_q          <= '0;
      first_line_q  <= 1'b0;
      meas_width_o  <= '0;
      meas_height_o <= '0;
    end else if (s_tvalid_i && s_tready_o) begin
      if (s_tuser_i) begin
        meas_height_o <= my_q;
        my_q          <= s_tlast_i ? CoordW'(1) : '0;
        mx_q          <= CoordW'(1);
        first_line_q  <= !s_tlast_i;
        if (s_tlast_i) meas_width_o <= CoordW'(1);
      end else begin
        if (mx_q != '1) mx_q <= mx_q + CoordW'(1);
        if (s_tlast_i) begin
          if (first_line_q) meas_width_o <= mx_q + CoordW'(1);
          first_line_q <= 1'b0;
          if (my_q != '1) my_q <= my_q + CoordW'(1);
        end
      end
    end
  end

endmodule
