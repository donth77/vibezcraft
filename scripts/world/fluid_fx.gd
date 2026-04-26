class_name FluidFx
extends RefCounted

# Visual + audio effects for fluid state changes.
#
# Today: `spawn_fizz` for the lava→obsidian/cobble conversion puff
# (ld.java:256-261 `i()`): 1 fizz SFX + 8 largesmoke particles. Factored
# out of ChunkManager to keep that file under the linter's file-length
# cap and to give the fluid subsystem a clean seam for future effects
# (bubble column on water, splash on entry, etc.).
#
# Pooling: first-time allocation of a GPUParticles3D + ParticleProcessMaterial
# triggers a GPU shader/pipeline compile that shows up as a visible frame
# hitch — bad news when 6 lava cells solidify in one frame (water-on-lava
# cascade). `warm_pool` pre-builds a handful of inert emitters at boot so
# the shader is already compiled, and `spawn_fizz` cycles them via a FIFO
# pool with a lifetime timer. Overflow falls back to fresh allocation.

const _PARTICLES_ATLAS_PATH: String = "res://assets/textures/particles/particles.png"
const _POOL_SIZE: int = 6

# Cached material — built once on first call. All fizz instances share
# the same StandardMaterial3D since the atlas + settings are identical.
static var _largesmoke_material: StandardMaterial3D = null
# Pre-warmed GPUParticles3D pool. Emitters here are already parented under
# the ChunkManager and have their shader compiled; spawn_fizz pops one,
# repositions, and calls restart().
static var _pool: Array = []
# Last parent we warmed against. Used to lazily warm the pool on first
# spawn if `warm_pool` wasn't called at boot (harmless safety net).
static var _pool_parent: Node = null
# Lava-spark material cache — see get_lava_spark_material below. Kept at
# the top of the file to satisfy gdlint's class-definitions-order rule.
static var _lava_spark_material: StandardMaterial3D = null
# Torch-flame material cache — small yellow-orange billboard, vanilla
# `EntityFlameFX` (db.java's flame entry). Lifetime ~1 s, slight upward
# drift, no gravity.
static var _torch_flame_material: StandardMaterial3D = null
# Bubble (EntityBubbleFX) — particles.png tile 32 = (0, 16, 8, 8). Drifts
# upward at 0.002/tick gravity, dies on leaving water.
static var _bubble_material: StandardMaterial3D = null
# Static gray puff used as sub-emitter smoke for lava sparks. Avoids
# BILLBOARD_PARTICLES + particles_anim_* which interact badly with
# sub_emitter_keep_velocity (the inherited parent INSTANCE_CUSTOM
# corrupts the per-particle animation frame, manifesting as
# horizontal-streak artifacts).
static var _smoke_subparticle_material: StandardMaterial3D = null


# Builds / returns the shared largesmoke material. Sprite source is
# vanilla particles.png row 0 (8 frames of 16×16 smoke). pi.java's
# per-age frame pick (`b = 7 - e*8/f`) is reproduced here via Godot's
# per-particle animation driven by the `anim_speed` knob on
# ParticleProcessMaterial.
static func get_largesmoke_material() -> StandardMaterial3D:
	if _largesmoke_material != null:
		return _largesmoke_material
	var tex: Texture2D = load(_PARTICLES_ATLAS_PATH) as Texture2D
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(0, 0, 128, 16)  # crop to smoke row
	atlas.filter_clip = true
	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = atlas
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.billboard_mode = StandardMaterial3D.BILLBOARD_PARTICLES
	mat.particles_anim_h_frames = 8
	mat.particles_anim_v_frames = 1
	mat.particles_anim_loop = false
	# pi.java:17 grey init `j = k = random * 0.3` — we tint albedo 0.6
	# so the sprite still reads against dark caves without washing out.
	mat.albedo_color = Color(0.6, 0.6, 0.6, 1.0)
	_largesmoke_material = mat
	return mat


# Pre-warm the pool at boot so the first water-on-lava doesn't pay the
# GPU shader compile as a frame spike. Safe to call once in Game._ready
# once a persistent Node is available (we pass ChunkManager in practice).
static func warm_pool(parent: Node) -> void:
	_pool_parent = parent
	get_largesmoke_material()
	while _pool.size() < _POOL_SIZE:
		var particles := _build_particles(8, Vector3(0.35, 0.1, 0.35))
		particles.emitting = false
		particles.visible = false
		parent.add_child(particles)
		_pool.append(particles)


# Spawns the fizz effect at `pos` (world coords) as a child of `parent`.
# Parent is expected to be the ChunkManager so the particles stay in
# world space.
#
# Vanilla numbers (pi.java + ld.java): 8 particles emitted at once,
# upward drift, ~2 s lifetime.
static func spawn_fizz(parent: Node, pos: Vector3i) -> void:
	SFX.play_fizz(true)
	var particles := _acquire(parent, 8, Vector3(0.35, 0.1, 0.35))
	particles.position = Vector3(pos) + Vector3(0.5, 1.0, 0.5)
	particles.visible = true
	particles.restart()
	_schedule_return(parent, particles)


# Drain deferred sky-light seeds + fizz positions collected during a
# fluid neighbor-notify fanout. Called from ChunkManager when its
# `_light_defer_depth` unwinds to zero. `sky_seeds` is a Dictionary
# keyed by Vector3i (dedup by position); `fizz_positions` is the raw
# list of solidified cells for coalesced burst.
static func flush_deferred(manager, sky_seeds: Dictionary, fizz_positions: Array) -> void:
	for world_pos: Vector3i in sky_seeds:
		Lighting.update_sky_light_around_world(world_pos, manager)
	var n: int = fizz_positions.size()
	if n == 0:
		return
	if n == 1:
		spawn_fizz(manager, fizz_positions[0])
	else:
		spawn_fizz_cluster(manager, fizz_positions)


# Coalesced variant. When multiple lava cells solidify in one
# water-neighbor fanout, emit ONE particle system sized to the cluster
# (box extents cover the cluster AABB) instead of N systems. One fizz
# SFX per burst — vanilla only plays fizz once per World.applyPhysics
# anyway. `positions` is the raw list of solidified cells.
static func spawn_fizz_cluster(parent: Node, positions: Array) -> void:
	if positions.is_empty():
		return
	SFX.play_fizz(true)
	# Compute AABB + centroid. Centroid anchors the emitter; extents size
	# the emission_box so particles spawn across the full cluster volume.
	var min_p: Vector3 = Vector3(positions[0])
	var max_p: Vector3 = Vector3(positions[0])
	for p: Vector3i in positions:
		var v: Vector3 = Vector3(p)
		min_p = Vector3(minf(min_p.x, v.x), minf(min_p.y, v.y), minf(min_p.z, v.z))
		max_p = Vector3(maxf(max_p.x, v.x), maxf(max_p.y, v.y), maxf(max_p.z, v.z))
	var centroid: Vector3 = (min_p + max_p) * 0.5 + Vector3(0.5, 1.0, 0.5)
	# 16-particle cap — 6 cells × 8 would be 48 for the worst cascade,
	# which is more smoke than vanilla's per-cell puff implies and reads
	# as a pyro column. 16 keeps the visual dense but readable.
	var amount: int = mini(positions.size() * 4, 16)
	# Base extents = half the cluster span, padded so a single-cell
	# cluster still picks up the default 0.35 / 0.1 / 0.35 per-axis
	# extents from the uncoalesced spawn.
	var span: Vector3 = (max_p - min_p) * 0.5
	var extents := Vector3(maxf(span.x, 0.35), maxf(span.y, 0.1), maxf(span.z, 0.35))
	var particles := _acquire(parent, amount, extents)
	particles.position = centroid
	particles.visible = true
	particles.restart()
	_schedule_return(parent, particles)


# --- Pool internals ---


static func _acquire(parent: Node, amount: int, extents: Vector3) -> GPUParticles3D:
	# Lazy warm if Game._ready skipped calling warm_pool.
	if _pool.is_empty() and _pool_parent == null:
		warm_pool(parent)
	while not _pool.is_empty():
		# Pop UNTYPED — assigning a freed instance to a typed
		# `GPUParticles3D` local triggers Godot's type check on the value
		# itself ("Trying to assign invalid previously freed instance"),
		# which fires before we ever reach the is_instance_valid guard.
		# Pool entries can become stale when their parent (a chunk) gets
		# unloaded and queue_free'd; keep popping past those.
		var raw: Variant = _pool.pop_back()
		if not is_instance_valid(raw):
			continue
		var p: GPUParticles3D = raw as GPUParticles3D
		if p == null:
			continue
		_configure_runtime(p, amount, extents)
		return p
	# Pool exhausted — build a fresh one parented to the caller. Not
	# returned to the pool (too many simultaneous bursts means the cap
	# will rebalance naturally on subsequent frames).
	var fresh := _build_particles(amount, extents)
	parent.add_child(fresh)
	return fresh


static func _schedule_return(parent: Node, particles: GPUParticles3D) -> void:
	var tree := parent.get_tree()
	if tree == null:
		return
	var cleanup := tree.create_timer(particles.lifetime + 0.2)
	cleanup.timeout.connect(func() -> void: _return(particles))


static func _return(particles: GPUParticles3D) -> void:
	if not is_instance_valid(particles):
		return
	particles.emitting = false
	particles.visible = false
	if _pool.size() < _POOL_SIZE:
		_pool.append(particles)
	else:
		particles.queue_free()


# Rebuild the per-instance knobs that differ between calls (amount,
# emission box extents). Everything else (material, gravity, etc.) stays
# from _build_particles so we don't reallocate shaders.
static func _configure_runtime(particles: GPUParticles3D, amount: int, extents: Vector3) -> void:
	particles.amount = amount
	var proc: ParticleProcessMaterial = particles.process_material as ParticleProcessMaterial
	if proc != null:
		proc.emission_box_extents = extents


static func _build_particles(amount: int, extents: Vector3) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = extents
	proc.direction = Vector3(0, 1, 0)
	proc.spread = 15.0
	proc.initial_velocity_min = 0.3
	proc.initial_velocity_max = 0.8
	proc.gravity = Vector3(0, 0.08, 0)
	proc.damping_min = 0.8
	proc.damping_max = 0.8
	proc.scale_min = 0.6
	proc.scale_max = 1.0
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.3))
	scale_curve.add_point(Vector2(0.2, 1.0))
	scale_curve.add_point(Vector2(1.0, 1.0))
	var scale_tex := CurveTexture.new()
	scale_tex.curve = scale_curve
	proc.scale_curve = scale_tex
	# lifetime=2.0 s, 8 frames → anim_speed ≈ 4 plays strip exactly once.
	proc.anim_speed_min = 4.0
	proc.anim_speed_max = 4.0
	particles.process_material = proc
	var draw := QuadMesh.new()
	draw.size = Vector2(0.6, 0.6)
	draw.material = get_largesmoke_material()
	particles.draw_pass_1 = draw
	particles.amount = amount
	particles.lifetime = 2.0
	particles.one_shot = true
	particles.explosiveness = 0.9
	return particles


