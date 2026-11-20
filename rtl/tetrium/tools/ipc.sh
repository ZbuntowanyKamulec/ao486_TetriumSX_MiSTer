#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# IPC of the benchmark set (L=4 bus latency, no reference check);
# usage: tools/ipc.sh [sim binary] [set: asm|c|c32|all]   (c32: 32-bit flat builds, bench/c/build32.sh)
SIM=${1:-build/sim/Vtetrium_core}
SET=${2:-all}
ASM="bigcode crc fib mixed sieve sort strops"
C="dhry coremark lzss vm qsort queens words"
C32="dhry_32 coremark_32 lzss_32 vm_32 qsort_32 queens_32 words_32 bigc_32"
case $SET in asm) L=$ASM;; c) L=$C;; c32) L=$C32;; *) L="$ASM $C";; esac
for b in $L; do
  echo "$b $($SIM -b -nocheck -l 4 bench/$b.com 2>&1 | grep -o "IPC=[0-9.]*" | cut -d= -f2)" &
done | sort | awk '{printf "%s %s  ", $1, $2} END {print ""}'
wait
