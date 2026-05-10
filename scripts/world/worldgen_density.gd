class_name WorldgenDensity
extends RefCounted

# 3D density-field terrain generator. Algorithmic equivalent to vanilla
# Alpha 1.2.6's `px.java`'s density pipeline (slices 3-B + 3-C).
#
# Vanilla pipeline (`px.java:181-260`):
#   1. Sample a 5×17×5 coarse density grid via reverse-FBM noise:
#      * Primary density `e` (16-octave reverse-FBM, vanilla `this.k`)
#      * Secondary density `f` (16-octave, vanilla `this.l`, blended)
#      * Selector `d` (8-octave 3D, vanilla `this.m`, blends e/f)
#      * Amplitude modulator `g` (10-octave 2D, vanilla `this.a`, scales bias)
#      * Terrain modifier `h` (16-octave 2D, vanilla `this.b`, target_y shift)
#   2. Per cell: blend = lerp(e/512, f/512, clamp((d/10+1)/2, 0, 1))
#   3. Per cell: density = blend - y_bias_with_modifiers(world_y)
#   4. Trilerp the grid to fill 16×128×16 cell densities.
#   5. For each cell: density > 0 → stone; else → air.
#   6. Top-4-row taper forces air at the world ceiling.
#
# Our port matches vanilla's RECIPE (same noise count, same blend, same
# normalization, same Y-bias asymmetry, same trilerp + threshold). NOT
# byte-identical to vanilla at the same seed — would require a Java
# Random + z.java Perlin port (see worldgen-deferred.md "byte-identical"
# section for the deferred decision).
#
# Substitutions for our biome-less world:
#   * Skip vanilla's biome-modulated d6/d7 multiplier on d8 (we have
#     no biomes); use d8 directly.
#   * Use a single 2D Perlin (not multi-octave) for the elevation
#     modifier, since we don't need vanilla's biome-driven shape
#     variation. Tunable via ELEVATION_AMPLITUDE.
#
# Faithfulness vs perf:
#   * Vanilla's COARSE-GRID + TRILERP architecture (425 noise samples
#     per chunk, not 32K). This is what makes 3D density tractable.
#   * 16-octave reverse-FBM via `NoiseOctaves` (see
#     scripts/world/noise_octaves.gd).
#   * Native C++ port lands in slice 3-A2/3-B2 once GDScript reference
#     proves out — until then, GDScript-only path. Per-chunk cost in
#     GDScript is ~5-10 ms with the full noise stack (3 grid samples +
#     2 column samples), acceptable on the worker thread.

# Coarse grid dimensions. Vanilla uses 5×17×5 (4-cell horizontal spacing
# × 8-cell vertical spacing across a 16×128×16 chunk). +1 in each
# direction so the trilerp has both endpoints; the loop iterates n4=4
# times (= GRID_X - 1), filling the 16 cells between corners.
const GRID_X: int = 5
const GRID_Y: int = 17
const GRID_Z: int = 5
const COARSE_STEP_X: int = 4  # = SIZE_X / (GRID_X - 1)
const COARSE_STEP_Y: int = 8  # = SIZE_Y / (GRID_Y - 1)
const COARSE_STEP_Z: int = 4  # = SIZE_Z / (GRID_Z - 1)

# Noise octave count for the density field. Matches vanilla's 16 (vanilla
# `px.java:42` `this.b = new nf(this.j, 16)` for the main density). With
# reverse-FBM, the dominant (last) octave has amplitude 2^15 = 32768 so
# raw output spans roughly ±32768. We normalize by NOISE_NORMALIZER below
# (matching vanilla's `e[n8] / 512.0` at `px.java:233`) to bring values
# back into a workable ±64 range that the Y-bias factors can dominate.
const NOISE_OCTAVES: int = 16
# Vanilla `px.java:233-234` divides density-noise output by 512 before
# threshold testing. With 16-octave reverse-FBM (max amplitude ~32768),
# this brings practical density values into ~±64 — comparable to our
# previous 8-octave non-normalized range, so existing Y-bias factors
# stay tuned without drastic recalibration.
const NOISE_NORMALIZER: float = 512.0  # vanilla px.java:233 — /512

# Density-noise spatial scale. Tuning history:
#   * 0.0625 → dominant octave wavelength ~2000 blocks. WAY too coarse:
#     within a 16-block chunk the noise barely changes → flat terrain.
#   * 0.25 → dominant octave wavelength ~500 blocks (chunk-visible
#     variation), smaller octaves at sub-cell scale (washed out by
#     trilerp). Continents at the dominant scale, hills at mid scales.
#
# Per-octave wavelength in our reverse-FBM scheme:
#   octave i: wavelength = 1 / (SCALE_XZ * 2^-i) = 2^i / SCALE_XZ
#   With SCALE_XZ=0.25: oct 0=4, oct 3=32, oct 5=128, oct 7=512 blocks.
const SCALE_XZ: float = 0.25
# Y scale half of XZ — vanilla pattern (m-noise uses d2/80 for XZ vs
# d3/160 for Y). Smoother overhangs since vertical noise wavelength is
# longer than horizontal — terrain doesn't get jagged column-by-column.
const SCALE_Y: float = 0.125

