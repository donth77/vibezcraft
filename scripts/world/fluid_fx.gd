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
# Pooling: generic smoke keeps a pre-warmed GPUParticles3D pool. Source-
# sensitive lava, fizz, bubble, and splash particles use individual Sprite3D
# lifecycles because the GPU path cannot reproduce their exact 8x8 frames,
# randomized lifetimes, collision checks, or per-tick motion.

const _PARTICLES_ATLAS_PATH: String = "res://assets/textures/particles/particles.png"
const _POOL_SIZE: int = 6
const _ALPHA_TORCH_PARTICLE: GDScript = preload("res://scripts/world/alpha_torch_particle.gd")
const _ALPHA_LAVA_PARTICLE: GDScript = preload("res://scripts/world/alpha_lava_particle.gd")
const _ALPHA_WATER_PARTICLE: GDScript = preload("res://scripts/world/alpha_water_particle.gd")
const _PARTICLE_VISIBILITY_DISTANCE_SQUARED: float = 16.0 * 16.0
const _TORCH_WALL_RISE: float = 0.22
const _TORCH_WALL_OFFSET: float = 0.27

# Cached material retained for generic smoke and the ghast trail. The
# source-faithful fizz paths below use AtlasTexture-backed Sprite3Ds instead.
static var _largesmoke_material: StandardMaterial3D = null
# Pre-warmed GPUParticles3D pool. Emitters here are already parented under
# the ChunkManager and have their shader compiled; generic pooled effects
# pop one, reposition it, and call restart().
static var _pool: Array = []
# Last parent we warmed against. Used to lazily warm the pool on first
# spawn if `warm_pool` wasn't called at boot (harmless safety net).
static var _pool_parent: Node = null


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


# Pre-warm the generic fluid-particle pool at boot. Safe to call once in
# Game._ready once a persistent Node is available (ChunkManager in practice).
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
# ld.java:256-261: eight `largesmoke` particles at random X/Z points
# exactly 0.2 blocks above the converted lava cell's top face.
static func spawn_fizz(parent: Node, pos: Vector3i) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	SFX.play_fizz(true)
	_spawn_lava_conversion_smoke(parent, pos)


# ag.java:64-68. A water bucket used in the Nether never places a block;
# it creates eight independent `largesmoke` (pi.java with f2=2.5) particles
# at random XYZ points throughout the attempted destination cell.
static func spawn_nether_water_evaporation(parent: Node, pos: Vector3i) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	SFX.play_fizz(true)
	for _i in range(8):
		var origin := Vector3(pos) + Vector3(randf(), randf(), randf())
		spawn_largesmoke_particle(parent, origin)


# One ordinary Alpha EntitySmokeFX (`pi.java`) with optional size/lifetime
# multiplier. A multiplier of 2.5 is the named `largesmoke` path; 1.0 is the
# regular `smoke` used by torches and redstone-torch burnout.
static func spawn_smoke_particle(
	parent: Node,
	world_position: Vector3,
	size_multiplier: float = 1.0,
	viewer_position: Variant = null
) -> Sprite3D:
	if parent == null or not is_instance_valid(parent):
		return null
	if not _named_particle_visible(parent, world_position, viewer_position):
		return null
	var cell := Vector3i(
		floori(world_position.x),
		floori(world_position.y),
		floori(world_position.z),
	)
	var brightness: float = EntityLighting.sample_brightness(parent, cell)
	var smoke: Sprite3D = _ALPHA_TORCH_PARTICLE.new() as Sprite3D
	parent.add_child(smoke)
	smoke.call("configure", 1, world_position, brightness, size_multiplier)
	return smoke


# pi.java's `largesmoke` constructor is ordinary animated smoke with a 2.5
# multiplier on both scale and lifetime. Sprite3D preserves the actual 8x8
# atlas cells; the GPU draw-pass path stretched the sheet into visual dashes.
static func spawn_largesmoke_particle(parent: Node, world_position: Vector3) -> Sprite3D:
	return spawn_smoke_particle(parent, world_position, 2.5)


# bo.java:113-120. On the eighth rapid off-transition, a redstone torch
# emits five ordinary smoke motes at independent points inside the central
# 60% of its cell. This is a one-shot burnout effect, not its ambient dust.
static func spawn_redstone_torch_burnout_smoke(
	parent: Node, cell_pos: Vector3i, viewer_position: Variant = null
) -> Array[Sprite3D]:
	var particles: Array[Sprite3D] = []
	for _i in range(5):
		var origin := (
			Vector3(cell_pos)
			+ Vector3(
				randf() * 0.6 + 0.2,
				randf() * 0.6 + 0.2,
				randf() * 0.6 + 0.2,
			)
		)
		var smoke := spawn_smoke_particle(parent, origin, 1.0, viewer_position)
		if smoke != null:
			particles.append(smoke)
	return particles


# Generic eight-particle GPU smoke puff at a Vector3 world position. This
# intentionally remains a cheap pooled effect for non-source-sensitive
# callers; lava conversion and Nether evaporation use real Sprite3D motes.
static func spawn_smoke(parent: Node, pos: Vector3) -> void:
	var particles := _acquire(parent, 8, Vector3(0.35, 0.1, 0.35))
	particles.position = pos
	particles.visible = true
	particles.restart()
	_schedule_return(parent, particles)


# Compatibility wrapper for callers that defer only sky seeds. ChunkManager's
# general batch path now drains both light channels itself.
static func flush_deferred(manager, sky_seeds: Dictionary, fizz_positions: Array) -> void:
	var positions: Array[Vector3i] = []
	for world_pos: Vector3i in sky_seeds:
		positions.append(world_pos)
	Lighting.update_sky_light_around_world_many(positions, manager)
	flush_deferred_fizz(manager, fizz_positions)


# Coalesce only the visual/audio part of a deferred fluid fanout. Lighting
# has already converged through ChunkManager's shared multi-source pass.
static func flush_deferred_fizz(manager, fizz_positions: Array) -> void:
	var n: int = fizz_positions.size()
	if n == 0:
		return
	if n == 1:
		spawn_fizz(manager, fizz_positions[0])
	else:
		spawn_fizz_cluster(manager, fizz_positions)


# Batched variant for a water-neighbor fanout. Audio remains coalesced into
# one fizz, but every converted cell retains Alpha's own eight smoke motes;
# merging their positions into one box was both visually wrong and unable to
# use pi.java's per-particle frame/lifetime sequence.
static func spawn_fizz_cluster(parent: Node, positions: Array) -> void:
	if parent == null or not is_instance_valid(parent) or positions.is_empty():
		return
	SFX.play_fizz(true)
	for p: Vector3i in positions:
		_spawn_lava_conversion_smoke(parent, p)


static func _spawn_lava_conversion_smoke(parent: Node, pos: Vector3i) -> void:
	for _i in range(8):
		var origin := Vector3(pos) + Vector3(randf(), 1.2, randf())
		spawn_largesmoke_particle(parent, origin)


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


# One or more source `bh.java` bubble entities. Motion is explicitly in
# Alpha blocks-per-tick units; callers whose simulation uses m/s divide by 20.
static func spawn_water_bubble(
	parent: Node,
	world_pos: Vector3,
	source_motion_per_tick: Vector3 = Vector3.ZERO,
	count: int = 1,
	viewer_position: Variant = null
) -> Array[Sprite3D]:
	return _spawn_water_particles(
		parent,
		_ALPHA_WATER_PARTICLE.Kind.BUBBLE,
		world_pos,
		source_motion_per_tick,
		count,
		viewer_position
	)


# One or more source `mf.java` splash entities, with the same units and
# visibility gate as spawn_water_bubble.
static func spawn_water_splash(
	parent: Node,
	world_pos: Vector3,
	source_motion_per_tick: Vector3 = Vector3.ZERO,
	count: int = 1,
	viewer_position: Variant = null
) -> Array[Sprite3D]:
	return _spawn_water_particles(
		parent,
		_ALPHA_WATER_PARTICLE.Kind.SPLASH,
		world_pos,
		source_motion_per_tick,
		count,
		viewer_position
	)


# lw.java:165-183, shared by every entity on an air→water transition.
# Alpha emits two independent loops of `1 + width*20`: bubbles first, then
# splash. Each loop rolls its own X/Z point across the entity's full width.
static func spawn_water_entry(
	parent: Node,
	entity_position: Vector3,
	aabb_min_y: float,
	entity_width: float,
	source_motion_per_tick: Vector3,
	viewer_position: Variant = null
) -> Array[Sprite3D]:
	var particles: Array[Sprite3D] = []
	var count: int = ceili(1.0 + entity_width * 20.0)
	var surface_y: float = floorf(aabb_min_y) + 1.0
	for _i in range(count):
		var origin := Vector3(
			entity_position.x + (randf() * 2.0 - 1.0) * entity_width,
			surface_y,
			entity_position.z + (randf() * 2.0 - 1.0) * entity_width,
		)
		var bubble_motion: Vector3 = source_motion_per_tick
		bubble_motion.y -= randf() * 0.2
		particles.append_array(
			spawn_water_bubble(parent, origin, bubble_motion, 1, viewer_position)
		)
	for _i in range(count):
		var origin := Vector3(
			entity_position.x + (randf() * 2.0 - 1.0) * entity_width,
			surface_y,
			entity_position.z + (randf() * 2.0 - 1.0) * entity_width,
		)
		particles.append_array(
			spawn_water_splash(parent, origin, source_motion_per_tick, 1, viewer_position)
		)
	return particles


# hf.java:117-124. Each drowning-damage pulse emits eight bubbles from a
# triangular random cube around the living entity, inheriting its motion.
static func spawn_drowning_bubbles(
	parent: Node,
	entity_position: Vector3,
	source_motion_per_tick: Vector3,
	viewer_position: Variant = null
) -> Array[Sprite3D]:
	var particles: Array[Sprite3D] = []
	for _i in range(8):
		var origin := (
			entity_position
			+ Vector3(
				randf() - randf(),
				randf() - randf(),
				randf() - randf(),
			)
		)
		particles.append_array(
			spawn_water_bubble(parent, origin, source_motion_per_tick, 1, viewer_position)
		)
	return particles


# dp.java:184-203. A moving boat creates one wake batch per Alpha tick once
# horizontal motion exceeds 0.15 blocks/tick. Half of the droplets are cast
# along either side of the hull; the other half trail one block behind it.
static func spawn_boat_wake(
	parent: Node,
	entity_position: Vector3,
	yaw_radians: float,
	source_motion_per_tick: Vector3,
	viewer_position: Variant = null
) -> Array[Sprite3D]:
	var particles: Array[Sprite3D] = []
	var horizontal_speed := Vector2(source_motion_per_tick.x, source_motion_per_tick.z).length()
	if horizontal_speed <= 0.15:
		return particles
	var forward := Vector2(-sin(yaw_radians), -cos(yaw_radians))
	var count: int = ceili(1.0 + horizontal_speed * 60.0)
	for _i in range(count):
		var longitudinal: float = randf() * 2.0 - 1.0
		var side: float = float(randi() % 2 * 2 - 1) * 0.7
		var origin: Vector3
		if randi() % 2 == 0:
			origin = Vector3(
				entity_position.x - forward.x * longitudinal * 0.8 + forward.y * side,
				entity_position.y - 0.125,
				entity_position.z - forward.y * longitudinal * 0.8 - forward.x * side,
			)
		else:
			origin = Vector3(
				entity_position.x + forward.x + forward.y * longitudinal * 0.7,
				entity_position.y - 0.125,
				entity_position.z + forward.y - forward.x * longitudinal * 0.7,
			)
		particles.append_array(
			spawn_water_splash(parent, origin, source_motion_per_tick, 1, viewer_position)
		)
	return particles


static func _spawn_water_particles(
	parent: Node,
	kind: int,
	world_pos: Vector3,
	source_motion_per_tick: Vector3,
	count: int,
	viewer_position: Variant
) -> Array[Sprite3D]:
	var particles: Array[Sprite3D] = []
	if parent == null or not is_instance_valid(parent) or count <= 0:
		return particles
	if not _named_particle_visible(parent, world_pos, viewer_position):
		return particles
	for _i in range(count):
		var particle: Sprite3D = _ALPHA_WATER_PARTICLE.new() as Sprite3D
		parent.add_child(particle)
		particle.call("configure", kind, world_pos, source_motion_per_tick)
		particles.append(particle)
	return particles


# f.java:963-970 rejects all named particles outside a 16-block sphere.
# Tests and detached preview worlds have no player, so absence of a viewer
# means "render"; production always resolves Main/Player here.
static func _named_particle_visible(
	parent: Node, world_pos: Vector3, viewer_position: Variant
) -> bool:
	var viewer: Variant = viewer_position
	if viewer == null and parent.get_tree() != null:
		var player := parent.get_tree().root.get_node_or_null("Main/Player") as Node3D
		if player != null:
			viewer = player.global_position
	if viewer == null:
		return true
	return (
		(viewer as Vector3).distance_squared_to(world_pos) <= _PARTICLE_VISIBILITY_DISTANCE_SQUARED
	)


static func lava_particle_origin(cell_pos: Vector3i) -> Vector3:
	# ld.java:193-197 chooses any X/Z point across the full exposed lava
	# surface. Y is the block's full-height upper bound, exactly cell.y + 1.
	return Vector3(cell_pos) + Vector3(randf(), 1.0, randf())


# One Alpha EntityLavaFX at a random point on the selected lava cell. The
# particle itself owns the 20 Hz arc, exact sprite, lifetime, shrink, and
# age-weighted smoke trail; none of those can be represented faithfully by
# the shared GPU burst pool.
static func spawn_lava_spark(
	parent: Node, cell_pos: Vector3i, viewer_position: Vector3
) -> Sprite3D:
	if parent == null or not is_instance_valid(parent):
		return null
	var origin: Vector3 = lava_particle_origin(cell_pos)
	# f.java:963-970 rejects a requested particle outside the 16-block sphere.
	if viewer_position.distance_squared_to(origin) > 16.0 * 16.0:
		return null
	var spark: Sprite3D = _ALPHA_LAVA_PARTICLE.new() as Sprite3D
	parent.add_child(spark)
	spark.call("configure", origin, viewer_position)
	return spark


# Fire smoke — vanilla qh.java:189-236 BlockFire.randomDisplayTick's
# `largesmoke` spawns. Delegates to spawn_smoke (lava-fizz pool path).
static func spawn_fire_smoke(parent: Node, pos: Vector3i) -> void:
	spawn_smoke(parent, Vector3(pos) + Vector3(0.5, 0.5, 0.5))


# Exact position from ob.java:140-162 (BlockTorch.randomDisplayTick).
# Keeping this pure makes the five metadata cases straightforward to test.
static func torch_particle_origin(cell_pos: Vector3i, meta: int) -> Vector3:
	var origin := Vector3(cell_pos) + Vector3(0.5, 0.7, 0.5)
	match meta:
		1:
			origin += Vector3(-_TORCH_WALL_OFFSET, _TORCH_WALL_RISE, 0.0)
		2:
			origin += Vector3(_TORCH_WALL_OFFSET, _TORCH_WALL_RISE, 0.0)
		3:
			origin += Vector3(0.0, _TORCH_WALL_RISE, -_TORCH_WALL_OFFSET)
		4:
			origin += Vector3(0.0, _TORCH_WALL_RISE, _TORCH_WALL_OFFSET)
	return origin


# ob.java emits one ordinary smoke particle followed by one flame at the
# same point. Dedicated Sprite3D particles avoid mutating the shared fluid
# GPUParticles pool and reproduce Alpha's tick-stepped size/frame changes.
static func spawn_torch_particles(parent: Node, cell_pos: Vector3i, meta: int) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	var origin: Vector3 = torch_particle_origin(cell_pos, meta)
	var brightness: float = EntityLighting.sample_brightness(parent, cell_pos)
	var smoke: Sprite3D = _ALPHA_TORCH_PARTICLE.new() as Sprite3D
	var flame: Sprite3D = _ALPHA_TORCH_PARTICLE.new() as Sprite3D
	parent.add_child(smoke)
	parent.add_child(flame)
	smoke.call("configure", 1, origin, brightness)
	flame.call("configure", 0, origin, brightness)
