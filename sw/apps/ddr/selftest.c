/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * ddr: `test [quick|full] [seed]`, the self-test of the IP and the memory.
 * Every check prints "  [ n] <name> ... ok" (or FAIL with detail lines
 * before it); the run ends with "ddr: PASS (n/n)" or "ddr: FAIL (k/n)".
 * The test stops the DRAM, initialises and calibrates it itself (also when
 * that was done before) and overwrites the test region (quick: small parts
 * of it, for the simulation). It leaves the memory READY.
 *
 * Window regions: the test region C (the DRAM, cut to the emulator storage)
 * is cut in 16 parts, part n at n * C / 16 (1 walk + bytes, 2 address, 3
 * random, 4 data kept over an eye sweep, 5 BIST, 6 BIST data / errors, 7
 * March C- and the data kept over a refresh pause, 8 retention).
 */
#include "ddr_app.h"

#define NUM_CHECKS 21u
#define SW_MAX_US  50u   /* longest DFII software section (the DRAM models flag 70 us) */
#define PAUSE_US   50u   /* refresh pause of the monitor check (REF_STARVE at 8 x 3.9 us) */

typedef struct {
  uint32_t cal_step, eye_step, bytes, addr, rand, bist, twin, eye_data, ret, ret_ms, samples;
  uint32_t march, ref_us;
} plan_t;

static const plan_t plan_quick = {
    .cal_step = 8, .eye_step = 24, .bytes = 256, .addr = 1024, .rand = 1024, .bist = 512,
    .twin = 512, .eye_data = 256, .ret = 1024, .ret_ms = 2, .samples = 4, .march = 1024,
    .ref_us = 200};
static const plan_t plan_full = {
    .cal_step = 2, .eye_step = 6, .bytes = 4096, .addr = 256u << 10, .rand = 1u << 20,
    .bist = 0 /* whole test region */, .twin = 8192, .eye_data = 4096, .ret = 64u << 10,
    .ret_ms = 1000, .samples = 28, .march = 64u << 10, .ref_us = 2000};

static unsigned checks, failures;
static uint32_t rng_state, seed0;
static plan_t pl;
static uint32_t test_log2, part, wbytes;
static uint32_t faults0; /* bow_ld_csr_faults at the start (after the deliberate ones) */
static uint32_t err_seen; /* STATUS error flags before the eye sweep (it clears some), for check 18 */

static uint32_t rng(void) { return rng_state = mt_xs32(rng_state); }

static void check(bool ok, const char *what) {
  checks++;
  if (!ok) failures++;
  bow_printf("  [%2u] ", checks);
  print_left(what, 62);
  bow_printf(" %s\n", ok ? "ok" : "FAIL");
}

static bool detail(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  bow_puts("       ");
  bow_vprintf(fmt, ap);
  bow_puts("\n");
  va_end(ap);
  return false;
}

static uint32_t region(uint32_t n) { return n * part; }

static uint32_t clamp(uint32_t len) { return len > part ? part : len; }

static bool ready(void) {
  uint32_t st = BOW_DDR_RD(STATUS);
  if (st & DDR_ST_READY) return true;
  return detail("not READY (STATUS %08x)", st);
}

static bool mt_ok(bool ok, const mt_res_t *r) {
  if (!ok) mt_report(r);
  return ok;
}

/* ERR_ADDR: the window offset in [28:0] (a bus address or an offset) */
static bool err_addr_is(uint32_t off) { return (BOW_DDR_RD(ERR_ADDR) & 0x1FFFFFFFu) == off; }

/* ---------------------------------------------------------------- checks */
static bool t_present(void) {
  bow_ddr_info_t *i = &app.info;
  app.present = bow_ddr_probe(i);
  if (!app.present) {
    if (i->bus_error) return detail("no answer at %08x", BOW32_DDR_PHY_BASE);
    return detail("ID %08x INFO %08x (stub: DdrEn = 0?)", i->id, i->info);
  }
  bool ok = true;
  const bow_ld_core_t *k = bow_ld_core(i);
  uint32_t mhz = (i->clk_hz + 500000u) / 1000000u;
  if (!bow_ddr_wait_clk(10)) {
    ok = detail("link down or DDR clock not running (STATUS %08x)", BOW_DDR_RD(STATUS));
  }
  if (i->dq_bits != k->databits || i->lanes != i->dq_bits / 8u || (1u << i->mem_log2) != k->mem_bytes ||
      i->has_dm != i->ddr3 || i->has_reset_n != i->ddr3) {
    ok = detail("INFO %08x: x%u, %u lanes, %u MiB, DM %u RESET# %u; LiteDRAM %s core x%u %u MiB",
                i->info, i->dq_bits, i->lanes, (1u << i->mem_log2) >> 20, i->has_dm,
                i->has_reset_n, k->name, k->databits, k->mem_bytes >> 20);
  }
  if (i->ps_steps == 0 || mhz == 0 || DDR_INFO_MHZ(i->info) + 1u < mhz ||
      DDR_INFO_MHZ(i->info) > mhz + 1u) {
    ok = detail("CLK_HZ %u, INFO %u MHz, %u phase steps", i->clk_hz, DDR_INFO_MHZ(i->info),
                i->ps_steps);
  }
  if (i->phy == DDR_PHY_NONE) ok = detail("INFO: no PHY, no memory to test");
  if (i->rd_lat == 0) ok = detail("INFO %08x: DFI read latency 0", i->info);
  if (!bow_ld_csr_ok()) {
    ok = detail("LiteDRAM CSRs at %08x do not answer (STATUS %08x)", BOW32_DDR_CTRL_BASE,
                BOW_DDR_RD(STATUS));
  }
  return ok;
}

/* With the DRAM stopped (CKE / RESET# low): refused CMD, window bus errors
 * while not READY, the CSR bridge during CORE_RST and the reset values. */
static bool t_reset(void) {
  bool ok = true;
  uint32_t v, st;
  if (!app.present) return false;
  app.inited = app.calibrated = false;
  if (!bow_ld_stop()) ok = detail("stop: APPLY refused (STATUS %08x)", BOW_DDR_RD(STATUS));
  BOW_DDR_WR(STATUS, DDR_ST_W1C);
  BOW_DDR_WR(CMD, DDR_CMD_APPLY | DDR_CMD_SNAP);
  st = BOW_DDR_RD(STATUS);
  for (unsigned i = 0; i < 100u && (st & DDR_ST_BUSY); i++) st = BOW_DDR_RD(STATUS);
  if ((st & (DDR_ST_CMD_ERR | DDR_ST_APPLIED | DDR_ST_BUSY)) != DDR_ST_CMD_ERR) {
    ok = detail("CMD with two bits: STATUS %08x", st);
  }
  BOW_DDR_WR(STATUS, DDR_ST_W1C);
  if (win_rd(0x40, &v)) ok = detail("window read answered while not READY (%08x)", v);
  st = BOW_DDR_RD(STATUS);
  if ((st & (DDR_ST_NOT_READY | DDR_ST_READY)) != DDR_ST_NOT_READY || !err_addr_is(0x40)) {
    ok = detail("window read while not READY: STATUS %08x ERR_ADDR %08x", st, BOW_DDR_RD(ERR_ADDR));
  }
  if (win_wr(0x80, 0x12345678u)) ok = detail("window write answered while not READY");
  if (!err_addr_is(0x80)) ok = detail("window write while not READY: ERR_ADDR %08x", BOW_DDR_RD(ERR_ADDR));
  if (!bow_ddr_core_reset(true)) ok = detail("APPLY of CTRL.CORE_RST refused");
  BOW_DDR_WR(STATUS, DDR_ST_CSR_ERR);
  if (bow_ld_csr_ok()) ok = detail("LiteDRAM CSR read answered during CORE_RST");
  st = BOW_DDR_RD(STATUS);
  if ((st & (DDR_ST_CSR_ERR | DDR_ST_READY)) != DDR_ST_CSR_ERR) {
    ok = detail("CSR read during CORE_RST: STATUS %08x", st);
  }
  if (!bow_ddr_core_reset(false)) {
    ok = detail("LiteDRAM CSRs do not answer after CORE_RST (STATUS %08x)", BOW_DDR_RD(STATUS));
  } else {
    uint32_t dfii = bow_ld_dfii_control();
    st = BOW_DDR_RD(STATUS);
    if (dfii != BOW_LD_DFII_SEL || (st & (DDR_ST_INIT_DONE | DDR_ST_INIT_ERROR | DDR_ST_BROKEN))) {
      ok = detail("after CORE_RST: dfii_control %02x (expected 01), STATUS %08x", dfii, st);
    }
  }
  BOW_DDR_WR(STATUS, DDR_ST_W1C);
  faults0 = bow_ld_csr_faults;
  return ok;
}

static bool t_init(void) {
  if (!app.present || !app_init(true)) return false;
  bool ok = true;
  uint32_t ctrl = BOW_DDR_RD(CTRL), lat = BOW_DDR_RD(LAT);
  uint32_t want_ctrl = bow_ddr_config_ctrl(&app.cfg, &app.info), want_lat = bow_ddr_config_lat(&app.cfg);
  if (ctrl != want_ctrl || lat != want_lat) {
    ok = detail("CTRL %08x LAT %08x, expected %08x %08x", ctrl, lat, want_ctrl, want_lat);
  }
  uint32_t dfii = bow_ld_dfii_control();
  if (dfii != BOW_LD_DFII_HW) ok = detail("dfii_control %02x after init, expected 0f", dfii);
  /* the generated sequence: commands on phase 0, CKE raised by a control
   * write, last command EMR1 OCD exit (DDR2) / ZQCL (DDR3) */
  const bow_ld_trace_t *t;
  uint32_t n = bow_ld_init_trace(&t), cmds = 0;
  bool cke = false, phase0 = true, last = false;
  for (uint32_t i = 0; i < n; i++) {
    if (t[i].kind == 'c') {
      if ((t[i].cmd & (BOW_LD_DFII_CKE | BOW_LD_DFII_SEL)) == BOW_LD_DFII_CKE) cke = true;
    } else {
      cmds++;
      if (t[i].phase) phase0 = false;
    }
  }
  if (n && t[n - 1].kind == 'x') {
    const bow_ld_trace_t *e = &t[n - 1];
    last = app.info.ddr3 ? (e->cmd & BOW_LD_CMD_PINS) == BOW_LD_CMD_ZQ && (e->a & BOW_LD_A10)
                         : (e->cmd & BOW_LD_CMD_PINS) == BOW_LD_CMD_MRS && e->ba == 1u &&
                               (e->a & 0x380u) == 0;
  }
  if (cmds < 5u || !cke || !phase0 || !last) {
    ok = detail("init trace: %u entries, %u commands, CKE %u, phase 0 %u, last command %u", n,
                cmds, cke, phase0, last);
  }
  if (app.info.emu_log2) {
    uint32_t dbg = bow_ddr_dbg();
    if (!(dbg & DDR_DBG_INIT_DONE) || (dbg & DDR_DBG_ERR)) {
      ok = detail("DBG %08x: emulator init done %u, %u errors, first code %02x", dbg,
                  (dbg >> 30) & 1u, DDR_DBG_COUNT(dbg), DDR_DBG_CODE(dbg));
    }
  }
  /* the controller refreshes now (hardware control) */
  bow_ddr_stats_t s0, s1;
  bool snap = bow_ddr_stats(&s0, false);
  bow_delay_us(40);
  snap = bow_ddr_stats(&s1, false) && snap;
  if (!snap || s1.ref - s0.ref < 2u) {
    ok = detail("%u REF in 40 us of DFII hardware control (SNAP %u)", s1.ref - s0.ref, snap);
  }
  return ok;
}

static bool t_cal(void) {
  if (!app.inited) return false;
  bow_ld_sw_max_clear();
  if (!app_calibrate(pl.cal_step, true)) return false;
  bool ok = ready();
  uint32_t st = BOW_DDR_RD(STATUS);
  if ((st & (DDR_ST_INIT_DONE | DDR_ST_INIT_ERROR)) != DDR_ST_INIT_DONE) {
    ok = detail("STATUS %08x: INIT_DONE / INIT_ERROR after the hand-over", st);
  }
  if (bow_ld_sw_max_us() > SW_MAX_US) {
    ok = detail("longest DFII software section %u us (limit %u)", bow_ld_sw_max_us(), SW_MAX_US);
  }
  return ok;
}

static bool t_walk(void) {
  mt_res_t r;
  mt_clear(&r);
  return ready() && mt_ok(mt_walk(region(1), &r), &r);
}

static bool t_lines(void) {
  mt_res_t r;
  mt_clear(&r);
  if (!ready()) return false;
  if (mt_addr_lines(test_log2, &r)) return true;
  mt_report(&r);
  if (r.errors) {
    uint32_t bad = r.off ? 31u - (uint32_t)__builtin_clz(r.off) : 0u;
    detail("suspect window address bit %u", bad);
  }
  return false;
}

static bool t_addr(void) {
  mt_res_t r;
  mt_clear(&r);
  return ready() && mt_ok(mt_addr(region(2), clamp(pl.addr), &r), &r);
}

static bool t_bytes(void) {
  mt_res_t r;
  bow_ddr_stats_t s;
  mt_clear(&r);
  if (!ready() || !bow_ddr_stats(&s, true)) return false;
  bool ok = mt_ok(mt_bytes(region(1) + 0x1000u, clamp(pl.bytes), seed0 + 1u, &r), &r);
  if (!bow_ddr_stats(&s, false)) return detail("SNAP refused");
  bool dm = app.info.has_dm && app.cfg.dm_en;
  uint32_t want = dm ? 0u : r.writes;
  if (s.rmw != want) ok = detail("ST_RMW %u after %u stores, expected %u", s.rmw, r.writes, want);
  if (s.wr < r.writes) ok = detail("ST_WR %u after %u stores", s.wr, r.writes);
  if (s.rd < r.words / 2u) ok = detail("ST_RD %u after %u loads", s.rd, r.words);
  return ok;
}

static bool t_rand(void) {
  mt_res_t r;
  mt_clear(&r);
  uint32_t len = clamp(pl.rand);
  return ready() && mt_ok(mt_fill(region(3), len, seed0 + 2u, &r) &&
                              mt_check(region(3), len, seed0 + 2u, &r), &r);
}

/* Offsets at the DRAM size and at the end of the 512 MiB decode: bus
 * error, RANGE, ERR_ADDR, nothing else changes. */
static bool t_range(void) {
  bool ok = true;
  uint32_t v, offs[2] = {1u << app.info.mem_log2, BOW32_DDR_SIZE - 4u};
  if (!ready()) return false;
  for (uint32_t i = 0; i < 2u; i++) {
    BOW_DDR_WR(STATUS, DDR_ST_RANGE);
    if (win_rd(offs[i], &v)) ok = detail("read at offset %08x answered (%08x)", offs[i], v);
    uint32_t st = BOW_DDR_RD(STATUS);
    if (!(st & DDR_ST_RANGE) || !err_addr_is(offs[i])) {
      ok = detail("offset %08x: STATUS %08x ERR_ADDR %08x", offs[i], st, BOW_DDR_RD(ERR_ADDR));
    }
    if (win_wr(offs[i], 0x5A5A5A5Au)) ok = detail("write at offset %08x answered", offs[i]);
  }
  BOW_DDR_WR(STATUS, DDR_ST_RANGE);
  if (!ready() || !win_rd(0, &v)) ok = detail("window unusable after the range errors");
  return ok;
}

static bool t_bist(void) {
  bool ok = true;
  if (!ready()) return false;
  uint32_t base = pl.bist ? region(5) : 0u, len = pl.bist ? pl.bist : 1u << test_log2;
  for (uint32_t m = 0; m < 2u; m++) {
    bool random = m == 0;
    for (uint32_t o = 0; o < len;) {
      uint32_t n = len - o > (16u << 20) ? 16u << 20 : len - o;
      bow_ld_bist_t b = {.base = base + o, .length = n, .random = random, .write = true, .read = true};
      bow_ld_bist_res_t res;
      if (!bow_ld_bist(&b, &res)) {
        ok = detail("%s data at %08x + %u: done %u errors %u", random ? "PRBS" : "counter", b.base,
                    n, res.done, res.errors);
        break;
      }
      if (res.wr_ticks < n / wbytes || res.rd_ticks < n / wbytes) {
        ok = detail("%s data: %u / %u ticks for %u words", random ? "PRBS" : "counter",
                    res.wr_ticks, res.rd_ticks, n / wbytes);
      }
      o += n;
    }
  }
  return ok;
}

/* BIST writes read back through the window, compared with the C twin of
 * the generator; the words just below and above the region are kept. */
static bool t_twin(void) {
  mt_res_t r;
  bool ok = true;
  uint32_t offs[32], v0 = 0, v1 = 0;
  if (!ready()) return false;
  uint32_t base = region(6), len = clamp(pl.twin), lo = base - 4u, hi = base + len;
  if (!win_wr(lo, 0xC0FFEE00u) || !win_wr(hi, 0xC0FFEE01u)) {
    return detail("window write next to the BIST region");
  }
  uint32_t n = pl.samples + 3u > 32u ? 32u : pl.samples + 3u;
  for (uint32_t m = 0; m < 2u; m++) {
    bool random = m == 0;
    bow_ld_bist_t b = {.base = base, .length = len, .random = random, .write = true};
    if (!bow_ld_bist(&b, NULL)) {
      ok = detail("BIST write of %s data", random ? "PRBS" : "counter");
      continue;
    }
    offs[0] = 0;
    offs[1] = wbytes + 4u;
    offs[2] = len - 4u;
    for (uint32_t i = 3; i < n; i++) offs[i] = (rng() % len) & ~3u;
    mt_clear(&r);
    if (!bist_twin(base, random, offs, n, &r)) {
      ok = detail("%s data at %08x: window %08x, C twin %08x%s", random ? "PRBS" : "counter",
                  BOW32_DDR_BASE + r.off, r.got, r.exp, r.bus_error ? " (bus error)" : "");
    }
  }
  if (!win_rd(lo, &v0) || !win_rd(hi, &v1) || v0 != 0xC0FFEE00u || v1 != 0xC0FFEE01u) {
    ok = detail("words next to the BIST region: %08x %08x", v0, v1);
  }
  return ok;
}

