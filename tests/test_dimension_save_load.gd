# gdlint: disable=max-public-methods
extends GutTest

# Dimension-scoped persistence (docs/nether-alpha-1.2.6-implementation-plan.md
# §3.3, Batch 1).
#
# Two guarantees, and the second is the one that bites:
#
#   1. Dimension -1 gets its own region files and entity store under
#      DIM-1/, while dimension 0 keeps writing exactly where it always
#      has. Existing worlds must not be relocated or rewritten.
#   2. The in-memory region CACHE is keyed by dimension too. Paths alone
#      are not enough — chunk (0,0) of the Nether asking for a region
#      would otherwise be handed the Overworld's cached dictionary and
#      then overwrite it on the next flush, silently destroying terrain.
#
# Every test uses a throwaway world name. SaveLoad.delete_world is a hard
# recursive delete with no trash, and the suite runs against the real
# user:// directory.

const _WORLD := "test_dimension_save_load"

var _dimension_was: int
var _active_world_was: String


func before_each() -> void:
	_dimension_was = DimensionContext.active()
	# Belt and braces: every call below names _WORLD explicitly, but
	# redirecting the active world too means a future test that forgets
	# the argument still cannot touch a real save slot.
	_active_world_was = Game.active_world
	Game.active_world = _WORLD
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	SaveLoad.clear_cache()
	SaveLoad.delete_world(_WORLD)


func after_each() -> void:
	SaveLoad.delete_world(_WORLD)
	SaveLoad.clear_cache()
	DimensionContext.set_active(_dimension_was)
	Game.active_world = _active_world_was


func _entry(fill_id: int) -> Dictionary:
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	blocks.fill(fill_id)
	var empty := PackedByteArray()
	empty.resize(Chunk.TOTAL_BLOCKS)
	var hm := PackedByteArray()
	hm.resize(Chunk.SIZE_X * Chunk.SIZE_Z)
	return {
		"bytes": blocks.compress(FileAccess.COMPRESSION_FASTLZ),
		"block_meta": empty.compress(FileAccess.COMPRESSION_FASTLZ),
		"sky_light": empty.compress(FileAccess.COMPRESSION_FASTLZ),
		"block_light": empty.compress(FileAccess.COMPRESSION_FASTLZ),
		"height_map": hm.compress(FileAccess.COMPRESSION_FASTLZ),
		"max_y": 70,
		"pending_ticks": [],
	}


func _first_block(entry: Dictionary) -> int:
	var raw: PackedByteArray = entry["bytes"] as PackedByteArray
	return raw.decompress(Chunk.TOTAL_BLOCKS)[0]


# --- Path layout ---


func test_overworld_paths_are_unchanged_by_the_nether() -> void:
	# The whole point of the DIM-1 sub-directory: nothing about
	# dimension 0's layout moves, so worlds saved before the Nether
	# existed keep loading from where they are.
	var world_dir: String = SaveLoad.world_dir(_WORLD)
	assert_eq(
		SaveLoad.dimension_dir(_WORLD, DimensionContext.OVERWORLD),
		world_dir,
		"dimension 0 lives at the world root"
	)
	assert_eq(
		SaveLoad.region_dir(_WORLD, DimensionContext.OVERWORLD),
		"%s/region" % world_dir,
		"Overworld region dir unchanged"
	)
	assert_eq(
		EntitySave.entities_path(_WORLD, DimensionContext.OVERWORLD),
		"%s/entities.bin" % world_dir,
		"Overworld entities.bin unchanged"
	)


func test_nether_paths_nest_under_dim_minus_one() -> void:
	var world_dir: String = SaveLoad.world_dir(_WORLD)
	assert_eq(
		SaveLoad.dimension_dir(_WORLD, DimensionContext.NETHER),
		"%s/DIM-1" % world_dir,
		"Nether gets its own namespace"
	)
	assert_eq(
		SaveLoad.region_dir(_WORLD, DimensionContext.NETHER),
		"%s/DIM-1/region" % world_dir,
		"Nether regions are separate files"
	)
	assert_eq(
		EntitySave.entities_path(_WORLD, DimensionContext.NETHER),
		"%s/DIM-1/entities.bin" % world_dir,
		"Nether entities are a separate store"
	)


