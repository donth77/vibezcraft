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
# bk.java:459 `f5` — how far a redstone-dust arm is pulled back on a side
# with no connection, in cell units. 5/16.
const _WIRE_ARM_CROP: float = 0.3125

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
# True when the loaded extension exposes mesh_chunk_data_lit2 (native
# non-cube pass). Stale platform binaries built before lit2 keep working
# through the legacy lit + full-scan GDScript appendix.
static var _native_has_lit2: bool = false
# True when the extension exposes mesh_chunk_data_lit3 (cross-chunk
# edge LIGHT slices — border faces sample the neighbor's real light
# instead of the sky=15 OOB default; docs/lighting-chunk-seams.md).
# Stale binaries fall back to lit2 with today's border-lighting quirk.
static var _native_has_lit3: bool = false


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
	_native_has_lit2 = _native_mesher.has_method("mesh_chunk_data_lit2")
	_native_has_lit3 = _native_mesher.has_method("mesh_chunk_data_lit3")
	if _native_has_lit2:
		# The lit2 pass needs the selection-AABB table on workers; build
		# it now on the main thread (same warm rule as uv_table_flat).
		Blocks.selection_aabb_flat()
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
	# A stale native binary (pre-lit3) cannot sample the attached neighbor
	# light planes. Once a neighbor is loaded, using lit2/lit here would
	# regress border faces to the OOB defaults (sky=15, block=0), producing
	# bright seam stripes in caves and at night. Preserve correctness by
	# using the GDScript reference for these seam-heal meshes. Initial meshes
	# still have empty planes and may use the older native path; current
	# binaries expose lit3 and never pay this fallback cost.
	if not _native_has_lit3 and _has_attached_edge_light(chunk):
		var result: Dictionary = mesh_chunk(chunk)
		return result
	var probe_token := PerfProbe.begin("mesher.mesh_chunk")
	var result: Dictionary
	if _native_has_lit3:
		# lit2 + cross-chunk edge LIGHT slices: border faces sample the
		# neighbor's real sky/block light instead of the OOB sky=15
		# default that lit seams full-bright in caves and at night.
		result = (
			_native_mesher
			. mesh_chunk_data_lit3(
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
				chunk.edge_sky_light_west,
				chunk.edge_sky_light_east,
				chunk.edge_sky_light_north,
				chunk.edge_sky_light_south,
				chunk.edge_block_light_west,
				chunk.edge_block_light_east,
				chunk.edge_block_light_north,
				chunk.edge_block_light_south,
				Blocks.selection_aabb_flat(),
			)
		)
		if chunk.has_non_cube_blocks:
			_append_special_cells(chunk, result)
	elif _native_has_lit2:
		# Native owns the full-grid scan AND the worldgen-hot non-cube
		# shapes (cross plants, snow layers); only the sparse player-built
		# cells it returns in `special_cells` go through GDScript. This is
		# what keeps snowy/flowered chunks off the ~25 ms-per-mesh GDScript
		# grid walk on wasm.
		result = (
			_native_mesher
			. mesh_chunk_data_lit2(
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
				Blocks.selection_aabb_flat(),
			)
		)
		if chunk.has_non_cube_blocks:
			_append_special_cells(chunk, result)
	else:
		# Stale extension binary without lit2 — legacy combo: native cubes
		# + the full-scan GDScript appendix. Slower but byte-correct.
		result = (
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


# True when a remesh snapshot carries at least one loaded neighbor's light
# plane. Plane contents may legitimately be all zero in a sealed cave, so
# size—not brightness—is the presence signal.
static func _has_attached_edge_light(chunk: Chunk) -> bool:
	return (
		not chunk.edge_sky_light_west.is_empty()
		or not chunk.edge_sky_light_east.is_empty()
		or not chunk.edge_sky_light_north.is_empty()
		or not chunk.edge_sky_light_south.is_empty()
		or not chunk.edge_block_light_west.is_empty()
		or not chunk.edge_block_light_east.is_empty()
		or not chunk.edge_block_light_north.is_empty()
		or not chunk.edge_block_light_south.is_empty()
	)


# Per-cell non-cube dispatch shared by every appendix below. The chain
# mirrors Blocks.mesh_shape's taxonomy; CROSS here also covers CROPS
# (its growth-stage UV resolves inside _emit_cross_quads).
# gdlint: disable=function-arguments-number
static func _emit_special_cell(
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
	collision_faces: PackedVector3Array,
	plant_faces: PackedVector3Array
) -> void:
	var ms: int = Blocks.mesh_shape(id)
	if ms == Blocks.MESH_SHAPE_CROSS:
		_emit_cross_quads(chunk, x, y, z, id, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_FIRE:
		_emit_fire_quads(chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_TORCH:
		_emit_torch_quads(chunk, x, y, z, id, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_EXTERNAL:
		_emit_external_collision(x, y, z, collision_faces)
	elif ms == Blocks.MESH_SHAPE_FENCE:
		_emit_fence_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, collision_faces)
	elif ms == Blocks.MESH_SHAPE_STAIRS:
		_emit_stair_geometry(
			chunk, x, y, z, id, verts, norms, uvs, colors, indices, collision_faces
		)
	elif ms == Blocks.MESH_SHAPE_DOOR:
		_emit_door_geometry(chunk, x, y, z, id, verts, norms, uvs, colors, indices, collision_faces)
	elif ms == Blocks.MESH_SHAPE_FENCE_GATE:
		_emit_fence_gate_geometry(
			chunk, x, y, z, verts, norms, uvs, colors, indices, collision_faces, plant_faces
		)
	elif ms == Blocks.MESH_SHAPE_LADDER:
		_emit_ladder_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_SNOW_LAYER:
		_emit_snow_layer_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_SLAB:
		_emit_slab_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, collision_faces)
	elif ms == Blocks.MESH_SHAPE_SIGN:
		_emit_sign_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_RAIL:
		_emit_rail_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_REDSTONE_WIRE:
		_emit_wire_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_BUTTON:
		_emit_button_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_PRESSURE_PLATE:
		_emit_plate_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_LEVER:
		_emit_lever_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces)
	elif ms == Blocks.MESH_SHAPE_BED:
		_emit_bed_geometry(chunk, x, y, z, verts, norms, uvs, colors, indices, collision_faces)
	elif ms == Blocks.MESH_SHAPE_NONE:
		# Portal — drawn by PortalRenderer, not the chunk mesh. Nothing is
		# emitted, INCLUDING collision; the pinned oracle is that a portal
		# cell meshes identically to air (test_portal_rendering).
		pass


# Merge locally-emitted non-cube arrays into a mesh result dict, shifting
# indices past the existing vertex count. Packed*Array types use CoW —
# `result["key"].append_array()` would mutate a temporary copy, leaving
# the dict unchanged. Extract, append, reassign instead.
static func _merge_nc_arrays(
	result: Dictionary,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	collision_faces: PackedVector3Array,
	plant_faces: PackedVector3Array
) -> void:
	if verts.is_empty() and collision_faces.is_empty() and plant_faces.is_empty():
		return
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


# Production appendix for the native lit2 path. The native pass already
# emitted CROSS plants + snow layers and returns every OTHER non-cube
# cell in `special_cells` (linear y-major indices, scan order) — so
# GDScript cost is proportional to actual player-built blocks, never the
# 32k-cell grid walk that made snowy/flowered chunks cost ~25 ms per
# mesh on wasm.
static func _append_special_cells(chunk: Chunk, result: Dictionary) -> void:
	var cells: PackedInt32Array = result.get("special_cells", PackedInt32Array())
	if cells.is_empty():
		return
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var collision_faces := PackedVector3Array()
	var plant_faces := PackedVector3Array()
	for ci in range(cells.size()):
		var idx: int = cells[ci]
		var x: int = idx % Chunk.SIZE_X
		var z: int = (idx / Chunk.SIZE_X) % Chunk.SIZE_Z
		var y: int = idx / (Chunk.SIZE_X * Chunk.SIZE_Z)
		var id := chunk.get_block(x, y, z)
		_emit_special_cell(
			chunk, x, y, z, id, verts, norms, uvs, colors, indices, collision_faces, plant_faces
		)
	_merge_nc_arrays(result, verts, norms, uvs, colors, indices, collision_faces, plant_faces)


# Reference twin of the production path (native lit2 + special-cells
# appendix), used by mesh_chunk: phase 1 emits CROSS plants (minus
# meta-UV CROPS) + snow layers in scan order, phase 2 replays every
# other non-cube cell through the shared special-cell dispatch. The
# two-phase order is what makes the reference's vertex stream byte-equal
# to native+appendix on chunks that mix worldgen plants/snow with
# player-built shapes.
static func _append_non_cube_reference(chunk: Chunk, result: Dictionary) -> void:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var collision_faces := PackedVector3Array()
	var plant_faces := PackedVector3Array()
	var specials := PackedInt32Array()
	var top: int = mini(chunk.max_y + 1, Chunk.SIZE_Y - 1)
	for y in range(top + 1):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				var id := chunk.get_block(x, y, z)
				if id == Blocks.AIR:
					continue
				var ms: int = Blocks.mesh_shape(id)
				if ms == Blocks.MESH_SHAPE_CROSS and id != Blocks.CROPS:
					_emit_cross_quads(
						chunk, x, y, z, id, verts, norms, uvs, colors, indices, plant_faces
					)
				elif ms == Blocks.MESH_SHAPE_SNOW_LAYER:
					_emit_snow_layer_geometry(
						chunk, x, y, z, verts, norms, uvs, colors, indices, plant_faces
					)
				elif ms != Blocks.MESH_SHAPE_CUBE:
					specials.append(y * Chunk.SIZE_X * Chunk.SIZE_Z + z * Chunk.SIZE_X + x)
	_merge_nc_arrays(result, verts, norms, uvs, colors, indices, collision_faces, plant_faces)
	result["special_cells"] = specials
	_append_special_cells(chunk, result)


# LEGACY appendix — single interleaved scan emitting every non-cube shape
# in cell order. Kept only for extension binaries that predate
# mesh_chunk_data_lit2 (e.g. a stale Windows DLL): mesh_chunk_fast pairs
# it with the old lit entry point so those platforms keep working
# unchanged. New code should not call this.
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
				if Blocks.mesh_shape(id) == Blocks.MESH_SHAPE_CUBE:
					continue
				_emit_special_cell(
					chunk,
					x,
					y,
					z,
					id,
					verts,
					norms,
					uvs,
					colors,
					indices,
					collision_faces,
					plant_faces
				)
	_merge_nc_arrays(result, verts, norms, uvs, colors, indices, collision_faces, plant_faces)


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
	# with integer sky subtraction plus COLOR.g for block light. Flat
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
	# Append non-cube geometry after all cubes, in the production order:
	# [cross plants + snow in scan order] then [special cells in scan
	# order] — the byte-order twin of native lit2 + _append_special_cells.
	if chunk.has_non_cube_blocks:
		_append_non_cube_reference(chunk, result)
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
	# Block classification is invariant across all emitted faces. Hoist it
	# out of the six-face loop so the GDScript fallback pays one registry
	# lookup per block, not one per visible face.
	var block_alpha_test: float = 0.0 if Blocks.is_opaque(id) else 1.0
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
		# Mob spawner: always emit all 6 cage faces regardless of neighbor
		# opacity. Vanilla `eb.java::shouldSideBeRendered` returns true for
		# any non-same-material neighbor (the cage looks like a complete
		# cube on every side). Without this exception the bottom face
		# vanished against grass/dirt and the spawner looked like a
		# floating five-faced block.
		if id == Blocks.MOB_SPAWNER:
			neighbor_hides_face = neighbor_id == id
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
		# COLOR.a is a flat alpha-test classification consumed by the chunk
		# shader. Opaque cube faces must not run texture-alpha discard:
		# under MSAA, edge-sample UV extrapolation can otherwise reach an
		# adjacent transparent atlas texel and expose the sky between two
		# perfectly touching floor quads. Non-opaque/cutout cubes retain
		# the existing discard behavior.
		var face_light := Color(sky_n, blk_n, 0.0, block_alpha_test)
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
# True if the cell at (nx, ny, nz) should have a fence rail extended
# toward it. Vanilla Bukkit `BlockFence.e()` returns true for same-id
# fence AND for any fence gate (no facing check) — we mirror exactly
# that. Other opaque-cube neighbours stay deliberately excluded.
static func _fence_attaches_to(chunk: Chunk, nx: int, ny: int, nz: int) -> bool:
	var nid: int = chunk.get_block(nx, ny, nz)
	return nid == Blocks.FENCE or nid == Blocks.FENCE_GATE


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
	# Vector3i offsets. Alpha gates on same-id neighbours only. Bukkit's
	# `BlockFence.e()` (the modern-MC connect check) explicitly returns
	# true for `Blocks.FENCE_GATE` neighbours regardless of gate facing,
	# so a fence rail extrudes into any gate-adjacent side — same rule we
	# adopt here. Other Beta+ "connect to any opaque renderAsNormalBlock"
	# neighbours stay deliberately omitted (would attach to dirt / planks
	# / etc., which doesn't fit the Alpha-leaning aesthetic).
	var conn_west: bool = _fence_attaches_to(chunk, x - 1, y, z)
	var conn_east: bool = _fence_attaches_to(chunk, x + 1, y, z)
	var conn_north: bool = _fence_attaches_to(chunk, x, y, z - 1)
	var conn_south: bool = _fence_attaches_to(chunk, x, y, z + 1)
	# Sample sky/block light at the fence's own cell — fence faces don't
	# have an obvious "open neighbor" the way cube faces do, and the cell
	# above is generally air. Self-light is what RenderBlocks.k() does
	# (bk.java:1010 reads `nq2.b(this.a, n2, n3, n4)` — own cell brightness).
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	# Tight box geometry uses only the opaque planks tile.
	var face_light := Color(sky_n, blk_n, 0.0, 0.0)
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
	var face_light := Color(sky_n, blk_n, 0.0, 0.0)
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
# Beta 1.8 BlockFenceGate, mesh modelled after the canonical 1.9 model
# JSON (`models/block/fence_gate_closed.json` + `_open.json`) but with
# the outer posts extended down to y=0 instead of y=5/16. Vanilla 1.9
# leaves a 5/16 gap below the gate because adjacent fences are expected
# to attach there; for standalone gates that gap reads as "floating".
# 8 boxes per state: 2 grounded outer posts, 2 short inner posts
# (y=6..15/16), and 4 rails (lower y=6..9/16, upper y=12..15/16). Open
# state swings the inner posts + rails back to +Z. Facing 0/2 keeps the
# canonical X-axis layout; facing 1/3 rotates 90° around Y.
#
# Collision: closed gate emits a full-width 1.5-tall fence-style hitbox
# (Bukkit `a(World,...)` AABB); open gate emits zero collision_faces so
# the player can walk through. Selection collision (plant_faces) is
# emitted in BOTH states, scaled to the per-facing selection AABB, so
# the cursor can still raycast-hit an OPEN gate to right-click it
# closed. Without this the raycast passed through the gate to whatever
# was behind it — the user-reported "unable to close gate fence" bug.
# gdlint: disable=function-arguments-number
static func _emit_fence_gate_geometry(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	collision_faces: PackedVector3Array,
	plant_faces: PackedVector3Array
) -> void:
	var meta: int = chunk.get_block_meta(x, y, z)
	var facing: int = Blocks.fence_gate_facing(meta)
	var is_open: bool = Blocks.is_fence_gate_open(meta)
	var fx: float = float(x)
	var fy: float = float(y)
	var fz: float = float(z)
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 0.0)
	var rect: Rect2 = BlockAtlas.uv_rect("planks")
	for box: Array in _fence_gate_boxes(facing, is_open):
		var mn: Vector3 = (box[0] as Vector3) + Vector3(fx, fy, fz)
		var mx: Vector3 = (box[1] as Vector3) + Vector3(fx, fy, fz)
		_emit_box(verts, norms, uvs, colors, indices, mn, mx, rect, face_light)
	# Physical collision: closed only. 1.5-tall (matches FENCE so the
	# player can't hop over) along the gate's spanned axis.
	if not is_open:
		if facing == 0 or facing == 2:
			_emit_collision_box(
				collision_faces,
				Vector3(fx, fy, fz + 0.375),
				Vector3(fx + 1.0, fy + 1.5, fz + 0.625)
			)
		else:
			_emit_collision_box(
				collision_faces,
				Vector3(fx + 0.375, fy, fz),
				Vector3(fx + 0.625, fy + 1.5, fz + 1.0)
			)
	# Selection collision (cursor target only). Emit on BOTH open and
	# closed so right-click still hits the open gate. Footprint matches
	# `Blocks._fence_gate_selection_aabb` so the highlight wireframe
	# and the cursor pick agree.
	var sel_aabb: AABB = Blocks._fence_gate_selection_aabb(meta)
	_emit_collision_box(
		plant_faces,
		Vector3(fx + sel_aabb.position.x, fy + sel_aabb.position.y, fz + sel_aabb.position.z),
		Vector3(
			fx + sel_aabb.position.x + sel_aabb.size.x,
			fy + sel_aabb.position.y + sel_aabb.size.y,
			fz + sel_aabb.position.z + sel_aabb.size.z
		)
	)


# Canonical 1.9 fence-gate box list in cell-local [0..1] coords. 8
# axis-aligned boxes per open/closed state — direct port of the
# `models/block/fence_gate_{closed,open}.json` element coords (1/16
# units divided by 16). Facing 1/3 rotates the X-axis boxes 90° CW
# around the cell center via (x, y, z) → (z, y, 1-x) so the gate
# spans Z instead of X. Used by the mesher (in-world geometry) and
# could also feed a held-mesh builder, but the held variant freezes
# facing 0 + closed so we just inline that case in block_mesh.gd.
static func _fence_gate_boxes(facing: int, is_open: bool) -> Array:
	var canonical: Array
	# Outer posts are grounded (y=0..1.0) — diverges from vanilla 1.9's
	# y=5..16 because standalone gates would otherwise float. Inner
	# posts + rails keep canonical heights.
	if is_open:
		canonical = [
			[Vector3(0.0, 0.0, 0.4375), Vector3(0.125, 1.0, 0.5625)],
			[Vector3(0.875, 0.0, 0.4375), Vector3(1.0, 1.0, 0.5625)],
			# Inner posts swung to +Z edge (open hinge position).
			[Vector3(0.0, 0.375, 0.8125), Vector3(0.125, 0.9375, 0.9375)],
			[Vector3(0.875, 0.375, 0.8125), Vector3(1.0, 0.9375, 0.9375)],
			# Rails connecting outer (z=0.5625) → inner (z=0.8125), both
			# sides + both y-levels. Gate "swung 90° toward +Z".
			[Vector3(0.0, 0.375, 0.5625), Vector3(0.125, 0.5625, 0.8125)],
			[Vector3(0.0, 0.75, 0.5625), Vector3(0.125, 0.9375, 0.8125)],
			[Vector3(0.875, 0.375, 0.5625), Vector3(1.0, 0.5625, 0.8125)],
			[Vector3(0.875, 0.75, 0.5625), Vector3(1.0, 0.9375, 0.8125)],
		]
	else:
		canonical = [
			# Outer posts — full height, 2/16 wide × 2/16 deep, cell edges.
			[Vector3(0.0, 0.0, 0.4375), Vector3(0.125, 1.0, 0.5625)],
			[Vector3(0.875, 0.0, 0.4375), Vector3(1.0, 1.0, 0.5625)],
			# Inner posts — y=6..15/16, centered pair.
			[Vector3(0.375, 0.375, 0.4375), Vector3(0.5, 0.9375, 0.5625)],
			[Vector3(0.5, 0.375, 0.4375), Vector3(0.625, 0.9375, 0.5625)],
			# Lower + upper rails, two halves of the gate body.
			[Vector3(0.125, 0.375, 0.4375), Vector3(0.375, 0.5625, 0.5625)],
			[Vector3(0.125, 0.75, 0.4375), Vector3(0.375, 0.9375, 0.5625)],
			[Vector3(0.625, 0.375, 0.4375), Vector3(0.875, 0.5625, 0.5625)],
			[Vector3(0.625, 0.75, 0.4375), Vector3(0.875, 0.9375, 0.5625)],
		]
	if facing == 0 or facing == 2:
		return canonical
	var rotated: Array = []
	for box: Array in canonical:
		var a: Vector3 = box[0]
		var b: Vector3 = box[1]
		var ra := Vector3(a.z, a.y, 1.0 - a.x)
		var rb := Vector3(b.z, b.y, 1.0 - b.x)
		rotated.append(
			[
				Vector3(minf(ra.x, rb.x), minf(ra.y, rb.y), minf(ra.z, rb.z)),
				Vector3(maxf(ra.x, rb.x), maxf(ra.y, rb.y), maxf(ra.z, rb.z))
			]
		)
	return rotated


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
	# Door sprites contain transparent window/cutout texels by design.
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
# Half-slab — vanilla qj.java::a(true)=double, (false)=half. Bottom
# half of the cell (bbox 0..1, 0..0.5, 0..1). Top + bottom faces use
# stone_slab_top; the 4 side faces use stone_slab_side stretched
# vertically to half-height (the side tile has the bevel baked in so
# the stretch reads correctly). Bottom face is conditionally emitted
# based on the cell below — opaque neighbor culls it like a cube face.
# Collision is the half-height box: trimesh face soup matches the
# render quads so the player can stand on top at y+0.5.
static func _emit_slab_geometry(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	collision_faces: PackedVector3Array,
) -> void:
	var fx: float = float(x)
	var fy: float = float(y)
	var fz: float = float(z)
	var mn := Vector3(fx, fy, fz)
	var mx := Vector3(fx + 1.0, fy + 0.5, fz + 1.0)
	# Slab texture varies by variant. The stone slab has a beveled side
	# tile (stone_slab_side) baked specifically for the half-height
	# stretch; wood + cobblestone variants don't ship dedicated tiles in
	# Alpha terrain.png so they reuse a single full-cube tile on every
	# face — the half-height silhouette alone reads as a slab.
	var slab_id: int = chunk.get_block(x, y, z)
	var top_rect: Rect2
	var side_rect: Rect2
	if slab_id == Blocks.WOOD_HALF_SLAB:
		top_rect = BlockAtlas.uv_rect("planks")
		side_rect = top_rect
	elif slab_id == Blocks.COBBLESTONE_HALF_SLAB:
		top_rect = BlockAtlas.uv_rect("cobblestone")
		side_rect = top_rect
	else:
		top_rect = BlockAtlas.uv_rect("stone_slab_top")
		side_rect = BlockAtlas.uv_rect("stone_slab_side")
	var sky: int = chunk.get_sky_light(x, y, z)
	var blk: int = chunk.get_block_light(x, y, z)
	var face_light := Color(float(sky) / 15.0, float(blk) / 15.0, 0.0, 0.0)
	# Per-face: [v0, v1, v2, v3, normal, uv_rect]
	var c000 := Vector3(mn.x, mn.y, mn.z)
	var c100 := Vector3(mx.x, mn.y, mn.z)
	var c010 := Vector3(mn.x, mx.y, mn.z)
	var c110 := Vector3(mx.x, mx.y, mn.z)
	var c001 := Vector3(mn.x, mn.y, mx.z)
	var c101 := Vector3(mx.x, mn.y, mx.z)
	var c011 := Vector3(mn.x, mx.y, mx.z)
	var c111 := Vector3(mx.x, mx.y, mx.z)
	var faces: Array = [
		[c010, c011, c111, c110, Vector3.UP, top_rect],
		[c001, c000, c100, c101, Vector3.DOWN, top_rect],
		[c100, c110, c111, c101, Vector3.RIGHT, side_rect],
		[c001, c011, c010, c000, Vector3.LEFT, side_rect],
		[c101, c111, c011, c001, Vector3.BACK, side_rect],
		[c000, c010, c110, c100, Vector3.FORWARD, side_rect],
	]
	# Side face indices 2..5 emit a half-height quad (Y span 0..0.5);
	# sampling the FULL tile across that span squishes the texture 2×.
	# Vanilla samples only the BOTTOM HALF of the tile so the aspect
	# stays 1:1 — for stone_slab_side that's where the slab silhouette
	# was painted; for wood / cobblestone variants it shows the bottom
	# 8 rows of the plain tile (no visible distortion). Matches the
	# inventory-icon path in BlockMesh._build_slab.
	for fi in range(faces.size()):
		var face: Array = faces[fi]
		var base: int = verts.size()
		var fv: Vector3 = face[4]
		var rect: Rect2 = face[5]
		for i in range(4):
			verts.append(face[i])
			norms.append(fv)
		var v_top: float = rect.position.y
		var v_bot: float = rect.position.y + rect.size.y
		if fi >= 2:
			# Side face — bottom-half slice (V ∈ [mid, max]).
			v_top = rect.position.y + rect.size.y * 0.5
		uvs.append(Vector2(rect.position.x, v_bot))
		uvs.append(Vector2(rect.position.x, v_top))
		uvs.append(Vector2(rect.position.x + rect.size.x, v_top))
		uvs.append(Vector2(rect.position.x + rect.size.x, v_bot))
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)
	_emit_collision_box(collision_faces, mn, mx)


