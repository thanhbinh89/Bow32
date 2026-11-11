/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MIPI CSI-2 receiver driver (Bow32 D-PHY RX + CSI-2 RX, docs/ip/csi2rx.md).
 *
 * The receiver decodes the packets of a CSI-2 camera (1, 2 or 4 data lanes,
 * RAW8 / RAW10) and streams the pixels of one virtual channel and data type
 * into the ISP (AXI4-Stream, tuser[0] = start of frame, tuser[1] = line
 * error with tlast; a frame whose first line cannot be output is skipped,
 * FRAME_ERR holds the errors of each frame). The sampling point of every
 * data lane is an input delay tap that software finds at run time
 * (bow_csi2rx_calibrate, then bow_csi2rx_margin): the capture has no static
 * timing.
 *
 * Two kinds of delay line (INFO.DLY_VID):
 *   0  UltraScale+ IDELAYE3 (KV260): a tap written to DLYn is applied at the
 *      next HS burst (byte clock), the first one after reset is loaded too.
 *   1  Versal XPHY: DLYn works in the video clock domain, every write loads
 *      its tap at once (no byte clock needed); after reset the PHY keeps the
 *      delay its built-in self-calibration (BISC) found, DLYn [24:16] shows it,
 *      and tracks voltage and temperature (VT) until the first tap load of
 *      the lane. The PHY is ready (STATUS.PHY_RDY) once its PLL is locked and
 *      BISC is done; only this PHY has the bit.
 *
 * The hardware takes the configuration without handshake, so:
 *   - change CTRL.LANES / LANES4 / VC / VC_ANY / DT / EXTRA only while
 *     CTRL.RX_EN = 0,
 *   - change PHY_CFG and CTRL.CLK_FORCE only while CTRL.PHY_EN = 0,
 *   - start the receiver before the sensor streams (it must see LP-11 first)
 *     and stop it after the sensor has finished its last frame.
 */
#ifndef BOW_CSI2RX_H_
#define BOW_CSI2RX_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t ID;          /* 0x000 R   0x43533201 */
  volatile uint32_t INFO;        /* 0x004 R   [3:0] lanes [4] PHY [5] DLY_VID [15:8] MHz
                                  *           [31:16] FIFO depth */
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
                                  *           [31:24] skew + format + frame errors + skips */
  volatile uint32_t CNT_EXT;     /* 0x048 R   [15:0] bursts with more than CTRL.EXTRA bytes
                                  *           after the packet [31:16] deskew bursts */
  volatile uint32_t FRAME_ERR;   /* 0x04C R   CSI2RX_ERR_* of the last complete frame (from
                                  *           the FE before it), latched at its FE */
  volatile uint32_t FRAME_INFO;  /* 0x050 R   last complete frame: [15:0] lines [31:16] number */
  volatile uint32_t LINE_INFO;   /* 0x054 R   last accepted line: [15:0] WC [21:16] DT [23:22] VC */
  volatile uint32_t FRAME_SUM;   /* 0x058 R   sum of the pixel values of the last frame */
  volatile uint32_t FRAME_TIME;  /* 0x05C R   CPU cycles between the last two FS */
  volatile uint32_t LINE_TIME;   /* 0x060 R   CPU cycles between two line ends of a frame */
  volatile uint32_t BYTECLK;     /* 0x064 R   [19:0] byte clocks per 65536 CPU cycles */
  volatile uint32_t CNT_SOT23;   /* 0x068 R   sync errors [15:0] lane 2 [31:16] lane 3 */
  volatile uint32_t CNT_BURST23; /* 0x06C R   HS entries [15:0] lane 2 [31:16] lane 3 */
  volatile uint32_t DLY[4];      /* 0x070 RW  W [8:0] tap, R [8:0] written [24:16] in use;
                                  *           lanes the receiver does not have: RAZ/WI */
  volatile uint32_t LOG_CTRL;    /* 0x080 RW  CSI2RX_LOG_* */
  volatile uint32_t RAW_CTRL;    /* 0x084 RW  CSI2RX_RAW_* */
  uint32_t reserved3[222];       /* 0x088 */
  volatile uint32_t LOG[64];     /* 0x400 R   packet log, CSI2RX_LOG_* entry fields */
  uint32_t reserved4[192];       /* 0x500 */
  volatile uint32_t RAW[64];     /* 0x800 R   8 bits per lane: [8k+7:8k] lane k word */
} bow_csi2rx_regs_t;

_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, CNT_MISC) == 0x044, "CSI2RX CNT offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, CNT_EXT) == 0x048, "CSI2RX CNT_EXT offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, FRAME_ERR) == 0x04C, "CSI2RX FRAME_ERR offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, CNT_SOT23) == 0x068, "CSI2RX CNT23 offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, FRAME_INFO) == 0x050, "CSI2RX INFO offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, DLY) == 0x070, "CSI2RX DLY offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, LOG_CTRL) == 0x080, "CSI2RX LOG_CTRL offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, LOG) == 0x400, "CSI2RX LOG offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, RAW) == 0x800, "CSI2RX RAW offset");

#define CSI2RX ((bow_csi2rx_regs_t *)BOW32_CSI2RX_BASE)

#define CSI2RX_ID_VALUE 0x43533201u

#define CSI2RX_MAX_LANES 4u

#define CSI2RX_INFO_LANES(i) ((i) & 0xFu)
#define CSI2RX_INFO_PHY      (1u << 4) /* a D-PHY is connected */
#define CSI2RX_INFO_DLY_VID  (1u << 5) /* DLYn in the video clock domain (Versal XPHY) */
#define CSI2RX_INFO_MHZ(i)   (((i) >> 8) & 0xFFu) /* video (PHY) clock */
#define CSI2RX_INFO_FIFO(i)  ((i) >> 16)

#define CSI2RX_CTRL_PHY_EN    (1u << 0)
#define CSI2RX_CTRL_RX_EN     (1u << 1)
#define CSI2RX_CTRL_LANES2    (1u << 2) /* 0: 1 data lane, 1: 2 data lanes (unless LANES4) */
#define CSI2RX_CTRL_CLK_FORCE (1u << 3) /* clock lane always HS (continuous clock only) */
#define CSI2RX_CTRL_VC_ANY    (1u << 4)
#define CSI2RX_CTRL_VC(v)     (((uint32_t)(v) & 3u) << 5)
#define CSI2RX_CTRL_VC_MASK   (3u << 5)
#define CSI2RX_CTRL_LANES4    (1u << 7) /* 4 data lanes (wins over LANES2) */
#define CSI2RX_CTRL_DT(d)     (((uint32_t)(d) & 0x3Fu) << 8)
#define CSI2RX_CTRL_DT_MASK   (0x3Fu << 8)
/* More than EXTRA bytes after a packet in its HS burst: ERR_STATUS.EXTRA (the
 * burst most likely carries further packets, which are dropped). 0 = off,
 * reset 64; must be above the trail bytes (bow_csi2rx_start sets it). Below
 * the trail every burst is flagged, and a flagged burst before the first
 * line of a frame drops that frame (ERR_STATUS.SKIP): with one packet per
 * burst, as the IMX219 and IMX274 send, every frame is lost. */
#define CSI2RX_CTRL_EXTRA(n)   (((uint32_t)(n) & 0xFFu) << 16)
#define CSI2RX_CTRL_EXTRA_MASK (0xFFu << 16)

#define CSI2RX_PHY_SETTLE(n)     ((uint32_t)(n) & 0xFFu)
#define CSI2RX_PHY_LP_FILTER(n)  (((uint32_t)(n) & 0xFu) << 8)
#define CSI2RX_PHY_CLK_SETTLE(n) (((uint32_t)(n) & 0xFFu) << 16)
#define CSI2RX_PHY_CLK_MISS(n)   (((uint32_t)(n) & 0xFFu) << 24) /* 0: no clock miss detection */

/* STATUS: data lanes 0/1 in [5:2] and [10:9], lanes 2/3 in [19:16] and [21:20] */
#define CSI2RX_ST_LP_CLK(s)  ((s) & 3u)                        /* filtered LP state {P, N} */
#define CSI2RX_ST_LP(s, l)   (((s) >> ((l) < 2u ? 2u + 2u * (l) : 12u + 2u * (l))) & 3u)
#define CSI2RX_ST_HS_CLK     (1u << 8)
#define CSI2RX_ST_HS(l)      (1u << ((l) < 2u ? 9u + (l) : 18u + (l))) /* data lane l */
#define CSI2RX_ST_CE         (1u << 11) /* byte clock gate open */
#define CSI2RX_ST_IN_FRAME   (1u << 12)
#define CSI2RX_ST_BYTECLK_OK (1u << 13)
#define CSI2RX_ST_PHY_RDY    (1u << 14) /* Versal (DLY_VID): XPLL locked, BISC done; else
                                         * 1, or 0 in bitstreams built before the bit */
#define CSI2RX_ST_HS_DATA                                                                   \
  (CSI2RX_ST_HS(0) | CSI2RX_ST_HS(1) | CSI2RX_ST_HS(2) | CSI2RX_ST_HS(3))

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
#define CSI2RX_ERR_EXTRA    (1u << 10) /* bytes after a packet in its burst (CTRL.EXTRA) */
#define CSI2RX_ERR_SKIP     (1u << 11) /* a frame was skipped: its first line could not be output */
#define CSI2RX_ERR_ALL      0xFFFu
/* Errors that a bad IDELAY sampling point causes (calibration, margin check,
 * the cause of a failed link check that a new calibration can fix). */
#define CSI2RX_ERR_TAP                                                                          \
  (CSI2RX_ERR_SOT | CSI2RX_ERR_ECC_CORR | CSI2RX_ERR_ECC | CSI2RX_ERR_CRC | CSI2RX_ERR_TRUNC | \
   CSI2RX_ERR_SKEW)

#define CSI2RX_FRAME_LINES(f) ((f) & 0xFFFFu)
#define CSI2RX_FRAME_NUM(f)   ((f) >> 16)
#define CSI2RX_LINE_WC(l)     ((l) & 0xFFFFu)
#define CSI2RX_LINE_DT(l)     (((l) >> 16) & 0x3Fu)
#define CSI2RX_LINE_VC(l)     (((l) >> 22) & 3u)

#define CSI2RX_DLY_TAP(d) ((d) & 0x1FFu)         /* written */
#define CSI2RX_DLY_OUT(d) (((d) >> 16) & 0x1FFu) /* in use (CNTVALUEOUT) */
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
#define CSI2_DT_OB    0x37u /* user defined 8: IMX274 optical black lines */

/* Return codes of bow_csi2rx_start() */
#define CSI2RX_OK       0
#define CSI2RX_ENOTRDY -8 /* STATUS.PHY_RDY stayed 0 */

typedef struct {
  uint32_t frames, packets, lines, ecc_corr, ecc_err, crc, trunc, sot[4], drop, ovf, burst[4],
      clk_burst, lp_err, misc_err, extra, deskew;
} bow_csi2rx_cnt_t;

typedef struct {
  uint32_t tap[4], width[4]; /* chosen tap and eye width (taps) per data lane */
  uint32_t lanes;            /* data lanes calibrated */
} bow_csi2rx_cal_t;

