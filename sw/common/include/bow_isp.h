/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * ISP (image signal processor) driver (docs/ip/isp.md).
 *
 * Pipeline: input -> BLC -> DPC -> WB -> demosaic -> [stats] -> CCM -> gamma
 * -> CSC -> AXI4-Stream output + capture buffer (BOW32_ISP_BUF_BASE).
 *
 * The "shadowed" registers (SIZE .. CSC_OFF) are a staging copy: change them,
 * then call bow_isp_update(), which makes the hardware copy them between two
 * frames. Capture and gamma registers take effect immediately.
 */
#ifndef BOW_ISP_H_
#define BOW_ISP_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t ID;          /* 0x000 R   0x49535001 */
  volatile uint32_t CTRL;        /* 0x004 RW  [0] EN [1] SRC_TPG */
  volatile uint32_t UPDATE;      /* 0x008 W   [0] apply staging registers between frames */
  volatile uint32_t STATUS;      /* 0x00C R/W1C, ISP_ST_* */
  volatile uint32_t IRQ_EN;      /* 0x010 RW  same bits as STATUS */
  volatile uint32_t FRAME_CNT;   /* 0x014 R   frames processed */
  volatile uint32_t IN_SIZE;     /* 0x018 R   measured input [27:16] height [11:0] width */
  volatile uint32_t INFO;        /* 0x01C R   [31:16] buffer KiWords [15:0] max width */
  /* shadowed configuration */
  volatile uint32_t SIZE;        /* 0x020 RW  [27:16] height [11:0] width */
  volatile uint32_t MODULES;     /* 0x024 RW  ISP_MOD_* */
  volatile uint32_t BAYER;       /* 0x028 RW  colour of pixel (0,0): ISP_BAYER_* */
  volatile uint32_t BLC;         /* 0x02C RW  black level (10 bit) */
  volatile uint32_t DPC_TH;      /* 0x030 RW  defect threshold (10 bit) */
  volatile uint32_t WB[4];       /* 0x034 RW  gains u4.8 for R, Gr, Gb, B */
  volatile uint32_t STAT_X;      /* 0x044 RW  [27:16] x1 [11:0] x0 (inclusive) */
  volatile uint32_t STAT_Y;      /* 0x048 RW  [27:16] y1 [11:0] y0 */
  volatile uint32_t STAT_SAT;    /* 0x04C RW  pixels >= SAT are left out of the RGB sums */
  volatile uint32_t TPG_CTRL;    /* 0x050 RW  [1:0] pattern [4] motion */
  volatile uint32_t TPG_BLANK;   /* 0x054 RW  [31:16] vblank lines [15:0] hblank cycles */
  volatile uint32_t TPG_COLOR;   /* 0x058 RW  [29:20] B [19:10] G [9:0] R */
  uint32_t reserved0;            /* 0x05C */
  volatile uint32_t CCM[9];      /* 0x060 RW  s3.8, row major */
  volatile uint32_t CCM_OFF[3];  /* 0x084 RW  signed 11 bit, 10 bit units */
  uint32_t reserved1[4];         /* 0x090 */
  volatile uint32_t CSC[9];      /* 0x0A0 RW  s3.8, row major */
  volatile uint32_t CSC_OFF[3];  /* 0x0C4 RW  signed 9 bit, 8 bit units */
  uint32_t reserved2[4];         /* 0x0D0 */
  /* gamma tables and capture (not shadowed) */
  volatile uint32_t GAMMA_ADDR;  /* 0x0E0 RW  [9:0] index [18:16] table mask (R, G, B) */
  volatile uint32_t GAMMA_DATA;  /* 0x0E4 W   8 bit entry, index auto increments */
  uint32_t reserved3[2];         /* 0x0E8 */
  volatile uint32_t CAP_CTRL;    /* 0x0F0 W   [0] START: capture the next full frame */
  volatile uint32_t CAP_ORIGIN;  /* 0x0F4 RW  [27:16] y0 [11:0] x0 (input pixels) */
  volatile uint32_t CAP_SIZE;    /* 0x0F8 RW  [27:16] height [11:0] width (output pixels) */
  volatile uint32_t CAP_SCALE;   /* 0x0FC RW  box filter 1 << SCALE (0..3) */
  /* statistics of the last frame (linear RGB after demosaic) */
  volatile uint32_t ST_SUM_R;    /* 0x100 */
  volatile uint32_t ST_SUM_G;    /* 0x104 */
  volatile uint32_t ST_SUM_B;    /* 0x108 */
  volatile uint32_t ST_CNT;      /* 0x10C pixels in the RGB sums */
  volatile uint32_t ST_SUM_Y;    /* 0x110 luma sum, all pixels of the window */
  volatile uint32_t ST_AF;       /* 0x114 sum |G(x) - G(x-1)| (sharpness) */
  volatile uint32_t ST_DPC;      /* 0x118 corrected defect pixels */
  volatile uint32_t ST_FRAME;    /* 0x11C frame number of these statistics */
  uint32_t reserved4[56];        /* 0x120 */
  volatile uint32_t HIST[64];    /* 0x200 luma histogram, bin = Y >> 4 */
} bow_isp_regs_t;

