class_name SnowballProjectile
extends Node3D

# Vanilla Alpha 1.2.6 EntitySnowball port. Right-click on a held
# SNOWBALL item spawns one of these with the player's look direction ×
# THROW_SPEED. Travels with vanilla per-tick gravity (0.03 motY/tick)
# and air drag (0.99/tick), sweeps for block/entity collision, on hit
# spawns a small particle burst and queue_free's.
#
# Vanilla behavior summary (`ag.java`, EntitySnowball):
#   * Damage to entities: ZERO. Calls `attackEntityFrom(snowball, 0)`
#     which still triggers the hurt flash + knockback + iframe — useful
#     for pulling aggro from across a gap without dealing damage.
#   * No melt-on-land, no place-on-land, no chain. Single-shot fizzle.
#   * Despawns on first hit OR after LIFETIME_SEC (safety net).
#
# Out of scope (Beta-era additions deliberately skipped):
#   * Blaze-melt damage (1 HP per snowball on Blaze)
#   * Snow Golem multi-shot (Snow Golem doesn't ship in Alpha)

# Vanilla `ag.java` calls `setThrowableHeading(this, x, y, z, 1.5f,
# 1.0f)` — speed scalar 1.5 blocks/tick = 30 m/s peak. Matches the
# vanilla feel: snappy throw, falls quickly under gravity.
const THROW_SPEED: float = 22.0

# Vanilla EntityThrowable per-tick constants. fa.java:181 sets gravity
# = 0.03 motY/tick downward, drag = 0.99 motion/tick. Converted to per-
# second for Godot's variable-delta integration.
const GRAVITY_PER_TICK: float = 0.03
const AIR_DRAG_PER_TICK: float = 0.99
const TICKS_PER_SEC: float = 20.0

# Safety despawn if the snowball never hits anything (open-sky throw,
# stuck in worldgen edge case). Vanilla projectiles get culled by the
# 20-second tickAlive cap; 10 s is plenty for the snowball's small
# horizontal range under gravity.
const LIFETIME_SEC: float = 10.0

# Visual scale — vanilla renders the snowball at 0.5 × the sprite
# pixel size. Sprite is 16×16; at our 1/16 m/pixel that's 0.5 m
# (too big — vanilla shrinks to ~0.25 m at render time).
const VISUAL_PIXEL_SIZE: float = 0.015  # 16 px × 0.015 = 0.24 m

# Knockback applied when hitting an entity. Vanilla doesn't move the
# mob in Alpha (just the hurt flash), but a small kick reads as a
# "real impact" visually; clamp low so it can't be used as a CC.
const HIT_KNOCKBACK_STRENGTH: float = 0.5

var _velocity: Vector3 = Vector3.ZERO
var _spawn_time: float = 0.0
var _thrower: Node = null
var _chunk_manager: Node = null
var _sprite: Sprite3D = null


# interaction.gd::_throw_snowball calls this immediately after
# add_child + global_position set. `thrower` is excluded from the
# entity sweep so the snowball can't self-hit on spawn.
func setup(thrower: Node, vel: Vector3) -> void:
	_thrower = thrower
	_velocity = vel
	_spawn_time = Time.get_ticks_msec() / 1000.0


func _ready() -> void:
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	_build_sprite()


# Sprite3D with the snowball.png texture, set to billboard mode so it
# always faces the camera (vanilla renders 2D snowballs in 3D space
# via the same billboarded-sprite path used for thrown items).
func _build_sprite() -> void:
	var tex: Texture2D = load("res://assets/textures/items/snowball.png") as Texture2D
	if tex == null:
		# Pack path fallback — alpha_vanilla extracted texture.
		tex = (
			load("res://assets/textures/blocks/packs/alpha_vanilla/items/snowball.png") as Texture2D
		)
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


