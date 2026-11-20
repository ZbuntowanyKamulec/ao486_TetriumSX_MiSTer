# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# protected mode privilege levels: IRET to ring 3 (outer return, data segments nulled),
# call gates from ring 3 to ring 0 (stack switch through the TSS, parameter copy) and RETF
# (n) back, INT from ring 3 (inner stack), a ring 3 fault handled at ring 0.
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
    mov  es, ax
    mov  ss, ax
    mov  esp, 0xF000
    mov  ax, 0x40
    ltr  ax
    # to ring 3: IRETD with SS:ESP
    push 0x2B                       # SS (DPL 3 stack)
    push 0xC000
    push 0x0002                     # EFLAGS
    push 0x1B                       # CS (DPL 3 code)
    push offset ring3
    mov  ax, 0x23
    mov  es, ax                     # DPL 3 data: stays valid
    iretd                           # DS (DPL 0) is nulled
ring3:
    mov  ax, 0x23
    mov  ds, ax
    mov  dword ptr [val], 1
    .byte 0x9A                      # call gate 0x33 -> ring 0 (no parameters)
    .long 0
    .word 0x33
    add  [val], eax
    push 0x1111
    push 0x2222
    .byte 0x9A                      # call gate 0x3B (2 parameters)
    .long 0
    .word 0x3B
    add  [val], eax
    int  0x30                       # interrupt gate DPL 3 -> ring 0
    add  [val], eax
    try  1f
    mov  ax, 0x10                   # DPL 0 data at CPL 3: #GP(10)
    mov  ds, ax
1:  mov  ax, 0x23
    mov  ds, ax
    add  [val], ebx
    int  0x31                       # back to ring 0 for good
g0:                                 # ring 0 through gate 0x33
    mov  eax, 0x100
    retf
g2:                                 # ring 0 through gate 0x3B, parameters on the inner stack
    mov  eax, [esp+8]
    add  eax, [esp+12]
    retf 8
h30:
    mov  eax, 0x30000
    iretd
hgp:                                # #GP at ring 3: resume there
    push eax
    mov  ebx, [esp+4]               # error code
    mov  eax, ss:[resume3 + 0]      # (ring 0 SS is the flat data segment)
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
gdtr:    .word 0x4F
         .long 0x10A00
idtr:    .word 0x32 * 8 - 1
         .long 0x10800
.org 0x700
tss:     .long 0, 0xE000, 0x10      # link, ESP0, SS0
         .fill 0x68 - 12, 1, 0
.org 0x800
idt:
    .fill 13, 8, 0
    gate hgp, 0x08, 0x8E                          # 13 #GP
    .fill 0x30 - 14, 8, 0
    gate h30, 0x08, 0xEE                          # 30 DPL 3 interrupt gate
    gate h31, 0x08, 0xEE                          # 31
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32 DPL 0
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32 DPL 0
    desc 0x10000, 0xFFFF, 0xFA, 4          # 18 code32 DPL 3
    desc 0x10000, 0xFFFF, 0xF2, 4          # 20 data32 DPL 3
    desc 0x30000, 0xFFFF, 0xF2, 4          # 28 stack DPL 3 (32-bit)
    gate g0, 0x08, 0xEC                    # 30 call gate DPL 3 -> 08
    gate g2, 0x08, 0xEC, 2                 # 38 call gate, 2 parameters
    desc 0x10700, 0x67, 0x89, 0            # 40 TSS32
