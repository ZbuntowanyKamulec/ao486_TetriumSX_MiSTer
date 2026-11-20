# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Stress kernel entry (loaded at 10000h, entered at 1000:0000 in real mode), descriptor
# tables, interrupt stubs and the switch into / out of the workloads.
.intel_syntax noprefix
.text
.code16
.globl _start
_start:
    cli
    mov  ax, cs
    mov  ds, ax
    mov  ax, 0x0003                     # text mode 3 (clears the screen)
    int  0x10
    mov  ah, 0x01                       # no cursor
    mov  cx, 0x2000
    int  0x10
    in   al, 0x92                       # A20 (fast gate)
    or   al, 2
    and  al, 0xFE
    out  0x92, al
    cli
    lgdt [gdt_desc - _start]
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
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    mov  esp, 0x98000
    cld
    mov  edi, offset __bss_start          # the BIOS leaves garbage there
    mov  ecx, offset __bss_end
    sub  ecx, edi
    xor  eax, eax
    rep  stosb
    call kmain
1:  cli
    hlt
    jmp  1b

# ---------------------------------------------------------------- boot GDT (kmain builds the real one)
# accessed bits preset: loading a selector must not write the image (the IDE check compares
# disk sectors with the copy of the loaded image)
.align 8
.globl gdt
gdt:
    .quad 0
    .quad 0x00CF9B000000FFFF            # 08 kernel code 32
    .quad 0x00CF93000000FFFF            # 10 kernel data 32
    .quad 0x00CFFB000000FFFF            # 18 user code 32 (DPL 3)
    .quad 0x00CFF3000000FFFF            # 20 user data 32 (DPL 3)
    .quad 0                             # 28 TSS
    .quad 0x0040F3100000FFFF            # 30 user data, base 100000, limit FFFF (DPL 3)
gdt_end:
gdt_desc:
    .word gdt_end - gdt - 1
    .long gdt

# ---------------------------------------------------------------- interrupt stubs
# frame (see kernel.c struct frame): gs fs es ds, pushad, vec, err, eip cs eflags [esp ss [v86 es ds fs gs]]
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

# run_frame(struct frame *f): enter a workload through the frame (ISR exit path); returns when
# the kernel calls kexit() (workload done or a stop)
.globl run_frame
run_frame:
    push ebp
    push ebx
    push esi
    push edi
    mov  [kctx_esp], esp
    mov  esp, [esp + 20]
    jmp  isr_return
.globl kexit
kexit:
    mov  esp, [kctx_esp]
    pop  edi
    pop  esi
    pop  ebx
    pop  ebp
    ret
.globl kctx_esp
kctx_esp: .long 0

# ---------------------------------------------------------------- call gate / task targets
TSS1 = 0x3C0000
# call gate (GDT 48h, 2 dword parameters) -> ring 0: EAX = p1 + p2, EDX mixed, RETF 8
.globl gate_fn
gate_fn:
    mov  eax, [esp + 8]
    add  eax, [esp + 12]
    xor  edx, eax
    rol  edx, 7
    retf 8
# task 2 (TSS 40h): mixes the caller's saved EAX / EBX (in TSS 1), writes the sandbox, IRET (NT)
.globl task_fn
task_fn:
    mov  eax, ds:[TSS1 + 0x28]
    mov  ebx, ds:[TSS1 + 0x34]
    imul eax, eax, 0x2C1B3C6D
    add  eax, ebx
    mov  ds:[TSS1 + 0x28], eax
    and  ebx, 0x3FFFC
    xor  ds:[ebx + 0x100000], eax
    iretd
    jmp  task_fn

# ---------------------------------------------------------------- real mode
# run_real(): runs the 16-bit workload in real mode (paging and PE off) from the register block
# at RMB (filled by the kernel); returns after INT 31h (status 1), a hang / fault / bad vector
# (status 2 / 3 / 4) with the block updated.  The stubs below sit in the real-mode IVT.
RMB = 0x700
.globl run_real
run_real:
    push ebp
    push ebx
    push esi
    push edi
    mov  [kctx_esp], esp
    cli
    .byte 0xEA                          # jmp 50h:rr16 (16-bit code, base 10000h)
    .long rr16 - _start
    .word 0x50
.code16
rr16:
    mov  ax, 0x58                       # 16-bit data, limit FFFF: real-mode compatible caches
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    mov  eax, cr0
    and  eax, 0x7FFFFFFE                # PG and PE off
    mov  cr0, eax
    .byte 0xEA
    .word rr_real - _start
    .word 0x1000
rr_real:
    xor  ax, ax
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    xor  esp, esp
    mov  sp, 0x6F0
    lidt cs:[rm_idtr - _start]
    mov  ss, word ptr ds:[RMB + 44]
    mov  esp, ds:[RMB + 16]
    push word ptr ds:[RMB + 32]
    push word ptr ds:[RMB + 40]
    push word ptr ds:[RMB + 36]
    mov  es, word ptr ds:[RMB + 52]
    mov  fs, word ptr ds:[RMB + 56]
    mov  gs, word ptr ds:[RMB + 60]
    mov  eax, ds:[RMB + 0]
    mov  ecx, ds:[RMB + 4]
    mov  edx, ds:[RMB + 8]
    mov  ebx, ds:[RMB + 12]
    mov  ebp, ds:[RMB + 20]
    mov  esi, ds:[RMB + 24]
    mov  edi, ds:[RMB + 28]
    mov  ds, word ptr ds:[RMB + 48]
    iret

.globl rm_exit                          # IVT 31h: the workload's end
rm_exit:
    cli
    push ds
    push 0
    pop  ds
    mov  ds:[RMB + 0], eax
    mov  ds:[RMB + 4], ecx
    mov  ds:[RMB + 8], edx
    mov  ds:[RMB + 12], ebx
    mov  ds:[RMB + 20], ebp
    mov  ds:[RMB + 24], esi
    mov  ds:[RMB + 28], edi
    pop  ax
    mov  ds:[RMB + 48], ax
    mov  ds:[RMB + 52], es
    mov  ds:[RMB + 56], fs
    mov  ds:[RMB + 60], gs
    mov  ds:[RMB + 44], ss
    pop  ax
    mov  ds:[RMB + 36], ax
    pop  ax
    mov  ds:[RMB + 40], ax
    pop  ax
    mov  ds:[RMB + 32], ax
    mov  ds:[RMB + 16], esp
    mov  dword ptr ds:[RMB + 64], 1
rm_back:
    cli
    .byte 0x66
    lgdt cs:[gdtr2 - _start]
    .byte 0x66
    lidt cs:[idtr_pm - _start]
    mov  eax, cr0
    or   eax, 0x80000001
    mov  cr0, eax
    .byte 0x66, 0xEA
    .long rm_pm32
    .word 0x08

.globl rm_irq0                          # IVT 20h (PIC IRQ0): watchdog, next period, chain to IVT 08h
rm_irq0:
    push eax
    push ds
    push 0
    pop  ds
    mov  al, 0x20
    out  0x20, al
    inc  dword ptr ds:[RMB + 80]
    mov  eax, ds:[RMB + 80]
    cmp  eax, ds:[RMB + 104]
    ja   rm_hang
    cmp  dword ptr ds:[RMB + 108], 0
    je   1f
    inc  dword ptr ds:[RMB + 112]
    push edx
    mov  eax, ds:[RMB + 92]
    mov  edx, eax
    shl  edx, 13
    xor  eax, edx
    mov  edx, eax
    shr  edx, 17
    xor  eax, edx
    mov  edx, eax
    shl  edx, 5
    xor  eax, edx
    mov  ds:[RMB + 92], eax
    xor  edx, edx
    div  dword ptr ds:[RMB + 100]
    add  edx, ds:[RMB + 96]
    mov  al, 0x34
    out  0x43, al
    mov  al, dl
    out  0x40, al
    mov  al, dh
    out  0x40, al
    pop  edx
    pop  ds
    pop  eax
    .byte 0x2E, 0xFF, 0x2E              # jmp far cs:[rm_chain0]
    .word rm_chain0 - _start
1:  pop  ds
    pop  eax
    iret
rm_hang:                                # stack: ds, eax, ip, cs, flags
    mov  bp, sp
    mov  ax, [bp + 6]
    mov  ds:[RMB + 68], ax
    mov  ax, [bp + 8]
    mov  ds:[RMB + 72], ax
    mov  dword ptr ds:[RMB + 64], 2
    jmp  rm_back

.globl rm_irq8                          # IVT 28h (IRQ8, RTC): ack, chain to IVT 70h
rm_irq8:
    push ax
    mov  al, 0x0C
    out  0x70, al
    in   al, 0x71
    mov  al, 0x20
    out  0xA0, al
    out  0x20, al
    push ds
    push 0
    pop  ds
    inc  dword ptr ds:[RMB + 112]
    pop  ds
    pop  ax
    .byte 0x2E, 0xFF, 0x2E
    .word rm_chain70 - _start
.globl rm_spur
rm_spur:
    iret
.globl rm_db                            # IVT 01h: single-step count
rm_db:
    push ds
    push 0
    pop  ds
    inc  dword ptr ds:[RMB + 84]
    pop  ds
    iret
.globl rm_f0, rm_f5, rm_f6, rm_f7, rm_f12, rm_f13
rm_f0:  push 0
        jmp  rm_fault
rm_f5:  push 5
        jmp  rm_fault
rm_f6:  push 6
        jmp  rm_fault
rm_f7:  push 7
        jmp  rm_fault
rm_f12: push 12
        jmp  rm_fault
rm_f13: push 13
        jmp  rm_fault
rm_fault:                               # stack: vec, ip, cs, flags; resume from the wl16 table
    push bp
    mov  bp, sp
    push ds
    push si
    push cx
    push ebx
    push 0x2000
    pop  ds
    cmp  word ptr [bp + 6], 0x2000
    jne  3f
    mov  si, ds:[24]
    mov  cx, ds:[26]
    mov  bx, [bp + 4]
2:  jcxz 3f
    cmp  ds:[si], bx
    je   4f
    add  si, 4
    dec  cx
    jmp  2b
4:  mov  bx, ds:[si + 2]
    mov  [bp + 4], bx
    movzx ebx, word ptr [bp + 2]
    inc  ebx
    imul ebx, ebx, 0x9E3779B1
    xor  eax, ebx
    push 0
    pop  ds
    inc  dword ptr ds:[RMB + 88]
    pop  ebx
    pop  cx
    pop  si
    pop  ds
    pop  bp
    add  sp, 2
    iret
3:  push 0
    pop  ds
    mov  bx, [bp + 4]
    mov  ds:[RMB + 68], bx
    mov  bx, [bp + 6]
    mov  ds:[RMB + 72], bx
    mov  bx, [bp + 2]
    mov  ds:[RMB + 76], bx
    mov  dword ptr ds:[RMB + 64], 3
    jmp  rm_back
.globl rm_bad                           # IVT 32h: the code reached an unused vector
rm_bad:
    mov  bp, sp
    push 0
    pop  ds
    mov  ax, [bp]
    mov  ds:[RMB + 68], ax
    mov  ax, [bp + 2]
    mov  ds:[RMB + 72], ax
    mov  dword ptr ds:[RMB + 64], 4
    jmp  rm_back
.code32
rm_pm32:
    mov  ax, 0x10
    mov  ds, ax
    mov  es, ax
    mov  fs, ax
    mov  gs, ax
    mov  ss, ax
    mov  esp, [kctx_esp]
    pop  edi
    pop  esi
    pop  ebx
    pop  ebp
    ret
.align 4
.globl rm_chain0, rm_chain70, gdtr2, idtr_pm
rm_chain0:  .long 0
rm_chain70: .long 0
rm_idtr:    .word 0x3FF
            .long 0
gdtr2:      .word 0
            .long 0
idtr_pm:    .word 0
            .long 0
