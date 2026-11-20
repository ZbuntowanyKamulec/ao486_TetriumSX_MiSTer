# hwstress

A bootable, self-checking stress test for a PC built around the CPU. Random workloads run in
five environments. Each runs once without interrupts as the reference, then repeatedly under
interrupt and paging stress; every stressed run must match the reference bit for bit.

## Build and run

```
tests/hwstress/build.sh [wlseed]                 # -> build/hwstress/hwstress.vhd (8 MB raw disk)
tests/hwstress/cfg.py build/hwstress/hwstress.vhd [seed=N] [tests=MASK] [first=N] ...
```

Boot the image as the first hard disk (the settings are listed at the top of `cfg.py`). The
system needs 8259 PICs, an 8254 PIT, an RTC with the periodic interrupt, a primary IDE
channel (PIO), VGA text mode and a BIOS with INT 13h. Ports E0-E7h and 2E0-2E7h must be
unmapped. The console is also written to port E9h.

## Environments

| mode | |
|------|-|
| V86  | 16-bit code under a V86 monitor with IOPL 0 (CLI/STI, PUSHF/POPF, INT n, IRET trap and are emulated; IRQs reflected through the IVT) |
| R3   | flat 32-bit ring 3: INT 30h system calls, a call gate to ring 0, task switches, LAR/LSL/VERR/VERW |
| R0   | the same 32-bit code at ring 0 |
| P16  | the 16-bit code in 16-bit protected mode at ring 3 (GDT + LDT selectors, CLI/STI emulated) |
| RM   | the 16-bit code in real mode (PE and PG switched off and back per run) |

The workloads mix integer, string, stack, segment, far-transfer and 486 instructions, and also
fault on purpose (#DE #UD #BR #GP #SS #NM, INT3, INTO), do port I/O through the I/O permission
bitmap (a virtual device), modify their own code and, in some seeds, run with TF set.

## Stress

Per pass, drawn at random: PIT and RTC interrupt rates; page stealing (an IRQ clears the
present bit of a workload page, the #PF handler restores it); A/D bits cleared; CR3 reloads;
WBINVD; IDE sector reads in the IRQ handler, checked against a copy of the disk taken at boot.

## Reports

The kernel stops with a red report on a **MISMATCH** (registers, flags, segments, counts and
the first differing memory dwords), an **unexpected exception** (full frame and code bytes), a
**HANG** (a pass over 8 s) or an **IDE** data error. Each report includes the last IRQ points
and #PF addresses. The software side of a pass is deterministic: `seed / pass / test` from the
report and `cfg.py seed=... tests=... first=...` restart there. Interrupt timing depends on the
system, so a report may need several runs to reproduce.

Not covered: DMA, IDT task gates, debug registers, alignment check.
