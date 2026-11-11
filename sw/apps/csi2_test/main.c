/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Test of the Bow32 MIPI CSI-2 receiver with a camera sensor and its test
 * patterns, from a shell on UART0. Type `h` for help. Sensors
 * (cam_sensor.h, detected at start-up): Raspberry Pi camera v2 (IMX219,
 * 2 lanes, KV260) and LI-IMX274MIPI-FMC (IMX274, 4 lanes x 1440 Mbit/s,
 * Huins MFP-VP1902 camera build).
 *
 *   test          all checks on the board: 1080p30 and 720p60, calibration
 *                 step 8, 60 frames per check, timing against the sensor
 *   test quick    the same checks on 64x48 frames, for the simulation
 *                 (make -C sim run TEST=csi2)
 * Each check prints "[PASS] <name> ..." or "[FAIL] <name>: <reason>", the
 * run ends with "csi2_test: PASS (k/k)" or "csi2_test: FAIL (j/k)" and
 * leaves the stream running with cleared counters.
 *
 * The other commands drive the receiver by hand: stream start/stop, eye
 * calibration, packet log, raw PHY words, delay taps, status. With the
 * Versal XPHY (INFO.DLY_VID, Huins camera build) also the PHY knobs on GPIO
 * (`phy`: status, re-initialisation, RX FIFO reset per burst) and the sensor
 * stream without the receiver (`sensor on`): when the PHY's self-calibration
 * (BISC) needs a running clock lane, `sensor on`, `phy reinit`, then `start`.
 */
#include "csi2_test.h"

/* Huins camera build (bow32_huins_vp1902_cam_top): knobs of the Versal
 * XPHY, level = OUT & DIR of the pin, 0 after reset; raw XPHY status. */
#define PHY_REINIT   GPIO_PIN(4) /* PA4: 1 = PHY in PLL reset; at 0 XPLL, BISC, VT again */
#define PHY_BURSTRST GPIO_PIN(5) /* PA5: 1 = RX FIFO reset at every HS burst */
#define PHY_NIB_RDY  GPIO_PIN(6) /* PB6: PHY_RDY of every nibble */
#define PHY_NIB_DLY  GPIO_PIN(7) /* PB7: DLY_RDY of every nibble */
#define PHY_RDY_MS   10u         /* `phy reinit`: wait for STATUS.PHY_RDY */
/* PA5 that every receiver start writes (cam_rx_start) */
#if CAM_BURST_RST
#define CAM_BURST_RST_STR "1"
#else
#define CAM_BURST_RST_STR "0"
#endif

/* `h`: help_a, help_phy (Versal XPHY), mode/tp/fmt lines of the sensor, help_b */
static const char help_a[] =
    "  test [quick]        run all checks (quick: 64x48 frames, for the simulation)\n"
    "  start | stop        stream from the sensor / stop it\n"
    "  stat                receiver status: link, counters, timing, PHY state\n"
    "  cal [step]          calibrate the data lane delays while streaming (step 16)\n"
    "  margin [k] [frames] errors at the taps in use and k taps around them\n"
    "                      (k 0: eye / 4 of the last calibration; 60 frames per point)\n"
    "  delay <lane> <tap>  set the delay tap (0..511) of a data lane\n"
    "  log [fs] [fe]       log of 64 packets: now, from the next FS, up to an FE\n"
    "  raw [now]           64 raw PHY words per lane from the next HS burst (or now)\n"
    "  irq                 count FS interrupts during 4 frames\n";
static const char help_219[] =
    "  mode <w> <h> [fps] | 1080p | 720p   frame size (fps 0: shortest frame)\n"
    "  tp <n> [r gr b gb]  test pattern: 0 off 1 solid 2 bars 3 fade 4 PN9; solid colour\n"
    "  fmt raw8|raw10      sensor output format\n";
static const char help_274[] =
    "  mode <w> <h> [fps] | 1080p | 720p | 4k   frame size (fps 0: shortest frame;\n"
    "                      4k: needs a receiver FIFO of 1024 groups)\n"
    "  tp <n>              test pattern: 0 off 1..4 solid 000/FFF/555/AAA 5..10 stripes\n"
    "                      11 colour bars 12 horizontal bars\n"
    "  simfast on|off      sensor start-up waits / 64 (simulation only)\n";
