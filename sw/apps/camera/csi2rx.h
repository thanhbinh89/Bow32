/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * AMD MIPI CSI-2 RX Subsystem (PG232) behind the Bow32 AXI4-Lite window.
 * Only in the camera build of the KV260 (hw/fpga/kv260_cam): elsewhere the
 * window answers with bus errors and csi2rx_probe() returns false.
 *
 * Register offsets follow PG232 and the Linux driver xilinx-csi2rxss.c.
 */
#ifndef CSI2RX_H_
#define CSI2RX_H_

#include <stdbool.h>
#include <stdint.h>

#include "bow32_memmap.h"

#define CSI2RX_BASE (BOW32_AXIL_BASE + 0x0000u)

#define CSI_CCR       0x00 /* core configuration: [0] enable [1] soft reset */
#define CSI_PCR       0x04 /* protocol configuration: [1:0] active lanes - 1, [4:3] max lanes - 1 */
#define CSI_CSR       0x10 /* core status: [0] reset/disable in progress [31:16] packet count */
#define CSI_GIER      0x20
#define CSI_ISR       0x24 /* interrupt status, W1C */
#define CSI_IER       0x28
#define CSI_SPKTR     0x30 /* generic short packet */
#define CSI_CLKINFR   0x3C /* clock lane: [1] stop state */
#define CSI_DLXINFR(n) (0x40 + 4 * (n)) /* data lane n: [5] stop [1] SoT error [0] SoT sync error */
#define CSI_VCXINF1R(vc) (0x60 + 8 * (vc)) /* [31:16] line count [15:0] byte count */
#define CSI_VCXINF2R(vc) (0x64 + 8 * (vc)) /* [5:0] data type */

#define CSI_CCR_ENABLE    (1u << 0)
#define CSI_CCR_SOFTRESET (1u << 1)
#define CSI_CSR_RIPCD     (1u << 0)

#define CSI_ISR_FR         (1u << 31) /* frame received */
#define CSI_ISR_ERRORS     0x00003FFFu /* SoT, ECC, CRC, data type, frame sync/level */

/* true if the subsystem answers; *lanes = active lanes. */
bool csi2rx_probe(uint32_t *lanes);
/* Soft reset, then enable (true) or keep disabled. */
bool csi2rx_start(bool enable);
void csi2rx_print_status(void);

#endif /* CSI2RX_H_ */
