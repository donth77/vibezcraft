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


func _process(_delta: float) -> void:
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
	# Push WorldTime.sky_factor into the chunk shader uniform so per-vertex
	# sky_light scales with the day cycle. Single shared ShaderMaterial
	# (BlockAtlas._material) — one set call covers every chunk in the world.
	# Water + lava share the same lighting convention now that their meshes
	# carry per-vertex COLOR (water_colors / lava_colors); push to those
	# materials too so they dim at night / in caves like cube blocks.
	var sf: float = WorldTime.sky_factor()
	BlockAtlas.material().set_shader_parameter("sky_factor", sf)
	BlockAtlas.water_material().set_shader_parameter("sky_factor", sf)
	BlockAtlas.lava_material().set_shader_parameter("sky_factor", sf)
