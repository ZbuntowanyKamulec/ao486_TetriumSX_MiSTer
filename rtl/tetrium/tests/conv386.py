#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Convert SingleStepTests/80386 MOO files to the compact binary the Tetrium
testbench and the x86ref runner read.

usage: conv386.py <in.MOO.gz> <out.bin> [max_tests]

Output (little endian):
  "T386", u32 count
  per test:
    u32 init[20], u32 fin[20]     register order: cr0 cr3 eax ebx ecx edx esi edi ebp esp
                                                  cs ds es fs gs ss eip eflags dr6 dr7
    u32 fmask                     EFLAGS bits that are defined after the instruction
    u8  exc (0xFF = none), u8 pad[3], u32 flag_addr   (address of the pushed FLAGS image)
    u16 nram,  u32 ram[nram]      (addr << 8) | value      initial memory (24-bit addresses)
    u16 nchk,  u32 chk[nchk]      final memory
The flag mask comes from the f_umask column of 80386.csv (opcode + group extension).
Tests whose hash is in revocation_list.txt are dropped.
"""
import csv, gzip, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SUITE = os.path.join(HERE, '..', 'ref', 'tests386')


def chunks(buf, pos, end):
    while pos + 8 <= end:
        tag = buf[pos:pos + 4]
        ln = struct.unpack_from('<I', buf, pos + 4)[0]
        yield tag, pos + 8, pos + 8 + ln
        pos += 8 + ln


def regs32(buf, pos, base):
    mask = struct.unpack_from('<I', buf, pos)[0]
    pos += 4
    r = list(base)
    for b in range(32):
        if mask >> b & 1:
            v = struct.unpack_from('<I', buf, pos)[0]
            pos += 4
            if b < 20:
                r[b] = v
    return r


def ram(buf, pos):
    n = struct.unpack_from('<I', buf, pos)[0]
    out = []
    for i in range(n):
        a, v = struct.unpack_from('<IB', buf, pos + 4 + 5 * i)
        out.append(((a & 0xFFFFFF) << 8) | v)
    return out


def flag_masks():
    """(opcode string, ext or None) -> mask of defined flag bits"""
    m = {}
    with open(os.path.join(SUITE, '80386.csv')) as f:
        for row in csv.DictReader(f):
            um = row['f_umask'].strip()
            ex = row['ex'].strip()
            key = (row['op'].strip().upper(), int(ex) if ex != '' else None)
            m[key] = int(um, 16) if um else 0xFFFF
    return m


def main():
    src, dst = sys.argv[1], sys.argv[2]
    maxn = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << 30
    name = os.path.basename(src).split('.MOO')[0]          # e.g. 676601, 80.4, 0FA0
    parts = name.split('.')
    op = parts[0]
    ext = int(parts[1]) if len(parts) > 1 else None
    while len(op) > 2 and op[:2] in ('66', '67'):          # size prefixes are part of the file name
        op = op[2:]
    fm = flag_masks()
    fmask = fm.get((op, ext), fm.get((op, None), 0xFFFF)) | 0xFFFF0000
    revoked = set()
    rl = os.path.join(SUITE, 'revocation_list.txt')
    if os.path.exists(rl):
        for line in open(rl):
            line = line.strip()
            if line and not line.startswith('#'):
                revoked.add(line.lower())
    buf = gzip.open(src, 'rb').read()
    out = []
    for tag, p, e in chunks(buf, 0, len(buf)):
        if tag != b'TEST' or len(out) >= maxn:
            continue
        init = fin = None
        iram = fram = []
        exc, faddr, hsh = 0xFF, 0, ''
        for t2, p2, e2 in chunks(buf, p + 4, e):
            if t2 == b'INIT':
                for t3, p3, e3 in chunks(buf, p2, e2):
                    if t3 == b'RG32':
                        init = regs32(buf, p3, [0] * 20)
                    elif t3 == b'RAM ':
                        iram = ram(buf, p3)
            elif t2 == b'FINA':
                for t3, p3, e3 in chunks(buf, p2, e2):
                    if t3 == b'RG32':
                        fin = (p3,)
                    elif t3 == b'RAM ':
                        fram = ram(buf, p3)
            elif t2 == b'EXCP':
                exc, faddr = struct.unpack_from('<BI', buf, p2)
            elif t2 == b'HASH':
                hsh = buf[p2:e2].hex()
        if init is None or hsh in revoked:
            continue
        finr = regs32(buf, fin[0], init) if fin else list(init)
        rec = struct.pack('<20I20I', *init, *finr)
        rec += struct.pack('<IB3xI', fmask, exc, faddr & 0xFFFFFF)
        rec += struct.pack('<H', len(iram)) + struct.pack('<%dI' % len(iram), *iram)
        rec += struct.pack('<H', len(fram)) + struct.pack('<%dI' % len(fram), *fram)
        out.append(rec)
    with open(dst, 'wb') as f:
        f.write(b'T386' + struct.pack('<I', len(out)))
        for r in out:
            f.write(r)


if __name__ == '__main__':
    main()
