/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * I2C master driver. Each CMD write sends (optionally) a START, one byte and
 * (optionally) a STOP; the driver waits for STATUS.DONE after every byte.
 */
#include "bow_i2c.h"

#include "bow_sysctrl.h"
#include "bow_time.h"

void bow_i2c_init(bow_i2c_regs_t *i2c, uint32_t scl_hz) {
  uint32_t div = (SYSCTRL->CLK_FREQ + 2u * scl_hz) / (4u * scl_hz);
  if (div == 0) div = 1;
  if (div > 0xFFFF) div = 0xFFFF;
  i2c->CTRL = 0;
  i2c->CTRL = I2C_CTRL_DIV(div) | I2C_CTRL_EN;
}

/* One command; returns I2C_OK, I2C_ENACK (written byte not acknowledged)
 * or I2C_ETIMEOUT. A byte takes 36 quarter periods: allow 100x that. */
static int i2c_cmd(bow_i2c_regs_t *i2c, uint32_t cmd, uint8_t *rx) {
  uint32_t div = i2c->CTRL >> 16;
  uint32_t limit = 3600u * div + 1000u;
  uint32_t start = bow_cycles();
  uint32_t s;
  i2c->CMD = cmd;
  while (!((s = i2c->STATUS) & I2C_STATUS_DONE)) {
    if ((uint32_t)(bow_cycles() - start) > limit) {
      i2c->CTRL &= ~I2C_CTRL_EN; /* release the bus */
      i2c->CTRL |= I2C_CTRL_EN;
      return I2C_ETIMEOUT;
    }
  }
  if (rx) *rx = (uint8_t)I2C_STATUS_RX(s);
  return ((cmd & I2C_CMD_WRITE) && (s & I2C_STATUS_NACK)) ? I2C_ENACK : I2C_OK;
}

static int i2c_stop(bow_i2c_regs_t *i2c) { return i2c_cmd(i2c, I2C_CMD_STOP, 0); }

/* START + address byte. */
static int i2c_address(bow_i2c_regs_t *i2c, uint8_t addr, bool read) {
  int r = i2c_cmd(i2c, I2C_CMD_START | I2C_CMD_WRITE | ((uint32_t)addr << 1) | (read ? 1u : 0u), 0);
  if (r != I2C_OK) i2c_stop(i2c);
  return r;
}

static int i2c_send(bow_i2c_regs_t *i2c, const uint8_t *data, uint32_t len) {
  for (uint32_t i = 0; i < len; i++) {
    int r = i2c_cmd(i2c, I2C_CMD_WRITE | data[i], 0);
    if (r != I2C_OK) {
      i2c_stop(i2c);
      return r;
    }
  }
  return I2C_OK;
}

/* Read len bytes; the last one is answered with NACK and followed by STOP. */
static int i2c_receive(bow_i2c_regs_t *i2c, uint8_t *data, uint32_t len) {
  for (uint32_t i = 0; i < len; i++) {
    bool last = (i + 1 == len);
    int r = i2c_cmd(i2c, I2C_CMD_READ | (last ? (I2C_CMD_NACK | I2C_CMD_STOP) : 0), &data[i]);
    if (r != I2C_OK) return r;
  }
  return I2C_OK;
}

int bow_i2c_write(bow_i2c_regs_t *i2c, uint8_t addr, const uint8_t *data, uint32_t len) {
  int r = i2c_address(i2c, addr, false);
  if (r == I2C_OK) r = i2c_send(i2c, data, len);
  if (r == I2C_OK) r = i2c_stop(i2c);
  return r;
}

int bow_i2c_read(bow_i2c_regs_t *i2c, uint8_t addr, uint8_t *data, uint32_t len) {
  int r = i2c_address(i2c, addr, true);
  if (r != I2C_OK) return r;
  if (len == 0) return i2c_stop(i2c);
  return i2c_receive(i2c, data, len);
}

int bow_i2c_write_read(bow_i2c_regs_t *i2c, uint8_t addr, const uint8_t *wdata, uint32_t wlen,
                       uint8_t *rdata, uint32_t rlen) {
  int r = i2c_address(i2c, addr, false);
  if (r == I2C_OK) r = i2c_send(i2c, wdata, wlen);
  if (r != I2C_OK) return r;
  return bow_i2c_read(i2c, addr, rdata, rlen); /* repeated START */
}

bool bow_i2c_probe(bow_i2c_regs_t *i2c, uint8_t addr) {
  int r = i2c_address(i2c, addr, false);
  if (r == I2C_OK) i2c_stop(i2c);
  return r == I2C_OK;
}
