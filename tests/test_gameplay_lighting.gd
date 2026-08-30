extends GutTest

# Gameplay consumers must all use ChunkManager's centralized effective-light
# contract. These fakes deliberately omit raw sky/block accessors so a caller
# regressing to an ad-hoc channel calculation fails immediately.

const NATURAL_SPAWNER_SCRIPT: GDScript = preload("res://scripts/world/natural_mob_spawner.gd")


class FakeLightManager:
	extends Node
	var effective_light: int = 0
	var sky_exposed: bool = true
	var cells: Dictionary = {}
	var loaded_chunk := Chunk.new()

	func get_chunk_at_coord(_coord: Vector2i) -> Chunk:
		return loaded_chunk

	func get_world_block(pos: Vector3i) -> int:
		return cells.get(pos, Blocks.AIR)

	func get_world_effective_light(_pos: Vector3i, _sky_subtraction: int = -1) -> int:
		return effective_light

	func is_sky_exposed_at_world(_pos: Vector3i) -> bool:
		return sky_exposed


var _manager: FakeLightManager


func before_each() -> void:
	_manager = FakeLightManager.new()
	add_child_autofree(_manager)


func test_hostile_spawn_accepts_seven_and_rejects_eight() -> void:
	var pos := Vector3i(0, 64, 0)
	_manager.cells[pos + Vector3i(0, -1, 0)] = Blocks.STONE
	var spawner: Node = NATURAL_SPAWNER_SCRIPT.new()
	_manager.effective_light = 7
	assert_true(spawner.call("_is_valid_hostile_spawn_cell", _manager, pos))
	_manager.effective_light = 8
	assert_false(spawner.call("_is_valid_hostile_spawn_cell", _manager, pos))
	spawner.free()


func test_passive_spawn_accepts_nine_and_rejects_eight() -> void:
	var pos := Vector3i(0, 64, 0)
	_manager.cells[pos + Vector3i(0, -1, 0)] = Blocks.GRASS
	var player := Node3D.new()
	add_child_autofree(player)
	player.global_position = Vector3(100.0, 64.0, 100.0)
	var spawner := PassiveSpawner.new()
	_manager.effective_light = 9
	assert_true(spawner.call("_can_spawn_at", _manager, player, pos.x, pos.y, pos.z))
	_manager.effective_light = 8
	assert_false(spawner.call("_can_spawn_at", _manager, player, pos.x, pos.y, pos.z))


func test_spider_brightness_uses_alpha_lut_threshold() -> void:
	var spider: Node = MobRegistry.script_for("spider").new()
	add_child_autofree(spider)
	spider.set("_chunk_manager", _manager)
	# Alpha compares the brightness LUT against 0.5: level 11 maps to
	# 0.437 and level 12 to 0.525, so 12 is the first bright level.
	_manager.effective_light = 11
	assert_false(spider.call("_is_brightly_lit"))
	_manager.effective_light = 12
	assert_true(spider.call("_is_brightly_lit"))


func test_daylight_burn_requires_brightness_and_direct_sky() -> void:
	for mob_name: String in ["zombie", "skeleton"]:
		var mob: Node = MobRegistry.script_for(mob_name).new()
		add_child_autofree(mob)
		mob.set("_chunk_manager", _manager)
		_manager.sky_exposed = true
		_manager.effective_light = 11
		mob.call("_check_daylight_burn")
		assert_eq(
			mob.get("_on_fire_ticks"), 0, "%s should not burn below brightness 0.5" % mob_name
		)
		_manager.effective_light = 12
		mob.call("_check_daylight_burn")
		assert_gt(mob.get("_on_fire_ticks"), 0, "%s should burn in bright direct sky" % mob_name)
		mob.set("_on_fire_ticks", 0)
		_manager.sky_exposed = false
		_manager.effective_light = 15
		mob.call("_check_daylight_burn")
		assert_eq(mob.get("_on_fire_ticks"), 0, "%s should not burn under cover" % mob_name)
