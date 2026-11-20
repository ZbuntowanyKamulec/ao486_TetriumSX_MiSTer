#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Random 16/32-bit real-mode programs (tests/rgen386.py), pipelined with random
# bus timing, in lockstep with the 86Box interpreter.
# usage: tests/rlock.sh [nprog] [seed0] [nretire] [jobs]      (PM=1: in 16-bit protected mode,
#        PG=1: protected mode with paging: random page tables and a demand-paging #PF handler)
set -e
cd "$(dirname "$0")/.."
NPROG=${1:-64}
SEED0=${2:-1}
NRET=${3:-3000}
JOBS=${4:-16}
SIM=${SIM:-build/sim/Vtetrium_core}
OUT=${ROUT:-build/rl486${PM:+pm}${PG:+pg}}
PMF=${PM:+--pm}
[ -n "$PG" ] && PMF=--pg
mkdir -p "$OUT"
LAST=$((SEED0 + NPROG - 1))
seq "$SEED0" "$LAST" | xargs -P "$JOBS" -I{} python3 -I tests/rgen386.py "$OUT/r{}.bin" {} "$NRET" $PMF
# (one program per run with a time limit: a hang shows up as a TIMEOUT line)
TMO=${TMO:-600}
seq "$SEED0" "$LAST" | xargs -P "$JOBS" -I{} sh -c "timeout $TMO $SIM -k -rb $OUT/r{}.bin; [ \$? = 124 ] && echo 'r{}.bin      LOCK TIMEOUT (killed after ${TMO}s)'; true" > ${RLOG:-build/rlock486$PMF.log} 2>&1
ok=$(grep -c "LOCK OK" ${RLOG:-build/rlock486$PMF.log} || true)
tot=$(grep -c "LOCK" ${RLOG:-build/rlock486$PMF.log} || true)
echo "random lockstep OK: $ok / $tot"
grep -v "LOCK OK" ${RLOG:-build/rlock486$PMF.log} | cut -c1-300 | head -20 || true
awk '/LOCK OK/ {split($6,a,"="); s+=a[2]; n++} END {if (n) printf "mean IPC (random bus): %.3f\n", s/n}' ${RLOG:-build/rlock486$PMF.log}
