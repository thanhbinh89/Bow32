/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Video demo: camera sensor (IMX219 on the KV260, IMX274 on the Huins
 * MFP-VP1902, sw/common/include/cam_sensor.h) -> Bow32 MIPI CSI-2 receiver
 * -> ISP (YUV, BT.709 video range) -> H.264 encoder -> DMA -> video RAM
 * -> UART0 -> tools/bow32_video.py (.h264 + .mp4). Shell on UART0, `h` for
 * help.
 *
 *   rec <frames> [skip] [kbytes]  records into the 1 MiB video RAM: SPS + PPS,
 *                                 then one IDR frame per coded frame; a
 *                                 rate control (bow_h264.h) aims every frame
 *                                 at the free space over the frames still
 *                                 to code (at most kbytes), so that all of
 *                                 them fit (1080p: 30 frames)
 *   send                          sends the recording:
 *     H264 <bytes> <crc32> <frames> <width> <height> <fps_num> <fps_den>\r\n
 *     <bytes raw bytes>\r\nEND
 *
 * Works on both KV260 builds (kv260: ISP test pattern only) and on the Huins
 * camera build. The camera set-up (eye calibration, AE, gray world AWB) is
 * the one of sw/apps/camera; the IMX274 runs with the longer lines the
 * encoder needs, ~79 % encoder load as the IMX219 on the KV260 (1080p30:
 * HMAX 672, 720p30: 448; at higher frame rates up to ~100 %, imx274.h).
 */
#include "bow32.h"
#include "cam_sensor.h"

/* `h`: source line of the sensor, help_src, tp line of the sensor, help_enc */
static const char help_cam219[] =
    "source:\n"
    "  cam                 stream from the IMX219 (kv260_cam build)\n";
static const char help_cam274[] =
    "source:\n"
    "  cam                 stream from the IMX274 (Huins camera build)\n";
static const char help_src[] =
    "  tpg [0..3]          ISP test pattern: 0 bars 1 ramp 2 checker 3 solid (+4 moving)\n"
    "  stop                stop the source\n"
    "  mode 1080p|720p|<w> <h> [fps]   frame size (default 720p, 30 fps)\n"
    "  ae on|off|<target>  auto exposure     awb on|off   gray world white balance\n";
static const char help_tp219[] =
    "  tp <n>              sensor test pattern (0 off, 2 colour bars)\n";
static const char help_tp274[] =
    "  tp <n>              sensor test pattern (0 off, 11 colour bars)\n";
static const char help_enc[] =
    "encoder:\n"
    "  qp <10..51>|auto    first QP of a recording (default auto: from the size per\n"
    "                      frame and the frame size)\n"
    "  deblock on|off      deblocking filter in the decoder (default on)\n"
    "  rec <n> [skip] [kbytes]   record n frames, skip frames between two, size per frame\n"
    "  send                send the recording (tools/bow32_video.py)\n"
    "  stat                encoder and DMA status\n"
    "  dmatest             DMA memory to memory copies (SRAM <-> video RAM)\n"
    "misc:\n"
    "  info  baud <rate>  rd <addr>  wr <addr> <val>\n";

/* The colour matrix comes from the sensor table (s3.8, rows sum to 1.0). */
static const int16_t ccm_off0[3] = {0, 0, 0};
/* BT.709 video range: Y 16..235, Cb/Cr 16..240 (the SPS says so) */
static const int16_t csc709v[9] = {47, 157, 16, -26, -86, 112, 112, -102, -10};
static const int16_t csc709v_off[3] = {16, 128, 128};

#define CTRL_PERIOD 3 /* frames between AE/AWB steps (sensor latency) */

/* video RAM: SPS/PPS, then the frames */
#define VRAM ((uint8_t *)BOW32_VRAM_BASE)

/* the sensor found at start-up (none: the IMX219 table, for its formulas) */
static const cam_sensor_t *sen = &cam_imx219;