/* One point of bow_csi2rx_margin(). Sampling errors are those a bad input
 * delay tap causes: CNT_SOT and CNT_SOT23 (every lane) + CNT_ECC (corrected
 * and not) + CNT_CRC (CRC and truncated), + 1 if ERR_STATUS.SKEW (CNT_MISC
 * also counts format and frame errors). err = ERR_STATUS at the end: OVF,
 * FORMAT, FRAME, LP, EXTRA and SKIP are shown there but are not sampling
 * errors. */
typedef struct {
  uint32_t tap[4];  /* DLYn during the point (the DLY registers written, else 0) */
  uint32_t frames;  /* frame ends seen */
  uint32_t lines;   /* accepted lines (CNT_LINE) */
  uint64_t bits;    /* packet bits per data lane: lines x (WC + 6) x 8 / lanes */
  uint32_t errors;  /* sampling errors */
  uint32_t err;     /* ERR_STATUS */
  int32_t result;   /* 1 clean, 0 errors, -1 not measured (or not reached) */
} bow_csi2rx_mpoint_t;

typedef struct {
  uint32_t k[4];                  /* taps from the centre to a side point, per lane (0: not used) */
  bow_csi2rx_mpoint_t centre;     /* every lane at its calibrated tap */
  bow_csi2rx_mpoint_t side[4][2]; /* [lane][0: tap - k, 1: tap + k], other lanes at their tap */
} bow_csi2rx_margin_t;

#define CSI2RX_MARGIN_MIN 40u /* smallest automatic k (taps) */

/* ID check; *lanes = data lanes, *phy = a D-PHY is connected (either may be
 * NULL). false: no Bow32 CSI-2 receiver at BOW32_CSI2RX_BASE. */
bool bow_csi2rx_probe(uint32_t *lanes, bool *phy);

/* Data lanes the receiver uses now (CTRL.LANES4 / LANES2, at most INFO). */
uint32_t bow_csi2rx_lanes(void);

/* With the Versal XPHY (INFO.DLY_VID) first waits up to 10 ms for
 * STATUS.PHY_RDY (CSI2RX_ENOTRDY and the receiver off if it stays 0); the
 * UltraScale+ PHY has no start-up calibration, its PHY_RDY is not checked
 * (bitstreams built before the bit read 0 there). PHY_CFG for the video
 * clock of INFO and the lane rate (bit/s per lane, e.g. IMX219_LANE_RATE):
 * SETTLE puts the oldest bit the sync search looks at (the aligner also sees
 * the 2 ISERDES words before hs_active, 16..24 UI) in the middle of
 * 85 ns + 6 UI (T_HS-PREPARE max) ... 145 ns + 2 UI (the zero byte before
 * the earliest sync) after LP-00 at the pin, ~20 ns from either end at
 * 912 Mbit/s (70 ns if lane_rate is 0); with INFO.DLY_VID 95 ns (the Versal
 * XPHY FIFO delays the sync search further, see SETTLE_VID_NS), CLK_SETTLE
 * 150 ns, LP_FILTER 2 and CLK_MISS = one byte clock period (8 UI) + 3 video
 * cycles, since the clock lane activity is seen as byte clock edges. CTRL =
 * PHY_EN | RX_EN | lanes (1, 2 or 4: LANES2 for 2 and more, LANES4 too for
 * 4) | dt (VC 0) | EXTRA above the trail bytes of the lane rate on the lanes
 * in use (T_HS-TRAIL max + LP-11 detection, + the XPHY FIFO with
 * INFO.DLY_VID); counters, ERR_STATUS and IRQ_STATUS cleared. Call BEFORE
 * the sensor starts streaming: the receiver must see LP-11 first. Lane rates
 * below ~350 Mbit/s are not supported (docs/ip/csi2rx.md). Returns CSI2RX_OK
 * or CSI2RX_ENOTRDY. */
int bow_csi2rx_start(uint32_t lanes, uint32_t dt, uint32_t lane_rate);

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
/* ecc_corr + ecc_err + crc + trunc + sot (4 lanes) + ovf + misc_err + extra
 * (0 = clean link). Deskew bursts are not errors. */