func test_paths_default_to_the_resident_dimension() -> void:
	DimensionContext.set_active(DimensionContext.NETHER)
	assert_true(
		SaveLoad.region_dir(_WORLD).ends_with("DIM-1/region"),
		"an unqualified call follows the active dimension"
	)
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	assert_true(SaveLoad.region_dir(_WORLD).ends_with("/region"), "and back to the Overworld root")
	assert_false(SaveLoad.region_dir(_WORLD).contains("DIM-1"), "no stray namespace")


# --- Region isolation ---


func test_same_coordinate_stores_different_bytes_per_dimension() -> void:
	# The Batch 1 acceptance criterion, stated directly.
	var coord := Vector2i(0, 0)
	SaveLoad.save_chunk(coord, _entry(Blocks.STONE), _WORLD, DimensionContext.OVERWORLD)
	SaveLoad.save_chunk(coord, _entry(Blocks.BEDROCK), _WORLD, DimensionContext.NETHER)
	SaveLoad.clear_cache()
	var ow: Dictionary = SaveLoad.load_chunk(coord, _WORLD, DimensionContext.OVERWORLD)
	var nether: Dictionary = SaveLoad.load_chunk(coord, _WORLD, DimensionContext.NETHER)
	assert_eq(_first_block(ow), Blocks.STONE, "Overworld chunk kept its own bytes")
	assert_eq(_first_block(nether), Blocks.BEDROCK, "Nether chunk kept its own bytes")


func test_the_two_dimensions_write_separate_region_files() -> void:
	var coord := Vector2i(0, 0)
	SaveLoad.save_chunk(coord, _entry(Blocks.STONE), _WORLD, DimensionContext.OVERWORLD)
	SaveLoad.save_chunk(coord, _entry(Blocks.BEDROCK), _WORLD, DimensionContext.NETHER)
	var ow_path: String = SaveLoad.region_path(0, 0, _WORLD, DimensionContext.OVERWORLD)
	var nether_path: String = SaveLoad.region_path(0, 0, _WORLD, DimensionContext.NETHER)
	assert_ne(ow_path, nether_path, "different files")
	assert_true(FileAccess.file_exists(ow_path), "Overworld region written")
	assert_true(FileAccess.file_exists(nether_path), "Nether region written")


func test_the_region_cache_is_keyed_by_dimension() -> void:
	# Without a dimension in the cache key this passes on disk and fails
	# in memory: the second read returns the first dimension's cached
	# dictionary, and the next flush writes it over the other dimension.
	var coord := Vector2i(2, -3)
	SaveLoad.save_chunk(coord, _entry(Blocks.STONE), _WORLD, DimensionContext.OVERWORLD)
	SaveLoad.save_chunk(coord, _entry(Blocks.BEDROCK), _WORLD, DimensionContext.NETHER)
	# No clear_cache here — read straight back through the warm cache.
	var ow: Dictionary = SaveLoad.load_chunk(coord, _WORLD, DimensionContext.OVERWORLD)
	var nether: Dictionary = SaveLoad.load_chunk(coord, _WORLD, DimensionContext.NETHER)
	assert_eq(_first_block(ow), Blocks.STONE, "warm-cache Overworld read is not the Nether's")
	assert_eq(_first_block(nether), Blocks.BEDROCK, "warm-cache Nether read is its own")


func test_a_chunk_saved_in_one_dimension_is_absent_from_the_other() -> void:
	var coord := Vector2i(7, 7)
	SaveLoad.save_chunk(coord, _entry(Blocks.STONE), _WORLD, DimensionContext.NETHER)
	SaveLoad.clear_cache()
	var ow: Dictionary = SaveLoad.load_chunk(coord, _WORLD, DimensionContext.OVERWORLD)
	assert_true(ow.is_empty(), "the Overworld has never seen this chunk")


func test_autosave_flushes_every_dimension_of_the_world() -> void:
	# A player who edits the Nether, walks back through a portal and then
	# autosaves must not lose the Nether edit.
	SaveLoad.save_chunk(Vector2i(0, 0), _entry(Blocks.STONE), _WORLD, DimensionContext.OVERWORLD)
	SaveLoad.save_chunk(Vector2i(0, 0), _entry(Blocks.BEDROCK), _WORLD, DimensionContext.NETHER)
	var written: int = SaveLoad.flush_all_regions(_WORLD)
	assert_eq(written, 2, "both dimensions' cached regions were flushed")


# --- Entity isolation ---


func test_entity_stores_do_not_leak_between_dimensions() -> void:
	var parent := Node.new()
	add_child_autofree(parent)
	var item := preload("res://scripts/world/dropped_item.gd").new()
	parent.add_child(item)
	item.global_position = Vector3(1, 65, 1)
	item.setup(Blocks.STONE)

	var saved: int = EntitySave.save_all(parent, _WORLD, DimensionContext.OVERWORLD)
	assert_eq(saved, 1, "one entity saved to the Overworld")

	var nether_parent := Node.new()
	add_child_autofree(nether_parent)
	var loaded: int = EntitySave.load_all(nether_parent, _WORLD, DimensionContext.NETHER)
	assert_eq(loaded, 0, "the Nether has no entities of its own")

	var ow_parent := Node.new()
	add_child_autofree(ow_parent)
	assert_eq(
		EntitySave.load_all(ow_parent, _WORLD, DimensionContext.OVERWORLD),
		1,
		"the Overworld still has its entity"
	)


# --- player.bin versioning and migration ---


func _write_v1_player_file(payload: Dictionary) -> void:
	# Hand-build a version-1 file: the format that existed before the
	# Nether, with no "dimension" key at all.
	DirAccess.make_dir_recursive_absolute(SaveLoad.world_dir(_WORLD))
	var magic := PackedByteArray([0x4D, 0x43, 0x41, 0x50])
	SaveLoad.pack_and_write(PlayerSave.player_path(_WORLD), magic, 1, var_to_bytes(payload))


func test_a_v1_save_reports_the_overworld() -> void:
	_write_v1_player_file({"pos": Vector3(10, 70, 10), "yaw": 0.0, "pitch": 0.0, "health": 20})
	assert_eq(
		PlayerSave.peek_dimension(_WORLD),
		DimensionContext.OVERWORLD,
		"a pre-Nether save was necessarily in the Overworld"
	)


func test_a_v1_save_still_yields_its_position() -> void:
	# The v1 -> v2 bump must not break the peek ChunkManager relies on to
	# centre the initial chunk ring.
	_write_v1_player_file({"pos": Vector3(120, 70, -40), "yaw": 0.0, "pitch": 0.0, "health": 20})
	var pos: Variant = PlayerSave.peek_position(_WORLD)
	assert_true(pos is Vector3, "v1 position still readable")
	if pos is Vector3:
		assert_eq(pos as Vector3, Vector3(120, 70, -40), "and unchanged")


func test_a_v1_save_is_not_rewritten_by_being_read() -> void:
	# Migration happens in memory. Opening an old world and quitting
	# without playing must leave its bytes alone.
	_write_v1_player_file({"pos": Vector3(1, 70, 1), "yaw": 0.0, "pitch": 0.0, "health": 20})
	var path: String = PlayerSave.player_path(_WORLD)
	var before: PackedByteArray = FileAccess.get_file_as_bytes(path)
	PlayerSave.peek_dimension(_WORLD)
	PlayerSave.peek_position(_WORLD)
	var after: PackedByteArray = FileAccess.get_file_as_bytes(path)
	assert_eq(after, before, "reading a v1 save does not rewrite it")


func test_a_v2_save_round_trips_its_dimension() -> void:
	DirAccess.make_dir_recursive_absolute(SaveLoad.world_dir(_WORLD))
	var magic := PackedByteArray([0x4D, 0x43, 0x41, 0x50])
	SaveLoad.pack_and_write(
		PlayerSave.player_path(_WORLD),
		magic,
		2,
		var_to_bytes({"pos": Vector3(5, 40, 5), "dimension": DimensionContext.NETHER})
	)
	assert_eq(
		PlayerSave.peek_dimension(_WORLD),
		DimensionContext.NETHER,
		"a v2 save restores the dimension it was written in"
	)


func test_an_unregistered_dimension_in_a_save_falls_back_to_the_overworld() -> void:
	# A hand-edited or future-format save must not strand the player in a
	# dimension with no provider.
	DirAccess.make_dir_recursive_absolute(SaveLoad.world_dir(_WORLD))
	var magic := PackedByteArray([0x4D, 0x43, 0x41, 0x50])
	SaveLoad.pack_and_write(
		PlayerSave.player_path(_WORLD),
		magic,
		2,
		var_to_bytes({"pos": Vector3(5, 40, 5), "dimension": 42})
	)
	# A warning rather than an error: the save is recoverable and we
	# recover it, so this must not read as a crash in the log.
	assert_eq(PlayerSave.peek_dimension(_WORLD), DimensionContext.OVERWORLD, "falls back safely")


func test_an_unknown_format_version_is_refused() -> void:
	DirAccess.make_dir_recursive_absolute(SaveLoad.world_dir(_WORLD))
	var magic := PackedByteArray([0x4D, 0x43, 0x41, 0x50])
	SaveLoad.pack_and_write(
		PlayerSave.player_path(_WORLD), magic, 99, var_to_bytes({"pos": Vector3(5, 40, 5)})
	)
	assert_eq(
		PlayerSave.peek_dimension(_WORLD),
		DimensionContext.OVERWORLD,
		"an unreadable save puts the player somewhere safe"
	)
	assert_null(PlayerSave.peek_position(_WORLD), "and reports no usable position")


func test_a_corrupt_player_file_is_refused() -> void:
	DirAccess.make_dir_recursive_absolute(SaveLoad.world_dir(_WORLD))
	var f := FileAccess.open(PlayerSave.player_path(_WORLD), FileAccess.WRITE)
	assert_not_null(f, "corrupt file created")
	if f != null:
		f.store_buffer(PackedByteArray([1, 2, 3]))
		f.close()
	assert_eq(PlayerSave.peek_dimension(_WORLD), DimensionContext.OVERWORLD, "safe default")
	assert_null(PlayerSave.peek_position(_WORLD), "no position from a truncated file")


func test_a_missing_player_file_reports_the_overworld() -> void:
	assert_eq(
		PlayerSave.peek_dimension(_WORLD),
		DimensionContext.OVERWORLD,
		"a fresh world starts in the Overworld"
	)


# --- Save / restart round trip in dimension -1 ---


func test_saving_in_the_nether_records_the_nether() -> void:
	# The round trip that matters: a player who quits in the Nether comes
	# back to the Nether, not to an Overworld coordinate with Nether
	# chunks around it.
	var player := CharacterBody3D.new()
	add_child_autofree(player)
	player.global_position = Vector3(12.5, 41.0, -8.5)
	DimensionContext.set_active(DimensionContext.NETHER)
	assert_true(PlayerSave.save_player(player, _WORLD), "save succeeds in the Nether")

	# Simulate a restart: forget the resident dimension entirely.
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	assert_eq(
		PlayerSave.peek_dimension(_WORLD),
		DimensionContext.NETHER,
		"the saved dimension survives a restart"
	)
	var pos: Variant = PlayerSave.peek_position(_WORLD)
	assert_true(pos is Vector3, "and so does the position")
	if pos is Vector3:
		assert_eq(pos as Vector3, Vector3(12.5, 41.0, -8.5), "exact position preserved")


func test_loading_a_nether_save_makes_the_nether_resident() -> void:
	var player := CharacterBody3D.new()
	add_child_autofree(player)
	player.global_position = Vector3(4.0, 45.0, 4.0)
	DimensionContext.set_active(DimensionContext.NETHER)
	PlayerSave.save_player(player, _WORLD)

	DimensionContext.set_active(DimensionContext.OVERWORLD)
	var target := CharacterBody3D.new()
	add_child_autofree(target)
	assert_true(PlayerSave.load_player(target, _WORLD), "load succeeds")
	assert_true(DimensionContext.is_nether(), "loading a Nether save makes the Nether resident")


func test_saving_in_the_overworld_still_records_the_overworld() -> void:
	# Regression guard for the v2 bump: the common case must not change.
	var player := CharacterBody3D.new()
	add_child_autofree(player)
	player.global_position = Vector3(1.0, 70.0, 1.0)
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	PlayerSave.save_player(player, _WORLD)
	assert_eq(PlayerSave.peek_dimension(_WORLD), DimensionContext.OVERWORLD, "Overworld round trip")
