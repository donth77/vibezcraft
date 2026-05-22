class_name BlockMesh
extends RefCounted

# Builds a small, fully-textured block cube using the shared block atlas.
# Used by dropped_item.gd (item entities) and player.gd (held-item display).
# Caches one ArrayMesh per block id so that many instances share GPU data.

const FACE_NAMES: Array = ["top", "bottom", "side", "side", "side", "side"]

# Held/dropped/icon fence gate boxes — canonical 1.9 closed-state model.
# 8 planks-textured boxes: 2 outer posts (y=5..16/16), 2 inner posts
# (y=6..15/16, centered), 4 rails (lower y=6..9/16, upper y=12..15/16).
# Inventory always shows the closed silhouette regardless of placed meta.
const _HELD_FENCE_GATE_BOXES: Array = [
	# Outer posts at the X edges — full height so the held / icon gate
	# doesn't appear to float (vanilla 1.9 trims to y=5..16 because real
	# placements connect to fences below, which we can't assume here).
	[Vector3(0.0, 0.0, 0.4375), Vector3(0.125, 1.0, 0.5625)],
	[Vector3(0.875, 0.0, 0.4375), Vector3(1.0, 1.0, 0.5625)],
	# Inner posts at the gate center.
	[Vector3(0.375, 0.375, 0.4375), Vector3(0.5, 0.9375, 0.5625)],
	[Vector3(0.5, 0.375, 0.4375), Vector3(0.625, 0.9375, 0.5625)],
	# Lower + upper rails, left + right halves.
	[Vector3(0.125, 0.375, 0.4375), Vector3(0.375, 0.5625, 0.5625)],
	[Vector3(0.125, 0.75, 0.4375), Vector3(0.375, 0.9375, 0.5625)],
	[Vector3(0.625, 0.375, 0.4375), Vector3(0.875, 0.5625, 0.5625)],
	[Vector3(0.625, 0.75, 0.4375), Vector3(0.875, 0.9375, 0.5625)],
]

static var _cache: Dictionary = {}  # block_id → ArrayMesh


static func get_cube_mesh(block_id: int, size: float = 1.0) -> ArrayMesh:
	var key: String = "%d_%.4f" % [block_id, size]
	if not _cache.has(key):
		# TORCH gets a tight 8-vert pillar box (same geometry the chunk
		# mesher emits for in-world torches), not a full cube.
		if block_id == Blocks.TORCH:
			_cache[key] = _build_torch(size)
		elif block_id == Blocks.FENCE:
			_cache[key] = _build_fence_post(size)
		elif block_id == Blocks.WOOD_STAIRS or block_id == Blocks.COBBLESTONE_STAIRS:
			_cache[key] = _build_stair(block_id, size)
		elif block_id == Blocks.WOODEN_DOOR or block_id == Blocks.IRON_DOOR:
			_cache[key] = _build_door(block_id, size)
		elif block_id == Blocks.LADDER:
			_cache[key] = _build_ladder(size)
		elif block_id == Blocks.HALF_SLAB:
			_cache[key] = _build_slab(block_id, size)
		elif block_id == Blocks.FENCE_GATE:
			_cache[key] = _build_fence_gate(size)
		else:
			_cache[key] = _build(block_id, size)
	return _cache[key] as ArrayMesh


# Held-torch mesh — same proportions as the in-world torch (square
# cross-section) but built at a larger `size` so it reads at held-item
# scale. Cached separately from the in-world mesh.
static func get_held_torch_mesh(size: float) -> ArrayMesh:
	var key: String = "torch_held_%.4f" % size
	if not _cache.has(key):
		_cache[key] = _build_torch(size, 1.0, 2.0)
	return _cache[key] as ArrayMesh


# Six-face textured cube. Face winding mirrors the chunk mesher's
# (CW-front + cull_back) and UVs are V-flipped so atlas tiles aren't
# upside-down on side faces.
static func _build(block_id: int, size: float) -> ArrayMesh:
	var s: float = size * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var faces: Array = [
		[
			Vector3(-s, s, -s),
			Vector3(-s, s, s),
			Vector3(s, s, s),
			Vector3(s, s, -s),
			Vector3(0, 1, 0)
		],
		[
			Vector3(-s, -s, s),
			Vector3(-s, -s, -s),
			Vector3(s, -s, -s),
			Vector3(s, -s, s),
			Vector3(0, -1, 0)
		],
		[
			Vector3(s, -s, -s),
			Vector3(s, s, -s),
			Vector3(s, s, s),
			Vector3(s, -s, s),
			Vector3(1, 0, 0)
		],
		[
			Vector3(-s, -s, s),
			Vector3(-s, s, s),
			Vector3(-s, s, -s),
			Vector3(-s, -s, -s),
			Vector3(-1, 0, 0)
		],
		[
			Vector3(s, -s, s),
			Vector3(s, s, s),
			Vector3(-s, s, s),
			Vector3(-s, -s, s),
			Vector3(0, 0, 1)
		],
		[
			Vector3(-s, -s, -s),
			Vector3(-s, s, -s),
			Vector3(s, s, -s),
			Vector3(s, -s, -s),
			Vector3(0, 0, -1)
		],
	]
	for face_idx: int in range(6):
		var face: Array = faces[face_idx]
		var base: int = verts.size()
		for i: int in range(4):
			verts.append(face[i])
			norms.append(face[4])
		var face_name: String = FACE_NAMES[face_idx]
		var tex_name: String = Blocks.get_face_texture(block_id, face_name)
		var rect: Rect2 = BlockAtlas.uv_rect(tex_name)
		# Side faces (idx 2-5) get U swapped so the texture renders
		# un-mirrored on the cube — without this, asymmetric horizontal
		# detail (like the "N" in TNT's side lettering) reads backwards
		# because the +X face's screen-right axis is -Z, but the v0 vertex
		# (at -Z) was being mapped to texture LEFT. Top/bottom keep the
		# original order (their U axis is world-X, not screen-mirrored).
		if face_idx < 2:
			uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
			uvs.append(Vector2(rect.position.x, rect.position.y))
			uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
			uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
		else:
			uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
			uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
			uvs.append(Vector2(rect.position.x, rect.position.y))
			uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, BlockAtlas.entity_material())
	return mesh


# Half-slab — full-width, half-height cube. Same per-face texture lookup
# as `_build` (top/bottom = stone_slab_top, sides = stone_slab_side), but
# the top vertex is at y=0 instead of y=+s. Used for inventory icons and
# dropped/held items so a half-slab in those contexts visually reads as
# half-height instead of a full cube. Without this, the icon renderer
# skipped HALF_SLAB and the inventory fell back to the flat side sprite,
# which looked wrong (no top face, no isometric).
static func _build_slab(block_id: int, size: float) -> ArrayMesh:
	var s: float = size * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Same face order as `_build`. Top y = 0 (half-height); bottom y = -s.
	var faces: Array = [
		[
			Vector3(-s, 0, -s),
			Vector3(-s, 0, s),
			Vector3(s, 0, s),
			Vector3(s, 0, -s),
			Vector3(0, 1, 0)
		],
		[
			Vector3(-s, -s, s),
			Vector3(-s, -s, -s),
			Vector3(s, -s, -s),
			Vector3(s, -s, s),
			Vector3(0, -1, 0)
		],
		[
			Vector3(s, -s, -s),
			Vector3(s, 0, -s),
			Vector3(s, 0, s),
			Vector3(s, -s, s),
			Vector3(1, 0, 0)
		],
		[
			Vector3(-s, -s, s),
			Vector3(-s, 0, s),
			Vector3(-s, 0, -s),
			Vector3(-s, -s, -s),
			Vector3(-1, 0, 0)
		],
		[
			Vector3(s, -s, s),
			Vector3(s, 0, s),
			Vector3(-s, 0, s),
			Vector3(-s, -s, s),
			Vector3(0, 0, 1)
		],
		[
			Vector3(-s, -s, -s),
			Vector3(-s, 0, -s),
			Vector3(s, 0, -s),
			Vector3(s, -s, -s),
			Vector3(0, 0, -1)
		],
	]
	for face_idx: int in range(6):
		var face: Array = faces[face_idx]
		var base: int = verts.size()
		for i: int in range(4):
			verts.append(face[i])
			norms.append(face[4])
		var face_name: String = FACE_NAMES[face_idx]
		var tex_name: String = Blocks.get_face_texture(block_id, face_name)
		var rect: Rect2 = BlockAtlas.uv_rect(tex_name)
		# Side faces (idx 2-5) only span the bottom half of the cube vertically,
		# so we sample the BOTTOM half of the slab_side texture (v ∈ [mid, max])
		# rather than stretching the full tile across the short face. Matches
		# vanilla qj.java::a which assigns stone_slab_side index 5 — designed
		# to read from the lower-half region of its own 16×16 sprite.
		if face_idx < 2:
			uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
			uvs.append(Vector2(rect.position.x, rect.position.y))
			uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
			uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
		else:
			var v_mid: float = rect.position.y + rect.size.y * 0.5
			var v_max: float = rect.position.y + rect.size.y
			uvs.append(Vector2(rect.position.x + rect.size.x, v_max))
			uvs.append(Vector2(rect.position.x + rect.size.x, v_mid))
			uvs.append(Vector2(rect.position.x, v_mid))
			uvs.append(Vector2(rect.position.x, v_max))
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, BlockAtlas.entity_material())
	return mesh


# Held/dropped/icon fence gate — canonical 1.9 closed-state model. See
# `_HELD_FENCE_GATE_BOXES` near the top of the file for the box list.
# Reuses `_emit_planks_box` so each face samples the planks sub-rect
# matching its projected extent (same convention as the held fence).
static func _build_fence_gate(size: float) -> ArrayMesh:
	var rect: Rect2 = BlockAtlas.uv_rect("planks")
	var pu0: float = rect.position.x
	var pu1: float = rect.position.x + rect.size.x
	var pv0: float = rect.position.y
	var pv1: float = rect.position.y + rect.size.y
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for box: Array in _HELD_FENCE_GATE_BOXES:
		_emit_planks_box(verts, norms, uvs, indices, box[0], box[1], size, pu0, pu1, pv0, pv1)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, BlockAtlas.entity_material())
	return mesh


# Held/dropped/icon fence — vanilla bk.java:1715-1759 (renderType 11
# inventory branch) draws FOUR boxes: two full-height posts hugging the
# front/back Z edges + two slim rails (top + bottom) connecting them
# along Z, extending slightly past the cell on both ends. This is what
# the user sees in their hand and on the ground; the in-world geometry
# (post + neighbour-connected rails) is built separately by the chunk
# mesher's `_emit_fence_geometry`.
static func _build_fence_post(size: float) -> ArrayMesh:
	var rect: Rect2 = BlockAtlas.uv_rect("planks")
	var pu0: float = rect.position.x
	var pu1: float = rect.position.x + rect.size.x
	var pv0: float = rect.position.y
	var pv1: float = rect.position.y + rect.size.y
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Post half-width and rail half-thickness from vanilla constants:
	#   posts use f3 = 0.125 (so post is 0.25 wide × 1.0 tall × 0.25 deep)
	#   rails use f3 = 0.0625 (0.125 wide × 0.125 tall × 1.25 long,
	#                          extending -0.125..1.125 along Z)
	var pf: float = 0.125
	var rf: float = 0.0625
	# Post 1 — front (low Z)
	_emit_planks_box(
		verts,
		norms,
		uvs,
		indices,
		Vector3(0.5 - pf, 0.0, 0.0),
		Vector3(0.5 + pf, 1.0, pf * 2.0),
		size,
		pu0,
		pu1,
		pv0,
		pv1
	)
	# Post 2 — back (high Z)
	_emit_planks_box(
		verts,
		norms,
		uvs,
		indices,
		Vector3(0.5 - pf, 0.0, 1.0 - pf * 2.0),
		Vector3(0.5 + pf, 1.0, 1.0),
		size,
		pu0,
		pu1,
		pv0,
		pv1
	)
	# Top rail — y 12/16..15/16, extends past the cell on both Z ends
	_emit_planks_box(
		verts,
		norms,
		uvs,
		indices,
		Vector3(0.5 - rf, 1.0 - rf * 3.0, -rf * 2.0),
		Vector3(0.5 + rf, 1.0 - rf, 1.0 + rf * 2.0),
		size,
		pu0,
		pu1,
		pv0,
		pv1
	)
	# Bottom rail — y 6/16..9/16
	_emit_planks_box(
		verts,
		norms,
		uvs,
		indices,
		Vector3(0.5 - rf, 0.5 - rf * 3.0, -rf * 2.0),
		Vector3(0.5 + rf, 0.5 - rf, 1.0 + rf * 2.0),
		size,
		pu0,
		pu1,
		pv0,
		pv1
	)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, BlockAtlas.entity_material())
	return mesh


# Vanilla-style box emit for held-fence rendering. `mn`/`mx` are in
# [0..1] unit-cube space (matches vanilla's nq.a() setBlockBounds
# convention); translated to origin-centered local coords scaled by
# `size`. Each face samples a sub-rect of the planks tile matching the
# box's projected dimensions on that face, same way RenderBlocks'
# default face renderers do (`bk.java::a/b/c/d/e/f` compute U/V from
# block bounds bk..bp). Coords outside [0, 1] (rails extending past
# the cell) are clamped to the planks tile bounds — vanilla samples
# beyond into neighbour atlas tiles, but the atlas-edge gutters and
# the rail's slim profile mean the difference is invisible at icon /
# entity scale.
# gdlint: disable=function-arguments-number
static func _emit_planks_box(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	mn: Vector3,
	mx: Vector3,
	size: float,
	pu0: float,
	pu1: float,
	pv0: float,
	pv1: float,
) -> void:
	var lx0: float = (mn.x - 0.5) * size
	var lx1: float = (mx.x - 0.5) * size
	var ly0: float = (mn.y - 0.5) * size
	var ly1: float = (mx.y - 0.5) * size
	var lz0: float = (mn.z - 0.5) * size
	var lz1: float = (mx.z - 0.5) * size
	var c000 := Vector3(lx0, ly0, lz0)
	var c100 := Vector3(lx1, ly0, lz0)
	var c010 := Vector3(lx0, ly1, lz0)
	var c110 := Vector3(lx1, ly1, lz0)
	var c001 := Vector3(lx0, ly0, lz1)
	var c101 := Vector3(lx1, ly0, lz1)
	var c011 := Vector3(lx0, ly1, lz1)
	var c111 := Vector3(lx1, ly1, lz1)
	# Map a 0..1 unit coord to the planks atlas U or V range (clamped).
	var pu_x0: float = pu0 + (pu1 - pu0) * clampf(mn.x, 0.0, 1.0)
	var pu_x1: float = pu0 + (pu1 - pu0) * clampf(mx.x, 0.0, 1.0)
	var pu_z0: float = pu0 + (pu1 - pu0) * clampf(mn.z, 0.0, 1.0)
	var pu_z1: float = pu0 + (pu1 - pu0) * clampf(mx.z, 0.0, 1.0)
	var pv_y0: float = pv0 + (pv1 - pv0) * (1.0 - clampf(mx.y, 0.0, 1.0))
	var pv_y1: float = pv0 + (pv1 - pv0) * (1.0 - clampf(mn.y, 0.0, 1.0))
	var pv_z0: float = pv0 + (pv1 - pv0) * clampf(mn.z, 0.0, 1.0)
	var pv_z1: float = pv0 + (pv1 - pv0) * clampf(mx.z, 0.0, 1.0)
	# +Y top — UV samples the x-z projection
	_fence_face(
		verts, norms, uvs, indices, c010, c011, c111, c110, Vector3.UP, pu_x0, pv_z0, pu_x1, pv_z1
	)
	# -Y bottom
	_fence_face(
		verts, norms, uvs, indices, c001, c000, c100, c101, Vector3.DOWN, pu_x0, pv_z0, pu_x1, pv_z1
	)
	# -Z (north) — UV is x × y (V-flipped)
	_fence_face(
		verts,
		norms,
		uvs,
		indices,
		c010,
		c110,
		c100,
		c000,
		Vector3(0, 0, -1),
		pu_x0,
		pv_y0,
		pu_x1,
		pv_y1
	)
	# +Z (south)
	_fence_face(
		verts,
		norms,
		uvs,
		indices,
		c111,
		c011,
		c001,
		c101,
		Vector3(0, 0, 1),
		pu_x0,
		pv_y0,
		pu_x1,
		pv_y1
	)
	# -X (west) — UV is z × y
	_fence_face(
		verts,
		norms,
		uvs,
		indices,
		c011,
		c010,
		c000,
		c001,
		Vector3(-1, 0, 0),
		pu_z0,
		pv_y0,
		pu_z1,
		pv_y1
	)
	# +X (east)
	_fence_face(
		verts,
		norms,
		uvs,
		indices,
		c110,
		c111,
		c101,
		c100,
		Vector3(1, 0, 0),
		pu_z0,
		pv_y0,
		pu_z1,
		pv_y1
	)


# Stair step — two-box mesh (bottom half-slab + upper step) in meta-0
# orientation (ascending +X). Centered at origin for held/dropped/icon.
static func _build_stair(block_id: int, size: float) -> ArrayMesh:
	var rect: Rect2 = BlockAtlas.uv_rect(Blocks.get_face_texture(block_id, "side"))
	var u0: float = rect.position.x
	var u1: float = rect.position.x + rect.size.x
	var v0_uv: float = rect.position.y
	var v1_uv: float = rect.position.y + rect.size.y
	var s: float = size * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	_stair_box(
		verts, norms, uvs, indices, Vector3(-s, -s, -s), Vector3(0.0, 0.0, s), u0, u1, v0_uv, v1_uv
	)
	_stair_box(
		verts, norms, uvs, indices, Vector3(0.0, -s, -s), Vector3(s, s, s), u0, u1, v0_uv, v1_uv
	)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, BlockAtlas.entity_material())
	return mesh


# Door slab — 3/16-thick × full-height panel showing the lower-half texture.
# Centered at origin for held/dropped/icon display.
static func _build_door(block_id: int, size: float) -> ArrayMesh:
	var tex_name: String = Blocks.door_texture(block_id, 0)  # lower half
	var rect: Rect2 = BlockAtlas.uv_rect(tex_name)
	var u0: float = rect.position.x
	var u1: float = rect.position.x + rect.size.x
	var v0_uv: float = rect.position.y
	var v1_uv: float = rect.position.y + rect.size.y
	var s: float = size * 0.5
	var t: float = (3.0 / 16.0) * size * 0.5  # half-thickness
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	_stair_box(
		verts, norms, uvs, indices, Vector3(-s, -s, -t), Vector3(s, s, t), u0, u1, v0_uv, v1_uv
	)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, BlockAtlas.entity_material())
	return mesh


# gdlint: disable=function-arguments-number
static func _stair_box(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	mn: Vector3,
	mx: Vector3,
	u0: float,
	u1: float,
	v0: float,
	v1: float,
) -> void:
	var c000 := Vector3(mn.x, mn.y, mn.z)
	var c100 := Vector3(mx.x, mn.y, mn.z)
	var c010 := Vector3(mn.x, mx.y, mn.z)
	var c110 := Vector3(mx.x, mx.y, mn.z)
	var c001 := Vector3(mn.x, mn.y, mx.z)
	var c101 := Vector3(mx.x, mn.y, mx.z)
	var c011 := Vector3(mn.x, mx.y, mx.z)
	var c111 := Vector3(mx.x, mx.y, mx.z)
	var faces: Array = [
		[c010, c011, c111, c110, Vector3.UP],
		[c001, c000, c100, c101, Vector3.DOWN],
		[c100, c110, c111, c101, Vector3.RIGHT],
		[c001, c011, c010, c000, Vector3.LEFT],
		[c101, c111, c011, c001, Vector3.BACK],
		[c000, c010, c110, c100, Vector3.FORWARD],
	]
	for face: Array in faces:
		var base: int = verts.size()
		for i: int in range(4):
			verts.append(face[i])
			norms.append(face[4])
		uvs.append(Vector2(u0, v1))
		uvs.append(Vector2(u0, v0))
		uvs.append(Vector2(u1, v0))
		uvs.append(Vector2(u1, v1))
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)


# gdlint: disable=function-arguments-number
static func _fence_face(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	normal: Vector3,
	u_min: float,
	v_min: float,
	u_max: float,
	v_max: float,
) -> void:
	var base: int = verts.size()
	verts.append(v0)
	verts.append(v1)
	verts.append(v2)
	verts.append(v3)
	for _i: int in range(4):
		norms.append(normal)
	uvs.append(Vector2(u_min, v_min))
	uvs.append(Vector2(u_max, v_min))
	uvs.append(Vector2(u_max, v_max))
	uvs.append(Vector2(u_min, v_max))
	indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array)


# Tight 8-vert torch pillar — same geometry the chunk mesher emits for
# floor torches via Mesher._emit_torch_box. Box dimensions in cell units:
# 0.125 wide × 0.625 tall × 0.125 deep. `size` scales the whole thing.
# UV mapping: top/bottom faces = flame center sub-rect (cols 7-9 / rows
# 6-8); 4 side faces = central torch silhouette (cols 7-9 / rows 6-16)
# mapped with U across face width, V along face height — so the visible
# silhouette (flame top, stick body) renders right-side-up from any
# camera angle.
static func _build_torch(
	size: float, width_mult: float = 1.0, depth_mult: float = 1.0
) -> ArrayMesh:
	var rect: Rect2 = BlockAtlas.uv_rect("torch")
	var u0: float = rect.position.x
	var u1: float = rect.position.x + rect.size.x
	var v0: float = rect.position.y
	var v1: float = rect.position.y + rect.size.y
	var su0: float = u0 + (u1 - u0) * (7.0 / 16.0)
	var su1: float = u0 + (u1 - u0) * (9.0 / 16.0)
	var t_v_top: float = v0 + (v1 - v0) * (6.0 / 16.0)
	var t_v_bot: float = v0 + (v1 - v0) * (8.0 / 16.0)
	var s_v_top: float = v0 + (v1 - v0) * (6.0 / 16.0)
	var s_v_bot: float = v1
	var hw: float = 0.0625 * size * width_mult  # half-width (X)
	var hh: float = 0.3125 * size  # half-height (Y, unscaled)
	var hd: float = 0.0625 * size * depth_mult  # half-depth (Z)
	# 8 box vertices — naming b/t = bottom/top of pillar, n/p = neg/pos
	# X, n/p Z. ao[0..3] are the bottom 4 verts, ao[4..7] the top 4.
	var ao: Array[Vector3] = [
		Vector3(-hw, -hh, -hd),  # ao[0] bot, -X, -Z
		Vector3(hw, -hh, -hd),  # ao[1] bot, +X, -Z
		Vector3(hw, -hh, hd),  # ao[2] bot, +X, +Z
		Vector3(-hw, -hh, hd),  # ao[3] bot, -X, +Z
		Vector3(-hw, hh, -hd),  # ao[4] top, -X, -Z
		Vector3(hw, hh, -hd),  # ao[5] top, +X, -Z
		Vector3(hw, hh, hd),  # ao[6] top, +X, +Z
		Vector3(-hw, hh, hd),  # ao[7] top, -X, +Z
	]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Mirrors Mesher._emit_torch_box's per-face vert ordering and UV map.
	_emit_torch_face(
		verts, norms, uvs, indices, ao[1], ao[0], ao[3], ao[2], su0, t_v_top, su1, t_v_bot
	)  # i3=0 — bottom, flame UV
	_emit_torch_face(
		verts, norms, uvs, indices, ao[6], ao[7], ao[4], ao[5], su0, t_v_top, su1, t_v_bot
	)  # i3=1 — top, flame UV
	_emit_torch_face(
		verts, norms, uvs, indices, ao[4], ao[0], ao[1], ao[5], su0, s_v_top, su1, s_v_bot
	)  # i3=2 — local -Z side
	_emit_torch_face(
		verts, norms, uvs, indices, ao[5], ao[1], ao[2], ao[6], su0, s_v_top, su1, s_v_bot
	)  # i3=3 — local +X side
	_emit_torch_face(
		verts, norms, uvs, indices, ao[6], ao[2], ao[3], ao[7], su0, s_v_top, su1, s_v_bot
	)  # i3=4 — local +Z side
	_emit_torch_face(
		verts, norms, uvs, indices, ao[7], ao[3], ao[0], ao[4], su0, s_v_top, su1, s_v_bot
	)  # i3=5 — local -X side
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, BlockAtlas.entity_material())
	return mesh


# Per-face emit for the torch pillar. Vert order is (TL, BL, BR, TR)
# CCW from outside; standard winding [0,1,2,0,2,3] lands the front of
# each face on the OUTSIDE of the box (matching the chunk mesher's
# _emit_torch_box_face after the recent winding fix).
# gdlint: disable=function-arguments-number
static func _emit_torch_face(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	v_tl: Vector3,
	v_bl: Vector3,
	v_br: Vector3,
	v_tr: Vector3,
	u_left: float,
	v_top: float,
	u_right: float,
	v_bot: float
) -> void:
	var base: int = verts.size()
	var normal: Vector3 = (v_br - v_tl).cross(v_bl - v_tl)
	if normal.length_squared() > 1.0e-8:
		normal = normal.normalized()
	verts.append(v_tl)
	verts.append(v_bl)
	verts.append(v_br)
	verts.append(v_tr)
	for _i in range(4):
		norms.append(normal)
	uvs.append(Vector2(u_left, v_top))
	uvs.append(Vector2(u_left, v_bot))
	uvs.append(Vector2(u_right, v_bot))
	uvs.append(Vector2(u_right, v_top))
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3] as PackedInt32Array)


static func _build_ladder(size: float) -> ArrayMesh:
	var s: float = size * 0.5
	var d: float = size * 0.0625  # 1/16 of size — thin slab
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var uv_rect: Rect2 = BlockAtlas.uv_rect("ladder")
	var u0: float = uv_rect.position.x
	var v0: float = uv_rect.position.y
	var u1: float = u0 + uv_rect.size.x
	var v1: float = v0 + uv_rect.size.y
	# Front face (+Z)
	var base: int = verts.size()
	verts.append(Vector3(-s, -s, d))
	verts.append(Vector3(-s, s, d))
	verts.append(Vector3(s, s, d))
	verts.append(Vector3(s, -s, d))
	for _i in range(4):
		norms.append(Vector3(0, 0, 1))
	uvs.append(Vector2(u0, v1))
	uvs.append(Vector2(u0, v0))
	uvs.append(Vector2(u1, v0))
	uvs.append(Vector2(u1, v1))
	indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array)
	# Back face (-Z)
	base = verts.size()
	verts.append(Vector3(s, -s, -d))
	verts.append(Vector3(s, s, -d))
	verts.append(Vector3(-s, s, -d))
	verts.append(Vector3(-s, -s, -d))
	for _i in range(4):
		norms.append(Vector3(0, 0, -1))
	uvs.append(Vector2(u0, v1))
	uvs.append(Vector2(u0, v0))
	uvs.append(Vector2(u1, v0))
	uvs.append(Vector2(u1, v1))
	indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, BlockAtlas.material())
	return mesh
