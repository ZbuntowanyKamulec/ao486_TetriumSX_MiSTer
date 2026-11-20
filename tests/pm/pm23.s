# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# task switch as an OS kernel does it: paging on, the current TSS with a large limit
# (I/O permission bitmap), an LDT loaded, CALL to a DPL 3 TSS from ring 0 and from ring 3
# (the new task: ring 0, its own CR3 = the same directory, LDT), IRETD with NT back.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
.macro gate off, sel, acc
    .word \off
    .word \sel
    .byte 0, \acc
    .word 0
.endm
PT = 0x21000
TSSA = 0x30000
TSSB = 0x34000
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
    mov  ax, 0x20                       # flat data
    mov  es, ax
    cld
    # paging: 0-4 MB identity, user / writable
    mov  edi, 0x20000
    mov  ecx, 1024
    xor  eax, eax
    rep  stosd
    mov  dword ptr es:[0x20000], PT + 7
    mov  edi, PT
    mov  eax, 0x67                      # A and D preset (86Box does not set D for the TSS link write)
    mov  ecx, 1024
1:  stosd
    add  eax, 0x1000
    loop 1b
    # TSS A: ring 0 stack, I/O bitmap all ones (limit 68h + 2000h); TSS B: the task
    mov  edi, TSSA
    mov  ecx, 0x68 + 0x2001
    mov  al, 0
    rep  stosb
    mov  edi, TSSA + 0x68
    mov  ecx, 0x2001
    mov  al, 0xFF
    rep  stosb
    mov  dword ptr es:[TSSA + 4], 0xE000
    mov  dword ptr es:[TSSA + 8], 0x10
    mov  word ptr es:[TSSA + 102], 0x68
    mov  dword ptr es:[TSSA + 0x1C], 0x20000            # CR3: loaded on the IRET back (never saved)
    mov  edi, TSSB
    mov  ecx, 26
    xor  eax, eax
    rep  stosd
    mov  dword ptr es:[TSSB + 0x1C], 0x20000            # CR3
    mov  dword ptr es:[TSSB + 0x20], offset taskB            # EIP (code base 10000)
    mov  dword ptr es:[TSSB + 0x24], 0x202              # EFLAGS
    mov  dword ptr es:[TSSB + 0x34], 0x1234             # EBX
    mov  dword ptr es:[TSSB + 0x38], 0xD000             # ESP
    mov  dword ptr es:[TSSB + 0x48], 0x20               # ES (flat)
    mov  dword ptr es:[TSSB + 0x4C], 0x08               # CS
    mov  dword ptr es:[TSSB + 0x50], 0x10               # SS
    mov  dword ptr es:[TSSB + 0x54], 0x10               # DS
    mov  dword ptr es:[TSSB + 0x60], 0x38               # LDT
    mov  dword ptr es:[TSSB + 0x64], 0x680000           # I/O map base past the limit
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  2f
2:  mov  ax, 0x28
    ltr  ax
    mov  ax, 0x38
    lldt ax
    mov  esi, 0x11111111
    mov  eax, 0x5
    .byte 0x9A                          # ring 0: call task B
    .long 0
    .word 0x43
    add  es:[res + 0x10000], eax
    add  es:[res + 0x10000], esi
    # to ring 3
    push 0x23
    push 0x1C000
    push 0x202
    push 0x1B
    push offset ring3
    iretd
ring3:
    mov  eax, 0x7
    .byte 0x9A                          # ring 3: call task B
    .long 0
    .word 0x43
    add  es:[res + 0x10000], eax
    mov  eax, 0x9
    .byte 0x9A
    .long 0
    .word 0x43
    add  es:[res + 0x10000], eax
    int  0x30                           # done (ring 0 handler: HLT)
taskB:
    mov  eax, es:[TSSA + 0x28]          # the caller's saved EAX / ESI
    add  eax, ebx
    mov  es:[TSSA + 0x28], eax
    xor  dword ptr es:[TSSA + 0x40], 0xFF00
    iretd
    jmp  taskB
done:
    mov  eax, es:[res + 0x10000]
    mov  ebx, es:[TSSB + 0x20]
    mov  ecx, es:[TSSB + 0x24]
    hlt
.align 4
res:    .long 0
gdtr:   .word gdt_end - gdt - 1
        .long 0x10000 + gdt
idtr:   .word 0x31 * 8 - 1
        .long 0x10000 + idt
.org 0x800
ldt:    .quad 0
        desc 0x10000, 0xFFFFF, 0x92, 0xC
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFFF, 0x9A, 0xC       # 08 code32 (base 10000)
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    desc 0x10000, 0xFFFFF, 0xFA, 0xC       # 18 ring 3 code (1B)
    desc 0x00000, 0xFFFFF, 0xF2, 0xC       # 20 flat data, DPL 3 (23)
    desc TSSA, 0x68 + 0x2000, 0x89, 0      # 28 TSS A (I/O bitmap)
    desc 0x10800, 0x0F, 0x82, 0      # 30 (unused)
    desc 0x10800, 0x0F, 0x82, 0      # 38 LDT
    desc TSSB, 0x67, 0xE9, 0               # 40 TSS B, DPL 3
gdt_end:
.org 0xC00
idt:
    .fill 0x30, 8, 0
    gate done, 0x08, 0xEE                  # 30: ring 3 -> 0
