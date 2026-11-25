# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Probe: INT n from V86 mode (IOPL 3) to ring 0 through a 16-bit (286) interrupt gate, then
# through a 32-bit one.  The handler prints the frame size (ESP0 - ESP), the frame as words
# (lowest address first) and its data segment selectors (cleared on the way out of V86).
.intel_syntax noprefix
.include "mac.s"
R    = 0x3000                           # results
TSSA = 0x1800
ESP0 = 0x2E000
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
    mov  esp, ESP0
    mov  ax, 0x28
    ltr  ax
    mov  ebx, offset v86a
    jmp  tov86
# IRETD into V86 at 1000:EBX, IOPL 3, IF clear
tov86:
    push 0x4444                         # GS
    push 0x3333                         # FS
    push 0x2222                         # DS
    push 0x1111                         # ES
    push 0x1000                         # SS
    push 0xF000                         # ESP
    push 0x23002                        # EFLAGS: VM, IOPL 3
    push 0x1000                         # CS
    push ebx                            # EIP
    iretd
.code16
v86a:
    int  0x31                           # 16-bit gate
v86b:
    int  0x32                           # 32-bit gate
.code32
# handlers: EBP = result block
h31:
    mov  ebp, R
    call grab
    mov  esp, ESP0
    mov  ebx, offset v86b
    jmp  tov86
h32:
    mov  ebp, R + 0x40
    call grab
    PS   "v86gate gate16 size frame sregs: "
    mov  ebp, R
    call show
    PS   "| gate32: "
    mov  ebp, R + 0x40
    call show
    jmp  done
# record the frame (caller's ESP + 4) and the data selectors at [EBP] (SS base 10000h)
grab:
    mov  ax, ds
    mov  ss:[ebp + 0x30], ax
    mov  ax, es
    mov  ss:[ebp + 0x32], ax
    mov  ax, fs
    mov  ss:[ebp + 0x34], ax
    mov  ax, gs
    mov  ss:[ebp + 0x36], ax
    mov  ax, 0x10
    mov  ds, ax
    lea  esi, [esp + 4]
    mov  eax, ESP0
    sub  eax, esi
    mov  [ebp], eax
    mov  ecx, 10                        # 10 dwords of the frame (40 bytes at most)
    lea  edi, [ebp + 4]
1:  mov  eax, [esi]
    mov  [edi], eax
    add  esi, 4
    add  edi, 4
    loop 1b
    ret
# print: size, the frame's words (size / 2 of them), the four selectors
show:
    PH   [ebp]
    mov  ecx, [ebp]
    shr  ecx, 1
    lea  esi, [ebp + 4]
1:  movzx eax, word ptr [esi]
    call puthex4
    add  esi, 2
    loop 1b
    PS   "sregs "
    movzx eax, word ptr [ebp + 0x30]
    call puthex4
    movzx eax, word ptr [ebp + 0x32]
    call puthex4
    movzx eax, word ptr [ebp + 0x34]
    call puthex4
    movzx eax, word ptr [ebp + 0x36]
    call puthex4
    ret
# AX as 4 hex digits and a space
puthex4:
    push eax
    push ecx
    push edx
    mov  edx, eax
    shl  edx, 16
    mov  ecx, 4
1:  rol  edx, 4
    mov  al, dl
    and  al, 15
    add  al, '0'
    cmp  al, '9'
    jbe  2f
    add  al, 7
2:  call putc
    loop 1b
    mov  al, ' '
    call putc
    pop  edx
    pop  ecx
    pop  eax
    ret
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
    .quad 0, 0                              # 18, 20
    desc 0x10000 + TSSA, 0x67, 0x89, 0      # 28 TSS32
gdt_end:
.align 8
idt:
    .fill 0x31, 8, 0
    gate h31, 0x08, 0xE6                    # 31 286 interrupt gate, DPL 3
    gate h32, 0x08, 0xEE                    # 32 386 interrupt gate, DPL 3
idt_end:
.org TSSA
    .long 0, ESP0, 0x10                     # link, ESP0, SS0
    .fill 0x68 - 12, 1, 0
