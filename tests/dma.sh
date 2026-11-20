#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# DMA snoop test (tests/dma.s): real mode and paging, several bus latencies, random
# bus timing, DMA timing seeds and spurious snoops (DMANOISE); paging with the DMA areas
# on PCD pages and the snoops switched off (DMANOSNOOP): uncacheable data and code.
# usage: tests/dma.sh [nseeds] [jobs]     (SIM=..., DMAD=<build dir> for parallel copies)
cd "$(dirname "$0")/.."
SIM=${SIM:-build/sim/Vtetrium_core}
NS=${1:-4}
JOBS=${2:-16}
D=${DMAD:-build/dma}
mkdir -p "$D"
for pg in 0 1; do
  as --32 --defsym PG=$pg -o $D/dma$pg.o tests/dma.s && objcopy -O binary $D/dma$pg.o $D/dma$pg.com || exit 1
done
# the alias pages uncacheable (PCD) and no snoops at all: nothing may be cached (code included)
as --32 --defsym PG=1 --defsym PCD=1 -o $D/dmapcd.o tests/dma.s && objcopy -O binary $D/dmapcd.o $D/dmapcd.com || exit 1
# one line per run: "<label>|<environment>|<simulator options>|<image>"
{
  for pg in 0 1; do for s in $(seq 1 $NS); do for b in "-l 1" "-l 4" "-rb"; do for nz in 0 7; do
    echo "pg=$pg seed=$s bus=$b noise=$nz|DMASEED=$s DMANOISE=$nz|$b|$D/dma$pg.com"
  done; done; done; done
  for s in $(seq 1 $NS); do for b in "-l 1" "-l 4" "-rb"; do
    echo "pcd nosnoop seed=$s bus=$b|DMANOSNOOP=1 DMASEED=$s|$b|$D/dmapcd.com"
  done; done
} > $D/runs.txt
export SIM
run_one() {
  IFS='|' read -r lab env opt img <<< "$1"
  out=$(env $env timeout 600 $SIM -b -nocheck -con $opt $img 2>&1)
  if echo "$out" | grep -q "DMA .. OK" && ! echo "$out" | grep -qE "TIMEOUT|MISMATCH"; then echo "OK $lab"
  else echo "FAIL $lab: $(echo "$out" | grep -E 'DMA|TIMEOUT' | head -2 | tr '\n' ' ')"; fi
}
export -f run_one
tr '\n' '\0' < $D/runs.txt | xargs -0 -P "$JOBS" -I{} bash -c 'run_one "$1"' _ {} > $D/dma.log
grep "^FAIL" $D/dma.log
echo "dma runs OK: $(grep -c '^OK' $D/dma.log) / $(wc -l < $D/runs.txt)"
