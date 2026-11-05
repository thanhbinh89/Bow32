/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * ddr: state and helpers shared by the shell (main.c), the CPU memory
 * tests (memtest.c), the self-test (selftest.c) and the random check
 * (verify.c).
 */
#ifndef DDR_APP_H_
#define DDR_APP_H_

#include "bow32.h"
#include "bow_litedram.h"

/* CPU access to the memory window at offset o (raw: a bus error traps).
 * A host test build defines both to a model before this header. */
#ifndef DDR_WIN_RD
#define DDR_WIN_RD(t, o)    (*(volatile t *)(uintptr_t)(BOW32_DDR_BASE + (o)))
#define DDR_WIN_WR(t, o, v) (*(volatile t *)(uintptr_t)(BOW32_DDR_BASE + (o)) = (t)(v))
#endif

/* Checked 32 bit window access: false when the window answers with a bus
 * error (not READY, beyond the DRAM size, timeout / BROKEN). */
static inline bool win_rd(uint32_t o, uint32_t *v) { return bow_probe_read32(BOW32_DDR_BASE + o, v); }
static inline bool win_wr(uint32_t o, uint32_t v) { return bow_probe_write32(BOW32_DDR_BASE + o, v); }

typedef struct {
  bow_ddr_info_t info;   /* bow_ddr_probe at start-up */
  bow_ddr_config_t cfg;  /* PHY configuration of the last init */
  bow_ld_cal_t cal;      /* result of the last calibration */
  bool present, inited, calibrated;
} ddr_app_t;

extern ddr_app_t app;

/* main.c */
bool app_init(bool verbose);                     /* bow_ld_init with the defaults of the IP */
bool app_calibrate(uint32_t step, bool verbose); /* init first when needed, read calibration */
void print_left(const char *s, unsigned width);
void print_mbs(uint64_t bytes, uint64_t cycles, uint32_t hz); /* "123.45 MB/s" */
void print_mbs100(uint32_t mbs100);                           /* MB/s x 100 as "123.45 MB/s" */

/* memtest.c: CPU tests through the window; offsets and lengths in bytes,
 * multiples of 4. The xorshift fill (mt_fill) is the documented sequence
 * x = seed (1 if 0), word i = x after i + 1 steps of xorshift32 (13, 17,
 * 5); tools/bow32_ddr.py checks it with `dump`. */
typedef struct {
  uint32_t words, errors;   /* compared words, mismatches */
  uint32_t writes;          /* window stores (one RMW each without DM) */
  uint32_t off, exp, got;   /* first mismatch */
  bool bus_error;           /* a checked access answered with an error */
} mt_res_t;

uint32_t mt_xs32(uint32_t x);
void mt_clear(mt_res_t *r);
bool mt_walk(uint32_t off, mt_res_t *r);                 /* walking 1 / 0, two native words */
bool mt_addr_lines(uint32_t cap_log2, mt_res_t *r);      /* offsets 0 and 2^k */
bool mt_addr(uint32_t off, uint32_t len, mt_res_t *r);   /* address in address, inverted */
bool mt_bytes(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r); /* byte / halfword stores */
bool mt_fill(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r);
bool mt_check(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r);
void mt_report(const mt_res_t *r);                       /* detail line(s) of a failure */
/* Window words at base + offs[i] (offsets from the start of a LiteDRAM BIST
 * write at base, multiples of 4) against the C twin of the generator data;
 * false on the first mismatch / bus error (r: that word). */
bool bist_twin(uint32_t base, bool random, const uint32_t *offs, uint32_t n, mt_res_t *r);
void bench(void);

/* verify.c: `verify N SEED` */
bool verify(uint32_t count, uint32_t seed);

/* selftest.c */
bool self_test(bool quick, uint32_t seed);

#endif /* DDR_APP_H_ */
