#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""i486 clock-parity test for Tetrium.

Every instruction form (P rows) must take no more cycles than the i486 needs for
it (Intel i486 Microprocessor data sheet 240440-002, Table 10.1, cache-hit column,
real mode; where the table gives a range the minimum is used).  Excluded by the
requirement and only listed for information (I rows): branches / transfers and
I/O.  Measured in a warmed-up straight-line loop with no interlocks: a body
repeated N and 2N times inside an outer loop, cycles per body =
(T(2N) - T(N)) / N with T(n) = (C(n, 2K) - C(n, K)) / K the cost of one warm outer
iteration (K, 2K outer iterations), which cancels loop overhead and cold misses.
Strings: cycles per element from two repeat counts, the same way.  Read-modify-write
forms alternate between two addresses (a body of two instructions, divided by 2): on one
address each would wait for the previous one's store (forwarded one cycle late).

Output: one line per violating form, then a single summary line.
usage: tests/clocks.py [-v] [-l LAT] [filter]
"""
import concurrent.futures, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM = os.environ.get('SIM', os.path.join(ROOT, 'build', 'sim', 'Vtetrium_core'))
K, N = 8, 128

SETUP = """
    mov eax, 0x1234
    mov ebx, 0x8000
    mov ecx, 0x0003
    mov edx, 0x0000
    mov esi, 0x8100
    mov edi, 0x9000
    mov esp, 0xF000
    mov ebp, 0xE000
    mov dword ptr [0x8000], 0x8200
    mov dword ptr [0x8004], 0x1000
"""

# (kind, name, i486 clocks of the body, extra setup, body)
#   kind P: parity-checked, I: information only
CASES = [
 # ---- moves
 ('P', 'mov r16, r16',              1, '', 'mov cx, dx'),
 ('P', 'mov r32, r32 (66)',         2, '', 'mov ecx, edx'),
 ('P', 'mov r16, [m]',              1, '', 'mov cx, [bx]'),
 ('P', 'mov [m], r16',              1, '', 'mov [bx], cx'),
 ('P', 'mov r16, imm',              1, '', 'mov cx, 0x1234'),
 ('P', 'mov [m], imm16',            1, '', 'mov word ptr [bx], 0x55'),
 ('P', 'mov ax, [moffs]',           1, '', 'mov ax, [0x8004]'),
 ('P', 'mov r16, [m] (67, SIB)',    2, '', 'mov cx, [ebx+esi*2-0x10100]'),
 ('P', 'mov r16, es:[m] (prefix)',  2, '', 'mov cx, es:[bx]'),
 ('P', 'movzx r32, r8 (66)',        4, '', 'movzx ecx, dl'),
 ('P', 'movsx r16, [m]',            3, '', 'movsx cx, byte ptr [bx]'),
 ('P', 'xchg r16, r16',             3, '', 'xchg cx, dx'),
 ('P', 'xchg ax, r16',              3, '', 'xchg ax, dx'),
 ('P', 'xchg [m], r16',             5, '', 'xchg [bx], cx\n xchg [bx+4], cx', 0, 2),
 ('P', 'lea r16, [bx+d8]',          1, '', 'lea cx, [bx+4]'),
 ('P', 'lea r16, [bx+si+d8]',       2, '', 'lea cx, [bx+si+4]'),
 ('P', 'nop',                       1, '', 'nop'),
 # ---- stack (pairs keep SP balanced)
 ('P', 'push r16 x4 + add sp + nop', 6, '', 'push cx\n push dx\n push si\n push di\n add sp, 8\n nop'),
 ('P', 'sub sp + nop + pop r16 x4', 6, '', 'sub sp, 8\n nop\n pop cx\n pop dx\n pop si\n pop di'),
 ('P', 'push r32 x2 + add sp + nop (66)', 7, '', 'push ecx\n push edx\n add sp, 8\n nop'),
 ('I', 'stores to 4 addresses',     4, '', 'mov [bx], cx\n mov [bx+2], cx\n mov [bx+4], cx\n mov [bx+6], cx'),
 ('P', 'push [m] + pop [m]',        9, '', 'push word ptr [bx]\n pop word ptr [bx+2]'),
 ('P', 'push imm x2 + add sp + nop', 4, '', 'push 0x1234\n push 0x55\n add sp, 4\n nop'),
 ('P', 'pusha + popa',             20, '', 'pusha\n popa'),
 ('P', 'push ds + pop es',          6, '', 'push ds\n pop es'),
 ('P', 'push fs + pop gs',          6, '', 'push fs\n pop gs'),
 ('P', 'pushf + popf',             13, '', 'pushf\n popf'),
 ('P', 'enter 8, 0 + leave',       19, '', 'enter 8, 0\n leave'),
 ('P', 'enter 8, 1 + leave',       22, '', 'enter 8, 1\n leave'),
 ('P', 'enter 8, 3 + leave',       31, '', 'enter 8, 3\n leave'),
 # ---- ALU
 ('P', 'add r16, r16',              1, '', 'add cx, dx'),
 ('P', 'add r32, r32 (66)',         2, '', 'add ecx, edx'),
 ('P', 'add r16, [m]',              2, '', 'add cx, [bx]'),
 ('P', 'add [m], r16',              3, '', 'add [bx], cx\n add [bx+4], cx', 0, 2),
 ('P', 'add r16, imm',              1, '', 'add cx, 5'),
 ('P', 'add [m], imm',              3, '', 'add word ptr [bx], 5\n add word ptr [bx+4], 5', 0, 2),
 ('P', 'adc r8, r8',                1, '', 'adc cl, dl'),
 ('P', 'inc r16',                   1, '', 'inc cx'),
 ('P', 'inc [m]',                   3, '', 'inc word ptr [bx]\n inc word ptr [bx+4]', 0, 2),
 ('P', 'neg r16',                   1, '', 'neg cx'),
 ('P', 'not [m]',                   3, '', 'not word ptr [bx]\n not word ptr [bx+4]', 0, 2),
 ('P', 'cmp r16, [m]',              2, '', 'cmp cx, [bx]'),
 ('P', 'cmp [m], imm',              2, '', 'cmp word ptr [bx], 5'),
 ('P', 'test r16, r16',             1, '', 'test cx, dx'),
 ('P', 'test [m], r16',             2, '', 'test [bx], cx'),
 ('P', 'lock add [m], r16',         4, '', 'lock add [bx], cx\n lock add [bx+4], cx', 0, 2),
 # ---- multiply / divide
 ('P', 'mul r8',                   13, 'mov dl, 3', 'mul dl'),
 ('P', 'mul r16',                  13, 'mov si, 3', 'mul si'),
 ('P', 'mul r32 (66)',             14, 'mov esi, 3', 'mul esi'),
 ('P', 'imul r16, [m]',            13, '', 'imul cx, [bx]'),
 ('P', 'imul r16, r16, imm8',      13, '', 'imul cx, dx, 7'),
 ('P', 'imul r32, r32 (66)',       14, '', 'imul ecx, edx'),
 ('P', 'div r8',                   16, 'mov ax, 100\n mov dh, 7', 'div dh'),
 ('P', 'div r16',                  24, 'mov si, 7', 'div si'),
 ('P', 'div r32 (66)',             41, 'mov esi, 7\n xor edx, edx', 'div esi'),
 ('P', 'idiv r16 + xor dx',        28, 'mov si, 7', 'idiv si\n xor dx, dx'),
 ('P', 'idiv r32 + xor edx (66)',  46, 'mov esi, 7\n xor edx, edx', 'idiv esi\n xor edx, edx'),
 ('P', 'div word [m]',             24, 'mov word ptr [0x8010], 9', 'div word ptr [0x8010]'),
 # ---- conversions, flags, BCD
 ('P', 'cbw',                       3, '', 'cbw'),
 ('P', 'cwd',                       3, '', 'cwd'),
 ('P', 'cwde (66)',                 4, '', 'cwde'),
 ('P', 'cdq (66)',                  4, '', 'cdq'),
 ('P', 'clc / stc / cmc',           6, '', 'clc\n stc\n cmc'),
 ('P', 'cld / std',                 4, '', 'cld\n std'),
 ('P', 'cli / sti',                10, '', 'cli\n sti'),
 ('P', 'lahf / sahf',               5, '', 'lahf\n sahf'),
 ('P', 'daa',                       2, '', 'daa'),
 ('P', 'das',                       2, '', 'das'),
 ('P', 'aaa',                       3, '', 'aaa'),
 ('P', 'aas',                       3, '', 'aas'),
 ('P', 'aam',                      15, '', 'aam'),
 ('P', 'aad',                      14, '', 'aad'),
 ('P', 'xlat + 3 nop (AL ready)',   7, 'mov al, 0', 'xlat\n nop\n nop\n nop'),
 ('P', 'bound r16, [m] (in range)', 7, 'mov word ptr [0x8020], 0\n mov word ptr [0x8022], 0x7FFF\n mov cx, 5',
                                          'bound cx, [0x8020]'),
 # ---- shifts / rotates
 ('P', 'shl r16, 1',                3, '', 'shl dx, 1'),
 ('P', 'shl [m], 1',                4, '', 'shl word ptr [bx], 1\n shl word ptr [bx+4], 1', 0, 2),
 ('P', 'shl r16, imm8',             2, '', 'shl dx, 3'),
 ('P', 'sar [m], imm8',             4, '', 'sar word ptr [bx], 3\n sar word ptr [bx+4], 3', 0, 2),
 ('P', 'rol r16, cl',               3, '', 'rol dx, cl'),
 ('P', 'shr [m], cl',               4, '', 'shr word ptr [bx], cl\n shr word ptr [bx+4], cl', 0, 2),
 ('P', 'rcl r16, 1',                3, '', 'rcl dx, 1'),
 ('P', 'rcr r16, cl',               8, '', 'rcr dx, cl'),
 ('P', 'rcl r16, imm8',             8, '', 'rcl dx, 5'),
 ('P', 'shld r16, r16, imm8',       2, '', 'shld dx, si, 3'),
 ('P', 'shrd [m], r16, imm8',       3, '', 'shrd [bx], si, 3\n shrd [bx+4], si, 3', 0, 2),
 ('P', 'shld r16, r16, cl',         3, '', 'shld dx, si, cl'),
 ('P', 'shrd [m], r16, cl',         4, '', 'shrd [bx], si, cl\n shrd [bx+4], si, cl', 0, 2),
 # ---- 386 / 486 additions
 ('P', 'setz r8 (false)',           3, '', 'setz cl'),
 ('P', 'setnz [m] (true)',          3, '', 'setnz byte ptr [bx]'),
 ('P', 'bt r16, imm8',              3, '', 'bt dx, 3'),
 ('P', 'bt r16, r16',               3, '', 'bt dx, cx'),
 ('P', 'bt [m], imm8',              3, '', 'bt word ptr [bx], 3'),
 ('P', 'bt [m], r16',               8, '', 'bt [bx], cx'),
 ('P', 'bts r16, imm8',             6, '', 'bts dx, 3'),
 ('P', 'btr [m], imm8',             8, '', 'btr word ptr [bx], 3\n btr word ptr [bx+4], 3', 0, 2),
 ('P', 'btc [m], r16',             13, '', 'btc [bx], cx\n btc [bx+4], cx', 0, 2),
 ('P', 'bsf r16, r16 (zero src)',   6, 'xor si, si', 'bsf dx, si'),
 ('P', 'bsr r16, r16 (bit 15)',     7, 'mov si, 0x8000', 'bsr dx, si'),
 ('P', 'bswap r32 (66)',            2, '', 'bswap ecx'),
 ('P', 'smsw r16',                  2, '', 'smsw cx'),
 ('P', 'mov r32, cr0',              4, '', 'mov ecx, cr0'),
 ('P', 'mov r32, dr7',              9, '', 'mov ecx, dr7'),
 ('P', 'mov r32, dr0',              9, '', 'mov ecx, dr0'),
 ('P', 'mov dr1, r32',             10, '', 'mov dr1, ecx'),
 ('P', 'mov dr7, r32',             10, 'xor ecx, ecx', 'mov dr7, ecx'),
 ('P', 'cpuid (leaf 0/1)',          9, '', 'cpuid'),
 ('P', 'sgdt m',                   10, 'mov bx, 0x8000', 'sgdt [bx]'),
 ('P', 'xadd r16, r16',             3, '', 'xadd cx, dx'),
 ('P', 'xadd [m], r16',             4, '', 'xadd [bx], cx\n xadd [bx+4], cx', 0, 2),
 ('P', 'cmpxchg r16, r16',          6, '', 'cmpxchg cx, dx'),
 ('P', 'cmpxchg [m], r16',          7, '', 'cmpxchg [bx], cx\n cmpxchg [bx+4], cx', 0, 2),
 # ---- segment registers
 ('P', 'mov ds, r16',               3, 'mov ax, ds', 'mov ds, ax'),
 ('P', 'mov es, [m]',               3, 'mov word ptr [0x8030], 0x1000', 'mov es, [0x8030]'),
 ('P', 'mov r16, ds',               3, '', 'mov cx, ds'),
 ('P', 'mov [m], ds',               3, '', 'mov [bx], ds'),
 ('P', 'les r16, [m]',              6, 'mov word ptr [0x8002], 0x1000', 'les cx, [bx]'),
 ('P', 'lfs r16, [m]',              6, 'mov word ptr [0x8002], 0x1000', 'lfs cx, [bx]'),
 ('P', 'lss r16, [m]',              6, 'mov word ptr [0x8040], 0xF000\n mov word ptr [0x8042], 0x1000',
                                          'lss sp, [0x8040]'),
 # ---- information: transfers, I/O
 ('I', 'jmp short',                 3, '', 'jmp 1f\n .fill 6, 1, 0x90\n1:'),
 ('I', 'cmp + jz taken',            4, '', 'cmp ax, ax\n jz 1f\n .fill 4, 1, 0x90\n1:'),
 ('I', 'cmp + jnz not taken',       2, '', 'cmp ax, ax\n jnz 1f\n1:'),
 ('I', 'cmp + jcc rel16 taken',     4, '', 'cmp ax, ax\n .byte 0x0F, 0x84\n .word 4\n .fill 4, 1, 0x90'),
 ('I', 'call near + ret',           8, '', 'call fnr\n .fill 5, 1, 0x90', 5),
 ('I', 'call far + retf',          31, '', 'call 0x1000:fnf\n .fill 3, 1, 0x90', 3),
 ('I', 'jmp far',                  17, '', 'jmp 0x1000:1f\n1:'),
 ('I', 'call far + retf, other CS', 31, '', 'call 0x0FFF:fnf + 0x10\n .fill 3, 1, 0x90', 3),
 ('I', 'jmp far x2, CS changes',    34, '', 'jmp 0x0FFF:1f + 0x10\n1: jmp 0x1000:2f\n2:'),
 ('I', 'loop taken',                7, 'mov cx, 0xFFFF', 'loop 1f\n .fill 6, 1, 0x90\n1:'),
 ('I', 'int n + iret',             45, 'xor dx, dx\n mov es, dx\n mov word ptr es:[0x0200], offset irh\n mov word ptr es:[0x0202], cs',
                                          'int 0x80'),
 ('I', 'mov r32, [m] aligned (66)', 2, 'mov bx, 0x8000', 'mov ecx, [bx]'),
 ('I', 'mov r32, [m] misaligned',   2, 'mov bx, 0x8001', 'mov ecx, [bx]'),
 ('I', 'mov r16, [m] line-crossing', 1, 'mov bx, 0x800F', 'mov cx, [bx]'),
 ('I', 'mov r32, [m] line-crossing', 2, 'mov bx, 0x800E', 'mov ecx, [bx]'),
 ('I', 'mov [m], r32 line-crossing', 2, 'mov bx, 0x800E', 'mov [bx], ecx'),
 ('I', 'in al, imm8',              14, '', 'in al, 0x80'),
 ('I', 'out imm8, al',             16, '', 'out 0x80, al'),
]

# protected mode (16-bit code, CPL 0; descriptors already accessed): i486 protected-mode
# clocks of Table 10.1.  GDT: 08 code (base 10000), 10 data (base 10000), 18 data DPL 3
# (VERR / LAR targets), 20 call gate -> 08:fng, 28 LDT, 30 TSS (available), 38 TSS (busy)
PMCASES = [
 ('P', 'pm mov ds, r16',            9, 'mov ax, 0x10', 'mov ds, ax'),
 ('P', 'pm mov es, [m]',            9, 'mov word ptr [0x8030], 0x10', 'mov es, [0x8030]'),
 ('P', 'pm push ds + pop es',      12, '', 'push ds\n pop es'),
 ('P', 'pm les r16, [m]',          12, 'mov word ptr [0x8002], 0x10', 'les cx, [bx]'),
 ('P', 'pm lss r16, [m]',          12, 'mov word ptr [0x8040], 0xF000\n mov word ptr [0x8042], 0x10',
                                          'lss sp, [0x8040]'),
 ('P', 'pm mov ds, r16 (null)',     9, 'xor ax, ax', 'mov es, ax'),
 ('P', 'pm lldt r16',              11, 'mov ax, 0x28', 'lldt ax'),
 ('P', 'pm sldt r16',               2, '', 'sldt cx'),
 ('P', 'pm str r16',                2, '', 'str cx'),
 ('P', 'pm lar r16, r16',          11, 'mov ax, 0x18', 'lar cx, ax'),
 ('P', 'pm lsl r16, r16',          10, 'mov ax, 0x18', 'lsl cx, ax'),
 ('P', 'pm verr r16',              11, 'mov ax, 0x18', 'verr ax'),
 ('P', 'pm verw r16',              11, 'mov ax, 0x18', 'verw ax'),
 ('P', 'pm arpl r16, r16',          9, 'mov dx, 3', 'mov cx, 0x10\n arpl cx, dx', 1),
 ('P', 'pm cli + sti',             10, '', 'cli\n sti'),
 ('P', 'pm pushf + popf',          13, '', 'pushf\n popf'),
 ('I', 'pm jmp far',               19, '', 'jmp 0x08:1f\n1:'),
 ('I', 'pm call far + retf',       38, '', 'call 0x08:fnf\n .fill 3, 1, 0x90', 3),
 ('I', 'pm call gate + retf',      53, '', 'call 0x20:0\n .fill 3, 1, 0x90', 3),
 ('I', 'pm int n + iret',          59, '', 'int 0x80'),
]

# per element: (kind, name, i486 clocks per element, setup, instruction)
STRINGS = [
 ('P', 'rep movsw',   3, 'mov si, 0x8000\n mov di, 0xA000', 'rep movsw'),
 ('P', 'rep stosw',   4, 'mov di, 0xA000', 'rep stosw'),
 ('P', 'rep lodsw',   4, 'mov si, 0x8000', 'rep lodsw'),
 ('P', 'repe cmpsb',  7, 'mov si, 0x8000\n mov di, 0x8000', 'repe cmpsb'),
 ('P', 'repne scasb', 5, 'mov di, 0xA000\n mov al, 0x5A', 'repne scasb'),
]


PMPRO = """
    cli
    lgdt [0xC080]
    lidt [0xC088]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp 0x08:pm16
pm16:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov ax, 0x30
    ltr ax
"""
PMTAB = """
    .org 0xC000
    .quad 0
    .word 0xFFFF, 0, 0x9B01, 0           # 08 code16, base 10000
    .word 0xFFFF, 0, 0x9301, 0           # 10 data16, base 10000
    .word 0xFFFF, 0, 0xF301, 0           # 18 data16 DPL 3
    .word fng, 0x08, 0x8400, 0           # 20 call gate
    .word 0x0007, 0xC100, 0x8201, 0      # 28 LDT at 1C100
    .word 0x0067, 0xC200, 0x8901, 0      # 30 TSS at 1C200
    .org 0xC080
    .word 0x37
    .long 0x1C000
    .org 0xC088
    .word 0x80 * 8 + 7
    .long 0x1C800
    .org 0xCC00
    .word irh, 0x08, 0x8600, 0           # IDT 80 (IDT base 1C800)
    .org 0xCC10
"""


def prog(setup, body, n, k=K, pm=False):
    return f""".intel_syntax noprefix
.code16
.org 0x100
start:
{PMPRO if pm else ''}
{SETUP}
    {setup}
    mov word ptr [0x7FF0], {k}
outer:
    .balign 8, 0x90
.rept {n}
    {body}
.endr
    dec word ptr [0x7FF0]
    jz done
    jmp outer
done:
    hlt
irh:
    iret
    .balign 8, 0x90
fnr:
    ret
    .balign 8, 0x90
fnf:
    retf
    .balign 8, 0x90
fng:
    retf
{PMTAB if pm else ''}
"""


def sprog(setup, ins, cnt, k=K):
    return f""".intel_syntax noprefix
.code16
.org 0x100
start:
{SETUP}
    mov word ptr [0x7FF0], {k}
outer:
    {setup}
    mov cx, {cnt}
    {ins}
    dec word ptr [0x7FF0]
    jnz outer
    hlt
"""


def asm(src, path):
    open(path + '.s', 'w').write(src)
    r = subprocess.run(['as', '--32', '-o', path + '.o', path + '.s'], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr)
    subprocess.run(['objcopy', '-O', 'binary', path + '.o', path + '.com'], check=True)
    return path + '.com'


def main():
    args = sys.argv[1:]
    verbose, lat = False, 1
    while args and args[0].startswith('-'):
        if args[0] == '-v':
            verbose = True; args = args[1:]
        elif args[0] == '-l':
            lat = int(args[1]); args = args[2:]
    flt = args[0] if args else ''
    tmp = tempfile.mkdtemp(prefix='clk486_')
    jobs = []        # (kind, name, i486 clocks, files, repeat count, padding, instructions per body)
    for i, c in enumerate(CASES):
        kind, name, clk, setup, body = c[:5]
        pad = c[5] if len(c) > 5 else 0          # NOP bytes / extra instructions inside the body
        div = c[6] if len(c) > 6 else 1          # copies of the instruction in the body
        if flt and flt not in name:
            continue
        fs = [asm(prog(setup, body, n, k), os.path.join(tmp, f'c{i}_{n}_{k}'))
              for n in (N, 2 * N) for k in (K, 2 * K)]
        jobs.append((kind, name, clk, fs, N, pad, div))
    for i, c in enumerate(PMCASES):
        kind, name, clk, setup, body = c[:5]
        pad = c[5] if len(c) > 5 else 0
        if flt and flt not in name:
            continue
        fs = [asm(prog(setup, body, n, k, pm=True), os.path.join(tmp, f'p{i}_{n}_{k}'))
              for n in (32, 64) for k in (K, 2 * K)]
        jobs.append((kind, name, clk, fs, 32, pad, 1))
    for i, (kind, name, clk, setup, ins) in enumerate(STRINGS):
        if flt and flt not in name:
            continue
        fs = [asm(sprog(setup, ins, n, k), os.path.join(tmp, f's{i}_{n}_{k}'))
              for n in (16, 32) for k in (K, 2 * K)]
        jobs.append((kind, name, clk, fs, 16, 0, 1))
    files = [f for j in jobs for f in j[3]]

    # one simulator process per program: predictor / BTB state must not carry over
    def run1(f):
        out = subprocess.run([SIM, '-b', '-nocheck', '-l', str(lat), f], capture_output=True, text=True,
                             timeout=60).stdout
        m = re.search(r'^(\S+)\s+insns=(\d+)\s+cycles=(\d+)(.*)$', out, re.M)
        if not m or 'TIMEOUT' in m.group(4):
            raise RuntimeError(f + ': ' + out)
        return os.path.basename(f), int(m.group(3))
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count() or 8) as ex:
        cyc = dict(ex.map(run1, files))
    bad, info = [], []
    for kind, name, clk, fs, n, pad, div in jobs:
        cy = [cyc[os.path.basename(f)] for f in fs]          # (n, K) (n, 2K) (2n, K) (2n, 2K)
        t1, t2 = (cy[1] - cy[0]) / K, (cy[3] - cy[2]) / K
        c = ((t2 - t1) / n - pad) / div
        line = f'{name:28s} tetrium {c:6.2f}  i486 {clk:3d}'
        if kind == 'I':
            info.append(line)
        elif c > clk + 0.05:
            bad.append(line + '  VIOLATION')
        elif verbose:
            print(line)
    for l in bad:
        print(l)
    if verbose:
        print('-- information (branches / transfers / I/O are not part of the requirement):')
        for l in info:
            print(l)
    np = sum(1 for j in jobs if j[0] == 'P')
    print(f'clock parity: {"PASS" if not bad else "FAIL"} ({np - len(bad)} / {np} forms within i486 clocks)')


if __name__ == '__main__':
    main()