_Static_assert(__builtin_offsetof(bow_isp_regs_t, CCM) == 0x060, "ISP CCM offset");
_Static_assert(__builtin_offsetof(bow_isp_regs_t, CSC) == 0x0A0, "ISP CSC offset");
_Static_assert(__builtin_offsetof(bow_isp_regs_t, GAMMA_ADDR) == 0x0E0, "ISP GAMMA offset");
_Static_assert(__builtin_offsetof(bow_isp_regs_t, CAP_CTRL) == 0x0F0, "ISP CAP offset");
_Static_assert(__builtin_offsetof(bow_isp_regs_t, ST_SUM_R) == 0x100, "ISP ST offset");
_Static_assert(__builtin_offsetof(bow_isp_regs_t, HIST) == 0x200, "ISP HIST offset");

#define ISP ((bow_isp_regs_t *)BOW32_ISP_BASE)
#define ISP_BUF ((const volatile uint32_t *)BOW32_ISP_BUF_BASE)

#define ISP_ID_VALUE 0x49535001u

#define ISP_CTRL_EN      (1u << 0)
#define ISP_CTRL_SRC_TPG (1u << 1)

#define ISP_ST_UPD_PENDING (1u << 0)
#define ISP_ST_FRAME_DONE  (1u << 1)
#define ISP_ST_CAP_DONE    (1u << 2)
#define ISP_ST_CAP_BUSY    (1u << 3)
#define ISP_ST_ERR_INPUT   (1u << 4) /* frame size does not match SIZE: frame dropped */
#define ISP_ST_ERR_FIFO    (1u << 5)
#define ISP_ST_ERR_OUTPUT  (1u << 6) /* output stream not ready */
#define ISP_ST_ERR_CAP     (1u << 7) /* capture region larger than the buffer */
#define ISP_ST_ERRORS      0xF0u

#define ISP_MOD_BLC   (1u << 0)
#define ISP_MOD_DPC   (1u << 1)
#define ISP_MOD_WB    (1u << 2)
#define ISP_MOD_CCM   (1u << 3)
#define ISP_MOD_GAMMA (1u << 4)
#define ISP_MOD_CSC   (1u << 5) /* RGB -> YCbCr: output is YUV 4:4:4 */
#define ISP_MOD_ALL   0x3Fu

#define ISP_BAYER_RGGB 0u
#define ISP_BAYER_GRBG 1u
#define ISP_BAYER_GBRG 2u
#define ISP_BAYER_BGGR 3u

#define ISP_TPG_BARS    0u
#define ISP_TPG_RAMP    1u
#define ISP_TPG_CHECKER 2u
#define ISP_TPG_SOLID   3u

#define ISP_WB_R  0
#define ISP_WB_GR 1
#define ISP_WB_GB 2
#define ISP_WB_B  3

#define ISP_XY(x, y) ((((uint32_t)(y) & 0xFFFu) << 16) | ((uint32_t)(x) & 0xFFFu))

typedef struct {
  uint32_t frame;
  uint32_t sum_r, sum_g, sum_b, cnt; /* unsaturated pixels only */
  uint32_t sum_y, npix;              /* npix = pixels of the statistics window */
  uint32_t af, dpc;
} bow_isp_stats_t;

/* Reset the ISP to a known configuration for a width x height RAW10 sensor:
 * all modules on, identity CCM, sRGB-like gamma, RGB output, statistics on
 * the whole frame. Leaves the ISP disabled. */
void bow_isp_init(uint32_t width, uint32_t height, uint32_t bayer);

/* Apply the staging registers (waits until the hardware took them, at most
 * timeout_ms; returns false on timeout, e.g. no video clock). */
bool bow_isp_update(uint32_t timeout_ms);

void bow_isp_set_ccm(const int16_t m[9], const int16_t off[3]);
/* Colour space conversion: false = RGB output, true = BT.709 full range YCbCr. */
void bow_isp_set_yuv(bool yuv);
/* Gamma: 1.0 = identity (in >> 2), otherwise the sRGB curve. */
void bow_isp_set_gamma_srgb(bool srgb);

/* Wait for the next FRAME_DONE (clears it first); false on timeout. */
bool bow_isp_wait_frame(uint32_t timeout_ms);
/* Consistent copy of the statistics registers. */
void bow_isp_read_stats(bow_isp_stats_t *s);

/* Capture the next full frame: region (x0, y0) of (w << scale) x (h << scale)
 * input pixels into w x h buffer words. Returns false on timeout or error. */
bool bow_isp_capture(uint32_t x0, uint32_t y0, uint32_t w, uint32_t h, uint32_t scale,
                     uint32_t timeout_ms);

#endif /* BOW_ISP_H_ */
