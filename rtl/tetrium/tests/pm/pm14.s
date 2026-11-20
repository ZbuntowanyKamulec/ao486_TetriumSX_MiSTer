# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# i486 debug registers: MOV DRn (reset values, DR6 / DR7 write masks, DR4 / DR5 aliases),
# instruction breakpoints (fault, DR6.Bn), data breakpoints (trap after the instruction:
# write-only and read / write, 1 / 2 / 4-byte lengths, accesses crossing into the
# breakpoint's word, the B bit of a matching breakpoint that is not enabled, a REP MOVSB
# trapping after the iteration that wrote the byte), TF (DR6.BS), DR7.GD (#DB fault with
# DR6.BD, GD cleared on entry), then in protected mode: RF set in the frame of an
# instruction breakpoint (IRETD resumes past it once), a breakpoint on a REP string
# instruction (one fault, no repeat between iterations), the instruction after MOV SS
# (no breakpoint), a task switch to a TSS with the T bit (DR6.BT).  The #DB handlers log DR6, the pushed IP and ECX, clear DR6 and load
# DR7 from [dr7new].
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
.macro setdr7 v                     # DR7 now and after the next #DB
    mov  eax, \v
    mov  dr7, eax
    mov  dword ptr [dr7new], \v
.endm
.code16
.org 0x100
start:
    cli
    mov  dword ptr [logp], offset log
    xor  ax, ax
    mov  es, ax
    mov  word ptr es:[4], offset hdb     # vector 1
    mov  word ptr es:[6], 0x1000
    push ds
    pop  es
    # ---- reset values, write masks, aliases
    mov  eax, dr6
    logr eax
    mov  eax, dr7
    logr eax
    mov  eax, 0x12345678
    mov  dr0, eax
    mov  eax, 0x9ABCDEF0
    mov  dr3, eax
    mov  ebx, dr0
    logr ebx
    mov  ebx, dr3
    logr ebx
    mov  eax, 0xFFFFFFFF
    mov  dr6, eax
    mov  eax, dr6
    logr eax
    xor  eax, eax
    .byte 0x0F, 0x23, 0xE0               # mov dr4, eax (DR6)
    mov  eax, dr6
    logr eax
    mov  eax, 0x00FF0300                 # (no breakpoint enabled)
    .byte 0x0F, 0x23, 0xE8               # mov dr5, eax (DR7)
    .byte 0x0F, 0x21, 0xE8               # mov eax, dr5
    logr eax
    xor  eax, eax
    mov  dr0, eax
    mov  dr3, eax
    mov  dr7, eax
    # ---- instruction breakpoint (real mode: the handler disables it)
    mov  eax, 0x10000 + offset ibp1
    mov  dr0, eax
    mov  dword ptr [dr7new], 0
    mov  eax, 0x00000001                 # L0, execute
    mov  dr7, eax
    xor  ecx, ecx
ibp1:
    inc  ecx
    logr ecx
    # ---- data breakpoint, write only, 4 bytes at var
    mov  eax, 0x10000 + offset var
    mov  dr1, eax
    setdr7 0x00D00008                    # G1, RW1 01, LEN1 11
    mov  al, [var + 2]                   # (a read: no match)
    mov  [var + 2], al
    nop
    # ---- read / write: reads, an access crossing into the breakpoint's word
    setdr7 0x0FF00008                    # G1, RW1 11, LEN1 11 (RW2 11, LEN2 11: not enabled)
    mov  ax, [var + 3]
    mov  eax, [var + 4]                  # (the next word: no match)
    mov  ax, [var - 1]
    mov  eax, [var - 3]
    mov  eax, [var - 4]                  # (no match)
    # a breakpoint not enabled: B2 set by a match all the same (no trap)
    mov  eax, 0x10000 + offset var + 8
    mov  dr2, eax
    mov  eax, [var + 8]
    mov  eax, dr6
    logr eax
    # 1 and 2-byte lengths
    mov  eax, 0x10000 + offset var + 13
    mov  dr3, eax
    setdr7 0x30000040                    # G3, RW3 11, LEN3 00 (byte)
    mov  al, [var + 12]                  # (no match)
    mov  ax, [var + 12]
    mov  eax, 0x10000 + offset var + 14
    mov  dr3, eax
    setdr7 0x70000040                    # LEN3 01 (word at 14)
    mov  al, [var + 13]                  # (no match)
    add  [var + 15], al
    mov  eax, [var + 16]                 # (no match)
    # ---- REP MOVSB: a trap after the iteration writing dst + 2
    mov  eax, 0x10000 + offset dst + 2
    mov  dr1, eax
    setdr7 0x00100008                    # G1, RW1 01, LEN1 00
    mov  dword ptr [dr7new], 0
    cld
    mov  si, offset var
    mov  di, offset dst
    mov  ecx, 6
    rep  movsb
    logr ecx
    # ---- single step: DR6.BS
    pushf
    pop  ax
    or   ah, 1
    push ax
    popf
    nop
    # ---- general detect: #DB before MOV DRn, DR6.BD, GD cleared for the handler
    setdr7 0x00002000
    mov  dword ptr [dr7new], 0
    mov  ebx, dr0
    mov  eax, dr7
    logr eax

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
    mov  es, ax
    mov  ss, ax
    mov  esp, 0xF000
    # an instruction breakpoint kept enabled: each pass faults once (RF in the frame)
    mov  eax, 0x10000 + offset ibp2
    mov  dr0, eax
    setdr7 0x00000002                    # G0, execute
    xor  ebx, ebx
    mov  ecx, 2