/* The checker counts the words that differ: PRBS expected over counter
 * data (count from the C twin), then one window store into counter data. */
static bool t_bist_err(void) {
  bool ok = true;
  bow_ld_bist_res_t res;
  if (!ready()) return false;
  uint32_t base = region(6), len = clamp(pl.twin), words = len / wbytes, want = 0, v;
  bow_ld_bist_t b = {.base = base, .length = len, .random = false, .write = true};
  if (!bow_ld_bist(&b, &res)) return detail("counter write: done %u", res.done);
  bow_ld_gen_t gp, gc;
  bow_ld_gen_start(&gp, true);
  bow_ld_gen_start(&gc, false);
  for (uint32_t k = 0; k < words; k++) {
    if (gp.o != gc.o) want++;
    bow_ld_gen_next(&gp);
    bow_ld_gen_next(&gc);
  }
  b.write = false;
  b.read = true;
  b.random = true;
  bow_ld_bist(&b, &res);
  if (!res.done || res.errors != want) {
    ok = detail("PRBS check of counter data: done %u errors %u, expected %u", res.done, res.errors,
                want);
  }
  uint32_t o = base + 5u * wbytes + 4u;
  if (!win_rd(o, &v) || !win_wr(o, ~v)) return detail("window access at %08x", BOW32_DDR_BASE + o);
  b.random = false;
  bow_ld_bist(&b, &res);
  if (!res.done || res.errors != 1u) {
    ok = detail("counter check after one window store: done %u errors %u, expected 1", res.done,
                res.errors);
  }
  return ok;
}

/* REF interval of a core in ns: its TRefi controller cycles of CK / 4
 * (DDR2 129 x 30 ns = 3870 ns, DDR3 121 x 32 ns = 3872 ns); CTRL.REF_NORM
 * doubles the interval at the DRAM */
static uint32_t trefi_ns(const bow_ld_core_t *k) {
  uint64_t hz = app.info.clk_hz ? app.info.clk_hz : 1u;
  uint64_t ns = ((uint64_t)k->trefi_cycles * 4000000000u + hz / 2u) / hz;
  return ns ? (uint32_t)ns : 1u;
}

static bool t_retention(void) {
  mt_res_t r;
  bow_ddr_stats_t s;
  mt_clear(&r);
  if (!ready()) return false;
  uint32_t len = clamp(pl.ret);
  bool ok = mt_fill(region(8), len, seed0 + 6u, &r);
  ok = ok && bow_ddr_cmd(DDR_CMD_CLR_STATS);
  uint32_t t0 = bow_cycles();
  bow_delay_ms(pl.ret_ms);
  uint32_t us = (uint32_t)((uint64_t)(bow_cycles() - t0) * 1000000u / bow_clk_hz());
  ok = bow_ddr_stats(&s, false) && ok;
  ok = mt_ok(mt_check(region(8), len, seed0 + 6u, &r), &r) && ok;
  const bow_ld_core_t *k = bow_ld_core(&app.info);
  uint32_t trefi = trefi_ns(k) * ((BOW_DDR_RD(CTRL) & DDR_CTRL_REF_NORM) ? 2u : 1u);
  uint32_t want = (uint32_t)((uint64_t)us * 1000u / trefi);
  if (s.ref < want - want / 4u || s.ref > want + want / 4u + 9u) {
    ok = detail("%u REF in %u us, expected about %u (tREFI %u ns = %u cycles of the %s core)", s.ref,
                us, want, trefi, k->trefi_cycles, k->name);
  }
  return ok;
}

/* REF rate at the DRAM with REF_NORM = 0 (every REF of the core, 3.9 us)
 * and 1 (every second one, 7.8 us), and the longest REF interval of the
 * refresh monitor (on since the hand-over); the policy is restored. */
