extends Node3D

# Node3D wrapper around a Chunk: builds and updates the visual mesh +
# collision whenever the underlying Chunk's `dirty` flag is set.
# Block data is supplied externally — set `chunk_data` before adding to
# the tree, and _ready will build the mesh.

var chunk_data: Chunk  # set by ChunkManager pre-add_child
var precomputed_mesh_data: Dictionary  # optional pre-built mesh arrays from worker

var chunk: Chunk

var _mesh_instance: MeshInstance3D
var _static_body: StaticBody3D
var _collision_shape: CollisionShape3D


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	add_child(_mesh_instance)
	_static_body = StaticBody3D.new()
	add_child(_static_body)
	_collision_shape = CollisionShape3D.new()
	_static_body.add_child(_collision_shape)
	chunk = chunk_data if chunk_data != null else Chunk.new()
	if not precomputed_mesh_data.is_empty():
		_apply_mesh_data(precomputed_mesh_data)
		chunk.dirty = false
	else:
		_rebuild_mesh()


func _process(_delta: float) -> void:
	if chunk and chunk.dirty:
		_rebuild_mesh()
		chunk.dirty = false


# Re-mesh on the main thread. Used when a player edit dirties the chunk —
# infrequent enough that a worker dispatch isn't worth the bookkeeping.
func _rebuild_mesh() -> void:
	_apply_mesh_data(Mesher.mesh_chunk_fast(chunk))


func _apply_mesh_data(data: Dictionary) -> void:
	var probe_token := PerfProbe.begin("chunk_node.apply")
	if data.vertices.is_empty():
		_mesh_instance.mesh = null
		_collision_shape.shape = null
		PerfProbe.end("chunk_node.apply", probe_token)
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data.vertices
	arrays[Mesh.ARRAY_NORMAL] = data.normals
	arrays[Mesh.ARRAY_TEX_UV] = data.uvs
	arrays[Mesh.ARRAY_INDEX] = data.indices
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	array_mesh.surface_set_material(0, BlockAtlas.material())
	_mesh_instance.mesh = array_mesh
	_collision_shape.shape = array_mesh.create_trimesh_shape()
	PerfProbe.end("chunk_node.apply", probe_token)
