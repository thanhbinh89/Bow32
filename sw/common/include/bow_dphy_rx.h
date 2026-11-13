/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MIPI D-PHY receiver driver: the registers of the digital D-PHY of the Bow32
 * CSI-2 receiver (bow_dphy_rx, docs/ip/dphy_rx.md) at 0xC00 of the CSI2RX
 * window, 0x4000_8C00 (step 4 of docs/ip/mipi_rx_arch.md). The CSI-2
 * controller and its driver (bow_csi2rx.h) use this one for the PHY part:
 * timing, input delays, LP / HS state, HS entry and LP error counters, raw
 * PHY words, the byte clock meter, the PHY's ready state and re-init.
 *
 * Every name has the prefix DPHY_ (struct DPHY, macros DPHY_*): the window
 * has registers whose names the controller has too (ID, INFO, CTRL, IRQ_*,
 * ERR_STATUS, BYTECLK, RAW_CTRL). Registers of later steps (AFE_TRIM, deskew,
 * PRBS, LANE_MAP, ...) read 0. Since step 5 the D-PHY speaks the AFE interface
 * (docs/ip/mipi_rx_arch.md section 3.2): DLYn drives static delay codes and OWN
 * (the AFE loads a changed code by itself), AFE_CTRL.PD the AFE's power down,
 * CMD.AFE_CAL its re-calibration (cal_start; CMD.REINIT up to step 5).
 *
 * Since step 6 (v1.x) CTRL and TIM0..TIM2 are shadow registers: a write
 * changes what they read, the D-PHY takes them all at once at CMD.APPLY
 * (bow_dphy_rx_apply(); the functions of this driver that write them apply
 * and return false when the D-PHY did not take it). CMD reads [0] while an
 * APPLY is pending and [31] DIRTY from a shadow write until the next APPLY:
 * CMD reads 0 when the D-PHY uses CTRL / TIM0..2 as they read. Every new bit
 * is 0 (TIM1.HS_TMO 2^20) after reset, the behaviour of v1: T_INIT (TIM2),
 * the HS and escape timeouts, HSRX_EARLY, CLK_MISS_OFF, CLK_TOG_DIV, ULPS_EN,
 * CLK_LOST_EN; LATE_EOT is always reported (ERR_STATUS[7], CNT_MISC, IRQ ERR:
 * nothing of the receiver reads them). CMD.REINIT sends the lane state
 * machines back to WaitStop and makes T_INIT due again. ID[7:0] is the
 * version of the register map: 2 since step 6 (CMD[1] became REINIT, CTRL /
 * TIM0 need CMD.APPLY), 1 in steps 4 and 5; bow_csi2rx_probe() refuses a
 * bitstream with another one.
 *
 * Kinds of PHY I/O (INFO[7:5], DPHY_AFE_*):
 *   UltraScale+ (KV260, IDELAYE3): a code written to DLYn is applied at the
 *     next HS burst (byte clock), the PHY has no start-up calibration
 *     (AFE_STATUS.READY is 1) and no re-init.
 *   Versal (Huins, XPHY): a new DLYn code is loaded at once (no byte clock
 *     needed; the code in use written again loads nothing); after reset,
 *     CMD.AFE_CAL or AFE_CTRL.PD the PHY keeps the delay of its self-calibration
 *     (BISC, INFO[23]: DLYn [24:16] shows it, OWN = 0) and tracks voltage and
 *     temperature until the first load of the lane; AFE_STATUS.READY once its
 *     PLL is locked and BISC is done.
 */
#ifndef BOW_DPHY_RX_H_
#define BOW_DPHY_RX_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t ID;           /* 0x000 R   0x44505202: "DPR", map version 2 */
  volatile uint32_t INFO;         /* 0x004 R   DPHY_INFO_* */
  volatile uint32_t INFO2;        /* 0x008 R   DPHY_INFO2_* */
  volatile uint32_t CTRL;         /* 0x00C RW  DPHY_CTRL_* */
  volatile uint32_t CMD;          /* 0x010 W   DPHY_CMD_*; R [0] APPLY pending, [31] DIRTY */
  volatile uint32_t AFE_CTRL;     /* 0x014 RW  DPHY_AFE_CTRL_* */
  volatile uint32_t AFE_STATUS;   /* 0x018 R   DPHY_AFE_* */
  volatile uint32_t AFE_TRIM[2];  /* 0x01C     (later step) */
  volatile uint32_t TIM0;         /* 0x024 RW  DPHY_TIM0_*, lp clock cycles */
  volatile uint32_t TIM1;         /* 0x028 RW  DPHY_TIM1_*: HS_TMO, CLK_TOG_DIV (shadow) */
  volatile uint32_t TIM2;         /* 0x02C RW  DPHY_TIM2_*: T_INIT, ESC_TMO (shadow) */
  volatile uint32_t LANE_LP;      /* 0x030 R   DPHY_LANE_LP*: filtered LP {P, N} */
  volatile uint32_t LANE_HS;      /* 0x034 R   DPHY_LANE_HS* */
  volatile uint32_t LANE_STOP;    /* 0x038 R   DPHY_LANE_STOP* / DPHY_LANE_ULPS*: Stopstate, ULPS */
  volatile uint32_t IRQ_STATUS;   /* 0x03C R/W1C DPHY_IRQ_* */
  volatile uint32_t IRQ_EN;       /* 0x040 RW  same bits */
  volatile uint32_t ERR_STATUS;   /* 0x044 R/W1C DPHY_ERR_*, sticky */
  volatile uint32_t ERR_LANE;     /* 0x048 R/W1C DPHY_ERR_LANE_*, sticky */
  volatile uint32_t BYTECLK;      /* 0x04C R   [19:0] byte clocks per 65536 CPU cycles */
  volatile uint32_t CNT_BURST[8]; /* 0x050 R   HS entries of data lane l (32 bit, saturating) */
  volatile uint32_t CNT_CLK;      /* 0x070 R   HS entries of the clock lane */
  volatile uint32_t CNT_LPERR;    /* 0x074 R   LP errors of every lane */
  volatile uint32_t CNT_DSK;      /* 0x078 R   [31:16] ULPS entries ([15:0] deskew bursts: step 8) */
  volatile uint32_t CNT_MISC;     /* 0x07C R   [31:16] HS_TMO + CLK_LOST + LATE_EOT + ESC_TMO */
  volatile uint32_t DLY[8];       /* 0x080 RW  DPHY_DLY_*; lanes the receiver does not have: RAZ/WI */
  uint32_t reserved0[24];         /* 0x0A0 */
  volatile uint32_t RAW_CTRL;     /* 0x100 RW  DPHY_RAW_* */
  uint32_t reserved1[63];         /* 0x104 */
  volatile uint32_t RAW[128];     /* 0x200 R   entry i: RAW[2i] lanes 0..3 (byte k = lane k),
                                   *           RAW[2i + 1] lanes 4..7 */
} bow_dphy_rx_regs_t;

_Static_assert(__builtin_offsetof(bow_dphy_rx_regs_t, TIM0) == 0x024, "DPHY TIM0 offset");
_Static_assert(__builtin_offsetof(bow_dphy_rx_regs_t, IRQ_STATUS) == 0x03C, "DPHY IRQ offset");
_Static_assert(__builtin_offsetof(bow_dphy_rx_regs_t, CNT_BURST) == 0x050, "DPHY CNT offset");
_Static_assert(__builtin_offsetof(bow_dphy_rx_regs_t, CNT_LPERR) == 0x074, "DPHY LPERR offset");
_Static_assert(__builtin_offsetof(bow_dphy_rx_regs_t, DLY) == 0x080, "DPHY DLY offset");
_Static_assert(__builtin_offsetof(bow_dphy_rx_regs_t, RAW_CTRL) == 0x100, "DPHY RAW_CTRL offset");
_Static_assert(__builtin_offsetof(bow_dphy_rx_regs_t, RAW) == 0x200, "DPHY RAW offset");

#define DPHY_BASE (BOW32_CSI2RX_BASE + 0xC00u)
#define DPHY      ((bow_dphy_rx_regs_t *)DPHY_BASE)

#define DPHY_ID_VALUE      0x44505202u /* "DPR", register map version DPHY_MAP_VERSION */
#define DPHY_ID_NAME(i)    ((i) >> 8)  /* 0x445052: "DPR" */
#define DPHY_ID_VERSION(i) ((i) & 0xFFu)
#define DPHY_MAP_VERSION   2u          /* this driver's map (1: steps 4 and 5) */

#define DPHY_MAX_LANES 4u /* lanes 4..7 of the map: not in v1 */

#define DPHY_INFO_LANES(i)     ((i) & 0xFu)
#define DPHY_INFO_AFE(i)       (((i) >> 5) & 7u)      /* DPHY_AFE_* */
#define DPHY_INFO_LP_MHZ(i)    (((i) >> 8) & 0x3FFu)  /* lp clock (MHz): the PHY timer clock */
#define DPHY_INFO_DLY_W(i)     (((i) >> 18) & 0xFu)   /* delay code bits */
#define DPHY_INFO_SELF_CAL     (1u << 23)             /* delays of a self-calibration (BISC) */
#define DPHY_INFO_ULPS         (1u << 27)             /* escape mode entry, ULPS (step 6) */
#define DPHY_AFE_ASIC          0u
#define DPHY_AFE_XUSP          1u /* UltraScale+ (bow_dphy_io_xusp, KV260) */
#define DPHY_AFE_VERSAL        2u /* Versal XPHY (bow_dphy_io_versal, Huins) */
#define DPHY_AFE_MODEL         3u
#define DPHY_INFO2_SETTLE_NS(i) ((i) & 0xFFu)          /* SETTLE target: ns part */
#define DPHY_INFO2_SETTLE_UI(i) (((i) >> 8) & 0xFFu)   /* ... and UI part */
#define DPHY_INFO2_TRAIL(i)     (((i) >> 16) & 0xFFu)  /* bytes per lane the PHY adds after a burst */

/* CTRL (shadow: CMD.APPLY) */
#define DPHY_CTRL_CLK_CONT     (1u << 1)  /* clock lane always HS (continuous clock only) */
#define DPHY_CTRL_ULPS_EN      (1u << 2)  /* escape mode entry and ULPS (else LP-10 is an LP error) */
#define DPHY_CTRL_HSRX_EARLY   (1u << 3)  /* HS receivers on from HS-Rqst (LP-01), not LP-00; not
                                           * for the FPGA adapters: one pin switches HS receiver
                                           * and termination, so this terminates LP-01 */
#define DPHY_CTRL_DES_RST_DIS  (1u << 6)  /* test only: no receive path reset while the gate is closed */
#define DPHY_CTRL_CLK_LOST_EN  (1u << 7)  /* CLK_LOST: a data lane in HS without the clock lane */
#define DPHY_CTRL_CLK_MISS_OFF (1u << 16) /* clock lane HS receiver + termination off at the clock
                                           * miss (T_CLK-MISS), not at LP-11 */

/* CMD (write; read [0] APPLY pending, [31] DIRTY) */
#define DPHY_CMD_APPLY   (1u << 0) /* take the shadow CTRL / TIM0..2 (step 6) */
#define DPHY_CMD_DIRTY   (1u << 31) /* read: a shadow register was written since the last APPLY */
#define DPHY_CMD_REINIT  (1u << 1) /* lane state machines back to WaitStop, T_INIT due again (step 6;
                                    * up to step 5: the AFE re-calibration, now CMD.AFE_CAL) */
#define DPHY_CMD_AFE_CAL (1u << 2) /* AFE re-calibration, cal_start (Versal: XPLL lock, BISC, VT
                                    * tracking again) */
#define DPHY_CMD_CNT_CLR (1u << 3) /* clear CNT_* */

#define DPHY_AFE_CTRL_PD (1u << 0) /* AFE powered down (0 after reset on the FPGAs; Versal: the
                                    * PHY held in its init reset, OWN of every lane cleared) */

#define DPHY_AFE_READY        (1u << 0)
#define DPHY_AFE_CAL_DONE     (1u << 1)  /* the AFE's internal calibration (0 on the FPGAs) */
#define DPHY_AFE_CAL_ERR      (1u << 2)
#define DPHY_AFE_STATUS(s)    (((s) >> 8) & 0xFFu) /* raw PHY status */
/* Versal: the raw status of bow_dphy_io_versal */
#define DPHY_AFE_ST_LOCKED    (1u << 8)  /* XPLL LOCKED */
#define DPHY_AFE_ST_LOCKED_FB (1u << 9)  /* XPLL LOCKED_FB */
#define DPHY_AFE_ST_DLY_RDY   (1u << 10) /* DLY_RDY of every nibble (BISC delays) */
#define DPHY_AFE_ST_PHY_RDY   (1u << 11) /* PHY_RDY of every nibble */

#define DPHY_TIM0_SETTLE(n)     ((uint32_t)(n) & 0xFFu)
#define DPHY_TIM0_LP_FILTER(n)  (((uint32_t)(n) & 0xFu) << 8)
#define DPHY_TIM0_CLK_SETTLE(n) (((uint32_t)(n) & 0xFFu) << 16)
#define DPHY_TIM0_CLK_MISS(n)   (((uint32_t)(n) & 0xFFu) << 24) /* 0: no clock miss detection */
/* TIM1, TIM2 (step 6, lp clock cycles; 0: off) */
#define DPHY_TIM1_HS_TMO(n)      ((uint32_t)(n) & 0xFFFFFFu)   /* HS watchdog of a data lane */
#define DPHY_TIM1_CLK_TOG_DIV(n) (((uint32_t)(n) & 0xFu) << 24) /* clock lane activity every
                                                                * 2^n byte clocks: 2^n byte
                                                                * clocks must last longer
                                                                * than one lp clock */
#define DPHY_TIM1_CLK_TOG_DIV_OF(v) (((v) >> 24) & 0xFu)
#define DPHY_TIM1_RESET          0x00100000u                   /* HS_TMO 2^20 (the v1 watchdog) */
#define DPHY_TIM1_HS_TMO_OF(v)   ((v) & 0xFFFFFFu)
#define DPHY_TIM2_T_INIT(n)      ((uint32_t)(n) & 0xFFFFFu)    /* LP-11 before Stop once ready rose
                                                                * or after CMD.REINIT */
#define DPHY_TIM2_ESC_TMO(n)     (((uint32_t)(n) & 0xFFFu) << 20) /* escape entry to command, in
                                                                  * 64 cycle units */
#define DPHY_TIM2_T_INIT_OF(v)   ((v) & 0xFFFFFu)
#define DPHY_TIM1_HS_TMO_MAX     0xFFFFFFu  /* field limits (cycles; ESC_TMO: 64 cycle units) */
#define DPHY_TIM2_T_INIT_MAX     0xFFFFFu
#define DPHY_TIM2_ESC_TMO_MAX    0xFFFu
#define DPHY_TIM1_CLK_TOG_DIV_MAX 15u

/* LANE_LP: [1:0] clock lane, [2l+3:2l+2] data lane l; LANE_HS: [0] clock
 * lane, [l+1] data lane l */
#define DPHY_LANE_LP_CLK(v)    ((v) & 3u)
#define DPHY_LANE_LP(v, l)     (((v) >> (2u + 2u * (l))) & 3u)
#define DPHY_LANE_HS_CLK       (1u << 0)
#define DPHY_LANE_HS(l)        (1u << (1u + (l)))
#define DPHY_LANE_HS_DATA      0x1Eu      /* every data lane */
#define DPHY_LANE_HS_GATE      (1u << 16) /* byte clock gate open */
#define DPHY_LANE_HS_CLK_ACT   (1u << 17) /* RxClkActiveHS (v1: the gate) */
#define DPHY_LANE_HS_BYTECLK_OK (1u << 18)
/* LANE_STOP: [0] StopstateClk, [l+1] Stopstate of data lane l; [16] ULPS of the
 * clock lane, [l+17] of data lane l */
#define DPHY_LANE_STOP_CLK     (1u << 0)
#define DPHY_LANE_STOP(l)      (1u << (1u + (l)))
#define DPHY_LANE_ULPS_CLK     (1u << 16)
#define DPHY_LANE_ULPS(l)      (1u << (17u + (l)))

#define DPHY_IRQ_ERR      (1u << 0) /* an ERR_STATUS bit was set */
#define DPHY_IRQ_ULPS     (1u << 1) /* a lane entered or left ULPS */
#define DPHY_IRQ_RAW_DONE (1u << 3)
#define DPHY_IRQ_ALL      0x0Bu

#define DPHY_ERR_CONTROL  (1u << 2)  /* LP sequence error or HS watchdog, any lane */
#define DPHY_ERR_HS_TMO   (1u << 3)  /* HS watchdog (TIM1.HS_TMO) */
#define DPHY_ERR_ESC      (1u << 4)  /* escape command other than ULPS */
#define DPHY_ERR_CLK_LOST (1u << 6)  /* data lane in HS without the clock lane (CLK_LOST_EN) */
#define DPHY_ERR_LATE_EOT (1u << 7)  /* the byte clock stopped before RxActiveHS fell */
#define DPHY_ERR_ESC_TMO  (1u << 10) /* escape mode longer than TIM2.ESC_TMO */
#define DPHY_ERR_ALL      0x4DCu
#define DPHY_ERR_LANE_CONTROL(l) (1u << (8u + (l)))
#define DPHY_ERR_LANE_CLK        (1u << 16)
#define DPHY_ERR_LANE_ALL        0x10F00u

/* DLYn: CODE written (the static code the D-PHY drives to the AFE), PEND (OWN
 * and the AFE's delay differs from CODE), the AFE's delay in use (dly_q:
 * CNTVALUEOUT on the FPGAs), OWN (the lane uses the software's code; 0 after
 * reset and while the AFE is not ready: a restart loses the loaded codes, and
 * the next write raises OWN and loads again) */
#define DPHY_DLY_CODE(d) ((d) & 0x3FFu)
#define DPHY_DLY_PEND    (1u << 15)
#define DPHY_DLY_Q(d)    (((d) >> 16) & 0x3FFu)
#define DPHY_DLY_OWN     (1u << 31)
#define DPHY_DLY_MAX     511u /* DlyW 9 on both FPGAs */

/* RAW_CTRL: ARM starts a capture (a new ARM restarts a pending one), NOW with
 * it starts at once. ARMED reads 1 until the capture has finished, then DONE. */
#define DPHY_RAW_ARM   (1u << 0) /* start when lane 0 enters HS */
#define DPHY_RAW_ARMED (1u << 0)
#define DPHY_RAW_NOW   (1u << 1)
#define DPHY_RAW_DONE  (1u << 8)
#define DPHY_RAW_WORDS 64u

/* Return codes */
#define DPHY_OK         0
#define DPHY_ENOREINIT -1 /* READY did not fall after CMD.AFE_CAL: no re-init in this PHY */
#define DPHY_ENOTRDY   -2 /* READY did not come back */

typedef struct {
  uint32_t burst[4]; /* HS entries per data lane */
  uint32_t clk_burst; /* HS entries of the clock lane */
  uint32_t lp_err;    /* LP errors of every lane */
} bow_dphy_rx_cnt_t;

/* SETTLE of TIM0, the one formula for every PHY (docs/ip/dphy_rx.md):
 * ((SETTLE_NS * 1000 + SETTLE_UI * UI_ps) * MHz + 500000) / 10^6 - (3 +
 * LP_FILTER), clamped to 1..255; UI_ps = 10^12 / lane_rate (integer). The
 * target SETTLE_NS + SETTLE_UI UI comes from INFO2: from LP-00 at the output
 * of the LP receiver to the start of the sync search; 3 + LP_FILTER cycles of
 * synchroniser, filter and state machine. Integer steps as the driver had
 * them before: 22 at 912 Mbit/s and 200 MHz with 107 ns + 24 UI (UltraScale+),
 * 19 = 0x13 with 120 ns + 0 UI (Versal, at every lane rate). lane_rate 0
 * (unknown) with a UI part: 70 ns, as settle_cycles() before; without one the
 * lane rate is not needed. Pure: no register access
 * (tools/tests/test_dphy_settle.py runs it on the host). */
static inline uint32_t bow_dphy_rx_settle(uint32_t settle_ns, uint32_t settle_ui,
                                          uint32_t lane_rate, uint32_t mhz, uint32_t lp_filter) {
  uint64_t n, lat = 3u + lp_filter;
  if (lane_rate == 0 && settle_ui != 0) {
    n = (70u * (uint64_t)mhz + 500u) / 1000u;
    return n < 1u ? 1u : n > 255u ? 255u : (uint32_t)n;
  }
  uint64_t ui_ps = lane_rate != 0 ? 1000000000000ull / lane_rate : 0u;
  n = (((uint64_t)settle_ns * 1000u + settle_ui * ui_ps) * mhz + 500000u) / 1000000u;
  n = n > lat ? n - lat : 1u;
  return n > 255u ? 255u : (uint32_t)n;
}

/* ID check: true for the D-PHY of this driver's register map version (false:
 * none at DPHY_BASE, or another version, bow_dphy_rx_version()). */
bool bow_dphy_rx_probe(void);
/* The version of the D-PHY's register map (ID[7:0]; DPHY_MAP_VERSION is this
 * driver's), 0 when there is no D-PHY of Bow32 at DPHY_BASE (bus error or no
 * "DPR" in ID[31:8]). */
uint32_t bow_dphy_rx_version(void);

/* Data lanes of the D-PHY (INFO): 1, 2 or 4. */
uint32_t bow_dphy_rx_lanes(void);
/* Kind of PHY I/O (DPHY_AFE_*). */
uint32_t bow_dphy_rx_afe(void);
/* The PHY calibrates its delays itself (Versal BISC, INFO[23]): the delays in
 * use are DLYn [24:16], never a blind code 0; it says when it is ready. */
bool bow_dphy_rx_self_cal(void);
/* lp clock of the PHY timers (MHz, INFO[17:8]). */
uint32_t bow_dphy_rx_lp_mhz(void);

/* TIM0 for the lane rate (bit/s per lane, 0: unknown): SETTLE of
 * bow_dphy_rx_settle() from INFO2, LP_FILTER 2, CLK_SETTLE 150 ns, CLK_MISS =
 * the period of the clock lane activity the clock lane state machine sees,
 * 2^CLK_TOG_DIV byte clocks (8 UI each; TIM1 as it reads), + 3 cycles (40 ns
 * per 2^CLK_TOG_DIV with lane rate 0; at most 255); then CMD.APPLY: false when
 * the D-PHY did not take it. Only while the PHY is off (CSI2RX CTRL.PHY_EN =
 * 0). TIM1 and TIM2 keep their values. */
bool bow_dphy_rx_timing(uint32_t lane_rate);

/* CMD.APPLY: the D-PHY takes the shadow CTRL / TIM0..2; waits until it has
 * (CMD[0] reads 0, a few lp clocks; false after 64 reads: no lp clock?). The
 * fields that change a running lane only while the PHY is off. */
bool bow_dphy_rx_apply(void);
/* CTRL = (CTRL & ~clear) | set, then apply (the DPHY_CTRL_* bits); false:
 * not applied. */
bool bow_dphy_rx_ctrl(uint32_t set, uint32_t clear);
/* lp clock cycles of ns, rounded up (the timers of TIM0..2) */
uint32_t bow_dphy_rx_lp_cycles(uint32_t ns);
/* TIM1.HS_TMO (cycles, 0: no HS watchdog), TIM1.CLK_TOG_DIV (with TIM0.CLK_MISS
 * for it: the lane rate of the last bow_dphy_rx_timing(), CLK_MISS 0 stays 0),
 * TIM2.T_INIT, TIM2.ESC_TMO (64 cycle units), each with an apply. false, and
 * nothing written, when the value does not fit its field (DPHY_TIM*_MAX; for
 * CLK_TOG_DIV also a CLK_MISS above 255), false when not applied.
 * DPHY_TIM1_RESET is the reset value of TIM1, TIM2 resets to 0. */
bool bow_dphy_rx_set_hs_tmo(uint32_t cycles);
bool bow_dphy_rx_set_clk_tog_div(uint32_t div);
bool bow_dphy_rx_set_t_init(uint32_t cycles);
bool bow_dphy_rx_set_esc_tmo(uint32_t units);

/* The v1.x status of the D-PHY in one read each (not polled by the receiver's
 * start / stop): ERR_STATUS, LANE_STOP, CNT_MISC[31:16], CNT_DSK[31:16]. */
typedef struct {
  uint32_t err;       /* ERR_STATUS (DPHY_ERR_*) */
  uint32_t stop;      /* LANE_STOP */
  uint32_t misc;      /* HS_TMO + CLK_LOST + LATE_EOT + ESC_TMO events */
  uint32_t ulps;      /* ULPS entries */
} bow_dphy_rx_v1x_t;
void bow_dphy_rx_v1x(bow_dphy_rx_v1x_t *s);
/* AFE_CTRL.PD = !on; with on, READY within timeout_ms (true). Never during a
 * stream: the Versal adapter restarts XPLL and BISC (the FPGAs come up with
 * PD = 0). */