# Sign — vanilla ni.java (BlockSign). Two variants:
#   SIGN_STANDING — short central post (0.125×0.5×0.125, y 0..0.5)
#     plus a flat panel (0.875×0.5×0.125) mounted at the top of the
#     post, rotated by yaw meta. The post is a regular AABB; the
#     panel is a rotated quad pair (since 22.5° increments don't
#     align with grid axes, we compute corners after rotation).
#   SIGN_WALL — panel only, mounted flush against one cell face
#     (no post). Meta 0..3 maps to -Z / +Z / -X / +X (chest-style
#     convention). Since these are axis-aligned, no rotation math.
# Selection collision wraps the whole bbox so right-click / mine-aim
# can target signs without worrying about the rotated panel offset.
static func _emit_sign_geometry(
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
	var id: int = chunk.get_block(x, y, z)
	var meta: int = chunk.get_block_meta_unchecked(x, y, z)
	var fx: float = float(x)
	var fy: float = float(y)
	var fz: float = float(z)
	var rect: Rect2 = BlockAtlas.uv_rect("planks")
	var sky: int = chunk.get_sky_light(x, y, z)
	var blk: int = chunk.get_block_light(x, y, z)
	var face_color := Color(float(sky) / 15.0, float(blk) / 15.0, 0.0, 0.0)
	if id == Blocks.SIGN_STANDING:
		# Detect fence support — if the cell directly below is a fence,
		# the standing sign should render with a shorter post so it
		# stacks cleanly on the fence post (visible fence top is at
		# fence_cell.y + 1.0, which is sign_cell.y, so a normal 0.5 m
		# post would extend further up than needed).
		var on_fence: bool = chunk.get_block(x, y - 1, z) == Blocks.FENCE
		_emit_standing_sign(
			fx,
			fy,
			fz,
			meta,
			rect,
			face_color,
			verts,
			norms,
			uvs,
			colors,
			indices,
			plant_faces,
			on_fence
		)
	else:
		_emit_wall_sign(
			chunk,
			x,
			y,
			z,
			fx,
			fy,
			fz,
			meta,
			rect,
			face_color,
			verts,
			norms,
			uvs,
			colors,
			indices,
			plant_faces
		)


# Post + rotated panel. Vanilla ni.java yaw meta is 16 increments
# (0..15 → 0°..337.5°). Standing on a fence post; panel mounted on
# top at the rotated angle.
# gdlint: disable=function-arguments-number
static func _emit_standing_sign(
	fx: float,
	fy: float,
	fz: float,
	meta: int,
	rect: Rect2,
	face_color: Color,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array,
	on_fence: bool = false
) -> void:
	# Fence-mounted standing sign has a SHORTER post (0.25 m instead of
	# 0.5 m) so the panel sits lower on the fence — reads as "sign on
	# top of fence" rather than "sign on a tall stand far above fence".
	# Panel y range also shifts down by 0.25 m to stay connected to the
	# post top.
	var post_height: float = 0.25 if on_fence else 0.5
	# Post AABB — centered XZ on the cell (0.5±0.0625).
	var post_mn := Vector3(fx + 0.4375, fy, fz + 0.4375)
	var post_mx := Vector3(fx + 0.5625, fy + post_height, fz + 0.5625)
	_emit_box(verts, norms, uvs, colors, indices, post_mn, post_mx, rect, face_color)
	# Panel — 0.875 wide × 0.5 tall × 0.125 thick. Normal sign: y=[0.5,
	# 1.0] (centered at 0.75). Fence-mounted: y=[0.25, 0.75] (centered
	# at 0.5), so it sits on the shorter post.
	var yaw_rad: float = float(meta) * (TAU / 16.0)
	var cs: float = cos(yaw_rad)
	var sn: float = sin(yaw_rad)
	var half_w: float = 0.4375
	var half_t: float = 0.0625
	var y0: float = post_height  # panel bottom — sits on post top
	var y1: float = post_height + 0.5  # panel top
	# 8 corners — index bits xtb: x=±half_w, t=±half_t, b=top/bottom.
	# Rotate (lx, lz) around Y by yaw_rad → (rx, rz). Translate to
	# (fx + 0.5 + rx, fy + ly, fz + 0.5 + rz).
	var corners: Array[Vector3] = []
	corners.resize(8)
	var i: int = 0
	for sx in [-half_w, half_w]:
		for sz in [-half_t, half_t]:
			for sy in [y0, y1]:
				var rx: float = sx * cs - sz * sn
				var rz: float = sx * sn + sz * cs
				corners[i] = Vector3(fx + 0.5 + rx, fy + sy, fz + 0.5 + rz)
				i += 1
	# Corners indexed: bit 2 = x-sign, bit 1 = z-sign, bit 0 = top.
	# c[i] = corner with (x = bit2*2-1, z = bit1*2-1, y = bit0 ? top : bot)
	# Build 6 quads with the same vertex layout convention as _emit_box.
	# Face order: +Y top, -Y bottom, +X front, -X back, +Z right, -Z left.
	# (After rotation "front" is whichever side the panel faces.)
	var c000: Vector3 = corners[0]  # -x, -z, bottom
	var c001: Vector3 = corners[1]  # -x, -z, top
	var c010: Vector3 = corners[2]  # -x, +z, bottom
	var c011: Vector3 = corners[3]  # -x, +z, top
	var c100: Vector3 = corners[4]  # +x, -z, bottom
	var c101: Vector3 = corners[5]  # +x, -z, top
	var c110: Vector3 = corners[6]  # +x, +z, bottom
	var c111: Vector3 = corners[7]  # +x, +z, top
	# Normals after rotation: front=(-sin, 0, +cos), right=(+cos, 0, +sin)
	var n_front := Vector3(-sn, 0, cs)
	var n_right := Vector3(cs, 0, sn)
	# Back face (-Z LOCAL) UV override. Default UV order is non-V-flipped
	# (texture top-left at FRONT quad's top-left). Back quad's vertex
	# order [top-L, top-R, bot-R, bot-L from −Z viewer] needs UVs
	# matched to THOSE corners so the texture reads upright + non-
	# mirrored from behind.
	var back_uvs := PackedVector2Array(
		[
			Vector2(rect.position.x, rect.position.y),
			Vector2(rect.position.x + rect.size.x, rect.position.y),
			Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y),
			Vector2(rect.position.x, rect.position.y + rect.size.y),
		]
	)
	# Quads: each is [v0, v1, v2, v3, normal] in winding-consistent order.
	# Optional 6th element (PackedVector2Array) overrides the default
	# UV pattern for faces where the standard order produces a rotated
	# or mirrored texture.
	var quads: Array = [
		[c001, c011, c111, c101, Vector3.UP],
		[c000, c100, c110, c010, Vector3.DOWN],
		[c001, c101, c100, c000, -n_front, back_uvs],  # -Z local face
		[c011, c010, c110, c111, n_front],  # +Z local face
		[c101, c111, c110, c100, n_right],  # +X local face
		[c001, c000, c010, c011, -n_right],  # -X local face
	]
	_emit_rotated_quads(verts, norms, uvs, colors, indices, quads, rect, face_color)
	# Collision wraps the whole sign (post + panel) as an axis-aligned
	# bbox — close enough for selection, vanilla does the same on the
	# rotated panel.
	var sel_mn := Vector3(fx, fy, fz)
	var sel_mx := Vector3(fx + 1.0, fy + 1.0, fz + 1.0)
	_emit_collision_box(plant_faces, sel_mn, sel_mx)


# Wall sign — panel mounted on one of 4 axis-aligned faces. Meta:
# 0 = panel on -Z face (normal -Z, sign visible from -Z side)
# 1 = panel on +Z face
# 2 = panel on -X face
# 3 = panel on +X face
# gdlint: disable=function-arguments-number
static func _emit_wall_sign(
	chunk: Chunk,
	x: int,
	y: int,
	z: int,
	fx: float,
	fy: float,
	fz: float,
	meta: int,
	rect: Rect2,
	face_color: Color,
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	plant_faces: PackedVector3Array,
) -> void:
	# Panel: 0.875 wide × 0.5 tall × 0.125 thick. Centered on the
	# mounted face at y=0.25..0.75 (vanilla puts wall signs slightly
	# lower than the cell top — eye-height for the player).
	var half_w: float = 0.4375
	var thick: float = 0.125
	var y0: float = 0.25
	var y1: float = 0.75
	var mn: Vector3
	var mx: Vector3
	# Fence-attached wall sign: vanilla mounts the panel at the cell face
	# (at distance 0 from the cell edge) but the fence post is 0.375 m
	# INSIDE the support cell, so the panel hangs in mid-air relative to
	# the visible post. We detect "support is a fence" here and offset
	# the panel by 0.375 m INTO the support cell so its back face touches
	# the fence post directly. Cross-chunk-edge fence support isn't
	# detected (chunk.get_block returns AIR for OOB), so a sign placed at
	# the very edge of a chunk against a fence in the neighbour chunk
	# will still float — rare enough to defer.
	var off: float = 0.375
	var fence_offset: Vector3 = Vector3.ZERO
	match meta:
		0:  # -Z face — panel hangs on the +Z side of the support, facing -Z
			mn = Vector3(fx + 0.5 - half_w, fy + y0, fz + 1.0 - thick)
			mx = Vector3(fx + 0.5 + half_w, fy + y1, fz + 1.0)
			if chunk.get_block(x, y, z + 1) == Blocks.FENCE:
				fence_offset = Vector3(0, 0, off)
		1:  # +Z face
			mn = Vector3(fx + 0.5 - half_w, fy + y0, fz)
			mx = Vector3(fx + 0.5 + half_w, fy + y1, fz + thick)
			if chunk.get_block(x, y, z - 1) == Blocks.FENCE:
				fence_offset = Vector3(0, 0, -off)
		2:  # -X face
			mn = Vector3(fx + 1.0 - thick, fy + y0, fz + 0.5 - half_w)
			mx = Vector3(fx + 1.0, fy + y1, fz + 0.5 + half_w)
			if chunk.get_block(x + 1, y, z) == Blocks.FENCE:
				fence_offset = Vector3(off, 0, 0)
		_:  # +X face (meta 3)
			mn = Vector3(fx, fy + y0, fz + 0.5 - half_w)
			mx = Vector3(fx + thick, fy + y1, fz + 0.5 + half_w)
			if chunk.get_block(x - 1, y, z) == Blocks.FENCE:
				fence_offset = Vector3(-off, 0, 0)
	# Visual mesh at the offset position (touching the fence post).
	# Collision / selection AABB stays at the ORIGINAL cell-face
	# position so the player's raycast hits the sign before the fence
	# collider behind it — otherwise the cursor always selects the
	# fence and the sign can never be right-clicked to edit.
	var sel_mn: Vector3 = mn
	var sel_mx: Vector3 = mx
	mn += fence_offset
	mx += fence_offset
	_emit_box(verts, norms, uvs, colors, indices, mn, mx, rect, face_color)
	_emit_collision_box(plant_faces, sel_mn, sel_mx)


# Helper to emit 6 quads with a per-quad normal (used by rotated
# standing-sign panel where face axes don't align with world axes).
static func _emit_rotated_quads(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	colors: PackedColorArray,
	indices: PackedInt32Array,
	quads: Array,
	rect: Rect2,
	face_light: Color
) -> void:
	for q in quads:
		var base: int = verts.size()
		var nv: Vector3 = q[4]
		for vi in range(4):
			verts.append(q[vi])
			norms.append(nv)
		# Optional per-quad UV override — used for faces (like the
		# standing-sign back) where the default winding-order UV pattern
		# rotates / mirrors the texture relative to the front face.
		if q.size() > 5 and q[5] is PackedVector2Array:
			var custom_uvs: PackedVector2Array = q[5]
			for vi in range(4):
				uvs.append(custom_uvs[vi])
		else:
			# Non-V-flipped UV order — texture row 0 (light pixel) lands
			# at the panel top vertex so standing signs show their wood
			# in the same orientation as wall signs + the edit-screen
			# preview (matching ask: "preview wood matches in-game").
			uvs.append(Vector2(rect.position.x, rect.position.y))
			uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
			uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
			uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		colors.append(face_light)
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)


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
	var face_color := Color(float(sky) / 15.0, float(blk) / 15.0, 0.0, 0.0)
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
	# Crossed sprites contain transparent texels by design.
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
	# _emit_torch_box maps only the opaque torch strip onto tight geometry;
	# unlike crossed sprites, it must never enter the atlas discard path.
	var face_light := Color(sky_n, blk_n, 0.0, 0.0)
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
	# Floor torches sit FLUSH with the ground. ob.java:135 gives the floor
	# variant bounds of (0.4, 0.0, 0.4)..(0.6, 0.6, 0.6) — bottom at y=0 —
	# and `Blocks.selection_aabb` already encodes that. The render used
	# +0.125, so the pillar hovered 2/16 above its own selection box and
	# above the block it stands on: visibly floating.
	# Vertical placement, from vanilla's renderBlockTorch call sites:
	# a floor torch is rendered at `d1` unchanged, a wall torch at
	# `d1 + 0.2`. Ours used +0.125 and +0.5, which floated the floor torch
	# above the ground and pushed the wall torch up out of its own
	# selection box (ob.java:122-136 puts wall bounds at y 0.2..0.8).
	var cy_off: float = float(y) + (0.2 if is_wall else 0.0)
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


# Emit a flat 1-pixel-thick rail quad sitting on top of the supporting
# block. Vanilla rails (qe.java) lie 1/16 m above the block's top face
# so the player walks ON TOP of them (the texture is alpha-tested, so
# the rail's outer "rectangle" sits over the support block visibly).
# Meta encodes orientation 0..9 per Blocks.RAIL comments; the texture
# rotates per direction. Stage-1 scope: flat orientations only
# (0 = N-S, 1 = E-W). Ascending (2..5) and curves (6..9) are valid
# meta values but render identically to flat straight here — physics
# in the minecart entity is the source of truth for slope/curve.
static func _emit_rail_geometry(
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
	var meta: int = chunk.get_block_meta(x, y, z)
	var is_turn: bool = meta >= 6 and meta <= 9
	var tex_name: String = "rail_turn" if is_turn else "rail"
	var rect: Rect2 = BlockAtlas.uv_rect(tex_name)
	# Top of the supporting block + small lift so the rail doesn't z-
	# fight the block's top face. Vanilla qe.java lifts by 1/16; we
	# use 1/16 too (matches the visible rail-on-block look in screenshots).
	var rail_y: float = float(y) + 1.0 / 16.0
	var x0: float = float(x)
	var z0: float = float(z)
	var x1: float = x0 + 1.0
	var z1: float = z0 + 1.0
	# Light from the cell ABOVE the rail's support (= the rail's own
	# cell, since the rail lives inside the AIR cell above the support).
	var skylight: float = float(chunk.get_sky_light(x, y, z)) / 15.0
	var blocklight: float = float(chunk.get_block_light(x, y, z)) / 15.0
	var light_color := Color(skylight, blocklight, 0.0, 1.0)
	# 4 corners of the rail quad. CCW from above (+Y looking down).
	# Ascending metas (2-5) tilt the plane so one edge is at rail_y + 1
	# (cell up) and the opposite edge stays at rail_y. The plane reads
	# as an actual ramp instead of a flat tile — matches vanilla
	# qe.java rendering.
	var nw_y: float = rail_y
	var ne_y: float = rail_y
	var se_y: float = rail_y
	var sw_y: float = rail_y
	match meta:
		2:  # ascending east — +X edge raised
			ne_y = rail_y + 1.0
			se_y = rail_y + 1.0
		3:  # ascending west — -X edge raised
			nw_y = rail_y + 1.0
			sw_y = rail_y + 1.0
		4:  # ascending north — -Z edge raised
			nw_y = rail_y + 1.0
			ne_y = rail_y + 1.0
		5:  # ascending south — +Z edge raised
			sw_y = rail_y + 1.0
			se_y = rail_y + 1.0
	var v_nw := Vector3(x0, nw_y, z0)  # -X, -Z
	var v_ne := Vector3(x1, ne_y, z0)  # +X, -Z
	var v_se := Vector3(x1, se_y, z1)  # +X, +Z
	var v_sw := Vector3(x0, sw_y, z1)  # -X, +Z
	# UVs — orient the rail texture so the visible bend / planks line up
	# with the meta direction. 4 rotations covered:
	#   straight N-S (meta 0): base orientation (texture U along X)
	#   straight E-W (meta 1) + X-ascending (2, 3): 90° CW
	#   curve meta 6 (S+E): base
	#   curve meta 7 (S+W): 90° CW
	#   curve meta 8 (N+W): 180°
	#   curve meta 9 (N+E): 270° CW (90° CCW)
	var u0: float = rect.position.x
	var v0: float = rect.position.y
	var u1: float = rect.position.x + rect.size.x
	var v1: float = rect.position.y + rect.size.y
	# Each meta → number of 90° CW rotations to apply to the UVs (0..3).
	var rot: int = 0
	match meta:
		0:
			rot = 0  # N-S straight
		1, 2, 3:
			rot = 1  # E-W straight + X-ascending
		4, 5:
			rot = 0  # Z-ascending — Z axis already matches the texture
		6:
			rot = 0  # S+E curve (wraps SE corner)
		7:
			rot = 1  # S+W curve (wraps SW corner)
		8:
			rot = 2  # N+W curve (wraps NW corner)
		9:
			rot = 3  # N+E curve (wraps NE corner)
	# Apply CW rotation to the UV corners. Each step rotates the
	# texture 90° clockwise as seen by the player looking down.
	var corners: Array = [
		Vector2(u0, v0),  # nw
		Vector2(u1, v0),  # ne
		Vector2(u1, v1),  # se
		Vector2(u0, v1),  # sw
	]
	# Rotate by `rot` positions (each = 90° CW). Direction matters —
	# shifting the corners array FORWARD (remove-first-append-last)
	# rotates the visible texture CCW. Shifting BACKWARD (pop-last-
	# insert-first) rotates CW, which is what the per-meta rot values
	# assume.
	for _i in range(rot):
		var last: Vector2 = corners[corners.size() - 1]
		corners.remove_at(corners.size() - 1)
		corners.insert(0, last)
	var uv_nw: Vector2 = corners[0]
	var uv_ne: Vector2 = corners[1]
	var uv_se: Vector2 = corners[2]
	var uv_sw: Vector2 = corners[3]
	# Top face (visible from above). Index order [0, 2, 1, 0, 3, 2]
	# gives triangles (nw, se, ne) and (nw, sw, se), both with cross-
	# product winding-normal = +Y, which means cull_back keeps them
	# visible when the camera looks down at the rail.
	var base: int = verts.size()
	verts.append(v_nw)
	verts.append(v_ne)
	verts.append(v_se)
	verts.append(v_sw)
	norms.append(Vector3.UP)
	norms.append(Vector3.UP)
	norms.append(Vector3.UP)
	norms.append(Vector3.UP)
	uvs.append(uv_nw)
	uvs.append(uv_ne)
	uvs.append(uv_se)
	uvs.append(uv_sw)
	colors.append(light_color)
	colors.append(light_color)
	colors.append(light_color)
	colors.append(light_color)
	indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array)
	# Bottom face (visible from below). Reverse winding so cull_back
	# renders it from a camera looking up at the rail (e.g., from under
	# a glass roof or while swimming directly below).
	var base_b: int = verts.size()
	verts.append(v_nw)
	verts.append(v_ne)
	verts.append(v_se)
	verts.append(v_sw)
	norms.append(Vector3.DOWN)
	norms.append(Vector3.DOWN)
	norms.append(Vector3.DOWN)
	norms.append(Vector3.DOWN)
	uvs.append(uv_nw)
	uvs.append(uv_ne)
	uvs.append(uv_se)
	uvs.append(uv_sw)
	colors.append(light_color)
	colors.append(light_color)
	colors.append(light_color)
	colors.append(light_color)
	# Reversed order vs the top face → winding normal flips to -Y.
	indices.append_array(
		[base_b, base_b + 1, base_b + 2, base_b, base_b + 2, base_b + 3] as PackedInt32Array
	)
	# Selection box on plant_faces (layer 2) — player raycast hits it
	# for break/highlight but player body (mask layer 1) passes through.
	# Use a thin 1/16-tall box matching the visible rail plane so the
	# raycast has a proper 3D target instead of an infinitely-thin
	# quad (which the cursor often misses).
	var sel_aabb: AABB = Blocks.selection_aabb(Blocks.RAIL, meta)
	var sel_min := Vector3(
		float(x) + sel_aabb.position.x,
		float(y) + sel_aabb.position.y,
		float(z) + sel_aabb.position.z
	)
	var sel_max: Vector3 = sel_min + sel_aabb.size
	_emit_collision_box(plant_faces, sel_min, sel_max)


# Bed — Beta 1.3 BlockBed (bd.java). A 1×9/16×1 box per half (FOOT or
# HEAD), with per-face textures picked from the bed atlas slots. The
# half that the player is looking at determines which textures load
# (foot vs head); meta encodes facing 0..3 so the END texture lands on
# the correct outer face and the INTERNAL face (the one that meets the
# other half) is skipped to avoid coplanar z-fighting between the two
# half-meshes.
#
# Vanilla refs:
#   bd.java::a(IBlockAccess,int,int,int,int) — per-face tile index
#   bd.java::a(World,...,EntityHuman) — sleep trigger (handled in
#     interaction.gd, not here)
#
# Facing convention (matches BlockDirectional / chest):
#   0 = +Z (south) — head is at FOOT.z + 1
#   1 = -X (west)  — head is at FOOT.x - 1
#   2 = -Z (north) — head is at FOOT.z - 1
#   3 = +X (east)  — head is at FOOT.x + 1
static func _emit_bed_geometry(
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
	# Bed mesh — verified against Bukkit/mc-dev BlockBed.java + a pixel
	# inspection of the vendored Mojang 1.6.4 bed_*_top / bed_*_side /
	# bed_*_end textures. Critical facts:
	#
	#   1. bd.java::a[][] = {{0,1},{-1,0},{0,-1},{1,0}} — meta 0..3 →
	#      foot→head offset (+Z, -X, -Z, +X). Matches our placement
	#      code's _bed_head_offset.
	#   2. bed_*_top textures: pillow / leg-end art at the HIGH-U side
	#      of the image (u=8..15 = right half). Wood frame at LOW U.
	#      U axis runs ALONG the bed length (foot→head = +U direction).
	#      V axis runs ACROSS the bed width.
	#   3. bed_*_side / bed_*_end textures: bed silhouette in rows 7..15
	#      (bottom 9 rows). Rows 0..6 are alpha=0 — those are above the
	#      bed in vanilla rendering. Sampling them = visible "gap" at
	#      the top of the side faces. Side V is clamped to [v_bed_top,
	#      v1] = [v0 + 7/16·dv, v1] so only the bed-art rows render.
	#   4. Internal face (where the two halves meet) is skipped so the
	#      pair seam doesn't z-fight between coplanar half-meshes.
	var id: int = chunk.get_block(x, y, z)
	var meta: int = chunk.get_block_meta_unchecked(x, y, z)
	var facing: int = meta & 3
	var is_head: bool = id == Blocks.BED_HEAD
	var bed_height: float = 9.0 / 16.0
	var mn := Vector3(float(x), float(y), float(z))
	var mx := Vector3(float(x) + 1.0, float(y) + bed_height, float(z) + 1.0)
	# Foot→head direction in cell coords (vanilla bd.java::a[]).
	var head_dir: Vector3i = _bed_head_dir_for_facing(facing)
	# Internal face normal: FOOT points +head_dir (toward head),
	# HEAD points -head_dir (toward foot). Skipped to avoid z-fight at
	# the half-pair seam.
	var internal_normal: Vector3i = -head_dir if is_head else head_dir
	var internal_face_idx: int = _face_idx_for_normal(internal_normal)
	# End face normal: outer end of this half. FOOT = -head_dir (legs
	# end); HEAD = +head_dir (pillow end). Carries the END texture.
	var end_normal: Vector3i = head_dir if is_head else -head_dir
	var end_face_idx: int = _face_idx_for_normal(end_normal)
	var top_tex: String = "bed_head_top" if is_head else "bed_foot_top"
	var side_tex: String = "bed_head_side" if is_head else "bed_foot_side"
	var end_tex: String = "bed_head_end" if is_head else "bed_foot_end"
	var bottom_tex: String = "planks"
	# 8 box corners.
	var c000 := Vector3(mn.x, mn.y, mn.z)
	var c100 := Vector3(mx.x, mn.y, mn.z)
	var c010 := Vector3(mn.x, mx.y, mn.z)
	var c110 := Vector3(mx.x, mx.y, mn.z)
	var c001 := Vector3(mn.x, mn.y, mx.z)
	var c101 := Vector3(mx.x, mn.y, mx.z)
	var c011 := Vector3(mn.x, mx.y, mx.z)
	var c111 := Vector3(mx.x, mx.y, mx.z)
	var sky: int = chunk.get_sky_light(x, y, z)
	var blk: int = chunk.get_block_light(x, y, z)
	# Bed side/end textures retain transparent pixels around the legs even
	# after V is cropped to the visible 9-row silhouette.
	var face_light := Color(float(sky) / 15.0, float(blk) / 15.0, 0.0, 1.0)
	# Face table — index matches the dir convention 0=+Y..5=-Z.
	var face_geom: Array = [
		[c010, c011, c111, c110, Vector3.UP],  # 0 +Y top
		[c001, c000, c100, c101, Vector3.DOWN],  # 1 -Y bottom
		[c100, c110, c111, c101, Vector3.RIGHT],  # 2 +X
		[c001, c011, c010, c000, Vector3.LEFT],  # 3 -X
		[c101, c111, c011, c001, Vector3.BACK],  # 4 +Z
		[c000, c010, c110, c100, Vector3.FORWARD],  # 5 -Z
	]
	for face_idx in range(6):
		if face_idx == internal_face_idx:
			continue
		var face: Array = face_geom[face_idx]
		var is_top: bool = face_idx == 0
		var is_bottom: bool = face_idx == 1
		var is_end: bool = face_idx == end_face_idx
		var tex_name: String
		if is_top:
			tex_name = top_tex
		elif is_bottom:
			tex_name = bottom_tex
		elif is_end:
			tex_name = end_tex
		else:
			tex_name = side_tex
		var rect: Rect2 = BlockAtlas.uv_rect(tex_name)
		var base: int = verts.size()
		var fv: Vector3 = face[4]
		for i in range(4):
			var vert: Vector3 = face[i]
			verts.append(vert)
			norms.append(fv)
			uvs.append(_bed_vertex_uv(vert, mn, mx, head_dir, face_idx, rect, is_top, is_bottom))
			colors.append(face_light)
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)
	_emit_collision_box(collision_faces, mn, mx)


# Maps a ±X / ±Y / ±Z normal to the face index used by face_geom
# (0=+Y, 1=-Y, 2=+X, 3=-X, 4=+Z, 5=-Z). Used by the bed mesher to
# compute internal-face / end-face indices from the head direction.
static func _face_idx_for_normal(n: Vector3i) -> int:
	if n.y > 0:
		return 0
	if n.y < 0:
		return 1
	if n.x > 0:
		return 2
	if n.x < 0:
		return 3
	if n.z > 0:
		return 4
	return 5


# Foot→head offset for a meta facing 0..3, as a Vector3i. Mirrors the
# vanilla bd.java::a[] table. Separate from the Vector3i variant in
# interaction.gd because that one is an instance method (Node3D access
# in _try_place_bed); the mesher needs a static for chunk-thread work.
static func _bed_head_dir_for_facing(facing: int) -> Vector3i:
	match facing:
		0:
			return Vector3i(0, 0, 1)
		1:
			return Vector3i(-1, 0, 0)
		2:
			return Vector3i(0, 0, -1)
		_:
			return Vector3i(1, 0, 0)


# Per-vertex UV picker for the bed mesh. Computes the UV from the
# vertex's world position rather than a per-(facing, face_idx) table —
# the position-driven derivation auto-handles all 4 facings without
# hand-rolled rotation tables.
#
# Three UV regimes:
#   * TOP face — U along bed length (HIGH U at +head_dir end, where the
#     pillow / leg-end art sits in the source texture). V across bed
#     width (one stable convention so both halves' top textures align
#     at the seam).
#   * BOTTOM face — planks tile, UV doesn't carry orientation.
#   * SIDE / END face — V clamped to the bed-art rows ([v_bed_top, v1]
#     in atlas coords, since the top 7/16 of the source texture is
#     alpha-0 above-the-bed empty space). U along bed length for side
#     faces (perpendicular to bed length axis), or across bed width
#     for the end face (parallel to the bed length axis).
static func _bed_vertex_uv(
	vert: Vector3,
	mn: Vector3,
	mx: Vector3,
	head_dir: Vector3i,
	face_idx: int,
	rect: Rect2,
	is_top: bool,
	is_bottom: bool
) -> Vector2:
	var u0: float = rect.position.x
	var v0: float = rect.position.y
	var u1: float = rect.position.x + rect.size.x
	var v1: float = rect.position.y + rect.size.y
	if is_bottom:
		# Planks tile — pick corners by world XZ position. No bed-aware
		# orientation needed here.
		var bu: float = u1 if vert.x > (mn.x + mx.x) * 0.5 else u0
		var bv: float = v1 if vert.z > (mn.z + mx.z) * 0.5 else v0
		return Vector2(bu, bv)
	# Is this vertex on the +head_dir end of the cell? Sign-aware
	# threshold against the cell center along the head axis.
	var head_axis_is_x: bool = head_dir.x != 0
	var along_at_high: bool
	if head_axis_is_x:
		along_at_high = (
			(vert.x > (mn.x + mx.x) * 0.5) if head_dir.x > 0 else (vert.x < (mn.x + mx.x) * 0.5)
		)
	else:
		along_at_high = (
			(vert.z > (mn.z + mx.z) * 0.5) if head_dir.z > 0 else (vert.z < (mn.z + mx.z) * 0.5)
		)
	# Is this vertex on the +width side? Width axis is perpendicular to
	# head axis. Stable convention: +X if bed is along Z, +Z if along X.
	var width_at_high: bool
	if head_axis_is_x:
		width_at_high = vert.z > (mn.z + mx.z) * 0.5
	else:
		width_at_high = vert.x > (mn.x + mx.x) * 0.5
	if is_top:
		var tu: float = u1 if along_at_high else u0
		var tv: float = v1 if width_at_high else v0
		return Vector2(tu, tv)
	# Side / end face. V clamped to bed-art region: top vertex (Y high)
	# maps to v_bed_top (= v0 + 7/16·dv); bottom vertex maps to v1.
	var v_bed_top: float = v0 + (7.0 / 16.0) * (v1 - v0)
	var v_out: float = v_bed_top if vert.y > (mn.y + mx.y) * 0.5 else v1
	# Distinguish SIDE (perp to bed length, normal axis ≠ head axis)
	# from END (parallel to bed length, normal axis = head axis).
	var face_normal_is_x: bool = face_idx == 2 or face_idx == 3
	var u_out: float
	if face_normal_is_x == head_axis_is_x:
		# END face — U across bed width.
		u_out = u1 if width_at_high else u0
	else:
		# SIDE face — U along bed length.
		u_out = u1 if along_at_high else u0
	return Vector2(u_out, v_out)


# Lever (pl.java render type 12). Two boxes: a cobblestone base plate
# flush against the mount face, and the handle sticking out of it. The
# handle tilts to the opposite side when the powered bit flips, which is
# the only visual feedback Alpha gives for lever state — there's no
# texture swap, so getting the tilt right matters.
#
# Meta layout (Redstone.MOUNT_*): bits 0-2 = mount face, bit 3 = on.
static func _emit_lever_geometry(
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
	var meta: int = chunk.get_block_meta(x, y, z)
	var mount: int = meta & 7
	var powered: bool = (meta & 8) != 0
	var base_rect: Rect2 = BlockAtlas.uv_rect("cobblestone")
	# The handle samples ONLY the stick column of the lever tile, not the
	# whole 16×16 sprite. The tile is 20 opaque pixels — a 2-wide, 10-tall
	# stick at x[7..8], y[6..15] — and everything around it is
	# transparent. Stretched across the handle box with the shader's
	# discard path off (see face_light below), that transparency renders
	# as solid black and the lever reads as a fat dark slab with a stick
	# buried in it.
	#
	# Identical sub-rect to `BlockMesh._build_torch`, which faces exactly
	# the same layout: both are a stick centred in the middle two columns.
	var handle_tile: Rect2 = BlockAtlas.uv_rect_for(Blocks.LEVER, BlockAtlas.FACE_SIDE)
	var handle_rect := Rect2(
		handle_tile.position.x + handle_tile.size.x * (7.0 / 16.0),
		handle_tile.position.y + handle_tile.size.y * (6.0 / 16.0),
		handle_tile.size.x * (2.0 / 16.0),
		handle_tile.size.y * (10.0 / 16.0)
	)
	# Light from this cell — the lever never fills it, so its own cell's
	# light is the right sample (same choice as the torch/rail paths).
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 0.0)
	var o := Vector3(float(x), float(y), float(z))
	# Base plate: 6/16 × 8/16 × 3/16, pressed against the mount face.
	var b_min: Vector3
	var b_max: Vector3
	match mount:
		Redstone.MOUNT_WEST_WALL:
			b_min = Vector3(0.0, 0.25, 0.3125)
			b_max = Vector3(0.1875, 0.75, 0.6875)
		Redstone.MOUNT_EAST_WALL:
			b_min = Vector3(0.8125, 0.25, 0.3125)
			b_max = Vector3(1.0, 0.75, 0.6875)
		Redstone.MOUNT_NORTH_WALL:
			b_min = Vector3(0.3125, 0.25, 0.0)
			b_max = Vector3(0.6875, 0.75, 0.1875)
		Redstone.MOUNT_SOUTH_WALL:
			b_min = Vector3(0.3125, 0.25, 0.8125)
			b_max = Vector3(0.6875, 0.75, 1.0)
		Redstone.MOUNT_FLOOR_ALT:
			# Second floor rotation — base runs along X instead of Z.
			b_min = Vector3(0.25, 0.0, 0.375)
			b_max = Vector3(0.75, 0.1875, 0.625)
		_:
			b_min = Vector3(0.375, 0.0, 0.25)
			b_max = Vector3(0.625, 0.1875, 0.75)
	_emit_box(verts, norms, uvs, colors, indices, o + b_min, o + b_max, base_rect, face_light)
	# Handle — a ROTATED stick, matching bk.java:147-192 rather than the
	# axis-aligned two-position box that used to stand in for it. Vanilla
	# tilts the model ±40° (0.69813174 rad) about X with a ∓1/16 nudge
	# along Z, then applies the mount transform. The stick itself is
	# 1/16 × 1/16 × 10/16 — exactly the 2×10 opaque column in the tile.
	var lever_on: bool = powered
	var tilt: float = 0.69813174 if lever_on else -0.69813174
	var nudge: float = -0.0625 if lever_on else 0.0625
	var hw: float = 0.0625
	var hh: float = 0.625
	var local: Array[Vector3] = [
		Vector3(-hw, 0.0, -hw),
		Vector3(hw, 0.0, -hw),
		Vector3(hw, 0.0, hw),
		Vector3(-hw, 0.0, hw),
		Vector3(-hw, hh, -hw),
		Vector3(hw, hh, -hw),
		Vector3(hw, hh, hw),
		Vector3(-hw, hh, hw),
	]
	# Yaw per wall mount — bk.java:174-183. Our MOUNT_* ids share vanilla's
	# numbering (1 = -X wall … 4 = +Z wall), so the table maps straight
	# across.
	# Derived from the transform rather than copied from bk.java's n6
	# table, because vanilla's mount numbering and ours agree on the power
	# model but not obviously on Z sign. After `y -= 0.375` and the 90°
	# tip, the stick lies along −Z with its root at z = −0.375; a yaw of θ
	# sends that root to (0.375·sinθ, ·, −0.375·cosθ) + 0.5. So:
	#   θ = 0     → z 0.125, the −Z wall
	#   θ = π     → z 0.875, the +Z wall
	#   θ = +π/2  → x 0.875, the +X wall
	#   θ = −π/2  → x 0.125, the −X wall
	# which is what puts the handle's root inside its own base plate.
	# Every entry MEASURED, not derived — an earlier version of this table
	# reasoned about Godot's rotation sign and got the Z pair backwards;
	# fixing those from a probe while leaving X on the same unchecked
	# assumption left the other two wrong. `test_the_lever_handle_roots_
	# in_its_own_base` now pins all four.
	#
	# Godot's `rotated(UP, θ)` sends the post-tip root at (0, ·, −0.375)
	# to (−0.375·sinθ, ·, −0.375·cosθ), so +π/2 lands on −X and −π/2 on +X.
	var wall_yaw: Dictionary = {
		Redstone.MOUNT_WEST_WALL: PI * 0.5,
		Redstone.MOUNT_EAST_WALL: -PI * 0.5,
		Redstone.MOUNT_NORTH_WALL: 0.0,
		Redstone.MOUNT_SOUTH_WALL: PI,
	}
	var corners: Array[Vector3] = []
	for c: Vector3 in local:
		var v: Vector3 = c + Vector3(0.0, 0.0, nudge)
		v = v.rotated(Vector3.RIGHT, tilt)
		if mount == Redstone.MOUNT_FLOOR_ALT:
			v = v.rotated(Vector3.UP, PI * 0.5)
		if mount < Redstone.MOUNT_FLOOR:
			# Wall mounts tip the whole stick horizontal, then spin it to
			# face out from its wall.
			v.y -= 0.375
			v = v.rotated(Vector3.RIGHT, PI * 0.5)
			v = v.rotated(Vector3.UP, float(wall_yaw.get(mount, 0.0)))
			v += Vector3(0.5, 0.5, 0.5)
		else:
			v += Vector3(0.5, 0.125, 0.5)
		corners.append(o + v)
	# Six faces of the rotated box, wound to match `_emit_box`.
	var handle_faces: Array = [
		[corners[4], corners[7], corners[6], corners[5], Vector3.UP],
		[corners[3], corners[0], corners[1], corners[2], Vector3.DOWN],
		[corners[1], corners[5], corners[6], corners[2], Vector3.RIGHT],
		[corners[3], corners[7], corners[4], corners[0], Vector3.LEFT],
		[corners[2], corners[6], corners[7], corners[3], Vector3.BACK],
		[corners[0], corners[4], corners[5], corners[1], Vector3.FORWARD],
	]
	# V-FLIP. `_emit_rotated_quads` sends corner0 to (u0, v0) — the tile's
	# TOP row — and the side faces above start at the stick's ROOT. The
	# lever tile is grey for its top two rows (the cap) and wood for the
	# eight below (the shaft), so without flipping, the root comes out
	# grey and the tip wooden: upside down. MC's convention puts a box's
	# top edge at v0, which is what puts the grey cap on the tip.
	var hu0: float = handle_rect.position.x
	var hv0: float = handle_rect.position.y
	var hu1: float = handle_rect.position.x + handle_rect.size.x
	var hv1: float = handle_rect.position.y + handle_rect.size.y
	var handle_uvs := PackedVector2Array(
		[Vector2(hu0, hv1), Vector2(hu0, hv0), Vector2(hu1, hv0), Vector2(hu1, hv1)]
	)
	for face: Array in handle_faces:
		face.append(handle_uvs)
	_emit_rotated_quads(verts, norms, uvs, colors, indices, handle_faces, handle_rect, face_light)
	# No collision faces emitted — vanilla pl.java d() returns null, so
	# the player walks straight through a lever.

	# Raycast target. These shapes emit no COLLISION faces — you walk
	# through a lever exactly as vanilla does — but without a selection
	# box the cursor ray passes straight through and hits the block
	# BEHIND it. Right-clicking a lever then toggles nothing, and the
	# component can't be mined either. The torch has emitted one since it
	# shipped; the redstone set was added without it.
	#
	# Uses the block's own selection AABB, so what you can click matches
	# what the outline draws.
	var sel: AABB = Blocks.selection_aabb(Blocks.LEVER, meta)
	var sel_o := Vector3(float(x), float(y), float(z))
	_append_torch_aabb_collision(plant_faces, sel_o + sel.position, sel_o + sel.position + sel.size)


