# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Rings 1 and 2 (paging on, NMI every 1500 cycles throughout): 32-bit code at ring 1, 16-bit
# code at ring 2.  Privileged instructions (#GP(0)), the system instructions allowed there, far
# CALL / JMP through memory and immediate, RET / RETF imm, IRET at the same level, the one-byte
# register forms, I/O and CLI with IOPL 0, #NM (CR0.TS), #DB (single step, a data breakpoint),
# #DF (#GP through a not-present gate), supervisor and not-present pages, task switches (CALL
# through a task gate from ring 1, JMP from ring 2), RETF to the outer ring 2.  The ring 0
# handlers log vector, error code, CR2 and EIP and resume after the instruction (ESI); the last
# NMI halts in its handler.
# lockenv: LOCKNMI=1500
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
PT  = 0x21000
LOG = 0x30000
VAR = 0x40800                           # STEPS, DBCNT, NCNT, FIN, T2CNT, T2MODE (+0 .. +20)
STEPS = VAR
DBCNT = VAR + 4
NCNT  = VAR + 8
FIN   = VAR + 12
T2CNT = VAR + 16
T2MODE = VAR + 20
G13 = 0x10000 + idt + 13 * 8 + 5       # (gate 13's access byte, linear)
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
    mov  edi, 0x20000
    mov  ecx, 2048
    xor  eax, eax
    cld
    rep  stosd
    mov  dword ptr [0x20000], PT + 7
    mov  edi, PT
    mov  eax, 7
    mov  ecx, 0x80
1:  stosd
    add  eax, 0x1000
    loop 1b
    mov  dword ptr [PT + 0x41 * 4], 0x41006      # not present
    mov  dword ptr [PT + 0x42 * 4], 0x42003      # supervisor
    mov  dword ptr [LOG], 0
    mov  edi, VAR
    mov  ecx, 8
    xor  eax, eax
    rep  stosd
    mov  word ptr [0x40104], 0x21                # a selector (VERR / LAR / ...)
    mov  word ptr [0x40130], offset f2           # 16-bit far pointers (ring 2)
    mov  word ptr [0x40132], 0x2A
    mov  word ptr [0x40134], offset j2
    mov  word ptr [0x40136], 0x2A
    mov  dword ptr [0x40140], offset f1          # 32-bit far pointers (ring 1)
    mov  word ptr [0x40144], 0x19
    mov  dword ptr [0x40148], offset j1
    mov  word ptr [0x4014C], 0x19
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x8000000A                         # PG, TS, MP
    mov  cr0, eax
    jmp  2f
2:  mov  eax, 0x40F00                            # data breakpoint: dword writes at 40F00
    mov  dr0, eax
    mov  eax, 0x000D0003                         # (L0 and G0: L0 cleared by the task switches)
    mov  dr7, eax
    mov  ax, 0x38
    ltr  ax
    push 0x21                                    # to ring 1: SS:ESP 21:2E000, IOPL 0, 19:r1
    push 0x2E000
    push 0x0002
    push 0x19
    push offset r1
    iretd

# ---- 32-bit, ring 1 (DS flat)
r1: mov  ax, 0x21
    mov  ds, ax
    mov  es, ax
    mov  ax, 0x59
    mov  fs, ax
    T lgdt [0x40100]
    T lidt fs:[0xFFE]
    mov  ax, 0x50
    T lldt ax
    T lldt [0x40104]
    mov  ax, 0x40
    T ltr  ax
    T ltr  [0x41000]
    T lmsw ax
    T lmsw [0x40100]
    T clts
    T hlt
    T mov  eax, cr0
    T mov  cr0, eax
    T mov  eax, dr7
    T mov  dr7, eax
    T mov  eax, tr6
    T mov  tr7, eax
    T invd
    T wbinvd
    T invlpg [0x40000]
    T in   al, 0x80
    T cli
    T sldt eax
    T sldt [0x40110]
    T str  eax
    T str  [0x40112]
    T sgdt [0x40118]
    T sidt fs:[0xFFC]
    T smsw [0x41000]
    mov  ax, 0x21
    T verr ax
    T verw ax
    T verr [0x40104]
    T verw [0x42000]
    T lar  ebx, eax
    T lar  ebx, [0x40104]
    T lsl  ecx, eax
    T lsl  ecx, [0x41000]
    T mov  eax, [0x42000]               # (supervisor page: allowed)
    T mov  [0x41004], eax
    T mov  ds, [0x40104]
    T mov  gs, [0x42000]
    T wait                              # #NM (TS, MP)
    T fnop
    T call fword ptr [0x40140]
    T jmp  fword ptr [0x40148]
j1: push 0x11111111
    call 1f
    jmp  2f
1:  ret  4
2:  push 0x22222222
    .byte 0x9A                          # CALL FAR 19:f1i
    .long f1i
    .word 0x19
    pushfd
    push 0x19
    push offset 3f
    iretd                               # (same level)
3:  mov  eax, 1
    mov  ecx, 2
    mov  edx, 3
    mov  ebx, 4
    mov  ebp, 5
    mov  edi, 7
    bswap eax
    bswap esp
    bswap esp
    inc  eax
    dec  ecx
    inc  esp
    dec  esp
    xchg eax, edx
    xchg eax, esp
    xchg eax, esp
    push eax
    pop  ebx
    push esp
    pop  esp
    xor  eax, eax
    cpuid
    # #DB: three single steps, then the data breakpoint
    mov  dword ptr [STEPS], 3
    pushfd
    or   dword ptr [esp], 0x100
    popfd
    nop
    add  eax, ebx
    nop
    mov  dword ptr [STEPS], 1
    mov  dword ptr [0x40F00], 5
    # #DF: gate 13 not present, then a #GP
    and  byte ptr [G13], 0x7F
    T in  al, 0x80
    # task switch: CALL through the task gate (T2MODE 0: back by IRET)
    mov  dword ptr [T2MODE], 0
    .byte 0x9A
    .long 0
    .word 0x48
    .byte 0x9A                          # (CALL to the TSS itself)
    .long 0
    .word 0x40
    # to ring 2 by RETF (outer): SS 32, ESP 2D000, CS 2A
    push 0x32
    push 0x2D000
    push 0x2A
    push offset r2
    retf
f1: retf
f1i: .byte 0xCA, 4, 0                   # RETF 4

# ---- 16-bit, ring 2 (DS 62: base 40000; page 41 at 1000, supervisor 42 at 2000)
.code16
r2: mov  ax, 0x62
    mov  ds, ax
    mov  ax, 0x32
    mov  es, ax
    T lldt ax
    T ltr  [0x104]
    T lmsw [0x100]
    T hlt
    T mov  eax, cr0
    T mov  eax, dr7
    T mov  tr6, eax
    T invd
    T wbinvd
    T in   al, 0x80
    T sldt [0x110]
    T str  [0x112]
    T sgdt [0x118]
    T smsw ax
    mov  ax, 0x21
    T verr [0x104]
    T verw [0x104]
    T lar  bx, [0x104]
    T lsl  cx, [0x104]
    T lar  bx, ax
    T lsl  cx, [0x1000]
    T mov  ax, [0x2000]
    T mov  [0x1000], ax
    T mov  fs, [0x104]
    T wait
    T .byte 0xFF, 0x1E, 0x30, 0x01      # CALL FAR [0130]
    T .byte 0xFF, 0x2E, 0x34, 0x01      # JMP FAR [0134]
j2: push 0x3333
    call 1f
    jmp  2f
1:  ret  2
2:  push 0x4444
    .byte 0x9A                          # CALL FAR 2A:f2i
    .word f2i
    .word 0x2A
    pushf
    push cs
    push offset 3f
    iret
3:  mov  ax, 1
    mov  cx, 2
    mov  dx, 3
    mov  bx, 4
    mov  bp, 5
    mov  di, 7
    mov  sp, 0xD000
    inc  ax
    dec  cx
    inc  sp
    dec  sp
    xchg ax, bx
    xchg ax, sp
    xchg ax, sp
    push ax
    pop  dx
    push sp
    pop  sp
    bswap eax
    xor  eax, eax
    cpuid
    mov  word ptr [STEPS - 0x40000], 2
    pushf
    or   word ptr ss:[esp], 0x100
    popf
    nop
    inc  ax
    mov  word ptr [STEPS - 0x40000], 1
    mov  dword ptr [0xF00], 6
    .byte 0x66, 0xBB                    # MOV EBX, G13
    .long G13
    and  byte ptr es:[ebx], 0x7F
    T in  al, 0x80
    mov  word ptr [T2MODE - 0x40000], 1         # task switch: JMP through the task gate
    .byte 0xEA                          #   (T2MODE 1: back by JMP to the main TSS)
    .word 0
    .word 0x48
    mov  esi, -1
    hlt
f2: retf
f2i: .byte 0xCA, 2, 0                   # RETF 2
.code32

# the second task (ring 0): counts, then back (T2MODE 0: IRET, 1: JMP to TSS 38)
task2:
    inc  dword ptr [T2CNT]
    cmp  dword ptr [T2MODE], 0
    jne  1f
    iretd
    jmp  task2
1:  .byte 0xEA
    .long 0
    .word 0x38
    jmp  task2

# handlers (ring 0)
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
nmi: push eax
    push ds
    mov  ax, 0x10
    mov  ds, ax
    inc  dword ptr [NCNT]
    cmp  dword ptr [FIN], 0
    jne  2f
    pop  ds
    pop  eax
    iretd
2:  mov  eax, [LOG]
    out  0xE9, al                       # (faults, #DBs, tasks: LOCKE9=1 shows them)
    mov  eax, [DBCNT]
    out  0xE9, al
    mov  eax, [T2CNT]
    out  0xE9, al
    hlt                                 # NMI blocked: stays here
e6:  push 0
     push 6
     jmp  hc
e7:  push 0
     push 7
     jmp  hc
e8:  or   byte ptr ss:[G13], 0x80       # #DF: gate 13 present again
     push 8
     jmp  hc
e11: push 11
     jmp  hc
e12: push 12
     jmp  hc
e13: push 13
     jmp  hc
e14: push 14
     jmp  hc
hc:  push ds
     push eax
     push ebx
     mov  ax, 0x10
     mov  ds, ax
     mov  ebx, [LOG]
     lea  ebx, [ebx*4 + ebx]
     add  ebx, ebx
     add  ebx, ebx
     mov  eax, [esp+12]
     mov  [LOG + 4 + ebx], eax
     mov  eax, [esp+16]
     mov  [LOG + 8 + ebx], eax
     mov  eax, cr2
     mov  [LOG + 12 + ebx], eax
     mov  eax, [esp+20]
     mov  [LOG + 16 + ebx], eax
     mov  [LOG + 20 + ebx], esi
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
    desc 0x10000, 0xFFFF, 0xBA, 4          # 18 code32 DPL 1
    desc 0x00000, 0xFFFFF, 0xB2, 0xC       # 20 flat data DPL 1
    desc 0x10000, 0xFFFF, 0xDA, 0          # 28 code16 DPL 2
    desc 0x00000, 0xFFFFF, 0xD2, 0xC       # 30 flat data DPL 2 (B)
    desc 0x13500, 0x67, 0xE9, 0            # 38 TSS (main), DPL 3
    desc 0x13600, 0x67, 0xE9, 0            # 40 TSS (task2), DPL 3
    gate 0, 0x40, 0xE5                     # 48 task gate to 40, DPL 3
    desc 0x13200, 0x0F, 0x82, 0            # 50 LDT
    desc 0x40000, 0x0FFF, 0xB2, 4          # 58 data DPL 1, limit FFF
    desc 0x40000, 0xFFFF, 0xD2, 0          # 60 data DPL 2, base 40000
gdt_end:
.org 0x3200
ldt:
    .quad 0
    desc 0x40000, 0xFFFF, 0xF2, 4
.org 0x3280
idt:
    .fill 1, 8, 0
    gate e1, 0x08, 0x8E
    gate nmi, 0x08, 0x8E
    .fill 3, 8, 0
    gate e6, 0x08, 0x8E
    gate e7, 0x08, 0x8E
    gate e8, 0x08, 0x8E
    .fill 2, 8, 0
    gate e11, 0x08, 0x8E
    gate e12, 0x08, 0x8E
    gate e13, 0x08, 0x8E
    gate e14, 0x08, 0x8E
idt_end:
.org 0x3500
tss:  .long 0, 0x2F000, 0x10, 0x2E000, 0x21, 0x2D000, 0x32, 0x20000
      .fill 0x66 - 32, 1, 0
      .word 0x200                       # (no I/O permission map)
.org 0x3600
tss2: .long 0, 0, 0, 0, 0, 0, 0, 0x20000, task2, 0x0002
      .long 0, 0, 0, 0, 0x2C000, 0, 0, 0
      .long 0x10, 0x08, 0x10, 0x10, 0, 0, 0
      .word 0, 0x200
