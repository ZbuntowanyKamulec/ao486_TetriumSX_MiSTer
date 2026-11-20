#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Build the 86Box interpreter as build/x86ref/libx86ref.a (see x86ref.h).
# usage: tb/x86ref/build.sh [jobs]
set -e
cd "$(dirname "$0")/../.."
JOBS=${1:-16}
S=ref/86box/src
H=tb/x86ref
O=build/x86ref
mkdir -p $O/obj
# 86Box changes towards a real 486 (see the patch): applied once
PT=$(pwd)/$H/86box-486.patch
if ! git -C ref/86box apply --reverse --check "$PT" 2>/dev/null; then
  git -C ref/86box apply "$PT" || { echo "86box-486.patch does not apply"; exit 1; }
fi
INC="-I$H/inc -I$H -I$S/include -I$S/cpu -I$S/codegen -I$S -I$S/cpu/softfloat3e"
CF="-O2 -g -w -fPIC $INC"
SRCS="$S/cpu/386_dynarec.c $S/cpu/386.c $S/cpu/386_common.c $S/cpu/x86seg.c $S/cpu/x86seg_2386.c
      $S/cpu/x86seg_common.c $S/cpu/x86.c $S/cpu/cpu.c $S/cpu/cpu_table.c $S/cpu/x87.c $S/cpu/fpu.c
      $S/cpu/x87_timings.c $S/cpu/x87_ferr.c $S/mem/mem.c $S/mem/mmu_2386.c
      $(ls $S/cpu/softfloat3e/*.c $S/cpu/softfloat3e/*.cc) $H/x86ref.c $H/stubs.c"
# (rebuilt when its source or any header is newer)
NH=$(ls -t $S/cpu/*.h $S/mem/*.h $S/include/86box/*.h $H/*.h $H/inc/*.h $H/inc/*/*.h 2>/dev/null | head -1)
build_one() {
  f=$1; o=$O/obj/$(echo "$f" | tr '/' '_' | sed 's/\.cc\?$/.o/')
  [ "$o" -nt "$f" ] && [ "$o" -nt "$NH" ] && return 0
  case $f in *.cc) g++ -c $CF -o "$o" "$f";; *) gcc -c $CF -o "$o" "$f";; esac || { echo "FAIL $f"; return 1; }
}
export -f build_one; export O H CF NH
echo $SRCS | tr ' ' '\n' | grep . | xargs -P "$JOBS" -I{} bash -c 'build_one {}'
rm -f $O/libx86ref.a
ar rcs $O/libx86ref.a $O/obj/*.o
echo "x86ref: $O/libx86ref.a ($(ls $O/obj/*.o | wc -l) objects)"
