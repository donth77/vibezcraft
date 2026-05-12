class_name Worldgen3D
extends RefCounted

# Vanilla Alpha 1.2.6 3D density terrain — direct port of `px.java`'s
# density pipeline (vendor/alpha-1.2.6-src/src/px.java:181-260) and chunk
# fill (px.java:46-99).
#
# This is Phase 3 of the terrain rework (see .claude/terrain-shape-rework-v2.md).
# Phase 3 ports the full density pipeline with constant climate=0.5 (no
# biome modulation yet — Phase 4 adds that).
#
# CRITICAL: this uses our ported NoiseOctaves.create_vanilla() which
# wraps NoisePerlin (z.java port) over a shared JavaRandom. Vanilla's
# px.java constants (684.412, 8.555, 200, 1.121, /8000, *3-2, etc.)
# are tuned for these exact noise output statistics and must be used
# AS-IS — no empirical retuning. If audit numbers are off, debug the
# port, not the constants.

# Biome IDs — match vanilla gg.java naming order. Each is a distinct
# climate region with its own surface block. Phase 6 only uses these
# for surface block selection (sand-vs-grass); future phases may add
# per-biome decoration density and grass tinting.
enum Biome {
	RAINFOREST,
	SWAMPLAND,
	SEASONAL_FOREST,
	FOREST,
	SAVANNA,
	SHRUBLAND,
	TAIGA,
	DESERT,
	PLAINS,
	ICE_DESERT,
	TUNDRA,
}

# Coarse grid: 5×17×5 sample positions per chunk; trilerped to 16×128×16
# cells. n5=n8=5 in vanilla; n7=17.
const GRID_X: int = 5
const GRID_Y: int = 17
const GRID_Z: int = 5
# Each coarse cell spans 4 world cells horizontally, 8 vertically.
# (Chunk is 16×128×16; grid is one extra at each edge for trilerp.)
const COARSE_STEP_X: int = 4
const COARSE_STEP_Y: int = 8
const COARSE_STEP_Z: int = 4

# Vanilla noise scales (px.java:185-194, all values verbatim).
const COORDINATE_SCALE: float = 684.412  # density e/f horizontal
const HEIGHT_SCALE: float = 684.412  # density e/f vertical
const SELECTOR_SCALE_XZ: float = 684.412 / 80.0  # = 8.555
const SELECTOR_SCALE_Y: float = 684.412 / 160.0  # = 4.27775
const AMPLITUDE_SCALE: float = 1.121  # g noise (XZ + Y same)
const DEPTH_SCALE: float = 200.0  # h noise

# Vanilla normalization constants (px.java:208, 212).
const AMPLITUDE_OFFSET: float = 256.0
const AMPLITUDE_DIVISOR: float = 512.0
const DEPTH_DIVISOR: float = 8000.0
const DENSITY_DIVISOR: float = 512.0
const SELECTOR_DIVISOR: float = 10.0  # px.java:248: (d/10 + 1)/2

# Vanilla SEA_LEVEL.
const SEA_LEVEL: int = 64

# Cached noise stack — built once per seed.
static var _e_noise: NoiseOctaves  # px.java this.k (16-octave 3D density)
static var _f_noise: NoiseOctaves  # px.java this.l (16-octave 3D density)
static var _selector_noise: NoiseOctaves  # px.java this.m (8-octave 3D)
static var _beach_noise: NoiseOctaves  # px.java this.n (4-octave 2D, unused in Phase 3)
static var _soil_noise: NoiseOctaves  # px.java this.o (4-octave 2D, unused in Phase 3)
static var _amplitude_noise: NoiseOctaves  # px.java this.a (10-octave 2D)
static var _depth_noise: NoiseOctaves  # px.java this.b (16-octave 2D)
static var _forest_noise: NoiseOctaves  # px.java this.c (8-octave 2D, unused in Phase 3)
# Phase 4: climate noises matching vanilla po.java (WorldChunkManager).
# Vanilla uses Simplex (aw.java) via 4-octave ng.java; we use FastNoiseLite
# Simplex for speed/simplicity. Output is approximate-vanilla, not exact.
# Scales match vanilla po.java:50-52 (temperature 0.025, rainfall 0.05,
# extreme 0.25 per-coord step). Each gets its own seed offset.
static var _temp_noise: FastNoiseLite
static var _rain_noise: FastNoiseLite
static var _extreme_noise: FastNoiseLite
static var _cached_seed: int = 0  # tracks which seed the noises were built with


# Build (or rebuild on seed change) the 8-noise stack the vanilla way:
# vanilla px.java:35-42 chains ALL 8 NoiseOctaves through ONE shared
# JavaRandom, where each `new nf(this.j, N)` constructor advances that
# RNG by N × (256+3) draws. The per-octave gradient tables therefore
# depend on the order AND the cumulative entropy consumption — feeding
# each noise its own RNG (the prior `create_vanilla(world_seed + i, N)`
# pattern) gave each noise a DIFFERENT gradient table than vanilla,
# producing the flat-ocean terrain bug at every seed.
#
# Order MUST match vanilla px.java exactly:
#   k = e (16-octave 3D density)
#   l = f (16-octave 3D density)
#   m = selector (8-octave 3D)
#   n = beach (4-octave 2D)
#   o = soil (4-octave 2D)
#   a = amplitude (10-octave 2D)
#   b = depth (16-octave 2D)
#   c = forest (8-octave 2D)
static func _ensure_noises(world_seed: int) -> void:
	if _e_noise != null and _cached_seed == world_seed:
		return
	var rng := JavaRandom.new(world_seed)
	_e_noise = NoiseOctaves.create_vanilla_chained(rng, 16)
	_f_noise = NoiseOctaves.create_vanilla_chained(rng, 16)
	_selector_noise = NoiseOctaves.create_vanilla_chained(rng, 8)
	_beach_noise = NoiseOctaves.create_vanilla_chained(rng, 4)
	_soil_noise = NoiseOctaves.create_vanilla_chained(rng, 4)
	_amplitude_noise = NoiseOctaves.create_vanilla_chained(rng, 10)
	_depth_noise = NoiseOctaves.create_vanilla_chained(rng, 16)
	_forest_noise = NoiseOctaves.create_vanilla_chained(rng, 8)
	# Climate noises (Phase 4). Frequencies from vanilla po.java:
	# temperature uses 0.025/cell, rainfall 0.05/cell, extreme 0.25/cell.
	# Vanilla seed multipliers: 9871 (temp), 39811 (rain), 543321 (extreme).
	# We pass through hash to fit FastNoiseLite's 32-bit seed.
	# Climate noise frequencies — these set how rapidly biomes change
	# across the map. Vanilla po.java uses 0.025 per cell which assumes
	# vanilla's specific noise distribution; with FastNoiseLite Simplex
	# at 0.025 we got biome boundaries flipping every ~5 cells, producing
	# 'snow-capped grass in a forest biome' artifacts (jagged taiga/
	# forest borders where every taiga sub-cell got snow_layer while
	# neighboring forest cells didn't). Vanilla biome regions are
	# 100+ blocks across.
	# Lowered to 1/5 vanilla — period now ~200 blocks for temp,
	# ~100 for rain. Biomes are now coherent regions you can recognize
	# instead of cell-by-cell speckling.
	_temp_noise = FastNoiseLite.new()
	_temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_temp_noise.frequency = 0.005
	_temp_noise.seed = (world_seed * 9871) & 0x7FFFFFFF
	_temp_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_temp_noise.fractal_octaves = 4
	_rain_noise = FastNoiseLite.new()
	_rain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_rain_noise.frequency = 0.01
	_rain_noise.seed = (world_seed * 39811) & 0x7FFFFFFF
	_rain_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_rain_noise.fractal_octaves = 4
	# Extreme noise stays at higher frequency — it's meant to add
	# regional climate spikes (small dramatic deserts/tundras inside
	# larger temperate zones), not the dominant biome scale.
	_extreme_noise = FastNoiseLite.new()
	_extreme_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_extreme_noise.frequency = 0.05
	_extreme_noise.seed = (world_seed * 543321) & 0x7FFFFFFF
	_extreme_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_extreme_noise.fractal_octaves = 2
	_cached_seed = world_seed


# Compute (temperature, rainfall) for a single (world_x, world_z) cell.
# Direct port of vanilla po.java:75-101 climate computation. Output is
# Vector2(temp, rain) where both are in [0, 1].
static func climate_at(world_x: float, world_z: float) -> Vector2:
	_ensure_noises(Worldgen.WORLD_SEED)
	# Vanilla uses raw noise output then clamps; FastNoiseLite returns
	# [-1, 1] which is already similar to vanilla simplex range.
	var temp_raw: float = _temp_noise.get_noise_2d(world_x, world_z)
	var rain_raw: float = _rain_noise.get_noise_2d(world_x, world_z)
	# Vanilla po.java uses *0.15 dampening + 0.7/0.5 baseline + smoothstep,
	# producing output clustered tight in [0.79, 0.98] for temp. That's
	# because vanilla's `ng.java` 4-octave wrapper has reverse-FBM
	# amplitude growth (~4× our FastNoiseLite FBM). Without porting ng.java
	# we'd lose biome variety entirely.
	#
	# Look-and-feel approximation: widen the formula to give vanilla-like
	# biome distribution (Forest ~50%, Shrubland ~30%, Savanna ~10%,
	# small bits of Taiga/Tundra/Desert at extremes). Vanilla biases
	# climate warm/wet (Forest is most common biome). We do the same:
	#   temp = noise * 0.3 + 0.65 → [0.35, 0.95], mean 0.65
	#   rain = noise * 0.3 + 0.5  → [0.20, 0.80], mean 0.50
	# This excludes pure Tundra (temp < 0.1) but allows Savanna+Desert
	# at the dry end and Taiga at the cool wet end. Most cells fall in
	# Forest/Shrubland zones.
	# Port of vanilla po.java:75-101 transform (line numbers in
	# vendor/alpha-1.2.6-src/src/po.java). Matches vanilla's distribution:
	#   extreme = c_noise * 1.1 + 0.5
	#   temp    = (a_noise * 0.15 + 0.7) * (1 - 0.01) + extreme * 0.01
	#   temp    = 1 - (1 - temp)^2
	#   rain    = (b_noise * 0.15 + 0.5) * (1 - 0.002) + extreme * 0.002
	# Vanilla mean: temp ≈ 0.91, rain ≈ 0.5, with narrow variance.
	# Earlier our formula (temp = noise*0.3+0.65) had temp mean 0.65, way
	# colder than vanilla → lower d7 → lower d8 → steeper d11 slope →
	# visible cliffs / 1-block grass towers. The vanilla-faithful
	# transform gives a warm climate with narrow variance, matching
	# vanilla's smooth terrain shape.
	var extreme_raw: float = _extreme_noise.get_noise_2d(world_x, world_z)
	var extreme: float = extreme_raw * 1.1 + 0.5
	var temp: float = (temp_raw * 0.15 + 0.7) * 0.99 + extreme * 0.01
	temp = 1.0 - (1.0 - temp) * (1.0 - temp)
	var rain: float = (rain_raw * 0.15 + 0.5) * 0.998 + extreme * 0.002
	if temp < 0.0:
		temp = 0.0
	if temp > 1.0:
		temp = 1.0
	if rain < 0.0:
		rain = 0.0
	if rain > 1.0:
		rain = 1.0
	return Vector2(temp, rain)


# Decision tree from vanilla gg.java::a(temp, rain) lines 71-104.
# Returns a Biome enum value given (temperature, rainfall_product) where
# rainfall_product = rain × temp (vanilla applies this multiplication).
static func biome_at(world_x: float, world_z: float) -> int:
	_ensure_noises(Worldgen.WORLD_SEED)
	var climate: Vector2 = climate_at(world_x, world_z)
	var temp: float = climate.x
	var rain: float = climate.y * temp  # vanilla: f3 = rain * temp
	# Direct port of gg.java decision tree
	if temp < 0.1:
		return Biome.TUNDRA
	if rain < 0.2:
		if temp < 0.5:
			return Biome.TUNDRA
		if temp < 0.95:
			return Biome.SAVANNA
		return Biome.DESERT
	if rain > 0.5 and temp < 0.7:
		return Biome.SWAMPLAND
	if temp < 0.5:
		return Biome.TAIGA
	if temp < 0.97:
		if rain < 0.35:
			return Biome.SHRUBLAND
		return Biome.FOREST
	if rain < 0.45:
		return Biome.PLAINS
	if rain < 0.9:
		return Biome.SEASONAL_FOREST
	return Biome.RAINFOREST


# Per-biome top block (the surface). Most biomes default to GRASS but
# Desert + Ice Desert use SAND. Vanilla gg.java init at line 47:
# `gg.h.o = gg.h.p = (byte)nq.E.bh` (Desert + Ice Desert top/filler = SAND).
static func biome_top_block(biome_id: int) -> int:
	if biome_id == Biome.DESERT or biome_id == Biome.ICE_DESERT:
		return Blocks.SAND
	return Blocks.GRASS


# Per-biome filler block (3 cells below surface). Same logic as top:
# Desert + Ice Desert use SAND throughout, others use DIRT.
static func biome_filler_block(biome_id: int) -> int:
	if biome_id == Biome.DESERT or biome_id == Biome.ICE_DESERT:
		return Blocks.SAND
	return Blocks.DIRT


# Is this biome cold enough to freeze water surfaces? Used by the surface
# pass to convert WATER_STILL → ICE. Vanilla's "cold" biomes are Tundra,
# Taiga, Ice Desert (anything with temp < ~0.15).
static func biome_is_cold(biome_id: int) -> bool:
	return biome_id == Biome.TUNDRA or biome_id == Biome.TAIGA or biome_id == Biome.ICE_DESERT


# Per-biome tree density multiplier on Worldgen's base 1..4 trees/chunk
# attempt count. Vanilla LEAVES baseline (per
# .claude/vanilla-alpha-real-baselines.md, measured across 1521 chunks
# of two real worlds) is **56 leaves/chunk** averaged across all
# biomes, ~33 leaves per oak → ~1.7 oaks/chunk overall mean. Most
# chunks are sparse-biome; dense-biome chunks compensate. Tuned so
# the cross-biome mean lands near vanilla's ~1.7 oaks/chunk.
static func biome_tree_density(biome_id: int) -> float:
	match biome_id:
		Biome.RAINFOREST:
			return 3.0  # densest, ~7 oaks
		Biome.FOREST:
			return 2.0  # ~5 oaks
		Biome.SEASONAL_FOREST:
			return 1.5
		Biome.TAIGA:
			return 1.2  # snowy forest, moderate
		Biome.SWAMPLAND:
			return 1.0
		Biome.SHRUBLAND:
			return 0.7
		Biome.SAVANNA:
			return 0.4  # mostly grass, sparse trees
		Biome.PLAINS:
			return 0.4  # vanilla plains has occasional trees
		Biome.TUNDRA:
			return 0.2  # very sparse
		Biome.DESERT, Biome.ICE_DESERT:
			return 0.0  # no trees
		_:
			return 1.0


# Reset noise cache — call after Worldgen.apply_world_seed for correctness.
static func reset() -> void:
	_e_noise = null
	_f_noise = null
	_selector_noise = null
	_beach_noise = null
	_soil_noise = null
	_amplitude_noise = null
	_depth_noise = null
	_forest_noise = null
	_temp_noise = null
	_rain_noise = null
	_extreme_noise = null


