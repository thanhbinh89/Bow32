/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * H.264 encoder driver: control, SPS / PPS writer.
 */
#include "bow_h264.h"

void bow_h264_init(uint32_t width, uint32_t height, uint32_t qp, bool deblock) {
  H264->CTRL = 0;
  H264->STATUS = 0xFFu; /* clear the W1C flags */
  H264->SIZE = (height << 16) | width;
  H264->QP = qp;
  H264->CTRL = H264_CTRL_EN | (deblock ? H264_CTRL_DEBLOCK : 0u);
  (void)H264->CTRL; /* EN reaches the video domain before a START */
}

void bow_h264_start(uint32_t frames, uint32_t skip) {
  H264->FRAMES = frames;
  H264->SKIP = skip;
  H264->STATUS = H264_ST_FRAME_DONE | H264_ST_DONE | H264_ST_ERR_OVF | H264_ST_ERR_INPUT;
  H264->CMD = H264_CMD_START;
}

void bow_h264_stop(void) { H264->CMD = H264_CMD_STOP; }

uint32_t bow_h264_level(uint32_t width, uint32_t height, uint32_t fps) {
  static const uint32_t levels[4][3] = {
      {41, 8192, 245760}, {42, 8704, 522240}, {50, 22080, 589824}, {51, 36864, 983040}};
  uint32_t mbs = (width / 16u) * ((height + 15u) / 16u);
  for (unsigned i = 0; i < 4; i++) {
    if (mbs <= levels[i][1] && mbs * fps <= levels[i][2]) return levels[i][0];
  }
  return 52;
}

/* ------------------------------------------------------------ bit writer */
typedef struct {
  uint8_t buf[64];
  uint32_t len;  /* complete bytes */
  uint32_t acc;
  uint32_t bits; /* bits in acc (< 8 after every call) */
} rbsp_t;

static void put_bits(rbsp_t *w, uint32_t n, uint32_t v) {
  while (n) {
    uint32_t take = n > 8u ? 8u : n;
    n -= take;
    w->acc = (w->acc << take) | ((v >> n) & ((1u << take) - 1u));
    w->bits += take;
    if (w->bits >= 8u) {
      w->bits -= 8u;
      if (w->len < sizeof w->buf) w->buf[w->len++] = (uint8_t)(w->acc >> w->bits);
      w->acc &= (1u << w->bits) - 1u;
    }
  }
}

static void put_ue(rbsp_t *w, uint32_t v) {
  uint32_t x = v + 1u, m = 0;
  while ((x >> m) > 1u) m++;
  put_bits(w, 2u * m + 1u, x);
}

static void put_se(rbsp_t *w, int32_t v) { put_ue(w, v > 0 ? (uint32_t)(2 * v - 1) : (uint32_t)(-2 * v)); }

static void put_trailing(rbsp_t *w) {
  put_bits(w, 1, 1);
  if (w->bits) put_bits(w, 8u - w->bits, 0);
}

/* Start code, header byte, payload with emulation prevention, zero bytes up
 * to a multiple of 4. Returns the bytes written or 0. */
static uint32_t put_nal(uint8_t *out, uint32_t size, uint8_t header, const rbsp_t *w) {
  uint32_t n = 0, zeros = 0;
  if (size < 5u) return 0;
  out[n++] = 0;
  out[n++] = 0;
  out[n++] = 0;
  out[n++] = 1;
  out[n++] = header;
  for (uint32_t i = 0; i < w->len; i++) {
    uint8_t b = w->buf[i];
    if (zeros == 2u && b <= 3u) {
      if (n >= size) return 0;
      out[n++] = 3;
      zeros = 0;
    }
    if (n >= size) return 0;
    out[n++] = b;
    zeros = b ? 0u : zeros + 1u;
  }
  while (n & 3u) {
    if (n >= size) return 0;
    out[n++] = 0;
  }
  return n;
}

