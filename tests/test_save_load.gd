# gdlint: disable=max-public-methods
extends GutTest

# SaveLoad disk persistence (step 7.1 of the save/load plan). Round-trip,
# region isolation, atomic-write crash recovery.
#
# Each test uses its own world name + tears it down in after_each so disk
# state from one test never leaks into another. `_test_world_name()` builds
# a unique name from the calling test method, which keeps parallel test
# runs safe and makes leftover dirs easy to spot if cleanup fails.

var _current_world: String = ""


func before_each() -> void:
	_current_world = ""


func after_each() -> void:
	if _current_world != "":
		SaveLoad.delete_world(_current_world)
	SaveLoad.clear_cache()


# Build a unique world name per test method so disk state can't leak between
# tests. We can't introspect the running test name reliably from GUT, so each
# test picks its own slug.
func _world(slug: String) -> String:
	_current_world = "test_save_load_" + slug
	# Guarantee a clean slate even if a previous run crashed mid-test.
	SaveLoad.delete_world(_current_world)
	SaveLoad.clear_cache()
	return _current_world


# Build a minimal entry dict matching chunk_manager._persist_chunk's shape.
# Tests only need the bytes / lights / max_y to round-trip; pending_ticks
# is exercised via a tagged test below.
func _make_entry(blocks: PackedByteArray, max_y: int = 70) -> Dictionary:
	var empty_32k := PackedByteArray()
	empty_32k.resize(Chunk.TOTAL_BLOCKS)
	var empty_hm := PackedByteArray()
	empty_hm.resize(Chunk.SIZE_X * Chunk.SIZE_Z)
	return {
		"bytes": blocks.compress(FileAccess.COMPRESSION_FASTLZ),
		"block_meta": empty_32k.compress(FileAccess.COMPRESSION_FASTLZ),
		"sky_light": empty_32k.compress(FileAccess.COMPRESSION_FASTLZ),
		"block_light": empty_32k.compress(FileAccess.COMPRESSION_FASTLZ),
		"height_map": empty_hm.compress(FileAccess.COMPRESSION_FASTLZ),
		"max_y": max_y,
		"pending_ticks": [],
	}


# --- Region math ---


func test_chunk_to_region_positive() -> void:
	assert_eq(SaveLoad.chunk_to_region(Vector2i(0, 0)), Vector2i(0, 0))
	assert_eq(SaveLoad.chunk_to_region(Vector2i(31, 31)), Vector2i(0, 0))
	assert_eq(SaveLoad.chunk_to_region(Vector2i(32, 32)), Vector2i(1, 1))


func test_chunk_to_region_negative() -> void:
	# Arithmetic right shift: -1 >> 5 == -1, not 0. Region -1 owns chunks
	# [-32..-1]; without this property, chunk -1 would land in region 0
	# and overwrite a real chunk slot.
	assert_eq(SaveLoad.chunk_to_region(Vector2i(-1, -1)), Vector2i(-1, -1))
	assert_eq(SaveLoad.chunk_to_region(Vector2i(-32, -32)), Vector2i(-1, -1))
	assert_eq(SaveLoad.chunk_to_region(Vector2i(-33, -33)), Vector2i(-2, -2))


# --- Round-trip ---


func test_save_then_load_returns_equivalent_entry() -> void:
	var world := _world("round_trip")
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	# Deterministic non-zero payload — picks a sparse stride to exercise
	# compress + decode without hammering the whole array.
	for i in range(0, Chunk.TOTAL_BLOCKS, 37):
		blocks[i] = (i % 250) + 1
	var entry: Dictionary = _make_entry(blocks, 99)
	assert_true(SaveLoad.save_chunk(Vector2i(5, 7), entry, world))
	# Drop the in-memory cache so the load actually reads from disk.
	SaveLoad.clear_cache()
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(5, 7), world)
	assert_false(loaded.is_empty(), "expected non-empty load")
	assert_eq(int(loaded.max_y), 99)
	var restored: PackedByteArray = (loaded.bytes as PackedByteArray).decompress(
		Chunk.TOTAL_BLOCKS, FileAccess.COMPRESSION_FASTLZ
	)
	assert_eq(restored, blocks, "blocks must survive round-trip byte-for-byte")


func test_load_missing_chunk_returns_empty() -> void:
	var world := _world("missing")
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), world)
	assert_true(loaded.is_empty(), "unsaved chunk reads as empty")


func test_save_and_load_preserves_pending_ticks() -> void:
	var world := _world("ticks")
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	var entry: Dictionary = _make_entry(blocks)
	# Mirror TickScheduler.take_for_chunk's output shape.
	entry["pending_ticks"] = [
		{"pos": Vector3i(1, 2, 3), "block_id": Blocks.WATER_FLOWING, "delay": 5},
		{"pos": Vector3i(4, 5, 6), "block_id": Blocks.LAVA_FLOWING, "delay": 12},
	]
	SaveLoad.save_chunk(Vector2i(0, 0), entry, world)
	SaveLoad.clear_cache()
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), world)
	var ticks: Array = loaded["pending_ticks"]
	assert_eq(ticks.size(), 2)
	assert_eq(ticks[0]["pos"], Vector3i(1, 2, 3))
	assert_eq(int(ticks[0]["block_id"]), Blocks.WATER_FLOWING)
	assert_eq(int(ticks[0]["delay"]), 5)
	assert_eq(int(ticks[1]["delay"]), 12)


# --- Region isolation ---


func test_writing_one_chunk_does_not_clobber_neighbour_in_same_region() -> void:
	var world := _world("isolation_same_region")
	var blocks_a := PackedByteArray()
	blocks_a.resize(Chunk.TOTAL_BLOCKS)
	blocks_a.fill(Blocks.STONE)
	var blocks_b := PackedByteArray()
	blocks_b.resize(Chunk.TOTAL_BLOCKS)
	blocks_b.fill(Blocks.DIRT)
	# Both chunks live in region (0,0) since 5 >> 5 == 0 and 10 >> 5 == 0.
	SaveLoad.save_chunk(Vector2i(5, 5), _make_entry(blocks_a), world)
	SaveLoad.save_chunk(Vector2i(10, 10), _make_entry(blocks_b), world)
	SaveLoad.clear_cache()
	var load_a: Dictionary = SaveLoad.load_chunk(Vector2i(5, 5), world)
	var load_b: Dictionary = SaveLoad.load_chunk(Vector2i(10, 10), world)
	var restored_a: PackedByteArray = (load_a.bytes as PackedByteArray).decompress(
		Chunk.TOTAL_BLOCKS, FileAccess.COMPRESSION_FASTLZ
	)
	var restored_b: PackedByteArray = (load_b.bytes as PackedByteArray).decompress(
		Chunk.TOTAL_BLOCKS, FileAccess.COMPRESSION_FASTLZ
	)
	assert_eq(restored_a[0], Blocks.STONE, "chunk A first byte must remain STONE")
	assert_eq(restored_b[0], Blocks.DIRT, "chunk B first byte must remain DIRT")


func test_chunks_in_different_regions_use_different_files() -> void:
	var world := _world("isolation_cross_region")
	var blocks_a := PackedByteArray()
	blocks_a.resize(Chunk.TOTAL_BLOCKS)
	blocks_a.fill(Blocks.STONE)
	var blocks_b := PackedByteArray()
	blocks_b.resize(Chunk.TOTAL_BLOCKS)
	blocks_b.fill(Blocks.GRASS)
	# Chunk (5,5) in region (0,0); chunk (35,35) in region (1,1).
	SaveLoad.save_chunk(Vector2i(5, 5), _make_entry(blocks_a), world)
	SaveLoad.save_chunk(Vector2i(35, 35), _make_entry(blocks_b), world)
	# Both region files must exist independently.
	assert_true(
		FileAccess.file_exists(SaveLoad.region_path(0, 0, world)), "region (0,0) file must exist"
	)
	assert_true(
		FileAccess.file_exists(SaveLoad.region_path(1, 1, world)), "region (1,1) file must exist"
	)
	SaveLoad.clear_cache()
	assert_false(SaveLoad.load_chunk(Vector2i(5, 5), world).is_empty())
	assert_false(SaveLoad.load_chunk(Vector2i(35, 35), world).is_empty())


# --- Crash recovery ---


func test_recovery_recovers_old_when_main_missing() -> void:
	var world := _world("recovery_old")
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	blocks.fill(Blocks.GRAVEL)
	SaveLoad.save_chunk(Vector2i(0, 0), _make_entry(blocks), world)
	# Simulate atomic_write crashing between "rename main → .old" and
	# "rename .new → main": main missing, .old exists. The next load should
	# rename .old → main and read normally.
	var path: String = SaveLoad.region_path(0, 0, world)
	DirAccess.rename_absolute(path, path + ".old")
	assert_false(FileAccess.file_exists(path))
	assert_true(FileAccess.file_exists(path + ".old"))
	SaveLoad.clear_cache()
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), world)
	assert_false(loaded.is_empty(), ".old must recover into main on next read")
	assert_true(FileAccess.file_exists(path), "recovery renamed .old back to main")


func test_recovery_discards_new_when_main_missing() -> void:
	var world := _world("recovery_new")
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	blocks.fill(Blocks.SAND)
	SaveLoad.save_chunk(Vector2i(0, 0), _make_entry(blocks), world)
	# Simulate atomic_write crashing during the initial temp write — main
	# missing, .new exists but is untrusted (could be partial). Recovery
	# discards .new and falls through to "no saved chunk".
	var path: String = SaveLoad.region_path(0, 0, world)
	DirAccess.rename_absolute(path, path + ".new")
	assert_false(FileAccess.file_exists(path))
	assert_true(FileAccess.file_exists(path + ".new"))
	SaveLoad.clear_cache()
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), world)
	assert_true(loaded.is_empty(), ".new without main must be discarded as untrusted")
	assert_false(FileAccess.file_exists(path + ".new"), "discarded .new should be removed")


# --- Cache behaviour ---

# --- Multi-world default routing (audit fix) ---

# Regression: previously, omitting world_name baked in the const "World1"
# at compile time. Picking World3 in the Select-World UI set
# Game.active_world but every save still routed to World1's region files.
# These tests pin the active-world-aware default.


func test_default_world_name_routes_to_active_world() -> void:
	var saved_active: String = Game.active_world
	Game.active_world = "test_save_load_active_routing"
	SaveLoad.delete_world(Game.active_world)
	SaveLoad.clear_cache()
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	blocks.fill(Blocks.STONE)
	# Save with NO world_name — should land in the active world, not World1.
	SaveLoad.save_chunk(Vector2i(0, 0), _make_entry(blocks))
	assert_true(
		FileAccess.file_exists(SaveLoad.region_path(0, 0, "test_save_load_active_routing")),
		"region file written to active world"
	)
	assert_false(
		SaveLoad.load_chunk(Vector2i(0, 0), "World1").has("bytes"),
		"World1 untouched when active world differs"
	)
	# Cleanup
	SaveLoad.delete_world(Game.active_world)
	Game.active_world = saved_active


func test_explicit_world_name_overrides_active() -> void:
	var saved_active: String = Game.active_world
	Game.active_world = "test_save_load_override_a"
	SaveLoad.delete_world("test_save_load_override_a")
	SaveLoad.delete_world("test_save_load_override_b")
	SaveLoad.clear_cache()
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	# Explicit world_name beats Game.active_world.
	SaveLoad.save_chunk(Vector2i(0, 0), _make_entry(blocks), "test_save_load_override_b")
	assert_true(FileAccess.file_exists(SaveLoad.region_path(0, 0, "test_save_load_override_b")))
	assert_false(FileAccess.file_exists(SaveLoad.region_path(0, 0, "test_save_load_override_a")))
	SaveLoad.delete_world("test_save_load_override_a")
	SaveLoad.delete_world("test_save_load_override_b")
	Game.active_world = saved_active


# --- Legacy world migration (step 7.5) ---


func test_migrate_legacy_world_renames_old_dir_to_world1() -> void:
	# Set up a fresh state by deleting whatever Game._ready may have done
	# on the running session, then plant a fake legacy dir.
	SaveLoad.delete_world("world")
	SaveLoad.delete_world("World1")
	DirAccess.make_dir_recursive_absolute("user://world/region")
	var f: FileAccess = FileAccess.open("user://world/marker.txt", FileAccess.WRITE)
	f.store_string("hello from pre-7.5 layout")
	f.close()
	assert_true(SaveLoad.migrate_legacy_world(), "migration should report success")
	assert_false(DirAccess.dir_exists_absolute("user://world"), "legacy dir gone after migration")
	assert_true(
		FileAccess.file_exists("user://World1/marker.txt"), "marker file preserved in new location"
	)
	# Cleanup
	SaveLoad.delete_world("World1")


func test_migrate_legacy_world_noop_when_target_exists() -> void:
	SaveLoad.delete_world("world")
	SaveLoad.delete_world("World1")
	# Both dirs present → don't touch either.
	DirAccess.make_dir_recursive_absolute("user://world")
	DirAccess.make_dir_recursive_absolute("user://World1")
	assert_false(SaveLoad.migrate_legacy_world(), "migration skipped when target exists")
	assert_true(DirAccess.dir_exists_absolute("user://world"))
	assert_true(DirAccess.dir_exists_absolute("user://World1"))
	SaveLoad.delete_world("world")
	SaveLoad.delete_world("World1")


func test_migrate_legacy_world_noop_when_neither_exists() -> void:
	SaveLoad.delete_world("world")
	SaveLoad.delete_world("World1")
	assert_false(SaveLoad.migrate_legacy_world(), "migration skipped when nothing to migrate")


func test_load_after_save_hits_cache_without_disk() -> void:
	var world := _world("cache")
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	SaveLoad.save_chunk(Vector2i(0, 0), _make_entry(blocks), world)
	# Delete the file but keep the cache. load_chunk should still succeed
	# because the in-memory region dict is the authoritative copy until cleared.
	var path: String = SaveLoad.region_path(0, 0, world)
	DirAccess.remove_absolute(path)
	# .new + .old also gone after save completes — atomic_write cleans up.
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), world)
	assert_false(loaded.is_empty(), "in-memory cache should serve loads after file deletion")


# --- Tile entities (step 7.2) ---
#
# These test the ChestStorage / FurnaceManager serialize_chunk +
# restore_chunk round-trip in isolation. The full save/load loop
# (persist → write region → read region → restore) is implicitly covered
# by exercising both halves: TE bytes survive var_to_bytes via the same
# region-file path the rest of the entry uses.


func test_chest_serialize_round_trip_within_chunk() -> void:
	# Chest at chunk (2, 3) local (5, 64, 7) = world (37, 64, 55).
	var coord := Vector2i(2, 3)
	var wp := Vector3i(2 * Chunk.SIZE_X + 5, 64, 3 * Chunk.SIZE_Z + 7)
	var slots: Array = ChestStorage.get_or_create(wp)
	slots[0] = ItemStack.new(Blocks.STONE, 32)
	slots[5] = ItemStack.new(Blocks.DIRT, 17)
	var serialized: Dictionary = ChestStorage.serialize_chunk(coord)
	assert_eq(serialized.size(), 1, "exactly one chest in chunk (2,3)")
	var local_key := Vector3i(5, 64, 7)
	assert_true(serialized.has(local_key))
	ChestStorage.forget_chunk(coord)
	assert_false(ChestStorage.has_chest(wp), "forget_chunk clears the singleton")
	ChestStorage.restore_chunk(coord, serialized)
	var restored: Array = ChestStorage.get_or_create(wp)
	assert_eq((restored[0] as ItemStack).item_id, Blocks.STONE)
	assert_eq((restored[0] as ItemStack).count, 32)
	assert_eq((restored[5] as ItemStack).item_id, Blocks.DIRT)
	assert_eq((restored[5] as ItemStack).count, 17)
	# Teardown so other tests don't see this chest.
	ChestStorage.forget_chunk(coord)


func test_chest_serialize_isolates_across_chunks() -> void:
	var coord_a := Vector2i(0, 0)
	var coord_b := Vector2i(1, 0)
	var wp_a := Vector3i(5, 64, 5)
	var wp_b := Vector3i(Chunk.SIZE_X + 5, 64, 5)  # second chunk in +X
	# Clear any leftover state from sibling test files that touched these
	# chunks (e.g. test_chest_storage.gd uses small world coords too).
	ChestStorage.forget_chunk(coord_a)
	ChestStorage.forget_chunk(coord_b)
	ChestStorage.get_or_create(wp_a)[0] = ItemStack.new(Blocks.STONE, 1)
	ChestStorage.get_or_create(wp_b)[0] = ItemStack.new(Blocks.DIRT, 1)
	var ser_a: Dictionary = ChestStorage.serialize_chunk(coord_a)
	var ser_b: Dictionary = ChestStorage.serialize_chunk(coord_b)
	assert_eq(ser_a.size(), 1, "chunk A picks up exactly its chest")
	assert_eq(ser_b.size(), 1, "chunk B picks up exactly its chest")
	# Local coords are both (5, 64, 5) even though world coords differ.
	assert_true(ser_a.has(Vector3i(5, 64, 5)))
	assert_true(ser_b.has(Vector3i(5, 64, 5)))
	# forget_chunk on A doesn't drop B.
	ChestStorage.forget_chunk(coord_a)
	assert_false(ChestStorage.has_chest(wp_a))
	assert_true(ChestStorage.has_chest(wp_b))
	ChestStorage.forget_chunk(coord_b)


func test_furnace_serialize_preserves_burn_progress() -> void:
	var coord := Vector2i(4, 5)
	var wp := Vector3i(4 * Chunk.SIZE_X + 8, 64, 5 * Chunk.SIZE_Z + 8)
	var state: Dictionary = FurnaceManager.get_or_create(wp)
	state.input = ItemStack.new(Blocks.IRON_ORE, 3)
	state.fuel = ItemStack.new(Items.COAL, 4)
	state.output = ItemStack.new(Items.IRON_INGOT, 1)
	state.cook_time = 87
	state.burn_time = 64
	state.burn_total = 128
	var serialized: Dictionary = FurnaceManager.serialize_chunk(coord)
	FurnaceManager.forget_chunk(coord)
	assert_false(FurnaceManager.has_furnace(wp))
	FurnaceManager.restore_chunk(coord, serialized)
	var restored: Dictionary = FurnaceManager.get_or_create(wp)
	assert_eq((restored.input as ItemStack).item_id, Blocks.IRON_ORE)
	assert_eq((restored.input as ItemStack).count, 3)
	assert_eq((restored.fuel as ItemStack).item_id, Items.COAL)
	assert_eq((restored.fuel as ItemStack).count, 4)
	assert_eq((restored.output as ItemStack).item_id, Items.IRON_INGOT)
	assert_eq(int(restored.cook_time), 87)
	assert_eq(int(restored.burn_time), 64)
	assert_eq(int(restored.burn_total), 128)
	FurnaceManager.forget_chunk(coord)


# End-to-end: tile entities make it through the full SaveLoad region file
# round-trip. Catches issues like Vector3i Dictionary keys or nested
# Arrays getting mangled by var_to_bytes.
func test_tile_entities_survive_region_file_round_trip() -> void:
	var world := _world("te_round_trip")
	var coord := Vector2i(0, 0)
	var wp := Vector3i(3, 70, 9)
	ChestStorage.forget_chunk(coord)  # isolate from sibling tests
	ChestStorage.get_or_create(wp)[0] = ItemStack.new(Blocks.DIAMOND_ORE, 7)
	var chest_data: Dictionary = ChestStorage.serialize_chunk(coord)
	ChestStorage.forget_chunk(coord)
	# Build the entry shape ChunkManager._persist_chunk produces.
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	var entry: Dictionary = _make_entry(blocks)
	var tile_entities: Dictionary = {}
	for local_pos: Vector3i in chest_data:
		tile_entities[local_pos] = {"type": "chest", "items": chest_data[local_pos]}
	entry["tile_entities"] = tile_entities
	# Round-trip via disk.
	SaveLoad.save_chunk(coord, entry, world)
	SaveLoad.clear_cache()
	var loaded: Dictionary = SaveLoad.load_chunk(coord, world)
	var te_back: Dictionary = loaded.get("tile_entities", {})
	assert_eq(te_back.size(), 1)
	# Restore back into ChestStorage via the same chunk_manager path.
	var chests_back: Dictionary = {}
	for local_pos: Vector3i in te_back:
		chests_back[local_pos] = (te_back[local_pos] as Dictionary).get("items", [])
	ChestStorage.restore_chunk(coord, chests_back)
	var restored: Array = ChestStorage.get_or_create(wp)
	assert_eq((restored[0] as ItemStack).item_id, Blocks.DIAMOND_ORE)
	assert_eq((restored[0] as ItemStack).count, 7)
	ChestStorage.forget_chunk(coord)
