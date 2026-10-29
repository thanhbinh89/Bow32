/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Sony IMX219 driver (see imx219.h).
 */
#include "imx219.h"

#include "bow32.h"

typedef struct {
  uint16_t reg;
  uint8_t val;
} imx219_reg_t;

/* Common settings: standby, access to the manufacturer registers, 2 CSI-2
 * lanes, 24 MHz clock, RAW10 and the PLL for 912 Mbit/s per lane (pixel
 * rate 182.4 MHz). The frame format follows in imx219_configure(). */
static const imx219_reg_t imx219_common[] = {
    {0x0100, 0x00},                                     /* mode select: standby */
    {0x30eb, 0x05}, {0x30eb, 0x0c}, {0x300a, 0xff},     /* access sequence */
    {0x300b, 0xff}, {0x30eb, 0x05}, {0x30eb, 0x09},
    {0x0114, 0x01},                                     /* CSI_LANE_MODE: 2 lanes */
    {0x0128, 0x00},                                     /* DPHY_CTRL: automatic */
    {0x012a, 0x18}, {0x012b, 0x00},                     /* EXCK_FREQ = 24 MHz */
    {0x0170, 0x01}, {0x0171, 0x01},                     /* x/y odd increment */
    {0x0174, 0x00}, {0x0175, 0x00},                     /* no binning */
    {0x018c, 0x0a}, {0x018d, 0x0a},                     /* CSI data format RAW10 */
    {0x0301, 0x05},                                     /* VTPXCK_DIV */
    {0x0303, 0x01},                                     /* VTSYCK_DIV */
    {0x0304, 0x03},                                     /* PREPLLCK_VT_DIV: 24 / 3 */
    {0x0305, 0x03},                                     /* PREPLLCK_OP_DIV */
    {0x0306, 0x00}, {0x0307, 0x39},                     /* PLL_VT_MPY = 57 */
    {0x0309, 0x0a},                                     /* OPPXCK_DIV = 10 (RAW10) */
    {0x030b, 0x01},                                     /* OPSYCK_DIV */
    {0x030c, 0x00}, {0x030d, 0x72},                     /* PLL_OP_MPY = 114 */
    {0x455e, 0x00}, {0x471e, 0x4b}, {0x4767, 0x0f},     /* undocumented, from the */
    {0x4750, 0x14}, {0x4540, 0x00}, {0x47b4, 0x14},     /* Linux driver */
    {0x4713, 0x30}, {0x478b, 0x10}, {0x478f, 0x10},
    {0x4793, 0x10}, {0x4797, 0x0e}, {0x479b, 0x0e},
};

/* ---------------------------------------------------------------- I2C */
static int write_burst(uint16_t reg, const uint8_t *val, uint32_t n) {
  uint8_t buf[2 + 16];
  buf[0] = (uint8_t)(reg >> 8);
  buf[1] = (uint8_t)reg;
  for (uint32_t i = 0; i < n; i++) buf[2 + i] = val[i];
  return bow_i2c_write(I2C0, IMX219_I2C_ADDR, buf, n + 2);
}

int imx219_write(uint16_t reg, uint8_t val) { return write_burst(reg, &val, 1); }

static int write16(uint16_t reg, uint32_t val) {
  uint8_t b[2] = {(uint8_t)(val >> 8), (uint8_t)val};
  return write_burst(reg, b, 2);
}

int imx219_read(uint16_t reg, uint8_t *val) {
  uint8_t a[2] = {(uint8_t)(reg >> 8), (uint8_t)reg};
  return bow_i2c_write_read(I2C0, IMX219_I2C_ADDR, a, 2, val, 1);
}

/* Write a table; registers with consecutive addresses go out in one burst
 * (the sensor increments the address after every byte). */
static int write_table(const imx219_reg_t *t, uint32_t n) {
  uint32_t i = 0;
  while (i < n) {
    uint8_t val[16];
    uint16_t base = t[i].reg;
    uint32_t len = 0;
    while (i < n && len < sizeof(val) && t[i].reg == base + len) val[len++] = t[i++].val;
    int r = write_burst(base, val, len);
    if (r != I2C_OK) return r;
  }
  return I2C_OK;
}

