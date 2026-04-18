extends Node3D

# Node3D wrapper around a Chunk: builds and updates the visual mesh + collision
# whenever the underlying Chunk's `dirty` flag is set.

@export var auto_populate_test_data: bool = false

var chunk: Chunk

var _mesh_instance: MeshInstance3D
var _static_body: StaticBody3D
var _collision_shape: CollisionShape3D
var _material: ShaderMaterial


func _ready() -> void:
	chunk = Chunk.new()
	_mesh_instance = MeshInstance3D.new()
	add_child(_mesh_instance)
	_static_body = StaticBody3D.new()
	add_child(_static_body)
	_collision_shape = CollisionShape3D.new()
	_static_body.add_child(_collision_shape)
	_material = _create_material()
	if auto_populate_test_data:
		_populate_test_data()
	_rebuild_mesh()


func _process(_delta: float) -> void:
	if chunk and chunk.dirty:
		_rebuild_mesh()
		chunk.dirty = false


func _rebuild_mesh() -> void:
	var data := Mesher.mesh_chunk(chunk)
	if data.vertices.is_empty():
		_mesh_instance.mesh = null
		_collision_shape.shape = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data.vertices
	arrays[Mesh.ARRAY_NORMAL] = data.normals
	arrays[Mesh.ARRAY_TEX_UV] = data.uvs
	arrays[Mesh.ARRAY_INDEX] = data.indices
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	array_mesh.surface_set_material(0, _material)
	_mesh_instance.mesh = array_mesh
	_collision_shape.shape = array_mesh.create_trimesh_shape()


func _create_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/chunk.gdshader") as Shader
	mat.set_shader_parameter("atlas_texture", BlockAtlas.texture())
	return mat


func _populate_test_data() -> void:
	# Stratified terrain: bedrock / stone / dirt / grass
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			chunk.set_block(x, 0, z, Blocks.BEDROCK)
			for y in range(1, 4):
				chunk.set_block(x, y, z, Blocks.STONE)
			chunk.set_block(x, 4, z, Blocks.DIRT)
			chunk.set_block(x, 5, z, Blocks.GRASS)
	# Sand patch
	for x in range(0, 4):
		for z in range(0, 4):
			chunk.set_block(x, 5, z, Blocks.SAND)
	# Tree at (8, 6+, 8)
	for h in range(4):
		chunk.set_block(8, 6 + h, 8, Blocks.LOG)
	for x in range(7, 10):
		for z in range(7, 10):
			for y in range(8, 10):
				if not (x == 8 and z == 8 and y == 8):
					if chunk.get_block(x, y, z) == Blocks.AIR:
						chunk.set_block(x, y, z, Blocks.LEAVES)
	# Cobblestone wall
	for y in range(6, 9):
		for z in range(4, 8):
			chunk.set_block(12, y, z, Blocks.COBBLESTONE)
	# Plank platform
	for x in range(3, 6):
		for z in range(12, 15):
			chunk.set_block(x, 6, z, Blocks.PLANKS)
