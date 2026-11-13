/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MIPI D-PHY receiver driver (bow_dphy_rx.h): timing, ready state and re-init,
 * input delays, counters, raw PHY words and the byte clock meter of the
 * D-PHY's registers at 0x4000_8C00; since step 6 the shadow registers (CTRL,
 * TIM0..2, CMD.APPLY) and the v1.x timers and status.
 */
#include "bow_dphy_rx.h"

#include "bow_printf.h"
#include "bow_probe.h"
#include "bow_time.h"

#define READY_FALL_US 20u   /* CMD.AFE_CAL: READY falls within a few cycles of the pulse */
#define APPLY_READS   64u   /* CMD.APPLY: the lp domain takes it within a few lp clocks */

static uint32_t ms_cycles(uint32_t ms) { return ms * (bow_clk_hz() / 1000u); }

static bool expired(uint32_t start, uint32_t limit) {
  return (uint32_t)(bow_cycles() - start) > limit;
}

/* PHY timing in lp clock cycles, rounded, 1..255 */
static uint32_t lp_cycles(uint32_t ns, uint32_t mhz) {
  uint32_t n = (ns * mhz + 500u) / 1000u;
  return n < 1u ? 1u : n > 255u ? 255u : n;
}

/* the lane rate of the last bow_dphy_rx_timing() (0: unknown), for CLK_MISS
 * when CLK_TOG_DIV changes */
static uint32_t timing_rate;

/* Clock miss timeout: the clock lane FSM sees one edge per 2^div byte clocks
 * (8 UI each; TIM1.CLK_TOG_DIV), up to one lp cycle late after the
 * synchroniser. That period, rounded up, + 3 cycles of margin: 5 cycles at
 * 912 Mbit/s, 200 MHz and div 0, so the gate closes early in T_CLK-TRAIL
 * (>= 60 ns). Lane rate 0: 40 ns per 2^div, rounded (8 at 200 MHz). Not
 * clamped: above 255 the field cannot hold it. */
static uint64_t clk_miss_cycles(uint32_t lane_rate, uint32_t mhz, uint32_t div) {
  if (lane_rate == 0) {
    uint64_t n = ((40ull << div) * mhz + 500u) / 1000u;
    return n < 1u ? 1u : n;
  }
  return ((8000000ull << div) * mhz + lane_rate - 1u) / lane_rate + 3u;
}

uint32_t bow_dphy_rx_version(void) {
  uint32_t id;
  if (!bow_probe_read32(DPHY_BASE, &id) || DPHY_ID_NAME(id) != DPHY_ID_NAME(DPHY_ID_VALUE)) {
    return 0;
  }
  return DPHY_ID_VERSION(id);
}

bool bow_dphy_rx_probe(void) { return bow_dphy_rx_version() == DPHY_MAP_VERSION; }

uint32_t bow_dphy_rx_lanes(void) {
  uint32_t n = DPHY_INFO_LANES(DPHY->INFO);
  return n == 0 ? 1u : n > DPHY_MAX_LANES ? DPHY_MAX_LANES : n;
}

uint32_t bow_dphy_rx_afe(void) { return DPHY_INFO_AFE(DPHY->INFO); }

bool bow_dphy_rx_self_cal(void) { return (DPHY->INFO & DPHY_INFO_SELF_CAL) != 0; }

uint32_t bow_dphy_rx_lp_mhz(void) { return DPHY_INFO_LP_MHZ(DPHY->INFO); }

/* The ns part of the SETTLE target, INFO2 of the PHY unless DPHY_SETTLE_NS
 * overrides it (simulation only: the brst0 firmware of sim/Makefile, 140 =
 * SETTLE 23 = 115 ns at 200 MHz for the Versal model without the receive path
 * reset; docs/camera_huins.md 6.3). */
static uint32_t settle_ns(uint32_t info2) {
#ifdef DPHY_SETTLE_NS
  (void)info2;
  return DPHY_SETTLE_NS;
#else
  return DPHY_INFO2_SETTLE_NS(info2);
#endif
}

bool bow_dphy_rx_timing(uint32_t lane_rate) {
  uint32_t mhz = bow_dphy_rx_lp_mhz(), info2 = DPHY->INFO2;
  uint32_t settle = bow_dphy_rx_settle(settle_ns(info2), DPHY_INFO2_SETTLE_UI(info2), lane_rate,
                                       mhz, 2);
  uint64_t miss = clk_miss_cycles(lane_rate, mhz, DPHY_TIM1_CLK_TOG_DIV_OF(DPHY->TIM1));
  timing_rate = lane_rate;
  DPHY->TIM0 = DPHY_TIM0_SETTLE(settle) | DPHY_TIM0_LP_FILTER(2) |
               DPHY_TIM0_CLK_SETTLE(lp_cycles(150, mhz)) |
               DPHY_TIM0_CLK_MISS(miss > 255u ? 255u : miss);
  return bow_dphy_rx_apply();
}

bool bow_dphy_rx_apply(void) {
  DPHY->CMD = DPHY_CMD_APPLY;
  for (uint32_t i = 0; i < APPLY_READS; i++) {
    if (!(DPHY->CMD & DPHY_CMD_APPLY)) return true;
  }
  return false;
}

bool bow_dphy_rx_ctrl(uint32_t set, uint32_t clear) {
  DPHY->CTRL = (DPHY->CTRL & ~clear) | set;
  return bow_dphy_rx_apply();
}

uint32_t bow_dphy_rx_lp_cycles(uint32_t ns) {
  return (uint32_t)(((uint64_t)ns * bow_dphy_rx_lp_mhz() + 999u) / 1000u);
}

bool bow_dphy_rx_set_hs_tmo(uint32_t cycles) {
  if (cycles > DPHY_TIM1_HS_TMO_MAX) return false;
  DPHY->TIM1 = (DPHY->TIM1 & ~DPHY_TIM1_HS_TMO(~0u)) | DPHY_TIM1_HS_TMO(cycles);
  return bow_dphy_rx_apply();
}

/* CLK_TOG_DIV with the CLK_MISS that goes with it (a clock miss timeout made
 * for one byte clock would close the gate in every burst with a divider) */
bool bow_dphy_rx_set_clk_tog_div(uint32_t div) {
  uint32_t tim0 = DPHY->TIM0;
  uint64_t miss = clk_miss_cycles(timing_rate, bow_dphy_rx_lp_mhz(), div);
  if (div > DPHY_TIM1_CLK_TOG_DIV_MAX || miss > 255u) return false;
  if (tim0 & DPHY_TIM0_CLK_MISS(~0u)) {
    DPHY->TIM0 = (tim0 & ~DPHY_TIM0_CLK_MISS(~0u)) | DPHY_TIM0_CLK_MISS(miss);
  }
  DPHY->TIM1 = (DPHY->TIM1 & ~DPHY_TIM1_CLK_TOG_DIV(~0u)) | DPHY_TIM1_CLK_TOG_DIV(div);
  return bow_dphy_rx_apply();
}

bool bow_dphy_rx_set_t_init(uint32_t cycles) {
  if (cycles > DPHY_TIM2_T_INIT_MAX) return false;
  DPHY->TIM2 = (DPHY->TIM2 & ~DPHY_TIM2_T_INIT(~0u)) | DPHY_TIM2_T_INIT(cycles);
  return bow_dphy_rx_apply();
}

bool bow_dphy_rx_set_esc_tmo(uint32_t units) {
  if (units > DPHY_TIM2_ESC_TMO_MAX) return false;
  DPHY->TIM2 = (DPHY->TIM2 & ~DPHY_TIM2_ESC_TMO(~0u)) | DPHY_TIM2_ESC_TMO(units);
  return bow_dphy_rx_apply();
}

void bow_dphy_rx_v1x(bow_dphy_rx_v1x_t *s) {
  s->err = DPHY->ERR_STATUS;
  s->stop = DPHY->LANE_STOP;
  s->misc = DPHY->CNT_MISC >> 16;
  s->ulps = DPHY->CNT_DSK >> 16;
}

bool bow_dphy_rx_ready(void) { return (DPHY->AFE_STATUS & DPHY_AFE_READY) != 0; }

bool bow_dphy_rx_wait_ready(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  while (!bow_dphy_rx_ready()) {
    if (expired(start, limit)) return false;
  }
  return true;
}

bool bow_dphy_rx_power(bool on, uint32_t timeout_ms) {
  DPHY->AFE_CTRL = on ? 0u : DPHY_AFE_CTRL_PD;
  return !on || bow_dphy_rx_wait_ready(timeout_ms);
}

int bow_dphy_rx_reinit(uint32_t timeout_ms, uint32_t *us) {
  uint32_t mhz = bow_clk_hz() / 1000000u, t0 = bow_cycles(), dt;
  DPHY->CMD = DPHY_CMD_AFE_CAL | DPHY_CMD_REINIT;
  while (bow_dphy_rx_ready()) {
    if (expired(t0, READY_FALL_US * mhz)) return DPHY_ENOREINIT;
  }
  bool rdy;
  do {
    rdy = bow_dphy_rx_ready();
    dt = bow_cycles() - t0;
  } while (!rdy && dt <= ms_cycles(timeout_ms));
  if (us) *us = dt / mhz;
  return rdy ? DPHY_OK : DPHY_ENOTRDY;
}

bool bow_dphy_rx_des_rst(bool on) {
  return on ? bow_dphy_rx_ctrl(0, DPHY_CTRL_DES_RST_DIS) : bow_dphy_rx_ctrl(DPHY_CTRL_DES_RST_DIS, 0);
}

bool bow_dphy_rx_des_rst_on(void) { return !(DPHY->CTRL & DPHY_CTRL_DES_RST_DIS); }

void bow_dphy_rx_set_delay(uint32_t lane, uint32_t code) {
  if (lane < DPHY_MAX_LANES) DPHY->DLY[lane] = code > DPHY_DLY_MAX ? DPHY_DLY_MAX : code;
}

/* DLYn of a lane. Self-calibrated PHY: [24:16] comes from the lp clock domain
 * through one synchroniser per bit and VT tracking may step it, so a read can
 * mix two values: read until two reads agree (at most 8 reads). */
static uint32_t dly_read(uint32_t lane, bool self_cal) {
  uint32_t d = DPHY->DLY[lane];
  for (uint32_t i = 0; self_cal && i < 8u; i++) {
    uint32_t e = DPHY->DLY[lane];
    if (e == d) break;
    d = e;
  }
  return d;
}

uint32_t bow_dphy_rx_read_delay(uint32_t lane) {
  if (lane >= DPHY_MAX_LANES) return 0;
  return dly_read(lane, bow_dphy_rx_self_cal());
}

bool bow_dphy_rx_wait_delay(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  uint32_t n = bow_dphy_rx_lanes();
  bool self_cal = bow_dphy_rx_self_cal();
  for (;;) {
    bool done = true;
    for (uint32_t l = 0; l < n; l++) {
      uint32_t d = dly_read(l, self_cal);
      if ((d & DPHY_DLY_OWN) && (d & DPHY_DLY_PEND)) done = false;
    }
    if (done) return true;
    if (expired(start, limit)) return false;
  }
}

void bow_dphy_rx_get_delays(uint32_t *d) {
  bool self_cal = bow_dphy_rx_self_cal();
  uint32_t n = bow_dphy_rx_lanes();
  for (uint32_t l = 0; l < DPHY_MAX_LANES; l++) {
    uint32_t v = l < n ? dly_read(l, self_cal) : 0;
    d[l] = self_cal ? DPHY_DLY_Q(v) : DPHY_DLY_CODE(v);
  }
}

void bow_dphy_rx_print_delays(uint32_t n) {
  uint32_t d[DPHY_MAX_LANES];
  bow_dphy_rx_get_delays(d);
  if (n > DPHY_MAX_LANES) n = DPHY_MAX_LANES;
  bow_printf("%u", d[0]);
  for (uint32_t i = 1; i < n; i++) bow_printf("/%u", d[i]);
}

void bow_dphy_rx_counters(bow_dphy_rx_cnt_t *c) {
  for (uint32_t l = 0; l < DPHY_MAX_LANES; l++) c->burst[l] = DPHY->CNT_BURST[l];
  c->clk_burst = DPHY->CNT_CLK;
  c->lp_err = DPHY->CNT_LPERR;
}

typedef struct {
  bow_dphy_rx_cnt_t c;
  uint32_t lp, hs;
} snap_t;

static void snap_read(snap_t *s) {
  bow_dphy_rx_counters(&s->c);
  s->lp = DPHY->LANE_LP;
  s->hs = DPHY->LANE_HS;
}

static bool snap_same(const snap_t *a, const snap_t *b) {
  for (uint32_t l = 0; l < DPHY_MAX_LANES; l++) {
    if (a->c.burst[l] != b->c.burst[l]) return false;
  }
  return a->c.clk_burst == b->c.clk_burst && a->c.lp_err == b->c.lp_err && a->lp == b->lp &&
         a->hs == b->hs;
}

void bow_dphy_rx_snapshot(bow_dphy_rx_cnt_t *c, uint32_t *lp, uint32_t *hs) {
  /* one register per counter and LANE_LP / LANE_HS apart (before step 4
   * STATUS held both lane states and CNT_BURST lanes 0 and 1): while bursts
   * arrive, read everything again until two reads agree */
  snap_t a, b;
  snap_read(&a);
  for (uint32_t i = 0; i < 8u; i++) {
    snap_read(&b);
    if (snap_same(&a, &b)) break;
    a = b;
  }
  *c = a.c;
  *lp = a.lp;
  *hs = a.hs;
}

void bow_dphy_rx_clear(void) {
  DPHY->CMD = DPHY_CMD_CNT_CLR;
  DPHY->ERR_STATUS = DPHY_ERR_ALL;
  DPHY->ERR_LANE = DPHY_ERR_LANE_ALL;
}

bool bow_dphy_rx_raw(uint32_t *w, bool now, uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  DPHY->RAW_CTRL = DPHY_RAW_ARM | (now ? DPHY_RAW_NOW : 0);
  while ((DPHY->RAW_CTRL & (DPHY_RAW_ARMED | DPHY_RAW_DONE)) != DPHY_RAW_DONE) {
    if (expired(start, limit)) return false;
  }
  for (uint32_t i = 0; i < DPHY_RAW_WORDS; i++) w[i] = DPHY->RAW[2u * i];
  return true;
}

uint32_t bow_dphy_rx_byteclk_hz(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms), max = 0;
  do {
    uint32_t v = DPHY->BYTECLK & 0xFFFFFu;
    if (v > max) max = v;
  } while (!expired(start, limit));
  return (uint32_t)(((uint64_t)max * bow_clk_hz()) >> 16); /* per 65536 CPU cycles */
}
