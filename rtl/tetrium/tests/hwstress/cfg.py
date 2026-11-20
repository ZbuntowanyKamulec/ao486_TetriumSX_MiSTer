#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Patch the stress kernel configuration in a hwstress image.
usage: cfg.py <image> [seed=N] [tests=0xMASK] [passes=N] [reps=N] [stop=N] [pit=0..3] [steal=0..255] [first=N] [off=MASK]
  seed    first data/register seed (each seed: every enabled test, quiet + 'passes' stressed runs)
  tests   bit t = mode*4 + workload (modes: 0 V86, 1 ring 3, 2 ring 0, 3 16-bit PM ring 3, 4 real mode); default FFFFF
  passes  stressed runs per test and seed;  reps: workload body repetitions per run
  stop    number of seeds to run (0 = forever);  pit: 0 random, 1 fast, 2 medium, 3 slow IRQ rate
  steal   maximum page-steal probability per IRQ (/256)
  off     bits: 1 RTC, 2 steal, 4 A/D clear, 8 CR3 reload, 16 WBINVD, 32 IDE, 64 no IRQ at all
          in stressed runs, 128 EM never set (bisecting a report)
  first   first pass of the first seed (replays a reported pass; the quiet reference still runs)
Without settings: prints the current configuration."""
import struct, sys
F = ['magic', 'seed', 'tests', 'passes', 'reps', 'stop', 'pit_sel', 'steal_max', 'first', 'off']
ALIAS = {'pit': 'pit_sel', 'steal': 'steal_max'}
p = sys.argv[1]
img = bytearray(open(p, 'rb').read())
o = img.find(b'WHST', 512, 512 + 65536)
assert o > 0, 'no configuration block'
v = list(struct.unpack_from('<10I', img, o))
for a in sys.argv[2:]:
    k, x = a.split('=')
    v[F.index(ALIAS.get(k, k))] = int(x, 0)
struct.pack_into('<10I', img, o, *v)
if len(sys.argv) > 2: open(p, 'wb').write(img)
print(' '.join('%s=%s' % (k, hex(x) if k == 'tests' else x) for k, x in zip(F[1:], v[1:])))
