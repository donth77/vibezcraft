extends Node

# Small driver that pushes WorldTime's per-frame state onto the scene's
# WorldEnvironment + DirectionalLight3D. Lives as a Node child under Main
# (see main.tscn) and grabs siblings via NodePath. Keeps the autoload
# (WorldTime) ignorant of scene structure — it's pure logic.
#
# Visible behavior with this slice alone (mesher hasn't consumed sky_light
# yet, so the *terrain* still looks bright at night):
#   • Sky background color sweeps blue → orange dusk → near-black night → orange dawn.
#   • Ambient light fades day blue-tinted dim at night.
#   • Sun direction rotates around the east-west axis; light energy fades
#     to 0 when the sun dips below the horizon.

# Minimum sky-color drift (sum of |ΔR|+|ΔG|+|ΔB|) before we push the new
# colors to the ProceduralSkyMaterial. Every write marks the Sky dirty
# and re-bakes its shader params — at 60+ fps and vanilla's 1200 s day
# cycle the per-frame drift is ~0.001, far below perceptual threshold,
# so writing every frame wastes main-thread cycles.
const _SKY_COLOR_EPS: float = 1.0 / 255.0

# Debug fast-day toggle target. WorldTime.set_day_length flips between
# vanilla 1200 s and this 30 s sprint on debug_fast_day.
const _FAST_DAY_SECONDS: float = 30.0

@export var environment_path: NodePath = ^"../WorldEnvironment"
@export var sun_path: NodePath = ^"../DirectionalLight3D"

# Cap so the directional sun's light energy at noon matches whatever value
# the scene shipped with — avoids surprise brightness changes vs the
# pre-day-night look. main.tscn currently sets DirectionalLight3D.light_energy
# to 1.5; we read that on _ready and treat it as "noon".
var _noon_sun_energy: float = 1.5

# Last sky_top pushed to the ProceduralSkyMaterial — skip writes when
# the color hasn't drifted enough to perceive (see _SKY_COLOR_EPS above).
var _last_sky_top: Color = Color(-1, -1, -1, -1)

@onready var _env: WorldEnvironment = get_node_or_null(environment_path) as WorldEnvironment
@onready var _sun: DirectionalLight3D = get_node_or_null(sun_path) as DirectionalLight3D


func _ready() -> void:
	if _sun != null:
		_noon_sun_energy = _sun.light_energy
		# Web: drop the sun's shadow map. The shadow pass re-renders every
		# chunk mesh into the atlas each frame — a large share of draw
		# calls and the single biggest GPU line item on phone GPUs — and
		# the game's look doesn't come from it (per-face Notch shading +
		# BFS sky/block light do the shading; vanilla Alpha had no dynamic
		# shadows at all). Native desktop keeps the shipped look.
		if OS.has_feature("web"):
			_sun.shadow_enabled = false


