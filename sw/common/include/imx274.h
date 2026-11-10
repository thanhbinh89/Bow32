/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Sony IMX274 driver (Leopard Imaging LI-IMX274MIPI-FMC module), 4 lane MIPI
 * CSI-2 at 1440 Mbit/s per lane, RAW10, 24 MHz clock on the module. Register
 * values follow the datasheet (IMX274LQC-C) and the Linux driver
 * (drivers/media/i2c/imx274.c).
 *
 * On the Huins MFP-VP1902 (Huins camera adapter on FMC+01) the sensor reset
 * XCLR is GPIO PA7 (0 = reset, 1 = run), the I2C bus is I2C0 without a
 * switch, XCE and FLASH are driven high by the FPGA.
 * Not included by bow32.h: applications that use the sensor include it.
 *
 * What differs from the IMX219:
 *   - multi-byte registers are LSB first (at the lower address);
 *   - no chip id register: imx274_probe() checks reset defaults;
 *   - fixed readout modes; a window is a centred crop of mode 5 (1288 x 734,
 *     3 x 2/3 binning), mode 3 (1932 x 1094, 2 x 2 binning) or mode 1
 *     (3864 x 2174, all pixels), the smallest mode that holds it;
 *   - one CSI-2 line every 2 HMAX periods of the 72 MHz sensor clock, a
 *     frame is HMAX x VMAX clocks; every frame carries 1 embedded data line
 *     (0x12) and 4 (mode 5) or 8 optical black lines (0x37) before the
 *     RAW10 lines;
 *   - stream on takes the standby cancel sequence (>= 10 ms + 7 ms) and the
 *     first frame after it is not output; stream off is immediate (it cuts
 *     the frame): stop after a frame end;
 *   - in standby every lane is LP-00 (not LP-11).
 */
#ifndef IMX274_H_
#define IMX274_H_

#include <stdbool.h>
#include <stdint.h>

#define IMX274_I2C_ADDR   0x1A
#define IMX274_ID         0x0274u      /* pseudo id: reset defaults matched */
#define IMX274_CLK_HZ     72000000u    /* HMAX unit (INCK 24 MHz) */
#define IMX274_LANES      4u
#define IMX274_LANE_RATE  1440000000u  /* bit/s per lane (byte clock 180 MHz) */
#define IMX274_PGC_MAX    1957u        /* analog gain = 2048 / (2048 - PGC), 22.5x */
#define IMX274_DGAIN_MAX  6u           /* digital gain x 2^DGAIN */
#define IMX274_EXP_MIN    4u           /* exposure units (HMAX periods) */
#define IMX274_BLACK      50u          /* BLKLEVEL default: 50 RAW10 codes */
#define IMX274_EMB_LINES  1u           /* embedded data lines (0x12) per frame */
#define IMX274_MAX_W      3864u
#define IMX274_MAX_H      2174u

/* Test patterns (imx274_set_test_pattern): n = register 0x303D value + 1,
 * the menu of the Linux driver. Values in 12 bit units; what the RAW10
 * output and the colour bars look like is measured on the board. */
#define IMX274_TP_OFF     0u
#define IMX274_TP_ALL_000 1u
#define IMX274_TP_ALL_FFF 2u
#define IMX274_TP_ALL_555 3u
#define IMX274_TP_ALL_AAA 4u
#define IMX274_TP_VSTRIPE 5u  /* 5..10: vertical stripes */
#define IMX274_TP_VBARS   11u /* vertical colour bars */
#define IMX274_TP_HBARS   12u /* horizontal colour bars */
#define IMX274_TP_MAX     12u

#define IMX274_EINVAL -3 /* invalid argument (other errors: I2C_* codes) */

/* Frame format of imx274_set_mode() */
typedef struct {
  uint16_t width, height; /* window: RAW10 pixels per line, lines per frame */
  uint8_t readout;        /* readout drive mode of the datasheet: 1, 3 or 5 */
  uint8_t ob_lines;       /* optical black lines (data type 0x37) per frame */
  bool video;             /* lines long enough for the H.264 encoder */
  bool legal;             /* window within the datasheet rules (else simulation only) */
  uint16_t hmax;          /* 72 MHz clocks; one CSI-2 line = 2 HMAX */
  uint16_t hmax_min;      /* sensor minimum for the window */
  uint32_t vmax;          /* HMAX periods per frame (SVR = 0) */
  uint32_t vmax_min;      /* sensor minimum for the window */
  uint16_t shr_min;       /* shortest SHR: exposure <= VMAX - SHR_min */
  uint16_t h_start, h_end;  /* HTRIMMING, pixels before binning (0 / 3864: none) */
  uint16_t vwidcut;       /* lines cut = 2 x VWIDCUT (0: no vertical crop) */
  uint16_t vwinpos;       /* first line = 2 x VWINPOS (sign added for vflip) */
} imx274_mode_t;

/* Reset the sensor (XCLR low >= 1 ms, then 20 ms before I2C), then check the
 * reset defaults: MDSEL1..4 (0x3004) = 03 31 00 09, HMAX (0x30F6) 0x0104,
 * VMAX (0x30F8, 3 bytes) 0x000906 or 0x000905, and a write / read back of
 * BLKLEVEL (0x3045). The sensor of the Huins board reads VMAX 0x906 after
 * reset, the datasheet says 0x905: both are accepted. Returns 0 with *id =
 * IMX274_ID, or 0 with *id = MDSEL1 << 8 | MDSEL2 when something answers at
 * 0x1A that does not look like an IMX274 (imx274_probe_regs() has what it
 * read), or a negative I2C error (I2C_ENACK: nothing at 0x1A). The sensor
 * stays in standby. */