static bool t_refresh(void) {
  bool ok = true;
  bow_ddr_stats_t s;
  if (!ready()) return false;
  const bow_ld_core_t *k = bow_ld_core(&app.info);
  bool norm0 = bow_ld_refresh_norm();
  if (!(BOW_DDR_RD(CTRL) & DDR_CTRL_REF_MON)) {
    ok = detail("refresh monitor off after the hand-over (CTRL %08x)", BOW_DDR_RD(CTRL));
  }
  for (uint32_t norm = 0; norm < 2u; norm++) {
    uint32_t iv = trefi_ns(k) * (norm + 1u);
    bow_ld_set_refresh_norm(norm != 0u);
    bow_delay_us(4u * trefi_ns(k) / 1000u + 1u); /* the new period starts at the next REF */
    /* the REFs between CLR_STATS and SNAP: at least those of the inner
     * window [t0, t1], at most those of the outer one (the commands take
     * their time, more so when the code runs from flash) */
    uint32_t a = bow_cycles();
    ok = bow_ddr_cmd(DDR_CMD_CLR_STATS) && ok;
    uint32_t t0 = bow_cycles();
    bow_delay_us(pl.ref_us);
    uint32_t t1 = bow_cycles();
    ok = bow_ddr_stats(&s, false) && ok;
    uint32_t b = bow_cycles(), mhz = bow_clk_hz() / 1000000u;
    uint32_t in_us = (t1 - t0) / mhz, out_us = (b - a) / mhz + 1u;
    uint32_t lo = in_us * 1000u / iv, hi = out_us * 1000u / iv + 1u;
    uint32_t ck = 4u * k->trefi_cycles * (norm + 1u);
    if (s.ref + 1u < lo || s.ref > hi) {
      ok = detail("REF_NORM %u: %u REF in %u .. %u us, expected %u .. %u (one per %u ns)", norm,
                  s.ref, in_us, out_us, lo - 1u, hi, iv);
    }
    if (s.rgap + 1u + 8u < ck || s.rgap + 1u > ck + 64u) {
      ok = detail("REF_NORM %u: longest REF interval %u CK, expected %u", norm, s.rgap + 1u, ck);
    }
  }
  bow_ld_set_refresh_norm(norm0);
  if (BOW_DDR_RD(STATUS) & DDR_ST_REF_STARVE) ok = detail("REF_STARVE with the refresh running");
  return ok;
}

/* Refresh monitor: the refresh stopped (DFII software control, REF_MON on,
 * 3.9 us) ends in REF_STARVE and an interrupt 8 intervals after the last
 * REF; the data are kept, READY comes back. */
static bool t_refmon(void) {
  const uint32_t bit = MIE_FAST(BOW32_IRQ_FAST_DDR);
  bool ok = true;
  mt_res_t r;
  uint32_t us;
  mt_clear(&r);
  if (!ready()) return false;
  const bow_ld_core_t *k = bow_ld_core(&app.info);
  bool norm0 = bow_ld_refresh_norm();
  uint32_t lim = 8u * trefi_ns(k) / 1000u; /* REF_STARVE this long after the last REF */
  ok = mt_fill(region(7), 256, seed0 + 10u, &r) && ok;
  bow_ld_set_refresh_norm(false);
  BOW_DDR_WR(STATUS, DDR_ST_REF_STARVE);
  BOW_DDR_WR(IRQ_EN, DDR_ST_REF_STARVE);
  if (!bow_ld_refresh_pause(PAUSE_US, &us)) {
    ok = detail("refresh pause: no REF_STARVE within %u us (STATUS %08x)", PAUSE_US, BOW_DDR_RD(STATUS));
  } else {
    if (us + lim / 8u + 2u < lim || us > lim + 4u) {
      ok = detail("REF_STARVE %u us after the refresh stopped, expected %u .. %u us", us,
                  lim - lim / 8u - 2u, lim + 4u);
    }
    if (!(CSR_READ(mip) & bit)) ok = detail("no irq on REF_STARVE");
  }
  BOW_DDR_WR(STATUS, DDR_ST_REF_STARVE);
  if (CSR_READ(mip) & bit) ok = detail("irq after REF_STARVE was cleared");
  BOW_DDR_WR(IRQ_EN, 0);
  bow_ld_set_refresh_norm(norm0);
  if (!ready()) ok = false;
  ok = mt_ok(mt_check(region(7), 256, seed0 + 10u, &r), &r) && ok;
  return ok;
}

/* March C- on whole words (stuck-at, transition, address decoder and
 * coupling faults). */
static bool t_march(void) {
  mt_res_t r;
  mt_clear(&r);
  if (!ready()) return false;
  return mt_ok(mt_march(region(7), clamp(pl.march), &r), &r);
}

/* An eye sweep after the hand-over (DFII sections while the controller
 * owns the DRAM): phase, LAT and READY come back, data and BIST survive. */
