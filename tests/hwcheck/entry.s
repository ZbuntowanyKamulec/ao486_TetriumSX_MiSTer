# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# hwcheck kernel entry: loaded at 1000:0000 (MBR: entered at 0, lockstep testbench: at 0100h),
# linked at C0010000.  Enters protected mode, maps the first 4 MB at 0 and at C0000000, jumps high.
.intel_syntax noprefix
.section .entry, "ax"
.code16
KBASE = 0xC0000000
PHYS  = 0x10000
.globl _start
_start:
    jmp  start16
.org 0x100
    jmp  start16
.globl cfg
.org 0x110
cfg:                                    # patched by cfg.py (see kern.h struct cfg)
    .ascii "HWCK"
    .long 1                             # seed
    .long 0xFFFFFFFF                    # suites
    .long 0                             # stop: rounds to run (0 = for ever)
    .long 0                             # tb: 1 = lockstep testbench (no BIOS, no devices)
    .long 0                             # items (0 = random)
    .long 0                             # progs: fuzz programs per round (0 = default)
    .long 0                             # off mask
    .long 0                             # envs: fuzz environments (0 = all)
    .long 0                             # one: run only this case number of the directed suites (0 = all)
.globl memkb
memkb: .long 0
start16:
    cli
    mov  ax, cs
    mov  ds, ax
    xor  bx, bx
    mov  ss, bx
    mov  sp, 0x7C00
    cmp  byte ptr cs:[cfg - _start + 16], 0
    jne  1f
    sti
    mov  ax, 0x0003
    int  0x10
    mov  ah, 0x01
    mov  cx, 0x2000
    int  0x10
    mov  ah, 0x88                       # KB above 1 MB (<= 64 MB)
    int  0x15
    movzx eax, ax
    mov  cs:[memkb - _start], eax
    mov  ax, 0xE801
    xor  cx, cx
    xor  dx, dx
    int  0x15
    jc   2f
    test cx, cx
    jnz  3f
    mov  cx, ax
    mov  dx, bx
3:  movzx ecx, cx
    movzx edx, dx
    shl  edx, 6
    add  ecx, edx
    mov  cs:[memkb - _start], ecx
2:  mov  ax, 0x2401                     # A20: BIOS, keyboard controller, port 92h
    int  0x15
    cli
    call kbcw
    mov  al, 0xD1
    out  0x64, al
    call kbcw
    mov  al, 0xDF
    out  0x60, al
    call kbcw
    in   al, 0x92
    or   al, 2
    and  al, 0xFE
    out  0x92, al
    jmp  1f
kbcw:
    xor  cx, cx
9:  in   al, 0x64
    test al, 2
    loopnz 9b
    ret
1:  cli
    .byte 0x66
    lgdt cs:[boot_gdtr - _start]
    mov  eax, cr0
    or   al, 1
    mov  cr0, eax
    .byte 0x66, 0xEA
    .long pm32 - KBASE
    .word 0x08
.code32
pm32:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    mov  esp, 0x7C00
    cld
    mov  edi, offset __bss_start - KBASE
    mov  ecx, offset __bss_end - KBASE
    sub  ecx, edi
    xor  eax, eax
    rep  stosb
    mov  edi, 0x62000                   # boot page directory 62000, table 63000 (the first 4 MB)
    mov  ecx, 1024
    rep  stosd
    mov  dword ptr ds:[0x62000], 0x63003
    mov  dword ptr ds:[0x62000 + 768 * 4], 0x63003
    mov  eax, 0x003
    mov  ecx, 1024
1:  stosd
    add  eax, 0x1000
    loop 1b
    mov  eax, 0x62000
    mov  cr3, eax
    mov  eax, cr0
    and  eax, 0x9FFAFFFF                # CD NW AM WP off
    or   eax, 0x80000001
    mov  cr0, eax
    mov  eax, offset high32
    jmp  eax
high32:
    mov  esp, offset kstack_top
    call kmain
1:  cli
    hlt
    jmp  1b

.align 8
boot_gdt:
    .quad 0
    .quad 0x00CF9B000000FFFF
    .quad 0x00CF93000000FFFF
boot_gdtr:
    .word 23
    .long boot_gdt - KBASE

.text
# ---------------------------------------------------------------- interrupt stubs
# frame: gs fs es ds, pushad, vec, err, eip cs eflags [esp ss [v86 es ds fs gs]]
.align 16
.globl isr_stubs
isr_stubs:
    .set i, 0
    .rept 256
    .if (i == 8) || ((i >= 10) && (i <= 14)) || (i == 17)
    push i
    .else
    push 0
    push i
    .endif
    jmp  isr_common
    .align 16
    .set i, i + 1
    .endr
