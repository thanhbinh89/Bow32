/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * MIPI CSI-2 receiver driver: start/stop around the sensor stream, counters,
 * eye calibration of the input delay codes (the D-PHY's, bow_dphy_rx.c) and
 * packet log.
 */
#include "bow_csi2rx.h"

#include "bow_printf.h"
#include "bow_probe.h"
#include "bow_time.h"

#define PHY_RDY_TIMEOUT_MS 10u

static uint32_t ms_cycles(uint32_t ms) { return ms * (bow_clk_hz() / 1000u); }

static bool expired(uint32_t start, uint32_t limit) {
  return (uint32_t)(bow_cycles() - start) > limit;
}

/* a * b / c without overflow (64 bit intermediate) */
static uint32_t muldiv(uint32_t a, uint32_t b, uint32_t c) {
  return c ? (uint32_t)((uint64_t)a * b / c) : 0;
}

/* "a/b/c": n values separated by slashes */
static void put_list(const uint32_t *v, uint32_t n) {
  bow_printf("%u", v[0]);
  for (uint32_t i = 1; i < n; i++) bow_printf("/%u", v[i]);
}

/* Data lanes of the receiver (INFO): 1, 2 or 4. */
static uint32_t info_lanes(uint32_t info) {
  uint32_t n = CSI2RX_INFO_LANES(info);
  return n == 0 ? 1u : n > CSI2RX_MAX_LANES ? CSI2RX_MAX_LANES : n;
}

static uint32_t num_lanes(void) { return info_lanes(CSI2RX->INFO); }

/* CTRL = 0: the enables first, the stream selection once RX is off. */
static void rx_off(void) {
  CSI2RX->CTRL &= ~(CSI2RX_CTRL_PHY_EN | CSI2RX_CTRL_RX_EN);
  CSI2RX->CTRL = 0;
}

/* CTRL.EXTRA: bytes the end of a burst may add after a packet on every lane
 * (T_HS-TRAIL max 105 ns + 12 UI, LP-11 detection ~60 ns, + 6 bytes of
 * pipeline; + the bytes the PHY adds (trail, INFO2 of the D-PHY: 8 for the
 * Versal XPHY, up to 8 words of its RX FIFO reach the receiver before the end
 * of the burst does), times the lanes in use, + 8. 4 lanes at 1440 Mbit/s:
 * 160, 192 with the XPHY; 0 lane rate: the reset value 64. Measured trails:
 * 17..20 bytes on 2 lanes (KV260, IMX219 at 912 Mbit/s: 62 is set), 49..52
 * bytes on 4 lanes (Huins VP1902, IMX274 through the XPHY: 192 leaves 140
 * bytes, the reset value 64 only 12). */
static uint32_t extra_bytes(uint32_t lane_rate, uint32_t lanes, uint32_t trail) {
  if (lane_rate == 0) return 64u;
  uint64_t ui_ps = 1000000000000ull / lane_rate;
  uint64_t per = (165000u + 12u * ui_ps + 8u * ui_ps - 1u) / (8u * ui_ps) + 6u + trail;
  uint64_t n = per * lanes + 8u;
  return n > 255u ? 255u : (uint32_t)n;
}

bool bow_csi2rx_probe(uint32_t *lanes, bool *phy) {
  uint32_t id;
  if (!bow_probe_read32(BOW32_CSI2RX_BASE, &id) || id != CSI2RX_ID_VALUE) return false;
  uint32_t info = CSI2RX->INFO;
  /* no alias: the PHY registers of a bitstream before the split are not
   * where this driver looks for them */
  uint32_t ver = (info & CSI2RX_INFO_DPHY) ? bow_dphy_rx_version() : 0u;
  if (ver == 0) {
    bow_puts("csi2rx: bitstream before the D-PHY split, rebuild it\n");
    return false;
  }
  /* nor those of another map version of the D-PHY (step 6: CMD[1] is REINIT,
   * CTRL / TIM0 need CMD.APPLY): bitstream and firmware from one commit */
  if (ver != DPHY_MAP_VERSION) {
    bow_printf("csi2rx: D-PHY register map version %u, this firmware needs %u: %s older than "
               "the %s, rebuild them from one commit\n", ver, DPHY_MAP_VERSION,
               ver < DPHY_MAP_VERSION ? "bitstream" : "firmware",
               ver < DPHY_MAP_VERSION ? "firmware" : "bitstream");
    return false;
  }
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
  uint32_t n = lanes >= 4 ? 4u : lanes >= 2 ? 2u : 1u;
  uint32_t trail = DPHY_INFO2_TRAIL(DPHY->INFO2);
  uint32_t ctrl = (lanes >= 4 ? CSI2RX_CTRL_LANES4 : 0) | (lanes >= 2 ? CSI2RX_CTRL_LANES2 : 0) |
                  CSI2RX_CTRL_DT(dt) | CSI2RX_CTRL_EXTRA(extra_bytes(lane_rate, n, trail));
  /* The D-PHY's TIM0 and the stream selection only change while the
   * receiver is off; 1 us lets the LP state machines reach their off state.
   * Only a self-calibrating PHY (the Versal XPHY) has a start-up calibration
   * (XPLL lock + BISC, up to ~1.3 ms after the FPGA start or a PHY
   * re-initialisation) and says when it is ready; the UltraScale+ PHY has
   * none (READY is 1 there). */
  rx_off();
  if (bow_dphy_rx_self_cal() && !bow_dphy_rx_wait_ready(PHY_RDY_TIMEOUT_MS)) {
    return CSI2RX_ENOTRDY;
  }
  bow_delay_us(1);
  if (!bow_dphy_rx_timing(lane_rate)) return CSI2RX_EAPPLY;
  CSI2RX->CTRL = ctrl;
  CSI2RX->CTRL = ctrl | CSI2RX_CTRL_PHY_EN | CSI2RX_CTRL_RX_EN;
  bow_csi2rx_clear();
  CSI2RX->IRQ_STATUS = CSI2RX_IRQ_ALL;
  return CSI2RX_OK;
}

const char *bow_csi2rx_strerror(int r) {
  switch (r) {
    case CSI2RX_OK: return "ok";
    case CSI2RX_ENOTRDY: return "D-PHY not ready (AFE_STATUS.READY = 0)";
    case CSI2RX_EAPPLY: return "the D-PHY did not take CMD.APPLY (no lp clock?)";
    default: return "receiver start failed";
  }
}

void bow_csi2rx_stop(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  uint32_t quiet = 2u * CSI2RX->LINE_TIME;
  if (quiet == 0) quiet = bow_clk_hz() / 5000u; /* no line seen yet: 200 us */

  /* The sensor finishes the frame it has started. A new burst shows on the
   * D-PHY's burst counter of lane 0, or on the HS state of a lane while it
   * lasts (the counter may be saturated). */
  CSI2RX->IRQ_STATUS = CSI2RX_IRQ_FE;
  uint32_t bursts = DPHY->CNT_BURST[0], last = bow_cycles();
  while (!(CSI2RX->IRQ_STATUS & CSI2RX_IRQ_FE) && !expired(start, limit)) {
    uint32_t hs = DPHY->LANE_HS, b = DPHY->CNT_BURST[0];
    if (b != bursts || (hs & DPHY_LANE_HS_DATA)) {
      bursts = b;
      last = bow_cycles();
    } else if (!(CSI2RX->STATUS & CSI2RX_ST_IN_FRAME) && expired(last, quiet)) {
      break;
    }
  }
  /* Clearing PHY_EN closes the byte clock gate at once, also while the HS
   * clock still toggles (T_CLK-POST after the FE): let the clock lane FSM
   * close it first (clock miss or LP-11; RxClkActiveHS of the D-PHY). A
   * continuous clock never stops. */
  last = bow_cycles();
  while ((DPHY->LANE_HS & DPHY_LANE_HS_CLK_ACT) && !expired(last, ms_cycles(1))) {
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
  bow_dphy_rx_clear();
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
  c->misc_err = CSI2RX->CNT_MISC >> 24;
  /* lanes 2 and 3 (0 on receivers with fewer lanes) */
  v = CSI2RX->CNT_SOT23;
  c->sot[2] = v & 0xFFFFu;
  c->sot[3] = v >> 16;
  v = CSI2RX->CNT_EXT;
  c->extra = v & 0xFFFFu;
  c->deskew = v >> 16;
  /* the D-PHY's: HS entries, LP errors */
  bow_dphy_rx_cnt_t d;
  bow_dphy_rx_counters(&d);
  for (uint32_t l = 0; l < CSI2RX_MAX_LANES; l++) c->burst[l] = d.burst[l];
  c->clk_burst = d.clk_burst;
  c->lp_err = d.lp_err;
}

uint32_t bow_csi2rx_link_errors(const bow_csi2rx_cnt_t *c) {
  return c->ecc_corr + c->ecc_err + c->crc + c->trunc + c->sot[0] + c->sot[1] + c->sot[2] +
         c->sot[3] + c->ovf + c->misc_err + c->extra;
}

/* Values of the per lane lists (sot, LP state, bursts, delay): 4 while 4
 * lanes are in use, else 2. While the receiver is off (CTRL.PHY_EN = 0:
 * CTRL holds no lane selection then) the lanes of the build (INFO): 4 on the
 * Huins camera build, e.g. after `stop` or `sensor on`. */
static uint32_t list_lanes(void) {
  uint32_t n = (CSI2RX->CTRL & CSI2RX_CTRL_PHY_EN) ? bow_csi2rx_lanes() : num_lanes();
  return n > 2u ? CSI2RX_MAX_LANES : 2u;
}

/* the terms of bow_csi2rx_link_errors(): keep both lists in step (sot: as
 * list_lanes()) */
void bow_csi2rx_print_errors(const bow_csi2rx_cnt_t *c) {
  bow_printf("ecc %u/%u crc %u trunc %u sot ", c->ecc_corr, c->ecc_err, c->crc, c->trunc);
  put_list(c->sot, list_lanes());
  bow_printf(" ovf %u misc %u extra %u", c->ovf, c->misc_err, c->extra);
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

bool bow_csi2rx_link_check_frames(uint32_t frames, uint32_t timeout_ms, uint32_t *done) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms), n = 0;
  bool whole = false; /* a frame start seen since the clear: the next FE ends a whole frame */
  bool ok = false;
  bow_csi2rx_cnt_t c;
  bow_csi2rx_clear();
  CSI2RX->IRQ_STATUS = CSI2RX_IRQ_FS | CSI2RX_IRQ_FE;
  for (;;) {
    uint32_t irq = CSI2RX->IRQ_STATUS & (CSI2RX_IRQ_FS | CSI2RX_IRQ_FE);
    if (irq) CSI2RX->IRQ_STATUS = irq;
    /* an FE and the next FS in one read: the FE ends the frame before */
    if ((irq & CSI2RX_IRQ_FE) && whole) n++;
    if (irq & CSI2RX_IRQ_FS) whole = true;
    /* the counters after the status: they hold every error of the frames
     * counted (their packets come before their FE) */
    bow_csi2rx_counters(&c);
    if (bow_csi2rx_link_errors(&c)) break;
    if (n >= frames) {
      ok = true;
      break;
    }
    if (expired(start, limit)) break;
  }
  if (done) *done = n;
  return ok;
}

bool bow_csi2rx_wait_frame(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  CSI2RX->IRQ_STATUS = CSI2RX_IRQ_FE;
  while (!(CSI2RX->IRQ_STATUS & CSI2RX_IRQ_FE)) {
    if (expired(start, limit)) return false;
  }
  return true;
}

/* ------------------------------------------------------------ calibration */
#define CAL_LINES 32u   /* error free accepted lines = good tap */
#define CAL_ALL   4u    /* sweep all lanes together */

/* Errors that a bad sampling point causes: CSI2RX_ERR_TAP. Frame errors are
 * not among them: a frame that lost its FS at the previous tap ends with an
 * FE without FS. */

typedef struct {
  uint32_t step, npts, timeout_ms;
  uint32_t nl;       /* lanes calibrated */
  uint32_t nw;       /* DLY registers written per point: nl, at least 2 with the UltraScale+ PHY */
  uint32_t map[16];  /* last sweep: bit p = tap p * step good */
  uint32_t done[16]; /* bit p = tap p * step measured */
} cal_t;

static void cal_set(const uint32_t *taps, uint32_t n) {
  for (uint32_t l = 0; l < n; l++) bow_dphy_rx_set_delay(l, taps[l]);
}

/* One tap measurement: 1 good, 0 bad, -1 tap not applied (no byte clock). */
static int cal_point(const cal_t *k, const uint32_t *taps) {
  cal_set(taps, k->nw);
  if (!bow_dphy_rx_wait_delay(k->timeout_ms)) return -1;
  /* Events of the burst before the tap change can still arrive (the end of
   * a burst is only seen when the byte clock restarts): let them pass. */
  bow_delay_us(50);
  bow_csi2rx_clear();
  uint32_t start = bow_cycles(), limit = ms_cycles(k->timeout_ms);
  for (;;) {
    uint32_t lines = CSI2RX->CNT_LINE;
    if (CSI2RX->ERR_STATUS & CSI2RX_ERR_TAP) return 0;
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

/* Self-calibrating PHY: from ref[lane] up, then down, until the first bad
 * tap on each side (grid of `step` taps; the others at ref[]). */
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
  bool vid = bow_dphy_rx_self_cal(), ok;

  if (step == 0) step = 1;
  k.step = step;
  k.npts = DPHY_DLY_MAX / step + 1u;
  k.timeout_ms = tap_timeout_ms;
  k.nl = bow_csi2rx_lanes();
  k.nw = (vid || k.nl > 2) ? k.nl : 2u;
  for (uint32_t l = 0; l < CSI2RX_MAX_LANES; l++) {
    uint32_t d = l < k.nw ? bow_dphy_rx_read_delay(l) : 0;
    /* self-calibrating PHY: what the lane uses now (BISC after reset), not
     * the 0 of a register never written */
    old[l] = c[l] = vid ? DPHY_DLY_Q(d) : DPHY_DLY_CODE(d);
    cal->tap[l] = cal->width[l] = 0;
  }
  cal->lanes = k.nl;

  /* Self-calibrating PHY: the delays in use (BISC) are the starting point if
   * the link is clean with them; otherwise (and always with the UltraScale+
   * PHY) pass 1. */
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

  /* pass 2: each lane alone, the others at their pass 1 centre (self-
   * calibrating PHY: at their best tap so far) */
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
   * start from clean counters. That frame may have lost its frame start at
   * the last swept tap: its end does not count, the next one is up to about
   * two frames away. */
  cal_set(cal->tap, k.nw);
  if (!bow_dphy_rx_wait_delay(tap_timeout_ms)) goto no_clock;
  if (!bow_csi2rx_wait_frame(2u * tap_timeout_ms)) {
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

/* ----------------------------------------------------------- margin check */
/* Start and end of frame interrupts, polled by the margin check. */
#define MARGIN_IRQ (CSI2RX_IRQ_FS | CSI2RX_IRQ_FE)

/* DLY registers written per point, as in the calibration: the lanes in use,
 * at least 2 with the UltraScale+ PHY. */
static uint32_t margin_nw(uint32_t nl) {
  return (bow_dphy_rx_self_cal() || nl > 2u) ? nl : 2u;
}

/* One margin point: taps[0..nw-1] on the lanes, nl lanes in use.
 * at_fe: the previous point has just seen a frame end (it was clean), so no
 * burst is in flight. The counters are cleared first, then the taps are
 * written. They load at the next burst, the frame start (or at once with a
 * continuous clock or a self-calibrating PHY), so a frame start lost at the new taps counts
 * as an error of this point. Otherwise the taps are written first, and the
 * events of the burst in flight pass (50 us) before the counters are
 * cleared. Then `frames` frame ends, the first sampling error, or timeout_ms
 * without a frame start or end. The frame in progress may have lost its
 * frame start at the previous taps, and its end then does not count
 * (IRQ_STATUS.FE needs the FS): the timer restarts on the first frame start
 * after each frame end. 1 clean, 0 errors, -1 not measured. */
static int margin_point(const uint32_t *taps, uint32_t nw, uint32_t nl, bool at_fe,
                        uint32_t frames, uint32_t timeout_ms, bow_csi2rx_mpoint_t *p) {
  bow_csi2rx_cnt_t c;
  bool fs_restart = true;
  for (uint32_t l = 0; l < CSI2RX_MAX_LANES; l++) p->tap[l] = l < nw ? taps[l] : 0u;
  p->frames = p->lines = p->errors = p->err = 0;
  p->bits = 0;
  p->result = -1;
  if (at_fe) {
    bow_csi2rx_clear();
    CSI2RX->IRQ_STATUS = MARGIN_IRQ;
  }
  cal_set(taps, nw);
  if (!bow_dphy_rx_wait_delay(timeout_ms)) return -1;
  if (!at_fe) {
    bow_delay_us(50);
    bow_csi2rx_clear();
    CSI2RX->IRQ_STATUS = MARGIN_IRQ;
  }
  uint32_t start = bow_cycles(), limit = ms_cycles(timeout_ms);
  while (p->frames < frames) {
    uint32_t irq;
    if (CSI2RX->ERR_STATUS & CSI2RX_ERR_TAP) break;
    irq = CSI2RX->IRQ_STATUS & MARGIN_IRQ;
    if (irq) CSI2RX->IRQ_STATUS = irq;
    if (irq & CSI2RX_IRQ_FE) {
      p->frames++;
      start = bow_cycles();
      fs_restart = true;
    } else if ((irq & CSI2RX_IRQ_FS) && fs_restart) {
      start = bow_cycles();
      fs_restart = false;
    } else if (expired(start, limit)) {
      break;
    }
  }
  bow_csi2rx_counters(&c);
  p->err = CSI2RX->ERR_STATUS;
  p->lines = c.lines;
  p->errors = c.ecc_corr + c.ecc_err + c.crc + c.trunc + ((p->err & CSI2RX_ERR_SKEW) ? 1u : 0u);
  for (uint32_t l = 0; l < CSI2RX_MAX_LANES; l++) p->errors += c.sot[l];
  /* bits per data lane: the packet bits / nl (1, 2 or 4) */
  p->bits = ((uint64_t)c.lines * (CSI2RX_LINE_WC(CSI2RX->LINE_INFO) + 6u) * 8u) >>
            (nl >= 4u ? 2u : nl - 1u);
  p->result = p->errors ? 0 : p->frames >= frames ? 1 : -1;
  return p->result;
}

/* v with two significant digits, "6.2e8" (below 100 as is) */
static void print_e(uint64_t v) {
  uint32_t e = 1;
  if (v < 100u) {
    bow_printf("%u", (uint32_t)v);
    return;
  }
  for (; v >= 100u; e++) v /= 10u;
  bow_printf("%u.%ue%u", (uint32_t)v / 10u, (uint32_t)v % 10u, e);
}

/* Bit error rate bound after 0 errors in n bits at 95 % confidence:
 * -ln(0.05) / n = 2.996 / n, rounded up, "4.9e-9". */
static void print_ber(uint64_t n) {
  uint64_t num = 2996u, q; /* bound = num / n x 10^e */
  int32_t e = -3;
  if (n == 0) {
    bow_puts("-");
    return;
  }
  while ((q = (num + n - 1u) / n) < 10u) {
    num *= 10u;
    e--;
  }
  for (; q >= 100u; e++) q = (q + 9u) / 10u;
  bow_printf("%u.%ue%d", (uint32_t)q / 10u, (uint32_t)q % 10u, (int)(e + 1));
}

/* lane CSI2RX_MAX_LANES: centre point (nw taps) */
static void print_point(uint32_t lane, int32_t dk, uint32_t nw, const bow_csi2rx_mpoint_t *p) {
  if (lane >= CSI2RX_MAX_LANES) {
    bow_puts("margin centre taps ");
    put_list(p->tap, nw);
    bow_printf(": %u frames, %u errors, ", p->frames, p->errors);
  } else {
    bow_printf("margin lane%u %c%u tap %u: %u frames, %u errors, ", lane, dk < 0 ? '-' : '+',
               (uint32_t)(dk < 0 ? -dk : dk), p->tap[lane], p->frames, p->errors);
  }
  print_e(p->bits);
  bow_printf(" bits (%u lines)", p->lines);
  if (p->errors == 0 && p->bits != 0) {
    bow_puts(", BER < ");
    print_ber(p->bits);
  }
  if (p->err & ~CSI2RX_ERR_TAP) bow_printf(" (ERR_STATUS %03x)", p->err);
  bow_puts("\n");
}

int bow_csi2rx_margin(const bow_csi2rx_cal_t *cal, uint32_t k, uint32_t frames,
                      uint32_t tap_timeout_ms, bow_csi2rx_margin_t *m, bool verbose) {
  uint32_t nl = bow_csi2rx_lanes(), nw = margin_nw(nl);
  uint32_t taps[CSI2RX_MAX_LANES];
  int result = 1, r;

  if (frames == 0) frames = 1;
  for (uint32_t l = 0; l < CSI2RX_MAX_LANES; l++) {
    uint32_t a = cal->width[l] / 4u;
    m->k[l] = l >= nl ? 0u : k ? k : a > CSI2RX_MARGIN_MIN ? a : CSI2RX_MARGIN_MIN;
    for (uint32_t s = 0; s < 2; s++) {
      m->side[l][s] = (bow_csi2rx_mpoint_t){{0}, 0, 0, 0, 0, 0, -1};
    }
  }

  /* Centre (the taps of the calibration), then each side of each lane, back
   * to back: the next taps are written at once after a point (printing would
   * move the change into the frame); a clean point has just seen a frame end. */
  r = margin_point(cal->tap, nw, nl, false, frames, tap_timeout_ms, &m->centre);
  if (r == 0) result = 0;
  for (uint32_t l = 0; r >= 0 && l < nl; l++) {
    for (uint32_t s = 0; r >= 0 && s < 2; s++) {
      uint32_t c = cal->tap[l], t;
      if (s == 0) {
        t = c > m->k[l] ? c - m->k[l] : 0u;
      } else {
        t = c + m->k[l] > DPHY_DLY_MAX ? DPHY_DLY_MAX : c + m->k[l];
      }
      for (uint32_t i = 0; i < CSI2RX_MAX_LANES; i++) taps[i] = cal->tap[i];
      taps[l] = t;
      r = margin_point(taps, nw, nl, r == 1, frames, tap_timeout_ms, &m->side[l][s]);
      if (r == 0) result = 0;
    }
  }
  if (r < 0 && result != 0) result = -1; /* errors found before stay the result */

  /* back to the calibrated taps; the frame in progress ends (it may have
   * lost its frame start at the last point: then the next one), clean
   * counters */
  cal_set(cal->tap, nw);
  if (bow_dphy_rx_wait_delay(tap_timeout_ms)) bow_csi2rx_wait_frame(2u * tap_timeout_ms);
  bow_csi2rx_clear();

  if (verbose) {
    if (m->centre.result >= 0) print_point(CSI2RX_MAX_LANES, 0, nw, &m->centre);
    for (uint32_t l = 0; l < nl; l++) {
      for (uint32_t s = 0; s < 2; s++) {
        const bow_csi2rx_mpoint_t *p = &m->side[l][s];
        if (p->result >= 0) print_point(l, (int32_t)p->tap[l] - (int32_t)cal->tap[l], nw, p);
      }
    }
    if (r < 0) {
      bow_puts("margin: a point was not measured: no byte clock, or no frame start or end"
               " (is the sensor streaming?)\n");
    }
  }
  return result;
}

void bow_csi2rx_print_margin(const bow_csi2rx_margin_t *m, int result) {
  uint64_t bits = m->centre.bits;
  uint32_t n = 1, nk = 1;
  if (result < 0) {
    bow_puts("not measured");
    return;
  }
  while (nk < CSI2RX_MAX_LANES && m->k[nk]) nk++;
  bow_printf("+-%u", m->k[0]);
  for (uint32_t l = 1; l < nk; l++) bow_printf("/+-%u", m->k[l]);
  bow_puts(" taps: ");
  if (m->centre.errors) {
    bow_printf("%u errors at the taps in use ", m->centre.errors);
    put_list(m->centre.tap, nk < 2u ? 2u : nk);
    return;
  }
  for (uint32_t l = 0; l < nk; l++) {
    for (uint32_t s = 0; s < 2; s++) {
      const bow_csi2rx_mpoint_t *p = &m->side[l][s];
      if (p->errors) {
        bow_printf("lane %u %c%u (tap %u): %u errors after ", l, s ? '+' : '-', m->k[l],
                   p->tap[l], p->errors);
        print_e(p->bits);
        bow_puts(" bits");
        return;
      }
      if (p->bits < bits) bits = p->bits;
      n++;
    }
  }
  bow_printf("0 errors in %u x %u frames, BER < ", n, m->centre.frames);
  print_ber(bits);
}

/* -------------------------------------------------------------------- log */
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

/* ----------------------------------------------------------------- status */
/* "HS" or the LP state "11" of a lane: hs = its HS receiver is on */
static const char *lp_state(bool hs, uint32_t lp) {
  static const char *const names[4] = {"00", "01", "10", "11"};
  return hs ? "HS" : names[lp & 3u];
}

void bow_csi2rx_print_status(void) {
  /* snapshot first: printing takes longer than a frame at low baud rates */
  bow_csi2rx_cnt_t c;
  bow_csi2rx_counters(&c);
  uint32_t err = bow_csi2rx_link_errors(&c), clk = bow_clk_hz();
  uint32_t fi = CSI2RX->FRAME_INFO, li = CSI2RX->LINE_INFO;
  uint32_t ferr = CSI2RX->FRAME_ERR;
  uint32_t sum = CSI2RX->FRAME_SUM, ft = CSI2RX->FRAME_TIME, lt = CSI2RX->LINE_TIME;
  uint32_t lp, hs, n = list_lanes(), d[DPHY_MAX_LANES];
  bow_dphy_rx_cnt_t pc; /* the PHY line: one snapshot of the D-PHY */
  bow_dphy_rx_snapshot(&pc, &lp, &hs);
  bool self_cal = bow_dphy_rx_self_cal();
  bow_dphy_rx_get_delays(d);
  /* BYTECLK covers 65536 CPU cycles: watch it for a whole frame */
  uint32_t byte_hz = bow_dphy_rx_byteclk_hz(ft ? muldiv(ft, 1000u, clk) + 2u : 0u);

  if (c.packets == 0) {
    bow_puts("csi2rx: no data\n");
  } else if (c.frames > 0 && err == 0 && c.lines == 0) {
    /* frames without an accepted line: CTRL.DT/VC do not match the stream */
    bow_puts("csi2rx: no lines (DT/VC filter?)\n");
  } else if (c.frames > 0 && err == 0) {
    bow_puts("csi2rx: link ok\n");
  } else {
    bow_puts("csi2rx: link errors\n");
  }
  bow_printf("  frames %u lines/frame %u wc %u dt %02x sum %08x frame errors %03x\n", c.frames,
             CSI2RX_FRAME_LINES(fi), CSI2RX_LINE_WC(li), CSI2RX_LINE_DT(li), sum, ferr);
  bow_puts("  errors: ");
  bow_csi2rx_print_errors(&c);
  bow_printf(" (dropped by DT/VC %u)\n", c.drop);
  if (c.extra) bow_puts("  no LP-11 between packets? (bytes after packets: dropped)\n");
  if (c.deskew) bow_printf("  deskew bursts %u\n", c.deskew);
  bow_printf("  timing: frame %u us, line %u ns, byte clock %u kHz\n", muldiv(ft, 1000000u, clk),
             muldiv(lt, 1000000000u, clk), byte_hz / 1000u);
  bow_printf("  phy: lp clk %s", lp_state(hs & DPHY_LANE_HS_CLK, DPHY_LANE_LP_CLK(lp)));
  for (uint32_t l = 0; l < n; l++) {
    bow_printf(" d%u %s", l, lp_state(hs & DPHY_LANE_HS(l), DPHY_LANE_LP(lp, l)));
  }
  bow_puts(", bursts ");
  put_list(pc.burst, n);
  bow_printf(" clk %u, delay ", pc.clk_burst);
  put_list(d, n);
  /* only a self-calibrating PHY (Versal XPHY) has a ready state */
  if (self_cal && !bow_dphy_rx_ready()) bow_puts(", PHY not ready");
  bow_puts("\n");
}