static bool t_eye(void) {
  mt_res_t r;
  bow_ld_cal_t e;
  mt_clear(&r);
  if (!ready()) return false;
  uint32_t len = clamp(pl.eye_data), lat = BOW_DDR_RD(LAT);
  int32_t ph = bow_ddr_ps_now();
  bool ok = mt_fill(region(4), len, seed0 + 8u, &r);
  ok = mt_fill(0, 2u * wbytes, seed0 + 9u, &r) && ok;  /* under the training pattern */
  /* the sweep clears RD_LATE / RD_EXTRA to check its own reads: keep the
   * error flags of the checks before it for check 18 */
  err_seen |= BOW_DDR_RD(STATUS) & DDR_ST_ERRORS;
  if (!bow_ld_eye(pl.eye_step, false, &e)) {
    ok = detail("eye sweep: %s (%u of %u points good)", e.err ? e.err : "phase / READY not restored",
                e.good, e.npts);
  }
  uint32_t st = BOW_DDR_RD(STATUS);
  if (!(st & DDR_ST_READY) || bow_ddr_ps_now() != ph || BOW_DDR_RD(LAT) != lat) {
    ok = detail("after the sweep: STATUS %08x phase %d (was %d) LAT %08x (was %08x)", st,
                bow_ddr_ps_now(), ph, BOW_DDR_RD(LAT), lat);
  }
  ok = mt_ok(mt_check(region(4), len, seed0 + 8u, &r), &r) && ok;
  ok = mt_ok(mt_check(0, 2u * wbytes, seed0 + 9u, &r), &r) && ok;
  bow_ld_bist_t b = {.base = region(5), .length = 64u * wbytes, .random = true, .write = true,
                     .read = true};
  bow_ld_bist_res_t res;
  if (!bow_ld_bist(&b, &res)) ok = detail("BIST after the sweep: done %u errors %u", res.done, res.errors);
  return ok;
}

/* Out of range phase targets are refused (PS_ERR) and change nothing. */
static bool t_limits(void) {
  bool ok = true;
  mt_res_t r;
  if (!ready()) return false;
  uint32_t n = app.info.ps_steps;
  int32_t ph = bow_ddr_ps_now(), wph = bow_ddr_wps_now();
  if (bow_ddr_ps_set(2 * (int32_t)n + 1)) {
    ok = detail("PS_GO to %u accepted (2 periods from the sync phase 0)", 2u * n + 1u);
    bow_ddr_ps_set(ph);
  }
  uint32_t st = BOW_DDR_RD(STATUS);
  if ((st & (DDR_ST_PS_DONE | DDR_ST_PS_ERR)) != (DDR_ST_PS_DONE | DDR_ST_PS_ERR) ||
      bow_ddr_ps_now() != ph) {
    ok = detail("refused PS_GO: STATUS %08x phase %d (was %d)", st, bow_ddr_ps_now(), ph);
  }
  if (bow_ddr_wps_set((int32_t)(n / 4u) + 1)) {
    ok = detail("WPS_GO to %u accepted (limit %u)", n / 4u + 1u, n / 4u);
    bow_ddr_wps_set(wph);
  }
  if (bow_ddr_wps_now() != wph) ok = detail("write phase %d, was %d", bow_ddr_wps_now(), wph);
  if (!bow_ddr_wps_set(wph)) ok = detail("WPS_GO to the current write phase refused");
  BOW_DDR_WR(STATUS, DDR_ST_PS_ERR | DDR_ST_PS_DONE); /* only the flags provoked here (check 18) */
  /* still working with the old phases */
  mt_clear(&r);
  if (!mt_ok(mt_fill(region(3), 256, seed0 + 7u, &r) && mt_check(region(3), 256, seed0 + 7u, &r), &r)) {
    ok = detail("window after the refused commands");
  }
  return ok;
}

static bool t_irq(void) {
  const uint32_t bit = MIE_FAST(BOW32_IRQ_FAST_DDR);
  bool ok = true;
  if (!ready()) return false;
  BOW_DDR_WR(STATUS, DDR_ST_APPLIED);   /* only the flag under test: check 18 sees the others */
  BOW_DDR_WR(IRQ_EN, DDR_ST_APPLIED);
  if (CSR_READ(mip) & bit) ok = detail("irq pending before the APPLY");
  if (!bow_ddr_apply()) ok = detail("APPLY refused (STATUS %08x)", BOW_DDR_RD(STATUS));
  if (!(CSR_READ(mip) & bit)) ok = detail("no irq on APPLIED");
  BOW_DDR_WR(STATUS, DDR_ST_APPLIED);
  if (CSR_READ(mip) & bit) ok = detail("irq after APPLIED was cleared");
  BOW_DDR_WR(IRQ_EN, 0);
  return ok;
}

/* Error flags raised by any check since the init: a check that provokes one
 * on purpose clears exactly that flag itself. (Every command clears CMD_ERR
 * and a phase move PS_ERR first: their callers see a refusal directly.) */
static bool t_flags(void) {
  bool ok = true;
  uint32_t st = BOW_DDR_RD(STATUS), dbg = bow_ddr_dbg();
  uint32_t bad = DDR_ST_ERRORS | DDR_ST_DBG_ERR | DDR_ST_RFIFO_BROKEN | DDR_ST_INIT_ERROR |
                 DDR_ST_BROKEN;
  if (st & bad) ok = detail("STATUS %08x: error flags", st);
  if (err_seen & ~st) ok = detail("STATUS %08x before the eye sweep: error flags", err_seen);
  if (dbg & DDR_DBG_ERR) {
    ok = detail("DBG %08x: %u memory model errors, first code %02x", dbg, DDR_DBG_COUNT(dbg),
                DDR_DBG_CODE(dbg));
  }
  if (app.info.emu_log2 && !(dbg & DDR_DBG_INIT_DONE)) {
    ok = detail("DBG %08x: emulator not initialised", dbg);
  }
  if (bow_ld_csr_faults != faults0) {
    ok = detail("%u LiteDRAM CSR accesses failed", bow_ld_csr_faults - faults0);
  }
  if (bow_ld_sw_max_us() > SW_MAX_US) {
    ok = detail("longest DFII software section %u us (limit %u)", bow_ld_sw_max_us(), SW_MAX_US);
  }
  return ok;
}

bool self_test(bool quick, uint32_t seed) {
  checks = failures = 0;
  seed0 = seed ? seed : 1u;
  rng_state = seed0;
  pl = quick ? plan_quick : plan_full;
  faults0 = bow_ld_csr_faults;
  err_seen = 0;
  bow_printf("ddr: self-test (%s, seed %u)\n", quick ? "quick" : "full", seed0);

  check(t_present(), "IP present: ID, INFO, CLK_HZ, link, DDR clock, LiteDRAM CSRs");
  check(t_reset(), "refused: 2 CMD bits, window while not READY, CSRs in CORE_RST");
  check(t_init(), "init: LiteDRAM JEDEC sequence over DFII, controller refresh");
  check(t_cal(), "read calibration: eye, RD_DLY / RD_SLIP, verify, hand-over");
  wbytes = app.info.word_bytes;
  test_log2 = app.calibrated ? app.info.test_log2 : 0u;
  part = test_log2 >= 16u ? (1u << test_log2) / 16u : 0u;
  if (app.calibrated && part < 0x1000u) {
    detail("test region of %u bytes is below 64 KiB", 1u << test_log2);
    app.calibrated = false;
  }
  bool mem = app.calibrated;
  check(mem && t_walk(), "window: walking ones / zeros on the data bits");
  check(mem && t_lines(), "window: address lines (unique word at 0 and every 2^k)");
  check(mem && t_addr(), "window: address in address, inverted");
  check(mem && t_bytes(), "window: byte / halfword stores (read-modify-write), ST_RMW");
  check(mem && t_rand(), "window: xorshift fill / check");
  check(mem && t_march(), "window: March C- (address decoder, coupling faults)");
  check(mem && t_range(), "window: beyond the DRAM size: bus error, RANGE, ERR_ADDR");
  check(mem && t_bist(), "BIST: LiteDRAM generator + checker, PRBS and counter data");
  check(mem && t_twin(), "BIST data read through the window = C twin, neighbours kept");
  check(mem && t_bist_err(), "BIST errors: PRBS check of counter data, one window store");
  check(mem && t_retention(), "refresh: data kept while idle, ST_REF counts the REF commands");
  check(mem && t_refresh(), "refresh: 3.9 us / 7.8 us (REF_NORM), ST_RGAP of the monitor");
  check(mem && t_refmon(), "refresh monitor: REF_STARVE + irq when the refresh stops");
  check(mem && t_eye(), "eye sweep after the hand-over: phase, READY, data kept");
  check(mem && t_limits(), "limits: PS_GO / WPS_GO beyond the limits refused");
  check(mem && t_irq(), "interrupt: APPLIED on irq_fast[11]");
  check(app.present && t_flags(), "no RFIFO / bus / PS / RD_LATE / CSR error, DBG model ok");

  bow_printf("ddr: %s (%u/%u)\n", failures ? "FAIL" : "PASS", checks - failures, checks);
  return failures == 0 && checks == NUM_CHECKS;
}
