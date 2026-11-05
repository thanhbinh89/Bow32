/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * LiteDRAM controller glue of bow_ddr v2 (docs/ip/ddr.md), used by
 * sw/apps/ddr only: JEDEC init over the DFII, read / write calibration of
 * the Bow32 PHY, hand-over to the controller, LiteDRAM BIST.
 *
 * The LiteDRAM CSRs (BOW32_DDR_CTRL_BASE, through the bow_ddr_csr bridge)
 * are those of the generated core: hw/ip/ddr/litedram/generated/<core>/
 * include/generated/csr.h, one map for both cores. bow_litedram.c is
 * compiled against the DDR2 core's headers and uses only what the cores
 * share (CSR map, DFII command bits); bow_litedram_ddr2.c / _ddr3.c hold
 * what differs (init_sequence() of each sdram_phy.h, CL, CWL, size), chosen
 * by INFO.DDR3. sw/common/litedram/include has stand-ins for the two LiteX
 * headers the generated ones include (system.h, hw/common.h).
 *
 * DFII: LiteDRAM's DFI injector sits between the controller and the DFI.
 * In hardware control (dfii_control = SEL | CKE | ODT | RESET_N) the
 * controller drives the DRAM: refresh (PREA + REF every tREFI, DDR3 also a
 * ZQCS per second), the native port (the window) once ddrctrl init_done = 1,
 * the BIST. In software control the CPU issues single commands on a phase
 * (pi<n>_address / baddress / command, then command_issue), the burst in
 * the four pi<n>_wrdata / pi<n>_rddata registers (phase n carries bytes
 * n * W / 4 .. (n + 1) * W / 4 - 1 of the native word of W bytes, little
 * endian), and nothing refreshes the DRAM: the DRAM emulator and the DV
 * model flag REF_STARVE after 9 x tREFI (70 us). So once the DRAM is
 * initialised the glue works in short software sections (PREA + REF, a few
 * commands with the bank closed again at the end, back to hardware control;
 * no print inside); bow_ld_sw_max_us() reports the longest one. After the
 * hand-over the controller's bank machines may hold rows open: a section
 * then needs bow_ld_quiesce() first (init_done = 0, wait until a refresh
 * closed them), bow_ld_release() afterwards.
 *
 * Bring-up (sw/apps/ddr does exactly this):
 *
 *   bow_ddr_info_t info;  bow_ddr_config_t cfg;  bow_ld_cal_t cal;
 *   if (!bow_ddr_probe(&info)) { ... no IP, or the stub (DdrEn = 0) ... }
 *   bow_ddr_config_for(&info, &cfg);     // card DDR2 / DDR3 DLL-off
 *   bow_ld_init(&cfg, true);             // power-up, JEDEC init, refresh on
 *   bow_ld_calibrate(4, true, &cal);     // read eye, RD_DLY, hand-over, BIST
 *   ... memory at BOW32_DDR_BASE (STATUS.READY) ...
 */
#ifndef BOW_LITEDRAM_H_
#define BOW_LITEDRAM_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow_ddr.h"

/* -------------------------------------------------------------- the core */
typedef struct {
  const char *name;            /* "DDR2", "DDR3" */
  bool ddr3;
  uint32_t databits, phases;   /* SDRAM_PHY_DATABITS (DQ), SDRAM_PHY_PHASES (4) */
  uint32_t cl, cwl;            /* SDRAM_PHY_CL / SDRAM_PHY_CWL */
  uint32_t rdphase, wrphase;   /* DFI phase of READ / WRITE commands */
  uint32_t mem_bytes;          /* SDRAM_PHY_SUPPORTED_MEMORY */
  uint32_t ctrl_hz;            /* CONFIG_CLOCK_FREQUENCY: the CK / 4 the core was made for */
  uint32_t trefi_cycles;       /* controller cycles (CK / 4) from one REF to the next: TRefi
                                  of the generated litedram_<core>_pkg.sv (not in its C headers) */
  void (*init_sequence)(void); /* init_sequence() of the generated sdram_phy.h */
} bow_ld_core_t;

