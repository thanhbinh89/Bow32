/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Test of the Bow32 MIPI CSI-2 receiver with the Raspberry Pi camera v2
 * (IMX219) and its test patterns, from a shell on UART0. Type `h` for help.
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
 * calibration, packet log, raw PHY words, delay taps, status.
 */
#include "csi2_test.h"

static const char help[] =
    "  test [quick]        run all checks (quick: 64x48 frames, for the simulation)\n"
    "  start | stop        stream from the sensor / stop it\n"
    "  stat                receiver status: link, counters, timing, PHY state\n"
    "  cal [step]          calibrate the data lane delays while streaming (step 16)\n"
    "  delay <lane> <tap>  set the delay tap (0..511) of a data lane\n"
    "  log [fs] [fe]       log of 64 packets: now, from the next FS, up to an FE\n"
    "  raw [now]           64 raw PHY words per lane from the next HS burst (or now)\n"
    "  irq                 count FS interrupts during 4 frames\n"
    "  mode <w> <h> [fps] | 1080p | 720p   frame size (fps 0: shortest frame)\n"
    "  tp <n> [r gr b gb]  test pattern: 0 off 1 solid 2 bars 3 fade 4 PN9; solid colour\n"
    "  fmt raw8|raw10      sensor output format\n"
    "  rd <addr>  wr <addr> <val>   bus read / write (hex)\n";