# Y-bias parameters. Final density = noise - y_bias(y). Stone if > 0.
#
# y_bias is a piecewise-linear function:
#   * Below TARGET_Y: y_bias is NEGATIVE (subtracts negative = adds
#     positive density → encourages stone). Strong at y=0, fades to 0
#     at TARGET_Y.
#   * Above TARGET_Y: y_bias is POSITIVE (subtracts positive = subtracts
#     density → encourages air). Strong at y=SIZE_Y, fades to 0 at
#     TARGET_Y.
#
# TARGET_Y is the "average ground level" — densities crest 0 here on
# average, so the surface clusters around it. Vanilla clusters ground a
# couple cells above sea level (target_y ≈ 68 with sea_level=64).
#
# Vanilla asymmetry (px.java:237-240):
#   d11 = (i4 - d9) * 12.0 / d8   // d11 in coarse-grid Y units
#   if (d11 < 0.0) d11 *= 4.0     // BELOW target: 4× stronger
# Per WORLD-cell slope (each coarse-Y = 8 world cells, d8 ∈ [0.5, 1.5]):
#   * Below target (stone): 12 * 4 / 8 / d8 = 6/d8 → range [4.0, 12.0] per cell
#   * Above target (air):   12 / 8 / d8     = 1.5/d8 → range [1.0, 3.0] per cell
# So vanilla stone-slope is ~4× stronger than air-slope. Keeps the GROUND
# solid (no floating air pockets near bedrock) but lets MOUNTAINS reach
# tall (gentler air slope means peaks can rise 20+ cells above target).
#
# Tuning history note: pre-2026-05-07 we had STONE=1.5 / AIR=4.0 — exact
# OPPOSITE of vanilla. The "AIR larger because vanilla *= 4" comment that
# was here was sign-confused (the *= 4 multiplies the ALREADY-NEGATIVE d11,
# so it amplifies the STONE branch, not air). The inversion meant surface
# was loosely clustered around target_y (no tight stone-floor pin), which
# manifested as 1-cell-wide beaches: surface jumps through the [60, 65]
# beach band in a single horizontal step instead of lingering 5+ cells.
# TARGET_Y is the "average ground level" — but this is BASE target.
# A per-column elevation modulator (see ELEVATION_* constants below)
# shifts the effective target up to ±ELEVATION_AMPLITUDE per region,
# producing mountainous + oceanic biomes naturally without a biome
# system. Without the modulator, all columns share one target and the
# surface clusters tightly around it (the "flat terrain" symptom).
#
# Target_y is the per-column ground baseline. With the vanilla d4
# elevation modifier (see _apply_d4_modifier), the per-column offset is
# ASYMMETRIC: ocean regions can shift target_y down by up to 32 cells,
# mountain regions shift up by 4 cells. So TARGET_Y is the "land mean"
# (slightly above sea level), and oceans naturally pull target_y deep
# without affecting the land baseline.
#
# Vanilla equivalent: d9_world = 68 + d4*32, where d4 ∈ [-1, 0.125]
# after asymmetric scaling. Land columns cluster at d4 ≈ 0 → target ≈
# TARGET_Y; ocean columns at d4 ≈ -1 → target ≈ TARGET_Y - 32.
#
# Tuning history:
#   * TARGET_Y=68/symmetric AMP=40 → surface min 47, ponds not oceans
#   * TARGET_Y=66/symmetric AMP=55 → surface min 38, but above-sea 50%
#     (too oceanic)
#   * TARGET_Y=68/d4 modifier → asymmetric: above-sea ~60%, ocean min
#     ~32 (proper deep oceans + vanilla land balance)
# 2 above sea — d4 lifts land target_y to ~70, dips oceans to ~55.
# Balances above-sea ratio toward vanilla 60% without losing ocean depth.
const TARGET_Y: int = 66

# Vanilla `h` noise (px.java:190) — 16-octave reverse-FBM at scale 200.
# This is what feeds the d4 modifier. Switching from single-octave Perlin
# to this match was the key to getting vanilla-shape distributions —
# vanilla's d4 coefficients were tuned for THIS noise's variance shape,
# not the smooth Perlin we had before.
const ELEVATION_NOISE_OCTAVES: int = 16
const ELEVATION_NOISE_FREQUENCY: float = 1.0 / 400.0  # 400-block features
# Our NoiseOctaves.sample_2d already produces output in vanilla's
# post-/8000 range (~±4) directly — no extra normalization needed.
# Vanilla samples a flat 16-octave reverse-FBM that returns raw output
# ±32k, then divides by 8000. Our wrapper normalizes per-octave so the
# net output is already in vanilla's d4-input range. Empirically
# verified: noise output for 400 samples spans [-4.5, +4.1] with mean
# ~0.2, exactly matching vanilla's expected d4 input distribution.
const ELEVATION_NOISE_NORMALIZER: float = 1.0
# When vanilla noise is enabled, raw output is much larger (~±5000-10000
# vs FastNoiseLite's ~±4). Vanilla's d4 expects /8000 to bring `h` into
# the [-4, 4] range its formula was designed for.
# Tuning: transitions abruptly from "all land" (/1000) to "all ocean"
# (/2000) — vanilla d4's threshold-jump character + the LAND_BIAS=1.0
# tuned for FastNoiseLite. Default to /1500 as a starting mid-point;
# expect to keep iterating LAND_BIAS in vanilla-noise mode separately.
const ELEVATION_NOISE_NORMALIZER_VANILLA: float = 1500.0

# Per-seed LAND BIAS — shifts the d4 input distribution toward the
# mountain branch so most seeds produce playable land/ocean mixes
# instead of all-ocean or all-land worlds. With 16-octave noise the
# dominant low-freq octave dominates per-seed (it's effectively a
# constant tilt across our 5000-block audit region), so without this
# bias seeds where that octave lands negative produce 99% ocean and
# seeds where it lands positive produce 99% land. Value 0.7 lifts
# mountain-branch coverage from ~26% baseline to ~55-60% on average,
# matching vanilla's audit and giving the user-visible win of
# "land somewhere near spawn, every time."
# Vanilla d4 chain compresses both branches heavily (ocean max -11.4,
# mountain max +4 cells), so without bias most columns hover near 0
# offset → 25% above sea (way oceanic). LAND_BIAS=1.0 pushes the
# distribution toward the mountain branch enough to land near vanilla
# 60% above sea. Tuned with d4 chain restored to vanilla.
const ELEVATION_LAND_BIAS: float = 1.0

# Amplitude modulator (vanilla `px.java:200` `d8` from `this.g` noise) —
# port slice 3-B option B. A separate 2D noise sampled per coarse column
# scales the Y-bias strength: regions with high `d8` have GENTLE bias
# (= wider surface variance = mountains), regions with low `d8` have
# STEEP bias (= tight surface = flat plains). Without this, every column
# has the same surface tightness and you get uniform terrain.
#
# Vanilla normalizes g-noise output to [0, 1] then adds 0.5 → [0.5, 1.5].
# Used as DIVISOR on Y-bias: bias_per_cell / d8.
# We mirror: 6-octave reverse-FBM, per-column sample, output [0.5, 1.5].
const AMPLITUDE_NOISE_OCTAVES: int = 6
# 0.005 ≈ vanilla's 1.121-scale-on-tiny-inputs effective wavelength.
# Per-region (~200 block) variation in surface tightness.
const AMPLITUDE_NOISE_FREQUENCY: float = 0.005
# 6-octave reverse-FBM max amplitude = 1+2+4+8+16+32 = 63. Divide raw
# output by this to normalize to ~±1, then map to [0.5, 1.5].
const AMPLITUDE_NOISE_NORMALIZER: float = 64.0

# Selector noise (vanilla `px.java:200` `d` from `this.m`) — port slice
# 3-C. A 3D noise that blends between TWO density variants per cell:
# primary (`e`) and secondary (`f`). Vanilla formula (px.java:235-238):
#   d14 = (selector / 10 + 1) / 2     // map to ~[0, 1]
#   d10 = clamp(d14, 0, 1) interpolation between d12 (primary) and d13 (secondary)
# In effect: selector < -10 → use primary; > +10 → use secondary;
# in between → blend. Outside the [-10, +10] band it's a hard switch.
# Adds 3D variation beyond what the modifiers achieve — terrain
# "character" can flip between two noise layouts per region.
const SELECTOR_NOISE_OCTAVES: int = 8
# Vanilla `px.java:188` selector samples at d2/80 (= 8.55 in our terms).
# Our SCALE_XZ=0.25 / 80 doesn't translate directly because vanilla's
# scale composition is different — practical equivalent: a noise at
# half the density frequency, so selector wavelength ≈ 2× density.
const SELECTOR_SCALE_XZ: float = 0.125
# Vanilla uses HALF the Y scale for selector (d3/160 vs d3/80) — same
# half-Y-scale rule as the density's Y vs XZ.
const SELECTOR_SCALE_Y: float = 0.0625
# 8-octave reverse-FBM max amplitude = 255. Vanilla divides selector
# by 10 in the formula so we want our values in similar magnitude
# ([-10, 10] is the meaningful transition range). Normalizing by
# (max/10) = ~25 brings raw output into the right order of magnitude.
const SELECTOR_NORMALIZER: float = 25.0
# Symmetric tight bias on BOTH sides of target_y. Vanilla uses asymmetric
# (4:1 stone:air ratio) which gives mountains noise variance to look
# craggy — but in our world without vanilla's multi-noise stack, that
# weak air bias means LAND COLUMNS jitter ±20 cells from target_y in
# noise lows, scattering "ocean-y" columns mid-land and producing 1-cell
# beach strips even when audit shows 25% beach band coverage.
# Symmetric STONE=AIR=6 caps surface variance to ~5 cells either way,
# giving cohesive land surfaces and contiguous coastline transitions.
# Trade: less mountain craggy variance (peaks are smoother).
const STONE_BIAS_FACTOR: float = 6.0  # density-units per Y-cell BELOW target
const AIR_BIAS_FACTOR: float = 6.0  # density-units per Y-cell ABOVE target

# Top-of-world taper. The TOP_TAPER_CELLS topmost layers force air no
# matter what the noise says — keeps the world ceiling flat (otherwise
# tall density peaks could spike to y=128 producing weird sliver
# columns). Vanilla applies `d10 = d10 * (1-d15) + -10 * d15` over the
# top 4 cells (px.java:228-231). Same approach.
const TOP_TAPER_CELLS: int = 4
const TOP_TAPER_FORCE_AIR: float = -10.0

const _SIZE_X: int = 16  # = Chunk.SIZE_X
const _SIZE_Y: int = 128  # = Chunk.SIZE_Y
const _SIZE_Z: int = 16  # = Chunk.SIZE_Z

# Cached density noise generator. Built once per session via
# get_density_noise() — re-init only on apply_world_seed.
# When true, all NoiseOctaves singletons are created via the vanilla
# `nf.java` pattern (NoisePerlin per octave, sharing one JavaRandom)
# instead of the FastNoiseLite-based default. Vanilla noise has wider
# variance + correlated octaves, producing terrain shapes closer to
# Alpha. Toggled via MC_CLONE_VANILLA_NOISE env var (game.gd reads it).
static var vanilla_noise_enabled: bool = false

static var _density_noise: NoiseOctaves
# Secondary density noise (vanilla `f`) — same parameters as primary,
# different seed. Selector noise blends between the two per cell,
# producing 3D variance beyond what the per-column modulators achieve.
static var _density_noise_2: NoiseOctaves
# Elevation modulator — vanilla `h` noise (px.java:190 — `this.b = new
# nf(this.j, 16)` sampled at scale 200). 16-octave reverse-FBM gives
# the dominant low-frequency variance vanilla's d4 modifier was tuned
# for; switching from single-octave Perlin to this is what unlocked
# vanilla's exact d4 chain producing vanilla-shape distributions.
static var _elevation_noise: NoiseOctaves
# Amplitude modulator — see AMPLITUDE_* constants. 6-octave reverse-FBM
# 2D noise sampled per coarse column. Scales the Y-bias strength: some
# regions get tight surface (plains), others get loose (mountains).
static var _amplitude_noise: NoiseOctaves
# Selector noise (vanilla `d` / `m`) — 3D noise that blends primary and
# secondary density per cell.
static var _selector_noise: NoiseOctaves


# Reset on seed change. Worldgen.apply_world_seed() calls this so the
# next density sample uses the new seed.
# Pre-create every NoiseOctaves singleton on the main thread. Worker
# threads can't call FastNoiseLite.new() (it triggers a /root notification
# Godot 4 forbids on non-main threads), so the worldgen worker would
# crash on the first chunk if any of these were still null. Game._ready
# calls this when 3D density mode is active.
static func warm_main_thread() -> void:
	_get_density_noise()
	_get_density_noise_2()
	_get_selector_noise()
	_get_amplitude_noise()
	_get_elevation_noise()


static func reset() -> void:
	_density_noise = null
	_density_noise_2 = null
	_elevation_noise = null
	_amplitude_noise = null
	_selector_noise = null


# Lazy-initialize the density noise. Seed offset of +101 to avoid
# correlation with the heightmap noise (which uses base_seed and
# base_seed+1 for detail/continental respectively).
static func _get_density_noise() -> NoiseOctaves:
	if _density_noise == null:
		_density_noise = _make_noise(Worldgen.WORLD_SEED + 101, NOISE_OCTAVES)
	return _density_noise


# Estimated target_y for a column at (world_x, world_z) WITHOUT
# generating the chunk. Uses just the elevation modifier (cheap single
# noise sample). Used by Worldgen's cross-chunk water-adjacency check
# in the beach pass — we need to know if a neighbor in another (not-
# yet-loaded) chunk will be ocean. The 2D heightmap was wrong for this
# in 3D mode (different surface shape entirely); this estimate matches
# the actual 3D logic since per-column target_y dominates the surface
# placement.
#
# NOT exact — actual surface is target_y ± noise_variance — but precise
# enough for the binary "will this be below sea level?" check. Skips
# the per-cell density noise + selector blend (expensive) since those
# only add ~±10 cells of variance around target_y.
static func estimate_target_y(world_x: int, world_z: int) -> float:
	var elev_noise := _get_elevation_noise()
	# Vanilla samples `h` at world_x/200, world_z/200 (px.java:190).
	var raw_h: float = (
		elev_noise
		. sample_2d(
			float(world_x) * ELEVATION_NOISE_FREQUENCY,
			float(world_z) * ELEVATION_NOISE_FREQUENCY,
		)
	)
	# Vanilla d4 = h / 8000; we use ELEVATION_NOISE_NORMALIZER for our scale.
	var d4: Dictionary = _apply_d4_modifier(raw_h / _elevation_normalizer())
	return float(TARGET_Y) + d4["target_y_offset"]