uint32_t bow_h264_write_headers(uint8_t *buf, uint32_t size, const bow_h264_params_t *p) {
  uint32_t mbw = p->width / 16u, mbh = (p->height + 15u) / 16u;
  uint32_t fps = (p->fps_num + p->fps_den - 1u) / p->fps_den;
  uint32_t crop = mbh * 16u - p->height;
  rbsp_t w = {0};

  /* SPS: constrained baseline, VUI with BT.709 colour and the frame rate */
  put_bits(&w, 8, 66);                                /* profile_idc */
  put_bits(&w, 8, 0xC0);                              /* constraint_set0/1_flag */
  put_bits(&w, 8, p->level ? p->level : bow_h264_level(p->width, p->height, fps));
  put_ue(&w, 0);                                      /* seq_parameter_set_id */
  put_ue(&w, 0);                                      /* log2_max_frame_num_minus4 */
  put_ue(&w, 2);                                      /* pic_order_cnt_type */
  put_ue(&w, 1);                                      /* max_num_ref_frames */
  put_bits(&w, 1, 0);                                 /* gaps_in_frame_num_allowed */
  put_ue(&w, mbw - 1u);
  put_ue(&w, mbh - 1u);
  put_bits(&w, 1, 1);                                 /* frame_mbs_only_flag */
  put_bits(&w, 1, 1);                                 /* direct_8x8_inference_flag */
  put_bits(&w, 1, crop ? 1u : 0u);                    /* frame_cropping_flag */
  if (crop) {
    put_ue(&w, 0);
    put_ue(&w, 0);
    put_ue(&w, 0);
    put_ue(&w, crop / 2u);                            /* bottom, in units of 2 lines */
  }
  put_bits(&w, 1, 1);                                 /* vui_parameters_present_flag */
  put_bits(&w, 1, 0);                                 /* aspect_ratio_info_present */
  put_bits(&w, 1, 0);                                 /* overscan_info_present */
  put_bits(&w, 1, 1);                                 /* video_signal_type_present */
  put_bits(&w, 3, 5);                                 /* video_format: unspecified */
  put_bits(&w, 1, p->full_range ? 1u : 0u);
  put_bits(&w, 1, 1);                                 /* colour_description_present */
  put_bits(&w, 8, 1);                                 /* colour_primaries BT.709 */
  put_bits(&w, 8, 1);                                 /* transfer_characteristics BT.709 */
  put_bits(&w, 8, 1);                                 /* matrix_coefficients BT.709 */
  put_bits(&w, 1, 1);                                 /* chroma_loc_info_present */
  put_ue(&w, 1);                                      /* chroma sample location: centre */
  put_ue(&w, 1);
  put_bits(&w, 1, 1);                                 /* timing_info_present */
  put_bits(&w, 16, p->fps_den >> 16);                 /* num_units_in_tick (32 bit) */
  put_bits(&w, 16, p->fps_den & 0xFFFFu);
  put_bits(&w, 16, (2u * p->fps_num) >> 16);          /* time_scale */
  put_bits(&w, 16, (2u * p->fps_num) & 0xFFFFu);
  put_bits(&w, 1, 1);                                 /* fixed_frame_rate_flag */
  put_bits(&w, 1, 0);                                 /* nal_hrd_parameters_present */
  put_bits(&w, 1, 0);                                 /* vcl_hrd_parameters_present */
  put_bits(&w, 1, 0);                                 /* pic_struct_present */
  put_bits(&w, 1, 0);                                 /* bitstream_restriction */
  put_trailing(&w);
  uint32_t n = put_nal(buf, size, 0x67, &w);
  if (n == 0) return 0;

  /* PPS: CAVLC, pic_init_qp 26, deblocking control in the slice headers */
  rbsp_t q = {0};
  put_ue(&q, 0);                                      /* pic_parameter_set_id */
  put_ue(&q, 0);                                      /* seq_parameter_set_id */
  put_bits(&q, 1, 0);                                 /* entropy_coding_mode_flag */
  put_bits(&q, 1, 0);                                 /* bottom_field_pic_order */
  put_ue(&q, 0);                                      /* num_slice_groups_minus1 */
  put_ue(&q, 0);                                      /* num_ref_idx_l0_default_minus1 */
  put_ue(&q, 0);                                      /* num_ref_idx_l1_default_minus1 */
  put_bits(&q, 1, 0);                                 /* weighted_pred_flag */
  put_bits(&q, 2, 0);                                 /* weighted_bipred_idc */
  put_se(&q, 0);                                      /* pic_init_qp_minus26 */
  put_se(&q, 0);                                      /* pic_init_qs_minus26 */
  put_se(&q, 0);                                      /* chroma_qp_index_offset */
  put_bits(&q, 1, 1);                                 /* deblocking_filter_control_present */
  put_bits(&q, 1, 0);                                 /* constrained_intra_pred_flag */
  put_bits(&q, 1, 0);                                 /* redundant_pic_cnt_present */
  put_trailing(&q);
  uint32_t m = put_nal(buf + n, size - n, 0x68, &q);
  return m ? n + m : 0;
}
