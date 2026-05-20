# gdlint: disable=max-public-methods
extends GutTest

# Regression guard for visible terrain artifacts. The 'd9 trilerp bug'
# (commit 3def0a9) sat in fill_chunk for weeks producing visible
# 1-block grass towers on every chunk, but the existing audit (whole-
# chunk cell-match) didn't catch it because most chunk cells are AIR
# above terrain or deep STONE below — those match trivially regardless
# of trilerp bugs. This test specifically measures surface-cell
# variance: how many columns have a surface_y that's strictly higher
# than ALL 4 cardinal neighbors (an isolated peak / spike).
#
# Vanilla terrain has near-zero such columns at typical seeds; our
# port should also be near-zero. A failure here means there's a
# trilerp bug, surface-placement bug, or cave-pass bug producing
# visible 1-cell elevation outliers.

# Save/restore WORLD_SEED so this test doesn't leak seed state into
# other test files (test_worldgen has assertions that depend on the
# default seed's terrain output).
var _world_seed_was: int


func before_all() -> void:
	_world_seed_was = Worldgen.WORLD_SEED


func after_all() -> void:
	Worldgen.apply_world_seed(_world_seed_was)
	Worldgen3D.reset()


# Sample surface heights for one chunk + count isolated peaks.
func _count_isolated_peaks(chunk: Chunk) -> int:
	var heights: Array = []
	for x in range(16):
		var row: Array = []
		for z in range(16):
			var sy: int = -1
			for y in range(127, -1, -1):
				var b: int = chunk.get_block_unchecked(x, y, z)
				if b != Blocks.AIR and b != Blocks.WATER_STILL and b != Blocks.WATER_FLOWING:
					sy = y
					break
			row.append(sy)
		heights.append(row)
	var peaks: int = 0
	for x in range(1, 15):
		for z in range(1, 15):
			var sy: int = heights[x][z]
			if sy < 0:
				continue
			var n_xm: int = heights[x - 1][z]
			var n_xp: int = heights[x + 1][z]
			var n_zm: int = heights[x][z - 1]
			var n_zp: int = heights[x][z + 1]
			if n_xm < 0 or n_xp < 0 or n_zm < 0 or n_zp < 0:
				continue
			var nmax: int = max(max(n_xm, n_xp), max(n_zm, n_zp))
			if sy > nmax:
				peaks += 1
	return peaks


# At seeds we know produce well-shaped terrain, isolated peaks should be
# rare. The d9 bug produced ~25 peaks per chunk (sawtooth at every
# coarse-cell boundary). Threshold of 10 is well above the typical
# ~0-5 we see post-fix and well below the bug-state.
func test_isolated_surface_peaks_rare() -> void:
	# Worldgen3D static state needs to be reset for clean test, but the
	# auto-fired _ensure_noises will rebuild the noise stack on apply_world_seed.
	for seed: int in [0, 1475921578, 2012828372]:
		Worldgen.apply_world_seed(seed)
		# Force noise rebuild
		Worldgen3D.reset()
		Worldgen.surface_height(0, 0)  # warm 2D heightmap
		var max_peaks: int = 0
		for cx: int in [-3, 0, 3]:
			for cz: int in [-3, 0, 3]:
				var chunk: Chunk = Chunk.new()
				Worldgen3D.fill_chunk(chunk, cx, cz)
				var peaks: int = _count_isolated_peaks(chunk)
				if peaks > max_peaks:
					max_peaks = peaks
		assert_lte(
			max_peaks,
			10,
			(
				(
					"Seed %d: max isolated peaks = %d (threshold 10). The d9 trilerp "
					+ "bug produced ~25 per chunk — high count means a similar "
					+ "regression was introduced."
				)
				% [seed, max_peaks]
			)
		)
