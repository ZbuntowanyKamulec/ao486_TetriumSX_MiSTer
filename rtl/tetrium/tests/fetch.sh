#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Fetch the external sources the tests use into ref/ (not part of this repository):
#   ref/86box     86Box, the lockstep reference model (tb/x86ref/build.sh patches and builds it)
#   ref/test386   test386.asm (tests/test386.sh)
#   ref/tests386  SingleStepTests/80386, real-mode set (tests/conv386.sh, make test)
set -e
cd "$(dirname "$0")/.."
mkdir -p ref
get() {   # dir url commit [sparse-checkout dirs]
  if [ -e "ref/$1" ]; then echo "ref/$1: present"; return; fi
  git clone -q --filter=blob:none --no-checkout "$2" "ref/$1"
  [ -n "$4" ] && git -C "ref/$1" sparse-checkout set $4
  git -C "ref/$1" checkout -q "$3"
  echo "ref/$1: $3"
}
get 86box    https://github.com/86Box/86Box         7b2dbc034dd60b931faa0d42ec318dcccc8c86ac
get test386  https://github.com/barotto/test386.asm cfd052d1e64d5375dea5a681c1eadeed64ceda2c
get tests386 https://github.com/SingleStepTests/80386 459d49f v1_ex_real_mode