isr_common:
    pushad
    push ds
    push es
    push fs
    push gs
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    cld
    push esp
    call isr_dispatch
    add  esp, 4
.globl isr_return
isr_return:
    pop  gs
    pop  fs
    pop  es
    pop  ds
    popad
    add  esp, 8
    iretd

# run_frame(struct frame *f): returns when the kernel calls kexit()
.globl run_frame
run_frame:
    pushfd
    push ebp
    push ebx
    push esi
    push edi
    mov  [kctx_esp], esp
    mov  esp, [esp + 24]
    jmp  isr_return
.globl kexit
kexit:
    mov  esp, [kctx_esp]
    pop  edi
    pop  esi
    pop  ebx
    pop  ebp
    popfd
    ret
# unreal_run(): real mode with 4 GB limits in DS ES FS (16-bit PM, limits loaded, PE and PG off);
# results at UB (physical 700h): [0] the caller's value, [1] status, ...
UB = 0x700
S_C16 = 0x1E0
S_D16 = 0x1E8
S_BIG = 0x1F0
.globl unreal_run
unreal_run:
    pushfd
    push ebp
    push ebx
    push esi
    push edi
    mov  [kctx_esp], esp
    cli
    mov  eax, offset 1f - KBASE         # the identity mapping
    jmp  eax
1:  .byte 0xEA
    .long ur16 - _start
    .word S_C16
.section .entry, "ax"
.code16
ur16:
    mov  ax, S_D16
    mov  gs, ax                         # GS, SS: 64 KB
    mov  ss, ax
    mov  esp, 0x6F0
    mov  ax, S_BIG
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  eax, cr0
    and  eax, 0x7FFFFFFE
    mov  cr0, eax
    .byte 0xEA
    .word ur_real - _start
    .word 0x1000
ur_real:
    lidt cs:[ur_idtr - _start]
    xor  ax, ax
    mov  es, ax
    mov  ss, ax
    mov  fs, ax
    mov  gs, ax
    mov  ds, ax                         # bases 0, the limits stay
    mov  dword ptr ds:[0x60 * 4], (0x1000 << 16) + (ur_int - _start)
    mov  dword ptr ds:[13 * 4], (0x1000 << 16) + (ur_gp - _start)
    mov  ebp, ds:[UB]
    mov  ebx, 0x210000
    mov  eax, fs:[ebx + 0x14]
    mov  ds:[UB + 8], eax
    lea  eax, [ebp + 1]
    mov  es:[ebx + 0x40], eax
    mov  ax, 0x1000                     # another base: the limit stays 4 GB
    mov  ds, ax
    mov  eax, ds:[ebx - 0x10000 + 0x24]
    push ds
    pop  gs
    push 0
    pop  ds
    mov  ds:[UB + 12], eax
    int  0x60
    mov  eax, ds:[ebx + 0x1C]
    mov  ds:[UB + 16], eax
    mov  eax, gs:[ebx]                  # GS: 64 KB
ur_f1e:
    mov  esi, 0x21F800 - 0x20000        # DS base 20000h: crosses offset 200000h
    mov  edi, 0x250000
    mov  ecx, 0x400
    mov  ax, 0x2000
    mov  ds, ax
    push 0
    pop  gs
    cld
    addr32 rep movsd es:[edi], ds:[esi]
    nop
    push 0
    pop  ds
    mov  dword ptr ds:[UB + 28], 0
    sub  esi, 0x1F0700
    mov  ds:[UB + 28], esi
    mov  dword ptr ds:[UB + 4], 0x600D
    .byte 0x66
    lgdt cs:[ur_gdtr - _start]
    .byte 0x66
    lidt cs:[ur_idtrpm - _start]
    mov  eax, cr0
    or   eax, 0x80000001
    mov  cr0, eax
    .byte 0x66, 0xEA
    .long ur_pm32
    .word 0x08
ur_int:                                 # INT 60h
    push ds
    push 0x3000
    pop  ds
    mov  al, ds:[0]
    pop  ds
    iret
ur_gp:                                  # #GP: the access through GS
    push bp
    mov  bp, sp
    mov  word ptr [bp + 2], offset ur_f1e - _start
    pop  bp
    push eax
    mov  eax, 13
    mov  dword ptr ss:[UB + 20], eax
    pop  eax
    iret
ur_idtr:
    .word 0x3FF
    .long 0
.globl ur_gdtr
.globl ur_idtrpm
ur_gdtr: .word 0
    .long 0
ur_idtrpm: .word 0
    .long 0
.code32
.text
ur_pm32:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    jmp  kexit
.globl kctx_esp
.data
kctx_esp: .long 0
.bss
.align 16
kstack: .skip 8192
.globl kstack_top
kstack_top:
istack: .skip 8192
.globl istack_top
istack_top:
