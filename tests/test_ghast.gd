# gdlint: disable=max-public-methods
extends GutTest

# Ghast — vanilla `am.java`, `hc.java` (model) and `jz.java` (renderer)
# (docs/nether-alpha-1.2.6-implementation-plan.md §8.2, Batch 9).
#
# Almost everything about a ghast is one of two integers. The WAYPOINT
# decides where it drifts — a random point within 16 blocks, rerolled
# whenever it gets closer than 1 or further than 60 — and the CHARGE
# COUNTER is the entire combat loop: climbs with line of sight, plays a
# sound at 10, swaps texture above 10, fires at 20, resets to -40, and
# decrements rather than resetting when sight is lost.

var _parent: Node = null
var _difficulty_was: int = 0


class FakeWorld:
	extends Node

	var blocks: Dictionary = {}
	var effective_light: int = 0

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id

	func get_world_effective_light(_pos: Vector3i, _sky_subtraction: int = -1) -> int:
		return effective_light

	func fill(from: Vector3i, to: Vector3i, id: int) -> void:
		for x: int in range(from.x, to.x + 1):
			for y: int in range(from.y, to.y + 1):
				for z: int in range(from.z, to.z + 1):
					blocks[Vector3i(x, y, z)] = id


func before_each() -> void:
	_parent = Node.new()
	add_child_autofree(_parent)
	_difficulty_was = Game.difficulty
	Game.difficulty = Game.DIFFICULTY_NORMAL


func after_each() -> void:
	Game.difficulty = _difficulty_was


func _ghast() -> Node:
	var mob: Node = MobRegistry.script_for("ghast").new()
	_parent.add_child(mob)
	return mob


func _ghast_at(pos: Vector3, world: Node = null) -> Node:
	var mob: Node = _ghast()
	(mob as Node3D).global_position = pos
	mob.set("waypoint", pos)
	if world != null:
		mob.set("_chunk_manager", world)
	return mob


func _fake_world() -> FakeWorld:
	var w := FakeWorld.new()
	_parent.add_child(w)
	return w


func _player_at(pos: Vector3) -> Node3D:
	var node := Node3D.new()
	_parent.add_child(node)
	node.global_position = pos
	return node


# --- Registration and configuration ---


func test_registered_under_ghast() -> void:
	var script: Script = MobRegistry.script_for("ghast")
	assert_not_null(script, "MobRegistry is missing 'ghast'")
	if script != null:
		assert_eq(script.resource_path, "res://scripts/entities/ghast.gd")


func test_ten_health_not_twenty() -> void:
	# `am` extends `ot` directly, not `ef`, so it never picks up
	# EntityMonster's bump from `hf.J = 10` to 20. A ghast dies to two
	# arrows, which is the whole reason fighting one is viable.
	assert_eq(_ghast().get("max_health"), 10, "hf.J = 10, inherited unchanged")


func test_four_by_four_body() -> void:
	var mob: Node = _ghast()
	assert_eq(mob.call("_get_body_height"), 4.0, "a(4.0f, 4.0f)")
	assert_eq(mob.call("_get_body_width"), 4.0)
	var half: Vector3 = mob.call("_voxel_half_extents")
	assert_eq(half, Vector3(2.0, 2.0, 2.0), "the collider is the full 4x4x4, not the 0.6 default")


func test_it_flies_and_never_falls() -> void:
	var mob: Node = _ghast()
	assert_false(mob.call("_uses_gravity"), "ot.java supplies its own motion")
	assert_false(mob.call("_takes_fall_damage"), "ot.c(float) is an empty override")


func test_it_is_fire_immune() -> void:
	assert_true(_ghast().call("_is_fire_immune"), "am.<init> sets this.bm = true")


func test_it_drops_gunpowder_and_never_tears() -> void:
	# `g_()` returns `dx.K.aW` — item 33 + 256 = 289, gunpowder. Ghast
	# tears are a Beta addition.
	var mob: Node = _ghast()
	assert_eq(mob.get("drop_item_id"), Items.GUNPOWDER)
	assert_eq(mob.get("drop_count_min"), 0)
	assert_eq(mob.get("drop_count_max"), 2)


# --- Peaceful ---


func test_peaceful_kills_it_outright() -> void:
	# `if (this.as.k == 0) this.J();` is the FIRST line of b_(), before
	# any movement or targeting.
	var mob: Node = _ghast_at(Vector3(0, 70, 0))
	Game.difficulty = Game.DIFFICULTY_PEACEFUL
	mob.call("_ai_tick")
	assert_true(mob.get("_dying"), "setDead on the first tick")


func test_it_survives_every_other_difficulty() -> void:
	for level: int in [Game.DIFFICULTY_EASY, Game.DIFFICULTY_NORMAL, Game.DIFFICULTY_HARD]:
		var mob: Node = _ghast_at(Vector3(0, 70, 0))
		Game.difficulty = level
		mob.call("_ai_tick")
		assert_false(mob.get("_dying"), "alive at difficulty %d" % level)
		mob.queue_free()


# --- Waypoints ---


func test_a_waypoint_too_close_is_rerolled() -> void:
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	# Starts at its own position, so distance 0 — below the minimum.
	mob.call("_tick_waypoint")
	var wp: Vector3 = mob.get("waypoint")
	assert_gt(
		wp.distance_to(Vector3(0, 70, 0)), 0.0, "a waypoint at distance 0 must not survive the tick"
	)


func test_a_waypoint_too_far_is_rerolled() -> void:
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	mob.set("waypoint", Vector3(0, 70, 500))
	mob.call("_tick_waypoint")
	assert_lte(
		(mob.get("waypoint") as Vector3).distance_to(Vector3(0, 70, 0)),
		Ghast.WAYPOINT_RANGE * sqrt(3.0) + 0.001,
		"a reroll lands within 16 blocks on each axis"
	)


func test_a_reasonable_waypoint_is_kept() -> void:
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	var chosen := Vector3(5, 72, -3)
	mob.set("waypoint", chosen)
	mob.call("_tick_waypoint")
	assert_eq(mob.get("waypoint"), chosen, "distance 6.2 is inside [1, 60]")


func test_rerolls_stay_inside_the_source_range() -> void:
	# `(nextFloat() * 2 - 1) * 16` per axis — a cube, not a sphere.
	var mob: Node = _ghast_at(Vector3(100, 70, -50), _fake_world())
	for _i: int in range(200):
		mob.set("waypoint", Vector3(100, 70, -50))  # forces a reroll
		mob.call("_tick_waypoint")
		var offset: Vector3 = (mob.get("waypoint") as Vector3) - Vector3(100, 70, -50)
		assert_lte(absf(offset.x), Ghast.WAYPOINT_RANGE, "X within 16")
		assert_lte(absf(offset.y), Ghast.WAYPOINT_RANGE, "Y within 16")
		assert_lte(absf(offset.z), Ghast.WAYPOINT_RANGE, "Z within 16")


func test_an_obstructed_course_abandons_the_waypoint() -> void:
	# `else { this.b = this.aw; ... }` — a blocked path resets the
	# waypoint to the current position, which fails the < 1 test next
	# tick and forces a fresh roll. The ghast does NOT accelerate.
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(-10, 60, 3), Vector3i(10, 80, 5), Blocks.NETHERRACK)
	var mob: Node = _ghast_at(Vector3(0, 70, 0), w)
	mob.set("waypoint", Vector3(0, 70, 20))
	mob.set("_course_countdown", 0)
	(mob as Node3D).velocity = Vector3.ZERO
	mob.call("_tick_waypoint")
	assert_eq((mob as Node3D).velocity, Vector3.ZERO, "a wall means no acceleration")
	assert_eq(mob.get("waypoint"), Vector3(0, 70, 0), "and the waypoint is abandoned")


func test_a_clear_course_accelerates_toward_the_waypoint() -> void:
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	mob.set("waypoint", Vector3(0, 70, 20))
	mob.set("_course_countdown", 0)
	(mob as Node3D).velocity = Vector3.ZERO
	mob.call("_tick_waypoint")
	var v: Vector3 = (mob as Node3D).velocity
	assert_gt(v.z, 0.0, "accelerated toward the waypoint")
	assert_almost_eq(v.length(), Ghast.DRIFT_ACCELERATION * 20.0, 1e-4, "0.1 per tick")


func test_the_course_is_only_re_evaluated_every_two_to_six_ticks() -> void:
	# `if (this.a-- <= 0) { this.a += this.bd.nextInt(5) + 2; ... }` —
	# post-decrement, so a counter of 0 fires and drops to -1 BEFORE the
	# reroll is added. The stored value lands in [1, 5]; the interval
	# between course changes is the [2, 6] that reroll represents.
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	for _i: int in range(300):
		mob.set("waypoint", Vector3(0, 70, 20))
		mob.set("_course_countdown", 0)
		mob.call("_tick_waypoint")
		assert_between(
			mob.get("_course_countdown"),
			Ghast.COURSE_INTERVAL_MIN - 1,
			Ghast.COURSE_INTERVAL_MIN + Ghast.COURSE_INTERVAL_SPAN - 2,
			"stored countdown lands in [1, 5]"
		)


func test_the_interval_between_course_changes_is_two_to_six_ticks() -> void:
	# The observable figure, measured rather than asserted on the field:
	# tick until the velocity changes, twice, and check the gap.
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	for _round: int in range(60):
		mob.set("_course_countdown", 0)
		mob.set("waypoint", Vector3(0, 70, 20))
		(mob as Node3D).velocity = Vector3.ZERO
		mob.call("_tick_waypoint")  # fires immediately
		var gap: int = 0
		while (mob as Node3D).velocity.length_squared() < 1e-9 or gap == 0:
			gap += 1
			(mob as Node3D).velocity = Vector3.ZERO
			mob.set("waypoint", Vector3(0, 70, 20))
			mob.call("_tick_waypoint")
			if (mob as Node3D).velocity.length_squared() > 1e-9:
				break
		assert_between(
			gap,
			Ghast.COURSE_INTERVAL_MIN,
			Ghast.COURSE_INTERVAL_MIN + Ghast.COURSE_INTERVAL_SPAN - 1,
			"course changes land 2-6 ticks apart"
		)


func test_course_clearance_sees_a_wall() -> void:
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(-10, 60, 5), Vector3i(10, 80, 6), Blocks.NETHERRACK)
	var mob: Node = _ghast_at(Vector3(0, 70, 0), w)
	assert_false(mob.call("course_is_clear", Vector3(0, 70, 20), 20.0), "the wall blocks it")
	assert_true(mob.call("course_is_clear", Vector3(0, 70, -20), 20.0), "the other way is open")


# --- Targeting ---


func test_it_ignores_a_player_beyond_a_hundred_blocks() -> void:
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	mob.set("_cached_player_node", _player_at(Vector3(0, 70, 300)))
	mob.call("_tick_target")
	assert_null(mob.get("_target"), "100 blocks is the search radius")


func test_it_acquires_a_player_inside_a_hundred_blocks() -> void:
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	var player: Node3D = _player_at(Vector3(0, 70, 50))
	mob.set("_cached_player_node", player)
	mob.call("_tick_target")
	assert_eq(mob.get("_target"), player, "acquired")
	assert_eq(mob.get("_target_countdown"), Ghast.TARGET_REACQUIRE_TICKS, "20-tick hold")


# --- The charge timeline ---


func _engaged_ghast(charge: int) -> Array:
	var w: FakeWorld = _fake_world()
	var mob: Node = _ghast_at(Vector3(0, 70, 0), w)
	var player: Node3D = _player_at(Vector3(0, 70, 10))
	mob.set("_cached_player_node", player)
	mob.set("_target", player)
	mob.set("_target_countdown", 20)
	mob.set("charge", charge)
	return [mob, player, w]


func test_the_charge_climbs_with_line_of_sight() -> void:
	var setup: Array = _engaged_ghast(0)
	var mob: Node = setup[0]
	for expected: int in range(1, 6):
		mob.call("_tick_combat")
		assert_eq(mob.get("charge"), expected, "one per tick")


func test_it_fires_at_twenty_and_resets_to_minus_forty() -> void:
	var setup: Array = _engaged_ghast(19)
	var mob: Node = setup[0]
	mob.call("_tick_combat")
	assert_eq(mob.get("charge"), Ghast.CHARGE_COOLDOWN, "-40 after firing")
	var fireballs: int = 0
	for child: Node in _parent.get_children():
		if child is GhastFireball:
			fireballs += 1
	# The fireball parents to the chunk manager when there is one; the
	# fake world is a plain Node, so it lands there.
	for child: Node in (setup[2] as Node).get_children():
		if child is GhastFireball:
			fireballs += 1
	assert_eq(fireballs, 1, "exactly one fireball per shot")


func test_the_cooldown_has_to_climb_back_through_zero() -> void:
	# -40 to 20 is 60 ticks — three seconds between shots, which is what
	# makes a ghast fight survivable.
	var setup: Array = _engaged_ghast(Ghast.CHARGE_COOLDOWN)
	var mob: Node = setup[0]
	for _i: int in range(59):
		mob.call("_tick_combat")
	assert_eq(mob.get("charge"), 19, "still one short after 59 ticks")


func test_losing_line_of_sight_decrements_rather_than_resetting() -> void:
	# A player who ducks behind a pillar for two ticks loses two ticks of
	# charge, not the whole windup.
	var setup: Array = _engaged_ghast(15)
	var mob: Node = setup[0]
	var w: FakeWorld = setup[2]
	w.fill(Vector3i(-4, 60, 4), Vector3i(4, 80, 5), Blocks.NETHERRACK)
	mob.call("_tick_combat")
	mob.call("_tick_combat")
	assert_eq(mob.get("charge"), 13, "two ticks lost, not fifteen")


func test_leaving_the_engage_radius_decrements_too() -> void:
	var setup: Array = _engaged_ghast(12)
	var mob: Node = setup[0]
	var player: Node3D = setup[1]
	player.global_position = Vector3(0, 70, 200)
	mob.call("_tick_combat")
	assert_eq(mob.get("charge"), 11, "out of range winds down")


func test_it_does_not_engage_beyond_sixty_four_blocks() -> void:
	var setup: Array = _engaged_ghast(0)
	var mob: Node = setup[0]
	(setup[1] as Node3D).global_position = Vector3(0, 70, 70)
	mob.call("_tick_combat")
	assert_eq(mob.get("charge"), 0, "no charge accumulates outside 64")


func test_the_fireball_launches_four_blocks_along_the_look_vector() -> void:
	var setup: Array = _engaged_ghast(19)
	var mob: Node = setup[0]
	var world: Node = setup[2]
	# Facing +Z: the look vector is -basis.z, so rotate 180 degrees.
	(mob as Node3D).rotation.y = PI
	mob.call("_tick_combat")
	var fireball: Node3D = null
	for child: Node in world.get_children():
		if child is GhastFireball:
			fireball = child as Node3D
	assert_not_null(fireball, "a fireball spawned")
	if fireball == null:
		return
	var offset: Vector3 = fireball.global_position - Vector3(0, 70, 0)
	assert_almost_eq(
		Vector2(offset.x, offset.z).length(),
		Ghast.FIREBALL_LAUNCH_DISTANCE,
		0.01,
		"four blocks out horizontally"
	)
	# `az2.ax = ax + this.aQ / 2 + 0.5` — mid-height plus half a block,
	# NOT along the look vector.
	assert_almost_eq(offset.y, 4.0 * 0.5 + 0.5, 0.01, "and at mid-height plus half")


# --- LOD cadence (audit finding #10) ---


func test_mid_lod_combat_runs_at_real_time_cadence() -> void:
	# At MID (32-64 m) the AI ticks at a quarter rate and each combat tick
	# steps the charge counter by four, so the wall-clock fire rate matches
	# vanilla. The counter PAUSES on the charge sound rather than stepping
	# past it: 0 -> 4 -> 8 -> 10 (sound, held) -> 14 -> 18 -> 22 fires.
	#
	# Without that pause a step of four crossed 10 and 20 in the same tick
	# and the ghast fired the instant it growled, with no windup for the
	# player to react to — and at FAR (step 20) there was no growl at all.
	var setup: Array = _engaged_ghast(0)
	var mob: Node = setup[0]
	mob.set("_lod_tier", MobBase.LOD_MID)
	for _i: int in range(3):
		mob.call("_tick_combat")
	assert_eq(mob.get("charge"), Ghast.CHARGE_SOUND_AT, "the counter holds on the charge sound")
	for _i: int in range(2):
		mob.call("_tick_combat")
	assert_eq(mob.get("charge"), 18, "then resumes stepping by four")
	mob.call("_tick_combat")
	assert_eq(mob.get("charge"), Ghast.CHARGE_COOLDOWN, "and the next tick fires")


func test_every_lod_tier_keeps_a_charge_warning() -> void:
	# The tell is the mechanic: vanilla gives ten ticks between
	# `mob.ghast.charge` and the fireball, and ENGAGE_RADIUS (64) reaches
	# well into MID and FAR, so a collapsed windup means most ghasts that
	# shoot at you fire without warning.
	for tier: int in [MobBase.LOD_NEAR, MobBase.LOD_MID, MobBase.LOD_FAR]:
		var setup: Array = _engaged_ghast(0)
		var mob: Node = setup[0]
		mob.set("_lod_tier", tier)
		var sound_tick: int = -1
		var fire_tick: int = -1
		for tick: int in range(1, 60):
			mob.call("_tick_combat")
			if sound_tick < 0 and int(mob.get("charge")) == Ghast.CHARGE_SOUND_AT:
				sound_tick = tick
			if int(mob.get("charge")) == Ghast.CHARGE_COOLDOWN:
				fire_tick = tick
				break
		assert_gt(sound_tick, -1, "tier %d played a charge sound" % tier)
		assert_gt(fire_tick, sound_tick, "tier %d fires AFTER the warning, not with it" % tier)


func test_a_large_step_cannot_jump_the_shot() -> void:
	# Crossings are >= tests, so a FAR-tier step of 20 from the cooldown
	# cannot tunnel past 20 without firing.
	var setup: Array = _engaged_ghast(19)
	var mob: Node = setup[0]
	mob.set("_lod_tier", MobBase.LOD_FAR)
	mob.call("_tick_combat")
	assert_eq(mob.get("charge"), Ghast.CHARGE_COOLDOWN, "fired despite overshooting 20")


func test_lod_decrements_also_scale_and_floor_at_zero() -> void:
	var setup: Array = _engaged_ghast(6)
	var mob: Node = setup[0]
	mob.set("_lod_tier", MobBase.LOD_MID)
	(setup[1] as Node3D).global_position = Vector3(0, 70, 200)  # out of range
	mob.call("_tick_combat")
	assert_eq(mob.get("charge"), 2, "one MID tick unwinds four units")
	mob.call("_tick_combat")
	assert_eq(mob.get("charge"), 0, "and floors at zero rather than going negative")


# --- Hurt flash vs texture swap (audit finding #11) ---


func test_a_texture_swap_during_a_hurt_flash_survives_the_flash() -> void:
	var mob: Node = _ghast()
	mob.call("_apply_hurt_flash")
	mob.set("charge", 15)
	mob.call("_apply_texture_state")
	var flash_mat: Material = (mob.get("_body_mesh") as MeshInstance3D).material_override
	mob.call("_clear_hurt_flash")
	var charging: StandardMaterial3D = MobBase.get_shared_material(Ghast._TEXTURE_CHARGING, false)
	assert_same(
		(mob.get("_body_mesh") as MeshInstance3D).material_override,
		charging,
		"the flash restored the CHARGING texture, not the stale calm one"
	)
	assert_ne(flash_mat, charging, "and the flash itself was never clobbered mid-flash")


# --- Texture state ---


func test_alpha_renderer_keeps_ghasts_fullbright_in_zero_world_light() -> void:
	# `mn.java` first sets the entity's sampled brightness, then
	# `jz.java::a(am,float)` deliberately overrides it with white.
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	mob.call("_tick_world_brightness")
	assert_eq(mob.get("_last_lit_bucket"), 31, "jz.java pins the final render colour to white")
	var meshes: Array = MobBase._find_mesh_instances(mob)
	assert_eq(meshes.size(), 10, "body plus all nine tentacles use the policy")
	for mesh: MeshInstance3D in meshes:
		var mat := mesh.material_override as StandardMaterial3D
		assert_eq(mat.albedo_color, Color.WHITE, "every ghast mesh remains fullbright")


func test_charge_texture_transitions_preserve_fullbright_policy() -> void:
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	mob.call("_tick_world_brightness")
	var body := mob.get("_body_mesh") as MeshInstance3D
	assert_eq((body.material_override as StandardMaterial3D).albedo_color, Color.WHITE, "calm")

	mob.set("charge", 11)
	mob.call("_apply_texture_state")
	assert_eq((body.material_override as StandardMaterial3D).albedo_color, Color.WHITE, "charging")
	assert_eq(mob.get("_last_lit_bucket"), 31, "the material swap reapplies the render policy")

	mob.set("charge", Ghast.CHARGE_COOLDOWN)
	mob.call("_apply_texture_state")
	assert_eq(
		(body.material_override as StandardMaterial3D).albedo_color, Color.WHITE, "calm again"
	)


func test_the_texture_swaps_above_ten_not_at_ten() -> void:
	# `this.z = this.f > 10 ? ghast_fire : ghast` — strictly greater, so
	# the swap is one tick behind the charge sound.
	var mob: Node = _ghast()
	for value: int in [0, 5, 10]:
		mob.set("charge", value)
		mob.call("_apply_texture_state")
		assert_false(mob.get("_charging_texture"), "calm at charge %d" % value)
	mob.set("charge", 11)
	mob.call("_apply_texture_state")
	assert_true(mob.get("_charging_texture"), "charging at 11")


func test_the_texture_returns_to_calm_after_firing() -> void:
	var mob: Node = _ghast()
	mob.set("charge", 15)
	mob.call("_apply_texture_state")
	mob.set("charge", Ghast.CHARGE_COOLDOWN)
	mob.call("_apply_texture_state")
	assert_false(mob.get("_charging_texture"), "-40 is not above 10")


func test_both_ghast_materials_are_shared() -> void:
	# Two ghasts in the same state must not hold two materials, and
	# swapping one's texture must not recolour the other.
	var calm: Node = _ghast()
	var charging: Node = _ghast()
	charging.set("charge", 15)
	charging.call("_apply_texture_state")
	var other_calm: Node = _ghast()
	assert_same(
		(calm.get("_body_mesh") as MeshInstance3D).material_override,
		(other_calm.get("_body_mesh") as MeshInstance3D).material_override,
		"two calm ghasts share one material"
	)
	assert_ne(
		(calm.get("_body_mesh") as MeshInstance3D).material_override,
		(charging.get("_body_mesh") as MeshInstance3D).material_override,
		"and a charging one does not drag the others with it"
	)


# --- Model (`hc.java`) ---


func test_nine_tentacles() -> void:
	assert_eq((_ghast().get("_tentacle_pivots") as Array).size(), 9, "hc.java builds nine")


func test_tentacle_lengths_are_deterministic() -> void:
	# `new Random(1660L)`, walked in a fixed order — identical in every
	# session, the same guarantee the portal texture has.
	var first: Array[int] = Ghast.tentacle_lengths()
	var second: Array[int] = Ghast.tentacle_lengths()
	assert_eq(first, second, "the same nine lengths every call")
	assert_eq(first.size(), 9)
	for length: int in first:
		assert_between(length, 8, 14, "nextInt(7) + 8")


func test_tentacle_lengths_match_the_pinned_sequence() -> void:
	# Pinned so a change to JavaRandom or to the walk order is caught
	# here rather than as a visual regression nobody notices.
	# Verified independently against a reference implementation of
	# java.util.Random's LCG rather than read off our own output, so this
	# pins the SOURCE sequence and not just our current behaviour.
	assert_eq(
		Ghast.tentacle_lengths(),
		[8, 13, 9, 11, 11, 10, 12, 9, 12] as Array[int],
		"Random(1660).nextInt(7) + 8 produces exactly this"
	)


func test_tentacle_anchors_form_the_offset_grid() -> void:
	# `f3 = ((i/3) - 1) * 5` — three rows at Z = -5, 0, +5.
	for i: int in range(9):
		var anchor: Vector2 = Ghast.tentacle_anchor(i)
		assert_eq(anchor.y, float(i / 3 - 1) * 5.0, "row %d sits at its Z" % (i / 3))
	# Middle row is offset half a cell, which is what stops the nine
	# reading as a regular lattice.
	assert_ne(Ghast.tentacle_anchor(0).x, Ghast.tentacle_anchor(3).x, "rows 0 and 1 are staggered")
	assert_eq(Ghast.tentacle_anchor(0).x, Ghast.tentacle_anchor(6).x, "rows 0 and 2 line up")