# Redstone wire (lu.java render type 5, drawn by bk.java:420-547).
#
# A flat film 1/32 above the supporting block's top face. Two things
# decide the look: connectivity (which of the four horizontal neighbours
# this wire links to, including the up/down step cases) selects the
# CROSS or LINE tile and its rotation, and the power level selects
# between the unpowered and powered tile.
#
# Alpha does NOT tint wire by power level — bk.java:427 sets a plain
# grey brightness and swaps the texture via `bg + (meta > 0 ? 16 : 0)`.
# The familiar dark-to-bright red gradient is a Beta addition; adding it
# here would be the single most obvious "this isn't Alpha" tell.
static func _emit_wire_geometry(
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
	var meta: int = chunk.get_block_meta(x, y, z)
	var powered: bool = meta > 0
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	# COLOR.a = 1.0 turns ON the shader's alpha-discard path, and wire is
	# the one redstone shape that needs it: the dust tiles are a thin
	# cross / line drawn on transparency (8-21% opaque), so with discard
	# OFF the quad renders as a solid coloured SQUARE covering the whole
	# cell instead of a dust trail. The lever, button and plate all
	# sample fully opaque tiles (cobblestone / stone / planks) and must
	# keep 0.0 — enabling discard on opaque faces lets MSAA edge samples
	# bleed into neighbouring atlas slots.
	var face_light := Color(sky_n, blk_n, 0.0, 1.0)
	# Connectivity, evaluated against the CHUNK (edge slices give us the
	# neighbouring chunk's blocks + meta, so a wire on a seam links up
	# correctly instead of rendering as an isolated cross).
	var west: bool = _wire_links(chunk, x, y, z, -1, 0)
	var east: bool = _wire_links(chunk, x, y, z, 1, 0)
	var north: bool = _wire_links(chunk, x, y, z, 0, -1)
	var south: bool = _wire_links(chunk, x, y, z, 0, 1)
	var ns: bool = north or south
	var ew: bool = west or east
	# Straight run along exactly one axis → the line tile, rotated to
	# suit. Everything else (isolated, corner, T, cross) uses the cross
	# tile, matching bk.java's n8 selection.
	var straight_ns: bool = ns and not ew
	var straight_ew: bool = ew and not ns
	var tex_name: String
	if straight_ns or straight_ew:
		tex_name = "redstone_dust_line_powered" if powered else "redstone_dust_line"
	else:
		tex_name = "redstone_dust_cross_powered" if powered else "redstone_dust_cross"
	var rect: Rect2 = BlockAtlas.uv_rect(tex_name)
	# 1/32 lift, same trick the rail path uses to avoid z-fighting the
	# supporting block's top face.
	var wy: float = float(y) + 1.0 / 32.0
	var x0: float = float(x)
	var z0: float = float(z)
	var x1: float = x0 + 1.0
	var z1: float = z0 + 1.0
	# ORIENTATION. `_emit_rotated_quads` maps corner0→corner3 to U and
	# corner0→corner1 to V. With the corner order below that puts U along
	# world X and V along world Z.
	#
	# The dust line tile's strip runs along the tile's OWN X axis — rows
	# 6-9 opaque across every column, measured from the art, not assumed.
	# So default UVs draw the strip east-west, which is right for an
	# east-west run and 90° wrong for a north-south one. An earlier
	# comment here claimed the strip ran along Z and swapped the corner
	# order for the EW case, which inverted both.
	#
	# Rotating via a UV override rather than by reordering corners keeps
	# the winding — and therefore the face normal — untouched.
	var quads: Array = []
	if straight_ns or straight_ew:
		var line_quad: Array = [
			Vector3(x0, wy, z0),
			Vector3(x0, wy, z1),
			Vector3(x1, wy, z1),
			Vector3(x1, wy, z0),
			Vector3.UP,
		]
		if not straight_ew:
			line_quad.append(_wire_uvs_along_first_edge(rect))
		quads.append(line_quad)
	else:
		# CROSS tile — and vanilla does NOT draw the whole thing. bk.java
		# :473-497 pulls both the quad and its UVs in by 5/16 on every
		# side that has no connection, so a corner renders as an L-shaped
		# stub rather than a full four-armed plus. Only a genuinely
		# isolated dust (no connections at all) keeps the complete cross.
		#
		# Geometry and UVs are inset by the same fraction, which is what
		# keeps the dust the right thickness instead of squashing the
		# texture into a shorter arm.
		var qx0: float = x0
		var qx1: float = x1
		var qz0: float = z0
		var qz1: float = z1
		var cu0: float = rect.position.x
		var cu1: float = rect.position.x + rect.size.x
		var cv0: float = rect.position.y
		var cv1: float = rect.position.y + rect.size.y
		if west or east or north or south:
			if not west:
				qx0 += _WIRE_ARM_CROP
				cu0 += rect.size.x * _WIRE_ARM_CROP
			if not east:
				qx1 -= _WIRE_ARM_CROP
				cu1 -= rect.size.x * _WIRE_ARM_CROP
			if not north:
				qz0 += _WIRE_ARM_CROP
				cv0 += rect.size.y * _WIRE_ARM_CROP
			if not south:
				qz1 -= _WIRE_ARM_CROP
				cv1 -= rect.size.y * _WIRE_ARM_CROP
		# Default corner→UV order: corner0→(u0,v0) … corner3→(u1,v0), so
		# U follows world X and V follows world Z. The cross tile is never
		# rotated in vanilla; only the straight case swaps texture.
		(
			quads
			. append(
				[
					Vector3(qx0, wy, qz0),
					Vector3(qx0, wy, qz1),
					Vector3(qx1, wy, qz1),
					Vector3(qx1, wy, qz0),
					Vector3.UP,
					PackedVector2Array(
						[
							Vector2(cu0, cv0),
							Vector2(cu0, cv1),
							Vector2(cu1, cv1),
							Vector2(cu1, cv0),
						]
					),
				]
			)
		)
	_emit_rotated_quads(verts, norms, uvs, colors, indices, quads, rect, face_light)
	# Wall-climb quads — where a neighbouring cell is a solid cube with
	# wire sitting on top of it, vanilla draws the dust running up that
	# block's near face (bk.java:523-546).
	var climb_rect: Rect2 = BlockAtlas.uv_rect(
		"redstone_dust_line_powered" if powered else "redstone_dust_line"
	)
	var inset: float = 1.0 / 32.0
	var climbs: Array = []
	if _wire_climbs(chunk, x, y, z, -1, 0):
		(
			climbs
			. append(
				[
					Vector3(x0 + inset, float(y + 1), z1),
					Vector3(x0 + inset, float(y), z1),
					Vector3(x0 + inset, float(y), z0),
					Vector3(x0 + inset, float(y + 1), z0),
					Vector3.RIGHT,
				]
			)
		)
	if _wire_climbs(chunk, x, y, z, 1, 0):
		(
			climbs
			. append(
				[
					Vector3(x1 - inset, float(y + 1), z0),
					Vector3(x1 - inset, float(y), z0),
					Vector3(x1 - inset, float(y), z1),
					Vector3(x1 - inset, float(y + 1), z1),
					Vector3.LEFT,
				]
			)
		)
	if _wire_climbs(chunk, x, y, z, 0, -1):
		(
			climbs
			. append(
				[
					Vector3(x0, float(y + 1), z0 + inset),
					Vector3(x0, float(y), z0 + inset),
					Vector3(x1, float(y), z0 + inset),
					Vector3(x1, float(y + 1), z0 + inset),
					Vector3.BACK,
				]
			)
		)
	if _wire_climbs(chunk, x, y, z, 0, 1):
		(
			climbs
			. append(
				[
					Vector3(x1, float(y + 1), z1 - inset),
					Vector3(x1, float(y), z1 - inset),
					Vector3(x0, float(y), z1 - inset),
					Vector3(x0, float(y + 1), z1 - inset),
					Vector3.FORWARD,
				]
			)
		)
	if not climbs.is_empty():
		# Every climb quad runs corner0→corner1 down the wall, so the same
		# override puts the strip VERTICAL — a trail climbing the face,
		# rather than a band drawn across it.
		var climb_uvs: PackedVector2Array = _wire_uvs_along_first_edge(climb_rect)
		for climb: Array in climbs:
			climb.append(climb_uvs)
		_emit_rotated_quads(verts, norms, uvs, colors, indices, climbs, climb_rect, face_light)

	# Raycast target. These shapes emit no COLLISION faces — you walk
	# through a lever exactly as vanilla does — but without a selection
	# box the cursor ray passes straight through and hits the block
	# BEHIND it. Right-clicking a lever then toggles nothing, and the
	# component can't be mined either. The torch has emitted one since it
	# shipped; the redstone set was added without it.
	#
	# Uses the block's own selection AABB, so what you can click matches
	# what the outline draws.
	var sel: AABB = Blocks.selection_aabb(Blocks.REDSTONE_WIRE, meta)
	var sel_o := Vector3(float(x), float(y), float(z))
	_append_torch_aabb_collision(plant_faces, sel_o + sel.position, sel_o + sel.position + sel.size)


# UV set that runs the tile's U axis along a quad's corner0→corner1 edge
# instead of corner0→corner3 — i.e. the texture rotated 90°. Used by the
# wire paths to point the dust strip along the direction the wire
# actually runs.
static func _wire_uvs_along_first_edge(rect: Rect2) -> PackedVector2Array:
	var u0: float = rect.position.x
	var v0: float = rect.position.y
	var u1: float = rect.position.x + rect.size.x
	var v1: float = rect.position.y + rect.size.y
	return PackedVector2Array([Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1)])


# Chunk-local mirror of Redstone.can_connect_to. The mesher runs on a
# worker thread against a Chunk snapshot, so it can't call through the
# ChunkManager — but edge slices give it the neighbouring chunk's
# blocks + meta, which is what keeps seam wire connected.
static func _wire_connectable(chunk: Chunk, x: int, y: int, z: int) -> bool:
	var id: int = chunk.get_block(x, y, z)
	if id == Blocks.REDSTONE_WIRE:
		return true
	if id == Blocks.AIR:
		return false
	return Redstone.is_power_source(id)


static func _wire_solid(chunk: Chunk, x: int, y: int, z: int) -> bool:
	var id: int = chunk.get_block(x, y, z)
	if id == Blocks.AIR or not Blocks.is_opaque(id):
		return false
	return Blocks.mesh_shape(id) == Blocks.MESH_SHAPE_CUBE


# Same predicate as Redstone.wire_connects_toward, including the
# asymmetric vertical rules.
static func _wire_links(chunk: Chunk, x: int, y: int, z: int, dx: int, dz: int) -> bool:
	if _wire_connectable(chunk, x + dx, y, z + dz):
		return true
	if not _wire_solid(chunk, x + dx, y, z + dz):
		return _wire_connectable(chunk, x + dx, y - 1, z + dz)
	if _wire_solid(chunk, x, y + 1, z):
		return false
	return _wire_connectable(chunk, x + dx, y + 1, z + dz)


# A climb quad is drawn when the neighbour is solid AND carries wire on
# top of it (and this cell isn't roofed over).
static func _wire_climbs(chunk: Chunk, x: int, y: int, z: int, dx: int, dz: int) -> bool:
	if not _wire_solid(chunk, x + dx, y, z + dz):
		return false
	if _wire_solid(chunk, x, y + 1, z):
		return false
	return chunk.get_block(x + dx, y + 1, z + dz) == Blocks.REDSTONE_WIRE


# Stone button (iy.java render). A single small box on the wall it is
# mounted on, sunk in by half when pressed — that visible travel is the
# only feedback the button gives.
static func _emit_button_geometry(
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
	var meta: int = chunk.get_block_meta(x, y, z)
	var rect: Rect2 = BlockAtlas.uv_rect_for(Blocks.STONE_BUTTON, BlockAtlas.FACE_SIDE)
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 0.0)
	var aabb: AABB = Blocks.selection_aabb(Blocks.STONE_BUTTON, meta)
	var o := Vector3(float(x), float(y), float(z))
	_emit_box(verts, norms, uvs, colors, indices, o + aabb.position, o + aabb.end, rect, face_light)

	# Raycast target. These shapes emit no COLLISION faces — you walk
	# through a lever exactly as vanilla does — but without a selection
	# box the cursor ray passes straight through and hits the block
	# BEHIND it. Right-clicking a lever then toggles nothing, and the
	# component can't be mined either. The torch has emitted one since it
	# shipped; the redstone set was added without it.
	#
	# Uses the block's own selection AABB — WITH its metadata. A button's
	# box hugs whichever wall it is mounted on, so omitting meta hands
	# back the default +Z-wall box and the clickable region ends up on the
	# opposite side of the cell from the button you can see.
	var sel: AABB = Blocks.selection_aabb(Blocks.STONE_BUTTON, meta)
	var sel_o := Vector3(float(x), float(y), float(z))
	_append_torch_aabb_collision(plant_faces, sel_o + sel.position, sel_o + sel.position + sel.size)


# Pressure plate (ap.java render). A flat pad inset 1/16 on each side,
# 1/16 tall and 1/32 when pressed. No collision — you walk over it.
static func _emit_plate_geometry(
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
	var id: int = chunk.get_block(x, y, z)
	var meta: int = chunk.get_block_meta(x, y, z)
	var rect: Rect2 = BlockAtlas.uv_rect_for(id, BlockAtlas.FACE_TOP)
	var sky_n: float = float(chunk.get_sky_light(x, y, z)) * _LIGHT_SCALE
	var blk_n: float = float(chunk.get_block_light(x, y, z)) * _LIGHT_SCALE
	var face_light := Color(sky_n, blk_n, 0.0, 0.0)
	var aabb: AABB = Blocks.selection_aabb(id, meta)
	var o := Vector3(float(x), float(y), float(z))
	_emit_box(verts, norms, uvs, colors, indices, o + aabb.position, o + aabb.end, rect, face_light)

	# Raycast target. These shapes emit no COLLISION faces — you walk
	# through a lever exactly as vanilla does — but without a selection
	# box the cursor ray passes straight through and hits the block
	# BEHIND it. Right-clicking a lever then toggles nothing, and the
	# component can't be mined either. The torch has emitted one since it
	# shipped; the redstone set was added without it.
	#
	# Uses the block's own selection AABB, so what you can click matches
	# what the outline draws.
	var sel: AABB = Blocks.selection_aabb(id, meta)
	var sel_o := Vector3(float(x), float(y), float(z))
	_append_torch_aabb_collision(plant_faces, sel_o + sel.position, sel_o + sel.position + sel.size)
