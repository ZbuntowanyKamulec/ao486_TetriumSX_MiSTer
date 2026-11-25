#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ZbuntowanyKamulec
"""Print the log hwcheck saved in its disk image.   usage: logread.py <hwcheck.vhd>"""
import sys
d = open(sys.argv[1], 'rb').read()
assert d[8192 * 512: 8192 * 512 + 8] == b'HWCKSCR!', 'not a hwcheck image'
print(d[8320 * 512: 8320 * 512 + 0xC000].split(b'\0')[0].decode('latin1'))
