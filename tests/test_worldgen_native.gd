extends GutTest

# Parity tests for the native worldgen base-terrain fill (WorldgenNative).
# The native path must produce chunk.blocks byte-identical to the pure
# GDScript path across a range of chunk coords — anything else is a
# regression in bedrock band randomness, strata layering, or max_y
# bookkeeping, which would break save compatibility and worldgen
# determinism.
#
# Ore + tree placement stay in GDScript for both paths, so the full
# generate_chunk output (including ores/trees on top of the fill) is
# what we compare. That exercises the whole pipeline end-to-end.


func before_each() -> void:
	# Defensive isolation — prior test files (test_density_terrain,
	# test_density_native_parity) toggle terrain_mode and the native
	# handle. Without this reset the parity check would compare across
	# a polluted state and surface as 1-cell divergences (especially
	# after the vanilla *12 Y-bias change made tiny FP differences in
	# noise caches amplify into block-level mismatches).
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_2D_HEIGHTMAP
	Worldgen.apply_world_seed(12345)
	WorldgenDensity.reset()


func _generate_with_native(chunk_x: int, chunk_z: int) -> Chunk:
	# Safety guard: only run if the extension actually loaded. Otherwise
	# these tests would silently compare GDScript vs GDScript.
	assert_true(
		ClassDB.class_exists("WorldgenNative"),
		"WorldgenNative not registered — skip this test or rebuild via `scons`."
	)
	var prev := Worldgen._native_worldgen
	if prev == null:
		Worldgen.enable_native()
	# Reset noise caches before each generate so prior chunk gens (which
	# may have warmed FastNoiseLite caches with different seeds) can't
	# leak FP-precision differences into the byte-equality check.
	WorldgenDensity.reset()
	Worldgen.apply_world_seed(12345)
	var chunk := Worldgen.generate_chunk(chunk_x, chunk_z)
	Worldgen._native_worldgen = prev
	return chunk


func _generate_with_gdscript(chunk_x: int, chunk_z: int) -> Chunk:
	var prev := Worldgen._native_worldgen
	Worldgen._native_worldgen = null
	WorldgenDensity.reset()
	Worldgen.apply_world_seed(12345)
	var chunk := Worldgen.generate_chunk(chunk_x, chunk_z)
	Worldgen._native_worldgen = prev
	return chunk


func _assert_parity(chunk_x: int, chunk_z: int) -> void:
	var native_chunk := _generate_with_native(chunk_x, chunk_z)
	var gds_chunk := _generate_with_gdscript(chunk_x, chunk_z)
	assert_eq(native_chunk.max_y, gds_chunk.max_y, "max_y parity at (%d, %d)" % [chunk_x, chunk_z])
	assert_eq(
		native_chunk.blocks,
		gds_chunk.blocks,
		"chunk.blocks byte-equal at (%d, %d)" % [chunk_x, chunk_z]
	)


func test_parity_origin_chunk() -> void:
	_assert_parity(0, 0)


func test_parity_positive_offset_chunk() -> void:
	_assert_parity(3, -2)


func test_parity_far_chunk() -> void:
	_assert_parity(47, -31)


func test_parity_negative_quadrant_chunk() -> void:
	_assert_parity(-5, -7)


func test_native_chunk_still_passes_base_layer_assertions() -> void:
	# Reuses the invariants from test_worldgen.gd but on the native path,
	# to make sure the C++ fill respects the bedrock / dirt / stone /
	# grass contract independently of the parity-vs-GDScript check. Surface
	# can be grass OR beach sand depending on whether the column sits in
	# the beach band around sea level.
	var chunk := _generate_with_native(0, 0)
	var surface_ok: Array[int] = [Blocks.GRASS, Blocks.SAND]
	var subsurface_ok: Array[int] = [Blocks.DIRT, Blocks.SAND]
	for x: int in [0, 7, 15]:
		for z: int in [0, 7, 15]:
			var h := Worldgen.surface_height(x, z)
			assert_eq(chunk.get_block(x, 0, z), Blocks.BEDROCK, "(%d,0,%d) bedrock" % [x, z])
			assert_true(
				chunk.get_block(x, h, z) in surface_ok, "(%d,%d,%d) grass or sand" % [x, h, z]
			)
			assert_true(
				chunk.get_block(x, h - 1, z) in subsurface_ok,
				"(%d,%d,%d) dirt or sand" % [x, h - 1, z]
			)
