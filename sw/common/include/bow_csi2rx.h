/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MIPI CSI-2 receiver driver (Bow32 CSI-2 RX controller, docs/ip/csi2rx.md).
 *
 * The receiver decodes the packets of a CSI-2 camera (1, 2 or 4 data lanes,
 * RAW8 / RAW10) and streams the pixels of one virtual channel and data type
 * into the ISP (AXI4-Stream, tuser[0] = start of frame, tuser[1] = line
 * error with tlast; a frame whose first line cannot be output is skipped,
 * FRAME_ERR holds the errors of each frame). The sampling point of every
 * data lane is an input delay code of the D-PHY that software finds at run
 * time (bow_csi2rx_calibrate, then bow_csi2rx_margin): the capture has no
 * static timing.
 *
 * The PHY registers (timing, LP / HS state, delays, HS entry and LP error
 * counters, raw words, byte clock meter, ready state) are those of the
 * D-PHY at 0xC00 of this window since step 4 of docs/ip/mipi_rx_arch.md
 * (bow_dphy_rx.h); their old offsets here read 0, there is no alias. The
 * driver uses both; bow_csi2rx_probe() refuses a bitstream built before the
 * split (INFO[6] = 0).
 *
 * The hardware takes the configuration without handshake, so:
 *   - change CTRL.LANES / LANES4 / VC / VC_ANY / DT / EXTRA only while
 *     CTRL.RX_EN = 0,
 *   - change the D-PHY's TIM0 and CTRL.CLK_CONT only while CTRL.PHY_EN = 0,
 *   - start the receiver before the sensor streams (it must see LP-11 first)
 *     and stop it after the sensor has finished its last frame.
 */
#ifndef BOW_CSI2RX_H_
#define BOW_CSI2RX_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"
#include "bow_dphy_rx.h"

typedef struct {
  volatile uint32_t ID;          /* 0x000 R   0x43533201 */
  volatile uint32_t INFO;        /* 0x004 R   [3:0] lanes [4] PHY [6] D-PHY at 0xC00 [15:8] MHz
                                  *           [31:16] FIFO depth */
  volatile uint32_t CTRL;        /* 0x008 RW  CSI2RX_CTRL_* */
  uint32_t reserved0;            /* 0x00C     (PHY_CFG before step 4: the D-PHY's TIM0) */
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
  uint32_t reserved1;            /* 0x040     (CNT_BURST: the D-PHY's CNT_BURSTn) */
  volatile uint32_t CNT_MISC;    /* 0x044 R   [31:24] skew + format + frame errors + skips
                                  *           ([23:0]: the D-PHY's CNT_CLK, CNT_LPERR) */
  volatile uint32_t CNT_EXT;     /* 0x048 R   [15:0] bursts with more than CTRL.EXTRA bytes
                                  *           after the packet [31:16] deskew bursts */
  volatile uint32_t FRAME_ERR;   /* 0x04C R   CSI2RX_ERR_* of the last complete frame (from
                                  *           the FE before it), latched at its FE */
  volatile uint32_t FRAME_INFO;  /* 0x050 R   last complete frame: [15:0] lines [31:16] number */
  volatile uint32_t LINE_INFO;   /* 0x054 R   last accepted line: [15:0] WC [21:16] DT [23:22] VC */
  volatile uint32_t FRAME_SUM;   /* 0x058 R   sum of the pixel values of the last frame */
  volatile uint32_t FRAME_TIME;  /* 0x05C R   CPU cycles between the last two FS */
  volatile uint32_t LINE_TIME;   /* 0x060 R   CPU cycles between two line ends of a frame */
  uint32_t reserved2;            /* 0x064     (BYTECLK: the D-PHY's) */
  volatile uint32_t CNT_SOT23;   /* 0x068 R   sync errors [15:0] lane 2 [31:16] lane 3 */
  uint32_t reserved3[5];         /* 0x06C     (CNT_BURST23, DLY0..3: the D-PHY's) */
  volatile uint32_t LOG_CTRL;    /* 0x080 RW  CSI2RX_LOG_* */
  uint32_t reserved4[223];       /* 0x084     (RAW_CTRL: the D-PHY's) */
  volatile uint32_t LOG[64];     /* 0x400 R   packet log, CSI2RX_LOG_* entry fields */
  uint32_t reserved5[448];       /* 0x500     (RAW at 0x800: the D-PHY's) */
} bow_csi2rx_regs_t;

_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, CNT_MISC) == 0x044, "CSI2RX CNT offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, CNT_EXT) == 0x048, "CSI2RX CNT_EXT offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, FRAME_ERR) == 0x04C, "CSI2RX FRAME_ERR offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, CNT_SOT23) == 0x068, "CSI2RX CNT23 offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, FRAME_INFO) == 0x050, "CSI2RX INFO offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, LOG_CTRL) == 0x080, "CSI2RX LOG_CTRL offset");
_Static_assert(__builtin_offsetof(bow_csi2rx_regs_t, LOG) == 0x400, "CSI2RX LOG offset");
_Static_assert(sizeof(bow_csi2rx_regs_t) == 0xC00, "CSI2RX controller window");

#define CSI2RX ((bow_csi2rx_regs_t *)BOW32_CSI2RX_BASE)

#define CSI2RX_ID_VALUE 0x43533201u

#define CSI2RX_MAX_LANES 4u

#define CSI2RX_INFO_LANES(i) ((i) & 0xFu)
#define CSI2RX_INFO_PHY      (1u << 4) /* a D-PHY is connected */
#define CSI2RX_INFO_DPHY     (1u << 6) /* the D-PHY's registers at 0xC00 (step 4 on) */
#define CSI2RX_INFO_MHZ(i)   (((i) >> 8) & 0xFFu) /* video clock of the controller */
#define CSI2RX_INFO_FIFO(i)  ((i) >> 16)

#define CSI2RX_CTRL_PHY_EN    (1u << 0)
#define CSI2RX_CTRL_RX_EN     (1u << 1)
#define CSI2RX_CTRL_LANES2    (1u << 2) /* 0: 1 data lane, 1: 2 data lanes (unless LANES4) */
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

/* STATUS: the PHY bits (LP / HS state, CE, BYTECLK_OK, PHY_RDY) are the
 * D-PHY's LANE_LP, LANE_HS and AFE_STATUS */
#define CSI2RX_ST_IN_FRAME   (1u << 12)

#define CSI2RX_IRQ_FS       (1u << 0)
#define CSI2RX_IRQ_FE       (1u << 1)
#define CSI2RX_IRQ_ERR      (1u << 2) /* an ERR_STATUS bit was set */
#define CSI2RX_IRQ_LOG_DONE (1u << 3)
#define CSI2RX_IRQ_PHY      (1u << 5) /* read only: the D-PHY's interrupt (DPHY_IRQ_*) */
#define CSI2RX_IRQ_ALL      0x0Fu     /* the W1C bits */

#define CSI2RX_ERR_SOT      (1u << 0)
#define CSI2RX_ERR_ECC_CORR (1u << 1)
#define CSI2RX_ERR_ECC      (1u << 2) /* uncorrectable header */
#define CSI2RX_ERR_CRC      (1u << 3)
#define CSI2RX_ERR_TRUNC    (1u << 4)
#define CSI2RX_ERR_OVF      (1u << 5)
#define CSI2RX_ERR_SKEW     (1u << 6)
#define CSI2RX_ERR_FORMAT   (1u << 7)
#define CSI2RX_ERR_FRAME    (1u << 8)
#define CSI2RX_ERR_LP       (1u << 9)  /* an ErrControl / ErrControlClk the D-PHY passed on */
#define CSI2RX_ERR_EXTRA    (1u << 10) /* bytes after a packet in its burst (CTRL.EXTRA) */
#define CSI2RX_ERR_SKIP     (1u << 11) /* a frame was skipped: its first line could not be output */
#define CSI2RX_ERR_ALL      0xFFFu
/* Errors that a bad delay code (sampling point) causes (calibration, margin
 * check, the cause of a failed link check that a new calibration can fix). */
#define CSI2RX_ERR_TAP                                                                          \
  (CSI2RX_ERR_SOT | CSI2RX_ERR_ECC_CORR | CSI2RX_ERR_ECC | CSI2RX_ERR_CRC | CSI2RX_ERR_TRUNC | \
   CSI2RX_ERR_SKEW)

