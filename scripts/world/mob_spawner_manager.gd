class_name MobSpawnerManager
extends RefCounted

const _MOB_REGISTRY: GDScript = preload("res://scripts/entities/mob_registry.gd")
const _MOB_BASE: GDScript = preload("res://scripts/entities/mob_base.gd")

# Tile-entity logic for BlockMobSpawner (id MOB_SPAWNER). Mirrors vanilla
# `kk.java::TileEntityMobSpawner.b()`:
#
#   * Per-block state: which mob to spawn (`entityID` in vanilla).
#   * Per-tick check: if player within 16 m, roll 4 spawn attempts;
#     each picks a random offset within 8 m, spawns the configured mob
#     if the cell is AIR with valid floor.
#   * Spawn cooldown: 10–40 s between cycles (vanilla uses 200–800 ticks).
#
# State is held in a single static dictionary keyed by world position.
# ChunkManager.set_world_block is responsible for clearing the entry
# when a MOB_SPAWNER cell is broken or replaced (otherwise we'd keep
# scheduling ticks for a defunct spawner).

# Distance from player below which a spawner runs its tick (matches
# vanilla `kk.java:32` `requiredPlayerRange = 16`).
const PLAYER_ACTIVATION_RADIUS: float = 16.0

# Square of activation radius — squared compare is faster than
# Vector3.distance_to() per tick.
const _ACTIVATION_RADIUS_SQ: float = PLAYER_ACTIVATION_RADIUS * PLAYER_ACTIVATION_RADIUS

# Spawn box: vanilla samples a random offset of (±4 X, ±1 Y, ±4 Z) from
# the spawner cell. Anywhere in that box that's AIR with a valid floor
# is a candidate. We use a slightly tighter 4×2×4 to keep spawns
# clearly within debug-visible range.
const _SPAWN_RANGE_X: int = 4
const _SPAWN_RANGE_Y: int = 1
const _SPAWN_RANGE_Z: int = 4

# Per-tick spawn attempt count (vanilla rolls 4).
const _ATTEMPTS_PER_TICK: int = 4

# Soft cap: don't spawn if there are already this many of the
# configured mob within the activation radius. Vanilla caps at 6.
const _NEARBY_MOB_CAP: int = 6

# Vanilla tick delay range: 200–800 game ticks = 10–40 s at 20 TPS.
# TickScheduler uses tick units (1 tick = 50 ms).
const _MIN_DELAY_TICKS: int = 200
const _MAX_DELAY_TICKS: int = 800

# Initial-tick delay after the player places a cage via the F6 debug UI.
# Vanilla rolls 200-800 ticks for the first tick which is too slow for
# "place a cage, see it work" testing. 20 ticks = 1 s gives the player
# a beat to see the cage land before the first mob appears — and the
# first spawn goes through the normal spawn-box randomization (NOT on
# top of the cage), so the mob shows up in a natural-looking spot.
const _FIRST_TICK_DELAY: int = 20

# Per-spawner state. Keyed by world Vector3i, value = { mob_name: String }.
# Idempotent: configure() overwrites, clear() removes.
static var _spawners: Dictionary = {}

# Cached player ref — refreshed when null or invalid. Saves a tree
# lookup per on_tick call (with N spawners and 0.5-4 ticks/sec, this
# would otherwise be N tree-path-resolves per second).
static var _player_cache: Node3D = null


# Register (or update) a mob spawner at `pos` with the given mob name.
# Schedules the first tick at _FIRST_TICK_DELAY (1 s). Caller is
# responsible for actually writing the MOB_SPAWNER block at `pos` via
# ChunkManager.set_world_block.
static func configure(pos: Vector3i, mob_name: String) -> void:
	if not _MOB_REGISTRY.has(mob_name):
		push_warning("[mob_spawner] unknown mob name: %s" % mob_name)
		return
	_spawners[pos] = {"mob_name": mob_name}
	TickScheduler.schedule(pos, Blocks.MOB_SPAWNER, _FIRST_TICK_DELAY)


# Clear the entry — called by ChunkManager when the cell is broken.
# No-op if `pos` wasn't configured.
static func clear(pos: Vector3i) -> void:
	_spawners.erase(pos)


# --- Persistence hooks ---


# Returns {Vector3i_local: mob_name_string} for every spawner whose
# world coord falls inside the chunk at `chunk_coord`. Used by
# ChunkManager._persist_chunk to bundle the configured mob type into
# the saved chunk's tile_entities dict. Mirrors ChestStorage's API.
static func serialize_chunk(chunk_coord: Vector2i) -> Dictionary:
	var result: Dictionary = {}
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	for world_pos: Vector3i in _spawners.keys():
		if world_pos.x < min_x or world_pos.x >= max_x:
			continue
		if world_pos.z < min_z or world_pos.z >= max_z:
			continue
		var local_pos := Vector3i(world_pos.x - min_x, world_pos.y, world_pos.z - min_z)
		result[local_pos] = _spawners[world_pos].get("mob_name", "")
	return result


# Drop every spawner in the given chunk from the live store. Called
# by ChunkManager._persist_chunk right after serialize_chunk so the
# unloaded chunk's tile entities don't linger in memory.
static func forget_chunk(chunk_coord: Vector2i) -> void:
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	var to_remove: Array[Vector3i] = []
	for world_pos: Vector3i in _spawners.keys():
		if world_pos.x < min_x or world_pos.x >= max_x:
			continue
		if world_pos.z < min_z or world_pos.z >= max_z:
			continue
		to_remove.append(world_pos)
	for pos: Vector3i in to_remove:
		_spawners.erase(pos)


# Inverse of serialize_chunk. `dict` is {Vector3i_local:
# mob_name_string}. Called from ChunkManager._materialize_chunk after
# a saved chunk loads.
#
# We DON'T call `configure` here because configure schedules a new
# first-tick (1 s), which would stack on top of the spawner's ORIGINAL
# pending tick that ChunkManager already restored via
# `TickScheduler.restore_ticks` (chunk_manager.gd:505, fires BEFORE this
# restore). Doing both produces two scheduled ticks per spawner and
# resets the cooldown to 1 s on every reload — a save-scum. Just
# populate the dict; the existing tick will fire on its rolled delay.
static func restore_chunk(chunk_coord: Vector2i, dict: Dictionary) -> void:
	var origin_x: int = chunk_coord.x * Chunk.SIZE_X
	var origin_z: int = chunk_coord.y * Chunk.SIZE_Z
	for local_pos: Vector3i in dict.keys():
		var world_pos := Vector3i(origin_x + local_pos.x, local_pos.y, origin_z + local_pos.z)
		var mob_name: String = str(dict[local_pos])
		if mob_name.is_empty():
			continue
		if not _MOB_REGISTRY.has(mob_name):
			push_warning("[mob_spawner] unknown mob name on restore: %s" % mob_name)
			continue
		_spawners[world_pos] = {"mob_name": mob_name}


# Wipe all in-memory spawner entries. Called from ChunkManager._ready
# (new world load) so leftover entries from the previous world don't
# leak — without this, switching from World 1 to World 2 keeps old
# spawner positions in _spawners, and they self-clean lazily on first
# on_tick (one wasted scheduling cycle per stale entry). Same pattern
# as ChestStorage/JukeboxStorage would benefit from but is broader
# than this feature.
static func clear_all() -> void:
	_spawners.clear()
	_player_cache = null


# Fired by Blocks.on_scheduled_tick → BlockTickDispatcher.
# Tries to spawn mobs, then re-schedules another tick.
static func on_tick(manager: Node, pos: Vector3i) -> void:
	if not _spawners.has(pos):
		return  # Cleared between schedule and fire; drop the tick.
	# Sanity-check the cell still holds a spawner — handles the case
	# where set_world_block wrote something else before this tick fired.
	if manager.get_world_block(pos) != Blocks.MOB_SPAWNER:
		_spawners.erase(pos)
		return
	# Player-distance gate: vanilla skips tile-entity processing for
	# spawners with no player within 16 m. We re-schedule with a long
	# delay so it doesn't burn CPU. Player ref is cached to skip the
	# get_node tree lookup on every tick.
	var player: Node3D = _get_player(manager)
	if player == null:
		_reschedule(pos)
		return
	var d_sq: float = player.global_position.distance_squared_to(Vector3(pos))
	if d_sq > _ACTIVATION_RADIUS_SQ:
		_reschedule(pos)
		return
	var entry: Dictionary = _spawners[pos]
	var mob_name: String = entry.get("mob_name", "") as String
	var mob_script: Script = _MOB_REGISTRY.script_for(mob_name)
	if mob_script == null:
		_reschedule(pos)
		return
	# Count nearby mobs of the same type — bail if at cap.
	var nearby: int = _count_nearby_mobs(manager, pos, mob_script)
	if nearby >= _NEARBY_MOB_CAP:
		_reschedule(pos)
		return
	# Try `_ATTEMPTS_PER_TICK` spawn rolls. Each picks a random offset
	# and spawns there if the cell is AIR with a valid floor.
	for _i in range(_ATTEMPTS_PER_TICK):
		_try_spawn_at_random(manager, pos, mob_script)
	_reschedule(pos)


