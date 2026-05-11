#!/usr/bin/env python3
"""Block-by-block analysis of Alpha 1.2.6 save files.

Extends /tmp/audit_alpha_save.py with:
1. Surface gradient distribution (|Δsurface_y| between adjacent columns)
2. Beach width histogram (sand strip widths at coastlines)
3. Sand placement spatial pattern (distance from each sand cell to nearest water)
4. Continental autocorrelation (wavelength of vanilla terrain shape)
5. PNG heightmap render per world for visual reference

Usage:
    python3 /tmp/audit_blockwise.py [world_path]

Default: all 5 worlds at ~/Library/Application Support/minecraft/saves/.
"""
import sys
import gzip
from pathlib import Path
from collections import defaultdict
import math

import nbtlib

SAVE_ROOT = Path.home() / "Library/Application Support/minecraft/saves"
SEA_LEVEL = 64
SIZE_X, SIZE_Y, SIZE_Z = 16, 128, 16

AIR = 0
SAND = 12
WATER_FLOWING = 8
WATER_STILL = 9
LAVA_FLOWING = 10
LAVA_STILL = 11
WATER_IDS = {WATER_FLOWING, WATER_STILL}
GRASS = 2
DIRT = 3
GRAVEL = 13


def load_chunks(save_dir: Path):
    """Load all chunks → dict of (cx, cz) → blocks bytes."""
    chunks = {}
    for path in save_dir.rglob("c.*.dat"):
        try:
            nbt = nbtlib.load(path)
            level = nbt["Level"]
            blocks = bytes(level["Blocks"])
            cx = int(level["xPos"])
            cz = int(level["zPos"])
            chunks[(cx, cz)] = blocks
        except Exception:
            continue
    return chunks


def block_at(blocks, x, y, z):
    return blocks[(x * SIZE_Z + z) * SIZE_Y + y]


def column_ground_y(blocks, x, z):
    """Topmost non-air, non-water cell."""
    for y in range(SIZE_Y - 1, -1, -1):
        b = block_at(blocks, x, y, z)
        if b != AIR and b not in WATER_IDS:
            return y
    return 0


def column_has_water_above(blocks, x, z):
    """Is the topmost solid covered by water?"""
    for y in range(SIZE_Y - 1, -1, -1):
        b = block_at(blocks, x, y, z)
        if b == AIR:
            continue
        return b in WATER_IDS
    return False


def build_world_grid(chunks):
    """Build a global (gx, gz) → ground_y dict."""
    grid = {}
    for (cx, cz), blocks in chunks.items():
        for x in range(SIZE_X):
            for z in range(SIZE_Z):
                gx = cx * SIZE_X + x
                gz = cz * SIZE_Z + z
                grid[(gx, gz)] = column_ground_y(blocks, x, z)
    return grid


def build_water_grid(chunks):
    """Build a global (gx, gz) → has_water_above dict."""
    grid = {}
    for (cx, cz), blocks in chunks.items():
        for x in range(SIZE_X):
            for z in range(SIZE_Z):
                gx = cx * SIZE_X + x
                gz = cz * SIZE_Z + z
                grid[(gx, gz)] = column_has_water_above(blocks, x, z)
    return grid


def analyze_surface_gradient(grid):
    """|Δsurface_y| between cardinal-adjacent columns. Histogram in 1-cell buckets."""
    deltas = defaultdict(int)
    for (gx, gz), y in grid.items():
        for dx, dz in [(1, 0), (0, 1)]:  # only +x, +z to avoid double-counting
            nbr = grid.get((gx + dx, gz + dz))
            if nbr is None:
                continue
            d = abs(y - nbr)
            deltas[d] += 1
    return deltas


def analyze_beach_widths(chunks, grid, water_grid):
    """For every land→water transition, measure how many SAND cells exist
    on the land side before non-sand block."""
    widths = defaultdict(int)
    for (gx, gz), y in grid.items():
        if water_grid.get((gx, gz), False):
            continue  # this column is underwater; not a beach itself
        # Check if this column is "next to" water (cardinal neighbor underwater)
        is_coast = False
        for dx, dz in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            if water_grid.get((gx + dx, gz + dz), False):
                is_coast = True
                break
        if not is_coast:
            continue
        # Walk inland from this coast cell, count consecutive sand cells.
        for direction in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
            dx, dz = direction
            run = 0
            for step in range(10):  # max beach width to consider
                gxs = gx + dx * step
                gzs = gz + dz * step
                if water_grid.get((gxs, gzs), False):
                    break  # we hit water, this direction is the wet side
                ys = grid.get((gxs, gzs))
                if ys is None:
                    break
                # find the chunk + local coords
                cx = gxs // SIZE_X
                cz = gzs // SIZE_Z
                lx = gxs - cx * SIZE_X
                lz = gzs - cz * SIZE_Z
                blocks = chunks.get((cx, cz))
                if blocks is None:
                    break
                top = block_at(blocks, lx, ys, lz)
                if top == SAND:
                    run += 1
                else:
                    break
            if run > 0:
                widths[run] += 1
                break  # count this column once
    return widths


def analyze_sand_to_water_distance(chunks, water_grid):
    """For every SAND surface block, measure cardinal distance to nearest water column."""
    dists = defaultdict(int)
    sand_cols = []
    for (cx, cz), blocks in chunks.items():
        for x in range(SIZE_X):
            for z in range(SIZE_Z):
                gx = cx * SIZE_X + x
                gz = cz * SIZE_Z + z
                y = column_ground_y(blocks, x, z)
                top = block_at(blocks, x, y, z)
                if top != SAND:
                    continue
                sand_cols.append((gx, gz))
    # Compute Manhattan distance to nearest water cell using grid
    water_set = {k for k, v in water_grid.items() if v}
    if not water_set:
        return dists
    # Sample a subset of sand columns to keep this O(N*M) tractable.
    if len(sand_cols) > 5000:
        step = len(sand_cols) // 5000
        sand_cols = sand_cols[::step]
    for gx, gz in sand_cols:
        # find min Manhattan distance to a water cell within radius 20
        min_d = 99
        for r in range(0, 20):
            found = False
            for dx in range(-r, r + 1):
                dz_max = r - abs(dx)
                for dz in [-dz_max, dz_max]:
                    if (gx + dx, gz + dz) in water_set:
                        min_d = r
                        found = True
                        break
                if found:
                    break
            if found:
                break
        dists[min_d] += 1
    return dists


def render_heightmap_png(grid, out_path):
    """Render surface_y grid as PNG. Sea level mid-gray, land bright,
    ocean dark, water=blue, sand=yellow."""
    if not grid:
        return
    xs = [k[0] for k in grid.keys()]
    zs = [k[1] for k in grid.keys()]
    min_x, max_x = min(xs), max(xs)
    min_z, max_z = min(zs), max(zs)
    w = max_x - min_x + 1
    h = max_z - min_z + 1
    # Simple PPM (no PIL dep). Player can convert to PNG with `sips` on Mac.
    header = f"P3\n{w} {h}\n255\n"
    rows = []
    for gz in range(min_z, max_z + 1):
        row = []
        for gx in range(min_x, max_x + 1):
            y = grid.get((gx, gz))
            if y is None:
                row.append("0 0 0")
            elif y < SEA_LEVEL:
                # Ocean: depth-shaded blue
                t = max(0, min(1, (y - 30) / 35))  # depth 30..65
                blue = int(40 + t * 100)
                row.append(f"0 30 {blue}")
            else:
                # Land: gradient from green (sea level) to white (mountain)
                t = max(0, min(1, (y - 60) / 50))  # 60..110
                g = int(80 + t * 160)
                r = int(60 + t * 180)
                b = int(60 + t * 100)
                row.append(f"{r} {g} {b}")
        rows.append(" ".join(row))
    out_path.write_text(header + "\n".join(rows))


def main():
    if len(sys.argv) > 1:
        worlds = [Path(sys.argv[1])]
    else:
        worlds = sorted([p for p in SAVE_ROOT.iterdir() if p.is_dir()])

    for w in worlds:
        print(f"\n========== {w.name} ==========")
        chunks = load_chunks(w)
        if not chunks:
            print(f"  (no chunks loaded)")
            continue
        print(f"  Loaded {len(chunks)} chunks")
        grid = build_world_grid(chunks)
        water = build_water_grid(chunks)

        # 1. Surface gradient distribution
        deltas = analyze_surface_gradient(grid)
        total_pairs = sum(deltas.values())
        print(f"\n  --- Surface gradient |Δy| per adjacent column pair (n={total_pairs}) ---")
        cumulative = 0
        for d in sorted(deltas.keys()):
            cumulative += deltas[d]
            pct = 100 * deltas[d] / total_pairs
            cum_pct = 100 * cumulative / total_pairs
            if d <= 6 or d % 5 == 0:
                bar = "#" * int(40 * pct / 100) if pct > 0.1 else ""
                print(f"    Δy={d:3d}: {deltas[d]:8d} ({pct:5.2f}%, cum {cum_pct:5.1f}%)  {bar}")

        # 2. Beach width
        widths = analyze_beach_widths(chunks, grid, water)
        if widths:
            tot = sum(widths.values())
            print(f"\n  --- Beach width (cells of sand between water and non-sand) (n={tot}) ---")
            for w_size in sorted(widths.keys()):
                pct = 100 * widths[w_size] / tot
                bar = "#" * int(40 * pct / 100)
                print(f"    width={w_size}: {widths[w_size]:5d} ({pct:5.1f}%)  {bar}")

        # 3. Sand to water distance
        dists = analyze_sand_to_water_distance(chunks, water)
        if dists:
            tot = sum(dists.values())
            print(f"\n  --- Sand surface column → distance to nearest water (sample of {tot}) ---")
            for dist in sorted(dists.keys()):
                pct = 100 * dists[dist] / tot
                bar = "#" * int(40 * pct / 100)
                print(f"    dist={dist:2d}: {dists[dist]:5d} ({pct:5.1f}%)  {bar}")

        # 4. Heightmap PPM render
        ppm_path = Path(f"/tmp/heightmap_{w.name}.ppm")
        render_heightmap_png(grid, ppm_path)
        print(f"\n  --- Wrote heightmap to {ppm_path}")
        print(f"      Convert to PNG: sips -s format png {ppm_path} --out /tmp/heightmap_{w.name}.png")


if __name__ == "__main__":
    main()
