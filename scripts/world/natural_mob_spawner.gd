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
const _SLIME: GDScript = preload("res://scripts/entities/slime.gd")

# Slime spawn-Y cap. Vanilla `ns.java::a()` requires `ax < 16.0`; our
# caves carve a few cells higher than Alpha so we widen the band a
# bit (matches the constant on Slime itself).
const _SLIME_MAX_Y: int = 40
# Per-tick slime attempts. Slimes use a SEPARATE path from the normal
# hostile pass (no light gate, no night gate, slime-chunk only) — 2
# attempts per tick at 1 Hz balances the rarity vs the 10% chunk
# pass-rate so a player sitting in a slime chunk eventually sees one.
const _SLIME_ATTEMPTS_PER_TICK: int = 2
# Y-band for slime candidates. The normal _SPAWN_Y_BAND samples ±10 m
# of the player; slime needs the entire 0..40 column, so we use the
# player's Y minus a wide negative range to reach down into caves.
const _SLIME_Y_MIN: int = 0

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

# Pack-spawn — vanilla `SpawnerCreature.spawnEntities` runs a 4-loop
# after the seed cell passes, attempting 4 MORE same-species spawns
# jittered by `nextInt(6) - nextInt(6)` (±5 X/Z) with ZERO Y delta.
# Each additional attempt independently checks cell validity, so the
# actual pack count is geometry-dependent — open caves get the full
# 4, tight corridors trim to 1-2. Vanilla's jitter loop produces "up
# to 4 mobs per pack" total (1 seed + 3 successful pack attempts).
const _PACK_INNER_ATTEMPTS: int = 3
const _PACK_JITTER_XZ: int = 6  # vanilla nextInt(6) - nextInt(6) = ±5
# Solo-spawn roll — 25% of successful seed cells skip the pack loop
# entirely so the player encounters a lone mob from time to time.
# Mirrors the Beta-era feel where the pack-loop's Y=0 jitter + tight
# cave geometry made single hostiles common in practice (most extras
# failed validity). The explicit roll keeps the variability stable
# regardless of how cleanly our chunk geometry resembles vanilla.
const _SOLO_SPAWN_CHANCE: float = 0.25

# Cached lookups so the per-tick path avoids find_child + Script load.
var _player_cache: Node3D = null
var _chunk_manager_cache: Node = null
# Hostile species pool, cached after first lookup. Per attempt we pick
# uniformly from this list. Vanilla SpawnerAnimals weights by mob's
# `getCanSpawnHere` per attempt rather than a flat pool, but uniform
# is close enough until skeleton-vs-zombie biome rules ship.
var _hostile_script_pool: Array = []
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
	var player: Node3D = _get_player()
	if player == null:
		return
	var manager: Node = _get_chunk_manager()
	if manager == null:
		return
	# Cap check — counts ALL MobBase descendants in the world. Once
	# spider/creeper/slime land, expand to filter by hostile-vs-passive
	# (MobBase.is_hostile() helper, or a class-list match). For now
	# the total-cap approach is correct enough — passive mobs spawn
	# separately via cages, hostile via this path.
	var active: Dictionary = _MOB_BASE.active_mobs()
	if active.size() >= _HOSTILE_CAP:
		return
	# Slime pass runs every tick regardless of time-of-day. Vanilla
	# `ns.java::a()` doesn't check sky_factor — slimes spawn 24/7
	# because they're deep underground anyway.
	for _i in range(_SLIME_ATTEMPTS_PER_TICK):
		_try_spawn_slime(manager, player)
	# Normal hostile pass — gated by night (vanilla `spawnHostileMobs`
	# from gameDifficulty + the per-cell light check). Sunset crosses
	# sky_factor ≤ 0.5.
	if WorldTime.sky_factor() > 0.5:
		return
	var pool: Array = _get_hostile_script_pool()
	if pool.is_empty():
		return
	for _i in range(_ATTEMPTS_PER_TICK):
		# Uniform pick from the hostile pool per attempt.
		var mob_script: Script = pool[randi() % pool.size()] as Script
		_try_spawn_one(manager, player, mob_script)


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
	var seed_cell: Vector3i = origin + Vector3i(dx, dy, dz)
	if not _is_valid_hostile_spawn_cell(manager, seed_cell):
		return
	# Seed mob — always spawns at the validated seed cell.
	_spawn_mob_at(manager, mob_script, seed_cell)
	# Solo-roll: 25% of seeds skip the pack expansion, so the player
	# encounters lone hostiles from time to time instead of always-packs.
	if randf() < _SOLO_SPAWN_CHANCE:
		return
	# Vanilla pack loop — `SpawnerCreature.spawnEntities` line ~135.
	# Up to _PACK_INNER_ATTEMPTS extra spawns, each at a triangular-
	# jittered cell (±5 X/Z, ZERO Y delta per vanilla `nextInt(1)-
	# nextInt(1)`). Each extra independently passes validity, so
	# tight caves naturally trim the pack to 1-2 even though we tried 3.
	var pack_cell: Vector3i = seed_cell
	for _i in range(_PACK_INNER_ATTEMPTS):
		# Vanilla jitter — triangular distribution biases toward the
		# seed cell so packs cluster rather than spread evenly.
		pack_cell += Vector3i(
			(randi() % _PACK_JITTER_XZ) - (randi() % _PACK_JITTER_XZ),
			0,
			(randi() % _PACK_JITTER_XZ) - (randi() % _PACK_JITTER_XZ)
		)
		if _is_valid_hostile_spawn_cell(manager, pack_cell):
			_spawn_mob_at(manager, mob_script, pack_cell)


# Instantiate the mob script + parent it under the chunk manager.
# Position-Y nudged 0.05 above the cell floor to avoid z-fighting.
func _spawn_mob_at(manager: Node, mob_script: Script, cell: Vector3i) -> void:
	var mob = mob_script.new() as CharacterBody3D
	if mob == null:
		return
	manager.add_child(mob)
	mob.global_position = Vector3(cell) + Vector3(0.5, 0.05, 0.5)


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


# Slime spawn pass. Vanilla `ns.java::a()` rules:
#   * Chunk passes `Slime.is_slime_chunk` (1-in-10 by world seed).
#   * Y < _SLIME_MAX_Y (vanilla 16; we widen to 40 to match our caves).
#   * Candidate cell + above are AIR; cell-below is opaque (real floor).
#   * NO light gate (slimes spawn in lit caves too).
#   * NO night gate.
#
# We sample XZ within the normal hostile radius band so slime spawns
# stay player-localized, and pick a random Y in [_SLIME_Y_MIN, _SLIME_MAX_Y]
# rather than relying on the ±10 m player-relative band — most players
# spend their time at Y > 40 so the player-relative sample would never
# fire.
func _try_spawn_slime(manager: Node, player: Node3D) -> void:
	# XZ pick: same polar distribution the normal hostile pass uses.
	var theta: float = randf() * TAU
	var r_sq: float = (
		_SPAWN_MIN_RADIUS * _SPAWN_MIN_RADIUS
		+ randf() * (_SPAWN_MAX_RADIUS * _SPAWN_MAX_RADIUS - _SPAWN_MIN_RADIUS * _SPAWN_MIN_RADIUS)
	)
	var r: float = sqrt(r_sq)
	var dx: int = int(round(cos(theta) * r))
	var dz: int = int(round(sin(theta) * r))
	var px: int = int(floor(player.global_position.x))
	var pz: int = int(floor(player.global_position.z))
	var cell_x: int = px + dx
	var cell_z: int = pz + dz
	var chunk_coord := Vector2i(cell_x >> 4, cell_z >> 4)
	# Slime-chunk gate FIRST — cheapest check, kills 90% of candidates.
	if not _SLIME.is_slime_chunk(Worldgen.WORLD_SEED, chunk_coord.x, chunk_coord.y):
		return
	# Y pick: uniform over the slime depth band.
	var cell_y: int = randi_range(_SLIME_Y_MIN, _SLIME_MAX_Y)
	var candidate := Vector3i(cell_x, cell_y, cell_z)
	if not _is_valid_slime_spawn_cell(manager, candidate):
		return
	# Size pick — vanilla `c = 1 << random.nextInt(3)` → 1, 2, or 4.
	var size: int = 1 << randi_range(0, 2)
	var slime = _SLIME.new()
	slime.setup_size(size)
	manager.add_child(slime)
	# Slightly higher Y nudge for larger slimes — their cube center
	# sits at half-height so they don't penetrate the floor.
	var slime_height: float = 0.6 * float(size)
	slime.global_position = Vector3(candidate) + Vector3(0.5, slime_height * 0.05, 0.5)


# Slime-specific validity. Looser than the hostile path: no light
# requirement, no night requirement. AIR / clearance / floor still
# apply.
func _is_valid_slime_spawn_cell(manager: Node, pos: Vector3i) -> bool:
	if pos.y > _SLIME_MAX_Y or pos.y < _SLIME_Y_MIN:
		return false
	var chunk_coord := Vector2i(pos.x >> 4, pos.z >> 4)
	if manager.get_chunk_at_coord(chunk_coord) == null:
		return false
	# Need 2-tall AIR for size-1 slimes; larger sizes need more, but
	# we accept the 2-tall check as a minimum and let bigger slimes
	# get pushed up by penetration-recovery if they spawn in a tight
	# pocket. Vanilla doesn't check size-aware clearance either.
	if manager.get_world_block(pos) != Blocks.AIR:
		return false
	if manager.get_world_block(pos + Vector3i(0, 1, 0)) != Blocks.AIR:
		return false
	var floor_id: int = manager.get_world_block(pos + Vector3i(0, -1, 0))
	if not Blocks.is_opaque(floor_id):
		return false
	return true


func _get_hostile_script_pool() -> Array:
	if not _hostile_script_pool.is_empty():
		return _hostile_script_pool
	# Spider added M5. The cell-validity check below still demands a
	# 2-tall AIR pocket — vanilla Alpha's SpawnerCreature uniformly
	# checks for humanoid clearance regardless of entity height, so
	# this matches vanilla even though spider's BB is only 0.9 m tall.
	for name: String in ["zombie", "skeleton", "spider"]:
		var s: Script = _MOB_REGISTRY.script_for(name)
		if s != null:
			_hostile_script_pool.append(s)
	return _hostile_script_pool
