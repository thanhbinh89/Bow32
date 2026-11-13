/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The checks of `test [quick]`, in this order (each one starts from what the
 * previous ones left: stream running, taps calibrated):
 *   phy-idle   sensor in standby, PHY on: every lane in LP-11, no HS
 *   link-up    stream on: HS bursts on every data lane and the clock lane
 *   calibrate  eye found on every lane, then a clean link check
 *   margin     PN9 data (IMX274: solid AAAh): no sampling error at the
 *              calibrated taps and at tap - k / tap + k of every lane
 *              (k = eye / 4), `frames per check` frames at each point; the
 *              taps stay where they are
 *   integrity  RAW10 solid colour: lines, word count, pixel sum, FRAME_ERR 0
 *   packets    packet log: FS, embedded data, lines, FE; frame numbers
 *   timing     frame period, line time, byte clock
 *   isp        sensor colour bars through the ISP, checked in a capture
 *   raw8       RAW8 stream (data type 0x2A): word count, pixel sum
 *   filter     virtual channel filter: VC 1 drops every line
 *   restart    3 x stop / start of the stream at random phases
 *   irq        FS interrupts on irq_fast[7]
 * quick: 64x48 frames with the shortest vertical blanking (simulation),
 * timing only checked for consistency. Full: link-up .. timing at 1080p30
 * and again at 720p60, timing against the sensor configuration. integrity,
 * raw8 and restart (check_frames) also need FRAME_ERR = 0 in every frame
 * they read; margin counts only sampling errors; the other checks do not
 * look at FRAME_ERR.
 *
 * With the IMX274 (4 lanes, test patterns of fixed undocumented values):
 *   phy-idle   every lane LP-00 (standby, datasheet) or every lane LP-11
 *   integrity  solid 555h, then solid AAAh (every bit toggles): the first
 *              two frames with the same pixel sum give the reference, the
 *              next frames must match it; the two sums must differ
 *   packets    also embedded data (0x12) and optical black lines (0x37);
 *              quick: exactly FS, 1 embedded line, the OB lines of the mode,
 *              H lines, FE in one frame
 *   timing     frame HMAX x VMAX / 72 MHz, line 2 HMAX / 72 MHz, byte clock
 *              180 MHz (at most 180 MHz if the clock lane leaves HS after
 *              every packet: the meter reads such short bursts low)
 *   isp        colour bars (tp 11): the same capture in two frames, several
 *              colours along the middle row (printed: the layout is measured
 *              on the board); solid 555h: grey
 *   raw8       not run (no RAW8 output)
 */
#include <stdarg.h>

#include "csi2_test.h"

typedef struct {
  bool quick;
  uint32_t step;    /* calibration step (taps) */
  uint32_t frames;  /* frames per check */
  uint32_t tap_ms;  /* time for one calibration tap */
  uint32_t wait_ms; /* time for one frame end */
} suite_t;

/* Solid test colours R, Gr, B, Gb: RAW10 with non-zero LSBs, RAW8 with two
 * zero LSBs (the sensor drops them). */
static const uint32_t colour10[4] = {0x135, 0x2CA, 0x0F3, 0x2CA};
static const uint32_t colour8[4] = {0x100, 0x200, 0x300, 0x200};

/* Camera app ISP setup: the colour matrix of the sensor table */
static const int16_t zero3[3] = {0, 0, 0};

static uint32_t log_e[CSI2RX_LOG_ENTRIES];
static const char *check_name;
static uint32_t rnd_state;
static uint32_t ref_sum; /* IMX274: FRAME_SUM of the test pattern ct.tp (integrity) */

/* ------------------------------------------------------------------ helpers */
static bool pass(const char *fmt, ...) {
  va_list ap;
  bow_printf("[PASS] %s ", check_name);
  va_start(ap, fmt);
  bow_vprintf(fmt, ap);
  va_end(ap);
  bow_puts("\n");
  return true;
}

static bool fail(const char *fmt, ...) {
  va_list ap;
  bow_printf("[FAIL] %s: ", check_name);
  va_start(ap, fmt);
  bow_vprintf(fmt, ap);
  va_end(ap);
  bow_puts("\n");
  return false;
}

static bool expired(uint32_t start, uint32_t ms) {
  return (uint32_t)(bow_cycles() - start) > ms * (bow_clk_hz() / 1000u);
}

static uint32_t muldiv(uint32_t a, uint32_t b, uint32_t c) {
  return c ? (uint32_t)((uint64_t)a * b / c) : 0;
}

/* |v - ref| <= pct % of ref */
static bool within(uint32_t v, uint32_t ref, uint32_t pct) {
  uint32_t d = v > ref ? v - ref : ref - v;
  return (uint64_t)d * 100u <= (uint64_t)ref * pct;
}

static uint32_t rnd(void) {
  rnd_state = rnd_state * 1664525u + 1013904223u;
  return rnd_state >> 8;
}

/* FRAME_SUM of a solid colour frame: every 2x2 block holds R, Gr, Gb, B
 * (RAW8: the receiver makes the 10 bit value byte << 2). */
static uint32_t solid_sum(const uint32_t c[4], bool raw8) {
  uint32_t s = raw8 ? 4u * ((c[0] >> 2) + (c[1] >> 2) + (c[2] >> 2) + (c[3] >> 2))
                    : c[0] + c[1] + c[2] + c[3];
  return (ct.w / 2u) * (ct.h / 2u) * s;
}

