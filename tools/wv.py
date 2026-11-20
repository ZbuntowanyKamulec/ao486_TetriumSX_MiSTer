#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Print selected signals from an FST/VCD file as a per-cycle table.

usage: wv.py wave.fst <from_cycle> <to_cycle> sig1 sig2 ...
  signal names are matched as suffixes of the full hierarchical name
  (e.g. u_mem.st, hold_m).  Values are printed in hex.
"""
import subprocess, sys


def main():
    fn, c0, c1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    want = sys.argv[4:]
    if fn.endswith('.fst'):
        src = subprocess.Popen(['fst2vcd', fn], stdout=subprocess.PIPE, text=True).stdout
    else:
        src = open(fn)
    scope = []
    ids = {}        # id -> column index list
    names = []
    for line in src:
        t = line.split()
        if not t:
            continue
        if t[0] == '$scope':
            scope.append(t[2])
        elif t[0] == '$upscope':
            scope.pop()
        elif t[0] == '$var':
            code, nm = t[3], t[4]
            full = '.'.join(scope[1:] + [nm])
            for w in want:
                if full == w or full.endswith('.' + w) or (w.startswith('=') and full == w[1:]):
                    if full not in names:
                        names.append(full)
                    ids.setdefault(code, []).append(names.index(full))
        elif t[0] == '$enddefinitions':
            break
    vals = ['x'] * len(names)
    rows = []
    cur = None

    def emit(tm):
        cyc = tm // 2
        if c0 <= cyc <= c1:
            rows.append((cyc, list(vals)))

    for line in src:
        if line[0] == '#':
            tm = int(line[1:])
            if cur is not None:
                emit(cur)
            cur = tm
            if cur // 2 > c1:
                break
            continue
        if line[0] == 'b':
            v, code = line[1:].split()
            if code in ids:
                try:
                    hv = '%x' % int(v, 2)
                except ValueError:
                    hv = v
                for i in ids[code]:
                    vals[i] = hv
        elif line[0] in '01xz':
            code = line[1:].strip()
            if code in ids:
                for i in ids[code]:
                    vals[i] = line[0]
    short = [n.split('.')[-2] + '.' + n.split('.')[-1] if n.count('.') else n for n in names]
    w = [max(len(s), 4) for s in short]
    for r in rows:
        for i, v in enumerate(r[1]):
            w[i] = max(w[i], len(v))
    print('cyc   ' + ' '.join(s.rjust(w[i]) for i, s in enumerate(short)))
    last = None
    for cyc, v in rows:
        if v == last:
            continue
        last = v
        print('%-5d ' % cyc + ' '.join(x.rjust(w[i]) for i, x in enumerate(v)))


if __name__ == '__main__':
    main()
