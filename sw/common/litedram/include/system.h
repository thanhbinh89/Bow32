/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Stand-in for LiteX's <system.h> (CPU cache helpers), which the generated
 * LiteDRAM csr.h includes. Bow32 has no data cache and the LiteDRAM headers
 * use nothing from it: intentionally empty. Only on the include path of the
 * LiteDRAM glue files of sw/apps/ddr (sw/apps/ddr/Makefile).
 */
#ifndef BOW_LD_SYSTEM_H_
#define BOW_LD_SYSTEM_H_

#endif /* BOW_LD_SYSTEM_H_ */