/* "[FAIL] <check>: <fmt ...>: ecc 0/0 crc 0 ... extra 0 (ERR_STATUS 040)" */
static bool fail_errors(const char *fmt, ...) {
  va_list ap;
  bow_csi2rx_cnt_t c;
  uint32_t err = CSI2RX->ERR_STATUS;
  bow_csi2rx_counters(&c);
  bow_printf("[FAIL] %s: ", check_name);
  va_start(ap, fmt);
  bow_vprintf(fmt, ap);
  va_end(ap);
  bow_puts(": ");
  bow_csi2rx_print_errors(&c);
  bow_printf(" (ERR_STATUS %03x)\n", err);
  if (err & CSI2RX_ERR_EXTRA) bow_puts("  no LP-11 between packets: a calibration does not help\n");
  return false;
}

static bool fail_link(uint32_t frame) { return fail_errors("frame %u: link errors", frame); }

/* Skip the frame in progress (FE within first_ms), clear the counters, then
 * n frames read at their FE: H lines, line word count and data type, pixel
 * sum, no link error. */
static bool check_frames(const suite_t *s, uint32_t first_ms, uint32_t n, uint32_t dt, uint32_t wc,
                         uint32_t sum) {
  bow_csi2rx_cnt_t c;
  if (!bow_csi2rx_wait_frame(first_ms)) return fail("no frame end");
  bow_csi2rx_clear();
  for (uint32_t i = 0; i < n; i++) {
    if (!bow_csi2rx_wait_frame(s->wait_ms)) return fail("frame %u: no frame end", i);
    uint32_t fi = CSI2RX->FRAME_INFO, li = CSI2RX->LINE_INFO, fs = CSI2RX->FRAME_SUM;
    if (CSI2RX_FRAME_LINES(fi) != ct.h) {
      return fail("frame %u: %u lines, expected %u", i, CSI2RX_FRAME_LINES(fi), ct.h);
    }
    if (CSI2RX_LINE_WC(li) != wc || CSI2RX_LINE_DT(li) != dt) {
      return fail("frame %u: line wc %u dt %02x, expected wc %u dt %02x", i, CSI2RX_LINE_WC(li),
                  CSI2RX_LINE_DT(li), wc, dt);
    }
    if (fs != sum) return fail("frame %u: pixel sum %08x, expected %08x", i, fs, sum);
    uint32_t fe = CSI2RX->FRAME_ERR;
    if (fe) return fail("frame %u: FRAME_ERR %03x", i, fe);
    bow_csi2rx_counters(&c);
    if (bow_csi2rx_link_errors(&c)) return fail_link(i);
  }
  return true;
}

/* ------------------------------------------------------------------ checks */
/* Clock lane and every data lane of the stream in LP state lp, no HS, byte
 * clock gate closed (the D-PHY's LANE_LP and LANE_HS). */
static bool idle(uint32_t lpst, uint32_t hs, uint32_t lp) {
  if (DPHY_LANE_LP_CLK(lpst) != lp) return false;
  for (uint32_t l = 0; l < stream_lanes(); l++) {
    if (DPHY_LANE_LP(lpst, l) != lp) return false;
  }
  return !(hs & (DPHY_LANE_HS_CLK | DPHY_LANE_HS_DATA | DPHY_LANE_HS_GATE));
}

static bool check_phy_idle(const suite_t *s) {
  bow_csi2rx_cnt_t c;
  uint32_t start, lpst, hs, lp = 3u, bursts, n = stream_lanes();
  bool i274 = sensor_imx274();
  if (ct.streaming) stream_stop();
  int rs = cam_rx_start(ct.s, CSI2_DT_RAW10);
  if (rs != CSI2RX_OK) return fail("%s", bow_csi2rx_strerror(rs));
  /* the sensor may still finish a frame (probe or last stop); in standby the
   * IMX219 lanes are LP-11, the IMX274 ones LP-00 (datasheet; LP-11 of every
   * lane is accepted too) */
  start = bow_cycles();
  for (;;) {
    lpst = DPHY->LANE_LP;
    hs = DPHY->LANE_HS;
    if (i274) lp = DPHY_LANE_LP_CLK(lpst) == 0u ? 0u : 3u;
    if (idle(lpst, hs, lp)) break;
    if (expired(start, s->wait_ms)) {
      if (i274) {
        return fail("LANE_LP %03x LANE_HS %05x: lanes not all in LP-00 or LP-11, or HS on", lpst,
                    hs);
      }
      return fail("LANE_LP %03x LANE_HS %05x: lanes not in LP-11 or HS on", lpst, hs);
    }
  }
  bow_csi2rx_clear();
  bow_delay_ms(s->quick ? 1u : 20u);
  lpst = DPHY->LANE_LP;
  hs = DPHY->LANE_HS;
  bow_csi2rx_counters(&c);
  bursts = c.clk_burst;
  for (uint32_t l = 0; l < n; l++) bursts += c.burst[l];
  if (!idle(lpst, hs, lp) || bursts) {
    if (n > 2) {
      return fail("HS while the sensor is in standby: LANE_LP %03x LANE_HS %05x, "
                  "bursts %u/%u/%u/%u clk %u", lpst, hs, c.burst[0], c.burst[1], c.burst[2],
                  c.burst[3], c.clk_burst);
    }
    return fail("HS while the sensor is in standby: LANE_LP %03x LANE_HS %05x, bursts %u/%u clk %u",
                lpst, hs, c.burst[0], c.burst[1], c.clk_burst);
  }
  if (i274) {
    return pass("all lanes LP-%s, no HS (LANE_LP %03x LANE_HS %05x)", lp ? "11" : "00 (standby)",
                lpst, hs);
  }
  return pass("all lanes LP-11, no HS (LANE_LP %03x LANE_HS %05x)", lpst, hs);
}

