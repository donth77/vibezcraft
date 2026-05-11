extends GutTest

# Slice 3-A: NoiseGeneratorOctaves (port of vanilla nf.java) sanity tests.
# Verifies the REVERSE-FBM behavior — large-feature dominance — that's
# the whole reason vanilla terrain looks the way it does.


func test_sample_2d_is_deterministic() -> void:
	var n := NoiseOctaves.create(12345, 4)
	var a: float = n.sample_2d(10.0, 20.0)
	var b: float = n.sample_2d(10.0, 20.0)
	assert_eq(a, b, "same coords + same instance gives same value")


func test_separate_instances_with_same_seed_match() -> void:
	var n1 := NoiseOctaves.create(12345, 4)
	var n2 := NoiseOctaves.create(12345, 4)
	for x in [0.0, 5.0, -5.0, 100.0]:
		for z in [0.0, 5.0, -5.0, 100.0]:
			assert_eq(
				n1.sample_2d(x, z),
				n2.sample_2d(x, z),
				"determinism: identical-seed instances should match at (%f, %f)" % [x, z]
			)


func test_different_seeds_diverge() -> void:
	var n1 := NoiseOctaves.create(12345, 4)
	var n2 := NoiseOctaves.create(54321, 4)
	# Sample several coords; at least one should differ. (Two seeds CAN
	# theoretically collide at one specific coord, but never across many.)
	var any_diff: bool = false
	for x in range(0, 100, 7):
		if n1.sample_2d(float(x), 0.0) != n2.sample_2d(float(x), 0.0):
			any_diff = true
			break
	assert_true(any_diff, "different seeds must produce different sequences")


# The signature property of reverse-FBM: low-frequency variation
# DOMINATES the sum. Sample over a large area and verify that the
# autocorrelation distance is large (heights at coords 200 blocks
# apart should still correlate more than coords 1 block apart for
# pure noise — but for reverse-FBM, even nearby cells should be
# strongly biased by the dominant low-freq layer).
#
# We measure this by comparing variance over a small (16-block) window
# vs over a large (256-block) window. With reverse-FBM, the small-
# window variance should be MUCH SMALLER than the large-window variance
# (because nearby cells share the same low-freq baseline). With normal
# FBM, the two would be roughly comparable.
func test_reverse_fbm_low_frequencies_dominate() -> void:
	var n := NoiseOctaves.create(12345, 8)
	var small_window_samples: Array[float] = []
	for i in range(16):
		small_window_samples.append(n.sample_2d(float(i), 0.0))
	var large_window_samples: Array[float] = []
	for i in range(0, 256, 4):
		large_window_samples.append(n.sample_2d(float(i), 0.0))
	var small_variance: float = _variance(small_window_samples)
	var large_variance: float = _variance(large_window_samples)
	# Reverse-FBM: large-window variance should be substantially bigger.
	# Loose threshold (≥ 1.5×) since exact ratio depends on octave count
	# + seed. Failing this means reverse-FBM isn't actually working —
	# the algorithm devolved into ordinary FBM.
	assert_gt(
		large_variance,
		small_variance * 1.5,
		(
			"reverse-FBM should make low-freq dominate (large var %.3f vs small var %.3f)"
			% [large_variance, small_variance]
		)
	)


# 3D grid variant: verify it produces deterministic output and the right
# array size.
func test_sample_3d_grid_fills_correctly() -> void:
	var n := NoiseOctaves.create(12345, 4)
	var size_x: int = 5
	var size_y: int = 17
	var size_z: int = 5
	var out := PackedFloat64Array()
	out.resize(size_x * size_y * size_z)
	n.sample_3d_grid(out, 0.0, 0.0, 0.0, size_x, size_y, size_z, 0.1, 0.1, 0.1)
	assert_eq(out.size(), size_x * size_y * size_z, "3D grid is correctly sized")
	# Verify we actually wrote SOMETHING (not all zeros). Pre-zeroing is
	# the first step of sample_3d_grid; if the per-octave loop didn't
	# accumulate, the array would stay zero.
	var any_nonzero: bool = false
	for v in out:
		if absf(v) > 1e-9:
			any_nonzero = true
			break
	assert_true(any_nonzero, "3D grid should be populated with non-trivial noise values")
	# Repeat with same params — must be byte-identical (determinism).
	var out2 := PackedFloat64Array()
	out2.resize(size_x * size_y * size_z)
	n.sample_3d_grid(out2, 0.0, 0.0, 0.0, size_x, size_y, size_z, 0.1, 0.1, 0.1)
	assert_eq(out, out2, "3D grid sampling is deterministic")


# Helper: simple population variance.
func _variance(samples: Array[float]) -> float:
	if samples.is_empty():
		return 0.0
	var mean: float = 0.0
	for v in samples:
		mean += v
	mean /= float(samples.size())
	var sq_diff: float = 0.0
	for v in samples:
		var d: float = v - mean
		sq_diff += d * d
	return sq_diff / float(samples.size())
