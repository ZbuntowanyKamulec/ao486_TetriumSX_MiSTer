#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Turn a DOS MZ .EXE into a testbench image: 256-byte PSP gap, a far JMP at 1000:0100 to
the EXE entry, the load module at the next paragraph with its relocations applied.
usage: mz2img.py in.exe out.com"""
import struct, sys

d = open(sys.argv[1], 'rb').read()
sig, last, pages, nrel, hdr, _, _, ss, sp, _, ip, cs, relo = struct.unpack_from('<2sHHHHHHHHHHHH', d, 0)
assert sig == b'MZ'
size = pages * 512 - (512 - last if last else 0)
img = bytearray(d[hdr * 16:size])
base = 0x100 + 16                       # file offset of the load module (paragraph aligned)
L = 0x1000 + base // 16                 # its load segment
for i in range(nrel):
    off, seg = struct.unpack_from('<HH', d, relo + 4 * i)
    a = seg * 16 + off
    v = struct.unpack_from('<H', img, a)[0]
    struct.pack_into('<H', img, a, (v + L) & 0xFFFF)
stub = bytes([0xEA]) + struct.pack('<HH', ip, (cs + L) & 0xFFFF)
out = bytes(256) + stub + bytes(16 - len(stub)) + bytes(img)
assert len(out) <= 0x10000, 'image larger than 64 KB'
open(sys.argv[2], 'wb').write(out)
