# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Probe: data segment registers after a return to ring 3 (RETF, then IRETD) when they hold a
# null selector with RPL > 0, a null selector, a ring 0 data segment and a ring 3 data segment.
# Prints the four selectors as ring 3 reads them after each return.
.intel_syntax noprefix
.include "mac.s"
R = 0x3000                              # results (DS / SS base 10000h)
TSSA = 0x1800                           # the TSS (a fixed address: descriptor fields)
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
    mov  esp, 0x2F000
    mov  ax, 0x30
    ltr  ax
    # RETF to ring 3: DS null RPL 3, ES null RPL 0, FS ring 0 data, GS ring 3 data
    push 0x23
    push 0xE000
    push 0x1B
    push offset r3a
    mov  ax, 0x0003
    mov  ds, ax
    xor  ax, ax
    mov  es, ax
    mov  ax, 0x10
    mov  fs, ax
    mov  ax, 0x23
    mov  gs, ax
    retf
r3a:
    mov  ax, ds
    movzx eax, ax
    mov  ss:[R], eax
    mov  ax, es
    movzx eax, ax
    mov  ss:[R + 4], eax
    mov  ax, fs
    movzx eax, ax
    mov  ss:[R + 8], eax
    mov  ax, gs
    movzx eax, ax
    mov  ss:[R + 12], eax
    int  0x40
h40:
    mov  ax, 0x10
    mov  ds, ax
    # IRETD to ring 3: DS null RPL 2, ES null RPL 1, FS null RPL 3, GS ring 0 data
    push 0x23
    push 0xE000
    push 0x0002
    push 0x1B
    push offset r3b
    mov  ax, 0x0002
    mov  ds, ax
    mov  ax, 0x0001
    mov  es, ax
    mov  ax, 0x0003
    mov  fs, ax
    mov  ax, 0x10
    mov  gs, ax
    iretd
r3b:
    mov  ax, ds
    movzx eax, ax
    mov  ss:[R + 16], eax
    mov  ax, es
    movzx eax, ax
    mov  ss:[R + 20], eax
    mov  ax, fs
    movzx eax, ax
    mov  ss:[R + 24], eax
    mov  ax, gs
    movzx eax, ax
    mov  ss:[R + 28], eax
    int  0x41
h41:
    mov  ax, 0x10
    mov  ds, ax
    PS   "nullrpl retf ds es fs gs: "
    PH   [R]
    PH   [R + 4]
    PH   [R + 8]
    PH   [R + 12]
    PS   "| iretd: "
    PH   [R + 16]
    PH   [R + 20]
    PH   [R + 24]
    PH   [R + 28]
    jmp  done
.include "lib.s"

.org 0x1000
gdtr:   .word gdt_end - gdt - 1
        .long 0x10000 + gdt
idtr:   .word idt_end - idt - 1
        .long 0x10000 + idt
.align 8
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4           # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC        # 10 data32
    desc 0x10000, 0xFFFF, 0xFA, 4           # 18 code32 DPL 3
    desc 0x10000, 0xFFFFF, 0xF2, 0xC        # 20 data32 DPL 3
    .quad 0                                 # 28
    desc 0x10000 + TSSA, 0x67, 0x89, 0      # 30 TSS32
gdt_end:
.align 8
idt:
    .fill 0x40, 8, 0
    gate h40, 0x08, 0xEE                    # 40 (DPL 3)
    gate h41, 0x08, 0xEE                    # 41 (DPL 3)
idt_end:
.org TSSA
tss:    .long 0, 0x2E000, 0x10              # link, ESP0, SS0
        .fill 0x68 - 12, 1, 0
