#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# C benchmarks (OpenWatcom builds in bench/*.com): each program checks its own
# result; the testbench also compares the pipelined run with a single-stepped one.
cd "$(dirname "$0")/.."
SIM=${SIM:-build/sim/Vtetrium_core}
declare -A want=( [dhry]="Int_Glob:            5" [coremark]="crcfinal      : 0x2e87" [lzss]=" OK sum="
                  [vm]="(OK)" [qsort]="records: OK" [queens]="352 OK" [words]="top: an=57" )
pass=0; n=0
for b in dhry coremark lzss vm qsort queens words; do
  out=$($SIM -b -con bench/$b.com 2>&1)
  n=$((n+1))
  if echo "$out" | grep -qF "${want[$b]}" && ! echo "$out" | grep -qE "MISMATCH|TIMEOUT"; then pass=$((pass+1))
  else echo "FAIL $b"; echo "$out" | head -5; fi
done
echo "C benchmarks OK: $pass / $n"
