/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * HyperRAM IP (bow_hyperram, docs/ip/hyperram.md): driver.
 *
 * HyperBus master for HyperRAM 2.0 x8 devices (Infineon S80KS2562, 256 Mb,
 * 1.8 V, on the FMC+_DDR2_HyperRam card behind TXV0108 level shifters). Two
 * bus slots:
 *
 *   BOW32_HYPERRAM_REG_BASE  registers (bow_hyperram_regs): IP info,
 *                            configuration (CTRL, LAT, TIM0, TRST, TWAKE),
 *                            commands, device register access (REG_SEL /
 *                            REG_DATA), phase steppers, raw read capture,
 *                            BIST, statistics, errors.
 *   BOW32_HYPERRAM_BASE      the memory window (256 MiB decode, the device
 *                            size is real, beyond it a bus error), with a
 *                            read buffer (32 byte lines, wrapped bursts) and
 *                            a posted write buffer. Usable when STATUS.READY =
 *                            1 (CTRL.INIT_DONE after bow_hr_init).
 *
 * The controller runs in the HyperRAM clock domain (CK, e.g. 100 MHz);
 * commands cross it with a request / acknowledge handshake:
 *
 *   CMD      one bit per write; STATUS.BUSY reads 1 until it is done, then
 *            STATUS.CMD_DONE or STATUS.CMD_ERR (ERR_CODE[7:0]: why). APPLY
 *            copies CTRL[3:0], LAT, TIM0, TRST and TWAKE into the controller
 *            when it is idle; CTRL[12:8] act at once.
 *   device   REG_RD / REG_WR on the register space (ID0, ID1, CR0, CR1); a
 *            CR0 write also sets the controller's latency (its CR0 shadow),
 *            CR0[15] = 0 enters deep power down, CR1[5] = 1 hybrid sleep;
 *            WAKE leaves both, HW_RESET pulses RESET#.
 *
 * Every wait has a timeout; no function touches the hardware unless it is
 * called. Functions return false on a refused command, an error or a
 * timeout.
 */
#ifndef BOW_HYPERRAM_H_
#define BOW_HYPERRAM_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t ID;         /* 0x000 R   0x48524D01 ("HRM" v1) */
  volatile uint32_t INFO;       /* 0x004 R   HR_INFO_* */
  volatile uint32_t CTRL;       /* 0x008 RW  HR_CTRL_* ([3:0] after APPLY, [12:8] at once) */
  volatile uint32_t CMD;        /* 0x00C W   one HR_CMD_* per write */
  volatile uint32_t STATUS;     /* 0x010 R/W1C HR_ST_* */
  volatile uint32_t IRQ_EN;     /* 0x014 RW  HR_ST_W1C bits */
  volatile uint32_t LAT;        /* 0x018 RW  HR_LAT_* (after APPLY) */
  volatile uint32_t TIM0;       /* 0x01C RW  HR_TIM0_* (after APPLY) */
  volatile uint32_t TRST;       /* 0x020 RW  [15:0] RESET# low, [31:16] wait after (CK cycles) */
  volatile uint32_t TWAKE;      /* 0x024 RW  [15:0] CS# wake pulse, [31:16] wait after (CK cycles) */
  volatile uint32_t REG_SEL;    /* 0x028 RW  HR_REG_* device register of REG_RD / REG_WR */
  volatile uint32_t REG_DATA;   /* 0x02C RW  [15:0] REG_WR data / REG_RD result */
  volatile uint32_t CR0;        /* 0x030 R   controller's CR0 shadow */
  volatile uint32_t CR1;        /* 0x034 R   controller's CR1 shadow */
  volatile uint32_t PS_TARGET;  /* 0x038 RW  [15:0] signed read phase target (fine steps) */
  volatile uint32_t PS_NOW;     /* 0x03C R   [15:0] signed read phase, [31:16] steps per CK */
  volatile uint32_t WPS_TARGET; /* 0x040 RW  [15:0] signed write phase target (|w| <= HR_WPS_LIMIT) */
  volatile uint32_t WPS_NOW;    /* 0x044 R   [15:0] signed write phase, [31:16] steps per CK */
  volatile uint32_t CLK_HZ;     /* 0x048 R   CK */
  volatile uint32_t ERR_ADDR;   /* 0x04C R   bus address of the last window access with an error */
  volatile uint32_t EMU;        /* 0x050 R   [4:0] log2 of the emulator storage, 0 = none */
  volatile uint32_t DBG;        /* 0x054 R   board debug word (emulator: HR_DBG_*) */
  volatile uint32_t ERR_CODE;   /* 0x058 R   [7:0] last command error, [15:8] last transaction error */
  volatile uint32_t WB_TMO;     /* 0x05C RW  [15:0] posted write buffer flush after N idle cycles */
  volatile uint32_t BIST_CTRL;  /* 0x060 RW  HR_BIST_* */
  volatile uint32_t BIST_ADDR;  /* 0x064 RW  first HyperRAM word address */
  volatile uint32_t BIST_LEN;   /* 0x068 RW  words */
  volatile uint32_t BIST_SEED;  /* 0x06C RW */
  volatile uint32_t BIST_CYCLES;/* 0x070 R   CK cycles of the last run */
  volatile uint32_t BIST_ERRS;  /* 0x074 R   mismatching words of the read pass */
  volatile uint32_t BIST_FADDR; /* 0x078 R   word address of the first mismatch */
  volatile uint32_t BIST_FDATA; /* 0x07C R   [15:0] expected, [31:16] read */
  volatile uint32_t ST[16];     /* 0x080 R   statistics (SNAP), HR_STAT_* */
  uint32_t reserved0[16];       /* 0x0C0 */
  volatile uint32_t CAP[64];    /* 0x100 R   raw capture, HR_CAP_* */
} bow_hr_regs_t;

