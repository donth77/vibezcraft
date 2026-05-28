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
