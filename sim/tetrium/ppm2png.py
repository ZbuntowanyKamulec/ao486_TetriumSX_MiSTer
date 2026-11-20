#!/usr/bin/env python3
"""ppm2png.py in.ppm out.png (no dependencies)"""
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read()
hdr = d.split(b'\n', 1)
_, w, h, _ = hdr[0].split()
w, h = int(w), int(h)
px = hdr[1]
raw = b''.join(b'\x00' + px[y * w * 3:(y + 1) * w * 3] for y in range(h))
def chunk(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
open(sys.argv[2], 'wb').write(png)
