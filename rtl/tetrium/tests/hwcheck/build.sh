#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Bootable CPU check image (see README.md).
# usage: tests/hwcheck/build.sh    -> build/hwcheck/hwcheck.vhd (boot disk), hwcheck.com (lockstep testbench)
set -e
cd "$(dirname "$0")"
S=$PWD
B=../../build/hwcheck
mkdir -p $B
cd $B
sed 's/^NSECT = .*/NSECT = 128/' $S/../hwstress/mbr.s > mbr.s
as --32 -o mbr.o mbr.s
ld -m elf_i386 -Ttext=0x7C00 -e _start -o mbr.elf mbr.o
objcopy -O binary mbr.elf mbr.bin
as --32 -o entry.o $S/entry.s
CF="-m32 -march=i486 -Os -ffreestanding -fno-pic -fno-pie -mgeneral-regs-only -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin -fno-delete-null-pointer-checks -fno-jump-tables -Wno-array-bounds -Wall -Wno-unused-function"
O=""
for f in kern fuzz acc seg task vm soc libc; do
  gcc $CF -c -o $f.o $S/$f.c
  O="$O $f.o"
done
ld -m elf_i386 -T $S/link.ld -o hwcheck.elf entry.o $O
objcopy -O binary -R .bss hwcheck.elf hwcheck.com
N=$(stat -c %s hwcheck.com)
BE=$(nm hwcheck.elf | awk '/ __bss_end$/ {print $1}')
echo "image $N bytes, bss end $BE"
[ $N -le 65536 ] || { echo "image > 64 KB"; exit 1; }
[ $((0x$BE)) -le $((0xC0030000)) ] || { echo "bss past C0030000"; exit 1; }
python3 - <<'PY'
img = bytearray(8 << 20)
img[0:512] = open('mbr.bin', 'rb').read()
d = open('hwcheck.com', 'rb').read()
img[512: 512 + len(d)] = d
img[8192 * 512: 8192 * 512 + 8] = b'HWCKSCR!'     # scratch sectors (IDE write tests): LBA 8192 on
open('hwcheck.vhd', 'wb').write(img)
PY
