class_name FallingBlock
extends Node3D

# Vanilla MC's EntityFallingBlock — visible falling animation for gravel
# / sand. Spawned by ChunkManager._settle_gravity_above when a gravity
# block becomes unsupported. Falls under constant gravity, raycasts down
# each frame to detect the landing surface, then writes itself back as a
# real block at the landing y and despawns.

const GRAVITY: float = -16.0  # vanilla EntityFallingBlock: motY -= 0.04/tick @ 20 TPS
const TERMINAL_VELOCITY: float = -32.0
const MESH_SIZE: float = 0.999  # tiny inset so raycasts don't self-collide
const SAFETY_LIFETIME_SEC: float = 6.0  # despawn fallback if something goes wrong

var block_id: int = 0
var _velocity_y: float = 0.0
var _spawn_time: float = 0.0
var _ray_query: PhysicsRayQueryParameters3D
var _chunk_manager: Node


func setup(p_block_id: int) -> void:
	block_id = p_block_id
	_spawn_time = Time.get_ticks_msec() / 1000.0
	var mesh := MeshInstance3D.new()
	mesh.mesh = BlockMesh.get_cube_mesh(p_block_id, MESH_SIZE)
	add_child(mesh)
	_ray_query = PhysicsRayQueryParameters3D.new()


func _ready() -> void:
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	# Vanilla EntityFallingBlock.move() does AABB collision against *blocks
	# only* — entities don't shove each other, so the falling block falls
	# straight through the player and lands on the terrain below. Our ray
	# hits every collider in its path including the player's CharacterBody3D,
	# which would land the block on the player's head. Exclude the player's
	# RID so the ray sees only terrain (and only terrain can be landed on).
	var player: CharacterBody3D = get_tree().root.get_node_or_null("Main/Player") as CharacterBody3D
	if player != null:
		_ray_query.exclude = [player.get_rid()]


func _process(delta: float) -> void:
	if _chunk_manager == null:
		queue_free()
		return
	var elapsed: float = Time.get_ticks_msec() / 1000.0 - _spawn_time
	if elapsed > SAFETY_LIFETIME_SEC:
		_land_at(int(floor(global_position.y)))
		return

	# Stacked-column defense: when a column of sand/gravel falls together,
	# entities land one at a time — but the entity above has its mesh
	# extending into the cell that just became solid, and renders a z-
	# fighting overlap for the frame between its neighbour landing and
	# its own raycast catching up. Check every frame whether the cell our
	# mesh bottom is currently in became solid; if so, land on top of it
	# immediately (same frame) instead of descending into it.
	var x: int = int(floor(global_position.x))
	var z: int = int(floor(global_position.z))
	var bottom_cell_y: int = int(floor(global_position.y - MESH_SIZE * 0.5))
	if _chunk_manager.get_world_block(Vector3i(x, bottom_cell_y, z)) != Blocks.AIR:
		_land_at(bottom_cell_y + 1)
		return

	_velocity_y = maxf(_velocity_y + GRAVITY * delta, TERMINAL_VELOCITY)
	var step: float = _velocity_y * delta
	var new_y: float = global_position.y + step
	# Raycast down from current center to (current center + step - half-height).
	# When we'd land inside a solid block, snap our base to its top and place.
	_ray_query.from = global_position
	_ray_query.to = Vector3(global_position.x, new_y - MESH_SIZE * 0.5, global_position.z)
	var hit := get_world_3d().direct_space_state.intersect_ray(_ray_query)
	if not hit.is_empty():
		# Land on top of whatever we hit. The block we write goes at
		# floor(hit.position.y + epsilon) — i.e. the cell ABOVE the hit
		# surface so the cube sits flush on top.
		var land_y: int = int(floor(hit.position.y + 0.001))
		_land_at(land_y)
		return
	global_position.y = new_y
	if new_y < -10.0:
		# Fell off the world; just disappear.
		queue_free()


# Place the block at the landing cell, but if that cell isn't air (player
# raced us by placing something), settle on top instead. Cascades up while
# the target is occupied so we never overwrite an existing block.
func _land_at(land_y: int) -> void:
	var x: int = int(floor(global_position.x))
	var z: int = int(floor(global_position.z))
	while land_y < 128:
		var pos := Vector3i(x, land_y, z)
		if _chunk_manager.get_world_block(pos) == Blocks.AIR:
			# `_immediate` forces the chunk to remesh this frame so the
			# landed block is drawn on the same frame we hide the entity
			# below. Without it, the entity vanishes first and the block
			# appears one frame later — a visible pop.
			_chunk_manager.set_world_block_immediate(pos, block_id)
			break
		land_y += 1
	# Hide before queue_free so we don't render one last frame at a pose
	# that might overlap freshly placed geometry (queue_free is deferred
	# to end-of-frame; visibility takes effect immediately).
	visible = false
	queue_free()
