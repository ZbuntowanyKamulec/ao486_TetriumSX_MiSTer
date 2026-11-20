// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ZbuntowanyKamulec
// Memory type of the aligned 32-bit word at physical address {a, 2'b00}:
//   [0] cacheable (write-through L1)   [1] write-combining (uncached reads, merged writes)
//   neither: strongly uncached (MMIO)
// Below 1 MB: the CACHEABLE / WCOMB bitmaps, one bit per 16 KB region.
// Above 1 MB: up to 4 ranges (4 KB granular), range k = addresses with
//   (a[31:12] & MT_MASK[k]) == MT_BASE[k], type MT_TYPE[k]; the lowest matching k
//   wins; no match: cached.
// Include inside a module that has the CACHEABLE, WCOMB and MT_* parameters.
function automatic logic [1:0] mtype(input logic [31:2] a);
  logic [1:0] t;
  t = 2'b01;
  for (int k = 3; k >= 0; k--)
    if (k < MT_N && (a[31:12] & MT_MASK[k*20 +: 20]) == MT_BASE[k*20 +: 20]) t = MT_TYPE[k*2 +: 2];
  if (a[31:20] == 12'h000) t = {WCOMB[a[19:14]], CACHEABLE[a[19:14]]};
  return t;
endfunction
