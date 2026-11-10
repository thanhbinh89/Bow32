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
#include "cam_sensor.h"

typedef struct {
  /* hardware found at start-up; lanes = data lanes of the receiver, s = the
   * sensor (cam_imx219 when none was found: its formulas); vid = the D-PHY
   * is the Versal XPHY (INFO.DLY_VID: PHY_RDY, `phy` and `sensor` commands) */
  bool sensor, phy, vid;
  uint32_t lanes;
  const cam_sensor_t *s;
  /* sensor: frame format, test pattern, colour of IMX219_TP_SOLID (R Gr B Gb) */
  uint32_t w, h, fps;
  uint32_t tp, colour[4];
  bool streaming;
  /* last eye calibration (calibrate check or `cal`), for the margin check */
  bool calibrated;
  bow_csi2rx_cal_t cal;
} csi2_test_t;

extern csi2_test_t ct;

static inline bool sensor_imx274(void) { return ct.s == &cam_imx274; }

/* Data lanes the stream uses: those of the sensor, at most the receiver's. */
static inline uint32_t stream_lanes(void) {
  return ct.s->lanes < ct.lanes ? ct.s->lanes : ct.lanes;
}

/* Frame period of the mode in ms (rounded up), time for one calibration tap
 * (1.2 frame periods + 2 ms). */
uint32_t frame_ms(void);
uint32_t tap_timeout_ms(void);

/* Receiver start, then (configure: sensor format, crop, test pattern) stream
 * on. Stop: stream off and receiver stop in the order of the sensor
 * (cam_stream_stop: the IMX274 is stopped after a frame end). */
bool stream_start(bool configure);
void stream_stop(void);

/* Frame size and rate (fps 0: shortest frame); restarts a running stream.
 * false: invalid size, or lines that overflow the receiver FIFO (e.g. 4K
 * of the IMX274 with less than 1024 groups). */
bool set_mode(uint32_t w, uint32_t h, uint32_t fps);
/* RAW8 / RAW10: sensor and CTRL.DT; restarts a running stream (the sensor
 * takes the format only in standby). false on I2C error (IMX274: RAW10 only). */
bool set_format(uint32_t bits);
/* IMX219: colour of the solid test pattern (IMX274: none, I2C_OK) */
int set_colour(const uint32_t c[4]);

/* FS interrupts counted by the trap handler during `frames` frames. */
uint32_t count_fs_irqs(uint32_t frames, uint32_t timeout_ms);

/* `test [quick]` (checks.c) */
bool run_tests(bool quick);

#endif /* CSI2_TEST_H_ */
