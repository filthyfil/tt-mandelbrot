# SPDX-FileCopyrightText: © 2026 Filip Jasionek
# SPDX-License-Identifier: Apache-2.0
"""Bit-level reference model of tt_um_filthyfil_mandelbrot.

Written from the spec (docs/info.md), independently of the RTL:
  * 80x60 blocks of 8x8 pixels, c = (-3.25 + col/16) + i(1.875 - row/16)
  * Q3.6 signed fixed point (1.0 = 64), 16 iterations of z <- z^2 + c
  * x^2, y^2 truncated (>> 6); 2xy = sign(x*y) * ((|x|*|y|) >> 5)
  * escape at iteration n if |x| >= 2, |y| >= 2 or x^2 + y^2 > 4;
    an update leaving [-4, 4) escapes at n + 1
  * colour = palette[sel][(n + phase) mod 16], sel = ui_in[5:4], inside black
"""
import os
import re

F = 6
ITER = 16
COLS, ROWS = 80, 60
LIM = 1 << (F + 2)  # Q3.6 range [-4, 4) = [-256, 256)
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src",
                   "tt_um_filthyfil_mandelbrot.v")


def _wrap9(v):
    v &= 0x1FF
    return v - 0x200 if v & 0x100 else v


def escape_count(cr, ci):
    """Escape iteration mod 16, or None if the point stays inside."""
    x = y = 0
    for n in range(ITER):
        x2 = (x * x) >> F
        y2 = (y * y) >> F
        two_xy = (abs(x) * abs(y)) >> (F - 1)
        if (x < 0) != (y < 0):
            two_xy = -two_xy
        if abs(x) >= 2 << F or abs(y) >= 2 << F or x2 + y2 > 4 << F:
            return n % 16
        xw = x2 - y2 + cr
        yw = two_xy + ci
        if not (-LIM <= xw < LIM and -LIM <= yw < LIM):
            return (n + 1) % 16
        x, y = _wrap9(xw), _wrap9(yw)
    return None


def blocks():
    """80x60 grid of escape counts."""
    return [[escape_count(4 * col - 208, 120 - 4 * row) for col in range(COLS)]
            for row in range(ROWS)]


def palettes():
    """The 4 palettes of 16 (r, g, b) 2-bit entries, read from the RTL case table."""
    with open(SRC) as fh:
        text = fh.read()
    table = {int(i): v.replace("_", "")
             for i, v in re.findall(r"6'd(\d+)\s*: rgb = 6'b([01_]+);", text)}
    assert sorted(table) == list(range(64)), "expected 64 palette entries"
    entries = [(int(v[0:2], 2), int(v[2:4], 2), int(v[4:6], 2)) for _, v in sorted(table.items())]
    assert (0, 0, 0) not in entries, "a black entry would merge bands with the set"
    return [entries[16 * sel:16 * sel + 16] for sel in range(4)]


def palette(sel=0):
    """The 16 entries of palette sel (ui_in[5:4])."""
    return palettes()[sel]


def frame(grid, pal, phase):
    """Expected 640x480 image as a flat list of (r, g, b)."""
    img = []
    for y in range(480):
        row = grid[y // 8]
        for x in range(640):
            n = row[x // 8]
            img.append((0, 0, 0) if n is None else pal[(n + phase) % 16])
    return img


def read_ppm(path):
    with open(path) as fh:
        tok = fh.read().split()
    assert tok[:4] == ["P3", "640", "480", "3"], path
    vals = [int(t) for t in tok[4:]]
    return [tuple(vals[i:i + 3]) for i in range(0, len(vals), 3)]