# Build the 5×17×5 coarse density grid for a chunk. Direct port of
# px.java:181-260. Output array is indexed (x*GRID_Y + y)*GRID_Z + z to
# match vanilla's layout for the trilerp consumer.
#
# Climate is constant=0.5 in Phase 3 — no biome modulation yet (Phase 4).
static func density_grid(chunk_x: int, chunk_z: int) -> PackedFloat64Array:
	_ensure_noises(Worldgen.WORLD_SEED)
	var out: PackedFloat64Array = PackedFloat64Array()
	out.resize(GRID_X * GRID_Y * GRID_Z)

	# Vanilla noise grid base coords: chunk_x * COARSE_STEP_X (= chunk_x * 4)
	var noise_base_x: int = chunk_x * COARSE_STEP_X
	var noise_base_y: int = 0
	var noise_base_z: int = chunk_z * COARSE_STEP_Z

	# Sample 2D noises (g amplitude, h depth) per (x, z) coarse column.
	# CRITICAL: vanilla nf.a's 8-arg wrapper (px.java:189-190) calls the
	# 10-arg bulk-grid version with HARDCODED base_y=10.0 and scale_y=1.0.
	# That means each octave samples at world Y = 10 * amp + offset_y, not
	# Y = 0. Calling sample_2d (which delegates to sample_3d at Y=0)
	# samples at the wrong Y → produces a completely different output
	# distribution than vanilla. Symptom: depth noise mean ~2k vs vanilla
	# ~10k → terrain forced into 'ocean' branch → mean surface y ~60 vs
	# vanilla y ~85 at the same seed/chunk.
	#
	# Use sample_3d_grid with size_y=1 to replicate vanilla's bulk-grid
	# sampling exactly. Layout for size_y=1 collapses to (ix * GRID_Z + iz),
	# matching the existing g_grid[ix * GRID_Z + iz] index.
	var g_grid: PackedFloat64Array = PackedFloat64Array()
	var h_grid: PackedFloat64Array = PackedFloat64Array()
	g_grid.resize(GRID_X * GRID_Z)
	h_grid.resize(GRID_X * GRID_Z)
	_amplitude_noise.sample_3d_grid(
		g_grid,
		float(noise_base_x),
		10.0,
		float(noise_base_z),
		GRID_X,
		1,
		GRID_Z,
		AMPLITUDE_SCALE,
		1.0,
		AMPLITUDE_SCALE
	)
	_depth_noise.sample_3d_grid(
		h_grid,
		float(noise_base_x),
		10.0,
		float(noise_base_z),
		GRID_X,
		1,
		GRID_Z,
		DEPTH_SCALE,
		1.0,
		DEPTH_SCALE
	)

	# Sample 3D density grids (e, f, selector). 5×17×5 = 425 samples
	# each. Use bulk sample_3d_grid for performance.
	var e_grid: PackedFloat64Array = PackedFloat64Array()
	var f_grid: PackedFloat64Array = PackedFloat64Array()
	var d_grid: PackedFloat64Array = PackedFloat64Array()
	e_grid.resize(GRID_X * GRID_Y * GRID_Z)
	f_grid.resize(GRID_X * GRID_Y * GRID_Z)
	d_grid.resize(GRID_X * GRID_Y * GRID_Z)
	_e_noise.sample_3d_grid(
		e_grid,
		float(noise_base_x),
		float(noise_base_y),
		float(noise_base_z),
		GRID_X,
		GRID_Y,
		GRID_Z,
		COORDINATE_SCALE,
		HEIGHT_SCALE,
		COORDINATE_SCALE
	)
	_f_noise.sample_3d_grid(
		f_grid,
		float(noise_base_x),
		float(noise_base_y),
		float(noise_base_z),
		GRID_X,
		GRID_Y,
		GRID_Z,
		COORDINATE_SCALE,
		HEIGHT_SCALE,
		COORDINATE_SCALE
	)
	_selector_noise.sample_3d_grid(
		d_grid,
		float(noise_base_x),
		float(noise_base_y),
		float(noise_base_z),
		GRID_X,
		GRID_Y,
		GRID_Z,
		SELECTOR_SCALE_XZ,
		SELECTOR_SCALE_Y,
		SELECTOR_SCALE_XZ
	)

	# Per coarse column: compute d4 (depth) and d8 (amplitude).
	# Then per coarse Y cell: blend e/f by selector, subtract Y-bias.
	var n6: int = GRID_Y  # = 17
	var density_idx: int = 0  # iterates x,y,z in vanilla order
	var column_idx: int = 0  # iterates 2D x,z

	# Vanilla samples climate at the CENTER of each coarse cell (px.java:198-202):
	#   n10 = 16 / GRID_X = 3 (integer)
	#   n11 = i2 * 3 + 1 = {1, 4, 7, 10, 13}
	# Vanilla's noise distribution makes climate ~constant across one chunk,
	# so per-coarse-column sampling produces ~constant d8 → smooth terrain.
	# Our FastNoiseLite Simplex distribution varies more per cell, producing
	# d8 swings of 0.1+ within one chunk → cliff-shaped trilerp output that
	# the user reported as 'duplicated grass towers / single-block towers'.
	# Fix: sample climate ONCE per chunk at chunk center, apply uniformly.
	# This deviates from vanilla's per-coarse-cell sampling but matches
	# vanilla's effective per-chunk-uniform climate distribution.
	var chunk_center_x: float = float(chunk_x * 16 + 8)
	var chunk_center_z: float = float(chunk_z * 16 + 8)
	var climate: Vector2 = climate_at(chunk_center_x, chunk_center_z)
	var d5_chunk: float = climate.x  # temperature
	var d6_chunk: float = climate.y * d5_chunk  # rain × temp (px.java:202)
	var d7_chunk: float = 1.0 - d6_chunk
	d7_chunk *= d7_chunk
	d7_chunk *= d7_chunk
	d7_chunk = 1.0 - d7_chunk  # = 1 - (1 - temp×rain)^4

	for ix in range(GRID_X):
		for iz in range(GRID_Z):
			var d7: float = d7_chunk

			# d8 — amplitude (px.java:208-211)
			var d8: float = (g_grid[column_idx] + AMPLITUDE_OFFSET) / AMPLITUDE_DIVISOR
			d8 *= d7
			if d8 > 1.0:
				d8 = 1.0

			# d4 — depth chain (px.java:212-227)
			var d4: float = h_grid[column_idx] / DEPTH_DIVISOR
			if d4 < 0.0:
				d4 = -d4 * 0.3
			d4 = d4 * 3.0 - 2.0
			if d4 < 0.0:
				d4 = d4 / 2.0
				if d4 < -1.0:
					d4 = -1.0
				d4 = d4 / 1.4
				d4 = d4 / 2.0
				d8 = 0.0  # force amplitude to 0 in deep ocean
			else:
				if d4 > 1.0:
					d4 = 1.0
				d4 = d4 / 8.0

			if d8 < 0.0:
				d8 = 0.0
			d8 += 0.5

			d4 = d4 * float(n6) / 16.0
			var d9: float = float(n6) / 2.0 + d4 * 4.0  # baseline depth in coarse-Y

			# Per Y cell (px.java:235-258)
			for iy in range(n6):
				var d11: float = (float(iy) - d9) * 12.0 / d8
				if d11 < 0.0:
					d11 *= 4.0  # 4× stronger pull-down below depth

				var d12: float = e_grid[density_idx] / DENSITY_DIVISOR
				var d13: float = f_grid[density_idx] / DENSITY_DIVISOR
				var d14: float = (d_grid[density_idx] / SELECTOR_DIVISOR + 1.0) / 2.0

				var d10: float
				if d14 < 0.0:
					d10 = d12
				elif d14 > 1.0:
					d10 = d13
				else:
					d10 = d12 + (d13 - d12) * d14

				d10 -= d11

				# Top taper (px.java:228-231): force toward -10 at top 4 cells
				if iy > n6 - 4:
					var d15: float = float(iy - (n6 - 4)) / 3.0
					d10 = d10 * (1.0 - d15) + -10.0 * d15

				# Vanilla layout: out[(ix * n7 + iy) * n8 + iz] where n7=17, n8=5
				out[(ix * GRID_Y + iy) * GRID_Z + iz] = d10
				density_idx += 1

			column_idx += 1
	return out


# Trilerp the 5×17×5 coarse density grid into 16×128×16 chunk cells.
# Per cell: density > 0 → STONE, else → AIR (water fill is a separate
# pass in worldgen.gd::_fill_ocean).
#
# Direct port of px.java:46-99 (`a(int n2, int n3, byte[] byArray, ...)`).
static func fill_chunk(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var grid: PackedFloat64Array = density_grid(chunk_x, chunk_z)
	# n4=4 horizontal coarse step, n5=64 sea level (unused in this fn —
	# we only do stone/air; ocean fill is separate).
	# Trilerp loop nesting (px.java:55-95):
	#   i2 in 0..3 (X coarse cells), i3 in 0..3 (Z coarse cells)
	#     i4 in 0..15 (Y coarse cells, 16 segments between 17 grid lines)
	#       i5 in 0..7 (Y subdivisions, 16/2 = 8 sub-cells per coarse Y)
	#         i6 in 0..3 (X sub), i7 in 0..3 (Z sub)
	# Total: 4 × 4 × 16 × 8 × 4 × 4 = 32768 cells = chunk volume ✓
	for i2 in range(4):
		for i3 in range(4):
			for i4 in range(16):
				# 8 corners of the (i2, i3, i4) coarse cell
				var d3: float = grid[((i2 + 0) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 0)]
				var d4: float = grid[((i2 + 0) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 1)]
				var d5: float = grid[((i2 + 1) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 0)]
				var d6: float = grid[((i2 + 1) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 1)]
				# Y interpolation step (1/8 because 8 sub-cells per coarse Y)
				var d7: float = (
					(grid[((i2 + 0) * GRID_Y + (i4 + 1)) * GRID_Z + (i3 + 0)] - d3) * 0.125
				)
				var d8: float = (
					(grid[((i2 + 0) * GRID_Y + (i4 + 1)) * GRID_Z + (i3 + 1)] - d4) * 0.125
				)
				# **CRITICAL BUG FIX 2026-05-12**: d9 was using (i4 + 0) instead
				# of (i4 + 1), which made d9 = (d5 - d5) * 0.125 = 0 always.
				# That zero'd the Y-step at the X+1 edge of every coarse cell,
				# so terrain at i6=3 stayed constant across all i5 instead of
				# interpolating Y. Result: visible sawtooth pattern where
				# surface dropped 3-5 cells at each coarse-cell boundary
				# (the user's 'duplicated grass towers').
				var d9: float = (
					(grid[((i2 + 1) * GRID_Y + (i4 + 1)) * GRID_Z + (i3 + 0)] - d5) * 0.125
				)
				var d10: float = (
					(grid[((i2 + 1) * GRID_Y + (i4 + 1)) * GRID_Z + (i3 + 1)] - d6) * 0.125
				)

				for i5 in range(8):
					var d12: float = d3
					var d13: float = d4
					# X interpolation step (1/4 because 4 sub-cells per coarse X)
					var d14: float = (d5 - d3) * 0.25
					var d15: float = (d6 - d4) * 0.25

					for i6 in range(4):
						var d17: float = d12
						# Z interpolation step (1/4)
						var d18: float = (d13 - d12) * 0.25

						for i7 in range(4):
							# Final density at (i2*4+i6, i4*8+i5, i3*4+i7) in chunk
							var density: float = d17
							var local_x: int = i2 * 4 + i6
							var local_y: int = i4 * 8 + i5
							var local_z: int = i3 * 4 + i7
							if density > 0.0:
								chunk.set_block_unchecked(local_x, local_y, local_z, Blocks.STONE)
							elif local_y < SEA_LEVEL:
								# Vanilla px.java:78-86: cells with negative
								# density (would be air) at y < sea_level
								# become WATER. This handles overhangs and
								# isolated air pockets that the column-based
								# _fill_ocean pass misses.
								chunk.set_block_unchecked(
									local_x, local_y, local_z, Blocks.WATER_STILL
								)
							# else: leave as AIR (chunk init is zeroed)
							d17 += d18

						d12 += d14
						d13 += d15

					d3 += d7
					d4 += d8
					d5 += d9
					d6 += d10

	# Update max_y from the topmost stone cell. Walk top-down across the
	# chunk to find it.
	var max_y: int = 0
	for x in range(16):
		for z in range(16):
			for y in range(127, -1, -1):
				if chunk.get_block_unchecked(x, y, z) != Blocks.AIR:
					if y > max_y:
						max_y = y
					break
	chunk.max_y = max_y
