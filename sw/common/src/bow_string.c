/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Freestanding implementations of the few libc functions the compiler may
 * emit calls to (struct copies, array initialisation).
 *
 * The 'no-tree-loop-distribute-patterns' attribute stops GCC from turning the
 * loops below back into calls to memset/memcpy (infinite recursion).
 */
#include <stddef.h>
#include <stdint.h>

#define NO_LIBCALL __attribute__((optimize("no-tree-loop-distribute-patterns")))

NO_LIBCALL void *memcpy(void *dst, const void *src, size_t n) {
  uint8_t *d = dst;
  const uint8_t *s = src;
  while (n--) *d++ = *s++;
  return dst;
}

NO_LIBCALL void *memmove(void *dst, const void *src, size_t n) {
  uint8_t *d = dst;
  const uint8_t *s = src;
  if (d < s) {
    while (n--) *d++ = *s++;
  } else {
    while (n--) d[n] = s[n];
  }
  return dst;
}

NO_LIBCALL void *memset(void *dst, int c, size_t n) {
  uint8_t *d = dst;
  while (n--) *d++ = (uint8_t)c;
  return dst;
}

NO_LIBCALL int memcmp(const void *a, const void *b, size_t n) {
  const uint8_t *x = a, *y = b;
  for (; n; n--, x++, y++) {
    if (*x != *y) return *x - *y;
  }
  return 0;
}

NO_LIBCALL size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}
