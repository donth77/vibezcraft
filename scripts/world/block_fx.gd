class_name BlockFx
extends RefCounted

# Vanilla Alpha block-break particles. Port of `bz.java:95-112` (RenderGlobal
# destroyBlockParticles) + `ki.java` (EntityDiggingFX). Vanilla samples a
# 4×4×4 = 64-particle grid across the cube's volume; each particle gets
# outward velocity = (sample_pos - center), texture is a 4×4 random sub-
# region of the block's terrain.png tile, tinted to k=j=i=0.6 (60% bright),
# gravity 0.06/tick, lifetime ~20-40 ticks (1-2 s).
#
# We use **CPUParticles3D** (not GPU). Reasons:
#   * GPUParticles3D triggers a per-permutation shader compile on first
#     DRAW — manifests as a 100-300 ms stutter on the first block break,
#     which also delays the chunk re-mesh visible update so the broken
#     block appears to persist for a moment (user-reported bug).
#   * CPU particle work for 24 quads is microseconds; well below the
#     break frequency we'll ever sustain.
#   * Identical visual output to GPU at this particle count.
# (FluidFx still uses GPU because its smoke/spark systems run continuously
# during fluid ticks, where per-particle CPU cost would matter.)

# Vanilla bz.java:101 hard-codes `n6 = 4` → 4×4×4 = 64 particles per break.
const _PARTICLES_PER_BREAK: int = 64
# 0.8 s ≈ vanilla's 16-32 tick range (which is 0.8-1.6 s at 20 TPS).
const _LIFETIME_SEC: float = 0.8
# Mining-tick particle (one per call). Lifetime is short — vanilla
# pp.java has per-tick AABB collision against blocks (particles stop on
# contact); we don't, so a long lifetime + gravity = particle falls
# straight through the still-solid block being mined. Cap at 0.35s so
# the crumb appears, drifts a few cm outward, fades before it can clip
# into the block volume.
const _MINING_LIFETIME_SEC: float = 0.35
# Pool cap. Mining at max speed (stone with diamond pick ≈ 4 breaks/sec)
# never has more than 4 active break-burst emitters in the 0.8 s lifetime
# window. Mining-particle emitters get a separate small pool — one per
# active mining target (we only mine one block at a time).
const _POOL_SIZE: int = 4
# 50ms cadence × 0.35s lifetime = ~7 emitters in flight at peak. Sized
# 8 so the steady-state recycles cleanly without queue_free churn.
const _MINING_POOL_SIZE: int = 8

# Per-block-id material cache. Key = block id, value = StandardMaterial3D
# with the block's atlas region as albedo texture.
static var _materials: Dictionary = {}
# Pre-warmed CPUParticles3D pool for break bursts. Lazily populated.
static var _pool: Array = []
# Separate pool for during-mining single-particle emitters. Sized smaller
# because we only mine one block at a time, so 1-2 emitters in flight
# at any given moment.
static var _mining_pool: Array = []
# Last parent we reused. Pool nodes stay parented under whichever node was
# the first caller (typically ChunkManager, lives for the whole session).
static var _pool_parent: Node = null


# Returns / builds the cached material for `block_id`. Atlas region comes
# from BlockAtlas.uv_rect_for(block_id, FACE_TOP) — matches the dig sound's
# top-face-as-canonical convention.
static func get_material(block_id: int) -> StandardMaterial3D:
	if _materials.has(block_id):
		return _materials[block_id]
	# Pull the standalone tile image straight from BlockAtlas, which
	# resolves through its _LAYOUT dict directly (no UV-rect round-trip,
	# no half-texel-inset float-to-int math, no AtlasTexture region
	# remapping). This bypass is the only reliable way to get pixel-
	# correct extraction — earlier attempts to derive the pixel rect from
	# the UV rect drifted by ±1 pixel on some packs and the get_region
	# call landed on neighboring tiles (furnace, lava bleed).
	# FACE_SIDE matches vanilla's `nq.bg` (Block.blockIndexInTexture) which
	# defaults to the side face — for grass that's grass_side (green band
	# over dirt) not grass_top (pure green). Vanilla's per-particle 4×4
	# sub-tile sampling means each crumb is a small slice of the side
	# texture; we use the whole tile per particle, but the side texture's
	# mixed colors still read more correctly than the top texture would.
	var tile_img: Image = BlockAtlas.tile_image(block_id, BlockAtlas.FACE_SIDE)
	if tile_img == null:
		return null
	# Foliage tint bake. The leaves texture ships GRAYSCALE so the chunk
	# shader can tint it different greens per biome via `leaves_tint`.
	# StandardMaterial3D doesn't run the chunk shader, so without baking
	# the tint into the per-pixel image, leaves particles render as raw
	# grey/black. Apply the active leaves_tint multiplicatively per pixel.
	# Tile_image returns a fresh duplicate so the mutation doesn't leak
	# back into the live atlas.
	if block_id == Blocks.LEAVES:
		_apply_tint_in_place(tile_img, BlockAtlas.leaves_tint())
	var tile_tex := ImageTexture.create_from_image(tile_img)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = tile_tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# BILLBOARD_PARTICLES + particles_anim_h/v_frames = 4 reproduces vanilla
	# ki.java:23-30 sub-tile sampling. The render shader does
	# `(b % 16 + c/4)/16` and `(b/16 + d/4)/16` with `b` as the tile index
	# and `c, d` as random ints 0-3 — i.e. each particle picks a random
	# 4×4-pixel slice of the 16×16 tile. For grass, grass_side is mostly
	# dirt (top 4px green, bottom 12px dirt) so most particles sample dirt
	# pixels and show as dirt crumbs with occasional green flecks — the
	# canonical vanilla grass-break look.
	#
	# This worked NOW (vs the earlier failed attempt with AtlasTexture)
	# because the texture is now a STANDALONE ImageTexture of just this
	# block's tile, so anim-frames UV slicing operates on tile-local
	# coords [0..1] and produces 1/4×1/4 sub-cells of the tile.
	mat.billboard_mode = StandardMaterial3D.BILLBOARD_PARTICLES
	mat.particles_anim_h_frames = 4
	mat.particles_anim_v_frames = 4
	mat.particles_anim_loop = false
	# Vanilla EntityDiggingFX (ki.java:11-13) sets k=j=i = 0.6f → modulate
	# the sampled texel by 0.6. Reads as "stone-grey crumbs" instead of
	# the full-bright texture pixels.
	mat.albedo_color = Color(0.6, 0.6, 0.6, 1.0)
	_materials[block_id] = mat
	return mat


# Multiply each pixel of `img` by `tint` (per-channel). Used to bake
# the chunk-shader's foliage `leaves_tint` into the standalone particle
# image so leaves crumbs render green instead of grey. Alpha is left
# alone. Values clamp to [0..1] — vanilla's HDR > 1.0 green is dropped
# back to the 8-bit ceiling here (acceptable for the small crumb size).
static func _apply_tint_in_place(img: Image, tint: Vector3) -> void:
	if img == null:
		return
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c: Color = img.get_pixel(x, y)
			if c.a <= 0.0:
				continue
			c.r = clampf(c.r * tint.x, 0.0, 1.0)
			c.g = clampf(c.g * tint.y, 0.0, 1.0)
			c.b = clampf(c.b * tint.z, 0.0, 1.0)
			img.set_pixel(x, y, c)


