# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Probe: i486-specific fault decisions.  Per case: vector, error code and RF in the pushed
# EFLAGS (vector FF: no fault).
#   cr4   MOV EAX, CR4 (the i486 has CR0, CR2, CR3)    cr1  MOV EAX, CR1
#   tr1   MOV EAX, TR1 (the i486 has TR3-TR7)          tr6  MOV EAX, TR6
#   gp    MOV DS with a selector beyond the GDT (#GP: RF in the frame)
#   de    DIV by 0 with the #DE gate not present (#NP while delivering a contributory
#         exception: #DF)
#   lgdt  LGDT whose 6-byte operand crosses the segment limit
# Bochs differs on purpose: its CPU level 4 has CR4 (as the later 486s: DX4, SL-enhanced; the
# i486 manuals list CR0, CR2, CR3) and no test registers (MOV TRn: #UD).
# bochs-expect: faults vec/err/rf cr4 cr1 tr1 tr6 gp de lgdt: 000000FF 00000000 00000000 | 00000006 00000000 00010000 | 00000006 00000000 00010000 | 00000006 00000000 00010000 | 0000000D 000000F8 00010000 | 00000008 00000000 00010000 | 0000000D 00000000 00010000 |
.intel_syntax noprefix
.include "mac.s"
R    = 0x3000
NC   = 0x3200                           # case count
.macro CASE insn:vararg
    mov  dword ptr [VEC], 0xFF
    mov  dword ptr [ERR], 0
    mov  dword ptr [RFB], 0
    mov  esi, offset 9f
    \insn
9:  mov  eax, [NC]
    shl  eax, 4
    mov  ecx, [VEC]
    mov  [R + eax], ecx
    mov  ecx, [ERR]
    mov  [R + eax + 4], ecx
    mov  ecx, [RFB]
    mov  [R + eax + 8], ecx
    inc  dword ptr [NC]
.endm
VEC  = 0x3300
ERR  = 0x3304
RFB  = 0x3308
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
    mov  dword ptr [NC], 0
    CASE .byte 0x0F, 0x20, 0xE0         # mov eax, cr4
    CASE .byte 0x0F, 0x20, 0xC8         # mov eax, cr1
    CASE .byte 0x0F, 0x24, 0xC8         # mov eax, tr1
    CASE .byte 0x0F, 0x24, 0xF0         # mov eax, tr6
    mov  ax, 0xF8
    CASE mov ds, ax
    mov  ax, 0x10                       # (DS back)
    mov  ds, ax
    xor  ecx, ecx
    CASE div ecx
    mov  ax, 0x18                       # data segment with limit FFFh
    mov  es, ax
    CASE lgdt es:[0xFFC]
    PS   "faults vec/err/rf cr4 cr1 tr1 tr6 gp de lgdt: "
    xor  ebx, ebx
1:  PH   [R + ebx]
    PH   [R + ebx + 4]
    PH   [R + ebx + 8]
    PS   "| "
    add  ebx, 16
    cmp  ebx, 7 * 16
    jb   1b
    jmp  done

# handlers: record vector, error code, RF; resume at ESI
.macro HND vec, ec
h\vec:
    push eax
    push ds
    mov  ax, 0x10
    mov  ds, ax
    mov  dword ptr [VEC], \vec
.if \ec
    mov  eax, [esp + 8]
    mov  [ERR], eax
    mov  eax, [esp + 20]
.else
    mov  eax, [esp + 16]
.endif
    and  eax, 0x10000
    mov  [RFB], eax
    pop  ds
    pop  eax
.if \ec
    add  esp, 4
.endif
    mov  [esp], esi
    iretd
.endm
    HND  6, 0
    HND  8, 1
    HND  11, 1
    HND  13, 1
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
    desc 0x10000, 0xFFF, 0x92, 4            # 18 data32, limit FFFh
gdt_end:
.align 8
idt:
    gate 0, 0x08, 0x0E                      # 0 #DE: not present
    .fill 5, 8, 0
    gate h6, 0x08, 0x8E                     # 6 #UD
    .quad 0
    gate h8, 0x08, 0x8E                     # 8 #DF
    .fill 2, 8, 0
    gate h11, 0x08, 0x8E                    # 11 #NP
    .quad 0
    gate h13, 0x08, 0x8E                    # 13 #GP
idt_end:
