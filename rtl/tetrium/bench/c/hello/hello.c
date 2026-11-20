// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
#include <stdio.h>
int main(void)
{
    unsigned long a = 123456789UL, b = 1000;
    long c = -7777777L;
    printf("hello %d %u %lu %ld %lx\n", -42, 65000u, a / b, c * 3, a * 7);
    return 0;
}
