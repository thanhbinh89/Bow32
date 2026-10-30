/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MIPI CSI-2 receiver driver (Bow32 D-PHY RX + CSI-2 RX, docs/ip/csi2rx.md).
 *
 * The receiver decodes the packets of a CSI-2 camera (1 or 2 data lanes,
 * RAW8 / RAW10) and streams the pixels of one virtual channel and data type
 * into the ISP. The sampling point of every data lane is an IDELAY tap that
 * software finds at run time (bow_csi2rx_calibrate): the capture has no
 * static timing.
 *
 * The hardware takes the configuration without handshake, so:
 *   - change CTRL.LANES / VC / VC_ANY / DT only while CTRL.RX_EN = 0,
 *   - change PHY_CFG and CTRL.CLK_FORCE only while CTRL.PHY_EN = 0,
 *   - start the receiver before the sensor streams (it must see LP-11 first)
 *     and stop it after the sensor has finished its last frame.
 * A tap written to DLYn is applied at the next HS burst (byte clock).
 */
#ifndef BOW_CSI2RX_H_
#define BOW_CSI2RX_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t ID;          /* 0x000 R   0x43533201 */
  volatile uint32_t INFO;        /* 0x004 R   [3:0] lanes [4] PHY [15:8] MHz [31:16] FIFO depth */
  volatile uint32_t CTRL;        /* 0x008 RW  CSI2RX_CTRL_* */
  volatile uint32_t PHY_CFG;     /* 0x00C RW  CSI2RX_PHY_*, video clock cycles */
  volatile uint32_t STATUS;      /* 0x010 R   CSI2RX_ST_* */
  volatile uint32_t IRQ_STATUS;  /* 0x014 R/W1C CSI2RX_IRQ_* */
  volatile uint32_t IRQ_EN;      /* 0x018 RW  same bits */
  volatile uint32_t ERR_STATUS;  /* 0x01C R/W1C CSI2RX_ERR_*, sticky */
  volatile uint32_t CNT_CLR;     /* 0x020 W   [0] clear CNT_* */
  volatile uint32_t CNT_FRAME;   /* 0x024 R   FS of the selected VC */
  volatile uint32_t CNT_PKT;     /* 0x028 R   packets with header ok or corrected */
  volatile uint32_t CNT_LINE;    /* 0x02C R   accepted pixel packets */
  volatile uint32_t CNT_ECC;     /* 0x030 R   [15:0] corrected [31:16] uncorrectable */
  volatile uint32_t CNT_CRC;     /* 0x034 R   [15:0] CRC errors [31:16] truncated */
  volatile uint32_t CNT_SOT;     /* 0x038 R   sync errors [15:0] lane 0 [31:16] lane 1 */
  volatile uint32_t CNT_DROP;    /* 0x03C R   [15:0] VC/DT filter [31:16] FIFO overflow */
  volatile uint32_t CNT_BURST;   /* 0x040 R   HS entries [15:0] lane 0 [31:16] lane 1 */
  volatile uint32_t CNT_MISC;    /* 0x044 R   [15:0] clock lane HS entries [23:16] LP errors
                                  *           [31:24] skew + format + frame errors */
  uint32_t reserved0[2];         /* 0x048 */
  volatile uint32_t FRAME_INFO;  /* 0x050 R   last complete frame: [15:0] lines [31:16] number */
  volatile uint32_t LINE_INFO;   /* 0x054 R   last accepted line: [15:0] WC [21:16] DT [23:22] VC */
  volatile uint32_t FRAME_SUM;   /* 0x058 R   sum of the pixel values of the last frame */
  volatile uint32_t FRAME_TIME;  /* 0x05C R   CPU cycles between the last two FS */
  volatile uint32_t LINE_TIME;   /* 0x060 R   CPU cycles between two line ends of a frame */
  volatile uint32_t BYTECLK;     /* 0x064 R   [19:0] byte clocks per 65536 CPU cycles */
  uint32_t reserved1[2];         /* 0x068 */
  volatile uint32_t DLY[2];      /* 0x070 RW  W [8:0] tap, R [8:0] written [24:16] in use */
  uint32_t reserved2[2];         /* 0x078 */
  volatile uint32_t LOG_CTRL;    /* 0x080 RW  CSI2RX_LOG_* */
  volatile uint32_t RAW_CTRL;    /* 0x084 RW  CSI2RX_RAW_* */
  uint32_t reserved3[222];       /* 0x088 */
  volatile uint32_t LOG[64];     /* 0x400 R   packet log, CSI2RX_LOG_* entry fields */
  uint32_t reserved4[192];       /* 0x500 */
  volatile uint32_t RAW[64];     /* 0x800 R   [7:0] lane 0 word [15:8] lane 1 word */
} bow_csi2rx_regs_t;

_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, CNT_MISC) == 0x044, "CSI2RX CNT offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, FRAME_INFO) == 0x050, "CSI2RX INFO offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, DLY) == 0x070, "CSI2RX DLY offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, LOG_CTRL) == 0x080, "CSI2RX LOG_CTRL offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, LOG) == 0x400, "CSI2RX LOG offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, RAW) == 0x800, "CSI2RX RAW offset");

#define CSI2RX ((bow_csi2rx_regs_t *)BOW32_CSI2RX_BASE)

#define CSI2RX_ID_VALUE 0x43533201u

#define CSI2RX_INFO_LANES(i) ((i) & 0xFu)
#define CSI2RX_INFO_PHY      (1u << 4) /* a D-PHY is connected */
#define CSI2RX_INFO_MHZ(i)   (((i) >> 8) & 0xFFu) /* video (PHY) clock */
#define CSI2RX_INFO_FIFO(i)  ((i) >> 16)

#define CSI2RX_CTRL_PHY_EN    (1u << 0)
#define CSI2RX_CTRL_RX_EN     (1u << 1)
#define CSI2RX_CTRL_LANES2    (1u << 2) /* 0: 1 data lane, 1: 2 data lanes */
#define CSI2RX_CTRL_CLK_FORCE (1u << 3) /* clock lane always HS (continuous clock only) */
#define CSI2RX_CTRL_VC_ANY    (1u << 4)
#define CSI2RX_CTRL_VC(v)     (((uint32_t)(v) & 3u) << 5)
#define CSI2RX_CTRL_VC_MASK   (3u << 5)
#define CSI2RX_CTRL_DT(d)     (((uint32_t)(d) & 0x3Fu) << 8)
#define CSI2RX_CTRL_DT_MASK   (0x3Fu << 8)

#define CSI2RX_PHY_SETTLE(n)     ((uint32_t)(n) & 0xFFu)
#define CSI2RX_PHY_LP_FILTER(n)  (((uint32_t)(n) & 0xFu) << 8)
#define CSI2RX_PHY_CLK_SETTLE(n) (((uint32_t)(n) & 0xFFu) << 16)
#define CSI2RX_PHY_CLK_MISS(n)   (((uint32_t)(n) & 0xFFu) << 24) /* 0: no clock miss detection */

#define CSI2RX_ST_LP_CLK(s)  ((s) & 3u)                        /* filtered LP state {P, N} */
#define CSI2RX_ST_LP(s, l)   (((s) >> (2u + 2u * (l))) & 3u)   /* data lane l */
#define CSI2RX_ST_HS_CLK     (1u << 8)
#define CSI2RX_ST_HS(l)      (1u << (9u + (l)))
#define CSI2RX_ST_CE         (1u << 11) /* byte clock gate open */
#define CSI2RX_ST_IN_FRAME   (1u << 12)
#define CSI2RX_ST_BYTECLK_OK (1u << 13)

#define CSI2RX_IRQ_FS       (1u << 0)
#define CSI2RX_IRQ_FE       (1u << 1)
#define CSI2RX_IRQ_ERR      (1u << 2) /* an ERR_STATUS bit was set */
#define CSI2RX_IRQ_LOG_DONE (1u << 3)
#define CSI2RX_IRQ_RAW_DONE (1u << 4)
#define CSI2RX_IRQ_ALL      0x1Fu

#define CSI2RX_ERR_SOT      (1u << 0)
#define CSI2RX_ERR_ECC_CORR (1u << 1)
#define CSI2RX_ERR_ECC      (1u << 2) /* uncorrectable header */
#define CSI2RX_ERR_CRC      (1u << 3)
#define CSI2RX_ERR_TRUNC    (1u << 4)
#define CSI2RX_ERR_OVF      (1u << 5)
#define CSI2RX_ERR_SKEW     (1u << 6)
#define CSI2RX_ERR_FORMAT   (1u << 7)
#define CSI2RX_ERR_FRAME    (1u << 8)
#define CSI2RX_ERR_LP       (1u << 9)
#define CSI2RX_ERR_ALL      0x3FFu

#define CSI2RX_FRAME_LINES(f) ((f) & 0xFFFFu)
#define CSI2RX_FRAME_NUM(f)   ((f) >> 16)
#define CSI2RX_LINE_WC(l)     ((l) & 0xFFFFu)
#define CSI2RX_LINE_DT(l)     (((l) >> 16) & 0x3Fu)
#define CSI2RX_LINE_VC(l)     (((l) >> 22) & 3u)

#define CSI2RX_DLY_TAP(d) ((d) & 0x1FFu)         /* written */
#define CSI2RX_DLY_OUT(d) (((d) >> 16) & 0x1FFu) /* in use (IDELAY CNTVALUEOUT) */
#define CSI2RX_DLY_MAX    511u

/* LOG_CTRL / RAW_CTRL: an ARM write starts a capture (a new ARM restarts a
 * pending one), the mode bits go with it. ARMED reads 1 until the capture
 * has finished, then DONE is 1. */
#define CSI2RX_LOG_ARM     (1u << 0)
#define CSI2RX_LOG_ARMED   (1u << 0)
#define CSI2RX_LOG_TRIG_FS (1u << 1) /* start with the next FS of the selected VC */
#define CSI2RX_LOG_STOP_FE (1u << 2) /* circular, stop when an FE of the selected VC is logged */
#define CSI2RX_LOG_DONE    (1u << 8)
#define CSI2RX_LOG_WPTR(c) (((c) >> 16) & 0x3Fu) /* STOP_FE: index of the oldest entry */
#define CSI2RX_RAW_ARM     (1u << 0) /* start when lane 0 enters HS */
#define CSI2RX_RAW_ARMED   (1u << 0)
#define CSI2RX_RAW_NOW     (1u << 1) /* start at once (with ARM) */
#define CSI2RX_RAW_DONE    (1u << 8)

#define CSI2RX_LOG_ENTRIES 64u
#define CSI2RX_RAW_WORDS   64u

/* Packet log entry */
#define CSI2RX_LOG_DT(e)    ((e) & 0x3Fu)
#define CSI2RX_LOG_VC(e)    (((e) >> 6) & 3u)
#define CSI2RX_LOG_WC(e)    (((e) >> 8) & 0xFFFFu) /* after ECC correction */
#define CSI2RX_LOG_ECC(e)   (((e) >> 24) & 3u)     /* CSI2RX_ECC_* (raw header) */
#define CSI2RX_LOG_CRC_ERR  (1u << 26)
#define CSI2RX_LOG_TRUNC    (1u << 27)
#define CSI2RX_LOG_ACCEPTED (1u << 28)
#define CSI2RX_LOG_OVF      (1u << 29)
#define CSI2RX_ECC_OK       0u
#define CSI2RX_ECC_CORR     1u
#define CSI2RX_ECC_ERR      2u

/* CSI-2 data types */
#define CSI2_DT_FS    0x00u
#define CSI2_DT_FE    0x01u
#define CSI2_DT_LS    0x02u
#define CSI2_DT_LE    0x03u
#define CSI2_DT_EMB   0x12u /* embedded data */
#define CSI2_DT_RAW8  0x2Au
#define CSI2_DT_RAW10 0x2Bu

typedef struct {
  uint32_t frames, packets, lines, ecc_corr, ecc_err, crc, trunc, sot[2], drop, ovf, burst[2],
      clk_burst, lp_err, misc_err;
} bow_csi2rx_cnt_t;

typedef struct {
  uint32_t tap[2], width[2]; /* chosen tap and eye width (taps) per data lane */
} bow_csi2rx_cal_t;

/* ID check; *lanes = data lanes, *phy = a D-PHY is connected (either may be
 * NULL). false: no Bow32 CSI-2 receiver at BOW32_CSI2RX_BASE. */
bool bow_csi2rx_probe(uint32_t *lanes, bool *phy);

