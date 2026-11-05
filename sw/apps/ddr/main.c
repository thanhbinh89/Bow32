/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * ddr: test of the Bow32 DDR2 / DDR3 IP (bow_ddr v2: LiteDRAM controller +
 * Bow32 PHY, docs/ip/ddr.md) from a shell on UART0, `h` for help.
 * tools/bow32_ddr.py and the system test (sim/tb/tb_bow32.sv, TEST=ddr)
 * drive it and parse the lines below: keep them stable.
 *
 *   test [quick|full] [seed]   init, calibration, window, BIST, refresh,
 *                              errors: "ddr: PASS (n/n)" / "ddr: FAIL (k/n)"
 *   init, cal, calw, eye       bring-up steps by hand
 *   verify, bist, memtest, dump   data checks (the host compares the dumps)
 *
 * Every command ends with a line "ok" or "error", then the prompt "> ".
 * Output (printf notation):
 *   start     "Bow32 DDR2/DDR3 test (sw/apps/ddr, LiteDRAM controller), type h for help"
 *   banner    "ddr: Bow32 DDR%u x%u (LiteDRAM controller), PHY %s, %u MHz (%u Hz),
 *             %u phase steps[, emulator %u KiB]" (one line; PHY pins | loopback |
 *             none), or "ddr: IP not found (bus error at 4000e000)" | "ddr: IP not
 *             found (stub: DdrEn = 0, INFO %08x)" | "ddr: IP not found (ID %08x[: the
 *             v1 IP, this firmware needs v2])"; "ddr: DDR clock not running (STATUS
 *             %08x)" after it when CLK_OK stays 0
 *   test      "ddr: self-test (quick|full, seed %u)", per check "  [%2u] <name padded
 *             to 62> ok|FAIL" (detail lines before a FAIL start with 7 spaces; init
 *             and cal print their lines too), last "ddr: PASS (%u/%u)" or
 *             "ddr: FAIL (%u/%u)" (passed / checks)
 *   init      "ddr: init DDR%u (LiteDRAM core: CL %u CWL %u, controller %u Hz), CK %u Hz,
 *             CTRL %08x LAT %08x", "ddr: init sequence: <command> ..." (continuation
 *             lines "ddr:  ..."; commands "{CKE ODT RESET_N}" = dfii_control write,
 *             PREA REF ZQCL MR%u=%04x ...), "ddr: init done, LiteDRAM refresh on (DFII
 *             hardware control), not handed over"; failure "ddr: init: <reason>"
 *   cal, eye  "ddr: eye |<map>| phase %d width %u p %d" (map: one character per phase
 *             point = beat offset p of the pattern, 0-9 a-z A-U, '.' none; 64 per
 *             line, continuation lines start with 10 spaces; no eye: "| no eye (%u of
 *             %u points good)"); cal then "ddr: read phase %d width %u p %d RD_DLY %u
 *             SLIP %u, BIST %u errors" or "ddr: calibration failed: <reason>"; eye
 *             of a calibrated memory whose read path can no longer be verified (data
 *             moved, sweep failed after the FIFO sync, phase not restored): "ddr: eye:
 *             <reason>, run cal again (window blocked)"
 *   calw      "ddr: write eye |<map: # pass . fail>| write phase %d width %u", then
 *             "ddr: write phase %d width %u"; or "ddr: calibration failed: write
 *             phase: <reason>" (e.g. "not for the loopback emulator"); a failure
 *             after the scan started ends "(old phase kept)" or, when the old
 *             phase fails too, "run cal again (window blocked)"
 *   bist      "bist: addr %08x len %u data prbs|count: done %u errors %u wticks %u
 *             rticks %u (write %s, read %s)" (ticks of the controller clock CK / 4,
 *             %s = "%u.%02u MB/s")
 *   memtest   "memtest: %08x + %u bytes seed %u: %u words, errors %u[, bus error]",
 *             "memtest: first error at %08x: expected %08x read %08x"
 *   verify    "verify: %u cases, seed %u", per failed case "verify: case %u: <case>:
 *             <reason>", last "verify: PASS (%u/%u cases)" | "verify: FAIL (%u/%u cases)"
 *   dump      "%08x: xx xx ..." (16 bytes per line) | "error: bus error at %08x"
 *   rd, wr    "%08x: %08x" (rd) | "%08x: bus error"
 *   phase     "read|write phase %d (of %u per CK)[, refused (PS_ERR)]"
 *   cap       "cap BA %u row %u col %u: rdata xx ..", then 4 lines "cap %2u: rr/ff(s)
 *             ..." (8 stream cycles each: DQ rise / fall, DQS nibble)
 *   info      banner, "  ID %08x INFO %08x EMU %08x CLK_HZ %u DBG %08x", "  pins: DQ %u,
 *             lanes %u, A0..A%u, BA0..BA%u, DM yes|no, RESET# yes|no", "  LiteDRAM
 *             DDR%u core: CL %u CWL %u, READ / WRITE on phase %u / %u of %u, read
 *             latency %u, controller %u Hz", "  memory: %u MiB at 80000000, test region
 *             %u KiB", "  state: ready | initialised, not handed over | not
 *             initialised (init, cal)", "  calibration: phase %d width %u RD_DLY %u SLIP
 *             %u, write phase %d" (once calibrated)
 *   stat      bow_ddr_print_status() and bow_ld_print_status() (free form)
 *   baud      "ok, switching to %u baud" (the rest at the new rate)
 *   other     "error: <reason>" lines; "unknown command, h for help"
 *
 * Window addresses: bist and memtest take an offset in the window or an
 * address 0x8xxxxxxx; rd, wr and dump take bus addresses.
 */
#include "ddr_app.h"

ddr_app_t app;

static const char help[] =
    "  test [quick|full] [SEED]   self-test (quick: small regions, for the simulation)\n"
    "  info | stat                IP, LiteDRAM core, calibration / registers, counters\n"
    "  init                       power-up and JEDEC init (LiteDRAM init_sequence over DFII)\n"
    "  cal [STEP] [--write]       read calibration (phase step STEP, 4), hand-over; --write: calw\n"
    "  calw [STEP]                write phase scan with the LiteDRAM BIST (STEP 8)\n"
    "  eye [STEP]                 eye map only (STEP 4); phase, READY and data kept if the read\n"
    "                             path verifies again, else the window is blocked (cal again)\n"
    "  verify [N] [SEED]          N random BIST / CPU cases checked against C models (20)\n"
    "  bist ADDR LEN [prbs|count] LiteDRAM BIST: write + check LEN bytes at ADDR\n"
    "  memtest ADDR LEN [SEED]    CPU test of LEN bytes, leaves the xorshift fill of SEED\n"
    "  bench                      CPU (window) and BIST bandwidth\n"
    "  phase N | wphase N         read / write phase (fine steps, signed)\n"
    "  cap [BA ROW COL]           one DFII read with raw capture (after init)\n"
    "  rd ADDR | wr ADDR VAL | dump ADDR LEN   bus access (ADDR, VAL hex; LEN bytes)\n"
    "  baud RATE\n";

/* ------------------------------------------------------------------ helpers */
void print_left(const char *s, unsigned width) { /* bow_printf has no '-' */
  unsigned n = 0;
  while (s[n]) n++;
  bow_puts(s);
  while (n++ < width) bow_puts(" ");
}

void print_mbs100(uint32_t x) { bow_printf("%u.%02u MB/s", x / 100u, x % 100u); }

void print_mbs(uint64_t bytes, uint64_t cycles, uint32_t hz) {
  while ((bytes >> 32) || (cycles >> 32)) { /* bytes * hz must fit 64 bits */
    bytes >>= 1;
    cycles >>= 1;
  }
  print_mbs100(cycles ? (uint32_t)(bytes * hz / cycles / 10000u) : 0u);
}

static const char *skip_spaces(const char *s) {
  while (*s == ' ') s++;
  return s;
}

/* Decimal (hex if hex), hex with 0x, optional '-'. Rest of the line or NULL. */
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

/* after the word w at the start of s (spaces skipped) */
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

/* window offset from an offset or a window address */
static uint32_t win_off(uint32_t a) { return a >= BOW32_DDR_BASE ? a - BOW32_DDR_BASE : a; }

static bool need_present(void) {
  if (!app.present) bow_printf("error: no DDR IP (stub or bus error)\n");
  return app.present;
}

static bool need_ready(void) {
  if (!need_present()) return false;
  if (bow_ddr_ready()) return true;
  bow_printf("error: not READY (STATUS %08x): init, cal\n", BOW_DDR_RD(STATUS));
  return false;
}

static const char *phy_name(uint32_t phy) {
  static const char *const names[4] = {"none", "pins", "loopback", "?"};
  return names[phy & 3u];
}

static void print_banner(void) {
  bow_ddr_info_t *i = &app.info;
  if (!app.present) {
    if (i->bus_error) {
      bow_printf("ddr: IP not found (bus error at %08x)\n", BOW32_DDR_PHY_BASE);
    } else if (i->id == DDR_ID_VALUE) {
      bow_printf("ddr: IP not found (stub: DdrEn = 0, INFO %08x)\n", i->info);
    } else if (i->id == DDR_ID_VALUE_V1) {
      bow_printf("ddr: IP not found (ID %08x: the v1 IP, this firmware needs v2)\n", i->id);
    } else {
      bow_printf("ddr: IP not found (ID %08x)\n", i->id);
    }
    return;
  }
  bow_printf("ddr: Bow32 DDR%u x%u (LiteDRAM controller), PHY %s, %u MHz (%u Hz), %u phase steps",
             i->ddr3 ? 3u : 2u, i->dq_bits, phy_name(i->phy), DDR_INFO_MHZ(i->info), i->clk_hz,
             i->ps_steps);
  if (i->emu_log2) bow_printf(", emulator %u KiB", (1u << i->emu_log2) >> 10);
  bow_puts("\n");
  if (!bow_ddr_wait_clk(2)) bow_printf("ddr: DDR clock not running (STATUS %08x)\n", BOW_DDR_RD(STATUS));
}

/* ------------------------------------------------------------------- setup */
bool app_init(bool verbose) {
  app.inited = app.calibrated = false;
  bow_ddr_config_for(&app.info, &app.cfg);
  app.inited = bow_ld_init(&app.cfg, verbose);
  return app.inited;
}

bool app_calibrate(uint32_t step, bool verbose) {
  if (!bow_ld_inited() && !app_init(verbose)) return false;
  app.calibrated = bow_ld_calibrate(step, verbose, &app.cal);
  return app.calibrated;
}

static void info(void) {
  bow_ddr_info_t *i = &app.info;
  print_banner();
  if (!app.present) return;
  const bow_ld_core_t *k = bow_ld_core(i);
  bow_printf("  ID %08x INFO %08x EMU %08x CLK_HZ %u DBG %08x\n", i->id, i->info,
             BOW_DDR_RD(EMU), i->clk_hz, bow_ddr_dbg());
  bow_printf("  pins: DQ %u, lanes %u, A0..A%u, BA0..BA%u, DM %s, RESET# %s\n", i->dq_bits,
             i->lanes, i->addr_pins - 1u, i->bank_pins - 1u, i->has_dm ? "yes" : "no",
             i->has_reset_n ? "yes" : "no");
  bow_printf("  LiteDRAM %s core: CL %u CWL %u, READ / WRITE on phase %u / %u of %u, "
             "read latency %u, controller %u Hz\n",
             k->name, k->cl, k->cwl, k->rdphase, k->wrphase, k->phases, i->rd_lat, i->clk_hz / 4u);
  bow_printf("  memory: %u MiB at %08x, test region %u KiB\n", (1u << i->mem_log2) >> 20,
             BOW32_DDR_BASE, (1u << i->test_log2) >> 10);
  bow_printf("  state: %s\n", bow_ddr_ready() ? "ready"
                              : bow_ld_inited() ? "initialised, not handed over"
                                                : "not initialised (init, cal)");
  if (app.calibrated) {
    bow_printf("  calibration: phase %d width %u RD_DLY %u SLIP %u, write phase %d\n",
               app.cal.phase, app.cal.width, app.cal.rd_dly, app.cal.rd_slip, bow_ddr_wps_now());
  }
}

/* ------------------------------------------------------------------ commands */
static bool cmd_bist(const char *a) {
  uint32_t addr, len;
  bool random = true;
  if (!(a = parse_int(a, &addr, true)) || !(a = parse_num(a, &len))) return false;
  if (word_is(a, "count")) {
    random = false;
  } else if (!word_is(a, "prbs") && !at_end(a)) {
    return false;
  }
  if (!need_ready()) return false;
  uint32_t w = app.info.word_bytes, off = win_off(addr), cap = 1u << app.info.test_log2;
  if ((off | len) & (w - 1u) || len == 0 || len > (32u << 20) || off >= cap || len > cap - off) {
    bow_printf("error: ADDR / LEN multiples of %u, LEN <= 32 MiB, inside the %u bytes tested\n",
               w, cap);
    return false;
  }
  bow_ld_bist_t b = {.base = off, .length = len, .random = random, .write = true, .read = true};
  bow_ld_bist_res_t r;
  bool ok = bow_ld_bist(&b, &r);
  uint32_t ck = BOW_DDR_RD(CLK_HZ);
  bow_printf("bist: addr %08x len %u data %s: done %u errors %u wticks %u rticks %u (write ", off,
             len, random ? "prbs" : "count", r.done, r.errors, r.wr_ticks, r.rd_ticks);
  print_mbs100(bow_ld_mbs100(len, r.wr_ticks, ck));
  bow_puts(", read ");
  print_mbs100(bow_ld_mbs100(len, r.rd_ticks, ck));
  bow_puts(")\n");
  if (!r.done) bow_printf("error: BIST timed out or CSR error (STATUS %08x)\n", BOW_DDR_RD(STATUS));
  return ok;
}