static const char help_phy[] =
    "  phy                 PHY_RDY, every nibble's PHY_RDY / DLY_RDY (PB6 / PB7), knobs\n"
    "  phy reinit          XPLL lock + BISC again (PA4 pulse), VT tracking back on\n"
    "  phy burstrst 0|1    RX FIFO reset at every HS burst (PA5; start sets " CAM_BURST_RST_STR ")\n"
    "  sensor on|off       sensor stream without the receiver (BISC needs a clock?)\n";
static const char help_b[] =
    "  rd <addr>  wr <addr> <val>   bus read / write (hex)\n";

csi2_test_t ct = {
    .s = &cam_imx219,
    .w = 1920, .h = 1080, .fps = 30,
    .tp = IMX219_TP_SOLID, .colour = {0x135, 0x2CA, 0x0F3, 0x2CA},
};

/* ------------------------------------------------------------------ parsing */
static const char *skip_spaces(const char *s) {
  while (*s == ' ') s++;
  return s;
}

/* Decimal (hex if hex), or hex with 0x. Returns the rest of the string or NULL. */
static const char *parse_int(const char *s, uint32_t *v, bool hex) {
  uint32_t x = 0;
  const char *start;
  s = skip_spaces(s);
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
  if (s == start) return NULL;
  *v = x;
  return s;
}

static const char *parse_num(const char *s, uint32_t *v) { return parse_int(s, v, false); }

/* Word at s (up to space / end) equals w? */
static bool word_is(const char *s, const char *w) {
  s = skip_spaces(s);
  while (*w && *s == *w) s++, w++;
  return *w == '\0' && (*s == '\0' || *s == ' ');
}

/* Any word of s equals w? */
static bool has_word(const char *s, const char *w) {
  for (s = skip_spaces(s); *s; s = skip_spaces(s)) {
    if (word_is(s, w)) return true;
    while (*s && *s != ' ') s++;
  }
  return false;
}

/* Command name -> rest of the line, or NULL if the line is another command. */
static const char *match(const char *line, const char *cmd) {
  const char *s = line;
  while (*cmd && *s == *cmd) s++, cmd++;
  if (*cmd != '\0' || (*s != '\0' && *s != ' ')) return NULL;
  return s;
}

/* ----------------------------------------------------------- stream control */
uint32_t frame_ms(void) { return cam_frame_us(ct.s) / 1000u + 1u; }

uint32_t tap_timeout_ms(void) { return cam_frame_us(ct.s) * 12u / 10000u + 3u; }

int set_colour(const uint32_t c[4]) {
  return sensor_imx274() ? I2C_OK : imx219_set_test_colour(c[0], c[1], c[2], c[3]);
}

/* Sensor (configure: format, crop, exposure, flip, test pattern) and its
 * stream on; the receiver is not touched. */
static int sensor_start(bool configure) {
  int r = I2C_OK;
  if (configure) {
    r = ct.s->configure();
    /* the power-on exposure (1000 lines) would stretch shorter frames */
    if (r == I2C_OK) r = ct.s->set_exposure(ct.s->exposure_max());
    if (r == I2C_OK) r = ct.s->set_flip(false, false);
    if (r == I2C_OK) r = ct.s->set_test_pattern(ct.tp);
    if (r == I2C_OK) r = set_colour(ct.colour);
  }
  if (r == I2C_OK) r = ct.s->start();
  return r;
}

bool stream_start(bool configure) {
  /* before the sensor leaves LP-11 (IMX274: LP-00 in standby); Versal XPHY:
   * PA5 = CAM_BURST_RST (cam_sensor.h) */
  if (cam_rx_start(ct.s, ct.s->dt()) != CSI2RX_OK) {
    bow_printf("error: D-PHY not ready (CSI2RX STATUS.PHY_RDY = 0)\n");
    if (ct.vid) bow_puts("  phy: nibble status; sensor on + phy reinit: BISC with a running clock\n");
    return false;
  }
  int r = sensor_start(configure);
  if (r != I2C_OK) {
    bow_printf("error: I2C %d while starting the sensor\n", r);
    CSI2RX->CTRL = 0;
    return false;
  }
  ct.streaming = true;
  return true;
}

static void stop_stream(uint32_t timeout_ms) {
  cam_stream_stop(ct.s, timeout_ms); /* the IMX219 finishes its frame first */
  ct.streaming = false;
}

void stream_stop(void) { stop_stream(frame_ms() + 10u); }

