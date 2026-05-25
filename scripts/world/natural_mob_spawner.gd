extends Node

# Natural mob spawning — vanilla's per-chunk hostile-mob spawn pass
# (`SpawnerAnimals.findChunksForSpawning` in Beta+, kept conceptually
# the same from Alpha). Vanilla picks per-chunk candidates within a
# 17×17 chunk window around each player, rolls a per-attempt sample,
# and spawns when light + floor + clearance + cap checks pass.
#
# Our Stage-1 cut keeps the spirit but trades the per-chunk loop for a
# simpler per-tick random-cell sample around the player. Good enough
# to validate the hostile-mob fight loop; the per-chunk loop is a Beta-
# parity polish item.
#
# Rules (Alpha-faithful):
#   * Only zombies for now (mob types Stage 1).
#   * Skylight ≤ 7 at the candidate cell (vanilla `World.getBlockLightValue`
#     comparison — Alpha used <=7 for hostile spawning).
#   * Target cell + cell-above are AIR; cell-below is opaque (real floor).
#   * Range 24..128 m XZ from the player (vanilla SPAWN_DISTANCE band).
#   * Hostile cap = 70 total active mobs (vanilla constant).
#   * Time-gate: only spawn during night (WorldTime.sky_factor() < 0.5)
#     when ambient sky-light at any candidate cell is naturally ≤ 7.

const _MOB_REGISTRY: GDScript = preload("res://scripts/entities/mob_registry.gd")
const _MOB_BASE: GDScript = preload("res://scripts/entities/mob_base.gd")

# Vanilla spawn-radius band. Mobs spawn 24..128 m XZ from the player.
const _SPAWN_MIN_RADIUS: float = 24.0
const _SPAWN_MAX_RADIUS: float = 128.0
# Y candidate range relative to the player. Vanilla checks the entire
# column above the chunk's surface; we sample within a ±10 m vertical
# band of the player which covers caves + surface for now.
const _SPAWN_Y_BAND: int = 12

# Vanilla per-player hostile cap. Counted across all hostile species
# (just zombie for now; skeleton/spider/creeper/slime later append).
const _HOSTILE_CAP: int = 70

# Tick interval. Vanilla runs the spawn pass every tick (20 Hz), one
# chunk per call. Our random-cell pass is cheaper and only spawns
# rarely, so 1 Hz is plenty.
const _SPAWN_INTERVAL_SEC: float = 1.0

# Per-tick attempts. Vanilla rolls 3 attempts per chunk; we roll 4
# attempts per tick at 1 Hz which mathematically matches a moderate
# vanilla spawn rate (slightly less aggressive — first ship can tune
# up if needed).
const _ATTEMPTS_PER_TICK: int = 4

# Cached lookups so the per-tick path avoids find_child + Script load.
var _player_cache: Node3D = null
var _chunk_manager_cache: Node = null
var _zombie_script_cache: Script = null
var _spawn_accum: float = 0.0


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	_spawn_accum += delta
	if _spawn_accum < _SPAWN_INTERVAL_SEC:
		return
	_spawn_accum = 0.0
	_run_spawn_pass()


func _run_spawn_pass() -> void:
	# Time gate — vanilla `SpawnerAnimals.findChunksForSpawning` is
	# called with `spawnHostileMobs` set by the world. In single-player
	# that comes from gameDifficulty >= 1; we approximate via "is it
	# night?" so hostile mobs are a night-time threat instead of a
	# constant ambient presence. WorldTime.sky_factor() ≤ 0.5 means we
	# crossed sunset.
	if WorldTime.sky_factor() > 0.5:
		return
	var player: Node3D = _get_player()
	if player == null:
		return
	var manager: Node = _get_chunk_manager()
	if manager == null:
		return
	var zombie_script: Script = _get_zombie_script()
	if zombie_script == null:
		return
	# Cap check — counts ALL MobBase descendants in the world. Once
	# skeleton/spider/creeper/slime land, expand to filter by hostile-
	# vs-passive (MobBase.is_hostile() helper, or a class-list match).
	# For Stage 1 with only zombies as hostile, the total-cap approach
	# is correct enough; passive mobs spawn separately via cages.
	var active: Dictionary = _MOB_BASE.active_mobs()
	if active.size() >= _HOSTILE_CAP:
		return
	for _i in range(_ATTEMPTS_PER_TICK):
		_try_spawn_one(manager, player, zombie_script)


