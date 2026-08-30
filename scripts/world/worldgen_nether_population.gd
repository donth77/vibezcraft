class_name WorldgenNetherPopulation
extends RefCounted

# Alpha 1.2.6 Nether decorations — a port of `kj.java`'s populate method
# and the five generators it drives: `kf` (lava springs), `pm` (fire),
# `dt` and `lp` (glowstone), and `aj` (mushrooms). See the plan's §6.5.
#
# The load-order problem, and what this does about it
# ---------------------------------------------------
# Alpha populates a chunk by writing into the LIVE world at a +8 offset,
# so a feature anchored in chunk S routinely lands in S+1. Worse, `kj`
# does not reseed its shared Random before populating, so what a chunk
# decorates depends on whatever ran before it. Both make the result
# depend on load order, which this project's generation contract forbids.
#
# The canonicalisation (plan §6.5), which the source oracle also uses:
#
#   * Each SOURCE chunk owns its decorations. Its RNG state is
#     reconstructed from its own coordinates plus the exact draws the
#     surface pass makes — never inherited from a neighbour.
#   * A source decorates into a private 2x2-chunk window of finished
#     terrain, producing a WRITE LIST rather than touching a live world.
#     Its own earlier writes are visible to its later attempts (glowstone
#     chains off itself), but one source never sees another's.
#   * A target chunk merges the write lists of the four sources that can
#     reach it, in a fixed coordinate order, clipped to its own bounds.
#
# The result depends only on (world seed, chunk coordinate). Generating a
# region in any order produces identical bytes.
#
# Why a 2x2 window is exactly right: anchors sit at `chunk * 16 +
# nextInt(16) + 8`, so within [S*16+8, S*16+23], and every generator
# reaches at most 7 blocks out. Reads and writes therefore stay inside
# [S*16+1, S*16+30], which one 32x128x32 window covers.

const _WINDOW_CHUNKS: int = 2
const _WINDOW: int = _WINDOW_CHUNKS * 16
const _HEIGHT: int = 128

# Raw Alpha ids. Population runs before the project remap, like terrain.
const _AIR: int = 0
const _LAVA_FLOWING: int = 10
const _NETHERRACK: int = 87
const _GLOWSTONE: int = 89
const _FIRE: int = 51
const _MUSHROOM_BROWN: int = 39
const _MUSHROOM_RED: int = 40

# kj.java:274-311 — feature counts and the Y ranges their anchors use.
const _LAVA_SPRINGS: int = 8
const _GLOWSTONE_B_COUNT: int = 10
const _ANCHOR_Y_SPAN: int = 120
const _ANCHOR_Y_BASE: int = 4

# Attempt counts inside each generator.
const _FIRE_ATTEMPTS: int = 64
const _GLOWSTONE_ATTEMPTS: int = 1500
const _MUSHROOM_ATTEMPTS: int = 64

# Ids that count as opaque for the mushroom's support check. Mirrors
# Alpha's `nq.o` lookup restricted to the ids Nether terrain can produce.
const _OPAQUE_SUPPORTS: Array[int] = [1, 2, 3, 7, 13, 87, 88, 89]

# Bounded caches. Population needs the terrain of nine chunks per target
# (its own plus a ring), and terrain costs far more than the decorating
# itself, so recomputing it per neighbour would be nine times the work.
# Both caches are keyed by seed so a world switch cannot serve stale data,
# and both are guarded because chunk generation runs on WorkerThreadPool.
const _CACHE_LIMIT: int = 96

static var _terrain_cache: Dictionary = {}
static var _writes_cache: Dictionary = {}
static var _cache_mutex := Mutex.new()


static func reset() -> void:
	_cache_mutex.lock()
	_terrain_cache.clear()
	_writes_cache.clear()
	_cache_mutex.unlock()


static func _key(world_seed: int, cx: int, cz: int) -> String:
	return "%d|%d|%d" % [world_seed, cx, cz]


static func _cached_terrain(world_seed: int, cx: int, cz: int) -> PackedByteArray:
	var key: String = _key(world_seed, cx, cz)
	_cache_mutex.lock()
	var hit: bool = _terrain_cache.has(key)
	var value: PackedByteArray = _terrain_cache.get(key, PackedByteArray())
	_cache_mutex.unlock()
	if hit:
		return value
	# Computed OUTSIDE the lock: terrain generation is slow, and holding
	# the mutex across it would serialise every worker. Two workers may
	# duplicate the work for one chunk; the result is deterministic, so
	# the duplicate is wasted time rather than a correctness problem.
	var terrain: PackedByteArray = WorldgenNether.generate_terrain_only(cx, cz)
	_cache_mutex.lock()
	if _terrain_cache.size() >= _CACHE_LIMIT:
		_terrain_cache.clear()
	_terrain_cache[key] = terrain
	_cache_mutex.unlock()
	return terrain