/* ------------------------------------------------------------- control */
int imx219_probe(uint16_t *id) {
  /* RPI_ENABLE (PA7): power up the module, give it time to start. */
  bow_gpio_set(GPIOA, GPIO_PIN(7));
  bow_gpio_output(GPIOA, GPIO_PIN(7));
  bow_delay_ms(10);

  uint8_t ch = TCA9546_CH_CAMERA;
  int r = bow_i2c_write(I2C0, TCA9546_I2C_ADDR, &ch, 1);
  if (r != I2C_OK) return r;

  uint8_t a[2] = {0x00, 0x00}, d[2];
  r = bow_i2c_write_read(I2C0, IMX219_I2C_ADDR, a, 2, d, 2);
  if (r == I2C_OK) *id = (uint16_t)(d[0] << 8 | d[1]);
  return r;
}

uint32_t imx219_fll_for_fps(uint32_t height, uint32_t fps) {
  uint32_t fll = fps ? IMX219_PIXEL_RATE / (IMX219_LLP * fps) : 0;
  if (fll < height + IMX219_VBLANK_MIN) fll = height + IMX219_VBLANK_MIN;
  return fll > 0xFFFF ? 0xFFFF : fll;
}

int imx219_configure(uint32_t width, uint32_t height, uint32_t fll) {
  int r = write_table(imx219_common, sizeof(imx219_common) / sizeof(imx219_common[0]));
  if (r != I2C_OK) return r;

  /* Centred crop, even start so that the Bayer order stays RGGB. */
  uint32_t x0 = ((IMX219_ACTIVE_W - width) / 2) & ~1u;
  uint32_t y0 = ((IMX219_ACTIVE_H - height) / 2) & ~1u;
  uint32_t x1 = x0 + width - 1, y1 = y0 + height - 1;
  uint8_t frame[16] = {
      (uint8_t)(fll >> 8),    (uint8_t)fll,          /* 0x0160 FRM_LENGTH_A */
      IMX219_LLP >> 8,        IMX219_LLP & 0xff,     /* 0x0162 LINE_LENGTH_A */
      (uint8_t)(x0 >> 8),     (uint8_t)x0,           /* 0x0164 X_ADD_STA_A */
      (uint8_t)(x1 >> 8),     (uint8_t)x1,           /* 0x0166 X_ADD_END_A */
      (uint8_t)(y0 >> 8),     (uint8_t)y0,           /* 0x0168 Y_ADD_STA_A */
      (uint8_t)(y1 >> 8),     (uint8_t)y1,           /* 0x016a Y_ADD_END_A */
      (uint8_t)(width >> 8),  (uint8_t)width,        /* 0x016c x_output_size */
      (uint8_t)(height >> 8), (uint8_t)height,       /* 0x016e y_output_size */
  };
  r = write_burst(0x0160, frame, sizeof(frame));
  if (r != I2C_OK) return r;
  /* Test pattern window = output size */
  uint8_t tpw[4] = {(uint8_t)(width >> 8), (uint8_t)width, (uint8_t)(height >> 8), (uint8_t)height};
  return write_burst(0x0624, tpw, sizeof(tpw));
}

int imx219_stream(bool on) { return imx219_write(0x0100, on ? 0x01 : 0x00); }

int imx219_set_exposure(uint32_t lines) { return write16(0x015a, lines); }

int imx219_set_analog_gain(uint32_t code) {
  return imx219_write(0x0157, (uint8_t)(code > IMX219_AGAIN_MAX ? IMX219_AGAIN_MAX : code));
}

int imx219_set_orientation(bool hflip, bool vflip) {
  return imx219_write(0x0172, (uint8_t)((vflip ? 2u : 0u) | (hflip ? 1u : 0u)));
}

int imx219_set_test_pattern(uint32_t pattern) { return write16(0x0600, pattern); }