# Asymmetric elevation modifier — same SPIRIT as vanilla `d4`
# (px.java:212-227) but with the formula adapted to our single-octave
# Perlin elevation noise (vanilla uses 16-octave reverse-FBM, very
# different distribution shape). Goal:
#
#   * 60% of columns above sea level (vanilla baseline)
#   * Deep ocean basins reaching y~32 (vanilla baseline)
#   * Modest mountains around y~80
#   * Force tight amplitude in ocean regions (vanilla `d8 = 0.0`)
#     so ocean surfaces cluster near target_y for proper basin shape
#
# Implementation: bias the +/- threshold toward the positive side so
# more columns land in the mountain branch. Asymmetric scale: mountain
# branch shifts by [0, +12] (modest peaks), ocean branch by [0, -32]
# (deep basins). The +0.2 offset on h_perlin matches vanilla's bias
# toward "mostly land with rare ocean" distribution.
#
# Returns:
#   target_y_offset: float in [-32, +12] world cells, relative to TARGET_Y
#   force_tight: bool — if true, column's amplitude (d8) becomes 0.5.
static func _apply_d4_modifier(h_normalized: float) -> Dictionary:
	# Exact vanilla `d4` modifier port from px.java:212-227.
	# Input: `h_normalized` is the reverse-FBM elevation noise sample
	# divided by ELEVATION_NOISE_NORMALIZER (matches vanilla's /8000).
	# Output: target_y_offset in WORLD cells + force_tight flag for amp.
	#
	# Vanilla source:
	#   if ((d4 = h / 8000.0) < 0.0)         d4 = -d4 * 0.3
	#   if ((d4 = d4 * 3.0 - 2.0) < 0.0)
	#       d4 /= 2.0; if (d4 < -1.0) d4 = -1.0; d4 /= 1.4; d4 /= 2.0
	#       d8 = 0.0  # force tight amplitude
	#   else
	#       if (d4 > 1.0) d4 = 1.0; d4 /= 8.0
	#   d9 = n6/2 + d4 * 4    (coarse-Y; n6=17, COARSE_Y=8)
	# Per WORLD-Y: world_target_y_offset = d4 * 32.
	#
	# Tuning history: we tried a smooth piecewise variant (mountain
	# h*4 / ocean h*8 with no threshold jump) hoping to fix the
	# 1-cell-beach issue. Net effect was different artifacts, not
	# improvement — vanilla's chain is the actual reference behavior
	# even if it has its own sharp-coastline character. Restored to
	# match vanilla exactly so biome layer (next) can be evaluated
	# against the real Alpha terrain shape.
	var d4: float = h_normalized + ELEVATION_LAND_BIAS
	if d4 < 0.0:
		d4 = -d4 * 0.3
	d4 = d4 * 3.0 - 2.0
	var force_tight: bool = false
	if d4 < 0.0:
		d4 /= 2.0
		d4 = maxf(d4, -1.0)
		d4 /= 1.4
		d4 /= 2.0
		force_tight = true
	else:
		d4 = minf(d4, 1.0) / 8.0
	return {"target_y_offset": d4 * 32.0, "force_tight": force_tight}


# Secondary density noise (vanilla `f`). Same parameters as primary,
# different seed offset (+102) so the two are independent.
static func _get_density_noise_2() -> NoiseOctaves:
	if _density_noise_2 == null:
		_density_noise_2 = _make_noise(Worldgen.WORLD_SEED + 102, NOISE_OCTAVES)
	return _density_noise_2


# Selector noise (vanilla `d` / `m`). 3D, fewer octaves, smaller scale.
# Seed offset +109 to stay independent of primary (+101), secondary
# (+102), elevation (+103), amplitude (+107).
static func _get_selector_noise() -> NoiseOctaves:
	if _selector_noise == null:
		_selector_noise = _make_noise(Worldgen.WORLD_SEED + 109, SELECTOR_NOISE_OCTAVES)
	return _selector_noise


# Per-column amplitude modulator (vanilla `d8`). Multi-octave reverse-FBM
# so the per-region scale variation has Alpha-style continental-then-
# detail layering. Seed offset +107 to stay independent of density (+101),
# heightmap (+0, +1, +2), and elevation (+103) noises.
static func _get_amplitude_noise() -> NoiseOctaves:
	if _amplitude_noise == null:
		_amplitude_noise = _make_noise(Worldgen.WORLD_SEED + 107, AMPLITUDE_NOISE_OCTAVES)
	return _amplitude_noise


# Noise factory — dispatches to vanilla NoisePerlin path or FastNoiseLite
# default based on `vanilla_noise_enabled`. All five worldgen noises route
# through this so flipping the flag affects the entire density pipeline.
static func _make_noise(seed: int, octaves: int) -> NoiseOctaves:
	if vanilla_noise_enabled:
		return NoiseOctaves.create_vanilla(seed, octaves)
	return NoiseOctaves.create(seed, octaves)


# Pick the right elevation normalizer based on noise mode. Vanilla noise
# output is ~thousands of units (16-octave reverse-FBM) so divide by
# ~1500 to bring into d4's expected ±4 input range. FastNoiseLite mode
# already produces ~±4 directly so /1.0 is correct there.
static func _elevation_normalizer() -> float:
	return (
		ELEVATION_NOISE_NORMALIZER_VANILLA if vanilla_noise_enabled else ELEVATION_NOISE_NORMALIZER
	)


