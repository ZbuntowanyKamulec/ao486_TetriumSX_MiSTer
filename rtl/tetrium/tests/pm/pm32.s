# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# The forms the coverage runs had not retired in these modes: real mode (the 0F 00 group and
# LAR / LSL #UD, LMSW / INVLPG / JMP FAR through memory, TR moves, SETcc r8, the one-byte
# register forms), 16-bit ring 0 (the system instructions with register and memory operands),
# and with paging on: 32-bit ring 0 and ring 3 (BSWAP, CPUID, INC / DEC r, XCHG eAX, r, MOV
# TRn at ring 3, RETF imm), a 16-bit ring 3 code segment (SLDT / STR / LLDT / LTR / VERR /
# VERW / LAR / LSL / LMSW / SGDT / SIDT / SMSW, CR / DR / TR moves, far CALL / JMP through
# memory, IRET, MOV Sreg, POP r, MOV r, imm, ...) and V86 (IOPL 0: the 0F 00 group and LAR /
# LSL #UD, DR / TR moves #GP, MOV Sreg from memory, POP r, XCHG, BSWAP, CPUID).  The ring 0
# handlers log vector, error code, CR2 and EIP and resume after the instruction (ESI).
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
.code16
.org 0x100
start:
    cli
    xor  ax, ax
    mov  ds, ax
    mov  word ptr [6 * 4], offset ud_rm
    mov  word ptr [6 * 4 + 2], cs
    mov  ax, 0x2000
    mov  ss, ax
    mov  sp, 0xFFF0
    mov  ax, 0x4000
    mov  ds, ax
    mov  word ptr [0x100], 0x10
    mov  word ptr [0x130], offset jrm
    mov  word ptr [0x132], cs
# ---- real mode: the 0F 00 group and LAR / LSL #UD (the IVT handler resumes at SI)
    mov  bx, 0x10
    T sldt ax
    T sldt [0x100]
    T str  ax
    T str  [0x100]
    T lldt ax
    T lldt [0x100]
    T ltr  ax
    T ltr  [0x100]
    T verr ax
    T verr [0x100]
    T verw ax
    T verw [0x100]
    T lar  ax, bx
    T lar  ax, [0x100]
    T lsl  ax, bx
    T lsl  ax, [0x100]
    mov  word ptr [0x102], 0
    lmsw [0x102]                        # (PE stays 0)
    invlpg [0x100]
    .byte 0xFF, 0x2E, 0x30, 0x01        # JMP FAR [0130]
jrm:
    mov  eax, 0x1001                    # TR6 lookup (C = 1): no TLB change
    mov  tr6, eax
    mov  eax, tr7
    seto al
    setno ah
    setb bl
    setae bh
    sete cl
    setne ch
    setbe dl
    seta dh
    sets al
    setns ah
    setp bl
    setnp bh
    setl cl
    setge ch
    setle dl
    setg dh
    call regs16
    lgdt cs:[gdtr]
    lidt cs:[idtr]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    .byte 0xEA                          # JMP 50:p16 (16-bit, ring 0)
    .word p16
    .word 0x50
ud_rm:
    push bp
    mov  bp, sp
    mov  [bp + 2], si
    pop  bp
    iret
# the one-byte register forms, SP included
regs16:
    inc  ax
    inc  cx
    inc  dx
    inc  bx
    inc  sp
    inc  bp
    inc  si
    inc  di
    dec  ax
    dec  cx
    dec  dx
    dec  bx
    dec  sp
    dec  bp
    dec  si
    dec  di
    xchg ax, cx
    xchg ax, dx
    xchg ax, bx
    xchg ax, sp
    xchg ax, sp
    xchg ax, bp
    xchg ax, si
    xchg ax, di
    push ax
    pop  cx
    push ax
    pop  dx
    push ax
    pop  bx
    push sp
    pop  sp
    push ax
    pop  bp
    push ax
    pop  si
    push ax
    pop  di
    push ax
    pop  ax
    mov  ax, 1
    mov  cx, 2
    mov  dx, 3
    mov  bx, 4
    mov  bp, 5
    mov  si, 6
    mov  di, 7
    bswap eax
    bswap esp
    bswap esp
    xor  eax, eax
    cpuid
    ret
