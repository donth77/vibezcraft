extends GutTest

# WorldMeta round-trip (step 7.4 of the save/load plan). JSON-on-disk
# format, atomic write via SaveLoad.atomic_write, format_version guard.

var _current_world: String = ""


func before_each() -> void:
	_current_world = ""


func after_each() -> void:
	if _current_world != "":
		SaveLoad.delete_world(_current_world)


func _world(slug: String) -> String:
	_current_world = "test_world_meta_" + slug
	SaveLoad.delete_world(_current_world)
	return _current_world


func test_load_missing_returns_empty_dict() -> void:
	var world := _world("missing")
	assert_eq(WorldMeta.load_meta(world), {})


func test_round_trip_preserves_seed_time_spawn() -> void:
	var world := _world("round_trip")
	var initial: Dictionary = WorldMeta.make_initial(12345, Vector3i(0, 70, 0), 6000)
	assert_true(WorldMeta.save_meta(initial, world))
	var loaded: Dictionary = WorldMeta.load_meta(world)
	assert_eq(int(loaded.seed), 12345)
	assert_eq(int(loaded.time_ticks), 6000)
	assert_eq(int(loaded.spawn.x), 0)
	assert_eq(int(loaded.spawn.y), 70)
	assert_eq(int(loaded.spawn.z), 0)
	assert_eq(int(loaded.format_version), 1)
	assert_true(loaded.has("created_at"))
	assert_true(loaded.has("last_played"))


func test_save_updates_last_played_each_call() -> void:
	var world := _world("last_played")
	var meta: Dictionary = WorldMeta.make_initial(1, Vector3i.ZERO, 0)
	WorldMeta.save_meta(meta, world)
	var first: Dictionary = WorldMeta.load_meta(world)
	# Wait at least a wall-clock second so the second save's ISO timestamp
	# can plausibly differ. Time.get_datetime_string_from_system rounds to
	# seconds so a sub-second gap would produce identical strings.
	OS.delay_msec(1100)
	WorldMeta.save_meta(first, world)
	var second: Dictionary = WorldMeta.load_meta(world)
	assert_ne(
		first.last_played, second.last_played, "last_played should advance between saves >1s apart"
	)


func test_unknown_format_version_returns_empty_with_warning() -> void:
	var world := _world("bad_version")
	# Hand-craft a JSON with format_version=999 → loader rejects.
	DirAccess.make_dir_recursive_absolute(SaveLoad.world_dir(world))
	var f: FileAccess = FileAccess.open(WorldMeta.meta_path(world), FileAccess.WRITE)
	f.store_string('{"format_version": 999, "seed": 42}')
	f.close()
	# load_meta should warn + return empty.
	assert_eq(WorldMeta.load_meta(world), {})


func test_non_json_payload_returns_empty() -> void:
	var world := _world("bad_payload")
	DirAccess.make_dir_recursive_absolute(SaveLoad.world_dir(world))
	var f: FileAccess = FileAccess.open(WorldMeta.meta_path(world), FileAccess.WRITE)
	f.store_string("not actually json {{{")
	f.close()
	assert_eq(WorldMeta.load_meta(world), {})


func test_play_time_accumulates_across_saves() -> void:
	var world := _world("playtime")
	var meta: Dictionary = WorldMeta.make_initial(1, Vector3i.ZERO, 0)
	meta["play_time_seconds"] = 100
	WorldMeta.save_meta(meta, world)
	# Caller's responsibility to add session delta — the module doesn't
	# inject it. Verify the stored value survives the round-trip unchanged.
	var loaded: Dictionary = WorldMeta.load_meta(world)
	assert_eq(int(loaded.play_time_seconds), 100)
	loaded["play_time_seconds"] = 250
	WorldMeta.save_meta(loaded, world)
	var second: Dictionary = WorldMeta.load_meta(world)
	assert_eq(int(second.play_time_seconds), 250)
