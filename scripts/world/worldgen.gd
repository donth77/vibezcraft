class_name Worldgen
extends RefCounted

# Phase 5 worldgen: 2D Perlin heightmap + stratified layering, plus
# ore veins and oak trees. Generation is deterministic per (seed, x, z)
# — the same chunk coords always produce the same blocks.
#
# Ore veins follow vanilla WorldGenMinable (ellipsoid-along-line fill,
# Bukkit/mc-dev). Vein sizes + Y bands match Beta 1.7-era (close to
# Alpha 1.2.6 — the era we're cloning). Per chunk, tuned to land in
# [100%, 140%] of vanilla Alpha's empirical numbers (coal ~111, iron ~77,
# gold ~8.5, diamond ~3.5) after the _HASH_MIX fix in _hash4:
#   • Coal:    14 attempts, vein ≤16 blocks, Y 0-128
#   • Iron:    18 attempts, vein ≤8,         Y 0-64
#   • Gold:    2 attempts,  vein ≤8,         Y 0-32
#   • Diamond: 1 attempt,   vein ≤7,         Y 0-16
#
# Trees: ~1-2 oaks per chunk, placed on grass tiles ≥2 blocks from chunk
# borders so the 5×5 canopy never spills into a neighbor (avoids the cross-
# chunk decoration problem until we add a proper structure-start system).

# Alpha 1.2.6 sea level = 64 (vendor/alpha-1.2.6-src/src/px.java:103,
# `int n4 = 64`). Surface terrain peaks ~SEA_LEVEL+amplitude, leaving
# ~60 blocks of stone below for caving/ore generation.
const SEA_LEVEL: int = 64
# Mountains (phase 6c): peak amplitude per octave. With FBM and gain=0.5
# the practical max rise over 4 octaves is ~1.875× this value, so
# HEIGHT_AMPLITUDE=22 yields a working range of roughly SEA_LEVEL ± 41
# (y≈22..104) — close to Beta-era vanilla's 55..100 surface range. Earlier
# single-octave value (10) produced flat-with-dips terrain; the FBM stack
# adds the iconic rolling hills and occasional tall peaks.
const HEIGHT_AMPLITUDE: int = 22
const NOISE_FREQUENCY: float = 0.018
# FBM stack. Vanilla Alpha's ChunkProviderGenerate instantiates several
# NoiseGeneratorOctaves (Bukkit/mc-dev `ChunkProviderGenerate.java:40-46`):
#   j, k = new NoiseGeneratorOctaves(rand, 16)    // main density, 16 octaves
#   l    = new NoiseGeneratorOctaves(rand, 8)     // biome/terrain selector
#   a    = new NoiseGeneratorOctaves(rand, 10)
# Vanilla stacks octaves with freq doubling and amplitude halving, feeding
# a 3D density field that's thresholded for the surface — a much richer
# shape than our 2D heightmap. We use the same FBM building block but only
# 4 octaves since a 2D heightmap doesn't benefit from vanilla's deeper
# stack (octaves beyond ~4 produce sub-block detail that gets floor()'d
# away when converted to integer cell heights). Lacunarity 2.0 / gain 0.5
# are FastNoiseLite defaults and match vanilla's per-octave scaling.
const NOISE_OCTAVES: int = 4
const NOISE_LACUNARITY: float = 2.0
const NOISE_GAIN: float = 0.5

# Vanilla Alpha beach band — columns whose surface peaks between (SEA_LEVEL
# - BEACH_DEPTH_BELOW) and (SEA_LEVEL + BEACH_HEIGHT_ABOVE) get their top
# BEACH_SAND_DEPTH cells of grass/dirt replaced with sand. This produces a
# visible sandy ring at the waterline — dry beach just above, submerged
# shelf just below. Outside this band, hills keep grass and deep ocean
# floors keep dirt (lake beds remain gray-brown, not bleached sand).
#
# Band bounds mirror BiomeBase.b() in Bukkit/mc-dev:
#   `if (l1 >= 59 && l1 <= 64) { block = this.ai; ... }`
# which is SEA_LEVEL-4 .. SEA_LEVEL+1 with SEA_LEVEL=63. Any adjacent
# grass/sand flicker at the y=64 edge is an artifact of 2D noise variance
# rather than a bug — vanilla has the same behavior when the heightmap
# is noisy at the band edge.
const BEACH_DEPTH_BELOW: int = 4
const BEACH_HEIGHT_ABOVE: int = 1
const BEACH_SAND_DEPTH: int = 4

