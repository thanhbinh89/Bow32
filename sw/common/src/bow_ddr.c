/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * DDR2 / DDR3 IP, Bow32 side (bow_ddr v2): probe, PHY configuration, the
 * command channel (APPLY, phase steppers, read FIFO, raw capture, counters)
 * and the status print. The JEDEC init, the calibration and the BIST use
 * the LiteDRAM CSRs as well: sw/common/litedram (ddr app only).
 */
#include "bow_ddr.h"

#include "bow_printf.h"
#include "bow_probe.h"
#include "bow_time.h"

#define RD(reg)    BOW_DDR_RD(reg)
#define WR(reg, v) BOW_DDR_WR(reg, v)

#define CMD_TIMEOUT_MS 10u  /* command channel: APPLY, SNAP, RFIFO_SYNC, CAP_ARM */
#define PS_TIMEOUT_MS  100u /* PS_GO / WPS_GO: up to 2 x 504 PSEN of ~20 ddr_clk cycles */

/* ------------------------------------------------------------------ helpers */
static uint32_t ms_cycles(uint32_t ms) { return ms * (bow_clk_hz() / 1000u); }

static bool expired(uint32_t start, uint32_t limit) {
  return (uint32_t)(bow_cycles() - start) > limit;
}

/* Wait until the command channel is idle; returns STATUS (BUSY set: timeout). */
static uint32_t wait_idle(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  for (;;) {
    uint32_t st = RD(STATUS);
    if (!(st & DDR_ST_BUSY) || expired(start, limit)) return st;
  }
}

/* wait_idle, then a few more reads until all `flags` or CMD_ERR show (a
 * result flag may follow the end of BUSY by a cycle). */
static uint32_t wait_flags(uint32_t timeout_ms, uint32_t flags) {
  uint32_t st = wait_idle(timeout_ms);
  for (unsigned i = 0; i < 8u && !(st & (DDR_ST_BUSY | DDR_ST_CMD_ERR)) && (st & flags) != flags;
       i++) {
    st = RD(STATUS);
  }
  return st;
}

uint32_t bow_ddr_word_bytes(void) { return DDR_INFO_DQ(RD(INFO)) == 16u ? 16u : 8u; }

uint32_t bow_ddr_ps_steps(void) { return DDR_PS_STEPS(RD(PS_NOW)); }

uint32_t bow_ddr_dbg(void) {
  uint32_t a = RD(DBG);
  for (unsigned i = 0; i < 8; i++) {
    uint32_t b = RD(DBG);
    if (a == b) break;
    a = b;
  }
  return a;
}

bool bow_ddr_ready(void) { return (RD(STATUS) & DDR_ST_READY) != 0; }

bool bow_ddr_wait_clk(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  const uint32_t want = DDR_ST_LINK | DDR_ST_CLK_OK;
  while ((RD(STATUS) & want) != want) {
    if (expired(start, limit)) return false;
  }
  return true;
}

/* ------------------------------------------------------------------- probe */
static uint32_t ilog2(uint32_t v) { return v ? 31u - (uint32_t)__builtin_clz(v) : 0u; }

bool bow_ddr_probe(bow_ddr_info_t *info) {
  bow_ddr_info_t tmp;
  uint32_t id;
  if (!info) info = &tmp;
  *info = (bow_ddr_info_t){0};
  if (!bow_probe_read32(BOW32_DDR_PHY_BASE, &id)) {
    info->bus_error = true;
    return false;
  }
  info->id = id;
  if (id != DDR_ID_VALUE) return false;
  uint32_t i = RD(INFO);
  info->info = i;
  if (!(i & DDR_INFO_EN)) return false; /* bow_ddr_stub */
  info->ddr3 = (i & DDR_INFO_DDR3) != 0;
  info->dq_bits = DDR_INFO_DQ(i);
  info->lanes = DDR_INFO_LANES(i);
  info->addr_pins = DDR_INFO_ADDR_PINS(i);
  info->bank_pins = DDR_INFO_BANK_PINS(i);
  info->has_dm = (i & DDR_INFO_HAS_DM) != 0;
  info->has_reset_n = (i & DDR_INFO_HAS_RESET_N) != 0;
  info->phy = DDR_INFO_PHY(i);
  info->rd_lat = DDR_INFO_RD_LAT(i);
  info->clk_hz = RD(CLK_HZ);
  info->ps_steps = DDR_PS_STEPS(RD(PS_NOW));
  info->emu_log2 = DDR_EMU_LOG2(RD(EMU));
  info->word_bytes = info->dq_bits == 16u ? 16u : 8u;
  info->mem_log2 = ilog2(info->dq_bits / 8u) + info->addr_pins + info->bank_pins + DDR_COL_BITS;
  info->test_log2 = info->mem_log2;
  if (info->phy == DDR_PHY_LOOPBACK && info->emu_log2 != 0 && info->emu_log2 < info->mem_log2) {
    info->test_log2 = info->emu_log2; /* rows beyond the emulator storage are flagged by it */
  }
  return true;
}