_Static_assert(__builtin_offsetof(bow_hr_regs_t, WB_TMO) == 0x05C, "HR WB_TMO offset");
_Static_assert(__builtin_offsetof(bow_hr_regs_t, ST) == 0x080, "HR ST offset");
_Static_assert(__builtin_offsetof(bow_hr_regs_t, CAP) == 0x100, "HR CAP offset");

#define HR_REGS ((bow_hr_regs_t *)(uintptr_t)BOW32_HYPERRAM_REG_BASE)
#define BOW_HR_RD(r) (HR_REGS->r)
#define BOW_HR_WR(r, v) (HR_REGS->r = (v))

#define HR_ID_VALUE 0x48524D01u

/* INFO */
#define HR_INFO_PHY(i) ((i) & 3u)                 /* 1 pads, 2 loopback emulator, 0 none */
#define HR_INFO_HAS_LS (1u << 2)                  /* level shifter controls (card) */
#define HR_INFO_HR_EN (1u << 3)                   /* 0: stub */
#define HR_INFO_MEM_LOG2(i) ((((i) >> 4) & 0xFu) + 16u)
#define HR_INFO_MHZ(i) (((i) >> 8) & 0xFFu)
#define HR_INFO_LINES(i) ((((i) >> 16) & 7u) + 1u)
#define HR_INFO_LINE_LOG2(i) (((i) >> 20) & 0xFu)
#define HR_INFO_BIST (1u << 24)
#define HR_PHY_PADS 1u
#define HR_PHY_LOOPBACK 2u

/* CTRL */
#define HR_CTRL_EN (1u << 0)
#define HR_CTRL_LS_EN (1u << 1)
#define HR_CTRL_IDLE_DRIVE (1u << 2)
#define HR_CTRL_STRICT (1u << 3)
#define HR_CTRL_INIT_DONE (1u << 8)
#define HR_CTRL_RBUF_EN (1u << 9)
#define HR_CTRL_WRAP_FILL (1u << 10)
#define HR_CTRL_WPOST (1u << 11)
#define HR_CTRL_CORE_RST (1u << 12)

