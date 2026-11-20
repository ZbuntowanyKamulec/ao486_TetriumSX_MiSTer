#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
#
# Verilator simulation of the SoC (rtl/system.v with Tetrium), SDL window for the VGA output.
# usage: sim/tetrium/build.sh [threads]        -> build/sim/Vsoc_sim (default 1 thread)
#        WIN=1 sim/tetrium/build.sh [threads]  -> build/winsim/Vsoc_sim.exe (MinGW cross build,
#                                                 SDL2 MinGW devel package in build/winsim/dl)
#        SIMO=<dir>: another output directory
# Needs Verilator 5 (built and tested with 5.020) and SDL2.
set -e
cd "$(dirname "$0")/../.."
TH=${1:-1}
[ -n "$WIN" ] && TH=${1:-2}   # fastest: Linux 1 thread, MinGW 2 (more threads only add sync per eval)
A=rtl
T=rtl/tetrium/rtl
S=sim/tetrium
O=build/sim
[ -n "$WIN" ] && O=build/winsim
O=${SIMO:-$O}
mkdir -p $O
UCODE=$(realpath $T/gen/ucode_rom.hex)
[ -n "$WIN" ] && UCODE=ucode_rom.hex   # read at run time from the working directory
CORE="$T/gen/tetrium_pkg.sv $T/tetrium_prims.sv $T/tetrium_fetch.sv $T/tetrium_decode.sv
      $T/tetrium_agu.sv $T/tetrium_mem.sv $T/tetrium_exec.sv $T/tetrium_wb.sv
      $T/tetrium_biu.sv $T/tetrium_core.sv $T/tetrium_mmu.sv $T/tetrium_top.sv"
# sim copies of SoC sources (see simfix.py)
python3 $S/simfix.py $A/system.v $O/system_sim.v > /dev/null
python3 $S/simfix.py $A/soc/vga.v $O/vga_sim.v ce_video > /dev/null
python3 $S/simfix.py $A/soc/rtc.v $O/rtc_sim.v ce_800hz ce_8192hz > /dev/null
python3 $S/simfix.py $A/soc/joystick.v $O/joystick_sim.v clk_grav tick_1100ns > /dev/null
SOC="$O/system_sim.v $A/soc/iobus.v $A/soc/floppy.v $A/soc/ide.v $O/joystick_sim.v $A/soc/dma.v
     $A/soc/pic.v $A/soc/pit.v $A/soc/pit_counter.v $A/soc/ps2.v $O/rtc_sim.v $O/vga_sim.v
     $A/common/simple_fifo.v $A/common/simple_ram.v"
# MiSTer's PS/2 device (sys/hps_io.sv) on its own
awk '/^module ps2_device/,/^endmodule/' sys/hps_io.sv > $O/ps2_device.sv
SIMF="$S/simlib.sv $S/stubs.v $O/ps2_device.sv $S/soc_sim.sv"
if [ -n "$WIN" ]; then
  SDL=build/winsim/dl/SDL2-2.30.9/x86_64-w64-mingw32
  [ -d $SDL ] || { echo "missing $SDL (SDL2-devel-2.30.9-mingw.tar.gz)"; exit 1; }
  SDL=$(realpath $SDL)
  SDLC="-I$SDL/include -Dmain=SDL_main -D_FILE_OFFSET_BITS=64"
  SDLL="-static -L$SDL/lib -lmingw32 -lSDL2main -lSDL2 -lm -lkernel32 -luser32 -lgdi32 -lwinmm -limm32 -lole32 -loleaut32 -lversion -luuid -ladvapi32 -lsetupapi -lshell32 -ldinput8"
  BUILD=""
else
  SDLC="$(sdl2-config --cflags)"; SDLL="$(sdl2-config --libs)"; BUILD="--build -j 16 -MAKEFLAGS OPT_FAST=${OPT_FAST:--Os}"
fi
# -fno-reorder: Verilator 5.020 statement reordering miscompiles the CPU's decoder
verilator --cc --exe $BUILD -O3 -fno-reorder --threads $TH --savable \
  -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN \
  -Wno-PINMISSING -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-COMBDLY -Wno-UNOPTFLAT -Wno-IMPLICIT \
  -I$T/gen -I$T -I$A/soc -I$A/common -DSIM -DBUS_DW=64 "-DUCODE_FILE=\"$UCODE\"" \
  --top-module soc_sim --x-assign fast --x-initial fast \
  -CFLAGS "-O2 $SDLC" -LDFLAGS "$SDLL" \
  --Mdir $O $CORE rtl/tetrium_ao486.sv rtl/cache/l2_cache.v $SOC $SIMF \
  $(realpath $S/tb_soc.cpp) $(realpath $S/ide_hps.cpp) > $O/build.log 2>&1 \
  || { grep -E "%Error" $O/build.log | head -30; tail -5 $O/build.log; exit 1; }
if [ -n "$WIN" ]; then
  M=x86_64-w64-mingw32
  make -C $O -j 16 -f Vsoc_sim.mk CXX=$M-g++-posix LINK=$M-g++-posix AR=$M-ar \
    OPT_FAST=${OPT_FAST:--O2} OPT_SLOW=-O1 >> $O/build.log 2>&1 \
    || { grep -E "error" $O/build.log | head -30; tail -5 $O/build.log; exit 1; }
  mv -f $O/Vsoc_sim $O/Vsoc_sim.exe 2>/dev/null || true
  ls -la $O/Vsoc_sim.exe; exit 0
fi
grep -E "%Warning" $O/build.log | grep -vE "DECLFILENAME|PINCONNECTEMPTY" | head -10 || true
ls -la $O/Vsoc_sim