/* ----------------------------------------------------------- configuration */
void bow_ddr_config_for(const bow_ddr_info_t *info, bow_ddr_config_t *c) {
  if (info->ddr3) {
    /* DDR3 in DLL-off mode (CL = CWL = 6, AL 0), no level shifters: the
     * shortest read window (DIR / OE) that keeps RL >= LEAD + OE_PRE. */
    *c = (bow_ddr_config_t){
        .ddr3 = true, .rl = 6, .wl = 6, .idle_drive = false, .ls_en = false,
        .rdir_lead = 1, .rdir_tail = 0, .oe_pre = 1, .oe_post = 0,
        .dm_en = info->has_dm, .odt_en = false,
    };
  } else {
    /* The FMC card: IS43DR86400E at CL 3 (WL = RL - 1) behind TXV0108 level
     * shifters, DQ / DQS always driven outside reads, Rtt off. */
    *c = (bow_ddr_config_t){
        .ddr3 = false, .rl = 3, .wl = 2, .idle_drive = true, .ls_en = true,
        .rdir_lead = 2, .rdir_tail = 2, .oe_pre = 1, .oe_post = 2,
        .dm_en = info->has_dm, .odt_en = false,
    };
  }
}

uint32_t bow_ddr_config_ctrl(const bow_ddr_config_t *c, const bow_ddr_info_t *info) {
  return DDR_CTRL_EN | DDR_CTRL_CK_EN | (c->ddr3 ? DDR_CTRL_DDR3 : 0u) |
         (c->idle_drive ? DDR_CTRL_IDLE_DRIVE : 0u) | (c->ls_en ? DDR_CTRL_LS_EN : 0u) |
         (c->dm_en && info->has_dm ? DDR_CTRL_DM_EN : 0u) | (c->odt_en ? DDR_CTRL_ODT_EN : 0u);
}

uint32_t bow_ddr_config_lat(const bow_ddr_config_t *c) {
  return DDR_LAT_RL(c->rl) | DDR_LAT_WL(c->wl) | DDR_LAT_OE_PRE(c->oe_pre) |
         DDR_LAT_RDIR_LEAD(c->rdir_lead) | DDR_LAT_RDIR_TAIL(c->rdir_tail) |
         DDR_LAT_OE_POST(c->oe_post);
}

/* ---------------------------------------------------------------- commands */
bool bow_ddr_cmd(uint32_t cmd) {
  bool ps = cmd == DDR_CMD_PS_GO || cmd == DDR_CMD_WPS_GO;
  uint32_t flag = cmd == DDR_CMD_APPLY ? DDR_ST_APPLIED : ps ? DDR_ST_PS_DONE : 0u;
  WR(STATUS, DDR_ST_CMD_ERR | flag);
  WR(CMD, cmd);
  uint32_t st = wait_flags(ps ? PS_TIMEOUT_MS : CMD_TIMEOUT_MS, flag);
  return !(st & (DDR_ST_BUSY | DDR_ST_CMD_ERR)) && (st & flag) == flag;
}

bool bow_ddr_apply(void) { return bow_ddr_cmd(DDR_CMD_APPLY); }

bool bow_ddr_rfifo_sync(void) {
  bool ok = bow_ddr_cmd(DDR_CMD_RFIFO_SYNC);
  bow_delay_us(2); /* flush, reset release and the restart of the pops */
  return ok && !(RD(STATUS) & DDR_ST_RFIFO_BROKEN);
}

bool bow_ddr_set_ctrl(uint32_t ctrl) {
  WR(CTRL, ctrl);
  return bow_ddr_apply();
}

bool bow_ddr_set_lat(uint32_t lat) {
  WR(LAT, lat);
  return bow_ddr_apply();
}

/* CORE_RST acts at once; the APPLY keeps the applied copy of CTRL in step.
 * The core in reset does not refresh: the refresh monitor goes off with it. */
bool bow_ddr_core_reset(bool on) {
  uint32_t ctrl = RD(CTRL);
  if (on) ctrl = (ctrl | DDR_CTRL_CORE_RST) & ~DDR_CTRL_REF_MON;
  else    ctrl &= ~DDR_CTRL_CORE_RST;
  if (!bow_ddr_set_ctrl(ctrl)) return false;
  if (on) return true;
  /* the reset release crosses into the controller clock domain: wait until
   * the ddr_ctrl slot answers without a bus error (the CSR_ERR of these
   * polls is cleared again) */
  uint32_t start = bow_cycles(), limit = ms_cycles(1), v;
  bool polled = false;
  while (!bow_probe_read32(BOW32_DDR_CTRL_BASE, &v)) {
    polled = true;
    if (expired(start, limit)) return false;
  }
  if (polled) WR(STATUS, DDR_ST_CSR_ERR);
  return true;
}

/* REF_NORM / REF_MON act at once: a CTRL write without APPLY (the other
 * bits are written back unchanged, so the next APPLY sees no difference) */
bool bow_ddr_set_refresh(bool norm, bool mon) {
  const uint32_t m = DDR_CTRL_REF_NORM | DDR_CTRL_REF_MON;
  uint32_t v = (RD(CTRL) & ~m) | (norm ? DDR_CTRL_REF_NORM : 0u) | (mon ? DDR_CTRL_REF_MON : 0u);
  WR(CTRL, v);
  return (RD(CTRL) & m) == (v & m);
}

bool bow_ddr_lock(void) {
  WR(CTRL, RD(CTRL) | DDR_CTRL_LOCK);
  return bow_ddr_locked();
}

bool bow_ddr_locked(void) { return (RD(CTRL) & DDR_CTRL_LOCK) != 0; }

static bool phase_go(bool write, int32_t target) {
  if (target < -32768 || target > 32767) return false;
  WR(STATUS, DDR_ST_PS_DONE | DDR_ST_PS_ERR);
  if (write) {
    WR(WPS_TARGET, (uint32_t)target & 0xFFFFu);
  } else {
    WR(PS_TARGET, (uint32_t)target & 0xFFFFu);
  }
  if (!bow_ddr_cmd(write ? DDR_CMD_WPS_GO : DDR_CMD_PS_GO)) return false;
  return (RD(STATUS) & (DDR_ST_PS_DONE | DDR_ST_PS_ERR)) == DDR_ST_PS_DONE;
}

bool bow_ddr_ps_set(int32_t target) { return phase_go(false, target); }
bool bow_ddr_wps_set(int32_t target) { return phase_go(true, target); }
int32_t bow_ddr_ps_now(void) { return DDR_PS_PHASE(RD(PS_NOW)); }
int32_t bow_ddr_wps_now(void) { return DDR_PS_PHASE(RD(WPS_NOW)); }

/* PS_GO accepts targets within two periods of the phase of the last sync */
bool bow_ddr_ps_goto_sync(int32_t target) {
  uint32_t steps = bow_ddr_ps_steps();
  if (steps == 0 || !bow_ddr_rfifo_sync()) return false;
  int32_t now = bow_ddr_ps_now(), n = (int32_t)steps;
  while (now != target) {
    int32_t d = target - now;
    if (d > n) d = n;
    if (d < -n) d = -n;
    if (!bow_ddr_ps_set(now + d) || !bow_ddr_rfifo_sync()) return false;
    now += d;
  }
  return true;
}

bool bow_ddr_cap_arm(void) {
  WR(STATUS, DDR_ST_CAP_DONE);
  return bow_ddr_cmd(DDR_CMD_CAP_ARM);
}

bool bow_ddr_cap_wait(uint32_t timeout_us) {
  uint32_t start = bow_cycles(), limit = timeout_us * (bow_clk_hz() / 1000000u);
  while (!(RD(STATUS) & DDR_ST_CAP_DONE)) {
    if (expired(start, limit)) return false;
  }
  return true;
}

/* ------------------------------------------------------------------ status */
bool bow_ddr_stats(bow_ddr_stats_t *s, bool clear) {
  bool ok = bow_ddr_cmd(DDR_CMD_SNAP);
  s->rd = RD(ST_RD);
  s->wr = RD(ST_WR);
  s->act = RD(ST_ACT);
  s->ref = RD(ST_REF);
  s->rmw = RD(ST_RMW);
  s->rgap = RD(ST_RGAP);
  if (clear) ok = bow_ddr_cmd(DDR_CMD_CLR_STATS) && ok;
  return ok;
}

static void print_flags(uint32_t v, const char *const *names, unsigned n) {
  for (unsigned i = 0; i < n; i++) {
    if (names[i][0] && (v >> i) & 1u) bow_printf(" %s", names[i]);
  }
}

void bow_ddr_print_status(void) {
  static const char *const ctrl_names[16] = {"EN",       "",        "",           "",
                                             "DM_EN",    "DDR3",    "IDLE_DRIVE", "LS_EN",
                                             "",         "",        "ODT_EN",     "CK_EN",
                                             "CORE_RST", "REF_NORM", "REF_MON",   "LOCK"};
  static const char *const st_names[26] = {
      "BUSY",     "READY",     "CLK_OK",     "APPLIED",    "",          "PS_DONE",
      "CAP_DONE", "",          "",           "CMD_ERR",    "RFIFO_ERR", "BUS_TIMEOUT",
      "DBG_ERR",  "LINK",      "PS_ERR",     "RFIFO_BROKEN", "INIT_DONE", "INIT_ERROR",
      "RD_LATE",  "RD_EXTRA",  "NOT_READY",  "RANGE",      "CSR_ERR",   "BROKEN",
      "REF_STARVE", "LOCK_ERR"};
  uint32_t st = RD(STATUS), ctrl = RD(CTRL), lat = RD(LAT), dbg = bow_ddr_dbg();
  bow_ddr_stats_t s;

  if (!(st & DDR_ST_LINK)) {
    bow_puts("ddr: link down (DDR clock domain in reset)\n");
  } else if (!(st & DDR_ST_CLK_OK)) {
    bow_puts("ddr: DDR clock not running\n");
  } else if (st & DDR_ST_READY) {
    bow_puts("ddr: ready (handed over to the LiteDRAM controller)\n");
  } else {
    bow_puts("ddr: not ready (not initialised / calibrated, init error or a bridge broken)\n");
  }
  bow_printf("  STATUS %08x:", st);
  print_flags(st, st_names, 26);
  bow_printf("\n  CTRL %08x:", ctrl);
  print_flags(ctrl, ctrl_names, 16);
  bow_printf("\n  LAT %08x: RL %u WL %u RD_DLY %u SLIP %u OE_PRE %u LEAD %u TAIL %u OE_POST %u\n",
             lat, DDR_LAT_GET_RL(lat), DDR_LAT_GET_WL(lat), DDR_LAT_GET_RD_DLY(lat),
             DDR_LAT_GET_SLIP(lat), (lat >> 18) & 3u, (lat >> 20) & 15u, (lat >> 24) & 15u,
             lat >> 28);
  bow_printf("  phase %d (of %u per CK), write phase %d, ERR_ADDR %08x\n", bow_ddr_ps_now(),
             bow_ddr_ps_steps(), bow_ddr_wps_now(), RD(ERR_ADDR));
  if (!(st & DDR_ST_BUSY) && (st & DDR_ST_CLK_OK) && bow_ddr_stats(&s, false)) {
    bow_printf("  counters: rd %u wr %u act %u ref %u rmw %u", s.rd, s.wr, s.act, s.ref, s.rmw);
    if (s.rgap) bow_printf(", longest REF interval %u CK", s.rgap + 1u);
    bow_puts("\n");
  }
  bow_printf("  DBG %08x (init %u, %u errors, code %02x)\n", dbg, (dbg >> 30) & 1u,
             DDR_DBG_COUNT(dbg), DDR_DBG_CODE(dbg));
}
