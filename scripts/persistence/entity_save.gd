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
# Boats. Vanilla EntityBoat — placed via right-click on water, breaks
# into planks + sticks. Persisted with pos, yaw, velocity, health.
const TYPE_BOAT: int = 4
# TYPE_MOB — single ID for ANY MobBase descendant. The mob's species
# (pig/cow/sheep/zombie/etc.) is stored in `payload.mob_name` and looked
# up via MobRegistry on restore. This indirection means adding new mob
# species doesn't require renumbering — the on-disk schema stays stable
# even as MobRegistry grows.
const TYPE_MOB: int = 6
# Paintings — wall-mounted EntityPainting (`scripts/entities/painting.gd`).
# Persisted with variant index + facing + support_pos + world pos so
# the painting reappears at exactly the same wall after reload.
const TYPE_PAINTING: int = 5
# Minecart — same persistence shape as boat (pos, yaw, velocity,
# health, has_rider). Three vanilla variants (regular/chest/furnace);
# Stage 1 only ships regular. payload.kind picks the variant at restore
# so we don't need separate TYPE_ ids when chest/furnace land.
const TYPE_MINECART: int = 7
# Future: TYPE_FALLING_BLOCK = 2, TYPE_PRIMED_TNT = 3.
# Preload Boat script for instantiation on load. Explicit GDScript
# type so `.resource_path` resolves cleanly — without the annotation
# Godot infers the type as `Boat` (the class_name the script declares)
# and rejects `.resource_path` since Boat extends CharacterBody3D
# which has no such member.
const _BOAT_SCRIPT: GDScript = preload("res://scripts/entities/boat.gd")
const _PAINTING_SCRIPT: GDScript = preload("res://scripts/entities/painting.gd")
const _MINECART_SCRIPT: GDScript = preload("res://scripts/entities/minecart.gd")

# "MCAE" magic — same const-expression workaround as SaveLoad._magic.
static var _magic: PackedByteArray = PackedByteArray(_MAGIC_BYTES)

# --- Path ---


static func entities_path(world_name: String = "") -> String:
	return "%s/entities.bin" % SaveLoad.world_dir(world_name)


# --- Save ---


# Walk every child of `parent` and serialize any that we know how to
# persist (currently DroppedItem). Writes the result to entities.bin
# atomically via the same .new → rename pattern SaveLoad uses.
# Returns the count of entities written.
static func save_all(parent: Node, world_name: String = "") -> int:
	if parent == null:
		return 0
	_ensure_world_dir(world_name)
	var entries: Array = []
	for child in parent.get_children():
		var entry: Dictionary = _serialize_one(child)
		if not entry.is_empty():
			entries.append(entry)
	var body: PackedByteArray = var_to_bytes(entries)
	if not SaveLoad.pack_and_write(entities_path(world_name), _magic, _FORMAT_VERSION, body):
		return 0
	return entries.size()


# Try to serialize one node. Returns {} for unsupported types (so the
# caller can skip without burning a branch per type — keeps the dispatch
# table here, not at every callsite).
static func _serialize_one(node: Node) -> Dictionary:
	if node is DroppedItem:
		var d: DroppedItem = node
		return {"type": TYPE_DROPPED_ITEM, "payload": d.to_save_dict()}
	# Boats — script_path comparison instead of `is Boat` because the
	# Boat class_name isn't always available outside the editor's
	# eager-loaded set.
	var script: Script = node.get_script() as Script
	if script != null and script.resource_path == _BOAT_SCRIPT.resource_path:
		return {"type": TYPE_BOAT, "payload": node.call("to_save_dict")}
	if script != null and script.resource_path == _MINECART_SCRIPT.resource_path:
		return {"type": TYPE_MINECART, "payload": node.call("to_save_dict")}
	# Paintings — same script-path comparison pattern. Walls them on
	# the same support cell + facing they were placed at; the actual
	# world position is saved too so off-by-half-cell math from the
	# placement code doesn't have to be re-derived on load.
	if script != null and script.resource_path == _PAINTING_SCRIPT.resource_path:
		return {"type": TYPE_PAINTING, "payload": node.call("to_save_dict")}
	# MobBase descendants (Pig, future Cow/Sheep/Zombie...) — single
	# TYPE_MOB record tagged with mob_name so we can dispatch via
	# MobRegistry on restore. Skip mobs whose script isn't registered
	# (defensive — registry should always cover live mobs, but a
	# rogue extends-MobBase node would otherwise crash the save).
	if node is MobBase:
		var mb: MobBase = node
		var script_res: Script = mb.get_script() as Script
		if script_res == null:
			return {}
		var mob_name: String = MobRegistry.name_for_script_path(script_res.resource_path)
		if mob_name == "":
			return {}
		var payload: Dictionary = mb.to_save_dict()
		payload["mob_name"] = mob_name
		return {"type": TYPE_MOB, "payload": payload}
	return {}


# --- Load ---


# Read entities.bin and respawn every entity as a child of `parent`.
# Returns the count of entities loaded. Safe to call when the file
# doesn't exist (returns 0); also resilient to a missing-main +
# .new-or-.old recovery (delegates to SaveLoad._read_with_recovery via
# the shared atomic-write contract — see crash recovery in save-load-plan §5.3).
static func load_all(parent: Node, world_name: String = "") -> int:
	if parent == null:
		return 0
	var path: String = entities_path(world_name)
	# read_with_recovery handles missing-main-but-.new-or-.old-exists from
	# a prior crash, same path SaveLoad uses for region files. Without it
	# a crash during save_all would silently lose entities forever.
	var bytes: PackedByteArray = SaveLoad.read_with_recovery(path)
	if bytes.is_empty():
		return 0
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
		TYPE_BOAT:
			var boat: Node3D = _BOAT_SCRIPT.new() as Node3D
			parent.add_child(boat)
			boat.call("restore_from_dict", payload)
			return true
		TYPE_MINECART:
			var cart: Node3D = _MINECART_SCRIPT.new() as Node3D
			parent.add_child(cart)
			cart.call("restore_from_dict", payload)
			return true
		TYPE_PAINTING:
			var painting: Node3D = _PAINTING_SCRIPT.new() as Node3D
			# variant + facing + support_pos must be set BEFORE add_child
			# so `_ready` builds the right mesh + collision the first time.
			painting.call(
				"setup",
				int(payload.get("variant", 0)),
				int(payload.get("facing", 0)),
				payload.get("support_pos", Vector3i.ZERO) as Vector3i
			)
			parent.add_child(painting)
			painting.global_position = payload.get("pos", Vector3.ZERO) as Vector3
			painting.call("apply_facing")
			return true
		TYPE_MOB:
			var mob_name: String = payload.get("mob_name", "") as String
			var script: Script = MobRegistry.script_for(mob_name)
			if script == null:
				push_warning("[EntitySave] unknown mob '%s', skipping" % mob_name)
				return false
			var mob: MobBase = script.new() as MobBase
			if mob == null:
				push_warning("[EntitySave] script for '%s' isn't a MobBase" % mob_name)
				return false
			parent.add_child(mob)
			# Position must be set BEFORE restore_from_dict — _ready ran
			# during add_child and may have already touched physics state
			# at the default (0,0,0) position. restore overwrites pos
			# from the dict so the final position is correct.
			mob.restore_from_dict(payload)
			return true
		_:
			push_warning("[EntitySave] unknown entity type_id=%d, skipping" % type_id)
			return false


# --- Cleanup helpers ---


# Delete the entities file for a world. Used when starting a fresh world
# in a previously-used slot (multi-world UI in step 7.6+) and by tests.
static func delete_entities_file(world_name: String = "") -> bool:
	var path: String = entities_path(world_name)
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(path) == OK


static func _ensure_world_dir(world_name: String) -> void:
	var path: String = SaveLoad.world_dir(world_name)
	if DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)
