# gdlint: disable=max-file-lines
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
	if _native_mesher == null:
		var result: Dictionary = mesh_chunk(chunk)
		return result
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
	if chunk.has_non_cube_blocks:
		_append_non_cube_geometry(chunk, result)
	PerfProbe.end("mesher.mesh_chunk", probe_token)
	return result


# GDScript pass for non-cube blocks only (CROSS, TORCH, EXTERNAL).
# Appends their geometry into the native mesher's result dict so the
# native path handles 99% of the chunk while GDScript covers the few
# special-shape blocks.
static func _append_non_cube_geometry(chunk: Chunk, result: Dictionary) -> void:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var collision_faces := PackedVector3Array()
	var plant_faces := PackedVector3Array()
	var top: int = mini(chunk.max_y + 1, Chunk.SIZE_Y - 1)
	for y in range(top + 1):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				var id := chunk.get_block(x, y, z)
				if id == Blocks.AIR:
					continue
				var ms: int = Blocks.mesh_shape(id)
				if ms == Blocks.MESH_SHAPE_CROSS:
					_emit_cross_quads(
						chunk, x, y, z, id, verts, norms, uvs, colors, indices, plant_faces
					)
				elif ms == Blocks.MESH_SHAPE_FIRE:
					_emit_fire_quads(
						chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces
					)
				elif ms == Blocks.MESH_SHAPE_TORCH:
					_emit_torch_quads(
						chunk, x, y, z, id, verts, norms, uvs, colors, indices, plant_faces
					)
				elif ms == Blocks.MESH_SHAPE_EXTERNAL:
					_emit_external_collision(x, y, z, collision_faces)
				elif ms == Blocks.MESH_SHAPE_FENCE:
					_emit_fence_geometry(
						chunk, x, y, z, verts, norms, uvs, colors, indices, collision_faces
					)
				elif ms == Blocks.MESH_SHAPE_STAIRS:
					_emit_stair_geometry(
						chunk, x, y, z, id, verts, norms, uvs, colors, indices, collision_faces
					)
				elif ms == Blocks.MESH_SHAPE_DOOR:
					_emit_door_geometry(
						chunk, x, y, z, id, verts, norms, uvs, colors, indices, collision_faces
					)
				elif ms == Blocks.MESH_SHAPE_LADDER:
					_emit_ladder_geometry(
						chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces
					)
				elif ms == Blocks.MESH_SHAPE_SNOW_LAYER:
					_emit_snow_layer_geometry(
						chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces
					)
	if verts.is_empty() and collision_faces.is_empty() and plant_faces.is_empty():
		return
	# Packed*Array types use CoW — `result["key"].append_array()` would
	# mutate a temporary copy, leaving the dict unchanged. Extract, append,
	# reassign instead.
	var rv: PackedVector3Array = result["vertices"]
	var base_vert: int = rv.size()
	if base_vert > 0 and not verts.is_empty():
		var shifted := PackedInt32Array()
		shifted.resize(indices.size())
		for i in range(indices.size()):
			shifted[i] = indices[i] + base_vert
		indices = shifted
	rv.append_array(verts)
	result["vertices"] = rv
	var rn: PackedVector3Array = result["normals"]
	rn.append_array(norms)
	result["normals"] = rn
	var ru: PackedVector2Array = result["uvs"]
	ru.append_array(uvs)
	result["uvs"] = ru
	var rc: PackedColorArray = result["colors"]
	rc.append_array(colors)
	result["colors"] = rc
	var ri: PackedInt32Array = result["indices"]
	ri.append_array(indices)
	result["indices"] = ri
	if not collision_faces.is_empty():
		var cf: PackedVector3Array = result.get("collision_faces", PackedVector3Array())
		cf.append_array(collision_faces)
		result["collision_faces"] = cf
	if not plant_faces.is_empty():
		var pf: PackedVector3Array = result.get("plant_faces", PackedVector3Array())
		pf.append_array(plant_faces)
		result["plant_faces"] = pf


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
	var water_colors := PackedColorArray()
	var water_indices := PackedInt32Array()
	# Lava gets its own arrays → separate opaque mesh with the emissive
	# lava shader. Same tapered-surface algorithm as water (vanilla
	# shared RenderBlocks.renderBlockFluids between both), different
	# material class.
	var lava_verts := PackedVector3Array()
	var lava_norms := PackedVector3Array()
	var lava_uvs := PackedVector2Array()
	var lava_colors := PackedColorArray()
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
						chunk,
						x,
						y,
						z,
						id,
						water_verts,
						water_norms,
						water_uvs,
						water_colors,
						water_indices
					)
					continue
				if Blocks.is_lava(id):
					_emit_fluid_faces(
						chunk,
						x,
						y,
						z,
						id,
						lava_verts,
						lava_norms,
						lava_uvs,
						lava_colors,
						lava_indices
					)
					continue
				# Cube hot path stays inline. Non-cube shapes (CROSS / TORCH
				# / EXTERNAL / FENCE / STAIRS / DOOR / LADDER) are deferred
				# to `_append_non_cube_geometry` below so the GDScript
				# reference produces the same vertex order as the production
				# path (`mesh_chunk_fast` = native cubes + appendix). Without
				# this split the parity test fails on chunks that contain a
				# mix of cubes and non-cubes (e.g. flowers in worldgen).
				if Blocks.needs_gdscript_mesher(id):
					continue
				_emit_block_faces(
					chunk, x, y, z, id, verts, norms, uvs, colors, indices, collision_faces
				)

	var result: Dictionary = {
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
		"water_colors": water_colors,
		"water_indices": water_indices,
		"lava_vertices": lava_verts,
		"lava_normals": lava_norms,
		"lava_uvs": lava_uvs,
		"lava_colors": lava_colors,
		"lava_indices": lava_indices,
	}
	# Append non-cube geometry (cross-quads, torches, doors, fence, stairs,
	# ladders) after all cubes — same order as `mesh_chunk_fast` does in
	# production via `_append_non_cube_geometry`.
	if chunk.has_non_cube_blocks:
		_append_non_cube_geometry(chunk, result)
	PerfProbe.end("mesher.mesh_chunk", probe_token)
	return result


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
		var rect: Rect2
		if Blocks.has_directional_face(id):
			# Directional blocks (pumpkin, jack o'lantern) need per-face-
			# index + meta lookup so the carved face only appears on the
			# side the player placed it facing. Slower string-keyed
			# atlas lookup, but rare enough that the cost is negligible.
			var meta_d: int = chunk.get_block_meta_unchecked(x, y, z)
			var tex_d: String = Blocks.directional_face_texture(id, face_idx, meta_d)
			rect = BlockAtlas.uv_rect(tex_d)
		else:
			rect = BlockAtlas.uv_rect_for(id, _FACE_KIND[face_idx])
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
		# Side faces (idx 2-5) also need U swapped: v0/v1 are on the -axis
		# end of the face's secondary direction, which corresponds to the
		# RIGHT side of the screen when viewing that face from outside.
		# Without the swap, asymmetric text (TNT side "N") renders mirrored.
		# Top/bottom keep the original order (their U axis isn't mirrored).
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


# Full-cube collision soup for an externally-rendered cell (CHEST etc.).
# Six faces × two triangles → 36 vertices added to `collision_faces`.
# Caller skips the visual emit, leaving the visible geometry to the
# entity. Triangle winding mirrors the cube path's
# `[base, base+2, base+1, base, base+3, base+2]` so the trimesh shape
# has matching outward-facing normals.
static func _emit_external_collision(
	x: int, y: int, z: int, collision_faces: PackedVector3Array
) -> void:
	var origin := Vector3(x, y, z)
	for face_idx in range(6):
		var face_verts: Array = _FACE_VERTS[face_idx]
		var v0: Vector3 = origin + (face_verts[0] as Vector3)
		var v1: Vector3 = origin + (face_verts[1] as Vector3)
		var v2: Vector3 = origin + (face_verts[2] as Vector3)
		var v3: Vector3 = origin + (face_verts[3] as Vector3)
		collision_faces.append(v0)
		collision_faces.append(v2)
		collision_faces.append(v1)
		collision_faces.append(v0)
		collision_faces.append(v3)
		collision_faces.append(v2)


# Vanilla BlockFence geometry (gd.java + bk.java:1190-1239). Always emits a
# 6/16-wide post; for each of the 4 horizontal neighbors that ALSO holds a
# fence (Alpha-faithful — vanilla checks `cy.a(...) == nq.bh`, same-id only,
# bk.java:1199-1208), emits two rail boxes (top y=12-15/16, bottom y=6-9/16)
# extending from the post out to the cell edge in that direction.
#
# Hitbox is 1.5 cells tall to match gd.java:13's
# `(x, y, z) → (x+1, y+1.5, z+1)` collision bbox — the player can't trivially
# hop a single fence. Collision soup spans the full hitbox; visible mesh
# stays at the 16/16 post height (vanilla's 1.5 hitbox is purely physical).
# gdlint: disable=function-arguments-number
static func _emit_fence_geometry(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	collision_faces: PackedVector3Array
) -> void:
	# Connection probes — same convention as bk.java:1205-1208 but with our
	# Vector3i offsets. Alpha gates on same-id neighbors only; we mirror that
	# strictly. Solid-block connection is a Beta+ change we deliberately omit.
	var conn_west: bool = chunk.get_block(x - 1, y, z) == Blocks.FENCE
	var conn_east: bool = chunk.get_block(x + 1, y, z) == Blocks.FENCE
	var conn_north: bool = chunk.get_block(x, y, z - 1) == Blocks.FENCE
	var conn_south: bool = chunk.get_block(x, y, z + 1) == Blocks.FENCE
	# Sample sky/block light at the fence's own cell — fence faces don't
	# have an obvious "open neighbor" the way cube faces do, and the cell
	# above is generally air. Self-light is what RenderBlocks.k() does
	# (bk.java:1010 reads `nq2.b(this.a, n2, n3, n4)` — own cell brightness).
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 1.0)
	# Post — 6/16 × 16/16 × 6/16, always rendered. Texture wraps onto every
	# face from the planks tile (Blocks.get_face_texture(FENCE, ...) → "planks").
	var rect: Rect2 = BlockAtlas.uv_rect("planks")
	_emit_box(
		verts,
		norms,
		uvs,
		colors,
		indices,
		Vector3(float(x) + 0.375, float(y), float(z) + 0.375),
		Vector3(float(x) + 0.625, float(y) + 1.0, float(z) + 0.625),
		rect,
		face_light
	)
	# Top rail (y 12/16-15/16) and bottom rail (y 6/16-9/16). Each rail
	# emits a separate box on the X axis if the cell connects E or W, and
	# on the Z axis if it connects N or S. Vanilla bk.java:1216-1219:
	#   f7 = bl6 ? 0.0 : f3   (-X end snaps to 0 if -X neighbor is fence)
	#   f8 = bl7 ? 1.0 : f4   (+X end snaps to 1 if +X neighbor is fence)
	# The "isolated post-only" case falls out: when no neighbor is a fence,
	# both ends collapse to [0.4375, 0.5625] which sits inside the post —
	# the box is degenerate and visually invisible, so we skip emission.
	for rail_y in [Vector2(0.75, 0.9375), Vector2(0.375, 0.5625)]:
		var y0: float = rail_y.x
		var y1: float = rail_y.y
		# X rail
		if conn_west or conn_east:
			var rx0: float = 0.0 if conn_west else 0.4375
			var rx1: float = 1.0 if conn_east else 0.5625
			_emit_box(
				verts,
				norms,
				uvs,
				colors,
				indices,
				Vector3(float(x) + rx0, float(y) + y0, float(z) + 0.4375),
				Vector3(float(x) + rx1, float(y) + y1, float(z) + 0.5625),
				rect,
				face_light
			)
		# Z rail
		if conn_north or conn_south:
			var rz0: float = 0.0 if conn_north else 0.4375
			var rz1: float = 1.0 if conn_south else 0.5625
			_emit_box(
				verts,
				norms,
				uvs,
				colors,
				indices,
				Vector3(float(x) + 0.4375, float(y) + y0, float(z) + rz0),
				Vector3(float(x) + 0.5625, float(y) + y1, float(z) + rz1),
				rect,
				face_light
			)
	# Collision: 1×1.5×1 box matching gd.java:13. Player physics already
	# gates on the trimesh, so emitting these 6 faces gives the fence its
	# vanilla "can't hop" hitbox without any cube-mesh collision faces.
	var c0 := Vector3(float(x), float(y), float(z))
	var c1 := Vector3(float(x) + 1.0, float(y) + 1.5, float(z) + 1.0)
	_emit_collision_box(collision_faces, c0, c1)


# Vanilla stair geometry — two axis-aligned boxes per cell, orientation
# driven by block_meta 0..3. Each orientation has a bottom half-slab and
# a full-height upper step. Box dims from mb.java:43-66. Both boxes use
# the parent block's texture on every face (planks for WOOD_STAIRS,
# cobblestone for COBBLESTONE_STAIRS).
# gdlint: disable=function-arguments-number
static func _emit_stair_geometry(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	block_id: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	collision_faces: PackedVector3Array
) -> void:
	var meta: int = chunk.get_block_meta(x, y, z) & 3
	var fx: float = float(x)
	var fy: float = float(y)
	var fz: float = float(z)
	# Two-box layout per meta — directly from mb.java:43-66.
	var box_a_min: Vector3
	var box_a_max: Vector3
	var box_b_min: Vector3
	var box_b_max: Vector3
	match meta:
		0:
			box_a_min = Vector3(fx, fy, fz)
			box_a_max = Vector3(fx + 0.5, fy + 0.5, fz + 1.0)
			box_b_min = Vector3(fx + 0.5, fy, fz)
			box_b_max = Vector3(fx + 1.0, fy + 1.0, fz + 1.0)
		1:
			box_a_min = Vector3(fx, fy, fz)
			box_a_max = Vector3(fx + 0.5, fy + 1.0, fz + 1.0)
			box_b_min = Vector3(fx + 0.5, fy, fz)
			box_b_max = Vector3(fx + 1.0, fy + 0.5, fz + 1.0)
		2:
			box_a_min = Vector3(fx, fy, fz)
			box_a_max = Vector3(fx + 1.0, fy + 0.5, fz + 0.5)
			box_b_min = Vector3(fx, fy, fz + 0.5)
			box_b_max = Vector3(fx + 1.0, fy + 1.0, fz + 1.0)
		_:
			box_a_min = Vector3(fx, fy, fz)
			box_a_max = Vector3(fx + 1.0, fy + 1.0, fz + 0.5)
			box_b_min = Vector3(fx, fy, fz + 0.5)
			box_b_max = Vector3(fx + 1.0, fy + 0.5, fz + 1.0)
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 1.0)
	var tex_name: String = Blocks.get_face_texture(block_id, "side")
	var rect: Rect2 = BlockAtlas.uv_rect(tex_name)
	_emit_box(verts, norms, uvs, colors, indices, box_a_min, box_a_max, rect, face_light)
	_emit_box(verts, norms, uvs, colors, indices, box_b_min, box_b_max, rect, face_light)
	# Two-box collision matching the visual step shape so the player can
	# walk up stairs without jumping (0.5-block step height).
	_emit_collision_box(collision_faces, box_a_min, box_a_max)
	_emit_collision_box(collision_faces, box_b_min, box_b_max)


# Ladder geometry — flat 2/16-thick slab mounted against a wall face.
# Vanilla ca.java: metadata 2..5 encodes the support direction (2=+Z,
# 3=-Z, 4=+X, 5=-X). Two textured quads (front + back) so the ladder
# is visible from both sides. Collision goes into plant_faces (layer 2)
# so the player walks through ladders but can target them with the cursor.
# gdlint: disable=function-arguments-number
static func _emit_ladder_geometry(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array,
) -> void:
	var meta: int = chunk.get_block_meta(x, y, z)
	var fx: float = float(x)
	var fy: float = float(y)
	var fz: float = float(z)
	var d: float = 0.0625  # 1/16 — half of 2/16 thickness
	# Quad corners for each meta — front face winding (CCW for cull_back).
	# v0..v3 are the 4 corners of the front face; back face reverses order.
	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3
	var normal_front: Vector3
	match meta:
		3:  # -Z face (support at -Z)
			v0 = Vector3(fx, fy, fz + d)
			v1 = Vector3(fx, fy + 1.0, fz + d)
			v2 = Vector3(fx + 1.0, fy + 1.0, fz + d)
			v3 = Vector3(fx + 1.0, fy, fz + d)
			normal_front = Vector3(0, 0, 1)
		4:  # +X face (support at +X)
			v0 = Vector3(fx + 1.0 - d, fy, fz)
			v1 = Vector3(fx + 1.0 - d, fy + 1.0, fz)
			v2 = Vector3(fx + 1.0 - d, fy + 1.0, fz + 1.0)
			v3 = Vector3(fx + 1.0 - d, fy, fz + 1.0)
			normal_front = Vector3(-1, 0, 0)
		5:  # -X face (support at -X)
			v0 = Vector3(fx + d, fy, fz + 1.0)
			v1 = Vector3(fx + d, fy + 1.0, fz + 1.0)
			v2 = Vector3(fx + d, fy + 1.0, fz)
			v3 = Vector3(fx + d, fy, fz)
			normal_front = Vector3(1, 0, 0)
		_:  # 2 / default: +Z face (support at +Z)
			v0 = Vector3(fx + 1.0, fy, fz + 1.0 - d)
			v1 = Vector3(fx + 1.0, fy + 1.0, fz + 1.0 - d)
			v2 = Vector3(fx, fy + 1.0, fz + 1.0 - d)
			v3 = Vector3(fx, fy, fz + 1.0 - d)
			normal_front = Vector3(0, 0, -1)
	var uv_rect: Rect2 = BlockAtlas.uv_rect("ladder")
	var u0: float = uv_rect.position.x
	var v_top: float = uv_rect.position.y
	var u1: float = uv_rect.position.x + uv_rect.size.x
	var v_bot: float = uv_rect.position.y + uv_rect.size.y
	var sky: int = chunk.get_sky_light(x, y, z)
	var blk: int = chunk.get_block_light(x, y, z)
	var face_color := Color(float(sky) / 15.0, float(blk) / 15.0, 0.0, 1.0)
	# Front face
	var base: int = verts.size()
	verts.append(v0)
	verts.append(v1)
	verts.append(v2)
	verts.append(v3)
	for i in range(4):
		norms.append(normal_front)
		colors.append(face_color)
	uvs.append(Vector2(u0, v_bot))
	uvs.append(Vector2(u0, v_top))
	uvs.append(Vector2(u1, v_top))
	uvs.append(Vector2(u1, v_bot))
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 1)
	indices.append(base)
	indices.append(base + 3)
	indices.append(base + 2)
	# Back face (reversed winding)
	var normal_back: Vector3 = -normal_front
	base = verts.size()
	verts.append(v3)
	verts.append(v2)
	verts.append(v1)
	verts.append(v0)
	for i in range(4):
		norms.append(normal_back)
		colors.append(face_color)
	uvs.append(Vector2(u0, v_bot))
	uvs.append(Vector2(u0, v_top))
	uvs.append(Vector2(u1, v_top))
	uvs.append(Vector2(u1, v_bot))
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 1)
	indices.append(base)
	indices.append(base + 3)
	indices.append(base + 2)
	# Selection collision (plant_faces layer 2) — thin AABB matching the slab.
	var aabb: AABB = Blocks.selection_aabb(Blocks.LADDER, meta)
	var cmin := Vector3(fx + aabb.position.x, fy + aabb.position.y, fz + aabb.position.z)
	var cmax := cmin + aabb.size
	_emit_collision_box(plant_faces, cmin, cmax)


# Door geometry — thin 3/16-block slab with 4 orientations × open/closed.
# Metadata layout (gv.java): bits 0-1 = raw direction, bit 2 = open flag,
# bit 3 = upper/lower half. Visual facing is derived via _door_facing
# (same as Blocks._door_facing). Each cell renders ONE half of the door
# (upper or lower); the block above/below holds the other half.
# gdlint: disable=function-arguments-number
static func _emit_door_geometry(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	block_id: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	collision_faces: PackedVector3Array
) -> void:
	var meta: int = chunk.get_block_meta(x, y, z)
	var fx: float = float(x)
	var fy: float = float(y)
	var fz: float = float(z)
	var f: float = 0.1875  # 3/16 door thickness
	var facing: int = Blocks._door_facing(meta)
	var mn: Vector3
	var mx: Vector3
	match facing:
		0:
			mn = Vector3(fx, fy, fz)
			mx = Vector3(fx + 1.0, fy + 1.0, fz + f)
		1:
			mn = Vector3(fx + 1.0 - f, fy, fz)
			mx = Vector3(fx + 1.0, fy + 1.0, fz + 1.0)
		2:
			mn = Vector3(fx, fy, fz + 1.0 - f)
			mx = Vector3(fx + 1.0, fy + 1.0, fz + 1.0)
		_:
			mn = Vector3(fx, fy, fz)
			mx = Vector3(fx + f, fy + 1.0, fz + 1.0)
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 1.0)
	var tex_name: String = Blocks.door_texture(block_id, meta)
	var rect: Rect2 = BlockAtlas.uv_rect(tex_name)
	_emit_box(verts, norms, uvs, colors, indices, mn, mx, rect, face_light)
	_emit_collision_box(collision_faces, mn, mx)


# Axis-aligned box helper. Emits 6 faces with planks texture (UV-tiled
# from the atlas rect) and per-face lighting. Used by fence post + rails.
# Triangle winding mirrors the cube path (`[base, base+2, base+1, base,
# base+3, base+2]`) so cull_back keeps outward sides. UVs are V-flipped
# the same way as the cube path so the planks pattern reads upright.
# gdlint: disable=function-arguments-number
# Snow layer — 2/16-tall slab at the floor (matches vanilla's
# `0..2/16` Y bounds). Renders the 5 visible faces (top + 4 sides);
# the bottom is hidden against the support block. Uses the snow texture
# for all faces. Light comes from the snow_layer cell itself, not the
# block beneath.
static func _emit_snow_layer_geometry(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array,
) -> void:
	var fx: float = float(x)
	var fy: float = float(y)
	var fz: float = float(z)
	var slab_height: float = 0.125  # 2/16
	var mn := Vector3(fx, fy, fz)
	var mx := Vector3(fx + 1.0, fy + slab_height, fz + 1.0)
	var rect: Rect2 = BlockAtlas.uv_rect("snow")
	var sky: int = chunk.get_sky_light(x, y, z)
	var blk: int = chunk.get_block_light(x, y, z)
	var face_color := Color(float(sky) / 15.0, float(blk) / 15.0, 0.0, 1.0)
	_emit_box(verts, norms, uvs, colors, indices, mn, mx, rect, face_color)
	# Selection collision so the player's raycast can target this slab.
	# Without this, the raycast falls through to the support block below
	# and the snow can't be broken or right-click-targeted.
	_emit_collision_box(plant_faces, mn, mx)


static func _emit_box(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	mn: Vector3,
	mx: Vector3,
	rect: Rect2,
	face_light: Color
) -> void:
	# 8 corners. Indexed bit-wise: bit0=x (mn/mx), bit1=y, bit2=z.
	var c000 := Vector3(mn.x, mn.y, mn.z)
	var c100 := Vector3(mx.x, mn.y, mn.z)
	var c010 := Vector3(mn.x, mx.y, mn.z)
	var c110 := Vector3(mx.x, mx.y, mn.z)
	var c001 := Vector3(mn.x, mn.y, mx.z)
	var c101 := Vector3(mx.x, mn.y, mx.z)
	var c011 := Vector3(mn.x, mx.y, mx.z)
	var c111 := Vector3(mx.x, mx.y, mx.z)
	# Face-vert order matches mesher's `_FACE_VERTS` so the winding +
	# UV mapping below stays consistent with cube faces.
	var faces: Array = [
		[c010, c011, c111, c110, Vector3.UP],
		[c001, c000, c100, c101, Vector3.DOWN],
		[c100, c110, c111, c101, Vector3.RIGHT],
		[c001, c011, c010, c000, Vector3.LEFT],
		[c101, c111, c011, c001, Vector3.BACK],
		[c000, c010, c110, c100, Vector3.FORWARD],
	]
	for face in faces:
		var base: int = verts.size()
		var fv: Vector3 = face[4]
		for i in range(4):
			verts.append(face[i])
			norms.append(fv)
		uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
		uvs.append(Vector2(rect.position.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)


# Six-face collision soup for a generic AABB. Used by FENCE for its
# vanilla-faithful 1×1.5×1 hitbox. Triangle winding matches the cube
# path so the trimesh shape's outward normals stay consistent.
static func _emit_collision_box(
	collision_faces: PackedVector3Array, mn: Vector3, mx: Vector3
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
		[c010, c011, c111, c110],
		[c001, c000, c100, c101],
		[c100, c110, c111, c101],
		[c001, c011, c010, c000],
		[c101, c111, c011, c001],
		[c000, c010, c110, c100],
	]
	for face in faces:
		collision_faces.append(face[0])
		collision_faces.append(face[2])
		collision_faces.append(face[1])
		collision_faces.append(face[0])
		collision_faces.append(face[3])
		collision_faces.append(face[2])


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
# gdlint: disable=function-arguments-number
static func _emit_fluid_faces(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	id: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
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
	# Horizontal flow vector — ports vanilla ld.java:e() (BlockFluids
	# .getFlowVector). Drives the water shader's directional UV scroll so
	# the surface visibly streams toward lower-pressure neighbors. Returns
	# (0,0) for static sources or fully-symmetric cells. Encoded into
	# Color.b/.a as (x*0.5+0.5, z*0.5+0.5) so the [-1,1] range survives
	# Color clamping to [0,1].
	var flow: Vector2 = _fluid_flow_vector(chunk, x, y, z, is_lava_fluid)
	var flow_b: float = flow.x * 0.5 + 0.5
	var flow_a: float = flow.y * 0.5 + 0.5
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
		# Per-vertex face light — sample sky/block light at the OPEN cell
		# adjacent to this face (same rule as cube faces). Without this, water
		# reads at constant brightness regardless of caves / night, which made
		# water surfaces look unlit in dark environments.
		var sky_n: float = float(chunk.get_sky_light(x + no.x, y + no.y, z + no.z)) * _LIGHT_SCALE
		var blk_n: float = float(chunk.get_block_light(x + no.x, y + no.y, z + no.z)) * _LIGHT_SCALE
		# R=sky/15, G=block/15 (per-face light), B=flow.x encoded, A=flow.z
		# encoded. Same flow value for all 6 faces of this cell — the cell's
		# "spreading direction" is a property of the cell, not the face.
		var face_light := Color(sky_n, blk_n, flow_b, flow_a)
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
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
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


# Per-cell horizontal flow vector. Mirrors vanilla ld.java:91-155
# (BlockFluids.getFlowVector / `e()`). Used by water.gdshader to scroll
# the surface UV along the direction the fluid is spreading toward.
#
# Algorithm: sum the (neighbor_offset * level_diff) contribution from
# each of the 4 horizontal neighbors. A drop-ledge case (non-fluid,
# non-solid neighbor with fluid one cell below) contributes as if the
# below-neighbor's level were lifted by 8, pulling the surface toward
# the cliff edge. Output is normalized to unit length; (0,0) for static
# sources or fully-symmetric cells.
#
# We deliberately omit the falling-water (level >= 8) downward Y bias
# from vanilla — only horizontal X/Z components are used for UV scroll,
# so the Y term wouldn't affect rendering. Keep this aligned with the
# C++ port (src/mesher_native.cpp::fluid_flow_vector) — parity is
# enforced by tests/test_mesher_native.gd.
static func _fluid_flow_vector(chunk: Chunk, x: int, y: int, z: int, lava: bool) -> Vector2:
	var my_level: int = _fluid_effective_level(chunk, x, y, z, lava)
	if my_level < 0:
		return Vector2.ZERO
	var fx: float = 0.0
	var fz: float = 0.0
	for dir_i in range(4):
		var dx: int = 0
		var dz: int = 0
		match dir_i:
			0:
				dx = -1
			1:
				dz = -1
			2:
				dx = 1
			3:
				dz = 1
		var nx: int = x + dx
		var nz: int = z + dz
		var n_level: int = _fluid_effective_level(chunk, nx, y, nz, lava)
		if n_level < 0:
			# Neighbor is not the same fluid. Solid block → no contribution
			# (water can't flow into stone). Otherwise check below the
			# neighbor — water spreading off a ledge tilts toward the drop
			# even though the side cell is air.
			var n_id: int = chunk.get_block(nx, y, nz)
			if Blocks.is_opaque(n_id):
				continue
			n_level = _fluid_effective_level(chunk, nx, y - 1, nz, lava)
			if n_level < 0:
				continue
			# Below counts as if 8 levels lower: diff = below_lvl - (my-8).
			# Larger diff for shallower ledges → stronger pull.
			var diff_drop: int = n_level - (my_level - 8)
			fx += float(dx) * float(diff_drop)
			fz += float(dz) * float(diff_drop)
			continue
		var diff: int = n_level - my_level
		fx += float(dx) * float(diff)
		fz += float(dz) * float(diff)
	var v := Vector2(fx, fz)
	if v == Vector2.ZERO:
		return v
	return v.normalized()


# Effective fluid level for flow math: -1 if cell isn't this fluid family,
# 0 if falling (meta >= 8, treated as a source for spreading purposes),
# else the raw meta (1-7). Mirrors ld.java:c().
static func _fluid_effective_level(chunk: Chunk, x: int, y: int, z: int, lava: bool) -> int:
	var id: int = chunk.get_block(x, y, z)
	var same: bool = Blocks.is_lava(id) if lava else Blocks.is_water(id)
	if not same:
		return -1
	var lvl: int = chunk.get_block_meta(x, y, z)
	return 0 if lvl >= 8 else lvl


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
	var rect: Rect2
	if id == Blocks.CROPS:
		# Crops swap texture per growth stage (meta 0..7). Vanilla wheat
		# textures live at terrain.png (8..15, 5); the atlas pre-registers
		# them as crops_stage_0..7 so we just compose the lookup name.
		var stage: int = chunk.get_block_meta_unchecked(x, y, z) & 0x07
		rect = BlockAtlas.uv_rect("crops_stage_%d" % stage)
	else:
		rect = BlockAtlas.uv_rect_for(id, BlockAtlas.FACE_SIDE)
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
	# Selection collision — emit an AABB-box triangle soup, not the
	# cross-quad sheets. Cross-quad triangles are vertical planes with
	# zero thickness in Y, so a player aiming straight down at the cell
	# casts a ray nearly parallel to both sheets and misses entirely.
	# Vanilla MC uses Block.selection_aabb (a box) for cursor targeting
	# regardless of the block's render shape (af.java RenderItem hits a
	# 3D bbox, not the rendered cross), so the box-soup matches that.
	# Box dimensions come from Blocks.selection_aabb so each plant gets
	# its vanilla-tuned hitbox (sapling 0.8 cube; flowers/mushrooms a
	# tighter 0.4 box). Emit ONCE per cell, outside the per-quad loop.
	var aabb: AABB = Blocks.selection_aabb(id)
	var box_min := Vector3(x, y, z) + aabb.position
	_emit_collision_box(plant_faces, box_min, box_min + aabb.size)


# Vanilla Alpha BlockFire render (bk.java::d, render-type 3). Fire visually
# "leans" — on an opaque floor it renders as two perpendicular leaning
# planes (an X with tops offset 0.2 inward from the cell center), and
# stretches up to y+1.4 so flames extend past the cell top. With no
# opaque floor it renders one wall-hugging quad against each opaque or
# flammable side neighbor, plus a ceiling quad if the cell above is
# opaque. All quads are double-sided (front + back winding emitted, same
# trick as cross-quad) and share the fire atlas tile — the chunk shader
# does the time-based UV strip lookup, so no extra material or geometry
# variations needed. Perf: at most 2 quads on a floor or 5 wall/ceiling
# quads per fire cell × ~30 fire cells in a burning tree = ~150 extra
# triangles, well under the per-frame budget.
static func _emit_fire_quads(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array
) -> void:
	var origin := Vector3(x, y, z)
	var rect: Rect2 = BlockAtlas.uv_rect_for(Blocks.FIRE, BlockAtlas.FACE_SIDE)
	var flame_normal := Vector3(0, 1, 0)
	# Self-cell light — fire is always lit (block_light=15 from FIRE itself)
	# but sample anyway so caves with no torches around a small fire still
	# read with the fire's own block-light contribution.
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 1.0)
	var below_id := chunk.get_block(x, y - 1, z)
	if Blocks.is_opaque(below_id):
		# Path A — opaque floor. Vanilla bk.java::d emits 8 distinct
		# leaning planes per fire cell, NOT 2: an inner X-cross of 4
		# planes at offsets 0.2/0.3/0.7/0.8 plus an outer X-cross of 4
		# planes near the walls at offsets 0/0.1/0.9/1.0. Together they
		# form a flame "asterisk" with curls visible in all 4 cardinal
		# directions — much denser than a simple 2-plane X. Top Y = +1.4
		# so flame tips extend past the cell. All planes double-sided
		# (front+back winding) so cull_back keeps them visible from any
		# angle (vanilla disables culling globally for fire).
		var top_y: float = 1.4
		# Inner cross planes 1-2 — along Z, opposing leans
		# Plane 1: bottom X=0.7 → top X=0.2 (leans -X)
		_emit_fire_plane(
			verts,
			norms,
			uvs,
			colors,
			indices,
			origin + Vector3(0.7, 0.0, 0.0),
			origin + Vector3(0.2, top_y, 0.0),
			origin + Vector3(0.2, top_y, 1.0),
			origin + Vector3(0.7, 0.0, 1.0),
			rect,
			flame_normal,
			face_light,
		)
		# Plane 2: bottom X=0.3 → top X=0.8 (leans +X)
		_emit_fire_plane(
			verts,
			norms,
			uvs,
			colors,
			indices,
			origin + Vector3(0.3, 0.0, 1.0),
			origin + Vector3(0.8, top_y, 1.0),
			origin + Vector3(0.8, top_y, 0.0),
			origin + Vector3(0.3, 0.0, 0.0),
			rect,
			flame_normal,
			face_light,
		)
		# Inner cross planes 3-4 — along X, opposing leans
		# Plane 3: bottom Z=0.7 → top Z=0.2 (leans -Z)
		_emit_fire_plane(
			verts,
			norms,
			uvs,
			colors,
			indices,
			origin + Vector3(0.0, 0.0, 0.7),
			origin + Vector3(0.0, top_y, 0.2),
			origin + Vector3(1.0, top_y, 0.2),
			origin + Vector3(1.0, 0.0, 0.7),
			rect,
			flame_normal,
			face_light,
		)
		# Plane 4: bottom Z=0.3 → top Z=0.8 (leans +Z)
		_emit_fire_plane(
			verts,
			norms,
			uvs,
			colors,
			indices,
			origin + Vector3(1.0, 0.0, 0.3),
			origin + Vector3(1.0, top_y, 0.8),
			origin + Vector3(0.0, top_y, 0.8),
			origin + Vector3(0.0, 0.0, 0.3),
			rect,
			flame_normal,
			face_light,
		)
		# Outer cross planes 5-6 — along Z, near walls
		# Plane 5: bottom X=0.0 (west wall) → top X=0.1
		_emit_fire_plane(
			verts,
			norms,
			uvs,
			colors,
			indices,
			origin + Vector3(0.0, 0.0, 0.0),
			origin + Vector3(0.1, top_y, 0.0),
			origin + Vector3(0.1, top_y, 1.0),
			origin + Vector3(0.0, 0.0, 1.0),
			rect,
			flame_normal,
			face_light,
		)
		# Plane 6: bottom X=1.0 (east wall) → top X=0.9
		_emit_fire_plane(
			verts,
			norms,
			uvs,
			colors,
			indices,
			origin + Vector3(1.0, 0.0, 1.0),
			origin + Vector3(0.9, top_y, 1.0),
			origin + Vector3(0.9, top_y, 0.0),
			origin + Vector3(1.0, 0.0, 0.0),
			rect,
			flame_normal,
			face_light,
		)
		# Outer cross planes 7-8 — along X, near walls
		# Plane 7: bottom Z=0.0 (north wall) → top Z=0.1
		_emit_fire_plane(
			verts,
			norms,
			uvs,
			colors,
			indices,
			origin + Vector3(1.0, 0.0, 0.0),
			origin + Vector3(1.0, top_y, 0.1),
			origin + Vector3(0.0, top_y, 0.1),
			origin + Vector3(0.0, 0.0, 0.0),
			rect,
			flame_normal,
			face_light,
		)
		# Plane 8: bottom Z=1.0 (south wall) → top Z=0.9
		_emit_fire_plane(
			verts,
			norms,
			uvs,
			colors,
			indices,
			origin + Vector3(0.0, 0.0, 1.0),
			origin + Vector3(0.0, top_y, 0.9),
			origin + Vector3(1.0, top_y, 0.9),
			origin + Vector3(1.0, 0.0, 1.0),
			rect,
			flame_normal,
			face_light,
		)
	else:
		# Path B — no opaque floor → up to 5 wall-hugging quads. Vanilla
		# `f4 = 0.2` (lean amount), `f3 = 1.4` (top y), `f5 = 0.0625` (bottom lift).
		var lean: float = 0.2
		var top_y_b: float = 1.4
		var lift: float = 0.0625
		# -X wall (quad against the west face, leans east at top)
		if _fire_attaches_to(chunk.get_block(x - 1, y, z)):
			_emit_fire_plane(
				verts,
				norms,
				uvs,
				colors,
				indices,
				origin + Vector3(0.0, lift, 1.0),
				origin + Vector3(lean, top_y_b + lift, 1.0),
				origin + Vector3(lean, top_y_b + lift, 0.0),
				origin + Vector3(0.0, lift, 0.0),
				rect,
				flame_normal,
				face_light,
			)
		# +X wall (leans west at top)
		if _fire_attaches_to(chunk.get_block(x + 1, y, z)):
			_emit_fire_plane(
				verts,
				norms,
				uvs,
				colors,
				indices,
				origin + Vector3(1.0, lift, 0.0),
				origin + Vector3(1.0 - lean, top_y_b + lift, 0.0),
				origin + Vector3(1.0 - lean, top_y_b + lift, 1.0),
				origin + Vector3(1.0, lift, 1.0),
				rect,
				flame_normal,
				face_light,
			)
		# -Z wall (leans south at top)
		if _fire_attaches_to(chunk.get_block(x, y, z - 1)):
			_emit_fire_plane(
				verts,
				norms,
				uvs,
				colors,
				indices,
				origin + Vector3(0.0, lift, 0.0),
				origin + Vector3(0.0, top_y_b + lift, lean),
				origin + Vector3(1.0, top_y_b + lift, lean),
				origin + Vector3(1.0, lift, 0.0),
				rect,
				flame_normal,
				face_light,
			)
		# +Z wall (leans north at top)
		if _fire_attaches_to(chunk.get_block(x, y, z + 1)):
			_emit_fire_plane(
				verts,
				norms,
				uvs,
				colors,
				indices,
				origin + Vector3(1.0, lift, 1.0),
				origin + Vector3(1.0, top_y_b + lift, 1.0 - lean),
				origin + Vector3(0.0, top_y_b + lift, 1.0 - lean),
				origin + Vector3(0.0, lift, 1.0),
				rect,
				flame_normal,
				face_light,
			)
		# Ceiling quad — flat plane near the top of the cell, flipped so
		# it reads as the "underside" of fire burning on a ceiling.
		if Blocks.is_opaque(chunk.get_block(x, y + 1, z)):
			var ceiling_y: float = top_y_b - 0.2
			_emit_fire_plane(
				verts,
				norms,
				uvs,
				colors,
				indices,
				origin + Vector3(0.0, ceiling_y, 0.0),
				origin + Vector3(0.0, ceiling_y, 1.0),
				origin + Vector3(1.0, ceiling_y, 1.0),
				origin + Vector3(1.0, ceiling_y, 0.0),
				rect,
				flame_normal,
				face_light,
			)
	# Selection AABB so the player's targeting raycast can hit the fire
	# even though the visual quads are tilted thin sheets. Same trick as
	# cross-quads — vanilla MC uses Block.selection_aabb (a box) for
	# cursor targeting regardless of render shape.
	var aabb: AABB = Blocks.selection_aabb(Blocks.FIRE)
	var box_min := Vector3(x, y, z) + aabb.position
	_emit_collision_box(plant_faces, box_min, box_min + aabb.size)


# True if a fire cell should attach to (render a leaning quad against)
# the given neighbor. Vanilla `qh.h()` checks for opaque OR flammable
# neighbors — either anchors the flame visually.
static func _fire_attaches_to(neighbor_id: int) -> bool:
	if Blocks.is_opaque(neighbor_id):
		return true
	return BlockFire.can_catch_fire(neighbor_id)


# Emit one double-sided fire quad given 4 corner positions in BL → TL →
# TR → BR order. UVs map texture-bottom to quad-bottom (V is flipped per
# the chunk mesher's convention so the atlas tile reads upright). Front
# + back winding both emitted so the flame is visible from either side
# without disabling cull_back globally.
static func _emit_fire_plane(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	bl: Vector3,
	tl: Vector3,
	tr: Vector3,
	br: Vector3,
	rect: Rect2,
	normal: Vector3,
	face_light: Color
) -> void:
	var base := verts.size()
	verts.append(bl)
	verts.append(tl)
	verts.append(tr)
	verts.append(br)
	norms.append(normal)
	norms.append(normal)
	norms.append(normal)
	norms.append(normal)
	uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
	uvs.append(Vector2(rect.position.x, rect.position.y))
	uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
	uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
	colors.append(face_light)
	colors.append(face_light)
	colors.append(face_light)
	colors.append(face_light)
	# Front winding (matches cross-quad).
	indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array)
	# Back winding — same triangles flipped so cull_back keeps the
	# reverse side too.
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3] as PackedInt32Array)


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
# All 4 side quads emit BOTH windings (front + back) so every wall is
# visible regardless of camera angle. Vanilla BlockTorch renders without
# back-face culling for this exact reason — without the back winding,
# cull_back hides the 2 walls facing away from the camera and the torch
# reads as a 2-sided "corner" instead of a 3D pillar. Texture mirrors on
# the back face, but the torch sprite is bilaterally symmetric so it
# looks identical.
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
	var meta: int = chunk.get_block_meta(x, y, z)
	# Vanilla MC (both Alpha 1.2.6 bk.java:142-185 and Beta Bukkit/mc-dev
	# RenderBlocks.renderBlockTorch) renders ALL torches as a closed
	# 8-vert tight box — fully opaque, no alpha-test, no transparent
	# texels in the geometry. Floor torches: upright box centered in the
	# cell. Wall torches: same box transformed via the rotation pipeline.
	# This is the only vanilla-faithful approach; the alpha-test wall
	# variant we tried before doesn't exist in MC.
	_emit_torch_box(
		verts, norms, uvs, colors, indices, plant_faces, x, y, z, meta, rect, face_light
	)


# Floor-torch geometry — 4 axis-aligned full-cell wall quads with the
# whole torch tile UV (alpha-tested to the central silhouette) plus one
# horizontal flame quad at vanilla's d16 = 10/16 position. Each wall
# emits BOTH front + back winding so cull_back doesn't hide the side
# facing away from the camera (vanilla bk.a renders torches without
# back-face culling). The visible result: torch silhouette on every
# wall, central pillars overlap to read as a 3D torch pillar — matches
# the look of vanilla Alpha.
# gdlint: disable=function-arguments-number
static func _emit_floor_torch_walls(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array,
	x: int,
	y: int,
	z: int,
	rect: Rect2,
	face_light: Color
) -> void:
	var d15: float = 0.0625  # 1/16 — half torch-pillar width
	var d16: float = 0.625  # 10/16 — flame-quad height (vanilla bk.a)
	var bx: float = float(x)
	var by: float = float(y)
	var bz: float = float(z)
	var cx: float = bx + 0.5
	var cz: float = bz + 0.5
	var u0: float = rect.position.x
	var u1: float = rect.position.x + rect.size.x
	var v0: float = rect.position.y
	var v1: float = rect.position.y + rect.size.y
	# 4 wall quads — each spans the full cell vertically and horizontally
	# but the texture's transparent surround alpha-tests away everything
	# except the central torch pillar.
	# -X wall (x = cx - d15).
	_emit_floor_torch_wall(
		verts,
		norms,
		uvs,
		colors,
		indices,
		Vector3(cx - d15, by + 1.0, bz),
		Vector3(cx - d15, by + 0.0, bz),
		Vector3(cx - d15, by + 0.0, bz + 1.0),
		Vector3(cx - d15, by + 1.0, bz + 1.0),
		Vector3(-1, 0, 0),
		u0,
		v0,
		u1,
		v1,
		face_light
	)
	# +X wall (x = cx + d15).
	_emit_floor_torch_wall(
		verts,
		norms,
		uvs,
		colors,
		indices,
		Vector3(cx + d15, by + 1.0, bz + 1.0),
		Vector3(cx + d15, by + 0.0, bz + 1.0),
		Vector3(cx + d15, by + 0.0, bz),
		Vector3(cx + d15, by + 1.0, bz),
		Vector3(1, 0, 0),
		u0,
		v0,
		u1,
		v1,
		face_light
	)
	# +Z wall (z = cz + d15).
	_emit_floor_torch_wall(
		verts,
		norms,
		uvs,
		colors,
		indices,
		Vector3(bx, by + 1.0, cz + d15),
		Vector3(bx, by + 0.0, cz + d15),
		Vector3(bx + 1.0, by + 0.0, cz + d15),
		Vector3(bx + 1.0, by + 1.0, cz + d15),
		Vector3(0, 0, 1),
		u0,
		v0,
		u1,
		v1,
		face_light
	)
	# -Z wall (z = cz - d15).
	_emit_floor_torch_wall(
		verts,
		norms,
		uvs,
		colors,
		indices,
		Vector3(bx + 1.0, by + 1.0, cz - d15),
		Vector3(bx + 1.0, by + 0.0, cz - d15),
		Vector3(bx, by + 0.0, cz - d15),
		Vector3(bx, by + 1.0, cz - d15),
		Vector3(0, 0, -1),
		u0,
		v0,
		u1,
		v1,
		face_light
	)
	# Top-cap quad at y = by + 14/16 — sits at the very top of the
	# visible flame silhouette (texture row 2 = top of opaque flame).
	# Closes the transparent gap that the alpha-tested wall quads leave
	# between cell-y 14/16 and cell-y 1.0. Samples the flame center
	# (cols 7-9 / rows 6-8) so the cap reads as flame-colored. Vanilla's
	# bk.a put a flame quad at d16=10/16 inside its tilted box; for our
	# upright wall-quad torch the right cap height is the silhouette top.
	var fy: float = by + 14.0 / 16.0
	var ffu0: float = u0 + (u1 - u0) * (7.0 / 16.0)
	var ffu1: float = u0 + (u1 - u0) * (9.0 / 16.0)
	var ffv0: float = v0 + (v1 - v0) * (6.0 / 16.0)
	var ffv1: float = v0 + (v1 - v0) * (8.0 / 16.0)
	var fbase: int = verts.size()
	verts.append(Vector3(cx - d15, fy, cz - d15))
	verts.append(Vector3(cx - d15, fy, cz + d15))
	verts.append(Vector3(cx + d15, fy, cz + d15))
	verts.append(Vector3(cx + d15, fy, cz - d15))
	for _i in range(4):
		norms.append(Vector3(0, 1, 0))
		colors.append(face_light)
	uvs.append(Vector2(ffu0, ffv0))
	uvs.append(Vector2(ffu0, ffv1))
	uvs.append(Vector2(ffu1, ffv1))
	uvs.append(Vector2(ffu1, ffv0))
	indices.append_array(
		[fbase, fbase + 1, fbase + 2, fbase, fbase + 2, fbase + 3] as PackedInt32Array
	)
	# Selection collision — emit the torch's full AABB (Blocks.selection_aabb
	# floor variant: 0.4..0.6 in X/Z, 0..0.6 in Y) so the cursor can hit
	# the torch from any nearby angle. Without this, only the tiny cap
	# quad is targetable and the player has to perfectly aim to mine.
	_append_torch_aabb_collision(
		plant_faces, Vector3(bx + 0.4, by, bz + 0.4), Vector3(bx + 0.6, by + 0.6, bz + 0.6)
	)


# Emits 12 triangles covering an axis-aligned AABB into a face soup.
# Used for torch selection collision so the cursor raycast can reach
# the torch from any angle. Winding doesn't matter for the physics
# shape — raycast hits both sides of every triangle.
static func _append_torch_aabb_collision(
	plant_faces: PackedVector3Array, mn: Vector3, mx: Vector3
) -> void:
	var v000 := Vector3(mn.x, mn.y, mn.z)
	var v100 := Vector3(mx.x, mn.y, mn.z)
	var v010 := Vector3(mn.x, mx.y, mn.z)
	var v110 := Vector3(mx.x, mx.y, mn.z)
	var v001 := Vector3(mn.x, mn.y, mx.z)
	var v101 := Vector3(mx.x, mn.y, mx.z)
	var v011 := Vector3(mn.x, mx.y, mx.z)
	var v111 := Vector3(mx.x, mx.y, mx.z)
	var faces: Array = [
		[v010, v110, v111, v011],  # +Y
		[v000, v001, v101, v100],  # -Y
		[v100, v101, v111, v110],  # +X
		[v000, v010, v011, v001],  # -X
		[v001, v011, v111, v101],  # +Z
		[v000, v100, v110, v010],  # -Z
	]
	for face: Array in faces:
		plant_faces.append(face[0])
		plant_faces.append(face[1])
		plant_faces.append(face[2])
		plant_faces.append(face[0])
		plant_faces.append(face[2])
		plant_faces.append(face[3])


# Wall-torch geometry — same 4-wall + flame quad shape as the floor
# variant, but the bottom of each wall is shifted by (ax, az) so the
# whole torch leans into the supporting wall. ax/az and the +0.2 Y bump
# come from vanilla's bk.b dispatch (with our wall-leaning approximation
# of vanilla's full rotation math). The leaning bottom pulls the torch
# pillar away from the support face's center toward the cell-center
# wall, matching the look of an Alpha wall torch.
# gdlint: disable=function-arguments-number
static func _emit_wall_torch_quads(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array,
	x: int,
	y: int,
	z: int,
	meta: int,
	rect: Rect2,
	face_light: Color
) -> void:
	var d15: float = 0.0625
	var d16: float = 0.625
	var bx: float = float(x)
	var by: float = float(y)
	var bz: float = float(z)
	# Wall-mount offset + tilt magnitude (matches the prior implementation
	# that the user confirmed reads like vanilla Alpha).
	var ax: float = 0.0
	var az: float = 0.0
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
	var d11: float = bx
	var d12: float = bx + 1.0
	var d13: float = bz
	var d14: float = bz + 1.0
	var cx: float = bx + 0.5
	var cz: float = bz + 0.5
	var u0: float = rect.position.x
	var u1: float = rect.position.x + rect.size.x
	var v0: float = rect.position.y
	var v1: float = rect.position.y + rect.size.y
	# -X wall.
	_emit_floor_torch_wall(
		verts,
		norms,
		uvs,
		colors,
		indices,
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
	# +X wall.
	_emit_floor_torch_wall(
		verts,
		norms,
		uvs,
		colors,
		indices,
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
	# +Z wall.
	_emit_floor_torch_wall(
		verts,
		norms,
		uvs,
		colors,
		indices,
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
	# -Z wall.
	_emit_floor_torch_wall(
		verts,
		norms,
		uvs,
		colors,
		indices,
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
	# Top-cap quad at the visible flame silhouette top (texture row 2 →
	# cell-y 14/16 of the wall quad). Offset by ax/az * 0.125 toward the
	# lean direction so the cap stays at the leaning torch tip.
	var top_h: float = 14.0 / 16.0
	var ftx: float = cx + ax * (1.0 - top_h)
	var ftz: float = cz + az * (1.0 - top_h)
	var fy: float = by + top_h
	var ffu0: float = u0 + (u1 - u0) * (7.0 / 16.0)
	var ffu1: float = u0 + (u1 - u0) * (9.0 / 16.0)
	var ffv0: float = v0 + (v1 - v0) * (6.0 / 16.0)
	var ffv1: float = v0 + (v1 - v0) * (8.0 / 16.0)
	var fbase: int = verts.size()
	verts.append(Vector3(ftx - d15, fy, ftz - d15))
	verts.append(Vector3(ftx - d15, fy, ftz + d15))
	verts.append(Vector3(ftx + d15, fy, ftz + d15))
	verts.append(Vector3(ftx + d15, fy, ftz - d15))
	for _i in range(4):
		norms.append(Vector3(0, 1, 0))
		colors.append(face_light)
	uvs.append(Vector2(ffu0, ffv0))
	uvs.append(Vector2(ffu0, ffv1))
	uvs.append(Vector2(ffu1, ffv1))
	uvs.append(Vector2(ffu1, ffv0))
	indices.append_array(
		[fbase, fbase + 1, fbase + 2, fbase, fbase + 2, fbase + 3] as PackedInt32Array
	)
	# Selection collision — full meta-aware AABB from Blocks.selection_aabb
	# (wall variant: 0.3 wide × 0.6 tall × 0.3 deep, anchored at the
	# support side per meta).
	var aabb_min: Vector3
	var aabb_max: Vector3
	match meta:
		1:
			aabb_min = Vector3(float(x), float(y) + 0.2, float(z) + 0.35)
			aabb_max = Vector3(float(x) + 0.3, float(y) + 0.8, float(z) + 0.65)
		2:
			aabb_min = Vector3(float(x) + 0.7, float(y) + 0.2, float(z) + 0.35)
			aabb_max = Vector3(float(x) + 1.0, float(y) + 0.8, float(z) + 0.65)
		3:
			aabb_min = Vector3(float(x) + 0.35, float(y) + 0.2, float(z))
			aabb_max = Vector3(float(x) + 0.65, float(y) + 0.8, float(z) + 0.3)
		_:  # 4
			aabb_min = Vector3(float(x) + 0.35, float(y) + 0.2, float(z) + 0.7)
			aabb_max = Vector3(float(x) + 0.65, float(y) + 0.8, float(z) + 1.0)
	_append_torch_aabb_collision(plant_faces, aabb_min, aabb_max)


# Single wall quad emitted both front- and back-facing so cull_back
# doesn't hide the side away from the camera. UV layout per vanilla:
# v0=top-back, v1=bot-back, v2=bot-front, v3=top-front (CCW from outside).
# gdlint: disable=function-arguments-number
static func _emit_floor_torch_wall(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
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
	for _i in range(4):
		norms.append(normal)
		colors.append(face_light)
	uvs.append(Vector2(u0, v_top))
	uvs.append(Vector2(u0, v_bot))
	uvs.append(Vector2(u1, v_bot))
	uvs.append(Vector2(u1, v_top))
	# Front + back winding so cull_back keeps both sides visible.
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3] as PackedInt32Array)
	indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array)


# Vanilla `ao.a(angle)` — rotation around X axis (sin/cos lookup in fi.java
# resolves to standard sin/cos). Mirrors:
#   new_y = y*cos + z*sin
#   new_z = z*cos - y*sin
static func _torch_rotate_x(v: Vector3, angle: float) -> Vector3:
	var c: float = cos(angle)
	var s: float = sin(angle)
	return Vector3(v.x, v.y * c + v.z * s, v.z * c - v.y * s)


# Vanilla `ao.b(angle)` — rotation around Y axis.
#   new_x = x*cos + z*sin
#   new_z = z*cos - x*sin
static func _torch_rotate_y(v: Vector3, angle: float) -> Vector3:
	var c: float = cos(angle)
	var s: float = sin(angle)
	return Vector3(v.x * c + v.z * s, v.y, v.z * c - v.x * s)


# Vanilla-faithful unified torch geometry — closed 8-vert box of size
# 0.125 × 0.625 × 0.125 per ob.java + bk.java:142-185, with tight UV
# sub-rects on every face. Handles BOTH floor torches (meta 0 / 5) AND
# wall torches (meta 1-4) by applying the full vanilla transformation
# pipeline:
#   1. Z shift +1/16              (bk.java:158, bl3=false branch)
#   2. Rotate X by -40°            (bk.java:159)
#   3. (wall only) Y shift -3/8    (bk.java:170)
#   4. (wall only) Rotate X +90°   (bk.java:171)
#   5. (wall only) Rotate Y per-meta — meta 1=-90°, 2=+90°, 3=180°, 4=0°
#   6. Translate by cell-center + (0.5, 0.125 floor / 0.5 wall, 0.5)
#
# Faces follow vanilla's i3=0..5 ordering and per-vert UV mapping
# (ao2=BL, ao3=TL, ao4=TR, ao5=BR per bk.java:225-228). Normals are
# computed from the rotated verts so they stay correct after every
# transform.
# gdlint: disable=function-arguments-number
static func _emit_torch_box(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array,
	x: int,
	y: int,
	z: int,
	meta: int,
	rect: Rect2,
	face_light: Color
) -> void:
	var d15: float = 0.0625  # 1/16
	var d16: float = 0.625  # 10/16
	# Local-space box vertices (vanilla bk.java:151-158). ao[0..3] bottom,
	# ao[4..7] top; ordering (-x,-z), (+x,-z), (+x,+z), (-x,+z).
	var ao: Array[Vector3] = [
		Vector3(-d15, 0.0, -d15),
		Vector3(d15, 0.0, -d15),
		Vector3(d15, 0.0, d15),
		Vector3(-d15, 0.0, d15),
		Vector3(-d15, d16, -d15),
		Vector3(d15, d16, -d15),
		Vector3(d15, d16, d15),
		Vector3(-d15, d16, d15),
	]
	var is_wall: bool = meta == 1 or meta == 2 or meta == 3 or meta == 4
	var ymeta: float = 0.0
	match meta:
		1:
			ymeta = -PI * 0.5
		2:
			ymeta = PI * 0.5
		3:
			ymeta = PI
		4:
			ymeta = 0.0
	var cx_off: float = float(x) + 0.5
	var cz_off: float = float(z) + 0.5
	var cy_off: float = float(y) + (0.5 if is_wall else 0.125)
	for i in range(8):
		var v: Vector3 = ao[i]
		if is_wall:
			# Vanilla bk.java:158-185 wall-torch pipeline. Steps 1-2 (Z+1/16
			# + rotate-X -40°) are part of the wall transform — step 4
			# (rotate-X +90°) rotates the leaning column horizontal so it
			# can extend into the support wall. For floor torches there's
			# no step 4 to undo it, so applying steps 1-2 leaves them
			# leaning forward like a fallen cigarette. Skipping steps 1-2
			# for floor torches gives an upright box (the visually correct
			# look players expect from MC torches).
			v.z += 0.0625
			v = _torch_rotate_x(v, -0.69813174)
			v.y -= 0.375
			v = _torch_rotate_x(v, 1.5707964)
			v = _torch_rotate_y(v, ymeta)
		# Final translate to world cell.
		ao[i] = Vector3(v.x + cx_off, v.y + cy_off, v.z + cz_off)
	# Debug logger — set MC_CLONE_DEBUG_MESH=1 in .env to print the 8
	# transformed verts for every torch the mesher emits. Confirms the
	# GDScript path is running (vs the native mesher silently treating
	# torches as cubes) and shows the actual geometry coords so we can
	# tell if the rotation pipeline is producing the right shape.
	if Game.debug_mesh:
		print("[torch] (%d,%d,%d) meta=%d wall=%s" % [x, y, z, meta, str(is_wall)])
	var u0: float = rect.position.x
	var u1: float = rect.position.x + rect.size.x
	var v0: float = rect.position.y
	var v1: float = rect.position.y + rect.size.y
	# UV setup. The pack's torch.png has the visible torch silhouette at
	# cols 7-8 / rows 6-15 (rows 0-5 are transparent, no flame texels in
	# this asset). Mapping rows 0-16 to the face leaves the top 37.5%
	# transparent and rendering looked like missing faces. Mapping just
	# rows 6-16 (the visible silhouette) to the full face height makes
	# every side render as a clean opaque torch sprite — flame at top
	# (rows 6-7 = yellow), stick body below (rows 8-15 = brown).
	var su0: float = u0 + (u1 - u0) * (7.0 / 16.0)
	var su1: float = u0 + (u1 - u0) * (9.0 / 16.0)
	var t_v_top: float = v0 + (v1 - v0) * (6.0 / 16.0)
	var t_v_bot: float = v0 + (v1 - v0) * (8.0 / 16.0)
	var s_v_top: float = v0 + (v1 - v0) * (6.0 / 16.0)  # row 6 = top of flame
	var s_v_bot: float = v1  # row 16 = bottom of stick
	# i3=0 (local -Y bottom) and i3=1 (local +Y top) use the flame
	# center sub-rect (cols 7-9 / rows 6-8). Side faces (i3=2..5) use
	# cols 7-9 / rows 6-16, mapped with U across face width and V along
	# face height (vert order: TL=high-Y opp-X, BL=low-Y opp-X, BR=low-Y
	# X, TR=high-Y X) — standard mapping so the texture renders upright.
	_emit_torch_box_face(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		ao[1],
		ao[0],
		ao[3],
		ao[2],
		su0,
		t_v_top,
		su1,
		t_v_bot,
		face_light,
		true
	)  # i3=0 — bottom of box, flame UV
	_emit_torch_box_face(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		ao[6],
		ao[7],
		ao[4],
		ao[5],
		su0,
		t_v_top,
		su1,
		t_v_bot,
		face_light,
		true
	)  # i3=1 — top of box, flame UV
	# Side faces — vert order = (TL=high Y, BL=low Y, BR=low Y opp X,
	# TR=high Y opp X) with U across width, V along height.
	_emit_torch_box_face(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		ao[4],
		ao[0],
		ao[1],
		ao[5],
		su0,
		s_v_top,
		su1,
		s_v_bot,
		face_light,
		true
	)  # i3=2 — local -Z face
	_emit_torch_box_face(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		ao[5],
		ao[1],
		ao[2],
		ao[6],
		su0,
		s_v_top,
		su1,
		s_v_bot,
		face_light,
		true
	)  # i3=3 — local +X face
	_emit_torch_box_face(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		ao[6],
		ao[2],
		ao[3],
		ao[7],
		su0,
		s_v_top,
		su1,
		s_v_bot,
		face_light,
		true
	)  # i3=4 — local +Z face
	_emit_torch_box_face(
		verts,
		norms,
		uvs,
		colors,
		indices,
		plant_faces,
		ao[7],
		ao[3],
		ao[0],
		ao[4],
		su0,
		s_v_top,
		su1,
		s_v_bot,
		face_light,
		true
	)  # i3=5 — local -X face
	# Selection collision — Blocks.selection_aabb (meta-aware AABB) so the
	# cursor can target the torch from any nearby angle, not just the tiny
	# box faces. Without this, mining is frustrating because the player
	# has to perfectly aim at the box silhouette.
	var aabb_min: Vector3
	var aabb_max: Vector3
	match meta:
		1:
			aabb_min = Vector3(float(x), float(y) + 0.2, float(z) + 0.35)
			aabb_max = Vector3(float(x) + 0.3, float(y) + 0.8, float(z) + 0.65)
		2:
			aabb_min = Vector3(float(x) + 0.7, float(y) + 0.2, float(z) + 0.35)
			aabb_max = Vector3(float(x) + 1.0, float(y) + 0.8, float(z) + 0.65)
		3:
			aabb_min = Vector3(float(x) + 0.35, float(y) + 0.2, float(z))
			aabb_max = Vector3(float(x) + 0.65, float(y) + 0.8, float(z) + 0.3)
		4:
			aabb_min = Vector3(float(x) + 0.35, float(y) + 0.2, float(z) + 0.7)
			aabb_max = Vector3(float(x) + 0.65, float(y) + 0.8, float(z) + 1.0)
		_:
			aabb_min = Vector3(float(x) + 0.4, float(y), float(z) + 0.4)
			aabb_max = Vector3(float(x) + 0.6, float(y) + 0.6, float(z) + 0.6)
	_append_torch_aabb_collision(plant_faces, aabb_min, aabb_max)


# Per-face emit using vanilla's UV mapping (TL,BL,BR,TR per CCW from
# outside). Normal computed from the rotated verts so it tracks any
# rotation pipeline applied before the call.
# gdlint: disable=function-arguments-number
static func _emit_torch_box_face(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array,
	v_tl: Vector3,
	v_bl: Vector3,
	v_br: Vector3,
	v_tr: Vector3,
	u_left: float,
	v_top: float,
	u_right: float,
	v_bot: float,
	face_light: Color,
	add_selection: bool
) -> void:
	var base: int = verts.size()
	# Vanilla bk.java draws torches with NO back-face culling, so it ships
	# verts in CW-from-outside order. Our chunk shader uses cull_back, so
	# we have to FLIP the winding to make the face's front point outward.
	# Computing the normal as (v_br - v_tl) × (v_bl - v_tl) gives the
	# outward-pointing direction (negation of the literal cross product),
	# matching the flipped triangle indices below.
	var normal: Vector3 = (v_br - v_tl).cross(v_bl - v_tl)
	if normal.length_squared() > 1.0e-8:
		normal = normal.normalized()
	verts.append(v_tl)
	verts.append(v_bl)
	verts.append(v_br)
	verts.append(v_tr)
	for _i in range(4):
		norms.append(normal)
		colors.append(face_light)
	uvs.append(Vector2(u_left, v_top))
	uvs.append(Vector2(u_left, v_bot))
	uvs.append(Vector2(u_right, v_bot))
	uvs.append(Vector2(u_right, v_top))
	# Standard CCW winding. Combined with the new vert order (TL=high-Y
	# opp-X for sides), the per-triangle CCW direction matches the face's
	# OUTWARD direction — cull_back keeps the face visible from outside.
	# Earlier this was reversed because the OLD vert order needed a flip;
	# the NEW order doesn't.
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3] as PackedInt32Array)
	if add_selection:
		plant_faces.append(v_tl)
		plant_faces.append(v_br)
		plant_faces.append(v_bl)
		plant_faces.append(v_tl)
		plant_faces.append(v_tr)
		plant_faces.append(v_br)
