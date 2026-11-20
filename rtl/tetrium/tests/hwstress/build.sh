#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Bootable CPU stress image (see README.md).
# usage: tests/hwstress/build.sh [wlseed]    -> build/hwstress/hwstress.vhd
#   cfg.py patches the kernel configuration (start seed, test mask, passes, ...) in the image.
set -e
cd "$(dirname "$0")"
S=$PWD
B=../../build/hwstress
WLSEED=${1:-1}
mkdir -p $B
cd $B
python3 $S/gen.py . $WLSEED
as --32 -o mbr.o $S/mbr.s
ld -m elf_i386 -Ttext=0x7C00 -e _start -o mbr.elf mbr.o
objcopy -O binary mbr.elf mbr.bin
as --32 -o wl16.o wl16.s
ld -m elf_i386 -Ttext=0 -e _start -o wl16.elf wl16.o
objcopy -O binary wl16.elf wl16.bin
as --32 -o wl32.o wl32.s
ld -m elf_i386 -Ttext=0x30000 -e _start -o wl32.elf wl32.o
objcopy -O binary wl32.elf wl32.bin
as --32 -o entry.o $S/entry.s
CF="-m32 -march=i486 -O2 -ffreestanding -fno-pic -fno-pie -mgeneral-regs-only -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin -fno-delete-null-pointer-checks -Wno-array-bounds -Wall -Wno-unused-function"
gcc $CF -c -o kernel.o $S/kernel.c
gcc $CF -c -o libc.o $S/libc.c
ld -m elf_i386 -T $S/link.ld -o kernel.elf entry.o kernel.o libc.o
objcopy -O binary -R .bss kernel.elf kernel.bin
for f in mbr kernel wl16 wl32; do printf "%-7s %6d bytes\n" $f $(stat -c %s $f.bin); done
[ $(stat -c %s mbr.bin) = 512 ] || { echo "mbr is not 512 bytes"; exit 1; }
BE=$(nm kernel.elf | awk '/ __bss_end$/ {print $1}')
[ $((0x$BE)) -le $((0x20000)) ] || { echo "kernel + bss past 20000h ($BE)"; exit 1; }
for f in wl16 wl32; do [ $(stat -c %s $f.bin) -le 65536 ] || { echo "$f > 64 KB"; exit 1; }; done
python3 - <<'PY'
img = bytearray(8 << 20)                       # 8 MB raw disk
img[0:512] = open('mbr.bin', 'rb').read()
for name, sec in (('kernel', 1), ('wl16', 129), ('wl32', 257)):
    d = open(name + '.bin', 'rb').read()
    img[sec * 512: sec * 512 + len(d)] = d
open('hwstress.vhd', 'wb').write(img)
PY
nm kernel.elf | awk '/ cfg$/ {print "cfg at " $1}'
ls -la hwstress.vhd