/* Receiver FIFO groups (4 pixels) a line of w pixels leaves at its end: the
 * line burst writes lanes x lane rate / bits per pixel, the video clock reads
 * one pixel per cycle (docs/ip/csi2rx.md). IMX274 RAW10 at 200 MHz: 0.163 W
 * (1920: 313, 3840: 626). */
static uint32_t fifo_peak(uint32_t w) {
  uint32_t in = ct.s->lanes * ct.s->lane_rate_mbps; /* Mbit/s */
  uint32_t out = CSI2RX_INFO_MHZ(CSI2RX->INFO) * (ct.s->dt() == CSI2_DT_RAW8 ? 8u : 10u);
  return in > out ? w * (in - out) / (4u * in) : 0;
}

bool set_mode(uint32_t w, uint32_t h, uint32_t fps) {
  if (w < 16 || h < 8 || w > ct.s->max_w || h > ct.s->max_h || (w & 3u) || (h & 1u)) {
    bow_printf("error: width 16..%u (multiple of 4), height 8..%u (even)\n", ct.s->max_w,
               ct.s->max_h);
    return false;
  }
  /* every line would overflow the FIFO (OVF, pixels lost); +4 groups for
   * the pointer synchronisers */
  uint32_t peak = ct.phy ? fifo_peak(w) : 0, depth = ct.phy ? CSI2RX_INFO_FIFO(CSI2RX->INFO) : 0;
  if (peak && peak + 4u > depth) {
    bow_printf("error: a %u pixel line leaves ~%u groups in the receiver FIFO, it has %u "
               "(4K: 1024 needed)\n", w, peak + 4u, depth);
    return false;
  }
  bool run = ct.streaming;
  uint32_t stop_ms = frame_ms() + 10u; /* of the running mode */
  if (ct.s->mode(w, h, fps, false) != I2C_OK) return false;
  if (run) stop_stream(stop_ms);
  ct.w = w;
  ct.h = h;
  ct.fps = fps;
  return run ? stream_start(true) : true;
}

/* The IMX219 takes a new output format (0x018c, 0x0309) only in standby:
 * changed while streaming, its output timing and pixels go wrong. */
bool set_format(uint32_t bits) {
  if (!ct.s->has_raw8) {
    if (bits == 10) return true;
    bow_printf("error: the %s has no RAW8 output\n", ct.s->name);
    return false;
  }
  bool run = ct.streaming;
  if (run) stream_stop();
  if (imx219_set_format(bits) != I2C_OK) return false;
  return run ? stream_start(false) : true;
}

/* ---------------------------------------------------------------- interrupt */
static volatile uint32_t irq_fs;

/* irq_fast[7] (mcause 0x80000017): count FS, clear the enabled flags. */
void bow_irq_fast_handler(unsigned line) {
  if (line == BOW32_IRQ_FAST_CSI2RX) {
    uint32_t st = CSI2RX->IRQ_STATUS & CSI2RX->IRQ_EN;
    CSI2RX->IRQ_STATUS = st;
    if (st & CSI2RX_IRQ_FS) irq_fs++;
  } else {
    bow_irq_fast_disable(line);
  }
}

uint32_t count_fs_irqs(uint32_t frames, uint32_t timeout_ms) {
  irq_fs = 0;
  CSI2RX->IRQ_STATUS = CSI2RX_IRQ_FS;
  CSI2RX->IRQ_EN = CSI2RX_IRQ_FS;
  bow_irq_fast_enable(BOW32_IRQ_FAST_CSI2RX);
  bow_irq_global_enable();
  while (frames-- && bow_csi2rx_wait_frame(timeout_ms)) {
  }
  CSI2RX->IRQ_EN = 0;
  bow_irq_fast_disable(BOW32_IRQ_FAST_CSI2RX);
  bow_irq_global_disable();
  return irq_fs;
}

/* ------------------------------------------------------------- raw words */
/* 8 bits of a lane's bit stream from bit b on (bit 0 of word 0 first). */
static uint32_t raw_bits(const uint32_t *w, uint32_t lane, uint32_t b) {
  uint32_t i = b / 8u, v = (w[i] >> (8u * lane)) & 0xFFu;
  if (i + 1u < CSI2RX_RAW_WORDS) v |= ((w[i + 1u] >> (8u * lane)) & 0xFFu) << 8;
  return (v >> (b % 8u)) & 0xFFu;
}

static void print_raw(const uint32_t *w) {
  for (uint32_t l = 0; l < ct.lanes; l++) {
    bow_printf("lane %u:", l);
    for (uint32_t i = 0; i < CSI2RX_RAW_WORDS; i++) {
      if (i && i % 16u == 0) bow_puts("\n       ");
      bow_printf(" %02x", (w[i] >> (8u * l)) & 0xFFu);
    }
    /* sync sequence of the aligner: a zero byte, then 0xB8 (LSB first) */
    uint32_t b = 8, end = 8u * CSI2RX_RAW_WORDS - 8u;
    while (b <= end && !(raw_bits(w, l, b - 8u) == 0 && raw_bits(w, l, b) == 0xB8u)) b++;
    if (b <= end) {
      bow_printf("\n        sync byte at bit %u (word %u + %u)\n", b, b / 8u, b % 8u);
    } else {
      bow_puts("\n        no sync byte\n");
    }
  }
}

/* -------------------------------------------------- Versal XPHY knobs (GPIO) */
static uint32_t knob(uint32_t pin) { return (GPIOA->OUT & GPIOA->DIR & pin) ? 1u : 0u; }

static void set_knob(uint32_t pin, bool on) {
  if (on) {
    bow_gpio_set(GPIOA, pin);
    bow_gpio_output(GPIOA, pin);
  } else {
    bow_gpio_clear(GPIOA, pin);
  }
}

static uint32_t phy_ready(void) { return (CSI2RX->STATUS & CSI2RX_ST_PHY_RDY) ? 1u : 0u; }

/* "phy: STATUS.PHY_RDY 1, every nibble PHY_RDY 1 DLY_RDY 1 (PB6 PB7), ..."
 * and the delays in use of every lane of the receiver */
static void print_phy(void) {
  uint32_t b = bow_gpio_read(GPIOB);
  bow_printf("phy: STATUS.PHY_RDY %u, every nibble PHY_RDY %u DLY_RDY %u (PB6 PB7), "
             "reinit %u burstrst %u (PA4 PA5)\n     delays in use",
             phy_ready(), (b & PHY_NIB_RDY) ? 1u : 0u, (b & PHY_NIB_DLY) ? 1u : 0u,
             knob(PHY_REINIT), knob(PHY_BURSTRST));
  for (uint32_t l = 0; l < ct.lanes; l++) {
    bow_printf("%c%u", l ? '/' : ' ', CSI2RX_DLY_OUT(bow_csi2rx_read_delay(l)));
  }
  bow_puts("\n");
}

/* PA4 pulse of >= 10 us: the PHY drops PHY_RDY and its loaded taps, then
 * runs XPLL lock, BISC and VT tracking again. Waits up to 10 ms for
 * STATUS.PHY_RDY and prints the time. */
static bool phy_reinit(void) {
  uint32_t mhz = bow_clk_hz() / 1000000u, before = phy_ready();
  set_knob(PHY_REINIT, true);
  bow_delay_us(10);
  uint32_t held = phy_ready();
  set_knob(PHY_REINIT, false);
  if (before && held) {
    bow_puts("error: PHY_RDY stayed 1 during the reinit pulse (no PA4 knob in this bitstream?)\n");
    return false;
  }
  bow_csi2rx_forget_delays(); /* every lane on its new BISC delay */
  uint32_t t0 = bow_cycles(), dt, rdy;
  do {
    rdy = phy_ready();
    dt = bow_cycles() - t0;
  } while (!rdy && dt <= PHY_RDY_MS * 1000u * mhz);
  if (rdy) {
    bow_printf("phy: PHY_RDY %u us after the reinit pulse\n", dt / mhz);
  } else {
    bow_printf("phy: PHY_RDY still 0 %u ms after the reinit pulse\n", PHY_RDY_MS);
  }
  print_phy();
  if (CSI2RX->CTRL & CSI2RX_CTRL_RX_EN) bow_puts("phy: the receiver ran through it: start\n");
  return rdy != 0;
}

/* `phy [reinit | burstrst 0|1]` (Versal XPHY) */
static bool phy_cmd(const char *a) {
  const char *s = skip_spaces(a);
  uint32_t v;
  if (*s == '\0') {
    print_phy();
    return true;
  }
  if (word_is(s, "reinit")) return phy_reinit();
  if (!word_is(s, "burstrst")) return false;
  if (!parse_num(s + 8, &v) || v > 1u) return false;
  set_knob(PHY_BURSTRST, v != 0);
  print_phy();
  return true;
}

