# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# ring 3 with IOPL 0: I/O permission bitmap (allowed / denied / a word across two map
# bytes / beyond the TSS limit), CLI #GP, POPF keeps IF, LAR / LSL / VERR / VERW / ARPL.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.macro gate off, sel, acc, cnt=0
    .word \off
    .word \sel
    .byte \cnt, \acc
    .word 0
.endm
.macro try lbl
    mov  dword ptr ds:[resume3], offset \lbl
.endm
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
    mov  ax, 0x40
    ltr  ax
    in   al, 0x81                   # CPL 0: no bitmap check
    push 0x2B
    push 0xC000
    push 0x0202                     # IF = 1, IOPL 0
    push 0x1B
    push offset ring3
    iretd
ring3:
    mov  ax, 0x23
    mov  ds, ax
    in   al, 0x80                   # allowed
    try  1f
    in   al, 0x81                   # denied: #GP(0)
1:  mov  dx, 0x86
    in   ax, dx                     # 86, 87 allowed
    try  1f
    mov  dx, 0x87
    in   ax, dx                     # 87 allowed, 88 denied (next map byte)
1:  try  1f
    mov  dx, 0x3F8
    out  dx, al                     # beyond the TSS limit: #GP(0)
1:  try  1f
    cli                             # #GP(0)
1:  pushfd
    and  dword ptr [esp], ~0x200
    popfd                           # IF unchanged (CPL > IOPL)
    pushfd
    pop  esi
    mov  ax, 0x2B
    lar  ebx, ax
    lsl  ecx, ax
    mov  ax, 0x10                   # DPL 0: not visible at CPL 3
    lar  ebp, ax
    verr ax
    mov  ax, 0x1B
    verr ax                         # readable code
    verw ax
    mov  ax, 0x23
    verw ax
    mov  ax, 0x43                   # TSS (system): LSL valid, VERR not
    lsl  edi, ax
    verr ax
    mov  ax, 0x500                  # beyond the GDT limit
    lar  ebx, ax
    mov  ax, 0x0010
    mov  bx, 0x0003
    arpl ax, bx                     # raised: ZF
    arpl ax, bx                     # unchanged
    mov  word ptr [val], 0x0008
    arpl [val], bx
    int  0x31
hgp:
    push eax
    mov  ebx, [esp+4]
    mov  eax, ds:[resume3]
    mov  [esp+8], eax
    pop  eax
    add  esp, 4
    iretd
h31:
    mov  ax, 0x10
    mov  ds, ax
    mov  eax, [val]
    hlt

.align 4
resume3: .long 0
val:     .long 0
gdtr:    .word 0x47
         .long 0x10A00
idtr:    .word 0x32 * 8 - 1
         .long 0x10800
.org 0x700
tss:     .long 0, 0xE000, 0x10
         .fill 0x66 - 12, 1, 0
         .word 0x68                 # I/O map base
         .fill 0x10, 1, 0           # ports 00-7F allowed
         .byte 0x02                 # 80 allowed, 81 denied
         .byte 0x01                 # 88 denied
         .fill 6, 1, 0              # up to port 0xBF; beyond: the TSS limit
tss_end:
.org 0x800
idt:
    .fill 13, 8, 0
    gate hgp, 0x08, 0x8E
    .fill 0x31 - 14, 8, 0
    gate h31, 0x08, 0xEE
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32 DPL 0
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32 DPL 0
    desc 0x10000, 0xFFFF, 0xFA, 4          # 18 code32 DPL 3
    desc 0x10000, 0xFFFF, 0xF2, 4          # 20 data32 DPL 3
    desc 0x30000, 0xFFFF, 0xF2, 4          # 28 stack DPL 3
    .quad 0, 0
    desc 0x10700, 0x7F, 0xE9, 0            # 40 TSS32 (DPL 3 for LSL), limit 7F
