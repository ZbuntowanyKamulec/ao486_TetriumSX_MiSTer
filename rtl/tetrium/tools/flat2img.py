#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Turn a raw 32-bit flat binary (bench/c/build32.sh, linked at linear 30000, entry at its
start) into a testbench image: 256-byte PSP gap, a 16-bit stub at 1000:0100 that loads
a GDT (08: flat 32-bit code, 10: flat 32-bit data, base 0, 4 GB), sets CR0.PE, copies the
program from where the testbench loaded it (10200) to 30000 (its BSS and stack would
reach the console buffer at 20000 otherwise) and jumps to it; the program sets its
segments and stack itself (bench/c/crt032.asm).
usage: flat2img.py in.bin out.com"""
import struct, sys

LOAD, SRC = 0x30000, 0x10200
prog = open(sys.argv[1], 'rb').read()
prog += bytes(-len(prog) % 4)
head = bytearray(0x100)                 # 1000:0100 .. 1000:01FF
gdtr, gdt, s32 = 0x40, 0x48, 0x60
stub = bytes([0xFA, 0x2E, 0x0F, 0x01, 0x16]) + struct.pack('<H', 0x100 + gdtr) + \
       bytes([0x0F, 0x20, 0xC0, 0x0C, 0x01, 0x0F, 0x22, 0xC0,
              0x66, 0xEA]) + struct.pack('<IH', 0x10100 + s32, 0x08)
head[:len(stub)] = stub
# 32-bit: mov eax, 10h; mov ds, ax; mov es, ax; mov esi, SRC; mov edi, LOAD;
#         mov ecx, dwords; cld; rep movsd; mov eax, LOAD; jmp eax
c32 = bytes([0xB8, 0x10, 0, 0, 0, 0x8E, 0xD8, 0x8E, 0xC0, 0xBE]) + struct.pack('<I', SRC) + \
      bytes([0xBF]) + struct.pack('<I', LOAD) + bytes([0xB9]) + struct.pack('<I', len(prog) // 4) + \
      bytes([0xFC, 0xF3, 0xA5, 0xB8]) + struct.pack('<I', LOAD) + bytes([0xFF, 0xE0])
head[s32:s32 + len(c32)] = c32
head[gdtr:gdtr + 6] = struct.pack('<HI', 3 * 8 - 1, 0x10000 + 0x100 + gdt)
head[gdt + 8:gdt + 16] = struct.pack('<Q', 0x00CF9B000000FFFF)     # code32, G, D, accessed
head[gdt + 16:gdt + 24] = struct.pack('<Q', 0x00CF93000000FFFF)    # data32, G, B, accessed
out = bytes(0x100) + bytes(head) + prog
assert len(out) <= 0x10000, 'image larger than 64 KB'
open(sys.argv[2], 'wb').write(out)