int imx274_probe(uint16_t *id);

/* What the last imx274_probe() read, for the message when the reset values
 * do not match (cam_print_not_found): valid once it returned 0. */
typedef struct {
  uint8_t mdsel[4];  /* 0x3004..0x3007: MDSEL1..4 */
  uint8_t hvmax[5];  /* 0x30F6..0x30FA: HMAX (2 bytes), VMAX (3 bytes), LSB first */
  bool blk_read;     /* MDSEL / HMAX / VMAX matched: BLKLEVEL was written (0x33) and read */
  uint8_t blk;       /* ... the value read back */
} imx274_probe_t;
const imx274_probe_t *imx274_probe_regs(void);

/* on: XCLR low >= 1 ms, high, 20 ms (registers at reset defaults, standby).
 * off: XCLR low (reset). */
int imx274_power(bool on);

/* Window width x height (readout mode and crop, see above; width a multiple
 * of 4 up to 1288, of 12 above, height even), frame rate fps (0: the
 * shortest frame), video: the H.264 encoder consumes the stream. HMAX at a
 * 200 MHz video clock (ISP 1 pixel/clock): 1280x720 300, 1920x1080 400,
 * 3840x2160 800, other windows max(sensor minimum, W / 5). With video (H.264,
 * imx274_h264_load): ceil(W x 0.35) (79 % load) if VMAX_min + 20 still gives
 * fps, else the longest HMAX that gives fps, at least ceil(W x 0.276)
 * (100 %); fps 0: ceil(W x 0.276). 1080p30 672, 720p30 448, 1080p60 542
 * (98 %). VMAX = 72 MHz / (HMAX x fps) rounded down, at least VMAX_min + 20.
 * No I2C: imx274_configure() programs it. */
int imx274_set_mode(uint32_t width, uint32_t height, uint32_t fps, bool video);
const imx274_mode_t *imx274_mode(void);

/* Step 1 of the standby cancel sequence: common settings (24 MHz INCK,
 * PLLs on), readout mode, crop, HMAX/VMAX, exposure, gains, black level,
 * flip and test pattern of the driver state. The sensor stays in standby. */
int imx274_configure(void);
/* on: replays imx274_configure() if the sensor was stopped since, waits
 * until 11 ms after the PLLs started, step 2 (standby off, SYS_MODE), 8 ms,
 * step 3 (master start). The first frame after it is not output.
 * off: standby at once, the frame in progress is cut. */
int imx274_stream(bool on);

/* HMAX / VMAX at run time (frame latched); vmax is clamped to the window
 * minimum, the exposure is kept (SHR follows VMAX). */
int imx274_set_frame(uint32_t hmax, uint32_t vmax);
/* Exposure in HMAX periods (SHR = VMAX - units, 2 frames latency), clamped
 * to IMX274_EXP_MIN .. imx274_exposure_max(). */
int imx274_set_exposure(uint32_t units);
uint32_t imx274_exposure_max(void);
uint32_t imx274_exposure(void);
int imx274_set_analog_gain(uint32_t pgc);   /* 0..1957, gain = 2048 / (2048 - pgc) */
int imx274_set_digital_gain(uint32_t dgain); /* 0..6, x 2^dgain */
int imx274_set_black_level(uint32_t level);  /* 0..255 RAW10 codes */
/* no horizontal flip: IMX274_EINVAL; while streaming MDVREV + crop under
 * REGHOLD (one frame start takes them all) */
int imx274_set_orientation(bool hflip, bool vflip);
int imx274_set_test_pattern(uint32_t pattern);      /* IMX274_TP_* */
int imx274_hold(bool hold);                         /* REGHOLD: frame latched writes wait */

/* Simulation only: the start-up waits (reset, standby cancel) divided by
 * 64. A real sensor needs the full waits. */
void imx274_set_quick(bool quick);

/* Raw register access (16 bit address, 8 bit data). */
int imx274_read(uint16_t reg, uint8_t *val);
int imx274_write(uint16_t reg, uint8_t val);
int imx274_read_buf(uint16_t reg, uint8_t *buf, uint32_t n);

/* ISP BAYER code of the output: RGGB (ISP_BAYER_RGGB), also with the
 * vertical flip. Measured on the Huins board (2026-11-10): the flipped
 * readout keeps the colour phase (the scene and the colour bars are right
 * with RGGB, GBRG gives a magenta image), as the Linux driver assumes. */
static inline uint32_t imx274_bayer(bool vflip) {
  (void)vflip;
  return 0u;
}

/* Load of the H.264 encoder in % (392 cycles per macroblock at 200 MHz)
 * with CSI-2 lines of 2 HMAX: a strip of 16 lines must be coded while the
 * next one arrives, 0.275625 x W / HMAX. Close to 100 % detailed scenes at
 * a low QP drop pixels (ERR_OVF). */
static inline uint32_t imx274_h264_load(uint32_t width, uint32_t hmax) {
  return hmax ? width * 2205u / (80u * hmax) : 0;
}

/* Frame period in us (SVR = 0) and CSI-2 line period in ns. */
static inline uint32_t imx274_frame_us(uint32_t hmax, uint32_t vmax) {
  return (uint32_t)((uint64_t)hmax * vmax / (IMX274_CLK_HZ / 1000000u));
}
static inline uint32_t imx274_line_ns(uint32_t hmax) {
  return (uint32_t)((uint64_t)hmax * 2000000000u / IMX274_CLK_HZ);
}

#endif /* IMX274_H_ */
