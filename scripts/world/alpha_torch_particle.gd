class_name AlphaTorchParticle
extends Sprite3D

# One source-faithful Alpha torch display particle. BlockTorch emits a
# separate smoke + flame pair; these are not a looping emitter attached to
# the block. Simulation intentionally advances at Alpha's 20 Hz tick rate
# while rendering interpolates between tick positions.

enum Kind { FLAME, SMOKE }

const _PARTICLES_TEXTURE: Texture2D = preload("res://assets/textures/particles/particles.png")
const _TICK_SECONDS: float = 1.0 / 20.0
const _TILE_SIZE_PX: float = 8.0
const _BASE_QUAD_SIZE: float = 0.2

var _kind: Kind = Kind.FLAME
var _age_ticks: int = 0
var _max_age_ticks: int = 1
var _tick_accumulator: float = 0.0
var _motion_per_tick: Vector3 = Vector3.ZERO
var _previous_position: Vector3 = Vector3.ZERO
var _current_position: Vector3 = Vector3.ZERO
var _base_scale: float = 1.0
var _local_brightness: float = 1.0
var _atlas: AtlasTexture


func configure(
	kind: Kind, world_position: Vector3, local_brightness: float, smoke_size_multiplier: float = 1.0
) -> void:
	_kind = kind
	_age_ticks = 0
	_tick_accumulator = 0.0
	_local_brightness = clampf(local_brightness, 0.0, 1.0)
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

	var initial_motion: Vector3 = _source_initial_motion()
	if _kind == Kind.FLAME:
		# ko.java:20,22. The flame keeps the one particles.png tile for its
		# whole life and reduces inherited pp.java motion to one percent.
		_max_age_ticks = int(8.0 / (randf() * 0.8 + 0.2)) + 4
		_base_scale = (randf() * 0.5 + 0.5) * 2.0
		_motion_per_tick = initial_motion * 0.01
		_set_atlas_frame(48)
		modulate = Color.WHITE
	else:
		# pi.java:14-23. Ordinary smoke is 0.75 of pp.java's random scale,
		# dark gray, and shorter-lived than largesmoke. pi.java's f2 overload
		# multiplies both its stored scale and its already-rounded lifetime;
		# Alpha passes 2.5 for the Nether water-evaporation puffs.
		var base_lifetime: int = int(8.0 / (randf() * 0.8 + 0.2))
		_max_age_ticks = int(float(base_lifetime) * smoke_size_multiplier)
		_base_scale = (randf() * 0.5 + 0.5) * 2.0 * 0.75 * smoke_size_multiplier
		_motion_per_tick = initial_motion * 0.1
		_set_atlas_frame(7)
		var gray: float = randf() * 0.3 * _local_brightness
		modulate = Color(gray, gray, gray, 1.0)
	_update_visual(0.0)


func _process(delta: float) -> void:
	# Avoid an unbounded catch-up loop after a debugger pause. Alpha also
	# caps the number of game ticks processed in one rendered frame.
	_tick_accumulator += minf(delta, _TICK_SECONDS * 10.0)
	while _tick_accumulator >= _TICK_SECONDS:
		_tick_accumulator -= _TICK_SECONDS
		if _age_ticks >= _max_age_ticks:
			queue_free()
			return
		_previous_position = _current_position
		_age_ticks += 1
		if _kind == Kind.SMOKE:
			# pi.java:46-55: frames count backward and smoke accelerates up.
			_set_atlas_frame(clampi(7 - _age_ticks * 8 / _max_age_ticks, 0, 7))
			_motion_per_tick.y += 0.004
		# ko.java:43-54 and pi.java:45-61: both particles move and damp
		# every tick. Flame motion is only one percent of pp.java's initial
		# velocity, but retaining it prevents the sprite from looking pinned.
		_current_position += _motion_per_tick
		_motion_per_tick *= 0.96

	var partial_tick: float = _tick_accumulator / _TICK_SECONDS
	global_position = _previous_position.lerp(_current_position, partial_tick)
	_update_visual((float(_age_ticks) + partial_tick) / float(_max_age_ticks))


# pp.java:28-40. This is the shared randomized starting velocity before
# EntityFlameFX scales it by 0.01 or EntitySmokeFX by 0.1.
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


func _update_visual(raw_progress: float) -> void:
	var progress: float = clampf(raw_progress, 0.0, 1.0)
	var size_scale: float
	if _kind == Kind.FLAME:
		# ko.java:25-28: parabolic shrink to half the starting size.
		size_scale = _base_scale * (1.0 - progress * progress * 0.5)
		# ko.java:31-40: starts fullbright, then approaches local light.
		var light: float = lerpf(1.0, _local_brightness, progress)
		modulate = Color(light, light, light, 1.0)
	else:
		# pi.java:27-36: reaches full scale in the first 1/32 of its life.
		size_scale = _base_scale * minf(progress * 32.0, 1.0)
	scale = Vector3.ONE * size_scale


func _set_atlas_frame(frame: int) -> void:
	var col: int = frame & 15
	var row: int = frame >> 4
	_atlas.region = Rect2(col * 8, row * 8, 8, 8)
