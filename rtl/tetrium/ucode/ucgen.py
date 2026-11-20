#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Microcode generator for the Tetrium core.

Produces:
  rtl/gen/tetrium_pkg.sv    field layout + enum constants (SystemVerilog package)
  rtl/gen/ucode_rom.hex     ROM image ($readmemh, UW_BITS wide, ROM_DEPTH deep)
  rtl/gen/ucode_class.svh   first-uop A-stage fields per opcode class (decoder tables)
  rtl/gen/modtab.svh        mod 9 / mod 17 tables (RCL / RCR counts)

Microcode model
---------------
Each macro instruction is one or more uops.  The ROM is indexed by a dispatch
index for the first uop of an instruction:
    normal opcode : {page (0F xx), opcode[7:0], mod3}                    (0..1023)
    group opcode  : 1024 + group*16 + reg*2 + mod3                       (1024..1135)
                    groups: F6 F7 FE FF 0F00 0F01 0FBA
    + 2048 in protected mode (CR0.PE and not VM; decode adds the bit): an
    instruction without a protected-mode sequence gets a copy of its real-mode
    first uop there (same successors)
Continuation uops live at 1136..2047 and 3184.. .  Undefined entries raise #UD.

The A stage (address generation) cannot use ROM outputs directly (BRAM clock
to out is too slow), so every uop word carries the A-stage fields of its
*successor* ("na_*").  The A-stage fields of the first uop come from
small LUT tables generated here (ucode_class.svh: per opcode class and group).
"""
import os, sys, copy

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'rtl', 'gen')
SPDX = '// SPDX-License-Identifier: GPL-3.0-or-later\n// Copyright (C) 2026 ZbuntowanyKamulec\n'

ROM_DEPTH = 2048
# protected-mode dispatch: the entries with their own sequence are placed like continuation
# code and found through pm_ent() (decoder table by dispatch index), the others use the
# real-mode entry (no second dispatch half)
UW_BITS = 88

# ---------------------------------------------------------------- enums
AMODE = ['NONE', 'EA', 'EA2', 'POP', 'POPN', 'SI', 'DI', 'VEC', 'VEC2', 'EAC', 'TA', 'TAS',
         'DSCR', 'DSCI', 'DSCT', 'IDT', 'TSS', 'LIN', 'TSSA']
#  EA   : modrm / moffs / xlat effective address, segment default/override
#  EA2  : same + operand size (the selector of a far pointer)
#  POP  : SS:SP, SP += operand size
#  POPN : SS:SP, SP += operand size + imm16   (RET n)
#  SI   : seg(DS/ovr):SI, SI += +-size
#  DI   : ES:DI, DI += +-size             (primary/load)
#  VEC  : 0:imm8*4     VEC2: 0:imm8*4+2
#  EAC  : EA computed but no memory access (LEA)
#  TA   : offset = T0 (computed by an earlier uop), segment as for EA
#  TAS  : offset = T0, segment SS, stack address size
#  system tables (linear addresses, no segment limit check; the table limits are
#  checked by the E uops), aoff = the uop's byte offset (look-ahead field):
#  DSCR / DSCI / DSCT : descriptor of the selector in the modrm r/m register / the
#         immediate / T0: GDT or LDT (selector TI) base + (selector & FFF8) + aoff (0 / 4)
#  IDT  : IDTR base + vector * 8 + aoff     TSS : TR base + T0 + aoff     LIN : T0 + aoff
#  TSSA : TR base + aoff (unscaled)
SEC = ['NONE', 'PUSH', 'STDI', 'DSCA']
#  PUSH : secondary (store) address SS:SP-2, SP -= 2
#  STDI : secondary (store) address ES:DI,  DI += +-size
#  DSCA : the access byte of the descriptor (DSC* modes): table base + (selector & FFF8) + 5
ABR = ['NONE', 'JMPD', 'LOOP', 'LOOPZ', 'LOOPNZ', 'JCXZ', 'BRE', 'BRI']
#  JMPD  : direct, always taken, resolved in A (JMP rel, CALL rel)
#  LOOP  : CX-=1, taken if CX!=0, resolved in A
#  LOOPZ/LOOPNZ : CX-=1, resolved in E (needs ZF)
#  JCXZ  : resolved in A
#  BRE   : Jcc, direct target, resolved in E
#  BRI   : indirect near (JMP/CALL r/m, RET) and real-mode / V86 far transfers (JFAR:
#          predicted when CS does not change), target from E
EOP = ['NOP', 'ALUOP', 'ALUREG', 'ADD', 'SUB', 'TEST', 'INC', 'DEC', 'NOT', 'NEG',
       'PASSA', 'PASSB', 'XCHG', 'SHIFT', 'MUL', 'DIV', 'AAM', 'AAD', 'DAA', 'DAS',
       'AAA', 'AAS', 'CBW', 'CWD', 'SALC', 'LAHF', 'SAHF', 'POPF', 'PUSHF', 'FLAGOP',
       'JCC', 'LOOPCC', 'JNEAR', 'JFAR', 'IRET', 'IN', 'OUT', 'HLT', 'INT', 'INTO',
       'INTFL', 'LEA', 'CMP', 'RETIRE', 'UD', 'MOVX', 'SETCC', 'BSWAP',
       'IMUL2', 'BOUND', 'BT', 'BTADR', 'BSF', 'SHXD', 'XADD', 'CSEL', 'SUBNF',
       'ADDNF', 'SRD', 'SWR', 'ESC', 'DLO', 'DHI', 'LDCS', 'EFL',
       'GATE', 'TSSOFF', 'LDSP', 'OLDSP', 'PADDR', 'SEGVAL', 'IOMAP', 'IOBIT', 'LARV', 'ARPL',
       'IRVM', 'LDV86', 'SEGNUL',
       'IRNT', 'TSSDESC', 'TFLG', 'TLNK', 'LDTSK', 'LDCR3', 'TLFL', 'TLDW',
       'INVLPG', 'TRD', 'TWR', 'PROBE', 'CPUID', 'CINV', 'TBIT']
#  CINV  : INVD / WBINVD: store buffer drained, both caches invalidated (tag sweep), refetch
#  CPUID : R = register rfix (0 EAX, 1 ECX, 2 EDX, 3 EBX) of CPUID leaf A (#UD without CPUID)
#  paging: INVLPG: drop the TLB entry of the operand's linear address (serializing);
#  TRD / TWR: MOV r32, TRn / MOV TRn, r32 (TR6 / TR7: TLB test, TR3-5: registers; #UD below TR3)
#  PROBE: a store uop that stores nothing: its address is checked for a write (limit, rights,
#         paging: #SS / #GP / #PF) and translated with write intent
#  task switch (see TSW below): IRNT: IRET with NT micro-jumps to the task return;
#  TSSDESC: R = the new TSS's base (T1 / T3), #TS if its limit is too small; TFLG: R = the
#  EFLAGS image to save (NT cleared for IRET); TLNK: the back-link store (CALL / INT only);
#  LDTSK: TR <- T0 / T1 / T3 (busy), CR0.TS, micro-jump to the load part at the new EIP (T2);
#  TBIT : the debug trap bit T <- B[0] (386 TSS byte 64h: a #DB trap after the task switch)
#  LDCR3: CR3 <- B;  TLFL: EFLAGS <- B (all bits, VM; NT for CALL / INT);  TLDW: R = B | FFFF0000
#  IRVM  : R = B (the popped EFLAGS); IRETD at CPL 0 with VM set micro-jumps to the V86 return
#  LDV86 : V86 return: CS = T0 (real-mode style), EIP = T2[15:0], EFLAGS = B (VM), CPL 3
#  SEGNUL: segment register rfix = null (interrupt from V86)
#  IOMAP : R = I/O map base (B) + port (A) / 8; #GP(0) for a 286 TSS at CPL > IOPL
#  IOBIT : #GP(0) if a bit of the port (A, size of the instruction) is set in the map
#          word B (map offset T0) or the bits lie beyond the TSS limit
#  LARV  : LAR / LSL / VERR / VERW (ck) of the selector A, descriptor high dword B, low
#          dword T1: ZF; LAR / LSL write the register only if valid
#  ARPL  : ARPL r/m (A), r (B): R = A with RPL raised, ZF; no write if unchanged
#  GATE  : call gate low dword A, high dword B: R = the target EIP, R2 = the target selector
#          (E keeps the parameter count)
#  TSSOFF: R = offset of SS:ESP for the privilege level of the code segment descriptor's DPL
#          (A = its high dword) in the TSS; #TS if beyond the TSS limit
#  LDSP  : (E)SP = B (+ imm16 of RET n: ck = RSS), at the size of the new stack (SS.B)
#  OLDSP : R = (E)SP at the stack size      PADDR : R = linear address after the call gate's
#          parameters on the current stack (SS base + (E)SP + count * operand size)
#  SEGVAL: the data segment register rfix is loaded with null unless valid at the new
#          CPL (RPL of T6): return to an outer level
#  EFL  : R = the EFLAGS image (VM, RF included), no flag change (interrupt frames)
#  DLO  : descriptor low dword: R = B (memory) , R2 = A (selector); table limit / null
#         checks of check kind ck
#  DHI  : descriptor high dword B, low dword in T1, selector A: type / privilege / present
#         checks of kind ck; d1 = SEG loads the segment register (c_sreg); the store
#         (wr = SEC, DSCA) sets the accessed bit (skipped if already set); R = B
#  LDCS : CS <- descriptor {T1, T3} with selector T0, EIP <- T2 (kind ck), redirect
#  ADDNF : R = A + B, no flags
#  SRD   : R = system register (rfix: 0 CR0 / MSW, 1 GDTR.limit, 2 GDTR.base, 3 IDTR.limit,
#          4 IDTR.base, 7 CR[modrm.reg])
#  SWR   : system register write, then refetch (rfix: 0 LMSW from B, 1 CLTS,
#          2 GDTR {limit T1, base B}, 3 IDTR {limit T1, base B}, 7 CR[modrm.reg] = B)
#  ESC   : coprocessor escape / WAIT without an FPU: #NM if CR0.EM / TS (WAIT: MP and TS)
#  SUBNF : R = A - B, no flags
#  IMUL2 : R = A * B (signed, truncated), CF = OF = overflow
#  BOUND : #BR if A < B (signed)
#  BT    : CF = bit (B mod size) of A; R = A with the bit set / reset / complemented
#  BTADR : R = EA + (bit offset B >> 3, operand aligned)     (bit string address)
#  BSF   : bit scan of B (forward / reverse by op[0]); R = index, or A if B = 0
#  SHXD  : SHLD / SHRD of A with B, count imm8 / CL
#  XADD  : R = A + B, R2 = A
#  CSEL  : R = ZF ? B : A
#  UD    : invalid opcode (#UD fault)
#  MOVX  : zero / sign extend B (byte or word, by op[0]) to the operand size (sign: op[3])
#  ALUOP : ALU op from opcode[5:3];  ALUREG: ALU op from modrm.reg
#  XCHG  : R = B, R2 = A ;  PASSA: R = A ; PASSB: R = B
#  JNEAR : IP <- A, R = ip_next (pushed if wr)
#  JFAR  : CS <- A, IP <- B, R = ip_next
#  IRET  : FLAGS <- MEM, CS <- T1, IP <- T0
#  INTFL : R = flags image, IF=TF=0
#  RETIRE: no-op marker that ends an instruction (REP exhaustion)
SRC = ['ZERO', 'REG', 'RM', 'MEM', 'ACC', 'IMM', 'OPR', 'T0', 'T1', 'SEG', 'FLAGS',
       'IPN', 'CS', 'DX', 'DISP', 'FIX', 'BP', 'OPSZ', 'T2', 'T3', 'T4', 'ERRC',
       'T5', 'T6', 'T7', 'T8', 'T9', 'SSR', 'SEGF', 'TRS']
#  SEGF : the selector of segment register rfix    TRS : the TR selector
#  T4..T9: read through the operand pre-select only (never by the uop right after the writer)
#  SSR : the SS selector
#  ERRC : the error code of the exception being delivered
#  OPSZ : the operand size in bytes (2 / 4)
DST = ['NONE', 'REG', 'RM', 'ACC', 'OPR', 'T0', 'T1', 'SEG', 'FIX', 'T2', 'T3', 'T4',
       'T5', 'T6', 'T7', 'T8', 'T9', 'SSR', 'SEGF']
#  SSR : SS (segment register load whatever the instruction's sreg field)   SEGF : register rfix
#  FIX : the GPR numbered by the uop's rfix field
ESZ = ['W0', 'W3', 'B', 'Z', 'W16', 'D32', 'SS', 'SEL', 'TSZ']
#  W0 / W3 : byte if opcode bit 0 / 3 is clear, else the operand size
#  Z : operand size (16 / 32)   W16, D32 : fixed   SS : stack address size
#  SEL : a selector pushed in an operand-size slot (16-bit store, operand-size step)
#  TSZ : 32 bit for a 386 TSS, else 16 bit
WR = ['NONE', 'PRI', 'SEC']
# descriptor check kinds (DLO / DHI / LDCS): see tetrium_exec.sv
CK = ['NONE', 'SEG', 'CSJ', 'CSC', 'CSR', 'LDT', 'TSS', 'CSI', 'INTG', 'INTCS', 'ACC',
      'CGJ', 'CGC', 'NSS', 'RSS', 'CGI', 'INTI', 'LAR', 'LSL', 'VERR', 'VERW', 'V86',
      'TTSS', 'TBSY', 'TFRE', 'TLDT', 'TCS', 'TSSS', 'TDS', 'SELO']
#  TTSS : the target TSS of a task switch (available; busy for IRET)   TBSY / TFRE : set /
#  clear its busy bit (DHI store; skipped for IRET / CALL, INT)   TLDT TCS TSSS TDS : the new
#  task's LDT, CS, SS, data segments (#TS)   SELO : load only the selector (task switch)
#  V86 : the segment register load of the uop is V86 style (base = selector << 4)
#  CGJ / CGC : a call gate's code segment (JMP / CALL; CALL to a more privileged
#        non-conforming segment micro-jumps to the stack switch)
#  NSS : the inner stack from the TSS (#TS)    RSS : the outer stack of RET / IRET (#GP)
#  CGI / INTI : LDCS of an inner-level CALL / interrupt (CPL = the segment's DPL)
#  (DHI reads the low dword from T5 instead of T1 for NSS, RSS, TSSS, TDS)
#  SEG : MOV / POP / LxS to a data segment register (SS: stack segment rules)
#  CSJ / CSC / CSR / CSI : far JMP / CALL / RET / IRET target    LDT : LLDT    TSS : LTR
#  INTG : IDT gate (DHI micro-jumps to the frame sequence)    INTCS : the gate's code segment
#  ACC : DHI only sets the accessed bit (descriptor high dword in B)
# static checks of the uop (any eop)
CHK = ['NONE', 'CPL0', 'IOPL', 'V86IOPL']
#  CPL0 : #GP(0) unless CPL 0 (protected mode) / always in V86
#  IOPL : #GP(0) if CPL > IOPL (protected mode; V86: IOPL < 3)       CLI, STI
#  V86IOPL : #GP(0) in V86 with IOPL < 3                    PUSHF, POPF, INT, IRET

# --------------------------------------------------------------- layout
FIELDS = [  # name, width   (LSB first)
    ('na_amode', 5), ('na_sec', 2), ('na_repchk', 1), ('na_abr', 3), ('na_islast', 1), ('na_endnr', 1), ('na_asz', 2), ('na_aoff', 7), ('na_ifec', 1),
    ('next', 11), ('last', 1), ('endnr', 1),
    ('mrd', 1),
    ('eop', 7), ('sa', 5), ('sb', 5), ('d1', 5), ('d2', 5), ('esz', 4),
    ('wr', 2), ('repz', 1), ('rfix', 3), ('m16', 1), ('lp', 1),
    ('ck', 5), ('chk', 2), ('sv', 1),
]
pos = 0
LAYOUT = {}
for n, w in FIELDS:
    LAYOUT[n] = (pos, w)
    pos += w
assert pos <= UW_BITS, pos

AF_FIELDS = [('amode', 5), ('sec', 2), ('repchk', 1), ('abr', 3), ('islast', 1), ('endnr', 1), ('asz', 2),
             ('aoff', 7), ('ifec', 1)]
#  ifec : the uop only runs if the exception being delivered has an error code (A1
#         turns it into a no-op otherwise)
AF_BITS = sum(w for _, w in AF_FIELDS)

_p = 0
for (n, w), (fn, fw) in zip(AF_FIELDS, FIELDS):
    assert fn == 'na_' + n and fw == w and LAYOUT[fn][0] == _p, ('na_* fields must mirror AF_FIELDS at bit 0', fn)
    _p += w


def enc_enum(lst, v):
    return lst.index(v)


class U:
    """One micro-op."""
    def __init__(self, a='NONE', sec='NONE', repchk=0, abr='NONE', mrd=0, e='NOP',
                 sa='ZERO', sb='ZERO', d1='NONE', d2='NONE', sz='W0', wr='NONE',
                 repz=0, label=None, goto=None, endnr=0, rfix=0, m16=0, lp=None, aoff=0, ck='NONE',
                 chk='NONE', ifec=0, sv=0):
        self.a, self.sec, self.repchk, self.abr = a, sec, repchk, abr
        self.mrd, self.e, self.sa, self.sb = mrd, e, sa, sb
        # E's port A pre-select has only these sources (tetrium_exec.sv sdec, pa)
        assert sa in ('ZERO', 'REG', 'RM', 'ACC', 'OPR', 'FIX', 'DX', 'IMM', 'MEM', 'T0', 'T1', 'T3'), \
            ('source not on port A', sa)
        self.d1, self.d2, self.sz, self.wr, self.repz = d1, d2, sz, wr, repz
        self.label, self.goto, self.endnr = label, goto, endnr
        self.rfix = rfix
        self.aoff, self.ck, self.chk, self.ifec = aoff, ck, chk, ifec
        # supervisor access (paging rights of CPL 0 whatever the CPL): the system tables
        # and the inner stack of a privilege change before CS is loaded
        self.sv = 1 if (sv or a in ('DSCR', 'DSCI', 'DSCT', 'IDT', 'TSS', 'TSSA', 'LIN')) else 0
        self.m16 = m16          # the memory load is 16 bits whatever the operand size (selectors)
        # micro-loop on the decoder's count register (ENTER level): if the count is zero the
        # sequence continues at the uop labelled lp, else the count is decremented and the
        # normal successor follows.  The exit uop sits at successor address + 1 (successor
        # even) and must have no A-stage fields (it is entered without look-ahead).
        self.lp = lp
        self.addr = None
        self.nxt = None  # successor U (for lookahead) or None
        self.last = 0

    def asz(self):
        # step size of a stack / string uop (A stage): 0 W0, 1 operand size, 2 16 bit
        if self.a not in ('POP', 'POPN', 'SI', 'DI') and self.sec in ('NONE', 'DSCA'):
            return 0
        m = {'W0': 0, 'Z': 1, 'W16': 2, 'SS': 2, 'SEL': 1, 'TSZ': 1}
        assert self.sz in m, ('stack / string uop size', self.sz)
        return m[self.sz]

    def af(self):
        return (enc_enum(AMODE, self.a), enc_enum(SEC, self.sec), self.repchk,
                enc_enum(ABR, self.abr), self.last, self.endnr, self.asz(), self.aoff, self.ifec)


# ------------------------------------------------------------ program
# dispatch: map index -> list of U (sequence).  Sequences may 'goto' a label
# (loop back) instead of falling through.
#   normal opcode : {page (0F), opcode[7:0], mod3}                     (0..1023)
#   group opcode  : 1024 + group*16 + reg*2 + mod3                      (1024..1135)
# Continuation uops live at CONT_BASE.. .
disp = {}          # real mode (and V86) dispatch
disp_pm = {}       # protected-mode dispatch (missing entries: the real-mode sequence)
labels = {}
GROUPS = {(0, 0xF6): 0, (0, 0xF7): 1, (0, 0xFE): 2, (0, 0xFF): 3, (1, 0x00): 4, (1, 0x01): 5, (1, 0xBA): 6}
GROUP_BASE = 1024
CONT_BASE = GROUP_BASE + 16 * 7


def didx(pg, op, mod3, reg=None):
    if (pg, op) in GROUPS:
        return GROUP_BASE + GROUPS[(pg, op)] * 16 + ((reg & 7) << 1) + mod3
    return (pg << 9) | (op << 1) | mod3


def define(op, seq_m, seq_r=None, regs=None, pg=0, mode='both'):
    """seq_m: uops for memory form (mod!=3), seq_r for register form (mod==3).
    For non-modrm instructions pass only seq_m (used for both).
    mode: 'both' (real-mode sequence, also used in protected mode), 'rm' (same), 'pm'
    (protected-mode sequence only)."""
    if seq_r is None:
        seq_r = seq_m
    rl = [None] if (pg, op) not in GROUPS else (regs if regs is not None else range(8))
    tab = disp_pm if mode == 'pm' else disp
    for reg in rl:
        for mod3, seq in ((0, seq_m), (1, seq_r)):
            i = didx(pg, op, mod3, reg)
            assert i not in tab, (pg, hex(op), reg, mode)
            tab[i] = seq() if callable(seq) else seq


def UD():
    return [U(e='UD')]


ALU_OPS = [0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38]

# ALU r/m,r ; r,r/m ; acc,imm
for b in ALU_OPS:
    for w in (0, 1):
        # op r/m, r
        define(b | w,
               lambda: [U(a='EA', mrd=1, e='ALUOP', sa='MEM', sb='REG', wr='PRI')],
               lambda: [U(e='ALUOP', sa='RM', sb='REG', d1='RM')])
        # op r, r/m
        define(b | 2 | w,
               lambda: [U(a='EA', mrd=1, e='ALUOP', sa='REG', sb='MEM', d1='REG')],
               lambda: [U(e='ALUOP', sa='REG', sb='RM', d1='REG')])
        define(b | 4 | w, lambda: [U(e='ALUOP', sa='ACC', sb='IMM', d1='ACC')])

# segment push/pop (0F is the two-byte escape, there is no POP CS)
for s in range(4):
    define(0x06 | (s << 3), lambda: [U(sec='PUSH', e='PASSB', sb='SEG', sz='Z', wr='SEC')])
    if s != 1:
        define(0x07 | (s << 3), lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='SEG', sz='Z')])

define(0x27, lambda: [U(e='DAA', sa='ACC', sz='W16')])
define(0x2F, lambda: [U(e='DAS', sa='ACC', sz='W16')])
define(0x37, lambda: [U(e='AAA', sa='ACC', sz='W16')])
define(0x3F, lambda: [U(e='AAS', sa='ACC', sz='W16')])

for r in range(8):
    define(0x40 + r, lambda: [U(e='INC', sa='OPR', d1='OPR', sz='Z')])
    define(0x48 + r, lambda: [U(e='DEC', sa='OPR', d1='OPR', sz='Z')])
    define(0x50 + r, lambda: [U(sec='PUSH', e='PASSB', sb='OPR', sz='Z', wr='SEC')])   # PUSH SP: the old value
    define(0x58 + r, lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='OPR', sz='Z')])

# PUSHA: AX CX DX BX (original SP) BP SI DI;  POPA: the reverse, the SP slot read but not
# written; a fault keeps the registers popped before it (386EX SingleStepTests 61 / 6661)
define(0x60, lambda: [U(sec='PUSH', e='XCHG', sa='FIX', rfix=4, sb='ACC', d2='T0', sz='Z', wr='SEC'),
                      U(sec='PUSH', e='PASSB', sb='FIX', rfix=1, sz='Z', wr='SEC'),
                      U(sec='PUSH', e='PASSB', sb='FIX', rfix=2, sz='Z', wr='SEC'),
                      U(sec='PUSH', e='PASSB', sb='FIX', rfix=3, sz='Z', wr='SEC'),
                      U(sec='PUSH', e='PASSB', sb='T0', sz='Z', wr='SEC'),
                      U(sec='PUSH', e='PASSB', sb='FIX', rfix=5, sz='Z', wr='SEC'),
                      U(sec='PUSH', e='PASSB', sb='FIX', rfix=6, sz='Z', wr='SEC'),
                      U(sec='PUSH', e='PASSB', sb='FIX', rfix=7, sz='Z', wr='SEC')])
define(0x61, lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='FIX', rfix=7, sz='Z'),
                      U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='FIX', rfix=6, sz='Z'),
                      U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='FIX', rfix=5, sz='Z'),
                      U(a='POP', mrd=1, e='NOP', sz='Z'),   # (E)SP slot: read, value dropped (386EX: limit / page checked)
                      U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='FIX', rfix=3, sz='Z'),
                      U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='FIX', rfix=2, sz='Z'),
                      U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='FIX', rfix=1, sz='Z'),
                      U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='FIX', rfix=0, sz='Z')])
# BOUND r, m: #BR unless m[0] <= r <= m[1] (signed)
define(0x62, lambda: [U(a='EA', mrd=1, e='BOUND', sa='REG', sb='MEM', sz='Z'),
                      U(a='EA2', mrd=1, e='BOUND', sa='MEM', sb='REG', sz='Z')], UD)
for op in (0x69, 0x6B):                # IMUL r, r/m, imm
    define(op, lambda: [U(a='EA', mrd=1, e='IMUL2', sa='MEM', sb='IMM', d1='REG', sz='Z')],
           lambda: [U(e='IMUL2', sa='RM', sb='IMM', d1='REG', sz='Z')])
for w in (0, 1):                       # INS / OUTS
    define(0x6C | w, lambda: [U(sec='STDI', repchk=1, e='IN', sa='DX', wr='SEC', label='self', endnr=1)])
    define(0x6E | w, lambda: [U(a='SI', mrd=1, repchk=1, e='OUT', sa='DX', sb='MEM', label='self', endnr=1)])
define(0x68, lambda: [U(sec='PUSH', e='PASSB', sb='IMM', sz='Z', wr='SEC')])
define(0x6A, lambda: [U(sec='PUSH', e='PASSB', sb='IMM', sz='Z', wr='SEC')])

for c in range(16):
    define(0x70 + c, lambda: [U(abr='BRE', e='JCC')])
    define(0x80 + c, lambda: [U(abr='BRE', e='JCC')], pg=1)
    define(0x90 + c, lambda: [U(a='EA', e='SETCC', sz='B', wr='PRI')],
           lambda: [U(e='SETCC', d1='RM', sz='B')], pg=1)

for op in (0x80, 0x81, 0x82, 0x83):
    define(op, lambda: [U(a='EA', mrd=1, e='ALUREG', sa='MEM', sb='IMM', wr='PRI')],
           lambda: [U(e='ALUREG', sa='RM', sb='IMM', d1='RM')])
for w in (0, 1):
    define(0x84 | w, lambda: [U(a='EA', mrd=1, e='TEST', sa='MEM', sb='REG')],
           lambda: [U(e='TEST', sa='RM', sb='REG')])
    define(0x86 | w, lambda: [U(a='EA', mrd=1, e='XCHG', sa='MEM', sb='REG', d2='REG', wr='PRI')],
           lambda: [U(e='XCHG', sa='RM', sb='REG', d1='RM', d2='REG')])
    define(0x88 | w, lambda: [U(a='EA', e='PASSB', sb='REG', wr='PRI')],
           lambda: [U(e='PASSB', sb='REG', d1='RM')])
    define(0x8A | w, lambda: [U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='REG')],
           lambda: [U(e='PASSB', sb='RM', d1='REG')])
# MOV r/m, Sreg: memory form stores 16 bits, register form writes the operand size
define(0x8C, lambda: [U(a='EA', e='PASSB', sb='SEG', sz='W16', wr='PRI')],
       lambda: [U(e='PASSB', sb='SEG', d1='RM', sz='Z')])
define(0x8D, lambda: [U(a='EAC', e='LEA', d1='REG', sz='Z')], UD)
define(0x8E, lambda: [U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='SEG', sz='W16')],
       lambda: [U(e='PASSB', sb='RM', d1='SEG', sz='W16')])
define(0x8F, lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z'),
                      U(a='EA', e='PASSB', sb='T0', sz='Z', wr='PRI')],
       lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='RM', sz='Z')])
define(0x90, lambda: [U(e='NOP')])
for r in range(1, 8):
    define(0x90 + r, lambda: [U(e='XCHG', sa='ACC', sb='OPR', d1='ACC', d2='OPR', sz='Z')])
define(0x98, lambda: [U(e='CBW', sa='ACC', sz='Z')])
define(0x99, lambda: [U(e='CWD', sa='ACC', sz='Z')])
define(0x9A, lambda: [U(sec='PUSH', e='PASSB', sb='CS', sz='Z', wr='SEC'),
                      U(sec='PUSH', abr='BRI', e='JFAR', sa='IMM', sb='DISP', sz='Z', wr='SEC')])
define(0x9B, lambda: [U(e='ESC')])                     # WAIT
define(0x9C, lambda: [U(sec='PUSH', e='PUSHF', sz='Z', wr='SEC', chk='V86IOPL')])
define(0x9D, lambda: [U(a='POP', mrd=1, e='POPF', sb='MEM', sz='Z', chk='V86IOPL')])
define(0x9E, lambda: [U(e='SAHF', sa='ACC', sz='W16')])
define(0x9F, lambda: [U(e='LAHF')])
for w in (0, 1):
    define(0xA0 | w, lambda: [U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='ACC')])
    define(0xA2 | w, lambda: [U(a='EA', e='PASSB', sb='ACC', wr='PRI')])
    define(0xA4 | w, lambda: [U(a='SI', mrd=1, sec='STDI', repchk=1, e='PASSB', sb='MEM', wr='SEC',
                                label='self', endnr=1)])
    # CMPS reads ES:EDI first, then DS:ESI (386 microcode order, as 86Box: decides which #PF / walk comes first)
    define(0xA6 | w, lambda: [U(a='DI', mrd=1, repchk=1, e='PASSB', sb='MEM', d1='T0', label='top'),
                              U(a='SI', mrd=1, e='CMP', sa='MEM', sb='T0', repz=1, goto='top', endnr=1)])
    define(0xA8 | w, lambda: [U(e='TEST', sa='ACC', sb='IMM')])
    define(0xAA | w, lambda: [U(sec='STDI', repchk=1, e='PASSB', sb='ACC', wr='SEC', label='self', endnr=1)])
    define(0xAC | w, lambda: [U(a='SI', mrd=1, repchk=1, e='PASSB', sb='MEM', d1='ACC', label='self', endnr=1)])
    define(0xAE | w, lambda: [U(a='DI', mrd=1, repchk=1, e='CMP', sa='ACC', sb='MEM', repz=1,
                                label='self', endnr=1)])
for r in range(8):
    define(0xB0 + r, lambda: [U(e='PASSB', sb='IMM', d1='OPR', sz='W3')])
    define(0xB8 + r, lambda: [U(e='PASSB', sb='IMM', d1='OPR', sz='W3')])
for op in (0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3):
    define(op, lambda: [U(a='EA', mrd=1, e='SHIFT', sa='MEM', wr='PRI')],
           lambda: [U(e='SHIFT', sa='RM', d1='RM')])
define(0xC2, lambda: [U(a='POPN', mrd=1, abr='BRI', e='JNEAR', sa='MEM', sz='Z')])
define(0xC3, lambda: [U(a='POP', mrd=1, abr='BRI', e='JNEAR', sa='MEM', sz='Z')])
for op in (0xC4, 0xC5):
    define(op, lambda: [U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z'),
                        U(a='EA2', mrd=1, m16=1, e='PASSA', sa='MEM', sb='T0', d1='SEG', d2='REG', sz='Z')],
           UD)
define(0xC6, lambda: [U(a='EA', e='PASSB', sb='IMM', wr='PRI')], lambda: [U(e='PASSB', sb='IMM', d1='RM')])
define(0xC7, lambda: [U(a='EA', e='PASSB', sb='IMM', wr='PRI')], lambda: [U(e='PASSB', sb='IMM', d1='RM')])
# LEAVE: SP / ESP <- BP / EBP (stack size), BP / EBP <- pop (operand size)
# ENTER size, level: push BP; frame = SP; (level - 1) x { BP' -= size; push [SS:BP'] };
# push frame (if level > 0); BP = frame; SP -= size.  T0 walks down the old frame, T1 = frame.
define(0xC8, lambda: [U(sec='PUSH', e='PASSB', sb='BP', sz='Z', wr='SEC'),
                      U(e='PASSB', sb='FIX', rfix=4, d1='T1', sz='D32', lp='G'),   # frame: SP / ESP by operand size
                      U(e='PASSB', sb='BP', d1='T0', sz='SS', lp='X'),
                      U(e='SUBNF', sa='T0', sb='OPSZ', d1='T0', sz='Z', label='top'),
                      U(a='TAS', mrd=1, sec='PUSH', e='PASSB', sb='MEM', sz='Z', wr='SEC', goto='top', lp='X'),
                      U(e='NOP', label='X'),
                      U(sec='PUSH', e='PASSB', sb='T1', sz='Z', wr='SEC', goto='G'),
                      # the final SS:(E)SP must take a write (#SS / #PF, nothing written: SDM,
                      # 80386 microcode check-write) before (E)BP / (E)SP change
                      U(e='SUBNF', sa='FIX', rfix=4, sb='IMM', d1='T0', sz='SS', label='G'),
                      U(a='TAS', e='PROBE', sz='Z', wr='PRI'),
                      U(e='PASSB', sb='T1', d1='FIX', rfix=5, sz='Z'),
                      U(e='PASSB', sb='T0', d1='FIX', rfix=4, sz='SS')])
define(0xC9, lambda: [U(e='PASSB', sb='BP', d1='FIX', rfix=4, sz='SS'),
                      U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='FIX', rfix=5, sz='Z')])
define(0xCA, lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z'),
                      U(a='POPN', mrd=1, abr='BRI', e='JFAR', sa='MEM', sb='T0', sz='Z')])
define(0xCB, lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z'),
                      U(a='POP', mrd=1, abr='BRI', e='JFAR', sa='MEM', sb='T0', sz='Z')])
define(0xCC, lambda: [U(e='INT', sz='W16', chk='V86IOPL')])
define(0xCD, lambda: [U(e='INT', sz='W16', chk='V86IOPL')])
define(0xCE, lambda: [U(e='INTO', sz='W16', chk='V86IOPL')])
define(0xCF, lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z', chk='V86IOPL'),
                      U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T1', sz='Z'),
                      U(a='POP', mrd=1, e='IRET', sb='MEM', sz='Z')])
define(0xD4, lambda: [U(e='AAM', sa='ACC', sz='W16')])
define(0xD5, lambda: [U(e='AAD', sa='ACC', sz='W16')])
define(0xD6, lambda: [U(e='SALC', sz='B')])
define(0xD7, lambda: [U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='ACC', sz='B')])
# ESC without a coprocessor: the modrm is decoded, nothing else happens (#NM if CR0.EM / TS)
for op in range(0xD8, 0xE0):
    define(op, lambda: [U(e='ESC')])
define(0xE0, lambda: [U(abr='LOOPNZ', e='LOOPCC')])
define(0xE1, lambda: [U(abr='LOOPZ', e='LOOPCC')])
define(0xE2, lambda: [U(abr='LOOP', e='NOP')])
define(0xE3, lambda: [U(abr='JCXZ', e='NOP')])
for w in (0, 1):
    define(0xE4 | w, lambda: [U(e='IN', sa='IMM', d1='ACC')])
    define(0xE6 | w, lambda: [U(e='OUT', sa='IMM', sb='ACC')])
    define(0xEC | w, lambda: [U(e='IN', sa='DX', d1='ACC')])
    define(0xEE | w, lambda: [U(e='OUT', sa='DX', sb='ACC')])
define(0xE8, lambda: [U(sec='PUSH', abr='JMPD', e='PASSB', sb='IPN', sz='Z', wr='SEC')])
define(0xE9, lambda: [U(abr='JMPD', e='NOP')])
define(0xEA, lambda: [U(abr='BRI', e='JFAR', sa='IMM', sb='DISP', sz='Z')])
define(0xEB, lambda: [U(abr='JMPD', e='NOP')])
define(0xF4, lambda: [U(e='HLT', chk='CPL0')])
for op in (0xF5, 0xF8, 0xF9, 0xFC, 0xFD):
    define(op, lambda: [U(e='FLAGOP')])
for op in (0xFA, 0xFB):                # CLI / STI
    define(op, lambda: [U(e='FLAGOP', chk='IOPL')])
# group 3
for op in (0xF6, 0xF7):
    define(op, lambda: [U(a='EA', mrd=1, e='TEST', sa='MEM', sb='IMM')],
           lambda: [U(e='TEST', sa='RM', sb='IMM')], regs=[0, 1])
    define(op, lambda: [U(a='EA', mrd=1, e='NOT', sa='MEM', wr='PRI')],
           lambda: [U(e='NOT', sa='RM', d1='RM')], regs=[2])
    define(op, lambda: [U(a='EA', mrd=1, e='NEG', sa='MEM', wr='PRI')],
           lambda: [U(e='NEG', sa='RM', d1='RM')], regs=[3])
    define(op, lambda: [U(a='EA', mrd=1, e='MUL', sa='ACC', sb='MEM')],
           lambda: [U(e='MUL', sa='ACC', sb='RM')], regs=[4, 5])
    define(op, lambda: [U(a='EA', mrd=1, e='DIV', sb='MEM')],
           lambda: [U(e='DIV', sb='RM')], regs=[6, 7])
# group 4/5
for op in (0xFE, 0xFF):
    define(op, lambda: [U(a='EA', mrd=1, e='INC', sa='MEM', wr='PRI')],
           lambda: [U(e='INC', sa='RM', d1='RM')], regs=[0])
    define(op, lambda: [U(a='EA', mrd=1, e='DEC', sa='MEM', wr='PRI')],
           lambda: [U(e='DEC', sa='RM', d1='RM')], regs=[1])
define(0xFF, lambda: [U(a='EA', mrd=1, sec='PUSH', abr='BRI', e='JNEAR', sa='MEM', sz='Z', wr='SEC')],
       lambda: [U(sec='PUSH', abr='BRI', e='JNEAR', sa='RM', sz='Z', wr='SEC')], regs=[2])
define(0xFF, lambda: [U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z'),
                      U(a='EA2', mrd=1, m16=1, sec='PUSH', e='XCHG', sa='MEM', sb='CS', d2='T1', sz='Z', wr='SEC'),
                      U(sec='PUSH', abr='BRI', e='JFAR', sa='T1', sb='T0', sz='Z', wr='SEC')], UD, regs=[3])
define(0xFF, lambda: [U(a='EA', mrd=1, abr='BRI', e='JNEAR', sa='MEM', sz='Z')],
       lambda: [U(abr='BRI', e='JNEAR', sa='RM', sz='Z')], regs=[4])
define(0xFF, lambda: [U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z'),
                      U(a='EA2', mrd=1, m16=1, abr='BRI', e='JFAR', sa='MEM', sb='T0', sz='Z')], UD, regs=[5])
define(0xFF, lambda: [U(a='EA', mrd=1, sec='PUSH', e='PASSB', sb='MEM', sz='Z', wr='SEC')],
       lambda: [U(sec='PUSH', e='PASSB', sb='RM', sz='Z', wr='SEC')], regs=[6])

# ---- 0F page
# system registers (real mode: CPL 0).  SGDT / SIDT / LGDT / LIDT: limit at EA, base at
# EA + 2 (T0 = EA); LGDT / LIDT with a 16-bit operand size load a 24-bit base.
def sdt_store(lim, base):
    # (EA2 of the 0F 01 group: EA + 2 at either operand size)
    return lambda: [U(a='EA', e='SRD', rfix=lim, sz='W16', wr='PRI'),
                    U(a='EA2', e='SRD', rfix=base, sz='D32', wr='PRI')]
def sdt_load(r):
    return lambda: [U(a='EAC', e='LEA', d1='T0', sz='Z', chk='CPL0'),
                    U(a='TA', mrd=1, e='PASSB', sb='MEM', d1='T1', sz='W16'),
                    U(e='ADDNF', sa='T0', sb='OPSZ', d1='T0', sz='W16'),
                    U(a='TA', mrd=1, e='SWR', rfix=r, sb='MEM', sz='D32')]
define(0x01, sdt_store(1, 2), UD, regs=[0], pg=1)                  # SGDT
define(0x01, sdt_store(3, 4), UD, regs=[1], pg=1)                  # SIDT
define(0x01, sdt_load(2), UD, regs=[2], pg=1)                      # LGDT
define(0x01, sdt_load(3), UD, regs=[3], pg=1)                      # LIDT
define(0x01, lambda: [U(a='EA', e='SRD', rfix=0, sz='W16', wr='PRI')],
       lambda: [U(e='SRD', rfix=0, d1='RM', sz='Z')], regs=[4], pg=1)          # SMSW (r32: all of CR0, 80386 microcode)
define(0x01, lambda: [U(a='EA', mrd=1, e='SWR', rfix=0, sb='MEM', sz='W16', chk='CPL0')],
       lambda: [U(e='SWR', rfix=0, sb='RM', sz='W16', chk='CPL0')], regs=[6], pg=1)        # LMSW
define(0x01, lambda: [U(a='EA', e='INVLPG', chk='CPL0')], UD, regs=[7], pg=1)              # INVLPG
define(0x06, lambda: [U(e='SWR', rfix=1, chk='CPL0')], pg=1)                               # CLTS
for op in (0x08, 0x09):                # INVD / WBINVD (write-through caches: the same)
    define(op, lambda: [U(e='CINV', chk='CPL0')], pg=1)
# MOV r32, CRn / MOV CRn, r32 (the modrm always names a register)
define(0x20, lambda: [U(e='SRD', rfix=7, d1='RM', sz='D32', chk='CPL0')], pg=1)
define(0x22, lambda: [U(e='SWR', rfix=7, sb='RM', sz='D32', chk='CPL0')], pg=1)
# MOV r32, DRn / MOV DRn, r32 (TRD / TWR uops, op[2] = 0: debug registers; DR7.GD: #DB)
define(0x21, lambda: [U(e='TRD', d1='RM', sz='D32', chk='CPL0')], pg=1)
define(0x23, lambda: [U(e='TWR', sb='RM', sz='D32', chk='CPL0')], pg=1)
# MOV r32, TRn / MOV TRn, r32
define(0x24, lambda: [U(e='TRD', d1='RM', sz='D32', chk='CPL0')], pg=1)
define(0x26, lambda: [U(e='TWR', sb='RM', sz='D32', chk='CPL0')], pg=1)
# CPUID: EBX, ECX, EDX from the leaf in EAX, then EAX
define(0xA2, lambda: [U(e='CPUID', sa='ACC', d1='FIX', rfix=3, sz='D32'),
                      U(e='CPUID', sa='ACC', d1='FIX', rfix=1, sz='D32'),
                      U(e='CPUID', sa='ACC', d1='FIX', rfix=2, sz='D32'),
                      U(e='CPUID', sa='ACC', d1='FIX', rfix=0, sz='D32')], pg=1)
define(0xA0, lambda: [U(sec='PUSH', e='PASSB', sb='SEG', sz='Z', wr='SEC')], pg=1)
define(0xA8, lambda: [U(sec='PUSH', e='PASSB', sb='SEG', sz='Z', wr='SEC')], pg=1)
define(0xA1, lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='SEG', sz='Z')], pg=1)
define(0xA9, lambda: [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='SEG', sz='Z')], pg=1)
for op in (0xB2, 0xB4, 0xB5):          # LSS / LFS / LGS
    define(op, lambda: [U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z'),
                        U(a='EA2', mrd=1, m16=1, e='PASSA', sa='MEM', sb='T0', d1='SEG', d2='REG', sz='Z')],
           UD, pg=1)
for op in (0xB6, 0xB7, 0xBE, 0xBF):    # MOVZX / MOVSX (source size from op[0], see exec)
    define(op, lambda: [U(a='EA', mrd=1, e='MOVX', sb='MEM', d1='REG', sz='Z')],
           lambda: [U(e='MOVX', sb='RM', d1='REG', sz='Z')], pg=1)
for r in range(8):
    define(0xC8 + r, lambda: [U(e='BSWAP', sa='OPR', d1='OPR', sz='D32')], pg=1)
define(0xAF, lambda: [U(a='EA', mrd=1, e='IMUL2', sa='REG', sb='MEM', d1='REG', sz='Z')],
       lambda: [U(e='IMUL2', sa='REG', sb='RM', d1='REG', sz='Z')], pg=1)
# bit tests: the register bit offset of a memory operand selects the word (T0 = its address)
define(0xA3, lambda: [U(a='EAC', e='BTADR', sb='REG', d1='T0', sz='Z'),
                      U(a='TA', mrd=1, e='BT', sa='MEM', sb='REG', sz='Z')],
       lambda: [U(e='BT', sa='RM', sb='REG', sz='Z')], pg=1)
for op in (0xAB, 0xB3, 0xBB):
    define(op, lambda: [U(a='EAC', e='BTADR', sb='REG', d1='T0', sz='Z'),
                        U(a='TA', mrd=1, e='BT', sa='MEM', sb='REG', sz='Z', wr='PRI')],
           lambda: [U(e='BT', sa='RM', sb='REG', d1='RM', sz='Z')], pg=1)
define(0xBA, lambda: [U(a='EA', mrd=1, e='BT', sa='MEM', sb='IMM', sz='Z')],
       lambda: [U(e='BT', sa='RM', sb='IMM', sz='Z')], regs=[4], pg=1)
define(0xBA, lambda: [U(a='EA', mrd=1, e='BT', sa='MEM', sb='IMM', sz='Z', wr='PRI')],
       lambda: [U(e='BT', sa='RM', sb='IMM', d1='RM', sz='Z')], regs=[5, 6, 7], pg=1)
for op in (0xBC, 0xBD):                # BSF / BSR
    define(op, lambda: [U(a='EA', mrd=1, e='BSF', sa='REG', sb='MEM', d1='REG', sz='Z')],
           lambda: [U(e='BSF', sa='REG', sb='RM', d1='REG', sz='Z')], pg=1)
for op in (0xA4, 0xA5, 0xAC, 0xAD):    # SHLD / SHRD
    define(op, lambda: [U(a='EA', mrd=1, e='SHXD', sa='MEM', sb='REG', sz='Z', wr='PRI')],
           lambda: [U(e='SHXD', sa='RM', sb='REG', d1='RM', sz='Z')], pg=1)
for op in (0xC0, 0xC1):                # XADD
    define(op, lambda: [U(a='EA', mrd=1, e='XADD', sa='MEM', sb='REG', d2='REG', wr='PRI')],
           lambda: [U(e='XADD', sa='RM', sb='REG', d1='RM', d2='REG')], pg=1)
for op in (0xB0, 0xB1):                # CMPXCHG: compare, then two conditional moves
    define(op, lambda: [U(a='EA', mrd=1, e='CMP', sa='ACC', sb='MEM', d2='T0'),
                        U(a='EA', e='CSEL', sa='T0', sb='REG', wr='PRI'),
                        U(e='CSEL', sa='T0', sb='ACC', d1='ACC')],
           lambda: [U(e='CMP', sa='ACC', sb='RM', d2='T0'),
                    U(e='CSEL', sa='T0', sb='REG', d1='RM'),
                    U(e='CSEL', sa='T0', sb='ACC', d1='ACC')], pg=1)

# ---------------------------------------------------------------- protected mode
# Segment register loads: the selector goes to T0 (from memory / the stack), then the
# descriptor's low dword (DLO: table limit / null checks; R2 = the selector) and high
# dword (DHI: type / privilege / present checks, loads the segment register, sets the
# accessed bit with a byte store).  A register selector is read by the address mode
# itself (DSCR), so MOV Sreg, r is two uops.
def dsc_load(src_first, a, rd=None):
    """src_first: uops that leave the selector in T0 (or [] with a = 'DSCR')"""
    lo = U(a=a, aoff=0, mrd=1, e='DLO', ck='SEG', sa=('RM' if a == 'DSCR' else 'T0'), sb='MEM',
           d1='T1', d2=('NONE' if a == 'DSCT' else 'T0'), sz='D32')
    hi = U(a=a, aoff=4, mrd=1, sec='DSCA', e='DHI', ck='SEG', sa='T0', sb='MEM', d1='SEG',
           sz='B', wr='SEC')
    return src_first + [lo, hi] + (rd or [])
define(0x8E, lambda: dsc_load([U(a='EA', mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16')], 'DSCT'),
       lambda: dsc_load([], 'DSCR'), mode='pm')
for sg in (0, 2, 3):
    define(0x07 | (sg << 3), lambda: dsc_load([U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z')], 'DSCT'),
           mode='pm')
for op in (0xA1, 0xA9):
    define(op, lambda: dsc_load([U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z')], 'DSCT'), pg=1, mode='pm')
# LDS / LES / LSS / LFS / LGS: offset to T2, selector to T0; the register is written last
def lxs():
    return dsc_load([U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='T2', sz='Z'),
                     U(a='EA2', mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16')], 'DSCT',
                    [U(e='PASSB', sb='T2', d1='REG', sz='Z')])
for op in (0xC4, 0xC5):
    define(op, lxs, UD, mode='pm')
for op in (0xB2, 0xB4, 0xB5):
    define(op, lxs, UD, pg=1, mode='pm')
# far JMP: EIP to T2, selector to T0, descriptor checks, LDCS loads CS and jumps
def far_cs(first, a, ck):
    lo = U(a=a, aoff=0, mrd=1, e='DLO', ck=ck, sa=('IMM' if a == 'DSCI' else 'T0'), sb='MEM',
           d1='T1', d2=('NONE' if a == 'DSCT' else 'T0'), sz='D32')
    hi = U(a=a, aoff=4, mrd=1, sec='DSCA', e='DHI', ck=ck, sa='T0', sb='MEM', d2='T3', sz='B', wr='SEC')
    return first + [lo, hi]
# (abr BRI on the LDCS of far JMP / CALL / RETF: one that keeps CS is verified in E and
# needs no redirect when predicted, see tetrium_exec.sv)
define(0xEA, lambda: far_cs([U(e='PASSB', sb='DISP', d1='T2', sz='Z')], 'DSCI', 'CSJ') +
       [U(abr='BRI', e='LDCS', ck='CSJ', sz='Z')], mode='pm')
define(0xFF, lambda: far_cs([U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='T2', sz='Z'),
                             U(a='EA2', mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16')], 'DSCT', 'CSJ') +
       [U(abr='BRI', e='LDCS', ck='CSJ', sz='Z')], UD, regs=[5], mode='pm')
# group 0F 00 (protected mode only; #UD in real mode and V86): SLDT STR LLDT LTR
define(0x00, lambda: [U(a='EA', e='SRD', rfix=5, sz='W16', wr='PRI')],
       lambda: [U(e='SRD', rfix=5, d1='RM', sz='W16')], regs=[0], pg=1, mode='pm')
define(0x00, lambda: [U(a='EA', e='SRD', rfix=6, sz='W16', wr='PRI')],
       lambda: [U(e='SRD', rfix=6, d1='RM', sz='W16')], regs=[1], pg=1, mode='pm')
for rg, ck in ((2, 'LDT'), (3, 'TSS')):
    def sysdsc(a, ck=ck, first=None):
        lo = U(a=a, aoff=0, mrd=1, e='DLO', ck=ck, sa=('RM' if a == 'DSCR' else 'T0'), sb='MEM',
               d1='T1', d2=('NONE' if a == 'DSCT' else 'T0'), sz='D32', chk='CPL0' if not first else 'NONE')
        hi = U(a=a, aoff=4, mrd=1, sec='DSCA', e='DHI', ck=ck, sa='T0', sb='MEM', sz='B',
               wr='SEC' if ck == 'TSS' else 'NONE')
        return (first or []) + [lo, hi]
    define(0x00, lambda sysdsc=sysdsc: sysdsc('DSCT', first=[U(a='EA', mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0',
                                                                 sz='W16', chk='CPL0')]),
           lambda sysdsc=sysdsc: sysdsc('DSCR'), regs=[rg], pg=1, mode='pm')

# far CALL: checks first, then the pushes; the last push loads CS
def far_call(first, a):
    return far_cs(first, a, 'CSC') + [U(sec='PUSH', e='PASSB', sb='CS', sz='Z', wr='SEC'),
                                      U(sec='PUSH', abr='BRI', e='LDCS', ck='CSC', sz='Z', wr='SEC')]
define(0x9A, lambda: far_call([U(e='PASSB', sb='DISP', d1='T2', sz='Z')], 'DSCI'), mode='pm')
define(0xFF, lambda: far_call([U(a='EA', mrd=1, e='PASSB', sb='MEM', d1='T2', sz='Z'),
                               U(a='EA2', mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16')], 'DSCT'),
       UD, regs=[3], mode='pm')
# far RET (n): EIP to T2, CS to T0
for op in (0xCA, 0xCB):
    define(op, lambda op=op: far_cs([U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T2', sz='Z'),
                                     U(a='POPN' if op == 0xCA else 'POP', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z')],
                                    'DSCT', 'CSR') + [U(abr='BRI', e='LDCS', ck='CSR', sz='Z')], mode='pm')
# IRET: EIP to T2, CS to T0, EFLAGS to T4; LDCS loads CS and the flags (from B = T4)
define(0xCF, lambda: far_cs([U(e='IRNT', sz='Z'),
                             U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T2', sz='Z'),
                             U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z'),
                             U(a='POP', mrd=1, e='IRVM', sb='MEM', d1='T4', sz='Z')], 'DSCT', 'CSI') +
       [U(e='LDCS', ck='CSI', sb='T4', sz='Z')], mode='pm')

# LAR / LSL (0F 02 / 03), VERR / VERW (0F 00 /4 /5): the selector to T0, the descriptor
# (LSL: low dword to T1) is read without faulting, ZF tells
def lar(ck, rd):
    def mk(m):
        first = [U(a='EA', mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16')] if m else []
        a = 'DSCT' if m else 'DSCR'
        sel = 'T0' if m else 'RM'
        lo = [U(a=a, aoff=0, mrd=1, e='DLO', ck='ACC', sa=sel, sb='MEM', d1='T1', sz='D32')] if ck == 'LSL' else []
        return first + lo + [U(a=a, aoff=4, mrd=1, e='LARV', ck=ck, sa=sel, sb='MEM', d1=('REG' if rd else 'NONE'),
                               sz=('Z' if rd else 'W16'))]
    return (lambda: mk(True)), (lambda: mk(False))
for op, ck in ((0x02, 'LAR'), (0x03, 'LSL')):
    m_, r_ = lar(ck, True)
    define(op, m_, r_, pg=1, mode='pm')
for rg, ck in ((4, 'VERR'), (5, 'VERW')):
    m_, r_ = lar(ck, False)
    define(0x00, m_, r_, regs=[rg], pg=1, mode='pm')
# ARPL r/m16, r16 (protected mode only)
define(0x63, lambda: [U(a='EA', mrd=1, e='ARPL', sa='MEM', sb='REG', sz='W16', wr='PRI')],
       lambda: [U(e='ARPL', sa='RM', sb='REG', d1='RM', sz='W16')], mode='pm')

# I/O instructions at CPL > IOPL (or V86): the I/O permission bitmap is checked first
# (decode dispatches here instead; port in DX or the immediate)
def iochk(port, body):
    return lambda: [U(a='TSSA', aoff=0x66, mrd=1, m16=1, e='IOMAP', sa=port, sb='MEM', d1='T0', sz='W16'),
                    U(a='TSS', aoff=0, mrd=1, e='IOBIT', sa=port, sb='MEM', sz='W16')] + body()
IOV = {}
for w in (0, 1):
    IOV[0xE4 | w] = iochk('IMM', lambda: [U(e='IN', sa='IMM', d1='ACC')])
    IOV[0xE6 | w] = iochk('IMM', lambda: [U(e='OUT', sa='IMM', sb='ACC')])
    IOV[0xEC | w] = iochk('DX', lambda: [U(e='IN', sa='DX', d1='ACC')])
    IOV[0xEE | w] = iochk('DX', lambda: [U(e='OUT', sa='DX', sb='ACC')])
    IOV[0x6C | w] = iochk('DX', lambda: [U(sec='STDI', repchk=1, e='IN', sa='DX', wr='SEC', label='self', endnr=1)])
    IOV[0x6E | w] = iochk('DX', lambda: [U(a='SI', mrd=1, repchk=1, e='OUT', sa='DX', sb='MEM', label='self', endnr=1)])

# Prefix / escape bytes: never dispatched (handled in decode) -> NOP entries.
for op in (0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x0F):
    define(op, lambda: [U(e='NOP')])

# Interrupt sequence (injected by decode; ctx.imm = vector, ctx.ip_next = return IP)
INT_SEQ = [U(a='VEC', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='W16'),
           U(a='VEC2', mrd=1, e='PASSB', sb='MEM', d1='T1', sz='W16'),
           U(sec='PUSH', e='INTFL', sz='W16', wr='SEC'),
           U(sec='PUSH', e='PASSB', sb='CS', sz='W16', wr='SEC'),
           U(sec='PUSH', e='JFAR', sa='T1', sb='T0', sz='W16', wr='SEC')]
# Protected-mode interrupt / exception entry (injected, vector in imm): the gate (DLO:
# IDT limit, DHI: type / DPL / present) leaves the new EIP in T2 and the selector in T0,
# then E micro-jumps to the frame sequence for the gate size (with or without an error
# code; operand size = gate size).
INT_PM = [U(a='IDT', aoff=0, mrd=1, e='DLO', ck='INTG', sb='MEM', d1='T1', sz='D32'),
          U(a='IDT', aoff=4, mrd=1, e='DHI', ck='INTG', sb='MEM', d1='T2', d2='T0', sz='D32')]
# (after a stack switch the CS accessed bit is already set: stack_in's ACC uop; a second
# one would store again, its high dword in T3 being the copy read before)
def int_tail(ck, sv=0, acc=True):
    return ([U(sec='PUSH', e='EFL', sz='Z', wr='SEC', sv=sv),
             U(sec='PUSH', e='PASSB', sb='CS', sz='SEL', wr='SEC', sv=sv),
             U(sec='PUSH', e='PASSB', sb='IPN', sz='Z', wr='SEC', sv=sv),
             U(sec='PUSH', e='PASSB', sb='ERRC', sz='Z', wr='SEC', ifec=1, sv=sv)] +
            ([U(a='DSCT', aoff=4, sec='DSCA', e='DHI', ck='ACC', sa='T0', sb='T3', sz='B', wr='SEC')] if acc else []) +
            [U(e='LDCS', ck=ck, sz='Z')])
INT_FRAME = ([U(a='DSCT', aoff=0, mrd=1, e='DLO', ck='INTCS', sa='T0', sb='MEM', d1='T1', sz='D32'),
              U(a='DSCT', aoff=4, mrd=1, e='DHI', ck='INTCS', sa='T0', sb='MEM', d2='T3', sz='D32')] +
             int_tail('INTCS'))
# Stack switch to the inner level (CALL through a gate, interrupt): CS selector, low and
# high dword in T0 / T1 / T3, EIP in T2.  Old SS -> T4, old (E)SP -> T9, CS selector -> T6,
# new (E)SP -> T7; SS is loaded (low dword in T5), then (E)SP.
def stack_in(params, v86=False, gate=True):
    sq = [U(e='PASSB', sb='SSR', d1='T4', sz='W16'),
          U(e='OLDSP', d1='T9', sz='D32') if gate else U(e='PASSB', sb='FIX', rfix=4, d1='T9', sz='D32')]
    if params:
        sq += [U(e='PADDR', d1='T8', sz='D32')]
    sq += [U(e='PASSB', sb='T0', d1='T6', sz='D32'),
           U(e='TSSOFF', sa='T3', d1='T0', sz='D32'),
           U(a='TSS', aoff=0, mrd=1, e='PASSB', sb='MEM', d1='T7', sz='TSZ'),
           U(a='TSS', aoff=4, mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16'),
           U(a='DSCT', aoff=0, mrd=1, e='DLO', ck='NSS', sa='T0', sb='MEM', d1='T5', sz='D32'),
           U(a='DSCT', aoff=4, mrd=1, sec='DSCA', e='DHI', ck='NSS', sa='T0', sb='MEM', d1='SSR',
             sz='B', wr='SEC'),
           U(e='LDSP', sb='T7', d1='FIX', rfix=4, sz='D32'),
           U(e='PASSB', sb='T6', d1='T0', sz='D32'),
           U(a='DSCT', aoff=4, sec='DSCA', e='DHI', ck='ACC', sa='T0', sb='T3', sz='B', wr='SEC')]
    # (the pushes onto the new stack: supervisor accesses, CS / CPL is loaded last)
    if v86:
        sq += [U(sec='PUSH', e='PASSB', sb='SEGF', rfix=r, sz='SEL', wr='SEC', sv=1) for r in (5, 4, 3, 0)]
        sq += [U(e='SEGNUL', rfix=r, sz='W16') for r in (3, 0, 4, 5)]
    sq += [U(sec='PUSH', e='PASSB', sb='T4', sz='SEL', wr='SEC', sv=1),
           U(sec='PUSH', e='PASSB', sb='T9', sz='Z', wr='SEC', sv=1)]
    if params:
        # copy the parameters (count from the gate) from the old stack, last one first
        sq += [U(e='PASSB', sb='T8', d1='T0', sz='D32', lp='X'),
               U(e='SUBNF', sa='T0', sb='OPSZ', d1='T0', sz='D32', label='top'),
               U(a='LIN', mrd=1, sec='PUSH', e='PASSB', sb='MEM', sz='Z', wr='SEC', goto='top', lp='X'),
               U(e='PASSB', sb='T6', d1='T0', sz='D32', label='X')]
    return sq
# call gate (E micro-jumps here from the far CALL / JMP; gate in T0 (selector) / T1 / T3,
# operand size = the gate's): target EIP to T2, its selector to T0
def gate_seq(ck, tail):
    return [U(e='GATE', sa='T1', sb='T3', d1='T2', d2='T0', sz='D32'),
            U(a='DSCT', aoff=0, mrd=1, e='DLO', ck=ck, sa='T0', sb='MEM', d1='T1', sz='D32'),
            U(a='DSCT', aoff=4, mrd=1, sec='DSCA', e='DHI', ck=ck, sa='T0', sb='MEM', d2='T3', sz='B', wr='SEC')] + tail
CALLG  = gate_seq('CGC', [U(sec='PUSH', e='PASSB', sb='CS', sz='Z', wr='SEC'),
                          U(sec='PUSH', e='LDCS', ck='CSC', sz='Z', wr='SEC')])
JMPG   = gate_seq('CGJ', [U(e='LDCS', ck='CSJ', sz='Z')])
CALLGI = stack_in(True) + [U(sec='PUSH', e='PASSB', sb='CS', sz='Z', wr='SEC', sv=1),
                           U(sec='PUSH', e='LDCS', ck='CGI', sz='Z', wr='SEC', sv=1)]
INTI   = stack_in(False, gate=False) + int_tail('INTI', sv=1, acc=False)
INTV   = stack_in(False, v86=True, gate=False) + int_tail('INTI', sv=1, acc=False)
# IRETD to V86 (CPL 0, VM in the popped EFLAGS in T4; EIP T2, CS T0): pop ESP, SS, ES, DS,
# FS, GS; the data segments are loaded V86 style at once, SS and ESP after the pops
IRETV  = ([U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T7', sz='Z'),
           U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T5', sz='Z')] +
          [U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='SEGF', rfix=r, ck='V86', sz='Z') for r in (0, 3, 4, 5)] +
          [U(e='PASSB', sb='T7', d1='FIX', rfix=4, sz='D32'),
           U(e='PASSB', sb='T5', d1='SSR', ck='V86', sz='W16'),
           U(e='LDV86', sb='T4', sz='D32')])
# Return to an outer level (RET / IRET micro-jump; EIP T2, CS T0 / T1 / T3, IRET: EFLAGS T4):
# pop (E)SP -> T7, SS -> T0, load SS (low dword in T5), (E)SP (+ imm16 of RET n), null the
# data segments not valid at the new CPL, load CS.
def ret_out(ck, flg):
    return ([U(e='PASSB', sb='T0', d1='T6', sz='D32'),
             U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T7', sz='Z'),
             U(a='POP', mrd=1, e='PASSB', sb='MEM', d1='T0', sz='Z'),
             U(a='DSCT', aoff=0, mrd=1, e='DLO', ck='RSS', sa='T0', sb='MEM', d1='T5', sz='D32'),
             U(a='DSCT', aoff=4, mrd=1, sec='DSCA', e='DHI', ck='RSS', sa='T0', sb='MEM', d1='SSR',
               sz='B', wr='SEC'),
             U(e='LDSP', ck='RSS', sa='IMM', sb='T7', d1='FIX', rfix=4, sz='D32'),   # (+ imm16 of RET n)
             U(e='PASSB', sb='T6', d1='T0', sz='D32'),
             U(a='DSCT', aoff=4, sec='DSCA', e='DHI', ck='ACC', sa='T0', sb='T3', sz='B', wr='SEC')] +
            [U(e='SEGVAL', rfix=r, sz='W16') for r in (3, 0, 4, 5)] +
            [U(e='LDCS', ck=ck, sb=('T4' if flg else 'ZERO'), sz='Z')])
RETO  = ret_out('CSR', False)
# ---- task switch
# entries: far JMP / CALL to a TSS (TSWD: T0 / T1 / T3 = its selector / descriptor) or a
# task gate (TASKG: gate in T0 / T1), INT through a task gate (TASKI: TSS selector in T0),
# IRET with NT (IRETT: the back link).  E keeps the kind (JMP / CALL / INT / IRET).
def ttss(a='DSCT'):
    return [U(a=a, aoff=0, mrd=1, e='DLO', ck='TTSS', sa='T0', sb='MEM', d1='T1', sz='D32'),
            U(a=a, aoff=4, mrd=1, e='DHI', ck='TTSS', sa='T0', sb='MEM', d2='T3', sz='D32')]
TASKG = [U(e='GATE', sa='T1', sb='T3', d2='T0', sz='D32')] + ttss()
TASKI = ttss()
IRETT = [U(a='TSSA', aoff=0, mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16')] + ttss()
# TSWS: save (old TSS layout: 386 / 286), busy bits, link, commit (E micro-jumps here from
# DHI TTSS, by the old TSS type)
def tsw_save(t32):
    eip, flg, gpr, sel = (0x20, 0x24, 0x28, 0x48) if t32 else (0x0E, 0x10, 0x12, 0x22)
    sz, st = ('D32', 4) if t32 else ('W16', 2)
    sq = [U(e='TSSDESC', sa='T0', d1='T8', sz='D32'),
          U(e='PASSB', sb='T0', d1='T6', sz='D32'),
          U(a='TSSA', aoff=eip, e='PASSB', sb='IPN', sz=sz, wr='PRI'),
          U(a='TSSA', aoff=flg, e='TFLG', sz=sz, wr='PRI')]
    sq += [U(a='TSSA', aoff=gpr + st * r, e='PASSB', sb='FIX', rfix=r, sz=sz, wr='PRI') for r in range(8)]
    sq += [U(a='TSSA', aoff=sel + st * k, e='PASSB', sb='SEGF', rfix=k, sz=sz, wr='PRI')
           for k in (range(6) if t32 else range(4))]
    sq += [U(a='DSCT', aoff=4, mrd=1, sec='DSCA', e='DHI', ck='TBSY', sa='T0', sb='MEM', sz='B', wr='SEC'),
           U(e='PASSB', sb='TRS', d1='T0', sz='W16'),
           U(a='DSCT', aoff=4, mrd=1, sec='DSCA', e='DHI', ck='TFRE', sa='T0', sb='MEM', sz='B', wr='SEC'),
           U(e='PASSB', sb='T8', d1='T0', sz='D32'),
           U(a='LIN', aoff=0, e='TLNK', sb='TRS', sz='W16', wr='PRI'),
           U(e='PASSB', sb='T6', d1='T5', sz='D32'),
           # the new EIP in both layouts (386: T2, 286: T7); LDTSK keeps the one of the new TSS in T2
           U(a='LIN', aoff=0x20, mrd=1, e='PASSB', sb='MEM', d1='T2', sz='D32'),
           U(a='LIN', aoff=0x0E, mrd=1, m16=1, e='PASSB', sb='MEM', d1='T7', sz='W16'),
           U(e='PASSB', sb='T5', d1='T0', sz='D32'),
           U(e='LDTSK', d1='T2', sz='D32')]
    return sq
# TSWL: load the new task (new TSS layout; E micro-jumped here at the new EIP, a fault is
# taken in the new task): CR3, EFLAGS, registers, selectors, then the LDT, CS, SS and data
# segment descriptors (#TS); V86 tasks: segments V86 style
def tsw_load(t32, v86=False):
    flg, gpr, sel, ldt = (0x24, 0x28, 0x48, 0x60) if t32 else (0x10, 0x12, 0x22, 0x2A)
    sz, st = ('D32', 4) if t32 else ('W16', 2)
    segs = range(6) if t32 else range(4)
    sq = ([U(a='TSSA', aoff=0x1C, mrd=1, e='LDCR3', sb='MEM', sz='D32')] if t32 else [])
    sq += [U(a='TSSA', aoff=flg, mrd=1, e='TLFL', sb='MEM', sz=sz)]
    if t32:
        sq += [U(a='TSSA', aoff=0x64, mrd=1, e='TBIT', sb='MEM', sz='B')]
    sq += [U(a='TSSA', aoff=gpr + st * r, mrd=1, m16=(0 if t32 else 1), e=('PASSB' if t32 else 'TLDW'), sb='MEM',
             d1='FIX', rfix=r, sz='D32') for r in range(8)]
    if v86:
        sq += [U(a='TSSA', aoff=sel + st * k, mrd=1, m16=1, e='PASSB', sb='MEM', d1='SEGF', rfix=k, ck='V86', sz='W16')
               for k in segs if k != 1]
        sq += [U(a='TSSA', aoff=ldt, mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16'),
               U(a='DSCT', aoff=0, mrd=1, e='DLO', ck='TLDT', sa='T0', sb='MEM', d1='T1', sz='D32'),
               U(a='DSCT', aoff=4, mrd=1, e='DHI', ck='TLDT', sa='T0', sb='MEM', sz='D32'),
               U(a='TSSA', aoff=sel + st, mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16'),
               # (EFLAGS image again from the TSS: the FLAGS operand source reads 0 here)
               U(a='TSSA', aoff=flg, mrd=1, e='LDV86', sb='MEM', sz='D32')]
        return sq
    sq += [U(a='TSSA', aoff=sel + st * k, mrd=1, m16=1, e='PASSB', sb='MEM', d1='SEGF', rfix=k, ck='SELO', sz='W16')
           for k in segs]
    if not t32:
        # a 286 TSS has no FS / GS: both null (80386 microcode LOAD_TASK_16: 0 -> FS, 0 -> GS)
        sq += [U(e='SEGNUL', rfix=r, sz='W16') for r in (4, 5)]
    sq += [U(a='TSSA', aoff=ldt, mrd=1, m16=1, e='PASSB', sb='MEM', d1='T0', sz='W16'),
           U(a='DSCT', aoff=0, mrd=1, e='DLO', ck='TLDT', sa='T0', sb='MEM', d1='T1', sz='D32'),
           U(a='DSCT', aoff=4, mrd=1, e='DHI', ck='TLDT', sa='T0', sb='MEM', sz='D32'),
           U(e='PASSB', sb='SEGF', rfix=1, d1='T0', sz='W16'),
           U(a='DSCT', aoff=0, mrd=1, e='DLO', ck='TCS', sa='T0', sb='MEM', d1='T1', sz='D32'),
           U(a='DSCT', aoff=4, mrd=1, e='DHI', ck='TCS', sa='T0', sb='MEM', d2='T3', sz='D32')]
    for k in [2] + [r for r in (3, 0, 4, 5) if r in segs]:
        ck = 'TSSS' if k == 2 else 'TDS'
        sq += [U(e='PASSB', sb='SEGF', rfix=k, d1='T0', sz='W16'),
               U(a='DSCT', aoff=0, mrd=1, e='DLO', ck=ck, sa='T0', sb='MEM', d1='T5', sz='D32'),
               U(a='DSCT', aoff=4, mrd=1, sec='DSCA', e='DHI', ck=ck, rfix=k, sa='T0', sb='MEM',
                 d1=('SSR' if k == 2 else 'SEGF'), sz='B', wr='SEC')]
    sq += [U(sec='PUSH', e='PASSB', sb='ERRC', sz='TSZ', wr='SEC', ifec=1),
           U(e='PASSB', sb='SEGF', rfix=1, d1='T0', sz='W16'),
           U(a='DSCT', aoff=4, sec='DSCA', e='DHI', ck='ACC', sa='T0', sb='T3', sz='B', wr='SEC'),
           U(e='LDCS', ck='TCS', sz=('D32' if t32 else 'W16'))]
    return sq
IRETO = ret_out('CSI', True)
# inject entry points (E selects one by id)
INJ = [('INT_RM', INT_SEQ), ('INT_PM', INT_PM), ('INTF', INT_FRAME), ('CALLG', CALLG), ('JMPG', JMPG),
       ('CALLGI', CALLGI), ('INTI', INTI), ('RETO', RETO), ('IRETO', IRETO), ('INTV', INTV), ('IRETV', IRETV),
       ('TASKG', TASKG), ('TASKI', TASKI), ('IRETT', IRETT), ('TSWS32', tsw_save(True)), ('TSWS16', tsw_save(False)),
       ('TSWL32', tsw_load(True)), ('TSWL16', tsw_load(False)), ('TSWV86', tsw_load(True, True))]

# REP-exhausted retire marker: A turns a killed rep iteration into this.

# everything not defined raises #UD
for pg in (0, 1):
    for op in range(256):
        if (pg, op) in GROUPS:
            for mod3 in (0, 1):
                disp[(pg << 9) | (op << 1) | mod3] = UD()      # (unused dispatch slot of a group opcode)
            for reg in range(8):
                for mod3 in (0, 1):
                    disp.setdefault(didx(pg, op, mod3, reg), UD())
        else:
            for mod3 in (0, 1):
                disp.setdefault(didx(pg, op, mod3), UD())

# ----------------------------------------------------------- assemble
rom = [None] * ROM_DEPTH
next_free = CONT_BASE


def alloc(n=1):
    """n consecutive continuation addresses (outside both dispatch areas)"""
    global next_free
    a = next_free
    next_free += n
    return a


PRE_T = ('T4', 'T5', 'T6', 'T7', 'T8', 'T9')


def place(seq, first_addr=None):
    """Place a sequence; first uop at first_addr (dispatch) or allocated."""
    global next_free
    for a, b in zip(seq, seq[1:]):
        if not b.goto and not a.goto:
            for t in PRE_T:
                assert not ((a.d1 == t or a.d2 == t) and (b.sa == t or b.sb == t)), ('T4..T9 read right after the write', t)
    lab = {}
    for u in seq:
        if u.label:
            lab[u.label] = u
    # micro-loop pairs: successor at an even address, exit uop right after it
    for i, u in enumerate(seq):
        if u.lp:
            n = lab[u.goto] if u.goto else seq[i + 1]
            x = lab[u.lp]
            assert n is not seq[0] and x is not seq[0]
            assert x.af()[:4] == (0, 0, 0, 0), 'loop exit uop must not use the A stage'
            if n.addr is None:
                assert x.addr is None
                if next_free & 1:
                    alloc()
                n.addr = alloc(2)
                x.addr = n.addr + 1
            assert x.addr == n.addr + 1
    for i, u in enumerate(seq):
        if i == 0 and first_addr is not None:
            u.addr = first_addr
        elif u.addr is None:
            u.addr = alloc()
    for i, u in enumerate(seq):
        if u.goto:
            u.nxt = lab[u.goto]
        elif u.label == 'self' and u.endnr:
            u.nxt = u
        elif i + 1 < len(seq):
            u.nxt = seq[i + 1]
        else:
            u.nxt = None
            u.last = 1
        if u.nxt is None:
            u.last = 1
        rom[u.addr] = u


for idx in sorted(disp):
    place(disp[idx], idx)
PM_ENT = {}         # dispatch index -> the protected-mode sequence (its first uop)
for idx in sorted(disp_pm):
    place(disp_pm[idx])
    PM_ENT[idx] = disp_pm[idx][0]
INJ_ADDR = {}
for n, sq in INJ:
    place(sq)
    INJ_ADDR[n] = sq[0].addr
INT_ENTRY = INJ_ADDR['INT_RM']
IOV_SEQ = {}
for op in sorted(IOV):
    IOV_SEQ[op] = IOV[op]()
    place(IOV_SEQ[op])
assert next_free <= ROM_DEPTH, next_free


def word(u):
    v = 0

    def put(name, val):
        nonlocal v
        p, w = LAYOUT[name]
        assert 0 <= val < (1 << w), (name, val)
        v |= val << p
    if u is None:
        u = U()
        u.last = 1
    nx = u.nxt
    if nx is not None:
        am, se, rc, ab, il, en, az, ao, ie = nx.af()
        put('na_amode', am); put('na_sec', se); put('na_repchk', rc); put('na_abr', ab)
        put('na_islast', il); put('na_endnr', en); put('na_asz', az); put('na_aoff', ao); put('na_ifec', ie)
        put('next', nx.addr)
    put('last', u.last)
    put('endnr', u.endnr)
    put('mrd', u.mrd)
    put('eop', enc_enum(EOP, u.e))
    put('sa', enc_enum(SRC, u.sa))
    put('sb', enc_enum(SRC, u.sb))
    put('d1', enc_enum(DST, u.d1))
    put('d2', enc_enum(DST, u.d2))
    put('esz', enc_enum(ESZ, u.sz))
    put('wr', enc_enum(WR, u.wr))
    put('repz', u.repz)
    put('rfix', u.rfix)
    put('m16', u.m16)
    put('lp', 1 if u.lp else 0)
    put('ck', enc_enum(CK, u.ck))
    put('chk', enc_enum(CHK, u.chk))
    put('sv', u.sv)
    return v


def af_val(u):
    v = 0
    p = 0
    for (n, w), x in zip(AF_FIELDS, u.af()):
        v |= x << p
        p += w
    return v


def classes(pg, limit):
    """class ids of (af(mod!=3), af(mod==3)) for the non-group opcodes of a page"""
    pairs, cls = [], {}
    for op in range(256):
        if (pg, op) in GROUPS:
            continue
        pr = (af_val(disp[didx(pg, op, 0)][0]), af_val(disp[didx(pg, op, 1)][0]))
        if pr not in pairs:
            pairs.append(pr)
        cls[op] = pairs.index(pr)
    assert len(pairs) <= limit, (pg, len(pairs))
    return pairs, cls


def main():
    os.makedirs(OUT, exist_ok=True)
    hexw = (UW_BITS + 3) // 4
    with open(os.path.join(OUT, 'ucode_rom.hex'), 'w') as f:
        for u in rom:
            f.write('%0*x\n' % (hexw, word(u)))
    # package
    L = []
    L.append('// Generated by ucode/ucgen.py -- do not edit')
    L.append('package tetrium_pkg;')
    L.append(f'  localparam int UW_BITS = {UW_BITS};')
    L.append(f'  localparam int ROM_DEPTH = {ROM_DEPTH};')
    L.append(f'  localparam int ROM_AW = {(ROM_DEPTH - 1).bit_length()};')
    L.append(f'  localparam int GROUP_BASE = {GROUP_BASE};')
    L.append(f'  localparam int INT_ENTRY = {INT_ENTRY};')
    L.append(f'  localparam int AF_BITS = {AF_BITS};')
    for n, (p, w) in LAYOUT.items():
        L.append(f'  localparam int UW_{n.upper()}_L = {p}, UW_{n.upper()}_W = {w};')
    p = 0
    for n, w in AF_FIELDS:
        L.append(f'  localparam int AF_{n.upper()}_L = {p}, AF_{n.upper()}_W = {w};')
        p += w
    for pre, lst in (('AM', AMODE), ('SEC', SEC), ('ABR', ABR), ('E', EOP), ('S', SRC),
                     ('D', DST), ('SZ', ESZ), ('WR', WR), ('CK', CK), ('CHK', CHK)):
        for i, n in enumerate(lst):
            L.append(f'  localparam int {pre}_{n} = {i};')
    L.append(f'  localparam logic [AF_BITS-1:0] INT_FIRST_AF = {AF_BITS}\'d{af_val(INT_SEQ[0])};')
    for i, (n, sq) in enumerate(INJ):
        L.append(f'  localparam int INJ_{n} = {i};')
    L.append('  // I/O instructions with the permission bitmap check: {hit, ROM address, first-uop A fields}')
    L.append('  function automatic logic [ROM_AW+AF_BITS:0] io_ent(input logic [7:0] op);')
    L.append('    case (op)')
    for op, sq in sorted(IOV_SEQ.items()):
        L.append(f"      8'h{op:02X}: return {{1'b1, {(ROM_DEPTH - 1).bit_length()}'d{sq[0].addr}, {AF_BITS}'d{af_val(sq[0])}}};")
    L.append(f"      default: return '0;")
    L.append('    endcase')
    L.append('  endfunction')
    L.append('  // inject entry points: ROM address and first-uop A fields by id')
    L.append('  function automatic logic [ROM_AW+AF_BITS-1:0] inj_ent(input logic [4:0] id);')
    L.append('    case (id)')
    for i, (n, sq) in enumerate(INJ):
        L.append(f"      5'd{i}: return {{{(ROM_DEPTH - 1).bit_length()}'d{INJ_ADDR[n]}, {AF_BITS}'d{af_val(sq[0])}}};")
    L.append(f"      default: return '0;")
    L.append('    endcase')
    L.append('  endfunction')
    L.append('endpackage')
    with open(os.path.join(OUT, 'tetrium_pkg.sv'), 'w') as f:
        f.write(SPDX + '\n'.join(L) + '\n')
    # ---- compact first-uop A-field tables for the decoder
    #   opclass(op) / opclass0f(op): class id of (af(mod!=3), af(mod==3)) per page
    #   class_af(cls, mod3) / class0f_af(cls, mod3), grp_af({group, reg, mod3})
    C = ['// Generated by ucode/ucgen.py -- do not edit']
    for pg, fn, bits, limit in ((0, '', 5, 32), (1, '0f', 4, 15)):
        pairs, cls = classes(pg, limit)
        C += [f'function automatic logic [{bits-1}:0] opclass{fn}(input logic [7:0] op);', '  case (op)']
        byc = {}
        for op, c in cls.items():
            byc.setdefault(c, []).append(op)
        for c, ops in sorted(byc.items()):
            if c == 0:
                continue
            C.append('    ' + ', '.join(f"8'h{o:02X}" for o in ops) + f": opclass{fn} = {bits}'d{c};")
        C += [f"    default: opclass{fn} = {bits}'d0;", '  endcase', 'endfunction',
              f'function automatic logic [{AF_BITS-1}:0] class{fn}_af(input logic [{bits-1}:0] c, input logic m3);',
              '  case ({c, m3})']
        for c, (m, r) in enumerate(pairs):
            C.append(f"    {bits+1}'d{2*c}: class{fn}_af = {AF_BITS}'d{m};")
            C.append(f"    {bits+1}'d{2*c+1}: class{fn}_af = {AF_BITS}'d{r};")
        C += [f"    default: class{fn}_af = {AF_BITS}'d0;", '  endcase', 'endfunction']
        print(f'ucode: page {pg}: {len(pairs)} opcode classes')
    # protected-mode sequences: {hit, ROM address, first-uop A fields}, one table by
    # {page, opcode, mod3} and one by {group, reg, mod3} (selected by grp after the lookup)
    aw = (ROM_DEPTH - 1).bit_length()
    for fn, kb, sel in (('pm_ent_n', 10, lambda k: k < GROUP_BASE), ('pm_ent_g', 7, lambda k: k >= GROUP_BASE)):
        C += [f'function automatic logic [{aw + AF_BITS}:0] {fn}(input logic [{kb-1}:0] k);', '  case (k)']
        for k, v in sorted(PM_ENT.items()):
            if sel(k):
                kk = k - GROUP_BASE if k >= GROUP_BASE else k
                C.append(f"    {kb}'d{kk}: {fn} = {{1'b1, {aw}'d{v.addr}, {AF_BITS}'d{af_val(v)}}};")
        C += [f"    default: {fn} = '0;", '  endcase', 'endfunction']
    print(f'ucode: {len(PM_ENT)} protected-mode dispatch entries')
    C += [f'function automatic logic [{AF_BITS-1}:0] grp_af(input logic [6:0] k);   // {{group, reg, mod3}}',
          '  case (k)']
    for k in range(16 * 7):
        C.append(f"    7'd{k}: grp_af = {AF_BITS}'d{af_val(disp[GROUP_BASE + k][0])};")
    C += [f"    default: grp_af = {AF_BITS}'d0;", '  endcase', 'endfunction']
    with open(os.path.join(OUT, 'ucode_class.svh'), 'w') as f:
        f.write(SPDX + '\n'.join(C) + '\n')
    M = ['// Generated by ucode/ucgen.py -- do not edit']
    for m in (9, 17):
        M.append(f'function automatic logic [4:0] mod{m}(input logic [7:0] n);')
        M.append('  case (n)')
        for n in range(256):
            M.append(f"    8'd{n}: mod{m} = 5'd{n % m};")
        M.append(f"    default: mod{m} = 5'd0;")
        M.append('  endcase')
        M.append('endfunction')
    with open(os.path.join(OUT, 'modtab.svh'), 'w') as f:
        f.write(SPDX + '\n'.join(M) + '\n')
    print(f'ucode: {next_free} words used, INT_ENTRY={INT_ENTRY}, fields={pos} bits')


if __name__ == '__main__':
    main()
