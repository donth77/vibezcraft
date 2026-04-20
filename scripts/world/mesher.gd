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
static func mesh_chunk_fast(chunk: Chunk) -> Dictionary:
	if _native_mesher != null:
		var probe_token := PerfProbe.begin("mesher.mesh_chunk")
		var result: Dictionary = _native_mesher.mesh_chunk_data(
			chunk.blocks, chunk.max_y, BlockAtlas.uv_table_flat()
		)
		PerfProbe.end("mesher.mesh_chunk", probe_token)
		return result
	return mesh_chunk(chunk)


static func mesh_chunk(chunk: Chunk) -> Dictionary:
	var probe_token := PerfProbe.begin("mesher.mesh_chunk")
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	# Skip empty layers above the highest filled block — saves ~60% of
	# iterations on a typical worldgen chunk peaking at y~44 of 128.
	var top: int = mini(chunk.max_y + 1, Chunk.SIZE_Y - 1)
	for y in range(top + 1):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				var id := chunk.get_block(x, y, z)
				if id == Blocks.AIR:
					continue
				_emit_block_faces(chunk, x, y, z, id, verts, norms, uvs, indices)

	PerfProbe.end("mesher.mesh_chunk", probe_token)
	return {
		"vertices": verts,
		"normals": norms,
		"uvs": uvs,
		"indices": indices,
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
	indices: PackedInt32Array
) -> void:
	var origin := Vector3(x, y, z)
	for face_idx in range(6):
		# CPU-side neighbor culling: skip faces between two adjacent opaque
		# blocks (the face is physically hidden by the neighbor anyway). The
		# render-side cull_back then trims the back-facing half of every
		# remaining face. Combined: ~3 visible faces per surface cube.
		var no: Vector3i = _FACE_NEIGHBOR[face_idx]
		var neighbor_id := chunk.get_block(x + no.x, y + no.y, z + no.z)
		if Blocks.is_opaque(neighbor_id):
			continue
		var face_verts: Array = _FACE_VERTS[face_idx]
		var normal: Vector3 = _FACE_NORMALS[face_idx]
		var rect: Rect2 = BlockAtlas.uv_rect_for(id, _FACE_KIND[face_idx])
		var base := verts.size()
		for v: Vector3 in face_verts:
			verts.append(origin + v)
			norms.append(normal)
		# V is flipped so the top of each cube face samples the top of the
		# texture — keeps grass_side's green strip on top, dirt on bottom.
		uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
		uvs.append(Vector2(rect.position.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
		# Reversed winding so cull_back keeps the outward-facing side in Godot 4.
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)
