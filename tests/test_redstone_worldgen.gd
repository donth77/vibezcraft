extends GutTest

# Phase 8 B1a — redstone ore generation (.claude/redstone-plan.md §6).
#
# Vanilla px.java:336-341 runs 8 vein attempts/chunk at size 7 with seed
# y = nextInt(16). Under the house _ORE_CONFIGS contract ([id, attempts,
# size, y_min, y_max] with inclusive final-cell clamps and the y=0
# bedrock exclusion) that confines every redstone cell to Y 1-16 —
# deviation §11.4 vs vanilla's unclamped upward ellipsoid tail.
#
# The yield oracle is deterministic, not statistical: WORLD_SEED pinned
# to 12345 and the fixed 8×8 chunk sample cx,cz ∈ [-4, 3] (same sample
# as test_worldgen.gd's density test). Target band [23, 35] cells/chunk
# = [100%, 140%] of the measured vanilla baseline (~23-25/chunk,
# .claude/vanilla-alpha-terrain-analysis.md:108).

const _SAMPLE_LO: int = -4
const _SAMPLE_HI: int = 4  # exclusive — range(-4, 4) = chunks -4..3
const _YIELD_MIN: float = 23.0
const _YIELD_MAX: float = 35.0
# Redstone cells can only exist in Y 1-16, so the yield scan stops at
# 17. The complementary "never above the band" assertion covers 17-127.
const _BAND_TOP_EXCLUSIVE: int = 17

var _terrain_3d_was: bool
var _seed_was: int


func before_all() -> void:
	# Pin the 2D pipeline + the canonical test seed so the fixed-sample
	# yield below is a deterministic oracle (redstone-plan.md §10).
	_terrain_3d_was = Worldgen.terrain_3d_enabled
	_seed_was = Worldgen.WORLD_SEED
	Worldgen.terrain_3d_enabled = false
	Worldgen.apply_world_seed(12345)


func after_all() -> void:
	Worldgen.terrain_3d_enabled = _terrain_3d_was
	Worldgen.apply_world_seed(_seed_was)


func _count_redstone(chunk: Chunk, y_top_exclusive: int) -> int:
	var count: int = 0
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			for y in range(y_top_exclusive):
				if chunk.get_block(x, y, z) == Blocks.REDSTONE_ORE:
					count += 1
	return count


func test_redstone_yield_in_vanilla_band_over_fixed_sample() -> void:
	var total: int = 0
	var chunk_count: int = 0
	for cx in range(_SAMPLE_LO, _SAMPLE_HI):
		for cz in range(_SAMPLE_LO, _SAMPLE_HI):
			var c := Worldgen.generate_chunk(cx, cz)
			chunk_count += 1
			total += _count_redstone(c, _BAND_TOP_EXCLUSIVE)
	var per_chunk: float = float(total) / float(chunk_count)
	print("redstone/chunk over %d chunks: %.2f" % [chunk_count, per_chunk])
	assert_between(
		per_chunk,
		_YIELD_MIN,
		_YIELD_MAX,
		"seed 12345, chunks -4..3: [23, 35] cells/chunk (100-140%% of vanilla ~23-25)"
	)


func test_redstone_confined_to_house_band_y1_16() -> void:
	# Same structure as test_worldgen.gd's diamond band test: the vein
	# walker is clamped to [y_lo, y_hi] = [1, 16], so no redstone cell
	# may appear at y=0 (bedrock band) or above y=16.
	for cx in range(-2, 3):
		for cz in range(-2, 3):
			var c := Worldgen.generate_chunk(cx, cz)
			for x in range(Chunk.SIZE_X):
				for z in range(Chunk.SIZE_Z):
					assert_ne(
						c.get_block(x, 0, z),
						Blocks.REDSTONE_ORE,
						"no redstone at y=0 in chunk (%d,%d)" % [cx, cz]
					)
					for y in range(_BAND_TOP_EXCLUSIVE, Chunk.SIZE_Y):
						assert_ne(
							c.get_block(x, y, z),
							Blocks.REDSTONE_ORE,
							"redstone above band at (%d,%d,%d) chunk (%d,%d)" % [x, y, z, cx, cz]
						)


func test_redstone_generation_is_deterministic() -> void:
	var c1 := Worldgen.generate_chunk(-3, 2)
	var c2 := Worldgen.generate_chunk(-3, 2)
	assert_eq(c1.blocks, c2.blocks, "regeneration reproduces identical bytes")
	assert_gt(
		(
			_count_redstone(c1, _BAND_TOP_EXCLUSIVE)
			+ _count_redstone(Worldgen.generate_chunk(0, 0), _BAND_TOP_EXCLUSIVE)
		),
		0,
		"sampled chunks actually contain redstone (guards against a silently dead config row)"
	)


func test_glowing_variant_never_generated() -> void:
	# Worldgen only places the unlit ore — the glowing id exists solely
	# as a gameplay state (contact glow, B1b).
	for cx in range(-2, 1):
		for cz in range(-2, 1):
			var c := Worldgen.generate_chunk(cx, cz)
			for x in range(Chunk.SIZE_X):
				for z in range(Chunk.SIZE_Z):
					for y in range(_BAND_TOP_EXCLUSIVE):
						assert_ne(
							c.get_block(x, y, z),
							Blocks.GLOWING_REDSTONE_ORE,
							"worldgen must never emit the lit variant"
						)