csi2_test_t ct = {
    .w = 1920, .h = 1080, .fll = 1763,
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
uint32_t frame_ms(void) { return imx219_frame_us(ct.fll) / 1000u + 1u; }

uint32_t tap_timeout_ms(void) { return imx219_frame_us(ct.fll) * 12u / 10000u + 3u; }

static uint32_t stream_dt(void) { return imx219_format() == 8 ? CSI2_DT_RAW8 : CSI2_DT_RAW10; }

int set_colour(const uint32_t c[4]) { return imx219_set_test_colour(c[0], c[1], c[2], c[3]); }

bool stream_start(bool configure) {
  int r = I2C_OK;
  bow_csi2rx_start(2, stream_dt(), IMX219_LANE_RATE); /* before the sensor leaves LP-11 */
  if (configure) {
    r = imx219_configure(ct.w, ct.h, ct.fll);
    /* the power-on exposure (1000 lines) would stretch shorter frames */
    if (r == I2C_OK) r = imx219_set_exposure(ct.fll - IMX219_EXP_OFFSET);
    if (r == I2C_OK) r = imx219_set_orientation(false, false);
    if (r == I2C_OK) r = imx219_set_test_pattern(ct.tp);
    if (r == I2C_OK) r = set_colour(ct.colour);
  }
  if (r == I2C_OK) r = imx219_stream(true);
  if (r != I2C_OK) {
    bow_printf("error: I2C %d while starting the sensor\n", r);
    CSI2RX->CTRL = 0;
    return false;
  }
  ct.streaming = true;
  return true;
}

void stream_stop(void) {
  imx219_stream(false);
  bow_csi2rx_stop(frame_ms() + 10u); /* the sensor finishes its frame first */
  ct.streaming = false;
}

bool set_mode(uint32_t w, uint32_t h, uint32_t fps) {
  if (w < 16 || h < 8 || w > IMX219_ACTIVE_W || h > IMX219_ACTIVE_H || (w & 3u) || (h & 1u)) {
    bow_printf("error: width 16..%u (multiple of 4), height 8..%u (even)\n", IMX219_ACTIVE_W,
               IMX219_ACTIVE_H);
    return false;
  }
  bool run = ct.streaming;
  if (run) stream_stop();
  ct.w = w;
  ct.h = h;
  ct.fll = imx219_fll_for_fps(h, fps);
  return run ? stream_start(true) : true;
}

/* The sensor takes a new output format (0x018c, 0x0309) only in standby:
 * changed while streaming, its output timing and pixels go wrong. */
bool set_format(uint32_t bits) {
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
static uint32_t raw_bits(const uint16_t *w, uint32_t lane, uint32_t b) {
  uint32_t i = b / 8u, v = (w[i] >> (8u * lane)) & 0xFFu;
  if (i + 1u < CSI2RX_RAW_WORDS) v |= ((w[i + 1u] >> (8u * lane)) & 0xFFu) << 8;
  return (v >> (b % 8u)) & 0xFFu;
}

static void print_raw(const uint16_t *w) {
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

/* --------------------------------------------------------------- commands */
static bool need_phy(void) {
  if (!ct.phy) bow_printf("error: this bitstream has no D-PHY (use the kv260_cam build)\n");
  return ct.phy;
}

static bool execute(const char *line) {
  static uint32_t entries[CSI2RX_LOG_ENTRIES];
  static uint16_t words[CSI2RX_RAW_WORDS];
  const char *a;
  uint32_t v, v2;

  if ((a = match(line, "h")) || (a = match(line, "help"))) {
    bow_puts(help);
    return true;
  }
  if ((a = match(line, "test"))) return run_tests(word_is(a, "quick"));
  if ((a = match(line, "stat"))) {
    bow_csi2rx_print_status();
    return true;
  }
  if ((a = match(line, "start"))) {
    if (!ct.sensor) {
      bow_printf("error: no IMX219\n");
      return false;
    }
    if (!need_phy()) return false;
    if (ct.streaming) stream_stop();
    if (!stream_start(true)) return false;
    bool ok = bow_csi2rx_link_check(64, 4u * tap_timeout_ms());
    bow_printf("streaming %ux%u RAW%u, link check %s\n", ct.w, ct.h, imx219_format(),
               ok ? "ok" : "failed (try cal)");
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
    if (!bow_csi2rx_calibrate(v, tap_timeout_ms(), &cal, true)) {
      bow_printf("csi2rx: calibration failed\n");
      return false;
    }
    bow_printf("csi2rx: calibrated taps %u/%u eye %u/%u\n", cal.tap[0], cal.tap[1], cal.width[0],
               cal.width[1]);
    return true;
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
    if (!need_phy()) return false;
    uint32_t n = bow_csi2rx_log(entries, mode, 3u * frame_ms() + 100u);
    if (n == 0) {
      bow_printf("error: no packets (streaming?)\n");
      return false;
    }
    bow_csi2rx_print_log(entries, n);
    return true;
  }
  if ((a = match(line, "raw"))) {
    if (!need_phy()) return false;
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
    } else {
      if (!(a = parse_num(a, &w)) || !(a = parse_num(a, &h))) return false;
      parse_num(a, &fps);
    }
    if (!set_mode(w, h, fps)) return false;
    bow_printf("mode %ux%u, FLL %u = frame %u us\n", ct.w, ct.h, ct.fll, imx219_frame_us(ct.fll));
    return true;
  }
  if ((a = match(line, "tp"))) {
    uint32_t c[4];
    if (!(a = parse_num(a, &v)) || v > IMX219_TP_PN9) return false;
    if ((a = parse_num(a, &c[0]))) {
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
    int r = imx219_set_test_pattern(ct.tp);
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
  uint16_t id = 0;
  uint32_t lanes = 0;
  bool phy = false;

  bow_i2c_init(I2C0, 400000);
  int r = imx219_probe(&id);
  ct.sensor = (r == I2C_OK && id == IMX219_CHIP_ID);
  if (ct.sensor) {
    bow_printf("camera: IMX219 found (id %04x)\n", id);
  } else if (r == I2C_OK) {
    bow_printf("camera: unknown sensor id %04x\n", id);
  } else {
    bow_printf("camera: no IMX219 on I2C (error %d)\n", r);
  }

  bool csi = bow_csi2rx_probe(&lanes, &phy);
  ct.phy = csi && phy;
  ct.lanes = lanes == 0 ? 1u : lanes > 2 ? 2u : lanes;
  if (ct.phy) {
    bow_printf("csi2rx: Bow32 receiver, %u lanes, PHY clock %u MHz\n", lanes,
               CSI2RX_INFO_MHZ(CSI2RX->INFO));
  } else if (csi) {
    bow_printf("csi2rx: Bow32 receiver, no D-PHY in this bitstream - ISP test pattern only\n");
  } else {
    bow_printf("csi2rx: not present - ISP test pattern only\n");
  }
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
