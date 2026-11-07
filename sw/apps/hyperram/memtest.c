/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * hyperram: CPU memory tests through the window, BIST twin, bench.
 */
#include "hr_app.h"

static bool win_rd(uint32_t off, uint32_t *v) { return bow_probe_read32(BOW32_HYPERRAM_BASE + off, v); }
static bool win_wr(uint32_t off, uint32_t v) { return bow_probe_write32(BOW32_HYPERRAM_BASE + off, v); }

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

/* the read buffer would answer from its copy: drop it before checking */
static bool fresh(mt_res_t *r) {
  if (bow_hr_flush() && bow_hr_inval()) return true;
  r->bus_error = true;
  return false;
}

/* Walking one, then walking zero, over the 32 bits of the 8 words of a line
 * (a 16 word HyperRAM burst): every DQ pin sees a lone 1 (0) between 0s (1s). */
bool mt_walk(uint32_t off, mt_res_t *r) {
  for (uint32_t inv = 0; inv < 2u; inv++) {
    for (uint32_t bit = 0; bit < 32u; bit++) {
      for (uint32_t w = 0; w < 8u; w++) {
        uint32_t v = 1u << ((bit + w) & 31u);
        if (!wr(r, off + 4u * w, inv ? ~v : v)) return false;
      }
      if (!fresh(r)) return false;
      for (uint32_t w = 0; w < 8u; w++) {
        uint32_t v = 1u << ((bit + w) & 31u);
        if (!expect(r, off + 4u * w, inv ? ~v : v)) return false;
      }
    }
  }
  return result(r);
}

/* Offset 0 and every 2^k (k = 2 .. cap_log2 - 1) get a value of their own,
 * written upwards, then checked: a stuck or shorted address bit makes two of
 * them share a location. */
static uint32_t line_value(uint32_t k) { return 0xADD00000u ^ (k << 8) ^ (k * 0x01010001u); }

bool mt_addr_lines(uint32_t cap_log2, mt_res_t *r) {
  if (!wr(r, 0, line_value(0))) return false;
  for (uint32_t k = 2; k < cap_log2; k++) {
    if (!wr(r, 1u << k, line_value(k))) return false;
  }
  if (!fresh(r) || !expect(r, 0, line_value(0))) return false;
  for (uint32_t k = 2; k < cap_log2; k++) {
    if (!expect(r, 1u << k, line_value(k))) return false;
  }
  return result(r);
}

/* every word holds its own offset, then its inverse */
bool mt_addr(uint32_t off, uint32_t len, mt_res_t *r) {
  for (uint32_t inv = 0; inv < 2u; inv++) {
    for (uint32_t o = off; o < off + len; o += 4u) {
      if (!wr(r, o, inv ? ~o : o)) return false;
    }
    if (!fresh(r)) return false;
    for (uint32_t o = off; o < off + len; o += 4u) {
      if (!expect(r, o, inv ? ~o : o)) return false;
    }
  }
  return result(r);
}

/* Byte and halfword stores (RWDS masks) into a known word pattern, checked
 * against a model of every byte. */
bool mt_bytes(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r) {
  uint32_t x = seed ? seed : 1u;
  for (uint32_t o = off; o < off + len; o += 4u) {
    if (!wr(r, o, 0x5A5A5A5Au ^ o)) return false;
  }
  for (uint32_t o = off; o < off + len; o += 4u) {
    uint32_t a = BOW32_HYPERRAM_BASE + o;
    x = mt_xs32(x);
    uint32_t v = x;
    switch (x >> 30) {
      case 0: *(volatile uint8_t *)(uintptr_t)(a + (x & 3u)) = (uint8_t)v; break;
      case 1: *(volatile uint16_t *)(uintptr_t)(a + (x & 2u)) = (uint16_t)v; break;
      case 2: *(volatile uint8_t *)(uintptr_t)(a + 3u) = (uint8_t)(v >> 8); break;
      default: *(volatile uint16_t *)(uintptr_t)a = (uint16_t)(v >> 16); break;
    }
  }
  if (!fresh(r)) return false;
  x = seed ? seed : 1u;
  for (uint32_t o = off; o < off + len; o += 4u) {
    uint32_t e = 0x5A5A5A5Au ^ o;
    x = mt_xs32(x);
    uint32_t v = x;
    switch (x >> 30) {
      case 0: e = (e & ~(0xFFu << (8u * (x & 3u)))) | ((v & 0xFFu) << (8u * (x & 3u))); break;
      case 1: e = (e & ~(0xFFFFu << (8u * (x & 2u)))) | ((v & 0xFFFFu) << (8u * (x & 2u))); break;
      case 2: e = (e & 0x00FFFFFFu) | (((v >> 8) & 0xFFu) << 24); break;
      default: e = (e & 0xFFFF0000u) | ((v >> 16) & 0xFFFFu); break;
    }
    if (!expect(r, o, e)) return false;
  }
  return result(r);
}

