#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# 32-bit flat builds of the C benchmarks (OpenWatcom wcc386 -mf -4r: register calls,
# 486 scheduling, as DOS4GW-era programs), linked as a raw binary at linear 30000 and
# wrapped by tools/flat2img.py (16-bit stub at 1000:0100 entering flat protected mode and
# copying the program from 10200 to 30000).
# Output: bench/<name>_32.com.   usage: bench/c/build32.sh [name ...]
set -e
cd "$(dirname "$0")"
export WATCOM=${WATCOM:-$HOME/tools/ow2}
export PATH=$WATCOM/binl64:$PATH
export INCLUDE=$WATCOM/h
CFLAGS="-4r -mf -ox -s -zq -zl -d0 -I. -DDHRY_RUNS=${DHRY_RUNS:-2000}"   # (2000: as bench/dhry.com)
OUT=../../build/cbench32
mkdir -p $OUT
wasm -zq -fo=$OUT/crt0.obj crt032.asm
wcc386 $CFLAGS -fo=$OUT/rt.obj rt.c
names=${@:-$(ls -d */ | tr -d /)}
for n in $names; do
  objs=""
  extra=$(cat $n/flags 2>/dev/null || true)
  for c in $n/*.c; do
    o=$OUT/${n}_$(basename $c .c).obj
    wcc386 $CFLAGS -I$n $extra -fo=$o $c
    objs="$objs file $o"
  done
  wlink option quiet format raw bin option offset=0x30000 name $OUT/$n.bin file $OUT/crt0.obj $objs \
        file $OUT/rt.obj library $WATCOM/lib386/dos/clib3r.lib option map=$OUT/$n.map
  python3 ../../tools/flat2img.py $OUT/$n.bin ../${n}_32.com
  end=$(sed -n 's/^STACK .* \([0-9a-f]\{8\}\) *\([0-9a-f]\{8\}\)$/\1 \2/p' $OUT/$n.map)
  echo "$n: $(stat -c %s $OUT/$n.bin) bytes, stack/end: $end"
done
