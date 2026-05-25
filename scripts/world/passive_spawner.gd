class_name PassiveSpawner
extends RefCounted

# Per-tick natural spawning of passive mobs — Alpha 1.2.6 `bg.java`
# (SpawnerAnimals) port, scoped to the four animal species since hostile
# mobs land in later phases.
#
# Vanilla algorithm (`bg.a(World)`):
#   1. Build a set of chunk coords within 8 chunks of every player
#      (`_SPAWN_RADIUS_CHUNKS` = 8 — Bukkit Beta later widened this to 16).
#   2. For each creature type (we just have ANIMAL):
#      a. Compute cap = `_CAP_PER_256_CHUNKS * loaded_chunks / 256`.
#         With Alpha's 8-chunk radius that's ~22 animals per single
#         player. Skip the type if `live_count >= cap`.
#      b. For each chunk in the set, roll 1/50 per tick to attempt a
#         spawn (`_SPAWN_CHUNK_CHANCE_DENOM`).
#      c. If the roll passes: pick a random spawn class from the biome
#         list (we use a single flat list since Alpha biomes share the
#         same animals — sheep/pig/chicken/cow), pick a random column
#         position in the chunk, then run up to
#         `_PACK_OUTER_ATTEMPTS` × `_PACK_INNER_ATTEMPTS` tries to
#         spawn a pack of `_MAX_PACK_SIZE` mobs near each other.
#      d. Each try jitters the position by ±6 X/Z, ±1 Y, then checks:
#         - block below feet is solid and is GRASS (vanilla
#           `ak.a()` line 29: `as.a(x, y-1, z) == nq.u.bh`)
#         - block at feet is empty + non-opaque
#         - block at head is empty
#         - sky light > 8 at spawn cell (daylight, not cave)
#         - no player within 24 m (576 m² distance check)
#      e. On success: instantiate, set global_position + yaw, add to
#         the chunk-manager's children (so save/load picks them up
#         via the live-mob walk in `entity_save.gd`).
#
# Performance budget per tick (20 Hz):
#   * Build chunk set: O(loaded_chunks). Bounded by `chunk_radius`
#     setting (default ~12 = 625 chunks). 1 iteration, cheap.
#   * Type loop: 1 type (animal only until hostiles land).
#   * Chunk loop: 1/50 pass rate × 625 chunks ≈ 12.5 attempts / tick.
#   * Per attempt: up to 12 cell probes (`_PACK_OUTER * _PACK_INNER`),
#     each ~10 voxel reads. ≈ 1500 reads / tick worst case.
#   * Each voxel read is O(1) via `chunk_manager.get_world_block`.
# Net: well under 0.1 ms / tick on the cap. Active-mob registry
# (`MobBase._active_mobs`) gives O(1) live count, so the cap gate
# short-circuits the chunk loop the instant the cap is hit.

# 8 chunks per Alpha bg.java line 24 (`int n5 = 8`).
const _SPAWN_RADIUS_CHUNKS: int = 8

# Per-creature-type cap denominator. Vanilla `gy.b.d = 20` for
# animals — `cap = 20 * chunks / 256`. With 17×17=289 chunks the cap
# is ~22 animals. Skip the type when count >= cap.
const _CAP_PER_256_CHUNKS: int = 20

# 1/50 chance per chunk per tick (`bg.java` line 38:
# `cy2.l.nextInt(50) != 0`). With ~289 chunks × 1/50 ≈ 5.8 attempts
# per tick per type.
const _SPAWN_CHUNK_CHANCE_DENOM: int = 50

# Pack pattern — bg.java has TWO nested loops:
#   outer i5 = 0..2 (3 tries)
#   inner i6 = 0..3 (4 sub-tries per outer)
# An outer iteration breaks early once `_MAX_PACK_SIZE` mobs are
# spawned, so a maxed-out pack stops after ~mob.i() spawns.
const _PACK_OUTER_ATTEMPTS: int = 3
const _PACK_INNER_ATTEMPTS: int = 4

# Max pack size — vanilla `hf.i() = 4` (Entity.getMaxSpawnedInChunk).
# Chickens use this default; pig/cow/sheep do too in Alpha (no
# overrides). Pack stops the moment this is hit so an active chunk
# doesn't pile up 12 cows in one cell.
const _MAX_PACK_SIZE: int = 4

# Pack-jitter range — bg.java line 51 (`int n14 = 6`). Each pack
# sub-attempt rolls (rand[0..n14) - rand[0..n14)) → range ±6, biased
# toward 0. Y jitter is the much smaller ±1.
const _PACK_JITTER_XZ: int = 6
const _PACK_JITTER_Y: int = 1

# Exclusion radius² around the nearest player. bg.java line 60: `f5 <
# 576.0f` rejects if within sqrt(576) = 24 m. Mobs spawned inside
# this radius would render right next to the camera which feels bad.
# Stored squared to skip the sqrt in the per-cell distance check.
const _PLAYER_EXCLUSION_SQ: float = 24.0 * 24.0

# Sky-light threshold — vanilla `ak.a()` line 29: `as.j(x, y, z) > 8`.
# Passive mobs only spawn in daylit (≥9) cells. At night this gates
# the spawn loop off everywhere except torch-lit overlap (rare).
const _MIN_SKY_LIGHT: int = 9

# Spawn-class list per Alpha 1.2.6 `gg.java:33`:
#   `this.s = new Class[]{bx, op, ou, as}` =
#   {SHEEP, PIG, CHICKEN, COW}. All biomes share this list — Alpha
#   doesn't have per-biome animal weighting (that's Beta+).
const _SPAWN_NAMES: Array = ["sheep", "pig", "chicken", "cow"]

# Tick cadence — vanilla `bg.a()` is called from `cy.B()` once per
# world tick (20 Hz). Match exactly so the random rolls + caps
# behave at vanilla rate regardless of render framerate.
const _TICK_DT: float = 1.0 / 20.0

# Worldgen-time spawn pass — Beta 1.0+ `SpawnerCreature.a(World,
# BiomeBase, i, j, k, l, Random)`. Called once per fresh chunk (not
# save-loaded) and pre-populates it with animal packs so a freshly-
# generated world doesn't feel empty until the per-tick spawner
# catches up (Alpha 1.2.6 strictly has no such pass — this is the
# small Beta-era deviation noted in the class header).
#
# Algorithm per chunk:
#   * `while rand < _WORLDGEN_DENSITY` (~0.1): one pack iteration.
#     Expected iterations per chunk = density / (1-density) ≈ 0.11.
#   * Per pack: pick a mob class, pick a random (x, z) in the chunk,
#     then up to `_WORLDGEN_PACK_SIZE` mobs × 4 retries each.
#   * Each retry: find the top non-air Y at (x, z); if it's grass AND
#     the cell above is empty AND lit, spawn there. Else jitter (x, z)
#     by ±5 (with bounds wrap) and try again.
const _WORLDGEN_DENSITY: float = 0.1
const _WORLDGEN_PACK_SIZE: int = 4
const _WORLDGEN_RETRIES_PER_MOB: int = 4
const _WORLDGEN_XZ_JITTER: int = 5
# Frame-budget guard — at density 0.1 the geometric draw has expected
# value 0.11 packs but the tail can spike to 5+. Cap so a single
# unlucky chunk can't pile on 20+ mobs and hitch the frame.
const _WORLDGEN_MAX_PACKS_PER_CHUNK: int = 3
# Y scan range for the "top non-air" lookup. Vanilla uses
# `world.i(x, z)` which returns the height-map sample; we walk down
# from Y=120 since our surface is always below that.
const _WORLDGEN_SCAN_TOP_Y: int = 120

