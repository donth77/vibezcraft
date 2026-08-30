class_name AlphaWaterParticle
extends Sprite3D

# Alpha 1.2.6's two water particle entities:
#   * `bh.java` (EntityBubbleFX), particles.png tile 32
#   * `mf.java` (EntitySplashFX), a `pc.java` subclass using tiles 20-23
#
# Both are ordinary ticked entities rather than GPU bursts. Keeping one node
# per mote preserves their source atlas pixels, randomized lifetime/scale,
# medium checks, and collision-dependent death behavior.

enum Kind { BUBBLE, SPLASH }

const _PARTICLES_TEXTURE: Texture2D = preload("res://assets/textures/particles/particles.png")
const _TICK_SECONDS: float = 1.0 / 20.0
const _TILE_SIZE_PX: float = 8.0
const _BASE_QUAD_SIZE: float = 0.2
const _BUBBLE_HALF_EXTENTS: Vector3 = Vector3.ONE * 0.01
const _SPLASH_HALF_EXTENTS: Vector3 = Vector3.ONE * 0.005

var _kind: Kind = Kind.BUBBLE
var _age_ticks: int = 0
var _max_age_ticks: int = 1
var _tick_accumulator: float = 0.0
var _motion_per_tick: Vector3 = Vector3.ZERO
var _previous_position: Vector3 = Vector3.ZERO
var _current_position: Vector3 = Vector3.ZERO
var _base_scale: float = 1.0
var _atlas: AtlasTexture


func configure(
	kind: Kind, world_position: Vector3, source_motion_per_tick: Vector3 = Vector3.ZERO
) -> void:
	_kind = kind
	_age_ticks = 0
	_tick_accumulator = 0.0
	_previous_position = world_position
	_current_position = world_position
	global_position = world_position

	_atlas = AtlasTexture.new()
	_atlas.atlas = _PARTICLES_TEXTURE
	_atlas.filter_clip = true
	texture = _atlas
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	pixel_size = _BASE_QUAD_SIZE / _TILE_SIZE_PX
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	transparent = true
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	shaded = false
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# pp.java:37-39. Every particle begins with a 1.0..2.0 render scale.
	_base_scale = (randf() * 0.5 + 0.5) * 2.0
	if _kind == Kind.BUBBLE:
		# bh.java:12-19. The inherited scale gets a second 0.2..0.8 factor,
		# and caller motion is reduced to 20% before independent axis jitter.
		_set_atlas_frame(32)
		_base_scale *= randf() * 0.6 + 0.2
		_motion_per_tick = source_motion_per_tick * 0.2
		_motion_per_tick += Vector3(
			randf() * 0.04 - 0.02,
			randf() * 0.04 - 0.02,
			randf() * 0.04 - 0.02,
		)
	else:
		# pc.java selects 19..22, then mf.java increments the tile once.
		# Tile 23 is wholly transparent in Alpha's sheet and is deliberately
		# retained: one quarter of source splash motes are invisible.
		_set_atlas_frame(20 + randi() % 4)
		_motion_per_tick = _source_particle_motion()
		_motion_per_tick.x *= 0.3
		_motion_per_tick.y = randf() * 0.2 + 0.1
		_motion_per_tick.z *= 0.3
		# mf.java only honors supplied velocity for a horizontal-only call.
		if (
			source_motion_per_tick.y == 0.0
			and (source_motion_per_tick.x != 0.0 or source_motion_per_tick.z != 0.0)
		):
			_motion_per_tick = Vector3(source_motion_per_tick.x, 0.1, source_motion_per_tick.z)
	_max_age_ticks = int(8.0 / (randf() * 0.8 + 0.2))
	scale = Vector3.ONE * _base_scale
	_update_brightness()


func _process(delta: float) -> void:
	# Alpha advances particles at 20 Hz. Interpolate only their rendered
	# position so low-speed bubbles remain smooth on a high-refresh display.
	_tick_accumulator += minf(delta, _TICK_SECONDS * 10.0)
	while _tick_accumulator >= _TICK_SECONDS:
		_tick_accumulator -= _TICK_SECONDS
		_previous_position = _current_position
		if _kind == Kind.BUBBLE:
			_tick_bubble()
		else:
			_tick_splash()
		if is_queued_for_deletion():
			return

	var partial_tick: float = _tick_accumulator / _TICK_SECONDS
	global_position = _previous_position.lerp(_current_position, partial_tick)


