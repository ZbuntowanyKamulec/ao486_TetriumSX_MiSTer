#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# interrupt regression: bench/irq.com with INTR every N cycles at several bus latencies.
# (N must exceed the ISR length, ~30 cycles; below that the CPU livelocks in the ISR, as an 8086 would)
cd "$(dirname "$0")/.."
SIM=${SIM:-build/sim/Vtetrium_core}
fail=0; n=0
for l in 1 2 4 7; do for i in 41 64 97 199 1003; do
  out=$($SIM -b -l $l -i $i bench/irq.com)
  n=$((n+1))
  if echo "$out" | grep -qE "MISMATCH|TIMEOUT|IRQCOUNT"; then fail=$((fail+1)); echo "FAIL l=$l i=$i: $(echo "$out" | head -2 | tr '\n' ' ')"; fi
done; done
echo "irq runs OK: $((n-fail)) / $n"
