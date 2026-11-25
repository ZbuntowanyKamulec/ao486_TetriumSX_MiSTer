# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Sequential execution past the code segment limit: #GP(0) at the instruction whose last byte
# lies beyond the limit, before it runs (pushed EIP = its start).  32-bit and 16-bit code
# segments: an instruction straddling the limit, code running off the end (the next
# instruction starts at limit + 1), a REP string instruction ending exactly at the limit.  The #GP handler logs CS:EIP and goes on with the next case.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
LOG = 0x30000
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
    mov  esp, 0x2FFF0
    mov  dword ptr [LOG], 0
    mov  esi, 0x40000
    mov  edi, 0x50000
next:                                   # case n: far jump through the table
    mov  ebx, [LOG]
    cmp  ebx, 5
    jae  done
    jmp  fword ptr [0x10000 + cases + ebx * 8]
done:
    mov  eax, [LOG]
    out  0xE9, al                       # (the number of faults and each EIP: LOCKE9=1 shows them)
    xor  ebx, ebx
1:  mov  eax, [LOG + 4 + ebx * 8]
    out  0xE9, al
    mov  al, ah
    out  0xE9, al
    inc  ebx
    cmp  ebx, [LOG]
    jb   1b
    hlt

gp: mov  eax, [LOG]
    mov  ecx, [esp + 4]                 # EIP
    mov  [LOG + 4 + eax * 8], ecx
    mov  ecx, [esp + 8]                 # CS
    mov  [LOG + 8 + eax * 8], ecx
    inc  dword ptr [LOG]
    add  esp, 16                        # (error code, EIP, CS, EFLAGS)
    mov  ax, 0x10
    mov  ds, ax
    jmp  next

# case code: segments 18 / 20 / 28 / 30 / 38 (base 10000) with the limits below
.org 0x1F8
c0: nop                                 # 18, limit 1FF: MOV EAX, imm32 at 1FC..200
    nop
    nop
    nop
    mov  eax, 0x12345678
.org 0x2F8
c1: add  eax, ecx                       # 20, limit 2FF: the last NOP at 2FF, then 300
    add  eax, ecx
    add  eax, ecx
    nop
    nop
.org 0x3F0
c2: mov  ecx, 4                         # 28, limit 3FF: REP MOVSD ends at 3FF, then 400
    jmp  1f
.org 0x3FE
1:  rep  movsd
    .byte 0xEB, 0xFE                    # (beyond the limit: JMP $)
.code16
.org 0x4F8
c3: nop                                 # 30, 16-bit, limit 4FF: MOV AX, imm16 at 4FE..500
    nop
    nop
    nop
    nop
    nop
    mov  ax, 0x1234
.org 0x5F8
c4: inc  ax                             # 38, 16-bit, limit 5FF: the last INC at 5FF, then 600
    inc  ax
    inc  ax
    inc  ax
    inc  ax
    inc  ax
    inc  ax
    inc  ax
.code32

.org 0x3000
gdtr:
    .word gdt_end - gdt - 1
    .long 0x10000 + gdt
idtr:
    .word idt_end - idt - 1
    .long 0x10000 + idt
cases:
    .long c0, 0x18
    .long c1, 0x20
    .long c2, 0x28
    .long c3, 0x30
    .long c4, 0x38
.align 8
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x00000, 0xFFFFF, 0x92, 0xC       # 10 flat data
    desc 0x10000, 0x1FF, 0x9A, 4           # 18 code32, limit 1FF
    desc 0x10000, 0x2FF, 0x9A, 4           # 20 code32, limit 2FF
    desc 0x10000, 0x3FF, 0x9A, 4           # 28 code32, limit 3FF
    desc 0x10000, 0x4FF, 0x9A, 0           # 30 code16, limit 4FF
    desc 0x10000, 0x5FF, 0x9A, 0           # 38 code16, limit 5FF
gdt_end:
.align 8
idt:
    .fill 13, 8, 0
    .word gp, 0x08, 0x8E00, 0
idt_end:
