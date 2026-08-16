# gdlint: disable=max-public-methods
extends GutTest

# Nether integration — the release-gate criteria that only make sense
# with several systems wired together
# (docs/nether-alpha-1.2.6-implementation-plan.md Batch 10).
#
# The individual batches each proved their own piece. What this file
# checks is that the pieces do not interfere: that a round trip preserves
# what it should, that neither dimension's state leaks into the other,
# and that a save written on one side of a portal comes back intact.
#
# Uses a real ChunkManager with no player child, so _process early-returns
# and no streaming or worker job starts — the same harness
# tests/test_dimension_context.gd established.

const ChunkManagerScript := preload("res://scripts/world/chunk_manager.gd")
const ChunkNodeScript := preload("res://scripts/world/chunk_node.gd")

# Throwaway save slot. A transition genuinely persists the dimension it
# leaves, and an unqualified save resolves to Game.active_world — a real
# slot the player has played in. Redirect it first, every time.
const _WORLD := "test_nether_integration"

var _cm: Node3D
var _dimension_was: int
var _active_world_was: String
var _difficulty_was: int


func before_each() -> void:
	_dimension_was = DimensionContext.active()
	_active_world_was = Game.active_world
	_difficulty_was = Game.difficulty
	Game.active_world = _WORLD
	Game.difficulty = Game.DIFFICULTY_NORMAL
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	PortalIndex.reset()
	TickScheduler.clear_all()
	SaveLoad.clear_cache()
	SaveLoad.delete_world(_WORLD)
	_cm = ChunkManagerScript.new()
	add_child_autofree(_cm)


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)
	PortalIndex.reset()
	TickScheduler.clear_all()
	SaveLoad.clear_cache()
	SaveLoad.delete_world(_WORLD)
	Game.active_world = _active_world_was
	Game.difficulty = _difficulty_was
	Game.is_loading = false


func _bind_chunk(coord: Vector2i) -> Chunk:
	var chunk := Chunk.new()
	var node: Node3D = ChunkNodeScript.new()
	node.chunk_data = chunk
	node.chunk = chunk
	_cm._chunks[coord] = node
	_cm.add_child(node)
	return chunk


# --- Dimension isolation ---


func test_a_round_trip_returns_to_the_overworld() -> void:
	assert_true(DimensionContext.is_overworld(), "starts at home")
	assert_true(_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8)), "down")
	assert_eq(DimensionContext.active(), DimensionContext.NETHER)
	assert_true(
		_cm.transition_to_dimension(DimensionContext.OVERWORLD, Vector3(64, 70, 64)), "and back"
	)
	assert_true(DimensionContext.is_overworld(), "home again")


func test_ten_round_trips_leave_the_world_coherent() -> void:
	# The stress version. A leak in the transition — a chunk that
	# survives, a provider that is mutated rather than read, an epoch
	# that stops advancing — compounds over repeats.
	var epoch_before: int = DimensionContext.epoch()
	for _i: int in range(10):
		_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
		_cm.transition_to_dimension(DimensionContext.OVERWORLD, Vector3(64, 70, 64))
	assert_true(DimensionContext.is_overworld(), "ends where it started")
	assert_eq(_cm._chunks.size(), 0, "no chunks left resident from either side")
	assert_gte(DimensionContext.epoch() - epoch_before, 20, "every switch bumped the epoch")


func test_blocks_do_not_leak_between_dimensions() -> void:
	var chunk: Chunk = _bind_chunk(Vector2i(0, 0))
	chunk.set_block(1, 70, 1, Blocks.GRASS)
	_cm._dirty_loaded[Vector2i(0, 0)] = true
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	# The Overworld chunk was persisted to the Overworld's region file and
	# freed. Nothing of it may be resident now.
	assert_false(_cm._chunks.has(Vector2i(0, 0)), "the chunk is gone")
	var nether_entry: Dictionary = SaveLoad.load_chunk(
		Vector2i(0, 0), _WORLD, DimensionContext.NETHER
	)
	assert_true(nether_entry.is_empty(), "and it was not written into the Nether's region file")


func test_entities_do_not_follow_the_player_through() -> void:
	# `_free_dimension_scene` removes every persistable entity. A pig that
	# survived a portal trip would be a duplicate the moment the player
	# came back and its saved copy reloaded.
	var pig: Node = MobRegistry.script_for("pig").new()
	_cm.add_child(pig)
	(pig as Node3D).global_position = Vector3(4, 70, 4)
	assert_true(EntitySave.is_persistable(pig), "a pig is persistable")
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	var survivors: int = 0
	for child: Node in _cm.get_children():
		if child is MobBase:
			survivors += 1
	assert_eq(survivors, 0, "no mob crossed the portal")


func test_the_provider_switches_with_the_dimension() -> void:
	# Every dimension-scoped policy is read from the provider rather than
	# branched on an `if nether`, so this one assertion covers all of them.
	assert_true(DimensionContext.active_provider().has_sky_light, "Overworld has sky")
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	var nether: WorldProvider = DimensionContext.active_provider()
	assert_false(nether.has_sky_light, "the Nether does not")
	assert_false(nether.allows_sleeping, "and denies beds")
	assert_false(nether.allows_water_placement, "and evaporates water")
	assert_false(nether.has_passive_spawns, "and has no passive list")
	assert_eq(nether.coordinate_scale, 8.0, "and is eight times smaller")


func test_providers_survive_repeated_switching_unmutated() -> void:
	# A system that wrote to the provider instead of reading it would
	# show up here, and nowhere else.
	for _i: int in range(10):
		_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
		_cm.transition_to_dimension(DimensionContext.OVERWORLD, Vector3(64, 70, 64))
	assert_eq(DimensionContext.provider(DimensionContext.NETHER).ambient_light_floor, 0.1)
	assert_eq(DimensionContext.provider(DimensionContext.OVERWORLD).ambient_light_floor, 0.05)
	assert_eq(DimensionContext.provider(DimensionContext.NETHER).hostile_cap_per_256_chunks, 100)
	assert_eq(DimensionContext.provider(DimensionContext.OVERWORLD).hostile_cap_per_256_chunks, 70)


# --- Persistence across a round trip ---


func test_each_dimension_keeps_its_own_region_files() -> void:
	# Written through SaveLoad rather than by ticking the ChunkManager,
	# because ChunkManager's disk writes are deliberately disabled under
	# headless (see _disk_writes_allowed — a headless boot of a real world
	# generates wrong-seed terrain, and persisting it fossilised World1
	# once already). The claim being tested is the DIMENSION KEYING, and
	# that lives in SaveLoad either way.
	SaveLoad.save_chunk(
		Vector2i(0, 0), _entry_filled_with(Blocks.GRASS), _WORLD, DimensionContext.OVERWORLD
	)
	SaveLoad.save_chunk(
		Vector2i(0, 0), _entry_filled_with(Blocks.NETHERRACK), _WORLD, DimensionContext.NETHER
	)
	# Same chunk coordinate, two dimensions, two different blocks.
	var ow: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), _WORLD, DimensionContext.OVERWORLD)
	var nether: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), _WORLD, DimensionContext.NETHER)
	assert_false(ow.is_empty(), "the Overworld chunk is on disk")
	assert_false(nether.is_empty(), "and so is the Nether one")
	assert_eq(_block_at(ow, 1, 70, 1), Blocks.GRASS, "grass stayed in the Overworld")
	assert_eq(_block_at(nether, 1, 70, 1), Blocks.NETHERRACK, "netherrack stayed in the Nether")


func test_a_headless_session_writes_no_chunks() -> void:
	# The guard the test above works around, asserted directly. A headless
	# run generates seed-12345 terrain; persisting any of it corrupts the
	# real world the run was pointed at.
	assert_false(_cm.call("_disk_writes_allowed"), "headless is read-only")
	var chunk: Chunk = _bind_chunk(Vector2i(3, 3))
	chunk.set_block(1, 70, 1, Blocks.GRASS)
	_cm._dirty_loaded[Vector2i(3, 3)] = true
	assert_eq(_cm.flush_dirty_loaded(), 0, "and writes nothing when asked to")


func _entry_filled_with(fill_id: int) -> Dictionary:
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


func _block_at(entry: Dictionary, x: int, y: int, z: int) -> int:
	var raw: PackedByteArray = (entry["bytes"] as PackedByteArray).decompress(Chunk.TOTAL_BLOCKS)
	return raw[y * Chunk.SIZE_X * Chunk.SIZE_Z + z * Chunk.SIZE_X + x]


func test_the_portal_index_persists_per_dimension() -> void:
	PortalIndex.record(DimensionContext.OVERWORLD, Vector3i(100, 70, 100))
	PortalIndex.save(_WORLD, DimensionContext.OVERWORLD)
	PortalIndex.record(DimensionContext.NETHER, Vector3i(12, 80, 12))
	PortalIndex.save(_WORLD, DimensionContext.NETHER)
	PortalIndex.reset()
	PortalIndex.load_index(_WORLD, DimensionContext.OVERWORLD)
	PortalIndex.load_index(_WORLD, DimensionContext.NETHER)
	assert_has(
		PortalIndex.entries(DimensionContext.OVERWORLD),
		Vector3i(100, 70, 100),
		"the Overworld portal came back"
	)
	assert_has(
		PortalIndex.entries(DimensionContext.NETHER),
		Vector3i(12, 80, 12),
		"and so did the Nether one"
	)


func test_a_nether_mob_round_trips_through_its_own_entity_file() -> void:
	# The full stack: a pigman saved in the Nether must come back from
	# the Nether's entities.bin, not the Overworld's.
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	var host := Node.new()
	add_child_autofree(host)
	var pigman: Node = MobRegistry.script_for("zombie_pigman").new()
	host.add_child(pigman)
	(pigman as Node3D).global_position = Vector3(12, 80, 12)
	pigman.set("anger", 640)
	assert_eq(EntitySave.save_all(host, _WORLD, DimensionContext.NETHER), 1, "written")
	host.remove_child(pigman)
	pigman.free()
	assert_eq(
		EntitySave.load_all(host, _WORLD, DimensionContext.OVERWORLD),
		0,
		"the Overworld's file does not have it"
	)
	assert_eq(EntitySave.load_all(host, _WORLD, DimensionContext.NETHER), 1, "the Nether's does")
	var restored: Node = null
	for child: Node in host.get_children():
		if child is ZombiePigman:
			restored = child
	assert_not_null(restored, "and it came back as a pigman")
	if restored != null:
		assert_eq(restored.get("anger"), 640, "still angry")


func test_the_saved_dimension_survives_a_restart() -> void:
	# What a "restart on the Nether side" actually depends on:
	# PlayerSave.peek_dimension, which ChunkManager._ready reads before
	# building the first chunk ring.
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	var player := CharacterBody3D.new()
	add_child_autofree(player)
	player.global_position = Vector3(12, 80, 12)
	PlayerSave.save_player(player, _WORLD)
	assert_eq(
		PlayerSave.peek_dimension(_WORLD),
		DimensionContext.NETHER,
		"a restart resumes in the Nether"
	)


func test_a_restart_on_the_overworld_side_resumes_there() -> void:
	var player := CharacterBody3D.new()
	add_child_autofree(player)
	player.global_position = Vector3(64, 70, 64)
	PlayerSave.save_player(player, _WORLD)
	assert_eq(
		PlayerSave.peek_dimension(_WORLD),
		DimensionContext.OVERWORLD,
		"and the Overworld resumes at home"
	)


# --- Generation parity ---


func test_native_and_gdscript_nether_generation_agree() -> void:
	# A release-gate criterion in its own right: "Native and fallback
	# generation stay fixture-identical." The per-native parity suite
	# covers this exhaustively; this is the integration-level statement
	# that the two paths are still wired to the same generator.
	if not WorldgenNether.native_available():
		gut.p("native extension not loaded — parity is vacuous, skipping")
		pass_test("no native extension in this build")
		return
	for coord: Vector2i in [Vector2i(0, 0), Vector2i(-3, 7)]:
		var native: PackedByteArray = WorldgenNether.generate_raw(coord.x, coord.y)
		var reference: PackedByteArray = WorldgenNether.generate_raw_gdscript(coord.x, coord.y)
		assert_eq(
			native, reference, "chunk (%d, %d) is byte-identical on both paths" % [coord.x, coord.y]
		)


func test_nether_generation_is_deterministic() -> void:
	var first: Chunk = WorldgenNether.generate_chunk(5, -2)
	var second: Chunk = WorldgenNether.generate_chunk(5, -2)
	assert_eq(first.blocks, second.blocks, "same coordinate, same chunk, every time")


func test_nether_generation_is_independent_of_request_order() -> void:
	# The Overworld guarantees this and the Nether must too, or a chunk
	# would depend on which neighbours were streamed first.
	var forward: Array[PackedByteArray] = []
	for x: int in range(3):
		forward.append(WorldgenNether.generate_chunk(x, 0).blocks)
	var backward: Array[PackedByteArray] = []
	for x: int in [2, 1, 0]:
		backward.push_front(WorldgenNether.generate_chunk(x, 0).blocks)
	assert_eq(forward, backward, "order does not matter")


# --- Cross-dimension ticking ---


func test_no_scheduled_ticks_survive_a_transition() -> void:
	# A block tick queued in the Overworld that fired in the Nether would
	# write into the wrong dimension's chunk at the same coordinate.
	TickScheduler.schedule(Vector3i(4, 70, 4), Blocks.FIRE, 10)
	assert_gt(TickScheduler.pending_count(), 0, "queued")
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	assert_eq(TickScheduler.pending_count(), 0, "cleared on the way out")


func test_stale_worker_results_are_refused_after_a_transition() -> void:
	# WorkerThreadPool has no cancel API, so a chunk job dispatched a
	# frame before a portal trip WILL finish. Refusing its result is the
	# only defence, and it is the one that keeps a Nether chunk from
	# being overwritten with Overworld terrain.
	var epoch_before: int = DimensionContext.epoch()
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	assert_false(
		DimensionContext.accepts_result(DimensionContext.OVERWORLD, epoch_before),
		"an in-flight Overworld job is rejected"
	)
	assert_false(
		DimensionContext.accepts_result(DimensionContext.NETHER, epoch_before),
		"and so is one tagged with the old epoch, whatever its dimension"
	)
	assert_true(
		DimensionContext.accepts_result(DimensionContext.NETHER, DimensionContext.epoch()),
		"but a fresh Nether job is accepted"
	)


func test_tile_entity_state_does_not_cross() -> void:
	# ChestStorage and friends are keyed by chunk coord, which repeats in
	# every dimension. A chest at (0,0) in the Overworld must not appear
	# at (0,0) in the Nether.
	ChestStorage.get_or_create(Vector3i(2, 70, 2))
	assert_gt(ChestStorage.get_active_chunks().size(), 0, "a chest exists")
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	assert_eq(ChestStorage.get_active_chunks().size(), 0, "and the Nether starts with none of it")


# --- Content registry ---


func test_every_nether_id_is_registered_and_unique() -> void:
	# The standing rule for this project: never infer content kind from
	# the numeric id. These four are the ones the Nether added.
	for id: int in [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE, Blocks.PORTAL]:
		assert_true(Blocks.is_registered(id), "block %d is registered" % id)
	assert_true(Items.is_registered(Items.GLOWSTONE_DUST), "glowstone dust is an item")
	assert_false(
		Blocks.has_item_form(Blocks.PORTAL), "and the portal is world-only, above the item floor"
	)


func test_the_burned_id_is_still_burned() -> void:
	# 50 was removed tall grass. Nothing this feature added may have
	# reused it.
	assert_false(Blocks.is_registered(50), "id 50 stays dead")
	assert_false(Items.is_registered(50), "on both sides of the registry")
