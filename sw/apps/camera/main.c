/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Camera demo: Raspberry Pi camera v2 (IMX219) -> Bow32 MIPI CSI-2 receiver
 * -> Bow32 ISP, controlled from a small shell on UART0. Type `h` for help.
 *
 * Works on both KV260 builds:
 *   hw/fpga/kv260      no D-PHY: ISP test pattern (`tpg`), I2C probe
 *   hw/fpga/kv260_cam  camera: `cam` streams 1080p30 (or `mode 720p` = 60 fps)
 * Images are read from the ISP capture buffer and sent to the PC with `snap`
 * (tools/bow32_cam.py turns them into PNG files). See docs/camera_kv260.md.
 *
 * Shows: sensor bring-up over I2C, CSI-2 receiver start/stop around the
 * stream and eye calibration, ISP configuration (shadow registers + UPDATE),
 * statistics driven auto exposure / auto white balance, capture.
 */
#include "bow32.h"
#include "imx219.h"

static const char help[] =
    "source:\n"
    "  cam                 stream from the IMX219 (needs the kv260_cam build)\n"
    "  tpg [0..3]          ISP test pattern: 0 bars 1 ramp 2 checker 3 solid\n"
    "  stop                stop streaming\n"
    "  mode 1080p|720p|<w> <h> [fps]   frame size (default 1080p, 30 fps)\n"
    "sensor:\n"
    "  tp <n>              sensor test pattern (0 off, 1 solid, 2 colour bars)\n"
    "  exp <lines>         exposure (turns AE off)\n"
    "  gain <0..232>       analog gain code, gain = 256 / (256 - code)\n"
    "  flip <h> <v>        mirror / flip (0|1)\n"
    "  sr <reg> [val]      read / write a sensor register (hex)\n"
    "ISP:\n"
    "  ae on|off|<target>  auto exposure (target = mean linear luma, 0..1023)\n"
    "  awb on|off          gray world white balance\n"
    "  wb <r> <b>          white balance gains, 256 = 1.0 (turns AWB off)\n"
    "  mod <hex>           modules: 1 BLC 2 DPC 4 WB 8 CCM 10 gamma 20 CSC\n"
    "  fmt rgb|yuv         output format\n"
    "  stat                statistics of the next frame\n"
    "  focus               sharpness of every frame until a key is pressed\n"
    "capture:\n"
    "  cap [x y w h s]     capture w x h pixels, box filter 2^s (default: whole frame)\n"
    "  dump                send the capture to the PC (tools/bow32_cam.py)\n"
    "  snap                cap + dump\n"
    "CSI-2 receiver:\n"
    "  csi                 link status, counters, timing, PHY state\n"
    "  cal [step]          calibrate the data lane delays while streaming (step 16)\n"
    "  csilog [fs|fe]      log of 64 packets: now, from the next FS or up to an FE\n"
    "misc:\n"
    "  info  baud <rate>  rd <addr>  wr <addr> <val>\n";

/* Starting point for the IMX219 colour matrix (s3.8, rows sum to 1.0);
 * tune it for your light. */
static const int16_t ccm_imx219[9] = {461, -128, -77, -102, 461, -103, -38, -166, 460};
static const int16_t ccm_off0[3] = {0, 0, 0};

#define CTRL_PERIOD 3 /* frames between AE/AWB steps (sensor latency) */

static struct {
  /* frame format */
  uint32_t w, h, fll;
  /* hardware found at start-up: sensor, CSI-2 receiver, its D-PHY; the
   * data lane delays were calibrated */
  bool sensor, csi, phy, calibrated;
  /* state */
  bool cam, tpg, yuv, hflip, vflip;
  uint32_t tp, exposure, again;
  uint32_t modules;
  /* control loops */
  bool ae, awb, ae_locked, awb_locked;
  uint32_t ae_target, wb_r, wb_b, frames;
  /* last capture */
  uint32_t cap_w, cap_h;
} cam = {
    .w = 1920, .h = 1080, .fll = 1763,
    .exposure = 1000, .modules = ISP_MOD_BLC | ISP_MOD_DPC | ISP_MOD_WB | ISP_MOD_CCM | ISP_MOD_GAMMA,
    .ae_target = 180, .wb_r = 256, .wb_b = 256,
};

/* ------------------------------------------------------------------ parsing */
static const char *skip_spaces(const char *s) {
  while (*s == ' ') s++;
  return s;
}

/* Decimal, or hex with 0x. Returns the rest of the string or NULL. */
static const char *parse_num(const char *s, uint32_t *v, bool hex) {
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

/* Word at s (up to space / end) equals w? */
static bool word_is(const char *s, const char *w) {
  s = skip_spaces(s);
  while (*w && *s == *w) s++, w++;
  return *w == '\0' && (*s == '\0' || *s == ' ');
}

/* Command name -> rest of the line, or NULL if the line is another command. */
static const char *match(const char *line, const char *cmd) {
  const char *s = line;
  while (*cmd && *s == *cmd) s++, cmd++;
  if (*cmd != '\0' || (*s != '\0' && *s != ' ')) return NULL;
  return s;
}

/* ---------------------------------------------------------------- ISP setup */
static void isp_setup(uint32_t bayer) {
  bow_isp_init(cam.w, cam.h, bayer);
  bow_isp_set_ccm(ccm_imx219, ccm_off0);
  bow_isp_set_yuv(cam.yuv);
  ISP->MODULES = (cam.modules & ~ISP_MOD_CSC) | (cam.yuv ? ISP_MOD_CSC : 0);
  ISP->WB[ISP_WB_R] = cam.wb_r;
  ISP->WB[ISP_WB_B] = cam.wb_b;
}

/* Frame period of the current mode in ms, rounded up. */
static uint32_t frame_ms(void) { return imx219_frame_us(cam.fll) / 1000u + 1u; }

static void stop_all(void) {
  if (cam.cam) {
    if (cam.sensor) imx219_stream(false);
    bow_csi2rx_stop(frame_ms() + 10u); /* the sensor finishes its frame first */
  }
  ISP->CTRL = 0;
  cam.cam = cam.tpg = false;
}

static bool start_tpg(uint32_t pattern) {
  stop_all();
  isp_setup(ISP_BAYER_RGGB);
  ISP->TPG_CTRL = pattern & 3u;
  ISP->TPG_BLANK = (32u << 16) | 256u; /* vblank lines, hblank cycles */
  if (!bow_isp_update(100)) {
    bow_printf("error: ISP does not take the configuration (no video clock?)\n");
    return false;
  }
  ISP->STATUS = 0xFF;
  ISP->CTRL = ISP_CTRL_EN | ISP_CTRL_SRC_TPG;
  cam.tpg = true;
  cam.frames = 0;
  bow_printf("tpg %u %ux%u\n", pattern & 3u, cam.w, cam.h);
  return true;
}

static int sensor_apply_ctrl(void) {
  int r = imx219_set_exposure(cam.exposure);
  if (r == I2C_OK) r = imx219_set_analog_gain(cam.again);
  return r;
}

/* Eye calibration of the data lanes while the sensor streams. One tap may
 * have to wait for a whole frame: allow 1.2 frame periods + 2 ms per tap. */
static bool calibrate(uint32_t step, bool verbose) {
  bow_csi2rx_cal_t cal;
  uint32_t tap_ms = imx219_frame_us(cam.fll) * 12u / 10000u + 3u;
  if (!bow_csi2rx_calibrate(step, tap_ms, &cal, verbose)) {
    bow_printf("csi2rx: calibration failed\n");
    return false;
  }
  bow_printf("csi2rx: calibrated taps %u/%u eye %u/%u\n", cal.tap[0], cal.tap[1], cal.width[0],
             cal.width[1]);
  cam.calibrated = true;
  return true;
}

static bool start_cam(void) {
  if (!cam.sensor) {
    bow_printf("error: no IMX219 (check the ribbon cable, then `info`)\n");
    return false;
  }
  if (!cam.phy) {
    bow_printf("error: this bitstream has no D-PHY, use the kv260_cam build\n");
    return false;
  }
  stop_all();
  isp_setup(imx219_bayer(cam.hflip, cam.vflip));
  if (!bow_isp_update(100)) {
    bow_printf("error: ISP does not take the configuration (no video clock?)\n");
    return false;
  }
  bow_csi2rx_start(2, CSI2_DT_RAW10, IMX219_LANE_RATE); /* the sensor is still in LP-11 */
  uint32_t max_exp = cam.fll - IMX219_EXP_OFFSET;
  if (cam.exposure > max_exp) cam.exposure = max_exp;
  int r = imx219_configure(cam.w, cam.h, cam.fll);
  if (r == I2C_OK) r = imx219_set_orientation(cam.hflip, cam.vflip);
  if (r == I2C_OK) r = imx219_set_test_pattern(cam.tp);
  if (r == I2C_OK) r = sensor_apply_ctrl();
  if (r == I2C_OK) {
    ISP->STATUS = 0xFF;
    ISP->CTRL = ISP_CTRL_EN;
    r = imx219_stream(true);
  }
  if (r != I2C_OK) {
    bow_printf("error: I2C %d while programming the sensor\n", r);
    ISP->CTRL = 0;
    CSI2RX->CTRL = 0;
    return false;
  }
  cam.cam = true;
  cam.frames = 0;
  cam.ae_locked = cam.awb_locked = false;
  /* The first start calibrates (the reset tap 0 can sit at the edge of the
   * eye). The receiver keeps the taps: calibrate again only when the link
   * has errors with them. */
  if (!cam.calibrated || !bow_csi2rx_link_check(64, 200)) {
    if (!calibrate(16, false)) return false;
    /* The ISP drops the frames broken by the tap sweep (input error), the
     * last one just ended: after one clean frame, clear its error flags. */
    bow_csi2rx_wait_frame(2u * frame_ms());
    ISP->STATUS = ISP_ST_ERRORS;
  }
  static const char *const order[4] = {"RGGB", "GRBG", "GBRG", "BGGR"};
  bow_printf("streaming %ux%u %s\n", cam.w, cam.h, order[imx219_bayer(cam.hflip, cam.vflip)]);
  return true;
}

/* Restart the current source after a format change. */
static bool restart(void) {
  if (cam.cam) return start_cam();
  if (cam.tpg) return start_tpg(ISP->TPG_CTRL);
  return true;
}

/* ------------------------------------------------------------ control loops */
static uint32_t gain_q8(uint32_t code) { return 65536u / (256u - code); }

/* Auto exposure: scale exposure x gain so that the mean linear luma reaches
 * the target, at most x2 / /2 per step; exposure first, gain when the
 * exposure is at its maximum (frame length - 4). */
static void ae_step(const bow_isp_stats_t *s) {
  if (s->npix == 0) return;
  uint32_t mean = s->sum_y / s->npix;
  uint32_t t = cam.ae_target;
  if (mean * 16u > t * 15u && mean * 16u < t * 17u) {
    if (!cam.ae_locked) {
      bow_printf("ae: locked exp=%u gain=%u mean=%u\n", cam.exposure, cam.again, mean);
      cam.ae_locked = true;
    }
    return;
  }
  cam.ae_locked = false;
  uint32_t f = (t * 256u) / (mean ? mean : 1u);
  if (f > 512u) f = 512u;
  if (f < 128u) f = 128u;

  uint64_t e = (uint64_t)cam.exposure * gain_q8(cam.again) * f >> 8; /* lines, Q8 */
  uint32_t max_exp = cam.fll - IMX219_EXP_OFFSET;
  if (e <= (uint64_t)max_exp * 256u) {
    cam.exposure = (uint32_t)(e >> 8);
    if (cam.exposure == 0) cam.exposure = 1;
    cam.again = 0;
  } else {
    uint32_t g = (uint32_t)(e / max_exp); /* Q8 */
    if (g > 2048u) g = 2048u;              /* 8x */
    cam.exposure = max_exp;
    cam.again = 256u - 65536u / g;
  }
  sensor_apply_ctrl();
}

/* Gray world: make the mean R and B (of the unsaturated pixels) equal to G. */
static void awb_step(const bow_isp_stats_t *s) {
  if (s->cnt < 64 || s->sum_r == 0 || s->sum_b == 0) return;
  if (ISP->STATUS & ISP_ST_UPD_PENDING) return;
  uint32_t r = s->sum_r / s->cnt, g = s->sum_g / s->cnt, b = s->sum_b / s->cnt;
  uint32_t kr = (g * 256u) / (r ? r : 1u), kb = (g * 256u) / (b ? b : 1u);
  if (kr > 240u && kr < 272u && kb > 240u && kb < 272u) {
    if (!cam.awb_locked) {
      bow_printf("awb: locked r=%u b=%u\n", cam.wb_r, cam.wb_b);
      cam.awb_locked = true;
    }
    return;
  }
  cam.awb_locked = false;
  cam.wb_r = (cam.wb_r * kr) >> 8;
  cam.wb_b = (cam.wb_b * kb) >> 8;
  if (cam.wb_r < 128u) cam.wb_r = 128u;
  if (cam.wb_r > 1023u) cam.wb_r = 1023u;
  if (cam.wb_b < 128u) cam.wb_b = 128u;
  if (cam.wb_b > 1023u) cam.wb_b = 1023u;
  ISP->WB[ISP_WB_R] = cam.wb_r;
  ISP->WB[ISP_WB_B] = cam.wb_b;
  ISP->UPDATE = 1; /* applied between two frames, no need to wait */
}

static void frame_done(void) {
  cam.frames++;
  if (!(cam.ae && cam.cam) && !cam.awb) return;
  if (cam.frames % CTRL_PERIOD) return;
  bow_isp_stats_t s;
  bow_isp_read_stats(&s);
  if (cam.ae && cam.cam) ae_step(&s);
  if (cam.awb) awb_step(&s);
}

/* ------------------------------------------------------------- statistics */
static void print_stats(void) {
  if (!bow_isp_wait_frame(500)) {
    uint32_t st = ISP->STATUS, in = ISP->IN_SIZE;
    bow_printf("error: no frame (STATUS %02x, input %ux%u)\n", st, in & 0xFFFu, in >> 16);
    return;
  }
  bow_isp_stats_t s;
  bow_isp_read_stats(&s);
  uint32_t in = ISP->IN_SIZE, n = s.cnt ? s.cnt : 1u;
  bow_printf("frame %u in %ux%u  mean R/G/B %u/%u/%u (%u px)  Y %u  af %u  dpc %u\n", s.frame,
             in & 0xFFFu, in >> 16, s.sum_r / n, s.sum_g / n, s.sum_b / n, s.cnt,
             s.npix ? s.sum_y / s.npix : 0, s.af, s.dpc);
  bow_puts("hist (Y/64, 0..1023):");
  for (int i = 0; i < 16; i++) {
    uint32_t sum = ISP->HIST[4 * i] + ISP->HIST[4 * i + 1] + ISP->HIST[4 * i + 2] + ISP->HIST[4 * i + 3];
    bow_printf(" %u", s.npix ? (sum * 100u + s.npix / 2) / s.npix : 0);
  }
  bow_puts(" %\n");
}

static void focus(void) {
  bow_printf("sharpness per frame, press a key to stop\n");
  uint32_t best = 0;
  while (bow_uart_getc_nb(UART0) < 0) {
    if (!bow_isp_wait_frame(500)) break;
    bow_isp_stats_t s;
    bow_isp_read_stats(&s);
    if (s.af > best) best = s.af;
    bow_printf("af %u  (best %u)\n", s.af, best);
  }
}

/* ---------------------------------------------------------------- capture */
static bool capture(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t sc) {
  uint32_t bufwords = (ISP->INFO >> 16) * 1024u;
  if (w == 0 || h == 0 || sc > 3 || w * h > bufwords || (sc && w > 1024) ||
      x + (w << sc) > cam.w || y + (h << sc) > cam.h) {
    bow_printf("error: region outside the frame or larger than the buffer (%u words)\n", bufwords);
    return false;
  }
  if (!bow_isp_capture(x, y, w, h, sc, 1000)) {
    bow_printf("error: capture timeout (is the ISP running?)\n");
    return false;
  }
  cam.cap_w = w;
  cam.cap_h = h;
  bow_printf("captured %ux%u (scale %u)\n", w, h, sc);
  return true;
}

/* Whole frame with the smallest box filter that fits the buffer. */
static bool capture_auto(void) {
  uint32_t bufwords = (ISP->INFO >> 16) * 1024u;
  uint32_t sc = 0;
  while (sc < 3 && (cam.w >> sc) * (cam.h >> sc) > bufwords) sc++;
  return capture(0, 0, cam.w >> sc, cam.h >> sc, sc);
}

/* Image transfer: "IMG <w> <h> rgb|yuv <bytes> <crc32>" line, raw bytes
 * (3 per pixel, row by row: R G B or Y U V), then "END". */
static void dump(void) {
  uint32_t n = cam.cap_w * cam.cap_h;
  if (n == 0) {
    bow_printf("error: nothing captured\n");
    return;
  }
  uint32_t crc = 0;
  for (uint32_t i = 0; i < n; i++) {
    uint32_t v = ISP_BUF[i];
    uint8_t b[3] = {(uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    crc = bow_crc32_update(crc, b, 3);
  }
  bow_printf("IMG %u %u %s %u %08x\n", cam.cap_w, cam.cap_h, cam.yuv ? "yuv" : "rgb", 3u * n, crc);
  for (uint32_t i = 0; i < n; i++) {
    uint32_t v = ISP_BUF[i];
    bow_uart_putc(UART0, (char)(v >> 16));
    bow_uart_putc(UART0, (char)(v >> 8));
    bow_uart_putc(UART0, (char)v);
  }
  bow_printf("\nEND\n");
}

/* ------------------------------------------------------------------- info */
static void info(void) {
  uint32_t in = ISP->IN_SIZE, sz = ISP->SIZE;
  bow_printf("ISP    id %08x ctrl %x status %02x frames %u size %ux%u input %ux%u modules %02x\n",
             ISP->ID, ISP->CTRL, ISP->STATUS, ISP->FRAME_CNT, sz & 0xFFFu, (sz >> 16) & 0xFFFu,
             in & 0xFFFu, in >> 16, ISP->MODULES);
  bow_printf("mode   %ux%u, frame length %u lines = %u fps\n", cam.w, cam.h, cam.fll,
             IMX219_PIXEL_RATE / (IMX219_LLP * cam.fll));
  bow_printf("sensor %s  exp %u gain %u  tp %u  flip %u/%u\n", cam.sensor ? "IMX219" : "none",
             cam.exposure, cam.again, cam.tp, cam.hflip, cam.vflip);
  bow_printf("ae %s (target %u)  awb %s (r %u b %u)  source %s\n", cam.ae ? "on" : "off",
             cam.ae_target, cam.awb ? "on" : "off", cam.wb_r, cam.wb_b,
             cam.cam ? "camera" : cam.tpg ? "tpg" : "none");
  if (cam.csi) bow_csi2rx_print_status();
}

/* --------------------------------------------------------------- commands */
static bool set_mode(const char *s) {
  uint32_t w, h, fps = 30;
  if (word_is(s, "1080p")) {
    w = 1920, h = 1080;
  } else if (word_is(s, "720p")) {
    w = 1280, h = 720, fps = 60;
  } else {
    if (!(s = parse_num(s, &w, false)) || !(s = parse_num(s, &h, false))) return false;
    parse_num(s, &fps, false);
  }
  uint32_t maxw = ISP->INFO & 0xFFFFu;
  if (w < 16 || h < 8 || w > maxw || w > IMX219_ACTIVE_W || h > IMX219_ACTIVE_H || (w | h) & 1u) {
    bow_printf("error: size must be even, 16..%u x 8..%u\n", maxw, IMX219_ACTIVE_H);
    return false;
  }
  cam.w = w;
  cam.h = h;
  cam.fll = imx219_fll_for_fps(h, fps);
  bow_printf("mode %ux%u @%u fps (FLL %u)\n", w, h, IMX219_PIXEL_RATE / (IMX219_LLP * cam.fll),
             cam.fll);
  return restart();
}

static bool sensor_cmd(int r) {
  if (!cam.sensor) return true; /* takes effect at `cam` */
  if (r != I2C_OK) bow_printf("error: I2C %d\n", r);
  return r == I2C_OK;
}

static bool execute(const char *line) {
  const char *a;
  uint32_t v, v2, x, y, w, h, sc;

  if ((a = match(line, "h")) || (a = match(line, "help"))) {
    bow_puts(help);
    return true;
  }
  if ((a = match(line, "info"))) {
    info();
    return true;
  }
  if ((a = match(line, "cam"))) return start_cam();
  if ((a = match(line, "tpg"))) {
    v = 0;
    parse_num(a, &v, false);
    return start_tpg(v);
  }
  if ((a = match(line, "stop"))) {
    stop_all();
    return true;
  }
  if ((a = match(line, "mode"))) return set_mode(a);
  if ((a = match(line, "tp"))) {
    if (!parse_num(a, &v, false)) return false;
    cam.tp = v;
    return sensor_cmd(cam.sensor ? imx219_set_test_pattern(v) : I2C_OK);
  }
  if ((a = match(line, "exp"))) {
    if (!parse_num(a, &v, false) || v == 0) return false;
    cam.ae = false;
    cam.exposure = v > cam.fll - IMX219_EXP_OFFSET ? cam.fll - IMX219_EXP_OFFSET : v;
    return sensor_cmd(cam.sensor ? imx219_set_exposure(cam.exposure) : I2C_OK);
  }
  if ((a = match(line, "gain"))) {
    if (!parse_num(a, &v, false)) return false;
    cam.ae = false;
    cam.again = v > IMX219_AGAIN_MAX ? IMX219_AGAIN_MAX : v;
    return sensor_cmd(cam.sensor ? imx219_set_analog_gain(cam.again) : I2C_OK);
  }
  if ((a = match(line, "flip"))) {
    if (!(a = parse_num(a, &v, false)) || !parse_num(a, &v2, false)) return false;
    cam.hflip = v != 0;
    cam.vflip = v2 != 0;
    if (cam.sensor && imx219_set_orientation(cam.hflip, cam.vflip) != I2C_OK) return false;
    if (cam.cam) {
      ISP->BAYER = imx219_bayer(cam.hflip, cam.vflip);
      bow_isp_update(100);
    }
    return true;
  }
  if ((a = match(line, "sr"))) {
    uint8_t b;
    if (!(a = parse_num(a, &v, true))) return false;
    if (parse_num(a, &v2, true)) return sensor_cmd(imx219_write((uint16_t)v, (uint8_t)v2));
    if (imx219_read((uint16_t)v, &b) != I2C_OK) return false;
    bow_printf("sensor[%04x] = %02x\n", v, b);
    return true;
  }
  if ((a = match(line, "ae"))) {
    if (word_is(a, "on")) {
      cam.ae = true;
    } else if (word_is(a, "off")) {
      cam.ae = false;
    } else if (parse_num(a, &v, false) && v > 0 && v < 1024) {
      cam.ae_target = v;
      cam.ae = true;
    } else {
      return false;
    }
    cam.ae_locked = false;
    return true;
  }
  if ((a = match(line, "awb"))) {
    if (word_is(a, "on")) {
      cam.awb = true;
    } else if (word_is(a, "off")) {
      cam.awb = false;
    } else {
      return false;
    }
    cam.awb_locked = false;
    return true;
  }
  if ((a = match(line, "wb"))) {
    if (!(a = parse_num(a, &v, false)) || !parse_num(a, &v2, false)) return false;
    cam.awb = false;
    cam.wb_r = v;
    cam.wb_b = v2;
    ISP->WB[ISP_WB_R] = v;
    ISP->WB[ISP_WB_B] = v2;
    return bow_isp_update(100);
  }
  if ((a = match(line, "mod"))) {
    if (!parse_num(a, &v, true)) return false;
    cam.modules = v & ISP_MOD_ALL;
    cam.yuv = (v & ISP_MOD_CSC) != 0;
    bow_isp_set_yuv(cam.yuv);
    ISP->MODULES = cam.modules;
    return bow_isp_update(100);
  }
  if ((a = match(line, "fmt"))) {
    if (word_is(a, "rgb")) {
      cam.yuv = false;
    } else if (word_is(a, "yuv")) {
      cam.yuv = true;
    } else {
      return false;
    }
    bow_isp_set_yuv(cam.yuv);
    cam.modules = ISP->MODULES;
    return bow_isp_update(100);
  }
  if ((a = match(line, "stat"))) {
    print_stats();
    return true;
  }
  if ((a = match(line, "focus"))) {
    focus();
    return true;
  }
  if ((a = match(line, "cap"))) {
    if (!(a = parse_num(a, &x, false))) return capture_auto();
    if (!(a = parse_num(a, &y, false)) || !(a = parse_num(a, &w, false)) ||
        !(a = parse_num(a, &h, false)) || !parse_num(a, &sc, false))
      return false;
    return capture(x, y, w, h, sc);
  }
  if ((a = match(line, "dump"))) {
    dump();
    return true;
  }
  if ((a = match(line, "snap"))) {
    if (!capture_auto()) return false;
    dump();
    return true;
  }
  if ((a = match(line, "csi"))) {
    if (!cam.csi) {
      bow_printf("no CSI-2 receiver in this bitstream\n");
      return true;
    }
    bow_csi2rx_print_status();
    return true;
  }
  if ((a = match(line, "cal"))) {
    if (!cam.cam) {
      bow_printf("error: the camera is not streaming (cam)\n");
      return false;
    }
    v = 16;
    parse_num(a, &v, false);
    if (v == 0 || v > 256) return false;
    return calibrate(v, true);
  }
  if ((a = match(line, "csilog"))) {
    static uint32_t entries[CSI2RX_LOG_ENTRIES];
    if (!cam.phy) {
      bow_printf("error: this bitstream has no D-PHY\n");
      return false;
    }
    uint32_t mode = 0;
    if (word_is(a, "fs")) mode = CSI2RX_LOG_TRIG_FS;
    if (word_is(a, "fe")) mode = CSI2RX_LOG_STOP_FE;
    uint32_t n = bow_csi2rx_log(entries, mode, 3u * frame_ms() + 100u);
    if (n == 0) {
      bow_printf("error: no packets (is the camera streaming?)\n");
      return false;
    }
    bow_csi2rx_print_log(entries, n);
    return true;
  }
  if ((a = match(line, "baud"))) {
    if (!parse_num(a, &v, false) || v < 1200) return false;
    bow_printf("ok, switching to %u baud\n", v);
    bow_uart_flush(UART0);
    bow_uart_init(UART0, v);
    bow_delay_ms(100); /* time for the PC to switch too */
    return true;
  }
  if ((a = match(line, "rd"))) {
    if (!parse_num(a, &v, true)) return false;
    if (!bow_probe_read32(v & ~3u, &v2)) {
      bow_printf("%08x: bus error\n", v & ~3u);
      return false;
    }
    bow_printf("%08x: %08x\n", v & ~3u, v2);
    return true;
  }
  if ((a = match(line, "wr"))) {
    if (!(a = parse_num(a, &v, true)) || !parse_num(a, &v2, true)) return false;
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
  uint32_t lanes;
  bool phy;

  bow_i2c_init(I2C0, 400000);
  int r = imx219_probe(&id);
  cam.sensor = (r == I2C_OK && id == IMX219_CHIP_ID);
  if (cam.sensor) {
    bow_printf("camera: IMX219 found (id %04x)\n", id);
  } else if (r == I2C_OK) {
    bow_printf("camera: unknown sensor id %04x\n", id);
  } else {
    bow_printf("camera: no IMX219 on I2C (error %d)\n", r);
  }

  cam.csi = bow_csi2rx_probe(&lanes, &phy);
  cam.phy = cam.csi && phy;
  if (cam.phy) {
    bow_printf("csi2rx: Bow32 receiver, %u lanes, PHY clock %u MHz\n", lanes,
               CSI2RX_INFO_MHZ(CSI2RX->INFO));
  } else if (cam.csi) {
    bow_printf("csi2rx: Bow32 receiver, no D-PHY in this bitstream - ISP test pattern only\n");
  } else {
    bow_printf("csi2rx: not present - ISP test pattern only\n");
  }

  if (ISP->ID != ISP_ID_VALUE) bow_printf("ISP: unexpected id %08x\n", ISP->ID);
}

int main(void) {
  static char line[48];
  unsigned len = 0;
  int prev = 0;

  bow_uart_init(UART0, SYSCTRL->BOOT_BAUD);
  bow_printf("\nBow32 camera demo (ISP + IMX219), type h for help\n");
  probe_hardware();

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

    if (ISP->STATUS & ISP_ST_FRAME_DONE) {
      ISP->STATUS = ISP_ST_FRAME_DONE;
      frame_done();
    }
  }
}
