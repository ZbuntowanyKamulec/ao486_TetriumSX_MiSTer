#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# test386.asm (ref/test386) in lockstep with the 86Box model, booted as a ROM from F000:FFF0.
# Builds a configured copy in build/test386 (POST port 190h, ASCII output on port E9h, 128 KB
# ROM), prints the POST codes reached, and compares the POST EEh results with the reference.
# usage: tests/test386.sh [p4|full|p3] [sim binary]
#   p4 (default): everything but the ARPL "no write, no #GP" check (the SDM raises #GP(0)
#      for a read-only destination; test386's BOCHS switch)
#   full: test386 as configured (the ARPL check fails: #GP)
#   p3: also skips the parts that need page translation
#      (flat-address-space ring switch of POST 20, POST 21 V86 and 22 TSS in flat mode,
#      POST 11 page faults, the ENTER #PF check) and the ARPL "no write, no #GP" check
#      (the SDM raises #GP(0) for a read-only destination; test386's BOCHS switch)
cd "$(dirname "$0")/.."
MODE=${1:-p4}
SIM=${2:-build/sim/Vtetrium_core}
D=build/test386
command -v nasm >/dev/null || { echo "test386: nasm not installed"; exit 1; }
rm -rf $D/$MODE; mkdir -p $D; cp -r ref/test386/src $D/$MODE
sed -i -e 's/^OUT_PORT equ 0$/OUT_PORT equ 0xE9/' -e 's/^ROM128 equ 0$/ROM128 equ 1/' $D/$MODE/configuration.asm
if [ "$MODE" != full ]; then
  sed -i 's/^BOCHS equ 0$/BOCHS equ 1/' $D/$MODE/configuration.asm
fi
if [ "$MODE" = p3 ]; then
  python3 - $D/$MODE/test386.asm <<'EOF'
import sys
p = sys.argv[1]; L = open(p).read().split('\n')
def idx(t, start=0):
    return next(i for i in range(start, len(L)) if L[i].strip() == t)
def post(c):
    i = idx('POST ' + c)
    return i - 1 if L[i - 1].startswith(';----') else i
ins = []
a = idx('call  switchToRing3FLATkernel ;Switch to ring 3 with flat kernel stack prepared')
b = idx('kernelModeInterruptKernelStackReturnPoint:')
ins += [(a, '\tjmp p3skip1'), (b + 1, 'p3skip1:')]
ins += [(post('21'), '\tjmp p3skip2'), (post('B'), 'p3skip2:')]
ins += [(post('11'), '\tjmp p3skip3'), (post('12'), 'p3skip3:')]
i = idx('.pageFaultTest:'); assert L[i + 1].strip() == 'loadProtModeStack'
j = next(k for k in range(i, i + 10) if L[k].strip() == 'testCPL 0')
ins += [(i + 2, '\tjmp p3skip4'), (j, 'p3skip4:')]
for k, t in sorted(ins, reverse=True): L.insert(k, t)
open(p, 'w').write('\n'.join(L))
EOF
fi
nasm -i./$D/$MODE/ -f bin $D/$MODE/test386.asm -w-all -l $D/test386$MODE.lst -o $D/test386$MODE.bin || exit 1
# (the i486 reset leaves the caches off (CR0.CD = NW = 1) and test386 never enables them:
# ~365M cycles, over the default limit)
LOCKMAXCYC=${LOCKMAXCYC:-1500000000} $SIM -rom $D/test386$MODE.bin | tee $D/test386$MODE.log
if diff -q <(tr -d '\r' < $D/test386$MODE.bin.out) <(tr -d '\r' < ref/test386/test386-EE-reference.txt) >/dev/null; then
  echo "test386 POST EE results: match the reference"
else
  echo "test386 POST EE results: DIFFER from the reference (diff $D/test386$MODE.bin.out ref/test386/test386-EE-reference.txt)"
fi
