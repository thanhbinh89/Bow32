/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef BOOTROM_LOADER_H_
#define BOOTROM_LOADER_H_

#include <stdbool.h>
#include <stdint.h>

#define BOW32_ROM_VERSION 0x00010000u /* 1.0.0: (major << 16) | (minor << 8) | patch */

/* Wait up to `ms` milliseconds for a request start byte on UART0. */
bool loader_wait_for_host(uint32_t ms);

/* Serve loader requests forever (BOOT/RESET commands reset the chip).
 * sof_seen: the start byte of the first request was already consumed. */
void loader_run(bool sof_seen) __attribute__((noreturn));

#endif /* BOOTROM_LOADER_H_ */