var _accum: float = 0.0
var _rng := RandomNumberGenerator.new()


# Driven from chunk_manager._process. Accumulates frame delta + fires
# the tick loop at 20 Hz exactly. Cheap when no work — most ticks bail
# out at the cap check.
func tick(delta: float, chunk_mgr: Node, player: Node3D) -> void:
	if chunk_mgr == null or player == null:
		return
	_accum += delta
	while _accum >= _TICK_DT:
		_accum -= _TICK_DT
		_run_one_tick(chunk_mgr, player)


# One vanilla `bg.a()` pass. Re-entry-safe: the accumulator gate above
# ensures this runs at most every 1/20 s even on render frames longer
# than a tick.
func _run_one_tick(chunk_mgr: Node, player: Node3D) -> void:
	# Active mob count is O(1) via the static registry — used both to
	# gate the cap and to bail out if the world is already full.
	var animal_count: int = MobBase.active_mobs().size()
	var chunks: Dictionary = chunk_mgr.get("_chunks") as Dictionary
	if chunks == null or chunks.is_empty():
		return
	# Build the spawn-eligible chunk set — chunks within 8 of any
	# player, intersected with loaded chunks. Single-player simplifies
	# vanilla's player-union; we just walk the radius square around the
	# one player.
	var eligible: Array = _eligible_chunks(chunks, player)
	if eligible.is_empty():
		return
	# Per-type cap. We only have ANIMAL right now; when hostiles land,
	# add another loop iteration with `cz` (MONSTER, cap = 100).
	var cap: int = _CAP_PER_256_CHUNKS * eligible.size() / 256
	if animal_count >= cap:
		return
	# Walk eligible chunks. The 1/50 gate makes most ticks no-op cheap.
	for chunk_coord: Vector2i in eligible:
		if _rng.randi() % _SPAWN_CHUNK_CHANCE_DENOM != 0:
			continue
		_attempt_spawn_in_chunk(chunk_mgr, player, chunk_coord)
		# Re-check the cap so a single tick can't blow past it via
		# back-to-back pack spawns across multiple eligible chunks.
		animal_count = MobBase.active_mobs().size()
		if animal_count >= cap:
			return


# Vanilla bg.java pack loop — pick a random column position in the
# chunk, then run up to 3×4 nearby tries to find a valid spawn cell.
func _attempt_spawn_in_chunk(chunk_mgr: Node, player: Node3D, chunk_coord: Vector2i) -> void:
	var mob_name: String = _SPAWN_NAMES[_rng.randi() % _SPAWN_NAMES.size()]
	var script: Script = MobRegistry.script_for(mob_name)
	if script == null:
		return
	# Random column in the chunk. bg.java line 11-13:
	#   n4 = chunkX*16 + rand[0..16)
	#   n5 = rand[0..128)  -- Y is uniform across vanilla's 128-tall world
	#   n6 = chunkZ*16 + rand[0..16)
	var base_x: int = chunk_coord.x * 16 + _rng.randi() % 16
	var base_y: int = _rng.randi() % 128
	var base_z: int = chunk_coord.y * 16 + _rng.randi() % 16
	# Spawn-base cell must be empty and not water (line 44 — vanilla's
	# `cy2.f(n7, n8, n9) != hb.a` rejects non-AIR materials at base).
	if chunk_mgr.get_world_block(Vector3i(base_x, base_y, base_z)) != Blocks.AIR:
		return
	var pack_count: int = 0
	for outer_i: int in range(_PACK_OUTER_ATTEMPTS):
		var nx: int = base_x
		var ny: int = base_y
		var nz: int = base_z
		for _inner_i: int in range(_PACK_INNER_ATTEMPTS):
			# Vanilla's jitter pattern: nx += rand[0..n14) - rand[0..n14)
			# = ±n14 with a triangular distribution centered on 0.
			nx += _rng.randi() % _PACK_JITTER_XZ - _rng.randi() % _PACK_JITTER_XZ
			ny += _rng.randi() % (_PACK_JITTER_Y + 1) - _rng.randi() % (_PACK_JITTER_Y + 1)
			nz += _rng.randi() % _PACK_JITTER_XZ - _rng.randi() % _PACK_JITTER_XZ
			if not _can_spawn_at(chunk_mgr, player, nx, ny, nz):
				continue
			_spawn_mob(chunk_mgr, script, mob_name, nx, ny, nz)
			pack_count += 1
			if pack_count >= _MAX_PACK_SIZE:
				return


# Vanilla `ak.a()` + bg.java cell checks bundled. Returns true if a
# passive mob can spawn at (x, y, z):
#   - block below is GRASS
#   - block at (x, y, z) is empty (and feet are non-opaque)
#   - block at (x, y+1, z) is empty (head clearance)
#   - sky light > 8 (daytime, surface-y)
#   - distance to nearest player > 24 m
func _can_spawn_at(chunk_mgr: Node, player: Node3D, x: int, y: int, z: int) -> bool:
	if y < 1 or y >= 127:
		return false
	# Squared player distance — early-out cheap check first.
	var dx: float = (float(x) + 0.5) - player.global_position.x
	var dy: float = float(y) - player.global_position.y
	var dz: float = (float(z) + 0.5) - player.global_position.z
	if dx * dx + dy * dy + dz * dz < _PLAYER_EXCLUSION_SQ:
		return false
	var grass_below: bool = chunk_mgr.get_world_block(Vector3i(x, y - 1, z)) == Blocks.GRASS
	var feet_clear: bool = chunk_mgr.get_world_block(Vector3i(x, y, z)) == Blocks.AIR
	var head_clear: bool = chunk_mgr.get_world_block(Vector3i(x, y + 1, z)) == Blocks.AIR
	var lit: bool = chunk_mgr.get_world_sky_light(Vector3i(x, y, z)) >= _MIN_SKY_LIGHT
	return grass_below and feet_clear and head_clear and lit


# Instantiate the mob script + attach to the chunk-manager. mob_name
# is stashed in meta so EntitySave can round-trip via MobRegistry.
func _spawn_mob(chunk_mgr: Node, script: Script, mob_name: String, x: int, y: int, z: int) -> void:
	var mob: Node = script.new()
	chunk_mgr.add_child(mob)
	mob.set_meta("mob_name", mob_name)
	if mob is Node3D:
		(mob as Node3D).global_position = Vector3(float(x) + 0.5, float(y), float(z) + 0.5)
		(mob as Node3D).rotation.y = _rng.randf_range(0.0, TAU)


# --- Worldgen-time spawn pass (Beta SpawnerCreature.a port) ---


# Pre-populate a freshly-generated chunk with animal packs. Called from
# chunk_manager._materialize_chunk for non-save chunks, so the world
# feels populated immediately at gen-time. Bypasses the per-tick cap
# and the player exclusion zone (those apply to ongoing live spawning,
# not the gen-time seed pass).
func populate_chunk_at_gen(chunk_mgr: Node, chunk_coord: Vector2i) -> void:
	# `while rand < density` — Beta's geometric loop. Expected ~0.11
	# packs per chunk with the default density of 0.1. Capped at
	# _WORLDGEN_MAX_PACKS_PER_CHUNK to bound worst-case frame cost from
	# the long-tail geometric draw.
	var packs_emitted: int = 0
	while _rng.randf() < _WORLDGEN_DENSITY and packs_emitted < _WORLDGEN_MAX_PACKS_PER_CHUNK:
		_worldgen_pack(chunk_mgr, chunk_coord)
		packs_emitted += 1


# One vanilla pack iteration — pick mob class, pick base (x, z) in
# chunk, then up to `_WORLDGEN_PACK_SIZE` mobs × 4 retries each.
func _worldgen_pack(chunk_mgr: Node, chunk_coord: Vector2i) -> void:
	var mob_name: String = _SPAWN_NAMES[_rng.randi() % _SPAWN_NAMES.size()]
	var script: Script = MobRegistry.script_for(mob_name)
	if script == null:
		return
	# Random column in chunk. Track base + current so jitter doesn't
	# walk away from the pack center indefinitely.
	var base_x: int = chunk_coord.x * 16 + _rng.randi() % 16
	var base_z: int = chunk_coord.y * 16 + _rng.randi() % 16
	var cx: int = base_x
	var cz: int = base_z
	var chunk_min_x: int = chunk_coord.x * 16
	var chunk_max_x: int = chunk_min_x + 16
	var chunk_min_z: int = chunk_coord.y * 16
	var chunk_max_z: int = chunk_min_z + 16
	for _pack_index: int in range(_WORLDGEN_PACK_SIZE):
		var spawned: bool = false
		for _retry: int in range(_WORLDGEN_RETRIES_PER_MOB):
			var sy: int = _top_grass_spawn_y(chunk_mgr, cx, cz)
			if sy != -1:
				_spawn_mob(chunk_mgr, script, mob_name, cx, sy, cz)
				spawned = true
				break
			# Jitter for next retry — ±5 X/Z, wrap back into chunk if
			# we drift past the edge (Beta's inner `for` clause walks
			# back to the base whenever the wander exits the chunk).
			cx += _rng.randi() % _WORLDGEN_XZ_JITTER - _rng.randi() % _WORLDGEN_XZ_JITTER
			cz += _rng.randi() % _WORLDGEN_XZ_JITTER - _rng.randi() % _WORLDGEN_XZ_JITTER
			if cx < chunk_min_x or cx >= chunk_max_x:
				cx = base_x + _rng.randi() % _WORLDGEN_XZ_JITTER
			if cz < chunk_min_z or cz >= chunk_max_z:
				cz = base_z + _rng.randi() % _WORLDGEN_XZ_JITTER
		if not spawned:
			break  # bail the pack if a single mob can't find a spot


# Find the spawn Y above the top non-air block at (x, z) — but only
# if that top block is GRASS. Returns -1 if the column has no grass at
# the surface (water, sand, stone exposed, etc.).
func _top_grass_spawn_y(chunk_mgr: Node, x: int, z: int) -> int:
	for y: int in range(_WORLDGEN_SCAN_TOP_Y, 1, -1):
		var b: int = chunk_mgr.get_world_block(Vector3i(x, y, z))
		if b == Blocks.AIR:
			continue
		# First non-air block from the top. Only spawn above grass.
		if b != Blocks.GRASS:
			return -1
		var spawn_y: int = y + 1
		# Spawn cell + head cell must both be AIR (matches per-tick path).
		if chunk_mgr.get_world_block(Vector3i(x, spawn_y, z)) != Blocks.AIR:
			return -1
		if chunk_mgr.get_world_block(Vector3i(x, spawn_y + 1, z)) != Blocks.AIR:
			return -1
		return spawn_y
	return -1


# Walk the player's 17×17 chunk square, keeping only chunks that are
# actually loaded. Vanilla iterates the same square via a HashSet
# union across all players; with one player we skip the union.
func _eligible_chunks(loaded_chunks: Dictionary, player: Node3D) -> Array:
	var out: Array = []
	var pcx: int = int(floor(player.global_position.x / 16.0))
	var pcz: int = int(floor(player.global_position.z / 16.0))
	for dx: int in range(-_SPAWN_RADIUS_CHUNKS, _SPAWN_RADIUS_CHUNKS + 1):
		for dz: int in range(-_SPAWN_RADIUS_CHUNKS, _SPAWN_RADIUS_CHUNKS + 1):
			var coord := Vector2i(pcx + dx, pcz + dz)
			if loaded_chunks.has(coord):
				out.append(coord)
	return out
