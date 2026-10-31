/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * csi2_test: state and stream control shared by the shell (main.c) and the
 * checks of `test` (checks.c).
 */
#ifndef CSI2_TEST_H_
#define CSI2_TEST_H_

#include "bow32.h"
#include "imx219.h"

typedef struct {
  /* hardware found at start-up; lanes = data lanes of the receiver */
  bool sensor, phy;
  uint32_t lanes;
  /* sensor: frame format, test pattern, colour of IMX219_TP_SOLID (R Gr B Gb) */
  uint32_t w, h, fll;
  uint32_t tp, colour[4];
  bool streaming;
} csi2_test_t;

extern csi2_test_t ct;

/* Frame period of the mode in ms (rounded up), time for one calibration tap
 * (1.2 frame periods + 2 ms). */
uint32_t frame_ms(void);
uint32_t tap_timeout_ms(void);

/* Receiver start, then (configure: sensor format, crop, test pattern) stream
 * on. Stop: stream off, receiver stop after the last frame. */
bool stream_start(bool configure);
void stream_stop(void);

/* Frame size and rate (fps 0: shortest frame); restarts a running stream. */
bool set_mode(uint32_t w, uint32_t h, uint32_t fps);
/* RAW8 / RAW10: sensor and CTRL.DT; restarts a running stream (the sensor
 * takes the format only in standby). false on I2C error. */
bool set_format(uint32_t bits);
int set_colour(const uint32_t c[4]);

/* FS interrupts counted by the trap handler during `frames` frames. */
uint32_t count_fs_irqs(uint32_t frames, uint32_t timeout_ms);

/* `test [quick]` (checks.c) */
bool run_tests(bool quick);

#endif /* CSI2_TEST_H_ */
