#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Random workloads for the hardware stress kernel (tests/hwstress).

usage: gen.py <outdir> <seed>     ->  <outdir>/wl16.s (V86, linked at 0, CS = 2000h)
                                       <outdir>/wl32.s (flat 32-bit, linked at 30000h)

Every workload is deterministic: its final registers and the memory it wrote depend only on
the initial registers / data the kernel gives it.  The kernel runs each one quiet (no IRQs)
and then many times under interrupt / paging stress; any difference is a CPU bug.

Address rules (no faults except the kernel's own demand-paging ones):
  V86   data segments 4000 5000 6000 7000 (DS ES FS GS, any 16-bit offset <= FFF0),
        stack segment 8000: offsets below E000 are data (hashed), the stack lives above;
        IRQ handlers use segment 0100 (offsets < 4000, not hashed) and never write elsewhere.
  32    sandbox 100000-147FFF (hashed), FS = selector 33h (base 100000, limit FFFF),
        stack 148000-14FFFF (far pointer table at 148000), code 30000-3FFFF.
Registers used as address bases are masked right before use (the masking is part of the
deterministic program).  ESP / SP are never general operands.  Loop bodies leave (E)CX alone.
"""
import random, sys, os

R16 = ['ax', 'bx', 'cx', 'dx', 'si', 'di', 'bp']
R32 = ['eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'ebp']
R8 = ['al', 'ah', 'bl', 'bh', 'cl', 'ch', 'dl', 'dh']
# register families: a b c d si di bp
FAM = {}
for f, names in (('a', 'al ah ax eax'), ('b', 'bl bh bx ebx'), ('c', 'cl ch cx ecx'), ('d', 'dl dh dx edx'),
                 ('si', 'si esi'), ('di', 'di edi'), ('bp', 'bp ebp')):
    for n in names.split(): FAM[n] = f
def fam(r): return FAM[r]
CC = ['o', 'no', 'b', 'ae', 'e', 'ne', 'be', 'a', 's', 'ns', 'p', 'np', 'l', 'ge', 'le', 'g']
PTR = {8: 'byte ptr', 16: 'word ptr', 32: 'dword ptr'}
S32 = 0x100000          # 32-bit sandbox base
# 16-bit data segments: GDT selectors = real-mode values, and LDT selectors (TI, RPL 3) whose
# real-mode / V86 meaning (segment 4007h = base 40070h) stays inside the sandbox too
SEGS16 = [0x4000, 0x5000, 0x6000, 0x7000, 0x4007, 0x5007, 0x6007, 0x7007]
RNUM = {'ax': 0, 'cx': 1, 'dx': 2, 'bx': 3, 'bp': 5, 'si': 6, 'di': 7,
        'eax': 0, 'ecx': 1, 'edx': 2, 'ebx': 3, 'ebp': 5, 'esi': 6, 'edi': 7}
VPORTS = list(range(0xE0, 0xE8))         # trapped "virtual device" ports (IOPM), unmapped in the system
VPORTS_DX = list(range(0x2E0, 0x2E8))


class Ctx:
    def __init__(self, mode, avoid=(), depth=0, irq=False, allow_call=True, allow_int=True, nsub=0, fsub=0, rsub=0):
        self.mode, self.avoid, self.depth, self.irq = mode, set(avoid), depth, irq
        self.allow_call, self.allow_int = allow_call, allow_int
        self.nsub, self.fsub, self.rsub = nsub, fsub, rsub

    def sub(self, **kw):
        c = Ctx(self.mode, self.avoid, self.depth + 1, self.irq, self.allow_call, self.allow_int,
                self.nsub, self.fsub, self.rsub)
        for k, v in kw.items(): setattr(c, k, v)
        return c


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.lab = 0
        self.ftab = []         # (key label, resume label): key = the faulting instruction (traps: the next one)

    def L(self):
        self.lab += 1
        return '.L%d' % self.lab

    # ---------------------------------------------------------------- registers
    def regs(self, ctx, size, write=True):
        rr = {8: R8, 16: R16, 32: R32}[size]
        if size == 8:
            pass
        return [r for r in rr if not (write and fam(r) in ctx.avoid)]

    def reg(self, ctx, size, write=True, excl=()):
        c = [r for r in self.regs(ctx, size, write) if fam(r) not in excl]
        return self.r.choice(c) if c else None

    def wsize(self, ctx):
        return self.r.choice([8, 16, 16, 32, 32] if ctx.mode == 32 else [8, 8, 16, 16, 16, 32])

    def imm(self, size):
        r = self.r.random()
        if r < 0.2: return self.r.choice([0, 1, (1 << size) - 1, 1 << (size - 1), (1 << (size - 1)) - 1])
        if r < 0.4: return self.r.randrange(0, 128)
        return self.r.getrandbits(size)

    def bigreg(self, r):
        """the 16/32-bit register of a family (for masking)"""
        f = fam(r)
        return f

    def r16of(self, f): return {'a': 'ax', 'b': 'bx', 'c': 'cx', 'd': 'dx'}.get(f, f)
    def r32of(self, f): return 'e' + self.r16of(f)

    # ---------------------------------------------------------------- memory operands
    def mem(self, ctx, size, margin=0):
        """(setup lines, operand) of a memory operand in the sandbox.  margin: extra bytes past
        the operand that may be touched (bit-string offsets)."""
        r = self.r
        if ctx.mode == 16:
            return self.mem16(ctx, size, margin)
        return self.mem32(ctx, size, margin)

    def mem16(self, ctx, size, margin):
        r = self.r
        pre = []
        # IRQ handlers: segment 0100 scratch through DS / ES only, offsets < 4000
        if ctx.irq:
            seg = r.choice(['ds', 'es'])
            lim = 0x3F00
        else:
            seg = r.choice(['', '', 'ds', 'es', 'fs', 'gs', 'ss'])
            lim = 0xDF00 if seg == 'ss' else 0xFF00
        lim -= margin
        w = [f for f in ('b', 'si', 'di', 'bp', 'a', 'c', 'd') if f not in ctx.avoid]
        form = r.choice(['abs', 'abs', 'b', 'bi', 'r32'])
        if form == 'abs' or not w:
            off = r.randrange(0, lim)
            if r.random() < 0.3: off = (off & ~0xFFF) + r.choice([0xFFE, 0xFFD, 0xFFF, 0xFFC]) if off + 0x1000 < lim else off
            return pre, '%s %s:[0x%x]' % (PTR[size], seg or 'ds', off)
        if form == 'b':
            bases = [f for f in ('b', 'si', 'di', 'bp') if f not in ctx.avoid]
            if ctx.irq: bases = [f for f in bases if f != 'bp']
            if not bases: return pre, '%s %s:[0x%x]' % (PTR[size], seg or 'ds', r.randrange(0, lim))
            b = r.choice(bases)
            if b == 'bp' and not seg: lim = 0xDF00 - margin       # SS: the data part only
            breg = self.r16of(b)
            half = lim // 2
            m = (1 << (half.bit_length() - 1)) - 1
            m &= ~r.choice([0, 1, 3, 7])
            pre.append('and %s, 0x%x' % (breg, m))
            disp = r.randrange(0, lim - m) if lim > m else 0
            eff_seg = seg if seg else ('ss' if b == 'bp' else 'ds')
            if eff_seg == 'ss' and not seg:
                # bp-based: SS (stack segment), data part below E000
                if m + disp > 0xDF00 - margin: disp = max(0, 0xDF00 - margin - m)
            return pre, '%s %s[%s+0x%x]' % (PTR[size], (seg + ':') if seg else '', breg, disp)
        if form == 'bi':
            pairs = [p for p in (('b', 'si'), ('b', 'di'), ('bp', 'si'), ('bp', 'di'))
                     if p[0] not in ctx.avoid and p[1] not in ctx.avoid]
            if ctx.irq: pairs = [p for p in pairs if p[0] != 'bp']
            if not pairs: return pre, '%s %s:[0x%x]' % (PTR[size], seg or 'ds', r.randrange(0, lim))
            b, i = r.choice(pairs)
            if b == 'bp' and not seg: lim = 0xDF00 - margin
            q = lim // 3
            m = (1 << (q.bit_length() - 1)) - 1
            pre.append('and %s, 0x%x' % (self.r16of(b), m))
            pre.append('and %s, 0x%x' % (self.r16of(i), m & ~r.choice([0, 1, 3])))
            disp = r.randrange(0, max(1, lim - 2 * m))
            return pre, '%s %s[%s+%s+0x%x]' % (PTR[size], (seg + ':') if seg else '', self.r16of(b), self.r16of(i), disp)
        # 32-bit addressing in V86 (67): base [+ index*scale], all masked below 64 KB
        bases = [f for f in ('a', 'b', 'c', 'd', 'si', 'di', 'bp') if f not in ctx.avoid]
        if ctx.irq: bases = [f for f in bases if f != 'bp']
        if not bases: return pre, '%s %s:[0x%x]' % (PTR[size], seg or 'ds', r.randrange(0, lim))
        b = r.choice(bases)
        if b == 'bp' and not seg: lim = 0xDF00 - margin
        q = lim // 3
        m = (1 << (q.bit_length() - 1)) - 1
        pre.append('and %s, 0x%x' % (self.r32of(b), m))
        idx = [f for f in bases if f != b]
        if idx and r.random() < 0.6:
            i = r.choice(idx)
            sc = r.choice([1, 2, 4])
            mi = m // sc
            pre.append('and %s, 0x%x' % (self.r32of(i), mi))
            disp = r.randrange(0, max(1, lim - 2 * m))
            return pre, '%s %s[%s+%s*%d+0x%x]' % (PTR[size], (seg + ':') if seg else '', self.r32of(b), self.r32of(i), sc, disp)
        disp = r.randrange(0, max(1, lim - m))
        return pre, '%s %s[%s+0x%x]' % (PTR[size], (seg + ':') if seg else '', self.r32of(b), disp)

    def mem32(self, ctx, size, margin):
        r = self.r
        pre = []
        lim = 0x48000 - 0x100 - margin
        bases = [f for f in ('a', 'b', 'c', 'd', 'si', 'di', 'bp') if f not in ctx.avoid]
        form = r.choice(['abs', 'abs', 'b', 'bi', 'fs'])
        if not bases: form = 'abs'
        if form == 'abs':
            off = r.randrange(0, lim)
            if r.random() < 0.4: off = min(lim - 1, (off & ~0xFFF) + r.choice([0xFFE, 0xFFD, 0xFFF, 0xFFC, 0xFFB, 0xFF9]))
            return pre, '%s ds:[0x%x]' % (PTR[size], S32 + off)
        if form == 'b':
            b = r.choice(bases)
            m = r.choice([0x3FFFF, 0x3FFFC, 0x3FFF8, 0xFFF, 0x1FFF])
            pre.append('and %s, 0x%x' % (self.r32of(b), m))
            disp = S32 + r.randrange(0, lim - m)
            return pre, '%s [%s+0x%x]' % (PTR[size], self.r32of(b), disp)
        if form == 'bi':
            b = r.choice(bases)
            pre.append('and %s, 0x%x' % (self.r32of(b), 0x1FFFF & ~r.choice([0, 3])))
            idx = [f for f in bases if f != b]
            if not idx:
                return pre, '%s [%s+0x%x]' % (PTR[size], self.r32of(b), S32 + r.randrange(0, lim - 0x20000))
            i = r.choice(idx)
            sc = r.choice([1, 2, 4, 8])
            pre.append('and %s, 0x%x' % (self.r32of(i), 0x3FFF))
            disp = S32 + r.randrange(0, lim - 0x20000 - 0x3FFF * 8)
            return pre, '%s [%s+%s*%d+0x%x]' % (PTR[size], self.r32of(b), self.r32of(i), sc, disp)
        # FS (base 100000, limit FFFF)
        b = r.choice(bases)
        m = r.choice([0x7FFF, 0x7FF8, 0x7FFC])
        pre.append('and %s, 0x%x' % (self.r32of(b), m))
        disp = r.randrange(0, 0x7F00 - margin)
        return pre, '%s fs:[%s+0x%x]' % (PTR[size], self.r32of(b), disp)

    def rm(self, ctx, size, write=True):
        """register or memory operand: (setup, operand)"""
        if self.r.random() < 0.45:
            m = self.reg(ctx, size, write)
            if m: return [], m
        return self.mem(ctx, size)

    def sreg(self, size, f):
        return {8: None, 16: self.r16of(f), 32: self.r32of(f)}[size]

    # ---------------------------------------------------------------- items
    def item(self, ctx):
        r = self.r
        mode = ctx.mode
        kinds = [('alu', 14), ('un', 4), ('shift', 6), ('shd', 2), ('mul', 3), ('div', 3), ('mov', 8),
                 ('movx', 3), ('lea', 2), ('xchg', 2), ('xadd', 2), ('cmpxchg', 2), ('bswap', 1),
                 ('cvt', 1), ('lahf', 1), ('setcc', 2), ('bt', 3), ('bsf', 1), ('xlat', 1), ('bcd', 1),
                 ('push', 4), ('pushf', 2), ('popf', 2), ('pusha', 1), ('jcc', 4), ('loop', 2), ('str', 5),
                 ('seg', 2), ('lock', 2), ('cpuid', 0.3), ('enter', 1)]
        if ctx.allow_call and not ctx.irq: kinds += [('call', 3), ('fcall', 1), ('rcall', 1)]
        if ctx.allow_int and not ctx.irq: kinds += [('int', 2)]
        if mode == 16 and not ctx.irq: kinds += [('cli', 1.5)]
        if mode == 32: kinds += [('sys32', 0.5)]
        if not ctx.irq:
            kinds += [('fault', 2.5), ('io', 1.5), ('smc', 1.5)]
            if mode == 32: kinds += [('gate', 1), ('task', 0.6)]
        if ctx.depth >= 2: kinds = [k for k in kinds if k[0] not in ('jcc', 'loop', 'cli', 'pusha', 'enter')]
        tot = sum(w for _, w in kinds)
        x = r.random() * tot
        for k, w in kinds:
            x -= w
            if x < 0: break
        out = getattr(self, 'i_' + k)(ctx)
        return out if out is not None else []

    def items(self, ctx, n):
        out = []
        for _ in range(n): out += self.item(ctx)
        return out

    def i_alu(self, ctx):
        r = self.r
        op = r.choice(['add', 'adc', 'sub', 'sbb', 'and', 'or', 'xor', 'cmp', 'test'])
        size = self.wsize(ctx)
        wr = op not in ('cmp', 'test')
        f = r.random()
        if f < 0.3:
            d = self.reg(ctx, size, wr); s = self.reg(ctx, size, False)
            if not d: return []
            return ['%s %s, %s' % (op, d, s)]
        if f < 0.55:
            d = self.reg(ctx, size, wr)
            if not d: return []
            return ['%s %s, 0x%x' % (op, d, self.imm(size))]
        if f < 0.7 and op != 'test':
            d = self.reg(ctx, size, wr)
            if not d: return []
            pre, m = self.mem(ctx, size)
            return pre + ['%s %s, %s' % (op, d, m)]
        pre, m = self.mem(ctx, size)
        if r.random() < 0.5:
            s = self.reg(ctx, size, False)
            return pre + ['%s %s, %s' % (op, m, s)]
        if size > 8 and r.random() < 0.4 and op != 'test':
            return pre + ['%s %s, %d' % (op, m, r.randrange(-128, 128))]
        return pre + ['%s %s, 0x%x' % (op, m, self.imm(size))]

    def i_un(self, ctx):
        op = self.r.choice(['inc', 'dec', 'neg', 'not'])
        pre, d = self.rm(ctx, self.wsize(ctx))
        return pre + ['%s %s' % (op, d)]

    def i_shift(self, ctx):
        r = self.r
        op = r.choice(['rol', 'ror', 'rcl', 'rcr', 'shl', 'shr', 'sar', 'sal'])
        size = self.wsize(ctx)
        pre, d = self.rm(ctx, size)
        if d is None: return []
        c = r.random()
        if c < 0.3: return pre + ['%s %s, 1' % (op, d)]
        if c < 0.7: return pre + ['%s %s, %d' % (op, d, r.choice([0, 1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 24, 31, r.randrange(32)]))]
        if 'c' in ctx.avoid: return pre + ['%s %s, 1' % (op, d)]
        return pre + ['%s %s, cl' % (op, d)]

    def i_shd(self, ctx):
        r = self.r
        size = r.choice([16, 32])
        pre, d = self.rm(ctx, size)
        s = self.reg(ctx, size, False)
        op = r.choice(['shld', 'shrd'])
        if r.random() < 0.5 or 'c' in ctx.avoid:
            return pre + ['%s %s, %s, %d' % (op, d, s, r.randrange(32))]
        return pre + ['%s %s, %s, cl' % (op, d, s)]

    def i_mul(self, ctx):
        r = self.r
        size = self.wsize(ctx)
        f = r.random()
        if f < 0.4:
            if 'a' in ctx.avoid or (size > 8 and 'd' in ctx.avoid): return []
            pre, s = self.rm(ctx, size, False)
            return pre + ['%s %s' % (r.choice(['mul', 'imul']), s)]
        if size == 8: size = 16
        d = self.reg(ctx, size)
        if not d: return []
        pre, s = self.rm(ctx, size, False)
        if f < 0.7: return pre + ['imul %s, %s' % (d, s)]
        return pre + ['imul %s, %s, %d' % (d, s, r.choice([r.randrange(-128, 128), r.getrandbits(15) - 16384]))]

    def i_div(self, ctx):
        r = self.r
        if 'a' in ctx.avoid or 'd' in ctx.avoid: return []
        size = self.wsize(ctx)
        sgn = r.random() < 0.5
        dv = self.reg(ctx, size, True, excl=('a', 'd'))
        out = []
        A = {8: 'al', 16: 'ax', 32: 'eax'}[size]
        if size == 8:
            out.append('cbw' if sgn else 'xor ah, ah')
        elif size == 16:
            out.append('cwd' if sgn else 'xor dx, dx')
        else:
            out.append('cdq' if sgn else 'xor edx, edx')
        top = {8: 0x7F, 16: 0x7FFF, 32: 0x7FFFFFFF}[size]
        low = {8: 0x10, 16: 0x100, 32: 0x10000}[size]
        if dv and r.random() < 0.6:
            if sgn: out += ['and %s, 0x%x' % (dv, top), 'or %s, 0x%x' % (dv, low)]
            else: out += ['or %s, 1' % dv]
            out.append('%s %s' % ('idiv' if sgn else 'div', dv))
            return out
        # (the address registers must survive CBW / CWD / XOR AH / XOR DX of the dividend setup)
        pre, m = self.mem(ctx.sub(avoid=ctx.avoid | {'a', 'd'}), size)
        out = pre + out
        if sgn: out += ['and %s, 0x%x' % (m, top), 'or %s, 0x%x' % (m, low)]
        else: out += ['or %s, 1' % m]
        out.append('%s %s' % ('idiv' if sgn else 'div', m))
        return out

    def i_mov(self, ctx):
        r = self.r
        size = self.wsize(ctx)
        f = r.random()
        if f < 0.25:
            d = self.reg(ctx, size); s = self.reg(ctx, size, False)
            return ['mov %s, %s' % (d, s)] if d else []
        if f < 0.4:
            d = self.reg(ctx, size)
            return ['mov %s, 0x%x' % (d, self.imm(size))] if d else []
        if f < 0.7:
            d = self.reg(ctx, size)
            if not d: return []
            pre, m = self.mem(ctx, size)
            return pre + ['mov %s, %s' % (d, m)]
        pre, m = self.mem(ctx, size)
        if r.random() < 0.6:
            return pre + ['mov %s, %s' % (m, self.reg(ctx, size, False))]
        return pre + ['mov %s, 0x%x' % (m, self.imm(size))]

    def i_movx(self, ctx):
        r = self.r
        op = r.choice(['movzx', 'movsx'])
        ss = r.choice([8, 16])
        ds = 32 if ss == 16 else r.choice([16, 32])
        d = self.reg(ctx, ds)
        if not d: return []
        pre, s = self.rm(ctx, ss, False)
        return pre + ['%s %s, %s' % (op, d, s)]

    def i_lea(self, ctx):
        size = self.r.choice([16, 32])
        d = self.reg(ctx, size)
        if not d: return []
        pre, m = self.mem(ctx, 8)
        m = m.split('[', 1)[1]
        m = '[' + m
        return pre + ['lea %s, %s' % (d, m)]

    def i_xchg(self, ctx):
        size = self.wsize(ctx)
        d = self.reg(ctx, size)
        if not d: return []
        if self.r.random() < 0.5:
            s = self.reg(ctx, size)
            return ['xchg %s, %s' % (d, s)] if s else []
        pre, m = self.mem(ctx, size)
        return pre + ['xchg %s, %s' % (m, d)]

    def i_xadd(self, ctx):
        size = self.wsize(ctx)
        s = self.reg(ctx, size)
        if not s: return []
        pre, d = self.rm(ctx, size)
        return pre + ['xadd %s, %s' % (d, s)]

    def i_cmpxchg(self, ctx):
        if 'a' in ctx.avoid: return []
        size = self.wsize(ctx)
        s = self.reg(ctx, size, False)
        pre, d = self.rm(ctx, size)
        return pre + ['cmpxchg %s, %s' % (d, s)]

    def i_bswap(self, ctx):
        d = self.reg(ctx, 32)
        return ['bswap %s' % d] if d else []

    def i_cvt(self, ctx):
        r = self.r
        if 'a' in ctx.avoid: return []
        ops = ['cbw', 'cwde']
        if 'd' not in ctx.avoid: ops += ['cwd', 'cdq']
        return [r.choice(ops)]

    def i_lahf(self, ctx):
        if 'a' in ctx.avoid: return []
        return [self.r.choice(['lahf', 'sahf', 'lahf'])]

    def i_setcc(self, ctx):
        pre, d = self.rm(ctx, 8)
        return pre + ['set%s %s' % (self.r.choice(CC), d)] if d else []

    def i_bt(self, ctx):
        r = self.r
        op = r.choice(['bt', 'bts', 'btr', 'btc'])
        size = r.choice([16, 32])
        if r.random() < 0.5:
            pre, d = self.rm(ctx, size, op != 'bt')
            return pre + ['%s %s, %d' % (op, d, r.randrange(256))]
        # register bit offset: masked (memory: up to 1023 bits = 128 bytes past the operand)
        o = self.reg(ctx, size)
        if not o: return []
        if r.random() < 0.4:
            d = self.reg(ctx, size, op != 'bt')
            if not d or fam(d) == fam(o): return []
            return ['%s %s, %s' % (op, d, o)]
        pre, m = self.mem(ctx, size, margin=136)
        # the offset mask comes after the address masks: if it shares a base register's family
        # it only makes that base smaller (still inside the masked range)
        return pre + ['and %s, 0x3ff' % o, '%s %s, %s' % (op, m, o)]

    def i_bsf(self, ctx):
        size = self.r.choice([16, 32])
        d = self.reg(ctx, size)
        if not d: return []
        pre, s = self.rm(ctx, size, True)
        if not s: return []
        return pre + ['or %s, 0x10' % s, '%s %s, %s' % (self.r.choice(['bsf', 'bsr']), d, s)]

    def i_xlat(self, ctx):
        if 'a' in ctx.avoid or 'b' in ctx.avoid: return []
        if ctx.mode == 16:
            seg = 'ds' if ctx.irq else self.r.choice(['ds', 'es', 'fs', 'gs'])
            return ['and bx, 0x%x' % (0x3EFF if ctx.irq else 0x7EFF), 'xlat %s:[bx]' % seg]
        return ['and ebx, 0x3FFFF', 'add ebx, 0x%x' % S32, 'xlat ds:[ebx]']

    def i_bcd(self, ctx):
        if 'a' in ctx.avoid: return []
        r = self.r
        op = r.choice(['daa', 'das', 'aaa', 'aas', 'aam', 'aad'])
        if op == 'aam': return ['aam %d' % r.randrange(1, 256)]
        if op == 'aad': return ['aad %d' % r.randrange(0, 256)]
        return [op]

    def i_push(self, ctx):
        r = self.r
        size = 16 if ctx.mode == 16 and r.random() < 0.7 else 32
        if ctx.mode == 32 and r.random() < 0.3: size = 16
        f = r.random()
        if f < 0.3:
            s = self.reg(ctx, size, False); d = self.reg(ctx, size)
            return ['push %s' % s, 'pop %s' % d] if d else []
        if f < 0.5:
            d = self.reg(ctx, size)
            if not d: return []
            return ['push%s 0x%x' % ('w' if size == 16 else 'd', self.imm(size)), 'pop %s' % d]
        if f < 0.75:
            pre, m = self.mem(ctx, size)
            d = self.reg(ctx, size)
            if not d: return []
            return pre + ['push %s' % m, 'pop %s' % d]
        s = self.reg(ctx, size, False)
        pre, m = self.mem(ctx, size)
        return pre + ['push %s' % s, 'pop %s' % m]

    def flagsreg(self, ctx):
        size = 16 if ctx.mode == 16 else 32
        return self.reg(ctx, size), size

    def i_pushf(self, ctx):
        d, size = self.flagsreg(ctx)
        if not d: return []
        if ctx.mode == 16 and self.r.random() < 0.3:
            d32 = self.r32of(fam(d))
            return ['pushfd', 'pop %s' % d32]
        return ['pushf' if size == 16 else 'pushfd', 'pop %s' % d]

    def i_popf(self, ctx):
        r = self.r
        d, size = self.flagsreg(ctx)
        if not d: return []
        # TF and NT never set, IF set (V86: the virtual IF)
        if ctx.mode == 16 and r.random() < 0.3:
            d32 = self.r32of(fam(d))
            return ['and %s, 0x%x' % (d32, 0xBEFF), 'or %s, 0x200' % d32, 'push %s' % d32, 'popfd']
        return ['and %s, 0x%x' % (d, 0xBEFF), 'or %s, 0x200' % d, 'push %s' % d, 'popf' if size == 16 else 'popfd']

    def i_pusha(self, ctx):
        r = self.r
        w = r.choice(['', 'd']) if ctx.mode == 16 else r.choice(['d', 'd', ''])
        inner = self.items(ctx.sub(), r.randrange(1, 4))
        return ['pusha' + w] + inner + ['popa' + w]

    def i_enter(self, ctx):
        r = self.r
        if 'bp' in ctx.avoid: return []
        lvl = r.choice([0, 0, 1, 2, 3])
        out = []
        bp = 'bp' if ctx.mode == 16 else 'ebp'
        sp = 'sp' if ctx.mode == 16 else 'esp'
        if lvl: out.append('mov %s, %s' % (bp, sp))
        out.append('enter %d, %d' % (r.randrange(0, 64) * 2, lvl))
        out += self.items(ctx.sub(avoid=ctx.avoid | {'bp'}), r.randrange(1, 4))
        out.append('leave')
        return out

    def i_jcc(self, ctx):
        r = self.r
        l = self.L()
        out = ['j%s %s' % (r.choice(CC), l)]
        out += self.items(ctx.sub(), r.randrange(1, 5))
        out.append('%s:' % l)
        return out

    def i_loop(self, ctx):
        r = self.r
        if 'c' in ctx.avoid: return []
        l = self.L()
        cx = 'cx' if ctx.mode == 16 else 'ecx'
        n = r.randrange(1, 9)
        op = r.choice(['loop', 'loop', 'loop', 'loope', 'loopne'])
        out = ['mov %s, %d' % (cx, n), '%s:' % l]
        out += self.items(ctx.sub(avoid=ctx.avoid | {'c'}), r.randrange(1, 6))
        out.append('%s %s' % (op, l))
        if r.random() < 0.3:
            l2 = self.L()
            out += ['%s %s' % ('jcxz' if ctx.mode == 16 else 'jecxz', l2)] + self.items(ctx.sub(avoid=ctx.avoid | {'c'}), 1) + ['%s:' % l2]
        return out

    def i_str(self, ctx):
        r = self.r
        if any(f in ctx.avoid for f in ('si', 'di', 'c')): return []
        size = r.choice([8, 16, 32])
        sfx = {8: 'b', 16: 'w', 32: 'd'}[size]
        out = [r.choice(['cld', 'std'])]
        n = r.randrange(0, 65)
        if ctx.mode == 16:
            lim = 0x3F00 if ctx.irq else 0x7F00
            m = (1 << (lim.bit_length() - 1)) - 1
            out += ['and si, 0x%x' % (m & ~r.choice([0, 1, 3])), 'and di, 0x%x' % (m & ~r.choice([0, 1, 3])),
                    'add si, 0x400', 'add di, 0x400', 'mov cx, %d' % n]
            sseg = 'ds' if ctx.irq else r.choice(['ds', 'es', 'fs', 'gs', 'ss'])
            src = '%s ptr %s:[si]' % ({8: 'byte', 16: 'word', 32: 'dword'}[size], sseg)
            dst = '%s ptr es:[di]' % {8: 'byte', 16: 'word', 32: 'dword'}[size]
        else:
            out += ['and esi, 0x%x' % (0x3FFFF & ~r.choice([0, 1, 3])), 'and edi, 0x%x' % (0x3FFFF & ~r.choice([0, 3])),
                    'add esi, 0x%x' % (S32 + 0x400), 'add edi, 0x%x' % (S32 + 0x400), 'mov ecx, %d' % n]
            src = '%s ptr ds:[esi]' % {8: 'byte', 16: 'word', 32: 'dword'}[size]
            dst = '%s ptr es:[edi]' % {8: 'byte', 16: 'word', 32: 'dword'}[size]
        A = {8: 'al', 16: 'ax', 32: 'eax'}[size]
        ops = ['movs', 'stos', 'cmps', 'scas']
        if 'a' not in ctx.avoid: ops += ['lods']
        op = r.choice(ops)
        rep = r.choice(['rep ', 'rep ', ''])
        if op == 'movs': out.append('%smovs %s, %s' % (rep, dst, src))
        elif op == 'stos': out.append('%sstos %s' % (rep, dst))
        elif op == 'lods': out.append('%slods %s' % (rep, src))
        elif op == 'cmps': out.append('%scmps %s, %s' % (r.choice(['repe ', 'repne ', '']), src, dst))
        else: out.append('%sscas %s' % (r.choice(['repe ', 'repne ', '']), dst))
        out.append('cld')
        return out

    def i_seg(self, ctx):
        r = self.r
        if ctx.irq: return ['push es', 'pop es']
        if ctx.mode == 16:
            sr = r.choice(['ds', 'es', 'fs', 'gs'])
            f = r.random()
            if f < 0.4:
                t = self.reg(ctx, 16)
                if not t: return []
                return ['mov %s, 0x%x' % (t, r.choice(SEGS16)), 'mov %s, %s' % (sr, t)]
            if f < 0.7:
                return ['push %s' % r.choice(['ds', 'es', 'fs', 'gs']), 'pop %s' % sr]
            # LDS / LES / LFS / LGS from a far pointer built in memory
            d = self.reg(ctx, 16)
            if not d: return []
            off = r.randrange(0, 0xFF00) & ~1
            seg = r.choice(SEGS16)
            ins = {'ds': 'lds', 'es': 'les', 'fs': 'lfs', 'gs': 'lgs'}[sr]
            return [
                'mov word ptr ss:[0x%x], 0x%x' % (0xD000 + (off & 0x07FE), r.getrandbits(16)),
                'mov word ptr ss:[0x%x], 0x%x' % (0xD002 + (off & 0x07FE), seg),
                '%s %s, dword ptr ss:[0x%x]' % (ins, d, 0xD000 + (off & 0x07FE))]
        f = r.random()
        if f < 0.4:
            t = self.reg(ctx, 16)
            if not t: return []
            sr = r.choice(['ds', 'es', 'fs', 'gs'])
            return ['mov %s, 0x%x' % (t, 0x33 if sr == 'fs' else 0x23), 'mov %s, %s' % (sr, t)]
        if f < 0.7:
            return r.choice([['push ds', 'pop es'], ['push es', 'pop ds'], ['push fs', 'pop fs'], ['push gs', 'pop gs']])
        d = self.reg(ctx, 32)
        if not d: return []
        p = S32 + 0x47800 + r.randrange(0, 0x80) * 8       # inside the sandbox (below 148000: counters, far pointers)
        ins = r.choice(['lfs', 'lgs'])
        return ['mov dword ptr ds:[0x%x], 0x%x' % (p, r.getrandbits(32)),
                'mov word ptr ds:[0x%x], 0x33' % (p + 4),
                '%s %s, fword ptr ds:[0x%x]' % (ins, d, p)]

    def i_lock(self, ctx):
        r = self.r
        size = self.wsize(ctx)
        pre, m = self.mem(ctx, size)
        f = r.random()
        if f < 0.4:
            op = r.choice(['add', 'adc', 'sub', 'sbb', 'and', 'or', 'xor'])
            return pre + ['lock %s %s, %s' % (op, m, self.reg(ctx, size, False))]
        if f < 0.55: return pre + ['lock %s %s' % (r.choice(['inc', 'dec', 'neg', 'not']), m)]
        if f < 0.7:
            s = self.reg(ctx, size)
            return pre + ['lock xadd %s, %s' % (m, s)] if s else []
        if f < 0.85 and 'a' not in ctx.avoid:
            return pre + ['lock cmpxchg %s, %s' % (m, self.reg(ctx, size, False))]
        if size == 8: return pre + ['lock or %s, 1' % m]
        return pre + ['lock %s %s, %d' % (r.choice(['bts', 'btr', 'btc']), m, r.randrange(size))]

    def i_cpuid(self, ctx):
        if any(f in ctx.avoid for f in 'abcd'): return []
        return ['xor eax, eax' if self.r.random() < 0.5 else 'mov eax, 1', 'cpuid']

    def guard(self, ctx, body):
        """calls / INTs inside a loop or an ENTER frame: the callee may change any register, so
        the loop counter / frame pointer of the caller are saved around it"""
        regs = [f for f in ('c', 'bp') if f in ctx.avoid]
        if not regs: return body
        rr = [self.r32of(f) if ctx.mode == 32 else self.r16of(f) for f in regs]
        return ['push %s' % x for x in rr] + body + ['pop %s' % x for x in reversed(rr)]

    def i_call(self, ctx):
        if not ctx.nsub: return []
        return self.guard(ctx, ['call sub%d' % self.r.randrange(ctx.nsub)])

    def i_fcall(self, ctx):
        if not ctx.fsub: return []
        k = self.r.randrange(ctx.fsub)
        if ctx.mode == 16:
            return self.guard(ctx, ['.byte 0x9A', '.word fsub%d' % k, '.word 0x2000'])
        return self.guard(ctx, ['call fword ptr ds:[0x%x]' % (0x148000 + 8 * k)])

    def i_rcall(self, ctx):
        if not ctx.rsub: return []
        k = self.r.randrange(ctx.rsub)
        if ctx.mode == 16: return self.guard(ctx, ['push 0x%x' % self.r.getrandbits(16), 'call rsub%d' % k])
        return self.guard(ctx, ['push 0x%x' % self.r.getrandbits(32), 'call rsub%d' % k])

    def i_int(self, ctx):
        if ctx.mode == 16: return self.guard(ctx, ['int 0x%x' % (0x40 + self.r.randrange(4))])
        return self.guard(ctx, ['int 0x30'])

    def i_cli(self, ctx):
        inner = self.items(ctx.sub(allow_int=False), self.r.randrange(1, 6))
        return ['cli'] + inner + ['sti']

    def i_sys32(self, ctx):
        # protection instructions on constant selectors (ring 0 and 3 alike)
        r = self.r
        d = self.reg(ctx, 32)
        if not d: return []
        sel = r.choice([0x23, 0x33, 0x1B, 0x08, 0x10, 0x28, 0x00, 0x2B])
        op = r.choice(['lar', 'lsl', 'verr', 'verw', 'smsw'])
        if op == 'smsw': return ['smsw %s' % self.r16of(fam(d))]
        if op in ('verr', 'verw'): return ['mov %s, 0x%x' % (self.r16of(fam(d)), sel), '%s %s' % (op, self.r16of(fam(d)))]
        return ['mov %s, 0x%x' % (d, sel), '%s %s, %s' % (op, d, self.r16of(fam(d)))]

    # ---------------------------------------------------------------- faults with a resume table
    def i_fault(self, ctx):
        """an instruction that faults (or traps): the kernel / real-mode stub resumes at the label
        after it and XORs EAX with a vector-dependent constant"""
        r = self.r
        if 'a' in ctx.avoid: return []
        L, R = self.L(), self.L()
        w = 16 if ctx.mode == 16 else 32
        A = 'ax' if w == 16 else 'eax'
        kinds = ['de', 'de8', 'ud', 'br', 'gp', 'nm', 'nm']
        kinds += ['ss'] if w == 16 else ['gpsel', 'int3', 'into']
        k = r.choice(kinds)
        pre, out, key = [], [], L
        if k in ('de', 'de8'):
            sz = 8 if k == 'de8' else w
            pre, m = self.mem(ctx, sz)
            pre = pre + ['mov %s, 0' % m]
            out = ['div %s' % m]
        elif k == 'ud':
            out = [r.choice(['ud2', '.byte 0xF0, 0x90', '.byte 0x8D, 0xC0', '.byte 0x0F, 0xFF', '.byte 0xF0, 0x40'])]
        elif k == 'br':
            pre, m = self.mem(ctx, w * 2 if w == 16 else 32, margin=8)
            lo = r.randrange(-4, 4)
            pre += ['mov %s, %d' % (m.replace('dword ptr', 'word ptr') if w == 16 else m, lo)]
            # the upper bound right after the lower one
            hi_m = m.replace('[', '[2+', 1) if w == 16 else m.replace('[', '[4+', 1)
            if w == 16: hi_m = hi_m.replace('dword ptr', 'word ptr')
            pre += ['mov %s, %d' % (hi_m, lo + r.randrange(0, 4))]
            br = self.reg(ctx, w, False)
            if w == 16: out = ['bound %s, %s' % (br, m)]
            else: out = ['bound %s, qword ptr %s' % (br, m.split(' ', 2)[2])]
        elif k == 'gp':
            d = self.reg(ctx, w)
            if not d: return []
            if w == 16:
                seg = r.choice(['ds', 'es', 'fs', 'gs'])
                out = ['mov %s, word ptr %s:[0xFFFF]' % (d, seg)]
            else:
                out = ['mov %s, dword ptr fs:[0x%x]' % (d, r.choice([0xFFFD, 0xFFFE, 0xFFFF, 0x10000]))]
        elif k == 'ss':
            d = self.reg(ctx, w)
            if not d: return []
            out = ['mov %s, word ptr ss:[0xFFFF]' % d]
        elif k == 'gpsel':
            pre = ['mov ax, 0x%x' % r.choice([0xFFF8, 0xFFFB, 0x9000])]
            out = ['mov %s, ax' % r.choice(['ds', 'es', 'fs', 'gs', 'ss'])]
        elif k == 'nm':
            pre, m = self.mem(ctx, 32)
            out = [r.choice(['fld %s' % m, 'fnstsw ax', 'fninit', 'fadd st, st(1)', 'fistp %s' % m, 'fnstcw %s' % m.replace('dword', 'word')])]
        elif k == 'int3':
            out = ['int3']; key = R
        else:
            pre = ['mov al, 0x7F', 'add al, 1']
            out = ['into']; key = R
        self.ftab.append((key, R))
        return pre + ['%s:' % L] + out + ['%s:' % R]

    # ---------------------------------------------------------------- port I/O
    def i_io(self, ctx):
        r = self.r
        if 'a' in ctx.avoid: return []
        f = r.random()
        if f < 0.15:
            return ['out 0x80, al']                        # allowed in the IOPM: direct
        if f < 0.25:
            if any(x in ctx.avoid for x in ('si', 'c', 'd')): return []
            seg = '' if ctx.mode == 32 else r.choice(['', 'es:', 'fs:', 'gs:'])
            if ctx.mode == 16:
                setup = ['and si, 0x3FF0', 'add si, 0x400', 'mov cx, %d' % r.randrange(1, 17), 'mov dx, 0x80']
                return setup + ['cld', 'rep outs dx, byte ptr %s[si]' % (seg or 'ds:')]
            return ['and esi, 0x3FFF0', 'add esi, 0x%x' % (S32 + 0x400), 'mov ecx, %d' % r.randrange(1, 17),
                    'mov dx, 0x80', 'cld', 'rep outs dx, byte ptr ds:[esi]']
        size = r.choice([8, 16, 32])
        A = {8: 'al', 16: 'ax', 32: 'eax'}[size]
        if r.random() < 0.5:
            p = r.choice(VPORTS)
            return [('in %s, 0x%x' % (A, p)) if r.random() < 0.5 else ('out 0x%x, %s' % (p, A))]
        if 'd' in ctx.avoid: return []
        p = r.choice(VPORTS_DX)
        return ['mov dx, 0x%x' % p, ('in %s, dx' % A) if r.random() < 0.5 else ('out dx, %s' % A)]

    # ---------------------------------------------------------------- self-modifying code
    def i_smc(self, ctx):
        """patch the immediate of a MOV r, imm a few instructions ahead with a register value,
        a JMP (the i486 rule), then run it"""
        r = self.r
        s16 = ctx.mode == 16
        src = self.reg(ctx, 16 if s16 else 32, False)
        dst = self.reg(ctx, 16 if s16 else 32)
        if not dst: return []
        L = self.L()
        if s16:
            # writable alias of the code segment: segment / selector 2008h (base 20080h)
            out = ['mov word ptr ss:[0xDFE0], 0x2008', 'push ds', 'mov ds, word ptr ss:[0xDFE0]',
                   'mov word ptr ds:[%s+1-0x80], %s' % (L, src), 'pop ds']
        else:
            out = ['mov dword ptr ds:[%s+1], %s' % (L, src)]
        # i486: a store into the prefetched instructions takes effect only after a jump (Intel's
        # rule for self-modifying code before the Pentium); the jump comes right after the store
        J = self.L()
        out += ['jmp %s' % J, '%s:' % J]
        if r.random() < 0.4:
            out += self.items(ctx.sub(avoid=ctx.avoid | {fam(dst)}, allow_call=False, allow_int=False), r.randrange(1, 3))
        imm = '.word 0' if s16 else '.long 0'
        out += ['%s:' % L, '.byte 0x%x' % (0xB8 + RNUM[dst]), imm]
        return out

    # ---------------------------------------------------------------- call gate / task switch (32-bit)
    def i_gate(self, ctx):
        r = self.r
        if 'a' in ctx.avoid or 'd' in ctx.avoid: return []
        return self.guard(ctx, ['push 0x%x' % r.getrandbits(32), 'push %s' % self.reg(ctx, 32, False),
                                'call fword ptr ds:[0x148040]'])

    def i_task(self, ctx):
        return self.guard(ctx, ['call fword ptr ds:[0x148048]'])



def subs(g, mode, nsub, fsub, rsub, n_items):
    out = []
    for k in range(nsub):
        out.append('sub%d:' % k)
        out += g.items(Ctx(mode, nsub=k, fsub=0, rsub=0, allow_int=False), n_items)
        out.append('ret')
    for k in range(fsub):
        out.append('fsub%d:' % k)
        out += g.items(Ctx(mode, nsub=nsub, fsub=0, rsub=0, allow_int=False), n_items)
        out.append('retf')
    for k in range(rsub):
        out.append('rsub%d:' % k)
        out += g.items(Ctx(mode, nsub=nsub, fsub=0, rsub=0, allow_int=False), n_items)
        out.append('ret %d' % (2 if mode == 16 else 4))
    return out


NWL = 4


def gen16(seed):
    g = Gen(seed)
    NS, FS, RS = 8, 3, 3
    o = ['.intel_syntax noprefix', '.code16', '.text', '.globl _start', '_start:']
    # header: workload entries, IRQ0 / RTC handler, INT 40-43 services, bad vector
    o += ['.word wl%d' % i for i in range(NWL)]
    o += ['.word irq0h', '.word rtch'] + ['.word svc%d' % i for i in range(4)] + ['.word badvec']
    o += ['.word %d' % NWL, '.word ftab', '.word (ftab_end - ftab) / 4']
    o += ['.org 0x100']                  # (code patched through segment 2008h: offsets >= 80h)
    # each workload body repeats (the kernel sets the count at SS:DFF0, outside the hashed data)
    for i in range(NWL):
        o += ['wl%d:' % i, '.Ltop16_%d:' % i]
        o += g.items(Ctx(16, nsub=NS, fsub=FS, rsub=RS), 260)
        o += ['dec word ptr ss:[0xDFF0]', 'jnz .Ltop16_%d' % i, 'int 0x31']
    o += subs(g, 16, NS, FS, RS, 30)
    for i in range(4):
        o.append('svc%d:' % i)
        o += g.items(Ctx(16, nsub=NS, fsub=FS, rsub=RS, allow_int=False), 25)
        o += ['iret'] if g.r.random() < 0.6 else ['sti', 'retf 2']
    for h in ('irq0h', 'rtch'):
        o += ['%s:' % h, 'pushad', 'push ds', 'push es', 'mov ax, 0x100', 'mov ds, ax', 'mov es, ax']
        o += g.items(Ctx(16, irq=True, allow_call=False, allow_int=False), 18)
        o += ['pop es', 'pop ds', 'popad', 'iret']
    o += ['badvec:', 'int 0x32', 'jmp badvec']
    o += ['.align 4', 'ftab:'] + ['.word %s, %s' % kr for kr in g.ftab] + ['ftab_end:']
    return o


def gen32(seed):
    g = Gen(seed * 31 + 7)
    NS, FS, RS = 8, 3, 3
    o = ['.intel_syntax noprefix', '.code32', '.text', '.globl _start', '_start:']
    o += ['.long wl%d' % i for i in range(NWL)]
    o += ['.long fsub%d' % i for i in range(FS)]
    o += ['.long %d' % NWL, '.long %d' % FS, '.long ftab', '.long (ftab_end - ftab) / 8']
    # repeat count at 148100 (stack area bottom, set by the kernel)
    for i in range(NWL):
        o += ['wl%d:' % i, '.Ltop32_%d:' % i]
        o += g.items(Ctx(32, nsub=NS, fsub=FS, rsub=RS), 260)
        o += ['dec dword ptr ds:[0x148100]', 'jnz .Ltop32_%d' % i, 'int 0x31']
    o += subs(g, 32, NS, FS, RS, 30)
    o += ['.align 4', 'ftab:'] + ['.long %s, %s' % kr for kr in g.ftab] + ['ftab_end:']
    return o


def main():
    out, seed = sys.argv[1], int(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, 'wl16.s'), 'w').write('\n'.join(gen16(seed)) + '\n')
    open(os.path.join(out, 'wl32.s'), 'w').write('\n'.join(gen32(seed)) + '\n')


if __name__ == '__main__':
    main()
