#!/usr/bin/env python3
"""Cell-by-cell diff between a vanilla Alpha 1.2.6 chunk save and a chunk
exported from our generator.

Usage:
    python3 tools/compare_chunks.py <vanilla.dat> <ours.raw>

Vanilla format: gzipped NBT, Level.Blocks is 32768 bytes indexed
    (x*16 + z)*128 + y
Our format: raw 32768 bytes in the same vanilla layout (export_chunk.gd
    writes them in the vanilla index order).

CRITICAL: Our codebase uses different block IDs than vanilla
(scripts/world/blocks.gd assigns BEDROCK=1 STONE=2 GRASS=4 etc.; vanilla
uses STONE=1 GRASS=2 BEDROCK=7). This script translates OUR IDs to
VANILLA IDs before comparing, via OUR_TO_VANILLA below.

Outputs:
- Total cell match %
- First (x, y, z) where they diverge
- Match % per Y band (bedrock, stone, surface, above-surface)
- Block-type confusion table (vanilla → our mapping, both shown as vanilla IDs)
"""
import sys
from collections import Counter, defaultdict
from pathlib import Path

import nbtlib

SIZE_X, SIZE_Y, SIZE_Z = 16, 128, 16
TOTAL = SIZE_X * SIZE_Y * SIZE_Z

# Vanilla Alpha 1.2.6 block ID names.
NAMES = {
    0: "AIR", 1: "STONE", 2: "GRASS", 3: "DIRT", 4: "COBBLE",
    5: "PLANKS", 6: "SAPLING", 7: "BEDROCK", 8: "WATER_F", 9: "WATER_S",
    10: "LAVA_F", 11: "LAVA_S", 12: "SAND", 13: "GRAVEL", 14: "GOLD_ORE",
    15: "IRON_ORE", 16: "COAL_ORE", 17: "LOG", 18: "LEAVES", 19: "SPONGE",
    20: "GLASS", 37: "DANDELION", 38: "POPPY", 39: "BROWN_MUSH",
    40: "RED_MUSH", 45: "BRICK", 46: "TNT", 49: "OBSIDIAN", 50: "TORCH",
    51: "FIRE", 53: "WOOD_STAIRS", 54: "CHEST", 56: "DIAMOND_ORE",
    58: "WORKBENCH", 60: "FARMLAND", 61: "FURNACE", 62: "LIT_FURNACE",
    64: "WOOD_DOOR", 65: "LADDER", 67: "COB_STAIRS", 71: "IRON_DOOR",
    73: "REDSTONE_ORE", 78: "SNOW_LAYER", 79: "ICE", 80: "SNOW_BLOCK",
    81: "CACTUS", 82: "CLAY", 83: "SUGAR_CANE", 85: "FENCE",
}

# Translation table: our internal block ID → vanilla Alpha 1.2.6 block ID.
# Our scripts/world/blocks.gd assigns IDs sequentially from 1 (different
# from vanilla's MC-standard IDs). To compare cell-by-cell with vanilla
# saves, translate our IDs into vanilla IDs first.
OUR_TO_VANILLA = {
    0: 0,    # AIR → AIR
    1: 7,    # BEDROCK → BEDROCK
    2: 1,    # STONE → STONE
    3: 3,    # DIRT → DIRT
    4: 2,    # GRASS → GRASS
    5: 4,    # COBBLESTONE → COBBLE
    6: 17,   # LOG → LOG
    7: 5,    # PLANKS → PLANKS
    8: 18,   # LEAVES → LEAVES
    9: 12,   # SAND → SAND
    10: 45,  # BRICK → BRICK
    11: 49,  # OBSIDIAN → OBSIDIAN
    12: 16,  # COAL_ORE → COAL_ORE
    13: 15,  # IRON_ORE → IRON_ORE
    14: 14,  # GOLD_ORE → GOLD_ORE
    15: 56,  # DIAMOND_ORE → DIAMOND_ORE
    16: 58,  # CRAFTING_TABLE → WORKBENCH
    17: 60,  # FARMLAND → FARMLAND
    18: 13,  # GRAVEL → GRAVEL
    19: 61,  # FURNACE → FURNACE
    20: 62,  # LIT_FURNACE → LIT_FURNACE
    21: 20,  # GLASS → GLASS
    22: 6,   # SAPLING → SAPLING
    23: 8,   # WATER_FLOWING → WATER_FLOWING
    24: 9,   # WATER_STILL → WATER_STILL
    25: 10,  # LAVA_FLOWING → LAVA_FLOWING
    26: 11,  # LAVA_STILL → LAVA_STILL
    27: 51,  # FIRE → FIRE
    28: 50,  # TORCH → TORCH
    29: 54,  # CHEST → CHEST
    30: 85,  # FENCE → FENCE (vanilla 85 in Beta; Alpha may differ)
    31: 53,  # WOOD_STAIRS → WOOD_STAIRS
    32: 67,  # COBBLE_STAIRS → COBBLE_STAIRS
    33: 64,  # WOODEN_DOOR → WOODEN_DOOR
    34: 71,  # IRON_DOOR → IRON_DOOR
    35: 65,  # LADDER → LADDER
    36: 46,  # TNT → TNT
    37: 38,  # FLOWER_RED (poppy) → POPPY
    38: 37,  # FLOWER_YELLOW (dandelion) → DANDELION
    39: 39,  # MUSHROOM_BROWN → BROWN_MUSH
    40: 40,  # MUSHROOM_RED → RED_MUSH
}


def translate_our_to_vanilla(our_blocks: bytes) -> bytes:
    """Translate every byte from our ID space to vanilla ID space."""
    out = bytearray(len(our_blocks))
    for i, b in enumerate(our_blocks):
        out[i] = OUR_TO_VANILLA.get(b, b)  # passthrough unknown
    return bytes(out)


def name_for(block_id: int) -> str:
    return NAMES.get(block_id, f"id_{block_id}")


def load_vanilla_chunk(path: Path) -> bytes:
    nbt = nbtlib.load(path)
    return bytes(nbt["Level"]["Blocks"])


def load_our_chunk(path: Path) -> bytes:
    raw = path.read_bytes()
    return translate_our_to_vanilla(raw)


def vanilla_idx(x: int, y: int, z: int) -> int:
    return (x * SIZE_Z + z) * SIZE_Y + y


def main() -> None:
    if len(sys.argv) != 3:
        print("Usage: compare_chunks.py <vanilla.dat> <ours.raw>", file=sys.stderr)
        sys.exit(1)
    vanilla_path = Path(sys.argv[1])
    ours_path = Path(sys.argv[2])

    vanilla = load_vanilla_chunk(vanilla_path)
    ours = load_our_chunk(ours_path)

    if len(vanilla) != TOTAL or len(ours) != TOTAL:
        print(f"Size mismatch: vanilla={len(vanilla)} ours={len(ours)} expected={TOTAL}",
              file=sys.stderr)
        sys.exit(1)

    matches = 0
    first_div = None
    band_total = defaultdict(int)
    band_match = defaultdict(int)
    confusion = Counter()  # (vanilla_id, our_id) -> count of mismatched cells

    for x in range(SIZE_X):
        for z in range(SIZE_Z):
            for y in range(SIZE_Y):
                i = vanilla_idx(x, y, z)
                v = vanilla[i]
                o = ours[i]
                if y < 5:
                    band = "bedrock"
                elif y < 50:
                    band = "stone"
                elif y < 70:
                    band = "surface"
                else:
                    band = "above"
                band_total[band] += 1
                if v == o:
                    matches += 1
                    band_match[band] += 1
                else:
                    if first_div is None:
                        first_div = (x, y, z, v, o)
                    confusion[(v, o)] += 1

    pct = 100.0 * matches / TOTAL
    print(f"=== {vanilla_path.name} vs {ours_path.name} ===")
    print(f"Cell match: {matches}/{TOTAL} ({pct:.2f}%)")
    if first_div is not None:
        x, y, z, v, o = first_div
        print(f"First divergence: ({x}, {y}, {z}) vanilla={name_for(v)}({v}) "
              f"ours={name_for(o)}({o})")

    print("\nMatch % by Y band:")
    for band in ["bedrock", "stone", "surface", "above"]:
        t = band_total[band]
        m = band_match[band]
        if t > 0:
            print(f"  {band:9s} (y={'0-4' if band == 'bedrock' else '5-49' if band == 'stone' else '50-69' if band == 'surface' else '70-127'}): "
                  f"{100*m/t:.2f}% ({m}/{t})")

    print("\nTop 10 confusion pairs (vanilla → ours):")
    for (v, o), count in confusion.most_common(10):
        print(f"  {name_for(v):14s}({v:3d}) -> {name_for(o):14s}({o:3d}): {count} cells")


if __name__ == "__main__":
    main()
