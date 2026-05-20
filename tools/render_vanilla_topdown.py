#!/usr/bin/env python3
"""Render a vanilla Alpha 1.2.6 save's top-down heightmap as PNG so we can
compare visually to our output."""
import sys
import nbtlib
from pathlib import Path
from PIL import Image

WORLD = sys.argv[1] if len(sys.argv) > 1 else "World1"
SAVE = Path.home() / "Library/Application Support/minecraft/saves" / WORLD


def surface_y(blocks, x, z):
    base = (x * 16 + z) * 128
    for y in range(127, -1, -1):
        b = blocks[base + y]
        if b not in (0, 8, 9):  # not AIR/WATER
            return y
    return -1


def top_block(blocks, x, z):
    sy = surface_y(blocks, x, z)
    if sy < 0:
        return 0
    return blocks[(x * 16 + z) * 128 + sy]


def color_for(sy, top):
    if sy < 64:
        h = (sy - 50) / 14.0
        h = max(0, min(1, h))
        return (int(0.1 * 255), int(0.2 * 255), int((0.5 + h * 0.3) * 255))
    if top == 12:  # SAND
        h = (sy - 64) / 30.0
        return (int((0.9 + h * 0.1) * 255), int((0.85 + h * 0.1) * 255), int((0.5 + h * 0.4) * 255))
    if top == 2:  # GRASS
        h = (sy - 64) / 50.0
        h = max(0, min(1, h))
        return (int((0.2 + h * 0.5) * 255), int((0.6 + h * 0.1) * 255), int((0.2 + h * 0.5) * 255))
    if top in (78, 80):  # SNOW
        return (240, 240, 250)
    return (128, 100, 80)


# Discover chunks under the world dir
chunks = {}
for f in SAVE.rglob("c.*.dat"):
    parts = f.stem.split(".")
    cx = int(parts[1], 36) if not parts[1].startswith("-") else -int(parts[1][1:], 36)
    cz = int(parts[2], 36) if not parts[2].startswith("-") else -int(parts[2][1:], 36)
    chunks[(cx, cz)] = f

if not chunks:
    print(f"No chunks found in {SAVE}")
    sys.exit(1)

# Find tightest bounding box of explored chunks
xs = [c[0] for c in chunks]
zs = [c[1] for c in chunks]
min_cx, max_cx = min(xs), max(xs)
min_cz, max_cz = min(zs), max(zs)
# Limit to a reasonable area
side = min(max_cx - min_cx + 1, max_cz - min_cz + 1, 32)
mid_cx = (min_cx + max_cx) // 2
mid_cz = (min_cz + max_cz) // 2
sx0 = mid_cx - side // 2
sz0 = mid_cz - side // 2

print(f"Rendering {side}×{side} chunks from ({sx0},{sz0}) of {WORLD}")
img = Image.new("RGB", (side * 16, side * 16))
n_loaded = 0
for cx in range(sx0, sx0 + side):
    for cz in range(sz0, sz0 + side):
        f = chunks.get((cx, cz))
        if f is None:
            continue
        n_loaded += 1
        blocks = bytes(nbtlib.load(f)["Level"]["Blocks"])
        for x in range(16):
            for z in range(16):
                sy = surface_y(blocks, x, z)
                top = top_block(blocks, x, z)
                px = (cx - sx0) * 16 + x
                pz = (cz - sz0) * 16 + z
                img.putpixel((px, pz), color_for(sy, top))

out = f"/tmp/vanilla_topdown_{WORLD}.png"
img.save(out)
print(f"{n_loaded}/{side*side} chunks loaded, wrote {out}")
