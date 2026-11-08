/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * ddr: CPU memory tests through the window, the check of LiteDRAM BIST
 * data against the C twin of its generator, and the bandwidth bench.
 *
 * Word accesses of the tests go through bow_probe_read32 / write32, so a
 * window that answers with a bus error ends the test with bus_error
 * instead of a trap. Byte and halfword stores (the read-modify-write path
 * of a controller without DM pins) and the bench use plain accesses: call
 * them only while STATUS.READY = 1.
 */
#include "ddr_app.h"

uint32_t mt_xs32(uint32_t x) {
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  return x;
}

void mt_clear(mt_res_t *r) { *r = (mt_res_t){0}; }

static void mismatch(mt_res_t *r, uint32_t off, uint32_t exp, uint32_t got) {
  if (r->errors == 0) {
    r->off = off;
    r->exp = exp;
    r->got = got;
  }
  if (r->errors != 0xFFFFFFFFu) r->errors++;
}

static bool wr(mt_res_t *r, uint32_t o, uint32_t v) {
  r->writes++;
  if (win_wr(o, v)) return true;
  r->bus_error = true;
  return false;
}

/* false only on a bus error (a mismatch is counted, the test goes on) */
static bool expect(mt_res_t *r, uint32_t o, uint32_t exp) {
  uint32_t v;
  if (!win_rd(o, &v)) {
    r->bus_error = true;
    return false;
  }
  r->words++;
  if (v != exp) mismatch(r, o, exp, v);
  return true;
}

static bool result(const mt_res_t *r) { return !r->bus_error && r->errors == 0; }

/* Walking one, then walking zero, over the 32 bits of every word of two
 * native words (bursts); neighbouring words carry neighbouring bits, so
 * every DQ pin sees a lone 1 (0) between 0s (1s) within a burst. */
bool mt_walk(uint32_t off, mt_res_t *r) {
  uint32_t nw = 2u * bow_ddr_word_bytes() / 4u;
  for (uint32_t inv = 0; inv < 2u; inv++) {
    for (uint32_t bit = 0; bit < 32u; bit++) {
      for (uint32_t w = 0; w < nw; w++) {
        uint32_t v = 1u << ((bit + w) & 31u);
        if (!wr(r, off + 4u * w, inv ? ~v : v)) return false;
      }
      for (uint32_t w = 0; w < nw; w++) {
        uint32_t v = 1u << ((bit + w) & 31u);
        if (!expect(r, off + 4u * w, inv ? ~v : v)) return false;
      }
    }
  }
  return result(r);
}

/* Offset 0 and every 2^k (k = 2 .. cap_log2 - 1) get a value of their own,
 * written upwards, then the inverse downwards: a stuck or shorted address
 * bit makes two of them share a location. */
static uint32_t line_value(uint32_t k) { return 0xADD00000u ^ (k << 8) ^ (k * 0x01010001u); }

bool mt_addr_lines(uint32_t cap_log2, mt_res_t *r) {
  if (cap_log2 > 29u) cap_log2 = 29u;
  for (uint32_t pass = 0; pass < 2u; pass++) {
    for (uint32_t i = 0; i < cap_log2; i++) {
      uint32_t k = pass ? cap_log2 - 1u - i : i; /* 0, 1 stand for offset 0 */
      if (k == 1u) continue;
      uint32_t o = k ? 1u << k : 0u;
      if (!wr(r, o, pass ? ~line_value(k) : line_value(k))) return false;
    }
    for (uint32_t k = 0; k < cap_log2; k++) {
      if (k == 1u) continue;
      if (!expect(r, k ? 1u << k : 0u, pass ? ~line_value(k) : line_value(k))) return false;
    }
  }
  return result(r);
}

/* Every word holds its own bus address, then its inverse. */
bool mt_addr(uint32_t off, uint32_t len, mt_res_t *r) {
  for (uint32_t inv = 0; inv < 2u; inv++) {
    for (uint32_t o = off; o < off + len; o += 4u) {
      uint32_t v = BOW32_DDR_BASE + o;
      if (!wr(r, o, inv ? ~v : v)) return false;
    }
    for (uint32_t o = off; o < off + len; o += 4u) {
      uint32_t v = BOW32_DDR_BASE + o;
      if (!expect(r, o, inv ? ~v : v)) return false;
    }
  }
  return result(r);
}

/* March C- (van de Goor), 10 accesses per word: up/down(w0); up(r0, w1);
 * up(r1, w0); down(r0, w1); down(r1, w0); up/down(r0), with 0 and ~0 as the
 * two values of a whole word. Finds stuck-at, transition and address
 * decoder faults and coupling faults between words (the March test that
 * IEC 61508 lists for RAM). */
bool mt_march(uint32_t off, uint32_t len, mt_res_t *r) {
  const uint32_t z = 0u, f = 0xFFFFFFFFu;
  uint32_t n = len / 4u;
  for (uint32_t i = 0; i < n; i++) {
    if (!wr(r, off + 4u * i, z)) return false;
  }
  for (uint32_t i = 0; i < n; i++) {
    if (!expect(r, off + 4u * i, z) || !wr(r, off + 4u * i, f)) return false;
  }
  for (uint32_t i = 0; i < n; i++) {
    if (!expect(r, off + 4u * i, f) || !wr(r, off + 4u * i, z)) return false;
  }
  for (uint32_t i = n; i-- > 0u;) {
    if (!expect(r, off + 4u * i, z) || !wr(r, off + 4u * i, f)) return false;
  }
  for (uint32_t i = n; i-- > 0u;) {
    if (!expect(r, off + 4u * i, f) || !wr(r, off + 4u * i, z)) return false;
  }
  for (uint32_t i = 0; i < n; i++) {
    if (!expect(r, off + 4u * i, z)) return false;
  }
  return result(r);
}

/* Byte and halfword stores into an xorshift background: word j gets byte
 * j % 4 replaced, every third word one of its halfwords as well; then word
 * loads and byte loads compare with the expected merge. */
static uint8_t byte_value(uint32_t j, uint32_t seed) { return (uint8_t)(j * 0x1Du + seed + 0x5Au); }

static uint16_t half_value(uint32_t j, uint32_t seed) {
  return (uint16_t)(0xC3A5u ^ (j * 0x0101u) ^ seed);
}

static uint32_t merged(uint32_t x, uint32_t j, uint32_t seed) {
  uint32_t b = 8u * (j & 3u);
  x = (x & ~(0xFFu << b)) | ((uint32_t)byte_value(j, seed) << b);
  if (j % 3u == 0) {
    uint32_t h = 16u * ((j >> 2) & 1u);
    x = (x & ~(0xFFFFu << h)) | ((uint32_t)half_value(j, seed) << h);
  }
  return x;
}

bool mt_bytes(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r) {
  uint32_t n = len / 4u, x;
  if (!mt_fill(off, len, seed, r)) return false;
  for (uint32_t j = 0; j < n; j++) {
    uint32_t o = off + 4u * j;
    DDR_WIN_WR(uint8_t, o + (j & 3u), byte_value(j, seed));
    r->writes++;
    if (j % 3u == 0) {
      DDR_WIN_WR(uint16_t, o + 2u * ((j >> 2) & 1u), half_value(j, seed));
      r->writes++;
    }
  }
  x = seed ? seed : 1u;
  for (uint32_t j = 0; j < n; j++) {
    uint32_t o = off + 4u * j;
    x = mt_xs32(x);
    uint32_t want = merged(x, j, seed);
    if (!expect(r, o, want)) return false;
    uint32_t bi = (j + 1u) & 3u;
    uint8_t b = DDR_WIN_RD(uint8_t, o + bi);
    r->words++;
    if (b != (uint8_t)(want >> (8u * bi))) mismatch(r, o + bi, (want >> (8u * bi)) & 0xFFu, b);
  }
  return result(r);
}

bool mt_fill(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r) {
  uint32_t x = seed ? seed : 1u;
  for (uint32_t o = off; o < off + len; o += 4u) {
    x = mt_xs32(x);
    if (!wr(r, o, x)) return false;
  }
  return true;
}

bool mt_check(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r) {
  uint32_t x = seed ? seed : 1u;
  for (uint32_t o = off; o < off + len; o += 4u) {
    x = mt_xs32(x);
    if (!expect(r, o, x)) return false;
  }
  return result(r);
}

void mt_report(const mt_res_t *r) {
  if (r->bus_error) bow_printf("       bus error from the window (STATUS %08x)\n", BOW_DDR_RD(STATUS));
  if (r->errors) {
    bow_printf("       %u errors in %u words, first at 0x%08x: expected %08x read %08x\n", r->errors,
               r->words, BOW32_DDR_BASE + r->off, r->exp, r->got);
  }
}

/* One pass of the generator up to the highest word asked for. */
bool bist_twin(uint32_t base, bool random, const uint32_t *offs, uint32_t n, mt_res_t *r) {
  uint32_t w = bow_ddr_word_bytes(), kmax = 0;
  bow_ld_gen_t g;
  for (uint32_t i = 0; i < n; i++) {
    if (offs[i] / w > kmax) kmax = offs[i] / w;
  }
  bow_ld_gen_start(&g, random);
  for (;;) {
    for (uint32_t i = 0; i < n; i++) {
      if (offs[i] / w != g.k) continue;
      uint32_t want = bow_ld_gen_lane(&g, (offs[i] % w) / 4u);
      if (!expect(r, base + offs[i], want)) return false;
      if (r->errors) return false;
    }
    if (g.k == kmax) break;
    bow_ld_gen_next(&g);
  }
  return result(r);
}

/* ------------------------------------------------------------------- bench */
#define BENCH_OFF   0x00040000u
#define BENCH_BYTES 4096u
#define BENCH_WORDS 4096u

static void bench_line(const char *name, uint32_t bytes, uint32_t accesses, uint32_t cycles) {
  bow_puts("  ");
  print_left(name, 30);
  print_mbs(bytes, cycles ? cycles : 1u, bow_clk_hz());
  bow_printf("  (%u cycles per access)\n", cycles / accesses);
}

void bench(void) {
  uint32_t t0, sum = 0, n = BENCH_BYTES;
  if (!bow_ddr_ready()) {
    bow_puts("bench: not READY (init, cal)\n");
    return;
  }
  bool dm = (BOW_DDR_RD(CTRL) & DDR_CTRL_DM_EN) && (BOW_DDR_RD(INFO) & DDR_INFO_HAS_DM);
  bow_printf("bench: CPU %u MHz through the window, %u bytes\n", bow_clk_hz() / 1000000u, n);
  t0 = bow_cycles();
  for (uint32_t o = 0; o < n; o += 4u) DDR_WIN_WR(uint32_t, BENCH_OFF + o, o);
  bench_line(dm ? "word stores" : "word stores (RMW)", n, n / 4u, bow_cycles() - t0);
  t0 = bow_cycles();
  for (uint32_t o = 0; o < n; o += 4u) sum += DDR_WIN_RD(uint32_t, BENCH_OFF + o);
  bench_line("word loads", n, n / 4u, bow_cycles() - t0);
  t0 = bow_cycles();
  for (uint32_t o = 0; o < n; o += 4u) sum += DDR_WIN_RD(uint32_t, BENCH_OFF);
  bench_line("word loads, same word", n, n / 4u, bow_cycles() - t0);
  t0 = bow_cycles();
  for (uint32_t o = 0; o < n / 4u; o++) DDR_WIN_WR(uint8_t, BENCH_OFF + o, o);
  bench_line(dm ? "byte stores" : "byte stores (RMW)", n / 4u, n / 4u, bow_cycles() - t0);
  if (sum == 0x12345678u) bow_puts("\n"); /* keeps the loads */

  uint32_t ck = BOW_DDR_RD(CLK_HZ), w = bow_ddr_word_bytes();
  bow_printf("BIST (LiteDRAM), %u words of %u bytes, controller %u Hz, peak ", BENCH_WORDS, w,
             ck / 4u);
  print_mbs100(bow_ld_mbs100(w, 1u, ck)); /* one native word per controller cycle */
  bow_puts("\n");
  bow_ld_bist_t b = {.base = BENCH_OFF, .length = BENCH_WORDS * w, .random = true, .write = true,
                     .read = true};
  bow_ld_bist_res_t res;
  bool ok = bow_ld_bist(&b, &res);
  bow_puts("  ");
  print_left("write (generator)", 30);
  print_mbs100(bow_ld_mbs100(b.length, res.wr_ticks, ck));
  bow_printf("  (%u ticks)\n", res.wr_ticks);
  bow_puts("  ");
  print_left("read (checker)", 30);
  print_mbs100(bow_ld_mbs100(b.length, res.rd_ticks, ck));
  bow_printf("  (%u ticks, %u errors)%s\n", res.rd_ticks, res.errors, ok ? "" : " bist error");
}
