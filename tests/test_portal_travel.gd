# gdlint: disable=max-public-methods
extends GutTest

# The dimension-travel transaction
# (docs/nether-alpha-1.2.6-implementation-plan.md §7.2, Batch 7).
#
# The acceptance criterion this file exists for is the last one in the
# batch: "Failure injection cannot duplicate the player, lose inventory,
# mix chunks, or strand a half-switched save." A transition that fails
# halfway is worse than one that refuses outright, because the save on
# disk then describes a world that does not exist.
#
# Uses a real ChunkManager with no player child, so _process early-returns
# and no streaming or worker job starts — the same pattern as
# tests/test_dimension_context.gd.

const ChunkManagerScript := preload("res://scripts/world/chunk_manager.gd")
const ChunkNodeScript := preload("res://scripts/world/chunk_node.gd")

# Throwaway save slot. The transaction genuinely persists the dimension it
# leaves, and an unqualified save resolves to Game.active_world — which is
# a real slot the player has played in. Redirect it first, every time.
const _WORLD := "test_portal_travel"

var _cm: Node3D
var _dimension_was: int
var _active_world_was: String


func before_each() -> void:
	_dimension_was = DimensionContext.active()
	_active_world_was = Game.active_world
	Game.active_world = _WORLD
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	PortalIndex.reset()
	TickScheduler.clear_all()
	_cm = ChunkManagerScript.new()
	add_child_autofree(_cm)


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)
	PortalIndex.reset()
	TickScheduler.clear_all()
	SaveLoad.clear_cache()
	SaveLoad.delete_world(_WORLD)
	Game.active_world = _active_world_was
	Game.is_loading = false


func _bind_chunk(coord: Vector2i) -> Chunk:
	var chunk := Chunk.new()
	var node: Node3D = ChunkNodeScript.new()
	node.chunk_data = chunk
	node.chunk = chunk
	_cm._chunks[coord] = node
	_cm.add_child(node)
	return chunk


# --- Direction and labels ---


func test_the_overworld_leads_to_the_nether_and_back() -> void:
	assert_eq(
		PortalTravel.destination_dimension(DimensionContext.OVERWORLD),
		DimensionContext.NETHER,
		"stepping in from the Overworld goes down"
	)
	assert_eq(
		PortalTravel.destination_dimension(DimensionContext.NETHER),
		DimensionContext.OVERWORLD,
		"and from the Nether, back up"
	)


func test_the_loading_labels_are_alphas_own() -> void:
	assert_eq(
		PortalTravel.label_for(DimensionContext.NETHER),
		"Entering the Nether",
		"the direction is part of the string"
	)
	assert_eq(
		PortalTravel.label_for(DimensionContext.OVERWORLD),
		"Leaving the Nether",
		"not a generic 'Loading'"
	)


# --- Failure injection ---


func test_an_unregistered_destination_leaves_the_world_untouched() -> void:
	_bind_chunk(Vector2i(0, 0))
	var before: int = DimensionContext.active()
	var ok: bool = _cm.transition_to_dimension(7, Vector3(0, 70, 0))
	assert_push_error("no provider for dimension 7")
	assert_false(ok, "there is no dimension 7")
	assert_eq(DimensionContext.active(), before, "so nothing switched")
	assert_true(_cm._chunks.has(Vector2i(0, 0)), "and the source scene is intact")


func test_a_refused_transition_does_not_leave_a_stranded_save() -> void:
	# The half-switched case the plan names: a save whose player.bin says
	# Nether while the region files say Overworld. A refusal must write
	# neither.
	_bind_chunk(Vector2i(0, 0))
	_cm.transition_to_dimension(7, Vector3(0, 70, 0))
	assert_push_error("no provider for dimension 7")
	assert_eq(
		DimensionContext.active(), DimensionContext.OVERWORLD, "still in the source dimension"
	)
	assert_false(
		DirAccess.dir_exists_absolute(SaveLoad.dimension_dir(_WORLD, DimensionContext.NETHER)),
		"no destination directory was created"
	)


func test_a_reentrant_transition_is_refused() -> void:
	# A second trip starting while one is mid-flight would free the scene
	# the first is rebuilding.
	_cm._in_dimension_transition = true
	assert_false(
		_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(0, 70, 0)), "the guard holds"
	)
	_cm._in_dimension_transition = false


func test_travel_refuses_without_a_player_or_manager() -> void:
	var orphan := Node3D.new()
	autofree(orphan)
	assert_false(await PortalTravel.travel(null, _cm), "no player, no trip")
	assert_false(await PortalTravel.travel(orphan, null), "no manager, no trip")
	assert_false(PortalTravel.in_progress(), "and the guard is not left latched")


# --- Chunk isolation ---


func test_chunks_do_not_survive_the_switch() -> void:
	# "Failure injection cannot ... mix chunks." The stronger statement is
	# that a SUCCESSFUL switch does not mix them either.
	var chunk: Chunk = _bind_chunk(Vector2i(0, 0))
	chunk.set_block(0, 70, 0, Blocks.GRASS)
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	assert_false(
		_cm._chunks.has(Vector2i(0, 0)), "the Overworld chunk is gone from the resident set"
	)
	assert_eq(DimensionContext.active(), DimensionContext.NETHER, "and we are in the Nether")


func test_the_epoch_advances_so_inflight_work_is_rejectable() -> void:
	var before: int = DimensionContext.epoch()
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(8, 80, 8))
	assert_gt(DimensionContext.epoch(), before, "the epoch moved")
	assert_false(
		DimensionContext.accepts_result(DimensionContext.OVERWORLD, before),
		"so a job dispatched before the switch is refused"
	)


# --- The portal index across a switch ---


func test_each_dimensions_portal_hints_survive_a_round_trip() -> void:
	PortalIndex.record(DimensionContext.OVERWORLD, Vector3i(100, 70, 100))
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(12, 80, 12))
	PortalIndex.record(DimensionContext.NETHER, Vector3i(12, 80, 12))
	assert_eq(PortalIndex.count(DimensionContext.NETHER), 1, "the Nether has its portal")
	_cm.transition_to_dimension(DimensionContext.OVERWORLD, Vector3(96, 70, 96))
	assert_eq(
		PortalIndex.count(DimensionContext.OVERWORLD),
		1,
		"and coming back, the Overworld's is still on file"
	)
	assert_has(
		PortalIndex.entries(DimensionContext.OVERWORLD),
		Vector3i(100, 70, 100),
		"the same portal it started with"
	)


func test_the_index_does_not_leak_across_dimensions_on_a_switch() -> void:
	PortalIndex.record(DimensionContext.OVERWORLD, Vector3i(100, 70, 100))
	_cm.transition_to_dimension(DimensionContext.NETHER, Vector3(12, 80, 12))
	assert_eq(
		PortalIndex.count(DimensionContext.NETHER), 0, "an Overworld portal is not a Nether portal"
	)


# --- Y safety ---


func test_a_low_overworld_arrival_is_lifted_out_of_the_bedrock_floor() -> void:
	# Y is NOT scaled between dimensions, so a player at Overworld Y 5
	# maps to Nether Y 5 — inside the bedrock. The interim position handed
	# to the streamer has to be somewhere survivable.
	var landing: Vector3 = PortalTravel._safe_landing(Vector3(10.0, 5.0, 10.0))
	assert_gte(
		landing.y, float(NetherTeleporter.FALLBACK_MIN_Y), "lifted to at least the fallback floor"
	)
	assert_eq(landing.x, 10.0, "without moving horizontally")
	assert_eq(landing.z, 10.0, "on either axis")


func test_a_high_arrival_is_brought_under_the_nether_roof() -> void:
	var landing: Vector3 = PortalTravel._safe_landing(Vector3(0.0, 127.0, 0.0))
	assert_lte(landing.y, 120.0, "below the roof")


func test_a_normal_arrival_height_is_left_alone() -> void:
	assert_eq(PortalTravel._safe_landing(Vector3(0.0, 90.0, 0.0)).y, 90.0, "no clamping needed")


# --- Coordinate round trip through the real transaction ---


func test_a_round_trip_returns_to_the_same_overworld_region() -> void:
	# 8:1 is lossy by design — the return trip lands in the same 8-block
	# cell it left, not the same block. What must NOT happen is drifting
	# further every trip, which is what an off-by-one in the scaling would
	# look like after four or five journeys.
	var start := Vector3(1000.0, 70.0, -1000.0)
	var here: Vector3 = start
	for _trip: int in range(6):
		var down: Vector3 = NetherTeleporter.scale_position(
			here, DimensionContext.OVERWORLD, DimensionContext.NETHER
		)
		here = NetherTeleporter.scale_position(
			down, DimensionContext.NETHER, DimensionContext.OVERWORLD
		)
	assert_lte(absf(here.x - start.x), 8.0, "six round trips drift at most one Nether cell on X")
	assert_lte(absf(here.z - start.z), 8.0, "and at most one on Z")
