class_name BlockFire
extends RefCounted

# Fire block behavior — direct port of Beta BlockFire.java (verified
# against Bukkit/mc-dev mirror). Beta's BlockFire is the canonical
# reference for fire spread + per-block flammability; Alpha 1.2.6's
# qh.java is structurally identical but pre-dated Beta-era tweaks.
#
# Two per-block-id tables drive everything:
#   chanceToEncourageFire[id] — how much this block contributes to the
#     fire-spread probability for nearby AIR cells (higher = neighbors
#     are more likely to ignite).
#   abilityToCatchFire[id] — how easily this block IS replaced by fire
#     when a flame tries to consume it (`tryToCatchBlockOnFire`).
#
# Vanilla Beta values ported below for the 3 flammables we currently
# have (LOG, PLANKS, LEAVES). When TNT / WOOL / BOOKSHELF land, add
# their entries to _build_flammability_tables.

const TICK_RATE: int = 10  # Beta tickRate() = 10 ticks (0.5 s)
const MAX_AGE: int = 15

# Beta per-block tables (chance_to_encourage / ability_to_catch).
# Block.planks(7) -> 5/20, Block.wood(17 = LOG) -> 5/5,
# Block.leaves(18 = LEAVES) -> 30/60.
static var _encourage: Dictionary = {}
static var _catch: Dictionary = {}
static var _tables_built: bool = false


# Initialize the per-block flammability tables. Idempotent — guarded
# by _tables_built so repeated calls don't re-allocate.
static func _ensure_tables() -> void:
	if _tables_built:
		return
	_encourage[Blocks.PLANKS] = 5
	_catch[Blocks.PLANKS] = 20
	_encourage[Blocks.LOG] = 5
	_catch[Blocks.LOG] = 5
	_encourage[Blocks.LEAVES] = 30
	_catch[Blocks.LEAVES] = 60
	_tables_built = true


static func _can_block_catch_fire(id: int) -> bool:
	_ensure_tables()
	return _encourage.get(id, 0) > 0


# Beta `getChanceToEncourageFire` — returns max(table[id], var5).
# Used by getChanceOfNeighborsEncouragingFire to find the strongest
# adjacent encourager.
static func _get_chance_to_encourage_fire(id: int, current_max: int) -> int:
	_ensure_tables()
	var v: int = _encourage.get(id, 0) as int
	return v if v > current_max else current_max


# Beta `getChanceOfNeighborsEncouragingFire`: sums max chance across
# 6 cardinal neighbors. Returns 0 if the cell isn't AIR.
static func _get_chance_of_neighbors_encouraging_fire(manager, pos: Vector3i) -> int:
	if manager.get_world_block(pos) != Blocks.AIR:
		return 0
	var v: int = 0
	for o: Vector3i in [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]:
		v = _get_chance_to_encourage_fire(manager.get_world_block(pos + o), v)
	return v


# Beta `canNeighborBurn` — true if any of the 6 neighbors is in the
# encourage table (i.e. provides fuel).
static func _can_neighbor_burn(manager, pos: Vector3i) -> bool:
	for o: Vector3i in [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]:
		if _can_block_catch_fire(manager.get_world_block(pos + o)):
			return true
	return false


# Beta `tryToCatchBlockOnFire(world, x, y, z, var5, rand)` — direct port.
# var5 is the random max (300 lateral, 200 down, 250 up); abilityToCatchFire
# rolls < var5 to ignite. On hit: 50/50 between FIRE and AIR (the AIR
# branch is vanilla's "burn out without leaving fire" path for blocks
# with high catch + low encourage like wood).
static func _try_to_catch_block_on_fire(manager, target: Vector3i, var5: int) -> void:
	_ensure_tables()
	var id: int = manager.get_world_block(target)
	var ability: int = _catch.get(id, 0) as int
	if ability <= 0:
		return
	if randi() % var5 >= ability:
		return
	if randi() % 2 == 0:
		manager.set_world_block_with_meta(target, Blocks.FIRE, 0)
		TickScheduler.schedule(target, Blocks.FIRE, TICK_RATE)
	else:
		manager.set_world_block(target, Blocks.AIR)


