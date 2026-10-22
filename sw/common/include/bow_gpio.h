/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * GPIO / IOPAD driver (docs/ip/gpio.md).
 */
#ifndef BOW_GPIO_H_
#define BOW_GPIO_H_

#include <stdint.h>

#include "bow32_memmap.h"

typedef struct {
  volatile uint32_t IN;         /* 0x00 R     pin levels */
  volatile uint32_t OUT;        /* 0x04 RW    output data */
  volatile uint32_t OUT_SET;    /* 0x08 W     OUT |= value */
  volatile uint32_t OUT_CLR;    /* 0x0C W     OUT &= ~value */
  volatile uint32_t OUT_TGL;    /* 0x10 W     OUT ^= value */
  volatile uint32_t DIR;        /* 0x14 RW    1 = output */
  volatile uint32_t OD;         /* 0x18 RW    1 = open-drain */
  volatile uint32_t AF;         /* 0x1C RW    1 = alternate function */
  volatile uint32_t IRQ_EN;     /* 0x20 RW    */
  volatile uint32_t IRQ_RISE;   /* 0x24 RW    */
  volatile uint32_t IRQ_FALL;   /* 0x28 RW    */
  volatile uint32_t IRQ_STATUS; /* 0x2C R/W1C */
} bow_gpio_regs_t;

#define GPIOA ((bow_gpio_regs_t *)BOW32_GPIOA_BASE)
#define GPIOB ((bow_gpio_regs_t *)BOW32_GPIOB_BASE)

#define GPIO_PIN(n) (1u << (n))

/* Alternate functions of port B (GPIOB->AF bits, both set after reset) */
#define GPIOB_AF_UART1_TX GPIO_PIN(0)
#define GPIOB_AF_UART1_RX GPIO_PIN(1)

/* Edges for bow_gpio_irq_config() */
#define GPIO_EDGE_NONE 0u
#define GPIO_EDGE_RISE 1u
#define GPIO_EDGE_FALL 2u
#define GPIO_EDGE_BOTH 3u

static inline void bow_gpio_output(bow_gpio_regs_t *gpio, uint32_t pins) { gpio->DIR |= pins; }
static inline void bow_gpio_input(bow_gpio_regs_t *gpio, uint32_t pins) { gpio->DIR &= ~pins; }
static inline void bow_gpio_set(bow_gpio_regs_t *gpio, uint32_t pins) { gpio->OUT_SET = pins; }
static inline void bow_gpio_clear(bow_gpio_regs_t *gpio, uint32_t pins) { gpio->OUT_CLR = pins; }
static inline void bow_gpio_toggle(bow_gpio_regs_t *gpio, uint32_t pins) { gpio->OUT_TGL = pins; }
static inline uint32_t bow_gpio_read(bow_gpio_regs_t *gpio) { return gpio->IN; }

/* Interrupt on `edges` (GPIO_EDGE_*) of `pins`; GPIO_EDGE_NONE disables them.
 * Events seen before the call are dropped. The CPU side still needs
 * bow_irq_fast_enable(BOW32_IRQ_FAST_GPIOx) and bow_irq_global_enable(). */
static inline void bow_gpio_irq_config(bow_gpio_regs_t *gpio, uint32_t pins, uint32_t edges) {
  gpio->IRQ_EN &= ~pins;
  gpio->IRQ_RISE = (edges & GPIO_EDGE_RISE) ? (gpio->IRQ_RISE | pins) : (gpio->IRQ_RISE & ~pins);
  gpio->IRQ_FALL = (edges & GPIO_EDGE_FALL) ? (gpio->IRQ_FALL | pins) : (gpio->IRQ_FALL & ~pins);
  gpio->IRQ_STATUS = pins;
  if (edges != GPIO_EDGE_NONE) gpio->IRQ_EN |= pins;
}

#endif /* BOW_GPIO_H_ */
