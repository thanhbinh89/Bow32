/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Sony IMX274 driver (see imx274.h).
 *
 * The driver keeps the whole sensor configuration (frame format, exposure,
 * gains, flip, test pattern) and writes it as step 1 of the standby cancel
 * sequence: at imx274_configure() and again at every stream start after a
 * stop, like the Linux driver. Controls changed in between go to the sensor
 * at once when it is configured or streaming, else only to the state.
 */
#include "imx274.h"

#include "bow32.h"

typedef struct {
  uint16_t reg;
  uint8_t val;
} imx274_reg_t;

#define NREGS(t)    ((uint32_t)(sizeof(t) / sizeof((t)[0])))
#define XCLR        GPIO_PIN(7) /* PA7: sensor reset, 0 = reset */
#define VMAX_MARGIN 20u         /* HMAX periods of blanking above the minimum */
#define VMAX_MAX    0xFFFFFu

/* Step 1 starts here: leave standby with the logic and the output still held
 * (STANDBY 0, STBLOGIC 1, STBMIPI 0, STBDV 1), PLL dividers for INCK =
 * 24 MHz, and the PLLs on last. */
static const imx274_reg_t imx274_pll[] = {
    {0x3000, 0x12},                 /* STANDBY / STBLOGIC / STBMIPI / STBDV */
    {0x3120, 0xF0}, {0x3121, 0x00}, /* PLRD1 = 0x00F0 */
    {0x3122, 0x02},                 /* PLRD2 */
    {0x3129, 0x9C},                 /* PLRD3 */
    {0x312A, 0x02},                 /* PLRD4 */
    {0x312D, 0x02},                 /* PLRD5 */
    {0x310B, 0x00},                 /* STBPL_IF = STBPL_AD = 0: PLLs on */
};

/* Readout drive pulse timing and MIPI settings (allowed in standby). */
static const imx274_reg_t imx274_init[] = {
    {0x304C, 0x00}, {0x304D, 0x03},                 /* PLSTMG01, PLSTMG02 */
    {0x331C, 0x1A}, {0x331D, 0x00},                 /* PLSTMG03 */
    {0x3502, 0x02},                                 /* PLSTMG04 */
    {0x3529, 0x0E}, {0x352A, 0x0E}, {0x352B, 0x0E}, /* PLSTMG05..07 */
    {0x3538, 0x0E}, {0x3539, 0x0E},                 /* PLSTMG08..09 */
    {0x3553, 0x00},                                 /* PLSTMG10 */
    {0x357D, 0x05}, {0x357F, 0x05},                 /* PLSTMG11..12 */
    {0x3581, 0x04}, {0x3583, 0x76},                 /* PLSTMG13..14 */
    {0x3587, 0x01},                                 /* PLSTMG15 */
    {0x35BB, 0x0E}, {0x35BC, 0x0E}, {0x35BD, 0x0E}, /* PLSTMG16..18 */
    {0x35BE, 0x0E}, {0x35BF, 0x0E},                 /* PLSTMG19..20 */
    {0x366E, 0x00}, {0x366F, 0x00},                 /* PLSTMG21..22 */
    {0x3670, 0x00}, {0x3671, 0x00},                 /* PLSTMG23..24 */
    {0x3304, 0x32}, {0x3305, 0x00},                 /* PSMIPI1 = 0x0032 */
    {0x3306, 0x32}, {0x3307, 0x00},                 /* PSMIPI2 */
    {0x3590, 0x32}, {0x3591, 0x00},                 /* PSMIPI3 */
    {0x3686, 0x32}, {0x3687, 0x00},                 /* PSMIPI4 */
};

/* Readout drive modes (CSI-2 columns of the datasheet mode table). MDSEL4,
 * WRITE_VSIZE and Y_OUT_SIZE go with the crop (write_geometry). */
static const imx274_reg_t imx274_mode1[] = {        /* all pixels, 3864 x 2174 */
    {0x3004, 0x01}, {0x3005, 0x01}, {0x3006, 0x00}, /* MDSEL1..3 */
    {0x306B, 0x05},                                 /* MDPLS17 */
    {0x30E2, 0x01},                                 /* VCUTMODE */
    {0x30EE, 0x01},                                 /* PSMOVEN */
    {0x3342, 0x0A}, {0x3343, 0x00},                 /* MDPLS01 */
    {0x3344, 0x16}, {0x3345, 0x00},                 /* MDPLS02 */
    {0x33A6, 0x01},                                 /* MDPLS16 */
    {0x3528, 0x0E},                                 /* MDPLS03 */
    {0x3554, 0x1F}, {0x3555, 0x01}, {0x3556, 0x01}, /* MDPLS04..06 */
    {0x3557, 0x01}, {0x3558, 0x01}, {0x3559, 0x00}, /* MDPLS07..09 */
    {0x355A, 0x00},                                 /* MDPLS10 */
    {0x35BA, 0x0E},                                 /* MDPLS11 */
    {0x366A, 0x1B}, {0x366B, 0x1A}, {0x366C, 0x19}, /* MDPLS12..14 */
    {0x366D, 0x17},                                 /* MDPLS15 */
    {0x3A41, 0x08},                                 /* MDSEL5 */
};

static const imx274_reg_t imx274_mode3[] = {        /* 2 x 2 binning, 1932 x 1094 */
    {0x3004, 0x02}, {0x3005, 0x21}, {0x3006, 0x00},
    {0x306B, 0x05}, {0x30E2, 0x02}, {0x30EE, 0x01},
    {0x3342, 0x0A}, {0x3343, 0x00}, {0x3344, 0x1A}, {0x3345, 0x00},
    {0x33A6, 0x01}, {0x3528, 0x0E},
    {0x3554, 0x00}, {0x3555, 0x01}, {0x3556, 0x01}, {0x3557, 0x01},
    {0x3558, 0x01}, {0x3559, 0x00}, {0x355A, 0x00}, {0x35BA, 0x0E},
    {0x366A, 0x1B}, {0x366B, 0x1A}, {0x366C, 0x19}, {0x366D, 0x17},
    {0x3A41, 0x08},
};

static const imx274_reg_t imx274_mode5[] = {        /* H 3 / V 2/3 binning, 1288 x 734 */
    {0x3004, 0x03}, {0x3005, 0x31}, {0x3006, 0x00},
    {0x306B, 0x05}, {0x30E2, 0x03}, {0x30EE, 0x01},
    {0x3342, 0x0A}, {0x3343, 0x00}, {0x3344, 0x1B}, {0x3345, 0x00},
    {0x33A6, 0x01}, {0x3528, 0x0E},
    {0x3554, 0x00}, {0x3555, 0x01}, {0x3556, 0x01}, {0x3557, 0x01},
    {0x3558, 0x01}, {0x3559, 0x00}, {0x355A, 0x00}, {0x35BA, 0x0E},
    {0x366A, 0x1B}, {0x366B, 0x19}, {0x366C, 0x17}, {0x366D, 0x17},
    {0x3A41, 0x04},
};

/* Test pattern on / off (Linux driver; 0x303D selects the pattern). */
static const imx274_reg_t imx274_tp_on[] = {
    {0x303C, 0x11}, {0x370E, 0x01}, {0x377F, 0x01}, {0x3781, 0x01}, {0x370B, 0x11},
};
static const imx274_reg_t imx274_tp_off[] = {
    {0x303C, 0x00}, {0x377F, 0x00}, {0x3781, 0x00}, {0x370B, 0x00},
};

/* Readout mode: output size w x h (before cropping), horizontal binning,
 * HTRIMMING step (pixels before binning), OB lines, SHR minimum, MDSEL4 */
typedef struct {
  uint8_t mode, hbin, hstep, ob, shr_min, mdsel4;
  uint16_t w, h, hmax_min;
  const imx274_reg_t *regs;
  uint32_t nregs;
} readout_t;

