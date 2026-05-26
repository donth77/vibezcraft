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
# Spawn band. With LOD tiering in mob_base (NEAR < 32m, MID < 64m,
# FAR < 96m, GATED beyond), we can spawn out to 80m and the distant
# mobs will still tick at reduced cadence (5 Hz mid, 1 Hz far). Mobs
# scatter across the visible band like vanilla but cost a fraction
# of the CPU. Inner 24m still protected.
const _SPAWN_MIN_RADIUS: float = 24.0
const _SPAWN_MAX_RADIUS: float = 80.0
# Y candidate range relative to the player. Vanilla checks the entire
# column above the chunk's surface; we sample within a ±10 m vertical
# band of the player which covers caves + surface for now.
const _SPAWN_Y_BAND: int = 12

# Vanilla per-player hostile cap (gameDifficulty * 70 in Alpha). The
# mob_base.gd 48 m physics gate + the subclass _physics_gated flag
# (skeleton / creeper / zombie / spider all check it) skip AI + path-
# finding for mobs out of range, so only ~10-15 of these 70 actually
# run full physics at any given moment. The remaining 55+ cost just a
# distance check per frame each (~100 ns).
const _HOSTILE_CAP: int = 70

# Tick interval — 1 Hz. Earlier 2 Hz × 8 attempts × 4-mob pack
# expansion landed up to 32 mob instantiations in one tick, each
# costing 5-10 ms in _ready (mesh + collider + fire billboards).
# That gave a 37 ms spike on main thread (visible as FPS dropping to
# single digits the instant a pack spawned). 1 Hz with hard cap below
# keeps per-tick cost bounded.
const _SPAWN_INTERVAL_SEC: float = 1.0

# Per-tick attempts. Hard cap of 4 — even with pack expansion (up to
# 4 mobs per seed), the per-tick spawn count is bounded so one bad
# tick can't stall the main thread.
const _ATTEMPTS_PER_TICK: int = 4
# Hard ceiling on mobs instantiated in a single tick. With shared
# mesh + material caching (MobCube._mesh_cache + MobBase._shared_materials)
# per-spawn _ready() is ~1-2 ms instead of 5-10 ms, so 4/tick keeps
# under a 16 ms frame budget and gets the cap fill rate close to
# vanilla. Pack expansion still drains 1/tick from the queue for
# graceful smoothing.
const _MAX_SPAWNS_PER_TICK: int = 4

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
const _SOLO_SPAWN_CHANCE: float = 0.25  # vanilla — 75% of seeds expand into packs

# Cached lookups so the per-tick path avoids find_child + Script load.
var _player_cache: Node3D = null
var _chunk_manager_cache: Node = null
# Hostile species pool, cached after first lookup. Per attempt we pick
# uniformly from this list. Vanilla SpawnerAnimals weights by mob's
# `getCanSpawnHere` per attempt rather than a flat pool, but uniform
# is close enough until skeleton-vs-zombie biome rules ship.
var _hostile_script_pool: Array = []
var _spawn_accum: float = 0.0
# Per-tick spawn counter, reset at the top of each spawn pass and
# incremented inside _spawn_mob_at. Caps the actual mob-instantiation
# work per tick so a lucky pack expansion can't pile 32 mob _ready()
# calls into one frame.
var _spawns_this_tick: int = 0
# Pack-spawn queue. Each entry is [mob_script, cell]. Drained 1 per
# tick (alongside the seed roll) so a pack of 4 takes 4 ticks to
# fully materialize instead of all-at-once. Maintains vanilla
# clustered-pack visuals without the per-frame stutter.
var _pack_queue: Array = []


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
	# Hostile cap — count ONLY hostile species. The old `active.size()`
	# check counted every MobBase (pigs, cows, sheep, chickens too), so
	# a normal grass biome with the passive cap full would block all
	# hostile spawning — explaining "walked 10 min at night and saw 1
	# spider." Filter the dict to hostile scripts before comparing.
	var active: Dictionary = _MOB_BASE.active_mobs()
	var pool: Array = _get_hostile_script_pool()
	var hostile_count: int = 0
	for mob in active.values():
		if not is_instance_valid(mob):
			continue
		if pool.has(mob.get_script()):
			hostile_count += 1
	if hostile_count >= _HOSTILE_CAP:
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
	if pool.is_empty():
		return
	_spawns_this_tick = 0
	# Drain the pack queue first — these are pre-validated cells
	# from previous seed spawns. Counts against the per-tick spawn
	# budget so the queue + new seeds together can't exceed it.
	while not _pack_queue.is_empty() and _spawns_this_tick < _MAX_SPAWNS_PER_TICK:
		var entry: Array = _pack_queue.pop_front()
		var queued_cell: Vector3i = entry[1] as Vector3i
		if _is_valid_hostile_spawn_cell(manager, queued_cell):
			_spawn_mob_at(manager, entry[0] as Script, queued_cell)
	# Then new seed rolls if budget remains.
	for _i in range(_ATTEMPTS_PER_TICK):
		if _spawns_this_tick >= _MAX_SPAWNS_PER_TICK:
			break
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
	# Y selection — biased toward the player's altitude so spawns
	# land on the SAME elevation band the player can see. Earlier
	# uniform [4, 124] meant a player at Y=106 (mountain top) had
	# most spawns land at Y=50 (caves below), invisible to the
	# player. Band of [player.Y - 16, player.Y + 4] covers ground
	# around the player + the immediate caves underfoot. Validation
	# gates still filter to AIR cells with opaque floors.
	var py: int = int(floor(player.global_position.y))
	var sy: int = clampi(py + randi_range(-16, 4), 4, Chunk.SIZE_Y - 4)
	var origin: Vector3i = Vector3i(
		int(floor(player.global_position.x)), 0, int(floor(player.global_position.z))
	)
	var seed_cell: Vector3i = Vector3i(origin.x + dx, sy, origin.z + dz)
	if not _is_valid_hostile_spawn_cell(manager, seed_cell):
		return
	# Seed mob — always spawns at the validated seed cell.
	_spawn_mob_at(manager, mob_script, seed_cell)
	# Solo-roll: 25% of seeds skip the pack expansion, so the player
	# encounters lone hostiles from time to time instead of always-packs.
	if randf() < _SOLO_SPAWN_CHANCE:
		return
	# Vanilla pack loop — `SpawnerCreature.spawnEntities` line ~135.
	# Up to _PACK_INNER_ATTEMPTS extra spawns at triangular-jittered
	# cells. We ENQUEUE these for subsequent ticks instead of spawning
	# inline; the queue drains 1/tick along with seed rolls so per-
	# frame cost stays bounded. Pre-validate so dead cells don't sit
	# in the queue (validity re-checked on drain in case terrain
	# changed in the meantime).
	var pack_cell: Vector3i = seed_cell
	for _i in range(_PACK_INNER_ATTEMPTS):
		pack_cell += Vector3i(
			(randi() % _PACK_JITTER_XZ) - (randi() % _PACK_JITTER_XZ),
			0,
			(randi() % _PACK_JITTER_XZ) - (randi() % _PACK_JITTER_XZ)
		)
		if _is_valid_hostile_spawn_cell(manager, pack_cell):
			_pack_queue.append([mob_script, pack_cell])
	# Bound the queue so a runaway frame can't pile up hundreds of
	# pending mobs that all spawn over the next 100 seconds.
	if _pack_queue.size() > 32:
		_pack_queue.resize(32)


# Instantiate the mob script + parent it under the chunk manager.
# Position-Y nudged 0.05 above the cell floor to avoid z-fighting.
func _spawn_mob_at(manager: Node, mob_script: Script, cell: Vector3i) -> void:
	# Hard per-tick budget — silently drop the spawn if we've already
	# instantiated _MAX_SPAWNS_PER_TICK mobs this tick. The cap still
	# fills (next tick will spawn more), just spread across multiple
	# frames so no single frame absorbs the full 10-20 ms of mob
	# construction work.
	if _spawns_this_tick >= _MAX_SPAWNS_PER_TICK:
		return
	var mob = mob_script.new() as CharacterBody3D
	if mob == null:
		return
	manager.add_child(mob)
	mob.global_position = Vector3(cell) + Vector3(0.5, 0.05, 0.5)
	_spawns_this_tick += 1


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
	# Vanilla light check — both sky AND block light contribute, but the
	# SKY component is scaled by the current sun position (vanilla's
	# `skyLightSubtracted`). Without the scale, surface cells still
	# read sky=15 at midnight (the chunk stores raw daylight max), so
	# `max(15, 0) > 7` rejected every surface spawn and hostiles only
	# appeared in caves. WorldTime.sky_factor() gives 0..1 (0.05 at
	# midnight, 1.0 at noon) — perfect attenuator. Same formula chunk
	# shader uses for terrain brightness.
	var sky_raw: int = manager.get_world_sky_light(pos)
	var sky_eff: int = int(round(float(sky_raw) * WorldTime.sky_factor()))
	var blk: int = manager.get_world_block_light(pos)
	var lit: int = maxi(sky_eff, blk)
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
	for name: String in ["zombie", "skeleton", "spider", "creeper"]:
		var s: Script = _MOB_REGISTRY.script_for(name)
		if s != null:
			_hostile_script_pool.append(s)
	return _hostile_script_pool
