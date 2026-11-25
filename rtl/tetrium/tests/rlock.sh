#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Random 16/32-bit real-mode programs (tests/rgen386.py), pipelined with random
# bus timing, in lockstep with the 86Box interpreter.
# usage: tests/rlock.sh [nprog] [seed0] [nretire] [jobs]      (PM=1: in 16-bit protected mode,
#        PG=1: protected mode with paging: random page tables and a demand-paging #PF handler,
#        D32=1: (with PM=1 / PG=1) in a 32-bit code segment, R3=1: (with PM=1 / PG=1) at ring 3,
#        RING=1 / 2: (with PM=1 / PG=1) at ring 1 / 2,
#        V86=1: (alone or with PG=1) in virtual-8086 mode,
#        IRQ=1: INTR every 61-360 cycles (the period differs per program), IF mostly set,
#        NMI=1: NMI every 400-999 cycles)
set -e
cd "$(dirname "$0")/.."
NPROG=${1:-64}
SEED0=${2:-1}
NRET=${3:-3000}
JOBS=${4:-16}
SIM=${SIM:-build/sim/Vtetrium_core}
OUT=${ROUT:-build/rl486${PM:+pm}${PG:+pg}${D32:+d32}${R3:+r3}${RING:+ring$RING}${V86:+v86}${IRQ:+irq}${NMI:+nmi}}
PMF=${PM:+--pm}
[ -n "$PG" ] && PMF=--pg
mkdir -p "$OUT"
LAST=$((SEED0 + NPROG - 1))
IRQF=${IRQ:+--irq}${D32:+ --d32}${R3:+ --r3}${RING:+ --r$RING}${V86:+ --v86}
seq "$SEED0" "$LAST" | xargs -P "$JOBS" -I{} python3 -I tests/rgen386.py "$OUT/r{}.bin" {} "$NRET" $PMF $IRQF
# (one program per run with a time limit: a hang shows up as a TIMEOUT line)
TMO=${TMO:-600}
seq "$SEED0" "$LAST" | xargs -P "$JOBS" -I{} sh -c "\${NMI:+env LOCKNMI=\$((400 + {} * 137 % 600))} timeout $TMO $SIM -k -rb \${IRQ:+-i \$((61 + {} * 37 % 300))} $OUT/r{}.bin; [ \$? = 124 ] && echo 'r{}.bin      LOCK TIMEOUT (killed after ${TMO}s)'; true" > ${RLOG:-build/rlock486$PMF${IRQ:+--irq}${D32:+--d32}${R3:+--r3}${RING:+--r$RING}${V86:+--v86}${NMI:+--nmi}.log} 2>&1
ok=$(grep -c "LOCK OK" ${RLOG:-build/rlock486$PMF${IRQ:+--irq}${D32:+--d32}${R3:+--r3}${RING:+--r$RING}${V86:+--v86}${NMI:+--nmi}.log} || true)
tot=$(grep -c "LOCK" ${RLOG:-build/rlock486$PMF${IRQ:+--irq}${D32:+--d32}${R3:+--r3}${RING:+--r$RING}${V86:+--v86}${NMI:+--nmi}.log} || true)
echo "random lockstep OK: $ok / $tot"
grep -v "LOCK OK" ${RLOG:-build/rlock486$PMF${IRQ:+--irq}${D32:+--d32}${R3:+--r3}${RING:+--r$RING}${V86:+--v86}${NMI:+--nmi}.log} | cut -c1-300 | head -20 || true
awk '/LOCK OK/ {split($6,a,"="); s+=a[2]; n++} END {if (n) printf "mean IPC (random bus): %.3f\n", s/n}' ${RLOG:-build/rlock486$PMF${IRQ:+--irq}${D32:+--d32}${R3:+--r3}${RING:+--r$RING}${V86:+--v86}${NMI:+--nmi}.log}
