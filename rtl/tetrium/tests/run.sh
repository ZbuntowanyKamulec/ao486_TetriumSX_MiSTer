#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
# Run test suites in one go: builds the simulator, runs the selected suites, keeps a log per
# suite in the output directory and prints one result line per suite, then a summary.
# Exit status 0 when every suite passed (known, documented failures count as passed).
#
# usage: tests/run.sh [options] [suite | preset ...]          (default: quick)
#   presets   quick   sst pm lock irq smc rand clocks                  (~10 min with 16 cores)
#             full    every suite, larger random and DMA runs           (hours)
#   suites    sst      SingleStepTests/80386, real mode (make test)
#             test386  test386.asm in lockstep (one simulation, ~25 min: runs alongside the others)
#             pm       protected-mode / paging directed tests (tests/pm)
#             lock     benchmarks and directed real-mode programs in lockstep
#             irq      interrupt regression          smc   self-modifying code
#             dma      DMA snoop test                cbench  C benchmarks (self-checking)
#             hwcheck  the hwcheck machine test under the lockstep testbench
#             rand     random programs in lockstep, every mode (tests/rlock.sh)
#             clocks   instruction forms against the i486 clock counts
#             probe    486 behaviour probes, core against Bochs (tests/probe.sh; ref/bochs)
#             configs  build variants (bus width, caches, TLBs, CPUID) with pm + random sets
#   options   -j N     parallel jobs (default: CPU count)
#             -n N     random programs per mode (quick 16, full 256)
#             -w BW    bus width of the main build: 16, 32, 64, 128 (default 32)
#             -o DIR   output directory (default build/run)
#             -l       list the suites and presets
set -u
cd "$(dirname "$0")/.."
JOBS=$(nproc); NPROG=""; BW=""; OUT=build/run; PRESET=quick
usage() { sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'; }
while getopts "j:n:w:o:lh" o; do
  case $o in
    j) JOBS=$OPTARG ;; n) NPROG=$OPTARG ;; w) BW=$OPTARG ;; o) OUT=$OPTARG ;;
    l|h) usage; exit 0 ;; *) usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
QUICK="sst pm lock irq smc rand clocks"
ALL="sst test386 pm lock irq smc dma cbench hwcheck rand clocks probe configs"
SUITES=()
for a in "${@:-quick}"; do
  case $a in
    quick) SUITES+=($QUICK) ;;
    full)  PRESET=full; SUITES+=($ALL) ;;
    *) [[ " $ALL " == *" $a "* ]] || { echo "unknown suite: $a (tests/run.sh -l)"; exit 2; }
       SUITES+=($a) ;;
  esac
done
[ -z "$NPROG" ] && { [ $PRESET = full ] && NPROG=256 || NPROG=16; }
mkdir -p "$OUT"
SUM=$OUT/summary.txt; : > "$SUM"
FAILED=0
if [ -n "$BW" ]; then SIM=build/sim_w$BW/Vtetrium_core; MK="BW=$BW"; else SIM=build/sim/Vtetrium_core; MK=""; fi
export SIM

# one result line: suite, PASS / FAIL, detail, seconds
result() {
  local s=$1 st=$2 d=$3 t=$4
  [ "$st" = PASS ] || FAILED=$((FAILED + 1))
  printf '%-9s %-4s %5ss  %s\n' "$s" "$st" "$t" "$d" | tee -a "$SUM"
}
# "a / b" counts: PASS when a == b and b > 0
ratio() { [ -n "$1" ] && [ "$1" = "$2" ] && [ "$2" != 0 ] && echo PASS || echo FAIL; }

echo "building the simulator (make sim $MK)"
make -s sim $MK > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "build FAILED"; exit 1; }

