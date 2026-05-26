class_name WorldgenDungeons
extends RefCounted

# Vanilla Alpha 1.2.6 WorldGenDungeons port (`cp.java`). Called once
# per chunk during worldgen decoration, between caves and trees.
# Places 5×4×5 or 7×4×7 cobblestone rooms (vanilla rolls 2-or-3 per
# axis independently) with a MOB_SPAWNER at the center, ≤2 chests
# against walls with loot, and a 30% mossy-cobble floor + 100% cobble
# walls.
#
# Vanilla algorithm:
#   * 8 attempts per chunk (`px.java:294`).
#   * Per attempt: random (x, y, z) in chunk × Y in [0, 128). Room
#     half-extents = nextInt(2) + 2 → 2 or 3 cells each side, X and Z
#     independent. Interior 4 cells tall (floor + 3 + roof).
#   * Validity (`cp.java:11-28`): 7×7 floor + ceiling rings must be
#     entirely solid material (treats water/lava as non-solid); 1-5
#     two-tall non-solid "doorways" on the outside-wall perimeter.
#   * On success: place walls + roof (pure cobble), mix mossy into
#     the floor, write spawner cell at center, attempt up to 2 chest
#     placements against valid 1-wall-touch interior cells.
#
# We use deterministic `_hash4(chunk_x, chunk_z, attempt, salt)` RNG
# rather than vanilla's JavaRandom stream — bit-parity isn't required
# and the hash is cheaper for chunk-reload determinism.

const _ATTEMPTS_PER_CHUNK: int = 8  # vanilla `px.java:294`
# Y range matches vanilla `px.java:296` (`nextInt(128)`) modulo the
# bedrock-clear margin. Earlier restriction to [8, 50] was useless:
# our cave gen carves at Y ~[40, 90], so dungeons in [8, 50] never
# saw the cave-opening that `_is_valid_dungeon_site` requires.
const _MIN_Y: int = 8  # avoid bedrock
const _MAX_Y: int = 90  # full cave layer

# Room half-extents — vanilla `cp.java:5-6` rolls `nextInt(2) + 2` per
# axis (independently), so each axis lands on 2 or 3 with equal
# probability. Combined room sizes 5×5, 5×7, 7×5, or 7×7 (25% each).
# Y is fixed 4-cell interior (vanilla `n8 = 3`; floor + 3 + ceiling).
const _HALF_EXTENT_MIN: int = 2
const _HALF_EXTENT_MAX: int = 3
const _ROOM_HEIGHT: int = 4

# Floor mossy-cobble ratio. Vanilla `rand.nextInt(4) != 0` → cobble
# 25% of the time, mossy 75%. We invert to read as "30% mossy" since
# the project comments lead with cobble percentages elsewhere.
const _FLOOR_MOSSY_RATIO: float = 0.3

# Hostile mob pool the spawner is configured to spawn. Vanilla Alpha
# picks one of {zombie, skeleton, spider} per dungeon. We have only
# zombie for now; the array still hashes-down to one entry, but the
# rest will land here as skeleton/spider classes ship.
const _SPAWNER_MOB_POOL: Array = ["zombie"]

# Chest loot — Alpha 1.2.6 `cp.java::a(Random)` does an 11-slot roll
# where most items have weight 1 (equal probability) and two items
# (golden apple + music disc) are gated behind a secondary rare roll.
# We mirror that shape: common items get weight 1, golden apple +
# music disc are SECONDARY rolls (only triggered when the outer slot
# rolls onto them AND a sub-roll passes). Modern Monster Room wiki
# extends the table with bone + coal + leather + redstone — those
# slot in as additional weight-1 entries.
#
# Per slot:
#   * "item" — id_from_name lookup at fill time (alias "redstone_dust"
#     resolves to REDSTONE; "music_disc" picks one of our 8 discs).
#   * "weight" — relative odds within the outer roll.
#   * "count_max" — count rolled uniformly in [1, count_max].
#   * "rare_chance" — if present, an additional 1/N sub-roll gates
#     the slot. Mirrors vanilla cp.java's `random.nextInt(N) == 0`
#     pattern for golden_apple (1/100) and music_disc (1/10).
const _LOOT_TABLE: Array = [
	# Bulk drops — most common (1-4 per slot). Direct from Alpha's
	# equal-weight slot pattern.
	{"item": "bone", "weight": 1, "count_max": 4},
	{"item": "gunpowder", "weight": 1, "count_max": 4},
	{"item": "string", "weight": 1, "count_max": 4},
	{"item": "coal", "weight": 1, "count_max": 4},
	{"item": "redstone_dust", "weight": 1, "count_max": 4},
	{"item": "iron_ingot", "weight": 1, "count_max": 4},
	{"item": "gold_ingot", "weight": 1, "count_max": 4},
	# Modest counts — vanilla 1-2 per slot.
	{"item": "wheat", "weight": 1, "count_max": 2},
	{"item": "leather", "weight": 1, "count_max": 2},
	# Single-item slots — vanilla 1 only.
	{"item": "bread", "weight": 1, "count_max": 1},
	{"item": "bucket_empty", "weight": 1, "count_max": 1},
	{"item": "saddle", "weight": 1, "count_max": 1},
	# Rare slots — gated by an additional sub-roll. Alpha cp.java has
	# golden_apple at 1/100 and music_disc at 1/10. Lower outer weight
	# would push the rare items off entirely; keeping weight 1 + the
	# sub-roll matches vanilla's published rarity.
	{"item": "golden_apple", "weight": 1, "count_max": 1, "rare_chance": 100},
	{"item": "music_disc", "weight": 1, "count_max": 1, "rare_chance": 10},
]

# Picks per chest — Alpha `cm.java` runs 8 fill iterations against a
# 27-slot inventory; many roll `null` (no item) and don't drop in.
# Realised drops per chest land around 3-5. We just roll 3-5 directly
# so the player sees a consistent loot density.
const _LOOT_PICKS_PER_CHEST_MIN: int = 3
const _LOOT_PICKS_PER_CHEST_MAX: int = 5

# Music disc pool — when the "music_disc" loot slot lands, pick one
# of our 8 discs uniformly. Vanilla Alpha had 2 discs (13 + cat) so
# the random.nextInt(2) pick maps a similar choice across our set.
const _DISC_POOL: Array = [
	"music_disc_first_light",
	"music_disc_green_distance",
	"music_disc_long_shadow",
	"music_disc_hollow_earth",
	"music_disc_bedrock",
	"music_disc_open_sky",
	"music_disc_hearthstone",
	"music_disc_still_water",
]

# Salts for the deterministic per-attempt hashes. Distinct from
# worldgen.gd's tree / ore salts (those use 999983, 1, 2, 3, etc.) so
# our hashes don't correlate.
const _SALT_X: int = 700001
const _SALT_Y: int = 700013
const _SALT_Z: int = 700031
const _SALT_MOB: int = 700057
const _SALT_FLOOR: int = 700099  # per-cell mossy decision on the floor
const _SALT_CHEST_POS: int = 700139
const _SALT_LOOT: int = 700171
const _SALT_HX: int = 700203  # X half-extent (2 or 3) per attempt
const _SALT_HZ: int = 700227  # Z half-extent


# Entry point — called by worldgen.gd's decoration phase. Mutates
# `chunk.blocks` and queues tile-entity work (chest contents + spawner
# config) via the singletons.
static func scatter(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	for attempt in range(_ATTEMPTS_PER_CHUNK):
		_try_place_dungeon(chunk, chunk_x, chunk_z, attempt)


static func _try_place_dungeon(chunk: Chunk, chunk_x: int, chunk_z: int, attempt: int) -> void:
	# Per-attempt room shape — vanilla `cp.java:5-6` rolls each axis
	# independently. With _HALF_EXTENT_{MIN,MAX} = (2, 3) → 2 or 3.
	var hx_hash: int = _hash4(chunk_x, chunk_z, attempt, _SALT_HX)
	var hz_hash: int = _hash4(chunk_x, chunk_z, attempt, _SALT_HZ)
	var hx: int = _HALF_EXTENT_MIN + (hx_hash % (_HALF_EXTENT_MAX - _HALF_EXTENT_MIN + 1))
	var hz: int = _HALF_EXTENT_MIN + (hz_hash % (_HALF_EXTENT_MAX - _HALF_EXTENT_MIN + 1))
	# Margin = max half-extent + 1 (room of size 2*hx+1 plus a 1-cell
	# outside-perimeter for the validity check, all inside the chunk).
	var margin: int = maxi(hx, hz) + 1
	var range_x: int = Chunk.SIZE_X - margin * 2
	var range_z: int = Chunk.SIZE_Z - margin * 2
	if range_x <= 0 or range_z <= 0:
		return
	var lx_hash: int = _hash4(chunk_x, chunk_z, attempt, _SALT_X)
	var lz_hash: int = _hash4(chunk_x, chunk_z, attempt, _SALT_Z)
	var hy: int = _hash4(chunk_x, chunk_z, attempt, _SALT_Y)
	var lx: int = margin + (lx_hash % range_x)
	var lz: int = margin + (lz_hash % range_z)
	var y: int = _MIN_Y + (hy % (_MAX_Y - _MIN_Y + 1))
	if not _is_valid_dungeon_site(chunk, lx, y, lz, hx, hz):
		return
	# Build order: walls first (carve doesn't expose raw stone behind
	# them), then interior carve, then spawner + chests.
	_build_room(chunk, lx, y, lz, hx, hz, chunk_x, chunk_z, attempt)
	_place_spawner(chunk, lx, y, lz, chunk_x, chunk_z, attempt)
	_place_chests(chunk, lx, y, lz, hx, hz, chunk_x, chunk_z, attempt)


# Vanilla `cp.java:11-28` port. Three checks against the surrounding
# terrain (sampled in a 7×7 plan centered on the room — the dungeon
# walls plus one cell of outside terrain on each side):
#   1. Every floor cell (`y = cy - 1`) is solid material (not AIR /
#      water / lava). Without this the room would hang over a void.
#   2. Every ceiling cell (`y = cy + _ROOM_HEIGHT - 1`) is solid —
#      prevents above-ground placements where the sky is the roof.
#   3. The outside-perimeter ring (one cell beyond the wall, at floor
#      level + the cell above) has 1-5 "doorway" gaps where BOTH
#      cells are non-solid. Forces ≥1 cave connection and <6 (so it
#      isn't a hillside with three walls missing).
# Vanilla `material.isSolid` treats water + lava as non-solid (they
# carve and flow). Below SEA_LEVEL our 3D-terrain post-pass converts
# cave AIR to WATER, so dungeons in underwater caves only work if we
# match vanilla's "fluid counts as opening" semantics. Treating only
# AIR as passable is the bug that made dungeons effectively impossible
# below Y=60 (where almost all our caves carve).
# Bounds-safe: margin in `_try_place_dungeon` already keeps the room
# center 3 cells from any chunk edge.
static func _is_solid_for_dungeon(block_id: int) -> bool:
	return (
		block_id != Blocks.AIR
		and block_id != Blocks.WATER_FLOWING
		and block_id != Blocks.WATER_STILL
		and block_id != Blocks.LAVA_FLOWING
		and block_id != Blocks.LAVA_STILL
	)


static func _is_valid_dungeon_site(
	chunk: Chunk, cx: int, cy: int, cz: int, hx: int, hz: int
) -> bool:
	var room_h: int = _ROOM_HEIGHT
	if cy <= 1 or cy + room_h >= Chunk.SIZE_Y:
		return false
	var x0: int = cx - hx - 1
	var x1: int = cx + hx + 1
	var z0: int = cz - hz - 1
	var z1: int = cz + hz + 1
	var floor_y: int = cy - 1
	var ceiling_y: int = cy + room_h - 1
	for ax in range(x0, x1 + 1):
		for az in range(z0, z1 + 1):
			if not _is_solid_for_dungeon(chunk.get_block(ax, floor_y, az)):
				return false
			if not _is_solid_for_dungeon(chunk.get_block(ax, ceiling_y, az)):
				return false
	var openings: int = 0
	for ax in range(x0, x1 + 1):
		for az in range(z0, z1 + 1):
			var on_outer: bool = ax == x0 or ax == x1 or az == z0 or az == z1
			if not on_outer:
				continue
			var here_solid: bool = _is_solid_for_dungeon(chunk.get_block(ax, cy, az))
			var above_solid: bool = _is_solid_for_dungeon(chunk.get_block(ax, cy + 1, az))
			if not here_solid and not above_solid:
				openings += 1
	if openings < 1 or openings > 5:
		return false
	return true


# Carve interior + place walls/floor/roof. Floor mixes cobble (70%)
# and mossy cobble (30%) per cell; walls and roof are pure cobble.
static func _build_room(
	chunk: Chunk,
	cx: int,
	cy: int,
	cz: int,
	hx: int,
	hz: int,
	chunk_x: int,
	chunk_z: int,
	attempt: int
) -> void:
	for wx in range(cx - hx, cx + hx + 1):
		for wz in range(cz - hz, cz + hz + 1):
			for wy in range(cy - 1, cy + _ROOM_HEIGHT):
				var on_floor: bool = wy == cy - 1
				var on_roof: bool = wy == cy + _ROOM_HEIGHT - 1
				var on_perim_xz: bool = (
					wx == cx - hx or wx == cx + hx or wz == cz - hz or wz == cz + hz
				)
				if on_floor:
					var floor_seed: int = _hash4(
						chunk_x * 31 + attempt, chunk_z * 31 + wx, wz, _SALT_FLOOR
					)
					var mossy_pick: bool = (
						(float(floor_seed & 0xFFFF) / 65535.0) < _FLOOR_MOSSY_RATIO
					)
					chunk.set_block(
						wx, wy, wz, Blocks.MOSSY_COBBLESTONE if mossy_pick else Blocks.COBBLESTONE
					)
				elif on_roof or on_perim_xz:
					chunk.set_block(wx, wy, wz, Blocks.COBBLESTONE)
				else:
					# Interior cell — carve to AIR.
					chunk.set_block(wx, wy, wz, Blocks.AIR)


# Place the MOB_SPAWNER block at the room center floor level + 1
# (just above the floor) and register the tile entity with
# MobSpawnerManager so the cage emits mobs of the chosen species.
static func _place_spawner(
	chunk: Chunk, cx: int, cy: int, cz: int, chunk_x: int, chunk_z: int, attempt: int
) -> void:
	# Set the cage block. Floor at cy-1 is solid; cy is the lowest
	# AIR interior cell. Spawner sits one cell above the floor so the
	# mob model has clearance to render.
	chunk.set_block(cx, cy, cz, Blocks.MOB_SPAWNER)
	var mob_idx: int = _hash4(chunk_x, chunk_z, attempt, _SALT_MOB) % _SPAWNER_MOB_POOL.size()
	var mob_name: String = _SPAWNER_MOB_POOL[mob_idx]
	# Worldgen runs on a WorkerThreadPool task. MobSpawnerManager's
	# static `_spawners` dict + TickScheduler queue are owned by the
	# main thread, so we record the intent here and let
	# ChunkManager._materialize_chunk drain it. Same pattern as
	# `cane_tops` (worker→main hand-off).
	chunk.pending_tile_entities.append(
		{"type": "spawner", "pos": Vector3i(cx, cy, cz), "mob": mob_name}
	)


# Attempt 2 chest placements (vanilla `cp.java:51` always loops 2).
# Each iteration tries 3 random interior positions; the first that's
# adjacent to EXACTLY ONE wall gets a chest (back to wall, opening to
# the interior). All 3 tries can fail, in which case that iteration
# places nothing — vanilla behavior. Realised count is 0-2; typically 2.
static func _place_chests(
	chunk: Chunk,
	cx: int,
	cy: int,
	cz: int,
	hx: int,
	hz: int,
	chunk_x: int,
	chunk_z: int,
	attempt: int
) -> void:
	# Vanilla `cp.java:51` always loops 2 chest-placement iterations.
	# Each iteration may FAIL to find a valid 1-wall-touch spot (after
	# 3 position tries), so realised chest count is 0-2 with typical
	# of 2. Previously `count = seed % 3` made 33% of dungeons
	# chestless on purpose — strictly less faithful than vanilla.
	for chest_idx in range(2):
		for try_idx in range(3):
			var pos_seed: int = _hash4(
				chunk_x * 53 + attempt, chunk_z * 53 + chest_idx, try_idx, _SALT_CHEST_POS
			)
			# Interior X / Z extents = (2*h - 1) cells (excludes walls).
			var range_x: int = hx * 2 - 1
			var range_z: int = hz * 2 - 1
			var ox: int = (pos_seed & 0xFF) % range_x - hx + 1
			var oz: int = ((pos_seed >> 8) & 0xFF) % range_z - hz + 1
			var chest_x: int = cx + ox
			var chest_z: int = cz + oz
			# Must be AIR (interior). Skip the spawner cell.
			if chunk.get_block(chest_x, cy, chest_z) != Blocks.AIR:
				continue
			# Count adjacent walls — vanilla `cp.java:60-72` requires
			# exactly 1 wall touch so the chest sits flush against a
			# single wall (back to wall, opening toward room interior).
			var walls: int = 0
			var wall_neg_x: bool = chunk.get_block(chest_x - 1, cy, chest_z) == Blocks.COBBLESTONE
			var wall_pos_x: bool = chunk.get_block(chest_x + 1, cy, chest_z) == Blocks.COBBLESTONE
			var wall_neg_z: bool = chunk.get_block(chest_x, cy, chest_z - 1) == Blocks.COBBLESTONE
			var wall_pos_z: bool = chunk.get_block(chest_x, cy, chest_z + 1) == Blocks.COBBLESTONE
			if wall_neg_x:
				walls += 1
			if wall_pos_x:
				walls += 1
			if wall_neg_z:
				walls += 1
			if wall_pos_z:
				walls += 1
			if walls != 1:
				continue
			chunk.set_block(chest_x, cy, chest_z, Blocks.CHEST)
			# Face the chest AWAY from the adjacent wall (latch toward
			# room interior — matches vanilla MC chest orientation and
			# the player-placement convention in `interaction.gd::
			# _chest_meta_from_yaw`). Meta encoding: 0=-Z, 1=-X, 2=+Z,
			# 3=+X (the direction the FRONT/latch faces).
			var chest_meta: int = 0
			if wall_neg_x:
				chest_meta = 3  # wall at -X → face +X
			elif wall_pos_x:
				chest_meta = 1  # wall at +X → face -X
			elif wall_neg_z:
				chest_meta = 2  # wall at -Z → face +Z
			else:  # wall_pos_z
				chest_meta = 0  # wall at +Z → face -Z
			chunk.set_block_meta(chest_x, cy, chest_z, chest_meta)
			# Roll the loot here (deterministic), and queue the slot
			# writes for main-thread application. Same threading rule
			# as the spawner above.
			var items: Array = _roll_chest_loot(chunk_x, chunk_z, attempt, chest_idx)
			chunk.pending_tile_entities.append(
				{"type": "chest_fill", "pos": Vector3i(chest_x, cy, chest_z), "items": items}
			)
			break


# Deterministic loot roll. Returns `Array[[item_id, count]]` of length
# 3-5 (matches realised vanilla chest density). Each pick rolls the
# weighted loot table; if the landed slot has a `rare_chance` field,
# it ALSO has to pass a 1/N sub-roll (vanilla Alpha cp.java pattern
# for golden_apple at 1/100 and music_disc at 1/10). Rare-roll
# failures are filtered out so the slot just stays empty. Caller
# (main thread) writes these into ChestStorage via the chunk's
# pending_tile_entities array.
static func _roll_chest_loot(chunk_x: int, chunk_z: int, attempt: int, chest_idx: int) -> Array:
	var result: Array = []
	var picks_seed: int = _hash4(chunk_x * 41 + attempt, chunk_z * 41 + chest_idx, 1, _SALT_LOOT)
	var pick_range: int = _LOOT_PICKS_PER_CHEST_MAX - _LOOT_PICKS_PER_CHEST_MIN + 1
	var picks: int = _LOOT_PICKS_PER_CHEST_MIN + (picks_seed % pick_range)
	var total_weight: int = 0
	for entry: Dictionary in _LOOT_TABLE:
		total_weight += int(entry["weight"])
	for pick_idx in range(picks):
		var item_seed: int = _hash4(
			chunk_x * 67 + chest_idx, chunk_z * 67 + pick_idx, attempt, _SALT_LOOT + 1
		)
		var count_seed: int = _hash4(
			chunk_x * 71 + chest_idx, chunk_z * 71 + pick_idx, attempt, _SALT_LOOT + 2
		)
		var rare_seed: int = _hash4(
			chunk_x * 73 + chest_idx, chunk_z * 73 + pick_idx, attempt, _SALT_LOOT + 3
		)
		var roll: int = item_seed % total_weight
		var entry: Dictionary = _LOOT_TABLE[0]
		var acc: int = 0
		for candidate: Dictionary in _LOOT_TABLE:
			acc += int(candidate["weight"])
			if roll < acc:
				entry = candidate
				break
		if entry.has("rare_chance"):
			var rare_chance: int = int(entry["rare_chance"])
			if rare_chance > 1 and (rare_seed % rare_chance) != 0:
				continue
		var item_name: String = entry["item"]
		if item_name == "music_disc":
			var disc_seed: int = _hash4(
				chunk_x * 79 + chest_idx, chunk_z * 79 + pick_idx, attempt, _SALT_LOOT + 4
			)
			item_name = _DISC_POOL[disc_seed % _DISC_POOL.size()]
		var item_id: int = Items.id_from_name(item_name)
		if item_id < 0:
			continue
		var count_max: int = int(entry["count_max"])
		var count: int = 1 + (count_seed % count_max)
		result.append([item_id, count])
	return result


# Deterministic 4-input integer hash. Same shape as worldgen.gd's
# _hash4 — used so this module can produce a stable RNG without
# importing the private static from worldgen.gd. xorshift mix.
static func _hash4(a: int, b: int, c: int, d: int) -> int:
	var h: int = a * 374761393 + b * 668265263 + c * 2654435761 + d * 1597334677
	h ^= h >> 13
	h *= 1274126177
	h ^= h >> 16
	return h & 0x7FFFFFFF
