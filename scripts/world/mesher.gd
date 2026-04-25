class_name Mesher
extends RefCounted

# Face-culled naive meshing. For each block, emit faces only against non-opaque
# neighbors. Returns Dictionary { vertices, normals, uvs, indices } ready for
# ArrayMesh.add_surface_from_arrays.

# Face order: +Y (top), -Y (bottom), +X, -X, +Z, -Z
# Vertex winding is CCW when viewed from outside the cube (front-face per Godot default).

const _FACE_VERTS: Array = [
	# +Y (top) — viewed from above
	[Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
	# -Y (bottom)
	[Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1)],
	# +X (east)
	[Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
	# -X (west)
	[Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(0, 0, 0)],
	# +Z (south)
	[Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1), Vector3(0, 0, 1)],
	# -Z (north)
	[Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)],
]

const _FACE_NORMALS: Array = [
	Vector3(0, 1, 0),
	Vector3(0, -1, 0),
	Vector3(1, 0, 0),
	Vector3(-1, 0, 0),
	Vector3(0, 0, 1),
	Vector3(0, 0, -1),
]

const _FACE_NEIGHBOR: Array = [
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

const _FACE_NAMES: Array = ["top", "bottom", "side", "side", "side", "side"]

# Maps face_idx (0..5) to BlockAtlas face_kind (0=top, 1=bottom, 2=side).
# Kept parallel to _FACE_NAMES so the fast uv_rect_for() path produces the
# same Rect2 as the old uv_rect(get_face_texture(id, name)) path.
const _FACE_KIND: Array = [
	BlockAtlas.FACE_TOP,
	BlockAtlas.FACE_BOTTOM,
	BlockAtlas.FACE_SIDE,
	BlockAtlas.FACE_SIDE,
	BlockAtlas.FACE_SIDE,
	BlockAtlas.FACE_SIDE,
]

# Light → 0..1 normalize. Multiplied (not divided) so float arithmetic
# bit-matches the C++ MesherNative path's `light_scale = 1.0f / 15.0f`.
# Without this, divide-then-cast vs multiply-by-reciprocal disagree at
# 1 ULP in float32 and the parity tests blow up on PackedColorArray equality.
const _LIGHT_SCALE: float = 1.0 / 15.0

# Cross-quad shape — two perpendicular billboards inset within the cell.
# Inset of 0.05/0.95 (i.e. 0.5 ± 0.45) matches vanilla Alpha 1.1.2's
# RenderBlocks.renderCrossedSquares verbatim — see Arta48/Minecraft-Sources-
# Alpha-1.1.2_01: net/minecraft/src/RenderBlocks.java. Each quad is
# rendered 2-sided (front + back winding emitted in _emit_cross_quads),
# matching vanilla's 4-quad emission (2 unique diagonals × 2 sides).
# Layout per quad: 4 verts in CCW order viewed from the side it faces.
const _CROSS_QUADS: Array = [
	# Quad A: SW → NE diagonal (/).
	[
		Vector3(0.05, 0, 0.05),
		Vector3(0.05, 1, 0.05),
		Vector3(0.95, 1, 0.95),
		Vector3(0.95, 0, 0.95),
	],
	# Quad B: NW → SE diagonal (\).
	[
		Vector3(0.05, 0, 0.95),
		Vector3(0.05, 1, 0.95),
		Vector3(0.95, 1, 0.05),
		Vector3(0.95, 0, 0.05),
	],
]

# Set by Game._ready() after the GDExtension loads. Shared across all
# worker threads — MesherNative.mesh_chunk_data is stateless so concurrent
# calls are safe.
static var _native_mesher: RefCounted


# Main-thread init. No-op if the native extension isn't available; callers
# fall through to the GDScript path automatically.
static func enable_native() -> bool:
	if _native_mesher != null:
		return true
	if not ClassDB.class_exists("MesherNative"):
		push_warning(
			"Mesher.enable_native: MesherNative class not in ClassDB (extension not loaded?)"
		)
		return false
	_native_mesher = ClassDB.instantiate("MesherNative")
	if _native_mesher == null:
		push_warning("Mesher.enable_native: failed to instantiate MesherNative")
		return false
	return true


# Fast path used by ChunkManager / ChunkNode during normal gameplay. Uses
# the C++ implementation when available (byte-identical to mesh_chunk —
# enforced by tests/test_mesher_native.gd parity cases) and falls back to
# the pure-GDScript mesh_chunk otherwise. Keep call sites calling this one;
# tests continue to exercise the GDScript path via mesh_chunk directly.
#
# Native handles cubes + water (with cross-chunk edge slices as of the
# edge-slice port — see `emit_water_cell` in mesher_native.cpp). Only
# non-cube blocks (sapling, future torches) still route to GDScript.
#
# Slice 5 ships per-vertex lighting via mesh_chunk_data_lit; water faces
# don't carry COLOR (the water shader ignores it). Parity is guarded by
# tests/test_mesher_native.gd.
static func mesh_chunk_fast(chunk: Chunk) -> Dictionary:
	var native_eligible: bool = _native_mesher != null and not chunk.has_non_cube_blocks
	if native_eligible:
		var probe_token := PerfProbe.begin("mesher.mesh_chunk")
		var result: Dictionary = (
			_native_mesher
			. mesh_chunk_data_lit(
				chunk.blocks,
				chunk.block_meta,
				chunk.sky_light,
				chunk.block_light,
				chunk.max_y,
				BlockAtlas.uv_table_flat(),
				chunk.edge_blocks_west,
				chunk.edge_blocks_east,
				chunk.edge_blocks_north,
				chunk.edge_blocks_south,
				chunk.edge_meta_west,
				chunk.edge_meta_east,
				chunk.edge_meta_north,
				chunk.edge_meta_south,
			)
		)
		_attach_collision_shape(result)
		PerfProbe.end("mesher.mesh_chunk", probe_token)
		return result
	var result: Dictionary = mesh_chunk(chunk)
	_attach_collision_shape(result)
	return result


# Build the ConcavePolygonShape3D from the mesher's collision-face soup
# and stash it on the result dict. Runs on whatever thread the mesher
# was called on — safe for WorkerThreadPool tasks because Godot 4's
# PhysicsServer3D defaults to thread-safe (PhysicsServer3DWrapMT) so
# shape RID allocation + set_faces queue through the server's mutex.
#
# Pre-building here moves the BVH construction (the dominant cost in
# chunk_node._apply_mesh_data — p50 ~2 ms, max 6+ ms) off the main
# thread. The main-thread apply just attaches the already-built shape
# to the StaticBody3D's CollisionShape3D, which is ~µs.
#
# Skips on empty soup (no opaque cells in the chunk → no collision).
static func _attach_collision_shape(result: Dictionary) -> void:
	if not result.has("collision_faces"):
		return
	var faces: PackedVector3Array = result["collision_faces"]
	if faces.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	result["collision_shape"] = shape


static func mesh_chunk(chunk: Chunk) -> Dictionary:
	var probe_token := PerfProbe.begin("mesher.mesh_chunk")
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Per-vertex face light. Each face stores 4 identical Color entries
	# packing sky_light/15 in R and block_light/15 in G (sampled from the
	# cell adjacent to the face — the "open" side it looks at for cube
	# faces, or self for cross-quad plants). chunk.gdshader reads COLOR.r
	# scaled by sky_factor uniform + COLOR.g for block-light. Flat
	# per-face matches Alpha 1.2.6 — smooth lighting was added Beta 1.6.
	var colors := PackedColorArray()
	# Collision face soup (3 verts per triangle, flat). Cube faces contribute;
	# cross-quad plants and water do NOT, so saplings stay passable (vanilla
	# BlockPlant.a(World,...) returns null = no entity collision) and water
	# is wadable. Built alongside the render mesh so chunk_node can build the
	# ConcavePolygonShape3D directly without ArrayMesh.create_trimesh_shape().
	var collision_faces := PackedVector3Array()
	# Selection-only triangle soup for non-cube blocks (sapling, future
	# torches/levers/buttons). Vanilla MC treats the entity-collision bbox
	# and the cursor-selection bbox as two separate things — saplings have
	# null entity collision (passable) but a 0.8-cube selection bbox so the
	# cursor can target them. We bake the cross-quad triangles into this
	# soup, attach it to a second StaticBody3D on a non-physics collision
	# layer in chunk_node, and the raycast queries both layers.
	var plant_faces := PackedVector3Array()
	# Water lives in its own vertex stream so chunk_node.gd can attach a
	# separate translucent ShaderMaterial. Mirrors vanilla MC's separate
	# fluid render pass (RenderBlocks.renderBlockFluids in later versions;
	# in Alpha the fluid draws are issued after opaque terrain in the
	# chunk's VBO). Keeps transparency sorting correct without a per-face
	# alpha sort.
	var water_verts := PackedVector3Array()
	var water_norms := PackedVector3Array()
	var water_uvs := PackedVector2Array()
	var water_indices := PackedInt32Array()
	# Lava gets its own arrays → separate opaque mesh with the emissive
	# lava shader. Same tapered-surface algorithm as water (vanilla
	# shared RenderBlocks.renderBlockFluids between both), different
	# material class.
	var lava_verts := PackedVector3Array()
	var lava_norms := PackedVector3Array()
	var lava_uvs := PackedVector2Array()
	var lava_indices := PackedInt32Array()

	# Skip empty layers above the highest filled block — saves ~60% of
	# iterations on a typical worldgen chunk peaking at y~44 of 128.
	var top: int = mini(chunk.max_y + 1, Chunk.SIZE_Y - 1)
	for y in range(top + 1):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				var id := chunk.get_block(x, y, z)
				if id == Blocks.AIR:
					continue
				if Blocks.is_water(id):
					_emit_fluid_faces(
						chunk, x, y, z, id, water_verts, water_norms, water_uvs, water_indices
					)
					continue
				if Blocks.is_lava(id):
					_emit_fluid_faces(
						chunk, x, y, z, id, lava_verts, lava_norms, lava_uvs, lava_indices
					)
					continue
				# Shape dispatch — cube hot path stays inline; non-cube
				# shapes branch out. TORCH uses a meta-aware cross-quad
				# variant that offsets the geometry toward the support wall
				# per vanilla ob.java meta (1 = -X support … 5 = floor).
				var ms: int = Blocks.mesh_shape(id)
				if ms == Blocks.MESH_SHAPE_CROSS:
					_emit_cross_quads(
						chunk, x, y, z, id, verts, norms, uvs, colors, indices, plant_faces
					)
				elif ms == Blocks.MESH_SHAPE_TORCH:
					_emit_torch_quads(
						chunk, x, y, z, id, verts, norms, uvs, colors, indices, plant_faces
					)
				else:
					_emit_block_faces(
						chunk, x, y, z, id, verts, norms, uvs, colors, indices, collision_faces
					)

	PerfProbe.end("mesher.mesh_chunk", probe_token)
	return {
		"vertices": verts,
		"normals": norms,
		"uvs": uvs,
		"colors": colors,
		"indices": indices,
		"collision_faces": collision_faces,
		"plant_faces": plant_faces,
		"water_vertices": water_verts,
		"water_normals": water_norms,
		"water_uvs": water_uvs,
		"water_indices": water_indices,
		"lava_vertices": lava_verts,
		"lava_normals": lava_norms,
		"lava_uvs": lava_uvs,
		"lava_indices": lava_indices,
	}


static func _emit_block_faces(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	id: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	collision_faces: PackedVector3Array
) -> void:
	var origin := Vector3(x, y, z)
	for face_idx in range(6):
		# CPU-side neighbor culling: skip the face between two adjacent
		# blocks whenever the neighbor fully hides it. Two exceptions:
		#   * LEAVES render with alpha-test (discard in chunk.gdshader),
		#     so a face behind a leaf must still be emitted — otherwise
		#     the shader discard punches a hole straight through to the
		#     world background. LEAVES are therefore not treated as
		#     opaque for culling purposes.
		#   * But two adjacent LEAVES blocks still cull each other (same-
		#     id cull), so canopy interiors don't explode in face count.
		# The render-side cull_back then trims the back-facing half of
		# every remaining face.
		var no: Vector3i = _FACE_NEIGHBOR[face_idx]
		var neighbor_id := chunk.get_block(x + no.x, y + no.y, z + no.z)
		var neighbor_hides_face: bool = (
			(Blocks.is_opaque(neighbor_id) and neighbor_id != Blocks.LEAVES) or neighbor_id == id
		)
		if neighbor_hides_face:
			continue
		var face_verts: Array = _FACE_VERTS[face_idx]
		var normal: Vector3 = _FACE_NORMALS[face_idx]
		var rect: Rect2 = BlockAtlas.uv_rect_for(id, _FACE_KIND[face_idx])
		var base := verts.size()
		var v0 := origin + (face_verts[0] as Vector3)
		var v1 := origin + (face_verts[1] as Vector3)
		var v2 := origin + (face_verts[2] as Vector3)
		var v3 := origin + (face_verts[3] as Vector3)
		verts.append(v0)
		verts.append(v1)
		verts.append(v2)
		verts.append(v3)
		norms.append(normal)
		norms.append(normal)
		norms.append(normal)
		norms.append(normal)
		# V is flipped so the top of each cube face samples the top of the
		# texture — keeps grass_side's green strip on top, dirt on bottom.
		uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
		uvs.append(Vector2(rect.position.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
		# Per-vertex face light: sky/15 in R, block/15 in G. Sample from the
		# neighbor cell — the "open" side this face looks at, which holds
		# the light reaching it. Vanilla / native parity: same rule mirrored
		# in src/mesher_native.cpp::mesh_chunk_data_lit. We multiply by the
		# precomputed reciprocal (instead of dividing by 15.0) to match the
		# C++ path's float arithmetic exactly — divide-then-cast and
		# multiply-by-reciprocal can disagree at 1 ULP in float32.
		var sky_n: float = float(chunk.get_sky_light(x + no.x, y + no.y, z + no.z)) * _LIGHT_SCALE
		var blk_n: float = float(chunk.get_block_light(x + no.x, y + no.y, z + no.z)) * _LIGHT_SCALE
		var face_light := Color(sky_n, blk_n, 0.0, 1.0)
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		# Reversed winding so cull_back keeps the outward-facing side in Godot 4.
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)
		# Same two triangles as flat soup for trimesh collision — mirrors
		# the index winding above so collision matches the visible face.
		collision_faces.append(v0)
		collision_faces.append(v2)
		collision_faces.append(v1)
		collision_faces.append(v0)
		collision_faces.append(v3)
		collision_faces.append(v2)


# Emit water faces into the dedicated water vertex stream. Face rules:
#   • Only emit against AIR neighbors. Opaque solids already draw their own
#     face toward water (since Blocks.is_opaque(water) == false), so two
#     coplanar faces would z-fight.
#   • Same-id water neighbors cull each other — interior water is solid-
#     feeling but never drawn.
#   • Top face of a surface cell (neighbor above = AIR) sits at y + 0.875
#     instead of y + 1 — vanilla BlockFluids.b(level) returns (level+1)/9
#     for a source block = 1.0, BUT the top quad is rendered at 14/16
#     height via RenderBlocks.renderBlockFluids to create the iconic "not
#     quite full" water surface. Side faces on the surface layer use the
#     same 14/16 top vertex so the geometry stays watertight.
# UVs match the block's world-space XZ (for top/bottom) or YZ/XY (for
# sides) so the animated shader sees a continuous ripple pattern across
# chunk boundaries without seams.
static func _emit_fluid_faces(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	id: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array
) -> void:
	# Per-corner top heights (Flow #4). Each of the 4 top-face corners is
	# shared with 3 lateral neighbors; the corner height is a weighted
	# average of the 4 cells touching it. Source (meta=0) and falling
	# (meta>=8) cells contribute with weight 10, flowing cells weight 1 —
	# so a corner adjacent to a source stays near 8/9 while a corner at
	# the spread tip tapers to ~1/9. Same-fluid-above at any of the 4
	# samples forces the corner to 1.0 (stacked column stays flush).
	# Vanilla reference: Beta-era RenderBlocks.renderBlockFluids +
	# Alpha ld.java:b() for the level→height formula.
	var is_lava_fluid: bool = Blocks.is_lava(id)
	var corner_h: Array[float] = [
		_fluid_corner_height(chunk, x, y, z, is_lava_fluid),  # NW
		_fluid_corner_height(chunk, x + 1, y, z, is_lava_fluid),  # NE
		_fluid_corner_height(chunk, x, y, z + 1, is_lava_fluid),  # SW
		_fluid_corner_height(chunk, x + 1, y, z + 1, is_lava_fluid),  # SE
	]
	for face_idx in range(6):
		var no: Vector3i = _FACE_NEIGHBOR[face_idx]
		var neighbor_id := chunk.get_block(x + no.x, y + no.y, z + no.z)
		# Vanilla BlockFluids.d(): skip face if neighbor material equals
		# this fluid's material (flowing ↔ still both merge), or if the
		# neighbor is a fully opaque block. Cross-fluid boundaries (water
		# touching lava) emit — the two fluids each draw their own face
		# against the other, matching vanilla's separate-material rule.
		var same_fluid: bool = (
			(Blocks.is_water(id) and Blocks.is_water(neighbor_id))
			or (Blocks.is_lava(id) and Blocks.is_lava(neighbor_id))
		)
		if same_fluid or Blocks.is_opaque(neighbor_id):
			continue
		var face_verts: Array = _FACE_VERTS[face_idx]
		var normal: Vector3 = _FACE_NORMALS[face_idx]
		var base := verts.size()
		for v: Vector3 in face_verts:
			# Top-corner vertex (y == 1): look up the per-corner height
			# from the precomputed array. Bottom vertex (y == 0): floor.
			# Corner index: (vx) | (vz << 1) maps 0..3 to NW/NE/SW/SE.
			var local_y: float = 0.0
			if v.y > 0.5:
				var corner_idx: int = int(v.x) + int(v.z) * 2
				local_y = corner_h[corner_idx]
			verts.append(Vector3(float(x) + v.x, float(y) + local_y, float(z) + v.z))
			norms.append(normal)
		# UVs derived from world-space coords (wrapped by the shader's
		# fract() on each hash lookup). The XZ plane drives the top/bottom
		# faces; side faces use whichever two axes the face lies on.
		var u0: float
		var v0: float
		var u1: float
		var v1: float
		if face_idx == 0 or face_idx == 1:  # +Y / -Y
			u0 = float(x)
			v0 = float(z)
			u1 = float(x + 1)
			v1 = float(z + 1)
		elif face_idx == 2 or face_idx == 3:  # +X / -X
			u0 = float(z)
			v0 = float(y)
			u1 = float(z + 1)
			v1 = float(y + 1)
		else:  # +Z / -Z
			u0 = float(x)
			v0 = float(y)
			u1 = float(x + 1)
			v1 = float(y + 1)
		uvs.append(Vector2(u0, v1))
		uvs.append(Vector2(u0, v0))
		uvs.append(Vector2(u1, v0))
		uvs.append(Vector2(u1, v1))
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)


# Per-corner top height for variable-height fluid rendering. A world
# corner at (cx, y, cz) is shared by the 4 cells at
# {(cx-1, cz-1), (cx, cz-1), (cx-1, cz), (cx, cz)}. Corner height is
# the weighted average of each contributing cell's surface-top minus
# a short-circuit for stacked-fluid-above (any sample with same fluid
# at y+1 returns 1.0 — keeps columns flush).
#
# Weights from vanilla: source (meta=0) and falling (meta>=8) both
# contribute with weight 10, flowing (meta 1-7) with weight 1. Drives
# the iconic "source stays full, flow tapers" silhouette.
#
# ld.java:16 `b(level)`: returns `(clamp(level, 0, 7) + 1) / 9` — the
# "depth from the top" of that cell's surface. top_height = 1 - b(level).
static func _fluid_corner_height(chunk: Chunk, cx: int, y: int, cz: int, lava: bool) -> float:
	var total_weight: int = 0
	var total_top: float = 0.0
	# 4 cells sharing this world corner. Offsets are (dx, dz) relative
	# to the corner; cell at (cx-1, cz-1) is the diagonal neighbor etc.
	# `lava` picks which fluid family we're building a surface for — water
	# cells don't lift a lava corner and vice versa.
	for dx in [-1, 0]:
		for dz in [-1, 0]:
			var sx: int = cx + dx
			var sz: int = cz + dz
			var above_id: int = chunk.get_block(sx, y + 1, sz)
			var above_same: bool = Blocks.is_lava(above_id) if lava else Blocks.is_water(above_id)
			if above_same:
				return 1.0
			var cell_id: int = chunk.get_block(sx, y, sz)
			var cell_same: bool = Blocks.is_lava(cell_id) if lava else Blocks.is_water(cell_id)
			if cell_same:
				var level: int = chunk.get_block_meta(sx, y, sz)
				var clamped: int = 0 if level >= 8 else level
				var depth: float = float(clamped + 1) / 9.0  # b(level)
				var top: float = 1.0 - depth
				# Sources + falling weight 10 so they dominate the average
				# adjacent to them — lets a waterfall edge stay at full
				# height instead of being dragged down by flowing neighbors.
				var weight: int = 10 if (level == 0 or level >= 8) else 1
				total_top += top * float(weight)
				total_weight += weight
			# Air / solid cells contribute nothing — the fluid surface
			# "bends down" toward them, producing the tapered edge.
	if total_weight == 0:
		# No fluid at this corner (caller should only ask for corners of
		# fluid cells, but be defensive). Flat floor — caller will clip.
		return 0.0
	return total_top / float(total_weight)


# Two perpendicular billboards (sapling, future tall-grass / flowers).
# Both quads are emitted with front-and-back winding so cull_back keeps
# both sides — vanilla MC plant sprites are visible from any angle. Normal
# is forced to +Y so the chunk shader's per-face lookup picks the brightest
# tier and the cross doesn't flip shading as the camera circles past the
# plane. No neighbor culling: plants float in air and never share faces.
# Selection-only collision faces are emitted into `plant_faces` so the
# player's targeting raycast can hit the cross even though the plant
# contributes nothing to the physics-collision body.
static func _emit_cross_quads(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	id: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array
) -> void:
	var origin := Vector3(x, y, z)
	var rect: Rect2 = BlockAtlas.uv_rect_for(id, BlockAtlas.FACE_SIDE)
	var top_normal := Vector3(0, 1, 0)
	# Cross-quad samples its OWN cell light (no "neighbor adjacent to face"
	# concept — the quad floats inside the cell). Bright air around the
	# plant carries sky-light into this cell already. _LIGHT_SCALE used
	# instead of /15.0 for ULP-exact float parity with C++ MesherNative.
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 1.0)
	for quad: Array in _CROSS_QUADS:
		var base := verts.size()
		var v0 := origin + (quad[0] as Vector3)
		var v1 := origin + (quad[1] as Vector3)
		var v2 := origin + (quad[2] as Vector3)
		var v3 := origin + (quad[3] as Vector3)
		verts.append(v0)
		verts.append(v1)
		verts.append(v2)
		verts.append(v3)
		norms.append(top_normal)
		norms.append(top_normal)
		norms.append(top_normal)
		norms.append(top_normal)
		uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
		uvs.append(Vector2(rect.position.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		# Front winding (matches cube path) — cull_back keeps this side.
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)
		# Back winding — same triangles flipped so cull_back keeps the
		# reverse side too. Cheaper than disabling cull_back per-material
		# (which would force a separate ShaderMaterial — see invariants).
		indices.append_array(
			[base, base + 1, base + 2, base, base + 2, base + 3] as PackedInt32Array
		)
		# Selection collision soup — one winding only (physics raycasts
		# don't back-face cull, so duplicating both sides would just bloat
		# the shape with no benefit).
		plant_faces.append(v0)
		plant_faces.append(v2)
		plant_faces.append(v1)
		plant_faces.append(v0)
		plant_faces.append(v3)
		plant_faces.append(v2)


# Vanilla bk.java:673-715 (RenderBlocks.renderTorchAtAngle), dispatched
# by bk.b for shape == 2 (BlockTorch). Emits 4 axis-aligned side quads +
# 1 horizontal flame quad on top, each 1.0 wide/tall but with the
# alpha-tested torch sprite painted onto a 2/16 × 10/16 silhouette.
# Wall torches tilt: their side-quad bottoms shift by (ax, az) per
# vanilla's `bk.b` dispatch (lines 84-97):
#   meta 1 (-X support): base at x = cell.x - 0.1, y + 0.2; tilt -0.4 X
#   meta 2 (+X support): base at x = cell.x + 0.1, y + 0.2; tilt +0.4 X
#   meta 3 (-Z support): base at z = cell.z - 0.1, y + 0.2; tilt -0.4 Z
#   meta 4 (+Z support): base at z = cell.z + 0.1, y + 0.2; tilt +0.4 Z
#   meta 5 / 0 (floor):  no offset, no tilt — straight pillar in cell.
# Side quads use cull_back (chunk shader default) — only the 2 quads
# facing the camera render, so a torch reads as a 2-sided pillar with
# proper depth from any angle. No back-face emission needed.
static func _emit_torch_quads(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	id: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array
) -> void:
	var rect: Rect2 = BlockAtlas.uv_rect_for(id, BlockAtlas.FACE_SIDE)
	var top_normal := Vector3(0, 1, 0)
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 1.0)
	# ---- bk.b dispatch: meta → (base position, tilt). Vanilla's 0.4 / 0.1
	# / 0.2 constants correspond to: tilt magnitude / wall inset / y bump.
	var meta: int = chunk.get_block_meta(x, y, z)
	var bx: float = float(x)
	var by: float = float(y)
	var bz: float = float(z)
	var ax: float = 0.0  # tilt in X (bottom shifts by ax)
	var az: float = 0.0  # tilt in Z
	match meta:
		1:
			bx -= 0.1
			by += 0.2
			ax = -0.4
		2:
			bx += 0.1
			by += 0.2
			ax = 0.4
		3:
			bz -= 0.1
			by += 0.2
			az = -0.4
		4:
			bz += 0.1
			by += 0.2
			az = 0.4
		# 5 / 0 / anything else — floor torch, no offset and no tilt.
	# ---- bk.a internals (vanilla lines 685-694):
	# d15 = 1/16 = half torch-pillar width. d16 = 10/16 = torch height
	# (used by the flame quad's vertical position).
	var d15: float = 0.0625
	var d16: float = 0.625
	var d11: float = bx  # cell-origin x (vanilla d11 = (d2 += 0.5) - 0.5)
	var d12: float = bx + 1.0
	var d13: float = bz
	var d14: float = bz + 1.0
	var cx: float = bx + 0.5  # cell-center x (vanilla's reassigned d2)
	var cz: float = bz + 0.5  # cell-center z (vanilla's reassigned d4)
	# Texture rect — full tile UV. Vanilla uses (f2..f3, f4..f5) which is
	# the full 16×16 cell with a 0.01-pixel inset; our atlas rect already
	# carries an equivalent half-texel inset for atlas-bleed safety.
	var u0: float = rect.position.x
	var u1: float = rect.position.x + rect.size.x
	var v0: float = rect.position.y
	var v1: float = rect.position.y + rect.size.y
	# ---- 4 side quads (vanilla bk.a:699-714). Each is a 1.0×1.0 quad
	# with alpha-tested torch sprite; bottom shifted by (ax, az) for tilt.
	# Side -X (vanilla quad 1, 699-702): visible from -X direction.
	_emit_torch_side_quad(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		Vector3(cx - d15, by + 1.0, d13),
		Vector3(cx - d15 + ax, by + 0.0, d13 + az),
		Vector3(cx - d15 + ax, by + 0.0, d14 + az),
		Vector3(cx - d15, by + 1.0, d14),
		Vector3(-1, 0, 0),
		u0,
		v0,
		u1,
		v1,
		face_light
	)
	# Side +X (vanilla quad 2, 703-706).
	_emit_torch_side_quad(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		Vector3(cx + d15, by + 1.0, d14),
		Vector3(cx + d15 + ax, by + 0.0, d14 + az),
		Vector3(cx + d15 + ax, by + 0.0, d13 + az),
		Vector3(cx + d15, by + 1.0, d13),
		Vector3(1, 0, 0),
		u0,
		v0,
		u1,
		v1,
		face_light
	)
	# Side +Z (vanilla quad 3, 707-710).
	_emit_torch_side_quad(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		Vector3(d11, by + 1.0, cz + d15),
		Vector3(d11 + ax, by + 0.0, cz + d15 + az),
		Vector3(d12 + ax, by + 0.0, cz + d15 + az),
		Vector3(d12, by + 1.0, cz + d15),
		Vector3(0, 0, 1),
		u0,
		v0,
		u1,
		v1,
		face_light
	)
	# Side -Z (vanilla quad 4, 711-714).
	_emit_torch_side_quad(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		Vector3(d12, by + 1.0, cz - d15),
		Vector3(d12 + ax, by + 0.0, cz - d15 + az),
		Vector3(d11 + ax, by + 0.0, cz - d15 + az),
		Vector3(d11, by + 1.0, cz - d15),
		Vector3(0, 0, -1),
		u0,
		v0,
		u1,
		v1,
		face_light
	)
	# ---- Flame quad (vanilla bk.a:695-698): horizontal 2/16 × 2/16 quad
	# at torch tip y = by + d16. Position offset toward tilt direction by
	# ax * (1 - d16) = ax * 0.375. Uses a tighter sub-rect of the texture
	# (the central 2×2 texels for the flame). For simplicity we use the
	# same full UV rect; the flame is barely visible from above anyway.
	var ftx: float = cx + ax * (1.0 - d16)
	var ftz: float = cz + az * (1.0 - d16)
	var fy: float = by + d16
	var ffu0: float = u0 + (u1 - u0) * (7.0 / 16.0)
	var ffu1: float = u0 + (u1 - u0) * (9.0 / 16.0)
	var ffv0: float = v0 + (v1 - v0) * (6.0 / 16.0)
	var ffv1: float = v0 + (v1 - v0) * (8.0 / 16.0)
	var fbase := verts.size()
	verts.append(Vector3(ftx - d15, fy, ftz - d15))
	verts.append(Vector3(ftx - d15, fy, ftz + d15))
	verts.append(Vector3(ftx + d15, fy, ftz + d15))
	verts.append(Vector3(ftx + d15, fy, ftz - d15))
	for _i in range(4):
		norms.append(top_normal)
		colors.append(face_light)
	uvs.append(Vector2(ffu0, ffv0))
	uvs.append(Vector2(ffu0, ffv1))
	uvs.append(Vector2(ffu1, ffv1))
	uvs.append(Vector2(ffu1, ffv0))
	indices.append_array(
		[fbase, fbase + 1, fbase + 2, fbase, fbase + 2, fbase + 3] as PackedInt32Array
	)
	# Selection collision (one winding) — center the cursor box on the flame
	# quad so the player can target the torch tip.
	plant_faces.append(verts[fbase])
	plant_faces.append(verts[fbase + 2])
	plant_faces.append(verts[fbase + 1])
	plant_faces.append(verts[fbase])
	plant_faces.append(verts[fbase + 3])
	plant_faces.append(verts[fbase + 2])


# Helper for one of the 4 axis-aligned torch side quads. Emits front
# winding only — chunk shader's cull_back keeps the side facing the
# camera; the opposing side is the back-to-back partner in this same
# emit set, so any camera angle sees exactly 2 of the 4 quads.
# gdlint: disable=function-arguments-number
static func _emit_torch_side_quad(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	normal: Vector3,
	u0: float,
	v_top: float,
	u1: float,
	v_bot: float,
	face_light: Color
) -> void:
	var base: int = verts.size()
	verts.append(v0)
	verts.append(v1)
	verts.append(v2)
	verts.append(v3)
	norms.append(normal)
	norms.append(normal)
	norms.append(normal)
	norms.append(normal)
	# Vanilla's UV pattern: top corners use V_top (image y small = top of
	# texture = flame end), bottom corners use V_bot (image y large = stick
	# bottom). U sweeps left → right for the +U side, right → left for
	# the opposite. Following bk.a:699-702: (u0,v0)→(u0,v1)→(u1,v1)→(u1,v0).
	uvs.append(Vector2(u0, v_top))
	uvs.append(Vector2(u0, v_bot))
	uvs.append(Vector2(u1, v_bot))
	uvs.append(Vector2(u1, v_top))
	colors.append(face_light)
	colors.append(face_light)
	colors.append(face_light)
	colors.append(face_light)
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3] as PackedInt32Array)
	plant_faces.append(v0)
	plant_faces.append(v2)
	plant_faces.append(v1)
	plant_faces.append(v0)
	plant_faces.append(v3)
	plant_faces.append(v2)
