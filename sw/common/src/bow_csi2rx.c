/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MIPI CSI-2 receiver driver: start/stop around the sensor stream, counters,
 * eye calibration of the input delay taps, packet log and raw PHY capture.
 */
#include "bow_csi2rx.h"

#include "bow_printf.h"
#include "bow_probe.h"
#include "bow_time.h"

#define PHY_RDY_TIMEOUT_MS 10u

/* Data lane SETTLE, from the LP-00 that the state machine sees (~25-30 ns
 * after the pins). The sync search starts at the end of it, but looks back
 * over the words already received: 2 words, plus the RX FIFO of the Versal
 * XPHY (INFO.DLY_VID; up to ~4 words at 180 MHz). With 70 ns it would reach
 * back to ~62 ns after LP-00 there, into a long HS-PREPARE (up to 85 ns +
 * 6 UI = 89 ns at 1440 Mbit/s) whose random bits can match the sync pattern
 * (seen in simulation). 95 ns starts it after any HS-PREPARE and still before
 * the earliest sync byte (HS-PREPARE + HS-ZERO >= 145 ns + 10 UI). That holds
 * while the XPHY's RX FIFOs restart with every burst (BurstRxRst, the
 * default of the Huins camera build: cam_rx_start() in cam_sensor.c); without
 * it glitch words can add up to 8 words, then ~115 ns is needed: build option
 * -DSETTLE_VID_NS=115 together with -DCAM_BURST_RST=0 (cam_sensor.h). */
#define SETTLE_NS     70u
#ifndef SETTLE_VID_NS
#define SETTLE_VID_NS 95u
#endif

static uint32_t ms_cycles(uint32_t ms) { return ms * (bow_clk_hz() / 1000u); }

static bool expired(uint32_t start, uint32_t limit) {
  return (uint32_t)(bow_cycles() - start) > limit;
}

/* a * b / c without overflow (64 bit intermediate) */
static uint32_t muldiv(uint32_t a, uint32_t b, uint32_t c) {
  return c ? (uint32_t)((uint64_t)a * b / c) : 0;
}

/* Data lanes of the receiver (INFO): 1, 2 or 4. */
static uint32_t info_lanes(uint32_t info) {
  uint32_t n = CSI2RX_INFO_LANES(info);
  return n == 0 ? 1u : n > CSI2RX_MAX_LANES ? CSI2RX_MAX_LANES : n;
}

static uint32_t num_lanes(void) { return info_lanes(CSI2RX->INFO); }

/* DLY_VID: lanes written by bow_csi2rx_set_delay() since the start or the
 * last bow_csi2rx_forget_delays(); the others still use the delay of the
 * PHY's self-calibration (their DLYn [8:0] reads 0, or a tap written before
 * a PHY re-initialisation). */
static uint32_t dly_written;

/* DLYn of a lane. DLY_VID: [24:16] (CNTVALUEOUT) comes from the video clock
 * domain through one synchroniser per bit and VT tracking may step it, so a
 * read can mix two values: read until two reads agree (at most 8 reads). */
static uint32_t dly_read(uint32_t lane, bool vid) {
  uint32_t d = CSI2RX->DLY[lane];
  for (uint32_t i = 0; vid && i < 8u; i++) {
    uint32_t e = CSI2RX->DLY[lane];
    if (e == d) break;
    d = e;
  }
  return d;
}

/* CTRL = 0: the enables first, the stream selection once RX is off. */
static void rx_off(void) {
  CSI2RX->CTRL &= ~(CSI2RX_CTRL_PHY_EN | CSI2RX_CTRL_RX_EN);
  CSI2RX->CTRL = 0;
}

/* PHY timing in video clock cycles, rounded, 1..255 */
static uint32_t phy_cycles(uint32_t ns, uint32_t mhz) {
  uint32_t n = (ns * mhz + 500u) / 1000u;
  return n < 1u ? 1u : n > 255u ? 255u : n;
}

/* Clock miss timeout: the clock lane FSM sees one edge per byte clock
 * (8 UI), up to one video cycle late after the synchroniser. One byte clock
 * period, rounded up, + 3 cycles of margin: 5 cycles at 912 Mbit/s and
 * 200 MHz, so the gate closes early in T_CLK-TRAIL (>= 60 ns). */
static uint32_t clk_miss_cycles(uint32_t lane_rate, uint32_t mhz) {
  if (lane_rate == 0) return phy_cycles(40, mhz);
  uint64_t n = (8000000ull * mhz + lane_rate - 1u) / lane_rate + 3u;
  return n > 255u ? 255u : (uint32_t)n;
}

bool bow_csi2rx_probe(uint32_t *lanes, bool *phy) {
  uint32_t id;
  if (!bow_probe_read32(BOW32_CSI2RX_BASE, &id) || id != CSI2RX_ID_VALUE) return false;
  uint32_t info = CSI2RX->INFO;
  if (lanes) *lanes = CSI2RX_INFO_LANES(info);
  if (phy) *phy = (info & CSI2RX_INFO_PHY) != 0;
  return true;
}

uint32_t bow_csi2rx_lanes(void) {
  uint32_t c = CSI2RX->CTRL, max = num_lanes();
  uint32_t n = (c & CSI2RX_CTRL_LANES4) ? 4u : (c & CSI2RX_CTRL_LANES2) ? 2u : 1u;
  return n > max ? max : n;
}

int bow_csi2rx_start(uint32_t lanes, uint32_t dt, uint32_t lane_rate) {
  uint32_t info = CSI2RX->INFO, mhz = CSI2RX_INFO_MHZ(info);
  uint32_t ctrl = (lanes >= 4 ? CSI2RX_CTRL_LANES4 : 0) | (lanes >= 2 ? CSI2RX_CTRL_LANES2 : 0) |
                  CSI2RX_CTRL_DT(dt);
  /* PHY_CFG and the stream selection only change while the receiver is off;
   * 1 us lets the LP state machines reach their off state. Only the Versal
   * XPHY (DLY_VID) has a start-up calibration (XPLL lock + BISC, up to
   * ~1.3 ms after the FPGA start or a PHY re-initialisation) and says when
   * it is ready. The UltraScale+ PHY has none: PHY_RDY is tied to 1 there,
   * and reads 0 in bitstreams built before the bit existed. */
  rx_off();
  if (info & CSI2RX_INFO_DLY_VID) {
    uint32_t start = bow_cycles(), limit = ms_cycles(PHY_RDY_TIMEOUT_MS);
    while (!(CSI2RX->STATUS & CSI2RX_ST_PHY_RDY)) {
      if (expired(start, limit)) return CSI2RX_ENOTRDY;
    }
  }
  bow_delay_us(1);
  uint32_t settle = (info & CSI2RX_INFO_DLY_VID) ? SETTLE_VID_NS : SETTLE_NS;
  CSI2RX->PHY_CFG = CSI2RX_PHY_SETTLE(phy_cycles(settle, mhz)) | CSI2RX_PHY_LP_FILTER(2) |
                    CSI2RX_PHY_CLK_SETTLE(phy_cycles(150, mhz)) |
                    CSI2RX_PHY_CLK_MISS(clk_miss_cycles(lane_rate, mhz));
  CSI2RX->CTRL = ctrl;
  CSI2RX->CTRL = ctrl | CSI2RX_CTRL_PHY_EN | CSI2RX_CTRL_RX_EN;
  bow_csi2rx_clear();
  CSI2RX->IRQ_STATUS = CSI2RX_IRQ_ALL;
  return CSI2RX_OK;
}

void bow_csi2rx_stop(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  uint32_t quiet = 2u * CSI2RX->LINE_TIME;
  if (quiet == 0) quiet = bow_clk_hz() / 5000u; /* no line seen yet: 200 us */

  /* The sensor finishes the frame it has started. A new burst shows on the
   * burst counter, or on the HS state of a lane while it lasts (the counter
   * may be saturated). */
  CSI2RX->IRQ_STATUS = CSI2RX_IRQ_FE;
  uint32_t bursts = CSI2RX->CNT_BURST, last = bow_cycles();
  while (!(CSI2RX->IRQ_STATUS & CSI2RX_IRQ_FE) && !expired(start, limit)) {
    uint32_t st = CSI2RX->STATUS, b = CSI2RX->CNT_BURST;
    if (b != bursts || (st & CSI2RX_ST_HS_DATA)) {
      bursts = b;
      last = bow_cycles();
    } else if (!(st & CSI2RX_ST_IN_FRAME) && expired(last, quiet)) {
      break;
    }
  }
  /* Clearing PHY_EN closes the byte clock gate at once, also while the HS
   * clock still toggles (T_CLK-POST after the FE): let the clock lane FSM
   * close it first (clock miss or LP-11). A continuous clock never stops. */
  last = bow_cycles();
  while ((CSI2RX->STATUS & CSI2RX_ST_CE) && !expired(last, ms_cycles(1))) {
  }
  rx_off();
}

