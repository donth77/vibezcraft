extends Node3D

# Hand-built 16x16 grass platform with a wall and a step for collision testing.
# Replaced in Phase 2 by real chunk meshing.

const PLATFORM_SIZE: int = 16

var _block_mesh: BoxMesh
var _block_shape: BoxShape3D
var _grass_mat: StandardMaterial3D
var _stone_mat: StandardMaterial3D


func _ready() -> void:
	_block_mesh = BoxMesh.new()
	_block_mesh.size = Vector3.ONE
	_block_shape = BoxShape3D.new()
	_block_shape.size = Vector3.ONE
	_grass_mat = _make_mat(Color(0.4, 0.78, 0.3))
	_stone_mat = _make_mat(Color(0.5, 0.5, 0.55))
	_build()


func _build() -> void:
	# 16x16 grass floor at y=0 (block centers at y=0; tops at y=0.5)
	for x: int in range(PLATFORM_SIZE):
		for z: int in range(PLATFORM_SIZE):
			_spawn_block(Vector3(x, 0, z), _grass_mat)
	# A 4-wide, 3-tall wall at x=4..7, z=4 — collision test
	for y: int in range(1, 4):
		for x: int in range(4, 8):
			_spawn_block(Vector3(x, y, 4), _stone_mat)
	# A small staircase at (10,1,10) → (11,2,11) — jump/step test
	_spawn_block(Vector3(10, 1, 10), _stone_mat)
	_spawn_block(Vector3(11, 1, 10), _stone_mat)
	_spawn_block(Vector3(11, 2, 11), _stone_mat)


func _make_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	return mat


func _spawn_block(pos: Vector3, mat: StandardMaterial3D) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	var mi := MeshInstance3D.new()
	mi.mesh = _block_mesh
	mi.material_override = mat
	var col := CollisionShape3D.new()
	col.shape = _block_shape
	body.add_child(mi)
	body.add_child(col)
	add_child(body)
