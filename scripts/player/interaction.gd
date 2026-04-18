extends Node

# Raycast-based block break/place wired into the player's Inventory.
#   Break: hold LMB; progress accumulates; on completion the block is removed
#   and Blocks.drops(id) goes into the inventory. Crack overlay + looped dig
#   sound provide visual + audio feedback during the hold.
#   Place: RMB (single click). Consumes one of the selected hotbar slot.

const REACH: float = 5.0
const PLACE_COOLDOWN_MS: int = 50
const DIG_SOUND_INTERVAL_MS: int = 300
const NO_TARGET: Vector3i = Vector3i(-2147483648, -2147483648, -2147483648)
const CRACK_ATLAS_PATH: String = "res://assets/textures/effects/destroy_stages.png"

var _last_place_ms: int = 0
var _highlight: MeshInstance3D
var _crack: MeshInstance3D
var _crack_material: ShaderMaterial
var _crack_stages: int = 6  # auto-detected from texture; default falls back to 6

# Hold-to-break state
var _mining_target: Vector3i = NO_TARGET
var _mining_progress: float = 0.0
var _mining_total_time: float = 0.0
var _last_dig_sound_ms: int = 0

@onready var _camera: Camera3D = get_parent().get_node("Camera3D")
@onready var _chunk_manager: Node3D = get_tree().root.get_node_or_null("Main/ChunkManager")


func _ready() -> void:
	_highlight = _build_highlight()
	_crack = _build_crack()
	_crack_material = _crack.material_override as ShaderMaterial
	# Parent under stationary ChunkManager so world-space overlays don't
	# inherit the player transform.
	var parent: Node = _chunk_manager if _chunk_manager != null else self
	parent.add_child(_highlight)
	parent.add_child(_crack)


func _process(delta: float) -> void:
	var hit := _raycast()
	_update_highlight(hit)
	_update_mining(hit, delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact_place"):
		_try_place()


func _update_highlight(hit: Dictionary) -> void:
	if hit.is_empty():
		_highlight.visible = false
	else:
		_highlight.visible = true
		_highlight.global_position = Vector3(hit.block_pos) + Vector3(0.5, 0.5, 0.5)


func _update_mining(hit: Dictionary, delta: float) -> void:
	var holding: bool = Input.is_action_pressed("interact_break")
	var swinging: bool = holding and not hit.is_empty() and _chunk_manager != null
	_set_player_mining(swinging)
	if not swinging:
		_reset_mining()
		return
	var target: Vector3i = hit.block_pos
	# Creative mode: instant break, ignore bedrock indestructibility, always drop
	if _is_creative():
		_creative_break(target)
		_reset_mining()
		return
	if target != _mining_target:
		_start_mining(target)
		if _mining_total_time < 0.0:
			# Unbreakable (bedrock). Bail.
			_reset_mining()
			return
	_mining_progress += delta
	# Loop the dig sound every ~300ms while mining
	var now: int = Time.get_ticks_msec()
	if now - _last_dig_sound_ms >= DIG_SOUND_INTERVAL_MS:
		_last_dig_sound_ms = now
		var id: int = _chunk_manager.get_world_block(target)
		SFX.play_break(id)
	# Update crack overlay — pick the integer stage based on progress
	var damage: float = clamp(_mining_progress / _mining_total_time, 0.0, 1.0)
	var stage: int = clamp(int(damage * float(_crack_stages)), 0, _crack_stages - 1)
	_crack.visible = true
	_crack.global_position = Vector3(target) + Vector3(0.5, 0.5, 0.5)
	_crack_material.set_shader_parameter("stage", stage)
	# Complete the break?
	if _mining_progress >= _mining_total_time:
		_complete_break(target)
		_reset_mining()


func _start_mining(target: Vector3i) -> void:
	_mining_target = target
	_mining_progress = 0.0
	_last_dig_sound_ms = 0
	var id: int = _chunk_manager.get_world_block(target)
	_mining_total_time = Blocks.break_time_bare_hand(id)


func _reset_mining() -> void:
	_mining_target = NO_TARGET
	_mining_progress = 0.0
	_mining_total_time = 0.0
	_crack.visible = false


func _complete_break(target: Vector3i) -> void:
	var broken_id: int = _chunk_manager.get_world_block(target)
	if broken_id == Blocks.AIR or broken_id == Blocks.BEDROCK:
		return
	_chunk_manager.set_world_block(target, Blocks.AIR)
	SFX.play_break(broken_id)
	# Spawn a physics-driven dropped item that the player walks over to pick up
	var dropped_id: int = Blocks.drops(broken_id)
	if dropped_id != Blocks.AIR:
		_spawn_dropped_item(target, dropped_id)


func _spawn_dropped_item(block_pos: Vector3i, dropped_id: int) -> void:
	var item := DroppedItem.new()
	var spawn_pos := Vector3(block_pos) + Vector3(0.5, 0.5, 0.5)
	_chunk_manager.add_child(item)
	item.global_position = spawn_pos
	item.setup(dropped_id)


func _creative_break(target: Vector3i) -> void:
	var broken_id: int = _chunk_manager.get_world_block(target)
	if broken_id == Blocks.AIR:
		return
	_chunk_manager.set_world_block(target, Blocks.AIR)
	SFX.play_break(broken_id)
	# Creative: skip the dropped-item dance, go straight to inventory
	var inventory: Inventory = _player_inventory()
	if inventory != null:
		inventory.add_item(broken_id, 1)


func _is_creative() -> bool:
	var player: Node = get_parent()
	if "creative_mode" in player:
		return player.get("creative_mode") as bool
	return false


func _try_place() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_place_ms < PLACE_COOLDOWN_MS:
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


func _set_player_mining(active: bool) -> void:
	var player: Node = get_parent()
	if "is_mining" in player:
		player.set("is_mining", active)


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


func _build_highlight() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 1.005
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.10)
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = StandardMaterial3D.CULL_BACK
	mi.material_override = mat
	mi.visible = false
	return mi