1:
ibp2:
    inc  ebx
    loop 1b
    logr ebx
    # on a REP string instruction: one fault for all its iterations
    mov  eax, 0x10000 + offset ibp3
    mov  dr0, eax
    mov  esi, offset var
    mov  edi, offset dst
    mov  ecx, 5
ibp3:
    rep  movsb
    logr ecx
    # the instruction after MOV SS: no breakpoint
    mov  eax, 0x10000 + offset ibp4
    mov  dr0, eax
    mov  ax, 0x10
    mov  ss, ax
ibp4:
    inc  ebx
    logr ebx
    xor  eax, eax
    mov  dr7, eax
    mov  eax, dr6
    logr eax
    # a task switch (JMP) to a 386 TSS with the T bit: #DB trap at its first instruction (DR6.BT)
    mov  ax, 0x18
    ltr  ax
    .byte 0xEA
    .long 0
    .word 0x20
tsk2:
    logr ebx
    mov  eax, [dbcnt]
    logr eax
    mov  eax, [logp]
    hlt

.code16
hdb:                                     # #DB, real mode
    push eax
    push edi
    push bp
    mov  bp, sp
    inc  dword ptr [dbcnt]
    mov  eax, dr6
    logr eax
    movzx eax, word ptr [bp + 10]        # IP
    logr eax
    logr ecx
    and  word ptr [bp + 14], 0xFEFF      # (TF off)
    xor  eax, eax
    mov  dr6, eax
    mov  eax, [dr7new]
    mov  dr7, eax
    pop  bp
    pop  edi
    pop  eax
    iret
.code32
hdb32:                                   # #DB, protected mode
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

.align 4
logp:   .long 0
dr7new: .long 0
dbcnt:  .long 0
var:    .long 0x44332211, 0x88776655, 0xCCBBAA99, 0x00FFEEDD, 0x55AA55AA
dst:    .fill 8, 1, 0
log:    .fill 64, 4, 0
gdtr:   .word 0x27
        .long 0x10A00
idtr:   .word 0x0F
        .long 0x10800
.org 0x800
idt:
    .fill 1, 8, 0
    gate hdb32, 0x08, 0x8E                  # 1 #DB
.org 0xA00
gdt:
    .quad 0
    desc 0x10000, 0xFFFF, 0x9A, 4           # 08 code32
    desc 0x10000, 0xFFFFF, 0x92, 0xC        # 10 data32
    desc 0x10B00, 0x67, 0x89, 0             # 18 TSS32 (the first task)
    desc 0x10B80, 0x67, 0x89, 0             # 20 TSS32 (T bit)
.org 0xB00
    .fill 0x68, 1, 0
.org 0xB80
    .long 0, 0, 0, 0, 0, 0, 0               # link, ESP0-2 / SS0-2
    .long 0                                 # CR3
    .long tsk2, 0x2                         # EIP, EFLAGS
    .long 0, 0, 0, 0x5A5A, 0xE000, 0, 0, 0  # EAX ECX EDX EBX ESP EBP ESI EDI
    .long 0x10, 0x08, 0x10, 0x10, 0, 0      # ES CS SS DS FS GS
    .long 0                                 # LDT
    .word 1, 0                              # T, I/O map base
