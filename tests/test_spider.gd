extends GutTest

# Spider mob smoke test — asserts registration, drop config, and BB
# dimensions match the vanilla `be.java` numbers our impl claims to
# clone. AI behavior (light gate, pounce, melee) needs a live world
# to test meaningfully, so we just verify the configuration plumbing
# here.

var _parent: Node = null


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
	# Vanilla eye height = 0.9 × 0.75 − 0.5 = 0.175 — used for drowning.
	assert_almost_eq(spider.call("_get_eye_height"), 0.175, 0.001)


# HP — vanilla EntitySpider override sets aT = 16 (lower than the
# default 20 used by zombie). Bones drop only after the spider is
# killed, so the HP value gates the kill loop.
func test_max_health_is_16() -> void:
	var spider: Node = _instantiate_offscreen()
	assert_eq(spider.get("max_health"), 16)


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