func _build_crack() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	# BoxMesh's default UVs split a single texture across all 6 faces with a
	# cube-unwrap layout — not what we want. Build a custom cube where each
	# face has full (0,0)-(1,1) UVs so the crack atlas samples cleanly.
	mi.mesh = _build_uv_cube_mesh(1.01)
	var tex: Texture2D = load(CRACK_ATLAS_PATH) as Texture2D
	if tex == null:
		push_error("[Crack] failed to load atlas: " + CRACK_ATLAS_PATH)
	else:
		_crack_stages = max(1, int(round(float(tex.get_height()) / float(tex.get_width()))))
		print(
			(
				"[Crack] atlas loaded: %dx%d, %d stages"
				% [tex.get_width(), tex.get_height(), _crack_stages]
			)
		)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/crack.gdshader") as Shader
	mat.set_shader_parameter("crack_atlas", tex)
	mat.set_shader_parameter("stage", 0)
	mat.set_shader_parameter("total_stages", _crack_stages)
	mi.material_override = mat
	mi.visible = false
	return mi


# Six-face cube where every face has UV (0,0)..(1,1) — needed so the crack
# shader can sample the full atlas cell per face (BoxMesh defaults split UVs).
func _build_uv_cube_mesh(size: float) -> ArrayMesh:
	var s: float = size * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Vertex orderings mirror the chunk mesher exactly (known-working winding
	# for Godot 4 cull_back). For a centered cube of given size: 0→-s, 1→+s.
	var faces: Array = [
		# +Y (top)
		[
			Vector3(-s, s, -s),
			Vector3(-s, s, s),
			Vector3(s, s, s),
			Vector3(s, s, -s),
			Vector3(0, 1, 0)
		],
		# -Y (bottom)
		[
			Vector3(-s, -s, s),
			Vector3(-s, -s, -s),
			Vector3(s, -s, -s),
			Vector3(s, -s, s),
			Vector3(0, -1, 0)
		],
		# +X (east)
		[
			Vector3(s, -s, -s),
			Vector3(s, s, -s),
			Vector3(s, s, s),
			Vector3(s, -s, s),
			Vector3(1, 0, 0)
		],
		# -X (west)
		[
			Vector3(-s, -s, s),
			Vector3(-s, s, s),
			Vector3(-s, s, -s),
			Vector3(-s, -s, -s),
			Vector3(-1, 0, 0)
		],
		# +Z (south)
		[
			Vector3(s, -s, s),
			Vector3(s, s, s),
			Vector3(-s, s, s),
			Vector3(-s, -s, s),
			Vector3(0, 0, 1)
		],
		# -Z (north)
		[
			Vector3(-s, -s, -s),
			Vector3(-s, s, -s),
			Vector3(s, s, -s),
			Vector3(s, -s, -s),
			Vector3(0, 0, -1)
		],
	]
	for face: Array in faces:
		var base: int = verts.size()
		for i: int in range(4):
			verts.append(face[i])
			norms.append(face[4])
		# Match the chunk shader's UV V-flip so face textures aren't upside-down
		uvs.append(Vector2(0, 1))
		uvs.append(Vector2(0, 0))
		uvs.append(Vector2(1, 0))
		uvs.append(Vector2(1, 1))
		# Reversed winding for Godot 4's CW-front + cull_back
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
	return mesh