static struct {
  uint32_t w, h, fps;
  bool sensor, csi, phy, calibrated;
  uint32_t lanes;
  bool cam, tpg, hflip, vflip;
  uint32_t tp, exposure, again;
  bool ae, awb, ae_locked, awb_locked;
  uint32_t ae_target, wb_r, wb_b, frames;
  uint32_t tpg_fps;            /* measured frame rate of the test pattern */
  uint32_t qp;                 /* first QP of a recording, 0: auto (bow_h264_rc_init) */
  bool deblock;
  /* last recording */
  uint32_t rec_bytes, rec_frames, fps_num, fps_den;
} st = {
    .w = 1280, .h = 720, .fps = 30,
    .exposure = 1000, .ae = true, .awb = true, .ae_target = 180, .wb_r = 256, .wb_b = 256,
    .qp = 0, .deblock = true,
};

/* ------------------------------------------------------------------ parsing */
static const char *skip_spaces(const char *s) {
  while (*s == ' ') s++;
  return s;
}

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

static bool word_is(const char *s, const char *w) {
  s = skip_spaces(s);
  while (*w && *s == *w) s++, w++;
  return *w == '\0' && (*s == '\0' || *s == ' ');
}

static const char *match(const char *line, const char *cmd) {
  const char *s = line;
  while (*cmd && *s == *cmd) s++, cmd++;
  if (*cmd != '\0' || (*s != '\0' && *s != ' ')) return NULL;
  return s;
}

/* ------------------------------------------------------------- the source */
static void isp_setup(uint32_t bayer) {
  bow_isp_init(st.w, st.h, bayer);
  if (sen->black_level != ISP->BLC) ISP->BLC = sen->black_level; /* init: 64 */
  bow_isp_set_ccm(sen->ccm, ccm_off0);
  for (int i = 0; i < 9; i++) ISP->CSC[i] = (uint32_t)(int32_t)csc709v[i] & 0xFFFu;
  for (int i = 0; i < 3; i++) ISP->CSC_OFF[i] = (uint32_t)(int32_t)csc709v_off[i] & 0x1FFu;
  ISP->MODULES = ISP_MOD_ALL; /* BLC DPC WB CCM gamma CSC: YUV output */
  ISP->WB[ISP_WB_R] = st.wb_r;
  ISP->WB[ISP_WB_B] = st.wb_b;
}

static uint32_t frame_ms(void) { return cam_frame_us(sen) / 1000u + 1u; }

/* Timeout of one tap (calibration, margin check): 1.2 frames + 3 ms */
static uint32_t tap_ms(void) { return cam_frame_us(sen) * 12u / 10000u + 3u; }

static void stop_all(void) {
  /* the IMX219 finishes its frame, the IMX274 is stopped after a frame end */
  if (st.cam) cam_stream_stop(st.sensor ? sen : NULL, frame_ms() + 10u);
  ISP->CTRL = 0;
  st.cam = st.tpg = false;
}

/* Frame rate of the ISP output, from the time of 4 frames. */
static uint32_t measure_fps(void) {
  if (!bow_isp_wait_frame(1000)) return 0;
  uint32_t t0 = bow_cycles();
  for (int i = 0; i < 4; i++) {
    if (!bow_isp_wait_frame(1000)) return 0;
  }
  uint32_t dt = bow_cycles() - t0;
  return dt ? (4u * bow_clk_hz() + dt / 2u) / dt : 0;
}

static bool start_tpg(uint32_t pattern) {
  stop_all();
  isp_setup(ISP_BAYER_RGGB);
  ISP->TPG_CTRL = (pattern & 3u) | ((pattern & 4u) ? 0x10u : 0u);
  /* line blanking = width: the encoder needs ~25 cycles per pixel column of
   * a strip of 16 lines, the TPG must not send lines faster than a camera */
  ISP->TPG_BLANK = (32u << 16) | (st.w > 256u ? st.w : 256u);
  if (!bow_isp_update(100)) {
    bow_printf("error: ISP does not take the configuration (no video clock?)\n");
    return false;
  }
  ISP->STATUS = 0xFF;
  ISP->CTRL = ISP_CTRL_EN | ISP_CTRL_SRC_TPG;
  st.tpg = true;
  st.frames = 0;
  st.tpg_fps = measure_fps();
  bow_printf("tpg %u %ux%u, %u fps\n", pattern & 7u, st.w, st.h, st.tpg_fps);
  return true;
}

static int sensor_apply_ctrl(void) {
  int r = sen->set_exposure(st.exposure);
  if (r == I2C_OK) r = sen->set_gain(st.again);
  return r;
}

