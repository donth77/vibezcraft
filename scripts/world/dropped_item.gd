class_name DroppedItem
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
const PICKUP_DELAY_SEC: float = 0.5  # default for break-spawned items
const PLAYER_DROP_DELAY_SEC: float = 2.0  # vanilla MC pickup delay for thrown items
const LIFETIME_SEC: float = 300.0  # matches vanilla Java MC
const PICKUP_RADIUS: float = 0.9
const MAGNET_RADIUS: float = 1.8
const MAGNET_SPEED: float = 9.0
const SPIN_SPEED: float = 1.2  # rad/s
const HOVER_AMPLITUDE: float = 0.06
const HOVER_FREQUENCY: float = 1.6  # cycles/sec
const GRAVITY: float = -22.0  # vanilla feel — items arc and settle quickly, not float
const TERMINAL_VELOCITY: float = -32.0
const HORIZONTAL_DRAG: float = 2.5  # 1/s — quickly damps thrown velocity

var item_id: int = 0
var _spawn_time: float = 0.0
var _hover_phase: float = 0.0
var _velocity: Vector3 = Vector3.ZERO  # full 3D so thrown items arc forward
var _pickup_delay: float = PICKUP_DELAY_SEC
var _picked_up: bool = false
var _mesh: MeshInstance3D
var _player: Node3D
var _ray_query: PhysicsRayQueryParameters3D  # reused per-frame to avoid allocs


func setup(
	p_item_id: int,
	p_initial_velocity: Vector3 = Vector3.ZERO,
	p_pickup_delay: float = PICKUP_DELAY_SEC
) -> void:
	# Called AFTER add_child + global_position set, so the block id and spawn
	# position are valid before the mesh is built. Pass a non-zero velocity
	# (and a longer pickup delay) for player-thrown drops.
	item_id = p_item_id
	_velocity = p_initial_velocity
	_pickup_delay = p_pickup_delay
	_spawn_time = Time.get_ticks_msec() / 1000.0
	# Mesh is a child Node3D so we can bob its local Y without fighting the
	# root's gravity-controlled global Y. BlockMesh.get_cube_mesh caches the
	# ArrayMesh per (block_id, size) so many items share one GPU resource.
	_mesh = MeshInstance3D.new()
	_mesh.mesh = BlockMesh.get_cube_mesh(p_item_id, MESH_SIZE)
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
	if _player != null and elapsed >= _pickup_delay:
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
			_velocity = Vector3.ZERO
			return

	# Always-on gravity. Each frame, raycast straight down — if there's still
	# terrain under us, snap to it and zero the velocity; otherwise fall.
	# This way breaking the block under a resting item resumes the fall.
	_apply_physics(delta)

	# Visual hover bob — applied to the mesh child only when the item is at
	# rest. Bobbing mid-fall would read as "floating".
	if _mesh != null:
		var at_rest: bool = (
			absf(_velocity.y) < 0.05 and Vector2(_velocity.x, _velocity.z).length() < 0.05
		)
		if at_rest:
			_hover_phase += delta * HOVER_FREQUENCY * TAU
			_mesh.position.y = sin(_hover_phase) * HOVER_AMPLITUDE
		else:
			_mesh.position.y = 0.0


func _apply_physics(delta: float) -> void:
	# Gravity on Y, exponential drag on horizontal so thrown items glide
	# briefly before settling. No horizontal collision — items rarely travel
	# more than a block from their spawn before friction stops them.
	_velocity.y = maxf(_velocity.y + GRAVITY * delta, TERMINAL_VELOCITY)
	var drag_factor: float = clampf(1.0 - HORIZONTAL_DRAG * delta, 0.0, 1.0)
	_velocity.x *= drag_factor
	_velocity.z *= drag_factor
	var new_pos: Vector3 = global_position + _velocity * delta
	# Down raycast snaps the item to the floor when it would pass through.
	_ray_query.from = global_position
	_ray_query.to = Vector3(new_pos.x, new_pos.y - MESH_SIZE * 0.5, new_pos.z)
	var result := get_world_3d().direct_space_state.intersect_ray(_ray_query)
	if not result.is_empty() and _velocity.y <= 0.0:
		new_pos.y = result.position.y + MESH_SIZE * 0.5
		_velocity.y = 0.0
	global_position = new_pos


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
