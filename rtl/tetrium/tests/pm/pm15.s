# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# i486 debug exceptions around deliveries: data breakpoints matched by INT n's pushes and
# by its implicit IDT gate read (#DB before the handler's first instruction), by the pushes
# of an exception delivery (#UD), none from the #DB delivery's own pushes, an instruction
# breakpoint on an instruction whose fetch page-faults (#DB first, RF in its frame lets the
# #PF and then the instruction through), and the T bit of a task reached through a task
# gate (#DB with DR6.BT at the new task's first instruction).  The #DB handler logs DR6, the
# pushed EIP and ECX, clears DR6 and loads DR7 from [dr7new].
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
.macro logr r                       # append a register to the log
    mov  edi, [logp]
    mov  [edi], \r
    add  dword ptr [logp], 4
.endm
.macro setdr7 v, after              # DR7 now, and after the next #DB
    mov  dword ptr [dr7new], \after
    mov  eax, \v
    mov  dr7, eax
.endm
.code16
.org 0x100
start:
    cli
    mov  dword ptr [logp], offset log
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
    mov  ax, 0x18
    mov  fs, ax
    mov  ax, 0x20
    ltr  ax
    # ---- INT n: its EFLAGS push at ESP - 4 (write breakpoint)
    mov  eax, 0x10000 + 0xF000 - 4
    mov  dr0, eax
    setdr7 0x000D0002, 0                 # G0, RW0 01, LEN0 11
    int  0x30
    logr ecx
    # ---- INT n: the implicit read of its IDT gate (read / write breakpoint)
    mov  eax, 0x10800 + 0x30 * 8
    mov  dr1, eax
    setdr7 0x00F00008, 0                 # G1, RW1 11, LEN1 11
    int  0x30
    # ---- an exception delivery (#UD) pushing onto the watched slot
    setdr7 0x000D0002, 0
    ud2
    # ---- the #DB frame's own pushes: no second #DB (DR3 covers where it goes)
    mov  eax, 0x10000 + 0xF000 - 4
    mov  dr2, eax
    mov  eax, 0x10000 + 0xF000 - 12
    mov  dr3, eax
    setdr7 0xDD0000A0, 0                 # G2 G3, RW 01, LEN 11
    push eax
    pop  eax
    # ---- paging: identity map of 4 MB, page 12000 not present
    mov  edi, 0x20000
    mov  dword ptr fs:[edi], 0x21003
    mov  ecx, 1
1:  mov  dword ptr fs:[edi + ecx * 4], 0
    inc  ecx
    cmp  ecx, 1024
    jne  1b
    xor  ecx, ecx
1:  mov  eax, ecx
    shl  eax, 12
    or   eax, 3
    mov  fs:[0x21000 + ecx * 4], eax
    inc  ecx
    cmp  ecx, 1024
    jne  1b
    and  dword ptr fs:[0x21000 + 0x12 * 4], ~1
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  1f
1:  # ---- an instruction breakpoint at a target whose page is not present (kept enabled)
    mov  eax, 0x12000
    mov  dr0, eax
    setdr7 0x00000002, 0x00000002        # G0, execute
    mov  eax, offset tgt
    jmp  eax
back:
    logr ebx
    # ---- the T bit through a task gate (INT 32h)
    int  0x32
    hlt

h30:                                     # INT 30h
    mov  eax, 0x30
    logr eax
    iretd
hud:                                     # #UD: skip the UD2
    push eax
    push edi
    mov  eax, 6
    logr eax
    add  dword ptr [esp + 8], 2
    pop  edi
    pop  eax
    iretd
hpf:                                     # #PF: map the page
    push eax
    push edi
    mov  eax, cr2
    logr eax
    shr  eax, 12
    or   dword ptr fs:[0x21000 + eax * 4], 1
    pop  edi
    pop  eax
    add  esp, 4
    iretd
hdb:                                     # #DB
    push eax
    push edi
    inc  dword ptr [dbcnt]
    mov  eax, dr6
    logr eax
    mov  eax, [esp + 8]                  # EIP
    logr eax
    logr ecx
    xor  eax, eax
    mov  dr6, eax
    mov  eax, [dr7new]
    mov  dr7, eax
    pop  edi
    pop  eax
    iretd
tsk2:                                    # the task with the T bit
    mov  eax, 0x7A5C
    logr eax
    mov  eax, [dbcnt]
    logr eax
    mov  eax, [logp]
    hlt

.align 4
logp:   .long 0
dr7new: .long 0
dbcnt:  .long 0
log:    .fill 64, 4, 0
gdtr:   .word 0x2F
        .long 0x10A00
idtr:   .word 0x33 * 8 - 1
        .long 0x10800
.org 0x800
idt:
    .fill 1, 8, 0
    gate hdb, 0x08, 0x8E                    # 1 #DB
    .fill 4, 8, 0
    gate hud, 0x08, 0x8E                    # 6 #UD
    .fill 7, 8, 0
    gate hpf, 0x08, 0x8E                    # 14 #PF
    .fill 0x30 - 15, 8, 0
    gate h30, 0x08, 0x8E                    # 30h
    .fill 1, 8, 0
    .word 0, 0x28, 0x8500, 0                # 32h task gate
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4           # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC        # 10 data32
    desc 0, 0xFFFFF, 0x92, 0xC              # 18 flat data
    desc 0x10B00, 0x67, 0x89, 0             # 20 TSS32 (the first task)
    desc 0x10B80, 0x67, 0x89, 0             # 28 TSS32 (T bit)
.org 0xB00
    .fill 0x68, 1, 0
.org 0xB80
    .long 0, 0, 0, 0, 0, 0, 0               # link, ESP0-2 / SS0-2
    .long 0x20000                           # CR3
    .long tsk2, 0x2                         # EIP, EFLAGS
    .long 0, 0, 0, 0, 0xE000, 0, 0, 0       # EAX ECX EDX EBX ESP EBP ESI EDI
    .long 0x10, 0x08, 0x10, 0x10, 0, 0      # ES CS SS DS FS GS
    .long 0                                 # LDT
    .word 1, 0                              # T, I/O map base
.org 0x2000
tgt:                                        # (linear 12000: not present at first)
    mov  ebx, 0x7777
    xor  eax, eax
    mov  dr7, eax
    mov  eax, offset back
    jmp  eax
