extends GutTest

var _terrain_3d_was: bool


func before_all() -> void:
	_terrain_3d_was = Worldgen.terrain_3d_enabled


func after_all() -> void:
	Worldgen.terrain_3d_enabled = _terrain_3d_was


static func _first_unsupported_gravity(chunk: Chunk) -> Vector3i:
	for y in range(1, Chunk.SIZE_Y):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				var id: int = chunk.get_block_unchecked(x, y, z)
				if not Blocks.has_gravity(id):
					continue
				var below: int = chunk.get_block_unchecked(x, y - 1, z)
				if FallingBlock.is_passable_for_fall(below):
					return Vector3i(x, y, z)
	return Vector3i(-1, -1, -1)


func test_generated_chunk_settles_known_cave_exposed_sand_repro() -> void:
	Worldgen.terrain_3d_enabled = false
	# Pre-fix deterministic repro: local (15,45,8) in this chunk was a
	# gravity block over cave AIR until a player update woke it.
	var chunk := Worldgen.generate_chunk(-8, -5)
	assert_eq(
		_first_unsupported_gravity(chunk),
		Vector3i(-1, -1, -1),
		"fresh chunks must never present dormant unsupported sand/gravel"
	)


func test_generated_gravity_stack_compacts_through_air_and_water_in_one_pass() -> void:
	var chunk := Chunk.new()
	chunk.set_block_unchecked(3, 2, 4, Blocks.STONE)
	chunk.set_block_unchecked(3, 3, 4, Blocks.WATER_STILL)
	chunk.set_block_unchecked(3, 4, 4, Blocks.WATER_STILL)
	chunk.set_block_unchecked(3, 7, 4, Blocks.SAND)
	chunk.set_block_unchecked(3, 8, 4, Blocks.GRAVEL)

	var moved: int = Worldgen._settle_generated_gravity_blocks(chunk)

	assert_eq(moved, 2, "both stacked gravity blocks move in one column scan")
	assert_eq(chunk.get_block_unchecked(3, 3, 4), Blocks.SAND, "sand sinks to the floor")
	assert_eq(chunk.get_block_unchecked(3, 4, 4), Blocks.GRAVEL, "stack order is preserved")
	assert_eq(chunk.get_block_unchecked(3, 7, 4), Blocks.AIR, "old sand cell is cleared")
	assert_eq(chunk.get_block_unchecked(3, 8, 4), Blocks.AIR, "old gravel cell is cleared")
	assert_eq(_first_unsupported_gravity(chunk), Vector3i(-1, -1, -1))
	assert_eq(chunk.max_y, 4, "max_y is recomputed from the settled result")


func test_generated_gravity_already_supported_is_byte_stable() -> void:
	var chunk := Chunk.new()
	chunk.set_block_unchecked(5, 10, 6, Blocks.STONE)
	chunk.set_block_unchecked(5, 11, 6, Blocks.SAND)
	chunk.set_block_unchecked(5, 12, 6, Blocks.GRAVEL)
	var before: PackedByteArray = chunk.blocks.duplicate()
	var revision_before: int = chunk.lighting_revision

	assert_eq(Worldgen._settle_generated_gravity_blocks(chunk), 0)
	assert_eq(chunk.blocks, before, "supported columns are not rewritten")
	assert_eq(chunk.lighting_revision, revision_before, "no-op settlement does not dirty lighting")


func test_generated_gravity_without_any_support_falls_out_of_world() -> void:
	var chunk := Chunk.new()
	chunk.set_block_unchecked(1, 20, 1, Blocks.SAND)

	assert_eq(Worldgen._settle_generated_gravity_blocks(chunk), 1)
	assert_eq(chunk.get_block_unchecked(1, 20, 1), Blocks.AIR)
	assert_eq(chunk.max_y, 0)


func test_generated_gravity_settlement_has_bounded_linear_cost() -> void:
	var chunk := Chunk.new()
	# Representative dense terrain with a few gravity cells; repeat the no-op
	# steady result so the timing measures the complete 32,768-cell scan, not
	# setup/allocation outside the pass.
	for y in range(64):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				chunk.set_block_unchecked(x, y, z, Blocks.STONE)
	for x in range(0, Chunk.SIZE_X, 4):
		chunk.set_block_unchecked(x, 64, 8, Blocks.SAND)
	Worldgen._settle_generated_gravity_blocks(chunk)
	const RUNS := 20
	var started_usec: int = Time.get_ticks_usec()
	for _i in range(RUNS):
		Worldgen._settle_generated_gravity_blocks(chunk)
	var average_ms: float = float(Time.get_ticks_usec() - started_usec) / float(RUNS) / 1000.0
	print("generated gravity settlement average: %.3f ms/chunk" % average_ms)
	var native_active: bool = (
		Worldgen._native_worldgen != null
		and Worldgen._native_worldgen.has_method("settle_generated_gravity")
	)
	var budget_ms: float = 1.0 if native_active else 10.0
	assert_lt(
		average_ms,
		budget_ms,
		"fresh-generation-only linear pass stays within its native/fallback CPU budget"
	)


func test_native_and_gdscript_generated_gravity_settlement_are_byte_equal() -> void:
	if not ClassDB.class_exists("WorldgenNative"):
		pending("WorldgenNative extension is unavailable")
		return
	var source := Chunk.new()
	source.set_block_unchecked(2, 1, 2, Blocks.STONE)
	source.set_block_unchecked(2, 2, 2, Blocks.WATER_STILL)
	source.set_block_unchecked(2, 6, 2, Blocks.SAND)
	source.set_block_unchecked(2, 7, 2, Blocks.GRAVEL)
	source.block_meta[Chunk.index(2, 7, 2)] = 5
	var gd_chunk := Chunk.new()
	gd_chunk.blocks = source.blocks.duplicate()
	gd_chunk.block_meta = source.block_meta.duplicate()
	var native_chunk := Chunk.new()
	native_chunk.blocks = source.blocks.duplicate()
	native_chunk.block_meta = source.block_meta.duplicate()
	var saved_native: RefCounted = Worldgen._native_worldgen

	Worldgen._native_worldgen = null
	var gd_moved: int = Worldgen._settle_generated_gravity_blocks(gd_chunk)
	Worldgen._native_worldgen = saved_native
	if Worldgen._native_worldgen == null:
		Worldgen.enable_native()
	var native_moved: int = Worldgen._settle_generated_gravity_blocks(native_chunk)
	Worldgen._native_worldgen = saved_native

	assert_eq(native_moved, gd_moved)
	assert_eq(native_chunk.blocks, gd_chunk.blocks)
	assert_eq(native_chunk.block_meta, gd_chunk.block_meta, "source metadata moves with its block")
	assert_eq(native_chunk.max_y, gd_chunk.max_y)
