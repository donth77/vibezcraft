extends GutTest

# Spider mob smoke test — asserts registration, drop config, and BB
# dimensions match the vanilla `be.java` numbers our impl claims to
# clone. AI behavior (light gate, pounce, melee) needs a live world
# to test meaningfully, so we just verify the configuration plumbing
# here.

var _parent: Node = null


class LightWorld:
	extends Node

	var level: int = 0
	var sampled_cell: Vector3i = Vector3i.ZERO

	func get_world_effective_light(pos: Vector3i) -> int:
		sampled_cell = pos
		return level


func before_each() -> void:
	_parent = Node.new()
	add_child_autofree(_parent)


# Mob registry must resolve "spider" to the spider.gd script so save/
# load round-trips (EntitySave's TYPE_MOB branch dispatches via name).
func test_registered_under_spider_name() -> void:
	var script: Script = MobRegistry.script_for("spider")
	assert_not_null(script, "MobRegistry missing 'spider' entry")
	assert_true(
		script.resource_path == "res://scripts/entities/spider.gd",
		"Spider registered to wrong path: %s" % script.resource_path
	)


# Drop config — vanilla be.java::g_() returns ItemString (Items.STRING
# in ours). 0-2 per kill matches the zombie/skeleton drop range.
func test_drop_config_string_0_to_2() -> void:
	var spider: Node = _instantiate_offscreen()
	assert_eq(spider.get("drop_item_id"), Items.STRING)
	assert_eq(spider.get("drop_count_min"), 0)
	assert_eq(spider.get("drop_count_max"), 2)


# BB dims — vanilla be.java::be(cy) calls setSize(1.4, 0.9). We use a
# BoxShape3D matching the vanilla AABB exactly (1.4 × 0.9 × 1.4) so
# arrows + sword swings register against the full body silhouette
# including the abdomen.
func test_bb_dims_match_vanilla() -> void:
	var spider: Node = _instantiate_offscreen()
	assert_eq(spider.call("_get_body_height"), 0.9, "BB height should be vanilla 0.9 m")
	assert_eq(spider.call("_get_body_width"), 1.4, "BB width should be vanilla 1.4 m")
	# EntityLiving.v() = height × 0.85. be.j() = 0.175 is the riding
	# offset and must not be reused for LOS.
	assert_almost_eq(spider.call("_get_eye_height"), 0.765, 0.001)


# HP — be.java has no override after ef.<init> sets J = 20.
func test_max_health_is_20() -> void:
	var spider: Node = _instantiate_offscreen()
	assert_eq(spider.get("max_health"), 20)


func test_alpha_combat_constants_and_speed_ratio() -> void:
	assert_eq(Spider._AI_MELEE_RANGE, 2.5, "ef.a attacks below 2.5 blocks")
	assert_eq(Spider._AI_MELEE_DAMAGE, 2, "spider inherits ef.f = 2")
	assert_eq(Spider._AI_MELEE_COOLDOWN_SEC, 1.0, "P = 20 ticks")
	assert_eq(Spider._AI_WALK_SPEED, Zombie._AI_WALK_SPEED * 1.6, "be.am 0.8 / nt.am 0.5")


func test_brightness_cutoff_uses_alpha_lut_and_body_sample_height() -> void:
	var spider: Node3D = _instantiate_offscreen() as Node3D
	var world := LightWorld.new()
	_parent.add_child(world)
	spider.global_position = Vector3(0.5, 10.3, 0.5)
	spider.set("_chunk_manager", world)
	world.level = 11
	assert_false(spider.call("_is_brightly_lit"), "LUT brightness 0.437 remains hostile")
	assert_eq(world.sampled_cell, Vector3i(0, 10, 0), "lw.a samples 66% up the AABB")
	world.level = 12
	assert_true(spider.call("_is_brightly_lit"), "LUT brightness 0.525 is daytime-bright")


func test_alpha_spider_has_no_beta_wall_climb_hook() -> void:
	var src: String = FileAccess.get_file_as_string("res://scripts/entities/spider.gd")
	assert_eq(src.find("_CLIMB_SPEED"), -1, "be.java predates wall climbing")


func test_damage_assigns_the_actual_attacker_without_a_revenge_timer() -> void:
	var spider: Node = _instantiate_offscreen()
	var attacker := Node3D.new()
	_parent.add_child(attacker)
	assert_true(spider.call("take_damage", 1, Vector3.ZERO, 0.0, attacker))
	assert_eq(spider.get("_ai_player_cache"), attacker, "ef assigns fc.g directly")
	var src: String = FileAccess.get_file_as_string("res://scripts/entities/spider.gd")
	assert_eq(src.find("_AI_REVENGE_DURATION_SEC"), -1, "Alpha has no timed revenge exemption")


# Spider extends MobBase — needed for take_damage / die() / drop
# hooks to work. Check via the parent script chain.
func test_extends_mob_base() -> void:
	var script: Script = MobRegistry.script_for("spider")
	var base: Script = script.get_base_script()
	assert_not_null(base, "spider.gd should have a base script")
	assert_true(
		base.resource_path == "res://scripts/entities/mob_base.gd",
		"spider.gd should extend MobBase, got: %s" % base.resource_path
	)


# Spider is in the natural hostile spawn pool alongside zombie/skeleton.
# Verifies the test pool match between MobRegistry and the spawner.
func test_is_in_natural_hostile_pool() -> void:
	# Indirect check — read the spawner script and confirm "spider" in
	# the pool literal. Avoids instantiating the spawner (which needs a
	# live ChunkManager).
	var src: String = FileAccess.get_file_as_string("res://scripts/world/natural_mob_spawner.gd")
	assert_true(
		src.find('"spider"') != -1,
		'natural_mob_spawner.gd should reference "spider" in its hostile pool'
	)


# Helper — instantiate a spider into the throwaway parent so _ready
# fires (drop_item_id is set in _ready). MobBase queries _chunk_manager
# which is null off-tree; the instance is functional enough for getter
# assertions but should NOT be _physics_processed (would NRE on
# _is_in_water cell lookups).
func _instantiate_offscreen() -> Node:
	var script: Script = MobRegistry.script_for("spider")
	var instance: Node = script.new()
	_parent.add_child(instance)
	return instance
