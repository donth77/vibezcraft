extends GutTest

# Natural hostile spawning regression tests against Alpha 1.2.6 bg.java.
# The live spawner still samples a player-centred ring for performance, but
# the candidate group itself must preserve the source's exact 3×4 walk.

const _SPAWNER_SCRIPT: GDScript = preload("res://scripts/world/natural_mob_spawner.gd")

var _parent: Node = null
var _dimension_was: int = 0


class SpawnWorld:
	extends Node

	var has_floor: bool = false
	var queries: Array[Vector3i] = []

	func get_chunk_at_coord(_coord: Vector2i) -> Variant:
		return true

	func get_world_block(pos: Vector3i) -> int:
		queries.append(pos)
		if has_floor and pos.y == 63:
			return Blocks.STONE
		return Blocks.AIR

	func get_world_effective_light(_pos: Vector3i) -> int:
		return 0


func before_each() -> void:
	_dimension_was = DimensionContext.active()
	DimensionContext.set_active(0)
	_parent = Node.new()
	add_child_autofree(_parent)


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)


func _spawner() -> Node:
	var node: Node = _SPAWNER_SCRIPT.new()
	_parent.add_child(node)
	return node


func _player_at(pos: Vector3) -> Node3D:
	var player := Node3D.new()
	_parent.add_child(player)
	player.global_position = pos
	return player


func test_pack_walk_is_three_resets_of_four_cumulative_steps() -> void:
	var spawner: Node = _spawner()
	var world := SpawnWorld.new()
	_parent.add_child(world)
	var player: Node3D = _player_at(Vector3.ZERO)
	var jitters: Array[Vector3i] = []
	for _i: int in range(12):
		jitters.append(Vector3i(1, 0, 0))
	spawner.call(
		"_spawn_group_from_origin",
		world,
		player,
		MobRegistry.script_for("spider"),
		Vector3i(64, 64, 0),
		jitters
	)
	var got: Array[Vector3i] = []
	for pos: Vector3i in world.queries:
		if pos.y == 65:
			got.append(pos)
	var expected: Array[Vector3i] = []
	for _outer: int in range(3):
		for x: int in range(65, 69):
			expected.append(Vector3i(x, 65, 0))
	assert_eq(got, expected, "each four-step walk resets to the group origin")


func test_failed_group_checks_all_twelve_candidates_without_a_seed_spawn() -> void:
	var spawner: Node = _spawner()
	var world := SpawnWorld.new()
	_parent.add_child(world)
	var player: Node3D = _player_at(Vector3(0.0, 64.0, 0.0))
	var spawned: int = int(
		spawner.call(
			"_spawn_group_from_origin",
			world,
			player,
			MobRegistry.script_for("spider"),
			Vector3i(64, 64, 0)
		)
	)
	assert_eq(spawned, 0, "an AIR origin is not a guaranteed seed spawn")
	var head_checks: int = 0
	var floor_checks: int = 0
	for pos: Vector3i in world.queries:
		if pos.y == 65:
			head_checks += 1
		elif pos.y == 63:
			floor_checks += 1
	assert_eq(head_checks, 12, "three outer passes times four candidate checks")
	assert_eq(floor_checks, 12, "every candidate independently validates its floor")


func test_open_group_stops_at_spiders_inherited_four_mob_cap() -> void:
	var spawner: Node = _spawner()
	var world := SpawnWorld.new()
	world.has_floor = true
	_parent.add_child(world)
	var player: Node3D = _player_at(Vector3(0.0, 64.0, 0.0))
	# Keep each 1.4-wide spider two cells from the previous one so the
	# source-faithful entity-overlap predicate permits all four.
	var jitters: Array[Vector3i] = []
	for _i: int in range(12):
		jitters.append(Vector3i(2, 0, 0))
	var spawned: int = int(
		spawner.call(
			"_spawn_group_from_origin",
			world,
			player,
			MobRegistry.script_for("spider"),
			Vector3i(64, 64, 0),
			jitters
		)
	)
	assert_eq(spawned, 4, "be.java inherits hf.i() = 4")
	assert_eq(world.get_child_count(), 4, "the other eight attempts never instantiate mobs")


func test_repeated_candidate_rejects_entity_overlap_instead_of_stacking_a_pack() -> void:
	var spawner: Node = _spawner()
	var world := SpawnWorld.new()
	world.has_floor = true
	_parent.add_child(world)
	var player: Node3D = _player_at(Vector3(0.0, 64.0, 0.0))
	var zero_jitters: Array[Vector3i] = []
	for _i: int in range(12):
		zero_jitters.append(Vector3i.ZERO)
	var spawned: int = int(
		spawner.call(
			"_spawn_group_from_origin",
			world,
			player,
			MobRegistry.script_for("spider"),
			Vector3i(64, 64, 0),
			zero_jitters
		)
	)
	assert_eq(spawned, 1, "hf.a() rejects the other eleven intersecting candidates")
	assert_eq(world.get_child_count(), 1, "only one spider occupies the candidate AABB")
