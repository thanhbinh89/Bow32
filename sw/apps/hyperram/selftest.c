/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * hyperram: self-test (`test [quick|full] [seed]`). Every check prints one
 * line "  [nn] <name> ok|FAIL", detail lines before a FAIL start with 7
 * spaces; the last line is "hyperram: PASS (n/n)" or "hyperram: FAIL (k/n)".
 * quick: small regions (the system simulation runs it), full: the test
 * region of the build (the emulator storage, or 1 MiB of the device).
 */
#include "hr_app.h"

#define NUM_CHECKS 19u

static uint32_t checks, failures, seed0;
static uint32_t region;   /* bytes of the window the tests use, from offset 0 */

static bool detail(const char *fmt, uint32_t a, uint32_t b) {
  bow_puts("       ");
  bow_printf(fmt, a, b);
  bow_puts("\n");
  return false;
}

static void check(bool ok, const char *name) {
  checks++;
  bow_printf("  [%2u] ", checks);
  print_left(name, 62);
  bow_puts(ok ? " ok\n" : " FAIL\n");
  if (!ok) failures++;
}

static bool mt_ok(bool ok, const mt_res_t *r) {
  if (!ok) mt_report(r);
  return ok;
}

/* ---------------------------------------------------------------- checks */
static bool t_present(void) {
  if (!app.present) return detail("IP not found (ID %08x INFO %08x)", app.info.id, app.info.info);
  if (!bow_hr_wait_clk(10)) return detail("no CLK_OK (STATUS %08x)%s", BOW_HR_RD(STATUS), 0);
  if (BOW_HR_RD(CLK_HZ) != app.info.clk_hz || app.info.ps_steps == 0u) {
    return detail("CLK_HZ %u, %u phase steps", BOW_HR_RD(CLK_HZ), app.info.ps_steps);
  }
  return true;
}

static bool t_refused(void) {
  bool ok = true;
  uint32_t v;
  BOW_HR_WR(CTRL, BOW_HR_RD(CTRL) & ~HR_CTRL_INIT_DONE);
  BOW_HR_WR(STATUS, HR_ST_W1C);
  if (bow_hr_cmd(HR_CMD_APPLY | HR_CMD_SNAP)) ok = detail("two CMD bits accepted%s%s", 0, 0);
  if (bow_hr_reg_write(HR_REG_ID0, 0x1234u)) ok = detail("ID0 write accepted%s%s", 0, 0);
  if (bow_probe_read32(BOW32_HYPERRAM_BASE, &v)) ok = detail("window read while not READY: %08x%s", v, 0);
  if (!(BOW_HR_RD(STATUS) & HR_ST_NOT_READY)) ok = detail("no NOT_READY (STATUS %08x)%s", BOW_HR_RD(STATUS), 0);
  BOW_HR_WR(STATUS, HR_ST_W1C);
  return ok;
}

static bool t_init(void) {
  if (!app_init(true)) return detail("init failed (STATUS %08x ERR_CODE %08x)", BOW_HR_RD(STATUS), BOW_HR_RD(ERR_CODE));
  return true;
}

static bool t_regs(void) {
  uint16_t id0, id1, cr0, cr1;
  bool ok = bow_hr_reg_read(HR_REG_ID0, &id0) && bow_hr_reg_read(HR_REG_ID1, &id1) &&
            bow_hr_reg_read(HR_REG_CR0, &cr0) && bow_hr_reg_read(HR_REG_CR1, &cr1);
  if (!ok) return detail("REG_RD failed (ERR_CODE %08x)%s", BOW_HR_RD(ERR_CODE), 0);
  if (id0 != HR_ID0_S80KS2562 || id1 != HR_ID1_HYPERRAM2) return detail("ID0 %04x ID1 %04x", id0, id1);
  if (cr0 != (BOW_HR_RD(CR0) & 0xFFFFu)) return detail("CR0 %04x, shadow %04x", cr0, BOW_HR_RD(CR0));
  if ((cr1 & 3u) != 1u && (cr1 & 3u) != 2u) return detail("CR1 %04x: refresh interval field%s", cr1, 0);
  return true;
}

static bool t_walk(void) {
  mt_res_t r;
  mt_clear(&r);
  return mt_ok(mt_walk(0x100u, &r), &r);
}

static bool t_lines(void) {
  mt_res_t r;
  uint32_t log2 = 0;
  while ((2u << log2) <= region) log2++;
  mt_clear(&r);
  return mt_ok(mt_addr_lines(log2, &r), &r);
}

static bool t_addr(void) {
  mt_res_t r;
  mt_clear(&r);
  return mt_ok(mt_addr(region / 2u, region / 4u, &r), &r);
}

static bool t_bytes(void) {
  mt_res_t r;
  mt_clear(&r);
  return mt_ok(mt_bytes(region / 4u, 1024u, seed0, &r), &r);
}

static bool t_fill(void) {
  mt_res_t r;
  uint32_t len = region / 4u;
  mt_clear(&r);
  bow_hr_window(true, true, true);
  bool ok = mt_fill(0, len, seed0 + 1u, &r) && mt_check(0, len, seed0 + 1u, &r);
  if (ok) {
    bow_hr_window(true, true, false);
    ok = mt_fill(len, len, seed0 + 2u, &r) && mt_check(len, len, seed0 + 2u, &r);
  }
  bow_hr_window(true, true, true);
  return mt_ok(ok, &r);
}

static bool t_rbuf(void) {
  uint32_t a = BOW32_HYPERRAM_BASE + 0x400u, st0[16], st1[16], v, bad = 0;
  if (!bow_hr_flush() || !bow_hr_inval() || !bow_hr_snap(st0)) return detail("flush / snap failed%s%s", 0, 0);
  for (uint32_t i = 0; i < 8u; i++) {   /* critical word 5 first, the rest hits */
    uint32_t w = (5u + i) & 7u;
    if (!bow_probe_read32(a + 4u * w, &v)) bad++;
  }
  if (!bow_hr_snap(st1)) return detail("snap failed%s%s", 0, 0);
  uint32_t miss = st1[HR_STAT_MISSES] - st0[HR_STAT_MISSES], hit = st1[HR_STAT_HITS] - st0[HR_STAT_HITS];
  if (bad || miss != 1u || hit < 7u) return detail("line read: %u misses, %u hits", miss, hit);
  /* write through: the line and the memory get the store */
  *(volatile uint32_t *)(uintptr_t)(a + 12u) = 0xC0DEF00Du ^ seed0;
  if (*(volatile uint32_t *)(uintptr_t)(a + 12u) != (0xC0DEF00Du ^ seed0)) return detail("line not updated%s%s", 0, 0);
  if (!bow_hr_flush() || !bow_hr_inval()) return detail("flush failed%s%s", 0, 0);
  if (*(volatile uint32_t *)(uintptr_t)(a + 12u) != (0xC0DEF00Du ^ seed0)) return detail("memory not updated%s%s", 0, 0);
  return true;
}

static bool t_range(void) {
  uint32_t v, a = BOW32_HYPERRAM_BASE + app.info.mem_bytes;
  BOW_HR_WR(STATUS, HR_ST_RANGE);
  if (bow_probe_read32(a, &v)) return detail("read beyond %08x answered %08x", a, v);
  if (!(BOW_HR_RD(STATUS) & HR_ST_RANGE)) return detail("no RANGE (STATUS %08x)%s", BOW_HR_RD(STATUS), 0);
  if (BOW_HR_RD(ERR_ADDR) != a) return detail("ERR_ADDR %08x, expected %08x", BOW_HR_RD(ERR_ADDR), a);
  BOW_HR_WR(STATUS, HR_ST_RANGE);
  return true;
}

static bool t_bist(void) {
  bow_hr_bist_res_t r;
  uint32_t words = region / 4u, burst = bow_hr_bist_burst_max();
  if (!bow_hr_flush()) return false;
  bool ok = bow_hr_bist(region / 4u, words, burst, HR_BIST_WRITE | HR_BIST_READ, seed0, &r);
  if (!ok) detail("PRBS: %u errors, first at word %08x", r.errors, r.faddr);
  if (ok && !bow_hr_bist(region / 4u, words, 16u, HR_BIST_WRITE | HR_BIST_READ | HR_BIST_COUNT, seed0, &r)) {
    ok = detail("count: %u errors, first at word %08x", r.errors, r.faddr);
  }
  (void)bow_hr_inval();
  return ok;
}

static bool t_twin(void) {
  bow_hr_bist_res_t r;
  uint32_t base = region / 2u, words = 256u;   /* bytes base .. base + 512 */
  for (uint32_t pass = 0; pass < 2u; pass++) {
    bool count = pass != 0u;
    if (!bow_hr_bist(base / 2u, words, 32u, HR_BIST_WRITE | (count ? HR_BIST_COUNT : 0u), seed0 + pass, &r)) {
      return detail("BIST write failed (%u errors)%s", r.errors, 0);
    }
    (void)bow_hr_inval();
    uint32_t x = seed0 + pass;
    if (x == 0u) x = 1u;
    for (uint32_t i = 0; i < words; i += 2u) {
      uint32_t v, e0, e1;
      if (count) {
        e0 = ((base / 2u + i) ^ (seed0 + pass)) & 0xFFFFu;
        e1 = ((base / 2u + i + 1u) ^ (seed0 + pass)) & 0xFFFFu;
      } else {
        e0 = x & 0xFFFFu;
        x = mt_xs32(x);
        e1 = x & 0xFFFFu;
        x = mt_xs32(x);
      }
      if (!bow_probe_read32(BOW32_HYPERRAM_BASE + base + 2u * i, &v)) return detail("bus error%s%s", 0, 0);
      if (v != (e0 | (e1 << 16))) return detail("word %u: %08x", i, v);
    }
  }
  return true;
}