extern const bow_ld_core_t bow_ld_core_ddr2, bow_ld_core_ddr3;

/* The core of the IP: DDR3 when INFO.DDR3, else DDR2 */
const bow_ld_core_t *bow_ld_core(const bow_ddr_info_t *info);

/* ------------------------------------------------------------------- CSR */
/* Bus-error safe CSR access (bow_probe): a failed access returns 0 /
 * does nothing and counts in bow_ld_csr_faults (STATUS.CSR_ERR is set). */
extern uint32_t bow_ld_csr_faults;
uint32_t bow_ld_csr_read(uint32_t addr);
void bow_ld_csr_write(uint32_t addr, uint32_t value);
/* The CSR bridge answers (link up, core out of reset): one probe read. */
bool bow_ld_csr_ok(void);

/* ------------------------------------------------------------------ DFII */
#define BOW_LD_DFII_SEL 0x01u                /* dfii_control: hardware control */
#define BOW_LD_DFII_CKE 0x02u
#define BOW_LD_DFII_SW  0x0Eu                /* software control, CKE ODT RESET_N high */
#define BOW_LD_DFII_HW  0x0Fu                /* hardware control (the hand-over value) */

/* DRAM commands in DFII command bits (pi<n>_command: CS 0x01, WE 0x02,
 * CAS 0x04, RAS 0x08, WRDATA 0x10, RDDATA 0x20) */
#define BOW_LD_CMD_PINS 0x0Fu                /* RAS CAS WE CS: the command on the pins */
#define BOW_LD_CMD_MRS  0x0Fu
#define BOW_LD_CMD_REF  0x0Du
#define BOW_LD_CMD_PRE  0x0Bu                /* A10 = 1: all banks */
#define BOW_LD_CMD_ACT  0x09u
#define BOW_LD_CMD_WR   0x17u
#define BOW_LD_CMD_RD   0x25u
#define BOW_LD_CMD_ZQ   0x03u                /* A10 = 1: ZQCL */
#define BOW_LD_CMD_NOP  0x01u
#define BOW_LD_A10      0x400u

uint32_t bow_ld_dfii_control(void);

/* Software sections by hand (bow_ld_burst_* do one each): begin = DFII
 * software control (CKE ODT RESET_N high), 1 us for a command the
 * controller just issued, with refresh: PREA + REF; end = hardware control.
 * In between: bow_ld_dfii_cmd on a phase (READ / WRITE on the core's
 * rdphase / wrphase), bow_ld_dfii_wrdata before a WR, bow_ld_dfii_rddata
 * after a RD (+ 1 us: read latency). Rules: below ~50 us (refresh), every
 * bank closed again before the end, no print; after the hand-over only
 * between bow_ld_quiesce and bow_ld_release. */
void bow_ld_sw_begin(bool refresh);
void bow_ld_sw_end(void);
void bow_ld_dfii_cmd(uint32_t phase, uint32_t cmd, uint32_t ba, uint32_t a); /* BOW_LD_CMD_* */
void bow_ld_dfii_wrdata(const uint8_t *burst); /* native word -> pi0..pi3 wrdata */
void bow_ld_dfii_rddata(uint8_t *burst);       /* pi0..pi3 rddata -> native word */

/* One burst by DFII in one software section (PREA + REF first, the bank
 * closed again at the end): ACT row, WR / RD at column col (a multiple of
 * 8) on the WRITE / READ phase of the core, PRE. burst: the native word
 * (word_bytes; NULL: read without data). cap: raw capture of the read
 * (CAP_ARM before, CAP_DONE after). Needs bow_ld_init(); after the
 * hand-over only between bow_ld_quiesce() and bow_ld_release(). */
bool bow_ld_burst_write(uint32_t ba, uint32_t row, uint32_t col, const uint8_t *burst);
bool bow_ld_burst_read(uint32_t ba, uint32_t row, uint32_t col, uint8_t *burst, bool cap);

/* Longest software section since the last clear, in microseconds */
uint32_t bow_ld_sw_max_us(void);
void bow_ld_sw_max_clear(void);

/* ------------------------------------------------------------- bring-up */
/* Leave a running DRAM in a state a new init can start from: native port
 * blocked (init_done = init_error = 0), rows closed (PREA), DFII software
 * control with CKE / ODT / RESET_N low, CTRL.EN = 0 (PHY drops commands,
 * CKE / RESET# pins low). */
bool bow_ld_stop(void);

/* bow_ld_stop, CORE_RST pulse, then: DFII software control (CKE, RESET#
 * low), CTRL / LAT of the configuration (RD_DLY 0) with EN, power-up wait
 * (DDR2 200 us CKE low with CK running, DDR3 200 us RESET# low), the
 * generated init_sequence() of the core (cdelay: 25 ns per count), 1024 nCK
 * (tZQinit / tDLLK), DFII hardware control (refresh on; native port still
 * blocked). verbose prints the configuration and the command trace. */
bool bow_ld_init(const bow_ddr_config_t *c, bool verbose);
bool bow_ld_inited(void);

/* Commands of the last init sequence (DFII trace) */
typedef struct {
  uint8_t kind;    /* 'c': dfii_control write (value in cmd), 'x': command issued */
  uint8_t phase;
  uint8_t cmd;     /* DFII command bits (BOW_LD_CMD_*) or the control value */
  uint8_t ba;
  uint16_t a;
} bow_ld_trace_t;

#define BOW_LD_TRACE_MAX 24u
uint32_t bow_ld_init_trace(const bow_ld_trace_t **t);
/* "PREA", "REF", "MR1=0380", "ZQCL", "{CKE ODT RESET_N}", ... into buf (>= 24 bytes) */
void bow_ld_trace_str(const bow_ld_trace_t *e, char *buf);

/* Hand-over: bow_ld_quiesce() when the native port is open (init_done = 1,
 * init_error = 0), then PREA by DFII, hardware control, ddrctrl init_error
 * = !ok, init_done = 1; ok: wait for STATUS.READY (window usable). With
 * ok = false it blocks the window (init_done = init_error = 1), also after
 * a hand-over: no DFII command ever runs beside a window access. */
bool bow_ld_handover(bool ok);

/* Before DFII sections after the hand-over: init_done = 0 (window blocked),
 * then 20 us so that a refresh closed the rows of the controller's bank
 * machines. was_ready (may be NULL): STATUS.READY before, for
 * bow_ld_release. */
void bow_ld_quiesce(bool *was_ready);
bool bow_ld_release(bool was_ready);

/* ---------------------------------------------------------- calibration */
typedef struct {
  uint32_t step, npts, good;   /* sweep step, points, points with the pattern */
  int32_t phase;               /* chosen read phase (fine steps) */
  uint32_t width;              /* eye width in fine steps */
  int32_t p;                   /* beat of the pattern start in the capture */
  uint32_t rd_dly, rd_slip;
  uint32_t bist_errors;        /* errors of the closing BIST check */
  int32_t wphase;              /* bow_ld_cal_write: chosen write phase */
  uint32_t wwidth;             /* its passing range in fine steps */
  const char *err;             /* reason of a failure */
} bow_ld_cal_t;

/* Read calibration (docs/ip/ddr.md, steps 1..6), DFII sections: training
 * pattern P / ~P into bank 0 row 0 columns 0 / 8, phase sweep in steps of
 * `step` with raw captures, centre of the widest eye, RD_DLY / RD_SLIP
 * (LAT, APPLY), verification by DFII reads (no RD_LATE / RD_EXTRA), the
 * hand-over and a BIST check over the first 64 native words. The sweep is
 * cyclic: one CK period later the data come one stream cycle earlier
 * (p - 2), so an eye can continue from the last point into the first.
 * Needs bow_ld_init(); verbose prints the eye map. A failure leaves
 * init_done = init_error = 1 (window blocked, refresh still on). */
bool bow_ld_calibrate(uint32_t step, bool verbose, bow_ld_cal_t *res);
/* Sweep and eye map only (steps 1..4); the phase is restored, and READY
 * when it was set and the pattern still reads right with LAT (the sweep
 * synchronised the read FIFO again at phase 0, which can move the read
 * data by a stream cycle: then the window stays blocked, run the
 * calibration again; the same when the sweep failed after that sync or the
 * phase could not be restored). The two native words under the training
 * pattern (window offsets 0 .. 2 * word - 1) are read before the sweep and
 * written back after it, so a READY memory keeps its data. */
bool bow_ld_eye(uint32_t step, bool verbose, bow_ld_cal_t *res);
/* Write phase (step 7, after bow_ld_calibrate): at write phases -steps/4 ..
 * +steps/4 two BIST runs over the first 64 words (PRBS, then counter data:
 * a write that did not happen fails one of them), centre of the widest
 * passing range (>= 20 %), checked once more there. A failure once the scan
 * has started (WPS_GO refused, no such range, the check at the centre)
 * moves back to the old write phase and checks it the same way; when that
 * fails too, the window is blocked (init_done = init_error = 1, as after a
 * failed bow_ld_calibrate; res->wphase = the write phase left). Not for the
 * loopback emulator (the write phase moves its read eye too). */
bool bow_ld_cal_write(uint32_t step, bool verbose, bow_ld_cal_t *res);

/* Eye of a sweep: map[i] = beat offset of the pattern at phase i * step
 * (-1: absent), n points, steps per CK. Sets width, and with an eye of at
 * least 20 % of a CK period phase and p; false: no such eye. */
bool bow_ld_eye_analyse(const int8_t *map, uint32_t n, uint32_t step, uint32_t steps,
                        bow_ld_cal_t *r);

/* ------------------------------------------------------------------ BIST */
/* LiteDRAM BIST (sdram_generator / sdram_checker CSRs, hardware control):
 * the generator writes `length` bytes from DRAM offset `base` (= window
 * offset), one native word per command, sequential addresses; the checker
 * reads them back and counts the words that differ. Data: PRBS31 (random)
 * or a counter, restarted by every run (see bow_ld_gen_*). base and length:
 * multiples of the native word, 1 word <= length <= 32 MiB, inside the
 * DRAM. Not while the CPU uses the window (window stores are a
 * read-modify-write). */
typedef struct {
  uint32_t base, length;
  bool random;               /* PRBS31 data, else the word counter */
  bool write, read;          /* generator pass, checker pass */
} bow_ld_bist_t;

typedef struct {
  bool done;                 /* the passes finished in time (no CSR error) */
  uint32_t errors;           /* checker: native words that differ */
  uint32_t wr_ticks, rd_ticks; /* controller clock cycles (CK / 4) of the passes */
} bow_ld_bist_res_t;

/* true = done, no errors */
bool bow_ld_bist(const bow_ld_bist_t *b, bow_ld_bist_res_t *r);
/* bytes over ticks at the controller clock CK / 4: MB/s x 100 */
uint32_t bow_ld_mbs100(uint32_t bytes, uint32_t ticks, uint32_t ck_hz);

/* The data of the BIST (C twin of LiteDRAM's generator / checker, word k of
 * a run): o_k = PRBS31 state after k + 1 steps of 31 shifts from 0 (new bit
 * = !(s[27] ^ s[30])) or the counter k; the native word repeats the 31 bits
 * of o_k from bit 0 up. */
typedef struct {
  uint32_t k, o;
  bool random;
} bow_ld_gen_t;

void bow_ld_gen_start(bow_ld_gen_t *g, bool random);
void bow_ld_gen_next(bow_ld_gen_t *g);
/* 32 bit lane l of the native word (= window word at byte 4 l of it) */
uint32_t bow_ld_gen_lane(const bow_ld_gen_t *g, uint32_t lane);

/* ---------------------------------------------------------------- status */
/* DFII control, init_done / init_error, BIST state, CSR faults, longest
 * software section. */
void bow_ld_print_status(void);

#endif /* BOW_LITEDRAM_H_ */