func test_tentacles_hang_below_the_body() -> void:
	var mob: Node = _ghast()
	var pivots: Array = mob.get("_tentacle_pivots")
	for pivot: Node3D in pivots:
		for child: Node in pivot.get_children():
			if child is MeshInstance3D:
				assert_lt(
					(child as MeshInstance3D).position.y, 0.0, "the box hangs down from the pivot"
				)


# --- Charge squash/stretch (`jz.java`) ---


func test_the_resting_pose_is_uniform() -> void:
	# q = 0 -> inv = 1 -> both scales (8 + 1)/2 = 4.5.
	var scale: Vector2 = Ghast.charge_render_scale(0.0)
	assert_almost_eq(scale.x, 4.5, 1e-5, "XZ at rest")
	assert_almost_eq(scale.y, 4.5, 1e-5, "Y at rest")


func test_the_counter_ten_pose() -> void:
	# q = 0.5 -> q^5 = 0.03125 -> inv = 1/1.0625 = 0.941176.
	var scale: Vector2 = Ghast.charge_render_scale(0.5)
	assert_almost_eq(scale.y, (8.0 + 1.0 / 1.0625) / 2.0, 1e-5, "Y barely squashed at 10")
	assert_almost_eq(scale.x, (8.0 + 1.0625) / 2.0, 1e-5, "XZ barely stretched at 10")
	assert_lt(scale.y, 4.5, "already flattening")
	assert_gt(scale.x, 4.5, "already widening")


func test_the_counter_twenty_pose() -> void:
	# q = 1 -> inv = 1/3. Y = (8 + 1/3)/2, XZ = (8 + 3)/2.
	var scale: Vector2 = Ghast.charge_render_scale(1.0)
	assert_almost_eq(scale.y, (8.0 + 1.0 / 3.0) / 2.0, 1e-5, "Y at full charge")
	assert_almost_eq(scale.x, 5.5, 1e-5, "XZ at full charge")


func test_a_negative_counter_clamps_to_the_resting_pose() -> void:
	# `if (f3 < 0.0f) f3 = 0.0f` — the -40 cooldown renders at rest, it
	# does not invert the squash.
	assert_eq(Ghast.charge_render_scale(-2.0), Ghast.charge_render_scale(0.0), "clamped from below")


func test_the_squash_conserves_the_silhouette_direction() -> void:
	# Charging always makes a ghast wider and flatter, never the reverse.
	var previous: Vector2 = Ghast.charge_render_scale(0.0)
	for step: int in range(1, 21):
		var current: Vector2 = Ghast.charge_render_scale(float(step) / 20.0)
		assert_lte(current.y, previous.y + 1e-9, "Y never grows")
		assert_gte(current.x, previous.x - 1e-9, "XZ never shrinks")
		previous = current


func test_the_animation_allocates_no_nodes() -> void:
	# §8.2: "animation must not allocate per frame." The whole
	# squash/stretch is one scale write on one render root.
	var mob: Node = _ghast()
	var before: int = mob.get_child_count()
	for _i: int in range(120):
		mob.call("_animate", 0.016)
	assert_eq(mob.get_child_count(), before, "no node churn across 120 frames")


# --- Airborne spawn ---


func test_it_declares_itself_airborne() -> void:
	assert_true(_ghast().call("spawns_airborne"), "a 4x4 body does not stand on a floor cell")


func test_the_spawn_search_finds_open_air_above_a_floor() -> void:
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(-8, 60, -8), Vector3i(8, 64, 8), Blocks.NETHERRACK)
	var found: Variant = MobBase.find_airborne_spawn(w, Vector3i(0, 65, 0), 4.0)
	assert_not_null(found, "there is open air above the floor")
	if found != null:
		assert_gte((found as Vector3).y, 65.0, "at or above the floor cell")


func test_the_spawn_search_lifts_past_a_ceiling_that_is_too_low() -> void:
	# A two-block gap under a ceiling cannot hold a 4x4 ghast; the search
	# must keep climbing rather than embedding it.
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(-8, 60, -8), Vector3i(8, 64, 8), Blocks.NETHERRACK)
	w.fill(Vector3i(-8, 67, -8), Vector3i(8, 68, 8), Blocks.NETHERRACK)
	var found: Variant = MobBase.find_airborne_spawn(w, Vector3i(0, 65, 0), 4.0)
	assert_not_null(found, "found somewhere")
	if found != null:
		assert_gte((found as Vector3).y, 69.0, "above the low ceiling, not inside it")


