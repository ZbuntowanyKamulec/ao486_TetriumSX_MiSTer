// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* N-queens backtracking (all solutions for N = 4..9) */
#include <stdio.h>
static int col[16], d1[32], d2[32], n, count;
static void place(int r)
{
    int c;
    if (r == n) { count++; return; }
    for (c = 0; c < n; c++)
        if (!col[c] && !d1[r + c] && !d2[r - c + n]) {
            col[c] = d1[r + c] = d2[r - c + n] = 1;
            place(r + 1);
            col[c] = d1[r + c] = d2[r - c + n] = 0;
        }
}
int main(void)
{
    static const int expect[] = { 2, 10, 4, 40, 92, 352 };
    int ok = 1;
    for (n = 4; n <= 9; n++) { count = 0; place(0); if (count != expect[n - 4]) ok = 0; printf("%d:%d ", n, count); }
    printf("%s\n", ok ? "OK" : "BAD");
    return 0;
}
