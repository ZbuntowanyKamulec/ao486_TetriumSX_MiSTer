// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* Word frequency count with a chained hash table over generated text, then
 * the most frequent words by repeated selection. */
#include <stdio.h>
#define HSIZE 256
#define MAXW 400
struct ent { char w[12]; unsigned cnt; int next; };
static struct ent ents[MAXW];
static int head[HSIZE], nents;
static char text[9000];
static unsigned hash(const char *s) { unsigned h = 0; while (*s) h = h * 31 + (unsigned char)*s++; return h & (HSIZE - 1); }
static int eq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static void add(const char *w)
{
    unsigned h = hash(w);
    int i;
    char *d;
    for (i = head[h]; i >= 0; i = ents[i].next) if (eq(ents[i].w, w)) { ents[i].cnt++; return; }
    if (nents >= MAXW) return;
    d = ents[nents].w; while ((*d++ = *w++) != 0) ;
    ents[nents].cnt = 1; ents[nents].next = head[h]; head[h] = nents++;
}
int main(void)
{
    static const char *syl[] = { "ka", "to", "ri", "mu", "sen", "da", "lo", "pe", "qui", "zo", "an", "el" };
    unsigned long seed = 7;
    unsigned i, n = 0, total = 0;
    char w[12];
    int k, best;
    for (i = 0; i < HSIZE; i++) head[i] = -1;
    while (n < sizeof(text) - 16) {
        int ns;
        seed = seed * 1103515245UL + 12345; ns = 1 + (int)((seed >> 16) % 3);
        while (ns--) { const char *s; seed = seed * 1103515245UL + 12345; s = syl[(seed >> 16) % 12]; while (*s) text[n++] = *s++; }
        text[n++] = (seed & 0x300) ? ' ' : '\n';
    }
    for (i = 0; i < n; ) {
        k = 0;
        while (i < n && text[i] != ' ' && text[i] != '\n') { if (k < 11) w[k++] = text[i]; i++; }
        w[k] = 0; i++;
        if (k) { add(w); total++; }
    }
    printf("words %u distinct %d top:", total, nents);
    for (k = 0; k < 5; k++) {
        unsigned bc = 0;
        best = -1;
        for (i = 0; i < (unsigned)nents; i++) if (ents[i].cnt > bc) { bc = ents[i].cnt; best = i; }
        if (best < 0) break;
        printf(" %s=%u", ents[best].w, ents[best].cnt); ents[best].cnt = 0;
    }
    printf("\n");
    return 0;
}