# Entry point from Blocks.on_scheduled_tick — direct port of Beta
# BlockFire.updateTick (qh.java:51-93). Sequence:
#   1. Bump age (cap at 15).
#   2. If no neighbor can burn: extinguish (with floor-not-solid OR
#      age>3 condition).
#   3. If support-below isn't flammable and age==15 and 1/4 roll:
#      extinguish (high-age burnout).
#   4. If `age % 2 == 0 && age > 2` (gated):
#      a. tryToCatchBlockOnFire on each of 6 neighbors at var5 ∈
#         {300 lateral, 200 below, 250 above, 300 lateral}.
#      b. 3×3×6 spread box around fire — for each AIR cell with
#         non-zero neighbor encouragement, ignite if rand < chance.
#         Vertical decay: var10 = 100 + (y-y0-1)*100 above y0+1.
static func update(manager, pos: Vector3i) -> void:
	_ensure_tables()
	var current_id: int = manager.get_world_block(pos)
	if current_id != Blocks.FIRE:
		return
	var age: int = manager.get_world_block_meta(pos)
	# Step 1 — age bump.
	if age < MAX_AGE:
		manager.set_world_block_with_meta(pos, Blocks.FIRE, age + 1)
		TickScheduler.schedule(pos, Blocks.FIRE, TICK_RATE)
	# Step 2 — no neighbor to burn: maybe extinguish.
	if not _can_neighbor_burn(manager, pos):
		var below: int = manager.get_world_block(pos + Vector3i(0, -1, 0))
		if not Blocks.is_opaque(below) or age > 3:
			manager.set_world_block(pos, Blocks.AIR)
		return
	# Step 3 — high-age burnout when nothing flammable below.
	var below_id: int = manager.get_world_block(pos + Vector3i(0, -1, 0))
	if not _can_block_catch_fire(below_id) and age == MAX_AGE and randi() % 4 == 0:
		manager.set_world_block(pos, Blocks.AIR)
		return
	# Step 4 — only spread on every-other-tick after age 2.
	if not (age % 2 == 0 and age > 2):
		return
	# 4a — direct-neighbor catch attempts. Beta var5 values: 300 / 300
	# lateral, 200 below, 250 above, 300 / 300 lateral.
	_try_to_catch_block_on_fire(manager, pos + Vector3i(1, 0, 0), 300)
	_try_to_catch_block_on_fire(manager, pos + Vector3i(-1, 0, 0), 300)
	_try_to_catch_block_on_fire(manager, pos + Vector3i(0, -1, 0), 200)
	_try_to_catch_block_on_fire(manager, pos + Vector3i(0, 1, 0), 250)
	_try_to_catch_block_on_fire(manager, pos + Vector3i(0, 0, -1), 300)
	_try_to_catch_block_on_fire(manager, pos + Vector3i(0, 0, 1), 300)
	# 4b — 3×3×6 spread box (Beta qh.java:75-89). For each AIR cell, sum
	# neighbor-encouragement and roll. Vertical layers above pos.y+1 add
	# 100*(dy-1) to the rand max, decaying upward spread.
	for dx: int in range(-1, 2):
		for dz: int in range(-1, 2):
			for dy: int in range(-1, 5):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var target: Vector3i = pos + Vector3i(dx, dy, dz)
				var rand_max: int = 100
				if dy > 1:
					rand_max += (dy - 1) * 100
				var chance: int = _get_chance_of_neighbors_encouraging_fire(manager, target)
				if chance > 0 and randi() % rand_max <= chance:
					manager.set_world_block_with_meta(target, Blocks.FIRE, 0)
					TickScheduler.schedule(target, Blocks.FIRE, TICK_RATE)


# Place a fresh FIRE cell at `pos` and schedule its first tick. Called
# from lava ignition. Idempotent (no-op if not AIR).
static func ignite(manager, pos: Vector3i) -> void:
	if manager.get_world_block(pos) != Blocks.AIR:
		return
	manager.set_world_block_with_meta(pos, Blocks.FIRE, 0)
	TickScheduler.schedule(pos, Blocks.FIRE, TICK_RATE)