static bool check_link_up(const suite_t *s) {
  bow_csi2rx_cnt_t a, b;
  uint32_t n = stream_lanes();
  ct.tp = ct.s->tp_solid;
  for (int i = 0; i < 4; i++) ct.colour[i] = colour10[i];
  if ((ct.s->has_raw8 && imx219_format() != 10 && imx219_set_format(10) != I2C_OK) ||
      !stream_start(true)) {
    return fail("sensor does not start");
  }
  /* first burst after the sensor start-up, then every counter grows */
  uint32_t start = bow_cycles();
  do {
    bow_csi2rx_counters(&a);
    if (expired(start, 4u * s->wait_ms)) {
      return fail("no HS burst: bursts %u/%u clk %u", a.burst[0], a.burst[1], a.clk_burst);
    }
  } while (a.burst[0] == 0);
  start = bow_cycles();
  for (;;) {
    bow_csi2rx_counters(&b);
    /* continuous clock: one HS entry only, the gate stays open */
    bool clk = b.clk_burst > a.clk_burst || (DPHY->LANE_HS & DPHY_LANE_HS_GATE);
    bool all = true;
    for (uint32_t l = 0; l < n; l++) all = all && b.burst[l] > a.burst[l];
    if (all && clk) break;
    if (expired(start, s->wait_ms)) {
      if (n > 2) {
        return fail("bursts %u/%u/%u/%u clk %u, then %u/%u/%u/%u clk %u", a.burst[0], a.burst[1],
                    a.burst[2], a.burst[3], a.clk_burst, b.burst[0], b.burst[1], b.burst[2],
                    b.burst[3], b.clk_burst);
      }
      return fail("bursts %u/%u clk %u, then %u/%u clk %u", a.burst[0], a.burst[1], a.clk_burst,
                  b.burst[0], b.burst[1], b.clk_burst);
    }
  }
  if (n > 2) {
    return pass("bursts %u/%u/%u/%u, clock lane %u", b.burst[0], b.burst[1], b.burst[2],
                b.burst[3], b.clk_burst);
  }
  return pass("bursts %u/%u, clock lane %u", b.burst[0], b.burst[1], b.clk_burst);
}

static bool check_calibrate(const suite_t *s) {
  bow_csi2rx_cal_t cal;
  uint32_t n = stream_lanes();
  bool ok = bow_csi2rx_calibrate(s->step, s->tap_ms, &cal, true);
  for (uint32_t l = 0; l < n; l++) ok = ok && cal.width[l] != 0;
  if (!ok) {
    bow_printf("[FAIL] %s: no eye: ", check_name);
    bow_csi2rx_print_cal(&cal);
    bow_puts("\n");
    return false;
  }
  for (uint32_t l = 0; l < n; l++) {
    uint32_t d = bow_dphy_rx_read_delay(l);
    if (DPHY_DLY_CODE(d) != cal.tap[l] || DPHY_DLY_Q(d) != cal.tap[l] || !(d & DPHY_DLY_OWN) ||
        (d & DPHY_DLY_PEND)) {
      return fail("lane %u: DLY %08x, expected tap %u", l, d, cal.tap[l]);
    }
  }
  if (!bow_csi2rx_link_check(64, 4u * s->tap_ms)) {
    if (cal.lanes > 2u) {
      return fail_errors("link check with taps %u/%u/%u/%u", cal.tap[0], cal.tap[1], cal.tap[2],
                         cal.tap[3]);
    }
    return fail_errors("link check with taps %u/%u", cal.tap[0], cal.tap[1]);
  }
  ct.cal = cal;
  ct.calibrated = true;
  bow_printf("[PASS] %s ", check_name);
  bow_csi2rx_print_cal(&cal);
  bow_puts("\n");
  return true;
}

/* IMX274: up to 6 frames until two consecutive ones have the same pixel sum
 * (a test pattern change is frame latched). */
static bool settle_sum(const suite_t *s, uint32_t *sum) {
  uint32_t prev = 0;
  for (uint32_t i = 0; i < 6; i++) {
    if (!bow_csi2rx_wait_frame(s->wait_ms)) return fail("no frame end");
    uint32_t v = CSI2RX->FRAME_SUM;
    if (i && v == prev) {
      *sum = v;
      return true;
    }
    prev = v;
  }
  return fail("pixel sum does not settle (last %08x)", prev);
}