# --- Window helpers ---


static func _window_index(lx: int, y: int, lz: int) -> int:
	return (lx * _WINDOW + lz) * _HEIGHT + y


# Build the 32x128x32 terrain window a source chunk decorates into. The
# window's south-west corner is the source chunk's own origin.
static func _build_window(world_seed: int, source_x: int, source_z: int) -> PackedByteArray:
	var window := PackedByteArray()
	window.resize(_WINDOW * _HEIGHT * _WINDOW)
	for dx: int in range(_WINDOW_CHUNKS):
		for dz: int in range(_WINDOW_CHUNKS):
			var terrain: PackedByteArray = _cached_terrain(world_seed, source_x + dx, source_z + dz)
			for x: int in range(16):
				for z: int in range(16):
					for y: int in range(_HEIGHT):
						window[_window_index(dx * 16 + x, y, dz * 16 + z)] = terrain[
							WorldgenNether.alpha_index(x, y, z)
						]
	return window


# --- Public entry point ---


# Every cell one source chunk's decorations write, as a flat list of
# [world_x, y, world_z, alpha_id]. Deterministic in (seed, source chunk).
static func write_list(world_seed: int, source_x: int, source_z: int) -> Array:
	if WorldgenNether.native_available():
		# Native returns a flat [x, y, z, id, ...] int array; unpack to the
		# same shape the GDScript path produces so callers never branch.
		var flat: PackedInt32Array = WorldgenNether.native_write_list(source_x, source_z)
		var unpacked: Array = []
		for i: int in range(0, flat.size(), 4):
			unpacked.append([flat[i], flat[i + 1], flat[i + 2], flat[i + 3]])
		return unpacked
	return write_list_gdscript(world_seed, source_x, source_z)


static func write_list_gdscript(world_seed: int, source_x: int, source_z: int) -> Array:
	var key: String = _key(world_seed, source_x, source_z)
	_cache_mutex.lock()
	var hit: bool = _writes_cache.has(key)
	var cached: Array = _writes_cache.get(key, [])
	_cache_mutex.unlock()
	if hit:
		return cached

	var window: PackedByteArray = _build_window(world_seed, source_x, source_z)
	var before: PackedByteArray = window.duplicate()
	# The canonical RNG state: the source chunk's own seed, advanced by
	# exactly the draws its surface pass makes. Alpha inherits whatever
	# state the previous chunk left behind; this does not.
	var rng: JavaRandom = WorldgenNether.post_surface_rng(source_x, source_z)
	_populate(window, rng, source_x, source_z)

	var writes: Array = []
	for lx: int in range(_WINDOW):
		for lz: int in range(_WINDOW):
			for y: int in range(_HEIGHT):
				var i: int = _window_index(lx, y, lz)
				if before[i] == window[i]:
					continue
				writes.append([source_x * 16 + lx, y, source_z * 16 + lz, window[i]])
	_cache_mutex.lock()
	if _writes_cache.size() >= _CACHE_LIMIT:
		_writes_cache.clear()
	_writes_cache[key] = writes
	_cache_mutex.unlock()
	return writes


# Apply every decoration that lands in this chunk. `blocks` is a raw
# Alpha-layout chunk array, mutated in place.
#
# The four contributing sources are visited in ascending (x, z) order so
# that two sources writing the same cell resolve the same way every time.
static func decorate(blocks: PackedByteArray, chunk_x: int, chunk_z: int) -> void:
	var world_seed: int = Worldgen.WORLD_SEED
	var min_x: int = chunk_x * 16
	var min_z: int = chunk_z * 16
	for source_x: int in [chunk_x - 1, chunk_x]:
		for source_z: int in [chunk_z - 1, chunk_z]:
			for entry: Array in write_list(world_seed, source_x, source_z):
				var lx: int = int(entry[0]) - min_x
				var lz: int = int(entry[2]) - min_z
				if lx < 0 or lx >= 16 or lz < 0 or lz >= 16:
					continue
				blocks[WorldgenNether.alpha_index(lx, int(entry[1]), lz)] = int(entry[3])


# --- kj.java:265-312, the populate sequence ---