uint32_t bow_csi2rx_link_errors(const bow_csi2rx_cnt_t *c);
/* "ecc 0/0 crc 0 trunc 0 sot 0/0 ovf 0 misc 0 extra 0": every term of
 * bow_csi2rx_link_errors() (no newline); sot has 4 values while 4 lanes are
 * in use, or while the receiver is off on a build with 4 lanes (INFO). */
void bow_csi2rx_print_errors(const bow_csi2rx_cnt_t *c);

/* Clear the counters, then true once `packets` packets arrived without a
 * link error; false at the first error or after timeout_ms. After false:
 * bow_csi2rx_link_errors() == 0 means the timeout, fewer packets (no data, or
 * a slow link; ERR_STATUS may still hold LP, which is not counted);
 * otherwise ERR_STATUS tells the cause: a new calibration only helps when it
 * holds CSI2RX_ERR_TAP bits (EXTRA, FORMAT, FRAME, OVF are not tap problems). */
bool bow_csi2rx_link_check(uint32_t packets, uint32_t timeout_ms);

/* Wait for the next frame end of the selected VC (IRQ_STATUS.FE is cleared
 * first); false on timeout. */
bool bow_csi2rx_wait_frame(uint32_t timeout_ms);

/* Input delay tap 0..511 of a data lane (DLY_VID 0: applied at the next HS
 * burst; DLY_VID 1: loaded at once, VT tracking of the lane stops). */
void bow_csi2rx_set_delay(uint32_t lane, uint32_t tap);
/* Wait until the lanes use their written tap (DLY_VID 0: every lane, needs a
 * burst; DLY_VID 1: the lanes written with bow_csi2rx_set_delay()). */
bool bow_csi2rx_wait_delay(uint32_t timeout_ms);
/* DLYn of a data lane (0 for lane >= 4). DLY_VID 1: read until two reads
 * agree, since [24:16] crosses from the video clock bit by bit while VT
 * tracking may step it (one read can mix two values). */
uint32_t bow_csi2rx_read_delay(uint32_t lane);
/* "97/112/88/120": the delays of the lanes, 4 values while 4 lanes are in
 * use, else 2 (as bow_csi2rx_print_status). DLY_VID 1: the delays in use
 * ([24:16], the BISC result until a tap is loaded); 0: the written taps. */
void bow_csi2rx_print_delays(void);
/* The same delays of all CSI2RX_MAX_LANES lanes into taps[] (0 for lanes
 * the receiver does not have): the centre of a margin check at the taps in
 * use (after `delay`, a PHY re-initialisation, or without a calibration). */
void bow_csi2rx_get_delays(uint32_t *taps);
/* DLY_VID 1, after a PHY re-initialisation (XPLL lock + BISC again, e.g.
 * csi2_test `phy reinit`): the loaded taps are gone, every lane uses its new
 * BISC delay; DLYn [8:0] still reads the last written tap, so
 * bow_csi2rx_wait_delay() must forget those lanes. */
void bow_csi2rx_forget_delays(void);

/* Eye calibration of the lanes in use (bow_csi2rx_lanes()) while the sensor
 * streams, steps of `step` taps; programs the centre of the widest error
 * free range of every lane.
 *   DLY_VID 0: sweeps the taps of all lanes together (2 lanes without a
 *     common eye: lane 1 at 4 taps over the range, sweep lane 0), then of
 *     each lane alone over the whole range, the others at the common centre.
 *   DLY_VID 1: starts from the delays in use (after reset: the BISC result;
 *     0 is never loaded blindly); only if they give no clean link, the
 *     common sweep first. Then walks each lane outward from there until the
 *     first bad tap on both sides, the others at their best tap so far.
 * tap_timeout_ms: time for one tap, >= 1.2 x frame period + 2 ms (a tap may
 * wait for the vertical blanking). verbose: one map line per sweep ('#'
 * good, '.' bad, '-' not measured). false (old taps restored): no byte
 * clock, no eye on a lane, or no frame with the new taps. */
