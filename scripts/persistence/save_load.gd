class_name SaveLoad
extends RefCounted

# Disk persistence for chunk data. Steps 7.1 + 7.5 of the save/load plan
# (see .claude/save-load-plan.md). Multi-world directory layout — every
# persistence call takes a `world_name` arg (default "World1" per Alpha
# le.java's slot naming). Select-World UI in step 7.6 sets Game.active_world.
#
# On-disk layout:
#   user://World1/
#     region/
#       r.0.0.bin       — region (rx=0, rz=0) covers chunks [0..31] × [0..31]
#       r.-1.0.bin      — region (rx=-1, rz=0) covers chunks [-32..-1] × [0..31]
#       ...
#   user://World2/, World3/, ... (when the UI ships)
#
# Pre-7.5 single-world data at user://world/ auto-migrates on first boot
# via migrate_legacy_world (called from Game._ready).
#
# Region file format:
#   [4 bytes]  magic "MCAC"
#   [4 bytes]  u32 format_version = 1
#   [variable] var_to_bytes-serialized Dictionary{Vector2i chunk_coord: entry_dict}
#
# Each entry_dict has the existing _saved_chunks shape from chunk_manager.gd
# (compressed PackedByteArrays for blocks / meta / sky_light / block_light /
# height_map + max_y + pending_ticks). Reusing that shape means
# chunk_manager._persist_chunk and _decode_saved_entry both stay unchanged
# above the disk layer; SaveLoad is purely a write-back for the existing
# in-memory cache.
#
# Atomic writes: temp file → fsync → rename, mirroring Alpha 1.2.6's
# cy.java:287-289 (.dat_new → rename .dat → .dat_old → rename .new → .dat).
# Crash recovery in load_region: if main file is missing but .new or .old
# exists, recover the safest one and log a warning.
#
# Region cache: per-region deserialized Dictionary kept in memory after
# first read. Avoids re-deserializing the whole region for every chunk
# load. Invalidated on save (rewritten with the updated entry).

const _FORMAT_VERSION: int = 1
const _HEADER_SIZE: int = 8  # 4 magic + 4 version

# 32 chunks per region edge → 1024 chunks per region. Bit-shifts work for
# negative coords too (Python-style arithmetic shift in GDScript).
const REGION_SHIFT: int = 5
const REGION_SIZE: int = 1 << REGION_SHIFT  # 32

# Alpha naming convention — `le.java:19-29` enumerates fixed slots
# "World1" through "World5". Multi-world UI in step 7.6 will set
# Game.active_world based on which slot the player clicks; until then
# everything stays on World1.
const DEFAULT_WORLD: String = "World1"
# Legacy directory from the pre-7.5 single-world layout. migrate_legacy_world
# renames this to DEFAULT_WORLD on boot so existing players don't lose data.
const _LEGACY_WORLD: String = "world"

# "MCAC" magic — not a const because PackedByteArray(...) isn't a constant
# expression in GDScript 4. Initialized once at class load, never mutated.
static var _magic: PackedByteArray = PackedByteArray([0x4D, 0x43, 0x41, 0x43])

# Per-region cache of deserialized chunk dicts. Key: "world|rx|rz" string
# (Vector2i can't be a Dictionary key when wrapped this deep without quirks
# in older Godot 4.x; stringly-typed is unambiguous + fast enough).
static var _region_cache: Dictionary = {}

# --- Path helpers ---


# Resolve an empty world_name to the live Game.active_world (set by
# Select-World UI). Callers that pass an explicit name get it back
# unchanged — used by tests for slot isolation. Without this, the
# multi-world UI was silently broken: defaults baked the const
# "World1" at compile time, so picking World3 in the slot list
# still routed every save to World1.
static func resolve_world(world_name: String) -> String:
	if world_name == "":
		return Game.active_world
	return world_name


static func world_dir(world_name: String = "") -> String:
	return "user://%s" % resolve_world(world_name)


static func region_dir(world_name: String = "") -> String:
	return "%s/region" % world_dir(world_name)