#define CSI2RX_FRAME_LINES(f) ((f) & 0xFFFFu)
#define CSI2RX_FRAME_NUM(f)   ((f) >> 16)
#define CSI2RX_LINE_WC(l)     ((l) & 0xFFFFu)
#define CSI2RX_LINE_DT(l)     (((l) >> 16) & 0x3Fu)
#define CSI2RX_LINE_VC(l)     (((l) >> 22) & 3u)

/* LOG_CTRL: an ARM write starts a capture (a new ARM restarts a pending
 * one), the mode bits go with it. ARMED reads 1 until the capture has
 * finished, then DONE is 1. (RAW: the D-PHY's RAW_CTRL, bow_dphy_rx_raw.) */
#define CSI2RX_LOG_ARM     (1u << 0)
#define CSI2RX_LOG_ARMED   (1u << 0)
#define CSI2RX_LOG_TRIG_FS (1u << 1) /* start with the next FS of the selected VC */
#define CSI2RX_LOG_STOP_FE (1u << 2) /* circular, stop when an FE of the selected VC is logged */
#define CSI2RX_LOG_DONE    (1u << 8)
#define CSI2RX_LOG_WPTR(c) (((c) >> 16) & 0x3Fu) /* STOP_FE: index of the oldest entry */

#define CSI2RX_LOG_ENTRIES 64u

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

/* Return codes of bow_csi2rx_start() (bow_csi2rx_strerror(): a line for them) */
#define CSI2RX_OK       0
#define CSI2RX_ENOTRDY -8 /* the D-PHY's AFE_STATUS.READY stayed 0 */
#define CSI2RX_EAPPLY  -9 /* the D-PHY did not take CMD.APPLY of its timing (no lp clock?) */

/* The counters of the receiver: the controller's, and from the D-PHY the HS
 * entries (burst, clk_burst) and the LP errors of every lane (lp_err). */
typedef struct {
  uint32_t frames, packets, lines, ecc_corr, ecc_err, crc, trunc, sot[4], drop, ovf, burst[4],
      clk_burst, lp_err, misc_err, extra, deskew;
} bow_csi2rx_cnt_t;

typedef struct {
  uint32_t tap[4], width[4]; /* chosen delay code and eye width (codes) per data lane */
  uint32_t lanes;            /* data lanes calibrated */
} bow_csi2rx_cal_t;

/* One point of bow_csi2rx_margin(). Sampling errors are those a bad input
 * delay tap causes: CNT_SOT and CNT_SOT23 (every lane) + CNT_ECC (corrected
 * and not) + CNT_CRC (CRC and truncated), + 1 if ERR_STATUS.SKEW (CNT_MISC
 * also counts format and frame errors). err = ERR_STATUS at the end: OVF,
 * FORMAT, FRAME, LP, EXTRA and SKIP are shown there but are not sampling
 * errors. */
typedef struct {
  uint32_t tap[4];  /* the D-PHY's DLYn during the point (the DLY registers written, else 0) */
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
 * NULL). false: no Bow32 CSI-2 receiver at BOW32_CSI2RX_BASE, one built
 * before the D-PHY split (INFO[6] = 0: "csi2rx: bitstream before the D-PHY
 * split, rebuild it" is printed; this driver has no path for its registers),
 * or a D-PHY of another register map version than this driver's (ID[7:0]:
 * "csi2rx: D-PHY register map version 1, this firmware needs 2: bitstream
 * older than the firmware, rebuild them from one commit" or the other way
 * round; DPHY_MAP_VERSION). */
bool bow_csi2rx_probe(uint32_t *lanes, bool *phy);

/* Data lanes the receiver uses now (CTRL.LANES4 / LANES2, at most INFO). */
uint32_t bow_csi2rx_lanes(void);

