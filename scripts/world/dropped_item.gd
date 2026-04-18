extends Node3D

# Vanilla MC dropped-item behavior:
#   - Spawns at the broken-block position and hovers (no gravity, no
#     collision — MC items just float in place at the spawn height).
#   - Sine-wave bob + slow Y-spin for visual life.
#   - Magnet: when player gets within MAGNET_RADIUS, accelerates toward them.
#   - Pickup: at PICKUP_RADIUS the item plays "pop", removes self, adds to
#     the player's inventory. PICKUP_DELAY_SEC prevents instant re-grab off
#     your own break.

const MESH_SIZE: float = 0.25
const PICKUP_DELAY_SEC: float = 0.5
const LIFETIME_SEC: float = 300.0  # matches vanilla Java MC
const PICKUP_RADIUS: float = 0.9
const MAGNET_RADIUS: float = 1.8
const MAGNET_SPEED: float = 9.0
const SPIN_SPEED: float = 1.2  # rad/s
const HOVER_AMPLITUDE: float = 0.06
const HOVER_FREQUENCY: float = 1.6  # cycles/sec
const GRAVITY: float = -10.0
const TERMINAL_VELOCITY: float = -16.0
const FACE_NAMES: Array = ["top", "bottom", "side", "side", "side", "side"]

static var _mesh_cache: Dictionary = {}  # block_id → ArrayMesh, shared across items

var item_id: int = 0
var _spawn_time: float = 0.0
var _hover_phase: float = 0.0
var _velocity_y: float = 0.0
var _picked_up: bool = false
var _mesh: MeshInstance3D
var _player: Node3D
var _ray_query: PhysicsRayQueryParameters3D  # reused per-frame to avoid allocs


func setup(p_item_id: int, _initial_velocity: Vector3 = Vector3.ZERO) -> void:
	# Called by ChunkManager AFTER add_child + global_position set, so we
	# have both the right block id and a valid spawn position before building
	# the mesh.
	item_id = p_item_id
	_spawn_time = Time.get_ticks_msec() / 1000.0
	# Mesh is a child Node3D so we can bob its local Y without fighting the
	# root's gravity-controlled global Y. Mesh data is cached per block id —
	# multiple items of the same type share one ArrayMesh resource.
	_mesh = MeshInstance3D.new()
	if not _mesh_cache.has(p_item_id):
		_mesh_cache[p_item_id] = _build_textured_cube_mesh(MESH_SIZE)
	_mesh.mesh = _mesh_cache[p_item_id]
	add_child(_mesh)
	_ray_query = PhysicsRayQueryParameters3D.new()


func _process(delta: float) -> void:
	if _picked_up:
		return
	rotate_y(delta * SPIN_SPEED)

	if _player == null:
		_player = _find_player()
	var elapsed: float = Time.get_ticks_msec() / 1000.0 - _spawn_time
	if elapsed > LIFETIME_SEC:
		queue_free()
		return

	# Magnet / pickup
	if _player != null and elapsed >= PICKUP_DELAY_SEC:
		var target: Vector3 = _player.global_position + Vector3(0, 0.4, 0)
		var to_target: Vector3 = target - global_position
		var dist: float = to_target.length()
		if dist <= PICKUP_RADIUS:
			_try_pickup(_player)
			return
		if dist <= MAGNET_RADIUS:
			var step: Vector3 = to_target.normalized() * MAGNET_SPEED * delta
			if step.length() >= dist:
				global_position = target
			else:
				global_position += step
			_velocity_y = 0.0
			return

	# Always-on gravity. Each frame, raycast straight down — if there's still
	# terrain under us, snap to it and zero the velocity; otherwise fall.
	# This way breaking the block under a resting item resumes the fall.
	_apply_gravity(delta)

	# Visual hover bob — applied to the mesh child, NOT the root, so it
	# doesn't race with the gravity-controlled global Y.
	_hover_phase += delta * HOVER_FREQUENCY * TAU
	if _mesh != null:
		_mesh.position.y = sin(_hover_phase) * HOVER_AMPLITUDE


func _apply_gravity(delta: float) -> void:
	_velocity_y = maxf(_velocity_y + GRAVITY * delta, TERMINAL_VELOCITY)
	var new_y: float = global_position.y + _velocity_y * delta
	_ray_query.from = global_position
	_ray_query.to = Vector3(global_position.x, new_y - MESH_SIZE * 0.5, global_position.z)
	var result := get_world_3d().direct_space_state.intersect_ray(_ray_query)
	if not result.is_empty():
		global_position.y = result.position.y + MESH_SIZE * 0.5
		_velocity_y = 0.0
	else:
		global_position.y = new_y


func _try_pickup(player: Node3D) -> void:
	if not "inventory" in player:
		return
	var inv: Inventory = player.get("inventory") as Inventory
	if inv == null:
		return
	var overflow: int = inv.add_item(item_id, 1)
	if overflow > 0:
		return  # inventory full — leave the item
	_picked_up = true
	SFX.play_pickup()
	queue_free()


func _find_player() -> Node3D:
	return get_tree().root.get_node_or_null("Main/Player") as Node3D


# Small textured cube using the block atlas (chunk-mesher winding + V-flip).
func _build_textured_cube_mesh(size: float) -> ArrayMesh:
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
		var tex_name: String = Blocks.get_face_texture(item_id, face_name)
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
