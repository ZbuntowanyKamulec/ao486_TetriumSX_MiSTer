// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* LZSS (after Okumura's LZSS.C, 4 KB window, 18-byte matches, binary tree
 * match finder): compress a generated text, decompress it, check the result. */
#include <stdio.h>
#define N 4096
#define F 18
#define THRESHOLD 2
#define NIL N
#define INSZ 6000
static unsigned char text_buf[N + F - 1];
static int match_position, match_length, lson[N + 1], rson[N + 257], dad[N + 1];
static unsigned char in[INSZ], comp[INSZ + INSZ / 8 + 16], out[INSZ];
static unsigned inpos, compos, outpos, insz;
int memcmp_ok(void);

static void init_tree(void)
{
    int i;
    for (i = N + 1; i <= N + 256; i++) rson[i] = NIL;
    for (i = 0; i < N; i++) dad[i] = NIL;
}
static void insert_node(int r)
{
    int i, p, cmp = 1;
    unsigned char *key = &text_buf[r];
    p = N + 1 + key[0];
    rson[r] = lson[r] = NIL;
    match_length = 0;
    for (;;) {
        if (cmp >= 0) {
            if (rson[p] != NIL) p = rson[p]; else { rson[p] = r; dad[r] = p; return; }
        } else {
            if (lson[p] != NIL) p = lson[p]; else { lson[p] = r; dad[r] = p; return; }
        }
        for (i = 1; i < F; i++) if ((cmp = key[i] - text_buf[p + i]) != 0) break;
        if (i > match_length) {
            match_position = p;
            if ((match_length = i) >= F) break;
        }
    }
    dad[r] = dad[p]; lson[r] = lson[p]; rson[r] = rson[p];
    dad[lson[p]] = r; dad[rson[p]] = r;
    if (rson[dad[p]] == p) rson[dad[p]] = r; else lson[dad[p]] = r;
    dad[p] = NIL;
}
static void delete_node(int p)
{
    int q;
    if (dad[p] == NIL) return;
    if (rson[p] == NIL) q = lson[p];
    else if (lson[p] == NIL) q = rson[p];
    else {
        q = lson[p];
        if (rson[q] != NIL) {
            do { q = rson[q]; } while (rson[q] != NIL);
            rson[dad[q]] = lson[q]; dad[lson[q]] = dad[q];
            lson[q] = lson[p]; dad[lson[p]] = q;
        }
        rson[q] = rson[p]; dad[rson[p]] = q;
    }
    dad[q] = dad[p];
    if (rson[dad[p]] == p) rson[dad[p]] = q; else lson[dad[p]] = q;
    dad[p] = NIL;
}
static int getb(void) { return inpos < insz ? in[inpos++] : -1; }
static void encode(void)
{
    int i, c, len, r, s, last_match_length, code_buf_ptr;
    unsigned char code_buf[17], mask;
    init_tree();
    code_buf[0] = 0; code_buf_ptr = mask = 1;
    s = 0; r = N - F;
    for (i = s; i < r; i++) text_buf[i] = ' ';
    for (len = 0; len < F && (c = getb()) != -1; len++) text_buf[r + len] = (unsigned char)c;
    if (len == 0) return;
    for (i = 1; i <= F; i++) insert_node(r - i);
    insert_node(r);
    do {
        if (match_length > len) match_length = len;
        if (match_length <= THRESHOLD) {
            match_length = 1;
            code_buf[0] |= mask;
            code_buf[code_buf_ptr++] = text_buf[r];
        } else {
            code_buf[code_buf_ptr++] = (unsigned char)match_position;
            code_buf[code_buf_ptr++] = (unsigned char)(((match_position >> 4) & 0xf0) | (match_length - (THRESHOLD + 1)));
        }
        if ((mask <<= 1) == 0) {
            for (i = 0; i < code_buf_ptr; i++) comp[compos++] = code_buf[i];
            code_buf[0] = 0; code_buf_ptr = mask = 1;
        }
        last_match_length = match_length;
        for (i = 0; i < last_match_length && (c = getb()) != -1; i++) {
            delete_node(s);
            text_buf[s] = (unsigned char)c;
            if (s < F - 1) text_buf[s + N] = (unsigned char)c;
            s = (s + 1) & (N - 1); r = (r + 1) & (N - 1);
            insert_node(r);
        }
        while (i++ < last_match_length) {
            delete_node(s);
            s = (s + 1) & (N - 1); r = (r + 1) & (N - 1);
            if (--len) insert_node(r);
        }
    } while (len > 0);
    if (code_buf_ptr > 1) for (i = 0; i < code_buf_ptr; i++) comp[compos++] = code_buf[i];
}
static void decode(void)
{
    int i, j, k, r, c;
    unsigned flags = 0, cp = 0;
    for (i = 0; i < N - F; i++) text_buf[i] = ' ';
    r = N - F;
    for (;;) {
        if (((flags >>= 1) & 256) == 0) {
            if (cp >= compos) break;
            flags = comp[cp++] | 0xff00;
        }
        if (flags & 1) {
            if (cp >= compos) break;
            c = comp[cp++];
            out[outpos++] = (unsigned char)c; text_buf[r++] = (unsigned char)c; r &= (N - 1);
        } else {
            if (cp + 1 >= compos + 1) break;
            i = comp[cp++]; j = comp[cp++];
            i |= ((j & 0xf0) << 4); j = (j & 0x0f) + THRESHOLD;
            for (k = 0; k <= j; k++) {
                c = text_buf[(i + k) & (N - 1)];
                out[outpos++] = (unsigned char)c; text_buf[r++] = (unsigned char)c; r &= (N - 1);
            }
        }
    }
}
static const char *words[] = { "the ", "quick ", "brown ", "fox ", "jumps ", "over ", "lazy ", "dog ",
    "compression ", "of ", "text ", "with ", "a ", "sliding ", "window ", "and ", "binary ", "tree ",
    "match ", "finder ", "\n", "8086 ", "segment ", "register " };
int main(void)
{
    unsigned long seed = 12345, sum = 0;
    unsigned i;
    while (insz < INSZ - 16) {
        const char *w;
        seed = seed * 1103515245UL + 12345;
        w = words[(unsigned)(seed >> 16) % 24];
        while (*w && insz < INSZ - 16) in[insz++] = (unsigned char)*w++;
    }
    encode();
    decode();
    for (i = 0; i < outpos; i++) sum = sum * 31 + out[i];
    printf("lzss in=%u comp=%u out=%u %s sum=%lx\n", insz, compos, outpos,
           (outpos == insz && !memcmp_ok()) ? "OK" : "BAD", sum);
    return 0;
}
int memcmp_ok(void)
{
    unsigned i;
    for (i = 0; i < insz; i++) if (in[i] != out[i]) return 1;
    return 0;
}