func _try_spawn_one(manager: Node, player: Node3D, mob_script: Script) -> void:
	# Pick a random XZ offset in the spawn band. Uniform polar
	# distribution (radius² uniform → linear radius distribution favors
	# the outer band) is closer to vanilla's per-chunk-uniform pick.
	var theta: float = randf() * TAU
	var r_sq: float = (
		_SPAWN_MIN_RADIUS * _SPAWN_MIN_RADIUS
		+ randf() * (_SPAWN_MAX_RADIUS * _SPAWN_MAX_RADIUS - _SPAWN_MIN_RADIUS * _SPAWN_MIN_RADIUS)
	)
	var r: float = sqrt(r_sq)
	var dx: int = int(round(cos(theta) * r))
	var dz: int = int(round(sin(theta) * r))
	var dy: int = randi_range(-_SPAWN_Y_BAND, _SPAWN_Y_BAND)
	var origin: Vector3i = Vector3i(
		int(floor(player.global_position.x)),
		int(floor(player.global_position.y)),
		int(floor(player.global_position.z))
	)
	var candidate: Vector3i = origin + Vector3i(dx, dy, dz)
	if not _is_valid_hostile_spawn_cell(manager, candidate):
		return
	# Spawn at cell-center with a small Y nudge so the mob isn't z-fighting
	# the floor. Same offset pattern mob_spawner_manager uses.
	var mob = mob_script.new() as CharacterBody3D
	if mob == null:
		return
	manager.add_child(mob)
	mob.global_position = Vector3(candidate) + Vector3(0.5, 0.05, 0.5)


# Vanilla hostile-spawn cell rules:
#   * Candidate cell AIR (entity body bottom).
#   * Cell above also AIR (entity head clearance; humanoid 2-tall).
#   * Cell below opaque (real floor).
#   * Sky-light ≤ 7 (vanilla `getBlockLightValue` comparison; dark only).
#   * No solid block at the candidate AABB (we approximate via the
#     AIR-above check — zombie collision is 0.6 × 1.95 × 0.6 which
#     fits a 1-wide × 2-tall pocket).
func _is_valid_hostile_spawn_cell(manager: Node, pos: Vector3i) -> bool:
	# Chunk loaded? Unloaded cells return AIR which would otherwise
	# pass the AIR check + fail the floor check anyway, but the early
	# check skips a few redundant lookups.
	var chunk_coord := Vector2i(pos.x >> 4, pos.z >> 4)
	if manager.get_chunk_at_coord(chunk_coord) == null:
		return false
	# Candidate cell + 1-above must be AIR for the 2-tall humanoid.
	if manager.get_world_block(pos) != Blocks.AIR:
		return false
	if manager.get_world_block(pos + Vector3i(0, 1, 0)) != Blocks.AIR:
		return false
	# Floor below must be opaque (no spawning on plants, fluids, slabs).
	var floor_id: int = manager.get_world_block(pos + Vector3i(0, -1, 0))
	if not Blocks.is_opaque(floor_id):
		return false
	# Vanilla light check — both sky AND block light contribute. The
	# combined max is what `World.getBlockLightValue` returns; ≤ 7 lets
	# hostile mobs spawn. Caves with no skylight and no torches pass;
	# torch-lit areas and sunlit surfaces don't.
	var sky: int = manager.get_world_sky_light(pos)
	var blk: int = manager.get_world_block_light(pos)
	var lit: int = maxi(sky, blk)
	if lit > 7:
		return false
	return true


# --- Cached lookups ---


func _get_player() -> Node3D:
	if _player_cache != null and is_instance_valid(_player_cache):
		return _player_cache
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	_player_cache = main.find_child("Player", true, false) as Node3D
	return _player_cache


func _get_chunk_manager() -> Node:
	if _chunk_manager_cache != null and is_instance_valid(_chunk_manager_cache):
		return _chunk_manager_cache
	_chunk_manager_cache = get_tree().root.get_node_or_null("Main/ChunkManager")
	return _chunk_manager_cache


func _get_zombie_script() -> Script:
	if _zombie_script_cache != null:
		return _zombie_script_cache
	_zombie_script_cache = _MOB_REGISTRY.script_for("zombie")
	return _zombie_script_cache