# Per-column elevation modulator. 16-octave reverse-FBM matching vanilla
# `h` noise (px.java:190 — `this.b = new nf(this.j, 16)`). Offset +103 to
# stay independent of density noise (+101) and heightmap noises (+0/1/2).
static func _get_elevation_noise() -> NoiseOctaves:
	if _elevation_noise == null:
		_elevation_noise = _make_noise(Worldgen.WORLD_SEED + 103, ELEVATION_NOISE_OCTAVES)
	return _elevation_noise


# Fill `chunk.blocks` with the 3D-density terrain. Replaces
# Worldgen._build_base_terrain_gdscript when terrain_mode = MODE_3D_DENSITY.
# After this call, the chunk has STONE/AIR (no grass/dirt/bedrock yet);
# the SECOND pass (apply_surface_layer) converts top-of-stone to grass,
# next 3 cells to dirt, and bottom 5 cells to bedrock — matching vanilla
# px.java's two-pass structure (density fill + biome surface).
static func build_density_terrain(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	# Sample the 5×17×5 coarse density grid at chunk-corner alignment.
	# base coords are scaled by COARSE_STEP so grid index 0 maps to the
	# chunk's origin world coord.
	var density := PackedFloat64Array()
	density.resize(GRID_X * GRID_Y * GRID_Z)
	var density_2 := PackedFloat64Array()
	density_2.resize(GRID_X * GRID_Y * GRID_Z)
	var selector := PackedFloat64Array()
	selector.resize(GRID_X * GRID_Y * GRID_Z)
	var noise := _get_density_noise()
	var noise_2 := _get_density_noise_2()
	var sel_noise := _get_selector_noise()
	# NoiseOctaves.sample_3d_grid takes (base + i) * scale per axis.
	# We want grid index i to sample at world coord (chunk_x*16 + i*4) * SCALE_XZ.
	# So: base_x * (COARSE_STEP_X * SCALE_XZ) = chunk_x*16 * SCALE_XZ
	#     → base_x = chunk_x * 16 / COARSE_STEP_X = chunk_x * 4
	var base_x: float = float(chunk_x) * float(_SIZE_X) / float(COARSE_STEP_X)
	var base_z: float = float(chunk_z) * float(_SIZE_Z) / float(COARSE_STEP_Z)
	(
		noise
		. sample_3d_grid(
			density,
			base_x,
			0.0,
			base_z,
			GRID_X,
			GRID_Y,
			GRID_Z,
			float(COARSE_STEP_X) * SCALE_XZ,
			float(COARSE_STEP_Y) * SCALE_Y,
			float(COARSE_STEP_Z) * SCALE_XZ,
		)
	)
	(
		noise_2
		. sample_3d_grid(
			density_2,
			base_x,
			0.0,
			base_z,
			GRID_X,
			GRID_Y,
			GRID_Z,
			float(COARSE_STEP_X) * SCALE_XZ,
			float(COARSE_STEP_Y) * SCALE_Y,
			float(COARSE_STEP_Z) * SCALE_XZ,
		)
	)
	(
		sel_noise
		. sample_3d_grid(
			selector,
			base_x,
			0.0,
			base_z,
			GRID_X,
			GRID_Y,
			GRID_Z,
			float(COARSE_STEP_X) * SELECTOR_SCALE_XZ,
			float(COARSE_STEP_Y) * SELECTOR_SCALE_Y,
			float(COARSE_STEP_Z) * SELECTOR_SCALE_XZ,
		)
	)
	# Per-column elevation modulator (vanilla `d4`): shifts target_y per
	# (gx, gz) so regions become mountainous (positive elev) or oceanic
	# (negative). Sampled at coarse-grid resolution; trilerp smooths the
	# transition.
	var elev_noise := _get_elevation_noise()
	var column_target_y := PackedFloat64Array()
	column_target_y.resize(GRID_X * GRID_Z)
	# Per-column amplitude modulator (vanilla `d8`): scales Y-bias
	# strength per region. Mountains where amp is high (gentle bias =
	# wide surface); plains where amp is low (steep bias = tight
	# surface). Without this, every region has identical surface
	# variance and terrain feels uniform.
	var amp_noise := _get_amplitude_noise()
	var column_amplitude := PackedFloat64Array()
	column_amplitude.resize(GRID_X * GRID_Z)
	for gx in range(GRID_X):
		for gz in range(GRID_Z):
			var wx: float = float(chunk_x * _SIZE_X + gx * COARSE_STEP_X)
			var wz: float = float(chunk_z * _SIZE_Z + gz * COARSE_STEP_Z)
			# Vanilla samples h at (world_x/200, world_z/200), px.java:190.
			var raw_h: float = elev_noise.sample_2d(
				wx * ELEVATION_NOISE_FREQUENCY, wz * ELEVATION_NOISE_FREQUENCY
			)
			var d4: Dictionary = _apply_d4_modifier(raw_h / _elevation_normalizer())
			column_target_y[gx * GRID_Z + gz] = float(TARGET_Y) + d4["target_y_offset"]
			# Per-column amplitude varies naturally [0.5, 1.5] for BOTH
			# ocean and land — gives ocean depth variation (some basins
			# tight, some loose) and natural surface texture on land.
			# Force-tight on ocean was producing FLAT UNIFORM oceans,
			# which user reported as "ocean depth way too uniform".
			# Letting amp vary matches vanilla's px.java behavior on
			# non-clobbered columns.
			var raw_amp: float = amp_noise.sample_2d(
				wx * AMPLITUDE_NOISE_FREQUENCY, wz * AMPLITUDE_NOISE_FREQUENCY
			)
			var clamped: float = clampf(raw_amp / AMPLITUDE_NOISE_NORMALIZER, -1.0, 1.0)
			column_amplitude[gx * GRID_Z + gz] = clamped * 0.5 + 1.0  # → [0.5, 1.5]
	# Native fast-path — does the density blend + Y-bias + trilerp +
	# threshold in C++. ~5-10× faster than the GDScript inner loop
	# below (which is dominated by `lerp()` function-call overhead in
	# the 32K-cell trilerp). Result is byte-identical to the GDScript
	# path; parity enforced by tests/test_worldgen_density_native.gd.
	if Worldgen._native_worldgen != null:
		var result: Dictionary = (
			Worldgen
			. _native_worldgen
			. call(
				"build_density_terrain",
				chunk_x,
				chunk_z,
				density,
				density_2,
				selector,
				column_target_y,
				column_amplitude,
				STONE_BIAS_FACTOR,
				AIR_BIAS_FACTOR,
				NOISE_NORMALIZER,
				SELECTOR_NORMALIZER,
				TOP_TAPER_CELLS,
				TOP_TAPER_FORCE_AIR,
			)
		)
		chunk.blocks = result["blocks"]
		chunk.max_y = result["max_y"]
		return
	# GDScript fallback — same algorithm, slower. Kept as the parity
	# reference and so the game still runs without the GDExtension.
	# Vanilla density-output normalization (`px.java:233-234`): primary
	# and secondary divide by 512. Apply the SAME normalization here +
	# perform the per-cell selector blend (vanilla px.java:235-238):
	#   d12 = e[idx] / 512        (primary)
	#   d13 = f[idx] / 512        (secondary)
	#   d14 = (d[idx] / 10 + 1) / 2  (selector → ~[0, 1])
	#   d10 = clamp(d14, 0, 1) interpolation between d12 and d13
	# Result lands back in `density` in place of the primary value.
	for i in range(density.size()):
		var d12: float = density[i] / NOISE_NORMALIZER
		var d13: float = density_2[i] / NOISE_NORMALIZER
		var d14: float = (selector[i] / SELECTOR_NORMALIZER + 1.0) * 0.5
		var t: float = clampf(d14, 0.0, 1.0)
		density[i] = d12 + (d13 - d12) * t
	# Apply per-column Y-bias to the density grid in place — cheaper than
	# per-cell during the trilerp inner loop. Then optionally apply the
	# top-of-world taper on top of the biased value (NOT replacing it —
	# earlier version's `continue` skipped y_bias for tapered rows,
	# leaving raw noise that produced ~50% stone at y~104+).
	for gx in range(GRID_X):
		for gy in range(GRID_Y):
			var world_y: float = float(gy * COARSE_STEP_Y)
			var taper: float = 0.0
			if gy >= GRID_Y - TOP_TAPER_CELLS:
				taper = float(gy - (GRID_Y - TOP_TAPER_CELLS)) / float(TOP_TAPER_CELLS - 1)
			for gz in range(GRID_Z):
				var col_target: float = column_target_y[gx * GRID_Z + gz]
				var col_amp: float = column_amplitude[gx * GRID_Z + gz]
				var y_bias: float = _y_bias_with_target_amp(world_y, col_target, col_amp)
				var idx: int = (gx * GRID_Y + gy) * GRID_Z + gz
				var biased: float = density[idx] - y_bias
				if taper > 0.0:
					biased = biased * (1.0 - taper) + TOP_TAPER_FORCE_AIR * taper
				density[idx] = biased
	# Trilerp to per-cell + threshold to STONE/AIR. Mirrors vanilla
	# px.java:54-100's nested-loop interpolation pattern.
	var max_y: int = 0
	for gx in range(GRID_X - 1):
		for gz in range(GRID_Z - 1):
			for gy in range(GRID_Y - 1):
				# 8 corners of the coarse cell.
				var d000: float = density[(gx * GRID_Y + gy) * GRID_Z + gz]
				var d001: float = density[(gx * GRID_Y + gy) * GRID_Z + gz + 1]
				var d010: float = density[(gx * GRID_Y + gy + 1) * GRID_Z + gz]
				var d011: float = density[(gx * GRID_Y + gy + 1) * GRID_Z + gz + 1]
				var d100: float = density[((gx + 1) * GRID_Y + gy) * GRID_Z + gz]
				var d101: float = density[((gx + 1) * GRID_Y + gy) * GRID_Z + gz + 1]
				var d110: float = density[((gx + 1) * GRID_Y + gy + 1) * GRID_Z + gz]
				var d111: float = density[((gx + 1) * GRID_Y + gy + 1) * GRID_Z + gz + 1]
				# Sub-cell loop: COARSE_STEP_X × COARSE_STEP_Y × COARSE_STEP_Z
				# (= 4×8×4 = 128 cells per coarse cube). Trilinear interpolation
				# unrolled per-axis.
				for sy in range(COARSE_STEP_Y):
					var ty: float = float(sy) / float(COARSE_STEP_Y)
					var d00: float = lerp(d000, d010, ty)
					var d01: float = lerp(d001, d011, ty)
					var d10: float = lerp(d100, d110, ty)
					var d11: float = lerp(d101, d111, ty)
					var world_y: int = gy * COARSE_STEP_Y + sy
					if world_y >= _SIZE_Y:
						continue
					for sx in range(COARSE_STEP_X):
						var tx: float = float(sx) / float(COARSE_STEP_X)
						var d0: float = lerp(d00, d10, tx)
						var d1: float = lerp(d01, d11, tx)
						var local_x: int = gx * COARSE_STEP_X + sx
						for sz in range(COARSE_STEP_Z):
							var tz: float = float(sz) / float(COARSE_STEP_Z)
							var d: float = lerp(d0, d1, tz)
							var local_z: int = gz * COARSE_STEP_Z + sz
							if d > 0.0:
								chunk.set_block_unchecked(local_x, world_y, local_z, Blocks.STONE)
								if world_y > max_y:
									max_y = world_y
							# else: leave as AIR (already initialized by Chunk.new())
	chunk.max_y = max_y


# Two-pass structure: after build_density_terrain fills the chunk with
# raw STONE/AIR (+ AIR above), this pass converts:
#   * The topmost STONE in each column → GRASS
#   * The next 3 STONE cells below → DIRT
#   * Cells at y=0..4 → BEDROCK (probabilistic, matching vanilla
#     px.java:130 pattern: y=0 always, y=1 → 4/5, y=2 → 3/5, y=3 → 2/5,
#     y=4 → 1/5).
# Beach band substitution + ocean fill happen LATER in
# Worldgen.generate_chunk (existing _place_beaches and _fill_ocean
# passes don't need to change — they operate on the surface y of each
# column which is now derived from the density-filled blocks).
static func apply_surface_layer(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	# Native fast-path — does the column scan + grass/dirt/bedrock
	# conversion in C++. ~16ms in GDScript → ~1ms native. Result is
	# byte-identical; parity guarded by tests/test_density_native_parity.
	# Disabled when biomes are on — native path doesn't know about
	# biome.top/filler decisions yet (slice 4 of biomes-plan.md).
	if Worldgen._native_worldgen != null and not Worldgen.biomes_enabled:
		chunk.blocks = Worldgen._native_worldgen.call(
			"apply_surface_layer", chunk_x, chunk_z, chunk.blocks
		)
		return
	for x in range(_SIZE_X):
		for z in range(_SIZE_Z):
			var world_x: int = chunk_x * _SIZE_X + x
			var world_z: int = chunk_z * _SIZE_Z + z
			# Walk top-down, find the topmost STONE.
			var top_stone_y: int = -1
			for y in range(_SIZE_Y - 1, -1, -1):
				if chunk.get_block_unchecked(x, y, z) == Blocks.STONE:
					top_stone_y = y
					break
			if top_stone_y < 0:
				continue  # entire column was air
			# Top + filler block selection. Vanilla px.java:130-148 uses
			# biome.top + biome.filler regardless of underwater status.
			# Plains underwater is GRASS, Desert underwater is SAND.
			# Ocean fill pass writes WATER above the surface separately.
			var top_block: int = Blocks.GRASS
			var filler_block: int = Blocks.DIRT
			if Worldgen.biomes_enabled:
				var biome: int = BiomeClimate.biome_at(world_x, world_z)
				top_block = Biomes.top_block(biome)
				filler_block = Biomes.filler_block(biome)
			elif top_stone_y < Worldgen.SEA_LEVEL:
				# No-biomes legacy: underwater = DIRT (workaround pre-biomes).
				top_block = Blocks.DIRT
			chunk.set_block_unchecked(x, top_stone_y, z, top_block)
			for dy in range(1, 4):
				var dy_y: int = top_stone_y - dy
				if dy_y < 0:
					break
				if chunk.get_block_unchecked(x, dy_y, z) == Blocks.STONE:
					chunk.set_block_unchecked(x, dy_y, z, filler_block)
			# Bedrock pass — probabilistic per vanilla. Use the same
			# deterministic hash pattern as Worldgen._is_bedrock_at to keep
			# bedrock placement reproducible per (seed, world_x, y, world_z).
			for y in range(5):
				if Worldgen._is_bedrock_at(world_x, y, world_z):
					chunk.set_block_unchecked(x, y, z, Blocks.BEDROCK)


# Linear Y-bias against a per-column target_y AND per-column amplitude.
# Encourages stone below target (negative bias subtracted = added
# density), encourages air above. The amp modulator (vanilla `d8`) is a
# DIVISOR — amp < 1 (steep bias) → tight surface = plains; amp > 1
# (gentle bias) → wide surface = mountains/cliffs.
# Asymmetric STONE/AIR factor ratio matches vanilla `px.java:224`'s
# `d11 *= 4` for the negative-bias branch.
static func _y_bias_with_target_amp(world_y: float, col_target: float, amp: float) -> float:
	var diff: float = world_y - col_target
	if diff < 0.0:
		return diff * STONE_BIAS_FACTOR / amp
	return diff * AIR_BIAS_FACTOR / amp
