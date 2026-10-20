/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Interrupt example: UART1 RX interrupts fill a ring buffer, the main loop
 * sleeps (WFI) and echoes the received bytes in upper case on UART1, while
 * statistics are printed on UART0.
 *
 * Shows: enabling a fast interrupt (mie) + global interrupts (mstatus.MIE),
 * overriding the weak bow_irq_fast_handler(), WFI.
 */
#include "bow32.h"

#define RING_SIZE 64u

static volatile uint8_t ring[RING_SIZE];
static volatile uint32_t ring_head, ring_tail;
static volatile uint32_t irq_count;

void bow_irq_fast_handler(unsigned line) {
  if (line == BOW32_IRQ_FAST_UART1) {
    int c;
    while ((c = bow_uart_getc_nb(UART1)) >= 0) {
      uint32_t next = (ring_head + 1) % RING_SIZE;
      if (next != ring_tail) {
        ring[ring_head] = (uint8_t)c;
        ring_head = next;
      }
    }
    irq_count++;
  } else {
    bow_irq_fast_disable(line);
  }
}

int main(void) {
  uint32_t baud = SYSCTRL->BOOT_BAUD;
  bow_uart_init(UART0, baud);
  bow_uart_init(UART1, baud);

  bow_printf("\nuart_irq: type on UART1, characters come back in upper case\n");
  bow_uart_puts(UART1, "\nuart_irq ready\n");

  UART1->CTRL |= UART_CTRL_RX_IE;
  bow_irq_fast_enable(BOW32_IRQ_FAST_UART1);
  bow_irq_global_enable();

  uint32_t echoed = 0;
  for (;;) {
    bow_wfi();  /* sleep until the next interrupt */
    while (ring_tail != ring_head) {
      char c = (char)ring[ring_tail];
      ring_tail = (ring_tail + 1) % RING_SIZE;
      if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
      bow_uart_putc(UART1, c);
      echoed++;
    }
    bow_printf("irqs=%u echoed=%u\n", irq_count, echoed);
  }
}
