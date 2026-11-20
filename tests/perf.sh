#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Dhrystone 2.1 and CoreMark per MHz (simulation, 32-bit flat protected mode).
#   Dhrystone: z486's freestanding build (same source and gcc flags as its z486 / z386 / ao486
#              comparison), fetched into ref/z486dhry
#   CoreMark:  bench/c/coremark, 2K performance run, CRCs checked
# Each runs at two iteration counts; the difference gives the cycles per iteration (no
# startup, warm caches).   usage: tests/perf.sh [bus latency] [sim binary]
set -e
cd "$(dirname "$0")/.."
LAT=${1:-4}
SIM=${2:-build/sim/Vtetrium_core}
O=build/perf
Z=ref/z486dhry
ZC=62ae68e3c4c13e7d69cd1cc619b2b8fe26c1841c
mkdir -p $O
if [ ! -e $Z/support.c ]; then
  mkdir -p $Z
  for f in dhry.h dhry_1.c dhry_2.c dhrystone_main.c support.c; do
    curl -sfL -o $Z/$f https://raw.githubusercontent.com/nand2mario/z486/$ZC/tests/dhrystone/$f
  done
fi
CF="-m32 -march=i386 -mno-80387 -ffreestanding -fno-builtin -fno-pic -fno-pie -fno-stack-protector
    -fno-asynchronous-unwind-tables -w -O2"
build() {   # name iterations defines sources...
  local n=$1 it=$2 def=$3 d=$O/$1_$2 objs=""; shift 3
  mkdir -p $d
  for s in "$@"; do
    gcc $CF $def -c $s -o $d/$(basename ${s%.*}).o
    objs="$objs $d/$(basename ${s%.*}).o"
  done
  gcc -m32 -nostdlib -static -no-pie -Wl,-T,bench/perf/perf.ld -Wl,--no-warn-rwx-segments \
      -Wl,--no-warn-execstack -Wl,--build-id=none $objs -o $d/$n.elf
  objcopy -O binary $d/$n.elf $d/$n.bin
  python3 tools/flat2img.py $d/$n.bin $d/$n.com
}
run() { "$SIM" -b -nocheck -con -l $LAT $1; }
cyc() { grep -o "cycles=[0-9]*" | cut -d= -f2; }

for it in 200 1200; do
  build dhry $it "-DREG=register -DDHRY_EMBEDDED -DDHRY_ITERS=$it -std=gnu89 -DENTRY=dhrystone_main -DCHECK_RESULT" \
        bench/perf/start.S $Z/dhrystone_main.c $Z/dhry_1.c $Z/dhry_2.c $Z/support.c
done
a=$(run $O/dhry_200/dhry.com); b=$(run $O/dhry_1200/dhry.com)
ok=$(( $(echo "$a" | grep -c "^OK") + $(echo "$b" | grep -c "^OK") ))
c=$(echo "($(echo "$b" | cyc) - $(echo "$a" | cyc)) / 1000" | bc -l)
printf "Dhrystone 2.1: %.1f cycles / iteration, %.3f DMIPS/MHz%s\n" $c $(echo "1000000 / $c / 1757" | bc -l) "$([ $ok = 2 ] || echo ' RESULT CHECK FAILED')"

C=bench/c
for it in 10 60; do
  build coremark $it "-D__386__ -DDHRY_RUNS=1 -I$C/coremark -DITERATIONS=$it -DTOTAL_DATA_SIZE=2000 -DENTRY=main" \
        bench/perf/start.S $C/coremark/*.c $C/rt.c
done
a=$(run $O/coremark_10/coremark.com); b=$(run $O/coremark_60/coremark.com)
crc=$(echo "$b" | grep -c -E "seedcrc *: 0xe9f5|crclist *: 0xe714|crcmatrix *: 0x1fd7|crcstate *: 0x8e3a" || true)
c=$(echo "($(echo "$b" | cyc) - $(echo "$a" | cyc)) / 50" | bc -l)
printf "CoreMark:      %.1f cycles / iteration, %.3f CoreMark/MHz%s\n" $c $(echo "1000000 / $c" | bc -l) "$([ $crc = 4 ] || echo ' CRC CHECK FAILED')"
