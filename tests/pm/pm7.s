# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# task switches: CALL to a 386 TSS + IRET (NT, back link), JMP through a task gate and JMP
# back, INT through an IDT task gate + IRET, CALL to a 286 TSS + IRET.
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
.macro tss32 eip, esp                # a 386 TSS image: CS 08, SS / DS / ES 10
    .long 0, 0, 0, 0, 0, 0, 0, 0     # link, ESP0, SS0 ... CR3 (0)
    .long \eip, 0x0002               # EIP, EFLAGS
    .long 0x11, 0x22, 0x33, 0x44, \esp, 0x66, 0x77, 0x88
    .long 0x10, 0x08, 0x10, 0x10, 0, 0, 0x38   # ES CS SS DS FS GS LDT
    .long 0
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
    mov  ax, 0x18
    ltr  ax
    mov  ebx, 0x1234
    .byte 0x9A                      # call task B (TSS 20)
    .long 0
    .word 0x20
    add  [res], eax
    .byte 0xEA                      # jmp task C through the task gate 28
    .long 0
    .word 0x28
backA:
    add  [res], eax
    int  0x40                       # task gate in the IDT: task B again
    add  [res], eax
    .byte 0x9A                      # call the 286 task D (TSS 40)
    .long 0
    .word 0x40
    add  [res], eax
    clts
    mov  eax, [res]
    hlt
taskB:
    mov  eax, 0x100
    add  eax, ebx                   # (EBX from the TSS image)
    iretd                           # NT: back to the caller
    mov  eax, 0x200
    iretd
    hlt
taskC:
    mov  eax, 0x3000
    .byte 0xEA                      # back to task A (available again)
    .long 0
    .word 0x18
.code16
taskD:
    mov  ax, 0x4000
    iret
.code32
.align 4
res:    .long 0
gdtr:   .word 0x57
        .long 0x10A00
idtr:   .word 0x41 * 8 - 1
        .long 0x10C00
.org 0x600
tssA:   .fill 0x68, 1, 0
.org 0x680
tssB:   tss32 taskB, 0xE000
.org 0x700
tssC:   tss32 taskC, 0xD000
.org 0x780
tssD:   .word 0, 0, 0, 0, 0, 0, 0   # link, SP0 SS0 .. SP2 SS2
        .word taskD, 0x0002         # IP, FLAGS
        .word 1, 2, 3, 4, 0xC000, 6, 7, 8
        .word 0x10, 0x48, 0x50, 0x10, 0   # ES CS SS DS LDT
.org 0x800
ldt:    .quad 0
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    desc 0x10600, 0x67, 0x89, 0            # 18 TSS A
    desc 0x10680, 0x67, 0x89, 0            # 20 TSS B
    gate 0, 0x30, 0x85                     # 28 task gate -> TSS C
    desc 0x10700, 0x67, 0x89, 0            # 30 TSS C
    desc 0x10800, 0x07, 0x82, 0            # 38 LDT
    desc 0x10780, 0x2B, 0x81, 0            # 40 TSS D (286)
    desc 0x10000, 0xFFFF, 0x9A, 0          # 48 code16
    desc 0x40000, 0xFFFF, 0x92, 0          # 50 16-bit stack
.org 0xC00
idt:
    .fill 0x40, 8, 0
    gate 0, 0x20, 0x85                     # 40 task gate -> TSS B
