# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Tetrium build / test
#   make ucode        regenerate the microcode ROM + package (ucode/ucgen.py)
#   make sim          build the Verilator testbench (with the 86Box lockstep model)
#   make test         run the SingleStepTests/80386 real-mode suite (tests/conv386.sh first)
#   make test T="00 01 F6.6"   selected opcode files
#   make lint
#   BW=16/32/64/128   Wishbone data width (separate build directories)
JOBS   ?= 16
P       = tetrium
R       = rtl
ifneq ($(BW),)
SIMD    = build/sim_w$(BW)
DBGD    = build/simdbg_w$(BW)
BWFLAGS = -DBUS_DW=$(BW) -CFLAGS -DBUS_DW=$(BW)
else
SIMD    = build/sim
DBGD    = build/simdbg
endif
VARP    = build/var_
TLOG    = build/test.log
TESTS   = tests/bin
TB      = tb/tb_main.cpp
# lockstep reference model (86Box interpreter, ref/86box: tests/fetch.sh), testbench only
XREF    = build/x86ref/libx86ref.a
XFLAGS  = -CFLAGS -I$(abspath tb/x86ref) -LDFLAGS "$(abspath $(XREF)) -lm"
RTL     = $(R)/gen/$(P)_pkg.sv $(R)/$(P)_prims.sv $(R)/$(P)_fetch.sv $(R)/$(P)_decode.sv \
          $(R)/$(P)_agu.sv $(R)/$(P)_mem.sv $(R)/$(P)_exec.sv $(R)/$(P)_wb.sv \
          $(R)/$(P)_biu.sv $(R)/$(P)_core.sv $(R)/$(P)_mmu.sv
HDRS    = $(wildcard $(R)/*.svh)
UCODE   = $(abspath $(R)/gen/ucode_rom.hex)
# -fno-reorder: Verilator 5.020's statement reordering miscompiles the A-select
# registers in decode (found by the 86Box lockstep).  -O0 and -fno-reorder are correct.
VFLAGS  = --cc --exe --build -O3 -fno-reorder -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE \
          -I$(R)/gen -I$(R) -DSIM '-DUCODE_FILE="$(UCODE)"' --top-module $(P)_core \
          -CFLAGS -O2 --x-assign fast --x-initial fast $(XFLAGS) $(BWFLAGS)
BIN     = $(SIMD)/V$(P)_core
T      ?=

.PHONY: ucode sim simdbg simvar test lint clean

$(R)/gen/ucode_rom.hex $(R)/gen/$(P)_pkg.sv: ucode/ucgen.py
	python3 ucode/ucgen.py

ucode: $(R)/gen/ucode_rom.hex

$(BIN): $(RTL) $(HDRS) $(R)/gen/ucode_rom.hex $(TB) $(XREF)
	@mkdir -p $(SIMD)
	@rm -f $(BIN)        # (verilator --build does not track the library in LDFLAGS: relink)
	verilator $(VFLAGS) --Mdir $(SIMD) $(RTL) $(abspath $(TB)) > $(SIMD)/build.log 2>&1 || (tail -40 $(SIMD)/build.log; exit 1)
	@grep -E "%Warning|%Error" $(SIMD)/build.log | grep -v -E "DECLFILENAME|PINCONNECTEMPTY" | head -20 || true

sim: $(BIN)

$(XREF): $(wildcard tb/x86ref/*.c tb/x86ref/*.h tb/x86ref/*.patch)
	tb/x86ref/build.sh $(JOBS)

DBIN = $(DBGD)/V$(P)_core
$(DBIN): $(RTL) $(HDRS) $(R)/gen/ucode_rom.hex $(TB) $(XREF)
	@mkdir -p $(DBGD)
	verilator $(VFLAGS) --trace-fst -CFLAGS -DTRACE --Mdir $(DBGD) $(RTL) $(abspath $(TB)) > $(DBGD)/build.log 2>&1 || (tail -40 $(DBGD)/build.log; exit 1)

simdbg: $(DBIN)

# experiment builds: make simvar V=name VDEF="-DBTB_AW=9 -DBTB_BUBBLE"
simvar: $(RTL) $(R)/gen/ucode_rom.hex $(TB) $(XREF)
	@mkdir -p $(VARP)$(V)
	verilator $(VFLAGS) $(VDEF) --Mdir $(VARP)$(V) $(RTL) $(abspath $(TB)) > $(VARP)$(V)/build.log 2>&1 || (tail -20 $(VARP)$(V)/build.log; exit 1)

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -I$(R)/gen -I$(R) -DSIM --top-module $(P)_core $(RTL) 2>&1 | head -60

ifeq ($(T),)
TFILES = $(sort $(wildcard $(TESTS)/*.bin))
else
TFILES = $(addprefix $(TESTS)/,$(addsuffix .bin,$(T)))
endif

test: $(BIN)
	@printf '%s\n' $(TFILES) | xargs -P $(JOBS) -n 4 $(BIN) $(ARGS) | sort > $(TLOG); \
	 grep -c PASS $(TLOG) | xargs printf 'files passed: %s / '; grep -c -E "PASS|FAIL" $(TLOG); \
	 grep -E "FAIL|TIMEOUT|LOADERR" $(TLOG) | head -60 || true

clean:
	rm -rf build
