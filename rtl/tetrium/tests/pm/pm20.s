# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# CMP with a memory destination only reads: CMP r/m, imm (80 / 81 / 83 /7) and CMP r/m, r
# (38 / 39) through a read-only data segment and a readable (non-conforming) code segment
# loaded as data, no #GP (Extreme Pinball: DOS/4GW's IRQ5 path does cmp word [x], 0 with DS
# = a readable code segment); with paging and CR0.WP, CMP on a read-only page at ring 0
# (no #PF) and on a clean page (the dirty bit stays clear: the PTE is read back).
# No IDT: any fault is a lockstep mismatch against 86Box.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
PT = 0x21000
.code16
.org 0x100
start:
    cli
    lgdt [gdtr]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    .byte 0x66, 0xEA
    .long pm32
    .word 0x08
.code32
pm32:
    mov  ax, 0x10
    mov  ds, ax
    mov  ss, ax
    mov  esp, 0xF000
    mov  dword ptr [buf], 0x12345678
    mov  dword ptr [buf+4], 0x0000FFFF
    xor  ebp, ebp                       # flag results, one bit per CMP
    xor  eax, eax
    mov  ax, 0x18                       # read-only data (base 10000)
    mov  es, ax
    mov  ax, 0x20                       # readable code as data (base 10000)
    mov  fs, ax
    mov  ax, 0x28                       # 16-bit readable code as data
    mov  gs, ax
    mov  ecx, 0x12345678
    cmp  dword ptr es:[buf], 0x12345678 # 81 /7
    setz al
    or   ebp, eax
    cmp  word ptr fs:[buf+4], 0         # 83 /7 word
    setnz al
    shl  ebp, 1
    or   ebp, eax
    cmp  byte ptr gs:[buf], 0x78        # 80 /7
    setz al
    shl  ebp, 1
    or   ebp, eax
    cmp  es:[buf], ecx                  # 39
    setz al
    shl  ebp, 1
    or   ebp, eax
    cmp  fs:[buf+1], cl                 # 38 (byte 56 vs 78)
    setb al
    shl  ebp, 1
    or   ebp, eax
    cmp  ecx, gs:[buf]                  # 3B (reads only anyway)
    setz al
    shl  ebp, 1
    or   ebp, eax
    .byte 0x66                          # 16-bit operand: cmp word ptr fs:[buf+4], 0FFFFh (83 /7, sign-extended)
    .byte 0x64, 0x83, 0x3D
    .long buf+4
    .byte 0xFF
    setz al
    shl  ebp, 1
    or   ebp, eax
    # paging: directory 20000, table 21000, pages 0-3F identity (supervisor, writable),
    # 32000 read-only, 31000 clean (D = 0)
    mov  ax, 0x30                       # flat data
    mov  es, ax
    mov  edi, 0x20000
    mov  ecx, 2048
    xor  eax, eax
    cld
    rep  stosd
    mov  dword ptr es:[0x20000], PT + 3
    mov  edi, PT
    mov  eax, 3 | 0x40                  # (dirty already: only 31000 starts clean)
    mov  ecx, 0x40
1:  stosd
    add  eax, 0x1000
    loop 1b
    mov  dword ptr es:[PT + 0x31*4], 0x31003         # writable, clean
    mov  dword ptr es:[PT + 0x32*4], 0x32001         # read-only
    mov  dword ptr es:[0x32010], 0xA5A5A5A5
    mov  dword ptr es:[0x31010], 0x5A5A5A5A
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80010000                # PG, WP
    mov  cr0, eax
    jmp  2f
2:  cmp  dword ptr es:[0x32010], 0xA5A5A5A5   # read-only page, WP: reads only
    setz al
    shl  ebp, 1
    or   ebp, eax
    cmp  es:[0x32011], cl
    cmp  word ptr es:[0x31010], 0x5A5A     # clean page: no dirty bit
    setz al
    shl  ebp, 1
    or   ebp, eax
    cmp  byte ptr es:[0x31012], 0x5A
    mov  ebx, es:[PT + 0x31*4]          # 31003 | accessed (20), D (40) clear
    mov  edx, es:[PT + 0x32*4]
    mov  esi, ebp
    hlt

.org 0x800
gdtr:
    .word gdt_end - gdt - 1
    .long 0x10000 + 0xA00
.align 4
buf:
    .long 0, 0, 0, 0
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    desc 0x10000, 0xFFFF, 0x90, 0          # 18 read-only data
    desc 0x10000, 0xFFFF, 0x9A, 4          # 20 readable code32 (as data)
    desc 0x10000, 0xFFFF, 0x9B, 0          # 28 readable code16, accessed (as data)
    desc 0x00000, 0xFFFFF, 0x92, 0xC       # 30 flat data
gdt_end:
