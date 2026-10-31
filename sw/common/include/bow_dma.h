/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * DMA controller driver (docs/ip/dma.md).
 *
 * Two channels; each copies memory to memory (M2M) or writes the words of
 * its stream input to memory (S2M, linear or ring buffer). In this SoC the
 * stream of channel 0 is the H.264 encoder output, channel 1 has no stream.
 *
 *   bow_dma_stream(0, buf, len, false);    // H.264 stream -> buf
 *   ... DMA->CH[0].PKT_CNT frames, DMA->CH[0].PKT_END bytes ...
 *   bow_dma_copy(1, dst, src, len);  bow_dma_wait(1, 100);
 */
#ifndef BOW_DMA_H_
#define BOW_DMA_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"
#include "bow_time.h"

typedef struct {
  volatile uint32_t CTRL;     /* +0x00 RW  DMA_CTRL_* */
  volatile uint32_t STATUS;   /* +0x04 R/W1C DMA_ST_* */
  volatile uint32_t SRC;      /* +0x08 RW  source (M2M) */
  volatile uint32_t DST;      /* +0x0C RW  destination / buffer */
  volatile uint32_t LEN;      /* +0x10 RW  bytes to copy / buffer size */
  volatile uint32_t WPTR;     /* +0x14 R   write offset (bytes) */
  volatile uint32_t RPTR;     /* +0x18 RW  ring: read offset of the consumer */
  volatile uint32_t PKT_CNT;  /* +0x1C R   stream packets written */
  volatile uint32_t PKT_END;  /* +0x20 R   WPTR after the last packet */
  volatile uint32_t COUNT;    /* +0x24 R   bytes written since the start */
  uint32_t reserved[6];
} bow_dma_ch_t;

typedef struct {
  volatile uint32_t ID;       /* 0x000 R   0x444D4101 */
  volatile uint32_t INFO;     /* 0x004 R   [7:0] channels */
  uint32_t reserved[14];
  bow_dma_ch_t CH[2];         /* 0x040, 0x080 */
} bow_dma_regs_t;

_Static_assert(__builtin_offsetof(bow_dma_regs_t, CH[1]) == 0x080, "DMA channel offset");

#define DMA ((bow_dma_regs_t *)BOW32_DMA_BASE)

#define DMA_ID_VALUE 0x444D4101u

#define DMA_CTRL_EN      (1u << 0)
#define DMA_CTRL_S2M     (1u << 1)  /* stream -> memory (else memory -> memory) */
#define DMA_CTRL_RING    (1u << 2)
#define DMA_CTRL_DROP    (1u << 3)  /* S2M: take the stream words and drop them */
#define DMA_CTRL_IE_DONE (1u << 8)
#define DMA_CTRL_IE_PKT  (1u << 9)
#define DMA_CTRL_IE_ERR  (1u << 10)

#define DMA_ST_BUSY (1u << 0)
#define DMA_ST_DONE (1u << 1)
#define DMA_ST_PKT  (1u << 2)
#define DMA_ST_ERR  (1u << 3)
#define DMA_ST_FULL (1u << 4)

/* Stream of channel `ch` -> buf (len bytes, multiple of 4). */
static inline void bow_dma_stream(unsigned ch, void *buf, uint32_t len, bool ring) {
  bow_dma_ch_t *c = &DMA->CH[ch];
  c->CTRL = 0;
  c->STATUS = DMA_ST_DONE | DMA_ST_PKT | DMA_ST_ERR;
  c->DST = (uint32_t)(uintptr_t)buf;
  c->LEN = len;
  c->RPTR = 0;
  c->CTRL = DMA_CTRL_EN | DMA_CTRL_S2M | (ring ? DMA_CTRL_RING : 0u);
}

/* Memory -> memory copy (word aligned, len multiple of 4), returns at once. */
static inline void bow_dma_copy(unsigned ch, void *dst, const void *src, uint32_t len) {
  bow_dma_ch_t *c = &DMA->CH[ch];
  c->CTRL = 0;
  c->STATUS = DMA_ST_DONE | DMA_ST_PKT | DMA_ST_ERR;
  c->SRC = (uint32_t)(uintptr_t)src;
  c->DST = (uint32_t)(uintptr_t)dst;
  c->LEN = len;
  c->CTRL = DMA_CTRL_EN;
}

static inline void bow_dma_disable(unsigned ch) { DMA->CH[ch].CTRL = 0; }

/* Wait for the end of a copy: true when done without bus error. */
static inline bool bow_dma_wait(unsigned ch, uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = timeout_ms * (bow_clk_hz() / 1000u);
  while (DMA->CH[ch].STATUS & DMA_ST_BUSY) {
    if ((uint32_t)(bow_cycles() - start) > limit) return false;
  }
  return !(DMA->CH[ch].STATUS & DMA_ST_ERR);
}

#endif /* BOW_DMA_H_ */