# random lockstep modes: name and rlock.sh environment
RMODES=(
  "rl|" "rlirq|IRQ=1" "rlnmi|NMI=1" "rlv86|V86=1" "rlv86irq|V86=1 IRQ=1" "rlv86irqnmi|V86=1 IRQ=1 NMI=1"
  "rlpm|PM=1" "rlpmirq|PM=1 IRQ=1" "rlpmirqnmi|PM=1 IRQ=1 NMI=1" "rlpmd|PM=1 D32=1" "rlpmdirq|PM=1 D32=1 IRQ=1"
  "rlpmr3|PM=1 R3=1" "rlpmr3irq|PM=1 R3=1 IRQ=1" "rlpmr3irqnmi|PM=1 R3=1 IRQ=1 NMI=1"
  "rlpmdr3|PM=1 D32=1 R3=1" "rlpmdr3irq|PM=1 D32=1 R3=1 IRQ=1"
  "rlpmring1|PM=1 RING=1" "rlpmring2irq|PM=1 RING=2 IRQ=1"
  "rlpg|PG=1" "rlpgirq|PG=1 IRQ=1" "rlpgd|PG=1 D32=1" "rlpgdirq|PG=1 D32=1 IRQ=1" "rlpgdnmi|PG=1 D32=1 NMI=1"
  "rlpgr3|PG=1 R3=1" "rlpgr3irq|PG=1 R3=1 IRQ=1" "rlpgr3irqnmi|PG=1 R3=1 IRQ=1 NMI=1"
  "rlpgdr3|PG=1 D32=1 R3=1" "rlpgdr3irq|PG=1 D32=1 R3=1 IRQ=1"
  "rlpgring1d32|PG=1 RING=1 D32=1" "rlpgring1nmi|PG=1 RING=1 NMI=1" "rlpgring2|PG=1 RING=2"
  "rlpgring2d32nmi|PG=1 RING=2 D32=1 NMI=1"
  "rlpgv86|PG=1 V86=1" "rlpgv86irq|PG=1 V86=1 IRQ=1" "rlpgv86nmi|PG=1 V86=1 NMI=1" "rlpgv86irqnmi|PG=1 V86=1 IRQ=1 NMI=1"
)
# quick: one mode per area
RQUICK="rl rlv86irq rlpmdr3irq rlpmring2irq rlpgdirq rlpgr3irqnmi rlpgv86irqnmi"
# random sets of one simulator: run_rand <sim> <dir> <nprog> <mode names>; prints "ok tot fails"
run_rand() {
  local sim=$1 d=$2 n=$3; shift 3
  local ok=0 tot=0 bad=""
  mkdir -p "$d"
  for m in "${RMODES[@]}"; do
    local name=${m%%|*} env=${m#*|}
    [[ " $* " == *" $name "* ]] || continue
    env $env SIM=$sim ROUT=$d/$name RLOG=$d/$name.log TMO=600 tests/rlock.sh "$n" 1 3000 "$JOBS" > /dev/null 2>&1
    local k; k=$(grep -c "LOCK OK" "$d/$name.log" 2>/dev/null); k=${k:-0}
    ok=$((ok + k)); tot=$((tot + n))
    [ "$k" = "$n" ] || bad="$bad $name:$k/$n"
  done
  echo "$ok $tot$bad"
}
# pm directed tests, one test per job: run_pm <sim> <dir> [tests left out]; prints "ok tot"
run_pm() {
  local sim=$1 d=$2 skip=" ${3:-} "
  mkdir -p "$d"
  for t in tests/pm/pm*.s; do b=$(basename $t .s); [[ "$skip" == *" $b "* ]] || echo $t; done | xargs -P "$JOBS" -I{} sh -c "SIM=$sim PMD=$d tests/pm.sh {}" | sort > "$d/pm.txt"
  echo "$(grep -c 'LOCK OK' "$d/pm.txt") $(wc -l < "$d/pm.txt")"
}

suite_sst() {
  make -s test $MK ARGS="" > "$OUT/sst.log" 2>&1
  local l; l=$(grep "files passed" "$OUT/sst.log")
  # known: 67 0F A4 / A5 / AC / AD (SHLD / SHRD with a 32-bit address: the 386EX's undefined flags)
  local other; other=$(grep -E "FAIL|TIMEOUT|LOADERR" "$OUT/sst.log" | grep -v "files passed" | grep -vE "^670F(A4|A5|AC|AD) ")
  if [ -n "$l" ] && [ -z "$other" ]; then echo "PASS|$l (known: 670FA4/A5/AC/AD)"; else echo "FAIL|$l $(echo $other | cut -c1-120)"; fi
}
suite_test386() {
  tests/test386.sh p4 "$SIM" > "$OUT/test386.log" 2>&1
  if grep -q "match the reference" "$OUT/test386.log" && grep -q "LOCK OK" "$OUT/test386.log"; then echo "PASS|POST EE results match, lockstep OK"
  else echo "FAIL|$(grep -E "LOCK|POST EE" "$OUT/test386.log" | tail -2 | tr '\n' ' ' | cut -c1-150)"; fi
}
suite_pm() {
  local r; r=($(run_pm "$SIM" "$OUT/pm")); cp "$OUT/pm/pm.txt" "$OUT/pm.log"
  echo "$(ratio ${r[0]} ${r[1]})|${r[0]} / ${r[1]} lockstep runs OK"
}
suite_lock()   { tests/lock.sh "$JOBS" > "$OUT/lock.log" 2>&1; local a; a=$(grep -oE "OK: [0-9]+ / [0-9]+" "$OUT/lock.log" | grep -oE "[0-9]+"); a=($a); echo "$(ratio ${a[0]:-} ${a[1]:-})|lockstep ${a[0]:-?} / ${a[1]:-?}"; }
suite_irq()    { tests/irq.sh > "$OUT/irq.log" 2>&1; local a; a=($(grep -oE "OK: [0-9]+ / [0-9]+" "$OUT/irq.log" | grep -oE "[0-9]+")); echo "$(ratio ${a[0]:-} ${a[1]:-})|${a[0]:-?} / ${a[1]:-?} runs"; }
suite_smc()    { tests/smc.sh > "$OUT/smc.log" 2>&1; local a; a=($(grep -oE "OK: [0-9]+ / [0-9]+" "$OUT/smc.log" | grep -oE "[0-9]+")); echo "$(ratio ${a[0]:-} ${a[1]:-})|${a[0]:-?} / ${a[1]:-?} runs"; }
suite_cbench() { tests/cbench.sh > "$OUT/cbench.log" 2>&1; local a; a=($(grep -oE "OK: [0-9]+ / [0-9]+" "$OUT/cbench.log" | grep -oE "[0-9]+")); echo "$(ratio ${a[0]:-} ${a[1]:-})|${a[0]:-?} / ${a[1]:-?} programs"; }
suite_dma() {
  local ns=4; [ $PRESET = full ] && ns=8
  DMAD=$OUT/dma tests/dma.sh $ns "$JOBS" > "$OUT/dma.log" 2>&1
  local a; a=($(grep -oE "OK: [0-9]+ / [0-9]+" "$OUT/dma.log" | grep -oE "[0-9]+")); echo "$(ratio ${a[0]:-} ${a[1]:-})|${a[0]:-?} / ${a[1]:-?} runs"
}
suite_hwcheck() {
  local ns=8; [ $PRESET = full ] && ns=16
  tests/hwcheck/lock.sh 1 $ns 319 "$JOBS" > "$OUT/hwcheck.log" 2>&1
  local a; a=($(grep -oE "OK: [0-9]+ / [0-9]+" "$OUT/hwcheck.log" | grep -oE "[0-9]+")); echo "$(ratio ${a[0]:-} ${a[1]:-})|${a[0]:-?} / ${a[1]:-?} seeds"
}
suite_rand() {
  local names=""
  if [ $PRESET = full ]; then for m in "${RMODES[@]}"; do names="$names ${m%%|*}"; done; else names=$RQUICK; fi
  local r; r=($(run_rand "$SIM" "$OUT/rand" "$NPROG" $names))
  cat "$OUT"/rand/*.log > "$OUT/rand.log"
  echo "$(ratio ${r[0]} ${r[1]})|${r[0]} / ${r[1]} programs in $(echo $names | wc -w) modes${r[2]:+, failing:} ${r[*]:2}"
}
suite_clocks() {
  python3 tests/clocks.py > "$OUT/clocks.log" 2>&1
  local l; l=$(grep "clock parity" "$OUT/clocks.log")
  # known: XCHG with memory and LOCK read-modify-write take the locked bus cycles (README)
  local other; other=$(grep VIOLATION "$OUT/clocks.log" | grep -vE "^(xchg \[m\], r16|lock add \[m\], r16) ")
  local nb; nb=$(grep -c VIOLATION "$OUT/clocks.log")
  if [ -n "$l" ] && [ -z "$other" ]; then echo "PASS|$(echo "$l" | grep -oE "[0-9]+ / [0-9]+") forms within i486 clocks, $nb known over (xchg [m], lock add [m])"
  else echo "FAIL|${l:-no result} $(echo $other | cut -c1-120)"; fi
}
suite_probe() {
  tests/probe.sh > "$OUT/probe.log" 2>&1
  local a; a=($(grep -oE "OK \(same, or a known Bochs difference\): [0-9]+ / [0-9]+" "$OUT/probe.log" | grep -oE "[0-9]+"))
  echo "$(ratio ${a[0]:-} ${a[1]:-})|${a[0]:-?} / ${a[1]:-?} probes agree with Bochs"
}
# build variants: name, defines, pm tests left out (the default build is the main one)
# (pm32 / pm33 run CPUID in every mode as one of the instruction forms covered)
CONFIGS=(
  "w16|BUS_DW=16" "w64|BUS_DW=64" "w128|BUS_DW=128" "nocpuid|HAS_CPUID=0|pm32 pm33"
  "csm|IC_KB=4 IC_WAYS=1 DC_KB=8 DC_WAYS=2 LINE_B=16" "cmix|IC_KB=8 IC_WAYS=2 DC_KB=4 DC_WAYS=1"
  "tfa|UT_SB=0 UT_WAYS=4 FUT_SB=1 L2TLB_AB=0" "tmid|UT_SB=2 UT_WAYS=2 FUT_SB=2 L2TLB_AB=8 L2TLB_WAYS=2"
  "w16csm|BUS_DW=16 LINE_B=16 DC_WAYS=1 DC_KB=4"
)
suite_configs() {
  local fail="" n=0 nok=0 cn=16; [ $PRESET = full ] && cn=64
  : > "$OUT/configs.log"
  for c in "${CONFIGS[@]}"; do
    local name=${c%%|*} rest=${c#*|} vd=""
    local defs=${rest%%|*} skip=""; [[ "$rest" == *"|"* ]] && skip=${rest#*|}
    for x in $defs; do vd="$vd -D$x -CFLAGS -D$x"; done
    n=$((n + 1))
    rm -f build/var_cfg_$name/Vtetrium_core
    if ! make -s simvar V=cfg_$name VDEF="$vd" > "$OUT/configs_$name.build.log" 2>&1; then
      echo "$name: build FAILED" >> "$OUT/configs.log"; fail="$fail $name(build)"; continue
    fi
    local b=build/var_cfg_$name/Vtetrium_core d=$OUT/configs/$name
    local p; p=($(run_pm "$b" "$d" "$skip"))
    local r; r=($(run_rand "$b" "$d" $cn rl rlpgd rlpgv86irq rlpmr3irqnmi rlpgring2d32nmi))
    echo "$name ($defs${skip:+; without $skip}): pm ${p[0]} / ${p[1]}, random ${r[0]} / ${r[1]} ${r[*]:2}" >> "$OUT/configs.log"
    if [ "${p[0]}" = "${p[1]}" ] && [ "${r[0]}" = "${r[1]}" ]; then nok=$((nok + 1)); else fail="$fail $name"; fi
  done
  [ -z "$fail" ] && echo "PASS|$nok / $n builds pass pm + random sets" || echo "FAIL|$nok / $n builds pass; failing:$fail"
}
# test386 is one long simulation: started first, in the background, collected at the end
T386=0
if [[ " ${SUITES[*]} " == *" test386 "* ]]; then
  T386=1; t0=$SECONDS
  ( r=$(suite_test386); echo "$r|$((SECONDS - t0))" > "$OUT/.test386.res" ) &
  T386PID=$!
fi
echo "suites: ${SUITES[*]}   (logs in $OUT/)"
for s in "${SUITES[@]}"; do
  [ $s = test386 ] && continue
  t0=$SECONDS
  r=$(suite_$s)
  result $s "${r%%|*}" "${r#*|}" $((SECONDS - t0))
done
if [ $T386 = 1 ]; then
  wait $T386PID
  IFS='|' read -r st d t < "$OUT/.test386.res"
  result test386 "$st" "$d" "$t"
fi
echo "----"
[ $FAILED = 0 ] && echo "ALL PASSED (${#SUITES[@]} suites)" | tee -a "$SUM" || echo "$FAILED suite(s) FAILED" | tee -a "$SUM"
[ $FAILED = 0 ]
