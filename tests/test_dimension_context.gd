# gdlint: disable=max-public-methods
extends GutTest

# Dimension provider, epoch and transition transaction
# (docs/nether-alpha-1.2.6-implementation-plan.md §3.2/§3.3/§5, Batch 1).
#
# The two things that have to be true before any Nether content exists:
# exactly one dimension's scene is resident at a time, and work queued for
# a dimension can never be applied to a different one. The second matters
# because WorkerThreadPool has no cancel API — a chunk job dispatched a
# frame before a portal transition WILL finish, and the only defence is
# refusing its result.

const ChunkManagerScript := preload("res://scripts/world/chunk_manager.gd")
const ChunkNodeScript := preload("res://scripts/world/chunk_node.gd")

# Throwaway save slot. transition_to_dimension legitimately PERSISTS the
# dimension it is leaving, and an unqualified save resolves to
# Game.active_world — which is a real slot the player has played in. Every
# test here redirects that first. (A previous session hard-deleted a real
# World1 by not doing this; SaveLoad.delete_world has no trash.)
const _WORLD := "test_dimension_context"

var _cm: Node3D
var _dimension_was: int
var _active_world_was: String


func before_each() -> void:
	_dimension_was = DimensionContext.active()
	_active_world_was = Game.active_world
	Game.active_world = _WORLD
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	TickScheduler.clear_all()
	# No player child, so _process early-returns and no streaming or
	# worker job starts. Same pattern as tests/test_redstone_state.gd.
	_cm = ChunkManagerScript.new()
	add_child_autofree(_cm)


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)
	TickScheduler.clear_all()
	SaveLoad.clear_cache()
	SaveLoad.delete_world(_WORLD)
	Game.active_world = _active_world_was


func _bind_chunk(coord: Vector2i) -> Chunk:
	var chunk := Chunk.new()
	var node: Node3D = ChunkNodeScript.new()
	node.chunk_data = chunk
	node.chunk = chunk
	_cm._chunks[coord] = node
	_cm.add_child(node)
	return chunk


# --- Provider registry ---


func test_both_dimensions_have_providers() -> void:
	assert_true(DimensionContext.is_registered(DimensionContext.OVERWORLD), "dimension 0 exists")
	assert_true(DimensionContext.is_registered(DimensionContext.NETHER), "dimension -1 exists")
	assert_eq(DimensionContext.registered_ids(), [-1, 0], "exactly the two Alpha dimensions")


func test_unknown_dimension_is_not_registered() -> void:
	for id: int in [1, 2, -2, 99]:
		assert_false(DimensionContext.is_registered(id), "dimension %d is not registered" % id)


func test_overworld_provider_keeps_the_pre_nether_values() -> void:
	# The plan requires the Overworld to move behind the provider WITHOUT
	# behaviour changes. These are the values the engine used before the
	# provider existed; if one drifts, dimension 0 changed.
	var ow: WorldProvider = DimensionContext.provider(DimensionContext.OVERWORLD)
	assert_eq(ow.id, 0, "id 0")
	assert_eq(ow.save_namespace, "", "Overworld saves stay at the world root")
	assert_true(ow.has_sky_light, "Overworld propagates skylight")
	assert_true(ow.renders_sky, "Overworld renders a sky")
	assert_eq(ow.coordinate_scale, 1.0, "no coordinate scaling")
	assert_true(ow.allows_water_placement, "water buckets place water")
	assert_eq(ow.lava_horizontal_decay, 2, "Overworld lava decays by 2 per block")
	assert_true(ow.allows_sleeping, "beds work")
	assert_true(ow.provides_player_spawn, "Overworld defines the spawn point")


func test_nether_provider_matches_the_source_derived_policy() -> void:
	# §5.1/§5.2 — every one of these traces to om.java or the plan's
	# source-derived environment section.
	var nether: WorldProvider = DimensionContext.provider(DimensionContext.NETHER)
	assert_eq(nether.id, -1, "dimension id -1")
	assert_eq(nether.save_namespace, "DIM-1", "own save namespace")
	assert_false(nether.has_sky_light, "no skylight channel")
	assert_false(nether.renders_sky, "no sky, sun, moon, stars or weather")
	assert_almost_eq(nether.ambient_light_floor, 0.1, 1e-6, "ambient floor 0.1, not 0.05")
	assert_almost_eq(nether.fixed_celestial_angle, 0.5, 1e-6, "celestial angle pinned at 0.5")
	assert_eq(nether.coordinate_scale, 8.0, "8:1 horizontal scaling")
	assert_false(nether.allows_water_placement, "water evaporates")
	assert_eq(nether.lava_horizontal_decay, 1, "lava decays by 1, giving longer reach")
	assert_false(nether.allows_sleeping, "beds are denied")
	assert_false(nether.provides_player_spawn, "Nether terrain never defines a spawn")
	assert_eq(
		Array(nether.natural_hostile_species),
		["zombie_pigman", "ghast"],
		"the Hell biome list is exactly these two"
	)


func test_provider_defaults_to_the_active_dimension() -> void:
	DimensionContext.set_active(DimensionContext.NETHER)
	assert_eq(DimensionContext.provider().id, -1, "no-arg provider follows the active dimension")
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	assert_eq(DimensionContext.provider().id, 0, "and back")


func test_activating_an_unregistered_dimension_is_refused() -> void:
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	DimensionContext.set_active(7)
	assert_push_error("refusing to activate unregistered dimension 7")
	assert_eq(DimensionContext.active(), 0, "an unknown id cannot become resident")


# --- Epoch and stale-result rejection ---


func test_epoch_advances_on_every_transition() -> void:
	var before: int = DimensionContext.epoch()
	var after: int = DimensionContext.begin_transition()
	assert_eq(after, before + 1, "begin_transition bumps the epoch")
	assert_eq(DimensionContext.epoch(), after, "and the bump is visible")


func test_a_result_from_the_current_dimension_and_epoch_is_accepted() -> void:
	var epoch: int = DimensionContext.epoch()
	assert_true(
		DimensionContext.accepts_result(DimensionContext.active(), epoch), "current work is applied"
	)


func test_a_result_from_a_previous_epoch_is_rejected() -> void:
	var stale_epoch: int = DimensionContext.epoch()
	DimensionContext.begin_transition()
	assert_false(
		DimensionContext.accepts_result(DimensionContext.active(), stale_epoch),
		"work queued before the transition is refused"
	)


func test_a_result_from_another_dimension_is_rejected() -> void:
	var epoch: int = DimensionContext.epoch()
	assert_false(
		DimensionContext.accepts_result(DimensionContext.NETHER, epoch),
		"Nether work cannot land in the Overworld"
	)


func test_the_chunk_manager_drops_a_stale_worker_result() -> void:
	# Fault injection: publish a result tagged with the epoch that was
	# current when a worker started, then transition, then drain. This is
	# the exact sequence a portal produces.
	var coord := Vector2i(4, 4)
	var stale_epoch: int = DimensionContext.epoch()
	_cm._pending[coord] = Time.get_ticks_msec()
	_cm._ready_results[coord] = {
		"chunk": Chunk.new(),
		"mesh": {},
		"dimension": DimensionContext.OVERWORLD,
		"epoch": stale_epoch,
	}
	DimensionContext.begin_transition()
	var rejected_before: int = _cm.stale_results_rejected
	_cm._materialize_one_ready_chunk()
	assert_eq(
		_cm.stale_results_rejected, rejected_before + 1, "the stale result was counted as rejected"
	)
	assert_false(_cm._chunks.has(coord), "and never became a resident chunk")
	assert_false(_cm._pending.has(coord), "its pending slot was released for re-dispatch")


func test_a_result_tagged_for_the_other_dimension_is_dropped() -> void:
	var coord := Vector2i(5, 5)
	_cm._pending[coord] = Time.get_ticks_msec()
	_cm._ready_results[coord] = {
		"chunk": Chunk.new(),
		"mesh": {},
		"dimension": DimensionContext.NETHER,
		"epoch": DimensionContext.epoch(),
	}
	var rejected_before: int = _cm.stale_results_rejected
	_cm._materialize_one_ready_chunk()
	assert_eq(_cm.stale_results_rejected, rejected_before + 1, "Nether result refused")
	assert_false(_cm._chunks.has(coord), "no cross-dimension chunk materialised")


# --- Dimension-owned state ---


func test_clearing_dimension_state_drops_every_position_keyed_structure() -> void:
	# A chest at (10, 64, 10) in the Overworld and one at the same
	# coordinate in the Nether are different chests, but the tile-entity
	# singletons key on position alone.
	ChestStorage.get_or_create(Vector3i(10, 64, 10))
	TickScheduler.schedule(Vector3i(1, 2, 3), Blocks.WATER_FLOWING, 5)
	_cm._saved_chunks[Vector2i(9, 9)] = {"bytes": PackedByteArray()}
	_cm._dirty_loaded[Vector2i(9, 9)] = true
	_cm._spawn_queue.append(Vector2i(1, 1))
	_cm._pending[Vector2i(2, 2)] = 0

	assert_true(ChestStorage.has_chest(Vector3i(10, 64, 10)), "chest exists before the clear")
	assert_gt(TickScheduler.pending_count(), 0, "a tick is scheduled before the clear")

	_cm._clear_dimension_owned_state()

	assert_false(ChestStorage.has_chest(Vector3i(10, 64, 10)), "tile entities cleared")
	assert_eq(TickScheduler.pending_count(), 0, "scheduled ticks cleared")
	assert_eq(_cm._saved_chunks.size(), 0, "persisted-chunk cache cleared")
	assert_eq(_cm._dirty_loaded.size(), 0, "dirty set cleared")
	assert_eq(_cm._spawn_queue.size(), 0, "spawn queue cleared")
	assert_eq(_cm._pending.size(), 0, "pending jobs cleared")


func test_freeing_the_dimension_scene_leaves_no_resident_chunks() -> void:
	_bind_chunk(Vector2i(0, 0))
	_bind_chunk(Vector2i(1, 0))
	assert_eq(_cm._chunks.size(), 2, "two chunks resident")
	var freed: int = _cm._free_dimension_scene()
	assert_eq(freed, 2, "both chunk nodes freed")
	assert_eq(_cm._chunks.size(), 0, "no chunk remains resident")


# --- Transition transaction ---


func test_transition_switches_the_active_dimension() -> void:
	assert_true(DimensionContext.is_overworld(), "starts in the Overworld")
	var ok: bool = _cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 40, 8))
	assert_true(ok, "transition reports success")
	assert_true(DimensionContext.is_nether(), "now resident in the Nether")


func test_transition_leaves_only_one_dimensions_chunks_resident() -> void:
	# The acceptance criterion: repeated switching must not accumulate.
	_bind_chunk(Vector2i(0, 0))
	_bind_chunk(Vector2i(1, 0))
	_bind_chunk(Vector2i(0, 1))
	var before: int = _cm._chunks.size()
	assert_eq(before, 3, "three Overworld chunks resident")
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(0, 40, 0))
	# No player, so nothing streams back in; the point is that the source
	# dimension's scene is gone rather than merged with the destination's.
	assert_eq(_cm._chunks.size(), 0, "the Overworld scene did not survive the switch")


func test_repeated_transitions_do_not_accumulate_state() -> void:
	for i: int in range(5):
		_bind_chunk(Vector2i(i, 0))
		_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(0, 40, 0))
		assert_eq(_cm._chunks.size(), 0, "round %d: nothing resident after entering" % i)
		_bind_chunk(Vector2i(i, 1))
		_cm.transition_to_dimension(DimensionContext.OVERWORLD, Vector3(0, 70, 0))
		assert_eq(_cm._chunks.size(), 0, "round %d: nothing resident after leaving" % i)
	assert_true(DimensionContext.is_overworld(), "ten switches end where they started")


func test_transition_bumps_the_epoch_before_tearing_down() -> void:
	var before: int = DimensionContext.epoch()
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(0, 40, 0))
	assert_gt(DimensionContext.epoch(), before, "in-flight work was invalidated")


func test_transition_to_the_same_dimension_is_a_no_op() -> void:
	var epoch_before: int = DimensionContext.epoch()
	var ok: bool = _cm.transition_to_dimension(DimensionContext.OVERWORLD, Vector3(0, 70, 0))
	assert_true(ok, "reports success")
	assert_eq(DimensionContext.epoch(), epoch_before, "no epoch churn for a no-op")


func test_transition_to_an_unregistered_dimension_fails_without_switching() -> void:
	# Rollback-safety: a failed transition must leave a coherent world,
	# not a half-switched one.
	_bind_chunk(Vector2i(0, 0))
	var ok: bool = _cm.transition_to_dimension(5, Vector3(0, 70, 0))
	assert_push_error("no provider for dimension 5")
	assert_false(ok, "transition refuses an unknown dimension")
	assert_true(DimensionContext.is_overworld(), "still resident in the source dimension")
	assert_eq(_cm._chunks.size(), 1, "the source scene was not torn down")


func test_transition_places_the_player_and_recentres_streaming() -> void:
	var player := CharacterBody3D.new()
	player.velocity = Vector3(3, -9, 2)
	_cm.add_child(player)
	_cm._player = player
	var arrival := Vector3(200.0, 45.0, -70.0)
	_cm.transition_to_dimension(DimensionContext.NETHER, arrival)
	assert_eq(player.global_position, arrival, "player moved to the arrival point")
	assert_eq(player.velocity, Vector3.ZERO, "velocity zeroed so no momentum carries through")
	assert_eq(
		_cm._initial_load_center,
		Vector2i(12, -5),
		"the streaming centre follows the player, including negative Z"
	)
	player.queue_free()


# --- Placeholder Nether generation ---


func test_nether_generation_differs_from_the_overworld_at_the_same_coord() -> void:
	# Batch 1 acceptance: identical chunk coordinates in the two
	# dimensions must not produce identical bytes.
	var overworld: Chunk = DimensionContext.provider(DimensionContext.OVERWORLD).generate_chunk(
		0, 0
	)
	var nether: Chunk = DimensionContext.provider(DimensionContext.NETHER).generate_chunk(0, 0)
	assert_ne(nether.blocks, overworld.blocks, "the same coordinate generates different terrain")


func test_nether_terrain_is_deterministic_and_sealed() -> void:
	var a: Chunk = DimensionContext.provider(DimensionContext.NETHER).generate_chunk(3, -7)
	var b: Chunk = DimensionContext.provider(DimensionContext.NETHER).generate_chunk(3, -7)
	assert_eq(a.blocks, b.blocks, "repeat generation is byte-identical")
	# Bedrock shell top and bottom, so a player arriving by portal cannot
	# fall out of the world. Batch 3 replaced the placeholder shell with
	# the real kj.java terrain, which seals the same two layers.
	assert_eq(a.get_block(0, 0, 0), Blocks.BEDROCK, "bedrock floor")
	assert_eq(a.get_block(0, Chunk.SIZE_Y - 1, 0), Blocks.BEDROCK, "bedrock ceiling")


func test_nether_terrain_varies_between_chunks() -> void:
	var a: Chunk = DimensionContext.provider(DimensionContext.NETHER).generate_chunk(0, 0)
	var b: Chunk = DimensionContext.provider(DimensionContext.NETHER).generate_chunk(1, 0)
	assert_ne(a.blocks, b.blocks, "neighbouring chunks are not byte-identical")
