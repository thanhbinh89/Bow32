/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * H.264 encoder driver (docs/ip/h264.md).
 *
 * The encoder takes the ISP output (YUV 4:4:4, the ISP CSC must be on) and
 * writes an H.264 / AVC byte stream to its output port (DMA channel 0):
 * constrained baseline, intra only, one IDR NAL unit "00 00 00 01 65 ..."
 * per frame, padded with zero bytes to a multiple of 4. The sequence and
 * picture parameter sets come from software: bow_h264_write_headers() puts
 * them in front of the frames.
 *
 *   bow_h264_init(1280, 720, 28, true);       // size, QP, deblocking filter
 *   n = bow_h264_write_headers(buf, sizeof buf, &params);
 *   ... DMA channel 0: stream -> buf + n ...
 *   bow_h264_start(60, 0);                     // 60 frames, no frame skipped
 *   while (!(H264->STATUS & H264_ST_DONE)) { ... }
 */
#ifndef BOW_H264_H_
#define BOW_H264_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t ID;           /* 0x000 R   0x48323601 */
  volatile uint32_t CTRL;         /* 0x004 RW  H264_CTRL_* */
  volatile uint32_t CMD;          /* 0x008 W   H264_CMD_* */
  volatile uint32_t STATUS;       /* 0x00C R/W1C H264_ST_* */
  volatile uint32_t IRQ_EN;       /* 0x010 RW  STATUS bits 1..4 */
  volatile uint32_t SIZE;         /* 0x014 RW  [27:16] height (even) [11:0] width (multiple of 16) */
  volatile uint32_t QP;           /* 0x018 RW  10..51, from the next coded frame */
  volatile uint32_t FRAMES;       /* 0x01C RW  frames to code after START, 0 = until STOP */
  volatile uint32_t SKIP;         /* 0x020 RW  input frames dropped after each coded frame */
  volatile uint32_t FRAME_CNT;    /* 0x024 R   frames coded since START */
  volatile uint32_t FRAME_BYTES;  /* 0x028 R   size of the last coded frame (bytes) */
  volatile uint32_t FRAME_CYCLES; /* 0x02C R   video clock cycles: its start of frame -> its end */
  volatile uint32_t MB_CYCLES;    /* 0x030 R   cycles the macroblock engine worked since START */
  volatile uint32_t INFO;         /* 0x034 R   [19:16] strips [15:0] max width */
  volatile uint32_t TOTAL_BYTES;  /* 0x038 R   bytes since START */
} bow_h264_regs_t;

#define H264 ((bow_h264_regs_t *)BOW32_H264_BASE)

#define H264_ID_VALUE 0x48323601u

#define H264_CTRL_EN      (1u << 0)
#define H264_CTRL_DEBLOCK (1u << 1) /* slice headers enable the deblocking filter */

#define H264_CMD_START (1u << 0)
#define H264_CMD_STOP  (1u << 1)    /* no new frame after the current one */

#define H264_ST_BUSY       (1u << 0)
#define H264_ST_FRAME_DONE (1u << 1)
#define H264_ST_DONE       (1u << 2) /* FRAMES frames coded */
#define H264_ST_ERR_OVF    (1u << 3) /* pixels dropped: the encoder was slower than the input */
#define H264_ST_ERR_INPUT  (1u << 4) /* input frame or line shorter than SIZE */
#define H264_ST_ARMED      (1u << 5)

#define H264_QP_MIN 10u
#define H264_QP_MAX 51u

/* Stream parameters of the SPS. */
typedef struct {
  uint32_t width, height;     /* coded size: width multiple of 16, height even */
  uint32_t fps_num, fps_den;  /* frame rate fps_num / fps_den of the coded frames */
  bool full_range;            /* YUV 0..255 (ISP default CSC) or 16..235 (video) */
  uint32_t level;             /* level_idc, 0 = smallest level >= 4.1 that fits */
} bow_h264_params_t;

/* Disable, set the frame size, QP and the deblocking flag, enable. */
void bow_h264_init(uint32_t width, uint32_t height, uint32_t qp, bool deblock);
/* Code `frames` frames (0 = until bow_h264_stop()) from the next start of
 * frame on, dropping `skip` input frames after each coded one. */
void bow_h264_start(uint32_t frames, uint32_t skip);
void bow_h264_stop(void);
static inline void bow_h264_set_qp(uint32_t qp) { H264->QP = qp; }

/* level_idc for a frame size and rate (>= 4.1: intra only streams have a
 * high bit rate). */
uint32_t bow_h264_level(uint32_t width, uint32_t height, uint32_t fps);

/* Annex B SPS + PPS (each NAL unit padded to 4 bytes), the same bytes as
 * sps_nal() + pps_nal() of tools/h264/h264_model.py. Returns the number of
 * bytes written (multiple of 4), 0 if `size` is too small. */
uint32_t bow_h264_write_headers(uint8_t *buf, uint32_t size, const bow_h264_params_t *p);

#endif /* BOW_H264_H_ */
