/* SPDX-License-Identifier: GPL-3.0-or-later
   Copyright (C) 2026 ZbuntowanyKamulec */
/* 32-bit benchmark builds: linked at 30000h (tools/flat2img.py) */
ENTRY(_start)
SECTIONS
{
    . = 0x30000;
    .text : { *(.text.start) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    /DISCARD/ : { *(.comment*) *(.note*) *(.eh_frame*) }
}
