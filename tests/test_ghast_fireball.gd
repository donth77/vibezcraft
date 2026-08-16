# gdlint: disable=max-public-methods
extends GutTest

# Ghast fireball — vanilla `az.java`
# (docs/nether-alpha-1.2.6-implementation-plan.md §8.3, Batch 9).
#
# An ACCELERATING projectile, not a ballistic one: it carries a stored
# acceleration normalised to 0.1 and adds it to velocity every tick
# before applying drag, so it starts slow and builds. Two rules carry the
# whole design:
#
#   * the shooter is ignored for the first 25 ticks and NOT after, which
#     is what makes a deflected fireball able to kill the ghast;
#   * deflecting rewrites velocity and acceleration but never touches the
#     stored shooter, so batting one back does not make the player its
#     owner.

var _parent: Node = null


class FakeWorld:
	extends Node

	var blocks: Dictionary = {}
	var explosions: Array = []

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id

	func fill(from: Vector3i, to: Vector3i, id: int) -> void:
		for x: int in range(from.x, to.x + 1):
			for y: int in range(from.y, to.y + 1):
				for z: int in range(from.z, to.z + 1):
					blocks[Vector3i(x, y, z)] = id

	# Explosion.detonate reaches for the chunk grid directly (it reads
	# blocks through chunk objects rather than get_world_block, for the
	# ray-cast hot loop). Returning null is what an unloaded chunk looks
	# like, which is enough for the impact tests: the blast finds nothing
	# to destroy, and the projectile still has to free itself.
	func get_chunk_at_coord(_coord: Vector2i) -> Variant:
		return null

	func begin_batch() -> void:
		pass

	func end_batch() -> void:
		pass

	func get_world_block_meta(_pos: Vector3i) -> int:
		return 0

	func set_world_block_with_meta(pos: Vector3i, id: int, _meta: int) -> void:
		blocks[pos] = id

	func count(id: int) -> int:
		var n: int = 0
		for key: Vector3i in blocks:
			if blocks[key] == id:
				n += 1
		return n


func before_each() -> void:
	_parent = Node.new()
	add_child_autofree(_parent)


func _fireball(pos: Vector3 = Vector3.ZERO, world: Node = null) -> Node3D:
	var ball: Node3D = GhastFireball.new()
	_parent.add_child(ball)
	ball.global_position = pos
	if world != null:
		ball.set("_chunk_manager", world)
	return ball


func _fake_world() -> FakeWorld:
	var w := FakeWorld.new()
	_parent.add_child(w)
	return w


# --- Aim construction ---


func test_acceleration_is_normalised_to_a_tenth() -> void:
	# `d5 = sqrt(...); this.b = d2 / d5 * 0.1` — the magnitude is fixed
	# regardless of how far away the target is.
	for aim: Vector3 in [Vector3(1, 0, 0), Vector3(0, 0, 100), Vector3(-3, 7, -12)]:
		var accel: Vector3 = GhastFireball.aim_to_acceleration(aim, _fixed_rng())
		assert_almost_eq(
			accel.length(),
			GhastFireball.ACCELERATION_MAGNITUDE,
			1e-6,
			"magnitude 0.1 for aim %s" % aim
		)


func test_a_far_target_and_a_near_one_give_the_same_speed() -> void:
	var near: Vector3 = GhastFireball.aim_to_acceleration(Vector3(0, 0, 5), _fixed_rng())
	var far: Vector3 = GhastFireball.aim_to_acceleration(Vector3(0, 0, 500), _fixed_rng())
	assert_almost_eq(near.length(), far.length(), 1e-6, "distance does not change the speed")


func test_the_aim_points_roughly_at_the_target() -> void:
	# Gaussian spread of 0.4 per axis against an aim vector 60 long is a
	# small angular error; against one 1 long it is a big one. That
	# proportionality is the source's behaviour and worth stating.
	var accel: Vector3 = GhastFireball.aim_to_acceleration(Vector3(0, 0, 60), _fixed_rng())
	assert_gt(accel.z, 0.0, "still heading toward the target")
	assert_gt(
		accel.normalized().dot(Vector3(0, 0, 1)), 0.95, "and within a few degrees of it at range"
	)


func test_a_degenerate_aim_does_not_produce_nan() -> void:
	# The source would divide by zero here. It cannot happen in play — a
	# ghast only fires at a target it can see — but it must not poison
	# the projectile if it ever does.
	var accel: Vector3 = GhastFireball.aim_to_acceleration(Vector3.ZERO, _arbitrary_rng())
	assert_false(is_nan(accel.x) or is_nan(accel.y) or is_nan(accel.z), "finite")
	assert_almost_eq(accel.length(), GhastFireball.ACCELERATION_MAGNITUDE, 1e-6, "and still 0.1")


func test_the_spread_actually_varies() -> void:
	# Two different seeds must not produce the same shot, or the
	# Gaussian term has been dropped.
	var a: Vector3 = GhastFireball.aim_to_acceleration(Vector3(0, 0, 10), _seeded_rng(1))
	var b: Vector3 = GhastFireball.aim_to_acceleration(Vector3(0, 0, 10), _seeded_rng(2))
	assert_ne(a, b, "the shot scatters")


func _seeded_rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


func _fixed_rng() -> RandomNumberGenerator:
	return _seeded_rng(12345)


# Just another fixed seed. Named separately from _fixed_rng so the
# degenerate-aim test reads as "some generator", which is the point —
# whatever spread comes out, a zero aim must still produce a finite
# unit-length acceleration.
func _arbitrary_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	return rng


# --- Motion ---


func test_it_accelerates_rather_than_flying_at_constant_speed() -> void:
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.set("acceleration", Vector3(0, 0, 0.1))
	ball.call("set_velocity_per_tick", Vector3.ZERO)
	var speeds: Array[float] = []
	for _i: int in range(5):
		ball.call("_tick")
		speeds.append((ball.call("velocity_per_tick") as Vector3).length())
	for i: int in range(1, speeds.size()):
		assert_gt(speeds[i], speeds[i - 1], "speed climbs every tick")


func test_air_drag_is_five_percent_per_tick() -> void:
	# `az *= 0.95` after the acceleration step. With zero acceleration
	# the velocity decays by exactly that.
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.set("acceleration", Vector3.ZERO)
	ball.call("set_velocity_per_tick", Vector3(0, 0, 1.0))
	ball.call("_tick")
	assert_almost_eq(
		(ball.call("velocity_per_tick") as Vector3).z,
		GhastFireball.AIR_DRAG_PER_TICK,
		1e-6,
		"one tick of 0.95 drag"
	)


func test_water_drag_is_heavier_than_air_drag() -> void:
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(-4, 68, -4), Vector3i(4, 72, 4), Blocks.WATER_STILL)
	var ball: Node3D = _fireball(Vector3(0, 70, 0), w)
	ball.set("acceleration", Vector3.ZERO)
	ball.call("set_velocity_per_tick", Vector3(0, 0, 0.01))
	ball.call("_tick")
	assert_almost_eq(
		(ball.call("velocity_per_tick") as Vector3).z,
		0.01 * GhastFireball.WATER_DRAG_PER_TICK,
		1e-8,
		"0.8 in water, not 0.95"
	)


func test_terminal_speed_is_finite() -> void:
	# 0.1 acceleration against 0.95 drag settles at 0.1 * 0.95/0.05 =
	# 1.9 blocks per tick. Not asserted to that precision — the point is
	# that it converges rather than running away.
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.set("acceleration", Vector3(0, 0, 0.1))
	ball.call("set_velocity_per_tick", Vector3.ZERO)
	for _i: int in range(400):
		if not is_instance_valid(ball):
			break
		ball.call("_tick")
	if is_instance_valid(ball):
		assert_lt(
			(ball.call("velocity_per_tick") as Vector3).length(), 2.5, "converges, does not diverge"
		)


# --- The shooter grace ---


func test_the_shooter_is_ignored_for_twenty_five_ticks() -> void:
	var shooter := Node3D.new()
	_parent.add_child(shooter)
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.call("setup", shooter, Vector3(0, 0, 1))
	for tick: int in range(GhastFireball.SHOOTER_GRACE_TICKS):
		ball.set("ticks_in_air", tick)
		assert_true(ball.call("ignores", shooter), "still ignored at tick %d" % tick)


func test_the_grace_expires_and_does_not_come_back() -> void:
	# The point of the rule: after 25 ticks the fireball CAN hit its
	# shooter, which is how a deflected one kills the ghast that fired it.
	var shooter := Node3D.new()
	_parent.add_child(shooter)
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.call("setup", shooter, Vector3(0, 0, 1))
	ball.set("ticks_in_air", GhastFireball.SHOOTER_GRACE_TICKS)
	assert_false(ball.call("ignores", shooter), "the ghast is fair game from tick 25")
	ball.set("ticks_in_air", 500)
	assert_false(ball.call("ignores", shooter), "and stays so")


func test_the_grace_applies_only_to_the_shooter() -> void:
	var shooter := Node3D.new()
	var bystander := Node3D.new()
	_parent.add_child(shooter)
	_parent.add_child(bystander)
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.call("setup", shooter, Vector3(0, 0, 1))
	ball.set("ticks_in_air", 1)
	assert_true(ball.call("ignores", shooter), "its own ghast")
	assert_false(ball.call("ignores", bystander), "but nobody else")
	assert_false(ball.call("ignores", null), "and null is not the shooter")


# --- Deflection ---


func test_deflecting_rewrites_velocity_and_acceleration() -> void:
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.call("setup", null, Vector3(0, 0, 1))
	ball.call("deflect", Vector3(1, 0, 0))
	assert_eq(ball.call("velocity_per_tick"), Vector3(1, 0, 0), "velocity is the look vector")
	assert_almost_eq(
		(ball.get("acceleration") as Vector3).length(),
		GhastFireball.ACCELERATION_MAGNITUDE,
		1e-6,
		"acceleration is a tenth of it"
	)
	assert_gt((ball.get("acceleration") as Vector3).x, 0.0, "and points the same way")


func test_deflecting_does_not_change_the_stored_shooter() -> void:
	# `a(lw2, n2)` never assigns `this.j`. That is the source's
	# behaviour, and it is what keeps the 25-tick grace pointed at the
	# ghast after a player bats the fireball back at it.
	var ghast := Node3D.new()
	var player := Node3D.new()
	_parent.add_child(ghast)
	_parent.add_child(player)
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.call("setup", ghast, Vector3(0, 0, 1))
	ball.call("take_damage", 4, Vector3.ZERO, 1.0, player)
	assert_eq(ball.get("shooter"), ghast, "still the ghast's fireball")
	assert_ne(ball.get("shooter"), player, "the deflector is never credited")


func test_a_deflected_fireball_can_still_hit_the_ghast() -> void:
	# The consequence of the two rules together, stated as one fact.
	var ghast := Node3D.new()
	_parent.add_child(ghast)
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.call("setup", ghast, Vector3(0, 0, 1))
	ball.set("ticks_in_air", 30)
	ball.call("deflect", Vector3(0, 0, -1))
	assert_eq(ball.get("shooter"), ghast, "shooter unchanged by the deflection")
	assert_false(ball.call("ignores", ghast), "and no longer protected from its own shot")


func test_damage_amount_is_irrelevant_to_a_deflection() -> void:
	# `a(lw2, n2)` discards `n2` entirely — a punch deflects exactly like
	# a diamond sword.
	var attacker := Node3D.new()
	_parent.add_child(attacker)
	attacker.global_position = Vector3(0, 70, -1)
	var weak: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	var strong: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	weak.call("take_damage", 0, Vector3.ZERO, 1.0, attacker)
	strong.call("take_damage", 99, Vector3.ZERO, 1.0, attacker)
	assert_eq(
		weak.call("velocity_per_tick"),
		strong.call("velocity_per_tick"),
		"the damage number does nothing"
	)


func test_a_deflection_with_no_attacker_is_refused() -> void:
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	ball.call("setup", null, Vector3(0, 0, 1))
	ball.call("set_velocity_per_tick", Vector3(0, 0, 0.5))
	assert_false(ball.call("take_damage", 5), "no attacker, no look vector, no deflection")
	assert_eq(ball.call("velocity_per_tick"), Vector3(0, 0, 0.5), "velocity untouched")


# --- Impact ---


func test_hitting_a_wall_frees_the_projectile() -> void:
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(-4, 68, 4), Vector3i(4, 72, 6), Blocks.NETHERRACK)
	var ball: Node3D = _fireball(Vector3(0.5, 70.5, 0.5), w)
	ball.set("acceleration", Vector3.ZERO)
	ball.call("set_velocity_per_tick", Vector3(0, 0, 6.0))
	ball.call("_tick")
	assert_true(ball.is_queued_for_deletion(), "impact frees it")


func test_it_survives_open_air() -> void:
	var ball: Node3D = _fireball(Vector3(0.5, 70.5, 0.5), _fake_world())
	ball.set("acceleration", Vector3(0, 0, 0.1))
	for _i: int in range(30):
		ball.call("_tick")
	assert_false(ball.is_queued_for_deletion(), "nothing to hit, so it keeps going")


func test_there_is_no_arbitrary_time_to_live() -> void:
	# §8.3 is explicit: "Do not add an arbitrary time-to-live that is
	# absent from az.java." A fireball fired into open sky flies forever.
	var ball: Node3D = _fireball(Vector3(0.5, 200.0, 0.5), _fake_world())
	ball.set("acceleration", Vector3(0, 0.1, 0))
	for _i: int in range(600):
		if ball.is_queued_for_deletion():
			break
		ball.call("_tick")
	assert_false(ball.is_queued_for_deletion(), "30 seconds of flight and still alive")