void bow_csi2rx_set_rx(bool on) {
  if (on) {
    CSI2RX->CTRL |= CSI2RX_CTRL_RX_EN;
  } else {
    CSI2RX->CTRL &= ~CSI2RX_CTRL_RX_EN;
  }
}

void bow_csi2rx_clear(void) {
  CSI2RX->CNT_CLR = 1;
  CSI2RX->ERR_STATUS = CSI2RX_ERR_ALL;
}

void bow_csi2rx_counters(bow_csi2rx_cnt_t *c) {
  /* in address order: errors are read after the packet counts */
  c->frames = CSI2RX->CNT_FRAME;
  c->packets = CSI2RX->CNT_PKT;
  c->lines = CSI2RX->CNT_LINE;
  uint32_t v = CSI2RX->CNT_ECC;
  c->ecc_corr = v & 0xFFFFu;
  c->ecc_err = v >> 16;
  v = CSI2RX->CNT_CRC;
  c->crc = v & 0xFFFFu;
  c->trunc = v >> 16;
  v = CSI2RX->CNT_SOT;
  c->sot[0] = v & 0xFFFFu;
  c->sot[1] = v >> 16;
  v = CSI2RX->CNT_DROP;
  c->drop = v & 0xFFFFu;
  c->ovf = v >> 16;
  v = CSI2RX->CNT_BURST;
  c->burst[0] = v & 0xFFFFu;
  c->burst[1] = v >> 16;
  v = CSI2RX->CNT_MISC;
  c->clk_burst = v & 0xFFFFu;
  c->lp_err = (v >> 16) & 0xFFu;
  c->misc_err = v >> 24;
  /* lanes 2 and 3 (0 on receivers with fewer lanes) */
  v = CSI2RX->CNT_SOT23;
  c->sot[2] = v & 0xFFFFu;
  c->sot[3] = v >> 16;
  v = CSI2RX->CNT_BURST23;
  c->burst[2] = v & 0xFFFFu;
  c->burst[3] = v >> 16;
}

uint32_t bow_csi2rx_link_errors(const bow_csi2rx_cnt_t *c) {
  return c->ecc_corr + c->ecc_err + c->crc + c->trunc + c->sot[0] + c->sot[1] + c->sot[2] +
         c->sot[3] + c->ovf + c->misc_err;
}

bool bow_csi2rx_link_check(uint32_t packets, uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  bow_csi2rx_cnt_t c;
  bow_csi2rx_clear();
  for (;;) {
    bow_csi2rx_counters(&c);
    if (bow_csi2rx_link_errors(&c)) return false;
    if (c.packets >= packets) return true;
    if (expired(start, limit)) return false;
  }
}

bool bow_csi2rx_wait_frame(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  CSI2RX->IRQ_STATUS = CSI2RX_IRQ_FE;
  while (!(CSI2RX->IRQ_STATUS & CSI2RX_IRQ_FE)) {
    if (expired(start, limit)) return false;
  }
  return true;
}

void bow_csi2rx_set_delay(uint32_t lane, uint32_t tap) {
  if (lane < CSI2RX_MAX_LANES) {
    CSI2RX->DLY[lane] = tap > CSI2RX_DLY_MAX ? CSI2RX_DLY_MAX : tap;
    dly_written |= 1u << lane;
  }
}

void bow_csi2rx_forget_delays(void) { dly_written = 0; }