# ---- 16-bit protected mode, ring 0 (DS 10 flat: no paging yet)
p16:
    mov  ax, 0x10
    mov  ds, ax
    mov  ss, ax
    mov  esp, 0x2F000
    mov  sp, 0xF000                     # (MOV r16, imm: ESP stays 2F000)
    mov  ebx, 0x40000
    sgdt [ebx]
    sidt [ebx + 8]
    smsw [ebx + 16]
    mov  word ptr [ebx + 18], 0x38       # LDT
    mov  word ptr [ebx + 20], 0x30       # TSS
    mov  word ptr [ebx + 22], 0x23
    lgdt [ebx]
    lidt [ebx + 8]
    lmsw [ebx + 16]
    sldt ax
    sldt [ebx + 24]
    lldt [ebx + 18]
    mov  ax, 0x38
    lldt ax
    str  ax
    str  [ebx + 24]
    ltr  [ebx + 20]
    mov  cx, 0x23
    verr cx
    verw cx
    verr [ebx + 22]
    verw [ebx + 22]
    lar  ax, cx
    lar  ax, [ebx + 22]
    lsl  ax, cx
    lsl  ax, [ebx + 22]
    mov  eax, dr7
    mov  dr7, eax
    mov  eax, 0x1001
    mov  tr6, eax
    mov  eax, tr7
    invd
    call regs16
    .byte 0x66, 0xEA                    # JMP 08:pm32
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
    mov  word ptr [0x40104], 0x23                # a selector (VERR / LAR / ...)
    mov  word ptr [0x40130], offset f16          # far pointers into the 16-bit ring 3 code
    mov  word ptr [0x40132], 0x43
    mov  word ptr [0x40134], offset j16
    mov  word ptr [0x40136], 0x43
    mov  word ptr [0x40140], 0x4B
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  2f
# ---- 32-bit, ring 0
2:  mov  eax, 0x11223344
    mov  ecx, eax
    mov  edx, eax
    mov  ebx, eax
    mov  ebp, eax
    mov  esi, eax
    mov  edi, eax
    bswap eax
    bswap ecx
    bswap edx
    bswap ebx
    bswap esp
    bswap esp
    bswap ebp
    bswap esi
    bswap edi
    xor  eax, eax
    cpuid
    mov  eax, 1
    cpuid
    inc  eax
    inc  ecx
    inc  edx
    inc  ebx
    inc  esp
    inc  ebp
    inc  esi
    inc  edi
    dec  eax
    dec  ecx
    dec  edx
    dec  ebx
    dec  esp
    dec  ebp
    dec  esi
    dec  edi
    xchg eax, ecx
    xchg eax, edx
    xchg eax, ebx
    xchg eax, esp
    xchg eax, esp
    xchg eax, ebp
    xchg eax, esi
    xchg eax, edi
    push 0x23                           # to ring 3 (TR loaded in the 16-bit part): SS:ESP 23:3F000, IOPL 0, 1B:r3
    push 0x3F000
    push 0x0002
    push 0x1B
    push offset r3
    iretd

# ---- 32-bit, ring 3
r3: mov  ax, 0x23
    mov  ds, ax
    mov  es, ax
    bswap eax
    bswap esp
    bswap esp
    xor  eax, eax
    cpuid
    inc  eax
    inc  esp
    dec  esp
    xchg eax, ebx
    T mov  eax, tr6
    T mov  tr7, eax
    T mov  eax, tr3
    T mov  tr4, eax
    sub  esp, 8                         # RETF 8 (same level): pops EIP, CS, then 8 bytes
    push 0x1B
    push offset 1f
    .byte 0xCA, 8, 0
1:  .byte 0xEA                          # JMP 43:r16 (16-bit ring 3 code)
    .long r16
    .word 0x43

# ---- 16-bit, ring 3 (DS 4B: base 40000, page 41 at 1000, 42 at 2000)
.code16
r16:
    mov  ax, 0x4B
    mov  ds, ax
    T sldt ax
    T sldt [0x100]
    T str  ax
    T str  [0x102]
    T lldt ax
    T lldt [0x100]
    T ltr  ax
    T ltr  [0x102]
    mov  ax, 0x23
    mov  bx, ax
    T verr ax
    T verw bx
    T verr [0x104]
    T verw [0x104]
    T verr [0x1000]
    T lar  ax, bx
    T lar  cx, [0x104]
    T lsl  dx, bx
    T lsl  dx, [0x104]
    T lsl  dx, [0x2000]
    T lmsw ax
    T lmsw [0x100]
    T sgdt [0x110]
    T sidt [0x118]
    T smsw [0x120]
    T smsw ax
    T mov  eax, cr0
    T mov  cr3, eax
    T mov  eax, dr7
    T mov  dr0, eax
    T mov  eax, tr6
    T mov  tr7, eax
    T .byte 0xFF, 0x1E, 0x30, 0x01       # CALL FAR [0130]
    T .byte 0xFF, 0x2E, 0x34, 0x01       # JMP FAR [0134]
j16:
    pushf
    push cs
    push offset 1f
    iret                                # (same level)
1:  mov  ax, 1
    mov  cx, 2
    mov  dx, 3
    mov  bx, 4
    mov  bp, 5
    mov  si, 6
    mov  di, 7
    mov  sp, 0xF000
    xchg ax, cx
    xchg ax, dx
    xchg ax, bx
    xchg ax, sp
    xchg ax, sp
    xchg ax, bp
    xchg ax, si
    xchg ax, di
    inc  ax
    inc  sp
    dec  sp
    dec  bx
    cpuid
    bswap ecx
    mov  ax, 0x4B
    mov  es, ax
    T mov  es, [0x140]
    T mov  fs, [0x1000]
    T mov  gs, [0x2000]
    push ax
    pop  cx
    push ax
    pop  di
    T les  bx, [0x130]
    T lds  bx, [0x2000]
    bswap esp
    bswap esp
    mov  esi, -2                        # to V86 (through the handler)
    hlt
f16:
    retf

# ---- V86 (IOPL 0, DS / ES 4000)
v86:
    T bswap eax
    T cpuid
    T lar  ax, [0x100]
    T lsl  ax, bx
    T lldt [0x100]
    T ltr  [0x100]
    T str  [0x100]
    T verr [0x100]
    T mov  dr7, eax
    T mov  eax, dr6
    T mov  tr6, eax
    T mov  eax, tr7
    mov  word ptr [0x10], 0x5000
    T mov  es, [0x10]
    T mov  fs, [0x1000]
    T mov  gs, [0x2000]
    push ax
    pop  cx
    push dx
    pop  bp
    xchg ax, cx
    xchg ax, di
    inc  si
    dec  di
    bswap esp
    bswap esp
    xchg ax, sp
    xchg ax, sp
    push sp
    pop  sp
    mov  esi, -1
    hlt
.code32

# exception handlers (ring 0): log {vector, error code, CR2, EIP, resume} and resume at ESI;
# ESI -2: enter V86 (IOPL 0, DS / ES 4000, SS 3000), ESI -1: done
e6:  push 0
     push 6
     jmp  hc
e11: push 11
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
     cmp  esi, -2
     je   tov86
     mov  [esp+20], esi
     pop  ebx
     pop  eax
     pop  ds
     add  esp, 8
     iretd
tov86:
     mov  esp, 0x2F000
     push 0
     push 0
     push 0x4000
     push 0x4000
     push 0x3000
     push 0xFFF0
     push 0x00020002
     push 0x1000
     push offset v86
     iretd
fin: mov  eax, [LOG]
     out  0xE9, al                      # (the number of faults: LOCKE9=1 shows it)
     hlt

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
    desc 0x10000, 0xFFFF, 0xFA, 4          # 18 code32 DPL 3
    desc 0x00000, 0xFFFFF, 0xF2, 0xC       # 20 flat data DPL 3
    .quad 0                                # 28
    desc 0x13500, 0x67, 0x89, 0            # 30 TSS
    desc 0x13200, 0x0F, 0x82, 0            # 38 LDT
    desc 0x10000, 0xFFFF, 0xFA, 0          # 40 code16 DPL 3
    desc 0x40000, 0xFFFF, 0xF2, 0          # 48 data DPL 3, base 40000
    desc 0x10000, 0xFFFF, 0x9A, 0          # 50 code16
gdt_end:
.org 0x3200
ldt:
    .quad 0
    desc 0x40000, 0xFFFF, 0xF2, 4
.org 0x3280
idt:
    .fill 6, 8, 0
    gate e6, 0x08, 0x8E
    .fill 4, 8, 0
    gate e11, 0x08, 0x8E
    .fill 1, 8, 0
    gate e13, 0x08, 0x8E
    gate e14, 0x08, 0x8E
idt_end:
.org 0x3500
tss:  .long 0, 0x2F000, 0x10
      .fill 0x66 - 12, 1, 0
      .word 0x200
