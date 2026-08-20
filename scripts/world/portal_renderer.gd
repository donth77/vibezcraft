class_name PortalRenderer
extends Node3D

# Draws every resident Nether portal cell, and emits their ambient sound
# and particles. See docs/nether-alpha-1.2.6-implementation-plan.md §7.1.
#
# Portal cells are deliberately NOT part of the chunk mesh. Three reasons,
# in order of weight:
#
#   1. the surface animates at 20 Hz, and the chunk atlas is a static
#      texture — animating it would mean re-uploading the atlas 20 times a
#      second for a handful of cells;
#   2. the plan requires ONE shared material and texture for all portals,
#      which is exactly what a MultiMesh gives and what a per-chunk
#      surface does not;
#   3. portals are a few cells per world. A MultiMesh of 6-24 instances is
#      one draw call; threading a fourth vertex stream through the mesher
#      would cost every chunk in the world something.
#
# The instance list is rebuilt on a slow timer from PortalIndex, which is
# a hint cache — so the renderer inherits the same rule as everything else
# that reads it: an entry is confirmed against real blocks before it draws
# anything, and a portal the index has never heard of simply is not drawn
# until the index learns about it (which happens the moment it is lit).

# Rebuild cadence. Portals change only when a player lights or breaks one,
# so five times a second is imperceptible and costs a few block reads.
const REBUILD_INTERVAL: float = 0.2

# x.java:20-25 — the slab is 0.125 either side of centre across the axis
# and full width along it.
const _HALF_THICKNESS: float = 0.125

# Vanilla's randomDisplayTick runs per frame per visible cell. Sampling at
# a fixed 20 Hz instead keeps the one-in-100 hum gate at its source rate
# regardless of framerate — the same reasoning as MobBase's idle SFX.
const _DISPLAY_TICK_INTERVAL: float = 1.0 / 20.0

# Hard cap on drawn cells. A player who walls a room in portals cannot
# make this unbounded; the plan asks for particle and voice counts that
# do not grow without limit, and the instance count is the thing they are
# derived from.
const MAX_CELLS: int = 512

# Cells that get particles and can roll the ambient hum: the nearest six,
# which is exactly one portal. Drawing is cheap (one MultiMesh draw call
# either way) but emitters and voices are not, and past the first portal
# the player cannot tell the difference anyway.
const EFFECT_CELLS: int = 6

# jd.java:22 — lifetime is `(int)(random()*10) + 40` ticks, so 2.0-2.45 s.
const _PARTICLE_LIFETIME: float = 2.2
# x.java:133 spawns four per animateTick HIT — but animateTick samples
# 1000 random cells per tick from a ±16 triangular distribution around
# the player, so a portal cell a few blocks away is hit ~0.1-0.25 times
# a tick, not every tick. Steady state up close is ~20-40 motes per
# cell; 176 (the old value, which assumed a hit every tick) rendered as
# a solid wall of quads.
const _PARTICLES_PER_EMITTER: int = 28
# jd.java:19-21 — blue at full strength, red at 0.9, green at 0.3, all
# scaled per particle by `nextFloat() * 0.6 + 0.4`. The ramp reproduces
# the uniform brightness roll: dim end at f2=0.4, bright end at f2=1.0.
const _PARTICLE_COLOR_DIM := Color(0.36, 0.12, 0.4)
const _PARTICLE_COLOR_BRIGHT := Color(0.9, 0.3, 1.0)

const _PARTICLES_ATLAS_PATH: String = "res://assets/textures/particles/particles.png"

# The particle material, shared by every emitter in every renderer.
static var _particle_mat: StandardMaterial3D = null

var _multimesh_instance: MultiMeshInstance3D
var _rebuild_accum: float = 0.0
var _display_accum: float = 0.0
# Cells currently drawn, with their axis. Shape: [{pos, axis}].
var _cells: Array = []
# Cells currently carrying an emitter, nearest first. Subset of _cells.
var _effect_cells: Array = []
# Persistent emitters, reused across rebuilds. One per EFFECT_CELLS slot.
var _emitters: Array[CPUParticles3D] = []
var _world: Node = null