# Bedrock placement — Alpha 1.2.6 px.java:119 scans columns top-down and
# writes bedrock where `i4 <= 0 + this.j.nextInt(5)` (with i4 = current y).
# Per-layer probability: y=0 always, y=1 → 4/5, y=2 → 3/5, y=3 → 2/5,
# y=4 → 1/5. Y>4 never bedrock. We convert to a deterministic
# per-(x,y,z) hash mod 5 check so chunk reload reproduces the same band.
const _BEDROCK_THRESHOLDS_FIFTHS: Array = [5, 4, 3, 2, 1]

# Ore generation parameters: [block_id, attempts_per_chunk, vein_size_max,
# y_min, y_max]. Counts, sizes, and Y-bands are copied verbatim from Alpha
# 1.2.6's populate pass (vendor/alpha-1.2.6-src/src/px.java:300-346):
#   dirt       → `new df(nq.v.bh, 32)` ×20 — px.java:306
#   gravel     → `new df(nq.F.bh, 32)` ×10 — px.java:312
#   coal ore   → `new df(nq.I.bh, 16)` ×20 — px.java:318
#   iron ore   → `new df(nq.H.bh, 8)` ×20, y<64 — px.java:324
#   gold ore   → `new df(nq.G.bh, 8)` ×2, y<32 — px.java:330
#   redstone   → `new df(nq.aN.bh, 7)` ×8, y<16 — px.java:336 (SKIPPED:
#                 we don't have redstone as a block yet)
#   diamond    → `new df(nq.aw.bh, 7)` ×1, y<16 — px.java:342
# Order here is identical to Alpha's decorator sequence so cells where
# veins overlap resolve the same way as vanilla.
const _ORE_CONFIGS: Array = [
	[Blocks.DIRT, 20, 32, 0, 128],
	[Blocks.GRAVEL, 10, 32, 0, 128],
	[Blocks.COAL_ORE, 20, 16, 0, 128],
	[Blocks.IRON_ORE, 20, 8, 0, 64],
	[Blocks.GOLD_ORE, 2, 8, 0, 32],
	[Blocks.DIAMOND_ORE, 1, 7, 0, 16],
]

# Sibling generator modules. Loaded via preload() because using `class_name`
# on worldgen_caves.gd would create a circular dependency with Worldgen
# (the caves module references Worldgen._hash4 / surface_height).
const _CAVES_SCRIPT: GDScript = preload("res://scripts/world/worldgen_caves.gd")

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

# Final Knuth multiplicative mix applied inside _hash3 / _hash4 so low-bit
# differences in the last argument avalanche into high bits. Without this,
# callers that vary only one hash argument (like the 28-attempts-per-pass
# ore-vein loop) produce (hash >> 16) values that are constant across
# iterations, causing entire passes to deposit zero ore.
const _HASH_MIX: int = 2654435761

static var _noise: FastNoiseLite
# Set by Game._ready() after the GDExtension loads. Fills the bedrock /
# stone / dirt / grass base layers in C++; ore + tree passes stay in
# GDScript. Parity with the GDScript fill is guaranteed by
# tests/test_worldgen_native.gd.
static var _native_worldgen: RefCounted

