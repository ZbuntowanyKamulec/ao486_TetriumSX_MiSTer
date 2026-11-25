# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# i486 additions: CPUID (leaves 0, 1, 2), BSWAP (ESP too), EFLAGS.AC / ID writable, the
# alignment check (#AC(0), CR0.AM + EFLAGS.AC at CPL 3): ring 0 never checked, ring 3 loads /
# stores / pushes / string sources and destinations, bytes and aligned accesses never fault, a
# limit fault comes before #AC, AC cleared and set again by POPFD at ring 3, LES (offset
# dword), and V86 mode.  The #AC / #GP handlers log (vector << 16 | error code, pushed EIP)
# and resume at [resume].  Segments 08 / 10 / 18 / 20 have base 10000 (the program).
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
.macro logr r                       # append a register to the log
    mov  edi, [logp]
    mov  [edi], \r
    add  dword ptr [logp], 4
.endm
.code16
.org 0x100
start:
    cli
    mov  dword ptr [logp], offset log
    # ---- CPUID (if EFLAGS.ID can be toggled: a build without CPUID skips it)
    pushfd
    pop  eax
    mov  ecx, eax
    xor  eax, 0x200000
    push eax
    popfd
    pushfd
    pop  eax
    push ecx
    popfd
    xor  eax, ecx
    test eax, 0x200000
    jz   nocpuid
    xor  eax, eax
    cpuid
    logr eax
    logr ebx
    logr ecx
    logr edx
    mov  eax, 1
    cpuid
    logr eax
    logr ebx
    logr ecx
    logr edx
    mov  eax, 2
    mov  ebx, 0x5555
    cpuid
    logr eax
    logr ebx
nocpuid:
    # ---- BSWAP, ESP included (swapped twice: the stack is not used in between)
    mov  eax, 0x11223344
    bswap eax
    logr eax
    mov  ebp, 0x8899AABB
    bswap ebp
    logr ebp
    mov  edx, esp
    bswap esp
    mov  ecx, esp
    bswap esp
    logr ecx
    # ---- EFLAGS: AC and ID flip, then restored
    pushfd
    pop  eax
    mov  ecx, eax
    xor  eax, 0x240000
    push eax
    popfd
    pushfd
    pop  eax
    logr eax
    push ecx
    popfd
    pushfd
    pop  eax
    logr eax
    # 16-bit POPF leaves them
    pushfd
    or   dword ptr [esp], 0x240000
    popfd
    push 0x0002
    popf
    pushfd
    pop  eax
    logr eax
    push ecx
    popfd

    # ---- protected mode
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
    mov  ax, 0x38
    ltr  ax
    mov  eax, cr0
    or   eax, 0x40000                # AM
    mov  cr0, eax
    pushfd
    or   dword ptr [esp], 0x40000    # AC
    popfd
    mov  eax, [mis + 1]              # ring 0: no check
    logr eax
    push 0x23                        # SS
    push 0xC000
    push 0x40002                     # EFLAGS: AC
    push 0x1B                        # CS
    push offset ring3
    iretd
ring3:
    mov  ax, 0x23
    mov  ds, ax
    mov  es, ax
    mov  ax, 0x43
    mov  gs, ax
    try  1f
    mov  ax, [mis + 1]               # word at an odd address
1:  try  1f
    mov  dword ptr [mis + 2], 0x12345678     # dword at 2 mod 4: nothing written
1:  mov  eax, [mis]
    logr eax
    mov  al, [mis + 1]               # bytes, aligned words / dwords: no check
    logr eax
    mov  ax, [mis + 2]
    logr eax
    mov  eax, [mis + 4]
    logr eax
    # pushes: a dword push to ESP 2 mod 4
    mov  esp, 0xC002
    try  1f
    push eax
1:  logr esp
    push ax                          # (a word push to an even address)
    pop  ax
    mov  esp, 0xC000
    try  1f
    push dword ptr [mis + 1]         # (the source)
1:  logr esp
    # strings: MOVSD to a misaligned destination, MOVSW from a misaligned source
    cld
    mov  esi, offset mis
    mov  edi, offset mis + 0x11
    try  1f
    movsd
1:  mov  eax, edi
    logr esi
    logr eax
    mov  esi, offset mis + 1
    mov  edi, offset mis + 0x10
    try  1f
    movsw
1:  logr esi
    mov  esi, offset mis + 4
    mov  edi, offset mis + 0x14
    movsd                            # aligned
    logr esi
    mov  eax, [mis + 0x14]
    logr eax
    # a limit fault (#GP) before #AC: dword at FE of a 256-byte segment
    try  1f
    mov  eax, gs:[0xFE]
1:  try  1f
    mov  eax, gs:[0xFB]              # (inside: #AC)
1:  # LES: the offset dword first
    try  1f
    les  eax, [mis + 2]
1:  # AC cleared at ring 3: no check; set again
    pushfd
    and  dword ptr [esp], ~0x40000
    popfd
    mov  eax, [mis + 1]
    logr eax
    pushfd
    or   dword ptr [esp], 0x40000
    popfd
    try  1f
    mov  eax, [mis + 3]
1:  try  1f
    add  [mis + 5], ax               # read-modify-write
1:  try  1f
    invd                             # CPL 3: #GP(0)
1:  try  1f
    wbinvd
1:  int  0x31                        # to ring 0: V86 next

h31:
    mov  ax, 0x10
    mov  ds, ax
    # V86 at 1000:v86 (IOPL 3, AC)
    push 0                           # GS
    push 0                           # FS
    push 0x1000                      # DS
    push 0x1000                      # ES
    push 0x1000                      # SS
    push 0xD000                      # ESP
    push 0x63002                     # EFLAGS: AC, VM, IOPL 3
    push 0x1000                      # CS
    push offset v86
    iretd
.code16
v86:
    try  1f
    mov  ax, [mis + 1]
1:  mov  ax, [mis + 2]
    logr eax
    try  1f
    mov  eax, [mis + 6]
1:  pushfd
    and  dword ptr [esp], ~0x40000
    popfd
    mov  eax, [mis + 6]
    logr eax
    int  0x32
.code32
h32:
    mov  ax, 0x10
    mov  ds, ax
    mov  eax, [logp]
    hlt

hac:                                 # #AC (17)
    push ds
    push eax
    push edi
    mov  ax, 0x10
    mov  ds, ax
    mov  edi, [logp]
    mov  eax, [esp + 12]
    or   eax, 0x110000
    mov  [edi], eax
    mov  eax, [esp + 16]
    mov  [edi + 4], eax
    add  dword ptr [logp], 8
    mov  eax, [resume]
    mov  [esp + 16], eax
    pop  edi
    pop  eax
    pop  ds
    add  esp, 4
    iretd
hgp:                                 # #GP (13)
    push ds
    push eax
    push edi
    mov  ax, 0x10
    mov  ds, ax
    mov  edi, [logp]
    mov  eax, [esp + 12]
    or   eax, 0x0D0000
    mov  [edi], eax
    mov  eax, [esp + 16]
    mov  [edi + 4], eax
    add  dword ptr [logp], 8
    mov  eax, [resume]
    mov  [esp + 16], eax
    pop  edi
    pop  eax
    pop  ds
    add  esp, 4
    iretd

.align 4
resume: .long 0
logp:   .long 0
mis:    .long 0x44332211, 0x88776655, 0xCCBBAA99, 0x00FFEEDD
        .long 0, 0, 0, 0
gdtr:   .word 0x4F
        .long 0x10A00
idtr:   .word 0x33 * 8 - 1
        .long 0x10800
.org 0x700
tss:    .long 0, 0xE000, 0x10        # link, ESP0, SS0
        .fill 0x68 - 12, 1, 0
.org 0x800
idt:
    .fill 13, 8, 0
    gate hgp, 0x08, 0x8E                    # 13 #GP
    .fill 3, 8, 0
    gate hac, 0x08, 0x8E                    # 17 #AC
    .fill 0x31 - 18, 8, 0
    gate h31, 0x08, 0xEE                    # 31 (DPL 3)
    gate h32, 0x08, 0xEE                    # 32 (DPL 3)
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4           # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC        # 10 data32
    desc 0x10000, 0xFFFF, 0xFA, 4           # 18 code32 DPL 3
    desc 0x10000, 0xFFFFF, 0xF2, 0xC        # 20 data32 DPL 3
    desc 0, 0xFFFFF, 0xF2, 0xC              # 28 flat data DPL 3
    desc 0, 0xFFFFF, 0x9A, 0xC              # 30 flat code32
    desc 0x10700, 0x67, 0x89, 0             # 38 TSS32
    desc 0x10000, 0xFF, 0xF2, 4             # 40 data32 DPL 3, limit FF
log:    .fill 64, 4, 0                  # (after the tables: room for the code)
