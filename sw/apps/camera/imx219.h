/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Sony IMX219 (Raspberry Pi camera module v2) driver, 2 lane MIPI CSI-2,
 * RAW10, 24 MHz clock on the module. Register values follow the Linux
 * driver (drivers/media/i2c/imx219.c).
 *
 * On the KV260 the sensor sits behind the TCA9546A I2C switch (channel 2)
 * and is powered through RPI_ENABLE (PA7), see docs/camera_kv260.md.
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
#define IMX219_LLP        3448u      /* line length in pixels */
#define IMX219_VBLANK_MIN 32u
#define IMX219_EXP_OFFSET 4u         /* exposure <= frame length - 4 */
#define IMX219_AGAIN_MAX  232u       /* analog gain = 256 / (256 - code) */
#define IMX219_ACTIVE_W   3280u
#define IMX219_ACTIVE_H   2464u

#define IMX219_TP_OFF  0u
#define IMX219_TP_BARS 2u /* colour bars */

/* Power on the module, select the I2C switch channel, read the chip id.
 * Returns 0 and the id, or a negative I2C error. */
int imx219_probe(uint16_t *id);

/* Program a centred crop of width x height (no binning) with the given
 * frame length in lines (frame rate = 182.4 MHz / (3448 * fll)). The sensor
 * stays in standby. */
int imx219_configure(uint32_t width, uint32_t height, uint32_t fll);
int imx219_stream(bool on);

int imx219_set_exposure(uint32_t lines);
int imx219_set_analog_gain(uint32_t code);
int imx219_set_orientation(bool hflip, bool vflip);
int imx219_set_test_pattern(uint32_t pattern);

/* Raw register access (16 bit address, 8 bit data). */
int imx219_read(uint16_t reg, uint8_t *val);
int imx219_write(uint16_t reg, uint8_t val);

/* ISP BAYER code of the output for a given orientation (RGGB without flip). */
static inline uint32_t imx219_bayer(bool hflip, bool vflip) {
  return (vflip ? 2u : 0u) | (hflip ? 1u : 0u);
}

/* Frame length for a frame rate, at least height + minimum blanking. */
uint32_t imx219_fll_for_fps(uint32_t height, uint32_t fps);

#endif /* IMX219_H_ */