static func region_path(rx: int, rz: int, world_name: String = "") -> String:
	return "%s/r.%d.%d.bin" % [region_dir(world_name), rx, rz]


static func chunk_to_region(coord: Vector2i) -> Vector2i:
	# Arithmetic right shift handles negative coords correctly:
	# -1 >> 5 = -1 (chunk -1 is in region -1, not region 0).
	return Vector2i(coord.x >> REGION_SHIFT, coord.y >> REGION_SHIFT)


# --- High-level API ---


# Write a single chunk's entry dict to its region file. Reads the existing
# region (or starts empty), updates the entry for `coord`, and atomically
# rewrites the region. Returns true on success.
static func save_chunk(coord: Vector2i, entry: Dictionary, world_name: String = "") -> bool:
	if entry.is_empty():
		return false
	world_name = resolve_world(world_name)
	_ensure_region_dir(world_name)
	var rcoord: Vector2i = chunk_to_region(coord)
	var region: Dictionary = _load_region(rcoord, world_name)
	region[coord] = entry
	return _flush_region(rcoord, region, world_name)


# Read a chunk's entry from its region file. Returns an empty dict if the
# chunk has never been saved (or the region file doesn't exist).
static func load_chunk(coord: Vector2i, world_name: String = "") -> Dictionary:
	world_name = resolve_world(world_name)
	var rcoord: Vector2i = chunk_to_region(coord)
	var region: Dictionary = _load_region(rcoord, world_name)
	return region.get(coord, {})


# Flush all in-memory region caches to disk. Used by autosave + save-and-quit.
# Returns the count of regions written.
static func flush_all_regions(world_name: String = "") -> int:
	world_name = resolve_world(world_name)
	var written: int = 0
	var prefix: String = "%s|" % world_name
	for key: String in _region_cache.keys():
		if not key.begins_with(prefix):
			continue
		var parts: PackedStringArray = key.split("|")
		if parts.size() != 3:
			continue
		var rx: int = int(parts[1])
		var rz: int = int(parts[2])
		var rcoord := Vector2i(rx, rz)
		if _flush_region(rcoord, _region_cache[key], world_name):
			written += 1
	return written


# Drop the in-memory region cache. Call between tests or on world unload.
static func clear_cache() -> void:
	_region_cache.clear()


# One-shot migration from the pre-7.5 single-world layout (user://world/)
# to the multi-world layout (user://World1/). Idempotent: no-op if either
# (a) the legacy dir doesn't exist, or (b) the target dir already exists
# (we never overwrite real data). Called from Game._ready early in boot
# so the rest of the persistence stack works against the new path.
# Returns true if a migration actually happened, false otherwise.
static func migrate_legacy_world() -> bool:
	var legacy_path: String = world_dir(_LEGACY_WORLD)
	var target_path: String = world_dir(DEFAULT_WORLD)
	if not DirAccess.dir_exists_absolute(legacy_path):
		return false
	if DirAccess.dir_exists_absolute(target_path):
		push_warning(
			(
				(
					"[SaveLoad] legacy world dir %s exists alongside %s — skipping migration"
					+ " to avoid overwriting; manual cleanup needed"
				)
				% [legacy_path, target_path]
			)
		)
		return false
	var err: int = DirAccess.rename_absolute(legacy_path, target_path)
	if err != OK:
		push_error(
			"[SaveLoad] migration failed: %s → %s (err=%d)" % [legacy_path, target_path, err]
		)
		return false
	print("[SaveLoad] migrated legacy world dir to %s" % target_path)
	return true


# Total disk size of a world's directory (recursive). Returns 0 if the
# world doesn't exist. Used by the Select World screen to render the
# "World N (X.XX MB)" slot label that le.java draws.
static func world_size_bytes(world_name: String = "") -> int:
	var dir_path: String = world_dir(world_name)
	if not DirAccess.dir_exists_absolute(dir_path):
		return 0
	return _dir_size_recursive(dir_path)


