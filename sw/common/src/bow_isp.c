/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * ISP driver: configuration helpers, statistics and capture.
 */
#include "bow_isp.h"

#include "bow_time.h"

/* sRGB transfer curve, 65 points over the 10 bit input (x = 16 * i, last
 * point x = 1023), output in 8.4 fixed point. Values between the points are
 * interpolated linearly. Generated with
 *   round(255 * 16 * srgb(min(16 * i, 1023) / 1023)) */
static const uint16_t srgb_pts[65] = {
    0,    537,  792,  979,  1132, 1264, 1382, 1488, 1586, 1677, 1763, 1843, 1919,
    1992, 2062, 2128, 2192, 2254, 2314, 2372, 2428, 2482, 2535, 2587, 2637, 2686,
    2734, 2781, 2827, 2872, 2916, 2959, 3002, 3043, 3084, 3124, 3164, 3203, 3241,
    3279, 3316, 3353, 3389, 3424, 3459, 3494, 3528, 3562, 3595, 3628, 3661, 3693,
    3725, 3756, 3787, 3818, 3849, 3879, 3909, 3938, 3967, 3996, 4025, 4054, 4080,
};

static const int16_t identity[9] = {256, 0, 0, 0, 256, 0, 0, 0, 256};
static const int16_t zero3[3] = {0, 0, 0};

/* BT.709 full range: Y = .2126 R + .7152 G + .0722 B, Cb/Cr centred on 128. */
static const int16_t rgb2yuv709[9] = {54, 183, 19, -29, -99, 128, 128, -116, -12};
static const int16_t yuv_off[3] = {0, 128, 128};

void bow_isp_set_ccm(const int16_t m[9], const int16_t off[3]) {
  for (int i = 0; i < 9; i++) ISP->CCM[i] = (uint32_t)(int32_t)m[i] & 0xFFFu;
  for (int i = 0; i < 3; i++) ISP->CCM_OFF[i] = (uint32_t)(int32_t)off[i] & 0x7FFu;
}

void bow_isp_set_yuv(bool yuv) {
  const int16_t *m = yuv ? rgb2yuv709 : identity;
  const int16_t *off = yuv ? yuv_off : zero3;
  for (int i = 0; i < 9; i++) ISP->CSC[i] = (uint32_t)(int32_t)m[i] & 0xFFFu;
  for (int i = 0; i < 3; i++) ISP->CSC_OFF[i] = (uint32_t)(int32_t)off[i] & 0x1FFu;
  if (yuv) {
    ISP->MODULES |= ISP_MOD_CSC;
  } else {
    ISP->MODULES &= ~ISP_MOD_CSC;
  }
}

void bow_isp_set_gamma_srgb(bool srgb) {
  ISP->GAMMA_ADDR = 7u << 16; /* all three tables, index 0 */
  for (uint32_t x = 0; x < 1024; x++) {
    uint32_t v;
    if (srgb) {
      uint32_t i = x >> 4, f = x & 15u;
      uint32_t a = srgb_pts[i], b = srgb_pts[i + 1];
      if (i == 63) f = f * 16u / 15u; /* last segment ends at 1023 */
      v = (a * 16u + (b - a) * f + 128u) >> 8;
    } else {
      v = x >> 2;
    }
    ISP->GAMMA_DATA = v > 255u ? 255u : v;
  }
}

void bow_isp_init(uint32_t width, uint32_t height, uint32_t bayer) {
  ISP->CTRL = 0;
  ISP->STATUS = 0xFFu; /* clear the W1C flags */
  ISP->SIZE = ISP_XY(width, height);
  ISP->MODULES = ISP_MOD_BLC | ISP_MOD_DPC | ISP_MOD_WB | ISP_MOD_CCM | ISP_MOD_GAMMA;
  ISP->BAYER = bayer;
  ISP->BLC = 64;     /* IMX219 / most RAW10 sensors */
  ISP->DPC_TH = 128;
  for (int i = 0; i < 4; i++) ISP->WB[i] = 256;
  ISP->STAT_X = ISP_XY(0, width - 1);
  ISP->STAT_Y = ISP_XY(0, height - 1);
  ISP->STAT_SAT = 1000;
  bow_isp_set_ccm(identity, zero3);
  bow_isp_set_yuv(false);
  bow_isp_set_gamma_srgb(true);
}

bool bow_isp_update(uint32_t timeout_ms) {
  uint32_t start = bow_cycles();
  uint32_t limit = timeout_ms * (bow_clk_hz() / 1000u);
  ISP->UPDATE = 1;
  while (ISP->STATUS & ISP_ST_UPD_PENDING) {
    if ((uint32_t)(bow_cycles() - start) > limit) return false;
  }
  return true;
}

bool bow_isp_wait_frame(uint32_t timeout_ms) {
  uint32_t start = bow_cycles();
  uint32_t limit = timeout_ms * (bow_clk_hz() / 1000u);
  ISP->STATUS = ISP_ST_FRAME_DONE;
  while (!(ISP->STATUS & ISP_ST_FRAME_DONE)) {
    if ((uint32_t)(bow_cycles() - start) > limit) return false;
  }
  return true;
}

void bow_isp_read_stats(bow_isp_stats_t *s) {
  /* The registers change at the end of every frame: read until the frame
   * number is the same before and after. */
  do {
    s->frame = ISP->ST_FRAME;
    s->sum_r = ISP->ST_SUM_R;
    s->sum_g = ISP->ST_SUM_G;
    s->sum_b = ISP->ST_SUM_B;
    s->cnt = ISP->ST_CNT;
    s->sum_y = ISP->ST_SUM_Y;
    s->af = ISP->ST_AF;
    s->dpc = ISP->ST_DPC;
  } while (s->frame != ISP->ST_FRAME);

  uint32_t size = ISP->SIZE, sx = ISP->STAT_X, sy = ISP->STAT_Y;
  uint32_t w = size & 0xFFFu, h = (size >> 16) & 0xFFFu;
  uint32_t x0 = sx & 0xFFFu, x1 = (sx >> 16) & 0xFFFu;
  uint32_t y0 = sy & 0xFFFu, y1 = (sy >> 16) & 0xFFFu;
  if (x1 > w - 1) x1 = w - 1;
  if (y1 > h - 1) y1 = h - 1;
  s->npix = (x1 >= x0 && y1 >= y0) ? (x1 - x0 + 1) * (y1 - y0 + 1) : 0;
}

bool bow_isp_capture(uint32_t x0, uint32_t y0, uint32_t w, uint32_t h, uint32_t scale,
                     uint32_t timeout_ms) {
  uint32_t start = bow_cycles();
  uint32_t limit = timeout_ms * (bow_clk_hz() / 1000u);
  ISP->CAP_ORIGIN = ISP_XY(x0, y0);
  ISP->CAP_SIZE = ISP_XY(w, h);
  ISP->CAP_SCALE = scale;
  ISP->STATUS = ISP_ST_CAP_DONE | ISP_ST_ERR_CAP;
  ISP->CAP_CTRL = 1;
  while (!(ISP->STATUS & ISP_ST_CAP_DONE)) {
    if ((uint32_t)(bow_cycles() - start) > limit) return false;
  }
  return !(ISP->STATUS & ISP_ST_ERR_CAP);
}
