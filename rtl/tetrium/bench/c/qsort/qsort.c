// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* Recursive quicksort through a comparison callback (like the C library's
 * qsort), on random ints and on records keyed by a string, then verified. */
#include <stdio.h>
#define NI 3000
#define NR 600
typedef int (*cmpf)(const void *, const void *);
static int ints[NI];
struct rec { char key[8]; int val; };
static struct rec recs[NR];
static void swapb(char *a, char *b, unsigned n) { while (n--) { char t = *a; *a++ = *b; *b++ = t; } }
static void qs(char *base, unsigned n, unsigned sz, cmpf cmp)
{
    while (n > 1) {
        unsigned i = 0, j = n - 1;
        char *piv = base + (n / 2) * sz;
        swapb(piv, base, sz);
        for (;;) {
            do i++; while (i < n && cmp(base + i * sz, base) < 0);
            while (cmp(base + j * sz, base) > 0) j--;
            if (i >= j) break;
            swapb(base + i * sz, base + j * sz, sz);
        }
        swapb(base, base + j * sz, sz);
        if (j < n - j) { qs(base, j, sz, cmp); base += (j + 1) * sz; n -= j + 1; }
        else { qs(base + (j + 1) * sz, n - j - 1, sz, cmp); n = j; }
    }
}
static int cmpi(const void *a, const void *b)
{
    int x = *(const int *)a, y = *(const int *)b;
    return x < y ? -1 : x > y;
}
static int cmps(const void *a, const void *b)
{
    const char *x = ((const struct rec *)a)->key, *y = ((const struct rec *)b)->key;
    while (*x && *x == *y) { x++; y++; }
    return (unsigned char)*x - (unsigned char)*y;
}
int main(void)
{
    unsigned long seed = 99;
    unsigned i, k, bad = 0;
    for (i = 0; i < NI; i++) { seed = seed * 1103515245UL + 12345; ints[i] = (int)(seed >> 16); }
    for (i = 0; i < NR; i++) {
        for (k = 0; k < 7; k++) { seed = seed * 1103515245UL + 12345; recs[i].key[k] = (char)('a' + (seed >> 16) % 26); }
        recs[i].key[7] = 0; recs[i].val = i;
    }
    qs((char *)ints, NI, sizeof(int), cmpi);
    qs((char *)recs, NR, sizeof(struct rec), cmps);
    for (i = 1; i < NI; i++) if (ints[i - 1] > ints[i]) bad++;
    for (i = 1; i < NR; i++) if (cmps(&recs[i - 1], &recs[i]) > 0) bad++;
    printf("qsort %u ints, %u records: %s\n", NI, NR, bad ? "BAD" : "OK");
    return 0;
}
