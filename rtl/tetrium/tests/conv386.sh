#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Convert the SingleStepTests/80386 real-mode suite into tests/bin/*.bin
# usage: tests/conv386.sh [tests per file (default 500)] [jobs]
cd "$(dirname "$0")/.."
N=${1:-500}
JOBS=${2:-16}
mkdir -p tests/bin
ls ref/tests386/v1_ex_real_mode/*.MOO.gz | xargs -P "$JOBS" -I{} sh -c \
  'python3 -I tests/conv386.py "$1" "tests/bin/$(basename "$1" .MOO.gz).bin" '"$N" _ {}
echo "converted: $(ls tests/bin/*.bin | wc -l) files, $(du -sh tests/bin | cut -f1)"