uint32_t bow_csi2rx_read_delay(uint32_t lane) {
  if (lane >= CSI2RX_MAX_LANES) return 0;
  return dly_read(lane, (CSI2RX->INFO & CSI2RX_INFO_DLY_VID) != 0);
}

bool bow_csi2rx_wait_delay(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms), info = CSI2RX->INFO;
  bool vid = (info & CSI2RX_INFO_DLY_VID) != 0;
  uint32_t n = info_lanes(info), mask = vid ? dly_written : ~0u;
  for (;;) {
    bool done = true;
    for (uint32_t l = 0; l < n; l++) {
      if (!((mask >> l) & 1u)) continue;
      uint32_t d = dly_read(l, vid);
      if (CSI2RX_DLY_OUT(d) != CSI2RX_DLY_TAP(d)) done = false;
    }
    if (done) return true;
    if (expired(start, limit)) return false;
  }
}

/* ------------------------------------------------------------ calibration */
#define CAL_LINES 32u   /* error free accepted lines = good tap */
#define CAL_ALL   4u    /* sweep all lanes together */

/* Errors that a bad sampling point causes. Frame errors are not among them:
 * a frame that lost its FS at the previous tap ends with an FE without FS. */
#define CAL_TAP_ERRORS                                                                       \
  (CSI2RX_ERR_SOT | CSI2RX_ERR_ECC_CORR | CSI2RX_ERR_ECC | CSI2RX_ERR_CRC | CSI2RX_ERR_TRUNC | \
   CSI2RX_ERR_SKEW)

typedef struct {
  uint32_t step, npts, timeout_ms;
  uint32_t nl;       /* lanes calibrated */
  uint32_t nw;       /* DLY registers written per point: nl, at least 2 with DLY_VID 0 */
  uint32_t map[16];  /* last sweep: bit p = tap p * step good */
  uint32_t done[16]; /* bit p = tap p * step measured */
} cal_t;

static void cal_set(const uint32_t *taps, uint32_t n) {
  for (uint32_t l = 0; l < n; l++) bow_csi2rx_set_delay(l, taps[l]);
}

/* One tap measurement: 1 good, 0 bad, -1 tap not applied (no byte clock). */
static int cal_point(const cal_t *k, const uint32_t *taps) {
  cal_set(taps, k->nw);
  if (!bow_csi2rx_wait_delay(k->timeout_ms)) return -1;
  /* Events of the burst before the tap change can still arrive (the end of
   * a burst is only seen when the byte clock restarts): let them pass. */
  bow_delay_us(50);
  bow_csi2rx_clear();
  uint32_t start = bow_cycles(), limit = ms_cycles(k->timeout_ms);
  for (;;) {
    uint32_t lines = CSI2RX->CNT_LINE;
    if (CSI2RX->ERR_STATUS & CAL_TAP_ERRORS) return 0;
    if (lines >= CAL_LINES) return 1;
    if (expired(start, limit)) return 0;
  }
}

static void cal_clear(cal_t *k) {
  for (uint32_t i = 0; i < 16; i++) k->map[i] = k->done[i] = 0;
}

/* Measure point p with `lane` (or all lanes: CAL_ALL) at tap p * step, the
 * others at ref[]. 1 good, 0 bad, -1 no byte clock. */
static int cal_measure(cal_t *k, uint32_t lane, const uint32_t *ref, uint32_t p) {
  uint32_t taps[CSI2RX_MAX_LANES];
  for (uint32_t l = 0; l < CSI2RX_MAX_LANES; l++) {
    taps[l] = (lane == CAL_ALL || lane == l) ? p * k->step : ref[l];
  }
  int r = cal_point(k, taps);
  if (r >= 0) k->done[p / 32] |= 1u << (p % 32);
  if (r > 0) k->map[p / 32] |= 1u << (p % 32);
  return r;
}

/* Sweep the taps of `lane` (or CAL_ALL) over the range, the others at ref[]. */
static bool cal_sweep(cal_t *k, uint32_t lane, const uint32_t *ref) {
  cal_clear(k);
  for (uint32_t p = 0; p < k->npts; p++) {
    if (cal_measure(k, lane, ref, p) < 0) return false;
  }
  return true;
}

