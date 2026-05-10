class_name Biomes
extends RefCounted

# Vanilla Alpha 1.2.6 biomes — direct port of the 11 biomes defined in
# `vendor/alpha-1.2.6-src/src/gg.java:7-17`. The Hell biome (`gg.l`) is
# omitted since the Nether is out of scope per CLAUDE.md.
#
# Biome enum order matches vanilla's static declaration order, NOT
# alphabetical — keeps cross-references with vanilla source easy.
#
# Each biome has:
#   * top_block: the surface block placed at the topmost STONE cell
#   * filler_block: the block placed in the N cells below the surface
#     (vanilla `n5` depth, computed by the beach pass's `t` noise; for
#     us it's a flat BEACH_SAND_DEPTH analog)
#   * grass_color / foliage_color: deferred to slice 3 (foliage tinting)
#
# Vanilla defaults (gg.java:28-34) for the gg base class:
#   top    = nq.u.bh = GRASS (id 2)
#   filler = nq.v.bh = DIRT  (id 3)
# Desert + Ice Desert override (gg.java:42-43): both top and filler = SAND
# Swamp / Plains / Savanna / etc. extend gg without overriding the
# defaults — they're functionally identical for surface block selection
# (decoration variety + foliage color are what visually differentiate
# them in vanilla; deferred to later slices).

enum Biome {
	RAINFOREST,  # gg.a — hot + wet, lush
	SWAMPLAND,  # gg.b — temperate + very wet, dark grass
	SEASONAL_FOREST,  # gg.c — temperate + medium wet
	FOREST,  # gg.d — temperate
	SAVANNA,  # gg.e — hot + dry
	SHRUBLAND,  # gg.f — temperate + dry
	TAIGA,  # gg.g — cold + wet, snowy
	DESERT,  # gg.h — hot + very dry, all sand
	PLAINS,  # gg.i — hot + dry-ish
	ICE_DESERT,  # gg.j — cold + dry, snow + sand
	TUNDRA,  # gg.k — very cold
}

const COUNT: int = 11

# Per-biome surface block. Indexed by Biome enum value.
# Mirrors vanilla `gg.o` (top block) defaults + Desert/Ice-Desert overrides.
const TOP_BLOCK: Array[int] = [
	Blocks.GRASS,  # RAINFOREST
	Blocks.GRASS,  # SWAMPLAND
	Blocks.GRASS,  # SEASONAL_FOREST
	Blocks.GRASS,  # FOREST
	Blocks.GRASS,  # SAVANNA
	Blocks.GRASS,  # SHRUBLAND
	Blocks.GRASS,  # TAIGA
	Blocks.SAND,  # DESERT — vanilla override
	Blocks.GRASS,  # PLAINS
	Blocks.SAND,  # ICE_DESERT — vanilla override
	Blocks.GRASS,  # TUNDRA
]

# Per-biome filler block (cells immediately below top). Mirrors vanilla `gg.p`.
const FILLER_BLOCK: Array[int] = [
	Blocks.DIRT,  # RAINFOREST
	Blocks.DIRT,  # SWAMPLAND
	Blocks.DIRT,  # SEASONAL_FOREST
	Blocks.DIRT,  # FOREST
	Blocks.DIRT,  # SAVANNA
	Blocks.DIRT,  # SHRUBLAND
	Blocks.DIRT,  # TAIGA
	Blocks.SAND,  # DESERT — vanilla override
	Blocks.DIRT,  # PLAINS
	Blocks.SAND,  # ICE_DESERT — vanilla override
	Blocks.DIRT,  # TUNDRA
]

# Display name for debug overlays + audit reports. Matches vanilla
# strings (gg.java:7-17 `.a("...")` arg).
const NAME: Array[String] = [
	"Rainforest",
	"Swampland",
	"Seasonal Forest",
	"Forest",
	"Savanna",
	"Shrubland",
	"Taiga",
	"Desert",
	"Plains",
	"Ice Desert",
	"Tundra",
]


# Convenience: SAND-as-default biomes don't run the beach pass — their
# whole chunk is already sand at the surface. Same for OCEAN-style biomes
# (would skip beach pass since columns ARE the ocean floor, no shoreline
# concept). Vanilla doesn't have an explicit "ocean biome" — instead any
# biome with surface_y < SEA_LEVEL gets WATER from the implicit ocean fill,
# and the beach pass handles the band [59, 64] specially.
#
# For our biome dispatch in the beach pass:
#   * Desert / Ice Desert — skip beach pass entirely (whole chunk is sand)
#   * Other biomes — run beach pass normally; biome.top_block decides
#     whether the column gets sand (in beach band) or grass (above band)
static func is_sand_biome(biome: int) -> bool:
	return biome == Biome.DESERT or biome == Biome.ICE_DESERT


# Get top surface block ID for a biome. O(1) array lookup.
static func top_block(biome: int) -> int:
	return TOP_BLOCK[biome]


# Get filler block ID for a biome.
static func filler_block(biome: int) -> int:
	return FILLER_BLOCK[biome]


# Display name of a biome for debug/audit output.
static func name_of(biome: int) -> String:
	return NAME[biome]
