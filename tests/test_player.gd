# gdlint: disable=max-public-methods
extends GutTest

const _PLAYER_SCENE := preload("res://scenes/player/player.tscn")


func test_input_actions_register() -> void:
	InputActions.register_defaults()
	for action: String in [
		"move_forward", "move_back", "move_left", "move_right", "jump", "sneak", "pause"
	]:
		assert_true(InputMap.has_action(action), "%s registered" % action)


func test_player_scene_instantiates_as_character_body() -> void:
	var packed: PackedScene = _PLAYER_SCENE
	assert_not_null(packed, "player.tscn loads")
	var inst: Node = packed.instantiate()
	assert_not_null(inst, "player instantiates")
	assert_true(inst is CharacterBody3D, "player is CharacterBody3D")
	assert_not_null(inst.get_node_or_null("Camera3D"), "player has Camera3D child")
	assert_not_null(inst.get_node_or_null("CollisionShape3D"), "player has CollisionShape3D child")
	inst.queue_free()


func test_chunk_scene_instantiates() -> void:
	var packed: PackedScene = load("res://scenes/world/chunk.tscn") as PackedScene
	assert_not_null(packed, "chunk.tscn loads")
	var inst: Node = packed.instantiate()
	assert_not_null(inst, "chunk instantiates")
	inst.queue_free()


# Procedural fake ChunkManager for the spawn-scan tests. One designated
# dry-land column (grass on top of stone); every other column is ocean
# (stone seabed at y=50, water 51..63, air above). land_x = -1 makes the
# whole chunk ocean.
class FakeSpawnCM:
	extends Node
	var land_x: int = -1
	var land_z: int = -1
	var land_top: int = 70
	var _seabed_y: int = 50
	var _sea_level: int = 64

	func get_world_block(p: Vector3i) -> int:
		if p.x == land_x and p.z == land_z:
			if p.y < land_top:
				return Blocks.STONE
			if p.y == land_top:
				return Blocks.GRASS
			return Blocks.AIR
		if p.y <= _seabed_y:
			return Blocks.STONE
		if p.y < _sea_level:
			return Blocks.WATER_STILL
		return Blocks.AIR


class FakeFloorCM:
	extends Node
	var cells: Dictionary = {}
	var loaded: bool = true
	var read_count: int = 0

	func get_world_block(pos: Vector3i) -> int:
		read_count += 1
		return cells.get(pos, Blocks.AIR)

	func is_chunk_loaded(_coord: Vector2i) -> bool:
		return loaded


func _make_player() -> CharacterBody3D:
	# Instantiate WITHOUT adding to the tree so _ready (which builds the
	# model, FP hand, etc.) doesn't fire — we only exercise the pure spawn
	# helpers here.
	return _PLAYER_SCENE.instantiate() as CharacterBody3D


func test_real_surface_y_reads_actual_terrain() -> void:
	var player := _make_player()
	var cm := FakeSpawnCM.new()
	cm.land_x = 3
	cm.land_z = 5
	# Land column tops at its grass block; ocean columns top at the seabed.
	assert_eq(player._real_surface_y(cm, 3, 5), 70, "land column surface = grass y")
	assert_eq(player._real_surface_y(cm, 0, 0), 50, "ocean column surface = seabed y")
	cm.free()
	player.free()


func test_find_safe_spawn_picks_dry_land_column() -> void:
	var player := _make_player()
	var cm := FakeSpawnCM.new()
	cm.land_x = 3
	cm.land_z = 5
	# Scan order is x-outer/z-inner; the lone land column with 2 air cells
	# of head clearance should win over every ocean column.
	var cell: Vector3i = player._find_safe_spawn_in_chunk(cm)
	assert_eq(cell, Vector3i(3, 70, 5), "picks the dry-land column at its surface y")
	cm.free()
	player.free()


func test_find_safe_spawn_falls_back_to_ocean() -> void:
	var player := _make_player()
	var cm := FakeSpawnCM.new()  # land_x stays -1: entire chunk is ocean
	var cell: Vector3i = player._find_safe_spawn_in_chunk(cm)
	assert_lt(cell.y, Worldgen.SEA_LEVEL, "all-ocean chunk yields a sub-sea-level pick")
	cm.free()
	player.free()


func test_find_safe_spawn_accepts_high_land_with_clearance() -> void:
	# A 3D peak well above the old fixed Y=100 spawn must still be picked
	# (and at its real surface y), not skipped.
	var player := _make_player()
	var cm := FakeSpawnCM.new()
	cm.land_x = 3
	cm.land_z = 5
	cm.land_top = 124  # grass at 124; 125/126 read AIR → has head clearance
	var cell: Vector3i = player._find_safe_spawn_in_chunk(cm)
	assert_eq(cell, Vector3i(3, 124, 5), "high land column with clearance is accepted")
	player.free()
	cm.free()


# --- Downward full-cube floor safety net ---


func _guard_y(
	player: CharacterBody3D, cm: FakeFloorCM, from_position: Vector3, to_position: Vector3
) -> float:
	return player._crossed_full_cube_floor_center_y(cm, from_position, to_position)


func test_voxel_floor_guard_catches_world3_cave_floor_crossing() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	cm.cells[Vector3i(-131, 57, 19)] = Blocks.STONE
	var corrected: float = _guard_y(
		player, cm, Vector3(-130.4593, 58.905, 19.56569), Vector3(-130.4593, 57.70, 19.56569)
	)
	assert_almost_eq(corrected, 58.901, 0.0001, "rests capsule on the y=58 cave floor")
	cm.free()
	player.free()


func test_voxel_floor_guard_selects_highest_crossed_top() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	cm.cells[Vector3i(2, 54, 3)] = Blocks.STONE
	cm.cells[Vector3i(2, 56, 3)] = Blocks.DIRT
	var corrected: float = _guard_y(player, cm, Vector3(2.5, 58.2, 3.5), Vector3(2.5, 54.2, 3.5))
	assert_almost_eq(corrected, 57.901, 0.0001, "first crossed surface wins")
	cm.free()
	player.free()


func test_voxel_floor_guard_allows_mined_opening_until_next_floor() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	# The former y=57 floor was mined; only the block one metre lower remains.
	cm.cells[Vector3i(2, 56, 3)] = Blocks.STONE
	var first_step: float = _guard_y(player, cm, Vector3(2.5, 58.901, 3.5), Vector3(2.5, 58.6, 3.5))
	assert_true(is_nan(first_step), "does not recreate the mined y=57 block")
	var landing_step: float = _guard_y(player, cm, Vector3(2.5, 58.2, 3.5), Vector3(2.5, 57.7, 3.5))
	assert_almost_eq(landing_step, 57.901, 0.0001, "catches the next real floor")
	cm.free()
	player.free()


func test_voxel_floor_guard_does_not_promote_partial_blocks() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	for block_id: int in [Blocks.HALF_SLAB, Blocks.WOOD_STAIRS, Blocks.FENCE]:
		cm.cells[Vector3i(2, 57, 3)] = block_id
		var corrected: float = _guard_y(
			player, cm, Vector3(2.5, 58.905, 3.5), Vector3(2.5, 57.7, 3.5)
		)
		assert_true(is_nan(corrected), "block %d keeps bespoke collision" % block_id)
	cm.free()
	player.free()


func test_voxel_floor_guard_includes_nonopaque_full_collision_cubes() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	for block_id: int in [Blocks.GLASS, Blocks.LEAVES, Blocks.ICE, Blocks.MOB_SPAWNER]:
		cm.cells[Vector3i(2, 57, 3)] = block_id
		var corrected: float = _guard_y(
			player, cm, Vector3(2.5, 58.905, 3.5), Vector3(2.5, 57.7, 3.5)
		)
		assert_almost_eq(
			corrected, 58.901, 0.0001, "full-cube block %d remains protective" % block_id
		)
	cm.free()
	player.free()


func test_voxel_floor_guard_skips_unloaded_destination_chunk() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	cm.loaded = false
	cm.cells[Vector3i(2, 57, 3)] = Blocks.STONE
	var corrected: float = _guard_y(player, cm, Vector3(2.5, 58.905, 3.5), Vector3(2.5, 57.7, 3.5))
	assert_true(is_nan(corrected), "unloaded AIR fallback cannot synthesize a floor")
	cm.free()
	player.free()


func test_voxel_floor_guard_skips_upward_motion() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	cm.cells[Vector3i(2, 57, 3)] = Blocks.STONE
	var corrected: float = _guard_y(player, cm, Vector3(2.5, 57.7, 3.5), Vector3(2.5, 58.905, 3.5))
	assert_true(is_nan(corrected), "jumping upward is never corrected")
	cm.free()
	player.free()


func test_voxel_floor_guard_samples_destination_not_departed_ledge() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	cm.cells[Vector3i(0, 57, 0)] = Blocks.STONE
	var corrected: float = _guard_y(player, cm, Vector3(0.8, 58.905, 0.5), Vector3(1.2, 58.7, 0.5))
	assert_true(is_nan(corrected), "walking off a ledge remains a real fall")
	cm.free()
	player.free()


func test_voxel_floor_guard_checks_both_cells_at_exact_seam() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	cm.cells[Vector3i(0, 57, 0)] = Blocks.STONE
	var corrected: float = _guard_y(player, cm, Vector3(1.0, 58.905, 0.5), Vector3(1.0, 57.7, 0.5))
	assert_almost_eq(corrected, 58.901, 0.0001, "integer seam retains touching floor")
	cm.free()
	player.free()


func test_voxel_floor_guard_common_paths_do_zero_voxel_reads() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	var stationary: float = _guard_y(
		player, cm, Vector3(2.5, 58.901, 3.5), Vector3(2.6, 58.901, 3.6)
	)
	assert_true(is_nan(stationary))
	assert_eq(cm.read_count, 0, "ground/horizontal movement performs no voxel lookup")
	var between_planes: float = _guard_y(
		player, cm, Vector3(2.5, 61.4, 3.5), Vector3(2.5, 61.2, 3.5)
	)
	assert_true(is_nan(between_planes))
	assert_eq(cm.read_count, 0, "sub-metre falling between Y planes performs no voxel lookup")
	cm.free()
	player.free()


func test_voxel_floor_guard_read_count_is_strictly_bounded() -> void:
	var player := _make_player()
	var cm := FakeFloorCM.new()
	cm.cells[Vector3i(2, 57, 3)] = Blocks.STONE
	_guard_y(player, cm, Vector3(2.5, 58.905, 3.5), Vector3(2.5, 57.7, 3.5))
	assert_eq(cm.read_count, 1, "ordinary crossed floor resolves with one voxel read")

	cm.read_count = 0
	cm.cells.clear()
	_guard_y(player, cm, Vector3(1.0, 58.905, 1.0), Vector3(1.0, 58.7, 1.0))
	assert_eq(cm.read_count, 4, "exact X/Z seam has a four-read worst case")
	cm.free()
	player.free()


# --- Mob-hit knockback (vanilla hf.java parity) ---


func test_mob_hit_applies_knockback() -> void:
	var player: CharacterBody3D = _PLAYER_SCENE.instantiate()
	autofree(player)
	player.health = 20
	player.velocity = Vector3.ZERO
	# Attacker on the -X side → player shoved toward +X, plus an upward pop.
	player.take_damage(3, "mob", Vector3(1.0, 0.0, 0.0))
	assert_gt(player.velocity.x, 0.0, "knocked back along +X")
	assert_almost_eq(player.velocity.z, 0.0, 0.01, "no lateral drift on a pure-X hit")
	assert_gt(player.velocity.y, 0.0, "upward pop on hit")


func test_knockback_direction_is_away_from_attacker() -> void:
	var player: CharacterBody3D = _PLAYER_SCENE.instantiate()
	autofree(player)
	player.health = 20
	player.velocity = Vector3.ZERO
	# Attacker on the +Z side → player shoved toward -Z.
	player.take_damage(3, "mob", Vector3(0.0, 0.0, -1.0))
	assert_lt(player.velocity.z, 0.0, "pushed away from a +Z attacker")


func test_ambient_damage_has_no_knockback() -> void:
	var player: CharacterBody3D = _PLAYER_SCENE.instantiate()
	autofree(player)
	player.health = 20
	player.velocity = Vector3.ZERO
	# Drown / lava / fall etc. pass no direction — velocity must stay put.
	player.take_damage(1, "drown")
	assert_eq(player.velocity, Vector3.ZERO, "ambient damage does not knock back")