func _tick_bubble() -> void:
	# bh.java:24-37: buoyancy, movement, then strong per-tick drag.
	_motion_per_tick.y += 0.002
	_move_one_tick(_BUBBLE_HALF_EXTENTS)
	_motion_per_tick *= 0.85
	# A bubble vanishes the first tick its center leaves water.
	var world: Node = get_parent()
	if world != null and world.has_method("get_world_block"):
		var cell := _cell_at(_current_position)
		var block_id: int = int(world.call("get_world_block", cell))
		if not Blocks.is_water(block_id):
			queue_free()
			return
	_advance_lifetime()
	_update_brightness()


func _tick_splash() -> void:
	# pc.java with mf.java's h=0.04: gravity precedes movement; all axes
	# retain 98%, then grounded droplets have a 50% chance to disappear.
	_motion_per_tick.y -= 0.04
	var on_floor: bool = _move_one_tick(_SPLASH_HALF_EXTENTS)
	_motion_per_tick *= 0.98
	if not _advance_lifetime():
		return
	if on_floor:
		if randf() < 0.5:
			queue_free()
			return
		_motion_per_tick.x *= 0.7
		_motion_per_tick.z *= 0.7
	if _inside_block_or_fluid_surface():
		queue_free()
		return
	_update_brightness()


# Java uses `if (f-- <= 0)`, so a particle with stored lifetime N completes
# N+1 movement ticks. Return false when this tick queued the particle.
func _advance_lifetime() -> bool:
	_age_ticks += 1
	if _age_ticks > _max_age_ticks:
		queue_free()
		return false
	return true


func _move_one_tick(half_extents: Vector3) -> bool:
	var world: Node = get_parent()
	if world == null or not world.has_method("get_world_block"):
		_current_position += _motion_per_tick
		return false
	var result: Dictionary = VoxelCollider.move(
		world, _current_position, half_extents, _motion_per_tick, 1.0
	)
	_current_position = result.get("pos", _current_position) as Vector3
	_motion_per_tick = result.get("vel", _motion_per_tick) as Vector3
	return bool(result.get("on_floor", false))


# pc.java:43-47. Liquids and solid materials absorb a droplet once its
# center falls below `floor(y)+1-BlockFluid.getPercentAir(meta)`.
func _inside_block_or_fluid_surface() -> bool:
	var world: Node = get_parent()
	if world == null or not world.has_method("get_world_block"):
		return false
	var cell := _cell_at(_current_position)
	var block_id: int = int(world.call("get_world_block", cell))
	if not Blocks.is_fluid(block_id) and not Blocks.is_solid_collision(block_id):
		return false
	var meta: int = 0
	if world.has_method("get_world_block_meta"):
		meta = int(world.call("get_world_block_meta", cell))
	return _current_position.y < source_surface_height(cell.y, meta)


# ld.java:16-22. Metadata 8+ (falling fluid) is source-height for this
# test; other values describe depth down from the cell's upper face.
static func source_surface_height(cell_y: int, meta: int) -> float:
	var level: int = 0 if meta >= 8 else meta
	var depth: float = float(level + 1) / 9.0
	return float(cell_y + 1) - depth


# pp.java:28-40. Splash's parent pc.java invokes this with zero caller
# velocity, then applies its own X/Z reduction and fresh Y roll.
func _source_particle_motion() -> Vector3:
	var motion := Vector3(
		randf() * 0.8 - 0.4,
		randf() * 0.8 - 0.4,
		randf() * 0.8 - 0.4,
	)
	var speed: float = (randf() + randf() + 1.0) * 0.15 * 0.4
	if motion.length_squared() > 1.0e-8:
		motion = motion.normalized() * speed
	motion.y += 0.1
	return motion


func _update_brightness() -> void:
	var world: Node = get_parent()
	if world == null:
		modulate = Color.WHITE
		return
	var brightness: float = EntityLighting.sample_brightness(world, _cell_at(_current_position))
	modulate = Color(brightness, brightness, brightness, 1.0)


func _set_atlas_frame(frame: int) -> void:
	var col: int = frame & 15
	var row: int = frame >> 4
	_atlas.region = Rect2(col * 8, row * 8, 8, 8)


func _cell_at(world_position: Vector3) -> Vector3i:
	return Vector3i(
		floori(world_position.x),
		floori(world_position.y),
		floori(world_position.z),
	)
