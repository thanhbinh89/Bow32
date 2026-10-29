/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bus-error safe register access. A load or store to an address that answers
 * with a bus error (unmapped address, AXI4-Lite window without a device,
 * bridge timeout) normally ends in the fatal exception handler; these
 * functions return false instead.
 */
#ifndef BOW_PROBE_H_
#define BOW_PROBE_H_

#include <stdbool.h>
#include <stdint.h>

bool bow_probe_read32(uint32_t addr, uint32_t *value);
bool bow_probe_write32(uint32_t addr, uint32_t value);

#endif /* BOW_PROBE_H_ */
