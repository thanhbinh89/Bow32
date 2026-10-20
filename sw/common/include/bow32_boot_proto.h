/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Boot ROM UART loader protocol (docs/boot.md). The host side lives in
 * tools/bow32_flash.py; keep both in sync.
 *
 * All multi-byte fields are little endian. CRC is CRC-32 (zlib.crc32).
 *
 *   request : SOF_REQ  CMD     LEN[2] PAYLOAD[LEN] CRC32[4] (over CMD..PAYLOAD)
 *   response: SOF_RSP  STATUS  LEN[2] PAYLOAD[LEN] CRC32[4] (over STATUS..PAYLOAD)
 *
 * The SOF bytes are outside the ASCII range so they never appear in the text
 * the ROM prints before entering the loader.
 */
#ifndef BOW32_BOOT_PROTO_H_
#define BOW32_BOOT_PROTO_H_

#define BOOT_SOF_REQ 0xA5u
#define BOOT_SOF_RSP 0xB5u

#define BOOT_MAX_DATA    256u                  /* bytes per READ/WRITE */
#define BOOT_MAX_PAYLOAD (8u + BOOT_MAX_DATA)

/* Commands */
#define BOOT_CMD_INFO  0x01u /* -> chip_id, rom_version, flash_base, flash_size,
                                 page_size, max_data, sram_base, sram_size     */
#define BOOT_CMD_ERASE 0x02u /* addr, len (len = 0xFFFFFFFF: mass erase)    */
#define BOOT_CMD_WRITE 0x03u /* addr, data[] (word aligned, len % 4 == 0)   */
#define BOOT_CMD_READ  0x04u /* addr, len -> data[]                         */
#define BOOT_CMD_CRC   0x05u /* addr, len -> crc32                          */
#define BOOT_CMD_BOOT  0x06u /* reset and start the flash image             */
#define BOOT_CMD_RESET 0x07u /* plain reset (normal boot sequence)          */

/* Status codes */
#define BOOT_OK          0x00u
#define BOOT_ERR_CRC     0x01u
#define BOOT_ERR_CMD     0x02u
#define BOOT_ERR_ARG     0x03u
#define BOOT_ERR_FLASH   0x04u
#define BOOT_ERR_LEN     0x05u

#endif /* BOW32_BOOT_PROTO_H_ */
