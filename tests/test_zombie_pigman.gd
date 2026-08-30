# gdlint: disable=max-public-methods
extends GutTest

# Zombie pigman — vanilla `pt.java`
# (docs/nether-alpha-1.2.6-implementation-plan.md §8.1, Batch 8).
#
# The mob is defined by three things that are easy to get subtly wrong,
# and most of this file is about them:
#
#   1. NEUTRALITY. `c_()` returns null while `Anger == 0`, so a calm
#      pigman never acquires a target no matter how close the player is.
#   2. GROUP AGGRO with a BOX, not a sphere. `this.aG.b(32, 32, 32)`
#      grows the pigman's own bounding box 32 blocks on each axis, so a
#      pigman at the far corner IS alerted and one just past a face is
#      not. A radius check would get both cases wrong.
#   3. PERMANENT ANGER. Nothing in `pt.java` decrements `Anger`. The
#      modern 20-40 second forgiveness timer does not exist in Alpha, and
#      the anger survives a save/load as a short.

var _parent: Node = null


func before_each() -> void:
	_parent = Node.new()
	add_child_autofree(_parent)


func _pigman() -> Node:
	var script: Script = MobRegistry.script_for("zombie_pigman")
	var mob: Node = script.new()
	_parent.add_child(mob)
	return mob


func _pigman_at(pos: Vector3) -> Node:
	var mob: Node = _pigman()
	(mob as Node3D).global_position = pos
	return mob


# A stand-in for the player. Joins the group player.gd joins in _ready,
# which is the route `_is_player` takes when the script does not match.
func _fake_player_at(pos: Vector3) -> Node3D:
	var node := Node3D.new()
	node.add_to_group(ZombiePigman.PLAYER_GROUP)
	_parent.add_child(node)
	node.global_position = pos
	return node


# --- Registration and configuration ---


func test_registered_under_its_own_name() -> void:
	var script: Script = MobRegistry.script_for("zombie_pigman")
	assert_not_null(script, "MobRegistry is missing 'zombie_pigman'")
	if script != null:
		assert_eq(script.resource_path, "res://scripts/entities/zombie_pigman.gd")


func test_the_registry_name_does_not_collide() -> void:
	var names: Array = MobRegistry.names()
	var seen: Dictionary = {}
	for name: String in names:
		assert_false(seen.has(name), "duplicate registry name %s" % name)
		seen[name] = true
	assert_has(names, "zombie_pigman", "listed for the debug spawner grid")


func test_extends_mob_base() -> void:
	var script: Script = MobRegistry.script_for("zombie_pigman")
	var base: Script = script.get_base_script()
	assert_not_null(base, "should have a base script")
	if base != null:
		assert_eq(
			base.resource_path,
			"res://scripts/entities/mob_base.gd",
			"damage, drops and death must route through MobBase"
		)


func test_health_and_melee_match_the_source() -> void:
	var mob: Node = _pigman()
	# `ef.<init>` sets `this.J = 20`; `pt.<init>` overrides `this.f = 5`,
	# up from EntityMonster's default of 2.
	assert_eq(mob.get("max_health"), 20, "20 health from the hostile base")
	assert_eq(ZombiePigman._AI_MELEE_DAMAGE, 5, "pt.java sets attack damage to 5")
	assert_eq(ZombiePigman._AI_MELEE_RANGE, 2.5, "inherited ef melee reach")
	assert_eq(ZombiePigman._AI_MELEE_COOLDOWN_SEC, 1.0, "P = 20 ticks")


func test_drops_zero_to_two_cooked_porkchops() -> void:
	# `g_()` returns `dx.ap.aW` — item 64 + 256 = 320, cooked porkchop —
	# and `hf.b(lw)` drops `nextInt(3)` of it.
	var mob: Node = _pigman()
	assert_eq(mob.get("drop_item_id"), Items.COOKED_PORKCHOP)
	assert_eq(mob.get("drop_count_min"), 0)
	assert_eq(mob.get("drop_count_max"), 2)


func test_it_does_not_drop_its_sword_or_gold() -> void:
	# Alpha has no sword drop and no gold nuggets at all. The held item is
	# render-only.
	var mob: Node = _pigman()
	assert_ne(mob.get("drop_item_id"), Items.GOLD_SWORD, "the sword is not a drop")
	assert_eq(mob.get("drop_item_id"), Items.COOKED_PORKCHOP, "porkchop and nothing else")


func test_speed_switches_between_neutral_and_hunting() -> void:
	# `e_()`: `this.am = this.g != null ? 0.95f : 0.5f`. The ratio is what
	# matters — an angry pigman outruns a walking player.
	assert_almost_eq(
		ZombiePigman._AI_WALK_SPEED_ANGRY / ZombiePigman._AI_WALK_SPEED_CALM, 1.9, 1e-6
	)


func test_speed_follows_the_target_not_the_anger() -> void:
	# The source reads `this.g` (the target), not `Anger`. An angry pigman
	# that has lost its target ambles.
	var mob: Node = _pigman_at(Vector3.ZERO)
	assert_eq(mob.call("_walk_speed"), ZombiePigman._AI_WALK_SPEED_CALM, "no target, no hurry")
	mob.set("anger", 400)
	assert_eq(
		mob.call("_walk_speed"),
		ZombiePigman._AI_WALK_SPEED_CALM,
		"angry but targetless is still a walk"
	)
	mob.set("_ai_target", _fake_player_at(Vector3(5, 0, 0)))
	assert_eq(mob.call("_walk_speed"), ZombiePigman._AI_WALK_SPEED_ANGRY, "target acquired")


# --- Fire immunity ---


func test_it_is_fire_immune() -> void:
	var mob: Node = _pigman()
	assert_true(mob.call("_is_fire_immune"), "pt.<init> sets this.bm = true")


func test_other_mobs_are_not_fire_immune() -> void:
	# The hook has to default to false or every mob stops burning.
	var zombie: Node = MobRegistry.script_for("zombie").new()
	_parent.add_child(zombie)
	assert_false(zombie.call("_is_fire_immune"), "zombies still burn")


func test_fire_immunity_clears_the_burn_timer_and_the_flames() -> void:
	# hf.java:111 forces the timer to zero every tick for a fireproof
	# LIVING entity — which is also why a pigman never burns in daylight
	# despite inheriting the zombie's ignition unchanged.
	var mob: Node = _pigman_at(Vector3.ZERO)
	mob.set("_on_fire_ticks", 300)
	mob.call("_env_tick", true)
	assert_eq(mob.get("_on_fire_ticks"), 0, "the timer is cancelled on the same tick")


func test_fire_immunity_blocks_contact_damage() -> void:
	var mob: Node = _pigman_at(Vector3.ZERO)
	var before: int = mob.get("health")
	mob.set("_in_lava", true)
	# Twenty ticks is exactly one lava damage interval for a normal mob.
	for _i: int in range(25):
		mob.call("_env_tick", false)
	assert_eq(mob.get("health"), before, "standing in lava costs a pigman nothing")


# --- Neutrality ---


func test_a_calm_pigman_has_no_target() -> void:
	var mob: Node = _pigman_at(Vector3.ZERO)
	_fake_player_at(Vector3(1, 0, 0))
	assert_false(mob.call("is_angry"), "starts neutral")
	assert_null(mob.call("_find_target"), "and will not look at a player standing on its toes")


func test_anger_makes_it_hostile() -> void:
	var mob: Node = _pigman_at(Vector3.ZERO)
	var player: Node3D = _fake_player_at(Vector3(4, 0, 0))
	mob.set("_ai_player_cache", player)
	mob.call("become_angry_at", player)
	assert_true(mob.call("is_angry"))
	assert_eq(mob.call("_find_target"), player, "an angry pigman acquires")


func test_becoming_angry_rolls_the_source_range() -> void:
	# `this.a = 400 + this.bd.nextInt(400)` — [400, 799].
	var player: Node3D = _fake_player_at(Vector3.ZERO)
	for _i: int in range(200):
		var mob: Node = _pigman_at(Vector3.ZERO)
		mob.call("become_angry_at", player)
		var anger: int = mob.get("anger")
		assert_between(anger, ZombiePigman.ANGER_BASE, ZombiePigman.ANGER_BASE + 399, "anger range")
		mob.queue_free()


func test_the_angry_sound_countdown_rolls_the_source_range() -> void:
	# `this.b = this.bd.nextInt(40)` — [0, 39], and zero is a real result.
	var player: Node3D = _fake_player_at(Vector3.ZERO)
	var saw_zero: bool = false
	for _i: int in range(400):
		var mob: Node = _pigman_at(Vector3.ZERO)
		mob.call("become_angry_at", player)
		var countdown: int = mob.get("angry_sound_countdown")
		assert_between(countdown, 0, ZombiePigman.ANGRY_SOUND_DELAY_MAX - 1, "countdown range")
		if countdown == 0:
			saw_zero = true
		mob.queue_free()
	assert_true(saw_zero, "zero must be reachable — it is the silent-pigman case")


# --- Permanent anger ---


func test_anger_is_never_decremented() -> void:
	# The behaviour the plan calls out explicitly: Alpha has no
	# forgiveness. 800+ ticks is past the largest value the roll can
	# produce, so a decrementing implementation would have reached zero.
	var mob: Node = _pigman_at(Vector3.ZERO)
	mob.call("become_angry_at", _fake_player_at(Vector3(100, 0, 0)))
	var initial: int = mob.get("anger")
	for _i: int in range(1200):
		mob.call("_ai_tick")
	assert_eq(mob.get("anger"), initial, "anger does not tick down, ever")
	assert_true(mob.call("is_angry"), "still hostile after 60 seconds")


func test_losing_the_target_does_not_calm_it() -> void:
	var mob: Node = _pigman_at(Vector3.ZERO)
	var player: Node3D = _fake_player_at(Vector3(4, 0, 0))
	mob.set("_ai_player_cache", player)
	mob.call("become_angry_at", player)
	# Walk the player past the abandon radius.
	player.global_position = Vector3(500, 0, 0)
	mob.call("_ai_tick")
	assert_true(mob.call("is_angry"), "the target is dropped; the grudge is not")


# --- Group aggro ---


func test_a_player_hit_alerts_the_group() -> void:
	var hit: Node = _pigman_at(Vector3.ZERO)
	var near: Node = _pigman_at(Vector3(10, 0, 10))
	var player: Node3D = _fake_player_at(Vector3(2, 0, 0))
	hit.call("take_damage", 1, Vector3.ZERO, 1.0, player)
	assert_true(hit.call("is_angry"), "the one that was hit")
	assert_true(near.call("is_angry"), "and its neighbour")


func test_the_alert_region_is_a_box_grown_thirty_two_on_each_axis() -> void:
	var mob: Node = _pigman_at(Vector3.ZERO)
	var region: AABB = mob.call("alert_region")
	# The pigman's own box is 0.6 wide and 1.95 tall, grown 32 each way.
	assert_almost_eq(region.size.x, 0.6 + 64.0, 1e-4, "X spans the body plus 32 either side")
	assert_almost_eq(region.size.y, 1.95 + 64.0, 1e-4, "Y too — vanilla grows all three axes")
	assert_almost_eq(region.size.z, 0.6 + 64.0, 1e-4, "and Z")


func test_a_pigman_at_the_corner_of_the_region_is_alerted() -> void:
	# The case a radius check gets wrong: the far corner of a 32-cube is
	# 55 blocks away, well outside any 32 m sphere, and vanilla alerts it.
	var hit: Node = _pigman_at(Vector3.ZERO)
	var corner: Node = _pigman_at(Vector3(32.0, 32.0, 32.0))
	hit.call("take_damage", 1, Vector3.ZERO, 1.0, _fake_player_at(Vector3(1, 0, 0)))
	assert_true(corner.call("is_angry"), "inside the box, however far in a straight line")


func test_a_pigman_just_past_the_face_is_not_alerted() -> void:
	var hit: Node = _pigman_at(Vector3.ZERO)
	# The region reaches 32 + half the body width past the origin, and the
	# other pigman's own box reaches half its width back, so 34 clears it.
	var far: Node = _pigman_at(Vector3(34.0, 0.0, 0.0))
	hit.call("take_damage", 1, Vector3.ZERO, 1.0, _fake_player_at(Vector3(1, 0, 0)))
	assert_true(hit.call("is_angry"), "the hit one is angry")
	assert_false(far.call("is_angry"), "the one outside the box is not")


func test_the_boundary_is_inclusive_where_the_boxes_touch() -> void:
	# Right at the edge: the region's face and the other pigman's box
	# share a plane. `World.getEntities` returns anything whose box
	# INTERSECTS, so a touching box is inside.
	var hit: Node = _pigman_at(Vector3.ZERO)
	var edge: Node = _pigman_at(Vector3(32.5, 0.0, 0.0))
	hit.call("take_damage", 1, Vector3.ZERO, 1.0, _fake_player_at(Vector3(1, 0, 0)))
	assert_true(edge.call("is_angry"), "touching counts as intersecting")


