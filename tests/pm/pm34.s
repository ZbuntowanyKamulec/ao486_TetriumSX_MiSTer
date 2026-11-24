# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Rarer event combinations (NMI every 700 cycles throughout, delivered through a task gate):
# #TS raised in the new task (CALL to a TSS whose LDT selector is invalid; the handler runs in
# that task and IRETs back), single stepping at ring 0 with NMIs landing on the traps, then V86
# (IOPL 3): INT n through a not-present gate (#NP), through a task gate to a TSS below the
# minimum limit (#TS from V86), a #GP whose gate is not present (#DF from V86), NMIs switching
# out of V86 to the NMI task and back.  The ring 0 handlers log vector, error code and EIP and
# resume at ESI; the last NMI halts in the NMI task.
# lockenv: LOCKNMI=700
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
.macro T insn:vararg
    mov  esi, offset 9f
    \insn
9:
.endm
LOG = 0x30000
STEPS = 0x30F00
DBCNT = 0x30F04
NCNT  = 0x30F08
FIN   = 0x30F0C
G13 = 0x10000 + idt + 13 * 8 + 5
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
    mov  ax, 0x38                       # (TR first: the first NMI switches tasks)
    ltr  ax
    mov  edi, LOG
    mov  ecx, 0x400
    xor  eax, eax
    cld
    rep  stosd
    # #TS in the new task: its LDT selector (F8) is beyond the GDT
    T .byte 0x9A, 0, 0, 0, 0, 0x40, 0
    # single steps (NMIs land on some of the traps)
    mov  dword ptr [STEPS], 60
    mov  ecx, 30
    pushfd
    or   dword ptr [esp], 0x100
    popfd
1:  add  eax, ecx
    dec  ecx
    jnz  1b
    nop
    nop
    # to V86: IOPL 3, CS 1000 (the program), DS 1000, SS 2000
    push 0
    push 0
    push 0x1000
    push 0x1000
    push 0x2000
    push 0xFFF0
    push 0x00023002
    push 0x1000
    push offset v86
    iretd

.code16
v86:
    T int  0x31                         # not present: #NP(18A)
    T int  0x40                         # task gate to the short TSS: #TS(48)
    int  0x41                           # (an interrupt gate: back by IRETD)
    mov  cx, 2000                       # (NMIs: out to the NMI task and back)
1:  add  ax, cx
    xor  dx, ax
    loop 1b
    and  byte ptr [G13 - 0x10000], 0x7F
    T in  al, 0x80                      # #GP through the missing gate: #DF
    mov  cx, 1000
1:  inc  ax
    loop 1b
    mov  esi, -1
    hlt                                 # (#GP: the end)
.code32

# the task of the #TS (the fault is delivered in it): back to the caller through the back link
# (NT: 86Box and the core set it after the descriptor loads, so a #TS there leaves it clear)
t3r: pushfd
     or   dword ptr [esp], 0x4000
     popfd
     iretd
# the NMI task: count, back by IRET (NT); after the end it halts with NMI blocked
nmitask:
    inc  dword ptr [NCNT]
    cmp  dword ptr [FIN], 0
    jne  2f
    iretd
    jmp  nmitask
2:  mov  eax, [LOG]
    out  0xE9, al                       # (faults, #DBs, NMIs: LOCKE9=1 shows them)
    mov  eax, [DBCNT]
    out  0xE9, al
    mov  eax, [NCNT]
    out  0xE9, al
    hlt

e1: push eax                            # #DB: count; TF cleared after STEPS of them
    push ds
    mov  ax, 0x10
    mov  ds, ax
    inc  dword ptr [DBCNT]
    dec  dword ptr [STEPS]
    jnz  1f
    and  dword ptr [esp + 16], ~0x100
1:  pop  ds
    pop  eax
    iretd
i41: iretd
e8:  or   byte ptr ss:[G13], 0x80       # #DF: gate 13 present again
     push 8
     jmp  hc
e10: push 10
     jmp  hc
e11: push 11
     jmp  hc
e13: push 13
     jmp  hc
hc:  push ds
     push eax
     push ebx
     mov  ax, 0x10
     mov  ds, ax
     mov  ebx, [LOG]
     shl  ebx, 4
     mov  eax, [esp+12]
     mov  [LOG + 4 + ebx], eax
     mov  eax, [esp+16]
     mov  [LOG + 8 + ebx], eax
     mov  eax, [esp+20]
     mov  [LOG + 12 + ebx], eax
     mov  [LOG + 16 + ebx], esi
     inc  dword ptr [LOG]
     cmp  esi, -1
     je   fin
     mov  [esp+20], esi
     pop  ebx
     pop  eax
     pop  ds
     add  esp, 8
     iretd
fin: mov  dword ptr [FIN], 1            # the next NMI ends the test
1:   jmp  1b

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
    .quad 0, 0, 0, 0                       # 18-30
    desc 0x13500, 0x67, 0x89, 0            # 38 TSS (main)
    desc 0x13600, 0x67, 0x89, 0            # 40 TSS: invalid LDT selector
    desc 0x13700, 0x60, 0xE9, 0            # 48 TSS below the minimum limit, DPL 3
    desc 0x13800, 0x67, 0x89, 0            # 50 NMI task
gdt_end:
.org 0x3280
idt:
    .fill 1, 8, 0
    gate e1, 0x08, 0x8E
    gate 0, 0x50, 0x85                     # NMI: task gate
    .fill 5, 8, 0
    gate e8, 0x08, 0x8E
    .fill 1, 8, 0
    gate e10, 0x08, 0x8E
    gate e11, 0x08, 0x8E
    .fill 1, 8, 0
    gate e13, 0x08, 0x8E
    .fill 0x31 - 14, 8, 0
    gate i41, 0x08, 0x6E                   # 31: not present, DPL 3
    .fill 0x40 - 0x32, 8, 0
    gate 0, 0x48, 0xE5                     # 40: task gate (DPL 3) to the short TSS
    gate i41, 0x08, 0xEE                   # 41: interrupt gate, DPL 3
idt_end:
.org 0x3500
tss:  .long 0, 0x2F000, 0x10
      .fill 0x66 - 12, 1, 0
      .word 0x200
.org 0x3600                                # (EIP t3r, ESI t3r: the #TS handler resumes there)
tss3: .long 0, 0, 0, 0, 0, 0, 0, 0, t3r, 0x0002
      .long 0, 0, 0, 0, 0x2A000, 0, t3r, 0
      .long 0x10, 0x08, 0x10, 0x10, 0, 0, 0xF8
      .word 0, 0x200
.org 0x3700
tss4: .fill 0x68, 1, 0
.org 0x3800
tssn: .long 0, 0, 0, 0, 0, 0, 0, 0, nmitask, 0x0002
      .long 0, 0, 0, 0, 0x2B000, 0, 0, 0
      .long 0x10, 0x08, 0x10, 0x10, 0, 0, 0
      .word 0, 0x200