static const readout_t readouts[3] = {
    {5, 3, 12, 4, 8, 0x09, 1288, 734, 260, imx274_mode5, NREGS(imx274_mode5)},
    {3, 2, 24, 8, 8, 0x11, 1932, 1094, 260, imx274_mode3, NREGS(imx274_mode3)},
    {1, 1, 12, 8, 12, 0x02, 3864, 2174, 263, imx274_mode1, NREGS(imx274_mode1)},
};

enum { ST_OFF, ST_STANDBY, ST_CONFIGURED, ST_STREAMING, ST_STOPPED };

static struct {
  imx274_mode_t m;
  const readout_t *r;  /* NULL: no mode set yet */
  uint8_t state;
  bool vflip, quick;
  uint32_t exposure;   /* HMAX periods (clamped when written) */
  uint32_t pgc, dgain, black, tp;
  uint32_t t_pll;      /* bow_cycles() when the PLLs were started */
} st = {.exposure = VMAX_MAX, .black = IMX274_BLACK};

/* ---------------------------------------------------------------- I2C */
static int write_burst(uint16_t reg, const uint8_t *val, uint32_t n) {
  uint8_t buf[2 + 16];
  buf[0] = (uint8_t)(reg >> 8);
  buf[1] = (uint8_t)reg;
  for (uint32_t i = 0; i < n; i++) buf[2 + i] = val[i];
  return bow_i2c_write(I2C0, IMX274_I2C_ADDR, buf, n + 2);
}

int imx274_write(uint16_t reg, uint8_t val) { return write_burst(reg, &val, 1); }

/* Multi-byte register, LSB at the lower address */
static int write_le(uint16_t reg, uint32_t val, uint32_t n) {
  uint8_t b[4];
  for (uint32_t i = 0; i < n; i++) b[i] = (uint8_t)(val >> (8u * i));
  return write_burst(reg, b, n);
}

int imx274_read_buf(uint16_t reg, uint8_t *buf, uint32_t n) {
  uint8_t a[2] = {(uint8_t)(reg >> 8), (uint8_t)reg};
  return bow_i2c_write_read(I2C0, IMX274_I2C_ADDR, a, 2, buf, n);
}

int imx274_read(uint16_t reg, uint8_t *val) { return imx274_read_buf(reg, val, 1); }

/* Write a table; registers with consecutive addresses go out in one burst
 * (the sensor increments the address after every byte). */
static int write_table(const imx274_reg_t *t, uint32_t n) {
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

/* ---------------------------------------------------------- helpers */
static void wait_us(uint32_t us) { bow_delay_us(st.quick ? (us + 63u) / 64u : us); }

static bool configured(void) { return st.state == ST_CONFIGURED || st.state == ST_STREAMING; }

/* SHR for an exposure of `units` HMAX periods: SHR_min <= SHR <= VMAX - 4,
 * SHR < 2^16. */
static uint32_t shr_for(uint32_t units) {
  uint32_t vmax = st.m.vmax, max = vmax - st.m.shr_min;
  if (units > max) units = max;
  if (units < IMX274_EXP_MIN) units = IMX274_EXP_MIN;
  if (vmax - units > 0xFFFFu) units = vmax - 0xFFFFu;
  return vmax - units;
}

/* VMAX for a frame rate, rounded down (the rate is not below fps) */
static uint32_t vmax_for(uint32_t hmax, uint32_t fps, uint32_t vmax_min) {
  uint32_t lo = vmax_min + VMAX_MARGIN;
  uint32_t v = fps ? (uint32_t)(IMX274_CLK_HZ / ((uint64_t)hmax * fps)) : 0;
  if (v < lo) v = lo;
  return v > VMAX_MAX ? VMAX_MAX : v;
}

/* HMAX for the H.264 encoder (392 cycles per macroblock at 200 MHz): a strip
 * of 16 lines (32 HMAX) is coded while the next one arrives, the load is
 * 0.2756 W / HMAX (imx274_h264_load). 0.35 W (79 %, the load the IMX219 has
 * on the KV260 at 1080p30: margin for slow CAVLC on detailed scenes) where
 * the frame rate leaves room for it (VMAX >= VMAX_min + 20), else the
 * longest line the frame rate allows, at least 0.276 W (100 %); fps 0: the
 * shortest frame, 0.276 W. 1080p30 672 (VMAX 3571), 720p30 448 (5357),
 * 1080p60 542 (2214, 98 %). */
static uint32_t hmax_h264(uint32_t width, uint32_t fps, uint32_t vmax_min) {
  uint32_t full = (width * 276u + 999u) / 1000u, hm = 0;
  if (fps) {
    uint64_t room = IMX274_CLK_HZ / ((uint64_t)fps * (vmax_min + VMAX_MARGIN));
    hm = (width * 35u + 99u) / 100u;
    if (hm > room) hm = (uint32_t)room;
  }
  return hm > full ? hm : full;
}

/* MDSEL4 (crop enable), HTRIMMING, vertical crop, WRITE_VSIZE / Y_OUT_SIZE */
static int write_geometry(void) {
  const imx274_mode_t *m = &st.m;
  bool hcrop = m->h_start != 0 || m->h_end != IMX274_MAX_W, vcrop = m->vwidcut != 0;
  /* the start position is negative with the vertical flip (12 bit) */
  uint32_t pos = st.vflip ? (0x1000u - m->vwinpos) & 0xFFFu : m->vwinpos;
  uint32_t wsize = (uint32_t)m->height + m->ob_lines;
  uint8_t h[5] = {hcrop ? 1u : 0u, (uint8_t)m->h_start, (uint8_t)(m->h_start >> 8),
                  (uint8_t)m->h_end, (uint8_t)(m->h_end >> 8)};
  uint8_t v[5] = {vcrop ? 1u : 0u, (uint8_t)m->vwidcut, (uint8_t)(m->vwidcut >> 8), (uint8_t)pos,
                  (uint8_t)(pos >> 8)};
  uint8_t sz[4] = {(uint8_t)wsize, (uint8_t)(wsize >> 8), (uint8_t)m->height,
                   (uint8_t)(m->height >> 8)};
  int r = imx274_write(0x3007, (uint8_t)(st.r->mdsel4 | (vcrop ? 0xA0u : 0u))); /* MDSEL4 */
  if (r == I2C_OK) r = write_burst(0x3037, h, sizeof(h)); /* HTRIMMING_EN, START, END */
  if (r == I2C_OK) r = write_burst(0x30DD, v, sizeof(v)); /* VWIDCUTEN, VWIDCUT, VWINPOS */
  if (r == I2C_OK) r = write_burst(0x3130, sz, sizeof(sz)); /* WRITE_VSIZE, Y_OUT_SIZE */
  return r;
}

/* HMAX (0x30F6) and VMAX (0x30F8, 20 bit) */
static int write_frame(void) {
  uint32_t hm = st.m.hmax, vm = st.m.vmax;
  uint8_t b[5] = {(uint8_t)hm, (uint8_t)(hm >> 8), (uint8_t)vm, (uint8_t)(vm >> 8),
                  (uint8_t)((vm >> 16) & 0x0Fu)};
  return write_burst(0x30F6, b, sizeof(b));
}

static int write_tp(void) {
  if (st.tp == IMX274_TP_OFF) return write_table(imx274_tp_off, NREGS(imx274_tp_off));
  int r = imx274_write(0x303D, (uint8_t)(st.tp - 1u));
  if (r == I2C_OK) r = write_table(imx274_tp_on, NREGS(imx274_tp_on));
  return r;
}

/* PGC, SHR, SVR = 0, DGAIN, MDVREV, BLKLEVEL, test pattern */
static int write_controls(void) {
  uint32_t shr = shr_for(st.exposure);
  uint8_t g[6] = {(uint8_t)st.pgc, (uint8_t)((st.pgc >> 8) & 7u), (uint8_t)shr,
                  (uint8_t)(shr >> 8), 0, 0};
  int r = write_burst(0x300A, g, sizeof(g)); /* PGC, SHR, SVR */
  if (r == I2C_OK) r = imx274_write(0x3012, (uint8_t)st.dgain);
  if (r == I2C_OK) r = imx274_write(0x301A, st.vflip ? 1u : 0u);
  if (r == I2C_OK) r = imx274_write(0x3045, (uint8_t)st.black);
  if (r == I2C_OK) r = write_tp();
  return r;
}

/* ------------------------------------------------------------- control */
int imx274_power(bool on) {
  bow_gpio_clear(GPIOA, XCLR);
  bow_gpio_output(GPIOA, XCLR);
  st.state = ST_OFF;
  if (!on) return I2C_OK;
  wait_us(1000);  /* XCLR low >= 100 ns */
  bow_gpio_set(GPIOA, XCLR);
  wait_us(20000); /* >= 20 us before I2C; module regulators and oscillator */
  st.state = ST_STANDBY;
  return I2C_OK;
}

static imx274_probe_t probe_regs;

const imx274_probe_t *imx274_probe_regs(void) { return &probe_regs; }

int imx274_probe(uint16_t *id) {
  static const uint8_t mdsel[4] = {0x03, 0x31, 0x00, 0x09}; /* MDSEL1..4 */
  imx274_probe_t *p = &probe_regs;
  uint8_t v = 0;
  p->blk_read = false;
  imx274_power(true);
  int r = imx274_read_buf(0x3004, p->mdsel, sizeof(p->mdsel));
  if (r == I2C_OK) r = imx274_read_buf(0x30F6, p->hvmax, sizeof(p->hvmax));
  if (r != I2C_OK) return r;
  *id = (uint16_t)(p->mdsel[0] << 8 | p->mdsel[1]);
  for (uint32_t i = 0; i < sizeof(mdsel); i++) {
    if (p->mdsel[i] != mdsel[i]) return I2C_OK;
  }
  /* HMAX 0x0104; VMAX 0x000906 on the board (2026-11-10), 0x000905 in the
   * datasheet */
  uint32_t hmax = p->hvmax[0] | (uint32_t)p->hvmax[1] << 8;
  uint32_t vmax = p->hvmax[2] | (uint32_t)p->hvmax[3] << 8 | (uint32_t)p->hvmax[4] << 16;
  if (hmax != 0x0104u || (vmax != 0x0906u && vmax != 0x0905u)) return I2C_OK;
  /* no id register: a register that can be written and read back */
  r = imx274_write(0x3045, 0x33); /* BLKLEVEL, immediate, harmless in standby */
  if (r == I2C_OK) r = imx274_read(0x3045, &v);
  if (r == I2C_OK) {
    p->blk_read = true;
    p->blk = v;
    r = imx274_write(0x3045, (uint8_t)st.black);
  }
  if (r == I2C_OK && v == 0x33) *id = IMX274_ID;
  return r;
}

int imx274_set_mode(uint32_t width, uint32_t height, uint32_t fps, bool video) {
  const readout_t *r = 0;
  for (uint32_t i = 0; i < 3 && !r; i++) {
    if (width <= readouts[i].w && height <= readouts[i].h) r = &readouts[i];
  }
  if (!r || width < 16 || height < 2 || (height & 1u)) return IMX274_EINVAL;
  uint32_t pre = width * r->hbin; /* pixels before binning */
  if ((IMX274_MAX_W - pre) % r->hstep) return IMX274_EINVAL;

  imx274_mode_t m = {0};
  /* Horizontal: whole steps on both sides, the odd one on the left (mode 3
   * 1920: 24..3863). Vertical: centred on the recording lines (from line 10,
   * Veff - 14 of them), or on the whole Veff when taller. */
  uint32_t steps = (IMX274_MAX_W - pre) / r->hstep, veff = r->h, rec = veff - 14u;
  uint32_t top = height <= rec ? 10u + (rec - height) / 2u : (veff - height) / 2u;
  m.width = (uint16_t)width;
  m.height = (uint16_t)height;
  m.readout = r->mode;
  m.ob_lines = r->ob;
  m.video = video;
  m.h_start = (uint16_t)((steps - steps / 2u) * r->hstep);
  m.h_end = (uint16_t)(m.h_start + pre);
  m.vwidcut = (uint16_t)((veff - height) / 2u);
  m.vwinpos = (uint16_t)(m.vwidcut ? top / 2u : 0u);
  /* datasheet: END - START >= 144, at least half of Veff */
  m.legal = pre >= 144u && 2u * height >= veff;
  m.shr_min = r->shr_min;
  m.hmax_min = r->hmax_min;
  if (r->mode == 1 && pre != IMX274_MAX_W) {
    uint32_t hm = (pre + 15u) / 16u + 22u; /* horizontal trimming in mode 1 */
    m.hmax_min = (uint16_t)(hm > 260u ? hm : 260u);
  }
  m.vmax_min = 2u * (1u + height + r->ob) + 13u; /* 2 HMAX per line, FS/FE, VBLK */

  /* HMAX for the Bow32 data path at a 200 MHz video clock: a line of W
   * pixels takes W / 200 MHz in the ISP (W / 5 HMAX, 90 % load) and
   * ~1.53 W / 200 MHz in the H.264 encoder (392 cycles per macroblock,
   * hmax_h264). */
  uint32_t hmax;
  if (video) {
    hmax = hmax_h264(width, fps, m.vmax_min);
  } else if (width == 1280 && height == 720) {
    hmax = 300u;
  } else if (width == 1920 && height == 1080) {
    hmax = 400u;
  } else if (width == 3840 && height == 2160) {
    hmax = 800u;
  } else {
    hmax = (width + 4u) / 5u;
  }
  if (hmax < m.hmax_min) hmax = m.hmax_min;
  m.hmax = (uint16_t)hmax;
  m.vmax = vmax_for(hmax, fps, m.vmax_min);

  st.m = m;
  st.r = r;
  return I2C_OK;
}

const imx274_mode_t *imx274_mode(void) { return &st.m; }

int imx274_configure(void) {
  if (!st.r) return IMX274_EINVAL;
  int r = write_table(imx274_pll, NREGS(imx274_pll));
  if (r != I2C_OK) return r;
  st.t_pll = bow_cycles();
  r = write_table(imx274_init, NREGS(imx274_init));
  if (r == I2C_OK) r = write_table(st.r->regs, st.r->nregs);
  if (r == I2C_OK) r = write_geometry();
  if (r == I2C_OK) r = write_frame();
  if (r == I2C_OK) r = write_controls();
  st.state = r == I2C_OK ? ST_CONFIGURED : ST_STANDBY;
  return r;
}

int imx274_stream(bool on) {
  int r;
  if (!on) {
    r = imx274_write(0x3000, 0x01); /* STANDBY: immediate */
    if (st.state != ST_OFF) st.state = ST_STOPPED;
    return r;
  }
  if (st.state != ST_CONFIGURED) {
    r = imx274_configure();
    if (r != I2C_OK) return r;
  }
  /* step 2 >= 10 ms after step 1 (+1 ms), step 3 >= 7 ms after step 2 */
  uint32_t wait = 11u * (bow_clk_hz() / 1000u) / (st.quick ? 64u : 1u);
  while ((uint32_t)(bow_cycles() - st.t_pll) < wait) {
  }
  r = imx274_write(0x3000, 0x00);                 /* STANDBY STBLOGIC STBMIPI STBDV = 0 */
  if (r == I2C_OK) r = imx274_write(0x303E, 0x02); /* SYS_MODE: 1440 Mbit/s */
  if (r != I2C_OK) return r;
  wait_us(8000);
  r = imx274_write(0x30F4, 0x00);                 /* XMSTA: master mode start */
  if (r == I2C_OK) r = imx274_write(0x3018, 0xA2); /* SYNCDRV: XHS / XVS outputs */
  if (r == I2C_OK) st.state = ST_STREAMING;
  return r;
}

int imx274_set_frame(uint32_t hmax, uint32_t vmax) {
  if (!st.r || hmax < st.m.hmax_min || hmax > 0xFFFFu) return IMX274_EINVAL;
  if (vmax < st.m.vmax_min + VMAX_MARGIN) vmax = st.m.vmax_min + VMAX_MARGIN;
  st.m.hmax = (uint16_t)hmax;
  st.m.vmax = vmax > VMAX_MAX ? VMAX_MAX : vmax;
  if (!configured()) return I2C_OK;
  int r = imx274_hold(true);
  if (r == I2C_OK) r = write_frame();
  if (r == I2C_OK) r = write_le(0x300C, shr_for(st.exposure), 2); /* SHR follows VMAX */
  int r2 = imx274_hold(false);
  return r != I2C_OK ? r : r2;
}

int imx274_set_exposure(uint32_t units) {
  st.exposure = units;
  return configured() ? write_le(0x300C, shr_for(units), 2) : I2C_OK;
}

uint32_t imx274_exposure_max(void) { return st.m.vmax - st.m.shr_min; }

uint32_t imx274_exposure(void) { return st.r ? st.m.vmax - shr_for(st.exposure) : st.exposure; }

int imx274_set_analog_gain(uint32_t pgc) {
  st.pgc = pgc > IMX274_PGC_MAX ? IMX274_PGC_MAX : pgc;
  return configured() ? write_le(0x300A, st.pgc, 2) : I2C_OK;
}

int imx274_set_digital_gain(uint32_t dgain) {
  st.dgain = dgain > IMX274_DGAIN_MAX ? IMX274_DGAIN_MAX : dgain;
  return configured() ? imx274_write(0x3012, (uint8_t)st.dgain) : I2C_OK;
}

int imx274_set_black_level(uint32_t level) {
  st.black = level > 255u ? 255u : level;
  return st.state != ST_OFF ? imx274_write(0x3045, (uint8_t)st.black) : I2C_OK;
}

/* Vertical flip: a mode transition (one frame is not output); the crop start
 * changes sign with it. While streaming the writes go under REGHOLD: MDVREV
 * (2nd frame) and MDSEL4, HTRIMMING, VWIDCUT/VWINPOS, WRITE_VSIZE/Y_OUT_SIZE
 * (1st frame) are frame reflected registers, which REGHOLD holds until its
 * release (IMX274LQC-C register map and "Register Hold Setting"), so the
 * sensor takes them at one frame start, never a frame with only some of them
 * (the writes take a few ms at 100 kHz). In standby the stream start takes
 * them. */
int imx274_set_orientation(bool hflip, bool vflip) {
  if (hflip) return IMX274_EINVAL;
  st.vflip = vflip;
  if (!configured()) return I2C_OK;
  bool hold = st.state == ST_STREAMING;
  int r = hold ? imx274_hold(true) : I2C_OK;
  if (r == I2C_OK) r = imx274_write(0x301A, vflip ? 1u : 0u); /* MDVREV */
  if (r == I2C_OK) r = write_geometry();
  if (hold) {
    int r2 = imx274_hold(false);
    if (r == I2C_OK) r = r2;
  }
  return r;
}

int imx274_set_test_pattern(uint32_t pattern) {
  if (pattern > IMX274_TP_MAX) return IMX274_EINVAL;
  st.tp = pattern;
  return configured() ? write_tp() : I2C_OK;
}

int imx274_hold(bool hold) { return imx274_write(0x302D, hold ? 1u : 0u); }

void imx274_set_quick(bool quick) { st.quick = quick; }
