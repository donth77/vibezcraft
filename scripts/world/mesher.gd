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


static func mesh_chunk(chunk: Chunk) -> Dictionary:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for y in range(Chunk.SIZE_Y):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				var id := chunk.get_block(x, y, z)
				if id == Blocks.AIR:
					continue
				_emit_block_faces(chunk, x, y, z, id, verts, norms, uvs, indices)

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
		var face_name: String = _FACE_NAMES[face_idx]
		var tex_name := Blocks.get_face_texture(id, face_name)
		var rect := BlockAtlas.uv_rect(tex_name)
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