/* Eye calibration, then a short margin check (8 frames per point, k = eye /
 * 4): a low margin is reported, the calibrated taps stay. */
static bool calibrate(void) {
  bow_csi2rx_cal_t cal;
  bow_csi2rx_margin_t m;
  if (!bow_csi2rx_calibrate(16, tap_ms(), &cal, false)) {
    bow_printf("csi2rx: calibration failed\n");
    return false;
  }
  bow_puts("csi2rx: calibrated ");
  bow_csi2rx_print_cal(&cal);
  bow_puts("\n");
  st.calibrated = true;
  int r = bow_csi2rx_margin(&cal, 0, 8, tap_ms(), &m, false);
  bow_printf("csi2rx: margin %s", r > 0 ? "ok " : r == 0 ? "low " : "");
  bow_csi2rx_print_margin(&m, r);
  bow_puts("\n");
  return true;
}

/* Calibrate at the first start (calibrated: the taps are to be checked
 * first); later, when the link check with the kept taps fails with errors a
 * new tap can fix (ERR_STATUS &
 * CSI2RX_ERR_TAP), or with no error at all: fewer than 64 packets in 2 x
 * tap_ms() (2.4 frames + 6 ms: the first frame start is up to a frame away,
 * 64 packets take at most ~1.3 frames; + the frames the sensor does not
 * output after its start, IMX274), so no data or a very slow link; without
 * a byte clock the calibration fails cleanly. Other link errors (EXTRA,
 * FORMAT, FRAME, OVF) are not a sampling problem: the taps are kept. */
static bool need_calibration(bool calibrated) {
  if (!calibrated) return true;
  uint32_t ms = 2u * tap_ms() + sen->start_frames * frame_ms();
  if (bow_csi2rx_link_check(64, ms)) return false;
  bow_csi2rx_cnt_t c;
  bow_csi2rx_counters(&c);
  uint32_t err = CSI2RX->ERR_STATUS;
  if (bow_csi2rx_link_errors(&c) == 0) {
    bow_printf("csi2rx: %u packets in %u ms, no link error: calibrating\n", c.packets, ms);
    return true;
  }
  if (err & CSI2RX_ERR_TAP) return true;
  bow_printf("csi2rx: link errors (ERR_STATUS %03x), not a sampling problem: taps kept\n", err);
  return false;
}

static bool start_cam(void) {
  if (!st.sensor) {
    bow_printf("error: no %s (check the ribbon cable)\n", sen->name);
    return false;
  }
  if (!st.phy) {
    bow_printf("error: this bitstream has no D-PHY, use the %s build\n", sen->build);
    return false;
  }
  if (st.lanes < sen->lanes) {
    bow_printf("error: the %s needs %u lanes, the receiver has %u\n", sen->name, sen->lanes,
               st.lanes);
    return false;
  }
  stop_all();
  isp_setup(sen->bayer(st.hflip, st.vflip));
  if (!bow_isp_update(100)) {
    bow_printf("error: ISP does not take the configuration (no video clock?)\n");
    return false;
  }
  if (cam_rx_start(sen, sen->dt()) != CSI2RX_OK) {
    bow_printf("error: D-PHY not ready (CSI2RX STATUS.PHY_RDY = 0)\n");
    return false;
  }
  uint32_t max_exp = sen->exposure_max();
  if (st.exposure > max_exp) st.exposure = max_exp;
  int r = sen->configure();
  if (r == I2C_OK) r = sen->set_flip(st.hflip, st.vflip);
  if (r == I2C_OK) r = sen->set_test_pattern(st.tp);
  if (r == I2C_OK) r = sensor_apply_ctrl();
  if (r == I2C_OK) {
    ISP->STATUS = 0xFF;
    ISP->CTRL = ISP_CTRL_EN;
    r = sen->start();
  }
  if (r != I2C_OK) {
    bow_printf("error: I2C %d while programming the sensor\n", r);
    ISP->CTRL = 0;
    CSI2RX->CTRL = 0;
    return false;
  }
  st.cam = true;
  st.frames = 0;
  st.ae_locked = st.awb_locked = false;
  /* as sw/apps/camera: the first start calibrates, also with the Versal
   * XPHY, whose self-calibration (BISC) leaves the lanes at the early edge
   * of their eyes on the Huins board */
  if (need_calibration(st.calibrated)) {
    if (!calibrate()) return false;
    bow_csi2rx_wait_frame(2u * frame_ms());
    ISP->STATUS = ISP_ST_ERRORS;
  }
  bow_printf("streaming %ux%u @%u fps\n", st.w, st.h, cam_fps(sen));
  return true;
}

/* --------------------------------------------------------- AE / AWB loops */
static void ae_step(const bow_isp_stats_t *s) {
  if (s->npix == 0) return;
  uint32_t mean = s->sum_y / s->npix, t = st.ae_target;
  if (mean * 16u > t * 15u && mean * 16u < t * 17u) {
    if (!st.ae_locked) bow_printf("ae: locked exp=%u gain=%u\n", st.exposure, st.again);
    st.ae_locked = true;
    return;
  }
  st.ae_locked = false;
  uint32_t f = (t * 256u) / (mean ? mean : 1u);
  if (f > 512u) f = 512u;
  if (f < 128u) f = 128u;
  uint64_t e = (uint64_t)st.exposure * sen->gain_q8(st.again) * f >> 8;
  uint32_t max_exp = sen->exposure_max();
  if (e <= (uint64_t)max_exp * 256u) {
    st.exposure = (uint32_t)(e >> 8);
    if (st.exposure == 0) st.exposure = 1;
    st.again = 0;
  } else {
    uint32_t g = (uint32_t)(e / max_exp);
    if (g > 2048u) g = 2048u;
    st.exposure = max_exp;
    st.again = sen->gain_code(g);
  }
  sensor_apply_ctrl();
}

static void awb_step(const bow_isp_stats_t *s) {
  if (s->cnt < 64 || s->sum_r == 0 || s->sum_b == 0) return;
  if (ISP->STATUS & ISP_ST_UPD_PENDING) return;
  uint32_t r = s->sum_r / s->cnt, g = s->sum_g / s->cnt, b = s->sum_b / s->cnt;
  uint32_t kr = (g * 256u) / (r ? r : 1u), kb = (g * 256u) / (b ? b : 1u);
  if (kr > 240u && kr < 272u && kb > 240u && kb < 272u) {
    if (!st.awb_locked) bow_printf("awb: locked r=%u b=%u\n", st.wb_r, st.wb_b);
    st.awb_locked = true;
    return;
  }
  st.awb_locked = false;
  st.wb_r = (st.wb_r * kr) >> 8;
  st.wb_b = (st.wb_b * kb) >> 8;
  if (st.wb_r < 128u) st.wb_r = 128u;
  if (st.wb_r > 1023u) st.wb_r = 1023u;
  if (st.wb_b < 128u) st.wb_b = 128u;
  if (st.wb_b > 1023u) st.wb_b = 1023u;
  ISP->WB[ISP_WB_R] = st.wb_r;
  ISP->WB[ISP_WB_B] = st.wb_b;
  ISP->UPDATE = 1;
}

/* Called for every ISP frame (main loop and recording). */
static void isp_frame_poll(void) {
  if (!(ISP->STATUS & ISP_ST_FRAME_DONE)) return;
  ISP->STATUS = ISP_ST_FRAME_DONE;
  st.frames++;
  /* a sensor test pattern follows neither exposure, gain nor white balance:
   * AE / AWB wait until it is off (as sw/apps/camera) */
  if (st.cam && st.tp != 0) return;
  if (!(st.ae && st.cam) && !st.awb) return;
  if (st.frames % CTRL_PERIOD) return;
  bow_isp_stats_t s;
  bow_isp_read_stats(&s);
  if (st.ae && st.cam) ae_step(&s);
  if (st.awb && (st.cam || st.tpg)) awb_step(&s);
}

/* -------------------------------------------------------------- recording */
/* Frame rate written into the SPS: the camera rate; the test pattern has
 * no real one (hundreds of fps), its video plays at 30 fps. */
static uint32_t source_fps(void) {
  uint32_t f = sen->frame_clks();
  if (st.cam && f) return (sen->timing_hz + f / 2u) / f;
  return 30u;
}

/* The encoder output drains into nothing: the recording keeps the frames
 * written up to then. Waits until the encoder is idle. */
static bool drain_encoder(uint32_t timeout_ms) {
  uint32_t start = bow_cycles(), limit = timeout_ms * (bow_clk_hz() / 1000u);
  bow_h264_stop();
  DMA->CH[0].CTRL = DMA_CTRL_EN | DMA_CTRL_S2M | DMA_CTRL_DROP;
  while (H264->STATUS & H264_ST_BUSY) {
    isp_frame_poll();
    if ((uint32_t)(bow_cycles() - start) > limit) return false;
  }
  return true;
}

static bool record(uint32_t n, uint32_t skip, uint32_t kbytes) {
  if (!st.cam && !st.tpg) {
    bow_printf("error: start the camera (cam) or the test pattern (tpg) first\n");
    return false;
  }
  if (H264->ID != H264_ID_VALUE) {
    bow_printf("error: no H.264 encoder in this bitstream\n");
    return false;
  }
  if (st.w > (H264->INFO & 0xFFFFu) || (st.w & 15u)) {
    bow_printf("error: the width must be a multiple of 16, at most %u\n", H264->INFO & 0xFFFFu);
    return false;
  }
  uint32_t fps = source_fps();
  bow_h264_params_t p = {
      .width = st.w, .height = st.h, .fps_num = fps, .fps_den = skip + 1u, .full_range = false};
  uint32_t hdr = bow_h264_write_headers(VRAM, 256, &p);
  uint32_t space = BOW32_VRAM_SIZE - hdr;
  uint32_t qmin = 99, qmax = 0, ovf = 0, big = 0, coded = 0;
  /* rate control (bow_h264.h): every frame aims at the free space over the
   * frames still to code (at most kbytes), the QP follows each frame by
   * 6 x log2(size / target); the first QP from the mode (qp auto) or `qp` */
  bow_h264_rc_t rc;
  bow_h264_rc_init(&rc, st.w, st.h, space, n, kbytes * 1024u, st.qp);

  bow_dma_stream(0, VRAM + hdr, space, false);
  bow_h264_init(st.w, st.h, rc.qp, st.deblock);
  bow_h264_start(n, skip);
  bow_printf("rec: %u frames %ux%u, %u/%u fps, QP %u%s, %u bytes per frame\n", n, st.w, st.h, fps,
             skip + 1u, rc.qp, st.qp ? "" : " (auto)", rc.target);

  uint32_t last = bow_cycles(), tmo = 3u * bow_clk_hz();
  uint32_t vid_mhz = st.csi ? CSI2RX_INFO_MHZ(CSI2RX->INFO) : 0;   /* video clock */
  bool ok = true, full = false, done = false;
  if (vid_mhz == 0) vid_mhz = bow_clk_hz() / 1000000u;
  while (!done) {
    isp_frame_poll();
    uint32_t s = H264->STATUS, cnt = H264->FRAME_CNT;
    done = (s & H264_ST_DONE) != 0;
    if (cnt != coded) {
      /* FRAME_BYTES is the size of the newest frame, TOTAL_BYTES the sum of
       * the coded ones; the QP of a frame is the one written before its
       * start (one frame of delay: the vertical blanking, or the skipped
       * frames, leave the time) */
      uint32_t bytes = H264->FRAME_BYTES, total = H264->TOTAL_BYTES, used = rc.qp;
      coded = cnt;
      if (bytes > big) big = bytes;
      if (used < qmin) qmin = used;
      if (used > qmax) qmax = used;
      bool fits = bow_h264_rc_frame(&rc, coded, bytes, total);
      bow_h264_set_qp(rc.qp);
      /* stop before the video RAM is full: the next frame would not fit */
      if (!fits && !full) {
        bow_h264_stop();
        full = true;
      }
      bow_printf("frame %u: %u bytes, QP %u, %u us\n", coded, bytes, used,
                 H264->FRAME_CYCLES / vid_mhz);
      last = bow_cycles();
    }
    if (s & H264_ST_ERR_OVF) {
      H264->STATUS = H264_ST_ERR_OVF;
      ovf++;
    }
    if ((DMA->CH[0].STATUS & DMA_ST_DONE) || (full && !(H264->STATUS & H264_ST_BUSY))) break;
    if (done) break;
    if ((uint32_t)(bow_cycles() - last) > tmo) {
      bow_printf("error: no frame from the encoder for 3 s (status %02x)\n", H264->STATUS);
      ok = false;
      break;
    }
  }
  /* the frames are in the video RAM once the encoder is idle and the DMA
   * has written all its packets */
  uint32_t start = bow_cycles();
  while ((H264->STATUS & H264_ST_BUSY) && !(DMA->CH[0].STATUS & DMA_ST_DONE) &&
         (uint32_t)(bow_cycles() - start) < bow_clk_hz()) {
    isp_frame_poll();
  }
  uint32_t frames = DMA->CH[0].PKT_CNT, end = DMA->CH[0].PKT_END;
  if (H264->STATUS & H264_ST_BUSY) {
    if (!drain_encoder(1000)) bow_printf("error: the encoder does not stop\n");
  }
  bow_dma_disable(0);
  H264->CTRL = 0;
  if (DMA->CH[0].STATUS & DMA_ST_ERR) {
    bow_printf("error: DMA bus error\n");
    ok = false;
  }
  st.rec_bytes = hdr + end;
  st.rec_frames = frames;
  st.fps_num = fps;
  st.fps_den = skip + 1u;
  bow_printf("rec: %u frames, %u bytes (QP %u..%u, largest %u)%s\n", frames, st.rec_bytes,
             qmin == 99 ? 0 : qmin, qmax, big, full ? ", video RAM full" : "");
  if (ovf || (H264->STATUS & H264_ST_ERR_OVF)) {
    if (st.cam && sen == &cam_imx274) {
      /* line length set by imx274_set_mode(): a lower frame rate only helps
       * above ~80 % (lines shorter than the 79 % ones) */
      uint32_t load = imx274_h264_load(st.w, imx274_mode()->hmax);
      bow_printf("warning: the encoder dropped pixels (H.264 load %u %%: %sraise qp or give rec "
                 "fewer kbytes per frame)\n", load,
                 load > 80u ? "lower the frame rate for longer lines, " : "");
    } else {
      bow_printf("warning: the encoder dropped pixels (lower the frame rate or the size)\n");
    }
  }
  return ok && frames != 0;
}

/* "H264 <bytes> <crc> <frames> <w> <h> <fps_num> <fps_den>", data, "END" */
static bool send(void) {
  if (st.rec_bytes == 0) {
    bow_printf("error: nothing recorded\n");
    return false;
  }
  uint32_t crc = bow_crc32_update(0, VRAM, st.rec_bytes);
  bow_printf("H264 %u %08x %u %u %u %u %u\n", st.rec_bytes, crc, st.rec_frames, st.w, st.h,
             st.fps_num, st.fps_den);
  bow_uart_write(UART0, VRAM, st.rec_bytes);
  bow_printf("\nEND\n");
  return true;
}

/* DMA channel 1: SRAM -> video RAM -> SRAM, compare. */
static bool dma_test(void) {
  static uint32_t a[64], b[64];
  uint32_t *v = (uint32_t *)(BOW32_VRAM_BASE + BOW32_VRAM_SIZE - sizeof a);
  for (unsigned i = 0; i < 64; i++) {
    a[i] = 0x9E3779B9u * (i + 1u) ^ bow_cycles();
    b[i] = 0;
  }
  bow_dma_copy(1, v, a, sizeof a);
  if (!bow_dma_wait(1, 100)) {
    bow_printf("error: copy to the video RAM failed (status %02x)\n", DMA->CH[1].STATUS);
    return false;
  }
  bow_dma_copy(1, b, v, sizeof b);
  if (!bow_dma_wait(1, 100)) {
    bow_printf("error: copy from the video RAM failed (status %02x)\n", DMA->CH[1].STATUS);
    return false;
  }
  for (unsigned i = 0; i < 64; i++) {
    if (b[i] != a[i] || v[i] != a[i]) {
      bow_printf("error: word %u: %08x -> %08x -> %08x\n", i, a[i], v[i], b[i]);
      return false;
    }
  }
  /* a bus error stops the channel: read from an unmapped address (0x7000_0000:
   * between the HyperRAM window at 0x6000_0000 and the DDR window at 0x8000_0000,
   * the crossbar's own decode error) */
  bow_dma_copy(1, b, (const void *)0x70000000u, 4);
  if (bow_dma_wait(1, 100) || !(DMA->CH[1].STATUS & DMA_ST_ERR)) {
    bow_printf("error: no DMA bus error from an unmapped address\n");
    return false;
  }
  DMA->CH[1].STATUS = DMA_ST_ERR;
  bow_printf("dma: 2 x 256 bytes copied, bus error detected\n");
  return true;
}

/* ------------------------------------------------------------------- info */
static void print_stat(void) {
  bow_printf("h264   id %08x ctrl %x status %02x size %ux%u qp %u frames %u bytes %u total %u\n",
             H264->ID, H264->CTRL, H264->STATUS, H264->SIZE & 0xFFFu, (H264->SIZE >> 16) & 0xFFFu,
             H264->QP, H264->FRAME_CNT, H264->FRAME_BYTES, H264->TOTAL_BYTES);
  bow_printf("       frame cycles %u, engine cycles %u, max width %u, %u strips\n",
             H264->FRAME_CYCLES, H264->MB_CYCLES, H264->INFO & 0xFFFFu, (H264->INFO >> 16) & 15u);
  bow_printf("dma    id %08x ch0 ctrl %x status %02x wptr %u packets %u end %u count %u\n",
             DMA->ID, DMA->CH[0].CTRL, DMA->CH[0].STATUS, DMA->CH[0].WPTR, DMA->CH[0].PKT_CNT,
             DMA->CH[0].PKT_END, DMA->CH[0].COUNT);
  bow_printf("isp    status %02x frames %u input %ux%u\n", ISP->STATUS, ISP->FRAME_CNT,
             ISP->IN_SIZE & 0xFFFu, ISP->IN_SIZE >> 16);
  bow_printf("record %u frames %u bytes %u/%u fps\n", st.rec_frames, st.rec_bytes, st.fps_num,
             st.fps_den);
}

static void info(void) {
  bow_printf("mode   %ux%u @%u fps (", st.w, st.h, st.fps);
  sen->print_timing(CAM_TIMING_LENGTH);
  bow_printf(")  source %s\n", st.cam ? "camera" : st.tpg ? "tpg" : "none");
  bow_printf("sensor %s  exp %u gain %u  ae %s awb %s (r %u b %u)\n",
             st.sensor ? sen->name : "none", st.exposure, st.again, st.ae ? "on" : "off",
             st.awb ? "on" : "off", st.wb_r, st.wb_b);
  if (st.qp) {
    bow_printf("encoder QP %u", st.qp);
  } else {
    bow_puts("encoder QP auto");
  }
  bow_printf(" deblock %s, video RAM %u KiB at %08x\n", st.deblock ? "on" : "off",
             BOW32_VRAM_SIZE / 1024u, BOW32_VRAM_BASE);
  if (st.csi) bow_csi2rx_print_status();
}

/* --------------------------------------------------------------- commands */
static bool set_mode(const char *s) {
  uint32_t w, h, fps = 30;
  if (word_is(s, "1080p")) {
    w = 1920, h = 1080;
  } else if (word_is(s, "720p")) {
    w = 1280, h = 720;
  } else {
    if (!(s = parse_num(s, &w, false)) || !(s = parse_num(s, &h, false))) return false;
  }
  if (s && !word_is(s, "1080p") && !word_is(s, "720p")) parse_num(s, &fps, false);
  if (w < 16 || h < 16 || (w & 15u) || (h & 1u) || w > (ISP->INFO & 0xFFFFu) || w > sen->max_w ||
      h > sen->max_h || fps == 0) {
    bow_printf("error: width multiple of 16, height even, at most %ux%u\n", ISP->INFO & 0xFFFFu,
               sen->max_h);
    return false;
  }
  /* video: the IMX274 lines are long enough for the encoder */
  if (sen->mode(w, h, fps, true) != I2C_OK) return false;
  st.w = w;
  st.h = h;
  st.fps = fps;
  bow_printf("mode %ux%u @%u fps (", w, h, cam_fps(sen));
  sen->print_timing(CAM_TIMING_SHORT);
  bow_puts(")\n");
  if (st.cam) return start_cam();
  if (st.tpg) return start_tpg(ISP->TPG_CTRL);
  return true;
}

static bool on_off(const char *a, bool *flag) {
  if (word_is(a, "on")) *flag = true;
  else if (word_is(a, "off")) *flag = false;
  else return false;
  return true;
}

