/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * GPIO / IOPAD demo: a small command shell on UART0 to drive and read the two
 * GPIO ports, with edge interrupts and a blinker. Type `h` for help.
 *
 * Kria KV260, PMOD J2: PA0..PA3 = pins 2/4/6/8, PB0/PB1 = pins 5/7 (UART1
 * TX/RX until `f b 0`). See docs/fpga_kria.md.
 *
 * Shows: GPIO registers (DIR, OUT_SET/CLR/TGL, OD, AF), edge interrupts with
 * a W1C status register, an ISR that hands events over to the main loop.
 */
#include "bow32.h"

static const char help[] =
    "commands (<p> = a|b, <hex> = pin mask, e.g. 0f):\n"
    "  r                  read both ports\n"
    "  d <p> <hex>        DIR (1 = output)\n"
    "  o <p> <hex>        OUT\n"
    "  s|c|t <p> <hex>    set / clear / toggle OUT bits\n"
    "  m <p> <hex>        OD (1 = open-drain)\n"
    "  f <p> <hex>        AF (PB0/PB1 = UART1 TX/RX)\n"
    "  i <p> <hex> [r|f]  interrupt on rising / falling / both edges (0 = off)\n"
    "  b [<p> <hex>]      blink the pins every 250 ms (no argument: stop)\n"
    "  u                  send a line on UART1\n";

static bow_gpio_regs_t *const ports[2] = {GPIOA, GPIOB};

static volatile uint32_t irq_pending[2]; /* edges reported by the ISR, per port */

void bow_irq_fast_handler(unsigned line) {
  unsigned p;
  if (line == BOW32_IRQ_FAST_GPIOA) {
    p = 0;
  } else if (line == BOW32_IRQ_FAST_GPIOB) {
    p = 1;
  } else {
    bow_irq_fast_disable(line);
    return;
  }
  uint32_t status = ports[p]->IRQ_STATUS;
  ports[p]->IRQ_STATUS = status; /* acknowledge (write 1 to clear) */
  irq_pending[p] |= status;
}

/* ------------------------------------------------------------------ parsing */
static const char *skip_spaces(const char *s) {
  while (*s == ' ') s++;
  return s;
}

/* Port letter a|b -> 0|1, -1 if none. */
static int parse_port(const char **s) {
  const char *p = skip_spaces(*s);
  int port = (*p == 'a' || *p == 'A') ? 0 : (*p == 'b' || *p == 'B') ? 1 : -1;
  if (port >= 0) *s = p + 1;
  return port;
}

/* Hex number -> *v; returns the rest of the string, or NULL if there is none. */
static const char *parse_hex(const char *s, uint32_t *v) {
  uint32_t x = 0;
  const char *start = s = skip_spaces(s);
  for (;; s++) {
    unsigned d;
    if (*s >= '0' && *s <= '9') {
      d = (unsigned)(*s - '0');
    } else if (*s >= 'a' && *s <= 'f') {
      d = (unsigned)(*s - 'a' + 10);
    } else if (*s >= 'A' && *s <= 'F') {
      d = (unsigned)(*s - 'A' + 10);
    } else {
      break;
    }
    x = (x << 4) | d;
  }
  if (s == start) return NULL;
  *v = x;
  return s;
}

/* ----------------------------------------------------------------- commands */
static uint32_t blink_mask, blink_last;
static unsigned blink_port;

static void print_ports(void) {
  for (unsigned p = 0; p < 2; p++) {
    bow_gpio_regs_t *g = ports[p];
    bow_printf("%c: in=%02x out=%02x dir=%02x od=%02x af=%02x ie=%02x\n", 'A' + p, g->IN,
               g->OUT, g->DIR, g->OD, g->AF, g->IRQ_EN);
  }
}

/* Returns false for a malformed command. */
static bool execute(const char *s) {
  uint32_t v;
  int p;

  s = skip_spaces(s);
  char cmd = *s;
  if (cmd != '\0') s++;

  switch (cmd) {
    case 'h':
      bow_puts(help);
      return true;
    case 'r':
      print_ports();
      return true;
    case 'u':
      bow_uart_puts(UART1, "uart1: hello from PB0\n");
      return true;
    case 'b':
      p = parse_port(&s);
      if (p < 0) {
        blink_mask = 0;
        return true;
      }
      if (!parse_hex(s, &v)) return false;
      blink_port = (unsigned)p;
      blink_mask = v;
      bow_gpio_output(ports[p], v);
      blink_last = bow_cycles();
      return true;
    default:
      break;
  }

  p = parse_port(&s);
  if (p < 0 || !(s = parse_hex(s, &v))) return false;
  bow_gpio_regs_t *g = ports[p];

  switch (cmd) {
    case 'd': g->DIR = v; break;
    case 'o': g->OUT = v; break;
    case 's': g->OUT_SET = v; break;
    case 'c': g->OUT_CLR = v; break;
    case 't': g->OUT_TGL = v; break;
    case 'm': g->OD = v; break;
    case 'f': g->AF = v; break;
    case 'i': {
      s = skip_spaces(s);
      uint32_t edges = (*s == 'r') ? GPIO_EDGE_RISE : (*s == 'f') ? GPIO_EDGE_FALL : GPIO_EDGE_BOTH;
      bow_gpio_irq_config(g, ~0u, GPIO_EDGE_NONE);
      bow_gpio_irq_config(g, v, edges);
      break;
    }
    default:
      return false;
  }
  return true;
}

/* --------------------------------------------------------------------- main */
int main(void) {
  static char line[40];
  unsigned len = 0;
  int prev = 0;

  uint32_t baud = SYSCTRL->BOOT_BAUD;
  bow_uart_init(UART0, baud);
  bow_uart_init(UART1, baud);

  bow_printf("\ngpio_demo: GPIOA/GPIOB (IOPAD), type h for help\n");
  bow_printf("KV260 PMOD J2: PA0..PA3 = pins 2/4/6/8, PB0/PB1 = pins 5/7 (UART1)\n");

  bow_irq_fast_enable(BOW32_IRQ_FAST_GPIOA);
  bow_irq_fast_enable(BOW32_IRQ_FAST_GPIOB);
  bow_irq_global_enable();

  bow_puts("> ");
  for (;;) {
    int c = bow_uart_getc_nb(UART0);
    if (c == '\n' && prev == '\r') {
      /* second half of a CR LF line ending */
    } else if (c == '\r' || c == '\n') {
      line[len] = '\0';
      bow_puts("\n");
      if (len != 0) bow_puts(execute(line) ? "ok\n" : "?\n");
      bow_puts("> ");
      len = 0;
    } else if ((c == '\b' || c == 0x7f) && len != 0) {
      len--;
      bow_uart_puts(UART0, "\b \b");
    } else if (c >= ' ' && c < 0x7f && len < sizeof(line) - 1) {
      line[len++] = (char)c;
      bow_uart_putc(UART0, (char)c); /* echo */
    }
    if (c >= 0) prev = c;

    for (unsigned p = 0; p < 2; p++) {
      if (irq_pending[p]) {
        bow_irq_global_disable();
        uint32_t pins = irq_pending[p];
        irq_pending[p] = 0;
        bow_irq_global_enable();
        bow_printf("irq %c: pins=%02x in=%02x\n", 'A' + p, pins, ports[p]->IN);
      }
    }

    if (blink_mask && (uint32_t)(bow_cycles() - blink_last) >= bow_clk_hz() / 4) {
      blink_last = bow_cycles();
      bow_gpio_toggle(ports[blink_port], blink_mask);
    }
  }
}