# N flips WorldTime.day_length_seconds between vanilla (1200 s) and
# _FAST_DAY_SECONDS so lighting changes are easy to eyeball. Bound via
# debug_fast_day in input_actions.gd. Game.debug_enabled-gated so a
# regular player can't accidentally drop into hyper-speed days.
func _unhandled_input(event: InputEvent) -> void:
	if not Game.debug_enabled:
		return
	if event.is_action_pressed("debug_fast_day"):
		var current: float = WorldTime.day_length_seconds
		var target: float = (
			WorldTime.VANILLA_DAY_SECONDS
			if current < WorldTime.VANILLA_DAY_SECONDS
			else _FAST_DAY_SECONDS
		)
		WorldTime.set_day_length(target)
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var provider: WorldProvider = DimensionContext.active_provider()
	if not provider.renders_sky:
		_apply_skyless_environment(provider)
		return
	if _env != null and _env.environment != null:
		var env := _env.environment
		env.ambient_light_color = WorldTime.ambient_color()
		# Drive the ProceduralSkyMaterial's two-stop gradient from the
		# current sky color. Top = vanilla zenith color (oz.java:87-90).
		# Horizon = same hue blended toward white for the Alpha-era
		# horizon-dish wash (kb.java:updateFogColor + renderSky). Fog
		# color pins to the horizon stop so terrain at the ring edge
		# fades cleanly into the lightened horizon rather than jumping
		# between terrain and a differently-tinted sky.
		var sky_top: Color = WorldTime.sky_color()
		var sky_horizon: Color = sky_top.lerp(Color.WHITE, 0.35)
		var color_drift: float = (
			absf(sky_top.r - _last_sky_top.r)
			+ absf(sky_top.g - _last_sky_top.g)
			+ absf(sky_top.b - _last_sky_top.b)
		)
		if color_drift >= _SKY_COLOR_EPS:
			_last_sky_top = sky_top
			if env.sky != null and env.sky.sky_material is ProceduralSkyMaterial:
				var sm: ProceduralSkyMaterial = env.sky.sky_material
				sm.sky_top_color = sky_top
				sm.sky_horizon_color = sky_horizon
				sm.ground_horizon_color = sky_horizon
				sm.ground_bottom_color = sky_top
			env.fog_light_color = sky_horizon
	if _sun != null:
		_sun.transform.basis = Basis.looking_at(WorldTime.sun_direction(), Vector3.UP)
		_sun.light_energy = WorldTime.sun_energy(_noon_sun_energy)
		# Hide sub-horizon sun so we don't double-shadow the moon-side at
		# midnight (sub-horizon directional lights still cast shadows in
		# Godot — the shading would invert).
		_sun.visible = WorldTime.sun_elevation() > 0.0
	# Push Alpha's integer skyLightSubtracted onto the shared terrain and
	# water materials. Lava is deliberately self-emissive and has no daylight
	# uniform. One write per shared material covers every loaded chunk.
	var sky_subtraction: float = float(WorldTime.sky_light_subtracted())
	BlockAtlas.material().set_shader_parameter("sky_subtraction", sky_subtraction)
	BlockAtlas.water_material().set_shader_parameter("sky_subtraction", sky_subtraction)
	_push_ambient_floor()


# Dimensions with no sky (om.java's Nether) get a flat fog colour and no
# celestial anything. Alpha renders no sky dome, no sun, no moon, no
# stars and no clouds down there; the horizon is the fog colour all the
# way round, which is what makes the Nether feel enclosed.
#
# The sun light itself is switched off rather than merely hidden: a
# sub-horizon directional light still shades geometry in Godot, and the
# Nether's illumination has to come entirely from the block-light channel
# (glowstone, lava, fire, portals).
func _apply_skyless_environment(provider: WorldProvider) -> void:
	if _env != null and _env.environment != null:
		var env := _env.environment
		var fog: Color = provider.fog_color
		env.background_mode = Environment.BG_COLOR
		env.background_color = fog
		env.ambient_light_color = fog
		env.fog_light_color = fog
		_last_sky_top = Color(-1, -1, -1, -1)
	if _sun != null:
		_sun.visible = false
	# No sky channel means no daylight subtraction to push: the terrain
	# shader's sky term is zero everywhere, so block light is the whole
	# story. Writing 0 keeps the uniform in a defined state across a
	# dimension switch rather than leaving the Overworld's last value.
	BlockAtlas.material().set_shader_parameter("sky_subtraction", 0.0)
	BlockAtlas.water_material().set_shader_parameter("sky_subtraction", 0.0)
	_push_ambient_floor()


# The brightness LUT's floor is the one term vanilla varies by dimension
# (oz.java:23 = 0.05, om.java:21 = 0.1). WorldProvider has carried the
# right value all along; nothing was pushing it to the renderer, so the
# Nether was lit on the Overworld curve — every unlit cell at half the
# brightness vanilla gives it, which is what made the dark/light
# transitions read as harsh.
func _push_ambient_floor() -> void:
	var provider: WorldProvider = DimensionContext.provider(DimensionContext.active())
	if provider == null:
		return
	var floor_value: float = provider.ambient_light_floor
	BlockAtlas.material().set_shader_parameter("ambient_floor", floor_value)
	BlockAtlas.water_material().set_shader_parameter("ambient_floor", floor_value)
	EntityLighting.set_ambient_floor(floor_value)