static bool t_variable(void) {
  mt_res_t r;
  uint32_t st0[16], st1[16];
  bow_hr_config_t c = app.cfg;
  c.fixed = false;
  if (app.info.has_ls) {   /* the card: fixed latency only, the driver must refuse */
    if (bow_hr_configure(&c)) {
      (void)bow_hr_configure(&app.cfg);
      return detail("level shifters: variable latency accepted%s%s", 0, 0);
    }
    (void)detail("level shifters: variable latency refused (fixed only)%s%s", 0, 0);
    return true;
  }
  mt_clear(&r);
  bool ok = bow_hr_flush() && bow_hr_configure(&c) && bow_hr_snap(st0) &&
            mt_fill(0x2000u, 2048u, seed0 + 7u, &r) && mt_check(0x2000u, 2048u, seed0 + 7u, &r) &&
            bow_hr_snap(st1);
  if (!ok) mt_report(&r);
  uint32_t n = st1[HR_STAT_RD_TXN] + st1[HR_STAT_WR_TXN] - st0[HR_STAT_RD_TXN] - st0[HR_STAT_WR_TXN];
  uint32_t x2 = st1[HR_STAT_LAT2X] - st0[HR_STAT_LAT2X];
  if (ok && (n == 0u || x2 >= n)) ok = detail("variable latency: %u transactions, %u with 2x", n, x2);
  c.fixed = app.cfg.fixed;
  if (!bow_hr_configure(&c)) ok = detail("back to fixed latency failed%s%s", 0, 0);
  return ok;
}

static bool t_sleep(void) {
  mt_res_t r;
  uint32_t v;
  mt_clear(&r);
  if (!mt_fill(0x3000u, 1024u, seed0 + 9u, &r) || !bow_hr_hybrid_sleep()) return detail("fill / sleep failed%s%s", 0, 0);
  bool ok = true;
  (void)bow_hr_inval();
  if (bow_probe_read32(BOW32_HYPERRAM_BASE + 0x3000u, &v)) ok = detail("window open in hybrid sleep%s%s", 0, 0);
  if (!bow_hr_wake()) return detail("wake failed (STATUS %08x)%s", BOW_HR_RD(STATUS), 0);
  BOW_HR_WR(STATUS, HR_ST_NOT_READY | HR_ST_RD_ERR);
  if (!mt_check(0x3000u, 1024u, seed0 + 9u, &r)) ok = mt_ok(false, &r);
  return ok;
}

static bool t_dpd(void) {
  mt_res_t r;
  mt_clear(&r);
  if (!bow_hr_deep_power_down()) return detail("enter failed%s%s", 0, 0);
  if (!bow_hr_wake()) return detail("wake failed (STATUS %08x)%s", BOW_HR_RD(STATUS), 0);
  if ((BOW_HR_RD(CR0) & 0xFFFFu) != HR_CR0_DEFAULT) return detail("CR0 shadow %04x after wake%s", BOW_HR_RD(CR0), 0);
  uint16_t cr0;
  if (!bow_hr_reg_read(HR_REG_CR0, &cr0) || cr0 != HR_CR0_DEFAULT) return detail("CR0 %04x after wake%s", cr0, 0);
  /* data are lost: configure again, the window works */
  if (!bow_hr_configure(&app.cfg)) return detail("configure failed%s%s", 0, 0);
  return mt_ok(mt_fill(0, 2048u, seed0 + 11u, &r) && mt_check(0, 2048u, seed0 + 11u, &r), &r);
}

static bool t_limits(void) {
  int32_t p = bow_hr_phase_now(), w = bow_hr_wphase_now();
  int32_t steps = (int32_t)app.info.ps_steps;
  bool ok = true;
  if (bow_hr_set_phase(p + 2 * steps + 1)) ok = detail("PS_GO 2 CK + 1 accepted%s%s", 0, 0);
  if (bow_hr_set_wphase((int32_t)HR_WPS_LIMIT(steps) + 1)) ok = detail("WPS_GO 3 CK / 16 + 1 accepted%s%s", 0, 0);
  if (bow_hr_phase_now() != p || bow_hr_wphase_now() != w) ok = detail("phase moved: %d %d", bow_hr_phase_now(), bow_hr_wphase_now());
  BOW_HR_WR(STATUS, HR_ST_CMD_ERR);
  return ok;
}

static bool t_irq(void) {
  uint32_t bit = MIE_FAST(BOW32_IRQ_FAST_HYPERRAM);
  bool ok = true;
  BOW_HR_WR(STATUS, HR_ST_W1C);
  BOW_HR_WR(IRQ_EN, HR_ST_CMD_DONE);
  if (CSR_READ(mip) & bit) ok = detail("irq pending before the command%s%s", 0, 0);
  BOW_HR_WR(CMD, HR_CMD_SNAP);
  uint32_t t0 = bow_cycles();
  while (!(BOW_HR_RD(STATUS) & HR_ST_CMD_DONE) && (uint32_t)(bow_cycles() - t0) < 100000u) {
  }
  if (!(CSR_READ(mip) & bit)) ok = detail("no irq on CMD_DONE (STATUS %08x)%s", BOW_HR_RD(STATUS), 0);
  BOW_HR_WR(STATUS, HR_ST_CMD_DONE);
  if (CSR_READ(mip) & bit) ok = detail("irq after CMD_DONE was cleared%s%s", 0, 0);
  BOW_HR_WR(IRQ_EN, 0);
  return ok;
}

static bool t_flags(void) {
  uint32_t st = BOW_HR_RD(STATUS), bad = HR_ST_RFIFO_ERR | HR_ST_BUS_TIMEOUT | HR_ST_TCSM_ERR |
                                         HR_ST_BIST_ERR | HR_ST_WR_ERR | HR_ST_RFIFO_BROKEN | HR_ST_BROKEN |
                                         HR_ST_DBG_ERR;
  uint32_t dbg = BOW_HR_RD(DBG);
  if (st & bad) return detail("STATUS %08x DBG %08x", st, dbg);
  if (dbg & HR_DBG_ERR) return detail("emulator error code %02x count %u", HR_DBG_CODE(dbg), HR_DBG_COUNT(dbg));
  return true;
}

/* ------------------------------------------------------------------ runner */
bool self_test(bool quick, uint32_t seed) {
  checks = failures = 0;
  seed0 = seed ? seed : 1u;
  bow_printf("hyperram: self-test (%s, seed %u)\n", quick ? "quick" : "full", seed0);

  check(t_present(), "IP present: ID, INFO, CLK_HZ, HyperRAM clock");
  check(app.present && t_refused(), "refused: 2 CMD bits, ID0 write, window while not READY");
  check(app.present && t_init(), "init: RESET#, ID0 eye, CR0 / CR1, pattern eye, window open");
  region = quick ? 0x10000u : (app.info.test_bytes < (1u << 20) ? app.info.test_bytes : (1u << 20));
  bool mem = app.inited;
  check(mem && t_regs(), "device registers: ID0, ID1, CR0 = shadow, CR1");
  check(mem && t_walk(), "window: walking ones / zeros on the data bits");
  check(mem && t_lines(), "window: address lines (unique word at 0 and every 2^k)");
  check(mem && t_addr(), "window: address in address, inverted");
  check(mem && t_bytes(), "window: byte / halfword stores (RWDS masks)");
  check(mem && t_fill(), "window: xorshift fill / check, posted and non-posted writes");
  check(mem && t_rbuf(), "read buffer: critical word first, hits, write through");
  check(mem && t_range(), "window: beyond the device size: bus error, RANGE, ERR_ADDR");
  check(mem && t_bist(), "BIST: PRBS and counter data, write + read");
  check(mem && t_twin(), "BIST data read through the window = C twin");
  check(mem && t_variable(), "variable latency: traffic, refresh collisions (2x) counted");
  check(mem && t_sleep(), "hybrid sleep: window refused, wake, data kept");
  check(mem && t_dpd(), "deep power down: wake, registers to defaults, configure again");
  check(mem && t_limits(), "limits: PS_GO / WPS_GO beyond the limits refused");
  check(mem && t_irq(), "interrupt: CMD_DONE on irq_fast[12]");
  check(app.present && t_flags(), "no RFIFO / bus timeout / TCSM error, DBG model ok");

  bow_printf("hyperram: %s (%u/%u)\n", failures ? "FAIL" : "PASS", checks - failures, checks);
  return failures == 0 && checks == NUM_CHECKS;
}
