/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Camera sensor layer (see cam_sensor.h): the operations tables of the
 * IMX219 and the IMX274, sensor detection, the receiver start with the PHY
 * setting of the board and the stream stop order.
 */
#include "cam_sensor.h"

#include "bow32.h"

/* Starting point for the colour matrix (s3.8, rows sum to 1.0), measured
 * for the IMX219; the IMX274 starts from it too until it has its own. */
static const int16_t ccm_default[9] = {461, -128, -77, -102, 461, -103, -38, -166, 460};

static uint32_t no_ob_lines(void) { return 0; }

/* ---------------------------------------------------------------- IMX219 */
static uint32_t i219_w = 1920u, i219_h = 1080u, i219_fll = 1763u;

/* RPI_ENABLE (PA7) */
static int i219_power(bool on) {
  if (on) {
    bow_gpio_set(GPIOA, GPIO_PIN(7));
    bow_gpio_output(GPIOA, GPIO_PIN(7));
    bow_delay_ms(10);
  } else {
    bow_gpio_clear(GPIOA, GPIO_PIN(7));
  }
  return I2C_OK;
}

static int i219_mode(uint32_t w, uint32_t h, uint32_t fps, bool video) {
  (void)video;
  if (w < 16 || h < 8 || w > IMX219_ACTIVE_W || h > IMX219_ACTIVE_H || ((w | h) & 1u)) {
    return IMX219_EINVAL;
  }
  i219_w = w;
  i219_h = h;
  i219_fll = imx219_fll_for_fps(h, fps);
  return I2C_OK;
}

static int i219_configure(void) { return imx219_configure(i219_w, i219_h, i219_fll); }
static int i219_start(void) { return imx219_stream(true); }
static int i219_stop(void) { return imx219_stream(false); }
static uint32_t i219_exposure_max(void) { return i219_fll - IMX219_EXP_OFFSET; }
static int i219_set_gain(uint32_t code) { return imx219_set_analog_gain(code); }
/* gain = 256 / (256 - code) */
static uint32_t i219_gain_q8(uint32_t code) { return 65536u / (256u - code); }
static uint32_t i219_gain_code(uint32_t q8) { return 256u - 65536u / (q8 < 256u ? 256u : q8); }
static uint32_t i219_dt(void) { return imx219_format() == 8 ? CSI2_DT_RAW8 : CSI2_DT_RAW10; }
static uint32_t i219_frame_clks(void) { return i219_fll * IMX219_LLP; }
static uint32_t i219_line_clks(void) { return IMX219_LLP; }

static void i219_print_timing(uint32_t form) {
  if (form == CAM_TIMING_SHORT) {
    bow_printf("FLL %u", i219_fll);
  } else {
    bow_printf(form == CAM_TIMING_LINES ? "frame length %u lines" : "frame length %u", i219_fll);
  }
}

const cam_sensor_t cam_imx219 = {
    .name = "IMX219",
    .build = "kv260_cam",
    .id = IMX219_CHIP_ID,
    .lanes = 2,
    .emb_lines = 2,
    .start_frames = 0,
    .tp_max = IMX219_TP_PN9,
    .tp_bars = IMX219_TP_BARS,
    .tp_solid = IMX219_TP_SOLID,
    .stop_cuts_frame = false,
    .has_hflip = true,
    .has_raw8 = true,
    .lane_rate_mbps = IMX219_LANE_RATE / 1000000u,
    .black_level = 64,
    .gain_max = IMX219_AGAIN_MAX,
    .max_w = IMX219_ACTIVE_W,
    .max_h = IMX219_ACTIVE_H,
    .wb_r = 256,
    .wb_b = 256,
    .timing_hz = IMX219_PIXEL_RATE,
    .ccm = ccm_default,
    .probe = imx219_probe,
    .power = i219_power,
    .mode = i219_mode,
    .configure = i219_configure,
    .start = i219_start,
    .stop = i219_stop,
    .set_exposure = imx219_set_exposure,
    .exposure_max = i219_exposure_max,
    .set_gain = i219_set_gain,
    .gain_q8 = i219_gain_q8,
    .gain_code = i219_gain_code,
    .set_flip = imx219_set_orientation,
    .bayer = imx219_bayer,
    .set_test_pattern = imx219_set_test_pattern,
    .dt = i219_dt,
    .frame_clks = i219_frame_clks,
    .line_clks = i219_line_clks,
    .ob_lines = no_ob_lines,
    .print_timing = i219_print_timing,
    .read = imx219_read,
    .write = imx219_write,
};

/* ---------------------------------------------------------------- IMX274 */
static int i274_mode(uint32_t w, uint32_t h, uint32_t fps, bool video) {
  int r = imx274_set_mode(w, h, fps, video);
  if (r != I2C_OK) {
    bow_printf("error: IMX274 window: width a multiple of 4 up to 1288, of 12 up to 3864; "
               "height even, up to 2174\n");
    return r;
  }
  const imx274_mode_t *m = imx274_mode();
  if (!m->legal) {
    bow_printf("note: %ux%u is below the IMX274 minimum window (simulation only)\n", w, h);
  }
  /* the frame rate leaves no room for the 79 % lines (imx274_set_mode) */
  uint32_t load = imx274_h264_load(w, m->hmax);
  if (video && load > 80u) {
    bow_printf("note: H.264 load %u %% (HMAX %u): detailed scenes at a low QP may drop pixels, "
               "a lower frame rate gives longer lines\n", load, m->hmax);
  }
  return r;
}

static int i274_start(void) { return imx274_stream(true); }
static int i274_stop(void) { return imx274_stream(false); }