func test_the_spawn_search_refuses_solid_rock() -> void:
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(-8, 60, -8), Vector3i(8, 120, 8), Blocks.NETHERRACK)
	assert_null(
		MobBase.find_airborne_spawn(w, Vector3i(0, 65, 0), 4.0),
		"nowhere to put it, so nowhere is returned"
	)


func test_grounded_species_are_unaffected() -> void:
	# The hook has to default to false or every mob starts levitating.
	for name: String in ["zombie", "pig", "creeper", "zombie_pigman"]:
		var mob: Node = MobRegistry.script_for(name).new()
		_parent.add_child(mob)
		assert_false(mob.call("spawns_airborne"), "%s still stands on the ground" % name)


# --- Resource sharing and stress ---


func test_many_ghasts_share_one_mesh_per_part() -> void:
	# §8.2: "Meshes and materials must be shared." MobCube caches by
	# (size, texture, origin), so nine identical tentacle boxes across
	# twelve ghasts must not be a hundred and eight ArrayMeshes.
	var meshes: Dictionary = {}
	var mobs: Array[Node] = []
	for _i: int in range(12):
		mobs.append(_ghast())
	for mob: Node in mobs:
		meshes[(mob.get("_body_mesh") as MeshInstance3D).mesh.get_instance_id()] = true
		for pivot: Node3D in mob.get("_tentacle_pivots") as Array:
			for child: Node in pivot.get_children():
				if child is MeshInstance3D:
					meshes[(child as MeshInstance3D).mesh.get_instance_id()] = true
	# One body mesh plus at most nine distinct tentacle lengths.
	assert_lte(meshes.size(), 10, "meshes are shared, not rebuilt per ghast")


func test_a_group_of_ghasts_ticks_cheaply() -> void:
	# The bounded stress sample §8.2 asks for. Twelve is well past what
	# the Nether cap would ever produce in one place.
	var w: FakeWorld = _fake_world()
	var mobs: Array[Node] = []
	for i: int in range(12):
		mobs.append(_ghast_at(Vector3(float(i) * 8.0, 70.0, 0.0), w))
	var start: int = Time.get_ticks_usec()
	for _round: int in range(20):
		for mob: Node in mobs:
			mob.call("_ai_tick")
	var elapsed_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
	gut.p(
		"12 ghasts x 20 AI ticks: %.2f ms (%.4f ms per mob-tick)" % [elapsed_ms, elapsed_ms / 240.0]
	)
	assert_lt(elapsed_ms, 400.0, "240 ghast ticks stay off the frame budget")


func test_ticking_a_ghast_allocates_no_children() -> void:
	# A ghast that has not fired must not accumulate nodes. Firing DOES
	# add one — the fireball — and that is the only growth allowed.
	var mob: Node = _ghast_at(Vector3(0, 70, 0), _fake_world())
	var before: int = mob.get_child_count()
	for _i: int in range(200):
		mob.call("_ai_tick")
	assert_eq(mob.get_child_count(), before, "no node churn across 200 ticks")


# --- Persistence ---


func test_charge_and_waypoint_round_trip() -> void:
	var mob: Node = _ghast_at(Vector3(4, 80, -2))
	mob.set("charge", 13)
	mob.set("waypoint", Vector3(9, 84, 3))
	var payload: Dictionary = mob.call("to_save_dict")
	var restored: Node = _ghast()
	restored.call("restore_from_dict", payload)
	assert_eq(restored.get("charge"), 13, "mid-charge survives")
	assert_eq(restored.get("prev_charge"), 13, "and the render counter is seeded to match")
	assert_eq(restored.get("waypoint"), Vector3(9, 84, 3), "waypoint survives")


func test_an_old_save_without_the_fields_loads_at_rest() -> void:
	var restored: Node = _ghast()
	restored.call("restore_from_dict", {"pos": Vector3(0, 70, 0), "hp": 10})
	assert_eq(restored.get("charge"), 0, "no charge in flight")
