#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Turn a DOS MZ .EXE (medium-model benchmark, bench/c/buildm.sh) into a testbench image
that runs in 16-bit protected mode at CPL 0: the relocated segment values become GDT
selectors (DGROUP and the frames above it data segments, every other frame a 16-bit code
segment, base = its real-mode frame * 16, limit FFFF), selector 2000 the console buffer
at 20000 (rt.c writes 2000:0000).  A stub at 1000:0100 loads the GDT, sets CR0.PE and
jumps to the entry.
usage: mz2pm.py in.exe out.com"""
import struct, sys

d = open(sys.argv[1], 'rb').read()
sig, last, pages, nrel, hdr, minalloc, _, ss, sp, _, ip, cs, relo = struct.unpack_from('<2sHHHHHHHHHHHH', d, 0)
assert sig == b'MZ'
size = pages * 512 - (512 - last if last else 0)
img = bytearray(d[hdr * 16:size])
base = 0x100 + 48                       # file offset of the load module (paragraph aligned)
L = 0x1000 + base // 16                 # its real-mode load segment
frames = sorted({struct.unpack_from('<H', img, seg * 16 + off)[0]
                 for off, seg in (struct.unpack_from('<HH', d, relo + 4 * i) for i in range(nrel))} | {cs, ss})
# DGROUP: crt0m starts with mov ax, DGROUP; it and the frames above it (the stack) are data
e = cs * 16 + ip
assert img[e] == 0xB8
dg = struct.unpack_from('<H', img, e + 1)[0]
sel = {f: (k + 1) << 3 for k, f in enumerate(frames)}
assert max(sel.values()) < 0x2000
for i in range(nrel):
    off, seg = struct.unpack_from('<HH', d, relo + 4 * i)
    a = seg * 16 + off
    struct.pack_into('<H', img, a, sel[struct.unpack_from('<H', img, a)[0]])


def desc(b, acc):
    return struct.pack('<HHBBBB', 0xFFFF, b & 0xFFFF, (b >> 16) & 0xFF, acc, 0, b >> 24)


gdt = bytearray(8 * 0x401)
for f, s in sel.items():
    gdt[s:s + 8] = desc((f + L) * 16, 0x93 if f >= dg else 0x9B)
gdt[0x2000:0x2008] = desc(0x20000, 0x93)
gofs = 0x10000 - len(gdt)               # GDT at the top of the 64 KB (past BSS and stack)
assert base + len(img) + minalloc * 16 <= gofs, 'no room for the GDT'
gdtr = 0x100 + 32
stub = bytes([0xFA, 0x2E, 0x0F, 0x01, 0x16]) + struct.pack('<H', gdtr) + \
       bytes([0x0F, 0x20, 0xC0, 0x0C, 0x01, 0x0F, 0x22, 0xC0, 0xEA]) + struct.pack('<HH', ip, sel[cs])
head = bytearray(48)
head[:len(stub)] = stub
head[32:38] = struct.pack('<HI', len(gdt) - 1, 0x10000 + gofs)
out = bytearray(256) + head + img
out += bytes(gofs - len(out)) + gdt
assert len(out) <= 0x10000, 'image larger than 64 KB'
open(sys.argv[2], 'wb').write(out)
