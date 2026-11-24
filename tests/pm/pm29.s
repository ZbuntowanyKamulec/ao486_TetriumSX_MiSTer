# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Ring 3 and V86 (IOPL 0), paging on: privileged instructions (#GP(0), also with a bad memory
# operand), the system instructions allowed there (SGDT / SIDT / SLDT / STR / SMSW: plain,
# beyond the limit, to a supervisor page, to a not-present page), #DE / #BR / #OF, INT3 /
# INT n through DPL 0 gates, CLI / STI / I/O; in V86 also the 0F 00 group and LAR / LSL /
# ARPL (#UD), 64 KB wrap faults (#GP / #SS) and the IOPL-sensitive instructions.  The
# ring 0 handlers log vector, error code, CR2 and EIP and resume after the instruction.
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
# one case: the handler resumes at the next label (ESI)
.macro T insn:vararg
    mov  esi, offset 9f
    \insn
9:
.endm
PT  = 0x21000
LOG = 0x30000
# pages: 40 user, 41 not present, 42 supervisor; everything else user (identity, 512 KB)
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
    mov  dword ptr [0x40000], 0                  # DIV operand
    mov  dword ptr [0x40010], 0                  # BOUND bounds 0 .. 10
    mov  dword ptr [0x40014], 10
    mov  word ptr [0x40018], 0
    mov  word ptr [0x4001A], 10
    mov  eax, 0x20000
    mov  cr3, eax
    mov  eax, cr0
    or   eax, 0x80000000
    mov  cr0, eax
    jmp  2f
2:  mov  ax, 0x30
    ltr  ax
    # to ring 3: SS:ESP 23:3F000, EFLAGS IOPL 0, CS:EIP 1B:r3
    push 0x23
    push 0x3F000
    push 0x0002
    push 0x1B
    push offset r3
    iretd

r3: mov  ax, 0x23
    mov  ds, ax
    mov  es, ax
    mov  ax, 0x2B
    mov  fs, ax
# ---- privileged: #GP(0), before any operand access
    T lgdt [0x40100]
    T lgdt [0x41000]
    T lidt [0x40100]
    T lidt fs:[0xFFE]
    mov  ax, 0x38
    T lldt ax
    T lldt [0x41000]
    mov  ax, 0x30
    T ltr  ax
    T ltr  [0x42000]
    T lmsw ax
    T lmsw [0x41000]
    T clts
    T hlt
    T mov  eax, cr0
    T mov  cr0, eax
    T mov  cr3, eax
    T mov  eax, dr6
    T mov  dr7, eax
    T invlpg [0x40000]
    T invlpg [0x41000]
    T invd
    T wbinvd
    T cli
    T sti
    T in   al, 0x80
    T out  dx, ax
    T insb
    T outsd
# ---- allowed at ring 3
    T sgdt [0x40100]
    T sgdt fs:[0xFFC]
    T sgdt [0x42000]
    T sgdt [0x41000]
    T sgdt [0x40FFE]                    # crossing into the missing page
    T sidt [0x40108]
    T sidt [0x42FFE]
    T sldt [0x40110]
    T sldt [0x42000]
    T str  [0x40112]
    T str  word ptr fs:[0xFFF]
    T smsw [0x40114]
    T smsw word ptr [0x41000]
    T smsw eax
    T sldt eax
    T str  ebx
    mov  ax, 0x10
    T lar  ebx, eax
    T lsl  ebx, word ptr [0x40114]
    T verr word ptr [0x42000]
    T verw word ptr [0x41000]
    T arpl [0x40114], ax
    T arpl [0x42000], ax
    T arpl [0x41000], ax
# ---- #DE / #BR / #OF / INT
    xor  edx, edx
    mov  eax, 1
    xor  ecx, ecx
    T div  ecx
    T div  dword ptr [0x40000]
    T div  byte ptr [0x40000]
    T idiv word ptr [0x40000]
    mov  eax, 0x80000000
    mov  edx, -1
    mov  ecx, -1
    T idiv ecx
    T aam  0
    T div  dword ptr [0x41000]          # (#PF before the divide)
    mov  eax, 20
    T bound eax, [0x40010]
    mov  eax, -1
    T bound eax, [0x40010]
    mov  eax, 5
    T bound eax, [0x40010]
    T bound ax, [0x40018]
    mov  ax, 11
    T bound ax, [0x40018]
    T bound eax, [0x42000]
    mov  al, 0x7F
    add  al, 1                          # OF
    T into
    T int3
    T int  0x40
    T int  0x31                         # (not present: #NP)
# ---- memory forms to the supervisor / missing page
    T btr  dword ptr [0x42000], 3
    T setz byte ptr [0x42000]
    T not  dword ptr [0x41000]
    T xadd [0x42000], eax
    T cmpxchg [0x42000], ecx
    T push dword ptr [0x42000]
    T pop  dword ptr [0x41000]
# ---- to V86 (through the handler: ESI = -2)
    mov  esi, -2
    hlt

.code16
v86:
# ---- 0F 00 group, LAR / LSL / ARPL: #UD
    T sldt ax
    T str  ax
    T lldt ax
    T ltr  ax
    T verr ax
    T verw ax
    T sldt [0x100]
    T verw [0x1000]
    T lar  ax, bx
    T lsl  ax, [0x100]
    T arpl [0x100], ax
    T arpl ax, bx
# ---- 0F 01: SGDT / SIDT / SMSW allowed; LGDT / LIDT / LMSW / INVLPG #GP(0)
    T sgdt [0x100]
    T sidt [0x108]
    T smsw [0x110]
    T smsw ax
    T sgdt [0xFFFC]                     # beyond FFFF
    T sidt [0x1000]                     # page 41
    T smsw [0x2000]                     # supervisor page
    T smsw [0xFFFF]
    T lgdt [0x100]
    T lidt [0x1000]
    T lmsw ax
    T lmsw [0xFFFF]
    T invlpg [0x100]
    T clts
    T invd
    T wbinvd
    T hlt
    T mov  eax, cr0
    T mov  cr2, eax
    T mov  eax, dr7
# ---- IOPL 0: INT n / CLI / STI / PUSHF / POPF / IRET / I/O
    T int  0x21
    T cli
    T sti
    T pushf
    T popf
    T iret
    T in   al, 0x60
    T outsb
# ---- #DE / #BR / #OF, 64 KB wrap
    xor  dx, dx
    mov  ax, 1
    xor  cx, cx
    T div  cx
    T div  byte ptr [0x10]
    mov  ax, 20
    T bound ax, [0x18]
    T bound ax, [0xFFFE]
    mov  al, 0x7F
    add  al, 1
    T into
    T int3
    T mov  ax, [0xFFFF]
    T mov  dword ptr [0xFFFD], 0
    T mov  ax, ss:[0xFFFF]
    mov  sp, 1
    T push ax
    mov  sp, 0xFFF0
    T mov  [0x1FFF], ax                 # page 41
    T mov  [0x2000], ax                 # page 42
    T btr  word ptr [0x2000], 1
    mov  esi, -1
    hlt
.code32

# exception handlers (ring 0): log {vector, error code, CR2, EIP, resume} and resume at ESI;
# ESI -2: enter V86 (IOPL 0, DS / ES 4000, SS 3000), ESI -1: done
e0:  push 0
     push 0
     jmp  hc
e3:  push 0
     push 3
     jmp  hc
e4:  push 0
     push 4
     jmp  hc
e5:  push 0
     push 5
     jmp  hc
e6:  push 0
     push 6
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
     add  ebx, ebx                      # 20 bytes per entry
     mov  eax, [esp+12]
     mov  [LOG + 4 + ebx], eax
     mov  eax, [esp+16]
     mov  [LOG + 8 + ebx], eax
     mov  eax, cr2
     mov  [LOG + 12 + ebx], eax
     mov  eax, [esp+20]
     mov  [LOG + 16 + ebx], eax          # faulting EIP
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
     push 0                             # GS
     push 0                             # FS
     push 0x4000                        # DS
     push 0x4000                        # ES
     push 0x3000                        # SS
     push 0xFFF0                        # SP
     push 0x00020002                    # EFLAGS: VM, IOPL 0
     push 0x1000                        # CS
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
    desc 0x40000, 0x0FFF, 0xF2, 4          # 28 data DPL 3, limit FFF
    desc 0x13500, 0x67, 0x89, 0            # 30 TSS (no I/O map)
    desc 0x13200, 0x0F, 0x82, 0            # 38 LDT
gdt_end:
.org 0x3200
ldt:
    .quad 0
    desc 0x40000, 0xFFFF, 0xF2, 4
.org 0x3280
idt:
    gate e0, 0x08, 0x8E
    .fill 2, 8, 0
    gate e3, 0x08, 0x8E                 # INT3: DPL 0 gate
    gate e4, 0x08, 0xEE                 # INTO: DPL 3 gate
    gate e5, 0x08, 0x8E
    gate e6, 0x08, 0x8E
    .fill 4, 8, 0
    gate e11, 0x08, 0x8E
    gate e12, 0x08, 0x8E
    gate e13, 0x08, 0x8E
    gate e14, 0x08, 0x8E
    .fill 0x31 - 15, 8, 0
    gate e13, 0x08, 0x6E                # 31: not present
    .fill 0x40 - 0x32, 8, 0
    gate e13, 0x08, 0x8E                # 40: DPL 0
idt_end:
.org 0x3500
tss:  .long 0, 0x2F000, 0x10
      .fill 0x66 - 12, 1, 0
      .word 0x200                       # (no I/O permission map)
