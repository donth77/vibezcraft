class_name AlphaRedDustParticle
extends Sprite3D

# Alpha 1.2.6 EntityReddustFX (`fh.java`). Every `reddust` request creates
# one ticked billboard using particles.png frames 7 down to 0. This is also
# the base particle used by Beta 1.3's powered repeater display tick; Beta
# retains its physics but changes the constructor's color calculation.

enum ColorProfile { ALPHA_1_2_6, BETA_1_3 }

const _PARTICLES_TEXTURE: Texture2D = preload("res://assets/textures/particles/particles.png")
const _TICK_SECONDS: float = 1.0 / 20.0
const _TILE_SIZE_PX: float = 8.0
const _BASE_QUAD_SIZE: float = 0.2
const _HALF_EXTENTS: Vector3 = Vector3.ONE * 0.1

var _age_ticks: int = 0
var _max_age_ticks: int = 1
var _tick_accumulator: float = 0.0
var _motion_per_tick: Vector3 = Vector3.ZERO
var _previous_position: Vector3 = Vector3.ZERO
var _current_position: Vector3 = Vector3.ZERO
var _base_scale: float = 1.0
var _base_color: Color = Color.WHITE
var _atlas: AtlasTexture


func configure(
	world_position: Vector3, color_profile: ColorProfile = ColorProfile.ALPHA_1_2_6
) -> void:
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

	# fh.java:13-24. The inherited pp.java motion is reduced to 10%.
	_motion_per_tick = _source_initial_motion() * 0.1
	if color_profile == ColorProfile.BETA_1_3:
		# Beta 1.3 EntityReddustFX receives (0,0,0) from the repeater. Its
		# constructor promotes the zero red input to 1, leaves G/B at zero,
		# then applies independent red and 0.6..1.0 brightness rolls.
		var beta_brightness: float = randf() * 0.4 + 0.6
		_base_color = Color((randf() * 0.2 + 0.8) * beta_brightness, 0.0, 0.0, 1.0)
	else:
		# Alpha fh.java uses red 0.7..1.0 and one shared 0.0..0.1 roll for
		# green and blue.
		_base_color = Color(randf() * 0.3 + 0.7, randf() * 0.1, 0.0, 1.0)
		_base_color.b = _base_color.g
	_base_scale = (randf() * 0.5 + 0.5) * 2.0 * 0.75
	_max_age_ticks = int(8.0 / (randf() * 0.8 + 0.2))
	_set_atlas_frame(7)
	_update_visual(0.0)
	_update_brightness()


func _process(delta: float) -> void:
	# Simulation remains on Alpha's 20 Hz entity tick; only the rendered
	# position and initial 1/32-lifetime scale ramp are interpolated.
	_tick_accumulator += minf(delta, _TICK_SECONDS * 10.0)
	while _tick_accumulator >= _TICK_SECONDS:
		_tick_accumulator -= _TICK_SECONDS
		_age_ticks += 1
		if _age_ticks > _max_age_ticks:
			queue_free()
			return
		_previous_position = _current_position
		_set_atlas_frame(clampi(7 - _age_ticks * 8 / _max_age_ticks, 0, 7))
		var on_floor: bool = _move_one_tick()
		# fh.java accelerates X/Z by 10% when vertical motion was blocked,
		# then damps every axis by 0.96 and grounded X/Z by another 0.7.
		if is_equal_approx(_current_position.y, _previous_position.y):
			_motion_per_tick.x *= 1.1
			_motion_per_tick.z *= 1.1
		_motion_per_tick *= 0.96
		if on_floor:
			_motion_per_tick.x *= 0.7
			_motion_per_tick.z *= 0.7
		_update_brightness()

	var partial_tick: float = _tick_accumulator / _TICK_SECONDS
	global_position = _previous_position.lerp(_current_position, partial_tick)
	_update_visual((float(_age_ticks) + partial_tick) / float(_max_age_ticks))


# pp.java:28-35, before fh.java's 0.1 multiplier.
func _source_initial_motion() -> Vector3:
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


func _move_one_tick() -> bool:
	var world: Node = get_parent()
	if world == null or not world.has_method("get_world_block"):
		_current_position += _motion_per_tick
		return false
	# The native collider marshals loaded chunks through this method. Small
	# detached preview/test worlds expose block reads only; let motes drift
	# normally there instead of asking the native path for unavailable chunks.
	if not world.has_method("get_chunk_at_coord"):
		_current_position += _motion_per_tick
		return false
	# Repeaters have a 1/8-block collision base, but the shared mob collider
	# intentionally treats most compound blocks as full cubes. A mote starts
	# at y+0.4, safely above the real base; bypass that false full-cube hit.
	var cell := _cell_at(_current_position)
	var block_id: int = int(world.call("get_world_block", cell))
	if block_id == Blocks.REDSTONE_REPEATER_OFF or block_id == Blocks.REDSTONE_REPEATER_ON:
		_current_position += _motion_per_tick
		return false
	var result: Dictionary = VoxelCollider.move(
		world, _current_position, _HALF_EXTENTS, _motion_per_tick, 1.0
	)
	_current_position = result.get("pos", _current_position) as Vector3
	_motion_per_tick = result.get("vel", _motion_per_tick) as Vector3
	return bool(result.get("on_floor", false))


func _update_visual(raw_progress: float) -> void:
	# fh.java:27-36. The mote reaches full size within the first 1/32 of
	# its lifetime and then stays there; it does not shrink/fade away.
	var progress: float = clampf(raw_progress, 0.0, 1.0)
	var size_scale: float = _base_scale * minf(progress * 32.0, 1.0)
	scale = Vector3.ONE * size_scale


func _update_brightness() -> void:
	var brightness: float = 1.0
	var world: Node = get_parent()
	if world != null:
		if world.has_method("get_world_effective_light"):
			brightness = EntityLighting.sample_brightness(world, _cell_at(_current_position))
		elif world.has_method("get_world_sky_light") and world.has_method("get_world_block_light"):
			brightness = EntityLighting.sample_brightness(world, _cell_at(_current_position))
	modulate = Color(
		_base_color.r * brightness,
		_base_color.g * brightness,
		_base_color.b * brightness,
		1.0,
	)


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