/* `sensor on|off` (Versal XPHY): the sensor streams with the receiver off,
 * e.g. so that BISC (`phy reinit`) sees a running clock lane; `start` then
 * restarts both in order. off: standby (`stop` order if the receiver runs). */
static bool sensor_cmd(const char *a) {
  bool on = word_is(a, "on");
  int r;
  if (!on && !word_is(a, "off")) return false;
  if (!ct.sensor) {
    bow_printf("error: no %s\n", ct.s->name);
    return false;
  }
  if (on) {
    if (ct.streaming) {
      stream_stop();
    } else {
      bow_csi2rx_stop(0); /* receiver off */
    }
    r = sensor_start(true);
  } else if (CSI2RX->CTRL & CSI2RX_CTRL_RX_EN) {
    stream_stop();
    return true;
  } else {
    r = ct.s->stop();
  }
  if (r != I2C_OK) {
    bow_printf("error: I2C %d\n", r);
    return false;
  }
  ct.streaming = on;
  if (on) {
    bow_printf("sensor: streaming %ux%u, receiver off (PHY_RDY %u)\n", ct.w, ct.h, phy_ready());
  }
  return true;
}

/* --------------------------------------------------------------- commands */
/* Link check of `start` over whole frames. On the Huins board (run 2) the
 * BISC delays, which every lane of the Versal XPHY uses after a PDI load or
 * `phy reinit`, gave 0.2-1.5 CRC errors per 1080p frame, and the check of 64
 * packets (6 % of a frame) used before passed there. 16 frames see a rate of
 * 0.2 errors per frame 96 % of the time (1 - e^-3.2); ~0.55 s at 1080p30. */
#define START_FRAMES 16u

static void start_check(void) {
  /* the first frame start comes after the frames the sensor does not output
   * after its start (IMX274), then up to a frame later */
  uint32_t ms = (START_FRAMES + 2u + ct.s->start_frames) * tap_timeout_ms(), done;
  bool ok = bow_csi2rx_link_check_frames(START_FRAMES, ms, &done);
  bow_csi2rx_cnt_t c;
  bow_csi2rx_counters(&c);
  uint32_t err = CSI2RX->ERR_STATUS;
  bow_printf("streaming %ux%u RAW%u, link check %s", ct.w, ct.h,
             ct.s->dt() == CSI2_DT_RAW8 ? 8u : 10u, ok ? "ok\n" : "failed");
  if (ok) return;
  if (bow_csi2rx_link_errors(&c) == 0) {
    if (c.packets == 0) {
      bow_printf(": no data (0 packets in %u ms, stat)\n", ms);
    } else {
      bow_printf(": %u of %u frames in %u ms (%u packets, stat)\n", done, START_FRAMES, ms,
                 c.packets);
    }
    return;
  }
  bow_printf(" (ERR_STATUS %03x)%s\n", err,
             (err & CSI2RX_ERR_TAP) ? ", try cal" : ", not a sampling problem (stat)");
  if ((err & CSI2RX_ERR_TAP) && ct.vid) {
    /* Versal XPHY: the BISC delays sit at the early edge of every eye
     * (docs/camera_huins.md 6.3, 9) */
    bow_printf("  errors in frame %u of %u at the delays in use ", done + 1u, START_FRAMES);
    bow_csi2rx_print_delays();
    bow_puts(": after a PDI load or\n"
             "  phy reinit these are the BISC delays, early in the eye; cal loads the eye centres\n");
  }
}

static bool need_phy(void) {
  if (!ct.phy) bow_printf("error: this bitstream has no D-PHY (use the %s build)\n", ct.s->build);
  return ct.phy;
}

/* false (with a message) after `sensor on`: the sensor streams, the receiver is off */
static bool rx_running(void) {
  if (ct.streaming && !(CSI2RX->CTRL & CSI2RX_CTRL_RX_EN)) {
    bow_printf("error: receiver off (sensor on): start\n");
    return false;
  }
  return true;
}

static bool execute(const char *line) {
  static uint32_t entries[CSI2RX_LOG_ENTRIES];
  static uint32_t words[CSI2RX_RAW_WORDS];
  const char *a;
  uint32_t v, v2;

  if ((a = match(line, "h")) || (a = match(line, "help"))) {
    bow_puts(help_a);
    if (ct.vid) bow_puts(help_phy);
    bow_puts(sensor_imx274() ? help_274 : help_219);
    bow_puts(help_b);
    return true;
  }
  if ((a = match(line, "test"))) return run_tests(word_is(a, "quick"));
  if ((a = match(line, "stat"))) {
    bow_csi2rx_print_status();
    return true;
  }
  if ((a = match(line, "start"))) {
    if (!ct.sensor) {
      bow_printf("error: no %s\n", ct.s->name);
      return false;
    }
    if (!need_phy()) return false;
    if (ct.lanes < ct.s->lanes) {
      bow_printf("error: the %s needs %u lanes, the receiver has %u\n", ct.s->name, ct.s->lanes,
                 ct.lanes);
      return false;
    }
    if (ct.streaming) stream_stop();
    if (!stream_start(true)) return false;
    start_check();
    return true;
  }
  if ((a = match(line, "stop"))) {
    stream_stop();
    return true;
  }
  if ((a = match(line, "cal"))) {
    bow_csi2rx_cal_t cal;
    v = 16;
    parse_num(a, &v);
    if (v == 0 || v > 256) return false;
    if (!ct.streaming) {
      bow_printf("error: not streaming (start)\n");
      return false;
    }
    if (!rx_running()) return false;
    if (!bow_csi2rx_calibrate(v, tap_timeout_ms(), &cal, true)) {
      bow_printf("csi2rx: calibration failed\n");
      return false;
    }
    bow_puts("csi2rx: calibrated ");
    bow_csi2rx_print_cal(&cal);
    bow_puts("\n");
    ct.cal = cal;
    ct.calibrated = true;
    return true;
  }
  if ((a = match(line, "margin"))) {
    bow_csi2rx_margin_t m;
    uint32_t k = 0, frames = 60;
    if ((a = parse_num(a, &k))) parse_num(a, &frames);
    if (frames == 0 || k > CSI2RX_DLY_MAX) return false;
    if (!ct.streaming || !ct.calibrated) {
      bow_printf("error: not streaming or not calibrated (start, cal)\n");
      return false;
    }
    /* around the taps in use on every lane (after `delay`, or the BISC
     * delays after `phy reinit`; DLY_VID: [24:16], the written [8:0] may be
     * an old tap), k from the eye of the last calibration */
    bow_csi2rx_cal_t c = ct.cal;
    bow_csi2rx_get_delays(c.tap);
    int r = bow_csi2rx_margin(&c, k, frames, tap_timeout_ms(), &m, true);
    bow_printf("csi2rx: margin %s", r > 0 ? "ok " : r == 0 ? "low " : "");
    bow_csi2rx_print_margin(&m, r);
    bow_puts("\n");
    return r > 0;
  }
  if ((a = match(line, "delay"))) {
    if (!(a = parse_num(a, &v)) || !parse_num(a, &v2) || v >= ct.lanes || v2 > CSI2RX_DLY_MAX) {
      return false;
    }
    bow_csi2rx_set_delay(v, v2);
    bool now = bow_csi2rx_wait_delay(tap_timeout_ms());
    bow_printf("lane %u tap %u: %s\n", v, v2, now ? "in use" : "used from the next burst");
    return true;
  }
  if ((a = match(line, "log"))) {
    uint32_t mode = (has_word(a, "fs") ? CSI2RX_LOG_TRIG_FS : 0) |
                    (has_word(a, "fe") ? CSI2RX_LOG_STOP_FE : 0);
    if (!need_phy() || !rx_running()) return false;
    uint32_t n = bow_csi2rx_log(entries, mode, 3u * frame_ms() + 100u);
    if (n == 0) {
      bow_printf("error: no packets (streaming?)\n");
      return false;
    }
    bow_csi2rx_print_log(entries, n);
    return true;
  }
  if ((a = match(line, "raw"))) {
    if (!need_phy() || !rx_running()) return false;
    if (!bow_csi2rx_raw(words, word_is(a, "now"), 3u * frame_ms() + 100u)) {
      bow_printf("error: no HS burst (streaming?)\n");
      return false;
    }
    print_raw(words);
    return true;
  }
  if ((a = match(line, "irq"))) {
    if (!need_phy()) return false;
    v = count_fs_irqs(4, 3u * tap_timeout_ms());
    bow_printf("irq: %u FS interrupts in 4 frames\n", v);
    return v != 0;
  }
  if ((a = match(line, "mode"))) {
    uint32_t w, h, fps = 30;
    if (word_is(a, "1080p")) {
      w = 1920, h = 1080;
    } else if (word_is(a, "720p")) {
      w = 1280, h = 720, fps = 60;
    } else if (sensor_imx274() && word_is(a, "4k")) {
      w = 3840, h = 2160, fps = 10; /* receiver test only: FIFO >= 1024 groups needed */
    } else {
      if (!(a = parse_num(a, &w)) || !(a = parse_num(a, &h))) return false;
      parse_num(a, &fps);
    }
    if (!set_mode(w, h, fps)) return false;
    bow_printf("mode %ux%u, ", ct.w, ct.h);
    ct.s->print_timing(CAM_TIMING_SHORT);
    bow_printf(" = frame %u us\n", cam_frame_us(ct.s));
    return true;
  }
  if ((a = match(line, "tp"))) {
    uint32_t c[4];
    if (!(a = parse_num(a, &v)) || v > ct.s->tp_max) return false;
    if ((a = parse_num(a, &c[0]))) {
      if (sensor_imx274()) return false; /* no programmable colour */
      for (int i = 1; i < 4; i++) {
        if (!(a = parse_num(a, &c[i]))) return false;
      }
      for (int i = 0; i < 4; i++) {
        if (c[i] > 0x3FFu) return false;
        ct.colour[i] = c[i];
      }
    }
    ct.tp = v;
    if (!ct.sensor) return true; /* takes effect at `start` */
    int r = ct.s->set_test_pattern(ct.tp);
    if (r == I2C_OK) r = set_colour(ct.colour);
    return r == I2C_OK;
  }
  if ((a = match(line, "fmt"))) {
    if (word_is(a, "raw8")) {
      v = 8;
    } else if (word_is(a, "raw10")) {
      v = 10;
    } else {
      return false;
    }
    return set_format(v);
  }
  if (sensor_imx274() && (a = match(line, "simfast"))) {
    if (!word_is(a, "on") && !word_is(a, "off")) return false;
    imx274_set_quick(word_is(a, "on"));
    return true;
  }
  if (ct.vid && (a = match(line, "phy"))) return phy_cmd(a);
  if (ct.vid && (a = match(line, "sensor"))) return sensor_cmd(a);
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
static void probe_hardware(void) {
  cam_detect_t d;
  uint32_t lanes = 0;
  bool phy = false;

  bow_i2c_init(I2C0, 400000);
  cam_sensor_detect(&d);
  ct.s = d.sensor;
  ct.sensor = d.found;
  if (ct.sensor) {
    bow_printf("camera: %s found (id %04x)\n", ct.s->name, d.id);
  } else {
    cam_print_not_found(&d);
  }
  ct.tp = ct.s->tp_solid;
  ct.s->mode(ct.w, ct.h, ct.fps, false); /* the default mode (1080p30) */

  bool csi = bow_csi2rx_probe(&lanes, &phy);
  ct.phy = csi && phy;
  ct.vid = ct.phy && (CSI2RX->INFO & CSI2RX_INFO_DLY_VID) != 0;
  ct.lanes = lanes == 0 ? 1u : lanes > CSI2RX_MAX_LANES ? CSI2RX_MAX_LANES : lanes;
  if (ct.phy) {
    bow_printf("csi2rx: Bow32 receiver, %u lanes, PHY clock %u MHz\n", lanes,
               CSI2RX_INFO_MHZ(CSI2RX->INFO));
  } else if (csi) {
    bow_printf("csi2rx: Bow32 receiver, no D-PHY in this bitstream - ISP test pattern only\n");
  } else {
    bow_printf("csi2rx: not present - ISP test pattern only\n");
  }
  if (!ct.sensor) cam_print_prsnt(lanes);
}

int main(void) {
  static char line[64];
  unsigned len = 0;
  int prev = 0;

  bow_uart_init(UART0, SYSCTRL->BOOT_BAUD);
  bow_printf("\ncsi2_test: Bow32 MIPI CSI-2 receiver test\n");
  probe_hardware();
  bow_printf("type h for help\n");

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
      bow_uart_putc(UART0, (char)c); /* echo */
    }
    if (c >= 0) prev = c;
  }
}
