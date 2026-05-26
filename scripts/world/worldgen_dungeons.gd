class_name WorldgenDungeons
extends RefCounted

# Vanilla Alpha 1.2.6 WorldGenDungeons port (`cm.java`). Called once
# per chunk during worldgen decoration, between caves and trees.
# Places 5×4×5 cobblestone rooms with a MOB_SPAWNER block at the
# center, 0-2 chests against walls with loot, and a 30% mossy-cobble
# floor + 100% cobble walls.
#
# Vanilla algorithm:
#   * 8 attempts per chunk.
#   * Per attempt: random (x, y, z) within chunk × Y in [1, 50].
#     Room half-extents from rand.nextInt(2)+2 → 2 or 3 cells each
#     side of center on X / Z. Y is always 4 cells tall (floor + 3
#     interior + roof).
#   * Validity: walls must enclose mostly-solid blocks; floor + roof
#     must be 100% solid; 1-5 wall openings (cave intersections) are
#     allowed for access. Outside that range → reject.
#   * On success: carve interior, place walls (70% cobble / 30% mossy
#     for the floor; pure cobble for walls + roof), place spawner +
#     0-2 chests with random hostile mob type + loot.
#
# We use deterministic `_hash4(chunk_x, chunk_z, attempt, salt)` RNG
# (same scheme worldgen.gd's _scatter_ores + _scatter_trees use) so
# chunk re-load reproduces identical dungeons. Vanilla's JavaRandom
# stream would be more bit-faithful but is overkill for first ship.
#
# Scope cut from vanilla:
#   * Fixed room size (half-extent always 2 → 5×4×5 interior). Vanilla
#     varies between 2 and 3, producing 5×4×5 to 7×4×7 rooms.
#   * Wall-opening count check is approximate: we require ≥1 wall
#     cell to be AIR (cave intersection = guaranteed access) but
#     don't enforce the upper bound. Vanilla rejects >5 openings to
#     avoid dungeons in giant caverns.
#   * No mossy ratio jitter on walls — only the floor gets mossy mix.

const _ATTEMPTS_PER_CHUNK: int = 8
const _MIN_Y: int = 8  # avoid bedrock
const _MAX_Y: int = 50  # below sea level, in the cave layer

# Room geometry. Half-extents fixed at 2 → 5 wide × 4 tall × 5 deep.
const _HALF_EXTENT_X: int = 2
const _HALF_EXTENT_Z: int = 2
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
const _SALT_CHEST_COUNT: int = 700121
const _SALT_CHEST_POS: int = 700139
const _SALT_LOOT: int = 700171


# Entry point — called by worldgen.gd's decoration phase. Mutates
# `chunk.blocks` and queues tile-entity work (chest contents + spawner
# config) via the singletons.
static func scatter(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	for attempt in range(_ATTEMPTS_PER_CHUNK):
		_try_place_dungeon(chunk, chunk_x, chunk_z, attempt)


static func _try_place_dungeon(chunk: Chunk, chunk_x: int, chunk_z: int, attempt: int) -> void:
	# Local-chunk coordinates for the dungeon CENTER. Keep clear of
	# chunk edges so the 5x5 walls fit inside the current chunk (we
	# don't carve into neighbor chunks).
	var margin: int = _HALF_EXTENT_X + 1
	var range_xz: int = Chunk.SIZE_X - margin * 2
	if range_xz <= 0:
		return
	var hx: int = _hash4(chunk_x, chunk_z, attempt, _SALT_X)
	var hz: int = _hash4(chunk_x, chunk_z, attempt, _SALT_Z)
	var hy: int = _hash4(chunk_x, chunk_z, attempt, _SALT_Y)
	var lx: int = margin + (hx % range_xz)
	var lz: int = margin + (hz % range_xz)
	var y: int = _MIN_Y + (hy % (_MAX_Y - _MIN_Y + 1))
	# Validate the candidate room location. Vanilla's check (walls
	# mostly opaque, floor + roof 100% opaque, 1-5 AIR openings) needs
	# the surrounding terrain present. Our approximation: room walls
	# touch ≥1 AIR cell (cave intersection = guaranteed player access)
	# AND room INTERIOR is currently mostly stone so we have something
	# to carve. Skip if either fails.
	if not _is_valid_dungeon_site(chunk, lx, y, lz):
		return
	# Build the room. Order: walls first (so the carve doesn't expose
	# raw stone behind them), then interior carve, then spawner +
	# chests.
	_build_room(chunk, lx, y, lz, chunk_x, chunk_z, attempt)
	_place_spawner(chunk, lx, y, lz, chunk_x, chunk_z, attempt)
	_place_chests(chunk, lx, y, lz, chunk_x, chunk_z, attempt)


# Room is valid if:
#   * Room center cell + the 4 cardinal floor neighbors are inside
#     the current chunk (already gated by `margin` above) AND inside
#     world Y bounds.
#   * At least one wall-perimeter cell at the floor level is AIR —
#     this proxies the "cave opening" check; without it, dungeons
#     spawn in solid stone with no way in. Vanilla requires 1-5
#     openings; we just require ≥1.
#   * Room interior has any STONE/DIRT cells (vs already-AIR) — guards
#     against placing a dungeon entirely inside a cave.
static func _is_valid_dungeon_site(chunk: Chunk, cx: int, cy: int, cz: int) -> bool:
	if cy <= 1 or cy + _ROOM_HEIGHT >= Chunk.SIZE_Y - 1:
		return false
	# Count AIR cells on the wall perimeter at the floor level.
	var openings: int = 0
	for wx in range(cx - _HALF_EXTENT_X, cx + _HALF_EXTENT_X + 1):
		for wz in range(cz - _HALF_EXTENT_Z, cz + _HALF_EXTENT_Z + 1):
			var on_perim: bool = (
				wx == cx - _HALF_EXTENT_X
				or wx == cx + _HALF_EXTENT_X
				or wz == cz - _HALF_EXTENT_Z
				or wz == cz + _HALF_EXTENT_Z
			)
			if on_perim and chunk.get_block(wx, cy, wz) == Blocks.AIR:
				openings += 1
	if openings < 1:
		return false
	# Confirm room INTERIOR has solid cells to carve. Counts STONE,
	# DIRT, GRAVEL (cave-floor materials) — pure-AIR interior means
	# we're already inside a cavern and the dungeon would float.
	var solid_interior: int = 0
	for ix in range(cx - _HALF_EXTENT_X + 1, cx + _HALF_EXTENT_X):
		for iz in range(cz - _HALF_EXTENT_Z + 1, cz + _HALF_EXTENT_Z):
			for iy in range(cy, cy + _ROOM_HEIGHT - 1):
				var b: int = chunk.get_block(ix, iy, iz)
				if b == Blocks.STONE or b == Blocks.DIRT or b == Blocks.GRAVEL:
					solid_interior += 1
	if solid_interior < 4:  # roughly 1/3 of the 3×2×3 = 18 interior
		return false
	return true


# Carve interior + place walls/floor/roof. Floor mixes cobble (70%)
# and mossy cobble (30%) per cell; walls and roof are pure cobble.
static func _build_room(
	chunk: Chunk, cx: int, cy: int, cz: int, chunk_x: int, chunk_z: int, attempt: int
) -> void:
	for wx in range(cx - _HALF_EXTENT_X, cx + _HALF_EXTENT_X + 1):
		for wz in range(cz - _HALF_EXTENT_Z, cz + _HALF_EXTENT_Z + 1):
			for wy in range(cy - 1, cy + _ROOM_HEIGHT):
				var on_floor: bool = wy == cy - 1
				var on_roof: bool = wy == cy + _ROOM_HEIGHT - 1
				var on_perim_xz: bool = (
					wx == cx - _HALF_EXTENT_X
					or wx == cx + _HALF_EXTENT_X
					or wz == cz - _HALF_EXTENT_Z
					or wz == cz + _HALF_EXTENT_Z
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
	# World coords for the tile-entity key. MobSpawnerManager reads it
	# on the next tick of the world spawner loop.
	var world_x: int = chunk_x * Chunk.SIZE_X + cx
	var world_z: int = chunk_z * Chunk.SIZE_Z + cz
	MobSpawnerManager.configure(Vector3i(world_x, cy, world_z), mob_name)


# Place 0-2 chests against walls. Vanilla cm.java loops `i < 2`, each
# iteration tries 3 random positions inside the room and places a
# chest at one that's adjacent to EXACTLY ONE wall (so the chest's
# back is against the wall, never floating in the middle).
static func _place_chests(
	chunk: Chunk, cx: int, cy: int, cz: int, chunk_x: int, chunk_z: int, attempt: int
) -> void:
	var count_seed: int = _hash4(chunk_x, chunk_z, attempt, _SALT_CHEST_COUNT)
	var count: int = count_seed % 3  # 0, 1, or 2 chests per dungeon
	for chest_idx in range(count):
		for try_idx in range(3):
			var pos_seed: int = _hash4(
				chunk_x * 53 + attempt, chunk_z * 53 + chest_idx, try_idx, _SALT_CHEST_POS
			)
			var range_x: int = _HALF_EXTENT_X * 2 - 1  # interior X range
			var range_z: int = _HALF_EXTENT_Z * 2 - 1
			var ox: int = (pos_seed & 0xFF) % range_x - _HALF_EXTENT_X + 1
			var oz: int = ((pos_seed >> 8) & 0xFF) % range_z - _HALF_EXTENT_Z + 1
			var chest_x: int = cx + ox
			var chest_z: int = cz + oz
			# Must be AIR (interior). Skip the spawner cell.
			if chunk.get_block(chest_x, cy, chest_z) != Blocks.AIR:
				continue
			# Count adjacent walls — vanilla requires exactly 1 wall touch.
			var walls: int = 0
			if chunk.get_block(chest_x - 1, cy, chest_z) == Blocks.COBBLESTONE:
				walls += 1
			if chunk.get_block(chest_x + 1, cy, chest_z) == Blocks.COBBLESTONE:
				walls += 1
			if chunk.get_block(chest_x, cy, chest_z - 1) == Blocks.COBBLESTONE:
				walls += 1
			if chunk.get_block(chest_x, cy, chest_z + 1) == Blocks.COBBLESTONE:
				walls += 1
			if walls != 1:
				continue
			chunk.set_block(chest_x, cy, chest_z, Blocks.CHEST)
			# Fill the chest with random loot.
			var world_x: int = chunk_x * Chunk.SIZE_X + chest_x
			var world_z: int = chunk_z * Chunk.SIZE_Z + chest_z
			_fill_chest(Vector3i(world_x, cy, world_z), chunk_x, chunk_z, attempt, chest_idx)
			break


# Fill a freshly-placed chest with 3-5 random items from the loot
# table. Each pick rolls the weighted table; if the landed slot has
# a `rare_chance` field, it ALSO has to pass a 1/N sub-roll (vanilla
# Alpha cp.java pattern for golden_apple at 1/100 and music_disc at
# 1/10). Rare-roll failures drop the pick so the empty slot stays
# empty — keeps the rare items rare without distorting outer weights.
static func _fill_chest(
	world_pos: Vector3i, chunk_x: int, chunk_z: int, attempt: int, chest_idx: int
) -> void:
	var slots: Array = ChestStorage.get_or_create(world_pos)
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
		# Rare-roll gate. Vanilla `random.nextInt(N) == 0` pattern; if
		# the slot has `rare_chance: N`, only 1 in N picks actually fills.
		if entry.has("rare_chance"):
			var rare_chance: int = int(entry["rare_chance"])
			if rare_chance > 1 and (rare_seed % rare_chance) != 0:
				continue
		var item_name: String = entry["item"]
		# `music_disc` is a meta-name — resolve to one of the 8 disc
		# items by hashing into _DISC_POOL. Alpha cp.java picks 1-of-2
		# discs via `dx.c[dx.aU.aW + random.nextInt(2)]`; same shape here.
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
		for slot_idx in range(slots.size()):
			var stack: ItemStack = slots[slot_idx]
			if stack.is_empty():
				stack.item_id = item_id
				stack.count = count
				break


# Deterministic 4-input integer hash. Same shape as worldgen.gd's
# _hash4 — used so this module can produce a stable RNG without
# importing the private static from worldgen.gd. xorshift mix.
static func _hash4(a: int, b: int, c: int, d: int) -> int:
	var h: int = a * 374761393 + b * 668265263 + c * 2654435761 + d * 1597334677
	h ^= h >> 13
	h *= 1274126177
	h ^= h >> 16
	return h & 0x7FFFFFFF
