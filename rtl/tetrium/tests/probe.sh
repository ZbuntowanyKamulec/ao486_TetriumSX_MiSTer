#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Probes for 486 behaviour the references may not settle (tests/probe/*.s): each prints its
# results on port E9h.  Runs every probe in the lockstep testbench (the core against 86Box)
# and as a boot floppy in Bochs (a 486SX PC: ref/bochs from tests/fetch.sh, built here on first
# use with --enable-cpu-level=4 --disable-fpu --with-nogui), and compares the printed lines.  The
# floppy images (build/probe/*.img) also boot on a real PC; the results show on port E9h only.
# A probe's '# bochs-expect: <line>' is Bochs's own (documented) result where it differs.
# usage: tests/probe.sh [probe ...]       (BOCHS=<bochs binary>)
cd "$(dirname "$0")/.."
SIM=${SIM:-build/sim/Vtetrium_core}
BX=${BOCHS:-ref/bochs/bochs/bochs}
BIOS=ref/bochs/bochs/bios
D=build/probe
mkdir -p $D
if [ ! -x "$BX" ]; then
  [ -d ref/bochs/bochs ] || { echo "probe: ref/bochs missing (tests/fetch.sh)"; exit 1; }
  echo "building Bochs (ref/bochs/bochs, log in $D/bochs-build.log)"
  (cd ref/bochs/bochs && ./configure --with-nogui --enable-cpu-level=4 --disable-fpu --disable-sound \
     --disable-usb --disable-pci --disable-cdrom && make -j"$(nproc)") > $D/bochs-build.log 2>&1 ||
    { echo "probe: Bochs build failed ($D/bochs-build.log)"; exit 1; }
fi
as --32 -o $D/boot.o tests/probe/boot.s && objcopy -O binary $D/boot.o $D/boot.bin || exit 1
if [ $# -gt 0 ]; then P=("$@"); else P=($(ls tests/probe/*.s | xargs -n1 basename | sed 's/\.s$//' | grep -vx "boot\|mac\|lib")); fi
same=0; n=0
for p in "${P[@]}"; do
  n=$((n + 1))
  as --32 -I tests/probe -o $D/$p.o tests/probe/$p.s && objcopy -O binary $D/$p.o $D/$p.com || { echo "$p: assembly failed"; continue; }
  # testbench: the E9h text, and the lockstep result
  LOCKE9=1 timeout 300 $SIM -k $D/$p.com > $D/$p.tb.txt 2>&1
  tb=$(grep -v "LOCK" $D/$p.tb.txt | grep -v "^$" | tr -d '\r')
  lk=$(grep -o "LOCK [A-Z]*" $D/$p.tb.txt | head -1)
  # floppy: boot sector (image sector count at 1FCh) + the image, padded to 1.44 MB
  ns=$(( ($(stat -c %s $D/$p.com) + 511) / 512 ))
  cp $D/boot.bin $D/$p.img
  printf "$(printf '\\x%02x\\x%02x' $((ns & 255)) $((ns >> 8)))" | dd of=$D/$p.img bs=1 seek=508 conv=notrunc status=none
  dd if=$D/$p.com of=$D/$p.img bs=512 seek=1 conv=notrunc,sync status=none
  truncate -s 1474560 $D/$p.img
  cat > $D/$p.bxrc <<EOF
megs: 16
romimage: file=$BIOS/BIOS-bochs-latest
vgaromimage: file=$BIOS/VGABIOS-lgpl/VGABIOS-lgpl-latest.bin
floppya: 1_44=$D/$p.img, status=inserted
boot: floppy
floppy_bootsig_check: disabled=0
clock: sync=none, time0=1
port_e9_hack: enabled=1
display_library: nogui
log: $D/$p.bx.log
panic: action=fatal
error: action=report
info: action=ignore
debug: action=ignore
EOF
  timeout 60 $BX -q -f $D/$p.bxrc > $D/$p.bx.out 2>&1
  # (port E9h text: the probe's line; the BIOS prints nothing there)
  bx=$(tr -d '\r' < $D/$p.bx.out | grep -a "^$p" | head -5)
  # a probe's '# bochs-expect: <line>': Bochs differs there on purpose (its own model choice)
  ex=$(sed -n 's/^# bochs-expect: //p' tests/probe/$p.s)
  bxt=$(echo "$bx" | sed 's/ *$//')
  if [ "$lk" != "LOCK OK" ]; then echo "$p: LOCKSTEP FAILED ($lk, $D/$p.tb.txt)"
  elif [ -n "$tb" ] && [ "$tb" = "$bx" ] && [ -z "$ex" ]; then same=$((same + 1)); echo "$p: same ($lk)"; echo "  $tb"
  elif [ -n "$tb" ] && [ -n "$ex" ] && [ "$bxt" = "$ex" ]; then same=$((same + 1)); echo "$p: known Bochs difference ($lk)"
    echo "  core/86Box: $tb"; echo "  Bochs:      $bx"
  else echo "$p: DIFFERENT ($lk)"; echo "  core/86Box: ${tb:-<none>}"; echo "  Bochs:      ${bx:-<none> (see $D/$p.bx.out, $D/$p.bx.log)}"; fi
done
echo "probes OK (same, or a known Bochs difference): $same / $n"
