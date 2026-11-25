#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# hwcheck under the lockstep testbench (RTL against the 86Box interpreter), one line per seed
# that fails.   usage: tests/hwcheck/lock.sh [first seed] [last seed] [suites] [jobs]
cd "$(dirname "$0")/../.."
SIM=${SIM:-build/sim/Vtetrium_core}
B=build/hwcheck
[ -f $B/hwcheck.com ] || tests/hwcheck/build.sh > /dev/null || exit 1
gcc -O2 -w -o $B/ref_run -Itb/x86ref tb/x86ref/ref_run.c build/x86ref/libx86ref.a -lm -lstdc++
export SIM B SU=${3:-319}
one() {
  f=$B/lk$1.com; cp $B/hwcheck.com $f
  tests/hwcheck/cfg.py $f tb=1 stop=1 seed=$1 suites=$SU progs=4 > /dev/null
  RB=""; [ $(($1 % 2)) = 1 ] && RB="-rb"
  LOCKE9=1 timeout 1800 $SIM -k $RB $f 2>&1 | grep -v "hwcheck  seed" | tr '\n' ' ' | sed "s/^/seed $1: /; s/\$/\n/"
  rm -f $f
}
export -f one
seq ${1:-1} ${2:-8} | xargs -P ${4:-8} -I{} bash -c "one {}" > $B/lock.log
echo "hwcheck lockstep OK: $(grep -c 'ALL PASSED 0.*LOCK OK' $B/lock.log) / $(wc -l < $B/lock.log)"
grep -v 'ALL PASSED 0.*LOCK OK' $B/lock.log | cut -c1-400
