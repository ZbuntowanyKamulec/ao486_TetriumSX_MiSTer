# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# paging: demand paging (#PF on a not-present page, the handler maps it and the access
# restarts), CR0.WP for supervisor writes, accesses crossing into a not-present /
# read-only page (no part done, CR2 = the last byte as 86Box), an aliased page (store
# through one mapping, load / execute through the other: forwarding and self-modifying
# code on physical addresses), an instruction fetch #PF, INVLPG, a CR3 reload, the
# accessed / dirty bits, ring 3 accesses to supervisor and read-only pages.
# Segments 08 / 10 have base 10000 (the program), 28 / 30 are flat.  The #PF handler logs
# (error code | 0E0000, CR2, pushed EIP); with [fixa] set it writes [fixv] to that PTE,
# INVLPGs and restarts the instruction, else it resumes at [resume].
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
.macro try lbl                      # the next instruction faults: resume at lbl
    mov  dword ptr [resume], offset \lbl
.endm
.macro fix pg, val                  # the next access faults on page pg: map it to val
    mov  dword ptr [fixa], 0x21000 + (\pg) * 4
    mov  dword ptr [fixv], \val
.endm
.macro logr r                       # append a register to the log
    mov  ebx, [logp]
    mov  [ebx], \r
    add  dword ptr [logp], 4
.endm
PT = 0x21000
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
    mov  ss, ax
    mov  esp, 0xF000
    mov  ax, 0x28
    mov  es, ax
    mov  fs, ax
    mov  ax, 0x38
    ltr  ax
    mov  dword ptr [logp], offset log
    # page directory 20000 (one table, 21000), pages 0-3F identity (user, writable)
    mov  edi, 0x20000
    mov  ecx, 2048
    xor  eax, eax
    cld
    rep  stosd
    mov  dword ptr es:[0x20000], PT + 7
    mov  edi, PT
    mov  eax, 7
    mov  ecx, 0x40
1:  stosd
    add  eax, 0x1000
    loop 1b
    mov  dword ptr es:[PT + 0x30*4], 0               # not present (demand paging -> 31000)
    mov  dword ptr es:[PT + 0x32*4], 0x32005         # read-only
    mov  dword ptr es:[PT + 0x33*4], 0x33003         # supervisor only
    mov  dword ptr es:[PT + 0x34*4], 0x35007         # alias of 35000
    mov  dword ptr es:[PT + 0x37*4], 0               # not present
    mov  dword ptr es:[PT + 0x38*4], 0x38005         # read-only
    mov  dword ptr es:[PT + 0x39*4], 0               # not present (code -> 35000)
    mov  dword ptr es:[0x31010], 0x12345678
    mov  dword ptr es:[0x36100], 0x36363636
    mov  dword ptr es:[0x36FFC], 0x0C0B0A09
    mov  dword ptr es:[0x37000], 0x44332211
    mov  dword ptr es:[0x37FFC], 0x99887766
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  1f
1:
    # demand paging: #PF(0), mapped, restarted
    fix  0x30, 0x31007
    mov  eax, fs:[0x30010]
    logr eax
    # supervisor write to a read-only page: allowed with WP clear, #PF(3) with WP set
    mov  dword ptr fs:[0x32000], 0x1111
    mov  eax, cr0
    or   eax, 0x10000
    mov  cr0, eax
    try  1f
    mov  dword ptr fs:[0x32004], 0x2222
1:  mov  eax, cr0
    and  eax, ~0x10000
    mov  cr0, eax
    # a dword read crossing into a not-present page: #PF(0), CR2 = 37001, restarted
    fix  0x37, 0x37007
    mov  eax, fs:[0x36FFE]
    logr eax
    # a dword write crossing into a read-only page (WP set): #PF(3), nothing written
    mov  eax, cr0
    or   eax, 0x10000
    mov  cr0, eax
    try  1f
    mov  dword ptr fs:[0x37FFE], 0xAABBCCDD
1:  mov  eax, cr0
    and  eax, ~0x10000
    mov  cr0, eax
    mov  eax, fs:[0x37FFC]
    logr eax
    # alias: a store through 34xxx, the load through 35xxx right after it
    mov  dword ptr fs:[0x34100], 0x5A5A1234
    mov  eax, fs:[0x35100]
    logr eax
    # self-modifying code through the alias: snippet at 35200 (mov eax, imm32; retf)
    mov  dword ptr fs:[0x35200], 0x111111B8
    mov  dword ptr fs:[0x35204], 0xCB11
    .byte 0x9A
    .long 0x35200
    .word 0x30
    logr eax
    mov  dword ptr fs:[0x34201], 0x22222222
    .byte 0x9A
    .long 0x35200
    .word 0x30
    logr eax
    # instruction fetch from a not-present page: #PF(0), CR2 = EIP = 39200, mapped to 35000
    fix  0x39, 0x35007
    .byte 0x9A
    .long 0x39200
    .word 0x30
    logr eax
    # INVLPG: remap 34 to 36000
    mov  eax, fs:[0x34100]
    mov  dword ptr es:[PT + 0x34*4], 0x36007
    mov  eax, 0x34000
    invlpg fs:[eax]
    mov  eax, fs:[0x34100]
    logr eax
    # CR3 reload: remap 34 back to 35000
    mov  dword ptr es:[PT + 0x34*4], 0x35007
    mov  eax, cr3
    mov  cr3, eax
    mov  eax, fs:[0x34100]
    logr eax
    # accessed / dirty bits
    mov  eax, fs:[0x3A000]
    mov  eax, es:[PT + 0x3A*4]
    logr eax
    mov  dword ptr fs:[0x3A004], 1
    mov  eax, es:[PT + 0x3A*4]
    logr eax
    mov  eax, es:[0x20000]
    logr eax
    # ring 3: supervisor page (#PF(5)), read-only page (#PF(7))
    push 0x23                       # SS
    push 0xC000
    push 0x0002                     # EFLAGS
    push 0x1B                       # CS
    push offset ring3
    iretd
ring3:
    mov  ax, 0x23
    mov  ds, ax
    mov  ax, 0x2B
    mov  fs, ax
    try  1f
    mov  eax, fs:[0x33000]
1:  try  1f
    mov  dword ptr fs:[0x32008], 0x3333
1:  mov  eax, fs:[0x32000]          # (readable)
    logr eax
    int  0x31

hpf:
    push eax
    push ebx
    mov  ebx, [logp]
    mov  eax, [esp+8]
    or   eax, 0x0E0000
    mov  [ebx], eax
    mov  eax, cr2
    mov  [ebx+4], eax
    mov  eax, [esp+12]
    mov  [ebx+8], eax
    add  dword ptr [logp], 12
    mov  eax, [fixa]
    test eax, eax
    jz   1f
    mov  ebx, [fixv]
    mov  es:[eax], ebx
    mov  dword ptr [fixa], 0
    mov  eax, cr2
    invlpg fs:[eax]
    jmp  2f
1:  mov  eax, [resume]
    mov  [esp+12], eax
2:  pop  ebx
    pop  eax
    add  esp, 4
    iretd
hgp:                                # (not expected)
    mov  eax, [esp]
    or   eax, 0x0D0000
    logr eax
    hlt
h31:
    mov  ax, 0x10
    mov  ds, ax
    mov  eax, [logp]
    hlt

.align 4
resume: .long 0
fixa:   .long 0
fixv:   .long 0
logp:   .long 0
log:    .fill 48, 4, 0
gdtr:   .word 0x3F
        .long 0x10A00
idtr:   .word 0x32 * 8 - 1
        .long 0x10800
.org 0x700
tss:    .long 0, 0xE000, 0x10       # link, ESP0, SS0
        .fill 0x68 - 12, 1, 0
.org 0x800
idt:
    .fill 13, 8, 0
    gate hgp, 0x08, 0x8E                   # 13 #GP
    gate hpf, 0x08, 0x8E                   # 14 #PF
    .fill 0x31 - 15, 8, 0
    gate h31, 0x08, 0xEE                   # 31 (DPL 3)
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
    desc 0x10000, 0xFFFF, 0xFA, 4          # 18 code32 DPL 3
    desc 0x10000, 0xFFFFF, 0xF2, 0xC       # 20 data32 DPL 3
    desc 0, 0xFFFFF, 0xF2, 0xC             # 28 flat data DPL 3
    desc 0, 0xFFFFF, 0x9A, 0xC             # 30 flat code32
    desc 0x10700, 0x67, 0x89, 0            # 38 TSS32
