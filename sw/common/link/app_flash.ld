/*
 * Copyright Bow32 contributors.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Linker script for applications executed in place from the internal flash.
 *
 *   FLASH: [image header 32 B][.text (_start first)][.vectors][.rodata][.data LMA]
 *   SRAM : [.data][.bss] ... free ... [stack (grows down from the top)]
 */

INCLUDE bow32_memory.ld

OUTPUT_ARCH(riscv)
ENTRY(_start)

__stack_size = DEFINED(__stack_size) ? __stack_size : 0x800;

SECTIONS
{
  .image_hdr ORIGIN(FLASH) :
  {
    KEEP(*(.image_hdr))
  } > FLASH

  .text :
  {
    KEEP(*(.text.start))
    *(.text .text.*)
  } > FLASH

  .vectors : ALIGN(256)
  {
    KEEP(*(.vectors))
  } > FLASH

  .rodata : ALIGN(4)
  {
    *(.rodata .rodata.* .srodata .srodata.*)
  } > FLASH

  .data : ALIGN(4)
  {
    __data_start = .;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    __data_end = .;
  } > SRAM AT > FLASH
  __data_load = LOADADDR(.data);

  .bss (NOLOAD) : ALIGN(4)
  {
    __bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > SRAM

  __global_pointer$ = __data_start + 0x800;
  __stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
  __heap_start = __bss_end;
  __image_end = __data_load + SIZEOF(.data);

  ASSERT(SIZEOF(.image_hdr) == 32, "missing or wrong size image header (.image_hdr)")
  ASSERT(__bss_end + __stack_size <= __stack_top, "SRAM overflow: .data + .bss + stack")

  /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment) }
}
