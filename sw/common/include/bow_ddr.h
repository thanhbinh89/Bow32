/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * DDR2 / DDR3 SDRAM IP (bow_ddr v2, docs/ip/ddr.md): driver of the Bow32
 * side, the PHY and bus bridge registers.
 *
 * The IP is a LiteDRAM controller (bank machines, refresh, DFII, BIST,
 * native port; generated cores in hw/ip/ddr/litedram) in front of the
 * Bow32 PHY. Three bus slots:
 *
 *   BOW32_DDR_PHY_BASE   these registers (bow_ddr_regs): IP info, PHY
 *                        configuration (CTRL, LAT), read / write phase
 *                        steppers, raw read capture, counters, errors.
 *   BOW32_DDR_CTRL_BASE  the CSRs of the LiteDRAM core (DFII, BIST,
 *                        init_done), through the bow_ddr_csr bridge. Used
 *                        by the LiteDRAM glue of sw/apps/ddr
 *                        (sw/common/litedram/bow_litedram.h), not here.
 *   BOW32_DDR_BASE       the memory window on the main bus (512 MiB decode,
 *                        the DRAM size is real, beyond it a bus error).
 *                        Usable when STATUS.READY = 1: the firmware handed
 *                        the trained DRAM over to the controller.
 *
 * The PHY runs in the DDR clock domain (CK, e.g. 133.33 MHz); commands
 * cross it with a request / acknowledge handshake:
 *
 *   CMD      one bit per write. STATUS.BUSY reads 1 until the ddr side has
 *            done it; a refused command sets STATUS.CMD_ERR (two bits,
 *            BUSY, no DDR clock). APPLY copies CTRL and LAT into the ddr
 *            domain once the PHY is idle: their bits act from then on,
 *            except CTRL.CORE_RST, REF_NORM, REF_MON and LOCK, which act
 *            at once.
 *   window   CPU loads / stores, one native word of the controller (one BL8
 *            burst: 8 bytes x8, 16 bytes x16) per access. Without DM pins
 *            every store is a read-modify-write of that word (ST_RMW).
 *
 * Every wait has a timeout; no function touches the hardware unless it is
 * called. Functions return false on a refused command, an error flag or a
 * timeout.
 */
#ifndef BOW_DDR_H_
#define BOW_DDR_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t ID;         /* 0x000 R   0x44445202 ("DDR" v2: LiteDRAM controller) */
  volatile uint32_t INFO;       /* 0x004 R   DDR_INFO_* */
  volatile uint32_t CTRL;       /* 0x008 RW  DDR_CTRL_* (acts after APPLY; CORE_RST, REF_*, LOCK at once) */
  volatile uint32_t CMD;        /* 0x00C W   one DDR_CMD_* per write */
  volatile uint32_t STATUS;     /* 0x010 R/W1C DDR_ST_* */
  volatile uint32_t IRQ_EN;     /* 0x014 RW  DDR_ST_W1C bits */
  uint32_t reserved0;           /* 0x018 */
  volatile uint32_t LAT;        /* 0x01C RW  DDR_LAT_* (acts after APPLY) */
  uint32_t reserved1[4];        /* 0x020 */
  volatile uint32_t PS_TARGET;  /* 0x030 RW  [15:0] signed read phase target */
  volatile uint32_t PS_NOW;     /* 0x034 R   [15:0] signed read phase [31:16] steps / CK */
  uint32_t reserved2[7];        /* 0x038 */
  volatile uint32_t WPS_TARGET; /* 0x054 RW  [15:0] signed write phase target (+-steps / 4) */
  volatile uint32_t WPS_NOW;    /* 0x058 R   [15:0] signed write phase */
  uint32_t reserved3[15];       /* 0x05C */
  volatile uint32_t EMU;        /* 0x098 R   [4:0] log2 of the emulator storage, 0 = none */
  volatile uint32_t CLK_HZ;     /* 0x09C R   DDR clock CK (exact) */
  volatile uint32_t ST_RD;      /* 0x0A0 R   native reads of the window (an RMW counts), SNAP copy */
  volatile uint32_t ST_WR;      /* 0x0A4 R   native writes of the window */
  volatile uint32_t ST_ACT;     /* 0x0A8 R   ACT commands to the DRAM */
  volatile uint32_t ST_REF;     /* 0x0AC R   REF commands to the DRAM */
  volatile uint32_t ST_RMW;     /* 0x0B0 R   window read-modify-write sequences */
  volatile uint32_t DBG;        /* 0x0B4 R   board debug word (asynchronous) */
  volatile uint32_t ERR_ADDR;   /* 0x0B8 R   bus address of the last failed window access */
  volatile uint32_t ST_RGAP;    /* 0x0BC R   longest REF interval with REF_MON (CK cycles - 1), SNAP copy */
  uint32_t reserved4[16];       /* 0x0C0 */
  volatile uint32_t CAP[32];    /* 0x100 R   raw DQ capture: DQ bits rise, next DQ bits fall */
  volatile uint32_t CAPS[32];   /* 0x180 R   raw DQS capture: [1:0] lane 0 {fall, rise} [3:2] lane 1 */
} bow_ddr_regs_t;

