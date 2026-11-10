/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Camera sensor layer: one operations table per supported sensor and the
 * detection that picks it, so that the applications drive the IMX219
 * (KV260, Raspberry Pi camera v2, imx219.h) and the IMX274 (Huins
 * MFP-VP1902, LI-IMX274MIPI-FMC, imx274.h) the same way:
 *
 *   cam_sensor_detect()        -> table of the sensor found (IMX219 if none)
 *   s->mode(w, h, fps, video)  frame format and timing, no I2C
 *   cam_rx_start(s, s->dt())   receiver start (bow_csi2rx_start) with the PHY
 *                              setting of the board
 *   s->configure()             sensor registers, stays in standby
 *   s->set_flip / set_test_pattern / set_exposure / set_gain
 *   s->start()                 stream on
 *   cam_stream_stop(s, ms)     stream off and receiver stop in the order
 *                              the sensor needs
 *
 * The IMX219 entries call imx219.c unchanged. Not included by bow32.h.
 */
#ifndef CAM_SENSOR_H_
#define CAM_SENSOR_H_

#include <stdbool.h>
#include <stdint.h>

#include "imx219.h"
#include "imx274.h"

/* Forms of print_timing() */
#define CAM_TIMING_SHORT  0u /* "FLL 1763"                | "HMAX 400 VMAX 6000" */
#define CAM_TIMING_LINES  1u /* "frame length 1763 lines" | "HMAX 400, VMAX 6000" */
#define CAM_TIMING_LENGTH 2u /* "frame length 1763"       | "HMAX 400 VMAX 6000" */

typedef struct cam_sensor {
  const char *name;        /* "IMX219" */
  const char *build;       /* bitstream with its D-PHY: "kv260_cam", "Huins camera" */
  uint16_t id;             /* id that probe() returns for this sensor */
  uint8_t lanes;           /* CSI-2 data lanes */
  uint8_t emb_lines;       /* embedded data lines (0x12) per frame */
  uint8_t start_frames;    /* frames after start() that are not output */
  uint8_t tp_max;          /* highest test pattern */
  uint8_t tp_bars;         /* colour bars */
  uint8_t tp_solid;        /* solid colour (IMX219: programmable, IMX274: fixed 555h) */
  bool stop_cuts_frame;    /* stream off is immediate: stop after a frame end */
  bool has_hflip;          /* horizontal mirror */
  bool has_raw8;           /* RAW8 output */
  uint16_t lane_rate_mbps; /* Mbit/s per lane */
  uint16_t black_level;    /* RAW10 black level (ISP BLC) */
  uint16_t gain_max;       /* highest analog gain code */
  uint16_t max_w, max_h;   /* largest window */
  uint16_t wb_r, wb_b;     /* white balance to start from, u4.8 */
  uint32_t timing_hz;      /* clock of frame_clks() / line_clks() */
  const int16_t *ccm;      /* colour matrix to start from, s3.8 row major (rows sum to 1) */

  int (*probe)(uint16_t *id);
  int (*power)(bool on);
  /* Window, frame rate (0: shortest frame), video: the H.264 encoder takes
   * the stream (IMX274: longer lines). No I2C; IMX219: any even window. */
  int (*mode)(uint32_t w, uint32_t h, uint32_t fps, bool video);
  int (*configure)(void);
  int (*start)(void);
  int (*stop)(void);
  int (*set_exposure)(uint32_t units); /* IMX219: lines, IMX274: HMAX periods */
  uint32_t (*exposure_max)(void);
  int (*set_gain)(uint32_t code);      /* analog gain code 0..gain_max */
  uint32_t (*gain_q8)(uint32_t code);  /* gain of a code, 256 = 1.0 */
  uint32_t (*gain_code)(uint32_t q8);  /* code of a gain (>= 1.0) */
  int (*set_flip)(bool hflip, bool vflip);
  uint32_t (*bayer)(bool hflip, bool vflip); /* ISP_BAYER_* of the output */
  int (*set_test_pattern)(uint32_t pattern);
  uint32_t (*dt)(void);                /* CSI-2 data type of the pixels */
  uint32_t (*frame_clks)(void);        /* frame period in timing_hz clocks */
  uint32_t (*line_clks)(void);         /* CSI-2 line period in timing_hz clocks */
  uint32_t (*ob_lines)(void);          /* optical black lines (0x37) per frame */
  void (*print_timing)(uint32_t form); /* CAM_TIMING_* */
  int (*read)(uint16_t reg, uint8_t *val);
  int (*write)(uint16_t reg, uint8_t val);
} cam_sensor_t;

extern const cam_sensor_t cam_imx219;
extern const cam_sensor_t cam_imx274;

