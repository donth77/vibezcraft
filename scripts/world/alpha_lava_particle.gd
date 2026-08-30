class_name AlphaLavaParticle
extends Sprite3D

# Alpha 1.2.6 EntityLavaFX (`db.java`). A lava popper is an individual
# billboard entity, not a looping GPU emitter: it follows a tick-stepped arc,
# shrinks parabolically, and sheds ordinary EntitySmokeFX particles from its
# current position with a probability that declines over its lifetime.

const _PARTICLES_TEXTURE: Texture2D = preload("res://assets/textures/particles/particles.png")
const _ALPHA_SMOKE_PARTICLE: GDScript = preload("res://scripts/world/alpha_torch_particle.gd")
const _TICK_SECONDS: float = 1.0 / 20.0
const _TILE_SIZE_PX: float = 8.0
const _BASE_QUAD_SIZE: float = 0.2
const _VISIBILITY_DISTANCE_SQUARED: float = 16.0 * 16.0

var _age_ticks: int = 0
var _max_age_ticks: int = 1
var _tick_accumulator: float = 0.0
var _motion_per_tick: Vector3 = Vector3.ZERO
var _previous_position: Vector3 = Vector3.ZERO
var _current_position: Vector3 = Vector3.ZERO
var _base_scale: float = 1.0
var _viewer_position: Vector3 = Vector3.ZERO
var _atlas: AtlasTexture


func configure(world_position: Vector3, viewer_position: Vector3) -> void:
	_age_ticks = 0
	_tick_accumulator = 0.0
	_previous_position = world_position
	_current_position = world_position
	_viewer_position = viewer_position
	global_position = world_position

	_atlas = AtlasTexture.new()
	_atlas.atlas = _PARTICLES_TEXTURE
	_atlas.region = Rect2(8, 24, 8, 8)  # db.java: `b = 49`.
	_atlas.filter_clip = true
	texture = _atlas
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	pixel_size = _BASE_QUAD_SIZE / _TILE_SIZE_PX
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	transparent = true
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	shaded = false
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	modulate = Color.WHITE  # EntityLavaFX is always fullbright.

	# pp.java supplies the randomized X/Z motion. db.java scales it by 0.8,
	# then replaces Y completely with a fresh 0.05..0.45 roll.
	_motion_per_tick = _source_initial_motion() * 0.8
	_motion_per_tick.y = randf() * 0.4 + 0.05
	var particle_scale: float = (randf() * 0.5 + 0.5) * 2.0
	_base_scale = particle_scale * (randf() * 2.0 + 0.2)
	_max_age_ticks = int(16.0 / (randf() * 0.8 + 0.2))
	_update_visual(0.0)


func _process(delta: float) -> void:
	# Simulation stays at Alpha's 20 Hz while rendering interpolates between
	# ticks. Limit debugger-pause catch-up just like the torch particles do.
	_tick_accumulator += minf(delta, _TICK_SECONDS * 10.0)
	while _tick_accumulator >= _TICK_SECONDS:
		_tick_accumulator -= _TICK_SECONDS
		if _age_ticks >= _max_age_ticks:
			queue_free()
			return
		_previous_position = _current_position
		_age_ticks += 1
		var progress: float = float(_age_ticks) / float(_max_age_ticks)
		# db.java:44-46. The smoke request precedes gravity and movement, so
		# each mote starts on the popper's actual trail rather than the surface.
		if randf() > progress:
			_spawn_smoke()
		_motion_per_tick.y -= 0.03
		_move_one_tick()
		_motion_per_tick *= 0.999

	var partial_tick: float = _tick_accumulator / _TICK_SECONDS
	global_position = _previous_position.lerp(_current_position, partial_tick)
	_update_visual((float(_age_ticks) + partial_tick) / float(_max_age_ticks))


# pp.java:28-40, before EntityLavaFX's 0.8 multiplier and Y override.
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


func _move_one_tick() -> void:
	var world: Node = get_parent()
	if world == null or not world.has_method("get_world_block"):
		_current_position += _motion_per_tick
		return
	# pp.java particles have a 0.2 m collision box. VoxelCollider clips the
	# same per-tick displacement and reports the grounded state used by db.java.
	var result: Dictionary = VoxelCollider.move(
		world, _current_position, Vector3.ONE * 0.1, _motion_per_tick, 1.0
	)
	_current_position = result["pos"] as Vector3
	_motion_per_tick = result["vel"] as Vector3
	if result["on_floor"] as bool:
		_motion_per_tick.x *= 0.7
		_motion_per_tick.z *= 0.7


func _spawn_smoke() -> void:
	var world: Node = get_parent()
	if world == null or not is_instance_valid(world):
		return
	# f.java:963-970 applies the same 16-block spherical visibility gate to
	# every smoke request made by the popper.
	if _viewer_position.distance_squared_to(_current_position) > _VISIBILITY_DISTANCE_SQUARED:
		return
	var cell := Vector3i(
		floori(_current_position.x),
		floori(_current_position.y),
		floori(_current_position.z),
	)
	var brightness: float = EntityLighting.sample_brightness(world, cell)
	var smoke: Sprite3D = _ALPHA_SMOKE_PARTICLE.new() as Sprite3D
	world.add_child(smoke)
	# f.java ignores EntityLavaFX's supplied velocity for the "smoke"
	# particle and constructs a fresh pi.java particle with zero arguments.
	smoke.call("configure", 1, _current_position, brightness)


func _update_visual(raw_progress: float) -> void:
	var progress: float = clampf(raw_progress, 0.0, 1.0)
	# db.java:31-34: `g = a * (1 - progress^2)`.
	var size_scale: float = _base_scale * (1.0 - progress * progress)
	scale = Vector3.ONE * size_scale
