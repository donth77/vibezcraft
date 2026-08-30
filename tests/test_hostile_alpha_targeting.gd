extends GutTest

# Alpha EntityMonster target acquisition is local to each entity: ordinary
# hostiles acquire a visible player within 16 blocks, while Spider keeps the
# same radius and darkness gate but deliberately omits the sight test.

var _main: Node = null
var _player: Node3D = null
var _parent: Node = null


class SightWorld:
	extends Node

	var blocks: Dictionary = {}
	var block_reads: int = 0

	func get_world_block(pos: Vector3i) -> int:
		block_reads += 1
		return int(blocks.get(pos, Blocks.AIR))


class DamagePlayer:
	extends Node3D

	var hits: int = 0

	func take_damage(_amount: int, _source: String, _knockback: Vector3) -> void:
		hits += 1


func before_each() -> void:
	_main = Node.new()
	_main.name = "Main"
	get_tree().root.add_child(_main)
	_player = DamagePlayer.new()
	_player.name = "Player"
	_main.add_child(_player)
	_parent = Node.new()
	add_child_autofree(_parent)


func after_each() -> void:
	if is_instance_valid(_main):
		_main.free()


func _mob(name: String, pos: Vector3) -> Node3D:
	var mob: Node3D = MobRegistry.script_for(name).new() as Node3D
	_parent.add_child(mob)
	mob.global_position = pos
	return mob


func test_pack_spiders_acquire_independently_at_sixteen_blocks() -> void:
	_player.global_position = Vector3.ZERO
	var near_spider: Node3D = _mob("spider", Vector3(15.9, 0.0, 0.0))
	var far_spider: Node3D = _mob("spider", Vector3(16.1, 0.0, 0.0))
	assert_eq(near_spider.call("_find_player"), _player, "this spider noticed the player")
	assert_null(far_spider.call("_find_player"), "its pack-mate remains unaware")
	assert_eq(near_spider.get("_ai_player_cache"), _player, "target state belongs to one spider")
	assert_null(far_spider.get("_ai_player_cache"), "there is no shared pack aggro")


func test_every_overworld_hostile_uses_sixteen_for_initial_acquisition() -> void:
	_player.global_position = Vector3.ZERO
	for mob_name: String in ["zombie", "skeleton", "creeper", "spider"]:
		var inside: Node3D = _mob(mob_name, Vector3(15.9, 0.0, 0.0))
		assert_eq(inside.call("_find_player"), _player, "%s acquires inside 16" % mob_name)
		var boundary: Node3D = _mob(mob_name, Vector3(16.0, 0.0, 0.0))
		assert_null(boundary.call("_find_player"), "%s uses Alpha's strict radius" % mob_name)
		var outside: Node3D = _mob(mob_name, Vector3(16.1, 0.0, 0.0))
		assert_null(outside.call("_find_player"), "%s ignores a new target outside 16" % mob_name)


func test_acquired_targets_are_retained_beyond_forty_blocks() -> void:
	for mob_name: String in ["zombie", "skeleton", "creeper", "spider"]:
		_player.global_position = Vector3.ZERO
		var mob: Node3D = _mob(mob_name, Vector3(1.0, 0.0, 0.0))
		assert_eq(mob.call("_find_player"), _player, "%s acquires nearby" % mob_name)
		_player.global_position = Vector3(80.0, 0.0, 0.0)
		mob.call("_ai_tick")
		assert_eq(
			mob.get("_ai_player_cache"),
			_player,
			"%s keeps fc.g until the living target is invalid" % mob_name
		)


func test_landed_player_hit_assigns_the_attacker_without_a_search() -> void:
	_player.global_position = Vector3(80.0, 0.0, 0.0)
	for mob_name: String in ["zombie", "skeleton", "creeper", "spider"]:
		var mob: Node3D = _mob(mob_name, Vector3.ZERO)
		assert_true(
			bool(mob.call("take_damage", 1, Vector3.ZERO, 0.0, _player)),
			"%s accepts the landed hit" % mob_name
		)
		assert_eq(
			mob.get("_ai_player_cache"),
			_player,
			"%s assigns ef.g directly instead of searching 16 blocks" % mob_name
		)


func test_alpha_melee_and_relative_movement_constants() -> void:
	assert_eq(Zombie._AI_MELEE_RANGE, 2.5)
	assert_eq(Zombie._AI_MELEE_DAMAGE, 5, "nt.<init> sets f = 5")
	assert_eq(Zombie._AI_MELEE_COOLDOWN_SEC, 1.0, "ef writes P = 20 ticks")
	assert_eq(Skeleton._AI_WALK_SPEED, Zombie._AI_WALK_SPEED * 1.4)
	assert_eq(Creeper._AI_WALK_SPEED, Zombie._AI_WALK_SPEED * 1.4)


func test_skeleton_drop_and_projectile_constants_match_alpha() -> void:
	var skeleton: Node3D = _mob("skeleton", Vector3.ZERO)
	assert_eq(skeleton.get("drop_item_id"), Items.ARROW, "dh.g_ returns dx.j")
	assert_eq(skeleton.get("drop_count_min"), 0)
	assert_eq(skeleton.get("drop_count_max"), 2)
	assert_eq(Skeleton._AI_ARROW_SPEED, 12.0, "0.6 blocks/tick at 20 TPS")
	assert_eq(Skeleton._AI_ARROW_INACCURACY, 0.09, "0.0075 * dh's spread 12")
	assert_eq(Skeleton._AI_ARROW_GRAVITY_PER_TICK, 0.03, "lv tick gravity")
	assert_eq(Skeleton._AI_ARROW_DAMAGE, 4, "lv applies fixed four damage")


func test_distance_gated_mob_can_wake_when_player_returns() -> void:
	_player.global_position = Vector3.ZERO
	var zombie: Node3D = _mob("zombie", Vector3(100.0, 0.0, 0.0))
	assert_true(zombie.call("_update_distance_lod"), "far mob gates expensive work")
	assert_true(bool(zombie.get("_physics_gated")))
	assert_false(zombie.visible)
	assert_eq(zombie.process_mode, Node.PROCESS_MODE_DISABLED, "gated mob has zero tick cost")
	var spawner: Node = load("res://scripts/world/natural_mob_spawner.gd").new()
	_parent.add_child(spawner)
	spawner.set_process(false)
	_player.global_position = Vector3(100.0, 0.0, 0.0)
	spawner.call("_process", 0.24)
	assert_true(bool(zombie.get("_physics_gated")), "shared sweep has not reached 250 ms")
	spawner.call("_process", 0.011)
	assert_false(bool(zombie.get("_physics_gated")), "shared 4 Hz sweep wakes returning mob")
	assert_true(zombie.visible)
	assert_eq(zombie.process_mode, Node.PROCESS_MODE_INHERIT)


func test_mid_and_far_hostile_chases_use_one_direct_waypoint() -> void:
	_player.global_position = Vector3(9.8, 65.2, -3.1)
	var world := SightWorld.new()
	_parent.add_child(world)
	var expected := Vector3i(9, 65, -4)
	for mob_name: String in ["zombie", "creeper", "spider", "zombie_pigman"]:
		var mob: Node3D = _mob(mob_name, Vector3.ZERO)
		mob.set("_chunk_manager", world)
		for tier: int in [MobBase.LOD_MID, MobBase.LOD_FAR]:
			mob.set("_lod_tier", tier)
			mob.call("_repath_toward", _player)
			assert_eq(mob.get("_ai_path"), [expected], "%s tier %d skips A*" % [mob_name, tier])
			assert_false(bool(mob.get("_ai_path_failed")))
	var skeleton: Node3D = _mob("skeleton", Vector3.ZERO)
	skeleton.set("_chunk_manager", world)
	for tier: int in [MobBase.LOD_MID, MobBase.LOD_FAR]:
		skeleton.set("_lod_tier", tier)
		skeleton.call("_repath_to", _player.global_position)
		assert_eq(skeleton.get("_ai_path"), [expected], "skeleton keeps the same LOD policy")


func test_los_traces_are_reused_and_range_gated() -> void:
	_player.global_position = Vector3(0.0, 64.0, 0.0)
	var world := SightWorld.new()
	_parent.add_child(world)
	var skeleton: Node3D = _mob("skeleton", Vector3(8.0, 64.0, 0.0))
	skeleton.set("_chunk_manager", world)
	assert_true(skeleton.call("has_line_of_sight", _player))
	var one_trace_reads: int = world.block_reads
	assert_gt(one_trace_reads, 0)
	world.block_reads = 0
	skeleton.set("_ai_player_cache", null)
	skeleton.set("_ai_shot_cooldown_sec", 1.0)
	skeleton.call("_ai_tick")
	assert_eq(world.block_reads, one_trace_reads, "acquire + aim reuse one LOS result")

	# Retained targets outside each attack hook's range need no visibility
	# result: cover cannot change the decision to pursue on this tick.
	skeleton.global_position = Vector3(12.0, 64.0, 0.0)
	skeleton.set("_lod_tier", MobBase.LOD_MID)
	world.block_reads = 0
	skeleton.call("_ai_tick")
	assert_eq(world.block_reads, 0, "skeleton pursuit outside 10 skips LOS")

	var creeper: Node3D = _mob("creeper", Vector3(8.0, 64.0, 0.0))
	creeper.set("_chunk_manager", world)
	creeper.set("_ai_player_cache", _player)
	creeper.set("_lod_tier", MobBase.LOD_MID)
	world.block_reads = 0
	creeper.call("_ai_tick")
	assert_eq(world.block_reads, 0, "creeper pursuit outside 7 skips LOS")

	var spider: Node3D = _mob("spider", Vector3(8.0, 64.0, 0.0))
	spider.set("_chunk_manager", world)
	spider.set("_lod_tier", MobBase.LOD_MID)
	world.block_reads = 0
	spider.call("_tick_chase", _player)
	assert_eq(world.block_reads, 0, "spider pursuit outside pounce range skips LOS")


