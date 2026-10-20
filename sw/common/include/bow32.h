/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bow32 umbrella header: memory map, CSR helpers and all peripheral drivers.
 */
#ifndef BOW32_H_
#define BOW32_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bow32_memmap.h"
#include "bow32_csr.h"
#include "bow_sysctrl.h"
#include "bow_uart.h"
#include "bow_flash.h"
#include "bow_time.h"
#include "bow_printf.h"
#include "bow_crc32.h"

#define BOW_REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

#endif /* BOW32_H_ */
