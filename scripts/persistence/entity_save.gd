class_name EntitySave
extends RefCounted

# Disk persistence for loose world entities — step 7.3 of the save/load
# plan (see .claude/save-load-plan.md). Scope today: DroppedItem only.
# FallingBlock (4-frame lifetime) and PrimedTNT (4-second fuse) are
# intentionally skipped because they're ephemeral — losing them on quit
# is fine. Future entities (Boats, Paintings, mobs) will register through
# the same dispatch table once the Entity base class lands alongside the
# Boat work in `.claude/pre-mob-roadmap.md` §2.6.
#
# On-disk layout:
#   user://<world>/entities.bin
#
# File format:
#   [4 bytes]  magic "MCAE"
#   [4 bytes]  u32 format_version = 1
#   [variable] var_to_bytes-serialized Array of per-entity dicts
#               Each dict: {type: int, payload: Dictionary}
#
# Per-type payload format is whatever the entity class returns from
# to_save_dict() / consumes via restore_from_dict(). Type IDs are stable
# (never renumber — they're persisted) and live in TYPE_* constants below.
# Append new IDs at the end as new entity classes get persistence hooks.

const _MAGIC_BYTES: Array[int] = [0x4D, 0x43, 0x41, 0x45]  # "MCAE"
const _FORMAT_VERSION: int = 1
const _HEADER_SIZE: int = 8

# Stable type IDs — persisted in the file, never renumber.
const TYPE_DROPPED_ITEM: int = 1
# Future: TYPE_FALLING_BLOCK = 2, TYPE_PRIMED_TNT = 3, TYPE_BOAT = 4,
# TYPE_PAINTING = 5, mobs from 6 upward.

# "MCAE" magic — same const-expression workaround as SaveLoad._magic.
static var _magic: PackedByteArray = PackedByteArray(_MAGIC_BYTES)

# --- Path ---


static func entities_path(world_name: String = SaveLoad.DEFAULT_WORLD) -> String:
	return "%s/entities.bin" % SaveLoad.world_dir(world_name)


# --- Save ---


# Walk every child of `parent` and serialize any that we know how to
# persist (currently DroppedItem). Writes the result to entities.bin
# atomically via the same .new → rename pattern SaveLoad uses.
# Returns the count of entities written.
static func save_all(parent: Node, world_name: String = SaveLoad.DEFAULT_WORLD) -> int:
	if parent == null:
		return 0
	_ensure_world_dir(world_name)
	var entries: Array = []
	for child in parent.get_children():
		var entry: Dictionary = _serialize_one(child)
		if not entry.is_empty():
			entries.append(entry)
	var body: PackedByteArray = var_to_bytes(entries)
	var out: PackedByteArray = PackedByteArray()
	out.resize(_HEADER_SIZE + body.size())
	for i in range(4):
		out[i] = _magic[i]
	out.encode_u32(4, _FORMAT_VERSION)
	for i in range(body.size()):
		out[_HEADER_SIZE + i] = body[i]
	if not SaveLoad.atomic_write(entities_path(world_name), out):
		return 0
	return entries.size()


# Try to serialize one node. Returns {} for unsupported types (so the
# caller can skip without burning a branch per type — keeps the dispatch
# table here, not at every callsite).
static func _serialize_one(node: Node) -> Dictionary:
	if node is DroppedItem:
		var d: DroppedItem = node
		return {"type": TYPE_DROPPED_ITEM, "payload": d.to_save_dict()}
	return {}


# --- Load ---


# Read entities.bin and respawn every entity as a child of `parent`.
# Returns the count of entities loaded. Safe to call when the file
# doesn't exist (returns 0); also resilient to a missing-main +
# .new-or-.old recovery (delegates to SaveLoad._read_with_recovery via
# the shared atomic-write contract — see crash recovery in save-load-plan §5.3).
static func load_all(parent: Node, world_name: String = SaveLoad.DEFAULT_WORLD) -> int:
	if parent == null:
		return 0
	var path: String = entities_path(world_name)
	if not FileAccess.file_exists(path):
		return 0
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[EntitySave] cannot open %s for read" % path)
		return 0
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	if bytes.size() < _HEADER_SIZE:
		push_warning("[EntitySave] %s shorter than header" % path)
		return 0
	if bytes.slice(0, 4) != _magic:
		push_warning("[EntitySave] %s: bad magic, skipping" % path)
		return 0
	var version: int = bytes.decode_u32(4)
	if version != _FORMAT_VERSION:
		push_warning("[EntitySave] %s: unknown format_version=%d, skipping" % [path, version])
		return 0
	var body: PackedByteArray = bytes.slice(_HEADER_SIZE, bytes.size())
	var parsed: Variant = bytes_to_var(body)
	if not parsed is Array:
		push_warning("[EntitySave] %s: payload not Array, skipping" % path)
		return 0
	var loaded: int = 0
	for entry: Variant in parsed:
		if not entry is Dictionary:
			continue
		if _spawn_one(entry as Dictionary, parent):
			loaded += 1
	return loaded


# Reverse of _serialize_one — dispatch on type id, spawn + restore.
# Returns true on success.
static func _spawn_one(entry: Dictionary, parent: Node) -> bool:
	var type_id: int = int(entry.get("type", 0))
	var payload: Dictionary = entry.get("payload", {}) as Dictionary
	match type_id:
		TYPE_DROPPED_ITEM:
			var item := DroppedItem.new()
			parent.add_child(item)
			item.global_position = payload.get("pos", Vector3.ZERO) as Vector3
			item.restore_from_dict(payload)
			return true
		_:
			push_warning("[EntitySave] unknown entity type_id=%d, skipping" % type_id)
			return false


# --- Cleanup helpers ---


# Delete the entities file for a world. Used when starting a fresh world
# in a previously-used slot (multi-world UI in step 7.6+) and by tests.
static func delete_entities_file(world_name: String = SaveLoad.DEFAULT_WORLD) -> bool:
	var path: String = entities_path(world_name)
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(path) == OK


static func _ensure_world_dir(world_name: String) -> void:
	var path: String = SaveLoad.world_dir(world_name)
	if DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)
