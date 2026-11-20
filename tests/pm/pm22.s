# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# INVD / WBINVD while the fetcher waits for a page walk: right after a CR3 reload (ITLB empty)
# the instruction sits just before a code page boundary, so fetch runs ahead into the next page
# (TLB miss: the walk waits for the pipeline to drain) while E waits for the cache sweep.
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
    mov  ax, 0x18
    mov  es, ax
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
2:  xor  esi, esi
    mov  ebx, 0x20000
    jmp  case1
# each case: reload CR3, a store (the store buffer is not empty), the flush, then the code
# continues into the next page
.org 0x0FF0
case1:
    mov  cr3, ebx
    mov  [0x800], esi
    wbinvd
    inc  esi
    nop
    nop
    nop
    nop
    nop
    nop
    jmp  case2
.org 0x1FF2
case2:
    mov  cr3, ebx
    mov  [0x804], esi
    invd
    inc  esi
    nop
    nop
    nop
    nop
    nop
    nop
    jmp  case3
.org 0x2FF4
case3:
    mov  cr3, ebx                       # the flush the last instruction of its page
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    wbinvd
    inc  esi
    mov  ecx, [0x800]
    hlt
.org 0x3100
gdtr:
    .word gdt_end - gdt - 1
    .long 0x10000 + gdt
.align 8
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    desc 0x00000, 0xFFFFF, 0x92, 0xC       # 18 flat data
gdt_end:
