#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Medium-model builds of the C benchmarks (far code: CALL FAR / RETF for every call).
# Output: bench/<name>_m.com (bench/<name>_mp.com: the
# same in 16-bit protected mode, tools/mz2pm.py)
# usage: [SPLIT=1] bench/c/buildm.sh [name ...]
#   SPLIT=1: every module in its own code segment (no code packing): calls between modules
#   change CS, as in programs with more than 64 KB of code.  Output: bench/<name>_ms.com
set -e
cd "$(dirname "$0")"
export WATCOM=${WATCOM:-$HOME/tools/ow2}
export PATH=$WATCOM/binl64:$PATH
export INCLUDE=$WATCOM/h
CFLAGS="-0 -mm -ox -s -zq -zl -d0 -I. -DDHRY_RUNS=${DHRY_RUNS:-500}"
OUT=../../build/cbench_m
mkdir -p $OUT
wasm -zq -fo=$OUT/crt0m.obj crt0m.asm
wcc $CFLAGS -fo=$OUT/rt.obj rt.c
names=${@:-$(ls -d */ | tr -d /)}
for n in $names; do
  objs=""
  extra=$(cat $n/flags 2>/dev/null || true)
  for c in $n/*.c; do
    o=$OUT/${n}_$(basename $c .c).obj
    wcc $CFLAGS -I$n $extra -fo=$o $c
    objs="$objs file $o"
  done
  sfx=_m; pk=""
  [ -n "$SPLIT" ] && { sfx=_ms; pk="option packcode=16"; }
  wlink option quiet format dos name $OUT/$n$sfx.exe file $OUT/crt0m.obj $objs file $OUT/rt.obj \
        library $WATCOM/lib286/dos/clibm.lib option map=$OUT/$n$sfx.map $pk
  python3 ../../tools/mz2img.py $OUT/$n$sfx.exe ../${n}$sfx.com
  # the same in 16-bit protected mode (<name>_mp / _msp; not when the GDT does not fit)
  python3 ../../tools/mz2pm.py $OUT/$n$sfx.exe ../${n}${sfx}p.com 2>/dev/null || echo "$n$sfx: no PM image"
  echo "$n: $(( $(stat -c %s ../${n}$sfx.com) - 256 )) bytes"
done
