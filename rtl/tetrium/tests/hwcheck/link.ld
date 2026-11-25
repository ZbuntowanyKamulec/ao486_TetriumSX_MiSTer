/* SPDX-License-Identifier: GPL-3.0-or-later
   Copyright (C) 2026 ZbuntowanyKamulec */
/* hwcheck kernel: loaded at physical 10000h, linked at C0010000h */
ENTRY(_start)
SECTIONS
{
  . = 0xC0010000;
  .text : AT(0x10000) { *(.entry) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  . = ALIGN(16);
  __bss_start = .;
  .bss : { *(.bss .bss.* COMMON) }
  __bss_end = .;
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
