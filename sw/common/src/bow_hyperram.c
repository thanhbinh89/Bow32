/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * HyperRAM IP driver (bow_hyperram.h, docs/ip/hyperram.md).
 *
 * Bring-up (bow_hr_init):
 *   1. enable: CTRL (EN, LS_EN on the card, IDLE_DRIVE, STRICT), LAT and
 *      TIM0 for the PHY kind, APPLY;
 *   2. HW_RESET: RESET# pulse, device registers to their defaults (latency
 *      7, fixed), recovery wait;
 *   3. coarse read calibration: read phase sweep, each point one ID0 read
 *      with raw capture; a point is good when the captured word (located by
 *      RWDS: first high sample after two low ones) is 0x0E86; eye = longest
 *      run of good points (circular), centre; RD_DLY from the capture there;
 *   4. configure: CR0 = latency for CK, fixed, drive strength; CR1 read
 *      (refresh interval -> TCSM); APPLY;
 *   5. fine read calibration with a 32 byte pattern in the memory (every DQ
 *      bit toggles between bytes): same sweep with captured line fills;
 *   6. CTRL.INIT_DONE: the window is open (STATUS.READY).
 * The write phase (card only: the loopback emulator takes the pins at the
 * logic level) is scanned separately (bow_hr_calibrate_write).
 */
#include "bow32.h"

#define HR_CMD_TIMEOUT_US 100000u
#define HR_BIST_TIMEOUT_US 2000000u
/* tHSIN / tDPDIN: 3 us from the entry into hybrid sleep / deep power down to
 * the earliest exit pulse; the entry functions return after it */
#define HR_SLEEP_IN_US 5u

static uint32_t us_to_cycles(uint32_t us) { return us * (bow_clk_hz() / 1000000u); }

static bool timed_out(uint32_t start, uint32_t us) {
  return (uint32_t)(bow_cycles() - start) > us_to_cycles(us);
}

const char *bow_hr_err_name(uint32_t code) {
  static const char *const names[] = {"none", "read data did not start", "RWDS not a strobe",
                                      "longer than tCSM", "device asleep", "disabled",
                                      "read FIFO broken"};
  return code < sizeof(names) / sizeof(names[0]) ? names[code] : "?";
}

/* ------------------------------------------------------------------ basics */
bool bow_hr_probe(bow_hr_info_t *i) {
  uint32_t base = BOW32_HYPERRAM_REG_BASE;
  *i = (bow_hr_info_t){0};
  if (!bow_probe_read32(base + 0x000u, &i->id) || !bow_probe_read32(base + 0x004u, &i->info)) {
    i->bus_error = true;
    return false;
  }
  if (i->id != HR_ID_VALUE || !(i->info & HR_INFO_HR_EN)) return false;
  i->present = true;
  i->phy = HR_INFO_PHY(i->info);
  i->has_ls = (i->info & HR_INFO_HAS_LS) != 0;
  i->mem_bytes = 1u << HR_INFO_MEM_LOG2(i->info);
  i->clk_hz = BOW_HR_RD(CLK_HZ);
  i->ps_steps = BOW_HR_RD(PS_NOW) >> 16;
  uint32_t emu = BOW_HR_RD(EMU) & 0x1Fu;
  i->emu_bytes = emu ? 1u << emu : 0u;
  i->test_bytes = i->emu_bytes ? (i->emu_bytes < i->mem_bytes ? i->emu_bytes : i->mem_bytes)
                               : i->mem_bytes;
  i->lines = HR_INFO_LINES(i->info);
  return true;
}

bool bow_hr_wait_clk(uint32_t ms) {
  uint32_t t0 = bow_cycles();
  while (!(BOW_HR_RD(STATUS) & HR_ST_CLK_OK)) {
    if (timed_out(t0, ms * 1000u)) return false;
  }
  return true;
}

bool bow_hr_ready(void) { return (BOW_HR_RD(STATUS) & HR_ST_READY) != 0; }