/* IMX274: solid 555h and AAAh, reference sums measured (see the top) */
static bool integrity_274(const suite_t *s, uint32_t wc) {
  static const uint32_t tps[2] = {IMX274_TP_ALL_555, IMX274_TP_ALL_AAA};
  uint32_t sum[2], px = ct.w * ct.h;
  for (uint32_t i = 0; i < 2; i++) {
    if (ct.s->set_test_pattern(tps[i]) != I2C_OK) return fail("I2C error");
    ct.tp = tps[i];
    if (!settle_sum(s, &sum[i])) return false;
    if (!check_frames(s, s->wait_ms, s->frames, CSI2_DT_RAW10, wc, sum[i])) return false;
  }
  if (sum[0] == sum[1]) return fail("555h and AAAh give the same pixel sum %08x", sum[0]);
  ref_sum = sum[1];
  return pass("2 x %u frames %ux%u RAW10: wc %u, sum %08x (555h, mean %u) %08x (AAAh, mean %u)",
              s->frames, ct.w, ct.h, wc, sum[0], sum[0] / px, sum[1], sum[1] / px);
}

/* Random data during the margin check (IMX219: PN9; the IMX274 has no
 * random pattern: solid AAAh, every bit toggles), then the solid colour of
 * the checks again; the sensor takes a test pattern at a frame start. */
static bool test_pattern(const suite_t *s, uint32_t tp) {
  if (ct.s->set_test_pattern(tp) != I2C_OK) return false;
  return bow_csi2rx_wait_frame(s->wait_ms) && bow_csi2rx_wait_frame(s->wait_ms);
}

static bool check_margin(const suite_t *s) {
  bow_csi2rx_margin_t m;
  bool i274 = sensor_imx274();
  if (!ct.calibrated) return fail("not calibrated");
  if (!test_pattern(s, i274 ? IMX274_TP_ALL_AAA : IMX219_TP_PN9)) {
    return fail("no %s test pattern", i274 ? "AAAh" : "PN9");
  }
  int r = bow_csi2rx_margin(&ct.cal, 0, s->frames, s->tap_ms, &m, true);
  bool back = test_pattern(s, ct.tp);
  bow_csi2rx_clear();
  if (r <= 0) {
    bow_printf("[FAIL] %s: ", check_name);
    bow_csi2rx_print_margin(&m, r);
    bow_puts("\n");
    return false;
  }
  if (!back) return fail("solid colour does not come back");
  bow_printf("[PASS] %s ", check_name);
  bow_csi2rx_print_margin(&m, r);
  bow_puts("\n");
  return true;
}

static bool check_integrity(const suite_t *s) {
  uint32_t wc = ct.w * 5u / 4u, sum = solid_sum(colour10, false);
  if (sensor_imx274()) return integrity_274(s, wc);
  if (!check_frames(s, s->wait_ms, s->frames, CSI2_DT_RAW10, wc, sum)) return false;
  return pass("%u frames %ux%u RAW10: wc %u, sum %08x", s->frames, ct.w, ct.h, wc, sum);
}

/* Log entry of the RAW10 test stream: NULL, or what is wrong with it.
 * LS/LE are allowed (counted in *lsle; the IMX219 does not send them), and
 * the optical black lines of the IMX274 (0x37, dropped by the receiver). */
static const char *entry_error(uint32_t e, uint32_t *lsle) {
  uint32_t dt = CSI2RX_LOG_DT(e);
  if (CSI2RX_LOG_ECC(e) != CSI2RX_ECC_OK) return "header ECC";
  if (e & (CSI2RX_LOG_CRC_ERR | CSI2RX_LOG_TRUNC)) return "CRC error or truncated";
  if (dt == CSI2_DT_LS || dt == CSI2_DT_LE) {
    (*lsle)++;
    return NULL;
  }
  if (dt == CSI2_DT_RAW10) return CSI2RX_LOG_WC(e) == ct.w * 5u / 4u ? NULL : "line word count";
  if (dt == CSI2_DT_OB && sensor_imx274()) return NULL;
  return (dt == CSI2_DT_FS || dt == CSI2_DT_FE || dt == CSI2_DT_EMB) ? NULL : "data type";
}

static bool check_log(const char *what, uint32_t n, uint32_t *lsle) {
  for (uint32_t i = 0; i < n; i++) {
    const char *err = entry_error(log_e[i], lsle);
    if (err) return fail("log %s: entry %u = %08x: %s", what, i, log_e[i], err);
  }
  return true;
}

/* Embedded data and OB packets of a log, up to the first line */
static void count_head(uint32_t n, uint32_t *emb, uint32_t *ob) {
  *emb = *ob = 0;
  for (uint32_t i = 0; i < n && CSI2RX_LOG_DT(log_e[i]) != CSI2_DT_RAW10; i++) {
    *emb += CSI2RX_LOG_DT(log_e[i]) == CSI2_DT_EMB;
    *ob += CSI2RX_LOG_DT(log_e[i]) == CSI2_DT_OB;
  }
}