static bool execute(const char *line) {
  const char *a;
  uint32_t v, v2;

  if ((a = match(line, "h")) || (a = match(line, "help"))) {
    bool i274 = sen == &cam_imx274;
    bow_puts(i274 ? help_cam274 : help_cam219);
    bow_puts(help_src);
    bow_puts(i274 ? help_tp274 : help_tp219);
    bow_puts(help_enc);
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
    if (sen == &cam_imx274 && v > sen->tp_max) return false;
    st.tp = v;
    return !st.sensor || sen->set_test_pattern(v) == I2C_OK;
  }
  if ((a = match(line, "ae"))) {
    if (parse_num(a, &v, false) && v > 0 && v < 1024) {
      st.ae_target = v;
      st.ae = true;
    } else if (!on_off(a, &st.ae)) {
      return false;
    }
    st.ae_locked = false;
    return true;
  }
  if ((a = match(line, "awb"))) {
    st.awb_locked = false;
    return on_off(a, &st.awb);
  }
  if ((a = match(line, "qp"))) {
    if (word_is(a, "auto")) {
      st.qp = 0;
      return true;
    }
    if (!parse_num(a, &v, false) || v < H264_QP_MIN || v > H264_QP_MAX) return false;
    st.qp = v;
    return true;
  }
  if ((a = match(line, "deblock"))) return on_off(a, &st.deblock);
  if ((a = match(line, "rec"))) {
    uint32_t skip = 0, kb = 0;
    if (!(a = parse_num(a, &v, false)) || v == 0 || v > 65535) return false;
    if ((a = parse_num(a, &skip, false))) parse_num(a, &kb, false);
    return record(v, skip, kb);
  }
  if ((a = match(line, "send"))) return send();
  if ((a = match(line, "dmatest"))) return dma_test();
  if ((a = match(line, "stat"))) {
    print_stat();
    return true;
  }
  if ((a = match(line, "baud"))) {
    if (!parse_num(a, &v, false) || v < 1200) return false;
    bow_printf("ok, switching to %u baud\n", v);
    bow_uart_flush(UART0);
    bow_uart_init(UART0, v);
    bow_delay_ms(100);
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
  cam_detect_t d;
  uint32_t lanes = 0;
  bool phy = false;

  bow_i2c_init(I2C0, 400000);
  cam_sensor_detect(&d);
  sen = d.sensor;
  st.sensor = d.found;
  if (st.sensor) {
    bow_printf("camera: %s found (id %04x)\n", sen->name, d.id);
  } else {
    cam_print_not_found(&d);
    bow_printf("camera: ISP test pattern only (tpg)\n");
  }
  /* frame format of the sensor layer: the default mode (720p30) */
  sen->mode(st.w, st.h, st.fps, true);
  st.wb_r = sen->wb_r;
  st.wb_b = sen->wb_b;

  st.csi = bow_csi2rx_probe(&lanes, &phy);
  st.phy = st.csi && phy;
  st.lanes = lanes;
  if (st.phy) {
    bow_printf("csi2rx: Bow32 receiver, %u lanes, PHY clock %u MHz\n", lanes,
               CSI2RX_INFO_MHZ(CSI2RX->INFO));
  }
  if (!st.sensor) cam_print_prsnt(lanes);
  if (H264->ID == H264_ID_VALUE && DMA->ID == DMA_ID_VALUE) {
    bow_printf("h264: Bow32 encoder, max width %u, %u strips; DMA %u channels; video RAM %u KiB\n",
               H264->INFO & 0xFFFFu, (H264->INFO >> 16) & 15u, DMA->INFO & 0xFFu,
               BOW32_VRAM_SIZE / 1024u);
  } else {
    bow_printf("h264: encoder / DMA not found (id %08x / %08x)\n", H264->ID, DMA->ID);
  }
}

int main(void) {
  static char line[48];
  unsigned len = 0;
  int prev = 0;

  bow_uart_init(UART0, SYSCTRL->BOOT_BAUD);
  bow_printf("\nBow32 video demo (camera -> ISP -> H.264 -> DMA), type h for help\n");
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
      bow_uart_putc(UART0, (char)c);
    }
    if (c >= 0) prev = c;
    isp_frame_poll();
  }
}
