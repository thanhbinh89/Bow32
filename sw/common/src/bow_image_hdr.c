/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Application image header (see bow32_image.h). 'size' and 'crc32' are
 * filled in after linking by tools/bow32_image.py.
 */
#include "bow32_image.h"

extern void _start(void);

__attribute__((section(".image_hdr"), used)) const bow32_image_hdr_t bow32_image_hdr = {
    .magic = BOW32_IMAGE_MAGIC,
    .hdr_version = BOW32_IMAGE_HDR_VERSION,
    .size = 0,
    .crc32 = 0,
    .entry = (uint32_t)(uintptr_t)&_start,
    .reserved = {0, 0, 0},
};