static func _reschedule(pos: Vector3i) -> void:
	var delay: int = randi_range(_MIN_DELAY_TICKS, _MAX_DELAY_TICKS)
	TickScheduler.schedule(pos, Blocks.MOB_SPAWNER, delay)


# Counts mobs matching `mob_script` within the activation radius of
# `pos`. Walks the static MobBase._active_mobs registry (bounded by the
# game-wide spawn cap, ~70 mobs max) instead of chunk_manager's full
# children list — which scales with chunk count, dropped items, falling
# blocks, etc., none of which can ever match the mob_script filter.
# `manager` arg is unused now but kept in the signature for future-
# proofing (per-chunk indexing if we add it later).
static func _count_nearby_mobs(_manager: Node, pos: Vector3i, mob_script: Script) -> int:
	var center: Vector3 = Vector3(pos)
	var count: int = 0
	for mob in _MOB_BASE.active_mobs().values():
		if not is_instance_valid(mob):
			continue
		if mob.get_script() != mob_script:
			continue
		if (mob as Node3D).global_position.distance_squared_to(center) <= _ACTIVATION_RADIUS_SQ:
			count += 1
	return count


# Cached player ref. Re-resolves only when null or stale (e.g. after a
# scene reload). Saves the tree-walk on every on_tick call.
static func _get_player(manager: Node) -> Node3D:
	if _player_cache != null and is_instance_valid(_player_cache):
		return _player_cache
	_player_cache = manager.get_tree().root.get_node_or_null("Main/Player") as Node3D
	return _player_cache


# One spawn attempt: random offset, check AIR + floor, then drop the
# mob in via add_child + global_position.
static func _try_spawn_at_random(manager: Node, pos: Vector3i, mob_script: Script) -> void:
	var dx: int = randi_range(-_SPAWN_RANGE_X, _SPAWN_RANGE_X)
	var dy: int = randi_range(-_SPAWN_RANGE_Y, _SPAWN_RANGE_Y)
	var dz: int = randi_range(-_SPAWN_RANGE_Z, _SPAWN_RANGE_Z)
	var target := pos + Vector3i(dx, dy, dz)
	# Cell at `target` (and the one above) must be passable — AIR or
	# snow_layer. Vanilla snow_layer is a thin 2-pixel slab that mobs
	# stand "in" rather than on top of (Material.snow with isReplaceable),
	# so it counts as a valid spawn cell. Without this exception,
	# spawners next to snow-covered terrain reject every candidate.
	var target_id: int = manager.get_world_block(target)
	if target_id != Blocks.AIR and target_id != Blocks.SNOW_LAYER:
		return
	var above_id: int = manager.get_world_block(target + Vector3i(0, 1, 0))
	if above_id != Blocks.AIR and above_id != Blocks.SNOW_LAYER:
		return
	# Floor check — must be opaque. If snow_layer sits directly below
	# the candidate cell, look ONE deeper for the actual grass/dirt
	# floor (vanilla `EntityAnimal.getCanSpawnHere` checks the block at
	# y-1, but treats snow_layer atop grass as a valid pig surface).
	var below_pos: Vector3i = target + Vector3i(0, -1, 0)
	var below: int = manager.get_world_block(below_pos)
	if below == Blocks.SNOW_LAYER:
		below = manager.get_world_block(below_pos + Vector3i(0, -1, 0))
	if not Blocks.is_opaque(below):
		return
	var mob = mob_script.new() as CharacterBody3D
	if mob == null:
		return
	manager.add_child(mob)
	# Cell-center + tiny y nudge so the mob doesn't z-fight the floor.
	mob.global_position = Vector3(target) + Vector3(0.5, 0.05, 0.5)