bool bow_hr_cmd(uint32_t cmd) {
  uint32_t t0 = bow_cycles();
  /* a command still running (e.g. after a timeout) refuses the next one */
  while (BOW_HR_RD(STATUS) & HR_ST_BUSY) {
    if (timed_out(t0, HR_CMD_TIMEOUT_US)) return false;
  }
  BOW_HR_WR(STATUS, HR_ST_CMD_DONE | HR_ST_CMD_ERR);
  BOW_HR_WR(CMD, cmd);
  t0 = bow_cycles();
  for (;;) {
    uint32_t st = BOW_HR_RD(STATUS);
    if ((st & (HR_ST_CMD_DONE | HR_ST_CMD_ERR)) && !(st & HR_ST_BUSY)) {
      return (st & HR_ST_CMD_DONE) && !(st & HR_ST_CMD_ERR);
    }
    if (timed_out(t0, HR_CMD_TIMEOUT_US)) return false;
  }
}

bool bow_hr_apply(void) { return bow_hr_cmd(HR_CMD_APPLY); }

bool bow_hr_reg_read(uint32_t sel, uint16_t *v) {
  BOW_HR_WR(REG_SEL, sel);
  bool ok = bow_hr_cmd(HR_CMD_REG_RD);
  *v = (uint16_t)BOW_HR_RD(REG_DATA);
  return ok;
}

bool bow_hr_reg_write(uint32_t sel, uint16_t v) {
  BOW_HR_WR(REG_SEL, sel);
  BOW_HR_WR(REG_DATA, v);
  return bow_hr_cmd(HR_CMD_REG_WR);
}

static uint32_t cr0_l(uint32_t cr0) {
  switch ((cr0 >> 4) & 0xFu) {
    case 0xEu: return 3u;
    case 0xFu: return 4u;
    case 0x0u: return 5u;
    case 0x1u: return 6u;
    default: return 7u;
  }
}

/* first data cycle of a register / memory read with 1x latency (variable)
 * or 2x (fixed), from the controller's CR0 shadow */
uint32_t bow_hr_td(void) {
  uint32_t cr0 = BOW_HR_RD(CR0), l = cr0_l(cr0);
  return (cr0 & HR_CR0_FIXED) ? 2u * l + 3u : l + 3u;
}

int32_t bow_hr_phase_now(void) { return (int16_t)(BOW_HR_RD(PS_NOW) & 0xFFFFu); }
int32_t bow_hr_wphase_now(void) { return (int16_t)(BOW_HR_RD(WPS_NOW) & 0xFFFFu); }

bool bow_hr_set_phase(int32_t phase) {
  BOW_HR_WR(PS_TARGET, (uint32_t)phase & 0xFFFFu);
  return bow_hr_cmd(HR_CMD_PS_GO);
}

bool bow_hr_set_wphase(int32_t phase) {
  BOW_HR_WR(WPS_TARGET, (uint32_t)phase & 0xFFFFu);
  return bow_hr_cmd(HR_CMD_WPS_GO);
}

bool bow_hr_rfifo_sync(void) { return bow_hr_cmd(HR_CMD_RFIFO_SYNC); }

/* RESET#, WAKE and the BIST bypass the read buffer: drop its lines after them */
bool bow_hr_reset(void) { return bow_hr_cmd(HR_CMD_HW_RESET) && bow_hr_inval(); }

void bow_hr_window(bool rbuf, bool wrap, bool posted) {
  uint32_t c = BOW_HR_RD(CTRL) & ~(HR_CTRL_RBUF_EN | HR_CTRL_WRAP_FILL | HR_CTRL_WPOST);
  BOW_HR_WR(CTRL, c | (rbuf ? HR_CTRL_RBUF_EN : 0u) | (wrap ? HR_CTRL_WRAP_FILL : 0u) |
                      (posted ? HR_CTRL_WPOST : 0u));
}

/* WIN_IDLE waits for the controller's answer to every posted block: after it
 * the data are in the device (a register write may follow safely) */
bool bow_hr_flush(void) {
  if (!bow_hr_cmd(HR_CMD_FLUSH)) return false;
  uint32_t t0 = bow_cycles();
  while (!(BOW_HR_RD(STATUS) & HR_ST_WIN_IDLE)) {
    if (timed_out(t0, HR_CMD_TIMEOUT_US)) return false;
  }
  return true;
}

bool bow_hr_inval(void) { return bow_hr_cmd(HR_CMD_INVAL); }

bool bow_hr_snap(uint32_t st[16]) {
  bool ok = bow_hr_cmd(HR_CMD_SNAP);
  for (uint32_t i = 0; i < 16u; i++) st[i] = BOW_HR_RD(ST[i]);
  return ok;
}

/* ------------------------------------------------------------ configuration */
void bow_hr_config_for(const bow_hr_info_t *info, bow_hr_config_t *c) {
  uint32_t mhz = info->clk_hz / 1000000u;
  c->lat = mhz <= 85u ? 3u : mhz <= 104u ? 4u : mhz <= 133u ? 5u : mhz <= 166u ? 6u : 7u;
  c->fixed = true;
  c->drive = 0u;   /* 34 ohm, the default */
  c->ctrl = HR_CTRL_EN | HR_CTRL_IDLE_DRIVE | HR_CTRL_STRICT | HR_CTRL_RBUF_EN | HR_CTRL_WRAP_FILL |
            HR_CTRL_WPOST | (info->has_ls ? HR_CTRL_LS_EN : 0u);
  if (info->phy == HR_PHY_LOOPBACK) {
    c->lat_reg = HR_LAT(2, 1, 1, 1, 4, 5, 3, 0);
  } else if (info->has_ls) {
    c->lat_reg = HR_LAT(2, 2, 1, 1, 5, 6, 3, 0);   /* TXV0108 turnaround (docs) */
  } else {
    c->lat_reg = HR_LAT(2, 1, 1, 1, 4, 5, 3, 0);
  }
  /* tCSM 1 us until CR1 tells, CS# high >= tRWR (35 ns), lat_smp 6 (L >= 4) */
  uint32_t tcsm = info->clk_hz / 1000000u - 5u;
  uint32_t cshi = (35u * mhz + 999u) / 1000u;
  if (cshi < 1u) cshi = 1u;
  c->tim0 = HR_TIM0(tcsm, cshi, c->lat >= 4u ? 6u : 5u, 12u, 1u);
}

bool bow_hr_enable(const bow_hr_config_t *c) {
  uint32_t keep = BOW_HR_RD(CTRL) & HR_CTRL_INIT_DONE;
  BOW_HR_WR(CTRL, (c->ctrl & ~HR_CTRL_INIT_DONE) | keep);
  BOW_HR_WR(LAT, c->lat_reg);
  BOW_HR_WR(TIM0, c->tim0);
  return bow_hr_wait_clk(10) && bow_hr_apply();
}

bool bow_hr_configure(bow_hr_config_t *c) {
  /* behind level shifters only fixed (2x) latency leaves the RWDS turnaround
   * of memory writes enough cycles (docs/ip/hyperram.md 2.5) */
  if (!c->fixed && (BOW_HR_RD(INFO) & HR_INFO_HAS_LS)) return false;
  uint16_t cr0 = (uint16_t)(0x8000u | ((c->drive & 7u) << 12) | 0x0F00u |
                            (HR_CR0_LAT_CODE(c->lat) << 4) | (c->fixed ? HR_CR0_FIXED : 0u) |
                            0x0004u | 0x0003u);   /* legacy wrap, 32 byte groups (the line size) */
  uint16_t rd0, cr1;
  if (!bow_hr_reg_write(HR_REG_CR0, cr0)) return false;
  if (!bow_hr_reg_read(HR_REG_CR0, &rd0) || rd0 != cr0) return false;
  if (!bow_hr_reg_read(HR_REG_CR1, &cr1)) return false;
  /* distributed refresh interval: 01 4 us, 10 1 us (TCSM leaves 5 cycles) */
  uint32_t us = (cr1 & 3u) == 1u ? 4u : 1u;
  uint32_t tcsm = BOW_HR_RD(CLK_HZ) / 1000000u * us - 5u;
  if (tcsm > 4095u) tcsm = 4095u;
  c->tim0 = (c->tim0 & ~0xFFFu) | tcsm;
  BOW_HR_WR(TIM0, c->tim0);
  return bow_hr_apply();
}

/* ----------------------------------------------------------------- capture */
static uint32_t cap_rw(const uint32_t *cap, uint32_t s) {
  return (s & 1u) ? HR_CAP_RWDS_F(cap[s >> 1]) : HR_CAP_RWDS_R(cap[s >> 1]);
}

static uint32_t cap_dq(const uint32_t *cap, uint32_t s) {
  return (s & 1u) ? HR_CAP_DQ_F(cap[s >> 1]) : HR_CAP_DQ_R(cap[s >> 1]);
}

/* Byte A of the first word: an RWDS sample high after two low ones and
 * before a low one. The latency indication of the CA phase (2x: RWDS high for
 * the three CA cycles) is high for several samples in a row: never taken. */
int32_t bow_hr_cap_first_a(const uint32_t *cap, uint32_t from) {
  uint32_t lows = 0;
  for (uint32_t s = 0; s + 1u < 128u; s++) {
    if (!cap_rw(cap, s)) {
      if (lows < 2u) lows++;
    } else {
      if (lows >= 2u && s >= 2u * from && !cap_rw(cap, s + 1u)) return (int32_t)s;
      lows = 0;
    }
  }
  return -1;
}

static void read_cap(uint32_t *cap) {
  for (uint32_t i = 0; i < 64u; i++) cap[i] = BOW_HR_RD(CAP[i]);
}

static bool wait_cap(void) {
  uint32_t t0 = bow_cycles();
  while (!(BOW_HR_RD(STATUS) & HR_ST_CAP_DONE)) {
    if (timed_out(t0, 10000u)) return false;
  }
  return true;
}

bool bow_hr_capture_reg(uint32_t sel, uint32_t *cap, uint16_t *value) {
  BOW_HR_WR(STATUS, HR_ST_CAP_DONE);
  if (!bow_hr_cmd(HR_CMD_CAP_ARM)) return false;
  uint16_t v = 0;
  bool rd = bow_hr_reg_read(sel, &v);   /* may fail before calibration */
  if (value) *value = v;
  if (!wait_cap()) return false;
  read_cap(cap);
  (void)rd;
  return true;
}

/* the n bytes of the captured stream from half cycle s on, with RWDS 1, 0, 1, .. */
static bool cap_match(const uint32_t *cap, int32_t s, const uint8_t *exp, uint32_t n) {
  if (s < 0 || (uint32_t)s + n > 128u) return false;
  for (uint32_t k = 0; k < n; k++) {
    uint32_t h = (uint32_t)s + k;
    if (cap_rw(cap, h) != ((k & 1u) ? 0u : 1u) || cap_dq(cap, h) != exp[k]) return false;
  }
  return true;
}

/* ------------------------------------------------------------- calibration */
static const uint8_t cal_pattern[32] = {
    0x00, 0xFF, 0x55, 0xAA, 0x33, 0xCC, 0x0F, 0xF0, 0xFF, 0x00, 0xAA, 0x55, 0xCC, 0x33, 0xF0, 0x0F,
    0x01, 0xFE, 0x80, 0x7F, 0x96, 0x69, 0xA5, 0x5A, 0x3C, 0xC3, 0x18, 0xE7, 0x81, 0x7E, 0x24, 0xDB};

/* longest circular run of good points: start index, length */
static void longest_run(const uint8_t *good, uint32_t n, uint32_t *start, uint32_t *len) {
  uint32_t best = 0, best_s = 0;
  for (uint32_t s = 0; s < n; s++) {
    if (!good[s] || good[(s + n - 1u) % n]) continue;   /* runs start after a bad point */
    uint32_t l = 0;
    while (l < n && good[(s + l) % n]) l++;
    if (l > best) {
      best = l;
      best_s = s;
    }
  }
  if (best == 0 && n && good[0]) best = n;              /* all good */
  *start = best_s;
  *len = best;
}