bool bow_dphy_rx_power(bool on, uint32_t timeout_ms);

/* AFE_STATUS.READY. */
bool bow_dphy_rx_ready(void);
/* READY within timeout_ms. */
bool bow_dphy_rx_wait_ready(uint32_t timeout_ms);
/* CMD.AFE_CAL with CMD.REINIT (the PHY loses its loaded codes, OWN clears,
 * Versal: XPLL lock + BISC + VT tracking again; the lane state machines go
 * back to WaitStop and T_INIT is due again), then READY again within
 * timeout_ms: DPHY_OK and *us = microseconds from the command to READY;
 * DPHY_ENOREINIT if READY did not fall (a PHY without re-init, e.g.
 * UltraScale+), DPHY_ENOTRDY if it did not come back. */
int bow_dphy_rx_reinit(uint32_t timeout_ms, uint32_t *us);

/* Receive path reset of the PHY I/O while the byte clock gate is closed: the
 * AFE's des_rst (step 5 of docs/ip/mipi_rx_arch.md; burst_rst_en_i of the
 * Versal adapter before). Versal: RX_RST of the data slices, the RX FIFOs
 * restart at every gate opening; UltraScale+ (KV260): the ISERDESE3 reset at
 * every gate opening, which aligns its divider. on = 1 after reset; off
 * (CTRL.DES_RST_DIS = 1) only to test, the Huins board broke without it, and
 * the KV260 ISERDESE3 is then never reset. The firmware turns it off only on
 * the Versal build (csi2_test `phy burstrst 0`, CAM_BURST_RST = 0). Applied
 * at once (CMD.APPLY; false: not applied). */
bool bow_dphy_rx_des_rst(bool on);
bool bow_dphy_rx_des_rst_on(void);

/* Delay code 0..DPHY_DLY_MAX of a data lane (UltraScale+: applied at the next
 * HS burst; Versal: loaded at once, the VT tracking of the lane stops). */
void bow_dphy_rx_set_delay(uint32_t lane, uint32_t code);
/* DLYn of a data lane (0 for lane >= DPHY_MAX_LANES). With a self-calibrated
 * PHY read until two reads agree: [24:16] crosses from the lp clock bit by bit
 * while VT tracking may step it (one read can mix two values). */
uint32_t bow_dphy_rx_read_delay(uint32_t lane);
/* Wait until no lane with OWN is pending (its PHY delay equals its CODE);
 * false after timeout_ms (UltraScale+: a code needs a burst). */
bool bow_dphy_rx_wait_delay(uint32_t timeout_ms);
/* The delays of all DPHY_MAX_LANES lanes into d[] (0 for lanes the receiver
 * does not have): self-calibrated PHY the delays in use ([24:16]: the BISC
 * result until a code is loaded), else the codes written. */
void bow_dphy_rx_get_delays(uint32_t *d);
/* "97/112/88/120": the delays of bow_dphy_rx_get_delays() of the first n lanes. */
void bow_dphy_rx_print_delays(uint32_t n);

/* CNT_BURSTn, CNT_CLK, CNT_LPERR (one read each: for polling). */
void bow_dphy_rx_counters(bow_dphy_rx_cnt_t *c);
/* The counters above with LANE_LP and LANE_HS as one snapshot (for printing):
 * read until two reads of them all agree, at most 9 times. */
void bow_dphy_rx_snapshot(bow_dphy_rx_cnt_t *c, uint32_t *lp, uint32_t *hs);
/* Clear CNT_* (CMD.CNT_CLR), ERR_STATUS and ERR_LANE. */
void bow_dphy_rx_clear(void);

/* 64 raw PHY words (byte k of w[i] = lane k, bit 0 received first), from when
 * lane 0 enters HS, or at once (now). */
bool bow_dphy_rx_raw(uint32_t *w, bool now, uint32_t timeout_ms);

/* Byte clock frequency: maximum of BYTECLK over timeout_ms (at least one
 * read). The register only counts bursts longer than ~2 x 256 CPU cycles. */
uint32_t bow_dphy_rx_byteclk_hz(uint32_t timeout_ms);

#endif /* BOW_DPHY_RX_H_ */
