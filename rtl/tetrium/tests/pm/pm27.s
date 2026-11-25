# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# BOUND with the upper bound beyond the segment limit (the lower one within it): #GP(0)
# before either bound is read.  With paging the lower bound's page must not be touched:
# not present -> still #GP (not #PF), present -> its accessed bit stays clear.
# 16-bit and 32-bit operands; then an in-range BOUND on the same pages.
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
    lidt [idtr]
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
    mov  dword ptr es:[PT + 0x40 * 4], 0x40000    # page 40: not present
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  2f
2:  xor  edx, edx                       # #GP count
    xor  edi, edi                       # #PF: CR2
    mov  cx, 5
    # 16-bit, lower bound on the missing page 40 (40FFE), upper one at 41000 beyond the limit
    mov  ax, 0x20
    mov  fs, ax
    mov  esi, offset 3f
    bound cx, fs:[0xFFE]
3:  # 16-bit, lower bound on page 42 (present, not accessed)
    mov  ax, 0x28
    mov  fs, ax
    mov  esi, offset 4f
    bound cx, fs:[0xFFE]
4:  mov  ebx, es:[PT + 0x42 * 4]        # (3: accessed bit clear)
    # 32-bit, lower bound on page 44 (present, not accessed)
    mov  ax, 0x30
    mov  fs, ax
    mov  esi, offset 5f
    bound ecx, fs:[0xFFC]
5:  mov  ebp, es:[PT + 0x44 * 4]        # (3)
    # in range: bounds 0 .. 7FFF at 46FF8 / 46FFA (page 46)
    mov  dword ptr es:[0x46FF8], 0x7FFF0000
    mov  esi, offset 6f
    bound cx, es:[0x46FF8]
6:  hlt

gp: add  esp, 4                         # (error code)
    mov  [esp], esi
    inc  edx
    iretd
pf: add  esp, 4
    mov  [esp], esi
    mov  edi, cr2
    iretd

.org 0x3100
gdtr:
    .word gdt_end - gdt - 1
    .long 0x10000 + gdt
idtr:
    .word idt_end - idt - 1
    .long 0x10000 + idt
.align 8
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    desc 0x00000, 0xFFFFF, 0x92, 0xC       # 18 flat data
    desc 0x40000, 0x1000, 0x92, 4          # 20 limit 1000: page 40 / 41
    desc 0x42000, 0x1000, 0x92, 4          # 28 page 42 / 43
    desc 0x44000, 0x1002, 0x92, 4          # 30 page 44 / 45 (upper dword 1000..1003)
gdt_end:
.align 8
idt:
    .fill 13, 8, 0
    .word 0x10000 + gp - 0x10000, 0x08, 0x8E00, 0
    .word 0x10000 + pf - 0x10000, 0x08, 0x8E00, 0
idt_end:
