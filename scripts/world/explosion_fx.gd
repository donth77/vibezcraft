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


# Build a continuous low-rate smoke emitter — used as a child of the
# primed-TNT entity for the during-fuse smoke trail. Caller is responsible
# for parenting and freeing it (typically: parent on `_ready`, queue_free
# on `_detonate`).
static func build_smoke_trail() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	# Continuous, not one-shot — keeps puffing every frame while the fuse
	# burns. one_shot=false + amount/lifetime ratio sets emission rate.
	p.one_shot = false
	p.amount = _TRAIL_AMOUNT
	p.lifetime = _TRAIL_LIFETIME
	p.explosiveness = 0.0
	# Spawn AT the entity (zero box extents) so puffs appear from a single
	# point and drift apart on per-particle velocity. Vanilla emits at
	# `entity.pos + (0, 0.5, 0)`; we match by offsetting the emitter
	# upward 0.5 in PrimedTNT.
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINT
	# pi.java:47 `aA += 0.004` per tick → ~+1.6 m/s per second after damp.
	# Negative gravity in our coord system = upward drift.
	p.gravity = Vector3(0, 1.5, 0)
	# Mild outward jitter so the column has shape rather than a vertical
	# line of identical puffs. Vanilla particle init randomizes velocity
	# slightly via Entity construction (lw.java spawn-speed).
	p.direction = Vector3(0, 1, 0)
	p.spread = 30.0
	p.initial_velocity_min = 0.05
	p.initial_velocity_max = 0.25
	# pi.java per-tick damping 0.96 → ≈55%/sec velocity decay. CPUParticles3D
	# damping is in m/s²; ~0.5 gives a similar curve at our velocity scale.
	p.damping_min = 0.3
	p.damping_max = 0.7
	# Scale ramp — vanilla pi.java:28-36 `g = a × (e/f × 32)` clamped
	# [0,1]; in plain English: particle starts tiny, ramps to full size
	# over its lifetime. CPUParticles3D doesn't expose a per-particle
	# size curve directly; the scale_amount range gives us a static
	# random size per particle, which reads as "varying puff sizes" —
	# similar visual impression even if the per-particle ramp is missed.
	p.scale_amount_min = 0.15
	p.scale_amount_max = 0.45
	# Color modulation — light to dark grey. CPUParticles3D's color_ramp
	# fades via gradient over particle lifetime; without one set, we get
	# constant alpha until cull. Use a 2-stop ramp from full grey to fully
	# transparent so puffs naturally fade out instead of popping.
	var grad := Gradient.new()
	grad.add_point(0.0, Color(0.25, 0.25, 0.25, 0.85))
	grad.add_point(1.0, Color(0.10, 0.10, 0.10, 0.0))
	# Replace the default 0/1 stops gradient created on add_point.
	grad.remove_point(0)
	grad.remove_point(0)
	grad.add_point(0.0, Color(0.25, 0.25, 0.25, 0.85))
	grad.add_point(1.0, Color(0.10, 0.10, 0.10, 0.0))
	p.color_ramp = grad
	var quad := QuadMesh.new()
	quad.size = Vector2(0.25, 0.25)
	p.mesh = quad
	# Material applied AFTER mesh assignment — CPUParticles3D resolves
	# `mesh.material` for the draw pass.
	(p.mesh as QuadMesh).material = _smoke_mat()
	p.emitting = true
	return p


# One-shot burst of `affected.size()` particles, one at each affected
# cell, with velocity pointing away from the explosion origin. Lifetime
# self-cleans via queue_free on a SceneTreeTimer.
#
# Vanilla ks.java:127-141 emits a per-block explode + smoke pair with a
# falloff-scaled outward velocity. We collapse to one particle per cell
# (using the brighter "explode" material) — visually it reads as the
# expected dust cloud plus directional spray without two pool entries
# per detonation.
static func spawn_burst(parent: Node, origin: Vector3, affected: Dictionary) -> void:
	if affected.is_empty():
		return
	var p := CPUParticles3D.new()
	parent.add_child(p)
	# EMISSION_SHAPE_POINTS lets us spawn each particle at a SPECIFIC cell
	# position with its own velocity — the only way to mirror vanilla's
	# "one particle per affected block" pattern in CPUParticles3D without
	# spawning N separate emitters.
	var points := PackedVector3Array()
	var velocities := PackedVector3Array()
	# Vanilla power for falloff math — we don't have it as a parameter
	# here, but the affected set is generated relative to the explosion's
	# `power × ~3` reach, so a fixed reference value matches the expected
	# velocity scale. TNT power = 4.
	var ref_power: float = 4.0
	for cell: Vector3i in affected:
		var cell_center: Vector3 = Vector3(cell) + Vector3(0.5, 0.5, 0.5)
		var to_cell: Vector3 = cell_center - origin
		var dist: float = to_cell.length()
		if dist < 0.01:
			# Cell at the origin — random direction so we don't emit a
			# zero-velocity particle.
			var rdir := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
			points.append(cell_center)
			velocities.append(rdir * 1.5)
			continue
		# Vanilla `d9 = 0.5 / (dist/power + 0.1)` × random envelope
		# `(rand × rand + 0.3)` per ks.java:139. Closer cells push faster
		# (1/x falloff with epsilon); the random envelope adds chunk-to-
		# chunk variance so the burst doesn't read as a perfect sphere.
		var falloff: float = 0.5 / (dist / ref_power + 0.1)
		var jitter: float = randf() * randf() + 0.3
		var dir: Vector3 = to_cell / dist
		# Position: vanilla emits at midpoint between cell and origin; we
		# match so particles spawn inside the destroyed-block region rather
		# than at the original cell (avoids the visual "puffs appearing
		# offset from the crater" issue).
		points.append((cell_center + origin) * 0.5)
		# Convert to m/s. Vanilla's velocity is per-tick (× 20 for m/s),
		# but the CPUParticles3D drag/lifetime defaults are tuned for our
		# m/s coords, so use a scaled-down magnitude.
		velocities.append(dir * falloff * jitter * 8.0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_POINTS
	p.emission_points = points
	p.emission_point_velocities = velocities
	p.amount = points.size()
	p.lifetime = _BURST_LIFETIME
	p.one_shot = true
	# 1.0 = burst-all-at-once; matches the visual impression of "the
	# explosion happens NOW" rather than a slow spawn.
	p.explosiveness = 1.0
	# Slight downward gravity so the dust cloud falls after the initial
	# outward push — vanilla's `aA -= 0.04` on smoke would normally rise,
	# but the explode particles use a different curve. Read as "dust
	# settling" with mild gravity.
	p.gravity = Vector3(0, -2.5, 0)
	p.damping_min = 1.5
	p.damping_max = 3.0
	p.scale_amount_min = _BURST_PARTICLE_SCALE * 0.7
	p.scale_amount_max = _BURST_PARTICLE_SCALE * 1.3
	# Fade-to-transparent ramp so particles disappear cleanly.
	var grad := Gradient.new()
	grad.remove_point(1)
	grad.remove_point(0)
	grad.add_point(0.0, Color(1.0, 0.95, 0.85, 0.95))
	grad.add_point(0.4, Color(0.7, 0.65, 0.55, 0.7))
	grad.add_point(1.0, Color(0.3, 0.3, 0.3, 0.0))
	p.color_ramp = grad
	var quad := QuadMesh.new()
	quad.size = Vector2(0.6, 0.6)
	p.mesh = quad
	(p.mesh as QuadMesh).material = _explode_mat()
	# emitting=true + one_shot=true emits the full burst on the next frame
	# and then stops. queue_free on a timer = lifetime + grace.
	p.emitting = true
	var tree: SceneTree = parent.get_tree()
	if tree != null:
		var cleanup := tree.create_timer(_BURST_LIFETIME + 0.3)
		cleanup.timeout.connect(_free_if_valid.bind(p))


static func _free_if_valid(node: Node) -> void:
	if is_instance_valid(node):
		node.queue_free()