_Static_assert(__builtin_offsetof(bow_ddr_regs_t, ID) == 0x000, "DDR ID offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, INFO) == 0x004, "DDR INFO offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, CTRL) == 0x008, "DDR CTRL offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, CMD) == 0x00C, "DDR CMD offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, STATUS) == 0x010, "DDR STATUS offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, IRQ_EN) == 0x014, "DDR IRQ_EN offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, LAT) == 0x01C, "DDR LAT offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, PS_TARGET) == 0x030, "DDR PS_TARGET offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, PS_NOW) == 0x034, "DDR PS_NOW offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, WPS_TARGET) == 0x054, "DDR WPS_TARGET offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, WPS_NOW) == 0x058, "DDR WPS_NOW offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, EMU) == 0x098, "DDR EMU offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, CLK_HZ) == 0x09C, "DDR CLK_HZ offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, ST_RD) == 0x0A0, "DDR ST_RD offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, ST_RMW) == 0x0B0, "DDR ST_RMW offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, DBG) == 0x0B4, "DDR DBG offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, ERR_ADDR) == 0x0B8, "DDR ERR_ADDR offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, ST_RGAP) == 0x0BC, "DDR ST_RGAP offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, CAP) == 0x100, "DDR CAP offset");
_Static_assert(__builtin_offsetof(bow_ddr_regs_t, CAPS) == 0x180, "DDR CAPS offset");
_Static_assert(sizeof(bow_ddr_regs_t) == 0x200, "DDR register block size");

#define DDR ((bow_ddr_regs_t *)BOW32_DDR_PHY_BASE)

/* Register access of the driver and of sw/apps/ddr: BOW_DDR_RD(STATUS),
 * BOW_DDR_WR(CMD, DDR_CMD_APPLY). A host test build defines both to a
 * model of the IP before including this header. */
#ifndef BOW_DDR_RD
#define BOW_DDR_RD(reg)    (DDR->reg)
#define BOW_DDR_WR(reg, v) (DDR->reg = (uint32_t)(v))
#endif

#define DDR_ID_VALUE    0x44445202u
#define DDR_ID_VALUE_V1 0x44445201u /* the v1 IP (own controller): not supported */

/* INFO (synthesis parameters) */
#define DDR_INFO_DQ(i)        ((i) & 0x1Fu)               /* DQ pins: 8 or 16 */
#define DDR_INFO_LANES(i)     ((((i) >> 5) & 3u) + 1u)    /* byte lanes (DQS / DM pins) */
#define DDR_INFO_ADDR_PINS(i) ((((i) >> 7) & 0xFu) + 1u)  /* A[n-1:0] */
#define DDR_INFO_BANK_PINS(i) ((((i) >> 11) & 3u) + 1u)   /* BA[n-1:0] */
#define DDR_INFO_HAS_DM       (1u << 13)
#define DDR_INFO_PHY(i)       (((i) >> 14) & 3u)          /* DDR_PHY_* */
#define DDR_INFO_MHZ(i)       (((i) >> 16) & 0xFFu)       /* rounded, display only */
#define DDR_INFO_EN           (1u << 24)                  /* 0: bow_ddr_stub (DdrEn = 0) */
#define DDR_INFO_HAS_RESET_N  (1u << 25)                  /* DDR3 RESET# pin */
#define DDR_INFO_DDR3         (1u << 26)                  /* LiteDRAM DDR3 core, else DDR2 */
#define DDR_INFO_RD_LAT(i)    (((i) >> 27) & 0x1Fu)       /* DFI read latency (controller cycles) */

#define DDR_PHY_NONE     0u
#define DDR_PHY_PADS     1u /* real pads */
#define DDR_PHY_LOOPBACK 2u /* pads + on-chip DRAM emulator (bow_ddr_lb) */

/* Column bits of both LiteDRAM cores (the DRAM size follows from INFO) */
#define DDR_COL_BITS 10u

/* CTRL: the bits act after an APPLY; CORE_RST, REF_NORM, REF_MON and LOCK at once */
#define DDR_CTRL_EN         (1u << 0)  /* PHY passes the DFI commands; CKE / ODT / RESET# follow DFI */
#define DDR_CTRL_DM_EN      (1u << 4)  /* DM pins (only with INFO.HAS_DM): masked window stores */
#define DDR_CTRL_DDR3       (1u << 5)  /* PHY in DDR3 mode (= INFO.DDR3) */
#define DDR_CTRL_IDLE_DRIVE (1u << 6)  /* drive DQ / DQS outside reads (level shifters) */
#define DDR_CTRL_LS_EN      (1u << 7)  /* level shifter OE# low */
#define DDR_CTRL_ODT_EN     (1u << 10) /* ODT pin = DFI odt (else held low) */
#define DDR_CTRL_CK_EN      (1u << 11) /* CK toggles */
#define DDR_CTRL_CORE_RST   (1u << 12) /* LiteDRAM core + window / CSR bridges in reset, clears BROKEN */
#define DDR_CTRL_REF_NORM   (1u << 13) /* the core refreshes every 7.8 us, Tc <= 85 C (0: 3.9 us) */
#define DDR_CTRL_REF_MON    (1u << 14) /* refresh monitor: REF_STARVE after 8 intervals without REF */
#define DDR_CTRL_LOCK       (1u << 15) /* configuration frozen until the SoC reset (bow_ddr_lock) */
#define DDR_CTRL_RESET      0x00000040u

/* CMD: exactly one bit per write */
#define DDR_CMD_APPLY      (1u << 0) /* take CTRL and LAT */
#define DDR_CMD_PS_GO      (1u << 1) /* step the read phase to PS_TARGET */
#define DDR_CMD_RFIFO_SYNC (1u << 4) /* flush and restart the read FIFO */
#define DDR_CMD_SNAP       (1u << 5) /* copy the counters into ST_* */
#define DDR_CMD_CLR_STATS  (1u << 6)
#define DDR_CMD_WPS_GO     (1u << 7) /* step the write phase to WPS_TARGET */
#define DDR_CMD_CAP_ARM    (1u << 8) /* the next RD to the DRAM fills CAP / CAPS */

/* STATUS (W1C bits: DDR_ST_W1C) and IRQ_EN */
#define DDR_ST_BUSY         (1u << 0)  /* R: command pending */
#define DDR_ST_READY        (1u << 1)  /* R: link, !CORE_RST, init_done, !init_error, !BROKEN */
#define DDR_ST_CLK_OK       (1u << 2)  /* R: link up and the DDR clock runs */
#define DDR_ST_APPLIED      (1u << 3)
#define DDR_ST_PS_DONE      (1u << 5)  /* PS_GO / WPS_GO done (also when refused) */
#define DDR_ST_CAP_DONE     (1u << 6)  /* raw capture complete */
#define DDR_ST_CMD_ERR      (1u << 9)  /* a CMD was refused */
#define DDR_ST_RFIFO_ERR    (1u << 10) /* read FIFO over / underflow */
#define DDR_ST_BUS_TIMEOUT  (1u << 11) /* window access timed out (BROKEN) */
#define DDR_ST_DBG_ERR      (1u << 12) /* R: DBG[31] */
#define DDR_ST_LINK         (1u << 13) /* R */
#define DDR_ST_PS_ERR       (1u << 14) /* phase target refused or PSDONE timeout */
#define DDR_ST_RFIFO_BROKEN (1u << 15) /* R: until RFIFO_SYNC */
#define DDR_ST_INIT_DONE    (1u << 16) /* R: LiteDRAM ddrctrl init_done */
#define DDR_ST_INIT_ERROR   (1u << 17) /* R: LiteDRAM ddrctrl init_error */
#define DDR_ST_RD_LATE      (1u << 18) /* read data not there at the DFI read latency */
#define DDR_ST_RD_EXTRA     (1u << 19) /* read burst from the PHY without a pending read */
#define DDR_ST_NOT_READY    (1u << 20) /* window access while !READY */
#define DDR_ST_RANGE        (1u << 21) /* window access beyond the DRAM size */
#define DDR_ST_CSR_ERR      (1u << 22) /* LiteDRAM CSR access failed */
#define DDR_ST_BROKEN       (1u << 23) /* R: a bridge timed out (until CORE_RST / link reset) */
#define DDR_ST_REF_STARVE   (1u << 24) /* refresh monitor: 8 REF intervals without a REF */
#define DDR_ST_LOCK_ERR     (1u << 25) /* a change refused by CTRL.LOCK */
#define DDR_ST_W1C          0x037C4E68u
#define DDR_ST_ERRORS       (DDR_ST_CMD_ERR | DDR_ST_RFIFO_ERR | DDR_ST_BUS_TIMEOUT | DDR_ST_PS_ERR | \
                             DDR_ST_RD_LATE | DDR_ST_RD_EXTRA | DDR_ST_CSR_ERR | DDR_ST_REF_STARVE | \
                             DDR_ST_LOCK_ERR)

/* LAT */
#define DDR_LAT_RL(n)        ((uint32_t)(n) & 0x3Fu)          /* AL + CL */
#define DDR_LAT_WL(n)        (((uint32_t)(n) & 0x3Fu) << 6)   /* DDR2 RL - 1, DDR3 AL + CWL */
#define DDR_LAT_RD_DLY(n)    (((uint32_t)(n) & 0x1Fu) << 12)  /* read data delay (calibration) */
#define DDR_LAT_RD_SLIP      (1u << 17)                       /* data start on a falling edge */
#define DDR_LAT_OE_PRE(n)    (((uint32_t)(n) & 3u) << 18)
#define DDR_LAT_RDIR_LEAD(n) (((uint32_t)(n) & 0xFu) << 20)
#define DDR_LAT_RDIR_TAIL(n) (((uint32_t)(n) & 0xFu) << 24)
#define DDR_LAT_OE_POST(n)   (((uint32_t)(n) & 0xFu) << 28)
#define DDR_LAT_RD_MASK      ((0x1Fu << 12) | DDR_LAT_RD_SLIP)
#define DDR_LAT_GET_RL(l)     ((l) & 0x3Fu)
#define DDR_LAT_GET_WL(l)     (((l) >> 6) & 0x3Fu)
#define DDR_LAT_GET_RD_DLY(l) (((l) >> 12) & 0x1Fu)
#define DDR_LAT_GET_SLIP(l)   (((l) >> 17) & 1u)
#define DDR_LAT_RESET        0x22240083u

/* PS_NOW / WPS_NOW */
#define DDR_PS_PHASE(v) ((int32_t)(int16_t)((v) & 0xFFFFu))
#define DDR_PS_STEPS(v) ((v) >> 16)

/* DBG word of the emulator / DV model */
#define DDR_DBG_ERR       (1u << 31) /* error count != 0 */
#define DDR_DBG_INIT_DONE (1u << 30)
#define DDR_DBG_CODE(d)   (((d) >> 16) & 0xFFu)
#define DDR_DBG_COUNT(d)  ((d) & 0xFFFFu)

#define DDR_EMU_LOG2(e) ((e) & 0x1Fu)

/* ------------------------------------------------------------------ info */
typedef struct {
  uint32_t id, info;      /* registers (0 when the probe failed) */
  bool bus_error;         /* nothing answers at BOW32_DDR_PHY_BASE */
  bool ddr3;              /* LiteDRAM DDR3 core (INFO.DDR3), else DDR2 */
  uint32_t dq_bits;       /* 8 or 16 */
  uint32_t lanes, addr_pins, bank_pins;
  bool has_dm, has_reset_n;
  uint32_t phy;           /* DDR_PHY_* */
  uint32_t clk_hz;        /* DDR clock CK; the controller runs at CK / 4 */
  uint32_t ps_steps;      /* fine phase steps per CK period */
  uint32_t emu_log2;      /* emulator storage log2(bytes), 0 = no emulator */
  uint32_t rd_lat;        /* DFI read latency of the controller (cycles of CK / 4) */
  uint32_t word_bytes;    /* native word = one BL8 burst: 8 (x8) or 16 (x16) */
  uint32_t mem_log2;      /* DRAM size: DQ / 8 * 2^(rows + banks + 10 columns) */
  uint32_t test_log2;     /* memory the tests may use: the DRAM, cut to the emulator */
} bow_ddr_info_t;

/* True when a bow_ddr v2 with DdrEn = 1 answers. info (may be NULL) is
 * filled in any case (bus_error, id, info) so the caller can say why not. */
bool bow_ddr_probe(bow_ddr_info_t *info);

/* ---------------------------------------------------------- configuration */
/* PHY configuration (CTRL, LAT). The JEDEC timing is the LiteDRAM core's
 * (fixed when it is generated); RL / WL must equal its CL / CWL (AL 0). */
typedef struct {
  bool ddr3;                         /* CTRL.DDR3 */
  uint8_t rl, wl;                    /* DDR2 CL / CL - 1, DDR3 CL / CWL */
  /* board: level shifters between FPGA and DRAM (docs/ip/ddr.md, PHY) */
  bool idle_drive, ls_en;            /* drive DQ / DQS outside reads, shifters on */
  uint8_t rdir_lead, rdir_tail;      /* DIR -> read this many cycles before RL, back after */
  uint8_t oe_pre, oe_post;           /* FPGA output off before DIR, on again after */
  bool dm_en, odt_en;                /* DM pins (INFO.HAS_DM), ODT pin (off: card Rtt off, DLL-off) */
} bow_ddr_config_t;

/* Defaults for the IP found by bow_ddr_probe: DDR2 = the FMC card (ISSI
 * IS43DR86400E, CL 3, TXV0108 level shifters: RL 3 WL 2, LAT reset value
 * 0x22240083), DDR3 = x16 DLL-off (CL = CWL = 6, no level shifters). */
void bow_ddr_config_for(const bow_ddr_info_t *info, bow_ddr_config_t *c);
/* CTRL (with EN and CK_EN) and LAT (RD_DLY 0, no SLIP) of a configuration */
uint32_t bow_ddr_config_ctrl(const bow_ddr_config_t *c, const bow_ddr_info_t *info);
uint32_t bow_ddr_config_lat(const bow_ddr_config_t *c);

/* ------------------------------------------------------------- commands */
/* One CMD bit; waits while BUSY. False: refused (CMD_ERR), no APPLIED /
 * PS_DONE, or timeout. */
bool bow_ddr_cmd(uint32_t cmd);
bool bow_ddr_apply(void);
bool bow_ddr_rfifo_sync(void);
/* CTRL (or LAT) and APPLY */
bool bow_ddr_set_ctrl(uint32_t ctrl);
bool bow_ddr_set_lat(uint32_t lat);
/* CTRL.CORE_RST on / off (APPLY). On also turns the refresh monitor off
 * (REF_MON: the core no longer refreshes). Off: waits up to 1 ms for the
 * LiteDRAM CSRs to answer again. */
bool bow_ddr_core_reset(bool on);

/* Refresh (CTRL.REF_NORM, REF_MON; they act at once, no APPLY, the other
 * CTRL bits are kept). The LiteDRAM core refreshes every 3.9 us (the JEDEC
 * rate for a DRAM case temperature of 85..95 C); norm = true doubles its
 * refresh period (7.8 us: Tc <= 85 C only; from the next REF). mon = true runs
 * the refresh monitor: STATUS.REF_STARVE after 8 expected REF intervals
 * without a REF at the PHY (eight missed, one before the JEDEC limit), the
 * longest interval in ST_RGAP. False when CTRL does not read the bits back
 * (LOCK: only norm = false is still taken). */
bool bow_ddr_set_refresh(bool norm, bool mon);
/* CTRL.LOCK: from now on CTRL (except clearing REF_NORM), LAT, the phase
 * targets, every command but SNAP / CLR_STATS and every LiteDRAM CSR write
 * are refused (STATUS.LOCK_ERR) until the next SoC reset; the window,
 * IRQ_EN and the STATUS flags still work. True when CTRL reads LOCK. */
bool bow_ddr_lock(void);
bool bow_ddr_locked(void);

/* Read phase (PS_GO) and write phase (WPS_GO): step to target, wait for
 * PS_DONE. False on PS_ERR (beyond the limits: read phase 2 CK periods from
 * the phase of the last RFIFO_SYNC, write phase steps / 4) or timeout. */
bool bow_ddr_ps_set(int32_t target);
bool bow_ddr_wps_set(int32_t target);
int32_t bow_ddr_ps_now(void);
int32_t bow_ddr_wps_now(void);
uint32_t bow_ddr_ps_steps(void);
/* Read phase to target in moves of at most one CK period, each from a fresh
 * RFIFO_SYNC; the read FIFO is synchronised at the target. */
bool bow_ddr_ps_goto_sync(int32_t target);

/* Raw capture: arm (CAP_DONE cleared), then the next RD the PHY sends fills
 * CAP / CAPS with 32 stream cycles from RL - 2; wait for CAP_DONE. */
bool bow_ddr_cap_arm(void);
bool bow_ddr_cap_wait(uint32_t timeout_us);

/* --------------------------------------------------------------- status */
typedef struct {
  uint32_t rd, wr, act, ref, rmw;
  uint32_t rgap;   /* ST_RGAP: longest REF interval with REF_MON, CK cycles - 1 */
} bow_ddr_stats_t;

/* SNAP, then the counters (clear: CLR_STATS afterwards). */
bool bow_ddr_stats(bow_ddr_stats_t *s, bool clear);

bool bow_ddr_ready(void);
uint32_t bow_ddr_word_bytes(void);      /* 8 (x8) or 16 (x16) */
uint32_t bow_ddr_dbg(void);             /* DBG, read until two reads agree */
/* Wait for LINK and CLK_OK (the DDR clocks start late in simulation). */
bool bow_ddr_wait_clk(uint32_t timeout_ms);

/* Registers, phases, counters, error flags, debug word. */
void bow_ddr_print_status(void);

#endif /* BOW_DDR_H_ */