func _physics_process(delta: float) -> void:
	if _tick_lifetime():
		return
	# Per-tick gravity + drag → per-second integration. Same math the
	# arrow uses (see arrow.gd:160-173 for the derivation).
	var gravity_accel: float = GRAVITY_PER_TICK * TICKS_PER_SEC * TICKS_PER_SEC
	var drag_factor: float = pow(AIR_DRAG_PER_TICK, delta * TICKS_PER_SEC)
	_velocity *= drag_factor
	_velocity.y -= gravity_accel * delta
	var step: Vector3 = _velocity * delta
	var new_pos: Vector3 = global_position + step
	# Block sweep first — if the path crosses a solid cell, fizzle at
	# the entry point. Substep resolution mirrors arrow.gd; thin
	# objects (panes, fences) get caught by the per-cell check.
	var block_hit: Variant = _sweep_block_hit_point(global_position, new_pos)
	if block_hit != null:
		_fizzle_at(block_hit)
		return
	# Then entity sweep — sphere check vs mobs in the swept segment.
	if _sweep_entity_hit(global_position, new_pos):
		return
	global_position = new_pos


func _tick_lifetime() -> bool:
	var elapsed: float = Time.get_ticks_msec() / 1000.0 - _spawn_time
	if elapsed > LIFETIME_SEC:
		queue_free()
		return true
	return false


# Walk the segment, return the LAST AIR sample before the first solid
# cell, or null if no hit. Same algorithm arrow.gd uses; fluids don't
# stop the snowball (snowballs in vanilla fly through water/lava
# unaffected by the surface).
func _sweep_block_hit_point(from: Vector3, to: Vector3) -> Variant:
	if _chunk_manager == null:
		return null
	var segment_len: float = (to - from).length()
	if segment_len < 0.001:
		return null
	var samples: int = maxi(1, int(ceil(segment_len * 16.0)))
	var prev: Vector3 = from
	for i in range(1, samples + 1):
		var t: float = float(i) / float(samples)
		var p: Vector3 = from.lerp(to, t)
		var cell := Vector3i(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
		var id: int = _chunk_manager.get_world_block(cell)
		if id != Blocks.AIR and Blocks.is_solid_collision(id):
			return prev
		prev = p
	return null


# Entity sweep — use Godot's physics raycast over the velocity
# segment, hitting collision-layer ALL except the thrower. Vanilla
# Alpha EntitySnowball uses a 0.3-block sphere per tick; the
# raycast-with-margin is a close approximation.
func _sweep_entity_hit(from: Vector3, to: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(from, to)
	# Exclude the thrower so we can't self-hit on spawn.
	if _thrower != null and _thrower.has_method("get_rid"):
		query.exclude = [_thrower.call("get_rid")]
	# Hit BOTH bodies + areas — mobs use Area3D head hitboxes.
	query.collide_with_bodies = true
	query.collide_with_areas = true
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return false
	var collider: Object = hit.get("collider")
	if collider == null:
		return false
	# Walk up the parent chain to find the MobBase or player. Mob hit-
	# areas are Area3D children of the mob root.
	var mob: Node = collider as Node
	while (
		mob != null
		and not (
			mob.has_method("take_damage")
			and (mob is CharacterBody3D or mob.get_parent() is MobBase)
		)
	):
		mob = mob.get_parent()
	if mob == null:
		return false
	_hit_entity(mob, hit.get("position", to))
	return true


# Vanilla EntitySnowball.attackEntityFrom passes damage=0 — only the
# hurt flash + knockback fire, no HP loss. Player and mob both have
# take_damage signatures that accept knockback; we call with amount 0
# so the iframe + flash trigger but health stays put.
func _hit_entity(target: Node, _hit_pos: Vector3) -> void:
	var dir: Vector3 = _velocity.normalized()
	if target is CharacterBody3D and not target is MobBase:
		# Player hit (CharacterBody3D, not a MobBase subclass). Don't
		# damage the player on their own snowball hits — vanilla also
		# zero-damage on self-hits (and the thrower-exclusion above
		# should already prevent this case).
		pass
	elif target.has_method("take_damage"):
		# Mob hit — amount 0 still triggers iframe + hurt flash via
		# mob_base.take_damage. Knockback strength low so it nudges
		# rather than launches.
		target.call("take_damage", 0, dir, HIT_KNOCKBACK_STRENGTH)
	_fizzle_at(global_position)


# Particle burst at the impact point using the snow block material,
# then despawn. Vanilla also plays a faint impact SFX — defer until a
# dedicated "snowball poof" clip ships (currently silent).
func _fizzle_at(pos: Vector3) -> void:
	var parent: Node = get_parent()
	if parent != null:
		var ipos := Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))
		BlockFx.spawn_break(parent, ipos, Blocks.SNOW_BLOCK)
	queue_free()