bool mt_fill(uint32_t off, uint32_t len, uint32_t seed, mt_res_t *r) {
  uint32_t x = seed ? seed : 1u;
  for (uint32_t o = off; o < off + len; o += 4u) {
    x = mt_xs32(x);
    if (!wr(r, o, x)) return false;
  }
  return fresh(r);
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
  if (r->bus_error) bow_printf("       bus error (STATUS %08x ERR_ADDR %08x)\n", BOW_HR_RD(STATUS), BOW_HR_RD(ERR_ADDR));
  if (r->errors) {
    bow_printf("       %u errors, first at %08x: expected %08x read %08x\n", r->errors,
               BOW32_HYPERRAM_BASE + r->off, r->exp, r->got);
  }
}

uint16_t bist_word(bool count, uint32_t seed, uint32_t index, uint32_t waddr) {
  if (count) return (uint16_t)((waddr ^ seed) & 0xFFFFu);
  uint32_t x = seed ? seed : 1u;
  for (uint32_t i = 0; i < index; i++) x = mt_xs32(x);
  return (uint16_t)x;
}

/* ------------------------------------------------------------------- bench */
void bench(void) {
  const uint32_t n = 4096u;   /* bytes */
  uint32_t ck = BOW_HR_RD(CLK_HZ), hz = bow_clk_hz(), t0, v = 0;
  uint32_t ctrl = BOW_HR_RD(CTRL);
  bow_printf("bench: %u bytes through the window, BIST of 64 KiB\n", n);
  /* non-posted writes, then reads with the read buffer (line fills) */
  bow_hr_window(true, true, false);
  t0 = bow_cycles();
  for (uint32_t o = 0; o < n; o += 4u) *(volatile uint32_t *)(uintptr_t)(BOW32_HYPERRAM_BASE + o) = o;
  uint32_t t_wr = bow_cycles() - t0;
  bow_hr_window(true, true, true);
  t0 = bow_cycles();
  for (uint32_t o = 0; o < n; o += 4u) *(volatile uint32_t *)(uintptr_t)(BOW32_HYPERRAM_BASE + o) = ~o;
  (void)bow_hr_flush();
  uint32_t t_pw = bow_cycles() - t0;
  (void)bow_hr_inval();
  t0 = bow_cycles();
  for (uint32_t o = 0; o < n; o += 4u) v += *(volatile uint32_t *)(uintptr_t)(BOW32_HYPERRAM_BASE + o);
  uint32_t t_rd = bow_cycles() - t0;
  bow_hr_window(false, true, true);
  t0 = bow_cycles();
  for (uint32_t o = 0; o < n; o += 4u) v += *(volatile uint32_t *)(uintptr_t)(BOW32_HYPERRAM_BASE + o);
  uint32_t t_un = bow_cycles() - t0;
  BOW_HR_WR(CTRL, ctrl);
  bow_puts("bench: CPU write ");
  print_mbs(n, t_wr, hz);
  bow_puts(", posted write ");
  print_mbs(n, t_pw, hz);
  bow_puts(", read (line buffer) ");
  print_mbs(n, t_rd, hz);
  bow_puts(", uncached read ");
  print_mbs(n, t_un, hz);
  bow_puts("\n");
  /* BIST: raw HyperBus bandwidth */
  bow_hr_bist_res_t w, r;
  uint32_t burst = bow_hr_bist_burst_max(), words = 32768u;
  if (words * 2u > app.info.test_bytes) words = app.info.test_bytes / 2u;
  bool okw = bow_hr_bist(0, words, burst, HR_BIST_WRITE, 7u, &w);
  bool okr = bow_hr_bist(0, words, burst, HR_BIST_READ, 7u, &r);
  (void)bow_hr_inval();
  bow_printf("bench: BIST %u words, bursts of %u: write ", words, burst);
  print_mbs(2ull * words, w.cycles, ck);
  bow_puts(", read ");
  print_mbs(2ull * words, r.cycles, ck);
  bow_printf("%s (sum %08x)\n", okw && okr ? "" : ", ERROR", v);
}
