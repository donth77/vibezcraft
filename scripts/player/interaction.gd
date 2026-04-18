extends Node

# Raycast-based block break/place wired into the player's Inventory:
# - Break: removes the block; the dropped item ID is added to the inventory.
# - Place: consumes one of the selected hotbar slot, places that block.

const REACH: float = 5.0
const ACTION_COOLDOWN_MS: int = 50

var _last_break_ms: int = 0
var _last_place_ms: int = 0
var _highlight: MeshInstance3D

@onready var _camera: Camera3D = get_parent().get_node("Camera3D")
@onready var _chunk_manager: Node3D = get_tree().root.get_node_or_null("Main/ChunkManager")


func _ready() -> void:
	_highlight = _build_highlight()
	# Parent under the stationary ChunkManager so the world-space overlay
	# isn't dragged around by the player's transform.
	if _chunk_manager != null:
		_chunk_manager.add_child(_highlight)
	else:
		add_child(_highlight)


func _process(_delta: float) -> void:
	var hit := _raycast()
	if hit.is_empty():
		_highlight.visible = false
	else:
		_highlight.visible = true
		_highlight.global_position = Vector3(hit.block_pos) + Vector3(0.5, 0.5, 0.5)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact_break"):
		_try_break()
	elif event.is_action_pressed("interact_place"):
		_try_place()


func _build_highlight() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	# Slight outset to avoid z-fighting with the block face
	box.size = Vector3.ONE * 1.005
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.18)
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = StandardMaterial3D.CULL_BACK
	mi.material_override = mat
	mi.visible = false
	return mi


func _try_break() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_break_ms < ACTION_COOLDOWN_MS:
		return
	_last_break_ms = now
	var hit := _raycast()
	if hit.is_empty() or _chunk_manager == null:
		return
	var inventory: Inventory = _player_inventory()
	var broken_id: int = _chunk_manager.get_world_block(hit.block_pos)
	if broken_id == Blocks.AIR or broken_id == Blocks.BEDROCK:
		return  # bedrock is indestructible (Alpha-faithful)
	_chunk_manager.set_world_block(hit.block_pos, Blocks.AIR)
	SFX.play_break(broken_id)
	if inventory != null:
		var dropped_id: int = Blocks.drops(broken_id)
		if dropped_id != Blocks.AIR:
			inventory.add_item(dropped_id, 1)


func _try_place() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_place_ms < ACTION_COOLDOWN_MS:
		print("[Place] suppressed (cooldown, %dms since last)" % (now - _last_place_ms))
		return
	var hit := _raycast()
	if hit.is_empty() or _chunk_manager == null:
		return
	var inventory: Inventory = _player_inventory()
	if inventory == null:
		return
	var stack: ItemStack = inventory.selected()
	if stack.is_empty():
		return
	var place: Vector3i = hit.block_pos + hit.normal_i
	if _chunk_manager.get_world_block(place) != Blocks.AIR:
		print("[Place] target %s already occupied — skipped" % place)
		return
	var player: Node3D = get_parent()
	var pp := player.global_position
	var player_block := Vector3i(int(floor(pp.x)), int(floor(pp.y)), int(floor(pp.z)))
	if place == player_block or place == player_block + Vector3i(0, 1, 0):
		return
	_last_place_ms = now
	_chunk_manager.set_world_block(place, stack.item_id)
	SFX.play_place(stack.item_id)
	inventory.consume_one_selected()
	print(
		(
			"[Place] hit=%s normal=%s placed=%s id=%d"
			% [hit.block_pos, hit.normal_i, place, stack.item_id]
		)
	)


func _player_inventory() -> Inventory:
	var player: Node = get_parent()
	if player.has_method("get") and "inventory" in player:
		return player.get("inventory") as Inventory
	return null


func _raycast() -> Dictionary:
	var space := _camera.get_world_3d().direct_space_state
	var origin := _camera.global_position
	var direction := -_camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * REACH)
	# Exclude the player's own collision shape so looking straight down hits
	# the block underfoot, not the capsule.
	var player: CollisionObject3D = get_parent() as CollisionObject3D
	if player != null:
		query.exclude = [player.get_rid()]
	var result := space.intersect_ray(query)
	if result.is_empty():
		return {}
	var hit_pos: Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	var inside := hit_pos - hit_normal * 0.01
	return {
		"collider": result.collider,
		"block_pos": Vector3i(int(floor(inside.x)), int(floor(inside.y)), int(floor(inside.z))),
		"normal_i":
		Vector3i(int(round(hit_normal.x)), int(round(hit_normal.y)), int(round(hit_normal.z))),
	}
