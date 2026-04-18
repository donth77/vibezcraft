class_name BlockMesh
extends RefCounted

# Builds a small, fully-textured block cube using the shared block atlas.
# Used by dropped_item.gd (item entities) and player.gd (held-item display).
# Caches one ArrayMesh per block id so that many instances share GPU data.

const FACE_NAMES: Array = ["top", "bottom", "side", "side", "side", "side"]

static var _cache: Dictionary = {}  # block_id → ArrayMesh


static func get_cube_mesh(block_id: int, size: float = 1.0) -> ArrayMesh:
	var key: String = "%d_%.4f" % [block_id, size]
	if not _cache.has(key):
		_cache[key] = _build(block_id, size)
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
		uvs.append(Vector2(rect.position.x, rect.position.y + rect.size.y))
		uvs.append(Vector2(rect.position.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y))
		uvs.append(Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y))
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
	mesh.surface_set_material(0, BlockAtlas.material())
	return mesh
