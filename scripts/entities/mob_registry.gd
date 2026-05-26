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
	# M2 — vanilla bx.java (EntitySheep). Passive, 10 HP. Drops 1-3
	# wool ONCE on first damage (Alpha first-hit shed mechanic) OR via
	# right-click with Beta SHEARS item (no damage variant).
	"sheep": "res://scripts/entities/sheep.gd",
	# M3 — vanilla lk.java (EntityZombie). First hostile mob. 20 HP,
	# 3-damage melee, daylight burn, drops 0-2 feather (Alpha 1.2.6
	# vanilla; Beta 1.8 swapped to rotten flesh). HostileAI = target +
	# chase + melee, reuses Pathfinder.find_path from the passives.
	"zombie": "res://scripts/entities/zombie.gd",
	# M4 — vanilla nq.java (EntitySkeleton). Second hostile, RANGED.
	# 20 HP, kites at bow range [4, 10] m, charges 1.5 s then fires an
	# Arrow at the player's torso. Drops 0-2 bone + 0-2 arrow.
	# Daylight burn (same as zombie).
	"skeleton": "res://scripts/entities/skeleton.gd",
	# M5 — vanilla be.java (EntitySpider). Light-gated hostile (neutral
	# in bright light, targets nearest player ≤ 16 m when brightness
	# < 0.5). 16 HP, 2-damage melee, drops 0-2 string. No daylight burn.
	# Pounces toward the player at 2-6 m range instead of Beta's wall
	# climb (Alpha be.java has no climbable-block flag).
	"spider": "res://scripts/entities/spider.gd",
	# M6 — vanilla ns.java (EntitySlime). Hops, splits on death, only
	# spawns in "slime chunks" (1-in-10 by world seed) below Y=16.
	# Light-independent: vanilla `ns.a()` skips the hostile light gate,
	# so slimes can spawn in lit caves. Sizes 1/2/4 with HP = size².
	# Size-1 drops slimeballs; larger drop nothing directly and split
	# into 4 half-size children on death.
	"slime": "res://scripts/entities/slime.gd",
	# M7 — vanilla dq.java (EntityCreeper). Chases the player, ignites
	# at 3 m proximity, detonates 30 ticks later at power 3.0. Drops
	# 0-2 gunpowder. Iconic + dangerous; standard hostile spawn.
	"creeper": "res://scripts/entities/creeper.gd",
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
