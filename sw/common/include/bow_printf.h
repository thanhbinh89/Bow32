/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Minimal printf on the console UART (UART0 by default).
 * Supports %c %s %d %i %u %x %X %p %% with optional '0' flag and width,
 * e.g. "%08x". No floating point, no long long.
 */
#ifndef BOW_PRINTF_H_
#define BOW_PRINTF_H_

#include <stdarg.h>

#include "bow_uart.h"

/* Select the UART used by bow_printf()/bow_puts() (default UART0). */
void bow_stdio_set_uart(bow_uart_regs_t *uart);

/* Not declared with __attribute__((format)): on RISC-V ELF toolchains
 * uint32_t is "unsigned long", and %x/%u here accept any 32 bit integer. */
int bow_printf(const char *fmt, ...);
int bow_vprintf(const char *fmt, va_list ap);
void bow_puts(const char *s); /* no newline appended */

#endif /* BOW_PRINTF_H_ */
