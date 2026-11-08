/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * hyperram application: shared declarations (main.c, memtest.c, selftest.c).
 */
#ifndef HR_APP_H_
#define HR_APP_H_

#include "bow32.h"

typedef struct {
  bow_hr_info_t info;     /* bow_hr_probe at start-up */
  bow_hr_config_t cfg;    /* configuration of the last init */
  bow_hr_cal_t cal;       /* result of the last calibration */
  bool present, inited;
} hr_app_t;

extern hr_app_t app;

/* main.c */
bool app_init(bool verbose);
void print_left(const char *s, unsigned width);
void print_mbs(uint64_t bytes, uint64_t cycles, uint32_t hz);   /* "123.45 MB/s" */

/* memtest.c: CPU tests through the window; offsets and lengths in bytes,
 * multiples of 4, from the window base. The xorshift fill (mt_fill) is the
 * documented sequence x = seed (1 if 0), word i = x after i + 1 steps of
 * xorshift32 (13, 17, 5); tools/bow32_hyperram.py checks it with `dump`. */
typedef struct {
  uint32_t words, errors;   /* compared words, mismatches */
  uint32_t off, exp, got;   /* first mismatch */
  bool bus_error;
} mt_res_t;

uint32_t mt_xs32(uint32_t x);
void mt_clear(mt_res_t *r);
bool mt_walk(uint32_t off, mt_res_t *r);                    /* walking 1 / 0 over a line */
bool mt_addr_lines(uint32_t cap_log2, mt_res_t *r);         /* offsets 0 and 2^k */
bool mt_addr(uint32_t off, uint32_t len, mt_res_t *r);      /* address in address, inverted */
bool mt_bytes(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r); /* byte / halfword stores */
bool mt_fill(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r);
bool mt_check(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r);
void mt_report(const mt_res_t *r);
/* the BIST data word of word address a (C twin of bow_hyperram_bist):
 * counter: (a ^ seed) & 0xFFFF; PRBS: state k of xorshift32 from seed. */
uint16_t bist_word(bool count, uint32_t seed, uint32_t index, uint32_t waddr);
void bench(void);

/* selftest.c */
bool self_test(bool quick, uint32_t seed);

#endif /* HR_APP_H_ */
