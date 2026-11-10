/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * hyperram: test of the Bow32 HyperRAM IP (bow_hyperram, docs/ip/hyperram.md)
 * from a shell on UART0, `h` for help. tools/bow32_hyperram.py and the system
 * test (sim/tb/tb_bow32.sv, TEST=hyperram) drive it and parse the lines
 * below: keep them stable.
 *
 * Every command ends with a line "ok" or "error", then the prompt "> ".
 * Output (printf notation):
 *   start    "Bow32 HyperRAM test (sw/apps/hyperram), type h for help"
 *   banner   "hyperram: Bow32 HyperRAM %u MiB x8, PHY %s, %u MHz (%u Hz), %u phase
 *            steps[, level shifters][, emulator %u KiB]" (PHY pads | loopback), or
 *            "hyperram: IP not found (bus error at 4000f000)" | "hyperram: IP not found
 *            (stub: HrEn = 0, INFO %08x)" | "hyperram: IP not found (ID %08x)";
 *            "hyperram: HyperRAM clock not running (STATUS %08x)" when CLK_OK stays 0
 *   test     "hyperram: self-test (quick|full, seed %u)", per check "  [%2u] <name
 *            padded to 62> ok|FAIL" (detail lines before a FAIL start with 7 spaces),
 *            last "hyperram: PASS (%u/%u)" or "hyperram: FAIL (%u/%u)"
 *   init     driver lines "hyperram: eye (ID0) |<map>|", "hyperram: eye (pattern)
 *            |<map>|" (one character per read phase point, '#' good, '.' bad, 64 per
 *            line, continuation lines start with 12 spaces), "hyperram: read phase %d
 *            width %u RD_DLY %u (first byte A at half cycle %u)", "hyperram: ready: ID0
 *            %04x ID1 %04x CR0 %04x, latency %u fixed|variable, TCSM %u cycles";
 *            failures "hyperram: init: <reason>" | "hyperram: calibration failed: <reason>"
 *   cal, eye the eye lines and the read phase line of init; eye then
 *            "hyperram: eye: read phase %d and RD_DLY %u restored[, window closed as
 *            before]" (phase, RD_DLY, the window state and the 32 bytes at offset 0
 *            of an open window are put back) | "... RD_DLY %u not restored, window
 *            closed: run cal or init" (ID0 fails at the old setting)
 *   calw     "hyperram: write eye |<map>|", "hyperram: write phase %d width %u"
 *   bist     "bist: words %u at %08x, bursts of %u, data prbs|count seed %08x,
 *            write|read|both: errors %u, cycles %u (%s)" (%s = "%u.%02u MB/s" of the
 *            HyperBus, both passes), on errors "bist: first error at word %08x:
 *            expected %04x read %04x"
 *   memtest  "memtest: %08x + %u bytes seed %u: %u words, errors %u[, bus error]",
 *            "memtest: first error at %08x: expected %08x read %08x"
 *   fill     "fill: %08x + %u bytes seed %u: xorshift written" (for the host's dump check)
 *   dump     "%08x: xx xx ..." (16 bytes per line) | "error: bus error at %08x"
 *   rd, wr   "%08x: %08x" | "%08x: bus error"
 *   reg      "reg ID0|ID1|CR0|CR1: %04x"
 *   cap      "cap ID0|ID1|CR0|CR1: value %04x, t_D %u, first byte A at half cycle %d",
 *            then 4 lines "cap %2u: <16 x rw:xx/yy>" (RWDS rise fall, DQ rise / fall);
 *            "cap ID0|...: failed (STATUS %08x ERR_CODE %08x)" when nothing was captured;
 *            "cap ID0|...: read failed (ERR_CODE %08x), t_D ..." then the 4 lines when
 *            the read itself failed (command error)
 *   phase    "read|write phase %d (of %u per CK)[, refused]"
 *   power    "hyperram: power active|deep power down|hybrid sleep|recovering"
 *   bench    "bench: CPU write %s, posted write %s, read (line buffer) %s, uncached
 *            read %s", "bench: BIST %u words, bursts of %u: write %s, read %s"
 *   info     banner, "  ID %08x INFO %08x EMU %08x CLK_HZ %u DBG %08x", "  memory: %u
 *            MiB at 60000000, test region %u KiB, read buffer %u x 32 bytes", "  state:
 *            ready | not initialised (init)", "  calibration: phase %d width %u RD_DLY %u,
 *            write phase %d" (once calibrated)
 *   stat     bow_hr_print_status() and the statistics (free form)
 *   baud     "ok, switching to %u baud" (the rest at the new rate)
 *   other    "error: <reason>" lines; "unknown command, h for help"
 * Window addresses: memtest, fill and bist take an offset in the window or an
 * address 0x6xxxxxxx; rd, wr and dump take bus addresses.
 */
#include "hr_app.h"

hr_app_t app;

static const char help[] =
    "  test [quick|full] [SEED]   self-test (quick: small regions, for the simulation)\n"
    "  info | stat                IP, device, calibration / registers, counters\n"
    "  init                       enable, reset, calibrate, configure, open the window\n"
    "  cal [STEP] | eye [STEP]    read calibration (phase step STEP, 4) | eye map only\n"
    "  calw [STEP]                write phase scan (card; STEP 8)\n"
    "  bist ADDR LEN [prbs|count] [w|r] [BURST [SEED]]   BIST of LEN bytes at ADDR\n"
    "  memtest ADDR LEN [SEED]    CPU test of LEN bytes, leaves the xorshift fill of SEED\n"
    "  fill ADDR LEN SEED         xorshift fill only\n"
    "  bench                      CPU (window) and BIST bandwidth\n"
    "  reg ID0|ID1|CR0|CR1 [VAL]  device register read / write\n"
    "  cap [ID0|ID1|CR0|CR1]      one captured register read\n"
    "  phase N | wphase N         read / write phase (fine steps, signed)\n"
    "  sleep | dpd | wake | reset hybrid sleep, deep power down, wake up, RESET# pulse\n"
    "  window [rbuf] [wrap] [posted]   window options (none given: all off)\n"
    "  rd ADDR | wr ADDR VAL | dump ADDR LEN   bus access (ADDR, VAL hex; LEN bytes)\n"
    "  baud RATE\n";

/* ------------------------------------------------------------------ helpers */
void print_left(const char *s, unsigned width) {
  unsigned n = 0;
  while (s[n]) n++;
  bow_puts(s);
  while (n++ < width) bow_puts(" ");
}

void print_mbs(uint64_t bytes, uint64_t cycles, uint32_t hz) {
  while ((bytes >> 32) || (cycles >> 32)) {
    bytes >>= 1;
    cycles >>= 1;
  }
  uint32_t x = cycles ? (uint32_t)(bytes * hz / cycles / 10000u) : 0u;
  bow_printf("%u.%02u MB/s", x / 100u, x % 100u);
}

static const char *skip_spaces(const char *s) {
  while (*s == ' ') s++;
  return s;
}

static const char *parse_int(const char *s, uint32_t *v, bool hex) {
  uint32_t x = 0;
  bool neg = false;
  const char *start;
  s = skip_spaces(s);
  if (*s == '-') {
    neg = true;
    s++;
  }
  if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
    hex = true;
    s += 2;
  }
  start = s;
  for (;; s++) {
    unsigned d;
    if (*s >= '0' && *s <= '9') {
      d = (unsigned)(*s - '0');
    } else if (hex && *s >= 'a' && *s <= 'f') {
      d = (unsigned)(*s - 'a' + 10);
    } else if (hex && *s >= 'A' && *s <= 'F') {
      d = (unsigned)(*s - 'A' + 10);
    } else {
      break;
    }
    x = x * (hex ? 16u : 10u) + d;
  }
  if (s == start || (*s != '\0' && *s != ' ')) return NULL;
  *v = neg ? 0u - x : x;
  return s;
}

static const char *parse_num(const char *s, uint32_t *v) { return parse_int(s, v, false); }

static bool word_is(const char *s, const char *w) {
  s = skip_spaces(s);
  while (*w && *s == *w) s++, w++;
  return *w == '\0' && (*s == '\0' || *s == ' ');
}

static const char *skip_word(const char *s) {
  s = skip_spaces(s);
  while (*s && *s != ' ') s++;
  return s;
}

static const char *match(const char *line, const char *cmd) {
  const char *s = line;
  while (*cmd && *s == *cmd) s++, cmd++;
  if (*cmd != '\0' || (*s != '\0' && *s != ' ')) return NULL;
  return s;
}

static bool at_end(const char *s) { return *skip_spaces(s) == '\0'; }

static uint32_t win_off(uint32_t a) {
  return (a >= BOW32_HYPERRAM_BASE && a < BOW32_HYPERRAM_BASE + BOW32_HYPERRAM_SIZE)
             ? a - BOW32_HYPERRAM_BASE : a;
}

static bool need_present(void) {
  if (!app.present) bow_printf("error: no HyperRAM IP (stub or bus error)\n");
  return app.present;
}

static bool need_ready(void) {
  if (!need_present()) return false;
  if (bow_hr_ready()) return true;
  bow_printf("error: not READY (STATUS %08x): init\n", BOW_HR_RD(STATUS));
  return false;
}

static bool in_test_region(uint32_t off, uint32_t len) {
  uint32_t cap = app.info.test_bytes;
  if ((off | len) & 3u || len == 0 || off >= cap || len > cap - off) {
    bow_printf("error: ADDR / LEN multiples of 4 inside the %u bytes tested\n", cap);
    return false;
  }
  return true;
}

static const char *phy_name(uint32_t phy) {
  static const char *const names[4] = {"none", "pads", "loopback", "?"};
  return names[phy & 3u];
}

static void print_banner(void) {
  bow_hr_info_t *i = &app.info;
  if (!app.present) {
    if (i->bus_error) {
      bow_printf("hyperram: IP not found (bus error at %08x)\n", BOW32_HYPERRAM_REG_BASE);
    } else if (i->id == HR_ID_VALUE) {
      bow_printf("hyperram: IP not found (stub: HrEn = 0, INFO %08x)\n", i->info);
    } else {
      bow_printf("hyperram: IP not found (ID %08x)\n", i->id);
    }
    return;
  }
  bow_printf("hyperram: Bow32 HyperRAM %u MiB x8, PHY %s, %u MHz (%u Hz), %u phase steps",
             i->mem_bytes >> 20, phy_name(i->phy), HR_INFO_MHZ(i->info), i->clk_hz, i->ps_steps);
  if (i->has_ls) bow_puts(", level shifters");
  if (i->emu_bytes) bow_printf(", emulator %u KiB", i->emu_bytes >> 10);
  bow_puts("\n");
  if (!bow_hr_wait_clk(2)) {
    bow_printf("hyperram: HyperRAM clock not running (STATUS %08x)\n", BOW_HR_RD(STATUS));
  }
}

bool app_init(bool verbose) {
  app.inited = bow_hr_init(&app.info, &app.cfg, &app.cal, verbose);
  return app.inited;
}

static void info(void) {
  bow_hr_info_t *i = &app.info;
  print_banner();
  if (!app.present) return;
  bow_printf("  ID %08x INFO %08x EMU %08x CLK_HZ %u DBG %08x\n", i->id, i->info, BOW_HR_RD(EMU),
             i->clk_hz, BOW_HR_RD(DBG));
  bow_printf("  memory: %u MiB at %08x, test region %u KiB, read buffer %u x 32 bytes\n",
             i->mem_bytes >> 20, BOW32_HYPERRAM_BASE, i->test_bytes >> 10, i->lines);
  bow_printf("  state: %s\n", bow_hr_ready() ? "ready" : "not initialised (init)");
  if (app.inited) {
    bow_printf("  calibration: phase %d width %u RD_DLY %u, write phase %d\n", app.cal.phase,
               app.cal.width, app.cal.rd_dly, bow_hr_wphase_now());
  }
}

static bool reg_sel(const char **a, uint32_t *sel) {
  static const char *const names[4] = {"ID0", "ID1", "CR0", "CR1"};
  for (uint32_t i = 0; i < 4u; i++) {
    if (word_is(*a, names[i])) {
      *sel = i;
      *a = skip_word(*a);
      return true;
    }
  }
  return false;
}

