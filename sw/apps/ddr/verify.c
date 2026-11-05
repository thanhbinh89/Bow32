/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * ddr: `verify [N] [SEED]`, random data checks on the target. N cases in a
 * region of the test region (1 MiB from offset 1 MiB, or its upper half
 * when it is smaller than 2 MiB), each one of
 *   bist  LiteDRAM BIST of 1..512 native words at a random word offset,
 *         PRBS or counter data: the checker must count no error, and four
 *         window words (first, last, two random) must equal the C twin of
 *         the generator (bow_ld_gen_*);
 *   cpu   xorshift fill / check of 4..2048 bytes through the window.
 * Prints the failed cases and "verify: PASS (n/n cases)" or "verify: FAIL
 * (k/n cases)". tools/bow32_ddr.py verify runs such cases with the data
 * compared on the host instead (dump).
 */
#include "ddr_app.h"

static uint32_t rng_state;

static uint32_t rnd(uint32_t n) {
  rng_state = mt_xs32(rng_state);
  return n ? rng_state % n : 0u;
}

bool verify(uint32_t count, uint32_t seed) {
  uint32_t cap = 1u << app.info.test_log2, w = app.info.word_bytes, failed = 0;
  uint32_t lo = cap >= (2u << 20) ? (1u << 20) : cap / 2u;
  uint32_t size = cap - lo > (1u << 20) ? (1u << 20) : cap - lo;
  rng_state = seed ? seed : 1u;
  bow_printf("verify: %u cases, seed %u\n", count, seed);
  for (uint32_t c = 0; c < count; c++) {
    mt_res_t r;
    mt_clear(&r);
    if (rnd(10) < 7u) {
      uint32_t words = 1u + rnd(512), len = words * w;
      uint32_t base = lo + rnd((size - len) / w + 1u) * w;
      bool random = rnd(2) == 0;
      const char *data = random ? "prbs" : "count";
      uint32_t offs[4] = {0, len - 4u, rnd(len / 4u) * 4u, rnd(len / 4u) * 4u};
      bow_ld_bist_t b = {.base = base, .length = len, .random = random, .write = true, .read = true};
      bow_ld_bist_res_t res;
      if (!bow_ld_bist(&b, &res)) {
        failed++;
        bow_printf("verify: case %u: bist %08x %u %s: done %u errors %u\n", c, base, len, data,
                   res.done, res.errors);
      } else if (!bist_twin(base, random, offs, 4, &r)) {
        failed++;
        bow_printf("verify: case %u: bist %08x %u %s: window %08x = %08x, C twin %08x%s\n", c, base,
                   len, data, BOW32_DDR_BASE + r.off, r.got, r.exp, r.bus_error ? " (bus error)" : "");
      }
    } else {
      uint32_t len = 4u * (1u + rnd(512)), off = lo + 4u * rnd((size - len) / 4u + 1u);
      uint32_t s = rnd(0xFFFFFFFFu);
      if (!(mt_fill(off, len, s, &r) && mt_check(off, len, s, &r))) {
        failed++;
        bow_printf("verify: case %u: memtest %08x %u %u: %u errors, first at %08x: expected %08x "
                   "read %08x%s\n",
                   c, BOW32_DDR_BASE + off, len, s, r.errors, BOW32_DDR_BASE + r.off, r.exp, r.got,
                   r.bus_error ? ", bus error" : "");
      }
    }
  }
  bow_printf("verify: %s (%u/%u cases)\n", failed ? "FAIL" : "PASS", count - failed, count);
  return failed == 0;
}
