#!/usr/bin/env python3
"""Audit surface y range across an Alpha 1.2.6 save folder.

Mirrors the audit format we use on our clone so numbers compare directly.
"""
import sys
import gzip
import struct
from pathlib import Path
from collections import defaultdict

import nbtlib

SAVE_DIR = Path.home() / "Library/Application Support/minecraft/saves/World1"
SEA_LEVEL = 64
SIZE_X, SIZE_Y, SIZE_Z = 16, 128, 16

# Alpha block IDs (subset we care about for surface analysis).
AIR = 0
WATER_FLOWING = 8
WATER_STILL = 9
LAVA_FLOWING = 10
LAVA_STILL = 11

WATER_IDS = {WATER_FLOWING, WATER_STILL}


def load_chunk(path: Path):
    """Load Alpha chunk NBT. Returns (blocks_bytes, chunk_x, chunk_z)."""
    nbt = nbtlib.load(path)
    level = nbt["Level"]
    blocks = bytes(level["Blocks"])
    cx = int(level["xPos"])
    cz = int(level["zPos"])
    return blocks, cx, cz


def column_surface_info(blocks: bytes, x: int, z: int):
    """Returns (true_ground_y, top_block_y_above_water).
    true_ground_y = topmost non-air, non-water cell (real surface)
    is_underwater = whether the topmost solid is below sea level + water above"""
    base = (x * SIZE_Z + z) * SIZE_Y
    ground_y = 0
    has_water_above = False
    for y in range(SIZE_Y - 1, -1, -1):
        b = blocks[base + y]
        if b in WATER_IDS:
            has_water_above = True
            continue
        if b != AIR:
            ground_y = y
            break
    return ground_y, has_water_above


def main():
    save_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else SAVE_DIR
    chunks = list(save_dir.rglob("c.*.dat"))
    print(f"Found {len(chunks)} chunks in {save_dir}")

    surface_ys = []  # ground y for ALL columns (incl. seabed)
    land_ys = []  # ground y for LAND columns only (not underwater)
    above_sea = 0
    beach_band_strict = 0  # land columns w/ y in [60,65] (matches our audit)
    beach_band_all = 0  # all columns w/ y in [60,65] (incl. shallow seabed)
    ocean_columns = 0
    underwater_block_counts = defaultdict(int)  # what's on the SEABED
    block_counts = defaultdict(int)
    chunk_coords = []

    for path in chunks:
        try:
            blocks, cx, cz = load_chunk(path)
        except Exception:
            continue
        chunk_coords.append((cx, cz))
        for x in range(SIZE_X):
            for z in range(SIZE_Z):
                sy, has_water = column_surface_info(blocks, x, z)
                surface_ys.append(sy)
                if has_water:
                    ocean_columns += 1
                    # What block is at the seabed?
                    seabed_block = blocks[(x * SIZE_Z + z) * SIZE_Y + sy]
                    underwater_block_counts[seabed_block] += 1
                else:
                    land_ys.append(sy)
                    if sy >= SEA_LEVEL:
                        above_sea += 1
                    if 60 <= sy <= 65:
                        beach_band_strict += 1
                if 60 <= sy <= 65:
                    beach_band_all += 1
        # Block tally for the chunk
        for b in blocks:
            block_counts[b] += 1

    if not surface_ys:
        print("No chunks parsed.")
        return

    n = len(surface_ys)
    surface_ys.sort()
    cx_list = [c[0] for c in chunk_coords]
    cz_list = [c[1] for c in chunk_coords]
    print(f"\nChunk extent: x[{min(cx_list)}..{max(cx_list)}] z[{min(cz_list)}..{max(cz_list)}]")
    print(f"\n--- Surface Statistics ---")
    print(f"  Surface y    min={surface_ys[0]} max={surface_ys[-1]} "
          f"mean={sum(surface_ys)/n:.1f} median={surface_ys[n//2]}")
    print(f"  Land cols    {len(land_ys)}/{n} ({100.0*len(land_ys)/n:.1f}%)")
    print(f"  Ocean cols   {ocean_columns}/{n} ({100.0*ocean_columns/n:.1f}%)")
    print(f"  Above sea    {above_sea}/{n} ({100.0*above_sea/n:.1f}%) [land cols at y>=64]")
    print(f"  Beach (LAND) {beach_band_strict}/{n} ({100.0*beach_band_strict/n:.1f}%) [land cols y∈[60,65]]")
    print(f"  Beach (ALL)  {beach_band_all}/{n} ({100.0*beach_band_all/n:.1f}%) [any col y∈[60,65]]")
    if underwater_block_counts:
        print(f"\n--- Seabed composition (underwater columns only) ---")
        ub_total = sum(underwater_block_counts.values())
        name_for_ub = {3: "DIRT", 12: "SAND", 13: "GRAVEL", 1: "STONE", 2: "GRASS"}
        for bid, c in sorted(underwater_block_counts.items(), key=lambda x: -x[1])[:6]:
            nm = name_for_ub.get(bid, f"id_{bid}")
            print(f"  {nm:10s}({bid:3d}): {c}/{ub_total} ({100.0*c/ub_total:.1f}%)")

    # Histogram in 5-cell buckets
    print(f"\n--- Surface y histogram (5-cell buckets) ---")
    buckets = defaultdict(int)
    for y in surface_ys:
        buckets[(y // 5) * 5] += 1
    for k in sorted(buckets.keys()):
        bar = "#" * int(50 * buckets[k] / max(buckets.values()))
        print(f"  y={k:3d}-{k+4:3d}: {buckets[k]:6d}  {bar}")

    # Block counts (per-chunk averages, top 12)
    chunks_n = len(chunks)
    print(f"\n--- Block counts (per chunk averages) ---")
    name_for = {0: "AIR", 1: "STONE", 2: "GRASS", 3: "DIRT", 4: "COBBLE",
                5: "PLANKS", 7: "BEDROCK", 8: "WATER_F", 9: "WATER_S",
                10: "LAVA_F", 11: "LAVA_S", 12: "SAND", 13: "GRAVEL",
                14: "GOLD_ORE", 15: "IRON_ORE", 16: "COAL_ORE", 17: "LOG",
                18: "LEAVES", 56: "DIAMOND_ORE"}
    sorted_blocks = sorted(block_counts.items(), key=lambda x: -x[1])[:14]
    for bid, count in sorted_blocks:
        avg = count / chunks_n
        nm = name_for.get(bid, f"id_{bid}")
        print(f"  {nm:14s}({bid:3d})  {avg:8.1f}/chunk")


if __name__ == "__main__":
    main()