func _ready() -> void:
	_multimesh_instance = MultiMeshInstance3D.new()
	_multimesh_instance.name = "PortalCells"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _build_cell_mesh()
	mm.instance_count = 0
	_multimesh_instance.multimesh = mm
	_multimesh_instance.material_override = BlockAtlas.portal_material()
	# Portal cells are unlit and self-illuminated; casting shadows from a
	# translucent surface would darken the frame it sits in.
	_multimesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_multimesh_instance)
	# Build the emitter pool now, dormant. Deferring it to the first lit
	# portal put the CPUParticles node setup and particle-shader compile
	# on the ignition frame — a visible hitch on top of the light floods.
	while _emitters.size() < EFFECT_CELLS:
		var fresh: CPUParticles3D = _build_emitter()
		fresh.visible = false
		add_child(fresh)
		_emitters.append(fresh)


# The world to read blocks from. Normally the ChunkManager; tests pass a
# double. Without one the renderer draws nothing rather than guessing.
func set_world(world: Node) -> void:
	_world = world
	rebuild()


func _process(delta: float) -> void:
	_rebuild_accum += delta
	if _rebuild_accum >= REBUILD_INTERVAL:
		_rebuild_accum = 0.0
		rebuild()
	if _cells.is_empty():
		return
	_display_accum += delta
	while _display_accum >= _DISPLAY_TICK_INTERVAL:
		_display_accum -= _DISPLAY_TICK_INTERVAL
		_display_tick()


# One 0.25-block-thick slab, centred on the cell, its wide faces normal to
# +/-Z. The instance transform rotates it a quarter turn for X-axis
# sheets. Built once and shared by every instance.
func _build_cell_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var t: float = _HALF_THICKNESS
	# Corners of the slab in cell-local space, origin at the cell centre.
	var corners: Array[Vector3] = [
		Vector3(-0.5, -0.5, -t),
		Vector3(0.5, -0.5, -t),
		Vector3(0.5, 0.5, -t),
		Vector3(-0.5, 0.5, -t),
		Vector3(-0.5, -0.5, t),
		Vector3(0.5, -0.5, t),
		Vector3(0.5, 0.5, t),
		Vector3(-0.5, 0.5, t),
	]
	# Six quads as corner indices, wound so the outward side survives back-
	# face culling — the shader disables culling anyway, but keeping the
	# winding honest means normals point outward for anything that reads
	# them.
	var quads: Array = [
		[0, 3, 2, 1],  # -Z, the wide face
		[4, 5, 6, 7],  # +Z, the other wide face
		[0, 1, 5, 4],  # -Y
		[3, 7, 6, 2],  # +Y
		[0, 4, 7, 3],  # -X
		[1, 2, 6, 5],  # +X
	]
	for quad: Array in quads:
		var a: Vector3 = corners[quad[0]]
		var b: Vector3 = corners[quad[1]]
		var c: Vector3 = corners[quad[2]]
		var d: Vector3 = corners[quad[3]]
		var normal: Vector3 = (b - a).cross(c - a).normalized()
		# V is flipped so the texture is not upside down, matching the
		# mesher's convention (see mesher.gd's note on winding).
		var uvs: Array[Vector2] = [
			Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0)
		]
		for tri: Array in [[0, 1, 2], [0, 2, 3]]:
			for index: int in tri:
				st.set_normal(normal)
				st.set_uv(uvs[index])
				st.add_vertex([a, b, c, d][index])
	return st.commit()


# Re-derive the drawn cell list from the index, confirming each entry
# against live blocks.
func rebuild() -> void:
	var pp := PerfProbe.begin("portal.rebuild")
	_cells.clear()
	if _world == null:
		_sync_multimesh()
		PerfProbe.end("portal.rebuild", pp)
		return
	var dimension: int = DimensionContext.active()
	for bottom: Vector3i in PortalIndex.entries(dimension):
		if not PortalIndex.validate(dimension, _world, bottom):
			continue
		var cell: Vector3i = bottom
		while _world.get_world_block(cell) == Blocks.PORTAL:
			if _cells.size() >= MAX_CELLS:
				break
			_cells.append({"pos": cell, "axis": NetherPortal.portal_axis(_world, cell)})
			cell += Vector3i(0, 1, 0)
		if _cells.size() >= MAX_CELLS:
			break
	_sync_multimesh()
	_sync_emitters()

	PerfProbe.end("portal.rebuild", pp)


func _sync_multimesh() -> void:
	if _multimesh_instance == null:
		return
	var mm: MultiMesh = _multimesh_instance.multimesh
	mm.instance_count = _cells.size()
	for i: int in range(_cells.size()):
		var entry: Dictionary = _cells[i]
		var pos: Vector3i = entry["pos"]
		var basis := Basis.IDENTITY
		if int(entry["axis"]) == NetherPortal.AXIS_Z:
			# The slab is built normal to Z, which is the X-axis sheet's
			# orientation. A Z-axis sheet is the same slab turned a quarter
			# turn about Y.
			basis = Basis(Vector3.UP, PI * 0.5)
		mm.set_instance_transform(i, Transform3D(basis, Vector3(pos) + Vector3(0.5, 0.5, 0.5)))


# x.java:129 — the per-cell display tick's audio half: one roll in a
# hundred, per cell, per tick.
#
# Only the effect cells roll. Vanilla rolls every visible cell, but
# vanilla is also not at risk of a player building a wall of portals and
# pinning every audio voice in the mixer.
func _display_tick() -> void:
	for entry: Dictionary in _effect_cells:
		if randi() % NetherPortal.AMBIENT_SOUND_CHANCE == 0:
			var pos: Vector3i = entry["pos"]
			SFX.play_portal_ambient(Vector3(pos) + Vector3(0.5, 0.5, 0.5))


# Point the fixed emitter pool at the nearest EFFECT_CELLS cells.
#
# Persistent continuous emitters rather than one-shot spawns: x.java asks
# for four particles per cell per display tick, which is 480 spawns a
# second across one portal. Pooling THAT would churn; a steady-state
# emitter produces the same population for a fixed cost.
func _sync_emitters() -> void:
	_effect_cells = _nearest_cells(EFFECT_CELLS)
	while _emitters.size() < _effect_cells.size():
		var fresh: CPUParticles3D = _build_emitter()
		add_child(fresh)
		_emitters.append(fresh)
	for i: int in range(_emitters.size()):
		var emitter: CPUParticles3D = _emitters[i]
		if i >= _effect_cells.size():
			emitter.emitting = false
			emitter.visible = false
			continue
		var entry: Dictionary = _effect_cells[i]
		var pos: Vector3i = entry["pos"]
		emitter.position = Vector3(pos) + Vector3(0.5, 0.5, 0.5)
		# x.java:144-149 — the drift is ACROSS the sheet, on whichever side
		# each particle spawns. A single emitter cannot pick a side per
		# particle, so it spans both: a box that reaches a quarter block
		# out either way, with the spread doing the rest. What survives is
		# the thing you actually see, which is a swirl breathing out of the
		# surface rather than sitting flat on it.
		if int(entry["axis"]) == NetherPortal.AXIS_X:
			emitter.emission_box_extents = Vector3(0.5, 0.5, 0.25)
		else:
			emitter.emission_box_extents = Vector3(0.25, 0.5, 0.5)
		emitter.visible = true
		emitter.emitting = true


# The EFFECT_CELLS cells closest to the camera. Camera rather than player
# because this is purely a display effect and the camera is what can see
# it — in third person the two are metres apart.
func _nearest_cells(limit: int) -> Array:
	if _cells.size() <= limit:
		return _cells.duplicate()
	var viewpoint := Vector3.ZERO
	var camera: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null:
		viewpoint = camera.global_position
	var sorted: Array = _cells.duplicate()
	sorted.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return (
				Vector3(a["pos"]).distance_squared_to(viewpoint)
				< Vector3(b["pos"]).distance_squared_to(viewpoint)
			)
	)
	return sorted.slice(0, limit)


func _build_emitter() -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = Vector3(0.5, 0.5, 0.25)
	particles.direction = Vector3(0, 1, 0)
	particles.spread = 180.0
	particles.initial_velocity_min = 0.1
	particles.initial_velocity_max = 0.4
	# jd.java:54 — vanilla's drift eases out and RETURNS: the mote is
	# pushed off the sheet, then converges back toward where it spawned.
	# CPUParticles3D has no return arc, but a negative radial pull toward
	# the emitter origin against the outward launch reads the same way —
	# a swirl breathing around the surface instead of a spray leaving it.
	particles.radial_accel_min = -0.4
	particles.radial_accel_max = -0.1
	particles.gravity = Vector3(0.0, 0.15, 0.0)
	particles.scale_amount_min = 0.5
	particles.scale_amount_max = 0.7
	particles.scale_amount_curve = _fade_curve()
	# Per-particle brightness roll (nextFloat() * 0.6 + 0.4) — sampled
	# uniformly along the dim→bright ramp instead of one flat pink.
	var ramp := Gradient.new()
	ramp.set_color(0, _PARTICLE_COLOR_DIM)
	ramp.set_color(1, _PARTICLE_COLOR_BRIGHT)
	particles.color_initial_ramp = ramp
	# jd.java picks a random smoke tile (0-7 of particles.png row 0) per
	# particle and keeps it: random anim offset, zero anim speed.
	particles.anim_offset_min = 0.0
	particles.anim_offset_max = 1.0
	particles.anim_speed_min = 0.0
	particles.anim_speed_max = 0.0
	var draw := QuadMesh.new()
	# EntityFX renders at half-width `0.1 * aq` with aq rolled 0.5-0.7 —
	# a 0.2 quad under the 0.5-0.7 scale roll above lands on the same
	# 0.10-0.14 world size.
	draw.size = Vector2(0.2, 0.2)
	draw.material = _particle_material()
	particles.mesh = draw
	particles.amount = _PARTICLES_PER_EMITTER
	particles.lifetime = _PARTICLE_LIFETIME
	particles.emitting = false
	return particles


static func _particle_material() -> StandardMaterial3D:
	if _particle_mat == null:
		# The 8-frame smoke row of vanilla particles.png. NOT via
		# AtlasTexture — its region crop is ignored by the 3D particle
		# path, so the whole 128x16 strip squishes onto each quad as
		# horizontal dashes (the same artifact fluid_fx.gd documents on
		# get_smoke_subparticle_material). Baking the row into a
		# standalone ImageTexture makes the anim grid slice real pixels,
		# the exact mechanism block_fx's dig particles ship on. The
		# purple tint comes from the per-particle color ramp via
		# vertex_color_use_as_albedo.
		var sheet: Texture2D = load(_PARTICLES_ATLAS_PATH) as Texture2D
		var img: Image = sheet.get_image()
		if img.is_compressed():
			img.decompress()
		var row: Image = img.get_region(Rect2i(0, 0, 128, 16))
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_texture = ImageTexture.create_from_image(row)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat.particles_anim_h_frames = 8
		mat.particles_anim_v_frames = 1
		mat.particles_anim_loop = false
		_particle_mat = mat
	return _particle_mat


static func _fade_curve() -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.2))
	curve.add_point(Vector2(0.35, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	return curve