static bool check_packets(const suite_t *s) {
  uint32_t n, lsle = 0, lines = 0, emb = 0, ob = 0;
  bool i274 = sensor_imx274();

  /* from the next FS */
  n = bow_csi2rx_log(log_e, CSI2RX_LOG_TRIG_FS, 2u * s->wait_ms);
  if (n == 0) return fail("log fs: timeout");
  if (CSI2RX_LOG_DT(log_e[0]) != CSI2_DT_FS) {
    return fail("log fs: entry 0 has data type %02x", CSI2RX_LOG_DT(log_e[0]));
  }
  if (!check_log("fs", n, &lsle)) return false;
  if (i274) count_head(n, &emb, &ob);

  /* up to the next FE: lines, then the FE */
  n = bow_csi2rx_log(log_e, CSI2RX_LOG_STOP_FE, 2u * s->wait_ms);
  if (n == 0) return fail("log fe: timeout");
  if (!check_log("fe", n, &lsle)) return false;
  uint32_t k = n - 1u;
  if (CSI2RX_LOG_DT(log_e[k]) != CSI2_DT_FE) return fail("log fe: no FE in %u entries", n);
  while (k > 0 && (CSI2RX_LOG_DT(log_e[k - 1u]) == CSI2_DT_LS ||
                   CSI2RX_LOG_DT(log_e[k - 1u]) == CSI2_DT_LE)) {
    k--;
  }
  if (k == 0 || CSI2RX_LOG_DT(log_e[k - 1u]) != CSI2_DT_RAW10) {
    return fail("log fe: data type %02x before the FE, expected a line",
                k ? CSI2RX_LOG_DT(log_e[k - 1u]) : 0xFFu);
  }

  /* quick: a whole frame fits in one log from FS to FE */
  if (s->quick) {
    n = bow_csi2rx_log(log_e, CSI2RX_LOG_TRIG_FS | CSI2RX_LOG_STOP_FE, 2u * s->wait_ms);
    if (n == 0) return fail("log fs fe: timeout");
    if (!check_log("fs fe", n, &lsle)) return false;
    for (uint32_t i = 0; i < n; i++) lines += CSI2RX_LOG_DT(log_e[i]) == CSI2_DT_RAW10;
    if (CSI2RX_LOG_DT(log_e[0]) != CSI2_DT_FS || CSI2RX_LOG_DT(log_e[n - 1u]) != CSI2_DT_FE ||
        lines != ct.h) {
      return fail("log fs fe: %u entries with %u lines, expected FS .. %u lines .. FE", n, lines,
                  ct.h);
    }
    /* IMX274: FS, embedded data, OB lines, lines, FE; nothing else */
    if (i274) {
      count_head(n, &emb, &ob);
      if (emb != ct.s->emb_lines || ob != ct.s->ob_lines() || n != 2u + emb + ob + lines) {
        return fail("log fs fe: %u entries: %u embedded, %u OB, %u lines, expected %u, %u, %u",
                    n, emb, ob, lines, ct.s->emb_lines, ct.s->ob_lines(), ct.h);
      }
    }
  }

  /* frame numbers of two consecutive frames: n + 1, or wrapped to 1 */
  if (!bow_csi2rx_wait_frame(s->wait_ms)) return fail("no frame end");
  uint32_t n1 = CSI2RX_FRAME_NUM(CSI2RX->FRAME_INFO);
  if (!bow_csi2rx_wait_frame(s->wait_ms)) return fail("no frame end");
  uint32_t n2 = CSI2RX_FRAME_NUM(CSI2RX->FRAME_INFO);
  bool used = n1 != 0 || n2 != 0;
  if (used && n2 != ((n1 + 1u) & 0xFFFFu) && n2 != 1u) {
    return fail("frame numbers %u then %u", n1, n2);
  }

  bow_printf("[PASS] %s FS, embedded data", check_name);
  if (i274) bow_printf(" (%u), OB lines (%u)", emb, ob);
  bow_puts(", lines, FE: headers and CRC ok");
  if (s->quick) bow_printf(", %u lines in one frame", lines);
  if (lsle) bow_printf(" (info: %u LS/LE packets)", lsle);
  if (used) {
    bow_printf("; frame numbers %u, %u\n", n1, n2);
  } else {
    bow_puts("; frame numbers not used\n");
  }
  return true;
}

static bool check_timing(const suite_t *s) {
  uint32_t clk = bow_clk_hz();
  bool gated = false;
  if (!bow_csi2rx_wait_frame(s->wait_ms)) return fail("no frame end");
  uint32_t ft = CSI2RX->FRAME_TIME, lt = CSI2RX->LINE_TIME;
  if (!s->quick) bow_csi2rx_clear(); /* clock lane HS entries during the measurement */
  uint32_t byte_hz = bow_dphy_rx_byteclk_hz(s->quick ? 0u : 100u);
  uint32_t f_us = muldiv(ft, 1000000u, clk), l_ns = muldiv(lt, 1000000000u, clk);
  if (s->quick) {
    if (lt == 0 || ft <= ct.h * lt) {
      return fail("frame %u cycles, line %u cycles: not more than %u lines", ft, lt, ct.h);
    }
    if (byte_hz == 0) return fail("no byte clock measured");
  } else {
    /* IMX219: FLL x 3448 / 182.4 MHz, line 3448; IMX274: HMAX x VMAX /
     * 72 MHz, line 2 x HMAX */
    bow_csi2rx_cnt_t c;
    uint32_t hz = ct.s->timing_hz, rate = cam_lane_rate(ct.s);
    uint32_t f_ref = (uint32_t)((uint64_t)ct.s->frame_clks() * clk / hz);
    uint32_t l_ref = (uint32_t)((uint64_t)ct.s->line_clks() * clk / hz);
    if (!within(ft, f_ref, 2)) {
      return fail("frame period %u us, expected %u us +-2 %%", f_us, muldiv(f_ref, 1000000u, clk));
    }
    if (!within(lt, l_ref, 2)) {
      return fail("line time %u ns, expected %u ns +-2 %%", l_ns, muldiv(l_ref, 1000000000u, clk));
    }
    /* BYTECLK only measures bursts longer than ~2 x 256 CPU cycles. A clock
     * lane that leaves HS after every packet (more than 2 HS entries per
     * frame; the IMX274 may do so) gives shorter bursts: the meter reads low
     * and only bounds the byte clock from below. */
    bow_csi2rx_counters(&c);
    gated = c.clk_burst > 2u * c.frames + 2u;
    if (gated ? byte_hz == 0 || byte_hz > rate / 800u * 103u : !within(byte_hz, rate / 8u, 3)) {
      return fail("byte clock %u kHz, expected %u kHz +-3 %%%s", byte_hz / 1000u, rate / 8000u,
                  gated ? " (or less: clock lane gated per packet)" : "");
    }
  }
  return pass("frame %u us, line %u ns, byte clock %u kHz%s", f_us, l_ns, byte_hz / 1000u,
              gated ? " (lower bound: clock lane gated per packet)" : "");
}

static bool bar_level(uint32_t v, bool on) { return on ? v > 160u : v < 80u; }

static uint32_t absdiff(uint32_t a, uint32_t b) { return a > b ? a - b : b - a; }

/* Colour of the capture in the middle row at k / 8 of the width + 1/16 */
static uint32_t bar_rgb(uint32_t cw, uint32_t ch, uint32_t k) {
  return ISP_BUF[(ch / 2u) * cw + k * cw / 8u + cw / 16u] & 0xFFFFFFu;
}

static uint32_t capture_hash(uint32_t n) {
  uint32_t h = 0;
  for (uint32_t i = 0; i < n; i++) h = h * 31u + ISP_BUF[i];
  return h;
}

/* IMX274 (layout and values of the patterns not documented): the colour
 * bars give the same capture twice and at least 3 colours in the middle row
 * (printed, so the layout can be written down); solid 555h comes out grey
 * (white balance 1.0, the rows of the colour matrix sum to 1.0). */
static bool isp_274(const suite_t *s, uint32_t cw, uint32_t ch, uint32_t sc) {
  uint32_t c[8], h0, h1, ncol = 0;
  h0 = capture_hash(cw * ch);
  for (uint32_t k = 0; k < 8; k++) c[k] = bar_rgb(cw, ch, k);
  if (!bow_isp_capture(0, 0, cw, ch, sc, 4u * s->wait_ms)) return fail("no second ISP capture");
  h1 = capture_hash(cw * ch);
  if (h0 != h1) return fail("colour bars: two captures differ");
  for (uint32_t k = 0; k < 8; k++) {
    bool fresh = true;
    for (uint32_t j = 0; j < k && fresh; j++) {
      uint32_t d = absdiff(c[k] >> 16, c[j] >> 16) + absdiff((c[k] >> 8) & 0xFFu, (c[j] >> 8) & 0xFFu) +
                   absdiff(c[k] & 0xFFu, c[j] & 0xFFu);
      fresh = d > 48u;
    }
    ncol += fresh;
  }
  if (ncol < 3) {
    return fail("colour bars: %u colours: %06x %06x %06x %06x %06x %06x %06x %06x", ncol, c[0],
                c[1], c[2], c[3], c[4], c[5], c[6], c[7]);
  }
  /* solid 555h from the next frame on */
  if (ct.s->set_test_pattern(IMX274_TP_ALL_555) != I2C_OK) return fail("I2C error");
  for (uint32_t i = 0; i < 3; i++) {
    if (!bow_csi2rx_wait_frame(s->wait_ms)) return fail("no frame end");
  }
  if (!bow_isp_capture(0, 0, cw, ch, sc, 4u * s->wait_ms)) return fail("no ISP capture of 555h");
  uint32_t grey = bar_rgb(cw, ch, 0);
  for (uint32_t k = 0; k < 8; k++) {
    uint32_t v = bar_rgb(cw, ch, k), r = v >> 16, g = (v >> 8) & 0xFFu, b = v & 0xFFu;
    if (absdiff(r, g) > 8u || absdiff(b, g) > 8u || absdiff(g, (grey >> 8) & 0xFFu) > 8u) {
      return fail("solid 555h: RGB %u %u %u at bar %u, expected grey", r, g, b, k);
    }
  }
  return pass("colour bars %06x %06x %06x %06x %06x %06x %06x %06x (%u colours), 555h grey %u, "
              "capture %ux%u (scale %u)",
              c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], ncol, (grey >> 8) & 0xFFu, cw, ch,
              sc);
}

