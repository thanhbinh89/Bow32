/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * UART driver (docs/ip/uart.md).
 */
#ifndef BOW_UART_H_
#define BOW_UART_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t DATA;   /* 0x00 */
  volatile uint32_t STATUS; /* 0x04 */
  volatile uint32_t CTRL;   /* 0x08 */
  volatile uint32_t BAUD;   /* 0x0C */
} bow_uart_regs_t;

#define UART0 ((bow_uart_regs_t *)BOW32_UART0_BASE)
#define UART1 ((bow_uart_regs_t *)BOW32_UART1_BASE)

#define UART_DATA_RX_EMPTY (1u << 31)

#define UART_STATUS_TX_FULL   (1u << 0)
#define UART_STATUS_TX_EMPTY  (1u << 1)
#define UART_STATUS_TX_IDLE   (1u << 2)
#define UART_STATUS_RX_VALID  (1u << 3)
#define UART_STATUS_RX_FULL   (1u << 4)
#define UART_STATUS_RX_OVR    (1u << 5)
#define UART_STATUS_FRAME_ERR (1u << 6)

#define UART_CTRL_TX_EN    (1u << 0)
#define UART_CTRL_RX_EN    (1u << 1)
#define UART_CTRL_RX_IE    (1u << 2)
#define UART_CTRL_TX_IE    (1u << 3)
#define UART_CTRL_RX_FLUSH (1u << 4)
#define UART_CTRL_TX_FLUSH (1u << 5)

/* Configure baud rate (clock taken from SYSCTRL.CLK_FREQ), enable TX/RX. */
void bow_uart_init(bow_uart_regs_t *uart, uint32_t baud);
void bow_uart_putc(bow_uart_regs_t *uart, char c);
void bow_uart_puts(bow_uart_regs_t *uart, const char *s);
void bow_uart_write(bow_uart_regs_t *uart, const void *buf, uint32_t len);
/* Returns the received byte, or -1 when the RX FIFO is empty. */
int bow_uart_getc_nb(bow_uart_regs_t *uart);
/* Blocking receive. */
char bow_uart_getc(bow_uart_regs_t *uart);
/* Wait until the last bit has left the transmitter. */
void bow_uart_flush(bow_uart_regs_t *uart);

#endif /* BOW_UART_H_ */
