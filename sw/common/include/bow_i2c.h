/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * I2C master driver (docs/ip/i2c.md). Blocking, one byte per command.
 */
#ifndef BOW_I2C_H_
#define BOW_I2C_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t CTRL;   /* 0x00 RW [0] EN [1] IE [31:16] DIV (quarter SCL period) */
  volatile uint32_t CMD;    /* 0x04 W  [7:0] data [8] START [9] STOP [10] WRITE [11] READ [12] NACK */
  volatile uint32_t STATUS; /* 0x08 R  [0] BUSY [1] NACK [2] DONE (W1C) [15:8] RX */
} bow_i2c_regs_t;

#define I2C0 ((bow_i2c_regs_t *)BOW32_I2C0_BASE)

#define I2C_CTRL_EN       (1u << 0)
#define I2C_CTRL_IE       (1u << 1)
#define I2C_CTRL_DIV(d)   ((uint32_t)(d) << 16)

#define I2C_CMD_START     (1u << 8)
#define I2C_CMD_STOP      (1u << 9)
#define I2C_CMD_WRITE     (1u << 10)
#define I2C_CMD_READ      (1u << 11)
#define I2C_CMD_NACK      (1u << 12)

#define I2C_STATUS_BUSY   (1u << 0)
#define I2C_STATUS_NACK   (1u << 1)
#define I2C_STATUS_DONE   (1u << 2)
#define I2C_STATUS_RX(s)  (((s) >> 8) & 0xFFu)

/* Return codes */
#define I2C_OK       0
#define I2C_ENACK   -1 /* address or data byte not acknowledged */
#define I2C_ETIMEOUT -2 /* bus stuck (e.g. SCL held low) */

/* Enable the controller with the given SCL frequency (e.g. 100000, 400000). */
void bow_i2c_init(bow_i2c_regs_t *i2c, uint32_t scl_hz);

/* addr = 7 bit device address. Every transfer ends with a STOP. */
int bow_i2c_write(bow_i2c_regs_t *i2c, uint8_t addr, const uint8_t *data, uint32_t len);
int bow_i2c_read(bow_i2c_regs_t *i2c, uint8_t addr, uint8_t *data, uint32_t len);
/* Write then read with a repeated START (register read of most sensors). */
int bow_i2c_write_read(bow_i2c_regs_t *i2c, uint8_t addr, const uint8_t *wdata, uint32_t wlen,
                       uint8_t *rdata, uint32_t rlen);
/* true if a device answers (ACK) at this address. */
bool bow_i2c_probe(bow_i2c_regs_t *i2c, uint8_t addr);

#endif /* BOW_I2C_H_ */