/* With a self-calibrating D-PHY (Versal XPHY, DPHY_INFO_SELF_CAL) first waits
 * up to 10 ms for its AFE_STATUS.READY (CSI2RX_ENOTRDY and the receiver off
 * if it stays 0); the UltraScale+ PHY has no start-up calibration, its READY
 * is not checked. The D-PHY's TIM0 for the lane rate (bit/s per lane, e.g.
 * IMX219_LANE_RATE; bow_dphy_rx_timing(): the SETTLE formula of
 * docs/ip/dphy_rx.md from the PHY's INFO2, which gives what the two PHYs had
 * before step 4: 22 at 912 Mbit/s on the KV260, 95 ns = 0x13 on the Huins
 * build). CTRL = PHY_EN | RX_EN | lanes (1, 2 or 4: LANES2 for 2 and more,
 * LANES4 too for 4) | dt (VC 0) | EXTRA above the trail bytes of the lane
 * rate on the lanes in use (T_HS-TRAIL max + LP-11 detection, + the bytes the
 * PHY adds, INFO2 of the D-PHY: the XPHY FIFO); counters (the D-PHY's too),
 * ERR_STATUS and IRQ_STATUS cleared. Call BEFORE the sensor starts streaming:
 * the receiver must see LP-11 first. Lane rates below ~350 Mbit/s are not
 * supported (docs/ip/csi2rx.md). Returns CSI2RX_OK, CSI2RX_ENOTRDY, or
 * CSI2RX_EAPPLY (the D-PHY did not take its timing: receiver off). */
int bow_csi2rx_start(uint32_t lanes, uint32_t dt, uint32_t lane_rate);
/* What a return code of bow_csi2rx_start() means, for an error line. */
const char *bow_csi2rx_strerror(int r);

/* Call AFTER the sensor stream-off: waits until the current frame has ended
 * (FE, or IN_FRAME = 0 and no new burst for 2 line times; at most timeout_ms)
 * and the clock lane state machine has closed the byte clock gate (the
 * D-PHY's LANE_HS RxClkActiveHS, at most 1 ms more), then CTRL = 0. The
 * delays (the D-PHY's DLYn) are kept. */
void bow_csi2rx_stop(uint32_t timeout_ms);

/* CTRL.RX_EN only (around VC / DT changes); clears the datapath when off. */
void bow_csi2rx_set_rx(bool on);

/* Clear the counters and ERR_STATUS, the D-PHY's too (bow_dphy_rx_clear). */
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
/* The same over whole frames of the selected VC: clear the counters, then
 * true once `frames` frames that started after the clear (FS) have ended
 * (FE) without a link error; false at the first error or after timeout_ms
 * (as bow_csi2rx_link_check; *done, if not NULL: the frames that ended).
 * A rare error (e.g. one CRC error every few frames) needs many frames to be
 * seen at all. */
bool bow_csi2rx_link_check_frames(uint32_t frames, uint32_t timeout_ms, uint32_t *done);

/* Wait for the next frame end of the selected VC (IRQ_STATUS.FE is cleared
 * first); false on timeout. */
bool bow_csi2rx_wait_frame(uint32_t timeout_ms);

/* Eye calibration of the lanes in use (bow_csi2rx_lanes()) while the sensor
 * streams, steps of `step` delay codes (the D-PHY's DLYn); programs the
 * centre of the widest error free range of every lane.
 *   UltraScale+ PHY: sweeps the codes of all lanes together (2 lanes without
 *     a common eye: lane 1 at 4 codes over the range, sweep lane 0), then of
 *     each lane alone over the whole range, the others at the common centre.
 *   Self-calibrating PHY (Versal, DPHY_INFO_SELF_CAL): starts from the
 *     delays in use (after reset: the BISC result; 0 is never loaded
 *     blindly); only if they give no clean link, the common sweep first. Then
 *     walks each lane outward from there until the first bad code on both
 *     sides, the others at their best code so far.
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
 * calibration (the lanes in use, at least 2 with the UltraScale+ PHY).
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

/* Link verdict ("csi2rx: link ok", "link errors", "no data", or "no lines":
 * frames without an accepted line), counters, frame/line info (FRAME_ERR
 * of the last frame), timing and PHY state (the D-PHY's registers). The byte
 * clock is measured over one frame period + 2 ms (a non-continuous clock may
 * stop for the whole vertical blanking). The per lane lists (sot, LP state,
 * bursts, delay) have 4 values while 4 lanes are in use (CTRL.LANES4), else
 * 2 as before; while the receiver is off (CTRL.PHY_EN = 0) as many as the
 * build has (INFO: 4 on the Huins camera build). delay: as
 * bow_dphy_rx_print_delays() (self-calibrating PHY: in use, else written);
 * ", PHY not ready" only with a self-calibrating PHY. */
void bow_csi2rx_print_status(void);

#endif /* BOW_CSI2RX_H_ */