# Spawn break particles at `world_pos` (the block's integer coord) for
# `block_id`. Parent should outlive the particle lifetime — typically the
# ChunkManager since it's persistent. No-op for AIR / unknown blocks.
# `meta` is consumed by non-cube blocks (signs) whose particle volume
# depends on orientation; default 0 covers full-cube blocks where meta
# doesn't matter.
static func spawn_break(parent: Node, world_pos: Vector3i, block_id: int, meta: int = 0) -> void:
	if block_id == Blocks.AIR:
		return
	var mat: StandardMaterial3D = get_material(block_id)
	if mat == null:
		return
	var particles: CPUParticles3D = _acquire(parent)
	# Swap in the per-block material on the cached QuadMesh draw pass.
	# Pool entries share one mesh; only the albedo texture varies per block.
	var draw: QuadMesh = particles.mesh as QuadMesh
	if draw != null:
		draw.material = mat
	# Pick an emission center + extents that hug the block's actual visible
	# volume. Default = full cube; non-cube blocks (signs) override so
	# particles don't spawn in the empty air around a small panel.
	var center: Vector3 = Vector3(0.5, 0.5, 0.5)
	var extents: Vector3 = Vector3(0.5, 0.5, 0.5)
	if block_id == Blocks.FENCE:
		# Fence post AABB — 0.25 wide × 1.5 tall (vanilla gd.java::a
		# bounds (0.375, 0, 0.375)→(0.625, 1.5, 0.625)). Centered XZ in
		# the cell, sticks 0.5 m above the cell top. Match the same box
		# here so particles spawn within the visible post + arms.
		center = Vector3(0.5, 0.75, 0.5)
		extents = Vector3(0.125, 0.75, 0.125)
	elif block_id == Blocks.SIGN_STANDING:
		# Post + rotating panel — the union of all panel rotations forms a
		# disc, but a 0.5×1×0.5 axis-aligned box covers the post and any
		# yaw of the panel without much overshoot. Matches vanilla
		# ni.java::a() which sets bounds (0.25, 0, 0.25)→(0.75, 1, 0.75).
		extents = Vector3(0.25, 0.5, 0.25)
	elif block_id == Blocks.SIGN_WALL:
		# Panel hangs on the support's far side; mesher coords:
		#   meta=0 (-Z): z ∈ [0.875, 1.0]
		#   meta=1 (+Z): z ∈ [0.0, 0.125]
		#   meta=2 (-X): x ∈ [0.875, 1.0]
		#   meta=3 (+X): x ∈ [0.0, 0.125]
		# Panel itself is 0.875 wide × 0.5 tall × 0.125 thick.
		match meta:
			0:
				center = Vector3(0.5, 0.5, 0.9375)
				extents = Vector3(0.4375, 0.25, 0.0625)
			1:
				center = Vector3(0.5, 0.5, 0.0625)
				extents = Vector3(0.4375, 0.25, 0.0625)
			2:
				center = Vector3(0.9375, 0.5, 0.5)
				extents = Vector3(0.0625, 0.25, 0.4375)
			_:
				center = Vector3(0.0625, 0.5, 0.5)
				extents = Vector3(0.0625, 0.25, 0.4375)
	particles.position = Vector3(world_pos) + center
	particles.emission_box_extents = extents
	particles.visible = true
	particles.restart()
	_schedule_return(parent, particles)


# --- Pool internals ---


static func _acquire(parent: Node) -> CPUParticles3D:
	if _pool_parent == null or not is_instance_valid(_pool_parent):
		_pool_parent = parent
	while not _pool.is_empty():
		# Variant intermediate — typed `: CPUParticles3D` errors on a freed
		# reference. Validate before the typed cast.
		var raw: Variant = _pool.pop_back()
		if is_instance_valid(raw):
			return raw as CPUParticles3D
	var fresh := _build_particles()
	parent.add_child(fresh)
	return fresh


static func _schedule_return(parent: Node, particles: CPUParticles3D) -> void:
	var tree: SceneTree = parent.get_tree()
	if tree == null:
		return
	# +0.2 s grace so the last-spawned particle finishes its lifetime
	# before we hide the emitter. Mirrors FluidFx._schedule_return.
	var cleanup := tree.create_timer(_LIFETIME_SEC + 0.2)
	cleanup.timeout.connect(func() -> void: _return(particles))


