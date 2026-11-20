#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Sim copies of SoC sources: Verilator (5.020) re-runs the initialiser of a reg declared inside
an always block every time the block runs (IEEE: once, static). Drop those initialisers (the
registers start at 0 under --x-initial fast; the resets set the ones that matter).
Also: module-level regs given after the file names that the source assigns with blocking
statements in clocked blocks (a register in synthesis, visible to other blocks in the same
cycle in Verilator): those assignments become non-blocking.
usage: simfix.py <in> <out> [reg ...]"""
import re, sys
src = open(sys.argv[1], newline='').read().split('\n')
out, n = [], 0
for l in src:
    m = re.match(r'^(\s+reg\b)(.*);(.*)$', l)
    if m and '=' in m.group(2):
        decl = re.sub(r"\s*=\s*[^,]+", "", m.group(2))
        l = m.group(1) + decl + ';' + m.group(3)
        n += 1
    for r in sys.argv[3:]:
        l2 = re.sub(r'^(\s+(?:if\s*\(.*\)\s*)?%s)\s*=\s*' % r, r'\1 <= ', l)
        if l2 != l: l = l2; n += 1
    out.append(l)
open(sys.argv[2], 'w', newline='').write('\n'.join(out))
print("%s: %d initialisers dropped" % (sys.argv[1], n))
