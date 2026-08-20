class_name GhastFireball
extends Node3D

# Vanilla Alpha 1.2.6 EntityFireball (`az.java`).
# See docs/nether-alpha-1.2.6-implementation-plan.md §8.3.
#
# An accelerating projectile, not a ballistic one. `az` carries a stored
# acceleration vector normalised to 0.1 and ADDS it to velocity every
# tick before applying drag, so a fireball starts slow and builds up —
# which is why a ghast's shot is dodgeable up close and lethal at range.
#
# Two details are easy to get wrong and both are load-bearing:
#
#   * the shooter is ignored for the first 25 ticks (`lw3 == this.j &&
#     this.l < 25`), so a ghast cannot blow itself up on the shot it just
#     fired — and after 25 ticks it CAN, which is how a fireball
#     deflected straight back kills the thing that fired it;
#   * deflecting does NOT change the stored shooter. `a(lw2, n2)`
#     rewrites velocity and acceleration from the attacker's look vector
#     and leaves `this.j` alone, so a player who bats a fireball back is
#     never credited as its owner and the 25-tick grace still belongs to
#     the ghast.
#
# There is deliberately no time-to-live: `az.java` has none, and the only
# despawn paths are impact and the inherited 1200-tick in-ground timer
# that a fireball can never actually reach.

# `a(1.0f, 1.0f)` — a one-block collision size.
const COLLISION_SIZE: float = 1.0

# The constructor's aim spread and speed. Each axis of the aim vector
# gets `nextGaussian() * 0.4` added BEFORE normalisation, so the spread
# is proportional to how far off-axis it lands, not a fixed cone.
const AIM_GAUSSIAN_SPREAD: float = 0.4
const ACCELERATION_MAGNITUDE: float = 0.1

# `f4 = 0.95f`, or `0.8f` while in water. Per tick.
const AIR_DRAG_PER_TICK: float = 0.95
const WATER_DRAG_PER_TICK: float = 0.8
const TICKS_PER_SEC: float = 20.0

# `lw3 == this.j && this.l < 25` — the shooter grace, in ticks.
const SHOOTER_GRACE_TICKS: int = 25

# `this.as.a(null, aw, ax, ay, 1.0f, true)` — a power-1 explosion with
# fire, and a NULL source so the blast damages the shooter like anything
# else standing there.
const EXPLOSION_POWER: float = 1.0

# `gl.java` renders it as the snowball item tile at 2x scale. §8.3 is
# explicit that this reuses Items.SNOWBALL rather than inventing a
# fire-charge texture, because Alpha has no such sprite.
const VISUAL_PIXEL_SIZE: float = 0.03  # 16 px x 0.03 = 0.48 m, ~2x a held item

# One persistent smoke emitter rather than a pooled one-shot per tick:
# `e_()` emits a smoke particle EVERY tick, which is 20 spawns a second
# per fireball, and FluidFx's shared pool is six emitters deep. A
# steady-state trail is bounded by construction — one emitter, freed with
# the projectile.
const _SMOKE_LIFETIME: float = 0.6
const _SMOKE_AMOUNT: int = 24
# `for (i3 = 0; i3 < 4; ++i3)` — four bubbles per tick while submerged.
const _BUBBLES_PER_TICK: int = 4

# `this.b/c/d` — the stored acceleration, added to velocity each tick.
var acceleration: Vector3 = Vector3.ZERO
# `this.j` — the shooter. Never reassigned, including on deflection.
var shooter: Node = null
# `this.l` — ticks in air, which the shooter grace counts against.
var ticks_in_air: int = 0

var _velocity: Vector3 = Vector3.ZERO
var _chunk_manager: Node = null
# The 1x1 ray-visible collider — see _build_hit_area.
var _hit_area: Area3D = null
var _sprite: Sprite3D = null
var _smoke: CPUParticles3D = null
var _tick_accum: float = 0.0
var _last_light_brightness: float = -1.0


# `az(cy, hf, d2, d3, d4)`. `aim` is the raw target delta — NOT
# normalised, because the Gaussian spread is added to it first and the
# normalisation happens after, which is what makes the spread relative.
#
# `rng` lets a test supply a deterministic source; the default is the
# global one, matching every other spawn path in this project.
func setup(from: Node, aim: Vector3, rng: RandomNumberGenerator = null) -> void:
	shooter = from
	acceleration = aim_to_acceleration(aim, rng)
	_velocity = Vector3.ZERO


# The constructor's aim maths, extracted so it is testable without a
# scene: add Gaussian spread per axis, normalise, scale to 0.1.
static func aim_to_acceleration(aim: Vector3, rng: RandomNumberGenerator = null) -> Vector3:
	var spread := Vector3.ZERO
	if rng != null:
		spread = Vector3(
			rng.randfn(0.0, 1.0) * AIM_GAUSSIAN_SPREAD,
			rng.randfn(0.0, 1.0) * AIM_GAUSSIAN_SPREAD,
			rng.randfn(0.0, 1.0) * AIM_GAUSSIAN_SPREAD
		)
	else:
		spread = Vector3(
			randfn(0.0, 1.0) * AIM_GAUSSIAN_SPREAD,
			randfn(0.0, 1.0) * AIM_GAUSSIAN_SPREAD,
			randfn(0.0, 1.0) * AIM_GAUSSIAN_SPREAD
		)
	var aimed: Vector3 = aim + spread
	var length: float = aimed.length()
	if length < 0.0001:
		# The source would divide by zero here. It cannot happen in
		# practice — a ghast only fires at a target it can see, so the
		# delta is never zero — but a degenerate aim must not produce NaN.
		return Vector3(0.0, 0.0, ACCELERATION_MAGNITUDE)
	return aimed / length * ACCELERATION_MAGNITUDE


func _ready() -> void:
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	# Swept by ChunkManager._free_dimension_scene: a projectile that
	# crossed a portal as a live node kept flying in the destination
	# dimension at its source coordinates (audit finding #5).
	add_to_group("transient_projectile")
	_build_sprite()
	_build_smoke_trail()
	_build_hit_area()


# `a(1.0f, 1.0f)` — a one-block collision size. Without a collider the
# fireball was invisible to every intersect_ray in the game: player
# melee and arrows could never touch it, so the deflection mechanic —
# correct and tested at the logic level — had no physical route in
# (audit finding #2). Monitoring stays off; the area exists purely to be
# ray-visible, exactly like the mobs' head-hit areas.
func _build_hit_area() -> void:
	_hit_area = Area3D.new()
	_hit_area.monitoring = false
	_hit_area.monitorable = true
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * COLLISION_SIZE
	shape.shape = box
	_hit_area.add_child(shape)
	add_child(_hit_area)


func _build_sprite() -> void:
	var tex: Texture2D = ItemIcons.icon_for(Items.SNOWBALL)
	if tex == null:
		return
	_sprite = Sprite3D.new()
	_sprite.texture = tex
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_sprite.pixel_size = VISUAL_PIXEL_SIZE
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.shaded = false
	_sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_sprite)


func _build_smoke_trail() -> void:
	_smoke = CPUParticles3D.new()
	_smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINT
	_smoke.direction = Vector3.UP
	_smoke.spread = 25.0
	_smoke.initial_velocity_min = 0.1
	_smoke.initial_velocity_max = 0.4
	_smoke.gravity = Vector3(0.0, 0.6, 0.0)
	_smoke.scale_amount_min = 0.5
	_smoke.scale_amount_max = 1.0
	_smoke.amount = _SMOKE_AMOUNT
	_smoke.lifetime = _SMOKE_LIFETIME
	# Local so the trail is left behind in world space rather than
	# dragged along with the projectile.
	_smoke.local_coords = false
	var quad := QuadMesh.new()
	quad.size = Vector2(0.18, 0.18)
	quad.material = FluidFx.get_largesmoke_material()
	_smoke.mesh = quad
	# `e_()` emits from `ax + 0.5`.
	_smoke.position = Vector3(0.0, 0.5, 0.0)
	_smoke.emitting = true
	add_child(_smoke)


# `e_()` runs at 20 Hz in the source, and every term in it — the drag
# exponent, the acceleration step, the grace counter — is per tick. A
# delta-scaled version would drift, so this drives a fixed tick.
func _physics_process(delta: float) -> void:
	_tick_accum += delta
	var ticked: bool = false
	while _tick_accum >= 1.0 / TICKS_PER_SEC:
		_tick_accum -= 1.0 / TICKS_PER_SEC
		ticked = true
		if _tick():
			return
	if ticked:
		_update_entity_lighting()


# One source tick. Returns true when the fireball destroyed itself, so
# the caller stops touching it.
func _tick() -> bool:
	ticks_in_air += 1
	var target: Vector3 = global_position + _velocity
	# Block sweep first, then entities — the source ray-traces blocks and
	# then looks for a nearer entity hit along the same segment.
	var block_hit: Variant = _sweep_block(global_position, target)
	var entity_hit: Node = _sweep_entity(global_position, target)
	if entity_hit != null:
		# `nx2.g.a(this.j, 0)` — the direct hit deals ZERO damage and is
		# credited to the SHOOTER, not the projectile; the explosion does
		# the real work. Signatures differ per target: the player's is
		# (int, String, Vector3) — calling it mob-style was a runtime
		# type error on every direct player hit (audit finding #9) — and
		# a struck FIREBALL deflects (az.a), after which this one
		# explodes, which is also what vanilla's fireball-on-fireball
		# collision does.
		if entity_hit is MobBase:
			entity_hit.take_damage(0, _velocity.normalized(), 0.0, shooter)
		elif entity_hit is GhastFireball:
			entity_hit.take_damage(0, _velocity.normalized(), 0.0, null)
		elif entity_hit.has_method("take_damage"):
			entity_hit.call("take_damage", 0, "fireball", _velocity.normalized())
		_explode()
		return true
	if block_hit != null:
		global_position = block_hit as Vector3
		_explode()
		return true
	global_position = target
	# Water: four bubbles, then the heavier drag. The source emits the
	# bubbles BEFORE swapping the drag factor, which is why the ordering
	# here matters even though nothing observes it between the two.
	var drag: float = AIR_DRAG_PER_TICK
	if _in_water():
		_emit_bubbles()
		drag = WATER_DRAG_PER_TICK
	# Acceleration THEN drag, in that order — the reverse would leave the
	# terminal speed 5% lower.
	_velocity += acceleration
	_velocity *= drag
	return false


func _in_water() -> bool:
	if _chunk_manager == null:
		return false
	var cell := Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	return Blocks.is_water(_chunk_manager.get_world_block(cell))


func _emit_bubbles() -> void:
	# The source spawns four discrete bubble particles behind the
	# projectile each tick. The trail emitter already provides a
	# continuous stream; retinting it while submerged reads the same and
	# keeps the node count flat, which is what §8.3's bounded-particle
	# requirement is protecting.
	if _smoke != null:
		_smoke.color = Color(0.7, 0.8, 1.0)


# Walk the segment and return the last clear point before the first
# solid cell, or null. Same sampling the snowball and arrow use.
func _sweep_block(from: Vector3, to: Vector3) -> Variant:
	if _chunk_manager == null:
		return null
	var segment_len: float = (to - from).length()
	if segment_len < 0.001:
		return null
	var samples: int = maxi(1, int(ceil(segment_len * 16.0)))
	var prev: Vector3 = from
	for i in range(1, samples + 1):
		var p: Vector3 = from.lerp(to, float(i) / float(samples))
		var cell := Vector3i(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
		var id: int = _chunk_manager.get_world_block(cell)
		if id != Blocks.AIR and Blocks.is_solid_collision(id):
			return prev
		prev = p
	return null


# The nearest collidable entity along the segment, skipping the shooter
# while the grace window is open.
func _sweep_entity(from: Vector3, to: Vector3) -> Node:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return null
	var query := PhysicsRayQueryParameters3D.create(from, to)
	# Always exclude our own hit area — the ray starts inside it — and
	# the shooter's body while the grace window holds.
	var excludes: Array = []
	if _hit_area != null:
		excludes.append(_hit_area.get_rid())
	if ignores(shooter) and shooter != null and shooter.has_method("get_rid"):
		excludes.append(shooter.call("get_rid"))
	query.exclude = excludes
	query.collide_with_bodies = true
	query.collide_with_areas = true
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	var node: Node = hit.get("collider") as Node
	while node != null and not node.has_method("take_damage"):
		node = node.get_parent()
	if node == null:
		return null
	if node == shooter and ignores(shooter):
		return null
	return node


# True while `entity` is still inside the shooter's 25-tick grace. Public
# because it is the single most testable statement of the rule, and the
# ghast test asserts on it directly.
func ignores(entity: Node) -> bool:
	if entity == null or entity != shooter:
		return false
	return ticks_in_air < SHOOTER_GRACE_TICKS


# `a(lw2, n2)` — deflection. Take the attacker's look vector as the new
# velocity and set acceleration to a tenth of it.
#
# The stored shooter is NOT reassigned. That is the source's behaviour,
# not an oversight: a player who bats a fireball back is never its owner,
# so the ghast's grace window keeps ticking against the ghast and a
# returned fireball can kill it.
func deflect(look_direction: Vector3) -> void:
	if look_direction.length_squared() < 0.0001:
		return
	_velocity = look_direction
	acceleration = look_direction * ACCELERATION_MAGNITUDE


# Player and mob melee both route here. Damage is ignored — the source
# discards `n2` entirely and only uses the attacker's look vector.
func take_damage(
	_amount: int,
	knockback_dir: Vector3 = Vector3.ZERO,
	_knockback_strength: float = 1.0,
	attacker: Node = null
) -> bool:
	var look: Vector3 = knockback_dir
	if attacker != null and attacker.has_method("look_direction"):
		look = attacker.call("look_direction")
	elif attacker is Node3D:
		look = -(attacker as Node3D).global_transform.basis.z
	if look.length_squared() < 0.0001:
		return false
	deflect(look.normalized())
	return true


func _explode() -> void:
	if _chunk_manager != null:
		# Source `null` so the blast treats the shooter like any other
		# entity in range — a ghast that fires into a wall beside itself
		# takes its own explosion, and so does a player who deflects one
		# into their own feet.
		Explosion.detonate(_chunk_manager, global_position, EXPLOSION_POWER, null, true)
	queue_free()


func _update_entity_lighting() -> void:
	if _sprite == null or _chunk_manager == null:
		return
	var cell := Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	var brightness: float = EntityLighting.sample_brightness(_chunk_manager, cell)
	if absf(brightness - _last_light_brightness) < 0.01:
		return
	_last_light_brightness = brightness
	# `bg = 10` every tick keeps the fireball rendered as burning, so it
	# is never darker than a flame. Floor the sampled brightness.
	_sprite.modulate = Color(maxf(brightness, 0.8), maxf(brightness, 0.8), maxf(brightness, 0.8))


# Current velocity, in blocks per tick — the unit the source works in.
func velocity_per_tick() -> Vector3:
	return _velocity


func set_velocity_per_tick(v: Vector3) -> void:
	_velocity = v
