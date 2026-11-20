// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* Bytecode stack VM with a switch dispatch loop (jump table), running a small
 * program: sieve of primes below LIMIT and a checksum, a few rounds. */
#include <stdio.h>
enum { PUSH, LOAD, STORE, ADD, SUB, MUL, LT, JZ, JMP, DUP, DROP, LDA, STA, INC, HALT, MOD, AND };
#define LIMIT 2000
static unsigned char mem[LIMIT];
static int vars[8];
static const int prog[] = {
    /*  0: v0 = 2, v1 = 0 */                   PUSH, 2, STORE, 0, PUSH, 0, STORE, 1,
    /*  8: clear: while v1 < LIMIT */          LOAD, 1, PUSH, LIMIT, LT, JZ, 24,
    /* 15:   mem[v1] = 0; v1++ */              LOAD, 1, PUSH, 0, STA, INC, 1, JMP, 8,
    /* 24: while v0 < LIMIT */                 LOAD, 0, PUSH, LIMIT, LT, JZ, 71,
    /* 31:   if mem[v0] goto next */           LOAD, 0, LDA, JZ, 38, JMP, 67,
    /* 38:   count++; v1 = v0 + v0 */          INC, 2, LOAD, 0, DUP, ADD, STORE, 1,
    /* 46:   while v1 < LIMIT */               LOAD, 1, PUSH, LIMIT, LT, JZ, 67,
    /* 53:     mem[v1] = 1; v1 += v0 */        LOAD, 1, PUSH, 1, STA, LOAD, 1, LOAD, 0, ADD, STORE, 1, JMP, 46,
    /* 67: next: v0++ */                       INC, 0, JMP, 24,
    /* 71: */                                  HALT
};
static int run(void)
{
    int stack[16], sp = 0, pc = 0, a, b;
    for (;;) {
        switch (prog[pc++]) {
        case PUSH:  stack[sp++] = prog[pc++]; break;
        case LOAD:  stack[sp++] = vars[prog[pc++]]; break;
        case STORE: vars[prog[pc++]] = stack[--sp]; break;
        case ADD:   b = stack[--sp]; a = stack[--sp]; stack[sp++] = a + b; break;
        case SUB:   b = stack[--sp]; a = stack[--sp]; stack[sp++] = a - b; break;
        case MUL:   b = stack[--sp]; a = stack[--sp]; stack[sp++] = a * b; break;
        case MOD:   b = stack[--sp]; a = stack[--sp]; stack[sp++] = a % b; break;
        case AND:   b = stack[--sp]; a = stack[--sp]; stack[sp++] = a & b; break;
        case LT:    b = stack[--sp]; a = stack[--sp]; stack[sp++] = a < b; break;
        case JZ:    a = prog[pc++]; if (!stack[--sp]) pc = a; break;
        case JMP:   pc = prog[pc]; break;
        case DUP:   stack[sp] = stack[sp - 1]; sp++; break;
        case DROP:  sp--; break;
        case LDA:   a = stack[--sp]; stack[sp++] = mem[a]; break;
        case STA:   b = stack[--sp]; a = stack[--sp]; mem[a] = (unsigned char)b; break;
        case INC:   vars[prog[pc++]]++; break;
        case HALT:  return vars[2];
        }
    }
}
int main(void)
{
    int r, n = 0;
    for (r = 0; r < 3; r++) { vars[2] = 0; n = run(); }
    printf("vm primes below %d: %d (%s)\n", LIMIT, n, n == 303 ? "OK" : "BAD");
    return 0;
}