static func _return(particles: CPUParticles3D) -> void:
	if not is_instance_valid(particles):
		return
	particles.emitting = false
	particles.visible = false
	if _pool.size() < _POOL_SIZE:
		_pool.append(particles)
	else:
		particles.queue_free()


static func _build_particles() -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	# Box emission at half-cube extents = full cube. Vanilla's 4×4×4 grid
	# spans the unit cube; CPU box-emit gives a uniform random sample of
	# the same volume.
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = Vector3(0.5, 0.5, 0.5)
	# Omnidirectional outward burst. Vanilla bz.java:108 derives velocity
	# from (sample - center); pp.java:31-35 then normalizes that direction
	# and rescales magnitude to f2*0.4 blocks/tick where f2 = 0.15-0.45.
	# Net: 0.06-0.18 blocks/tick = 1.2-3.6 m/s outward, plus +0.1 upward
	# bias (aA += 0.1 → +2 m/s up). 180° spread approximates the random
	# outward distribution.
	particles.direction = Vector3(0, 1, 0)
	particles.spread = 180.0
	particles.initial_velocity_min = 1.5
	particles.initial_velocity_max = 4.0
	# Vanilla pp.java:64 `aA -= 0.04 * h` where h = nq.br = 1.0 for solid
	# blocks → 0.04 blocks/tick² = 16 m/s² in our scale. Earth-like;
	# crumbs arc outward then fall noticeably within the 0.8s lifetime.
	particles.gravity = Vector3(0, -16.0, 0)
	# Vanilla pp.java:66-68 damps velocity by 0.98^tick = ~33%/sec decay.
	# CPUParticles3D `damping` is in m/s²; ~1 m/s² gives a similar curve.
	particles.damping_min = 0.5
	particles.damping_max = 1.5
	# Per-particle random anim_offset → each particle picks one of the 16
	# (anim_h × anim_v) sub-tiles of the block texture. anim_speed=0
	# freezes the pick for the particle's lifetime. Material's
	# particles_anim_h/v_frames=4 defines the slicing.
	particles.anim_offset_min = 0.0
	particles.anim_offset_max = 1.0
	particles.anim_speed_min = 0.0
	particles.anim_speed_max = 0.0
	# Final particle size = mesh.size * scale. mesh 0.15 × scale 0.6-1.0
	# = 9-15 cm crumbs — readable as crumbs without dominating the break
	# point. Matches vanilla's ~3-5-pixel-at-GUI-1 read.
	particles.scale_amount_min = 0.6
	particles.scale_amount_max = 1.0
	# Mesh + draw pass. CPUParticles3D uses `mesh` directly (no draw_pass_1).
	var draw := QuadMesh.new()
	draw.size = Vector2(0.15, 0.15)
	particles.mesh = draw
	particles.amount = _PARTICLES_PER_BREAK
	particles.lifetime = _LIFETIME_SEC
	particles.one_shot = true
	# 1.0 = burst-all-at-once. Vanilla emits the whole 64-particle grid in
	# a single tick at break time, so explosive emit matches that shape.
	particles.explosiveness = 1.0
	# Don't auto-emit on add_child. _acquire returns this in the
	# emitting=false state; spawn_break flips it via restart().
	particles.emitting = false
	return particles


# Vanilla `bz.java:114-143` (RenderGlobal.destroyBlockPartialDigging) —
# called once per tick during mining at the face being hit. Spawns ONE
# EntityDiggingFX with zero initial velocity (slowdown 0.2, size 0.6) at
# `world_pos + 0.5 + face_normal × 0.6` (just outside the face). Particle
# falls straight down with gravity, samples a random 4×4 sub-tile of the
# block texture.
#
# `face_normal` is the OUTWARD normal of the face being hit (e.g. (0,1,0)
# for the top face). interaction.gd derives it from the raycast hit normal.
static func spawn_mining(
	parent: Node, world_pos: Vector3i, block_id: int, face_normal: Vector3
) -> void:
	if block_id == Blocks.AIR:
		return
	var mat: StandardMaterial3D = get_material(block_id)
	if mat == null:
		return
	var particles: CPUParticles3D = _acquire_mining(parent)
	var draw: QuadMesh = particles.mesh as QuadMesh
	if draw != null:
		draw.material = mat
	# Vanilla bz.java:121-141: particle position is randomized within the
	# face plane on the two non-normal axes (f2=0.1 inset from the cube
	# edges → range ~[0.1, 0.9]) and locked at 0.1 outside on the normal
	# axis. We reproduce by setting emission_box_extents to span the face
	# (0.4 on the two non-normal axes, 0 on the normal axis) and offsetting
	# the emitter PAST the face along the normal so particles spawn just
	# outside the still-solid block being mined.
	#
	# face_abs picks out the normal axis; (0.4, 0.4, 0.4) - face_abs * 0.4
	# zeroes the normal axis and leaves 0.4 on the other two.
	var face_abs: Vector3 = face_normal.abs()
	particles.emission_box_extents = Vector3(0.4, 0.4, 0.4) - face_abs * 0.4
	# 0.65 = 0.5 (half-cube) + 0.15 outward — pushes the spawn plane far
	# enough off the face that initial particle position + first-frame
	# gravity don't immediately put it inside the block. Also re-aim the
	# `direction` outward from the face so initial velocity carries the
	# particle further away before gravity dominates.
	particles.position = Vector3(world_pos) + Vector3(0.5, 0.5, 0.5) + face_normal * 0.65
	particles.direction = face_normal
	particles.visible = true
	particles.restart()
	_schedule_return_mining(parent, particles)


static func _acquire_mining(parent: Node) -> CPUParticles3D:
	if _pool_parent == null or not is_instance_valid(_pool_parent):
		_pool_parent = parent
	while not _mining_pool.is_empty():
		# Pop into a Variant first — typed `: CPUParticles3D` errors on a
		# freed-instance ref (chunk unload + pool not invalidated). Validate
		# before the typed cast.
		var raw: Variant = _mining_pool.pop_back()
		if is_instance_valid(raw):
			return raw as CPUParticles3D
	var fresh := _build_mining_particles()
	parent.add_child(fresh)
	return fresh


static func _schedule_return_mining(parent: Node, particles: CPUParticles3D) -> void:
	var tree: SceneTree = parent.get_tree()
	if tree == null:
		return
	var cleanup := tree.create_timer(_MINING_LIFETIME_SEC + 0.2)
	cleanup.timeout.connect(func() -> void: _return_mining(particles))


static func _return_mining(particles: CPUParticles3D) -> void:
	if not is_instance_valid(particles):
		return
	particles.emitting = false
	particles.visible = false
	if _mining_pool.size() < _MINING_POOL_SIZE:
		_mining_pool.append(particles)
	else:
		particles.queue_free()


# Single-particle emitter for the during-mining sprinkle. Vanilla spawns
# one ki at a time with zero initial velocity — gravity + slowdown carry
# it down past the face. We use amount=1 + explosiveness=1 to fire one
# crumb per restart() call.
static func _build_mining_particles() -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	# BOX emission so each spawn lands at a random point within the face
	# plane (extents are set per-spawn in spawn_mining based on face
	# normal). Default extents here are a placeholder — overwritten on
	# first restart().
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = Vector3(0.4, 0, 0.4)
	# `direction` and emission box are reset per-spawn in spawn_mining
	# based on the face being hit. Default to upward as a sane fallback.
	particles.direction = Vector3(0, 1, 0)
	particles.spread = 35.0
	# Vanilla bz.java:142 spawns with input vel (0,0,0); pp.java:31-35
	# jitters and normalizes to ~2 m/s, then `b(0.2f)` slowdown brings it
	# to ~0.4 m/s. Vanilla relies on block-AABB collision (pp.java:65) to
	# stop particles from clipping into the cube. We don't have collision,
	# so we use a slightly stronger outward velocity (0.5-1.2 m/s along
	# face normal) to push the crumb off the face fast enough to clear the
	# cube within the short lifetime.
	particles.initial_velocity_min = 0.5
	particles.initial_velocity_max = 1.2
	# Soft gravity. Vanilla's 16 m/s² × b(0.2f) factor on the +0.1 upward
	# bias gives an effective ~3 m/s² apparent gravity for mining crumbs
	# (they hover briefly then drift). 2.5 m/s² approximates that without
	# block collision pulling them through the cube during 0.35s lifetime.
	particles.gravity = Vector3(0, -2.5, 0)
	particles.damping_min = 0.5
	particles.damping_max = 1.0
	# Per-particle 4×4 sub-tile sampling (same setup as the break burst).
	particles.anim_offset_min = 0.0
	particles.anim_offset_max = 1.0
	particles.anim_speed_min = 0.0
	particles.anim_speed_max = 0.0
	# Vanilla `d(0.6f)` halves the particle size. Our break burst uses 0.6-1.0;
	# mining sprinkle uses 0.4-0.6 → final mesh × scale = 6-9 cm crumbs.
	particles.scale_amount_min = 0.4
	particles.scale_amount_max = 0.6
	var draw := QuadMesh.new()
	draw.size = Vector2(0.15, 0.15)
	particles.mesh = draw
	# One particle per restart(). Caller drives restart at vanilla's
	# 1-per-tick cadence (interaction.gd throttles to ~3 ticks for mining
	# visibility without spam).
	particles.amount = 1
	particles.lifetime = _MINING_LIFETIME_SEC
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emitting = false
	return particles


# Pool warmup. CPUParticles3D with a `BILLBOARD_PARTICLES + anim_h/v_frames`
# StandardMaterial3D triggers a one-time shader-permutation compile on
# first DRAW (~100-300 ms stutter). Even though there's no GPU compute
# particle shader, the rendering side still needs to compile the
# material's vertex+fragment shader for this specific flag combination.
# We force the compile by spawning ONE visible burst at boot — the
# loading screen overlays everything during chunk gen so the brief
# flash is hidden. From then on the shader is in Godot's pipeline
# cache; the first real break is hitch-free.
#
# Uses STONE as the warm material (always available, predictable). Once
# compiled, all per-block-id materials reuse the same shader (only the
# albedo_texture uniform differs, which doesn't trigger a recompile).
#
# The warm emit must land in the active camera's frustum or the renderer
# culls the draw call → shader never compiles. We defer one frame so
# Player._ready has set up the camera, then position the emitter 3 m
# in front of whatever camera is active.
static func warm_pool(parent: Node) -> void:
	_pool_parent = parent
	if not is_instance_valid(parent):
		return
	var mat: StandardMaterial3D = get_material(Blocks.STONE)
	if mat == null:
		return
	var particles := _build_particles()
	var draw: QuadMesh = particles.mesh as QuadMesh
	if draw != null:
		draw.material = mat
	parent.add_child(particles)
	# Defer until after all _readys (Player, Camera3D) so the active camera
	# is set up. Without this, get_camera_3d returns null at boot and we'd
	# spawn at origin where culling may skip the draw → no shader compile.
	var warmer := func() -> void:
		if not is_instance_valid(parent) or not is_instance_valid(particles):
			return
		var cam: Camera3D = parent.get_viewport().get_camera_3d()
		if cam != null:
			particles.position = cam.global_position + (-cam.global_transform.basis.z) * 3.0
		else:
			particles.position = Vector3.ZERO
		particles.visible = true
		particles.restart()
		var tree: SceneTree = parent.get_tree()
		if tree != null:
			var cleanup := tree.create_timer(_LIFETIME_SEC + 0.2)
			cleanup.timeout.connect(func() -> void: _return(particles))
	warmer.call_deferred()
