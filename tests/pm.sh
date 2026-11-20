#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Directed protected-mode / paging tests (tests/pm/pm*.s) in lockstep with 86Box,
# fixed and random bus timing.   usage: tests/pm.sh [pmN ...]
cd "$(dirname "$0")/.."
SIM=${SIM:-build/sim/Vtetrium_core}
P=${PMD:-build/pm}
mkdir -p $P
if [ $# -gt 0 ]; then T=("$@"); else T=(tests/pm/pm*.s); fi
for t in "${T[@]}"; do
  b=$(basename "$t" .s)
  # a test's own lockstep options: a line '# lockenv: NAME=value ...'
  E=$(sed -n 's/^# lockenv: //p' tests/pm/$b.s)
  as --32 -o $P/$b.o tests/pm/$b.s && objcopy -O binary $P/$b.o $P/$b.com ||
    { echo "$b: assembly failed"; continue; }
  # INTR every N cycles (replayed into the model): a line '# lockirq: N ...' runs each N
  IRQ=$(sed -n 's/^# lockirq: //p' tests/pm/$b.s)
  for i in ${IRQ:-0}; do
    IA=""; SFX=""; [ "$i" != 0 ] && { IA="-i $i"; SFX=" irq$i"; }
    echo "$b fixed$SFX: $(env $E "$SIM" -k $IA $P/$b.com 2>&1 | grep LOCK | cut -c1-200)"
    echo "$b rndbus$SFX: $(env $E "$SIM" -k -rb $IA $P/$b.com 2>&1 | grep LOCK | cut -c1-200)"
  done
done
