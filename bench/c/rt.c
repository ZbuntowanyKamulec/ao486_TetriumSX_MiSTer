// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
/* Minimal freestanding runtime for the Tetrium C benchmarks (OpenWatcom, tiny model).
 * (also the 32-bit flat builds, build32.sh).
 * Console output goes to a buffer at 2000:0000 (NUL terminated), which the
 * testbench prints with -con.  No DOS or BIOS calls. */
#include <stdarg.h>
#include <stddef.h>

#ifdef __386__
static char *con = (char *)0x20000;                 /* 32-bit flat build: linear 20000 */
#else
static char __far *con = (char __far *)0x20000000L;
#endif

int putchar(int c)
{
    *con++ = (char)c;
    *con = 0;
    return c;
}

int puts(const char *s)
{
    while (*s) putchar(*s++);
    putchar('\n');
    return 0;
}

static void putnum(unsigned long v, int base, int neg, int width, char pad)
{
    char buf[12];
    int n = 0;
    do { int d = (int)(v % base); buf[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v /= base; } while (v);
    if (neg) buf[n++] = '-';
    while (n < width) { putchar(pad); width--; }
    while (n) putchar(buf[--n]);
}

int printf(const char *f, ...)
{
    va_list ap;
    va_start(ap, f);
    for (; *f; f++) {
        int width = 0, lng = 0;
        char pad = ' ';
        if (*f != '%') { putchar(*f); continue; }
        f++;
        if (*f == '0') { pad = '0'; f++; }
        while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
        if (*f == 'l') { lng = 1; f++; }
        switch (*f) {
        case 'd': case 'i': {
            long v = lng ? va_arg(ap, long) : va_arg(ap, int);
            putnum(v < 0 ? -v : v, 10, v < 0, width, pad);
            break; }
        case 'u':
            putnum(lng ? va_arg(ap, unsigned long) : va_arg(ap, unsigned), 10, 0, width, pad);
            break;
        case 'x': case 'X':
            putnum(lng ? va_arg(ap, unsigned long) : va_arg(ap, unsigned), 16, 0, width, pad);
            break;
        case 'c': putchar(va_arg(ap, int)); break;
        case 's': { const char *s = va_arg(ap, const char *); while (*s) putchar(*s++); break; }
        case '%': putchar('%'); break;
        default: break;
        }
    }
    va_end(ap);
    return 0;
}

/* Dhrystone asks for the number of runs */
int scanf(const char *f, ...)
{
    va_list ap;
    va_start(ap, f);
    *va_arg(ap, int *) = DHRY_RUNS;
    va_end(ap);
    return 1;
}

/* bump allocator */
#ifdef __386__
static long heapl[1024];                            /* dword-aligned blocks */
#define heap ((char *)heapl)
#define HALIGN 3u
#else
static char heap[4096];
#define HALIGN 1u
#endif
static unsigned heap_used;
void *malloc(size_t n)
{
    void *p = heap + heap_used;
    heap_used += (n + HALIGN) & ~HALIGN;
    return p;
}
void free(void *p) { (void)p; }

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++) != 0) ;
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

void *memcpy(void *d, const void *s, size_t n)
{
    char *dd = d;
    const char *ss = s;
    while (n--) *dd++ = *ss++;
    return d;
}

void *memset(void *d, int c, size_t n)
{
    char *dd = d;
    while (n--) *dd++ = (char)c;
    return d;
}

/* Dhrystone timing hooks: no clock here */
long time(long *t) { if (t) *t = 0; return 0; }
struct tms { long a, b, c, d; };
int times(struct tms *t) { t->a = t->b = t->c = t->d = 0; return 0; }