static func _populate(
	window: PackedByteArray, rng: JavaRandom, source_x: int, source_z: int
) -> void:
	var base_x: int = source_x * 16
	var base_z: int = source_z * 16
	# 1. Eight lava springs.
	for _i: int in range(_LAVA_SPRINGS):
		var x: int = base_x + rng.next_int_bounded(16) + 8
		var y: int = rng.next_int_bounded(_ANCHOR_Y_SPAN) + _ANCHOR_Y_BASE
		var z: int = base_z + rng.next_int_bounded(16) + 8
		_lava_spring(window, source_x, source_z, x, y, z)
	# 2. Fire clusters. The doubly-nested nextInt is short-biased: most
	#    chunks get one or two.
	var fire_count: int = rng.next_int_bounded(rng.next_int_bounded(10) + 1) + 1
	for _i: int in range(fire_count):
		var x: int = base_x + rng.next_int_bounded(16) + 8
		var y: int = rng.next_int_bounded(_ANCHOR_Y_SPAN) + _ANCHOR_Y_BASE
		var z: int = base_z + rng.next_int_bounded(16) + 8
		_fire_cluster(window, rng, source_x, source_z, x, y, z)
	# 3. Glowstone, entry point A. Note the missing `+ 1` compared with
	#    the fire count above — this one can legitimately be zero.
	var glow_a: int = rng.next_int_bounded(rng.next_int_bounded(10) + 1)
	for _i: int in range(glow_a):
		var x: int = base_x + rng.next_int_bounded(16) + 8
		var y: int = rng.next_int_bounded(_ANCHOR_Y_SPAN) + _ANCHOR_Y_BASE
		var z: int = base_z + rng.next_int_bounded(16) + 8
		_glowstone(window, rng, source_x, source_z, x, y, z)
	# 4. Glowstone, entry point B — always ten, and anchored anywhere in
	#    the column rather than in the 4..123 band.
	#
	#    `dt.java` and `lp.java` are BYTE-IDENTICAL in the decompiled
	#    source; the plan asked for two named entry points until parity
	#    proved otherwise, and it has. They differ only in how they are
	#    called, which is preserved above and below.
	for _i: int in range(_GLOWSTONE_B_COUNT):
		var x: int = base_x + rng.next_int_bounded(16) + 8
		var y: int = rng.next_int_bounded(128)
		var z: int = base_z + rng.next_int_bounded(16) + 8
		_glowstone(window, rng, source_x, source_z, x, y, z)
	# 5-6. One brown and one red mushroom. Both guards are `nextInt(1) ==
	#      0`, which is always true — the draw still happens and still
	#      advances the stream, so it cannot be optimised away.
	if rng.next_int_bounded(1) == 0:
		var x: int = base_x + rng.next_int_bounded(16) + 8
		var y: int = rng.next_int_bounded(128)
		var z: int = base_z + rng.next_int_bounded(16) + 8
		_mushroom(window, rng, source_x, source_z, x, y, z, _MUSHROOM_BROWN)
	if rng.next_int_bounded(1) == 0:
		var x: int = base_x + rng.next_int_bounded(16) + 8
		var y: int = rng.next_int_bounded(128)
		var z: int = base_z + rng.next_int_bounded(16) + 8
		_mushroom(window, rng, source_x, source_z, x, y, z, _MUSHROOM_RED)


# --- Window access in world coordinates ---
#
# Named _read/_write rather than _get/_set: those two collide with
# Object's built-in property virtuals and GDScript rejects the override.


static func _read(window: PackedByteArray, ox: int, oz: int, x: int, y: int, z: int) -> int:
	var lx: int = x - ox
	var lz: int = z - oz
	if lx < 0 or lx >= _WINDOW or lz < 0 or lz >= _WINDOW or y < 0 or y >= _HEIGHT:
		return _AIR
	return window[_window_index(lx, y, lz)]


static func _write(
	window: PackedByteArray, ox: int, oz: int, x: int, y: int, z: int, id: int
) -> void:
	var lx: int = x - ox
	var lz: int = z - oz
	if lx < 0 or lx >= _WINDOW or lz < 0 or lz >= _WINDOW or y < 0 or y >= _HEIGHT:
		return
	window[_window_index(lx, y, lz)] = id


# --- kf.java: lava spring ---
#
# Places a single flowing-lava source in a netherrack pocket that has
# exactly one open side. Consumes no RNG of its own.
#
# DEVIATION: the source follows the placement with a block update, which
# runs Alpha's fluid tick and lets the lava start flowing during
# generation. This port places the source block only and leaves the flow
# to the project's own fluid system after the chunk materialises.
static func _lava_spring(window: PackedByteArray, ox: int, oz: int, x: int, y: int, z: int) -> void:
	var origin_x: int = ox * 16
	var origin_z: int = oz * 16
	if _read(window, origin_x, origin_z, x, y + 1, z) != _NETHERRACK:
		return
	var here: int = _read(window, origin_x, origin_z, x, y, z)
	if here != _AIR and here != _NETHERRACK:
		return
	var neighbours: Array[Vector3i] = [
		Vector3i(x - 1, y, z),
		Vector3i(x + 1, y, z),
		Vector3i(x, y, z - 1),
		Vector3i(x, y, z + 1),
		Vector3i(x, y - 1, z),
	]
	var rock: int = 0
	var air: int = 0
	for n: Vector3i in neighbours:
		var id: int = _read(window, origin_x, origin_z, n.x, n.y, n.z)
		if id == _NETHERRACK:
			rock += 1
		elif id == _AIR:
			air += 1
	if rock == 4 and air == 1:
		_write(window, origin_x, origin_z, x, y, z, _LAVA_FLOWING)


# --- pm.java: fire cluster ---


static func _fire_cluster(
	window: PackedByteArray, rng: JavaRandom, ox: int, oz: int, x: int, y: int, z: int
) -> void:
	var origin_x: int = ox * 16
	var origin_z: int = oz * 16
	for _i: int in range(_FIRE_ATTEMPTS):
		# Draw order is X, Y, Z — the source computes X on its own line
		# and the other two inside the argument list, left to right.
		var tx: int = x + rng.next_int_bounded(8) - rng.next_int_bounded(8)
		var ty: int = y + rng.next_int_bounded(4) - rng.next_int_bounded(4)
		var tz: int = z + rng.next_int_bounded(8) - rng.next_int_bounded(8)
		if _read(window, origin_x, origin_z, tx, ty, tz) != _AIR:
			continue
		if _read(window, origin_x, origin_z, tx, ty - 1, tz) != _NETHERRACK:
			continue
		_write(window, origin_x, origin_z, tx, ty, tz, _FIRE)


# --- dt.java / lp.java: glowstone ---


static func _glowstone(
	window: PackedByteArray, rng: JavaRandom, ox: int, oz: int, x: int, y: int, z: int
) -> void:
	var origin_x: int = ox * 16
	var origin_z: int = oz * 16
	# The anchor must be open air with a netherrack ceiling. A failed
	# anchor returns immediately and consumes NO further RNG, which is
	# why the early-out has to happen before the attempt loop.
	if _read(window, origin_x, origin_z, x, y, z) != _AIR:
		return
	if _read(window, origin_x, origin_z, x, y + 1, z) != _NETHERRACK:
		return
	_write(window, origin_x, origin_z, x, y, z, _GLOWSTONE)
	for _i: int in range(_GLOWSTONE_ATTEMPTS):
		var tx: int = x + rng.next_int_bounded(8) - rng.next_int_bounded(8)
		var ty: int = y - rng.next_int_bounded(12)
		var tz: int = z + rng.next_int_bounded(8) - rng.next_int_bounded(8)
		if _read(window, origin_x, origin_z, tx, ty, tz) != _AIR:
			continue
		# Grow only where EXACTLY ONE orthogonal neighbour is already
		# glowstone. That is what makes the cluster hang in a blob rather
		# than flood the cavern.
		#
		# The decompiled source writes this as `if (n8 != true)`, which is
		# not valid Java — CFR rendered a comparison against the constant
		# 1 that way. See the artifact repair in the oracle's emitter.
		var touching: int = 0
		for n: Vector3i in [
			Vector3i(tx - 1, ty, tz),
			Vector3i(tx + 1, ty, tz),
			Vector3i(tx, ty - 1, tz),
			Vector3i(tx, ty + 1, tz),
			Vector3i(tx, ty, tz - 1),
			Vector3i(tx, ty, tz + 1),
		]:
			if _read(window, origin_x, origin_z, n.x, n.y, n.z) == _GLOWSTONE:
				touching += 1
		if touching != 1:
			continue
		_write(window, origin_x, origin_z, tx, ty, tz, _GLOWSTONE)


# --- aj.java: mushrooms ---


static func _mushroom(
	window: PackedByteArray,
	rng: JavaRandom,
	ox: int,
	oz: int,
	x: int,
	y: int,
	z: int,
	block_id: int
) -> void:
	var origin_x: int = ox * 16
	var origin_z: int = oz * 16
	for _i: int in range(_MUSHROOM_ATTEMPTS):
		var tx: int = x + rng.next_int_bounded(8) - rng.next_int_bounded(8)
		var ty: int = y + rng.next_int_bounded(4) - rng.next_int_bounded(4)
		var tz: int = z + rng.next_int_bounded(8) - rng.next_int_bounded(8)
		if _read(window, origin_x, origin_z, tx, ty, tz) != _AIR:
			continue
		# `mr.java`'s placement predicate is
		# `world.getLightLevel(x,y,z) <= 13 && isOpaqueCube(below)`.
		# During Nether population no light exists yet — the dimension has
		# no sky and block light has not propagated — so the light term is
		# trivially satisfied and only the support check remains.
		if not _OPAQUE_SUPPORTS.has(_read(window, origin_x, origin_z, tx, ty - 1, tz)):
			continue
		_write(window, origin_x, origin_z, tx, ty, tz, block_id)
