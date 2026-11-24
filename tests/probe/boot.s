# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Floppy boot sector for the probes (Bochs, or a real PC): loads the probe image that follows
# it (sector count in the word at offset 1FCh, patched by tests/probe.sh) to 1000:0000 and starts
# it at 1000:0100 in the testbench's .COM state: CS = DS = ES = SS = 1000h, SP = FFFEh, the
# other registers 0, FLAGS 0002h (interrupts off).
.intel_syntax noprefix
.code16
    .byte 0xEA                          # jmp 07C0:go (offsets from the sector start)
    .word go, 0x07C0
go:
    cli
    mov  ax, cs
    mov  ds, ax
    xor  ax, ax
    mov  ss, ax
    mov  sp, 0x7C00
    mov  [drive], dl
    mov  ax, 0x1000
    mov  es, ax
    xor  bx, bx
    mov  cx, 2                          # cylinder 0, sector 2
    xor  dh, dh                         # head 0
    mov  si, [nsec]
1:  mov  ax, 0x0201
    mov  dl, [drive]
    int  0x13
    jc   fail
    add  bx, 512
    inc  cl
    cmp  cl, 19                         # 18 sectors per track
    jb   2f
    mov  cl, 1
    xor  dh, 1
    jnz  2f
    inc  ch
2:  dec  si
    jnz  1b
    cli
    mov  ax, 0x1000
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  esp, 0xFFFE
    xor  eax, eax
    mov  fs, ax
    mov  gs, ax
    xor  ebx, ebx
    xor  ecx, ecx
    xor  edx, edx
    xor  esi, esi
    xor  edi, edi
    xor  ebp, ebp
    push 2
    popf
    .byte 0xEA                          # jmp 1000:0100
    .word 0x0100, 0x1000
fail:
    mov  al, '!'
    out  0xE9, al
    hlt
    jmp  fail
drive: .byte 0
.org 0x1FC
nsec:  .word 0
    .byte 0x55, 0xAA