static bool check_isp(const suite_t *s) {
  uint32_t bufwords = (ISP->INFO >> 16) * 1024u, sc = 0;
  bool ok = false;
  while (sc < 3 && (ct.w >> sc) * (ct.h >> sc) > bufwords) sc++;
  uint32_t cw = ct.w >> sc, ch = ct.h >> sc;
  if (ct.w > (ISP->INFO & 0xFFFFu) || cw * ch > bufwords) {
    return fail("%ux%u does not fit the ISP", ct.w, ct.h);
  }
  if (ct.s->set_test_pattern(ct.s->tp_bars) != I2C_OK) return fail("I2C error");
  bow_isp_init(ct.w, ct.h, ISP_BAYER_RGGB);
  if (ct.s->black_level != ISP->BLC) ISP->BLC = ct.s->black_level; /* init: 64 */
  bow_isp_set_ccm(ct.s->ccm, zero3);
  if (!bow_isp_update(100)) {
    fail("the ISP does not take its configuration");
    goto out;
  }
  ISP->STATUS = 0xFF;
  ISP->CTRL = ISP_CTRL_EN;
  /* bars from the next frame on, then a capture of a complete frame */
  if (!bow_csi2rx_wait_frame(s->wait_ms) || !bow_csi2rx_wait_frame(s->wait_ms)) {
    fail("no frame end");
    goto out;
  }
  if (!bow_isp_capture(0, 0, cw, ch, sc, 4u * s->wait_ms)) {
    uint32_t st = ISP->STATUS;
    fail("no ISP capture (ISP STATUS %02x)", st);
    goto out;
  }
  if (sensor_imx274()) {
    ok = isp_274(s, cw, ch, sc);
    goto out;
  }
  /* white yellow cyan green magenta red blue black: centre of every bar */
  for (uint32_t k = 0; k < 8; k++) {
    uint32_t v = ISP_BUF[(ch / 2u) * cw + k * cw / 8u + cw / 16u];
    uint32_t r = (v >> 16) & 0xFFu, g = (v >> 8) & 0xFFu, b = v & 0xFFu;
    bool er = k == 0 || k == 1 || k == 4 || k == 5, eg = k < 4, eb = (k & 1u) == 0;
    if (!bar_level(r, er) || !bar_level(g, eg) || !bar_level(b, eb)) {
      fail("bar %u: RGB %u %u %u", k, r, g, b);
      goto out;
    }
  }
  ok = pass("8 colour bars ok, capture %ux%u (scale %u)", cw, ch, sc);
out:
  ISP->CTRL = 0;
  ct.s->set_test_pattern(ct.tp);
  return ok;
}

/* After a format switch (stream restart): until a line of the new data type
 * was accepted, at most 3 frames. */
static bool wait_line_dt(uint32_t dt, uint32_t timeout_ms) {
  for (uint32_t i = 0; i < 3 && CSI2RX_LINE_DT(CSI2RX->LINE_INFO) != dt; i++) {
    if (!bow_csi2rx_wait_frame(timeout_ms)) return false;
  }
  return CSI2RX_LINE_DT(CSI2RX->LINE_INFO) == dt;
}

static bool check_raw8(const suite_t *s) {
  uint32_t sum = solid_sum(colour8, true);
  bool ok = false;
  if (set_colour(colour8) != I2C_OK || !set_format(8)) {
    fail("switch to RAW8 failed");
  } else if (!wait_line_dt(CSI2_DT_RAW8, 2u * s->wait_ms)) {
    fail("no RAW8 line after the switch");
  } else {
    ok = check_frames(s, s->wait_ms, s->frames, CSI2_DT_RAW8, ct.w, sum);
  }
  /* back to RAW10 */
  bool back = set_format(10) && set_colour(colour10) == I2C_OK &&
              wait_line_dt(CSI2_DT_RAW10, 2u * s->wait_ms);
  uint32_t li = CSI2RX->LINE_INFO;
  if (ok && (!back || CSI2RX_LINE_WC(li) != ct.w * 5u / 4u)) {
    return fail("RAW10 does not come back (line wc %u dt %02x)", CSI2RX_LINE_WC(li),
                CSI2RX_LINE_DT(li));
  }
  if (!ok) return false;
  return pass("%u frames RAW8: wc %u, sum %08x; back to RAW10", s->frames, ct.w, sum);
}

/* VC of the receiver (CTRL.VC changes only while RX_EN = 0) */
static void set_vc(uint32_t vc) {
  bow_csi2rx_set_rx(false);
  CSI2RX->CTRL = (CSI2RX->CTRL & ~CSI2RX_CTRL_VC_MASK) | CSI2RX_CTRL_VC(vc);
  bow_csi2rx_set_rx(true);
}

static bool check_filter(const suite_t *s) {
  bow_csi2rx_cnt_t c;
  uint32_t period = CSI2RX->FRAME_TIME, nf = s->frames;
  /* long packets per frame: lines, embedded data, OB lines */
  uint32_t per = ct.h + ct.s->emb_lines + ct.s->ob_lines();
  if (period == 0) return fail("no frame period measured");
  if (nf * per > 0xFFFFu) nf = 0xFFFFu / per; /* 16 bit drop counter */
  /* VC 1 between two frames: nothing passes, every long packet is dropped;
   * no FE either, so wait nf frame periods (>= nf - 1 whole frames) */
  if (!bow_csi2rx_wait_frame(s->wait_ms)) return fail("no frame end");
  set_vc(1);
  bow_csi2rx_clear();
  bow_delay_cycles(nf * period);
  bow_csi2rx_counters(&c);
  set_vc(0);
  if (c.lines != 0) return fail("%u lines accepted with VC 1", c.lines);
  if (c.drop < (nf - 1u) * ct.h) {
    return fail("%u packets dropped in %u frame periods, expected >= %u", c.drop, nf,
                (nf - 1u) * ct.h);
  }
  /* VC 0 again: the first FE comes with the next complete frame */
  if (!bow_csi2rx_wait_frame(2u * s->wait_ms)) return fail("no frame with VC 0 again");
  uint32_t fi = CSI2RX->FRAME_INFO;
  if (CSI2RX_FRAME_LINES(fi) != ct.h) {
    return fail("VC 0 again: %u lines, expected %u", CSI2RX_FRAME_LINES(fi), ct.h);
  }
  return pass("VC 1: no line, %u packets dropped in %u frame periods; VC 0: frames resume", c.drop,
              nf);
}

static bool check_restart(const suite_t *s) {
  uint32_t period = CSI2RX->FRAME_TIME;
  /* IMX274: the pixel sum of its test pattern measured by `integrity` */
  uint32_t sum = sensor_imx274() ? ref_sum : solid_sum(colour10, false);
  if (period == 0) period = frame_ms() * (bow_clk_hz() / 1000u);
  rnd_state ^= bow_cycles();
  for (uint32_t i = 0; i < 3; i++) {
    bow_delay_cycles(rnd() % period); /* stream off somewhere in the frame */
    stream_stop();
    bow_delay_cycles(rnd() % period); /* and on again after a while */
    if (!stream_start(false)) return fail("restart %u: sensor does not start", i);
    if (!check_frames(s, 4u * s->wait_ms, 2, CSI2_DT_RAW10, ct.w * 5u / 4u, sum)) return false;
  }
  return pass("3 x stop/start at random phases, frames resume without errors");
}

static bool check_irq(const suite_t *s) {
  uint32_t n = count_fs_irqs(s->frames, s->wait_ms), en = CSI2RX->IRQ_EN;
  if (en != 0) return fail("IRQ_EN still %02x", en);
  if (n == 0) return fail("no FS interrupt in %u frames", s->frames);
  return pass("%u FS interrupts in %u frames", n, s->frames);
}

/* ------------------------------------------------------------------ runner */
typedef struct {
  const char *name;
  bool (*fn)(const suite_t *s);
} check_t;

/* checks 2-7 run once per mode */
static const check_t link_checks[] = {
    {"link-up", check_link_up},     {"calibrate", check_calibrate}, {"margin", check_margin},
    {"integrity", check_integrity}, {"packets", check_packets},     {"timing", check_timing},
};
static const check_t stream_checks[] = {
    {"isp", check_isp},         {"raw8", check_raw8}, {"filter", check_filter},
    {"restart", check_restart}, {"irq", check_irq},
};

#define NCHECKS(a) (sizeof(a) / sizeof((a)[0]))

static void run(const check_t *t, uint32_t n, const suite_t *s, uint32_t *passed, uint32_t *total) {
  for (uint32_t i = 0; i < n; i++) {
    if (t[i].fn == check_raw8 && !ct.s->has_raw8) continue; /* IMX274: RAW10 only */
    check_name = t[i].name;
    (*total)++;
    if (t[i].fn(s)) (*passed)++;
  }
}

/* Stream stopped, new frame format, timeouts for it. */
static void suite_mode(suite_t *s, uint32_t w, uint32_t h, uint32_t fps) {
  if (ct.streaming) stream_stop();
  set_mode(w, h, fps);
  s->tap_ms = s->quick ? 5u : tap_timeout_ms();
  s->wait_ms = 3u * s->tap_ms;
  bow_printf("csi2_test: %ux%u, frame %u us, %u frames per check, calibration step %u\n", ct.w,
             ct.h, cam_frame_us(ct.s), s->frames, s->step);
}

bool run_tests(bool quick) {
  static const check_t idle_check = {"phy-idle", check_phy_idle};
  suite_t s = {.quick = quick, .step = quick ? 32u : 8u, .frames = quick ? 4u : 60u};
  uint32_t passed = 0, total = 0;

  if (!ct.sensor || !ct.phy) {
    bow_printf("error: the test needs the %s and a D-PHY (%s build)\n", ct.s->name, ct.s->build);
    return false;
  }
  if (ct.lanes < ct.s->lanes) {
    bow_printf("error: the %s needs %u lanes, the receiver has %u\n", ct.s->name, ct.s->lanes,
               ct.lanes);
    return false;
  }
  if (quick) {
    suite_mode(&s, 64, 48, 0); /* shortest vertical blanking */
    run(&idle_check, 1, &s, &passed, &total);
    run(link_checks, NCHECKS(link_checks), &s, &passed, &total);
  } else {
    suite_mode(&s, 1920, 1080, 30);
    run(&idle_check, 1, &s, &passed, &total);
    run(link_checks, NCHECKS(link_checks), &s, &passed, &total);
    suite_mode(&s, 1280, 720, 60);
    run(link_checks, NCHECKS(link_checks), &s, &passed, &total);
  }
  run(stream_checks, NCHECKS(stream_checks), &s, &passed, &total);

  /* the stream keeps running, counters from zero (e.g. for `stat`) */
  bow_csi2rx_clear();
  bow_printf("csi2_test: %s (%u/%u)\n", passed == total ? "PASS" : "FAIL", passed, total);
  return passed == total;
}
