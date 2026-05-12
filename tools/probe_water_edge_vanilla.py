#!/usr/bin/env python3
"""Count water-edge surface cells in vanilla Alpha 1.2.6 saves, to compare
against our gen. Same metric as tools/probe_water_edge.gd.
"""
import sys
from pathlib import Path
import nbtlib

WORLDS = ["World1", "World2", "World3", "World4", "World5"]
SAVE = Path.home() / "Library/Application Support/minecraft/saves"

# Vanilla block IDs
GRASS = 2
DIRT = 3
WATER_FLOWING = 8
WATER_STILL = 9
SAND = 12
AIR = 0


def surface_y(blocks, x, z):
    base = (x * 16 + z) * 128
    for y in range(127, -1, -1):
        b = blocks[base + y]
        if b not in (AIR, WATER_FLOWING, WATER_STILL):
            return y
    return -1


def get_block(blocks, x, y, z):
    if x < 0 or x >= 16 or z < 0 or z >= 16 or y < 0 or y >= 128:
        return -1
    return blocks[(x * 16 + z) * 128 + y]


for w in WORLDS:
    chunks = list((SAVE / w).rglob("c.*.dat"))
    if not chunks:
        continue
    n = 0
    total_surface = 0
    total_water_edge = 0
    total_water_cells = 0
    for f in chunks[:50]:  # sample 50 chunks per world
        try:
            blocks = bytes(nbtlib.load(f)["Level"]["Blocks"])
        except Exception:
            continue
        n += 1
        for x in range(1, 15):
            for z in range(1, 15):
                sy = surface_y(blocks, x, z)
                if sy < 0:
                    continue
                top = get_block(blocks, x, sy, z)
                if top not in (GRASS, DIRT, SAND):
                    continue
                total_surface += 1
                for dx, dz in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
                    nb = get_block(blocks, x + dx, sy, z + dz)
                    if nb in (WATER_FLOWING, WATER_STILL):
                        total_water_edge += 1
                        break
        # Total water cells in this chunk
        for b in blocks:
            if b == WATER_STILL:
                total_water_cells += 1
    if n == 0:
        continue
    print(f"=== VANILLA {w}, {n} chunks ===")
    print(f"  surface cells (grass/dirt/sand): {total_surface} ({total_surface/n:.1f}/chunk)")
    pct = 100.0 * total_water_edge / max(total_surface, 1)
    print(f"  water-edge cells: {total_water_edge} ({total_water_edge/n:.1f}/chunk = {pct:.1f}% of surface)")
    print(f"  total WATER_STILL: {total_water_cells} ({total_water_cells/n:.1f}/chunk)")
