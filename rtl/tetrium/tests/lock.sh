#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Lockstep against the 86Box interpreter (tb/x86ref): every benchmark program,
# pipelined, registers / flags / stores compared after each retired instruction.
# usage: tests/lock.sh [jobs]      (SIM=... to pick another simulator binary)
cd "$(dirname "$0")/.."
SIM=${SIM:-build/sim/Vtetrium_core}
JOBS=${1:-16}
LOG=${LOG:-build/lock486.log}
T4=${T4:-build/t486}
# directed real-mode programs (tests/*.s with a .COM layout)
mkdir -p $T4
for t in aexshl pfxskip; do
  as --32 -o $T4/$t.o tests/$t.s && objcopy -O binary $T4/$t.o $T4/$t.com || exit 1
done
{
  for b in bench/*.com $T4/aexshl.com $T4/pfxskip.com; do
    echo "-k -l 2 $b"; echo "-k -rb $b"
  done
  # warm predictor (BTB / return stack / target cache are not cleared by reset): the
  # far-call builds run twice in one process, the second run on the first one's entries
  for b in bench/*_m.com bench/*_ms.com bench/*_mp.com bench/*_msp.com; do echo "-k -rb $b $b"; done
  # interrupts (incl. interrupted REP string instructions)
  for i in 97 333 700; do echo "-k -rb -i $i bench/irq.com"; done
} | xargs -P "$JOBS" -I{} sh -c "$SIM {} | sed 's|^|{} : |'" > $LOG 2>&1
ok=$(grep -c "LOCK OK" $LOG); tot=$(grep -c "LOCK" $LOG)
echo "lockstep OK: $ok / $tot"
grep -v "LOCK OK" $LOG | cut -c1-300 | head -20
