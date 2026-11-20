#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Build the freestanding C benchmarks with OpenWatcom (8086, tiny model .COM).
# usage: bench/c/build.sh [name ...]   (default: all subdirectories)
#   each bench/c/<name>/ holds the program sources (+ optional flags file);
#   output: bench/<name>.com
set -e
cd "$(dirname "$0")"
export WATCOM=${WATCOM:-$HOME/tools/ow2}
export PATH=$WATCOM/binl64:$PATH
export INCLUDE=$WATCOM/h
CFLAGS="-0 -ms -ox -s -zq -zl -d0 -I. -DDHRY_RUNS=${DHRY_RUNS:-500}"
OUT=../../build/cbench
mkdir -p $OUT
wasm -zq -fo=$OUT/crt0.obj crt0.asm
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
  wlink option quiet format dos com name ../$n.com file $OUT/crt0.obj $objs file $OUT/rt.obj \
        library $WATCOM/lib286/dos/clibs.lib option map=$OUT/$n.map
  # the testbench loads images that include the 256-byte PSP gap (like objcopy output)
  python3 -c "import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[1],'wb').write(bytes(256)+d)" ../$n.com
  echo "$n: $(( $(stat -c %s ../$n.com) - 256 )) bytes"
done
