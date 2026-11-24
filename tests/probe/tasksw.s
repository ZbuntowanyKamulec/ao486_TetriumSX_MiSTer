# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Probe: task switch faults raised in the new task.  CALL to a TSS whose LDT selector names a
# data segment (#TS(LDT)), then to a TSS whose DS selector is beyond the GDT (#TS(DS)).  The
# #TS handler (interrupt gate, in the new task) prints per case: error code, NT in the pushed
# EFLAGS, LDTR, TR, and DR7 (L0 / G0 / L1 / G1 were set before the switches: a task switch
# clears the local enables).  It returns into the new task, which sets NT and IRETs back.
.intel_syntax noprefix
.include "mac.s"
R    = 0x3000                           # results: 20h bytes per case
CASE = 0x3100
TS0A = 0x1800                           # TSS addresses (fixed: descriptor fields)
TS1A = 0x1880
TS2A = 0x1900
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
    mov  ax, 0x28
    ltr  ax
    mov  dword ptr [CASE], 0
    mov  eax, 0xFFFFF000                # breakpoints that never match (execute, at FFFFF000h)
    mov  dr0, eax
    mov  dr1, eax
    mov  eax, 0x0F                      # L0 G0 L1 G1
    mov  dr7, eax
    .byte 0x9A                          # call 0030:0 (TSS: bad LDT)
    .long 0
    .word 0x30
    .byte 0x9A                          # call 0040:0 (TSS: bad DS)
    .long 0
    .word 0x40
    PS   "tasksw ldt: err ntpushed ldtr tr dr7: "
    PH   [R]
    PH   [R + 4]
    PH   [R + 8]
    PH   [R + 12]
    PH   [R + 16]
    PS   "| ds: "
    PH   [R + 32]
    PH   [R + 36]
    PH   [R + 40]
    PH   [R + 44]
    PH   [R + 48]
    jmp  done

# #TS (interrupt gate, ring 0, in the new task)
h10:
    mov  ax, 0x10
    mov  ds, ax
    mov  ebx, [CASE]
    shl  ebx, 5
    pop  eax
    mov  [R + ebx], eax                 # error code
    mov  eax, [esp + 8]
    and  eax, 0x4000
    mov  [R + ebx + 4], eax             # NT in the pushed EFLAGS
    sldt ax
    movzx eax, ax
    mov  [R + ebx + 8], eax
    str  ax
    movzx eax, ax
    mov  [R + ebx + 12], eax
    mov  eax, dr7
    mov  [R + ebx + 16], eax
    inc  dword ptr [CASE]
    iretd
# the new tasks' code: back to the caller (NT set whatever the switch left)
tcode:
    mov  ax, 0x10
    mov  ds, ax
    pushfd
    or   dword ptr [esp], 0x4000
    popfd
    iretd
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
    desc 0x10000 + TS0A, 0x67, 0x89, 0      # 28 TSS32: the first task
    desc 0x10000 + TS1A, 0x67, 0x89, 0      # 30 TSS32: LDT selector 38 (a data segment)
    desc 0x10000, 0xFFFF, 0x92, 0           # 38 data (not an LDT)
    desc 0x10000 + TS2A, 0x67, 0x89, 0      # 40 TSS32: DS selector F8 (beyond the GDT)
gdt_end:
.align 8
idt:
    .fill 10, 8, 0
    gate h10, 0x08, 0x8E                    # 10 #TS
idt_end:
# 32-bit TSS: link, ESP0, SS0, ESP1, SS1, ESP2, SS2, CR3, EIP, EFLAGS, EAX..EDI, ES CS SS DS FS GS, LDT, T / I/O map
.macro tss32 eip, esp, ds, ldt
    .long 0, 0x2E000, 0x10, 0, 0, 0, 0, 0, \eip, 0x0002
    .long 0, 0, 0, 0, \esp, 0, 0, 0
    .long 0x10, 0x08, 0x10, \ds, 0x10, 0x10, \ldt, 0
.endm
.org TS0A
    tss32 0, 0, 0x10, 0
.org TS1A
    tss32 tcode, 0x2D000, 0x10, 0x38
.org TS2A
    tss32 tcode, 0x2C000, 0xF8, 0
