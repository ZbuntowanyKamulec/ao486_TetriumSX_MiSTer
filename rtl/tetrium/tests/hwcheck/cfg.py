#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Patch the hwcheck configuration in an image (hwcheck.vhd or hwcheck.com).
usage: cfg.py <image> [seed=N] [suites=MASK] [stop=N] [tb=0|1] [items=N] [progs=N] [off=MASK] [envs=MASK] [one=N]
  seed    first round; every round runs each enabled suite with its own random data
  suites  bit 0 fuzz, 1 acc, 2 seg, 3 xfer, 4 task, 5 vm, 6 irq, 7 soc, 8 unreal
  stop    rounds to run (0 = for ever);  tb: 1 = lockstep testbench (no BIOS, no devices)
  items   fuzz: instructions per program (0 = random);  progs: programs per round
  envs    fuzz: bit 0 flat 32-bit ring 3, 1 16-bit protected mode, 2 V86 (0 = all)
Without settings: prints the current configuration."""
import struct, sys
F = ['magic', 'seed', 'suites', 'stop', 'tb', 'items', 'progs', 'off', 'envs', 'one']
p = sys.argv[1]
img = bytearray(open(p, 'rb').read())
o = img.find(b'HWCK', 0, 2048)
assert o > 0, 'no configuration block'
v = list(struct.unpack_from('<10I', img, o))
for a in sys.argv[2:]:
    k, x = a.split('=')
    v[F.index(k)] = int(x, 0)
struct.pack_into('<10I', img, o, *v)
if len(sys.argv) > 2: open(p, 'wb').write(img)
print(' '.join('%s=%s' % (k, hex(x) if k in ('suites', 'off', 'envs') else x) for k, x in zip(F[1:], v[1:])))
