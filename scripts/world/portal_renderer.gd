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
# x.java:133 — four per display tick. At 20 Hz with the lifetime above,
# 4 * 20 * 2.2 rounds to the steady-state population of one emitter.
const _PARTICLES_PER_EMITTER: int = 176
# jd.java:19-21 — blue at full strength, red at 0.9, green at 0.3, all
# scaled per particle by `nextFloat() * 0.6 + 0.4`.
const _PARTICLE_COLOR := Color(0.9, 0.3, 1.0)

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
	_cells.clear()
	if _world == null:
		_sync_multimesh()
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
	particles.initial_velocity_min = 0.05
	particles.initial_velocity_max = 0.35
	# jd.java:54 — `ax = p + aA * f2 + (1 - f3)`, a steady rise on top of
	# the drift. Vanilla's drift eases out and back; CPUParticles3D has no
	# return arc, so the outward push plus this lift is the approximation.
	particles.gravity = Vector3(0.0, 0.35, 0.0)
	particles.scale_amount_min = 0.6
	particles.scale_amount_max = 1.0
	particles.scale_amount_curve = _fade_curve()
	particles.color = _PARTICLE_COLOR
	var draw := QuadMesh.new()
	draw.size = Vector2(0.1, 0.1)
	draw.material = _particle_material()
	particles.mesh = draw
	particles.amount = _PARTICLES_PER_EMITTER
	particles.lifetime = _PARTICLE_LIFETIME
	particles.emitting = false
	return particles


static func _particle_material() -> StandardMaterial3D:
	if _particle_mat == null:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_particle_mat = mat
	return _particle_mat


static func _fade_curve() -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.2))
	curve.add_point(Vector2(0.35, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	return curve
