/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Application image header, placed at the start of the flash.
 *
 * The linker script reserves the header (section .image_hdr) and the build
 * patches 'size' and 'crc32' with tools/bow32_image.py. The boot ROM only
 * jumps to an image whose header and CRC are valid (docs/boot.md).
 */
#ifndef BOW32_IMAGE_H_
#define BOW32_IMAGE_H_

#include <stdint.h>

#define BOW32_IMAGE_MAGIC       0x32334F42u /* bytes "BO32" */
#define BOW32_IMAGE_HDR_VERSION 1u
#define BOW32_IMAGE_HDR_SIZE    32u

typedef struct {
  uint32_t magic;       /* BOW32_IMAGE_MAGIC */
  uint32_t hdr_version; /* BOW32_IMAGE_HDR_VERSION */
  uint32_t size;        /* payload size in bytes (everything after the header) */
  uint32_t crc32;       /* CRC-32 of the payload */
  uint32_t entry;       /* absolute address of the first instruction */
  uint32_t reserved[3];
} bow32_image_hdr_t;

_Static_assert(sizeof(bow32_image_hdr_t) == BOW32_IMAGE_HDR_SIZE, "header size");

#endif /* BOW32_IMAGE_H_ */
