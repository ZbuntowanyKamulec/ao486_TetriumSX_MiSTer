# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Shutdown left by NMI, in lockstep (NMI every 900 cycles; the model holds its state in
# shutdown as the core does).  The IDT ends after the NMI gate (vector 2), so any other
# exception is a #GP beyond the limit, a #DF beyond it too, then shutdown: INT 40h, an
# undefined opcode (#UD), a divide by zero.  Each time the NMI handler skips the
# instruction (the saved EIP points at it) and returns; the last NMI after the end halts
# with NMI blocked.
# lockenv: LOCKNMI=900
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
CNT  = 0x30000                          # NMIs
SKIP = 0x30004                          # length of the instruction to skip
FIN  = 0x30008
SHUT = 0x3000C                          # NMIs that returned to an instruction to skip
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
    xor  eax, eax
    mov  [CNT], eax
    mov  [SKIP], eax
    mov  [FIN], eax
    mov  [SHUT], eax
    mov  dword ptr [SKIP], 2
    int  0x40                           # #GP, #DF, shutdown
    mov  dword ptr [SKIP], 2
    .byte 0x0F, 0xFF                    # #UD, ...
    mov  dword ptr [SKIP], 2
    xor  ecx, ecx
    div  ecx                            # #DE, ...
    mov  dword ptr [FIN], 1
1:  inc  eax
    jmp  1b

# NMI: count; after a shutdown (SKIP set) skip the instruction the saved EIP points at
nmi:
    inc  dword ptr [CNT]
    cmp  dword ptr [FIN], 0
    jne  2f
    push eax
    mov  eax, [SKIP]
    test eax, eax
    jz   1f
    add  [esp + 4], eax
    mov  dword ptr [SKIP], 0
    inc  dword ptr [SHUT]
1:  pop  eax
    iretd
2:  mov  eax, [SHUT]
    out  0xE9, al                       # (shutdowns left: LOCKE9=1 shows them)
    hlt

.org 0x3000
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
    desc 0x00000, 0xFFFFF, 0x92, 0xC       # 10 flat data
gdt_end:
.align 8
idt:
    .quad 0, 0
    .word nmi, 0x08, 0x8E00, 0
idt_end:
