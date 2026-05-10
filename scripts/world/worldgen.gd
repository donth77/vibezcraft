# gdlint: disable=max-file-lines
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

# --- Terrain mode toggle (slice 3-B) ---
# Toggles between the 2D-heightmap path (continental + detail noise →
# single Y per column → bedrock/stone/dirt/grass layering) and the 3D
# density path (vanilla-faithful: noise + Y-bias → per-cell stone/air →
# surface conversion).
#
# Keep MODE_2D_HEIGHTMAP as the default while 3D density bakes in. Flip
# to MODE_3D_DENSITY at runtime via `Worldgen.terrain_mode = ...` to
# A/B test in-game; chunks generated under different modes look
# obviously different at the seam (vertical cliff at the boundary), so
# don't toggle mid-session unless you want to see that.
enum TerrainMode { MODE_2D_HEIGHTMAP, MODE_3D_DENSITY }

# Alpha 1.2.6 sea level = 64 (vendor/alpha-1.2.6-src/src/px.java:103,
# `int n4 = 64`). Surface terrain peaks ~SEA_LEVEL+amplitude, leaving
# ~60 blocks of stone below for caving/ore generation.
const SEA_LEVEL: int = 64
# Continental + detail noise stack (slice 2 of the worldgen reshape —
# see `.claude/worldgen-deferred.md` for context). The 2D heightmap
# combines two noise samples per (x, z):
#
#   1. Continental noise: low-freq (~333 block wavelength = ~21 chunks),
#      2 octaves, amplitude ±CONTINENTAL_AMPLITUDE. Shifts the BASELINE
#      per region — positive in "land regions", negative in "ocean
#      regions". With this layer dominating, the surface only crosses
#      sea level at the boundaries between land/ocean regions instead
#      of every ~30-50 blocks (the symptom of the islandy/excessive-
#      beaches feel — see `worldgen-deferred.md` for the analysis).
#
#   2. Detail noise: higher freq (~83 block wavelength = ~5 chunks),
#      4-octave FBM, amplitude ±DETAIL_AMPLITUDE. Local variation that
#      rides on top of the continental baseline.
#
# Plus a BASELINE_BIAS of +4 that shifts the overall mean above sea
# level, so most of the world is land (vanilla's 3D density field has
# the same effect via Y-bias in the threshold).
#
# Practical range: SEA_LEVEL + BASELINE_BIAS ± (CONTINENTAL_AMPLITUDE +
# DETAIL_AMPLITUDE) = 64 + 4 ± 24 = [44, 92]. Most of the world clusters
# around y=68 (continental ≈ 0); ocean basins where continental is
# strongly negative; mountain peaks where both noises align positive.
const CONTINENTAL_FREQUENCY: float = 0.003
const CONTINENTAL_AMPLITUDE: int = 40  # deep oceans (down to y~30) + tall hills (~95)
const CONTINENTAL_OCTAVES: int = 2
const NOISE_FREQUENCY: float = 0.018  # pre-3D value (commit 20739fc)
const DETAIL_AMPLITUDE: int = 8
# Loose upper bound for `test_surface_height_in_expected_range`. Equal to
# CONTINENTAL_AMPLITUDE + DETAIL_AMPLITUDE + abs(BASELINE_BIAS) = 28, so
# the range check covers the worst-case excursion in either direction.
const HEIGHT_AMPLITUDE: int = 22  # pre-3D value (commit 20739fc)
# Vertical offset added to every column. Positive bias lifts the world
# mean above SEA_LEVEL, so most land is above water without forcing a
# specific noise distribution. Tweakable; +4 keeps the mean at y=68
# while still allowing ocean basins to dip to y~44.
const BASELINE_BIAS: int = 0  # mean at sea level → ~50/50 land/ocean — vanilla Alpha shape
# FBM stack for the detail noise (continental noise has its own setup
# in `_get_continental_noise`). Vanilla Alpha's ChunkProviderGenerate
# instantiates several NoiseGeneratorOctaves (Bukkit/mc-dev
# `ChunkProviderGenerate.java:40-46`) feeding a 3D density field; we
# emulate the LARGE-FEATURE-DOMINATES outcome via the continental layer
# above rather than vanilla's reverse-FBM. Standard FBM (gain 0.5) is
# fine for the detail layer since the continental layer carries the
# big-feature shape.
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
# Vanilla band: BiomeBase.b() uses `if (l1 >= 59 && l1 <= 64)` (with
# SEA_LEVEL=63), which is 6 cells wide. With our SEA_LEVEL=64 the
# equivalent is y∈[60, 65]. With the corrected vanilla *12 Y-bias the
# surface clusters tightly to target_y; few columns land in the narrow
# vanilla band, producing 1-cell beach strips. We widen to 9 cells
# (y∈[58, 67]) — covers the same physical "near-shoreline" zone while
# accounting for the symmetric elevation modulator pushing fewer columns
# into the vanilla band than vanilla's asymmetric d4 modifier does.
# Pre-3D values (used by 2D heightmap mode beach pass). Vanilla
# Alpha BiomeBase.b() band: y∈[59, 64] = 6 cells with SEA_LEVEL=63;
# our SEA_LEVEL=64 equivalent is y∈[60, 65] = BEACH_DEPTH_BELOW=4
# below + BEACH_HEIGHT_ABOVE=1 above. Keeping these at vanilla values
# so 2D mode produces the original beach pattern (audit: ~8% beach
# columns instead of the 40% we hit when these were bumped to 6/5).
const BEACH_DEPTH_BELOW: int = 4
const BEACH_HEIGHT_ABOVE: int = 1
# Vanilla beach sand depth varies 0-4 cells via the `t`-noise (px.java:113).
# Without noise, we use a flat 2 cells = vanilla average. 4 cells produced
# 1000% sand counts; 2 cells lands in vanilla range (~40 cells/chunk).
const BEACH_SAND_DEPTH: int = 2
# 3D-mode-only band offsets — separate from BEACH_DEPTH_BELOW above so
# 2D mode stays at vanilla [60, 65]. The 3D-mode beach pass uses these
# wider offsets to compensate for the 3D surface staircasing more.
const BEACH_PASS_LO_OFFSET: int = 1  # 3D mode: sea_level - 1 = 63
const BEACH_PASS_HI_OFFSET: int = 5  # 3D mode: sea_level + 5 = 69

