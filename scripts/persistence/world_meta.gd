class_name WorldMeta
extends RefCounted

# Per-world metadata (seed, time-of-day, spawn point, version stamps) —
# step 7.4 of the save/load plan (see .claude/save-load-plan.md §4.2).
# Stored as human-readable JSON at user://<world>/world.json so it can be
# eyeballed in a text editor when something looks off.
#
# Schema (current format_version = 1):
#   {
#     "format_version": 1,
#     "seed": <int>,
#     "time_ticks": <int>,                  -- WorldTime cycle position (0..23999)
#     "spawn": {"x": <int>, "y": <int>, "z": <int>},
#     "created_at": "2026-05-20T14:23:00Z", -- ISO 8601, set on world creation
#     "last_played": "2026-05-20T16:11:42Z",-- updated on every save
#     "play_time_seconds": <int>,           -- cumulative real-time playtime
#     "clone_version": "0.1"
#   }
#
# Missing or older formats: load_meta returns an empty Dictionary +
# push_warning; caller falls back to defaults (matches the "fresh world"
# code path in Game._ready). New keys can be added without bumping version
# — only breaking changes require it.

const _FORMAT_VERSION: int = 1
const CLONE_VERSION: String = "0.1"

# --- Path ---


static func meta_path(world_name: String = "") -> String:
	return "%s/world.json" % SaveLoad.world_dir(world_name)


# --- Save / Load ---


# Write the world's metadata. `meta` is the same dict load_meta returns —
# pass through the loaded one with updated fields. Always rewrites
# last_played + format_version + clone_version so callers don't have to
# remember to.
static func save_meta(meta: Dictionary, world_name: String = "") -> bool:
	_ensure_world_dir(world_name)
	var to_write: Dictionary = meta.duplicate(true)
	to_write["format_version"] = _FORMAT_VERSION
	to_write["clone_version"] = CLONE_VERSION
	to_write["last_played"] = _now_iso8601()
	if not to_write.has("created_at"):
		to_write["created_at"] = to_write["last_played"]
	var json: String = JSON.stringify(to_write, "  ")
	return SaveLoad.atomic_write(meta_path(world_name), json.to_utf8_buffer())


# Read world.json. Returns the parsed Dictionary, or an empty Dictionary
# if the file is missing / malformed / unrecognized format. Empty result
# is the "this is a fresh world" signal — caller picks defaults.
static func load_meta(world_name: String = "") -> Dictionary:
	var path: String = meta_path(world_name)
	# Crash-recovery aware read via SaveLoad.read_with_recovery (same
	# .new/.old fallback the region + entity + player loaders use).
	var bytes: PackedByteArray = SaveLoad.read_with_recovery(path)
	if bytes.is_empty():
		return {}
	var text: String = bytes.get_string_from_utf8()
	# JSON.new().parse(...) instead of JSON.parse_string: the static helper
	# logs an engine-level ERROR on malformed input, which GUT treats as a
	# test failure. The instance API returns the error code quietly.
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK or not json.data is Dictionary:
		push_warning(
			"[WorldMeta] %s: not parseable as a JSON object (err=%d), skipping" % [path, err]
		)
		return {}
	var meta: Dictionary = json.data
	var version: int = int(meta.get("format_version", 0))
	if version != _FORMAT_VERSION:
		push_warning(
			(
				"[WorldMeta] %s: unknown format_version=%d (expected %d), skipping"
				% [path, version, _FORMAT_VERSION]
			)
		)
		return {}
	return meta


# Convenience: build a fresh meta dict for a brand-new world. Callers
# pass the seed they're about to use + the spawn they picked + the
# current world time.
static func make_initial(seed_value: int, spawn: Vector3i, time_ticks: int) -> Dictionary:
	return {
		"format_version": _FORMAT_VERSION,
		"seed": seed_value,
		"time_ticks": time_ticks,
		"spawn": {"x": spawn.x, "y": spawn.y, "z": spawn.z},
		"created_at": _now_iso8601(),
		"last_played": _now_iso8601(),
		"play_time_seconds": 0,
		"clone_version": CLONE_VERSION,
	}


# --- Helpers ---


static func _now_iso8601() -> String:
	# Time.get_datetime_string_from_system(true) returns UTC in
	# "YYYY-MM-DDTHH:MM:SS" form — add the trailing Z to make it
	# valid ISO 8601 UTC.
	return Time.get_datetime_string_from_system(true) + "Z"


static func _ensure_world_dir(world_name: String) -> void:
	var path: String = SaveLoad.world_dir(world_name)
	if DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)