/* gain = 2048 / (2048 - PGC) */
static uint32_t i274_gain_q8(uint32_t code) {
  return 524288u / (2048u - (code > IMX274_PGC_MAX ? IMX274_PGC_MAX : code));
}
static uint32_t i274_gain_code(uint32_t q8) {
  uint32_t c = 2048u - 524288u / (q8 < 256u ? 256u : q8);
  return c > IMX274_PGC_MAX ? IMX274_PGC_MAX : c;
}

static uint32_t i274_bayer(bool hflip, bool vflip) {
  (void)hflip;
  return imx274_bayer(vflip);
}

static uint32_t i274_dt(void) { return CSI2_DT_RAW10; }

static uint32_t i274_frame_clks(void) {
  const imx274_mode_t *m = imx274_mode();
  uint64_t c = (uint64_t)m->hmax * m->vmax;
  return c > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)c;
}

static uint32_t i274_line_clks(void) { return 2u * imx274_mode()->hmax; }
static uint32_t i274_ob_lines(void) { return imx274_mode()->ob_lines; }

static void i274_print_timing(uint32_t form) {
  const imx274_mode_t *m = imx274_mode();
  bow_printf(form == CAM_TIMING_LINES ? "HMAX %u, VMAX %u" : "HMAX %u VMAX %u", m->hmax, m->vmax);
}

const cam_sensor_t cam_imx274 = {
    .name = "IMX274",
    .build = "Huins camera",
    .id = IMX274_ID,
    .lanes = IMX274_LANES,
    .emb_lines = IMX274_EMB_LINES,
    .start_frames = 1,
    .tp_max = IMX274_TP_MAX,
    .tp_bars = IMX274_TP_VBARS,
    .tp_solid = IMX274_TP_ALL_555,
    .stop_cuts_frame = true,
    .has_hflip = false,
    .has_raw8 = false,
    .lane_rate_mbps = IMX274_LANE_RATE / 1000000u,
    .black_level = IMX274_BLACK,
    .gain_max = IMX274_PGC_MAX,
    .max_w = IMX274_MAX_W,
    .max_h = IMX274_MAX_H,
    .wb_r = 256,
    .wb_b = 256,
    .timing_hz = IMX274_CLK_HZ,
    .ccm = ccm_default,
    .probe = imx274_probe,
    .power = imx274_power,
    .mode = i274_mode,
    .configure = imx274_configure,
    .start = i274_start,
    .stop = i274_stop,
    .set_exposure = imx274_set_exposure,
    .exposure_max = imx274_exposure_max,
    .set_gain = imx274_set_analog_gain,
    .gain_q8 = i274_gain_q8,
    .gain_code = i274_gain_code,
    .set_flip = imx274_set_orientation,
    .bayer = i274_bayer,
    .set_test_pattern = imx274_set_test_pattern,
    .dt = i274_dt,
    .frame_clks = i274_frame_clks,
    .line_clks = i274_line_clks,
    .ob_lines = i274_ob_lines,
    .print_timing = i274_print_timing,
    .read = imx274_read,
    .write = imx274_write,
};

/* ------------------------------------------------------------- detection */
void cam_sensor_detect(cam_detect_t *d) {
  d->sensor = &cam_imx219;
  d->found = false;
  d->id = d->id219 = d->id274 = 0;
  d->tried274 = false;
  d->r274 = I2C_ENACK;
  d->i2c_hz = 400000u;

  /* KV260: TCA9546A switch at 0x74, IMX219 on channel 2 */
  d->r219 = imx219_probe(&d->id219);
  if (d->r219 == I2C_OK) {
    d->found = d->id219 == IMX219_CHIP_ID;
    d->id = d->id219;
    return; /* the KV260 camera bus answers: no IMX274 there */
  }

  /* Huins camera adapter: IMX274 at 0x1A, no switch, FPGA pull-ups and the
   * level shifters of the module: 100 kHz */
  d->tried274 = true;
  d->i2c_hz = 100000u;
  bow_i2c_init(I2C0, d->i2c_hz);
  d->r274 = imx274_probe(&d->id274);
  d->found = d->r274 == I2C_OK && d->id274 == IMX274_ID;
  if (d->found) {
    d->sensor = &cam_imx274;
    d->id = d->id274;
  } else {
    d->i2c_hz = 400000u;
    bow_i2c_init(I2C0, d->i2c_hz);
  }
}

void cam_print_prsnt(uint32_t rx_lanes) {
  if (rx_lanes < 4u) return;
  uint32_t prsnt = (bow_gpio_read(GPIOB) >> 5) & 1u;
  bow_printf("camera: FMC+01 PRSNT_M2C_L (PB5) = %u: %s\n", prsnt,
             prsnt ? "no module on the site" : "a module is plugged in");
}

/* ------------------------------------------------- receiver start (board) */
#define CAM_PA5_BURSTRST GPIO_PIN(5) /* Huins camera top: burst_rst_en_i */

int cam_rx_start(const cam_sensor_t *s, uint32_t dt) {
  if (CSI2RX->INFO & CSI2RX_INFO_DLY_VID) {
#if CAM_BURST_RST
    bow_gpio_set(GPIOA, CAM_PA5_BURSTRST);
    bow_gpio_output(GPIOA, CAM_PA5_BURSTRST);
#else
    bow_gpio_clear(GPIOA, CAM_PA5_BURSTRST);
#endif
  }
  return bow_csi2rx_start(s->lanes, dt, cam_lane_rate(s));
}

void cam_stream_stop(const cam_sensor_t *s, uint32_t timeout_ms) {
  if (s && s->stop_cuts_frame) {
    bow_csi2rx_wait_frame(timeout_ms);
    bow_csi2rx_stop(timeout_ms);
    s->stop();
    return;
  }
  if (s) s->stop();
  bow_csi2rx_stop(timeout_ms); /* the sensor finishes its frame first */
}
