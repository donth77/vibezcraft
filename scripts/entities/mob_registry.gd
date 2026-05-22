class_name MobRegistry
extends RefCounted

# Mob name → script-path map. Lets the debug mob-spawner UI, the
# vanilla BlockMobSpawner tile entity, and (later) save/load look up
# the script for a configured mob without hard-coding refs everywhere.
#
# Mirrors vanilla `fq.java::a(Class, String, int)` registrations —
# the "name" string is what TileEntityMobSpawner persists as its
# `entityID` field. We omit the integer id for now since we don't have
# a persistence layer yet; once that lands we can index this list.

const _ENTRIES: Dictionary = {
	# M0 — debug placeholder. Kept around for base-mechanic regression
	# testing even after real mobs ship.
	"test_mob": "res://scripts/entities/test_mob.gd",
	# M1a — first vanilla mob. op.java port; passive, 10 HP, drops 0-2
	# raw pork. PassiveAI (wander + flee) lands in M1b.
	"pig": "res://scripts/entities/pig.gd",
	# M1b — vanilla as.java (EntityCow). Passive, 10 HP, drops 0-2
	# leather. Right-click with empty bucket → milk bucket. Uses
	# vanilla `el.java` model (head/body/legs/horns/udder).
	"cow": "res://scripts/entities/cow.gd",
	# M1c — vanilla ou.java (EntityChicken). Passive, 4 HP, drops
	# 0-2 feather + 0-2 raw_chicken (deviation, modern QoL). Lays
	# an egg every 5-10 min. Slow-fall (motionY × 0.6 per tick).
	"chicken": "res://scripts/entities/chicken.gd",
}


# Returns the Script for a registered mob name, or null if unknown.
static func script_for(name: String) -> Script:
	var path: String = _ENTRIES.get(name, "")
	if path == "":
		return null
	return load(path) as Script


# All registered mob names, sorted for stable UI ordering. Used by
# DebugMobSpawner to build its button grid.
static func names() -> Array:
	var keys: Array = _ENTRIES.keys()
	keys.sort()
	return keys


# True if the name is registered. Used by tile-entity restore from save
# to verify the persisted entity_id still maps to a known mob.
static func has(name: String) -> bool:
	return _ENTRIES.has(name)


# Reverse lookup: script path → registered name. Used by EntitySave to
# tag a live MobBase node with its mob_name so the spawner-cage and the
# `entities.bin` round-trip can both find the right Script to
# instantiate on restore. Returns "" if `script_path` isn't registered.
static func name_for_script_path(script_path: String) -> String:
	for name: String in _ENTRIES:
		if _ENTRIES[name] == script_path:
			return name
	return ""
