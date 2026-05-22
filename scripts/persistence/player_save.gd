class_name PlayerSave
extends RefCounted

# Per-world player state — step 7.4 of the save/load plan (see
# .claude/save-load-plan.md §4.6). Persists position, head rotation,
# health, and the full 45-slot inventory (hotbar + main + armor + craft
# grid + result) so quitting + relaunching resumes the player exactly
# where they were.
#
# On-disk layout:
#   user://<world>/player.bin
#
# Format (var_to_bytes blob with explicit header):
#   [4 bytes]  magic "MCAP"
#   [4 bytes]  u32 format_version = 1
#   [variable] var_to_bytes-serialized Dictionary {
#                pos: Vector3,
#                yaw: float, pitch: float,    -- head rotation only
#                health: int,
#                hotbar_selected: int,
#                inventory: Array[Array[3 ints]]
#                              -- per slot: [item_id, count, damage]
#              }
#
# Transient fields skipped on save (rebuilt fresh on load):
#   velocity, _fall_peak_y, _fire_remaining_sec, all mining/swing state,
#   creative_mode, perspective. These either reset cleanly or are debug
#   toggles a saved load shouldn't pick up across sessions.
#
# Vec3i spawn point lives in world.json (it's per-world, not per-player —
# beds in §2.10 of pre-mob-roadmap will move it to per-player later).

const _MAGIC_BYTES: Array[int] = [0x4D, 0x43, 0x41, 0x50]  # "MCAP"
const _FORMAT_VERSION: int = 1
const _HEADER_SIZE: int = 8

# "MCAP" magic — same const-expression workaround as the other persistence modules.
static var _magic: PackedByteArray = PackedByteArray(_MAGIC_BYTES)

# --- Path ---


static func player_path(world_name: String = "") -> String:
	return "%s/player.bin" % SaveLoad.world_dir(world_name)


# --- Save ---


# Snapshot the player's persistent state and write it to disk. Returns
# true on success.
static func save_player(player: Node3D, world_name: String = "") -> bool:
	if player == null:
		return false
	_ensure_world_dir(world_name)
	var payload: Dictionary = _build_payload(player)
	var body: PackedByteArray = var_to_bytes(payload)
	return SaveLoad.pack_and_write(player_path(world_name), _magic, _FORMAT_VERSION, body)


static func _build_payload(player: Node3D) -> Dictionary:
	var inv: Inventory = player.get("inventory") as Inventory
	var slots_out: Array = []
	if inv != null:
		slots_out.resize(Inventory.TOTAL_SIZE)
		for i in range(Inventory.TOTAL_SIZE):
			var stack: ItemStack = inv.slots[i]
			if stack == null:
				slots_out[i] = [0, 0, 0]
			else:
				slots_out[i] = [stack.item_id, stack.count, stack.damage]
	# Camera pitch lives on the player's "Camera3D" child (see player.gd's
	# _apply_mouse_motion + the @onready _camera). Yaw is on the player
	# Node3D itself (rotate_y in _apply_mouse_motion).
	var camera: Camera3D = player.get_node_or_null("Camera3D") as Camera3D
	var yaw: float = player.rotation.y
	var pitch: float = camera.rotation.x if camera != null else 0.0
	return {
		"pos": player.global_position,
		"yaw": yaw,
		"pitch": pitch,
		"health": int(player.get("health")) if "health" in player else 20,
		"hotbar_selected": inv.selected_slot if inv != null else 0,
		"inventory": slots_out,
	}


# --- Load ---


# Restore the player from disk. Mutates the passed Node3D in-place.
# Returns true on success, false on missing/malformed file (leaves the
# player at its default-spawn position so the caller can detect fresh
# worlds with player_save.load_player(...) == false).
static func load_player(player: Node3D, world_name: String = "") -> bool:
	if player == null:
		return false
	var path: String = player_path(world_name)
	# Crash-recovery aware read via SaveLoad.read_with_recovery (same
	# .new/.old fallback the region loader uses).
	var bytes: PackedByteArray = SaveLoad.read_with_recovery(path)
	if bytes.is_empty():
		return false
	if bytes.size() < _HEADER_SIZE:
		push_warning("[PlayerSave] %s shorter than header" % path)
		return false
	if bytes.slice(0, 4) != _magic:
		push_warning("[PlayerSave] %s: bad magic, skipping" % path)
		return false
	var version: int = bytes.decode_u32(4)
	if version != _FORMAT_VERSION:
		push_warning("[PlayerSave] %s: unknown format_version=%d, skipping" % [path, version])
		return false
	var body: PackedByteArray = bytes.slice(_HEADER_SIZE, bytes.size())
	var parsed: Variant = bytes_to_var(body)
	if not parsed is Dictionary:
		push_warning("[PlayerSave] %s: payload not Dictionary, skipping" % path)
		return false
	_apply_payload(player, parsed as Dictionary)
	return true


static func _apply_payload(player: Node3D, payload: Dictionary) -> void:
	player.global_position = payload.get("pos", Vector3.ZERO) as Vector3
	player.rotation.y = float(payload.get("yaw", 0.0))
	var camera: Camera3D = player.get_node_or_null("Camera3D") as Camera3D
	if camera != null:
		camera.rotation.x = float(payload.get("pitch", 0.0))
	if "health" in player:
		player.set("health", int(payload.get("health", 20)))
	var inv: Inventory = player.get("inventory") as Inventory
	if inv != null:
		var slots_in: Array = payload.get("inventory", []) as Array
		for i in range(min(slots_in.size(), Inventory.TOTAL_SIZE)):
			var entry: Array = slots_in[i]
			var stack := ItemStack.new(int(entry[0]), int(entry[1]))
			stack.damage = int(entry[2])
			inv.slots[i] = stack
		inv.selected_slot = int(payload.get("hotbar_selected", 0))
		# Direct slot mutation bypasses Inventory's normal setters, which
		# would emit `changed` themselves. Emit once here so subscribers
		# (hotbar UI, held-item mesh, armor overlay) repaint after load.
		inv.changed.emit()


# --- Cleanup ---


static func delete_player_file(world_name: String = "") -> bool:
	var path: String = player_path(world_name)
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(path) == OK


static func _ensure_world_dir(world_name: String) -> void:
	var path: String = SaveLoad.world_dir(world_name)
	if DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)