# Lava spark material — port of vanilla `db.java` (ParticleLava). Vanilla
# spawns these via ld.java:193-197 on air-above-lava cells at 1/100 per
# random tick. Lifetime `16 / rand(0.2..1.0)` = 16-80 ticks ≈ 0.8-4 s in
# vanilla; we run ~1 s for a crisp pop. Initial upward drift + gravity
# so the spark arcs back down. Orange-red tint approximates the "b=49"
# tile in vanilla's particles.png sheet without needing a separate atlas.
static func get_lava_spark_material() -> StandardMaterial3D:
	if _lava_spark_material != null:
		return _lava_spark_material
	# Vanilla db.java:21 sets `this.b = 49` which points at a 4×4 solid
	# orange block (RGB 255,180,37) sitting on an 8×8 transparent tile
	# in particles.png. Using AtlasTexture on a quad caused visible
	# aspect warping (it read as "strings"); rendering a flat orange
	# quad directly gives the same 4-pixel orange square visual without
	# the atlas/UV interaction. Quad size below is tuned so the rendered
	# particle matches the apparent size of vanilla's `0.1 * g` render
	# half-width.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_DISABLED
	mat.billboard_mode = StandardMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(1.0, 0.706, 0.145, 1.0)  # 255/180/37 → linear
	_lava_spark_material = mat
	return mat


# Single-particle upward arc, Alpha-faithful to ld.java:193-197. Uses the
# pool via _acquire so lava-heavy caves don't allocate new GPUParticles3D
# on every spark; amount=1 per call, position = cell top.
# Builds / returns a simple static gray puff for use as a sub-emitter
# sub-particle. Vanilla pi.java cycles through 8 smoke frames over a
# particle's life (`b = 7 - e*8/f`); reproducing that on a sub-emitter
# requires INSTANCE_CUSTOM coordination that Godot doesn't provide
# correctly when sub_emitter_keep_velocity inherits parent custom data.
# A single static frame from the smoke sprite strip — frame 0 (the
# densest puff) — at full opacity reads cleanly.
static func get_smoke_subparticle_material() -> StandardMaterial3D:
	if _smoke_subparticle_material != null:
		return _smoke_subparticle_material
	# Vanilla-faithful smoke. AtlasTexture + BILLBOARD_PARTICLES +
	# particles_anim_* combo was producing horizontally-squished sprites
	# (the 64×8 strip got stretched onto the 0.4×0.4 quad as if it were
	# a single frame). Switched to: full particles.png as albedo, UV
	# transform crops to a single 8×8 smoke frame, no per-particle
	# animation. Single dense smoke frame is acceptable divergence from
	# vanilla's 8-frame cycle — frames are visually similar enough that
	# losing the animation isn't a major fidelity hit.
	var sheet: Texture2D = load(_PARTICLES_ATLAS_PATH) as Texture2D
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = sheet
	# Crop UVs to a single 8×8 smoke tile at (0, 0) on the 128×128 sheet.
	# uv_scale = 8/128 = 0.0625 — only that tile's worth of the texture
	# samples onto the quad; uv_offset = (0, 0, 0) for top-left tile.
	mat.uv1_scale = Vector3(8.0 / 128.0, 8.0 / 128.0, 1.0)
	mat.uv1_offset = Vector3.ZERO
	mat.texture_filter = StandardMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	# BILLBOARD_ENABLED — full camera-facing, no INSTANCE_CUSTOM animation
	# dependency. Quad stays square (0.4 × 0.4 m) regardless of texture.
	mat.billboard_mode = StandardMaterial3D.BILLBOARD_ENABLED
	# Beta pi.java `j = k = rand * 0.3` (gray 0..0.3); we use top of range
	# 0.3 so smoke reads against grass/lava without being washed out.
	mat.albedo_color = Color(0.3, 0.3, 0.3, 1.0)
	_smoke_subparticle_material = mat
	return mat


# Builds / returns the shared bubble material. Sprite source is
# particles.png tile 32 (col 0, row 2 → region (0, 16, 8, 8)). Vanilla
# Beta EntityBubbleFX renders this with 1.0 r/g/b tint, scaled
# 0.2..0.8 (rand*0.6+0.2 in EntityBubbleFX:14).
static func get_bubble_material() -> StandardMaterial3D:
	if _bubble_material != null:
		return _bubble_material
	var sheet: Texture2D = load(_PARTICLES_ATLAS_PATH) as Texture2D
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = Rect2(0, 16, 8, 8)
	atlas.filter_clip = true
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = atlas
	mat.texture_filter = StandardMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = StandardMaterial3D.BILLBOARD_ENABLED
	_bubble_material = mat
	return mat


# Spawns N water bubbles drifting up from `world_pos`. Mirrors Beta
# EntityBubbleFX: motY += 0.002/tick (upward acceleration), motXYZ *=
# 0.85/tick damping, lifetime 8..40 ticks (0.4..2 s), dies on leaving
# water. Used for swim-trail bubbles and water-surface ambient bubbles.
static func spawn_water_bubble(
	parent: Node, world_pos: Vector3, motion: Vector3 = Vector3.ZERO, count: int = 1
) -> void:
	var particles := _acquire(parent, count, Vector3(0.05, 0.05, 0.05))
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(0.05, 0.05, 0.05)
	# Vanilla EntityBubbleFX initial motion = caller_motion * 0.2 + jitter,
	# Y also has * 0.2 + jitter. We replicate via direction + initial vel.
	if motion.length_squared() > 0.0001:
		proc.direction = motion.normalized()
		proc.initial_velocity_min = motion.length() * 0.18
		proc.initial_velocity_max = motion.length() * 0.22
	else:
		proc.direction = Vector3(0, 1, 0)
		proc.initial_velocity_min = 0.0
		proc.initial_velocity_max = 0.05
	proc.spread = 25.0
	# motY += 0.002/tick = +0.04/sec/tick acceleration up.
	proc.gravity = Vector3(0, 0.04, 0)
	# motXYZ *= 0.85/tick — strong damping.
	proc.damping_min = 1.5
	proc.damping_max = 1.5
	# rand.nextFloat() * 0.6 + 0.2 → 0.2..0.8 base scale * 0.02 set_size.
	# Quad below is 0.06 m, so net visible bubble is 0.012..0.048 m.
	proc.scale_min = 0.4
	proc.scale_max = 1.4
	proc.particle_flag_align_y = false
	proc.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_DISABLED
	particles.process_material = proc
	var draw := QuadMesh.new()
	draw.size = Vector2(0.06, 0.06)
	draw.material = get_bubble_material()
	particles.draw_pass_1 = draw
	# Lifetime 8..40 ticks (0.4..2 s) — pick midpoint.
	particles.lifetime = 1.0
	particles.position = world_pos
	particles.sub_emitter = NodePath("")  # clear any leftover from pool reuse
	particles.visible = true
	particles.restart()
	_schedule_return(parent, particles)


static func spawn_lava_spark(parent: Node, pos: Vector3i) -> void:
	var particles := _acquire(parent, 1, Vector3(0.4, 0.0, 0.4))
	# Vanilla db.java / Beta EntityLavaFX: initial Y velocity rand*0.4+0.05
	# (per-tick units → 1.0..9.0 m/s at 20 TPS). Y gravity: aA -= 0.03/tick
	# = -0.6/sec/tick → -12 m/s². XZ damping 0.999/tick. Lifetime 16..80
	# ticks (0.8..4 s). Initial scale `g *= rand*2+0.2` with parabolic
	# fade `g = a * (1 - f²)` per render.
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(0.4, 0.0, 0.4)
	proc.direction = Vector3(0, 1, 0)
	proc.spread = 10.0
	proc.initial_velocity_min = 1.2
	proc.initial_velocity_max = 2.5
	proc.gravity = Vector3(0, -6.0, 0)
	# DEBUG: lock spark scale so it's unambiguously the right size — no
	# random variation, no parabolic shrink. If user still sees "specks",
	# they're not the spark (which renders as a clean 0.3 m square).
	proc.scale_min = 1.0
	proc.scale_max = 1.0
	proc.particle_flag_align_y = false
	# Beta EntityLavaFX.onUpdate: per-tick smoke sub-particle spawn at
	# the spark's CURRENT world position with its CURRENT velocity, with
	# probability decaying from 1.0 → 0.0 over lifetime. Godot's GPU
	# sub_emitter at SUB_EMITTER_CONSTANT mode emits sub-particles at
	# the parent particle's position throughout its life. We can't gate
	# spawn rate per-particle on age in GPU mode, but a constant 8 Hz
	# emission averages to roughly the same density across the spark's
	# 1 s lifetime as vanilla's decaying probability over 16-80 ticks.
	# DEBUG: sub-emitter temporarily disabled to disambiguate what the
	# user is seeing. With this off, the only thing rendered should be
	# the orange lava-spark square itself — no gray smoke at all.
	# Re-enable once we've identified whether the "glitchy specks" are
	# the spark or the sub-emitter smoke.
	proc.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_DISABLED
	particles.process_material = proc
	var draw := QuadMesh.new()
	# DEBUG: bumped from 0.15 to 0.3 so spark is unmistakably visible.
	draw.size = Vector2(0.3, 0.3)
	draw.material = get_lava_spark_material()
	particles.draw_pass_1 = draw
	particles.lifetime = 1.0
	particles.position = Vector3(pos) + Vector3(0.5, 1.0, 0.5)
	# Build the smoke sub-emitter as a child of the spark particles so
	# it survives the spark's lifetime + cleanup. Reused across calls
	# via _ensure_lava_smoke_subemitter — no per-call allocation cost.
	# Sub-emitter abandoned — Godot 4's GPU sub_emitter coordination
	# (parent INSTANCE_CUSTOM passing, sub_emitter_keep_velocity binary
	# inheritance, position tracking) doesn't expose enough hooks to
	# reproduce vanilla pi.java's "spawn smoke at parent's CURRENT pos
	# with 0.1× parent velocity" behavior cleanly. Instead, co-spawn a
	# separate dedicated smoke emitter that fires independently and
	# uses simple, debuggable parameters.
	particles.visible = true
	particles.restart()
	_schedule_return(parent, particles)
	_spawn_lava_smoke_burst(parent, Vector3(pos) + Vector3(0.5, 1.0, 0.5))


# Standalone smoke burst that co-spawns with each lava spark.
# Approximates Beta EntityLavaFX.onUpdate's per-tick smoke-spawn
# behavior by emitting ~12 smoke particles continuously over the
# spark's typical 1-second lifetime. Each smoke gets a random upward
# velocity (matches the spread of velocities the spark passes through
# during its arc), so the smokes form a vertical column from the
# lava surface — visually similar to a per-tick trail.
static func _spawn_lava_smoke_burst(parent: Node, world_pos: Vector3) -> void:
	# Vanilla-faithful smoke trail. Beta EntityLavaFX.onUpdate spawns one
	# `EntitySmokeFX` per tick with `nextFloat() > age/maxAge` probability
	# — average ~10 smokes over a 1-2 second spark life. We emit 4 over
	# the burst (lower density to avoid the prior "fountain" complaint).
	var smoke := _acquire(parent, 4, Vector3(0.05, 0.0, 0.05))
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(0.05, 0.0, 0.05)
	proc.direction = Vector3(0, 1, 0)
	proc.spread = 30.0
	# Vanilla pi.java inherits caller velocity at 0.1× scale. Avg spark
	# velocity 1.85 m/s × 0.1 = 0.185 m/s base upward drift, with spread.
	proc.initial_velocity_min = 0.1
	proc.initial_velocity_max = 0.35
	# pi.java:47 `aA += 0.004/tick` = +0.08 m/s²/tick acceleration up.
	proc.gravity = Vector3(0, 0.08, 0)
	# pi.java:53 `motXYZ *= 0.96/tick` damping. Godot damping is unit/sec;
	# 0.96/tick at 20 TPS = 0.96^20 ≈ 0.44 over 1 second → effective
	# damping ~0.6/sec.
	proc.damping_min = 0.6
	proc.damping_max = 0.6
	# Vanilla scale: g = (rand*0.5+0.5)*2 * 0.75 ≈ 0.75..1.5 unscaled.
	# pi.java:35 `g = a * f8` where f8 climbs 0→1 over first ~3% of life
	# then stays — effectively pops to full scale instantly. We use
	# scale_min/max 0.7..1.4 against a 0.3 m base quad → final 0.21..0.42 m.
	proc.scale_min = 0.7
	proc.scale_max = 1.4
	# Vanilla's f8 is essentially a step function — full scale by 3% of
	# life. Match with a near-instant ramp so smokes pop in cleanly.
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.0))
	sc.add_point(Vector2(0.03, 1.0))
	sc.add_point(Vector2(1.0, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	proc.scale_curve = sct
	# Material uses BILLBOARD_ENABLED + UV-transform crop, NOT the
	# particles_anim_* path. Anim speed irrelevant — keep zero so we
	# don't accidentally drive INSTANCE_CUSTOM.z toward garbage.
	proc.anim_speed_min = 0.0
	proc.anim_speed_max = 0.0
	proc.particle_flag_align_y = false
	proc.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_DISABLED
	smoke.process_material = proc
	var draw := QuadMesh.new()
	# Vanilla EntitySmokeFX nominal size ~0.3 m, but at typical FP camera
	# distance (3-10 m) that reads as a single pixel. Bumped to 0.4 m
	# base × scale 0.7..1.4 = 0.28..0.56 m — top of vanilla's visible
	# size range, closer to what vanilla looks like in-game.
	draw.size = Vector2(0.4, 0.4)
	draw.material = get_smoke_subparticle_material()
	smoke.draw_pass_1 = draw
	# pi.java:22 — lifetime `8 / (rand*0.8 + 0.2)` ticks → 8..40 ticks
	# = 0.4..2.0 s. Use 1.0 s midpoint.
	smoke.lifetime = 1.0
	smoke.one_shot = true
	smoke.explosiveness = 0.0
	smoke.position = world_pos
	smoke.sub_emitter = NodePath("")  # clear leftover sub_emitter from pool reuse
	smoke.visible = true
	smoke.restart()
	_schedule_return(parent, smoke)


# Fire smoke — mirrors qh.java:189-236 BlockFire.randomDisplayTick's
# `largesmoke` spawns on flammable-adjacent faces of a FIRE cell. Single
# puff per call, drifts up + disperses. Shares the largesmoke material
# with spawn_fizz so no extra shader / material.
static func spawn_fire_smoke(parent: Node, pos: Vector3i) -> void:
	var particles := _acquire(parent, 3, Vector3(0.3, 0.1, 0.3))
	particles.position = Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	particles.lifetime = 1.5
	particles.visible = true
	particles.restart()
	_schedule_return(parent, particles)


# Vanilla EntityFlameFX (ko.java:23) samples particles.png tile 48 — an
# 8×8 sprite at pixel (0, 24, 8, 8) on the 128×128 atlas, NOT a solid
# block. The sprite has a soft yellow-orange flame shape with translucent
# edges. Solid-yellow billboards read as "yellow boxes" — wrong look.
static func get_torch_flame_material() -> StandardMaterial3D:
	if _torch_flame_material != null:
		return _torch_flame_material
	var sheet: Texture2D = load(_PARTICLES_ATLAS_PATH) as Texture2D
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = sheet
	# Crop UVs to the 8×8 flame tile at (0, 24) on the 128×128 sheet.
	# uv_scale = 8/128 = 0.0625; uv_offset.y = 24/128 = 0.1875.
	mat.uv1_scale = Vector3(8.0 / 128.0, 8.0 / 128.0, 1.0)
	mat.uv1_offset = Vector3(0.0, 24.0 / 128.0, 0.0)
	mat.texture_filter = StandardMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = StandardMaterial3D.BILLBOARD_ENABLED
	_torch_flame_material = mat
	return mat


# Torch tip particle — vanilla `bk.b` (BlockTorch.randomDisplayTick)
# spawns ONE smoke + ONE flame at the torch tip per random-tick roll.
# We emit just the flame for now: the smoke half wants vanilla's
# `EntitySmokeFX` (pi.java, ~0.1 m, single 8×8 tile) but our existing
# pool is wired for `largesmoke` (4× larger) which reads as a small
# cloud over a torch. Adding a dedicated small-smoke pool is a follow-up.
#
# Sizing: vanilla `ko.java` (EntityFlameFX) renders sprite tile 48 at
# parent default `g ≈ 0.1 × (rand·0.5 + 0.5)` → 0.05-0.15 m visible quad.
# We render at 0.10 m flat — the tile is solid yellow (no alpha gradient)
# so we don't need vanilla's parabolic shrink to read the same.
#
# Position: floor torches centered; wall torches (meta 1-4) lean toward
# the supporting wall by 0.27 cells (vanilla bk.b `d4 = 0.27`).
static func spawn_torch_particles(parent: Node, cell_pos: Vector3i, meta: int) -> void:
	# Floor: particle at (cx+0.5, cy+0.7, cz+0.5) — just below box top.
	# Wall: the rotation pipeline places the flame tip at cy+0.95 and
	# ~0.064 blocks away from the wall in the lean direction. Offsets
	# derived from tracing the vanilla bk.java rotation pipeline
	# (Z+1/16, rotX-40°, Y-3/8, rotX+90°, rotY per-meta) through
	# the top-face center vertex.
	var tip := Vector3(cell_pos) + Vector3(0.5, 0.85, 0.5)
	match meta:
		1:
			tip.y += 0.18
		2:
			tip.y += 0.18
		3:
			tip.y += 0.18
		4:
			tip.y += 0.18
	# --- Flame particle (vanilla ko.java / EntityFlameFX) ---
	# Spawns at exact tip position with zero velocity. Vanilla's ±0.05
	# position jitter in the constructor is dead code (modifies locals
	# after super() already set position). Quad size: vanilla base
	# pp.g ∈ [1.0, 2.0], rendered at 0.1*g per half → full [0.2, 0.4].
	var flame := _acquire(parent, 1, Vector3.ZERO)
	var fproc := ParticleProcessMaterial.new()
	fproc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
	fproc.direction = Vector3.ZERO
	fproc.spread = 0.0
	fproc.initial_velocity_min = 0.0
	fproc.initial_velocity_max = 0.0
	fproc.gravity = Vector3.ZERO
	fproc.scale_min = 0.8
	fproc.scale_max = 1.0
	fproc.particle_flag_align_y = false
	fproc.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_DISABLED
	# Vanilla parabolic shrink: g = a * (1 - f8² * 0.5)
	var sc := Curve.new()
	for i in range(7):
		var f8: float = float(i) / 6.0
		sc.add_point(Vector2(f8, 1.0 - f8 * f8 * 0.5))
	var sct := CurveTexture.new()
	sct.curve = sc
	fproc.scale_curve = sct
	var fdraw := QuadMesh.new()
	fdraw.size = Vector2(0.28, 0.28)
	fdraw.material = get_torch_flame_material()
	flame.draw_pass_1 = fdraw
	flame.lifetime = 1.0
	flame.one_shot = false
	flame.position = tip
	flame.visible = true
	flame.emitting = true
	flame.process_material = fproc
	flame.restart()
	_schedule_return(parent, flame)
	# TODO: torch smoke particles — removed for now, needs proper tuning.
