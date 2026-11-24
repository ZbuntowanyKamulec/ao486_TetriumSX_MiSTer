# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# LAR / LSL (failing and succeeding, register and memory selector) and ARPL (no change) right
# before an instruction that reads their destination; single stepping (TF) over STI, MOV SS, LSS
# and REP strings (a trap per iteration, one after the last); RF in the frame of a fault.
.intel_syntax noprefix
.macro desc base, limit, acc, fl
    .word (\limit) & 0xFFFF
    .word (\base) & 0xFFFF
    .byte ((\base) >> 16) & 0xFF
    .byte \acc
    .byte (((\limit) >> 16) & 0x0F) | ((\fl) << 4)
    .byte ((\base) >> 24) & 0xFF
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
    xor  ebp, ebp
    mov  ecx, 0x1FF8                    # beyond the GDT
    mov  dword ptr [buf], 0x1FF8
    mov  edi, 3
1:  mov  ebx, 0x12345678
    lsl  ebx, ecx
    add  ebp, ebx
    mov  ebx, 0x9ABCDEF0
    lar  ebx, ecx
    adc  ebp, ebx
    mov  esi, 0x11112222
    lsl  esi, word ptr [buf]
    xor  ebp, esi
    mov  dx, 0x7777
    lar  dx, word ptr [buf]
    add  ebp, edx
    mov  eax, 0x08
    lsl  ebx, eax                       # succeeding
    add  ebp, ebx
    lar  ebx, eax
    add  ebp, ebx
    mov  eax, 0x1233
    mov  edx, 0x0002
    arpl ax, dx                         # RPL 3 > 2: no change
    add  ebp, eax
    arpl dx, ax
    add  ebp, edx
    dec  edi
    jnz  1b
    # single stepping
    mov  esi, offset buf
    mov  edi, offset buf + 0x100
    mov  eax, 0x10
    mov  dword ptr [buf + 0x80], 0xF000
    mov  word ptr [buf + 0x84], 0x10
    pushfd
    or   dword ptr [esp], 0x100
    popfd
    nop
    mov  ss, ax
    nop
    lss  esp, [buf + 0x80]
    nop
    mov  ecx, 3
    rep  movsd
    mov  ecx, 1
    rep  stosb
    xor  ecx, ecx
    rep  movsb
    mov  ecx, 4
    repe cmpsb
    mov  ecx, 4
    repne scasb
    mov  ecx, 2
    rep  lodsw
    pushfd
    and  dword ptr [esp], 0xFFFFFEFF
    popfd
    ud2
    nop
    mov  eax, ebp
    mov  ebx, [steps]
    hlt

h_db:
    inc  dword ptr [steps]
    push eax
    mov  eax, [esp + 4]
    mov  [last], eax
    pop  eax
    iretd
h_ud:
    push eax
    mov  eax, [esp + 12]                # EFLAGS: RF set
    mov  [last], eax
    add  dword ptr [esp + 4], 2
    pop  eax
    iretd
.align 8
gdt:
    .quad 0
    desc 0x10000, 0xFFFFF, 0x9B, 0xC
    desc 0x10000, 0xFFFFF, 0x93, 0xC
gdtr:
    .word . - gdt - 1
    .long 0x10000 + gdt
.align 8
idt:
    .quad 0
    .word h_db, 0x08, 0x8E00, 0
    .quad 0, 0, 0, 0
    .word h_ud, 0x08, 0x8E00, 0
idtr:
    .word . - idt - 1
    .long 0x10000 + idt
steps: .long 0
last:  .long 0
.align 16
buf:   .skip 0x200