/* DLY_VID: from ref[lane] up, then down, until the first bad tap on each
 * side (grid of `step` taps; the others at ref[]). */
static bool cal_walk(cal_t *k, uint32_t lane, const uint32_t *ref) {
  uint32_t up = (ref[lane] + k->step - 1u) / k->step;
  int r;
  cal_clear(k);
  for (uint32_t p = up; p < k->npts; p++) {
    if ((r = cal_measure(k, lane, ref, p)) < 0) return false;
    if (r == 0) break;
  }
  for (uint32_t p = up < k->npts ? up : k->npts; p-- > 0;) {
    if ((r = cal_measure(k, lane, ref, p)) < 0) return false;
    if (r == 0) break;
  }
  return true;
}

static bool cal_good(const cal_t *k, uint32_t p) { return (k->map[p / 32] >> (p % 32)) & 1u; }
static bool cal_done(const cal_t *k, uint32_t p) { return (k->done[p / 32] >> (p % 32)) & 1u; }

/* Centre and width (taps) of the widest run of good taps. Runs do not wrap
 * around; a run that touches neither end of the range is preferred when it
 * is at least half as wide (the eye may continue beyond the end). */
static bool cal_best(const cal_t *k, uint32_t *centre, uint32_t *width) {
  uint32_t best = 0, best_n = 0, in = 0, in_n = 0;
  for (uint32_t p = 0; p < k->npts;) {
    if (!cal_good(k, p)) {
      p++;
      continue;
    }
    uint32_t a = p;
    while (p < k->npts && cal_good(k, p)) p++;
    uint32_t n = p - a;
    if (n > best_n) {
      best = a;
      best_n = n;
    }
    if (a > 0 && p < k->npts && n > in_n) {
      in = a;
      in_n = n;
    }
  }
  if (best_n == 0) return false;
  if ((best == 0 || best + best_n == k->npts) && 2u * in_n >= best_n) {
    best = in;
    best_n = in_n;
  }
  *centre = (2u * best + best_n - 1u) * k->step / 2u;
  *width = best_n * k->step;
  return true;
}

static void put_list(const uint32_t *v, uint32_t n) {
  bow_printf("%u", v[0]);
  for (uint32_t i = 1; i < n; i++) bow_printf("/%u", v[i]);
}

/* "lane0 |....#######.....| tap 120 width 112 (other lane at 128)" */
static void cal_print(const cal_t *k, uint32_t lane, const uint32_t *ref, bool ok,
                      uint32_t centre, uint32_t width) {
  char buf[33];
  uint32_t n = 0;
  if (lane == CAL_ALL) {
    bow_puts("lanes |");
  } else {
    bow_printf("lane%u |", lane);
  }
  for (uint32_t p = 0; p < k->npts; p++) {
    buf[n++] = !cal_done(k, p) ? '-' : cal_good(k, p) ? '#' : '.';
    if (n == 32 || p + 1 == k->npts) {
      buf[n] = '\0';
      bow_puts(buf);
      n = 0;
    }
  }
  if (ok) {
    bow_printf("| tap %u width %u", centre, width);
  } else {
    bow_puts("| no eye");
  }
  if (lane != CAL_ALL && k->nl == 2) {
    bow_printf(" (other lane at %u)", ref[1u - lane]);
  } else if (lane != CAL_ALL && k->nl > 2) {
    bow_puts(" (others at");
    for (uint32_t l = 0; l < k->nl; l++) {
      if (l != lane) bow_printf(" %u", ref[l]);
    }
    bow_puts(")");
  }
  bow_puts("\n");
}

bool bow_csi2rx_calibrate(uint32_t step, uint32_t tap_timeout_ms, bow_csi2rx_cal_t *cal,
                          bool verbose) {
  cal_t k;
  uint32_t c[CSI2RX_MAX_LANES], old[CSI2RX_MAX_LANES], w;
  bool vid = (CSI2RX->INFO & CSI2RX_INFO_DLY_VID) != 0, ok;

  if (step == 0) step = 1;
  k.step = step;
  k.npts = CSI2RX_DLY_MAX / step + 1u;
  k.timeout_ms = tap_timeout_ms;
  k.nl = bow_csi2rx_lanes();
  k.nw = (vid || k.nl > 2) ? k.nl : 2u;
  for (uint32_t l = 0; l < CSI2RX_MAX_LANES; l++) {
    uint32_t d = l < k.nw ? dly_read(l, vid) : 0;
    /* DLY_VID: what the lane uses now (BISC after reset), not the 0 of a
     * register never written */
    old[l] = c[l] = vid ? CSI2RX_DLY_OUT(d) : CSI2RX_DLY_TAP(d);
    cal->tap[l] = cal->width[l] = 0;
  }
  cal->lanes = k.nl;

  /* DLY_VID: the delays in use (BISC) are the starting point if the link is
   * clean with them; otherwise (and always with DLY_VID 0) pass 1. */
  ok = false;
  if (vid) {
    int r = cal_point(&k, c);
    if (r < 0) goto no_clock;
    ok = r > 0;
    if (verbose) {
      bow_puts("delays in use ");
      put_list(c, k.nl);
      bow_puts(ok ? ": link ok\n" : ": link errors\n");
    }
  }
  if (!ok) {
    /* pass 1: all lanes with the same tap */
    if (!cal_sweep(&k, CAL_ALL, c)) goto no_clock;
    ok = cal_best(&k, &c[0], &w);
    for (uint32_t l = 1; l < CSI2RX_MAX_LANES; l++) c[l] = c[0];
    if (verbose) cal_print(&k, CAL_ALL, c, ok, c[0], w);
    /* no common eye of 2 lanes (lane skew): lane 1 at 4 taps over the
     * range, sweep lane 0 */
    for (uint32_t t1 = 0; !ok && k.nl == 2 && t1 <= 384u; t1 += 128u) {
      c[1] = t1;
      if (!cal_sweep(&k, 0, c)) goto no_clock;
      ok = cal_best(&k, &c[0], &w);
      if (verbose) cal_print(&k, 0, c, ok, c[0], w);
    }
    if (!ok) goto fail;
  }

  /* pass 2: each lane alone, the others at their pass 1 centre (DLY_VID:
   * at their best tap so far) */
  if (k.nl == 1 && !vid) {
    cal->tap[0] = c[0];
    cal->width[0] = w;
  }
  for (uint32_t l = 0; (k.nl > 1 || vid) && l < k.nl; l++) {
    if (!(vid ? cal_walk(&k, l, c) : cal_sweep(&k, l, c))) goto no_clock;
    ok = cal_best(&k, &cal->tap[l], &cal->width[l]);
    if (verbose) cal_print(&k, l, c, ok, cal->tap[l], cal->width[l]);
    if (!ok) goto fail;
    if (vid) c[l] = cal->tap[l];
  }

  /* Program the result; the frame received during the change ends, then
   * start from clean counters. */
  cal_set(cal->tap, k.nw);
  if (!bow_csi2rx_wait_delay(tap_timeout_ms)) goto no_clock;
  if (!bow_csi2rx_wait_frame(tap_timeout_ms)) {
    if (verbose) bow_puts("no frame end with the new taps\n");
    goto fail;
  }
  bow_csi2rx_clear();
  return true;

no_clock:
  if (verbose) {
    bow_puts(vid ? "tap not applied: DLYn read back differs (PHY not ready?)\n"
                 : "tap not applied: no byte clock (is the sensor streaming?)\n");
  }
fail:
  cal_set(old, k.nw);
  return false;
}

void bow_csi2rx_print_cal(const bow_csi2rx_cal_t *cal) {
  uint32_t n = cal->lanes < 2u ? 2u : cal->lanes > CSI2RX_MAX_LANES ? CSI2RX_MAX_LANES : cal->lanes;
  bow_puts("taps ");
  put_list(cal->tap, n);
  bow_puts(" eye ");
  put_list(cal->width, n);
}

/* -------------------------------------------------------- log and raw words */
uint32_t bow_csi2rx_log(uint32_t *e, uint32_t mode, uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms), ctrl;
  mode &= CSI2RX_LOG_TRIG_FS | CSI2RX_LOG_STOP_FE;
  CSI2RX->LOG_CTRL = mode | CSI2RX_LOG_ARM;
  while (((ctrl = CSI2RX->LOG_CTRL) & (CSI2RX_LOG_ARMED | CSI2RX_LOG_DONE)) != CSI2RX_LOG_DONE) {
    if (expired(start, limit)) return 0;
  }
  uint32_t first = (mode & CSI2RX_LOG_STOP_FE) ? CSI2RX_LOG_WPTR(ctrl) : 0;
  for (uint32_t i = 0; i < CSI2RX_LOG_ENTRIES; i++) {
    e[i] = CSI2RX->LOG[(first + i) % CSI2RX_LOG_ENTRIES];
  }
  if (!(mode & CSI2RX_LOG_STOP_FE)) return CSI2RX_LOG_ENTRIES;

  /* The capture ended with the first FE of the selected VC; when it did not
   * wrap around, the entries after it are older ones. */
  uint32_t c = CSI2RX->CTRL, vc = (c & CSI2RX_CTRL_VC_MASK) >> 5;
  for (uint32_t i = 0; i < CSI2RX_LOG_ENTRIES; i++) {
    if (CSI2RX_LOG_DT(e[i]) == CSI2_DT_FE && CSI2RX_LOG_ECC(e[i]) != CSI2RX_ECC_ERR &&
        ((c & CSI2RX_CTRL_VC_ANY) || CSI2RX_LOG_VC(e[i]) == vc)) {
      return i + 1;
    }
  }
  return CSI2RX_LOG_ENTRIES;
}

static const char *dt_name(uint32_t dt) {
  switch (dt) {
    case CSI2_DT_FS: return "FS   ";
    case CSI2_DT_FE: return "FE   ";
    case CSI2_DT_LS: return "LS   ";
    case CSI2_DT_LE: return "LE   ";
    case CSI2_DT_EMB: return "EMB  ";
    case CSI2_DT_RAW8: return "RAW8 ";
    case CSI2_DT_RAW10: return "RAW10";
    case CSI2_DT_OB: return "OB   "; /* user defined 8: IMX274 optical black */
    default: return dt < 0x10u ? "short" : "long ";
  }
}

void bow_csi2rx_print_log(const uint32_t *e, uint32_t n) {
  static const char *const ecc[4] = {"", " ecc-corrected", " ecc-error", " ecc-?"};
  for (uint32_t i = 0; i < n; i++) {
    uint32_t v = e[i];
    bow_printf("  %2u vc%u dt %02x %s wc %u%s%s%s%s%s\n", i, CSI2RX_LOG_VC(v), CSI2RX_LOG_DT(v),
               dt_name(CSI2RX_LOG_DT(v)), CSI2RX_LOG_WC(v), ecc[CSI2RX_LOG_ECC(v)],
               (v & CSI2RX_LOG_CRC_ERR) ? " crc-error" : "",
               (v & CSI2RX_LOG_TRUNC) ? " truncated" : "",
               (v & CSI2RX_LOG_ACCEPTED) ? " accepted" : "",
               (v & CSI2RX_LOG_OVF) ? " overflow" : "");
  }
}

bool bow_csi2rx_raw(uint32_t *w, bool now, uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  CSI2RX->RAW_CTRL = CSI2RX_RAW_ARM | (now ? CSI2RX_RAW_NOW : 0);
  while ((CSI2RX->RAW_CTRL & (CSI2RX_RAW_ARMED | CSI2RX_RAW_DONE)) != CSI2RX_RAW_DONE) {
    if (expired(start, limit)) return false;
  }
  for (uint32_t i = 0; i < CSI2RX_RAW_WORDS; i++) w[i] = CSI2RX->RAW[i];
  return true;
}

uint32_t bow_csi2rx_byteclk_hz(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms), max = 0;
  do {
    uint32_t v = CSI2RX->BYTECLK & 0xFFFFFu;
    if (v > max) max = v;
  } while (!expired(start, limit));
  return (uint32_t)(((uint64_t)max * bow_clk_hz()) >> 16); /* per 65536 CPU cycles */
}

/* ----------------------------------------------------------------- status */
static const char *lp_state(uint32_t st, uint32_t lp, uint32_t hs_bit) {
  static const char *const names[4] = {"00", "01", "10", "11"};
  return (st & hs_bit) ? "HS" : names[lp];
}

/* Values of the per lane lists: 4 while 4 lanes are in use, else 2 */
static uint32_t list_lanes(void) { return bow_csi2rx_lanes() > 2u ? CSI2RX_MAX_LANES : 2u; }

/* Delays of the first n lanes: DLY_VID the ones in use ([24:16]: the BISC
 * result until a tap is loaded, the written [8:0] reads 0 before), else the
 * written taps (the IDELAY takes them at the next burst). */
static void delays(uint32_t *d, uint32_t n, bool vid) {
  for (uint32_t l = 0; l < n; l++) {
    uint32_t v = dly_read(l, vid);
    d[l] = vid ? CSI2RX_DLY_OUT(v) : CSI2RX_DLY_TAP(v);
  }
}

void bow_csi2rx_print_delays(void) {
  uint32_t d[CSI2RX_MAX_LANES], n = list_lanes();
  delays(d, n, (CSI2RX->INFO & CSI2RX_INFO_DLY_VID) != 0);
  put_list(d, n);
}

void bow_csi2rx_print_status(void) {
  /* snapshot first: printing takes longer than a frame at low baud rates */
  bow_csi2rx_cnt_t c;
  bow_csi2rx_counters(&c);
  uint32_t err = bow_csi2rx_link_errors(&c), clk = bow_clk_hz();
  uint32_t st = CSI2RX->STATUS, fi = CSI2RX->FRAME_INFO, li = CSI2RX->LINE_INFO;
  uint32_t sum = CSI2RX->FRAME_SUM, ft = CSI2RX->FRAME_TIME, lt = CSI2RX->LINE_TIME;
  uint32_t info = CSI2RX->INFO, n = list_lanes(), d[4];
  bool vid = (info & CSI2RX_INFO_DLY_VID) != 0;
  delays(d, n, vid);
  /* BYTECLK covers 65536 CPU cycles: watch it for a whole frame */
  uint32_t byte_hz = bow_csi2rx_byteclk_hz(ft ? muldiv(ft, 1000u, clk) + 2u : 0u);

  if (c.packets == 0) {
    bow_puts("csi2rx: no data\n");
  } else if (c.frames > 0 && err == 0 && c.lines == 0) {
    /* frames without an accepted line: CTRL.DT/VC do not match the stream,
     * or the sensor sends several packets per HS burst */
    bow_puts("csi2rx: no lines (DT/VC filter?)\n");
  } else if (c.frames > 0 && err == 0) {
    bow_puts("csi2rx: link ok\n");
  } else {
    bow_puts("csi2rx: link errors\n");
  }
  bow_printf("  frames %u lines/frame %u wc %u dt %02x sum %08x\n", c.frames,
             CSI2RX_FRAME_LINES(fi), CSI2RX_LINE_WC(li), CSI2RX_LINE_DT(li), sum);
  bow_printf("  errors: ecc %u/%u crc %u trunc %u sot ", c.ecc_corr, c.ecc_err, c.crc, c.trunc);
  put_list(c.sot, n);
  bow_printf(" drop %u ovf %u misc %u\n", c.drop, c.ovf, c.misc_err);
  bow_printf("  timing: frame %u us, line %u ns, byte clock %u kHz\n", muldiv(ft, 1000000u, clk),
             muldiv(lt, 1000000000u, clk), byte_hz / 1000u);
  bow_printf("  phy: lp clk %s", lp_state(st, CSI2RX_ST_LP_CLK(st), CSI2RX_ST_HS_CLK));
  for (uint32_t l = 0; l < n; l++) {
    bow_printf(" d%u %s", l, lp_state(st, CSI2RX_ST_LP(st, l), CSI2RX_ST_HS(l)));
  }
  bow_puts(", bursts ");
  put_list(c.burst, n);
  bow_printf(" clk %u, delay ", c.clk_burst);
  put_list(d, n);
  /* only the Versal XPHY has PHY_RDY (bitstreams before it read 0) */
  if (vid && !(st & CSI2RX_ST_PHY_RDY)) bow_puts(", PHY not ready");
  bow_puts("\n");
}
