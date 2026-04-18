extends Node

# Raycast-based block break/place. Attached as a child of the Player.
# For Phase 2 the world contains a single ChunkNode at world origin, so block
# coords == world coords (floored). Multi-chunk handling lands in Phase 3.

const REACH: float = 5.0  # blocks

const _HOTBAR_BLOCKS: Array = [
	Blocks.STONE,  # 1
	Blocks.COBBLESTONE,  # 2
	Blocks.DIRT,  # 3
	Blocks.GRASS,  # 4
	Blocks.SAND,  # 5
	Blocks.LOG,  # 6
	Blocks.PLANKS,  # 7
	Blocks.LEAVES,  # 8
	Blocks.BEDROCK,  # 9
]

@export var selected_block_id: int = Blocks.STONE

@onready var _camera: Camera3D = get_parent().get_node("Camera3D")
@onready var _selected_label: Label = get_parent().get_node_or_null("Crosshair/SelectedLabel")
@onready var _chunk_manager: Node3D = get_tree().root.get_node_or_null("Main/ChunkManager")


func _ready() -> void:
	_refresh_selected_label()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact_break"):
		_try_break()
	elif event.is_action_pressed("interact_place"):
		_try_place()
	for i in range(1, 10):
		if event.is_action_pressed("hotbar_%d" % i):
			selected_block_id = _hotbar_block(i)
			_refresh_selected_label()


func _refresh_selected_label() -> void:
	if _selected_label != null:
		_selected_label.text = "Selected: " + Blocks.name_of(selected_block_id)


func _try_break() -> void:
	var hit := _raycast()
	if hit.is_empty() or _chunk_manager == null:
		return
	_chunk_manager.set_world_block(hit.block_pos, Blocks.AIR)


func _try_place() -> void:
	var hit := _raycast()
	if hit.is_empty() or _chunk_manager == null:
		return
	var place: Vector3i = hit.block_pos + hit.normal_i
	# Don't place inside the player's own bounding cells
	var player: Node3D = get_parent()
	var pp := player.global_position
	var player_block := Vector3i(int(floor(pp.x)), int(floor(pp.y)), int(floor(pp.z)))
	if place == player_block or place == player_block + Vector3i(0, 1, 0):
		return
	_chunk_manager.set_world_block(place, selected_block_id)


func _raycast() -> Dictionary:
	var space := _camera.get_world_3d().direct_space_state
	var origin := _camera.global_position
	var direction := -_camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * REACH)
	var result := space.intersect_ray(query)
	if result.is_empty():
		return {}
	var hit_pos: Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	# Step slightly into the block so floor() lands on the right cell
	var inside := hit_pos - hit_normal * 0.01
	return {
		"collider": result.collider,
		"block_pos": Vector3i(floor(inside.x), floor(inside.y), floor(inside.z)),
		"normal_i": Vector3i(round(hit_normal.x), round(hit_normal.y), round(hit_normal.z)),
	}


func _hotbar_block(slot: int) -> int:
	if slot < 1 or slot > _HOTBAR_BLOCKS.size():
		return Blocks.STONE
	return _HOTBAR_BLOCKS[slot - 1]
