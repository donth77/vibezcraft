extends GutTest


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


func test_oob_sky_light_reads_as_full_daylight() -> void:
	# Mesher's per-face neighbor sample at chunk borders depends on this —
	# returning 0 for OOB would erroneously darken outward-facing faces.
	var chunk := Chunk.new()
	assert_eq(chunk.get_sky_light(-1, 0, 0), 15)
	assert_eq(chunk.get_sky_light(16, 0, 0), 15)
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
