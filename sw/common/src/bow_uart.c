/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 */
#include "bow_uart.h"

#include "bow_sysctrl.h"

void bow_uart_init(bow_uart_regs_t *uart, uint32_t baud) {
  uint32_t clk = SYSCTRL->CLK_FREQ;
  uart->CTRL = UART_CTRL_RX_FLUSH | UART_CTRL_TX_FLUSH;
  uart->BAUD = (clk + baud / 2) / baud;
  uart->STATUS = UART_STATUS_RX_OVR | UART_STATUS_FRAME_ERR;
  uart->CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN;
}

void bow_uart_putc(bow_uart_regs_t *uart, char c) {
  while (uart->STATUS & UART_STATUS_TX_FULL) {
  }
  uart->DATA = (uint8_t)c;
}

void bow_uart_puts(bow_uart_regs_t *uart, const char *s) {
  while (*s) {
    if (*s == '\n') bow_uart_putc(uart, '\r');
    bow_uart_putc(uart, *s++);
  }
}

void bow_uart_write(bow_uart_regs_t *uart, const void *buf, uint32_t len) {
  const uint8_t *p = buf;
  while (len--) bow_uart_putc(uart, (char)*p++);
}

int bow_uart_getc_nb(bow_uart_regs_t *uart) {
  uint32_t d = uart->DATA;
  return (d & UART_DATA_RX_EMPTY) ? -1 : (int)(d & 0xFFu);
}

char bow_uart_getc(bow_uart_regs_t *uart) {
  int c;
  while ((c = bow_uart_getc_nb(uart)) < 0) {
  }
  return (char)c;
}

void bow_uart_flush(bow_uart_regs_t *uart) {
  while (!(uart->STATUS & UART_STATUS_TX_IDLE)) {
  }
}