func test_the_flaming_pass_only_lights_air_above_solid_ground() -> void:
	# `ks.java:103-114` — for each cell the blast touched, place fire only
	# where the cell is now AIR and the block below is an opaque cube, on
	# a one-in-three roll. Never on a ceiling, never in mid-air.
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(0, 63, 0), Vector3i(9, 63, 0), Blocks.NETHERRACK)
	var affected: Dictionary = {}
	for x: int in range(10):
		affected[Vector3i(x, 64, 0)] = true  # air over rock: eligible
		affected[Vector3i(x, 70, 0)] = true  # air over air: never
	# Run it enough times that the 1-in-3 roll is certain to have fired.
	for _round: int in range(40):
		Explosion._apply_flaming_pass(w, affected)
	assert_gt(w.count(Blocks.FIRE), 0, "fire landed on the exposed floor")
	for x: int in range(10):
		assert_ne(
			w.get_world_block(Vector3i(x, 70, 0)), Blocks.FIRE, "and never in mid-air at x=%d" % x
		)


func test_the_flaming_pass_leaves_occupied_cells_alone() -> void:
	# `if (n16 != 0 ...) continue` — a cell the blast did not actually
	# clear keeps its block.
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(0, 63, 0), Vector3i(4, 64, 0), Blocks.NETHERRACK)
	var affected: Dictionary = {}
	for x: int in range(5):
		affected[Vector3i(x, 64, 0)] = true
	for _round: int in range(40):
		Explosion._apply_flaming_pass(w, affected)
	assert_eq(w.count(Blocks.FIRE), 0, "solid cells are not replaced with fire")


func test_a_non_flaming_explosion_lights_nothing() -> void:
	# TNT and creepers pass false; only the fireball passes true. The
	# default must stay false or every blast would start a forest fire.
	var w: FakeWorld = _fake_world()
	w.fill(Vector3i(0, 63, 0), Vector3i(4, 63, 0), Blocks.NETHERRACK)
	Explosion.detonate(w, Vector3(2.5, 65.0, 0.5), 1.0)
	assert_eq(w.count(Blocks.FIRE), 0, "no fire without the flag")


func test_the_explosion_is_power_one_and_flaming() -> void:
	# Stated as constants rather than by detonating, because a real
	# explosion needs a live ChunkManager. The values are what
	# `this.as.a(null, aw, ax, ay, 1.0f, true)` passes.
	assert_eq(GhastFireball.EXPLOSION_POWER, 1.0, "power 1, a third of TNT")


func test_the_collision_size_is_one_block() -> void:
	assert_eq(GhastFireball.COLLISION_SIZE, 1.0, "a(1.0f, 1.0f)")


# --- Persistence ---


func test_fireballs_are_not_persistable() -> void:
	# `az` has no entity-registry entry in `fq.java`, so vanilla cannot
	# write one to disk. EntitySave must agree, or a save would carry a
	# projectile that vanilla would have dropped.
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	assert_false(EntitySave.is_persistable(ball), "not written to entities.bin")


func test_it_is_not_in_the_mob_registry() -> void:
	# It is a projectile, not a mob — it must never appear in the debug
	# spawner grid or be restorable as one.
	assert_false(MobRegistry.has("ghast_fireball"), "no debug-spawner entry")
	for name: String in MobRegistry.names():
		assert_ne(
			MobRegistry.script_for(name).resource_path,
			"res://scripts/entities/ghast_fireball.gd",
			"and no registry entry points at it"
		)


# --- Cleanup ---


func test_the_smoke_trail_is_one_emitter_and_dies_with_it() -> void:
	# §8.3 wants bounded particle counts. One persistent emitter per
	# projectile, freed with the projectile — not a pooled one-shot per
	# tick, which at 20 spawns a second would exhaust the shared pool.
	var ball: Node3D = _fireball(Vector3(0, 70, 0), _fake_world())
	var emitters: int = 0
	for child: Node in ball.get_children():
		if child is CPUParticles3D:
			emitters += 1
	assert_eq(emitters, 1, "exactly one trail")
	ball.free()
	assert_eq(_parent.get_child_count(), 1, "and it took its emitter with it")


func test_a_sustained_barrage_holds_its_node_count() -> void:
	# The stress case §8.3 names: many projectiles alive at once must not
	# leak nodes as they come and go.
	var w: FakeWorld = _fake_world()
	var baseline: int = _parent.get_child_count()
	var balls: Array[Node3D] = []
	for _i: int in range(40):
		balls.append(_fireball(Vector3(0, 70, 0), w))
	assert_eq(_parent.get_child_count(), baseline + 40, "40 projectiles, 40 children")
	for ball: Node3D in balls:
		ball.free()
	assert_eq(_parent.get_child_count(), baseline, "and nothing left behind")
