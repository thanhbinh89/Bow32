/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Sony IMX219 (Raspberry Pi camera module v2) driver, 2 lane MIPI CSI-2,
 * RAW10 or RAW8, 24 MHz clock on the module. Register values follow the
 * Linux driver (drivers/media/i2c/imx219.c).
 *
 * On the KV260 the sensor sits behind the TCA9546A I2C switch (channel 2)
 * and is powered through RPI_ENABLE (PA7), see docs/camera_kv260.md.
 * Not included by bow32.h: applications that use the sensor include it.
 */
#ifndef IMX219_H_
#define IMX219_H_

#include <stdbool.h>
#include <stdint.h>

#define IMX219_I2C_ADDR   0x10
#define IMX219_CHIP_ID    0x0219
#define TCA9546_I2C_ADDR  0x74
#define TCA9546_CH_CAMERA 0x04 /* channel 2 */

#define IMX219_PIXEL_RATE 182400000u /* pixels/s (2 lanes x 912 Mbit/s / 10 bit) */
#define IMX219_LANE_RATE  912000000u /* bit/s per lane (byte clock = rate / 8) */
#define IMX219_LLP        3448u      /* line length in pixels */
#define IMX219_VBLANK_MIN 32u
#define IMX219_EXP_OFFSET 4u         /* exposure <= frame length - 4 */
#define IMX219_AGAIN_MAX  232u       /* analog gain = 256 / (256 - code) */
#define IMX219_ACTIVE_W   3280u
#define IMX219_ACTIVE_H   2464u

/* Test patterns (imx219_set_test_pattern) */
#define IMX219_TP_OFF   0u
#define IMX219_TP_SOLID 1u /* colour of imx219_set_test_colour() */
#define IMX219_TP_BARS  2u /* colour bars */
#define IMX219_TP_FADE  3u /* colour bars fading to grey */
#define IMX219_TP_PN9   4u /* pseudo random */

#define IMX219_EINVAL -3 /* invalid argument (other errors: I2C_* codes) */

/* Power on the module, select the I2C switch channel, read the chip id.
 * An IMX219 then streams for 100 us and goes back to standby, like in the
 * Linux probe: after power-up the lanes only enter LP-11 once the sensor
 * has streamed. Returns 0 and the id, or a negative I2C error. */
int imx219_probe(uint16_t *id);

/* Program a centred crop of width x height (no binning) with the given
 * frame length in lines (frame rate = 182.4 MHz / (3448 * fll)) and the
 * output format of imx219_set_format(). The sensor stays in standby. */
int imx219_configure(uint32_t width, uint32_t height, uint32_t fll);
/* Stream on / off. After a stream-off the sensor finishes the current frame. */
int imx219_stream(bool on);

/* Output format: 10 (RAW10, CSI-2 data type 0x2B, default) or 8 (RAW8,
 * 0x2A). Stored for imx219_configure() and written to the sensor now. */
int imx219_set_format(uint32_t bits);
uint32_t imx219_format(void);

int imx219_set_exposure(uint32_t lines);
int imx219_set_analog_gain(uint32_t code);
int imx219_set_orientation(bool hflip, bool vflip);
int imx219_set_test_pattern(uint32_t pattern);
/* Colour of IMX219_TP_SOLID: 10 bit per Bayer component. */
int imx219_set_test_colour(uint32_t r, uint32_t gr, uint32_t b, uint32_t gb);

/* Raw register access (16 bit address, 8 bit data). */
int imx219_read(uint16_t reg, uint8_t *val);
int imx219_write(uint16_t reg, uint8_t val);

/* ISP BAYER code of the output for a given orientation (RGGB without flip). */
static inline uint32_t imx219_bayer(bool hflip, bool vflip) {
  return (vflip ? 2u : 0u) | (hflip ? 1u : 0u);
}

/* Frame length for a frame rate, at least height + minimum blanking
 * (fps = 0: the shortest frame). */
uint32_t imx219_fll_for_fps(uint32_t height, uint32_t fps);

/* Frame period in us for a frame length (3448 * fll / 182.4 MHz). */
static inline uint32_t imx219_frame_us(uint32_t fll) {
  return fll * (IMX219_LLP * 10u) / (IMX219_PIXEL_RATE / 100000u);
}

#endif /* IMX219_H_ */
