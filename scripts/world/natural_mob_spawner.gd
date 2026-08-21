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
#   * Effective combined light ≤ 7 at the candidate cell (Alpha's
#     time-adjusted `World.getBlockLightValue`).
#   * Target cell + cell-above are AIR; cell-below is opaque (real floor).
#   * Range 24..128 m XZ from the player (vanilla SPAWN_DISTANCE band).
#   * Hostile cap = 70 total active mobs (vanilla constant).
# There is intentionally no coarse global night gate: Alpha applies the
# per-cell combined-light rule, allowing dark caves to spawn hostiles by day
# while rejecting bright surface cells.

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

# `hf.i()` returns 4. Species override it — `am.i()` returns 1.
const _DEFAULT_GROUP_SIZE: int = 4

# Cached lookups so the per-tick path avoids find_child + Script load.
var _player_cache: Node3D = null
var _chunk_manager_cache: Node = null
# Hostile species pool, cached after first lookup. Per attempt we pick
# uniformly from this list. Vanilla SpawnerAnimals weights by mob's
# `getCanSpawnHere` per attempt rather than a flat pool, but uniform
# is close enough until skeleton-vs-zombie biome rules ship.
# dimension:int -> Array[Script]. Keyed by dimension because a portal
# trip changes the answer; a single slot would have carried Overworld
# mobs into the Nether.
var _hostile_pool_cache: Dictionary = {}
# Script -> {airborne, size, group_size}. Read once per species; see
# _species_descriptor.
var _species_cache: Dictionary = {}
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
# Seconds of hostile-spawn suppression remaining. See grant_spawn_grace.
var _spawn_grace_remaining: float = 0.0


func _ready() -> void:
	set_process(true)


# DEVIATION from vanilla (modern QoL): hold off hostile spawning for a
# few seconds after the player is dropped somewhere they did not walk
# to. Vanilla Alpha has no such window — it does not need one, because
# its own rarity gates (a ghast is `nextInt(20)`) mean an arrival is not
# usually met by anything. A player who steps out of a portal into an
# unfamiliar dimension has no bearings, no line of retreat, and cannot
# yet see what is above them; being shot during that window reads as
# unfair rather than dangerous. Applies to the hostile pass only —
# passive spawns and already-living mobs are untouched.
func grant_spawn_grace(seconds: float) -> void:
	_spawn_grace_remaining = maxf(_spawn_grace_remaining, seconds)
	# Anything already queued from before the trip would land the instant
	# the window closes, which defeats the point.
	_pack_queue.clear()


func _process(delta: float) -> void:
	if _spawn_grace_remaining > 0.0:
		_spawn_grace_remaining = maxf(0.0, _spawn_grace_remaining - delta)
	_spawn_accum += delta
	if _spawn_accum < _SPAWN_INTERVAL_SEC:
		return
	_spawn_accum = 0.0
	if _spawn_grace_remaining > 0.0:
		return
	_run_spawn_pass()


func _run_spawn_pass() -> void:
	# `ef.e_()` kills every hostile outright on Peaceful and `pt.a()` /
	# `am.a()` both refuse to spawn there. Stopping the whole pass is the
	# same observable result and saves the work.
	if Game.difficulty == Game.DIFFICULTY_PEACEFUL:
		return
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
	# Vanilla scales the per-type cap by the loaded-chunk count —
	# bg.java:34 `count > maxPerType * eligibleChunks.size() / 256`.
	# At Alpha's SP ring (17×17 = 289) that allows 79; we clamp to the
	# shipped 70 so Normal/Far render distances behave exactly as
	# before. The scaling matters at Short/Tiny (81 chunks → 22,
	# 25 → 6): a flat 70 packed small worlds wall-to-wall — every mob
	# inside the NEAR/MID LOD rings — which measured as the 31 → 4 fps
	# night collapse on mobile web. has_method guards minimal fake
	# managers in unit tests (missing accessor → flat cap, old behavior).
	var loaded_chunks: int = 256
	if manager.has_method("iter_loaded_chunks"):
		loaded_chunks = manager.iter_loaded_chunks().size()
	# The per-256-chunk factor is `gy.java`'s, read off the provider: 70
	# in the Overworld (this project's shipped figure, unchanged) and the
	# source's 100 in the Nether.
	var factor: int = DimensionContext.active_provider().hostile_cap_per_256_chunks
	var hostile_cap: int = mini(factor, factor * loaded_chunks / 256)
	if hostile_count >= hostile_cap:
		return
	# Slime pass runs every tick regardless of time-of-day. Vanilla
	# `ns.java::a()` doesn't check sky_factor — slimes spawn 24/7
	# because they're deep underground anyway.
	# Slimes are not on any Nether list — `k.java` names ghast and pigman
	# and nothing else — and this path deliberately bypasses the normal
	# pool, so it needs its own gate. An explicit provider flag rather
	# than "the species list is empty": that convention would have
	# silently killed Overworld slimes the day the Overworld gained an
	# explicit list (audit finding #15).
	if DimensionContext.active_provider().has_slime_spawns:
		for _i in range(_SLIME_ATTEMPTS_PER_TICK):
			_try_spawn_slime(manager, player)
	# Normal hostile pass. The per-cell effective-light check below is the
	# time-of-day gate for exposed cells and still permits dark daytime caves.
	if pool.is_empty():
		return
	_spawns_this_tick = 0
	# Drain the pack queue first — these are pre-validated cells
	# from previous seed spawns. Counts against the per-tick spawn
	# budget so the queue + new seeds together can't exceed it.
	while not _pack_queue.is_empty() and _spawns_this_tick < _MAX_SPAWNS_PER_TICK:
		var entry: Array = _pack_queue.pop_front()
		var queued_cell: Vector3i = entry[1] as Vector3i
		if not _outside_player_exclusion(player, queued_cell):
			continue
		if _is_valid_spawn_cell_for(manager, entry[0] as Script, queued_cell):
			_spawn_mob_at(manager, entry[0] as Script, queued_cell)
	# Then new seed rolls if budget remains.
	for _i in range(_ATTEMPTS_PER_TICK):
		if _spawns_this_tick >= _MAX_SPAWNS_PER_TICK:
			break
		# `int n6 = cy2.l.nextInt(classArray.length)` — ONE class is
		# chosen per candidate group, not per attempt within it.
		var mob_script: Script = pool[randi() % pool.size()] as Script
		# Vanilla rolls the species gate on the CANDIDATE, and a failed
		# roll costs the attempt — that is what makes ghasts rare rather
		# than merely slower to place.
		if not _passes_species_spawn_roll(mob_script):
			continue
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
	if not _is_valid_spawn_cell_for(manager, mob_script, seed_cell):
		return
	# Seed mob — always spawns at the validated seed cell.
	_spawn_mob_at(manager, mob_script, seed_cell)
	# `if (n10 >= hf2.i()) continue block6;` — the group-size cap is the
	# ENTITY's, and a ghast's is 1. `am.i()` returns 1 where the
	# EntityLiving default is 4, which is why ghasts are always alone.
	if _group_size_for(mob_script) <= 1:
		return
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
		if not _outside_player_exclusion(player, pack_cell):
			continue
		if _is_valid_spawn_cell_for(manager, mob_script, pack_cell):
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


# Per-species spawn validity. `bg.java` constructs the entity and calls
# its own `a()` predicate, so the rules are the ENTITY's, not the
# spawner's — and a 4x4 ghast needs a very different pocket from a 2-tall
# humanoid. This dispatches on a descriptor read once per species rather
# than constructing and discarding an entity per attempt.
func _is_valid_spawn_cell_for(manager: Node, mob_script: Script, pos: Vector3i) -> bool:
	var descriptor: Dictionary = _species_descriptor(mob_script)
	if not bool(descriptor.get("airborne", false)):
		return _is_valid_hostile_spawn_cell(manager, pos)
	# A flying species wants open air and no floor at all. `hf.a()` is
	# "the box is clear of blocks, entities and liquid" — for a ghast
	# that is a 4x4x4 pocket, which is also what stops one appearing
	# half-inside a cavern roof.
	var chunk_coord := Vector2i(pos.x >> 4, pos.z >> 4)
	if manager.get_chunk_at_coord(chunk_coord) == null:
		return false
	var span: int = int(ceil(float(descriptor.get("size", 1.0))))
	var half: int = span / 2
	for dx: int in range(-half, span - half):
		for dy: int in range(span):
			for dz: int in range(-half, span - half):
				var cell := Vector3i(pos.x + dx, pos.y + dy, pos.z + dz)
				if manager.get_world_block(cell) != Blocks.AIR:
					return false
	return true


# `hf2.i()` — the entity's own group-size cap. Four by default,
# one for a ghast.
func _group_size_for(mob_script: Script) -> int:
	return int(_species_descriptor(mob_script).get("group_size", _DEFAULT_GROUP_SIZE))


# Vanilla's per-species `getCanSpawnHere` roll (`am.a()`'s
# `nextInt(20) == 0`). Species that do not declare one return 1, which
# always passes — so this changes nothing for the eight species that
# have no such gate.
func _passes_species_spawn_roll(mob_script: Script) -> bool:
	var denominator: int = int(_species_descriptor(mob_script).get("spawn_denominator", 1))
	if denominator <= 1:
		return true
	return randi() % denominator == 0


# Read a species' spawn-relevant constants once. The probe instance is
# never added to the tree, so `_ready` does not run — which is fine
# because every method read here returns a constant. Freed immediately.
func _species_descriptor(mob_script: Script) -> Dictionary:
	if _species_cache.has(mob_script):
		return _species_cache[mob_script]
	var descriptor: Dictionary = {
		"airborne": false, "size": 1.0, "group_size": _DEFAULT_GROUP_SIZE, "spawn_denominator": 1
	}
	var probe: Object = mob_script.new()
	if probe != null:
		if probe.has_method("spawns_airborne"):
			descriptor["airborne"] = bool(probe.call("spawns_airborne"))
		if probe.has_method("_get_body_height"):
			descriptor["size"] = float(probe.call("_get_body_height"))
		if probe.has_method("spawn_group_size"):
			descriptor["group_size"] = int(probe.call("spawn_group_size"))
		if probe.has_method("natural_spawn_denominator"):
			descriptor["spawn_denominator"] = maxi(1, int(probe.call("natural_spawn_denominator")))
		if probe is Node:
			(probe as Node).free()
		else:
			probe.free()
	_species_cache[mob_script] = descriptor
	return descriptor


# `bg.java` rejects any spawn attempt within 24 blocks of a player. The
# seed ring already starts at 24, but pack jitter is ±5 per hop with up
# to three hops, so an expansion cell could land inside the ring (audit
# finding #16). Checked at enqueue AND at drain — the player moves
# between the two.
func _outside_player_exclusion(player: Node3D, cell: Vector3i) -> bool:
	if player == null or not is_instance_valid(player):
		return true
	var centre: Vector3 = Vector3(cell) + Vector3(0.5, 0.0, 0.5)
	return centre.distance_squared_to(player.global_position) >= 24.0 * 24.0


# gdlint: disable=max-returns
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
	# Alpha combines block light with raw sky minus the world's integer
	# skyLightSubtracted value. The manager helper is shared with shaders,
	# plants, AI, and entity rendering.
	#
	# Skipped entirely in the Nether: `ef.a()` owns the light gate, and
	# neither `pt.a()` nor `am.a()` calls `super.a()` — they both
	# reimplement the check from `hf.a()` upward. A pigman is as happy in
	# a lava-lit hall as in a dark one, which is exactly what makes the
	# Nether feel populated rather than nocturnal.
	if not DimensionContext.active_provider().hostile_spawns_use_light_gate:
		return true
	var lit: int = manager.get_world_effective_light(pos)
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


# The hostile pool for whichever dimension is resident.
#
# `bg.java` reads the biome's own list — `gg.java` for the Overworld,
# `k.java` for Hell — so the pool is a property of where you are, not a
# global. The Overworld's list stays hard-coded here exactly as it was;
# the Nether names its two species on its provider.
#
# Cached per dimension, because a portal trip changes the answer and the
# old single-slot cache would have carried Overworld mobs into the Nether.
func _get_hostile_script_pool() -> Array:
	var dimension: int = DimensionContext.active()
	if _hostile_pool_cache.has(dimension):
		return _hostile_pool_cache[dimension]
	var names: Array = []
	var configured: PackedStringArray = DimensionContext.provider(dimension).natural_hostile_species
	if configured.is_empty():
		# Spider added M5. The cell-validity check still demands a 2-tall
		# AIR pocket — vanilla Alpha's SpawnerCreature uniformly checks
		# for humanoid clearance regardless of entity height, so this
		# matches vanilla even though spider's BB is only 0.9 m tall.
		names = ["zombie", "skeleton", "spider", "creeper"]
	else:
		for entry: String in configured:
			names.append(entry)
	var pool: Array = []
	for name: String in names:
		var s: Script = _MOB_REGISTRY.script_for(name)
		if s != null:
			pool.append(s)
	_hostile_pool_cache[dimension] = pool
	return pool
