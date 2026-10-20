/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * C runtime start-up for applications running from flash.
 *
 * The boot ROM jumps to _start (image header 'entry'). We set up gp/sp, copy
 * .data from flash to SRAM, clear .bss, install the vector table and call
 * main().
 */

  .section .text.start, "ax"
  .globl _start
_start:
  .option push
  .option norelax
  la    gp, __global_pointer$
  .option pop
  la    sp, __stack_top

  /* Copy .data (load address in flash -> run address in SRAM) */
  la    a0, __data_load
  la    a1, __data_start
  la    a2, __data_end
1:
  bgeu  a1, a2, 2f
  lw    t0, 0(a0)
  sw    t0, 0(a1)
  addi  a0, a0, 4
  addi  a1, a1, 4
  j     1b
2:
  /* Clear .bss */
  la    a1, __bss_start
  la    a2, __bss_end
3:
  bgeu  a1, a2, 4f
  sw    zero, 0(a1)
  addi  a1, a1, 4
  j     3b
4:
  /* Ibex only supports vectored mode: base must be 256 byte aligned */
  la    t0, __vectors_start
  ori   t0, t0, 1
  csrw  mtvec, t0

  call  main

  /* main() returned: sleep forever */
5:
  wfi
  j     5b

/*
 * Common trap entry: save caller saved registers, call
 *   uint32_t bow_trap_handler(mcause, mepc, mtval)
 * and resume at the returned address.
 */
  .section .text.trap, "ax"
  .globl bow_trap_entry
  .balign 4
bow_trap_entry:
  addi  sp, sp, -64
  sw    ra,  0(sp)
  sw    t0,  4(sp)
  sw    t1,  8(sp)
  sw    t2, 12(sp)
  sw    a0, 16(sp)
  sw    a1, 20(sp)
  sw    a2, 24(sp)
  sw    a3, 28(sp)
  sw    a4, 32(sp)
  sw    a5, 36(sp)
  sw    a6, 40(sp)
  sw    a7, 44(sp)
  sw    t3, 48(sp)
  sw    t4, 52(sp)
  sw    t5, 56(sp)
  sw    t6, 60(sp)

  csrr  a0, mcause
  csrr  a1, mepc
  csrr  a2, mtval
  call  bow_trap_handler
  csrw  mepc, a0

  lw    ra,  0(sp)
  lw    t0,  4(sp)
  lw    t1,  8(sp)
  lw    t2, 12(sp)
  lw    a0, 16(sp)
  lw    a1, 20(sp)
  lw    a2, 24(sp)
  lw    a3, 28(sp)
  lw    a4, 32(sp)
  lw    a5, 36(sp)
  lw    a6, 40(sp)
  lw    a7, 44(sp)
  lw    t3, 48(sp)
  lw    t4, 52(sp)
  lw    t5, 56(sp)
  lw    t6, 60(sp)
  addi  sp, sp, 64
  mret

/*
 * Vector table (mtvec vectored mode): entry 0 = exceptions,
 * entry N = interrupt with mcause code N. All go to bow_trap_entry.
 */
  .section .vectors, "ax"
  .option push
  .option norvc
  .globl __vectors_start
__vectors_start:
  .rept 32
  j     bow_trap_entry
  .endr
  .option pop
