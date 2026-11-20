#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# self-modifying code idioms (bench/smc.s) against the single-stepped run, several bus latencies
cd "$(dirname "$0")/.."
SIM=${SIM:-build/sim/Vtetrium_core}
as --32 -o build/smc.o bench/smc.s && objcopy -O binary build/smc.o bench/smc.com
ok=0
for l in 1 2 4 7; do
  out=$($SIM -b -l $l bench/smc.com | head -1)
  if echo "$out" | grep -qE "MISMATCH|TIMEOUT"; then echo "FAIL l=$l: $out"; else ok=$((ok+1)); fi
done
echo "smc runs OK: $ok / 4"
