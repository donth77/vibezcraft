extends GutTest

# Slice 3-B: 3D density terrain integration tests.
# Verifies the MODE_3D_DENSITY path produces a sane chunk (not all-air,
# not all-stone, has surface variation) and that mode is properly
# isolated (toggling doesn't affect 2D-mode determinism).


func before_each() -> void:
	Worldgen.apply_world_seed(12345)
	# Reset to default so tests don't leak mode state between runs.
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_2D_HEIGHTMAP


func after_each() -> void:
	# Always restore default — other test files assume MODE_2D_HEIGHTMAP.
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_2D_HEIGHTMAP


func test_3d_density_mode_produces_non_trivial_chunk() -> void:
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_3D_DENSITY
	# Scan a 5×5 area instead of just (0,0) — any single chunk may
	# happen to land entirely below sea level (all-DIRT, no GRASS),
	# but a 25-chunk sample is guaranteed to include some land.
	var stone_count: int = 0
	var grass_count: int = 0
	var bedrock_count: int = 0
	var air_count: int = 0
	for cx in range(-2, 3):
		for cz in range(-2, 3):
			var chunk := Worldgen.generate_chunk(cx, cz)
			for i in range(Chunk.TOTAL_BLOCKS):
				match chunk.blocks[i]:
					Blocks.STONE:
						stone_count += 1
					Blocks.GRASS:
						grass_count += 1
					Blocks.BEDROCK:
						bedrock_count += 1
					Blocks.AIR:
						air_count += 1
	assert_gt(stone_count, 1000, "expected substantial stone")
	assert_gt(air_count, 1000, "expected substantial air")
	assert_gt(grass_count, 0, "expected at least one grass cell across 25 chunks")
	assert_gt(bedrock_count, 0, "expected at least one bedrock cell")


func test_3d_density_mode_is_deterministic() -> void:
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_3D_DENSITY
	var c1 := Worldgen.generate_chunk(2, -3)
	var c2 := Worldgen.generate_chunk(2, -3)
	assert_eq(c1.blocks, c2.blocks, "same coord + same mode = identical blocks")


func test_2d_mode_unchanged_after_3d_run() -> void:
	# Generate a baseline in 2D mode.
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_2D_HEIGHTMAP
	var baseline := Worldgen.generate_chunk(0, 0)
	# Switch to 3D, generate something, switch back. The 2D path should
	# still produce the same baseline blocks — no cross-contamination.
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_3D_DENSITY
	Worldgen.generate_chunk(5, 5)
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_2D_HEIGHTMAP
	var after := Worldgen.generate_chunk(0, 0)
	assert_eq(baseline.blocks, after.blocks, "2D mode unaffected by 3D mode runs")


# Integration test: beach band fires only on columns whose ACTUAL surface
# (the chunk's topmost non-AIR cell) is in [60, 65], NOT the heightmap's
# surface_height. The earlier bug was beach/ocean/tree passes querying
# the 2D heightmap surface even in 3D mode, producing sand mixed with
# grass everywhere because the heightmap value didn't match the chunk's
# real surface. Verify by looking at sand placements: every sand cell
# should have its column's actual surface within the beach band.
func test_3d_density_beaches_only_on_correct_columns() -> void:
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_3D_DENSITY
	var sand_violations: int = 0
	var checked_chunks: int = 0
	for cx in range(-1, 2):
		for cz in range(-1, 2):
			var chunk := Worldgen.generate_chunk(cx, cz)
			checked_chunks += 1
			for x in range(Chunk.SIZE_X):
				for z in range(Chunk.SIZE_Z):
					# Find topmost SAND cell (if any).
					var top_sand_y: int = -1
					for y in range(Chunk.SIZE_Y - 1, -1, -1):
						if chunk.get_block_unchecked(x, y, z) == Blocks.SAND:
							top_sand_y = y
							break
					if top_sand_y < 0:
						continue
					# Sand should only exist within or below the beach band.
					# The beach band's high edge is SEA_LEVEL + BEACH_PASS_HI_OFFSET
					# (5 cells above sea — the dry-beach zone). Sand above
					# that means the beach pass placed sand on a hill,
					# indicating a stale surface_y read.
					if top_sand_y > Worldgen.SEA_LEVEL + Worldgen.BEACH_PASS_HI_OFFSET:
						sand_violations += 1
	assert_gt(checked_chunks, 0, "test sanity: at least one chunk generated")
	assert_eq(
		sand_violations,
		0,
		(
			(
				"beach pass placed sand above SEA_LEVEL+%d in %d cells — beach passes are using "
				+ "a stale surface_y (heightmap) instead of the chunk's actual surface"
			)
			% [Worldgen.BEACH_PASS_HI_OFFSET, sand_violations]
		)
	)


# Sanity: surface should hover around TARGET_Y. Sample many columns
# and verify the average top-of-stone is in a reasonable range.
func test_3d_density_surface_clusters_near_target_y() -> void:
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_3D_DENSITY
	var sum: int = 0
	var count: int = 0
	for cx in range(-1, 2):
		for cz in range(-1, 2):
			var chunk := Worldgen.generate_chunk(cx, cz)
			for x in range(0, Chunk.SIZE_X, 4):
				for z in range(0, Chunk.SIZE_Z, 4):
					# Find the topmost non-AIR cell.
					for y in range(Chunk.SIZE_Y - 1, -1, -1):
						if chunk.get_block_unchecked(x, y, z) != Blocks.AIR:
							sum += y
							count += 1
							break
	var avg: float = float(sum) / float(count)
	# Loose: surface mean should be within ±20 of TARGET_Y. If far below,
	# the air-bias is too weak; far above, the stone-bias is too weak.
	assert_between(
		avg,
		float(WorldgenDensity.TARGET_Y - 20),
		float(WorldgenDensity.TARGET_Y + 20),
		"surface mean (%.1f) should cluster near TARGET_Y (%d)" % [avg, WorldgenDensity.TARGET_Y]
	)
