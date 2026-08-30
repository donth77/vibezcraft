extends GutTest

const _CHUNK_SCENE := preload("res://scenes/world/chunk.tscn")


func test_new_chunk_is_all_air() -> void:
	var chunk := Chunk.new()
	assert_eq(chunk.get_block(0, 0, 0), Blocks.AIR)
	assert_eq(chunk.get_block(15, 127, 15), Blocks.AIR)


func test_set_get_roundtrip() -> void:
	var chunk := Chunk.new()
	chunk.set_block(5, 64, 7, Blocks.STONE)
	assert_eq(chunk.get_block(5, 64, 7), Blocks.STONE)


func test_extreme_corners() -> void:
	var chunk := Chunk.new()
	chunk.set_block(0, 0, 0, Blocks.BEDROCK)
	chunk.set_block(15, 127, 15, Blocks.BEDROCK)
	assert_eq(chunk.get_block(0, 0, 0), Blocks.BEDROCK)
	assert_eq(chunk.get_block(15, 127, 15), Blocks.BEDROCK)


func test_out_of_bounds_get_returns_air() -> void:
	var chunk := Chunk.new()
	assert_eq(chunk.get_block(-1, 0, 0), Blocks.AIR)
	assert_eq(chunk.get_block(16, 0, 0), Blocks.AIR)
	assert_eq(chunk.get_block(0, 128, 0), Blocks.AIR)
	assert_eq(chunk.get_block(0, 0, -1), Blocks.AIR)


func test_out_of_bounds_set_is_silently_ignored() -> void:
	var chunk := Chunk.new()
	chunk.set_block(-1, 0, 0, Blocks.STONE)
	chunk.set_block(20, 0, 0, Blocks.STONE)
	# In-bounds neighbor is unaffected
	assert_eq(chunk.get_block(0, 0, 0), Blocks.AIR)


func test_set_marks_dirty() -> void:
	var chunk := Chunk.new()
	chunk.dirty = false
	chunk.set_block(0, 0, 0, Blocks.STONE)
	assert_true(chunk.dirty)


func test_remesh_keeps_old_collision_live_until_replacement_is_cooked() -> void:
	var original := Chunk.new()
	original.set_block(1, 10, 1, Blocks.STONE)
	var node: Node3D = _CHUNK_SCENE.instantiate()
	node.chunk_data = original
	add_child_autofree(node)
	assert_true(node.has_live_collision(), "initial chunk has cooked collision")
	var collision_shape: CollisionShape3D = node.get("_collision_shape")
	var old_shape: Shape3D = collision_shape.shape

	var replacement := Chunk.new()
	replacement.set_block(1, 10, 1, Blocks.STONE)
	replacement.set_block(2, 10, 1, Blocks.STONE)
	node._apply_mesh_data(Mesher.mesh_chunk_fast(replacement))
	assert_same(
		collision_shape.shape,
		old_shape,
		"mesh apply preserves the old live shape during deferred physics cooking"
	)
	assert_true(node._cook_pending_collision(), "replacement collision was pending")
	assert_not_same(collision_shape.shape, old_shape, "cook atomically installs a new shape")
	assert_true(node.has_live_collision(), "replacement never leaves collision null")


func test_redstone_visual_remesh_reuses_unchanged_collision_shapes() -> void:
	var original := Chunk.new()
	original.set_block(1, 10, 1, Blocks.STONE)
	original.set_block(1, 11, 1, Blocks.REDSTONE_REPEATER_OFF)
	original.set_block(3, 10, 1, Blocks.STONE)
	original.set_block(3, 11, 1, Blocks.REDSTONE_WIRE)
	var node: Node3D = _CHUNK_SCENE.instantiate()
	node.chunk_data = original
	add_child_autofree(node)
	var solid_shape: Shape3D = node._collision_shape.shape
	var selection_shape: Shape3D = node._plants_shape.shape
	assert_not_null(solid_shape, "support + repeater collision is live")
	assert_not_null(selection_shape, "wire selection collision is live")

	var powered := Chunk.new()
	powered.set_block(1, 10, 1, Blocks.STONE)
	powered.set_block(1, 11, 1, Blocks.REDSTONE_REPEATER_ON)
	powered.set_block(3, 10, 1, Blocks.STONE)
	powered.set_block(3, 11, 1, Blocks.REDSTONE_WIRE)
	powered.set_block_meta(3, 11, 1, 15)
	node._apply_mesh_data(Mesher.mesh_chunk_fast(powered))

	assert_false(node._collision_cook_pending, "unchanged solid soup does not queue a BVH cook")
	assert_same(node._collision_shape.shape, solid_shape, "solid collision shape is reused")
	assert_same(node._plants_shape.shape, selection_shape, "selection collision shape is reused")


# --- Lighting (slice 1: storage + accessors only) ---


func test_default_sky_light_is_full_daylight() -> void:
	# Until the slice 3 fill pass lands, every cell defaults to 15 so the
	# world looks identical to the pre-lighting state. Vanilla's
	# EnumSkyBlock.SKY uses the same "default = 15" rule.
	var chunk := Chunk.new()
	assert_eq(chunk.get_sky_light(0, 0, 0), 15)
	assert_eq(chunk.get_sky_light(8, 64, 8), 15)
	assert_eq(chunk.get_sky_light(15, 127, 15), 15)


func test_default_block_light_is_zero() -> void:
	var chunk := Chunk.new()
	assert_eq(chunk.get_block_light(0, 0, 0), 0)
	assert_eq(chunk.get_block_light(15, 127, 15), 0)


func test_sky_light_set_get_roundtrip_with_clamping() -> void:
	var chunk := Chunk.new()
	chunk.set_sky_light(2, 30, 4, 7)
	assert_eq(chunk.get_sky_light(2, 30, 4), 7)
	# Clamped to 0..15 — vanilla NibbleArray would silently truncate.
	chunk.set_sky_light(2, 30, 4, 99)
	assert_eq(chunk.get_sky_light(2, 30, 4), 15)
	chunk.set_sky_light(2, 30, 4, -3)
	assert_eq(chunk.get_sky_light(2, 30, 4), 0)


func test_block_light_set_get_roundtrip() -> void:
	var chunk := Chunk.new()
	chunk.set_block_light(1, 1, 1, 14)
	assert_eq(chunk.get_block_light(1, 1, 1), 14)


func test_oob_sky_light_uses_horizontal_and_vertical_defaults() -> void:
	# Horizontal unloaded neighbors read as daylight. Vertical bounds are
	# asymmetric: below-world is dark and above-world is open sky.
	var chunk := Chunk.new()
	assert_eq(chunk.get_sky_light(-1, 0, 0), 15)
	assert_eq(chunk.get_sky_light(16, 0, 0), 15)
	assert_eq(chunk.get_sky_light(0, -1, 0), 0)
	assert_eq(chunk.get_sky_light(0, 128, 0), 15)


func test_oob_block_light_reads_as_zero() -> void:
	var chunk := Chunk.new()
	assert_eq(chunk.get_block_light(-1, 0, 0), 0)
	assert_eq(chunk.get_block_light(0, -1, 0), 0)


func test_effective_light_takes_max_of_sky_and_block() -> void:
	var chunk := Chunk.new()
	# Default state: sky=15, block=0 → effective=15 at noon.
	assert_eq(chunk.effective_light(8, 64, 8, 1.0), 15)
	# Block-light dominates when sky is dimmed (e.g. midnight = 0.0).
	chunk.set_block_light(8, 64, 8, 12)
	assert_eq(chunk.effective_light(8, 64, 8, 0.0), 12)
	# Half-day sky-factor: sky 15 * 0.5 = 7.5 → 8 (round); block 12 wins.
	assert_eq(chunk.effective_light(8, 64, 8, 0.5), 12)
	# When sky-factor is high enough to beat block-light, sky wins.
	chunk.set_block_light(8, 64, 8, 5)
	assert_eq(chunk.effective_light(8, 64, 8, 1.0), 15)


# --- Block metadata (Flow #1) ---


func test_default_block_meta_is_zero() -> void:
	var chunk := Chunk.new()
	assert_eq(chunk.get_block_meta(0, 0, 0), 0)
	assert_eq(chunk.get_block_meta(8, 64, 8), 0)
	assert_eq(chunk.get_block_meta(15, 127, 15), 0)


func test_block_meta_set_get_roundtrip_with_clamping() -> void:
	var chunk := Chunk.new()
	chunk.set_block_meta(4, 64, 4, 7)
	assert_eq(chunk.get_block_meta(4, 64, 4), 7)
	# Values above 15 must be clamped — metadata is a nibble.
	chunk.set_block_meta(4, 64, 4, 255)
	assert_eq(chunk.get_block_meta(4, 64, 4), 15)
	# Negative values clamp to 0.
	chunk.set_block_meta(4, 64, 4, -3)
	assert_eq(chunk.get_block_meta(4, 64, 4), 0)


func test_oob_block_meta_reads_as_zero() -> void:
	var chunk := Chunk.new()
	assert_eq(chunk.get_block_meta(-1, 0, 0), 0)
	assert_eq(chunk.get_block_meta(0, -1, 0), 0)
	assert_eq(chunk.get_block_meta(16, 0, 0), 0)
	assert_eq(chunk.get_block_meta(0, 128, 0), 0)


func test_set_block_resets_meta_to_zero() -> void:
	# Vanilla World.setBlockWithNotify resets metadata on block change —
	# the new block starts in its default state. Guards against stale
	# flow levels lingering when a player places solid over flowing water.
	var chunk := Chunk.new()
	chunk.set_block_with_meta(4, 64, 4, Blocks.WATER_FLOWING, 5)
	assert_eq(chunk.get_block_meta(4, 64, 4), 5)
	chunk.set_block(4, 64, 4, Blocks.STONE)
	assert_eq(chunk.get_block_meta(4, 64, 4), 0, "meta must reset when block changes")


func test_set_block_with_meta_writes_both() -> void:
	var chunk := Chunk.new()
	chunk.set_block_with_meta(4, 64, 4, Blocks.WATER_FLOWING, 3)
	assert_eq(chunk.get_block(4, 64, 4), Blocks.WATER_FLOWING)
	assert_eq(chunk.get_block_meta(4, 64, 4), 3)
	# has_water_cells flag must also flip — flow uses mesh_chunk's water path.
	assert_true(chunk.has_water_cells, "has_water_cells sticky flag set for WATER_FLOWING")
