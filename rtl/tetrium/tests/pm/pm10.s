# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# TLB test registers TR6 / TR7 (i486 manual 10.6), paging off: TLB writes into a given
# way (TR7.PL / REP) and into the replacement way (pseudo-LRU, an invalid way first),
# lookups (hit / miss, V, the D / U / W bit pairs), TR7's LRU bits before the lookup and
# the way, TR6's attribute pairs set from the hit, CR3 write (flush), INVLPG, MOV TR0
# (#UD).  Every TR6 / TR7 value read is logged.
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
.macro logr r
    mov  ebx, [logp]
    mov  [ebx], \r
    add  dword ptr [logp], 4
.endm
.macro tw lin, attr, pa, ctl       # TLB write: TR7 = pa | ctl, TR6 = lin | attr (C = 0)
    mov  eax, (\pa) | (\ctl)
    mov  tr7, eax
    mov  eax, (\lin) | (\attr)
    mov  tr6, eax
.endm
.macro tl lin, attr                # TLB lookup: TR6 = lin | attr | C, log TR7, TR6
    mov  eax, (\lin) | (\attr) | 1
    mov  tr6, eax
    mov  eax, tr7
    logr eax
    mov  eax, tr6
    logr eax
.endm
V = 0x800
D = 0x400
DN = 0x200
U = 0x100
UN = 0x80
W = 0x40
WN = 0x20
ALL = D | DN | U | UN | W | WN     # lookup: match the bit set or clear
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
    mov  dword ptr [logp], offset log
    mov  eax, cr3                   # empty TLB
    mov  cr3, eax
    # set 1 (linear bits 14:12 = 1): four entries in given ways, then lookups
    tw   0x00401000, V | D | U | W,       0x12345000, 0x10 | (0 << 2)
    tw   0x00809000, V | U | W,           0x23456800, 0x10 | (2 << 2)    # (PCD)
    tw   0x00C01000, V | D,               0x34567400, 0x10 | (1 << 2)    # (PWT)
    tw   0x01009000, V | W,               0x45678C00, 0x10 | (3 << 2)
    tl   0x00401000, V | ALL
    tl   0x00809000, V | ALL
    tl   0x00C01000, V | ALL
    tl   0x01009000, V | ALL
    tl   0x00401000, V | DN | ALL & ~D  # D must be clear: miss
    tl   0x00C01000, V | D | U | W | WN # U clear required? (U set only): miss
    tl   0x00809000, V | UN | U | W | DN # hit
    tl   0x00401000, ALL                # V clear: miss
    tl   0x00405000, V | ALL            # other set: miss
    # replacement: set 2 empty -> ways 0, 1, 2, 3 in order, then by the LRU bits
    tw   0x00002000, V | D | U | W,       0x00102000, 0
    tw   0x00402000, V | D | U | W,       0x00202000, 0
    tw   0x00802000, V | D | U | W,       0x00302000, 0
    tw   0x00C02000, V | D | U | W,       0x00402000, 0
    tl   0x00402000, V | ALL            # touch way 1
    tw   0x01002000, V | D | U | W,       0x00502000, 0     # victim by LRU
    tl   0x00002000, V | ALL
    tl   0x00402000, V | ALL
    tl   0x00802000, V | ALL
    tl   0x00C02000, V | ALL
    tl   0x01002000, V | ALL
    tw   0x01402000, V | D | U | W,       0x00602000, 0
    tl   0x01402000, V | ALL
    tl   0x00802000, V | ALL
    # an invalid entry written (V = 0) is matched by a V = 0 lookup only
    tw   0x00003000, D | U | W,           0x00703000, 0x10 | (2 << 2)
    tl   0x00003000, V | ALL
    tl   0x00003000, ALL
    # INVLPG drops the entry of its page, CR3 drops all
    mov  eax, 0x00401000
    invlpg [eax]
    tl   0x00401000, V | ALL
    tl   0x00809000, V | ALL
    mov  eax, cr3
    mov  cr3, eax
    tl   0x00809000, V | ALL
    tl   0x01402000, V | ALL
    # TR0 does not exist: #UD
    mov  dword ptr [resume], offset 1f
    .byte 0x0F, 0x24, 0xC0          # mov eax, tr0
1:  mov  eax, [logp]
    hlt

hud:
    push eax
    mov  eax, 0x060000
    logr eax
    mov  eax, [resume]
    mov  [esp+4], eax
    pop  eax
    iretd

.align 4
resume: .long 0
logp:   .long 0
log:    .fill 96, 4, 0
gdtr:   .word 0x17
        .long 0x10A00
idtr:   .word 7 * 8 - 1
        .long 0x10800
.org 0x800
idt:
    .fill 6, 8, 0
    gate hud, 0x08, 0x8E                   # 6 #UD
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4          # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC       # 10 data32