func test_damage_from_a_non_player_does_not_anger_anyone() -> void:
	# `lw2 instanceof eb` — only a player. Lava, a skeleton's arrow, or
	# another mob's melee leaves the group calm, which is why a pigman
	# killed by a ghast fireball never starts a riot.
	var hit: Node = _pigman_at(Vector3.ZERO)
	var near: Node = _pigman_at(Vector3(5, 0, 0))
	var not_a_player := Node3D.new()
	_parent.add_child(not_a_player)
	hit.call("take_damage", 1, Vector3.ZERO, 1.0, not_a_player)
	assert_false(hit.call("is_angry"), "an unattributed hit does not anger")
	assert_false(near.call("is_angry"), "and does not spread")


func test_damage_with_no_attacker_does_not_anger() -> void:
	var mob: Node = _pigman_at(Vector3.ZERO)
	mob.call("take_damage", 3, Vector3.ZERO)
	assert_false(mob.call("is_angry"), "environmental damage leaves it neutral")


func test_only_pigmen_are_alerted() -> void:
	var hit: Node = _pigman_at(Vector3.ZERO)
	var zombie: Node = MobRegistry.script_for("zombie").new()
	_parent.add_child(zombie)
	(zombie as Node3D).global_position = Vector3(3, 0, 0)
	hit.call("take_damage", 1, Vector3.ZERO, 1.0, _fake_player_at(Vector3(1, 0, 0)))
	# Nothing to assert on the zombie beyond "it did not crash and has no
	# anger field" — the real assertion is that the scan is type-filtered.
	assert_false(zombie.has_method("is_angry"), "a zombie has no anger to set")


# --- Persistence ---


func test_anger_survives_a_save_round_trip() -> void:
	var mob: Node = _pigman_at(Vector3(3, 64, 5))
	mob.call("become_angry_at", _fake_player_at(Vector3.ZERO))
	var expected: int = mob.get("anger")
	var payload: Dictionary = mob.call("to_save_dict")
	assert_eq(payload.get("anger"), expected, "anger is written")
	var restored: Node = _pigman()
	restored.call("restore_from_dict", payload)
	assert_eq(restored.get("anger"), expected, "and read back")
	assert_true(restored.call("is_angry"), "a pigman loaded angry stays angry")


func test_a_calm_pigman_round_trips_calm() -> void:
	var mob: Node = _pigman_at(Vector3(1, 64, 1))
	var restored: Node = _pigman()
	restored.call("restore_from_dict", mob.call("to_save_dict"))
	assert_false(restored.call("is_angry"), "neutral in, neutral out")


func test_an_old_save_without_the_field_loads_calm() -> void:
	# Saves written before this batch have no "anger" key at all.
	var restored: Node = _pigman()
	restored.call("restore_from_dict", {"pos": Vector3(0, 64, 0), "hp": 20})
	assert_eq(restored.get("anger"), 0, "missing field means neutral, not garbage")


func test_anger_is_clamped_to_a_short() -> void:
	# Vanilla stores it as an NBT short; a wider value from a future
	# version must still load as "angry" rather than overflow.
	var restored: Node = _pigman()
	restored.call("restore_from_dict", {"anger": 99999})
	assert_eq(restored.get("anger"), 32767, "clamped to the field width")
	assert_true(restored.call("is_angry"))


func test_an_angry_pigman_reacquires_a_target_after_load() -> void:
	# The plan requires this explicitly: the target reference is not
	# persisted, only the anger, so a loaded pigman has to find someone.
	var restored: Node = _pigman_at(Vector3.ZERO)
	restored.call("restore_from_dict", {"pos": Vector3.ZERO, "hp": 20, "anger": 500})
	assert_null(restored.get("_ai_target"), "no target survives the save")
	var player: Node3D = _fake_player_at(Vector3(6, 0, 0))
	restored.set("_ai_player_cache", player)
	assert_eq(restored.call("_find_target"), player, "and one is found within 16 m")


func test_a_loaded_pigman_does_not_reacquire_beyond_sixteen_metres() -> void:
	var restored: Node = _pigman_at(Vector3.ZERO)
	restored.call("restore_from_dict", {"pos": Vector3.ZERO, "hp": 20, "anger": 500})
	var player: Node3D = _fake_player_at(Vector3(40, 0, 0))
	restored.set("_ai_player_cache", player)
	assert_null(restored.call("_find_target"), "ef.c_() searches 16 m, not the whole world")


func test_an_existing_pigman_target_has_no_forty_block_leash() -> void:
	var mob: Node3D = _pigman_at(Vector3.ZERO) as Node3D
	mob.set("anger", 500)
	var player: Node3D = _fake_player_at(Vector3(6, 0, 0))
	mob.set("_ai_player_cache", player)
	mob.set("_ai_target", player)
	player.global_position = Vector3(80, 0, 0)
	mob.call("_ai_tick")
	assert_eq(mob.get("_ai_target"), player, "fc retains a living target regardless of distance")


# --- Held item ---


func test_it_holds_a_gold_sword() -> void:
	var mob: Node = _pigman()
	var sword: Variant = mob.get("_sword_mesh")
	assert_not_null(sword, "the sword mesh was built")
	if sword != null:
		assert_true(
			(sword as Node).get_parent() == mob.get("_arm_r_pivot"),
			"parented to the right arm, so it follows the arm's pose"
		)


func test_the_held_item_pose_has_its_scale_baked_into_the_basis() -> void:
	# Godot 4 wipes `node.scale` when `node.basis` is assigned, which was
	# a real bug in the skeleton's bow. The helper bakes the scale into
	# the column lengths instead.
	var scale: float = 1.0 / 22.0
	var basis: Basis = MobBase.held_item_basis_full_3d(scale)
	assert_almost_eq(basis.x.length(), scale, 1e-6, "X column carries the scale")
	assert_almost_eq(basis.y.length(), scale, 1e-6, "Y column too")
	assert_almost_eq(basis.z.length(), scale, 1e-6, "and Z")


func test_the_held_item_pose_is_a_rotation_not_a_reflection() -> void:
	# A negative determinant would render the sprite inside-out.
	var basis: Basis = MobBase.held_item_basis_full_3d(1.0)
	assert_gt(basis.determinant(), 0.0, "right-handed frame")
	assert_almost_eq(basis.determinant(), 1.0, 1e-5, "and orthonormal at unit scale")


func test_the_blade_is_perpendicular_to_the_arm_like_vanilla() -> void:
	# The complete m.java -> ku.java stack puts grip→tip almost on
	# arm-local -Z. The omitted ku.java rotations used to put it on -Y,
	# parallel to the raised arm and aimed directly at the player.
	var basis: Basis = MobBase.held_item_basis_full_3d(1.0)
	var grip_to_tip: Vector3 = (basis * Vector3(11.0, 13.0, 0.0)).normalized()
	assert_lt(grip_to_tip.z, -0.99, "blade crosses the raised arm instead of following it")
	assert_lt(absf(grip_to_tip.x), 0.05, "not kicked off to one side")
	assert_lt(absf(grip_to_tip.y), 0.1, "not aimed down the arm at the player")


func test_the_raised_arm_leaves_the_sword_upright() -> void:
	# ck.java locks the arm at -pi/2; our Y-flipped model uses +pi/2.
	# Applying that arm pose after the complete held-item stack must leave
	# the blade almost vertical, as in Alpha, rather than pointing forward.
	var basis: Basis = MobBase.held_item_basis_full_3d(1.0)
	var grip_to_tip: Vector3 = (basis * Vector3(11.0, 13.0, 0.0)).normalized()
	var raised_arm := Basis(Vector3.RIGHT, ZombiePigman._ARM_HORIZONTAL_PITCH)
	var posed_blade: Vector3 = raised_arm * grip_to_tip
	assert_gt(posed_blade.y, 0.99, "sword tip is above the hand")
	assert_lt(absf(posed_blade.z), 0.1, "sword is not aimed at the player")


# --- LOD and body ---


func test_body_dimensions_match_the_zombie_model() -> void:
	var mob: Node = _pigman()
	assert_eq(mob.call("_get_body_height"), 1.95, "same silhouette as the zombie")
	assert_eq(mob.call("_get_body_width"), 0.6)
	assert_almost_eq(mob.call("_get_eye_height"), 1.62, 1e-6, "EntityHuman eye height")


func test_the_sword_is_visible_at_every_lod_the_mob_is() -> void:
	# The plan asks for the sword to be observable at every LOD. It is a
	# CHILD of the arm pivot, so it inherits the mob's own visibility —
	# LOD_GATED hides the whole node and the tiers below leave it alone.
	# What this pins is that nothing gates the sword separately.
	var mob: Node = _pigman()
	var sword: Node3D = mob.get("_sword_mesh")
	assert_not_null(sword, "the sword exists")
	if sword == null:
		return
	for tier: int in [MobBase.LOD_NEAR, MobBase.LOD_MID, MobBase.LOD_FAR]:
		mob.set("_lod_tier", tier)
		mob.call("_process", 0.016)
		assert_true(sword.visible, "sword still shown at LOD tier %d" % tier)


func test_it_participates_in_the_shared_lod_tiers() -> void:
	var mob: Node = _pigman()
	assert_eq(mob.get("_lod_tier"), MobBase.LOD_NEAR, "starts at the near tier")
	assert_true(mob.has_method("_physics_process"), "and runs the LOD-scaled tick")


func test_it_registers_in_the_active_mob_table() -> void:
	# The group-aggro scan walks MobBase.active_mobs; a pigman missing
	# from it would silently never be alerted.
	var mob: Node = _pigman()
	assert_true(
		MobBase.active_mobs().has((mob as Object).get_instance_id()), "listed while in the tree"
	)


# --- Combat ---


func test_it_deals_five_damage_to_the_player() -> void:
	var mob: Node = _pigman_at(Vector3.ZERO)
	var target := _DamageProbe.new()
	_parent.add_child(target)
	target.global_position = Vector3(1, 0, 0)
	mob.call("_attack_player", target)
	assert_eq(target.last_amount, 5, "pt.java's `this.f = 5`")
	assert_eq(target.last_source, "mob", "routed through the player's mob-damage path")
	assert_eq(target.hits, 1, "one hit per swing")


func test_melee_respects_its_cooldown() -> void:
	var mob: Node = _pigman_at(Vector3.ZERO)
	var target := _DamageProbe.new()
	_parent.add_child(target)
	target.global_position = Vector3(1, 0, 0)
	mob.call("_attack_player", target)
	assert_gt(mob.get("_ai_melee_cooldown_sec"), 0.0, "a swing arms the cooldown")
	# The AI tick only calls _attack_player when the cooldown has expired,
	# so a second immediate tick at melee range must not land a hit.
	mob.set("anger", 500)
	mob.set("_ai_player_cache", target)
	mob.call("_ai_tick")
	assert_eq(target.hits, 1, "still one hit — the cooldown held")


func test_a_swing_starts_the_chomp_animation() -> void:
	var mob: Node = _pigman_at(Vector3.ZERO)
	var target := _DamageProbe.new()
	_parent.add_child(target)
	mob.call("_attack_player", target)
	assert_gt(mob.get("_swing_remaining_sec"), 0.0, "the arm animates on a hit")


# --- Entity save round-trip through the real binary file ---


func test_a_pigman_round_trips_through_entities_bin() -> void:
	# Not just the payload Dictionary — the actual save file, dispatched
	# back through MobRegistry the way a world load does it.
	var world := "test_zombie_pigman_entities"
	SaveLoad.delete_world(world)
	var mob: Node = _pigman_at(Vector3(12.5, 65.0, -7.5))
	mob.call("become_angry_at", _fake_player_at(Vector3.ZERO))
	var expected_anger: int = mob.get("anger")
	assert_eq(EntitySave.save_all(_parent, world), 1, "one persistable entity")
	# Out of the tree and gone before the load, so the restored node is
	# unambiguously a fresh one. free() rather than queue_free() because
	# GUT counts orphans at the end of the test, before the deferred
	# free would have run.
	_parent.remove_child(mob)
	mob.free()
	var host := Node.new()
	add_child_autofree(host)
	assert_eq(EntitySave.load_all(host, world), 1, "and it comes back")
	var restored: Node = null
	for child: Node in host.get_children():
		if child is ZombiePigman:
			restored = child
			break
	assert_not_null(restored, "restored as a ZombiePigman, not some other species")
	if restored != null:
		assert_eq(restored.get("anger"), expected_anger, "anger survived the binary round trip")
		assert_almost_eq(
			(restored as Node3D).global_position.x, 12.5, 0.01, "and so did the position"
		)
	SaveLoad.delete_world(world)


func test_the_registry_reverse_lookup_finds_the_pigman() -> void:
	# EntitySave tags a live mob by reverse-looking-up its script path.
	# A missing entry here means pigmen silently do not persist at all.
	assert_eq(
		MobRegistry.name_for_script_path("res://scripts/entities/zombie_pigman.gd"),
		"zombie_pigman",
		"reverse lookup resolves"
	)


# --- Debug spawn clearance ---


func test_it_spawns_the_way_the_debug_spawner_instantiates_mobs() -> void:
	# debug_mob_spawner._spawn_one_mob does exactly this: script.new()
	# cast to CharacterBody3D, add_child, then set global_position. A mob
	# that needed a pre-add setup hook (as slime does for its size) would
	# come out misconfigured.
	var script: Script = MobRegistry.script_for("zombie_pigman")
	var mob: CharacterBody3D = script.new() as CharacterBody3D
	assert_not_null(mob, "instantiates as a CharacterBody3D")
	if mob != null:
		_parent.add_child(mob)
		mob.global_position = Vector3(4.5, 64.05, 4.5)
		assert_eq(mob.get("max_health"), 20, "fully configured with no extra setup call")
		assert_eq(mob.get("health"), 20, "and at full health")


func test_a_two_cell_gap_is_enough_clearance() -> void:
	# The spawner cage checks the target cell and the one above it. A
	# 1.95 m pigman fits a 2-cell gap, so no species-specific clearance
	# rule is needed — this pins that the body was not made taller than
	# the placement rule allows.
	var mob: Node = _pigman()
	assert_lte(
		mob.call("_get_body_height"), 2.0, "fits the 2-cell gap the cage and debug spawner check"
	)


# --- Bounded multi-mob performance sample ---


func test_a_group_alert_stays_cheap_with_a_full_mob_cap() -> void:
	# The alert scan walks every active mob on every player hit. Vanilla's
	# hostile cap is 70, so that is the population to measure at. This is
	# a ceiling check, not a benchmark: it fails only if the scan became
	# something worse than linear.
	var player: Node3D = _fake_player_at(Vector3(1, 0, 0))
	var mobs: Array[Node] = []
	# A 10x7 grid at 3 m spacing spans 27x18 blocks, comfortably inside
	# the 32-block alert box so the count below is unambiguous.
	for i: int in range(70):
		mobs.append(_pigman_at(Vector3(float(i % 10) * 3.0, 0.0, float(i / 10) * 3.0)))
	var start: int = Time.get_ticks_usec()
	for _round: int in range(20):
		mobs[0].call("_alert_group", player)
	var elapsed_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
	gut.p("70 pigmen, 20 group alerts: %.2f ms (%.3f ms each)" % [elapsed_ms, elapsed_ms / 20.0])
	assert_lt(elapsed_ms, 200.0, "20 alerts over 70 mobs stays well under a frame budget each")
	var angry: int = 0
	for i: int in range(1, mobs.size()):
		if mobs[i].call("is_angry"):
			angry += 1
	assert_eq(angry, 69, "every other pigman in the box was alerted")
	# _alert_group deliberately skips the caller: `pt.a(lw, int)` alerts
	# the group and THEN calls c() on itself, and take_damage is where
	# that second half lives.
	assert_false(mobs[0].call("is_angry"), "the scan does not anger the caller")


func test_an_ai_tick_stays_cheap_across_a_group() -> void:
	var mobs: Array[Node] = []
	for i: int in range(70):
		mobs.append(_pigman_at(Vector3(float(i) * 3.0, 0.0, 0.0)))
	var start: int = Time.get_ticks_usec()
	for _round: int in range(20):
		for mob: Node in mobs:
			mob.call("_ai_tick")
	var elapsed_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
	gut.p(
		(
			"70 pigmen x 20 AI ticks: %.2f ms (%.4f ms per mob-tick)"
			% [elapsed_ms, elapsed_ms / 1400.0]
		)
	)
	assert_lt(elapsed_ms, 500.0, "1400 neutral AI ticks stay off the frame budget")


# A stand-in for the player that records incoming damage. Named with a
# leading underscore so GUT does not treat it as a test.
class _DamageProbe:
	extends Node3D

	var hits: int = 0
	var last_amount: int = 0
	var last_source: String = ""

	func take_damage(amount: int, source: String = "", _dir: Vector3 = Vector3.ZERO) -> void:
		hits += 1
		last_amount = amount
		last_source = source