# Global seed driving every deterministic worldgen hash. Mutable static
# so the main-menu "World seed" setting can rewrite it before Game._ready
# warms the noise generator. Default kept at 12345 for back-compat with
# tests / saves predating the configurable-seed feature; Game._ready
# overrides this from user://settings.cfg [world] seed before any
# generate_chunk call. C++ WorldgenNative has its own mirrored
# `world_seed` static — both must be set together via apply_world_seed().
# Uppercase name preserved (despite being a var) because every reader —
# tests, worldgen_caves, CLAUDE.md docs — already calls it WORLD_SEED.
# gdlint:ignore=class-variable-name
static var WORLD_SEED: int = 12345


static func _get_noise() -> FastNoiseLite:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_noise.frequency = NOISE_FREQUENCY
		_noise.seed = WORLD_SEED
		# FBM stack — mirrors vanilla NoiseGeneratorOctaves.generateNoise()
		# summing octaves with freq*=lacunarity and amp*=gain per step.
		_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_noise.fractal_octaves = NOISE_OCTAVES
		_noise.fractal_lacunarity = NOISE_LACUNARITY
		_noise.fractal_gain = NOISE_GAIN
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
	# Push the current GDScript-side seed into the native singleton on first
	# init so its hash3/hash4 match GDScript even if Game._ready wired the
	# seed before the extension was instantiated. set_world_seed is bound
	# as a class-level static method, so call it via ClassDB.class_call_static
	# (Engine has no direct StaticMethodCall syntax — this routes through
	# the class registry the same way ClassDB.instantiate above does).
	if _native_worldgen != null:
		_call_native_set_seed(WORLD_SEED)
	return _native_worldgen != null


# Wrap the static-method dispatch so the two callsites (enable_native +
# apply_world_seed) share one place to fix if godot-cpp's static-bind API
# changes. Uses Object.call on the singleton instance — godot-cpp routes
# instance .call() through to the registered static method when there's
# a matching name. This works because bind_static_method registers the
# method under the class, and instance .call() falls back to class-level
# methods after instance lookup.
static func _call_native_set_seed(seed: int) -> void:
	if _native_worldgen == null:
		return
	_native_worldgen.call("set_world_seed", seed)


# Set the global worldgen seed and propagate to the C++ extension. Call
# BEFORE the first generate_chunk / surface_height call — clears the
# cached FastNoiseLite so the next call rebuilds with the new seed.
# Caves + ores read Worldgen.WORLD_SEED on each call so they pick up the
# new value automatically (no warm cache to invalidate).
static func apply_world_seed(seed: int) -> void:
	WORLD_SEED = seed
	# Drop the cached noise so _get_noise() rebuilds with the new seed on
	# the next call. Without this, surface_height(0,0) would keep using
	# the seed the noise was first built with.
	_noise = null
	_call_native_set_seed(seed)


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
	# 2b. Caves — Alpha's MapGenCaves (lx.java). Random-walk worm tunnels
	#    carve STONE/DIRT/GRASS → AIR. Runs AFTER ores so veins get
	#    opened up by caves (mining loop); BEFORE beaches so the sand
	#    pass sees cave-affected surface cells. Radius 8 chunks — see
	#    scripts/world/worldgen_caves.gd for full port notes.
	#
	# Native fast path: WorldgenNative.scatter_caves runs the same
	# algorithm (bit-exact JavaRandom stream) in C++, ~10× faster than
	# the GDScript reference. Parity is enforced by tests/test_cave_parity.gd
	# across 4 sample coords; an earlier divergence (2026-04-24 repro at
	# cx=-5) appears resolved as of this commit. If parity regresses,
	# fall back here to `_CAVES_SCRIPT.scatter` and chase the C++ side.
	# Native fast path: WorldgenNative.scatter_caves runs the same
	# algorithm (bit-exact JavaRandom) in C++. Cave-blocks parity is
	# enforced by tests/test_cave_parity. Native only mutates the blocks
	# array; the GDScript reference goes through Chunk.set_block_unchecked
	# which ALSO updates block_meta (zero on carved cells), the sticky
	# has_water_cells / has_non_cube_blocks flags, and the height_map.
	# After the native call we replicate those side-effects in
	# `_post_process_native_caves` so chunk state is byte-equivalent to
	# the GDScript path — required for tests/test_mesher_native parity.
	if _native_worldgen != null:
		var caves_token := PerfProbe.begin("worldgen.caves")
		chunk.blocks = _native_worldgen.call("scatter_caves", chunk_x, chunk_z, chunk.blocks)
		_post_process_native_caves(chunk)
		PerfProbe.end("worldgen.caves", caves_token)
	else:
		_CAVES_SCRIPT.scatter(chunk, chunk_x, chunk_z)
	# 3. Beaches — replaces surface grass/dirt near sea level with sand
	#    (vanilla Alpha's ChunkProviderGenerate.replaceBlocksForBiome). Must
	#    run after ores (ores only replace stone, so ordering is neutral
	#    there) and before trees (so the grass-check gate drops columns
	#    that were just sanded over).
	_place_beaches(chunk, chunk_x, chunk_z)
	# 4. Ocean fill — writes WATER_STILL into the gap between surface and
	#    SEA_LEVEL wherever the column peaks below the sea. Runs AFTER
	#    beaches (water doesn't care what the floor is, and beaches need
	#    the original grass/dirt surface to decide whether to replace) and
	#    BEFORE trees (so the tree pass can gate on "dry land"). Matches
	#    vanilla Alpha's ChunkProviderGenerate sequencing: base strata →
	#    ore veins → biome replace → water pass → decorators.
	_fill_ocean(chunk, chunk_x, chunk_z)
	# 5. Trees — must come after surface placement so we know where grass is.
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
	# Alpha's nextInt(5) band extends to y=4 inclusive (px.java:119).
	if y <= 4 and _is_bedrock_at(world_x, y, world_z):
		return Blocks.BEDROCK
	if y == surface_y:
		# Vanilla BiomeBase.b() applies the biome's surface block (`this.ai`).
		# BiomeOcean overrides ai = DIRT, BiomePlains uses GRASS. Without
		# biomes, columns that peak below the beach band are "ocean floor"
		# and should use DIRT — grass underwater reads as a bug. Beaches
		# handle the SEA_LEVEL ± beach-band substitution separately.
		if surface_y < SEA_LEVEL - BEACH_DEPTH_BELOW:
			return Blocks.DIRT
		return Blocks.GRASS
	if y >= surface_y - 3:
		return Blocks.DIRT
	return Blocks.STONE


static func _is_bedrock_at(world_x: int, y: int, world_z: int) -> bool:
	if y < 1 or y > 4:
		return false
	var threshold: int = _BEDROCK_THRESHOLDS_FIFTHS[y]
	return (_hash3(world_x, y, world_z) % 5) < threshold


# --- Beaches ---


static func _place_beaches(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.beaches")
	var lo: int = SEA_LEVEL - BEACH_DEPTH_BELOW
	var hi: int = SEA_LEVEL + BEACH_HEIGHT_ABOVE
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			var world_x: int = chunk_x * Chunk.SIZE_X + x
			var world_z: int = chunk_z * Chunk.SIZE_Z + z
			var surface_y: int = surface_height(world_x, world_z)
			# Outside the beach band: hills + deep oceans untouched.
			if surface_y < lo or surface_y > hi:
				continue
			# Replace the top BEACH_SAND_DEPTH grass/dirt cells with sand.
			# Stops at a non-grass/dirt cell (ore, bedrock, existing sand)
			# so we don't scrub through embedded stone veins near the coast.
			for dy in range(BEACH_SAND_DEPTH):
				var y: int = surface_y - dy
				if y <= 0:
					break
				var existing: int = chunk.get_block_unchecked(x, y, z)
				if existing != Blocks.GRASS and existing != Blocks.DIRT:
					break
				chunk.set_block_unchecked(x, y, z, Blocks.SAND)
	PerfProbe.end("worldgen.beaches", probe_token)


# --- Ocean fill ---


# For every column, fill AIR cells between the surface and SEA_LEVEL with
# WATER_STILL. Deterministic — no RNG, so parity tests stay green even when
# the rest of the pipeline changes. Runs in GDScript on top of the native
# base-terrain fill; at 16×16 columns × ~10 cells each that's ~2.5k writes
# per chunk, cheap compared to the ore pass.
static func _fill_ocean(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.ocean")
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			var world_x: int = chunk_x * Chunk.SIZE_X + x
			var world_z: int = chunk_z * Chunk.SIZE_Z + z
			var surface_y: int = surface_height(world_x, world_z)
			# Dry land: surface pokes at or above the sea. Nothing to fill.
			if surface_y >= SEA_LEVEL:
				continue
			# Fill (surface_y, SEA_LEVEL] with water. Only overwrite AIR so
			# we don't clobber surface grass or any block an earlier pass
			# may have written above the heightmap in the future.
			for y in range(surface_y + 1, SEA_LEVEL + 1):
				if chunk.get_block_unchecked(x, y, z) == Blocks.AIR:
					chunk.set_block_unchecked(x, y, z, Blocks.WATER_STILL)
	# Ocean columns now peak at SEA_LEVEL. max_y is monotonic — respect
	# the invariant from CLAUDE.md (never decrease), but bump up if water
	# pushed the column past the previous max.
	if SEA_LEVEL > chunk.max_y:
		chunk.max_y = SEA_LEVEL
	PerfProbe.end("worldgen.ocean", probe_token)


# --- Ore veins ---


# Vanilla's WorldGenMinable shifts each vein's center by +8 on X/Z, so a chunk
# at (cx, cz)'s decoration pass writes its veins into the 2×2 square starting
# at (cx, cz) and extending NE. To collect the full ore set for our chunk, we
# also run the decoration passes for the 3 SW-adjacent chunks and clip every
# placement to our bounds. This mirrors vanilla's population-phase overlap
# without any cross-chunk side effects.
#
# Dispatcher: native WorldgenNative.scatter_ores when the GDExtension is
# loaded, else the GDScript fallback. Parity with the GDScript pass is
# enforced by tests/test_worldgen_native.gd — chunk.blocks must be byte-equal
# after either path.
static func _scatter_ores(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.ores")
	if _native_worldgen != null:
		_scatter_ores_native(chunk, chunk_x, chunk_z)
	else:
		_scatter_ores_gdscript(chunk, chunk_x, chunk_z)
	PerfProbe.end("worldgen.ores", probe_token)


# Pure-GDScript reference implementation. Kept so the native path has a
# ground truth to diff against in test_worldgen_native.gd.
static func _scatter_ores_gdscript(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	for dcx in [-1, 0]:
		for dcz in [-1, 0]:
			_decorate_ores(chunk, chunk_x, chunk_z, chunk_x + dcx, chunk_z + dcz)


# Flattens _ORE_CONFIGS into a PackedInt32Array so the knobs stay in
# GDScript (no rebuild needed to retune), then hands chunk.blocks off to
# C++. The native path runs the same 4-decoration-pass overlap and writes
# ore only on existing STONE cells, so the result is byte-identical.
static func _scatter_ores_native(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var flat := PackedInt32Array()
	flat.resize(_ORE_CONFIGS.size() * 5)
	for i in range(_ORE_CONFIGS.size()):
		var cfg: Array = _ORE_CONFIGS[i]
		flat[i * 5] = cfg[0]
		flat[i * 5 + 1] = cfg[1]
		flat[i * 5 + 2] = cfg[2]
		flat[i * 5 + 3] = cfg[3]
		flat[i * 5 + 4] = cfg[4]
	chunk.blocks = _native_worldgen.scatter_ores(chunk_x, chunk_z, chunk.blocks, flat)


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
	# Alpha df.java:22-23:
	#   double d6 = n3 + random.nextInt(3) + 2;    // y + 2..4
	#   double d7 = n3 + random.nextInt(3) + 2;
	# Both line-endpoints start 2-4 blocks ABOVE the seed y, so veins
	# extend upward into the rock column. Earlier version of this file
	# had `- 2` instead of `+ 2`, mirroring the number below the seed —
	# confirmed against vendor/alpha-1.2.6-src/src/df.java (verbatim).
	var d4: float = float(j + (_hash3(seed_hash, 2, ore_id) % 3) + 2)
	var d5: float = float(j + (_hash3(seed_hash, 3, ore_id) % 3) + 2)
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
		# No trees underwater — a submerged grass cell still reads as GRASS
		# after the ocean fill pass, but growing a canopy up through water
		# is vanilla-wrong (Alpha's BiomeDecorator gates trees on the surface
		# being at or above sea level).
		if ground_y < SEA_LEVEL:
			continue
		# Only plant on grass; surface might be sand/water/etc. in future.
		if chunk.get_block_unchecked(lx, ground_y, lz) != Blocks.GRASS:
			continue
		var trunk_height: int = _TREE_TRUNK_MIN + (hh % trunk_range)
		# Pass a combined hash to _place_oak for canopy-corner randomization.
		var t_hash: int = _hash4(chunk_x, chunk_z, t, 4)
		_place_oak(chunk, lx, ground_y + 1, lz, trunk_height, t_hash)
	PerfProbe.end("worldgen.trees", probe_token)


# Beta-faithful oak (matches WorldGenTrees from mc-dev / Bukkit). The
# 4-layer canopy WRAPS around the top of the trunk. Vanilla loop:
#   for i1 = j+l-3 to j+l:                  # 4 layers, k2 = -3..0 from j+l
#     l1 = 1 - k2 / 2                       # radii: 2, 2, 1, 1
#     for dx,dz in -l1..l1:
#       place unless (abs(dx)==l1 AND abs(dz)==l1 AND (rand(2)==0 OR k2==0))
#
# Mapped to our dy offsets from trunk_top (= base_y + trunk_height - 1):
#   dy = -2 (vanilla k2 = -3): radius 2, 50% corners
#   dy = -1 (vanilla k2 = -2): radius 2, 50% corners
#   dy =  0 (vanilla k2 = -1): radius 1, 50% corners
#   dy = +1 (vanilla k2 =  0): radius 1, corners always trimmed
#
# Generic over the world: takes Callables for read/write so the same
# routine serves worldgen (writes into the in-progress chunk) AND
# runtime sapling growth (writes via ChunkManager.set_world_block,
# crossing chunk boundaries). The set callback is responsible for clipping
# OOB writes (worldgen drops cross-chunk canopy spillover; growth path
# routes to the right chunk). base_pos is the cell where the trunk
# *starts* (i.e. directly above the support block).
static func place_oak_tree(
	base_pos: Vector3i,
	trunk_height: int,
	t_hash: int,
	get_block_cb: Callable,
	set_block_cb: Callable
) -> void:
	for i in range(trunk_height):
		var ty: int = base_pos.y + i
		if ty >= Chunk.SIZE_Y:
			return
		set_block_cb.call(Vector3i(base_pos.x, ty, base_pos.z), Blocks.LOG)
	var trunk_top: int = base_pos.y + trunk_height - 1
	# Canopy layers: [y_offset_from_trunk_top, half_width, randomize_corners]
	var layers: Array = [
		[-2, 2, true],
		[-1, 2, true],
		[0, 1, true],
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
				var lp := Vector3i(base_pos.x + dx, ly, base_pos.z + dz)
				if get_block_cb.call(lp) == Blocks.AIR:
					set_block_cb.call(lp, Blocks.LEAVES)


# Worldgen wrapper — writes into a single chunk via the unchecked
# accessors, dropping any canopy spillover that lands outside this
# chunk's (x,z) footprint. base_x/z are chunk-local; everything inside
# place_oak_tree treats them as world coords, but the closures translate
# back. Net result: byte-identical to the previous _place_oak.
static func _place_oak(
	chunk: Chunk, base_x: int, base_y: int, base_z: int, trunk_height: int, t_hash: int
) -> void:
	var get_local := func(p: Vector3i) -> int:
		if p.x < 0 or p.x >= Chunk.SIZE_X or p.z < 0 or p.z >= Chunk.SIZE_Z:
			return Blocks.AIR  # OOB reads as AIR — same effect as the old early-return
		if p.y < 0 or p.y >= Chunk.SIZE_Y:
			return Blocks.AIR
		return chunk.get_block_unchecked(p.x, p.y, p.z)
	var set_local := func(p: Vector3i, id: int) -> void:
		if p.x < 0 or p.x >= Chunk.SIZE_X or p.z < 0 or p.z >= Chunk.SIZE_Z:
			return  # canopy spillover dropped (same as old _place_leaf_if_air guard)
		if p.y < 0 or p.y >= Chunk.SIZE_Y:
			return
		chunk.set_block_unchecked(p.x, p.y, p.z, id)
	place_oak_tree(Vector3i(base_x, base_y, base_z), trunk_height, t_hash, get_local, set_local)


# --- Hashing ---


# Cheap deterministic hash per (x, y, z, seed). Three large primes + XOR
# scramble, then a final Knuth multiplicative mix (see _HASH_MIX note near
# the top of the file) so low-bit differences in the last argument
# avalanche up to the high bits.
# Replicate Chunk.set_block_unchecked's chunk-state side-effects for the
# native scatter_caves fast path. Native only writes the blocks array;
# this scan brings block_meta + has_water_cells + has_non_cube_blocks +
# height-map dirtiness back in sync with what the GDScript scatter would
# have produced via per-cell set_block_unchecked. Cost: one linear pass
# over CHUNK_VOLUME (~32K bytes) — still < 1 ms in GDScript.
#
# Why this matters: tests/test_mesher_native parity relies on byte-equal
# chunk state between native and GDScript paths. Skipping this leaves
# stale flags that change mesher dispatch and emit different face counts.
static func _post_process_native_caves(chunk: Chunk) -> void:
	var blocks := chunk.blocks
	var meta := chunk.block_meta
	var saw_non_cube: bool = chunk.has_non_cube_blocks
	var saw_water: bool = chunk.has_water_cells
	for i in range(Chunk.TOTAL_BLOCKS):
		var b: int = blocks[i]
		# Cave cells are AIR (above y=10) or LAVA_STILL (below y=10) — both
		# carry meta=0. Zero meta on the carved cells; non-carved cells
		# (still STONE/DIRT/etc.) already had meta=0 from base terrain so
		# the unconditional write is a no-op for them.
		meta[i] = 0
		if not saw_non_cube and Blocks.needs_gdscript_mesher(b):
			saw_non_cube = true
		if not saw_water and Blocks.is_water(b):
			saw_water = true
	chunk.block_meta = meta
	chunk.has_non_cube_blocks = saw_non_cube
	chunk.has_water_cells = saw_water
	# Heightmap: cave-AIR at non-topmost cells doesn't change the column's
	# topmost-opaque, but cave-AIR at the topmost-opaque (rare — caves
	# breaking through to surface) DOES. Flag dirty so the next
	# is_sky_exposed lookup rebuilds from raw blocks. Cheaper than scanning
	# every column here.
	chunk._height_map_dirty = true


static func _hash3(x: int, y: int, z: int) -> int:
	var h: int = WORLD_SEED
	h = (h * 73856093) ^ x
	h = (h * 19349663) ^ y
	h = (h * 83492791) ^ z
	h = h * _HASH_MIX
	return absi(h)


# 4-arg hash for ore veins (need to vary by attempt index too).
static func _hash4(a: int, b: int, c: int, d: int) -> int:
	var h: int = WORLD_SEED
	h = (h * 73856093) ^ a
	h = (h * 19349663) ^ b
	h = (h * 83492791) ^ c
	h = (h * 49979693) ^ d
	h = h * _HASH_MIX
	return absi(h)