/* CMD */
#define HR_CMD_APPLY (1u << 0)
#define HR_CMD_PS_GO (1u << 1)
#define HR_CMD_WPS_GO (1u << 2)
#define HR_CMD_RFIFO_SYNC (1u << 3)
#define HR_CMD_CAP_ARM (1u << 4)
#define HR_CMD_HW_RESET (1u << 5)
#define HR_CMD_REG_RD (1u << 6)
#define HR_CMD_REG_WR (1u << 7)
#define HR_CMD_WAKE (1u << 8)
#define HR_CMD_FLUSH (1u << 9)
#define HR_CMD_INVAL (1u << 10)
#define HR_CMD_BIST_GO (1u << 11)
#define HR_CMD_BIST_STOP (1u << 12)
#define HR_CMD_SNAP (1u << 13)
#define HR_CMD_CLR_STATS (1u << 14)

/* STATUS */
#define HR_ST_BUSY (1u << 0)
#define HR_ST_READY (1u << 1)
#define HR_ST_CLK_OK (1u << 2)
#define HR_ST_APPLIED (1u << 3)
#define HR_ST_POWER(s) (((s) >> 4) & 3u)          /* HR_PWR_* */
#define HR_ST_BIST_BUSY (1u << 6)
#define HR_ST_BROKEN (1u << 7)
#define HR_ST_CMD_DONE (1u << 8)
#define HR_ST_CMD_ERR (1u << 9)
#define HR_ST_CAP_DONE (1u << 10)
#define HR_ST_BIST_DONE (1u << 11)
#define HR_ST_RD_ERR (1u << 12)
#define HR_ST_WR_ERR (1u << 13)
#define HR_ST_RFIFO_ERR (1u << 14)
#define HR_ST_BUS_TIMEOUT (1u << 15)
#define HR_ST_NOT_READY (1u << 16)
#define HR_ST_RANGE (1u << 17)
#define HR_ST_BIST_ERR (1u << 18)
#define HR_ST_TCSM_ERR (1u << 19)
#define HR_ST_DBG_ERR (1u << 20)
#define HR_ST_RFIFO_BROKEN (1u << 21)
#define HR_ST_WIN_IDLE (1u << 22)
#define HR_ST_W1C 0x000FFF00u

/* ERR_CODE[7:0] (command) / [15:8] (transaction) */
#define HR_ERR_NONE 0u
#define HR_ERR_RD_TMO 1u    /* read data did not start in time */
#define HR_ERR_RWDS 2u      /* RWDS not a strobe (STRICT) */
#define HR_ERR_TCSM 3u      /* longer than TCSM: refused */
#define HR_ERR_POWER 4u     /* device in deep power down / hybrid sleep */
#define HR_ERR_DISABLE 5u   /* EN = 0, no clock, channel in reset */
#define HR_ERR_RFIFO 6u     /* read FIFO broken */
#define HR_ERR_ARG 7u       /* argument refused: malformed CMD, ID0 / ID1 write, reserved CR0
                             * latency code, phase step beyond its limit, BIST_GO during a run */
#define HR_ERR_PS 8u        /* phase step: no PSDONE from the MMCM */
#define HR_PWR_ACTIVE 0u
#define HR_PWR_DPD 1u
#define HR_PWR_HS 2u
#define HR_PWR_WAIT 3u

/* LAT (reset 0x00365522: card at 100 MHz) */
#define HR_LAT(lead, tail, pre, post, rw_dir, rw_oe, arm, dly)                                   \
  ((uint32_t)(lead) | ((uint32_t)(tail) << 4) | ((uint32_t)(pre) << 8) | ((uint32_t)(post) << 10) | \
   ((uint32_t)(rw_dir) << 12) | ((uint32_t)(rw_oe) << 16) | ((uint32_t)(arm) << 20) |            \
   ((uint32_t)(dly) << 24))
#define HR_LAT_RD_DLY(l) (((l) >> 24) & 0x1Fu)
#define HR_LAT_RD_DLY_MASK (0x1Fu << 24)

/* TIM0 */
#define HR_TIM0(tcsm, cshi, lat_smp, rd_tmo, rd_hold)                                            \
  ((uint32_t)(tcsm) | ((uint32_t)(cshi) << 12) | ((uint32_t)(lat_smp) << 16) |                  \
   ((uint32_t)(rd_tmo) << 20) | ((uint32_t)(rd_hold) << 24))
#define HR_TIM0_TCSM(t) ((t) & 0xFFFu)
#define HR_TIM0_RD_HOLD(t) (((t) >> 24) & 3u)

/* write phase limit: +-3/16 of a CK period in phase steps (WPS_NOW[31:16]) */
#define HR_WPS_LIMIT(steps) ((3u * (uint32_t)(steps)) / 16u)

/* device registers */
#define HR_REG_ID0 0u
#define HR_REG_ID1 1u
#define HR_REG_CR0 2u
#define HR_REG_CR1 3u
#define HR_ID0_S80KS2562 0x0E86u
#define HR_ID1_HYPERRAM2 0x0001u
#define HR_CR0_DEFAULT 0x8F2Fu
#define HR_CR0_DPD_N (1u << 15)                   /* 0: enter deep power down */
#define HR_CR0_FIXED (1u << 3)
#define HR_CR1_HS (1u << 5)                        /* 1: enter hybrid sleep */
/* CR0 latency code ([7:4]) for L clocks (3..7) */
#define HR_CR0_LAT_CODE(l) ((l) == 3u ? 0xEu : (l) == 4u ? 0xFu : (l) == 5u ? 0x0u : (l) == 6u ? 0x1u : 0x2u)

/* BIST_CTRL */
#define HR_BIST_WRITE (1u << 0)
#define HR_BIST_READ (1u << 1)
#define HR_BIST_COUNT (1u << 2)                  /* 0: xorshift32 PRBS */
#define HR_BIST_BURST(n) (((uint32_t)(n) & 0xFFu) << 8)

/* statistics ST[] */
#define HR_STAT_RD_TXN 0u
#define HR_STAT_WR_TXN 1u
#define HR_STAT_RD_WORDS 2u
#define HR_STAT_WR_WORDS 3u
#define HR_STAT_LAT2X 4u
#define HR_STAT_REG 5u
#define HR_STAT_FAILED 6u
#define HR_STAT_BIST_TXN 7u
#define HR_STAT_HITS 8u
#define HR_STAT_MISSES 9u
#define HR_STAT_FLUSHES 10u

/* CAP[i]: stream cycle i from the controller cycle of t = 0 */
#define HR_CAP_DQ_R(c) ((c) & 0xFFu)
#define HR_CAP_DQ_F(c) (((c) >> 8) & 0xFFu)
#define HR_CAP_RWDS_R(c) (((c) >> 16) & 1u)
#define HR_CAP_RWDS_F(c) (((c) >> 17) & 1u)

/* DBG of the loopback emulator */
#define HR_DBG_ERR (1u << 31)
#define HR_DBG_CODE(d) (((d) >> 16) & 0xFFu)
#define HR_DBG_COUNT(d) ((d) & 0xFFFFu)

/* ------------------------------------------------------------------- driver */
typedef struct {
  uint32_t id, info;
  bool present;          /* ID matches and INFO.HR_EN */
  bool bus_error;        /* the register slot answered a bus error */
  uint32_t phy;          /* HR_PHY_* */
  bool has_ls;
  uint32_t mem_bytes;    /* device size of the build */
  uint32_t clk_hz;       /* CK */
  uint32_t ps_steps;     /* fine phase steps per CK */
  uint32_t emu_bytes;    /* loopback emulator storage, 0 = none */
  uint32_t test_bytes;   /* bytes the tests may use: min(emulator, device) */
  uint32_t lines;        /* read buffer lines */
} bow_hr_info_t;

typedef struct {
  uint32_t lat;          /* L, clocks (3..7) */
  bool fixed;            /* fixed 2x latency (the card) */
  uint32_t drive;        /* CR0[14:12] */
  uint32_t ctrl;         /* CTRL bits [3:0] and [11:9] */
  uint32_t lat_reg;      /* LAT (RD_DLY from the calibration) */
  uint32_t tim0;         /* TIM0 (TCSM from CR1) */
} bow_hr_config_t;

typedef struct {
  int32_t phase;         /* chosen read phase (fine steps) */
  uint32_t width;        /* eye width (fine steps) */
  uint32_t points;       /* phase points tried, good */
  uint32_t good;
  uint32_t rd_dly;       /* LAT.RD_DLY */
  uint32_t first_half;   /* capture half cycle of the first byte A at the chosen phase */
  int32_t wphase;        /* write phase (0 unless calibrated) */
  uint32_t wwidth;
} bow_hr_cal_t;

typedef struct {
  uint32_t cycles, errors, faddr, fdata;
  bool done, ok;
} bow_hr_bist_res_t;

bool bow_hr_probe(bow_hr_info_t *info);
bool bow_hr_wait_clk(uint32_t ms);                 /* CLK_OK within ms */
bool bow_hr_cmd(uint32_t cmd);                     /* one HR_CMD_*, wait CMD_DONE / CMD_ERR */
bool bow_hr_apply(void);
bool bow_hr_ready(void);                           /* STATUS.READY */
void bow_hr_config_for(const bow_hr_info_t *info, bow_hr_config_t *cfg);
bool bow_hr_enable(const bow_hr_config_t *cfg);    /* CTRL / LAT / TIM / TRST / TWAKE, APPLY */
bool bow_hr_reset(void);                           /* RESET# pulse + recovery */
bool bow_hr_reg_read(uint32_t sel, uint16_t *v);
bool bow_hr_reg_write(uint32_t sel, uint16_t v);
uint32_t bow_hr_td(void);                          /* first data cycle of a read (CR0 shadow) */
bool bow_hr_set_phase(int32_t phase);              /* read phase (PS_GO) */
bool bow_hr_set_wphase(int32_t phase);             /* write phase (WPS_GO) */
int32_t bow_hr_phase_now(void);
int32_t bow_hr_wphase_now(void);
bool bow_hr_rfifo_sync(void);
/* Capture of one device register read (and the read itself): cap[64]. Returns
 * whether the capture was taken; *read_ok whether the read worked (*value is 0
 * otherwise). Either pointer may be NULL. */
bool bow_hr_capture_reg(uint32_t sel, uint32_t *cap, uint16_t *value, bool *read_ok);
/* Half cycle index of the first byte A in a capture (RWDS high for one
 * sample after two low ones, from half cycle 2 * from on), -1 if none. */
int32_t bow_hr_cap_first_a(const uint32_t *cap, uint32_t from);
/* Read calibration: phase sweep with captured ID0 reads and a memory pattern,
 * eye centre, RD_DLY; verbose prints the eye map. */
bool bow_hr_calibrate(uint32_t step, bool verbose, bow_hr_cal_t *cal);
/* Write phase scan (card): pattern writes / reads through the window. */
bool bow_hr_calibrate_write(uint32_t step, bool verbose, bow_hr_cal_t *cal);
/* Device configuration: CR0 latency / fixed / drive, CR1 -> TCSM; APPLY. */
bool bow_hr_configure(bow_hr_config_t *cfg);
/* Whole bring-up: enable, reset, calibrate, configure, window open. */
bool bow_hr_init(const bow_hr_info_t *info, bow_hr_config_t *cfg, bow_hr_cal_t *cal, bool verbose);
void bow_hr_window(bool rbuf, bool wrap, bool posted); /* CTRL[11:9] */
bool bow_hr_flush(void);
bool bow_hr_inval(void);
bool bow_hr_bist(uint32_t waddr, uint32_t words, uint32_t burst, uint32_t mode, uint32_t seed,
                 bow_hr_bist_res_t *res);
uint32_t bow_hr_bist_burst_max(void);              /* longest burst that fits TCSM */
bool bow_hr_hybrid_sleep(void);
bool bow_hr_deep_power_down(void);
bool bow_hr_wake(void);
bool bow_hr_snap(uint32_t st[16]);
void bow_hr_print_status(void);
const char *bow_hr_err_name(uint32_t code);

#endif /* BOW_HYPERRAM_H_ */
