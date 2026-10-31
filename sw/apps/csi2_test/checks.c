/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * The checks of `test [quick]`, in this order (each one starts from what the
 * previous ones left: stream running, taps calibrated):
 *   phy-idle   sensor in standby, PHY on: every lane in LP-11, no HS
 *   link-up    stream on: HS bursts on every data lane and the clock lane
 *   calibrate  eye found on every lane, then a clean link check
 *   integrity  RAW10 solid colour: lines, word count, pixel sum of frames
 *   packets    packet log: FS, embedded data, lines, FE; frame numbers
 *   timing     frame period, line time, byte clock
 *   isp        sensor colour bars through the ISP, checked in a capture
 *   raw8       RAW8 stream (data type 0x2A): word count, pixel sum
 *   filter     virtual channel filter: VC 1 drops every line
 *   restart    3 x stop / start of the stream at random phases
 *   irq        FS interrupts on irq_fast[7]
 * quick: 64x48 frames with the shortest vertical blanking (simulation),
 * timing only checked for consistency. Full: link-up .. timing at 1080p30
 * and again at 720p60, timing against the sensor configuration.
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

/* Camera app ISP setup: IMX219 colour matrix */
static const int16_t ccm_imx219[9] = {461, -128, -77, -102, 461, -103, -38, -166, 460};
static const int16_t zero3[3] = {0, 0, 0};

static uint32_t log_e[CSI2RX_LOG_ENTRIES];
static const char *check_name;
static uint32_t rnd_state;

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

static bool fail_link(const bow_csi2rx_cnt_t *c, uint32_t frame) {
  return fail("frame %u: link errors: ecc %u/%u crc %u trunc %u sot %u/%u ovf %u misc %u", frame,
              c->ecc_corr, c->ecc_err, c->crc, c->trunc, c->sot[0], c->sot[1], c->ovf, c->misc_err);
}

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
    bow_csi2rx_counters(&c);
    if (bow_csi2rx_link_errors(&c)) return fail_link(&c, i);
  }
  return true;
}

/* ------------------------------------------------------------------ checks */
static bool idle(uint32_t st) {
  bool lp11 = CSI2RX_ST_LP_CLK(st) == 3u && CSI2RX_ST_LP(st, 0) == 3u &&
              (ct.lanes < 2 || CSI2RX_ST_LP(st, 1) == 3u);
  return lp11 && !(st & (CSI2RX_ST_HS_CLK | CSI2RX_ST_HS(0) | CSI2RX_ST_HS(1) | CSI2RX_ST_CE));
}

static bool check_phy_idle(const suite_t *s) {
  bow_csi2rx_cnt_t c;
  uint32_t start, st;
  if (ct.streaming) stream_stop();
  bow_csi2rx_start(2, CSI2_DT_RAW10, IMX219_LANE_RATE);
  /* the sensor may still finish a frame (probe or last stop) */
  start = bow_cycles();
  while (!idle(st = CSI2RX->STATUS)) {
    if (expired(start, s->wait_ms)) return fail("STATUS %04x: lanes not in LP-11 or HS on", st);
  }
  bow_csi2rx_clear();
  bow_delay_ms(s->quick ? 1u : 20u);
  st = CSI2RX->STATUS;
  bow_csi2rx_counters(&c);
  if (!idle(st) || c.burst[0] || c.burst[1] || c.clk_burst) {
    return fail("HS while the sensor is in standby: STATUS %04x, bursts %u/%u clk %u", st,
                c.burst[0], c.burst[1], c.clk_burst);
  }
  return pass("all lanes LP-11, no HS (STATUS %04x)", st);
}

static bool check_link_up(const suite_t *s) {
  bow_csi2rx_cnt_t a, b;
  ct.tp = IMX219_TP_SOLID;
  for (int i = 0; i < 4; i++) ct.colour[i] = colour10[i];
  if ((imx219_format() != 10 && imx219_set_format(10) != I2C_OK) || !stream_start(true)) {
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
    bool clk = b.clk_burst > a.clk_burst || (CSI2RX->STATUS & CSI2RX_ST_CE);
    if (b.burst[0] > a.burst[0] && (ct.lanes < 2 || b.burst[1] > a.burst[1]) && clk) break;
    if (expired(start, s->wait_ms)) {
      return fail("bursts %u/%u clk %u, then %u/%u clk %u", a.burst[0], a.burst[1], a.clk_burst,
                  b.burst[0], b.burst[1], b.clk_burst);
    }
  }
  return pass("bursts %u/%u, clock lane %u", b.burst[0], b.burst[1], b.clk_burst);
}

static bool check_calibrate(const suite_t *s) {
  bow_csi2rx_cal_t cal;
  bool ok = bow_csi2rx_calibrate(s->step, s->tap_ms, &cal, true);
  if (!ok || cal.width[0] == 0 || (ct.lanes > 1 && cal.width[1] == 0)) {
    return fail("no eye: taps %u/%u eye %u/%u", cal.tap[0], cal.tap[1], cal.width[0], cal.width[1]);
  }
  for (uint32_t l = 0; l < ct.lanes; l++) {
    uint32_t d = CSI2RX->DLY[l];
    if (CSI2RX_DLY_TAP(d) != cal.tap[l] || CSI2RX_DLY_OUT(d) != cal.tap[l]) {
      return fail("lane %u: DLY %08x, expected tap %u", l, d, cal.tap[l]);
    }
  }
  if (!bow_csi2rx_link_check(64, 4u * s->tap_ms)) {
    return fail("link check with taps %u/%u", cal.tap[0], cal.tap[1]);
  }
  return pass("taps %u/%u eye %u/%u", cal.tap[0], cal.tap[1], cal.width[0], cal.width[1]);
}

static bool check_integrity(const suite_t *s) {
  uint32_t wc = ct.w * 5u / 4u, sum = solid_sum(colour10, false);
  if (!check_frames(s, s->wait_ms, s->frames, CSI2_DT_RAW10, wc, sum)) return false;
  return pass("%u frames %ux%u RAW10: wc %u, sum %08x", s->frames, ct.w, ct.h, wc, sum);
}

/* Log entry of the RAW10 test stream: NULL, or what is wrong with it.
 * LS/LE are allowed (counted in *lsle; the IMX219 does not send them). */
static const char *entry_error(uint32_t e, uint32_t *lsle) {
  uint32_t dt = CSI2RX_LOG_DT(e);
  if (CSI2RX_LOG_ECC(e) != CSI2RX_ECC_OK) return "header ECC";
  if (e & (CSI2RX_LOG_CRC_ERR | CSI2RX_LOG_TRUNC)) return "CRC error or truncated";
  if (dt == CSI2_DT_LS || dt == CSI2_DT_LE) {
    (*lsle)++;
    return NULL;
  }
  if (dt == CSI2_DT_RAW10) return CSI2RX_LOG_WC(e) == ct.w * 5u / 4u ? NULL : "line word count";
  return (dt == CSI2_DT_FS || dt == CSI2_DT_FE || dt == CSI2_DT_EMB) ? NULL : "data type";
}

static bool check_log(const char *what, uint32_t n, uint32_t *lsle) {
  for (uint32_t i = 0; i < n; i++) {
    const char *err = entry_error(log_e[i], lsle);
    if (err) return fail("log %s: entry %u = %08x: %s", what, i, log_e[i], err);
  }
  return true;
}

static bool check_packets(const suite_t *s) {
  uint32_t n, lsle = 0, lines = 0;

  /* from the next FS */
  n = bow_csi2rx_log(log_e, CSI2RX_LOG_TRIG_FS, 2u * s->wait_ms);
  if (n == 0) return fail("log fs: timeout");
  if (CSI2RX_LOG_DT(log_e[0]) != CSI2_DT_FS) {
    return fail("log fs: entry 0 has data type %02x", CSI2RX_LOG_DT(log_e[0]));
  }
  if (!check_log("fs", n, &lsle)) return false;

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

  bow_printf("[PASS] %s FS, embedded data, lines, FE: headers and CRC ok", check_name);
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
  if (!bow_csi2rx_wait_frame(s->wait_ms)) return fail("no frame end");
  uint32_t ft = CSI2RX->FRAME_TIME, lt = CSI2RX->LINE_TIME;
  uint32_t byte_hz = bow_csi2rx_byteclk_hz(s->quick ? 0u : 100u);
  uint32_t f_us = muldiv(ft, 1000000u, clk), l_ns = muldiv(lt, 1000000000u, clk);
  if (s->quick) {
    if (lt == 0 || ft <= ct.h * lt) {
      return fail("frame %u cycles, line %u cycles: not more than %u lines", ft, lt, ct.h);
    }
    if (byte_hz == 0) return fail("no byte clock measured");
  } else {
    uint32_t f_ref = (uint32_t)((uint64_t)ct.fll * IMX219_LLP * clk / IMX219_PIXEL_RATE);
    uint32_t l_ref = (uint32_t)((uint64_t)IMX219_LLP * clk / IMX219_PIXEL_RATE);
    if (!within(ft, f_ref, 2)) {
      return fail("frame period %u us, expected %u us +-2 %%", f_us, muldiv(f_ref, 1000000u, clk));
    }
    if (!within(lt, l_ref, 2)) {
      return fail("line time %u ns, expected %u ns +-2 %%", l_ns, muldiv(l_ref, 1000000000u, clk));
    }
    if (!within(byte_hz, IMX219_LANE_RATE / 8u, 3)) {
      return fail("byte clock %u kHz, expected %u kHz +-3 %%", byte_hz / 1000u,
                  IMX219_LANE_RATE / 8000u);
    }
  }
  return pass("frame %u us, line %u ns, byte clock %u kHz", f_us, l_ns, byte_hz / 1000u);
}

static bool bar_level(uint32_t v, bool on) { return on ? v > 160u : v < 80u; }

static bool check_isp(const suite_t *s) {
  uint32_t bufwords = (ISP->INFO >> 16) * 1024u, sc = 0;
  bool ok = false;
  while (sc < 3 && (ct.w >> sc) * (ct.h >> sc) > bufwords) sc++;
  uint32_t cw = ct.w >> sc, ch = ct.h >> sc;
  if (ct.w > (ISP->INFO & 0xFFFFu) || cw * ch > bufwords) {
    return fail("%ux%u does not fit the ISP", ct.w, ct.h);
  }
  if (imx219_set_test_pattern(IMX219_TP_BARS) != I2C_OK) return fail("I2C error");
  bow_isp_init(ct.w, ct.h, ISP_BAYER_RGGB);
  bow_isp_set_ccm(ccm_imx219, zero3);
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
  imx219_set_test_pattern(ct.tp);
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
  if (period == 0) return fail("no frame period measured");
  if (nf * (ct.h + 2u) > 0xFFFFu) nf = 0xFFFFu / (ct.h + 2u); /* 16 bit drop counter */
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
  if (period == 0) period = frame_ms() * (bow_clk_hz() / 1000u);
  rnd_state ^= bow_cycles();
  for (uint32_t i = 0; i < 3; i++) {
    bow_delay_cycles(rnd() % period); /* stream off somewhere in the frame */
    stream_stop();
    bow_delay_cycles(rnd() % period); /* and on again after a while */
    if (!stream_start(false)) return fail("restart %u: sensor does not start", i);
    if (!check_frames(s, 4u * s->wait_ms, 2, CSI2_DT_RAW10, ct.w * 5u / 4u,
                      solid_sum(colour10, false))) {
      return false;
    }
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

/* checks 2-6 run once per mode */
static const check_t link_checks[] = {
    {"link-up", check_link_up},     {"calibrate", check_calibrate}, {"integrity", check_integrity},
    {"packets", check_packets},     {"timing", check_timing},
};
static const check_t stream_checks[] = {
    {"isp", check_isp},         {"raw8", check_raw8}, {"filter", check_filter},
    {"restart", check_restart}, {"irq", check_irq},
};

#define NCHECKS(a) (sizeof(a) / sizeof((a)[0]))

static void run(const check_t *t, uint32_t n, const suite_t *s, uint32_t *passed, uint32_t *total) {
  for (uint32_t i = 0; i < n; i++) {
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
             ct.h, imx219_frame_us(ct.fll), s->frames, s->step);
}

bool run_tests(bool quick) {
  static const check_t idle_check = {"phy-idle", check_phy_idle};
  suite_t s = {.quick = quick, .step = quick ? 32u : 8u, .frames = quick ? 4u : 60u};
  uint32_t passed = 0, total = 0;

  if (!ct.sensor || !ct.phy) {
    bow_printf("error: the test needs the IMX219 and a D-PHY (kv260_cam build)\n");
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