static bool cmd_memtest(const char *a) {
  uint32_t addr, len, seed = 1;
  mt_res_t r;
  if (!(a = parse_int(a, &addr, true)) || !(a = parse_num(a, &len))) return false;
  parse_num(a, &seed);
  if (!need_ready()) return false;
  uint32_t off = win_off(addr), cap = 1u << app.info.test_log2;
  if ((off | len) & 3u || len == 0 || off >= cap || len > cap - off) {
    bow_printf("error: ADDR / LEN multiples of 4 inside the %u bytes tested\n", cap);
    return false;
  }
  mt_clear(&r);
  bool ok = mt_addr(off, len, &r) && mt_fill(off, len, seed, &r) && mt_check(off, len, seed, &r);
  bow_printf("memtest: %08x + %u bytes seed %u: %u words, errors %u%s\n", BOW32_DDR_BASE + off, len,
             seed, r.words, r.errors, r.bus_error ? ", bus error" : "");
  if (r.errors) {
    bow_printf("memtest: first error at %08x: expected %08x read %08x\n", BOW32_DDR_BASE + r.off,
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

/* one DFII read with raw capture: ACT, RD, PRE in a software section */
static bool cmd_cap(const char *a) {
  uint32_t ba = 0, row = 0, col = 0;
  if (!at_end(a)) {
    if (!(a = parse_num(a, &ba)) || !(a = parse_num(a, &row)) || !(a = parse_num(a, &col)) ||
        !at_end(a)) {
      return false;
    }
  }
  if (!need_present()) return false;
  if (!bow_ld_inited()) {
    bow_puts("error: DRAM not initialised (init)\n");
    return false;
  }
  if (ba >= (1u << app.info.bank_pins) || row >= (1u << app.info.addr_pins) || (col & 7u) ||
      col >= (1u << DDR_COL_BITS)) {
    bow_puts("error: BA / ROW out of range, COL a multiple of 8 below 1024\n");
    return false;
  }
  uint8_t d[16];
  bool ready;
  bow_ld_quiesce(&ready);
  bool ok = bow_ld_burst_read(ba, row, col, d, true);
  ok = bow_ld_release(ready) && ok;
  uint32_t dq = app.info.dq_bits, m = dq == 16u ? 0xFFFFu : 0xFFu;
  bow_printf("cap BA %u row %u col %u: rdata", ba, row, col);
  for (uint32_t i = 0; i < app.info.word_bytes; i++) bow_printf(" %02x", d[i]);
  bow_puts("\n");
  for (uint32_t i = 0; i < 32u; i++) {
    uint32_t c = BOW_DDR_RD(CAP[i]);
    if (i % 8u == 0) bow_printf("cap %2u:", i);
    bow_printf(dq == 16u ? " %04x/%04x" : " %02x/%02x", c & m, (c >> dq) & m);
    bow_printf("(%x)", BOW_DDR_RD(CAPS[i]) & 0xFu);
    if (i % 8u == 7u) bow_puts("\n");
  }
  if (!ok) bow_printf("error: no capture or CSR error (STATUS %08x)\n", BOW_DDR_RD(STATUS));
  return ok;
}

static bool cmd_cal(const char *a, bool write_only) {
  uint32_t step = write_only ? 8u : 4u;
  const char *rest = parse_num(a, &step);
  bool write = write_only;
  if (rest) a = rest;
  if (!write_only && word_is(a, "--write")) {
    write = true;
    a = skip_word(a);
  }
  if (!at_end(a) || !need_present()) return false;
  if (!write_only && !app_calibrate(step, true)) return false;
  if (!write) return true;
  if (!bow_ld_cal_write(write_only ? step : 8u, true, &app.cal)) {
    if (!bow_ddr_ready()) app.calibrated = false; /* window blocked: cal again */
    return false;
  }
  bow_printf("ddr: write phase %d width %u\n", app.cal.wphase, app.cal.wwidth);
  return true;
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
    if (!need_present()) return false;
    bow_ddr_print_status();
    bow_ld_print_status();
    return true;
  }
  if ((a = match(line, "init"))) return at_end(a) && need_present() && app_init(true);
  if ((a = match(line, "cal"))) return cmd_cal(a, false);
  if ((a = match(line, "calw"))) return cmd_cal(a, true);
  if ((a = match(line, "eye"))) {
    uint32_t step = 4;
    parse_num(a, &step);
    if (!need_present()) return false;
    if (!bow_ld_inited() && !app_init(true)) return false;
    bool ok = bow_ld_eye(step, true, NULL);
    if (!bow_ddr_ready()) app.calibrated = false; /* window blocked: cal again */
    return ok;
  }
  if ((a = match(line, "verify"))) {
    uint32_t n = 20, seed = 1;
    if ((a = parse_num(a, &n)) && !at_end(a) && !parse_num(a, &seed)) return false;
    return need_ready() && verify(n, seed);
  }
  if ((a = match(line, "bist"))) return cmd_bist(a);
  if ((a = match(line, "memtest"))) return cmd_memtest(a);
  if ((a = match(line, "bench"))) {
    if (!need_ready()) return false;
    bench();
    return true;
  }
  if ((a = match(line, "phase")) || (a = match(line, "wphase"))) {
    bool w = line[0] == 'w';
    if (!parse_num(a, &v) || !need_present()) return false;
    bool ok = w ? bow_ddr_wps_set((int32_t)v) : bow_ddr_ps_set((int32_t)v);
    bow_printf("%s phase %d (of %u per CK)%s\n", w ? "write" : "read",
               w ? bow_ddr_wps_now() : bow_ddr_ps_now(), bow_ddr_ps_steps(),
               ok ? "" : ", refused (PS_ERR)");
    return ok;
  }
  if ((a = match(line, "cap"))) return cmd_cap(a);
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
    return true;
  }
  bow_printf("unknown command, h for help\n");
  return false;
}

/* --------------------------------------------------------------------- main */
int main(void) {
  static char line[96];
  unsigned len = 0;
  int prev = 0;

  bow_uart_init(UART0, SYSCTRL->BOOT_BAUD);
  bow_printf("\nBow32 DDR2/DDR3 test (sw/apps/ddr, LiteDRAM controller), type h for help\n");
  app.present = bow_ddr_probe(&app.info);
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
