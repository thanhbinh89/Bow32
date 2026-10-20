/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Hello world: prints chip information on UART0 and UART1, then echoes
 * whatever is typed on either UART. Typing 'B' on UART0 reboots into the
 * boot ROM UART loader.
 */
#include "bow32.h"

int main(void) {
  uint32_t baud = SYSCTRL->BOOT_BAUD;
  bow_uart_init(UART0, baud);
  bow_uart_init(UART1, baud);

  bow_printf("\nHello from Bow32!\n");
  bow_printf("  chip id   : %08x\n", SYSCTRL->CHIP_ID);
  bow_printf("  clock     : %u Hz\n", bow_clk_hz());
  bow_printf("  misa      : %08x\n", CSR_READ(misa));
  bow_printf("  flash     : %u KiB @ %08x\n", FLASH_CTRL->SIZE / 1024, BOW32_FLASH_BASE);
  bow_printf("  sram      : %u KiB @ %08x\n", BOW32_SRAM_SIZE / 1024, BOW32_SRAM_BASE);
  bow_printf("  boot cycle: %u\n", bow_cycles());
  bow_printf("Echo on UART0/UART1, 'B' on UART0 = reboot into the bootloader\n");

  bow_uart_puts(UART1, "\nHello from Bow32 on UART1!\n");

  for (;;) {
    int c = bow_uart_getc_nb(UART0);
    if (c == 'B') {
      bow_printf("\nrebooting into the UART loader...\n");
      bow_uart_flush(UART0);
      bow_system_reset(BOOT_FLAG_LOADER);
    }
    if (c >= 0) bow_uart_putc(UART0, (char)c);

    c = bow_uart_getc_nb(UART1);
    if (c >= 0) bow_uart_putc(UART1, (char)c);
  }
}