# True if any data exists for this slot. Cheap shortcut around
# world_size_bytes for the empty-vs-not-empty UI test.
static func world_exists(world_name: String = "") -> bool:
	return DirAccess.dir_exists_absolute(world_dir(world_name))


static func _dir_size_recursive(path: String) -> int:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return 0
	var total: int = 0
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		var sub: String = "%s/%s" % [path, name]
		if dir.current_is_dir():
			total += _dir_size_recursive(sub)
		else:
			var f: FileAccess = FileAccess.open(sub, FileAccess.READ)
			if f != null:
				total += f.get_length()
				f.close()
		name = dir.get_next()
	dir.list_dir_end()
	return total


# Wipe a world from disk + cache. Used by Delete World UI (step 7.7) and by
# tests doing isolated setups.
static func delete_world(world_name: String = "") -> bool:
	world_name = resolve_world(world_name)
	var prefix: String = "%s|" % world_name
	for key: String in _region_cache.keys():
		if key.begins_with(prefix):
			_region_cache.erase(key)
	var dir_path: String = world_dir(world_name)
	if not DirAccess.dir_exists_absolute(dir_path):
		return true
	return _remove_dir_recursive(dir_path) == OK


# --- Internal: region load / save ---


static func _cache_key(rcoord: Vector2i, world_name: String) -> String:
	return "%s|%d|%d" % [world_name, rcoord.x, rcoord.y]


# Load a region's chunk dict from cache or disk. Returns an empty dict if
# the region has no saved chunks yet.
static func _load_region(rcoord: Vector2i, world_name: String) -> Dictionary:
	var key: String = _cache_key(rcoord, world_name)
	if _region_cache.has(key):
		return _region_cache[key]
	var path: String = region_path(rcoord.x, rcoord.y, world_name)
	var bytes: PackedByteArray = read_with_recovery(path)
	var region: Dictionary = {}
	if bytes.size() >= _HEADER_SIZE:
		var magic: PackedByteArray = bytes.slice(0, 4)
		if magic == _magic:
			var version: int = bytes.decode_u32(4)
			if version == _FORMAT_VERSION:
				var body: PackedByteArray = bytes.slice(_HEADER_SIZE, bytes.size())
				var parsed: Variant = bytes_to_var(body)
				if parsed is Dictionary:
					region = parsed
				else:
					push_warning("[SaveLoad] region %s: payload not Dictionary, skipping" % path)
			else:
				push_warning(
					"[SaveLoad] region %s: unknown format_version=%d, skipping" % [path, version]
				)
		else:
			push_warning("[SaveLoad] region %s: bad magic, skipping" % path)
	_region_cache[key] = region
	return region


# Serialize + atomic-write a region's chunk dict. Updates the cache entry.
static func _flush_region(rcoord: Vector2i, region: Dictionary, world_name: String) -> bool:
	var path: String = region_path(rcoord.x, rcoord.y, world_name)
	var body: PackedByteArray = var_to_bytes(region)
	if not pack_and_write(path, _magic, _FORMAT_VERSION, body):
		return false
	_region_cache[_cache_key(rcoord, world_name)] = region
	return true


# Shared header-+ body pack-and-write helper used by every persistence
# module that writes a magic / version / payload file (chunk regions,
# entities.bin, player.bin). Uses append_array (memcpy-style) so a full
# 4 MB region payload doesn't churn through 4M GDScript loop iterations
# like the previous byte-by-byte version did. Centralized so the
# multi-module file-format pattern stays in one place.
static func pack_and_write(
	path: String, magic: PackedByteArray, version: int, body: PackedByteArray
) -> bool:
	var header: PackedByteArray = magic.duplicate()
	var version_bytes: PackedByteArray = PackedByteArray()
	version_bytes.resize(4)
	version_bytes.encode_u32(0, version)
	header.append_array(version_bytes)
	header.append_array(body)
	return atomic_write(path, header)


# --- Atomic write + crash recovery ---


# Write bytes atomically: tmp → fsync → rename. Mirrors Alpha 1.2.6's
# cy.java:287-289 (.dat_new → rename .dat → .dat_old → rename .new → .dat).
# Returns true on success.
static func atomic_write(path: String, bytes: PackedByteArray) -> bool:
	var tmp_path: String = path + ".new"
	var old_path: String = path + ".old"
	var f: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_error(
			(
				"[SaveLoad] atomic_write: cannot open %s for write (err=%d)"
				% [tmp_path, FileAccess.get_open_error()]
			)
		)
		return false
	f.store_buffer(bytes)
	f.flush()
	f.close()
	# Move existing main file out of the way before renaming the temp in.
	if FileAccess.file_exists(path):
		var rm_old_err: int = DirAccess.remove_absolute(old_path)
		if rm_old_err != OK and FileAccess.file_exists(old_path):
			push_warning(
				"[SaveLoad] atomic_write: could not pre-clean %s (err=%d)" % [old_path, rm_old_err]
			)
		var rename_main_err: int = DirAccess.rename_absolute(path, old_path)
		if rename_main_err != OK:
			push_error(
				(
					"[SaveLoad] atomic_write: rename %s → %s failed (err=%d)"
					% [path, old_path, rename_main_err]
				)
			)
			return false
	var rename_tmp_err: int = DirAccess.rename_absolute(tmp_path, path)
	if rename_tmp_err != OK:
		push_error(
			(
				"[SaveLoad] atomic_write: rename %s → %s failed (err=%d)"
				% [tmp_path, path, rename_tmp_err]
			)
		)
		return false
	# Best-effort cleanup of the previous version. A failure here just leaves
	# a stale .old file; load_region will skip it next boot.
	if FileAccess.file_exists(old_path):
		DirAccess.remove_absolute(old_path)
	return true


# Read a file, recovering from a mid-write crash:
#   - main exists → use it (the normal path)
#   - main missing, .new exists → discard .new (was mid-write, untrusted)
#                                 and start fresh. Vanilla MC's pattern.
#   - main missing, .old exists → recover .old (atomic_write crashed between
#                                 the rename-out and the rename-in)
# Returns empty PackedByteArray when no recoverable file exists.
static func read_with_recovery(path: String) -> PackedByteArray:
	if FileAccess.file_exists(path):
		var f: FileAccess = FileAccess.open(path, FileAccess.READ)
		if f == null:
			push_warning(
				"[SaveLoad] cannot open %s for read (err=%d)" % [path, FileAccess.get_open_error()]
			)
			return PackedByteArray()
		var bytes: PackedByteArray = f.get_buffer(f.get_length())
		f.close()
		return bytes
	var new_path: String = path + ".new"
	if FileAccess.file_exists(new_path):
		push_warning(
			"[SaveLoad] %s missing but .new exists; discarding .new (crash mid-write)" % path
		)
		DirAccess.remove_absolute(new_path)
	var old_path: String = path + ".old"
	if FileAccess.file_exists(old_path):
		push_warning("[SaveLoad] %s missing but .old exists; recovering previous version" % path)
		DirAccess.rename_absolute(old_path, path)
		return read_with_recovery(path)
	return PackedByteArray()


# --- Directory helpers ---


static func _ensure_region_dir(world_name: String) -> void:
	var path: String = region_dir(world_name)
	if DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)


# Recursively remove a directory. Returns OK on success, the first error
# code on failure. Stops short of OS::move_to_trash because Godot doesn't
# expose it from script reliably across platforms.
static func _remove_dir_recursive(path: String) -> int:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return ERR_FILE_NOT_FOUND
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		var sub: String = "%s/%s" % [path, name]
		if dir.current_is_dir():
			var err: int = _remove_dir_recursive(sub)
			if err != OK:
				dir.list_dir_end()
				return err
		else:
			var err: int = DirAccess.remove_absolute(sub)
			if err != OK:
				dir.list_dir_end()
				return err
		name = dir.get_next()
	dir.list_dir_end()
	return DirAccess.remove_absolute(path)