# Vanilla beach noise (`px.java:108-122` — `this.r`). A separate 2D
# Perlin sampled per (world_x, world_z) GATES whether a column in the
# beach Y-band actually becomes sand (`bl2 = r > 0`). Without this
# gate, every column whose surface dips into [60, 65] turns to sand —
# including isolated low spots inside forests, producing the
# "sand-in-forest" bug the user observed. Vanilla uses scale 0.03125
# for r; we match.
const BEACH_NOISE_FREQUENCY: float = 0.03125

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
# Tree count range. Bumped MAX from 3 to 5 for 3D-density mode where
# rejection rate is higher (more cliff/sand surfaces vs grass). Net
# expected count after rejection: ~1.5 (matches vanilla plains).
const _TREES_PER_CHUNK_MIN: int = 0
const _TREES_PER_CHUNK_MAX: int = 5
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

# --- Decoration constants (flowers + mushrooms) ---
# Vanilla aj.java attempts per scatter call. 64 is the canonical value.
# Flower scatter attempts per call. Vanilla aj.java uses 64 — we match
# for the algorithm but bump to 96 for our 3D-density mode where the
# random base-Y often misses the surface band entirely (vanilla samples
# uniform 0-127 too, but with biome-based surface placement gets more
# successful hits per call). Extra attempts compensate without
# violating Alpha shape — same scatter pattern, just more tries.
const _FLOWER_ATTEMPTS: int = 96
# Distinct salts per plant species so the seed streams don't correlate.
const _FLOWER_SALT_RED: int = 0xF101
const _FLOWER_SALT_YELLOW: int = 0xF102
const _FLOWER_SALT_BROWN: int = 0xF103
const _FLOWER_SALT_RED_MUSHROOM: int = 0xF104

# --- Lake decorator (vanilla `bv.java` / px.java:280-292) ---
# Per-chunk: 1-in-LAKE_WATER_CHANCE chance for a water lake, 1-in-LAKE_LAVA_CHANCE
# for a lava lake (with deeper-Y bias). Each lake is a 16×8×16 region
# with 4-7 random ellipsoids carved into a boolean shape, then written
# as water/lava (lower half) or air (upper half — lake "bowl"). Lakes
# also re-grass dirt cells around their rim.
const _LAKE_SALT_WATER: int = 0x1A4E
const _LAKE_SALT_LAVA: int = 0x1A7A
const _LAKE_WATER_CHANCE: int = 4
# Vanilla is 1/8 (px.java:286). Our lakes use a permissive validation
# (OOB→STONE always-pass) so more pass than vanilla; bump chance to 1/24
# for vanilla-shaped per-chunk lava density. Combined with the strict
# surface gate below, lava lakes only appear underground.
const _LAKE_LAVA_CHANCE: int = 64
const _LAKE_BBOX_X: int = 16
const _LAKE_BBOX_Y: int = 8
const _LAKE_BBOX_Z: int = 16
const _LAKE_ELLIPSOIDS_MIN: int = 4
const _LAKE_ELLIPSOIDS_MAX: int = 7
# Vanilla bv.java row 26: lake "water level" = bbox_y/2. Cells at
# y>=mid become AIR (the bowl); cells at y<mid become water/lava.
const _LAKE_WATER_LEVEL: int = 4  # = _LAKE_BBOX_Y / 2

static var terrain_mode: int = TerrainMode.MODE_2D_HEIGHTMAP

# Biome system toggle. When true, surface block selection (top + filler)
# is biome-driven via BiomeClimate.biome_at(). When false, every column
# uses the legacy SEA_LEVEL-based GRASS/DIRT split. Set by Game._ready
# from MC_CLONE_BIOMES env var. Orthogonal to terrain_mode — biomes
# work with both 2D heightmap and 3D density.
static var biomes_enabled: bool = false
static var _noise: FastNoiseLite
# Low-freq continental noise — see CONTINENTAL_* constants above.
# Sampled per-cell alongside the detail noise. ~256 extra noise calls
# per chunk (16×16 cells); FastNoiseLite samples in ~50ns, so the added
# cost is ~13µs/chunk — negligible vs the existing fill (~50ms p50 in
# the worker). Possible future optimization: sample at the 4 chunk
# corners and bilinear-interpolate per cell (continental wavelength is
# ~333 blocks so within-chunk variation is sub-cell anyway), reducing
# 256 calls to 4. Skipped for now — measure first.
static var _continental_noise: FastNoiseLite
# Vanilla beach noise (`px.java:108`'s this.r) — gates which columns in
# the beach Y-band actually become sand. See BEACH_NOISE_FREQUENCY for
# the rationale.
static var _beach_noise: FastNoiseLite
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


# Beach noise: gates sand placement. Single-octave 2D Perlin at vanilla's
# scale (~32-block wavelength). Seed offset +2 keeps it independent of
# the detail/continental noises (same pattern as continental noise).
static func _get_beach_noise() -> FastNoiseLite:
	if _beach_noise == null:
		_beach_noise = FastNoiseLite.new()
		_beach_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_beach_noise.frequency = BEACH_NOISE_FREQUENCY
		_beach_noise.seed = WORLD_SEED + 2
		_beach_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	return _beach_noise


# Continental noise: low-freq, dominant baseline shift per region. Uses
# a SEED OFFSET so it doesn't correlate with the detail noise — sharing
# the world seed without offset would make the two stacks crest/trough
# at identical (x,z), defeating the purpose of stacking them.
static func _get_continental_noise() -> FastNoiseLite:
	if _continental_noise == null:
		_continental_noise = FastNoiseLite.new()
		_continental_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_continental_noise.frequency = CONTINENTAL_FREQUENCY
		# +1 seed offset → independent stream from detail noise. Any
		# distinct nonzero offset works; 1 is the cheapest.
		_continental_noise.seed = WORLD_SEED + 1
		_continental_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_continental_noise.fractal_octaves = CONTINENTAL_OCTAVES
		_continental_noise.fractal_lacunarity = NOISE_LACUNARITY
		_continental_noise.fractal_gain = NOISE_GAIN
	return _continental_noise


# Per-column surface y derived from the chunk's actual blocks. Walks
# top-down from chunk.max_y until it hits a non-AIR cell. Required for
# 3D density mode where the heightmap-based `surface_height()` no longer
# matches the chunk's actual surface — beaches/ocean/trees that consult
# `surface_height` would land at the wrong y in 3D mode.
#
# In 2D mode this returns the same value as `surface_height()` (the
# base-terrain fill puts grass exactly at the heightmap top, so
# topmost-non-AIR == heightmap), so callers can use this unconditionally
# regardless of the active mode.
static func chunk_column_surface_y(chunk: Chunk, local_x: int, local_z: int) -> int:
	var top: int = mini(chunk.max_y, Chunk.SIZE_Y - 1)
	for y in range(top, -1, -1):
		if chunk.get_block_unchecked(local_x, y, local_z) != Blocks.AIR:
			return y
	return -1  # entire column is AIR (shouldn't happen with bedrock at y<=4)


static func surface_height(world_x: int, world_z: int) -> int:
	# Continental + detail noise stack. The continental layer creates
	# large coherent landmasses (low freq, big amplitude); the detail
	# layer rides on top with small hills/valleys. BASELINE_BIAS lifts
	# the mean above sea so the world averages land instead of water.
	#
	# This was originally tuned to fix the "too islandy with excessive
	# beaches" feel of pre-pre-improvement 2D mode (which used a single
	# FBM layer at high freq → many small hills → many sand-edged
	# islands). With continental layer the world has BIG landmasses
	# separated by BIG oceans — proper continental shape.
	var fx: float = float(world_x)
	var fz: float = float(world_z)
	var continental: float = _get_continental_noise().get_noise_2d(fx, fz)
	var detail: float = _get_noise().get_noise_2d(fx, fz)
	var continental_offset: int = int(round(continental * float(CONTINENTAL_AMPLITUDE)))
	var detail_offset: int = int(round(detail * float(DETAIL_AMPLITUDE)))
	return SEA_LEVEL + BASELINE_BIAS + continental_offset + detail_offset


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
	# Drop the cached noise so _get_noise() / _get_continental_noise()
	# rebuild with the new seed on the next call. Without this,
	# surface_height(0,0) would keep using the seed the noise was first
	# built with.
	_noise = null
	_continental_noise = null
	_beach_noise = null
	WorldgenDensity.reset()
	BiomeClimate.reset()
	_call_native_set_seed(seed)


static func generate_chunk(chunk_x: int, chunk_z: int) -> Chunk:
	var probe_token := PerfProbe.begin("worldgen.generate_chunk")
	var chunk := Chunk.new()
	# 1. Base terrain — 2D heightmap (default, fast) or 3D density
	# (vanilla-faithful, slower-but-richer: overhangs, cliffs, surface
	# caves). Selected via `terrain_mode` static. See
	# `.claude/worldgen-deferred.md` for the full design.
	if terrain_mode == TerrainMode.MODE_3D_DENSITY:
		var density_token := PerfProbe.begin("worldgen.density_terrain")
		WorldgenDensity.build_density_terrain(chunk, chunk_x, chunk_z)
		WorldgenDensity.apply_surface_layer(chunk, chunk_x, chunk_z)
		PerfProbe.end("worldgen.density_terrain", density_token)
	elif _native_worldgen != null and not biomes_enabled:
		# Native fast-path doesn't yet know about biomes — fall through to
		# GDScript when biomes are on so surface block selection runs the
		# biome-aware _block_at. Slice 4 of the biome plan ports the biome
		# decision into native; until then accept the GDScript path cost.
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
	# algorithm (bit-exact JavaRandom stream) in C++ and also returns the
	# chunk-state flags (has_non_cube / has_water) computed via an inline
	# 32K-cell scan in C++. The native scan is ~10× faster than the
	# equivalent GDScript loop and used to dominate the cave probe time.
	# Parity is enforced by tests/test_cave_parity.
	if _native_worldgen != null:
		var caves_token := PerfProbe.begin("worldgen.caves")
		var caves_result: Dictionary = _native_worldgen.call(
			"scatter_caves", chunk_x, chunk_z, chunk.blocks
		)
		chunk.blocks = caves_result["blocks"]
		# OR-merge with prior flag state so that water/non-cube cells set
		# by base terrain or ores stay sticky even if the cave scan didn't
		# observe one (caves never carve those cells, but the OR keeps the
		# invariant explicit).
		chunk.has_non_cube_blocks = chunk.has_non_cube_blocks or caves_result["has_non_cube"]
		chunk.has_water_cells = chunk.has_water_cells or caves_result["has_water"]
		# Cave AIR at topmost-opaque cells changes column heightmap; cheaper
		# to flag dirty than to re-scan every column here.
		chunk._height_map_dirty = true
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
	# 4b. Lakes — vanilla `bv.java` decorator (px.java:280-292). Skipped
	#     in 2D heightmap mode because pre-3D 2D mode had no lakes, and
	#     adding them produces visible "small water pools surrounded by
	#     sand" anomalies (the beach pass treats lake water as ocean →
	#     adjacent columns become beach → lake gets a sand ring around
	#     it). Lakes work better in 3D mode where the surface is more
	#     varied.
	if terrain_mode == TerrainMode.MODE_3D_DENSITY:
		_scatter_lakes(chunk, chunk_x, chunk_z)
	# 5. Trees — must come after surface placement so we know where grass is.
	_scatter_trees(chunk, chunk_x, chunk_z)
	# 6. Flowers + mushrooms — vanilla's populate phase decoration calls.
	#    Runs AFTER trees so we don't drop flowers into trunks/leaves.
	_scatter_flowers(chunk, chunk_x, chunk_z)
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
		# With biomes ON: biome.top always wins, even underwater. Vanilla
		# Plains has GRASS at ocean floor; Desert has SAND. Ocean fill
		# pass writes WATER above the surface separately. This matches
		# vanilla px.java:130-148 directly.
		if biomes_enabled:
			return Biomes.top_block(BiomeClimate.biome_at(world_x, world_z))
		# Without biomes: simple rule — underwater = DIRT, above sea =
		# GRASS. This was the workaround for "grass-underwater" before
		# biomes existed; with biomes the issue disappears in non-Plains
		# biomes (Desert columns are SAND, not grass).
		if surface_y < SEA_LEVEL:
			return Blocks.DIRT
		return Blocks.GRASS
	if y >= surface_y - 3:
		# Filler block — next 3 cells below the surface. Biome-aware:
		# Desert/Ice-Desert use SAND filler so the column is sand all
		# the way down (no grass/dirt revealed where caves cut through).
		# Vanilla px.java:130-148 sets `by3 = biome.p` for the filler.
		if biomes_enabled:
			return Biomes.filler_block(BiomeClimate.biome_at(world_x, world_z))
		return Blocks.DIRT
	return Blocks.STONE