/* Result of cam_sensor_detect() */
typedef struct {
  const cam_sensor_t *sensor; /* the one found, else cam_imx219 (formulas, messages) */
  bool found;
  uint16_t id;                /* id of the sensor found */
  int r219;                   /* imx219_probe(): I2C_OK or an error */
  uint16_t id219;             /* its id when r219 == I2C_OK */
  bool tried274;              /* the IMX274 was probed (the IMX219 path got no answer) */
  int r274;
  uint16_t id274;
  uint32_t i2c_hz;            /* I2C0 clock left set: 400 kHz, 100 kHz with the IMX274 */
} cam_detect_t;

/* I2C0 must be enabled at 400 kHz. First the KV260 path (TCA9546A + IMX219,
 * imx219_probe(): powers PA7 = RPI_ENABLE), and only when nothing answers
 * there the IMX274 at 100 kHz (XCLR = PA7 reset, I2C 0x1A, reset default
 * signature); I2C0 stays at 100 kHz when it is found. */
void cam_sensor_detect(cam_detect_t *d);

/* No sensor found (d->found false): one line per sensor tried, what
 * answered and what it read:
 *   "camera: no IMX219 on I2C (error -1)" or "camera: unknown sensor id 0123"
 *   "camera: no IMX274 on I2C (error -1)" or "camera: unknown sensor at 0x1a:
 *   MDSEL1..4 03 31 00 09, HMAX 0104, VMAX 000907 (IMX274 after reset: ...)"
 * (imx274_probe_regs(): the registers the probe compares, and the BLKLEVEL
 * read back when they matched). */
void cam_print_not_found(const cam_detect_t *d);

/* No sensor found and a 4 lane receiver (Huins camera build): prints
 * PRSNT_M2C_L of FMC+01, GPIO PB5 (0 = module present), as a hint. */
void cam_print_prsnt(uint32_t rx_lanes);

/* Huins camera build (bow32_huins_vp1902_cam_top): GPIO PA5 (OUT & DIR) is
 * burst_rst_en_i of its Versal XPHY (BurstRxRst: the RX FIFOs restart at every
 * HS burst). CAM_BURST_RST 1 (default): cam_rx_start() sets PA5 = 1, the FIFO
 * latency stays at 0..3 words; with the driver's SETTLE of 95 ns the board
 * (2026-11-10, IMX274 at 4 x 1440 Mbit/s) ran clean for more than 3.2 M
 * bursts, and every SETTLE from 65 to 170 ns was clean. 0: PA5 = 0 (like the
 * PHY of AMD): on the board the link broke for good at the first receiver
 * re-enable during a stream (lane 0 SOT / ECC / CRC, SKEW and FRAME errors
 * until PA5 = 1 again), at every SETTLE: do not use it on silicon. The
 * option stays for the simulation, whose PHY model runs clean with it at
 * SETTLE 115 ns (make -C sim run TEST=csi2_274 FW=brst0: model only;
 * docs/camera_huins.md 6.3, docs/ip/csi2rx.md). */
#ifndef CAM_BURST_RST
#define CAM_BURST_RST 1
#endif

/* Receiver start for a stream of s with data type dt: bow_csi2rx_start() with
 * the lanes and lane rate of s. Before it, on the Huins camera build only
 * (Versal XPHY: INFO.DLY_VID = 1), PA5 = CAM_BURST_RST; the GPIOs of other
 * builds are not touched. Returns what bow_csi2rx_start() returns. */
int cam_rx_start(const cam_sensor_t *s, uint32_t dt);

/* Stream off and receiver stop (s NULL: receiver only). IMX219: stream off,
 * then bow_csi2rx_stop() waits for the frame end. IMX274 (stops at once):
 * the next frame end, the receiver off, then the sensor to standby (its
 * lanes drop to LP-00 there, which the receiver would take for an error). */
void cam_stream_stop(const cam_sensor_t *s, uint32_t timeout_ms);

static inline uint32_t cam_lane_rate(const cam_sensor_t *s) {
  return s->lane_rate_mbps * 1000000u;
}
/* Frame period (us), CSI-2 line period (ns), frame rate (rounded down). */
static inline uint32_t cam_frame_us(const cam_sensor_t *s) {
  return (uint32_t)((uint64_t)s->frame_clks() * 1000000u / s->timing_hz);
}
static inline uint32_t cam_line_ns(const cam_sensor_t *s) {
  return (uint32_t)((uint64_t)s->line_clks() * 1000000000u / s->timing_hz);
}
static inline uint32_t cam_fps(const cam_sensor_t *s) {
  uint32_t f = s->frame_clks();
  return f ? s->timing_hz / f : 0;
}

#endif /* CAM_SENSOR_H_ */