bool bow_csi2rx_calibrate(uint32_t step, uint32_t tap_timeout_ms, bow_csi2rx_cal_t *cal,
                          bool verbose);
/* "taps 208/200 eye 272/256": 2 values for 1 or 2 lanes, else one per lane. */
void bow_csi2rx_print_cal(const bow_csi2rx_cal_t *cal);

/* Margin check after bow_csi2rx_calibrate(), while the sensor streams:
 * `frames` frame ends with every lane at its calibrated tap, then for each
 * data lane in use (1, 2 or 4) `frames` frame ends at tap - k and at tap + k
 * (the other lanes at their tap). k = 0: width / 4 per lane, at least
 * CSI2RX_MARGIN_MIN. The DLY registers written are those of the
 * calibration (the lanes in use, at least 2 with DLY_VID 0).
 * A point stops at its first sampling error. After a clean point the
 * counters are cleared before the next taps are written: a frame start lost
 * at the new taps is an error of that point. Returns 1: no sampling error at
 * any point; 0: errors (m says where, also when a later point was not
 * measured); -1: not measured (tap not applied, or no frame start or end
 * within tap_timeout_ms: is the sensor streaming?). Then the calibrated
 * taps, one frame end, counters and ERR_STATUS cleared. The taps are never
 * moved: a low margin is only reported. Polls and clears IRQ_STATUS.FS and
 * FE (IRQ_EN must not include them). verbose: one line per measured point,
 * after all points (printing would move tap changes into frames). */
int bow_csi2rx_margin(const bow_csi2rx_cal_t *cal, uint32_t k, uint32_t frames,
                      uint32_t tap_timeout_ms, bow_csi2rx_margin_t *m, bool verbose);
/* "+-68/+-66 taps: 0 errors in 5 x 60 frames, BER < 4.9e-9" (one k per
 * lane in use) or the first point with errors (no newline). */
void bow_csi2rx_print_margin(const bow_csi2rx_margin_t *m, int result);

/* Packet log: mode = 0 (next 64 packets) or CSI2RX_LOG_TRIG_FS and/or
 * CSI2RX_LOG_STOP_FE. e[64] receives the entries in time order. Returns the
 * number of entries (STOP_FE: the last one is the FE), 0 on timeout. */
uint32_t bow_csi2rx_log(uint32_t *e, uint32_t mode, uint32_t timeout_ms);
void bow_csi2rx_print_log(const uint32_t *e, uint32_t n);

/* 64 raw PHY words (byte k of w[i] = lane k, bit 0 received first), from
 * when lane 0 enters HS, or at once (now). */
bool bow_csi2rx_raw(uint32_t *w, bool now, uint32_t timeout_ms);

/* Byte clock frequency: maximum of BYTECLK over timeout_ms (at least one
 * read). The register only counts bursts longer than ~2 x 256 CPU cycles. */
uint32_t bow_csi2rx_byteclk_hz(uint32_t timeout_ms);

/* Link verdict ("csi2rx: link ok", "link errors", "no data", or "no lines":
 * frames without an accepted line), counters, frame/line info (FRAME_ERR
 * of the last frame), timing and PHY state. The byte clock is measured over
 * one frame period + 2 ms (a non-continuous clock may stop for the whole
 * vertical blanking). The per lane lists (sot, LP state, bursts, delay)
 * have 4 values while 4 lanes are in use (CTRL.LANES4), else 2 as before;
 * while the receiver is off (CTRL.PHY_EN = 0) as many as the build has
 * (INFO: 4 on the Huins camera build). delay: as bow_csi2rx_print_delays()
 * (DLY_VID 1: in use, else written); ", PHY not ready" only with DLY_VID 1. */
void bow_csi2rx_print_status(void);

#endif /* BOW_CSI2RX_H_ */