static func _is_bedrock_at(world_x: int, y: int, world_z: int) -> bool:
	if y < 1 or y > 4:
		return false
	var threshold: int = _BEDROCK_THRESHOLDS_FIFTHS[y]
	return (_hash3(world_x, y, world_z) % 5) < threshold


# --- Beaches ---


static func _place_beaches(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	# 2D heightmap mode uses the pre-3D beach pass: heightmap surface,
	# no water-adjacency, narrow vanilla [SEA_LEVEL-4, SEA_LEVEL+1] band.
	# All the 3D-era complications (chunk_column_surface_y reads, wider
	# band, water-adjacency search) were added to handle 3D-mode-specific
	# issues (steep coastlines, surface-vs-heightmap divergence) and
	# WORSEN 2D mode behavior (sand blotches from radius search, etc.).
	if terrain_mode == TerrainMode.MODE_2D_HEIGHTMAP:
		_place_beaches_2d(chunk, chunk_x, chunk_z)
		return
	var probe_token := PerfProbe.begin("worldgen.beaches")
	# Use the BEACH_PASS_* offsets (tighter than _block_at's BEACH_DEPTH_BELOW)
	# to concentrate sand into the visible dry-beach zone near the waterline.
	var lo: int = SEA_LEVEL - BEACH_PASS_LO_OFFSET
	var hi: int = SEA_LEVEL + BEACH_PASS_HI_OFFSET
	var beach_noise := _get_beach_noise()
	# Precompute every column's surface y so the water-adjacency check
	# below scans neighbors without re-walking the chunk per cell.
	var col_surface := PackedInt32Array()
	col_surface.resize(Chunk.SIZE_X * Chunk.SIZE_Z)
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			col_surface[z * Chunk.SIZE_X + x] = chunk_column_surface_y(chunk, x, z)
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			var surface_y: int = col_surface[z * Chunk.SIZE_X + x]
			# Outside the beach band: hills + deep oceans untouched.
			if surface_y < lo or surface_y > hi:
				continue
			# Strict 1-cell water-adjacency. Wider radius (4) was creating
			# sand-blotch circles around isolated lakes mid-grass. The
			# real fix for "1-cell wide beaches at staircases" is the
			# smooth elevation noise gradient, not blasting sand into
			# every column near water.
			var has_water_neighbor: bool = false
			for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + off.x
				var nz: int = z + off.y
				var neighbor_below_sea: bool = false
				if nx >= 0 and nx < Chunk.SIZE_X and nz >= 0 and nz < Chunk.SIZE_Z:
					neighbor_below_sea = col_surface[nz * Chunk.SIZE_X + nx] < SEA_LEVEL
				else:
					var nwx: int = chunk_x * Chunk.SIZE_X + nx
					var nwz: int = chunk_z * Chunk.SIZE_Z + nz
					if terrain_mode == TerrainMode.MODE_3D_DENSITY:
						neighbor_below_sea = (
							WorldgenDensity.estimate_target_y(nwx, nwz) < float(SEA_LEVEL)
						)
					else:
						neighbor_below_sea = surface_height(nwx, nwz) < SEA_LEVEL
				if neighbor_below_sea:
					has_water_neighbor = true
					break
			if not has_water_neighbor:
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


# Pre-3D-era beach pass — 2D heightmap mode only. Mostly identical to
# commit 20739fc (the last pre-3D beach pass) but with a STRICT 1-cell
# water-adjacency check added — without it, FLAT seeds produce huge
# sand fields (entire chunks in the beach Y band become sand) which
# was pre-3D's actual complaint. The water-adjacency check uses the
# heightmap directly (no chunk reads needed in 2D mode), so it's free
# performance-wise.
static func _place_beaches_2d(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.beaches")
	var lo: int = SEA_LEVEL - BEACH_DEPTH_BELOW
	var hi: int = SEA_LEVEL + BEACH_HEIGHT_ABOVE
	# Vanilla approach (px.java BiomeBase.b): any beach-band column where
	# beach noise > 0 becomes sand. NO water-adjacency requirement — that
	# was our addition to suppress sand-in-forest, but it produced 1-cell
	# beach strips at coastlines (only the column directly adjacent to
	# water converts). Beach noise (0.03125 freq) provides natural soft
	# patches that look like Alpha beaches.
	var beach_noise := _get_beach_noise()
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			var world_x: int = chunk_x * Chunk.SIZE_X + x
			var world_z: int = chunk_z * Chunk.SIZE_Z + z
			var surface_y: int = surface_height(world_x, world_z)
			if surface_y < lo or surface_y > hi:
				continue
			if beach_noise.get_noise_2d(float(world_x), float(world_z)) <= 0.0:
				continue
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
static func _fill_ocean(chunk: Chunk, _chunk_x: int, _chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.ocean")
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			# Use chunk's actual surface (mode-agnostic — see beach pass).
			var surface_y: int = chunk_column_surface_y(chunk, x, z)
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


# --- Lake decorator (vanilla bv.java) ---
#
# Vanilla algorithm (verbatim from `bv.java`):
#   1. Subtract 8 from x/z to get bbox corner (px.java passes center+8)
#   2. Walk down from y until non-air, then -4 → lake top
#   3. Build 16×16×8 boolean shape via 4-7 random ellipsoids
#   4. Validate: every "wall" cell (non-lake adjacent to lake) must be
#      solid in the bottom half (no air gaps below water level) and not
#      liquid in the top half (no caves above water table). Reject lake
#      if any wall fails the check.
#   5. Write blocks: cells inside shape become AIR (top half) or
#      water/lava (bottom half).
#   6. Convert shore dirt to grass: any AIR-cell-just-written above water
#      level whose block-below is dirt and has skylight → grass.
#
# Cross-chunk handling: vanilla writes via World.setBlock which crosses
# chunk boundaries freely. We use the SW-spillover dispatch (mirroring
# `_scatter_flowers`) so each chunk sees the lakes that spill INTO it
# from SW neighbors. Each pass clips writes to the target chunk and
# treats out-of-bounds reads as STONE — the validation pass will be
# slightly more permissive than vanilla (can't see a cave in a not-yet-
# generated neighbor), so lake density runs ~1.5-2× vanilla. Acceptable
# tradeoff for chunk-determinism without a populate-after-load step.


static func _scatter_lakes(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.lakes")
	for dcx in [0, -1]:
		for dcz in [0, -1]:
			var src_cx: int = chunk_x + dcx
			var src_cz: int = chunk_z + dcz
			_try_water_lake(chunk, chunk_x, chunk_z, src_cx, src_cz)
			_try_lava_lake(chunk, chunk_x, chunk_z, src_cx, src_cz)
	PerfProbe.end("worldgen.lakes", probe_token)


# Mirrors vanilla px.java:280-285 — 1/4 chance of a water lake at a
# random Y in [0, 128) and a random XZ in chunk + offset 8.
static func _try_water_lake(
	target_chunk: Chunk, target_cx: int, target_cz: int, src_cx: int, src_cz: int
) -> void:
	var lake_seed: int = _hash4(src_cx, src_cz, _LAKE_SALT_WATER, 0)
	var c: int = 0
	if _next_int(lake_seed, c, _LAKE_WATER_CHANCE) != 0:
		return
	c += 1
	var center_x: int = src_cx * Chunk.SIZE_X + _next_int(lake_seed, c, 16) + 8
	c += 1
	var center_y: int = _next_int(lake_seed, c, 128)
	c += 1
	var center_z: int = src_cz * Chunk.SIZE_X + _next_int(lake_seed, c, 16) + 8
	c += 1
	_try_place_lake(
		target_chunk,
		target_cx,
		target_cz,
		center_x,
		center_y,
		center_z,
		Blocks.WATER_STILL,
		lake_seed,
		c
	)


# Mirrors vanilla px.java:286-293 — 1/8 chance of a lava lake, with
# nextInt(nextInt(120)+8) Y bias (skewed deeper) and an additional gate:
# only place if y<64 OR 1/10 chance (so most surface lava lakes are
# rejected; lava lakes mostly land underground).
static func _try_lava_lake(
	target_chunk: Chunk, target_cx: int, target_cz: int, src_cx: int, src_cz: int
) -> void:
	var lake_seed: int = _hash4(src_cx, src_cz, _LAKE_SALT_LAVA, 0)
	var c: int = 0
	if _next_int(lake_seed, c, _LAKE_LAVA_CHANCE) != 0:
		return
	c += 1
	var center_x: int = src_cx * Chunk.SIZE_X + _next_int(lake_seed, c, 16) + 8
	c += 1
	# Vanilla nextInt(nextInt(120)+8) — two consecutive draws, the inner
	# becomes the upper bound for the outer. Skews distribution toward
	# small Y values (nearly half land below y=30).
	var inner_max: int = _next_int(lake_seed, c, 120) + 8
	c += 1
	var center_y: int = _next_int(lake_seed, c, inner_max)
	c += 1
	var center_z: int = src_cz * Chunk.SIZE_X + _next_int(lake_seed, c, 16) + 8
	c += 1
	# Strict surface gate — vanilla allows 1/10 chance for surface lava
	# lakes (px.java:290), but visually they're jarring (bright orange
	# pools on the green grass). For Alpha-feel without surface lava,
	# always reject if y >= sea level. Lava only underground.
	if center_y >= SEA_LEVEL - 4:
		return
	c += 1
	_try_place_lake(
		target_chunk,
		target_cx,
		target_cz,
		center_x,
		center_y,
		center_z,
		Blocks.LAVA_STILL,
		lake_seed,
		c
	)


# Returns true if the lake was placed (writes hit the target chunk),
# false if validation rejected it. Per-chunk pass-rate matters less for
# our chunk-isolated model since each chunk votes independently — see
# class-level commentary above.
static func _try_place_lake(
	target_chunk: Chunk,
	target_cx: int,
	target_cz: int,
	center_x: int,
	center_y: int,
	center_z: int,
	fluid_id: int,
	lake_seed: int,
	c_start: int
) -> bool:
	var c: int = c_start
	# bv.java:18-19: shift to bbox corner.
	var corner_x: int = center_x - 8
	var corner_z: int = center_z - 8
	# bv.java:20-23: walk down from y until non-air, then -4.
	#
	# Vanilla reads world blocks freely. Our chunk-isolated model can only
	# walk down inside the target chunk; for SW-spillover passes whose
	# corner column lands in a NEIGHBOR chunk we use a surface estimate
	# (heightmap in 2D mode, density target_y in 3D mode) so the walk-down
	# still terminates near the actual surface — without this, OOB reads
	# returned STONE and the walk terminated immediately at the random
	# `center_y`, dropping spillover lakes at random Ys (often deep
	# underground or near the world ceiling). See worldgen-deferred.md.
	var lx_corner: int = corner_x - target_cx * Chunk.SIZE_X
	var lz_corner: int = corner_z - target_cz * Chunk.SIZE_Z
	var corner_in_target: bool = (
		lx_corner >= 0 and lx_corner < Chunk.SIZE_X and lz_corner >= 0 and lz_corner < Chunk.SIZE_Z
	)
	var corner_y: int = center_y
	if corner_in_target:
		while (
			corner_y > 0
			and target_chunk.get_block_unchecked(lx_corner, corner_y, lz_corner) == Blocks.AIR
		):
			corner_y -= 1
	else:
		var est_surface: int = _surface_estimate_for_lake(corner_x, corner_z)
		corner_y = mini(corner_y, est_surface)
	corner_y -= 4
	if corner_y < 1:
		return false  # would clip into bedrock — vanilla would too

	# bv.java:24-44: build 16×8×16 boolean shape from 4-7 ellipsoids.
	# Layout: shape[(ix * 16 + iz) * 8 + iy] (matches vanilla index order).
	var shape := PackedByteArray()
	shape.resize(_LAKE_BBOX_X * _LAKE_BBOX_Z * _LAKE_BBOX_Y)
	var num_ellipsoids: int = (
		_next_int(lake_seed, c, _LAKE_ELLIPSOIDS_MAX - _LAKE_ELLIPSOIDS_MIN + 1)
		+ _LAKE_ELLIPSOIDS_MIN
	)
	c += 1
	for _i in range(num_ellipsoids):
		# Vanilla bv.java:25-30: ellipsoid radii + center within bbox.
		var rad_x: float = _float01(lake_seed, c) * 6.0 + 3.0
		c += 1
		var rad_y: float = _float01(lake_seed, c) * 4.0 + 2.0
		c += 1
		var rad_z: float = _float01(lake_seed, c) * 6.0 + 3.0
		c += 1
		var ctr_x: float = _float01(lake_seed, c) * (16.0 - rad_x - 2.0) + 1.0 + rad_x / 2.0
		c += 1
		var ctr_y: float = _float01(lake_seed, c) * (8.0 - rad_y - 4.0) + 2.0 + rad_y / 2.0
		c += 1
		var ctr_z: float = _float01(lake_seed, c) * (16.0 - rad_z - 2.0) + 1.0 + rad_z / 2.0
		c += 1
		var half_rx: float = rad_x / 2.0
		var half_ry: float = rad_y / 2.0
		var half_rz: float = rad_z / 2.0
		# bv.java:31-43 inner triple loop. Bounds [1, 14] / [1, 6] match vanilla.
		for ix in range(1, 15):
			var dx: float = (float(ix) - ctr_x) / half_rx
			var dx2: float = dx * dx
			for iz in range(1, 15):
				var dz: float = (float(iz) - ctr_z) / half_rz
				var dz2: float = dz * dz
				for iy in range(1, 7):
					var dy: float = (float(iy) - ctr_y) / half_ry
					if dx2 + dy * dy + dz2 < 1.0:
						shape[(ix * 16 + iz) * 8 + iy] = 1

	# bv.java:45-66: validation pass — walls must be solid in bottom half,
	# non-liquid in top half. We treat OOB cells as STONE (always-pass)
	# since we can't read neighbor chunks — see class-level note.
	for ix in range(_LAKE_BBOX_X):
		for iz in range(_LAKE_BBOX_Z):
			for iy in range(_LAKE_BBOX_Y):
				if shape[(ix * 16 + iz) * 8 + iy] != 0:
					continue
				var is_wall: bool = (
					(ix < 15 and shape[((ix + 1) * 16 + iz) * 8 + iy] != 0)
					or (ix > 0 and shape[((ix - 1) * 16 + iz) * 8 + iy] != 0)
					or (iz < 15 and shape[(ix * 16 + (iz + 1)) * 8 + iy] != 0)
					or (iz > 0 and shape[(ix * 16 + (iz - 1)) * 8 + iy] != 0)
					or (iy < 7 and shape[(ix * 16 + iz) * 8 + (iy + 1)] != 0)
					or (iy > 0 and shape[(ix * 16 + iz) * 8 + (iy - 1)] != 0)
				)
				if not is_wall:
					continue
				var wx: int = corner_x + ix
				var wy: int = corner_y + iy
				var wz: int = corner_z + iz
				var b: int = _lake_read_block(target_chunk, target_cx, target_cz, wx, wy, wz)
				if iy >= _LAKE_WATER_LEVEL:
					# Top half: no liquid in walls (no caves/water above lake)
					if _lake_is_liquid(b):
						return false
				else:
					# Bottom half: must be solid (not air, not other fluid)
					if b == Blocks.AIR:
						return false
					if b != fluid_id and _lake_is_liquid(b):
						return false

	# bv.java:67-77: write blocks. Top half (iy ≥ 4) becomes AIR; bottom
	# half becomes the fluid. AIR carved cells form the lake's "bowl".
	for ix in range(_LAKE_BBOX_X):
		for iz in range(_LAKE_BBOX_Z):
			for iy in range(_LAKE_BBOX_Y):
				if shape[(ix * 16 + iz) * 8 + iy] == 0:
					continue
				var write_id: int = Blocks.AIR if iy >= _LAKE_WATER_LEVEL else fluid_id
				_lake_write_block(
					target_chunk,
					target_cx,
					target_cz,
					corner_x + ix,
					corner_y + iy,
					corner_z + iz,
					write_id
				)

	# bv.java:78-87: shore dirt → grass conversion. For AIR cells written
	# above water level, if the cell BELOW is dirt and exposed to sky,
	# convert it to grass. Skylight is computed post-gen; we approximate
	# by checking that no opaque block sits directly above the AIR cell
	# inside the lake bbox (minor visual diff from vanilla skylight test).
	for ix in range(_LAKE_BBOX_X):
		for iz in range(_LAKE_BBOX_Z):
			for iy in range(_LAKE_WATER_LEVEL, _LAKE_BBOX_Y):
				if shape[(ix * 16 + iz) * 8 + iy] == 0:
					continue
				var wx: int = corner_x + ix
				var wy: int = corner_y + iy
				var wz: int = corner_z + iz
				var below: int = _lake_read_block(
					target_chunk, target_cx, target_cz, wx, wy - 1, wz
				)
				if below != Blocks.DIRT:
					continue
				_lake_write_block(target_chunk, target_cx, target_cz, wx, wy - 1, wz, Blocks.GRASS)

	return true


# Helper: deterministic int in [0, n) using existing _float01 stream.
static func _next_int(seed_hash: int, salt: int, n: int) -> int:
	return int(_float01(seed_hash, salt) * float(n))


# Read a block at world coords. OOB returns STONE so validation treats
# unknown neighbor cells as solid wall (lake passes), and the walk-down
# step stops at the chunk boundary instead of falling forever.
static func _lake_read_block(
	target_chunk: Chunk, target_cx: int, target_cz: int, wx: int, wy: int, wz: int
) -> int:
	if wy < 0 or wy >= Chunk.SIZE_Y:
		return Blocks.STONE
	var lx: int = wx - target_cx * Chunk.SIZE_X
	var lz: int = wz - target_cz * Chunk.SIZE_Z
	if lx < 0 or lx >= Chunk.SIZE_X or lz < 0 or lz >= Chunk.SIZE_Z:
		return Blocks.STONE
	return target_chunk.get_block_unchecked(lx, wy, lz)


# Write a block at world coords. OOB writes are silently dropped
# (recovered when the neighbor chunk runs its own SW-spillover pass).
static func _lake_write_block(
	target_chunk: Chunk, target_cx: int, target_cz: int, wx: int, wy: int, wz: int, block_id: int
) -> void:
	if wy < 0 or wy >= Chunk.SIZE_Y:
		return
	var lx: int = wx - target_cx * Chunk.SIZE_X
	var lz: int = wz - target_cz * Chunk.SIZE_Z
	if lx < 0 or lx >= Chunk.SIZE_X or lz < 0 or lz >= Chunk.SIZE_Z:
		return
	target_chunk.set_block_unchecked(lx, wy, lz, block_id)


static func _lake_is_liquid(id: int) -> bool:
	return (
		id == Blocks.WATER_STILL
		or id == Blocks.WATER_FLOWING
		or id == Blocks.LAVA_STILL
		or id == Blocks.LAVA_FLOWING
	)


# Approximate surface y for a column NOT in the target chunk. Used by the
# lake walk-down to find where the lake's top should sit when the bbox
# corner lands in a neighbor chunk that hasn't been generated yet (so
# direct block reads are impossible). Mirrors the mode-aware surface API
# used by beaches.
static func _surface_estimate_for_lake(world_x: int, world_z: int) -> int:
	if terrain_mode == TerrainMode.MODE_3D_DENSITY:
		return int(WorldgenDensity.estimate_target_y(world_x, world_z))
	return surface_height(world_x, world_z)


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
		# Use chunk's actual surface (mode-agnostic — beach/ocean did the
		# same fix; surface_height() is wrong in 3D mode).
		var ground_y: int = chunk_column_surface_y(chunk, lx, lz)
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


# --- Decoration: flowers + mushrooms ---
#
# Vanilla Alpha 1.2.6 px.java populate phase (lines 388-411) — per chunk:
#   * Red poppy (nq.ad):        2 calls always
#   * Yellow dandelion (nq.ae): 1 call at 1/2 probability
#   * Brown mushroom (nq.af):   1 call at 1/4 probability
#   * Red mushroom (nq.ag):     1 call at 1/8 probability
#
# Each "call" is `new aj(blockId).a(world, rand, x, y, z)`, where x/z =
# `chunk*16 + nextInt(16) + 8` and y = `nextInt(128)`. WorldGenFlowers
# (aj.java) then runs 64 attempts at base ± (8, 4, 8), placing on AIR
# cells whose support passes the block's `g()` check (light ≤ 13 + grass
# /dirt below for flowers).
#
# Determinism + spillover: vanilla's `+8` offset means decoration writes
# spill into the +X +Z neighbor. Mirroring the ore decorator pattern, we
# run for own + 3 SW neighbors (chunk_x + dcx, chunk_z + dcz with dcx,dcz
# in {-1, 0}) and clip writes to the current chunk's bounds. Restores
# vanilla's coverage without cross-chunk writes from the worker thread.


static func _scatter_flowers(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.flowers")
	for dcx in [-1, 0]:
		for dcz in [-1, 0]:
			_decorate_flowers(chunk, chunk_x, chunk_z, chunk_x + dcx, chunk_z + dcz)
	PerfProbe.end("worldgen.flowers", probe_token)


# Run the populate-phase flower/mushroom calls AS IF this is the
# (deco_cx, deco_cz) chunk. Writes that fall outside (chunk_x, chunk_z)'s
# bounds are clipped, so each call to this only contributes the cells
# that vanilla's spillover would have landed in our chunk.
static func _decorate_flowers(
	chunk: Chunk, chunk_x: int, chunk_z: int, deco_cx: int, deco_cz: int
) -> void:
	# Red poppy — always 2 calls. Distinct seed per call so the two
	# clusters land in different spots.
	for i in range(2):
		_scatter_plant(
			chunk,
			chunk_x,
			chunk_z,
			deco_cx,
			deco_cz,
			Blocks.FLOWER_RED,
			_hash4(deco_cx, deco_cz, _FLOWER_SALT_RED, i + 1),
			false,
		)
	# Yellow dandelion — 1 call at 1/2 probability.
	var yellow_gate: int = _hash4(deco_cx, deco_cz, _FLOWER_SALT_YELLOW, 0)
	if (yellow_gate & 1) == 0:
		_scatter_plant(
			chunk,
			chunk_x,
			chunk_z,
			deco_cx,
			deco_cz,
			Blocks.FLOWER_YELLOW,
			_hash4(deco_cx, deco_cz, _FLOWER_SALT_YELLOW, 1),
			false,
		)
	# Brown mushroom — 1 call at 1/4 probability.
	var brown_gate: int = _hash4(deco_cx, deco_cz, _FLOWER_SALT_BROWN, 0)
	if (brown_gate & 3) == 0:
		_scatter_plant(
			chunk,
			chunk_x,
			chunk_z,
			deco_cx,
			deco_cz,
			Blocks.MUSHROOM_BROWN,
			_hash4(deco_cx, deco_cz, _FLOWER_SALT_BROWN, 1),
			true,
		)
	# Red mushroom — 1 call at 1/8 probability.
	var red_mush_gate: int = _hash4(deco_cx, deco_cz, _FLOWER_SALT_RED_MUSHROOM, 0)
	if (red_mush_gate & 7) == 0:
		_scatter_plant(
			chunk,
			chunk_x,
			chunk_z,
			deco_cx,
			deco_cz,
			Blocks.MUSHROOM_RED,
			_hash4(deco_cx, deco_cz, _FLOWER_SALT_RED_MUSHROOM, 1),
			true,
		)


# Vanilla aj.java port — pick a base position then run 64 placement
# attempts at base ± (8, 4, 8). `is_mushroom` relaxes support to allow
# any opaque block below (vanilla mushrooms grow on stone too).
# Writes that fall outside (chunk_x, chunk_z) are clipped — that's how
# the SW-neighbor decoration passes contribute spillover into us.
static func _scatter_plant(
	chunk: Chunk,
	chunk_x: int,
	chunk_z: int,
	deco_cx: int,
	deco_cz: int,
	plant_id: int,
	seed_hash: int,
	is_mushroom: bool
) -> void:
	# Base in vanilla is `chunk*16 + nextInt(16) + 8` for X/Z and
	# `nextInt(128)` for Y.
	var base_x: int = deco_cx * Chunk.SIZE_X + (seed_hash & 0xF) + 8
	var base_z: int = deco_cz * Chunk.SIZE_Z + ((seed_hash >> 8) & 0xF) + 8
	var base_y: int = (seed_hash >> 16) & 0x7F  # 0..127
	var chunk_origin_x: int = chunk_x * Chunk.SIZE_X
	var chunk_origin_z: int = chunk_z * Chunk.SIZE_Z
	for attempt in range(_FLOWER_ATTEMPTS):
		var att_hash: int = _hash4(seed_hash, attempt, plant_id, 0x117)
		# Vanilla: `nextInt(8) - nextInt(8)` for x,z (range [-7, 7]) and
		# `nextInt(4) - nextInt(4)` for y (range [-3, 3]). Approximated
		# with two nibbles per coord.
		var ox: int = (att_hash & 7) - ((att_hash >> 3) & 7)
		var oy: int = ((att_hash >> 6) & 3) - ((att_hash >> 8) & 3)
		var oz: int = ((att_hash >> 10) & 7) - ((att_hash >> 13) & 7)
		var wx: int = base_x + ox
		var wy: int = base_y + oy
		var wz: int = base_z + oz
		if wy < 1 or wy >= Chunk.SIZE_Y - 1:
			continue
		var lx: int = wx - chunk_origin_x
		var lz: int = wz - chunk_origin_z
		if lx < 0 or lx >= Chunk.SIZE_X or lz < 0 or lz >= Chunk.SIZE_Z:
			continue
		# Cell must be AIR.
		if chunk.get_block_unchecked(lx, wy, lz) != Blocks.AIR:
			continue
		# Block below must be valid support. Flowers: grass / dirt / farmland.
		# Mushrooms: same, plus any opaque cube (vanilla allows stone in caves).
		var support_id: int = chunk.get_block_unchecked(lx, wy - 1, lz)
		var support_ok: bool = Blocks.is_valid_plant_support(support_id)
		if not support_ok and is_mushroom:
			support_ok = Blocks.is_opaque(support_id)
		if not support_ok:
			continue
		# Y-band check — vanilla flowers spawn at any light ≥ 9; light is
		# tied to elevation (deep caves dark, surface bright). Strict
		# sky-exposure was the previous proxy but was too aggressive in
		# 3D mode (overhangs hide grass cells from the sky → flowers
		# rejected even when they'd be perfectly visible from the side).
		# Replace with a simple Y-band: flowers must be near the surface
		# elevation to spawn (y >= SEA_LEVEL - 2). Excludes deep-cave
		# dirt veins that the user can't reach without much affecting
		# overhang flowers. Mushrooms keep no Y check (vanilla allows
		# them in caves).
		if not is_mushroom and wy < SEA_LEVEL - 2:
			continue
		chunk.set_block_unchecked(lx, wy, lz, plant_id)


# --- Hashing ---


# Cheap deterministic hash per (x, y, z, seed). Three large primes + XOR
# scramble, then a final Knuth multiplicative mix (see _HASH_MIX note near
# the top of the file) so low-bit differences in the last argument
# avalanche up to the high bits.
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