func test_enclosed_player_is_not_visible_to_a_skeleton() -> void:
	_player.global_position = Vector3(0.0, 64.0, 0.0)
	var skeleton: Node3D = _mob("skeleton", Vector3(8.0, 64.0, 0.0))
	var world := SightWorld.new()
	_parent.add_child(world)
	# A floor-to-ceiling stone cave wall between both eye positions.
	for y: int in range(63, 68):
		world.blocks[Vector3i(1, y, 0)] = Blocks.STONE
	skeleton.set("_chunk_manager", world)
	assert_false(skeleton.call("has_line_of_sight", _player), "solid cave cover blocks sight")
	assert_null(skeleton.call("_find_player"), "a hidden player is not newly acquired")


func test_spider_can_notice_through_cover_but_cannot_attack_through_it() -> void:
	_player.global_position = Vector3(0.0, 64.0, 0.0)
	var spider: Node3D = _mob("spider", Vector3(2.0, 64.0, 0.0))
	var world := SightWorld.new()
	_parent.add_child(world)
	for y: int in range(63, 68):
		world.blocks[Vector3i(1, y, 0)] = Blocks.STONE
	spider.set("_chunk_manager", world)
	assert_eq(spider.call("_find_player"), _player, "be.c_() acquisition omits sight")
	spider.set("_ai_path_failed", true)  # keep this unit test out of full A*
	spider.call("_tick_chase", _player)
	assert_eq((_player as DamagePlayer).hits, 0, "EntityCreature gates the attack hook on sight")


func test_skeleton_with_retained_target_does_not_aim_or_fire_through_cover() -> void:
	_player.global_position = Vector3(0.0, 64.0, 0.0)
	var skeleton: Node3D = _mob("skeleton", Vector3(8.0, 64.0, 0.0))
	var world := SightWorld.new()
	_parent.add_child(world)
	for y: int in range(63, 68):
		world.blocks[Vector3i(1, y, 0)] = Blocks.STONE
	skeleton.set("_chunk_manager", world)
	skeleton.set("_ai_player_cache", _player)  # acquired before entering cover
	skeleton.set("_ai_shot_cooldown_sec", 0.0)  # otherwise ready to fire now
	skeleton.set("_ai_aiming", true)
	# MID avoids invoking full A* against the deliberately tiny fake world;
	# the retained target should still produce a pursuit waypoint.
	skeleton.set("_lod_tier", MobBase.LOD_MID)
	var main_children_before: int = _main.get_child_count()
	skeleton.call("_ai_tick")
	assert_false(bool(skeleton.get("_ai_aiming")), "cover lowers the bow")
	assert_eq(
		float(skeleton.get("_ai_shot_cooldown_sec")),
		0.0,
		"cover leaves the source cooldown ready without releasing a shot"
	)
	assert_eq(_main.get_child_count(), main_children_before, "no Arrow was released")
	assert_false((skeleton.get("_ai_path") as Array).is_empty(), "it pursues instead of firing")


func test_pigman_cannot_reacquire_or_melee_through_cover() -> void:
	_player.global_position = Vector3(0.0, 64.0, 0.0)
	var pigman: Node3D = _mob("zombie_pigman", Vector3(2.0, 64.0, 0.0))
	var world := SightWorld.new()
	_parent.add_child(world)
	for y: int in range(63, 68):
		world.blocks[Vector3i(1, y, 0)] = Blocks.STONE
	pigman.set("_chunk_manager", world)
	pigman.set("anger", 500)
	pigman.set("_ai_player_cache", _player)
	assert_null(pigman.call("_find_target"), "ef.c_ sight-gates fresh angry acquisition")
	# A target assigned before entering cover is retained, but fc.b_ does not
	# invoke the melee hook until sight is restored.
	pigman.set("_ai_target", _player)
	pigman.set("_ai_path_failed", true)
	var hits_before: int = (_player as DamagePlayer).hits
	pigman.call("_ai_tick")
	assert_eq((_player as DamagePlayer).hits, hits_before, "pigman cannot punch through stone")


func test_visible_skeleton_fires_then_starts_alpha_cooldown() -> void:
	_player.global_position = Vector3(0.0, 64.0, 0.0)
	var skeleton: Node3D = _mob("skeleton", Vector3(8.0, 64.0, 0.0))
	var world := SightWorld.new()
	_parent.add_child(world)
	skeleton.set("_chunk_manager", world)
	var main_children_before: int = _main.get_child_count()
	skeleton.call("_ai_tick")
	assert_eq(_main.get_child_count(), main_children_before + 1, "attackTime zero fires now")
	assert_eq(
		float(skeleton.get("_ai_shot_cooldown_sec")),
		1.5,
		"dh.java sets attackTime to 30 ticks after firing"
	)
	var arrow: Node = _main.get_child(_main.get_child_count() - 1)
	assert_eq(int(arrow.get("_fixed_damage")), 4, "skeleton arrow carries Alpha fixed damage")
	assert_eq(float(arrow.get("_gravity_per_tick")), 0.03, "skeleton arrow carries lv gravity")
