# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# NMI (the testbench raises an edge every 600 cycles, replayed into 86Box): real mode, then
# 32-bit protected mode.  Every fourth handler run is longer than the NMI period, so the next
# NMI is pending while blocked and must be taken right after the IRET, not nested.  NMIs land in
# straight code, inside REP MOVS, after MOV SS and in HLT with IF = 0 (the handler returns
# past the HLT).  The last NMI halts in its handler: NMI stays blocked, the core halted.
# lockenv: LOCKNMI=600
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
.endm
CNT = 0x30000                           # NMI count (linear), FIN: the final flag
FIN = 0x30004
.code16
.org 0x100
start:
    cli
    xor  ax, ax
    mov  ds, ax
    mov  word ptr [2 * 4], offset nmi_rm
    mov  word ptr [2 * 4 + 2], cs
    mov  ax, 0x3000
    mov  es, ax
    mov  dword ptr es:[0], 0
    mov  dword ptr es:[4], 0
    mov  ax, 0x2000
    mov  ss, ax
    mov  sp, 0xFFF0
    call work16
    mov  si, 0
    mov  di, 0x8000
    mov  ax, 0x4000
    mov  ds, ax
    mov  ax, 0x5000
    mov  es, ax
    mov  cx, 0x3000
    cld
    rep  movsb
    mov  cx, 0x1000
    std
    rep  movsw
    cld
    hlt
    hlt
    nop
    hlt
    call work16
    # to protected mode
    lgdt cs:[gdtr]
    lidt cs:[idtr]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    .byte 0x66, 0xEA
    .long pm32
    .word 0x08

work16:
    mov  cx, 600
1:  add  ax, cx
    mov  bx, ss
    mov  ss, bx
    xor  dx, ax
    loop 1b
    ret

nmi_rm:
    push ax
    push ds
    mov  ax, 0x3000
    mov  ds, ax
    inc  dword ptr [0]
    mov  ax, 10
    test byte ptr [0], 3
    jnz  1f
    mov  ax, 350                        # (longer than the NMI period)
1:  dec  ax
    jnz  1b
    pop  ds
    pop  ax
    iret

.code32
pm32:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  esp, 0x2FFF0
    call work32
    mov  esi, 0x40000
    mov  edi, 0x60000
    mov  ecx, 0x2000
    rep  movsd
    hlt
    nop
    hlt
    call work32
    mov  dword ptr [FIN], 1
1:  jmp  1b

work32:
    mov  ecx, 800
1:  imul eax, ecx
    mov  bx, ss
    mov  ss, bx
    add  edx, eax
    loop 1b
    ret

nmi_pm:
    push eax
    inc  dword ptr [CNT]
    cmp  dword ptr [FIN], 0
    jne  2f
    mov  eax, 10
    test byte ptr [CNT], 3
    jnz  1f
    mov  eax, 350
1:  dec  eax
    jnz  1b
    pop  eax
    iretd
2:  mov  eax, [CNT]
    out  0xE9, al                       # (the number of NMIs: LOCKE9=1 shows it)
    hlt                                 # NMI blocked: stays here

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
    .word nmi_pm, 0x08, 0x8E00, 0
idt_end:
