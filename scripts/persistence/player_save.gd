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


static func player_path(world_name: String = SaveLoad.DEFAULT_WORLD) -> String:
	return "%s/player.bin" % SaveLoad.world_dir(world_name)


# --- Save ---


# Snapshot the player's persistent state and write it to disk. Returns
# true on success.
static func save_player(player: Node3D, world_name: String = SaveLoad.DEFAULT_WORLD) -> bool:
	if player == null:
		return false
	_ensure_world_dir(world_name)
	var payload: Dictionary = _build_payload(player)
	var body: PackedByteArray = var_to_bytes(payload)
	var out: PackedByteArray = PackedByteArray()
	out.resize(_HEADER_SIZE + body.size())
	for i in range(4):
		out[i] = _magic[i]
	out.encode_u32(4, _FORMAT_VERSION)
	for i in range(body.size()):
		out[_HEADER_SIZE + i] = body[i]
	return SaveLoad.atomic_write(player_path(world_name), out)


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
	# Head rotation: the player's camera/head is a child node usually
	# named "Head"; fall back to the body yaw if not present so the save
	# still survives a missing-head edge case.
	var head: Node3D = player.get_node_or_null("Head") as Node3D
	var yaw: float = player.rotation.y
	var pitch: float = head.rotation.x if head != null else 0.0
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
static func load_player(player: Node3D, world_name: String = SaveLoad.DEFAULT_WORLD) -> bool:
	if player == null:
		return false
	var path: String = player_path(world_name)
	if not FileAccess.file_exists(path):
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[PlayerSave] cannot open %s for read" % path)
		return false
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
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
	var head: Node3D = player.get_node_or_null("Head") as Node3D
	if head != null:
		head.rotation.x = float(payload.get("pitch", 0.0))
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


# --- Cleanup ---


static func delete_player_file(world_name: String = SaveLoad.DEFAULT_WORLD) -> bool:
	var path: String = player_path(world_name)
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(path) == OK


static func _ensure_world_dir(world_name: String) -> void:
	var path: String = SaveLoad.world_dir(world_name)
	if DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)
