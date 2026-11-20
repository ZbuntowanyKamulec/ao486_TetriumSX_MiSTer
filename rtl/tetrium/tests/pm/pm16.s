# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Debug trap and interrupts at the same instruction end: single stepping (TF) with IF set
# while INTR arrives every N cycles (lockirq).  The 486 takes the TF trap first (#DB),
# INTR after the #DB handler's IRET; the single-step trap is never lost.  The handlers
# count; the final EAX / EBX are the counts.
# lockirq: 151 233 397 611
.intel_syntax noprefix
.code16
.org 0x100
start:
    cli
    xor  ax, ax
    mov  es, ax
    mov  word ptr es:[4], offset hdb          # vector 1
    mov  word ptr es:[6], 0x1000
    mov  word ptr es:[0x20], offset hirq      # vector 8 (the testbench's INTR)
    mov  word ptr es:[0x22], 0x1000
    push ds
    pop  es
    xor  ebx, ebx
    pushf
    pop  ax
    or   ax, 0x0300                           # TF, IF
    push ax
    popf
    mov  ecx, 200
1:  add  bx, cx
    pushad                                   # (long instructions with defined flags:
    popad                                    # INTR often arrives while one executes)
    xchg [ndb + 4], ax
    mov  si, bx
    loop 1b
    pushf
    pop  ax
    and  ax, 0xFEFF
    push ax
    popf
    cli
    movzx eax, word ptr [ndb]
    movzx ebx, word ptr [nirq]
    hlt
hdb:
    inc  word ptr cs:[ndb]
    iret
hirq:
    inc  word ptr cs:[nirq]
    iret
.align 2
ndb:  .word 0
nirq: .word 0
      .word 0