static void print_map(const char *title, const uint8_t *good, uint32_t n) {
  bow_printf("hyperram: %s |", title);
  for (uint32_t k = 0; k < n; k++) {
    if (k && k % 64u == 0) bow_puts("\n            ");
    bow_puts(good[k] ? "#" : ".");
  }
  bow_puts("|\n");
}

/* One sweep point: a capture of what the window read returns. kind 0: ID0
 * register read; kind 1: line fill of the calibration pattern at window
 * offset 0 (read buffer invalidated first). good = the bytes are found. */
static bool sweep_point(uint32_t kind, uint32_t td, uint32_t *cap, int32_t *first) {
  if (kind == 0u) {
    static const uint8_t id0[2] = {0x0E, 0x86};
    if (!bow_hr_capture_reg(HR_REG_ID0, cap, NULL)) return false;
    *first = bow_hr_cap_first_a(cap, td);
    return cap_match(cap, *first, id0, 2u);
  }
  uint32_t v;
  BOW_HR_WR(STATUS, HR_ST_CAP_DONE);
  if (!bow_hr_inval() || !bow_hr_cmd(HR_CMD_CAP_ARM)) return false;
  (void)bow_probe_read32(BOW32_HYPERRAM_BASE, &v);     /* a line fill, wrapped from word 0 */
  if (!wait_cap()) return false;
  read_cap(cap);
  *first = bow_hr_cap_first_a(cap, td);
  return cap_match(cap, *first, cal_pattern, 32u);
}

static bool set_rd_dly(uint32_t d) {
  BOW_HR_WR(LAT, (BOW_HR_RD(LAT) & ~HR_LAT_RD_DLY_MASK) | ((d & 0x1Fu) << 24));
  return bow_hr_apply();
}

static bool sweep(uint32_t kind, uint32_t step, bool verbose, bow_hr_cal_t *cal) {
  static uint8_t good[1024];
  uint32_t steps = BOW_HR_RD(PS_NOW) >> 16, cap[64];
  int32_t base = bow_hr_phase_now(), first = -1;
  uint32_t td = bow_hr_td(), n = 0;
  if (step == 0u) step = 4u;
  if (!bow_hr_rfifo_sync()) return false;   /* the sweep's reference phase */
  for (uint32_t p = 0; p < steps && n < sizeof(good); p += step, n++) {
    if (!bow_hr_set_phase(base + (int32_t)p)) return false;
    good[n] = sweep_point(kind, td, cap, &first) ? 1u : 0u;
  }
  uint32_t s, len, gcount = 0;
  for (uint32_t k = 0; k < n; k++) gcount += good[k];
  if (verbose) print_map(kind ? "eye (pattern)" : "eye (ID0)", good, n);
  cal->points = n;
  cal->good = gcount;
  /* The IDDR samples on both edges of hr_rd_clk and DQ / RWDS change on both
   * CK edges: the bad phases repeat every half period. A coarse step can
   * miss a narrow bad region and merge two half-period eyes into one run whose
   * middle is that very region (seen on the MPS4: 82 of 84 points good, the
   * centre at the missed transition). When the sweep covers one period in an
   * even number of points, fold the map onto half a period (a phase is good
   * when it and the phase T/2 later both are) and centre in the folded eye. */
  uint32_t m = n;
  if ((n & 1u) == 0u && n * step == steps) {
    m = n / 2u;
    for (uint32_t k = 0; k < m; k++) good[k] = (uint8_t)(good[k] & good[k + m]);
  }
  longest_run(good, m, &s, &len);
  if (len == 0u) return false;
  int32_t off = (int32_t)(((s + len / 2u) % m) * step);
  cal->width = len * step;
  /* centre, back near the reference (folded: phases T/2 apart are equivalent),
   * then the stream delay at the centre */
  int32_t span = (int32_t)(m * step);
  if (off > span / 2) off -= span;
  int32_t centre = base + off;
  cal->phase = centre;
  if (!bow_hr_set_phase(centre) || !bow_hr_rfifo_sync()) return false;
  cal->phase = bow_hr_phase_now();
  if (!sweep_point(kind, td, cap, &first)) return false;
  uint32_t dly = (uint32_t)first / 2u;
  if (dly < td || dly - td > 31u) return false;
  cal->rd_dly = dly - td;
  cal->first_half = (uint32_t)first;
  return set_rd_dly(cal->rd_dly);
}

static bool write_pattern(void) {
  for (uint32_t i = 0; i < 8u; i++) {
    uint32_t w = (uint32_t)cal_pattern[4 * i] | ((uint32_t)cal_pattern[4 * i + 1] << 8) |
                 ((uint32_t)cal_pattern[4 * i + 2] << 16) | ((uint32_t)cal_pattern[4 * i + 3] << 24);
    if (!bow_probe_write32(BOW32_HYPERRAM_BASE + 4u * i, w)) return false;
  }
  return bow_hr_flush();
}

static bool check_pattern(void) {
  for (uint32_t i = 0; i < 8u; i++) {
    uint32_t v, w = (uint32_t)cal_pattern[4 * i] | ((uint32_t)cal_pattern[4 * i + 1] << 8) |
                    ((uint32_t)cal_pattern[4 * i + 2] << 16) | ((uint32_t)cal_pattern[4 * i + 3] << 24);
    if (!bow_probe_read32(BOW32_HYPERRAM_BASE + 4u * i, &v) || v != w) return false;
  }
  return true;
}

bool bow_hr_calibrate(uint32_t step, bool verbose, bow_hr_cal_t *cal) {
  bow_hr_cal_t c = {0};
  uint16_t v;
  if (!sweep(0u, step, verbose, &c)) {
    if (verbose) bow_printf("hyperram: calibration failed: no ID0 eye (%u of %u points)\n", c.good, c.points);
    return false;
  }
  if (!bow_hr_reg_read(HR_REG_ID0, &v) || v != HR_ID0_S80KS2562) {
    if (verbose) bow_printf("hyperram: calibration failed: ID0 %04x at phase %d\n", v, c.phase);
    return false;
  }
  /* fine sweep with the memory pattern (window open meanwhile) */
  uint32_t ctrl = BOW_HR_RD(CTRL);
  BOW_HR_WR(CTRL, ctrl | HR_CTRL_INIT_DONE);
  bool ok = write_pattern() && sweep(1u, step, verbose, &c) && bow_hr_inval() && check_pattern() &&
            bow_hr_reg_read(HR_REG_ID0, &v) && v == HR_ID0_S80KS2562;
  BOW_HR_WR(CTRL, ok ? (ctrl | HR_CTRL_INIT_DONE) : (ctrl & ~HR_CTRL_INIT_DONE));
  c.wphase = bow_hr_wphase_now();
  if (verbose) {
    if (ok) {
      bow_printf("hyperram: read phase %d width %u RD_DLY %u (first byte A at half cycle %u)\n",
                 c.phase, c.width, c.rd_dly, c.first_half);
    } else {
      bow_printf("hyperram: calibration failed: pattern eye (%u of %u points)\n", c.good, c.points);
    }
  }
  if (cal) *cal = c;
  return ok;
}

bool bow_hr_calibrate_write(uint32_t step, bool verbose, bow_hr_cal_t *cal) {
  static uint8_t good[512];
  int32_t lim = (int32_t)HR_WPS_LIMIT(BOW_HR_RD(WPS_NOW) >> 16), old = bow_hr_wphase_now();
  uint32_t n = 0;
  if (step == 0u) step = 8u;
  for (int32_t w = -lim; w <= lim && n < sizeof(good); w += (int32_t)step, n++) {
    uint16_t id = 0;
    good[n] = 0;
    if (!bow_hr_set_wphase(w)) continue;
    bool ok = write_pattern() && bow_hr_inval() && check_pattern() &&
              bow_hr_reg_read(HR_REG_ID0, &id) && id == HR_ID0_S80KS2562;
    good[n] = ok ? 1u : 0u;
  }
  uint32_t s, len;
  longest_run(good, n, &s, &len);   /* not circular in practice: the ends are bad */
  if (verbose) print_map("write eye", good, n);
  if (len == 0u) {
    (void)bow_hr_set_wphase(old);
    return false;
  }
  int32_t w = -lim + (int32_t)((s + len / 2u) % n * step);
  bool ok = bow_hr_set_wphase(w) && write_pattern() && bow_hr_inval() && check_pattern();
  if (cal) {
    cal->wphase = bow_hr_wphase_now();
    cal->wwidth = len * step;
  }
  if (verbose) bow_printf("hyperram: write phase %d width %u\n", bow_hr_wphase_now(), len * step);
  return ok;
}

bool bow_hr_init(const bow_hr_info_t *info, bow_hr_config_t *cfg, bow_hr_cal_t *cal, bool verbose) {
  BOW_HR_WR(CTRL, BOW_HR_RD(CTRL) & ~HR_CTRL_INIT_DONE);
  bow_hr_config_for(info, cfg);
  if (!bow_hr_enable(cfg)) {
    if (verbose) bow_printf("hyperram: init: enable failed (STATUS %08x)\n", BOW_HR_RD(STATUS));
    return false;
  }
  if (!bow_hr_reset()) {
    if (verbose) bow_printf("hyperram: init: HW_RESET failed (STATUS %08x)\n", BOW_HR_RD(STATUS));
    return false;
  }
  bow_hr_cal_t c = {0};
  if (!sweep(0u, 8u, verbose, &c)) {
    if (verbose) bow_printf("hyperram: init: no ID0 eye (%u of %u points)\n", c.good, c.points);
    return false;
  }
  uint16_t id0 = 0, id1 = 0;
  if (!bow_hr_reg_read(HR_REG_ID0, &id0) || !bow_hr_reg_read(HR_REG_ID1, &id1) ||
      id0 != HR_ID0_S80KS2562 || id1 != HR_ID1_HYPERRAM2) {
    if (verbose) bow_printf("hyperram: init: ID0 %04x ID1 %04x\n", id0, id1);
    return false;
  }
  if (!bow_hr_configure(cfg)) {
    if (verbose) bow_printf("hyperram: init: CR0 / CR1 failed (CR0 %04x)\n", BOW_HR_RD(CR0));
    return false;
  }
  if (!bow_hr_calibrate(4u, verbose, &c)) return false;
  cfg->lat_reg = BOW_HR_RD(LAT);
  if (cal) *cal = c;
  if (verbose) {
    bow_printf("hyperram: ready: ID0 %04x ID1 %04x CR0 %04x, latency %u %s, TCSM %u cycles\n", id0,
               id1, BOW_HR_RD(CR0) & 0xFFFFu, cfg->lat, cfg->fixed ? "fixed" : "variable",
               HR_TIM0_TCSM(BOW_HR_RD(TIM0)));
  }
  return bow_hr_ready();
}

/* --------------------------------------------------------------------- BIST */
uint32_t bow_hr_bist_burst_max(void) {
  uint32_t cr0 = BOW_HR_RD(CR0);
  uint32_t tim0 = BOW_HR_RD(TIM0), tcsm = HR_TIM0_TCSM(tim0);
  uint32_t td2 = 2u * cr0_l(cr0) + 3u + HR_TIM0_RD_HOLD(tim0);   /* reads hold CS# longer */
  uint32_t n = tcsm > td2 ? tcsm - td2 : 1u;
  return n > 255u ? 255u : n;
}

bool bow_hr_bist(uint32_t waddr, uint32_t words, uint32_t burst, uint32_t mode, uint32_t seed,
                 bow_hr_bist_res_t *r) {
  *r = (bow_hr_bist_res_t){0};
  BOW_HR_WR(BIST_ADDR, waddr);
  BOW_HR_WR(BIST_LEN, words);
  BOW_HR_WR(BIST_SEED, seed);
  BOW_HR_WR(BIST_CTRL, (mode & 7u) | HR_BIST_BURST(burst));
  BOW_HR_WR(STATUS, HR_ST_BIST_DONE | HR_ST_BIST_ERR);
  if (!bow_hr_cmd(HR_CMD_BIST_GO)) return false;
  uint32_t t0 = bow_cycles();
  while (!(BOW_HR_RD(STATUS) & HR_ST_BIST_DONE)) {
    if (timed_out(t0, HR_BIST_TIMEOUT_US)) return false;
  }
  r->done = true;
  r->cycles = BOW_HR_RD(BIST_CYCLES);
  r->errors = BOW_HR_RD(BIST_ERRS);
  r->faddr = BOW_HR_RD(BIST_FADDR);
  r->fdata = BOW_HR_RD(BIST_FDATA);
  r->ok = !(BOW_HR_RD(STATUS) & HR_ST_BIST_ERR) && r->errors == 0u;
  return bow_hr_inval() && r->ok;
}

/* ------------------------------------------------------------------- power */
static bool wait_power(uint32_t pwr) {
  uint32_t t0 = bow_cycles();
  while (HR_ST_POWER(BOW_HR_RD(STATUS)) != pwr) {
    if (timed_out(t0, HR_CMD_TIMEOUT_US)) return false;
  }
  return true;
}

bool bow_hr_hybrid_sleep(void) {
  bool ok = bow_hr_flush() && bow_hr_reg_write(HR_REG_CR1, (uint16_t)(BOW_HR_RD(CR1) | HR_CR1_HS)) &&
            wait_power(HR_PWR_HS);
  if (ok) bow_delay_us(HR_SLEEP_IN_US);
  return ok;
}

bool bow_hr_deep_power_down(void) {
  bool ok = bow_hr_flush() &&
            bow_hr_reg_write(HR_REG_CR0, (uint16_t)(BOW_HR_RD(CR0) & ~HR_CR0_DPD_N)) &&
            wait_power(HR_PWR_DPD);
  if (ok) bow_delay_us(HR_SLEEP_IN_US);
  return ok;
}

/* out of deep power down the array is lost, out of hybrid sleep it is kept:
 * the read buffer is dropped either way */
bool bow_hr_wake(void) { return bow_hr_cmd(HR_CMD_WAKE) && wait_power(HR_PWR_ACTIVE) && bow_hr_inval(); }

/* ------------------------------------------------------------------ status */
void bow_hr_print_status(void) {
  uint32_t st = BOW_HR_RD(STATUS), ec = BOW_HR_RD(ERR_CODE);
  static const char *const pwr[4] = {"active", "deep power down", "hybrid sleep", "recovering"};
  bow_printf("  STATUS %08x:%s%s%s%s%s%s, power %s\n", st, (st & HR_ST_READY) ? " READY" : "",
             (st & HR_ST_CLK_OK) ? " CLK_OK" : "", (st & HR_ST_APPLIED) ? " APPLIED" : "",
             (st & HR_ST_BROKEN) ? " BROKEN" : "", (st & HR_ST_WIN_IDLE) ? " WIN_IDLE" : "",
             (st & HR_ST_RFIFO_BROKEN) ? " RFIFO_BROKEN" : "", pwr[HR_ST_POWER(st)]);
  bow_printf("  CTRL %08x LAT %08x TIM0 %08x CR0 %04x CR1 %04x PS %d WPS %d\n", BOW_HR_RD(CTRL),
             BOW_HR_RD(LAT), BOW_HR_RD(TIM0), BOW_HR_RD(CR0) & 0xFFFFu, BOW_HR_RD(CR1) & 0xFFFFu,
             bow_hr_phase_now(), bow_hr_wphase_now());
  bow_printf("  ERR_CODE command %u (%s) transaction %u (%s), ERR_ADDR %08x, DBG %08x\n", ec & 0xFFu,
             bow_hr_err_name(ec & 0xFFu), (ec >> 8) & 0xFFu, bow_hr_err_name((ec >> 8) & 0xFFu),
             BOW_HR_RD(ERR_ADDR), BOW_HR_RD(DBG));
}
