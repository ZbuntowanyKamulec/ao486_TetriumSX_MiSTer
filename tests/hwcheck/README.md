# hwcheck

A bootable, self-checking CPU test for a PC built around the CPU. It covers what `hwstress`
does not: random programs generated on the machine itself, and the rules of protected mode,
paging, debug registers and task switches against software models.

## Build and run

```
tests/hwcheck/build.sh                                   # -> build/hwcheck/hwcheck.vhd (8 MB raw disk), hwcheck.com
tests/hwcheck/cfg.py build/hwcheck/hwcheck.vhd [seed=N] [suites=MASK] [stop=N] ...
tests/hwcheck/logread.py build/hwcheck/hwcheck.vhd       # the failures, as saved on the disk
```

Boot `hwcheck.vhd` as the first hard disk. It runs round after round (a new seed each) and never
stops on a failure, only on a hang or an unexpected exception. The screen shows each suite's
rounds and failures. The text also goes to port E9h and to scratch sectors of the image (LBA 8320
on; the IDE tests write to LBA 8192 on). Both are written only if the disk has the image's
signature.

## Suites

| bit | suite | |
|---|---|---|
| 0 | fuzz | random programs (any opcode, ModR/M, prefix and 32-bit address) in flat 32-bit ring 3, 16-bit protected mode and V86. Each runs plainly, single-stepped with every page stolen again after each instruction, with only a few pages present, and under interrupts, and must give the same registers, flags, memory, faults and A / D bits |
| 1 | acc | 117 instruction forms: each of their accesses against page protection (restart included), the alignment check, data breakpoints and segment limits |
| 2 | seg | segment loads, far transfers, LAR / LSL / VERR / VERW with random descriptors |
| 3 | xfer | call gates, interrupt gates, stack switches, returns |
| 4 | task | task switches, task gates (also for #GP and #DF), faults of a switch |
| 5 | vm | four address spaces remapped, protected and copied on write at random; code through aliases |
| 6 | irq | the instruction at which a pending interrupt is taken |
| 7 | soc | the CPU against the machine: RAM, cache control, A20, VGA memory writes in order with OUTs, IDE transfers that page-fault in the middle |
| 8 | unreal | real mode with 4 GB segments |

`off=` bits: 100h no RAM test, 200h no cache control, 400h no A20, 800h no VGA, 1000h no IDE,
2000h no log on the disk.

## Before hardware

The same kernel runs without devices (`tb=1`, suites 0-5 and 8):

```
tests/hwcheck/lock.sh [first] [last]     # RTL in lockstep with 86Box
build/hwcheck/ref_run -conat 90000 ...   # the 86Box interpreter alone (much faster; built by lock.sh)
```

Suites 5-8 also pass on stock 86Box (interpreter). It differs from a 486 in what the others check
(segment limits of some stack accesses, RF of fault frames, instruction bytes read ahead).

Not covered: DMA, the FPU, NMI, shutdown.
