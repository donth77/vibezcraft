class_name Worldgen
extends RefCounted

# Phase 5 worldgen: 2D Perlin heightmap + stratified layering, plus
# ore veins and oak trees. Generation is deterministic per (seed, x, z)
# — the same chunk coords always produce the same blocks.
#
# Ore veins follow vanilla WorldGenMinable (ellipsoid-along-line fill,
# Bukkit/mc-dev). Vein sizes + Y bands match Beta 1.7-era (close to
# Alpha 1.2.6 — the era we're cloning). Coal and iron attempt counts
# are bumped a notch above vanilla's 20/20 (to 23/22) so our per-chunk
# yields land inside [100%, 140%] of vanilla Alpha's empirical numbers
# (coal ~111, iron ~77) — the ellipsoid's natural clip at chunk borders
# shaves ~10% off without this nudge. Per chunk:
#   • Coal:    28 attempts, vein ≤16 blocks, Y 0-128
#   • Iron:    24 attempts, vein ≤8,         Y 0-64
#   • Gold:    2 attempts,  vein ≤8,         Y 0-32
#   • Diamond: 1 attempt,   vein ≤7,         Y 0-16
#
# Trees: ~1-2 oaks per chunk, placed on grass tiles ≥2 blocks from chunk
# borders so the 5×5 canopy never spills into a neighbor (avoids the cross-
# chunk decoration problem until we add a proper structure-start system).

const WORLD_SEED: int = 12345
# Alpha-canonical sea level. Surface terrain peaks ~SEA_LEVEL+amplitude,
# leaving ~60 blocks of stone below for caving/ore generation.
const SEA_LEVEL: int = 63
const HEIGHT_AMPLITUDE: int = 10
const NOISE_FREQUENCY: float = 0.018

# Probability of bedrock at each layer in the bottom band, in eighths.
# Y=0 is always bedrock; Y=1..3 fade out chaotically; Y>3 never bedrock.
const _BEDROCK_THRESHOLDS_EIGHTHS: Array = [8, 5, 3, 1]

# Ore generation parameters: [block_id, attempts_per_chunk, vein_size_max,
# y_min, y_max]. Order matters — coal first means it can be overwritten by
# iron later (at the rare overlap zones); fine in practice.
const _ORE_CONFIGS: Array = [
	[Blocks.COAL_ORE, 28, 16, 0, 128],
	[Blocks.IRON_ORE, 24, 8, 0, 64],
	[Blocks.GOLD_ORE, 2, 8, 0, 32],
	[Blocks.DIAMOND_ORE, 1, 7, 0, 16],
]

# Trees per chunk — we pick a deterministic count between MIN and MAX
# from the chunk's hash. ~1.5 average matches Alpha plains.
const _TREES_PER_CHUNK_MIN: int = 0
const _TREES_PER_CHUNK_MAX: int = 3
const _TREE_TRUNK_MIN: int = 4
const _TREE_TRUNK_MAX: int = 6

# Spawn safety: keep a small clearing around the player's initial world
# position (Main scene puts them at world (8, 100, 8)) so they don't drop
# from the sky into a leaf canopy or get trapped inside a trunk on load.
# Radius covers trunk + half a canopy.
const _SPAWN_X: int = 8
const _SPAWN_Z: int = 8
const _SPAWN_TREE_EXCLUSION_RADIUS: int = 4

static var _noise: FastNoiseLite
# Set by Game._ready() after the GDExtension loads. Fills the bedrock /
# stone / dirt / grass base layers in C++; ore + tree passes stay in
# GDScript. Parity with the GDScript fill is guaranteed by
# tests/test_worldgen_native.gd.
static var _native_worldgen: RefCounted


static func _get_noise() -> FastNoiseLite:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_noise.frequency = NOISE_FREQUENCY
		_noise.seed = WORLD_SEED
	return _noise


static func surface_height(world_x: int, world_z: int) -> int:
	var n: float = _get_noise().get_noise_2d(float(world_x), float(world_z))
	return SEA_LEVEL + int(round(n * float(HEIGHT_AMPLITUDE)))


# Main-thread init. No-op when the native extension isn't loaded.
static func enable_native() -> bool:
	if _native_worldgen != null:
		return true
	if not ClassDB.class_exists("WorldgenNative"):
		return false
	_native_worldgen = ClassDB.instantiate("WorldgenNative")
	return _native_worldgen != null


static func generate_chunk(chunk_x: int, chunk_z: int) -> Chunk:
	var probe_token := PerfProbe.begin("worldgen.generate_chunk")
	var chunk := Chunk.new()
	# 1. Heightmap + stratified base (bedrock / stone / dirt / grass).
	if _native_worldgen != null:
		_build_base_terrain_native(chunk, chunk_x, chunk_z)
	else:
		_build_base_terrain_gdscript(chunk, chunk_x, chunk_z)
	# 2. Ore veins — only replaces stone, never grass/dirt/bedrock.
	_scatter_ores(chunk, chunk_x, chunk_z)
	# 3. Trees — must come after surface placement so we know where grass is.
	_scatter_trees(chunk, chunk_x, chunk_z)
	chunk.dirty = true
	PerfProbe.end("worldgen.generate_chunk", probe_token)
	return chunk


# Pure-GDScript fill. Kept as the reference implementation; the native
# path must produce byte-identical chunk.blocks.
static func _build_base_terrain_gdscript(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			var world_x: int = chunk_x * Chunk.SIZE_X + x
			var world_z: int = chunk_z * Chunk.SIZE_Z + z
			var h: int = surface_height(world_x, world_z)
			for y in range(h + 1):
				chunk.set_block_unchecked(x, y, z, _block_at(world_x, y, world_z, h))


# Native fill. GDScript samples the heightmap (256 FastNoiseLite calls —
# already native), C++ does the ~17k per-block inner loop.
static func _build_base_terrain_native(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var heightmap := PackedInt32Array()
	heightmap.resize(Chunk.SIZE_X * Chunk.SIZE_Z)
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			var world_x: int = chunk_x * Chunk.SIZE_X + x
			var world_z: int = chunk_z * Chunk.SIZE_Z + z
			heightmap[z * Chunk.SIZE_X + x] = surface_height(world_x, world_z)
	var result: Dictionary = _native_worldgen.build_base_terrain(chunk_x, chunk_z, heightmap)
	chunk.blocks = result.blocks
	chunk.max_y = result.max_y


static func _block_at(world_x: int, y: int, world_z: int, surface_y: int) -> int:
	if y == 0:
		return Blocks.BEDROCK
	if y <= 3 and _is_bedrock_at(world_x, y, world_z):
		return Blocks.BEDROCK
	if y == surface_y:
		return Blocks.GRASS
	if y >= surface_y - 3:
		return Blocks.DIRT
	return Blocks.STONE


static func _is_bedrock_at(world_x: int, y: int, world_z: int) -> bool:
	if y < 1 or y > 3:
		return false
	var threshold: int = _BEDROCK_THRESHOLDS_EIGHTHS[y]
	return (_hash3(world_x, y, world_z) & 7) < threshold


# --- Ore veins ---


# Vanilla's WorldGenMinable shifts each vein's center by +8 on X/Z, so a chunk
# at (cx, cz)'s decoration pass writes its veins into the 2×2 square starting
# at (cx, cz) and extending NE. To collect the full ore set for our chunk, we
# also run the decoration passes for the 3 SW-adjacent chunks and clip every
# placement to our bounds. This mirrors vanilla's population-phase overlap
# without any cross-chunk side effects.
static func _scatter_ores(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.ores")
	for dcx in [-1, 0]:
		for dcz in [-1, 0]:
			_decorate_ores(chunk, chunk_x, chunk_z, chunk_x + dcx, chunk_z + dcz)
	PerfProbe.end("worldgen.ores", probe_token)


static func _decorate_ores(
	chunk: Chunk, chunk_x: int, chunk_z: int, deco_cx: int, deco_cz: int
) -> void:
	for cfg: Array in _ORE_CONFIGS:
		var ore_id: int = cfg[0]
		var attempts: int = cfg[1]
		var vein_size: int = cfg[2]
		var y_min: int = cfg[3]
		var y_max: int = cfg[4]
		# Clamp y band to valid range (never overwrite bedrock at y=0).
		var y_lo: int = maxi(y_min, 1)
		var y_hi: int = mini(y_max, Chunk.SIZE_Y - 1)
		if y_hi < y_lo:
			continue
		var span: int = y_hi - y_lo + 1
		# Each attempt gets a unique sub-hash via attempt index + ore id.
		for attempt in range(attempts):
			var seed_hash: int = _hash4(deco_cx, deco_cz, ore_id, attempt)
			var world_x: int = deco_cx * Chunk.SIZE_X + (seed_hash % Chunk.SIZE_X)
			var world_z: int = deco_cz * Chunk.SIZE_Z + ((seed_hash >> 8) % Chunk.SIZE_Z)
			var world_y: int = y_lo + ((seed_hash >> 16) % span)
			_place_vein_ellipsoid(
				chunk,
				chunk_x,
				chunk_z,
				world_x,
				world_y,
				world_z,
				ore_id,
				vein_size,
				seed_hash,
				y_lo,
				y_hi
			)


# Deterministic port of vanilla WorldGenMinable.generate (Bukkit/mc-dev).
# Traces a short line in world coordinates and, at b+1 samples along it,
# fills an ellipsoid of stone cells with ore. `chunk_(x|z)` are our target
# chunk; writes land only in that chunk's 16×128×16 slab.
static func _place_vein_ellipsoid(
	chunk: Chunk,
	chunk_x: int,
	chunk_z: int,
	i: int,
	j: int,
	k: int,
	ore_id: int,
	b: int,
	seed_hash: int,
	y_lo: int,
	y_hi: int
) -> void:
	var bf: float = float(b)
	var f: float = _float01(seed_hash, 1) * PI
	var d0: float = float(i + 8) + sin(f) * bf / 8.0
	var d1: float = float(i + 8) - sin(f) * bf / 8.0
	var d2: float = float(k + 8) + cos(f) * bf / 8.0
	var d3: float = float(k + 8) - cos(f) * bf / 8.0
	var d4: float = float(j + (_hash3(seed_hash, 2, ore_id) % 3) - 2)
	var d5: float = float(j + (_hash3(seed_hash, 3, ore_id) % 3) - 2)
	var chunk_origin_x: int = chunk_x * Chunk.SIZE_X
	var chunk_origin_z: int = chunk_z * Chunk.SIZE_Z
	for l in range(b + 1):
		var t: float = float(l) / bf
		var d6: float = d0 + (d1 - d0) * t
		var d7: float = d4 + (d5 - d4) * t
		var d8: float = d2 + (d3 - d2) * t
		var d9: float = _float01(seed_hash, l * 97 + 5) * bf / 16.0
		var radius: float = (sin(float(l) * PI / bf) + 1.0) * d9 + 1.0
		var half_r: float = radius / 2.0
		var min_x: int = floori(d6 - half_r)
		var min_y: int = floori(d7 - half_r)
		var min_z: int = floori(d8 - half_r)
		var max_x: int = floori(d6 + half_r)
		var max_y: int = floori(d7 + half_r)
		var max_z: int = floori(d8 + half_r)
		for bx in range(min_x, max_x + 1):
			var lx: int = bx - chunk_origin_x
			if lx < 0 or lx >= Chunk.SIZE_X:
				continue
			var nx: float = (float(bx) + 0.5 - d6) / half_r
			var nx2: float = nx * nx
			if nx2 >= 1.0:
				continue
			for by in range(min_y, max_y + 1):
				if by < y_lo or by > y_hi:
					continue
				var ny: float = (float(by) + 0.5 - d7) / half_r
				var nxy2: float = nx2 + ny * ny
				if nxy2 >= 1.0:
					continue
				for bz in range(min_z, max_z + 1):
					var lz: int = bz - chunk_origin_z
					if lz < 0 or lz >= Chunk.SIZE_Z:
						continue
					var nz: float = (float(bz) + 0.5 - d8) / half_r
					if nxy2 + nz * nz >= 1.0:
						continue
					if chunk.get_block_unchecked(lx, by, lz) != Blocks.STONE:
						continue
					chunk.set_block_unchecked(lx, by, lz, ore_id)


# Deterministic pseudo-random float in [0, 1) derived from (seed_hash, salt).
# Uses the low 24 bits of the derived hash — keeps full float precision.
static func _float01(seed_hash: int, salt: int) -> float:
	return float(_hash3(seed_hash, salt, 0x5E1D) & 0xFFFFFF) / 16777216.0


# --- Trees ---


static func _scatter_trees(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.trees")
	# Distinct salt so tree count doesn't collide with any tree's own hash.
	var count_hash: int = _hash4(chunk_x, chunk_z, 999983, 0)
	var span: int = _TREES_PER_CHUNK_MAX - _TREES_PER_CHUNK_MIN + 1
	var tree_count: int = _TREES_PER_CHUNK_MIN + (count_hash % span)
	# Keep tree centers away from chunk edges so the 5×5 canopy fits.
	var margin: int = 2
	var range_x: int = Chunk.SIZE_X - margin * 2
	var range_z: int = Chunk.SIZE_Z - margin * 2
	var trunk_range: int = _TREE_TRUNK_MAX - _TREE_TRUNK_MIN + 1
	for t in range(tree_count):
		# Three independent hashes per tree — sharing bit-slices of one hash
		# correlates x/z/trunk_height and produces visible grid artifacts.
		var hx: int = _hash4(chunk_x, chunk_z, t, 1)
		var hz: int = _hash4(chunk_x, chunk_z, t, 2)
		var hh: int = _hash4(chunk_x, chunk_z, t, 3)
		var lx: int = margin + (hx % range_x)
		var lz: int = margin + (hz % range_z)
		var world_x: int = chunk_x * Chunk.SIZE_X + lx
		var world_z: int = chunk_z * Chunk.SIZE_Z + lz
		# Skip any tree whose trunk would fall inside the spawn clearing.
		var dx_spawn: int = world_x - _SPAWN_X
		var dz_spawn: int = world_z - _SPAWN_Z
		if (
			dx_spawn * dx_spawn + dz_spawn * dz_spawn
			<= (_SPAWN_TREE_EXCLUSION_RADIUS * _SPAWN_TREE_EXCLUSION_RADIUS)
		):
			continue
		var ground_y: int = surface_height(world_x, world_z)
		# Only plant on grass; surface might be sand/water/etc. in future.
		if chunk.get_block_unchecked(lx, ground_y, lz) != Blocks.GRASS:
			continue
		var trunk_height: int = _TREE_TRUNK_MIN + (hh % trunk_range)
		# Pass a combined hash to _place_oak for canopy-corner randomization.
		var t_hash: int = _hash4(chunk_x, chunk_z, t, 4)
		_place_oak(chunk, lx, ground_y + 1, lz, trunk_height, t_hash)
	PerfProbe.end("worldgen.trees", probe_token)


# Beta-faithful oak (matches WorldGenTrees from mc-dev / Bukkit). The
# 4-layer canopy WRAPS around the top of the trunk instead of stacking
# above it. Vanilla loop:
#   for i1 = j+l-3 to j+l:                  # 4 layers, k2 = -3..0 from j+l
#     l1 = 1 - k2 / 2                        # widths: 2, 2, 1, 1 (radius)
#     for dx,dz in -l1..l1:
#       skip if corner AND (random || k2==0)
#
# Translated:
#   trunk_top - 2  (5×5, randomize corners)
#   trunk_top - 1  (5×5, randomize corners)
#   trunk_top      (3×3, always trim corners — overlaps trunk top block)
#   trunk_top + 1  (3×3, always trim corners — single block ABOVE trunk)
static func _place_oak(
	chunk: Chunk, base_x: int, base_y: int, base_z: int, trunk_height: int, t_hash: int
) -> void:
	# Trunk — base_x/base_z are in [margin, SIZE_X-1-margin], base_y ≥ 1,
	# so unchecked is safe once we've verified ty < SIZE_Y.
	for i in range(trunk_height):
		var ty: int = base_y + i
		if ty >= Chunk.SIZE_Y:
			return
		chunk.set_block_unchecked(base_x, ty, base_z, Blocks.LOG)
	var trunk_top: int = base_y + trunk_height - 1
	# Canopy layers: [y_offset_from_trunk_top, half_width, randomize_corners]
	var layers: Array = [
		[-2, 2, true],
		[-1, 2, true],
		[0, 1, false],
		[1, 1, false],
	]
	for layer_idx in range(layers.size()):
		var cfg: Array = layers[layer_idx]
		var dy: int = cfg[0]
		var hw: int = cfg[1]
		var randomize: bool = cfg[2]
		var ly: int = trunk_top + dy
		if ly < 0 or ly >= Chunk.SIZE_Y:
			continue
		for dx in range(-hw, hw + 1):
			for dz in range(-hw, hw + 1):
				var is_corner: bool = absi(dx) == hw and absi(dz) == hw
				if is_corner:
					if not randomize:
						continue  # 3×3 layers always trim corners
					# 50% deterministic chance to keep this corner leaf.
					if (_hash4(t_hash, layer_idx, dx, dz) & 1) == 0:
						continue
				_place_leaf_if_air(chunk, base_x + dx, ly, base_z + dz)


static func _place_leaf_if_air(chunk: Chunk, x: int, y: int, z: int) -> void:
	if x < 0 or x >= Chunk.SIZE_X or z < 0 or z >= Chunk.SIZE_Z:
		return  # canopy spills past chunk border — drop those blocks
	if y < 0 or y >= Chunk.SIZE_Y:
		return
	# Bounds already checked above; use unchecked accessors.
	if chunk.get_block_unchecked(x, y, z) == Blocks.AIR:
		chunk.set_block_unchecked(x, y, z, Blocks.LEAVES)


# --- Hashing ---


# Cheap deterministic hash per (x, y, z, seed). Three large primes + XOR
# scramble — random-enough for visual chaos, no allocations.
static func _hash3(x: int, y: int, z: int) -> int:
	var h: int = WORLD_SEED
	h = (h * 73856093) ^ x
	h = (h * 19349663) ^ y
	h = (h * 83492791) ^ z
	return absi(h)


# 4-arg hash for ore veins (need to vary by attempt index too).
static func _hash4(a: int, b: int, c: int, d: int) -> int:
	var h: int = WORLD_SEED
	h = (h * 73856093) ^ a
	h = (h * 19349663) ^ b
	h = (h * 83492791) ^ c
	h = (h * 49979693) ^ d
	return absi(h)