static const char *reg_name(uint32_t sel) {
  static const char *const names[4] = {"ID0", "ID1", "CR0", "CR1"};
  return names[sel & 3u];
}

/* ------------------------------------------------------------------ commands */
static bool cmd_bist(const char *a) {
  uint32_t addr, len, burst = 0, mode = HR_BIST_WRITE | HR_BIST_READ;
  bool count = false;
  if (!(a = parse_int(a, &addr, true)) || !(a = parse_num(a, &len))) return false;
  for (;;) {
    if (word_is(a, "count")) {
      count = true;
    } else if (word_is(a, "prbs")) {
      count = false;
    } else if (word_is(a, "w")) {
      mode = HR_BIST_WRITE;
    } else if (word_is(a, "r")) {
      mode = HR_BIST_READ;
    } else {
      break;
    }
    a = skip_word(a);
  }
  uint32_t seed = 0xC0FFEEu;
  if (!at_end(a) && !(a = parse_num(a, &burst))) return false;
  if (!at_end(a) && !parse_int(a, &seed, false)) return false;
  if (!need_ready()) return false;
  uint32_t off = win_off(addr);
  if (!in_test_region(off, len)) return false;
  if (burst == 0u || burst > bow_hr_bist_burst_max()) burst = bow_hr_bist_burst_max();
  bow_hr_bist_res_t r;
  bool ok = bow_hr_flush() && bow_hr_bist(off / 2u, len / 2u, burst, mode | (count ? HR_BIST_COUNT : 0u),
                                          seed, &r);
  (void)bow_hr_inval();   /* the BIST bypasses the read buffer */
  uint32_t passes = (mode == (HR_BIST_WRITE | HR_BIST_READ)) ? 2u : 1u;
  bow_printf("bist: words %u at %08x, bursts of %u, data %s seed %08x, %s: errors %u, cycles %u (",
             len / 2u, BOW32_HYPERRAM_BASE + off, burst, count ? "count" : "prbs", seed,
             passes == 2u ? "both" : (mode == HR_BIST_WRITE ? "write" : "read"), r.errors, r.cycles);
  print_mbs((uint64_t)len * passes, r.cycles, BOW_HR_RD(CLK_HZ));
  bow_puts(")\n");
  if (r.errors) {
    bow_printf("bist: first error at word %08x: expected %04x read %04x\n", r.faddr,
               r.fdata & 0xFFFFu, r.fdata >> 16);
  }
  if (!r.done) bow_printf("error: BIST timed out (STATUS %08x)\n", BOW_HR_RD(STATUS));
  return ok;
}

static bool cmd_memtest(const char *a, bool fill_only) {
  uint32_t addr, len, seed = 1;
  mt_res_t r;
  if (!(a = parse_int(a, &addr, true)) || !(a = parse_num(a, &len))) return false;
  parse_num(a, &seed);
  if (!need_ready()) return false;
  uint32_t off = win_off(addr);
  if (!in_test_region(off, len)) return false;
  mt_clear(&r);
  if (fill_only) {
    bool ok = mt_fill(off, len, seed, &r);
    bow_printf("fill: %08x + %u bytes seed %u: xorshift written%s\n", BOW32_HYPERRAM_BASE + off, len,
               seed, ok ? "" : ", bus error");
    return ok;
  }
  bool ok = mt_addr(off, len, &r) && mt_fill(off, len, seed, &r) && mt_check(off, len, seed, &r);
  bow_printf("memtest: %08x + %u bytes seed %u: %u words, errors %u%s\n", BOW32_HYPERRAM_BASE + off,
             len, seed, r.words, r.errors, r.bus_error ? ", bus error" : "");
  if (r.errors) {
    bow_printf("memtest: first error at %08x: expected %08x read %08x\n", BOW32_HYPERRAM_BASE + r.off,
               r.exp, r.got);
  }
  return ok;
}

static bool cmd_dump(const char *a) {
  uint32_t addr, len;
  if (!(a = parse_int(a, &addr, true)) || !parse_num(a, &len)) return false;
  addr &= ~3u;
  for (uint32_t o = 0; o < len; o += 16u) {
    bow_printf("%08x:", addr + o);
    for (uint32_t w = 0; w < 16u && o + w < len; w += 4u) {
      uint32_t v;
      if (!bow_probe_read32(addr + o + w, &v)) {
        bow_printf("\nerror: bus error at %08x\n", addr + o + w);
        return false;
      }
      for (uint32_t b = 0; b < 4u && o + w + b < len; b++) bow_printf(" %02x", (v >> (8u * b)) & 0xFFu);
    }
    bow_puts("\n");
  }
  return true;
}

static bool cmd_cap(const char *a) {
  uint32_t sel = HR_REG_ID0, cap[64];
  uint16_t v = 0;
  if (!at_end(a) && (!reg_sel(&a, &sel) || !at_end(a))) return false;
  if (!need_present()) return false;
  uint32_t td = bow_hr_td();
  bool rd_ok = false;
  bool ok = bow_hr_capture_reg(sel, cap, &v, &rd_ok);
  if (!ok) {   /* no capture (e.g. before init: the read is refused): nothing to show */
    bow_printf("cap %s: failed (STATUS %08x ERR_CODE %08x)\n", reg_name(sel), BOW_HR_RD(STATUS), BOW_HR_RD(ERR_CODE));
    return false;
  }
  int32_t first = bow_hr_cap_first_a(cap, td);
  if (rd_ok) {
    bow_printf("cap %s: value %04x, t_D %u, first byte A at half cycle %d\n", reg_name(sel), v, td, first);
  } else {     /* the capture of a failed read is what shows why it failed */
    bow_printf("cap %s: read failed (ERR_CODE %08x), t_D %u, first byte A at half cycle %d\n", reg_name(sel),
               BOW_HR_RD(ERR_CODE), td, first);
  }
  for (uint32_t i = 0; i < 64u; i++) {
    uint32_t c = cap[i];
    if (i % 16u == 0) bow_printf("cap %2u:", i);
    bow_printf(" %u%u:%02x/%02x", HR_CAP_RWDS_R(c), HR_CAP_RWDS_F(c), HR_CAP_DQ_R(c), HR_CAP_DQ_F(c));
    if (i % 16u == 15u) bow_puts("\n");
  }
  return rd_ok;
}

static bool cmd_reg(const char *a) {
  uint32_t sel, v;
  uint16_t r;
  if (!reg_sel(&a, &sel)) return false;
  if (!need_present()) return false;
  if (!at_end(a)) {
    if (!parse_int(a, &v, true)) return false;
    if (!bow_hr_reg_write(sel, (uint16_t)v)) {
      bow_printf("error: REG_WR refused (STATUS %08x ERR_CODE %08x)\n", BOW_HR_RD(STATUS),
                 BOW_HR_RD(ERR_CODE));
      return false;
    }
  }
  bool ok = bow_hr_reg_read(sel, &r);
  if (HR_ST_POWER(BOW_HR_RD(STATUS)) != HR_PWR_ACTIVE) {
    bow_printf("reg %s: device asleep\n", reg_name(sel));
    return true;
  }
  bow_printf("reg %s: %04x\n", reg_name(sel), r);
  return ok;
}

static void print_power(void) {
  static const char *const pwr[4] = {"active", "deep power down", "hybrid sleep", "recovering"};
  bow_printf("hyperram: power %s\n", pwr[HR_ST_POWER(BOW_HR_RD(STATUS))]);
}

static bool execute(const char *line) {
  const char *a;
  uint32_t v, v2;

  if ((a = match(line, "h")) || (a = match(line, "help"))) {
    bow_puts(help);
    return true;
  }
  if ((a = match(line, "test"))) {
    bool quick = word_is(a, "quick");
    uint32_t seed = 1;
    if (quick || word_is(a, "full")) a = skip_word(a);
    if (!at_end(a) && !parse_num(a, &seed)) return false;
    return self_test(quick, seed);
  }
  if ((a = match(line, "info"))) {
    info();
    return true;
  }
  if ((a = match(line, "stat"))) {
    uint32_t st[16];
    if (!need_present()) return false;
    bow_hr_print_status();
    bool ok = bow_hr_snap(st);
    bow_printf("  transactions: read %u write %u register %u failed %u BIST %u, 2x latency %u\n",
               st[HR_STAT_RD_TXN], st[HR_STAT_WR_TXN], st[HR_STAT_REG], st[HR_STAT_FAILED],
               st[HR_STAT_BIST_TXN], st[HR_STAT_LAT2X]);
    bow_printf("  words: read %u written %u; read buffer hits %u misses %u, write buffer flushes %u\n",
               st[HR_STAT_RD_WORDS], st[HR_STAT_WR_WORDS], st[HR_STAT_HITS], st[HR_STAT_MISSES],
               st[HR_STAT_FLUSHES]);
    return ok;
  }
  if ((a = match(line, "init"))) return at_end(a) && need_present() && app_init(true);
  if ((a = match(line, "cal")) || (a = match(line, "eye"))) {
    uint32_t step = 4;
    bool eye = line[0] == 'e';
    if (!at_end(a) && !parse_num(a, &step)) return false;
    if (!need_present()) return false;
    if (!app.inited && !app_init(true)) return false;
    if (!eye) return bow_hr_calibrate(step, true, &app.cal);
    /* eye: the maps only. The sweeps move the read phase and RD_DLY, write the
     * calibration pattern at window offset 0 and open / close the window: all
     * of it is put back as it was (a window that was closed: the 32 bytes could
     * not be read before, they hold the pattern afterwards). The old setting is
     * checked with an ID0 read before the window reopens; if it fails, the
     * window stays closed and the next cal / eye starts with init */
    int32_t old = bow_hr_phase_now();
    uint32_t lat = BOW_HR_RD(LAT), ctrl = BOW_HR_RD(CTRL), keep[8];
    bool was_open = (ctrl & HR_CTRL_INIT_DONE) != 0u, saved = was_open;
    for (uint32_t i = 0; saved && i < 8u; i++) saved = bow_probe_read32(BOW32_HYPERRAM_BASE + 4u * i, &keep[i]);
    bool ok = bow_hr_calibrate(step, true, NULL);
    BOW_HR_WR(CTRL, ctrl & ~HR_CTRL_INIT_DONE);
    BOW_HR_WR(LAT, lat);
    uint16_t id0 = 0;
    bool back = bow_hr_set_phase(old) && bow_hr_rfifo_sync() && bow_hr_apply() &&
                bow_hr_reg_read(HR_REG_ID0, &id0) && id0 == HR_ID0_S80KS2562;
    if (back && was_open) {
      BOW_HR_WR(CTRL, ctrl);
      for (uint32_t i = 0; back && saved && i < 8u; i++) back = bow_probe_write32(BOW32_HYPERRAM_BASE + 4u * i, keep[i]);
      back = back && saved && bow_hr_flush();
      if (!back) BOW_HR_WR(CTRL, ctrl & ~HR_CTRL_INIT_DONE);
    }
    (void)bow_hr_inval();
    if (!back) app.inited = false;
    bow_printf("hyperram: eye: read phase %d and RD_DLY %u %s\n", bow_hr_phase_now(), HR_LAT_RD_DLY(BOW_HR_RD(LAT)),
               !back ? "not restored, window closed: run cal or init"
                     : (was_open ? "restored" : "restored, window closed as before"));
    return ok && back;
  }
  if ((a = match(line, "calw"))) {
    uint32_t step = 8;
    if (!at_end(a) && !parse_num(a, &step)) return false;
    if (!need_ready()) return false;
    if (app.info.phy == HR_PHY_LOOPBACK) {
      bow_puts("hyperram: calibration failed: write phase: not for the loopback emulator\n");
      return false;
    }
    return bow_hr_calibrate_write(step, true, &app.cal);
  }
  if ((a = match(line, "bist"))) return cmd_bist(a);
  if ((a = match(line, "memtest"))) return cmd_memtest(a, false);
  if ((a = match(line, "fill"))) return cmd_memtest(a, true);
  if ((a = match(line, "bench"))) {
    if (!need_ready()) return false;
    bench();
    return true;
  }
  if ((a = match(line, "reg"))) return cmd_reg(a);
  if ((a = match(line, "cap"))) return cmd_cap(a);
  if ((a = match(line, "phase")) || (a = match(line, "wphase"))) {
    bool w = line[0] == 'w';
    if (!parse_num(a, &v) || !need_present()) return false;
    bool ok = w ? bow_hr_set_wphase((int32_t)v) : bow_hr_set_phase((int32_t)v);
    bow_printf("%s phase %d (of %u per CK)%s\n", w ? "write" : "read",
               w ? bow_hr_wphase_now() : bow_hr_phase_now(), app.info.ps_steps, ok ? "" : ", refused");
    return ok;
  }
  if ((a = match(line, "sleep"))) {
    bool ok = need_present() && bow_hr_hybrid_sleep();
    print_power();
    return ok;
  }
  if ((a = match(line, "dpd"))) {
    bool ok = need_present() && bow_hr_deep_power_down();
    app.inited = false;   /* data and configuration lost */
    print_power();
    return ok;
  }
  if ((a = match(line, "wake"))) {
    bool ok = need_present() && bow_hr_wake();
    print_power();
    return ok;
  }
  if ((a = match(line, "reset"))) {
    bool ok = need_present() && bow_hr_reset();
    app.inited = false;
    print_power();
    return ok;
  }
  if ((a = match(line, "window"))) {
    bool rbuf = false, wrap = false, posted = false;
    while (!at_end(a)) {
      if (word_is(a, "rbuf")) rbuf = true;
      else if (word_is(a, "wrap")) wrap = true;
      else if (word_is(a, "posted")) posted = true;
      else return false;
      a = skip_word(a);
    }
    if (!need_present() || !bow_hr_flush()) return false;
    bow_hr_window(rbuf, wrap, posted);
    return bow_hr_inval();
  }
  if ((a = match(line, "dump"))) return cmd_dump(a);
  if ((a = match(line, "baud"))) {
    if (!parse_num(a, &v) || v < 1200) return false;
    bow_printf("ok, switching to %u baud\n", v);
    bow_uart_flush(UART0);
    bow_uart_init(UART0, v);
    bow_delay_ms(100);
    return true;
  }
  if ((a = match(line, "rd"))) {
    if (!parse_int(a, &v, true)) return false;
    if (!bow_probe_read32(v & ~3u, &v2)) {
      bow_printf("%08x: bus error\n", v & ~3u);
      return false;
    }
    bow_printf("%08x: %08x\n", v & ~3u, v2);
    return true;
  }
  if ((a = match(line, "wr"))) {
    if (!(a = parse_int(a, &v, true)) || !parse_int(a, &v2, true)) return false;
    if (!bow_probe_write32(v & ~3u, v2)) {
      bow_printf("%08x: bus error\n", v & ~3u);
      return false;
    }
    bow_printf("%08x: %08x\n", v & ~3u, v2);
    return true;
  }
  bow_puts("unknown command, h for help\n");
  return false;
}

int main(void) {
  static char line[96];
  unsigned len = 0;
  int prev = 0;

  bow_uart_init(UART0, SYSCTRL->BOOT_BAUD);
  bow_printf("\nBow32 HyperRAM test (sw/apps/hyperram), type h for help\n");
  app.present = bow_hr_probe(&app.info);
  print_banner();

  bow_puts("> ");
  for (;;) {
    int c = bow_uart_getc_nb(UART0);
    if (c == '\n' && prev == '\r') {
      /* second half of a CR LF line ending */
    } else if (c == '\r' || c == '\n') {
      line[len] = '\0';
      bow_puts("\n");
      if (len != 0) bow_puts(execute(line) ? "ok\n" : "error\n");
      bow_puts("> ");
      len = 0;
    } else if ((c == '\b' || c == 0x7f) && len != 0) {
      len--;
      bow_uart_puts(UART0, "\b \b");
    } else if (c >= ' ' && c < 0x7f && len < sizeof(line) - 1) {
      line[len++] = (char)c;
      bow_uart_putc(UART0, (char)c);
    }
    if (c >= 0) prev = c;
  }
}
