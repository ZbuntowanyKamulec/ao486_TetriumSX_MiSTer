# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# OUTS data from memory (the lockstep compares every OUT byte with 86Box): REP OUTSD / OUTSW /
# OUTSB to a plain port (300h), paging on, the source in cached lines, after WBINVD (D-cache
# misses), after a CR3 reload (TLB misses, the walk in E), crossing a page, just written by
# stores (store buffer / forwarding), single OUTSD, and OUT from a register.
# (MS-DOS under EMM386 wrote sectors of zeros with the Bochs BIOS's rep outsd: corrupt FATs)
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
BUF = 0x40F80                         # 256 bytes, crosses the page at 41000
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
    mov  ax, 0x18                     # flat data
    mov  es, ax
    # paging: directory 20000, table 21000, pages 0-7F identity
    mov  edi, 0x20000
    mov  ecx, 2048
    xor  eax, eax
    cld
    rep  stosd
    mov  dword ptr es:[0x20000], PT + 3
    mov  edi, PT
    mov  eax, 3
    mov  ecx, 0x80
1:  stosd
    add  eax, 0x1000
    loop 1b
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  2f
2:  # old contents EE in memory (written, then the caches flushed), then the pattern
    mov  edi, BUF
    mov  ecx, 64
    mov  eax, 0xEEEEEEEE
    rep  stosd
    wbinvd
    mov  edi, BUF
    mov  ecx, 64
    mov  eax, 0x03020100
3:  stosd
    add  eax, 0x04040404
    loop 3b
    mov  ax, 0x18
    mov  ds, ax                       # flat DS for the OUTS sources
    mov  dx, 0x300
    # 1: cached source (just written by STOSD: forwarding / store buffer)
    mov  esi, BUF
    mov  ecx, 64
    rep  outsd
    # 2: after WBINVD (every source line misses)
    wbinvd
    mov  esi, BUF
    mov  ecx, 64
    rep  outsd
    # 3: after a CR3 reload (TLB misses: the walk for the first source and at the page)
    mov  eax, cr3
    mov  cr3, eax
    mov  esi, BUF
    mov  ecx, 64
    rep  outsd
    # 4: both (WBINVD + CR3), words and bytes
    wbinvd
    mov  eax, cr3
    mov  cr3, eax
    mov  esi, BUF
    mov  ecx, 128
    rep  outsw
    wbinvd
    mov  eax, cr3
    mov  cr3, eax
    mov  esi, BUF + 0x70
    mov  ecx, 32
    rep  outsb
    # 5: stores right before (the store still in flight), single OUTSD / OUTSW
    mov  dword ptr [BUF], 0xA1B2C3D4
    mov  esi, BUF
    outsd
    mov  word ptr [BUF + 4], 0x5566
    outsw
    mov  dword ptr [BUF + 0x7C], 0xDEADBEEF   # the last dword before the page
    mov  dword ptr [BUF + 0x80], 0x01234567   # the first one after it
    mov  esi, BUF + 0x7C
    mov  ecx, 2
    rep  outsd
    # 6: OUT from registers
    mov  eax, 0x89ABCDEF
    out  dx, eax
    out  dx, ax
    out  dx, al
    # 7: real-mode style 16-bit addressing, 16-bit code (DOS's BIOS case): ES:DI fill, DS:SI out
    .byte 0xEA
    .long pm16
    .word 0x20
.code16
pm16:
    mov  ax, 0x28                     # 16-bit data at 40000
    mov  ds, ax
    mov  es, ax
    mov  di, 0x0F80
    mov  cx, 128
    mov  ax, 0x1111
4:  stosw
    add  ax, 0x0101
    loop 4b
    mov  si, 0x0F80
    mov  cx, 64
    rep  outsd
    wbinvd
    mov  eax, cr3
    mov  cr3, eax
    mov  si, 0x0F80
    mov  cx, 64
    rep  outsd
    hlt

.org 0x800
gdtr:
    .word gdt_end - gdt - 1
    .long 0x10000 + 0xA00
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    desc 0x00000, 0xFFFFF, 0x92, 0xC       # 18 flat data
    desc 0x10000, 0xFFFF, 0x9A, 0          # 20 code16
    desc 0x40000, 0xFFFF, 0x92, 0          # 28 data16 at 40000
gdt_end:
