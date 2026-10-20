/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Default trap handling. crt0.S saves the caller saved registers and calls
 * bow_trap_handler(); the value it returns is written back to mepc.
 *
 * Applications override the weak bow_irq_fast_handler() to handle the
 * peripheral interrupts (line numbers: BOW32_IRQ_FAST_* in bow32_memmap.h).
 */
#include "bow32.h"

__attribute__((weak)) void bow_irq_fast_handler(unsigned line) {
  /* Nobody handles this line: mask it to avoid an interrupt storm. */
  bow_irq_fast_disable(line);
  bow_printf("\n[trap] unhandled fast irq %u, masked\n", line);
}

__attribute__((weak)) void bow_exception_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
  static const char *const names[] = {
      "instr misaligned", "instr access fault", "illegal instr", "breakpoint",
      "load misaligned",  "load access fault",  "store misaligned", "store access fault",
      "ecall U",          "ecall S",            "reserved",       "ecall M",
  };
  const char *name = mcause < sizeof(names) / sizeof(names[0]) ? names[mcause] : "?";
  bow_printf("\n[trap] exception %u (%s) mepc=%08x mtval=%08x\n", mcause, name, mepc, mtval);
  for (;;) bow_wfi();
}

uint32_t bow_trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
  if (mcause & MCAUSE_IRQ_FLAG) {
    uint32_t code = MCAUSE_CODE(mcause);
    if (code >= 16 && code < 31) {
      bow_irq_fast_handler(code - 16);
    } else {
      bow_printf("\n[trap] unexpected interrupt %u\n", code);
    }
    return mepc;
  }
  bow_exception_handler(mcause, mepc, mtval);
  return mepc;
}
