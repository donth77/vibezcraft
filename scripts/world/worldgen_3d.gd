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
static var _cached_seed: int = 0  # tracks which seed the noises were built with


# Build (or rebuild on seed change) the 8-noise stack the vanilla way:
# all noises share ONE JavaRandom, consumed in order. Each NoisePerlin
# constructor pulls 256+3 random doubles, so each noise gets a different
# gradient table. This sharing is load-bearing for vanilla seed
# determinism.
static func _ensure_noises(world_seed: int) -> void:
	if _e_noise != null and _cached_seed == world_seed:
		return
	# Vanilla px.java constructor:
	#   this.k = new nf(this.j, 16);   // e
	#   this.l = new nf(this.j, 16);   // f
	#   this.m = new nf(this.j, 8);    // d (selector)
	#   this.n = new nf(this.j, 4);    // r (beach)
	#   this.o = new nf(this.j, 4);    // t (soil)
	#   this.a = new nf(this.j, 10);   // g (amplitude)
	#   this.b = new nf(this.j, 16);   // h (depth)
	#   this.c = new nf(this.j, 8);    // forest
	# Each `new nf(rand, N)` consumes N × (256+3) doubles from `rand`.
	# Our NoiseOctaves.create_vanilla(world_seed, N) creates a fresh
	# JavaRandom internally — that breaks vanilla's sharing pattern.
	# For Phase 3, accept this divergence: each noise gets a slightly
	# different state than vanilla, but determinism within OUR system
	# is preserved. Phase 4 may need a shared-Random factory.
	# (TODO: if cell-diff Phase 3 is too far off, build a shared-Random
	# factory that mimics vanilla's exact entropy consumption order.)
	_e_noise = NoiseOctaves.create_vanilla(world_seed, 16)
	_f_noise = NoiseOctaves.create_vanilla(world_seed + 1, 16)
	_selector_noise = NoiseOctaves.create_vanilla(world_seed + 2, 8)
	_beach_noise = NoiseOctaves.create_vanilla(world_seed + 3, 4)
	_soil_noise = NoiseOctaves.create_vanilla(world_seed + 4, 4)
	_amplitude_noise = NoiseOctaves.create_vanilla(world_seed + 5, 10)
	_depth_noise = NoiseOctaves.create_vanilla(world_seed + 6, 16)
	_forest_noise = NoiseOctaves.create_vanilla(world_seed + 7, 8)
	_cached_seed = world_seed


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
	# These are 5×5 = 25 samples each — small, just call sample_2d.
	var g_grid: PackedFloat64Array = PackedFloat64Array()
	var h_grid: PackedFloat64Array = PackedFloat64Array()
	g_grid.resize(GRID_X * GRID_Z)
	h_grid.resize(GRID_X * GRID_Z)
	for ix in range(GRID_X):
		for iz in range(GRID_Z):
			var nx: float = float(noise_base_x + ix)
			var nz: float = float(noise_base_z + iz)
			# Vanilla samples at (nx * scale, nz * scale).
			g_grid[ix * GRID_Z + iz] = _amplitude_noise.sample_2d(
				nx * AMPLITUDE_SCALE, nz * AMPLITUDE_SCALE
			)
			h_grid[ix * GRID_Z + iz] = _depth_noise.sample_2d(nx * DEPTH_SCALE, nz * DEPTH_SCALE)

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

	for ix in range(GRID_X):
		for iz in range(GRID_Z):
			# Climate = 0.5 constant for Phase 3 (Phase 4 ports cy.java
			# biome temp/rain). d7 calc with t=0.5, r=0.5: t*r=0.25,
			# (1-0.25)^4 = 0.316, d7 = 1-0.316 = 0.684.
			var d5: float = 0.5  # temperature
			var d6: float = 0.5 * d5  # rain × temp = 0.25
			var d7: float = 1.0 - d6
			d7 *= d7
			d7 *= d7
			d7 = 1.0 - d7  # ≈ 0.684 with constant climate

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
				var d9: float = (
					(grid[((i2 + 1) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 0)] - d5) * 0.125
				)
				# px.java has a typo? Let me re-check. Actually:
				# d10 = (q[((i2+1)*n8 + (i3+1))*n7 + (i4+1)] - d6) * d2
				# But our layout is x,y,z with stride GRID_Z so:
				# d10 = grid[((i2+1)*GRID_Y + (i4+1))*GRID_Z + (i3+1)] - d6) * 0.125
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