/* PHY_CFG for the video clock of INFO and the lane rate (bit/s per lane,
 * e.g. IMX219_LANE_RATE): SETTLE 70 ns, CLK_SETTLE 150 ns, LP_FILTER 2 and
 * CLK_MISS = one byte clock period (8 UI) + 3 video cycles, since the clock
 * lane activity is seen as byte clock edges. CTRL = PHY_EN | RX_EN | lanes
 * (1 or 2) | dt (VC 0); counters, ERR_STATUS and IRQ_STATUS cleared. Call
 * BEFORE the sensor starts streaming: the receiver must see LP-11 first.
 * Lane rates below ~350 Mbit/s are not supported (docs/ip/csi2rx.md). */
void bow_csi2rx_start(uint32_t lanes, uint32_t dt, uint32_t lane_rate);

/* Call AFTER the sensor stream-off: waits until the current frame has ended
 * (FE, or IN_FRAME = 0 and no new burst for 2 line times; at most timeout_ms)
 * and the clock lane state machine has closed the byte clock gate (at most
 * 1 ms more), then CTRL = 0. The taps (DLYn) are kept. */
void bow_csi2rx_stop(uint32_t timeout_ms);

/* CTRL.RX_EN only (around VC / DT changes); clears the datapath when off. */
void bow_csi2rx_set_rx(bool on);

/* Clear the counters and ERR_STATUS. */
void bow_csi2rx_clear(void);

void bow_csi2rx_counters(bow_csi2rx_cnt_t *c);
/* ecc_corr + ecc_err + crc + trunc + sot + ovf + misc_err (0 = clean link). */
uint32_t bow_csi2rx_link_errors(const bow_csi2rx_cnt_t *c);

/* Clear the counters, then true once `packets` packets arrived without a
 * link error; false at the first error or after timeout_ms. */
bool bow_csi2rx_link_check(uint32_t packets, uint32_t timeout_ms);

/* Wait for the next frame end of the selected VC (IRQ_STATUS.FE is cleared
 * first); false on timeout. */
bool bow_csi2rx_wait_frame(uint32_t timeout_ms);

/* IDELAY tap 0..511 of a data lane; applied at the next HS burst. */
void bow_csi2rx_set_delay(uint32_t lane, uint32_t tap);
/* Wait until every lane uses its written tap (needs a burst). */
bool bow_csi2rx_wait_delay(uint32_t timeout_ms);

/* Eye calibration while the sensor streams: sweeps the taps of both lanes
 * together, then of each lane alone (steps of `step` taps) and programs the
 * centre of the widest error free range. tap_timeout_ms: time for one tap,
 * >= 1.2 x frame period + 2 ms (a tap may wait for the vertical blanking).
 * verbose: one map line per sweep. false (old taps restored): no byte clock
 * or no eye on a lane. */
bool bow_csi2rx_calibrate(uint32_t step, uint32_t tap_timeout_ms, bow_csi2rx_cal_t *cal,
                          bool verbose);

/* Packet log: mode = 0 (next 64 packets) or CSI2RX_LOG_TRIG_FS and/or
 * CSI2RX_LOG_STOP_FE. e[64] receives the entries in time order. Returns the
 * number of entries (STOP_FE: the last one is the FE), 0 on timeout. */
uint32_t bow_csi2rx_log(uint32_t *e, uint32_t mode, uint32_t timeout_ms);
void bow_csi2rx_print_log(const uint32_t *e, uint32_t n);

/* 64 raw PHY words per lane (w[i] = lane 0 | lane 1 << 8, bit 0 received
 * first), from when lane 0 enters HS, or at once (now). */
bool bow_csi2rx_raw(uint16_t *w, bool now, uint32_t timeout_ms);

/* Byte clock frequency: maximum of BYTECLK over timeout_ms (at least one
 * read). The register only counts bursts longer than ~2 x 256 CPU cycles. */
uint32_t bow_csi2rx_byteclk_hz(uint32_t timeout_ms);

/* Link verdict ("csi2rx: link ok", "link errors", "no data", or "no lines":
 * frames without an accepted line), counters,
 * frame/line info, timing and PHY state. The byte clock is measured over
 * one frame period + 2 ms (a non-continuous clock may stop for the whole
 * vertical blanking). */
void bow_csi2rx_print_status(void);

#endif /* BOW_CSI2RX_H_ */
