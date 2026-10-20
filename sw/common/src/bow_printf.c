/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 */
#include "bow_printf.h"

#include <stdbool.h>
#include <stdint.h>

static bow_uart_regs_t *stdio_uart = UART0;

void bow_stdio_set_uart(bow_uart_regs_t *uart) { stdio_uart = uart; }

static void out_char(char c, int *count) {
  if (c == '\n') bow_uart_putc(stdio_uart, '\r');
  bow_uart_putc(stdio_uart, c);
  (*count)++;
}

static void out_num(uint32_t v, unsigned base, bool upper, int width, char pad, bool neg,
                    int *count) {
  char buf[12];
  int n = 0;
  const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  do {
    buf[n++] = digits[v % base];
    v /= base;
  } while (v);
  if (neg) {
    if (pad == '0') {
      out_char('-', count);
      width--;
    } else {
      buf[n++] = '-';
    }
  }
  while (width-- > n) out_char(pad, count);
  while (n) out_char(buf[--n], count);
}

int bow_vprintf(const char *fmt, va_list ap) {
  int count = 0;
  for (; *fmt; fmt++) {
    if (*fmt != '%') {
      out_char(*fmt, &count);
      continue;
    }
    fmt++;
    char pad = ' ';
    int width = 0;
    if (*fmt == '0') {
      pad = '0';
      fmt++;
    }
    while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
    while (*fmt == 'l') fmt++; /* 32 bit target: long == int */

    switch (*fmt) {
      case 'c':
        out_char((char)va_arg(ap, int), &count);
        break;
      case 's': {
        const char *s = va_arg(ap, const char *);
        if (!s) s = "(null)";
        int len = 0;
        while (s[len]) len++;
        while (width-- > len) out_char(' ', &count);
        while (*s) out_char(*s++, &count);
        break;
      }
      case 'd':
      case 'i': {
        int32_t v = va_arg(ap, int32_t);
        out_num(v < 0 ? 0u - (uint32_t)v : (uint32_t)v, 10, false, width, pad, v < 0, &count);
        break;
      }
      case 'u':
        out_num(va_arg(ap, uint32_t), 10, false, width, pad, false, &count);
        break;
      case 'x':
      case 'X':
        out_num(va_arg(ap, uint32_t), 16, *fmt == 'X', width, pad, false, &count);
        break;
      case 'p':
        out_char('0', &count);
        out_char('x', &count);
        out_num((uint32_t)(uintptr_t)va_arg(ap, void *), 16, false, 8, '0', false, &count);
        break;
      case '%':
        out_char('%', &count);
        break;
      case '\0':
        return count;
      default:
        out_char('%', &count);
        out_char(*fmt, &count);
        break;
    }
  }
  return count;
}

int bow_printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = bow_vprintf(fmt, ap);
  va_end(ap);
  return n;
}

void bow_puts(const char *s) { bow_uart_puts(stdio_uart, s); }
