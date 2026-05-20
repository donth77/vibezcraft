class_name ExplosionFx
extends RefCounted

# TNT particle effects — port of vanilla Alpha kr.java + ks.java::b():
#
#   * Smoke trail during fuse (kr.java:51) — vanilla emits ONE "smoke"
#     particle per tick at the entity's center+0.5y with zero velocity.
#     Reproduced here as a continuous CPUParticles3D child of the primed
#     entity, ~20 Hz emission rate × 4-second fuse ≈ 80 puffs total.
#     Particle params follow pi.java (ParticleSmoke):
#       - lifetime 0.4-2.0 s (vanilla 8-40 ticks)
#       - color rand × 0.3 → dark grey (pi.java:17 `j = k = rand × 0.3`)
#       - gravity +0.004 (slight rise; pi.java:47 `aA += 0.004`)
#       - 0.96/tick damping
#       - scale ramp 0 → full across lifetime (pi.java:28-36)
#
#   * Per-block explosion burst (ks.java:127-141) — vanilla iterates the
#     affected-block set and emits TWO particles per cell:
#       1. "explode" at midpoint between cell and origin, outward velocity
#          scaled by `0.5 / (distance/power + 0.1)` × random factor
#       2. "smoke" at random offset within the cell, same velocity vector
#     We approximate with a single CPUParticles3D burst that uses
#     EMISSION_SHAPE_POINTS to emit at each affected cell. Per-point
#     velocity matches vanilla's outward direction × falloff. Skipping
#     the explode/smoke split keeps the implementation simple — visually
#     it's a single bright puff per destroyed block, close enough to read
#     correctly without two pool entries per detonation.

# Vanilla pi.java ParticleSmoke ranges (8-40 ticks at 20 TPS).
const _SMOKE_LIFETIME_MIN: float = 0.4
const _SMOKE_LIFETIME_MAX: float = 2.0
# Trail emit cadence — vanilla 1/tick at 20 TPS = 20 Hz. CPUParticles3D
# uses `lifetime / amount` as the emit interval, so amount = lifetime ×
# rate (40 = 2.0 × 20). Picks a steady density without spawn bursts.
const _TRAIL_AMOUNT: int = 40
const _TRAIL_LIFETIME: float = 2.0
# Burst lifetime is shorter than the trail — explode particles in vanilla
# fade fast (the boom is over in ~1 second visually, even if the smoke
# residue lingers).
const _BURST_LIFETIME: float = 1.2
const _BURST_PARTICLE_SCALE: float = 0.4

const _PARTICLES_TEX_PATH: String = "res://assets/textures/particles/particles.png"

static var _smoke_material: StandardMaterial3D
static var _explode_material: StandardMaterial3D
static var _particles_tex: Texture2D


static func _particles_texture() -> Texture2D:
	if _particles_tex == null:
		_particles_tex = load(_PARTICLES_TEX_PATH) as Texture2D
	return _particles_tex


# Builds the dark-grey smoke material. Cached after first build.
# Vanilla's smoke is a 7-frame greyscale gradient on particles.png; we
# approximate with a procedurally tinted soft quad — visually equivalent
# at the small particle size we render at (≈10 cm).
static func _smoke_mat() -> StandardMaterial3D:
	if _smoke_material != null:
		return _smoke_material
	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = StandardMaterial3D.BILLBOARD_PARTICLES
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# pi.java:17 `j = k = i = rand × 0.3` — dark grey, alpha ~85% so the
	# puffs feel solid but not opaque.
	mat.albedo_color = Color(0.18, 0.18, 0.18, 0.85)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# Use the soft circular smoke texture if particles.png ships one,
	# fall through to a plain quad if not. Fine either way for the
	# visual read.
	var tex: Texture2D = _particles_texture()
	if tex != null:
		mat.albedo_texture = tex
	_smoke_material = mat
	return mat


# Brighter, oranger material for the explosion burst. Vanilla's "explode"
# particle is a muted-orange puff (particles.png cell). Same billboard
# setup as smoke; only color differs.
static func _explode_mat() -> StandardMaterial3D:
	if _explode_material != null:
		return _explode_material
	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = StandardMaterial3D.BILLBOARD_PARTICLES
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Off-white with a warm tint — reads as a bright burst against the
	# darker smoke trail without slipping into "fire" territory.
	mat.albedo_color = Color(0.92, 0.85, 0.75, 0.9)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var tex: Texture2D = _particles_texture()
	if tex != null:
		mat.albedo_texture = tex
	_explode_material = mat
	return mat


# Burst disabled — same smoke-rendering issue as TNT fuse trail and
# block-on-fire smoke (squished sprite look through the lava-fizz pool
# path that otherwise works for fizz). The explosion SFX + the chunk
# re-mesh after destruction still convey the impact; revisit when a
# dedicated emitter looks correct.
static func spawn_burst(_parent: Node, _origin: Vector3, _affected: Dictionary) -> void:
	pass
