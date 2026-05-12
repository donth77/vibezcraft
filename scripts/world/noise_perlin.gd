class_name NoisePerlin
extends RefCounted

# Vanilla Alpha 1.2.6 Perlin noise — direct port of `z.java`
# (vendor/alpha-1.2.6-src/src/z.java). This is the per-octave noise
# generator vanilla's `nf.java` reverse-FBM stack uses.
#
# Why this exists alongside our existing FastNoiseLite-based noise:
# vanilla's noise output has different distribution characteristics
# from FastNoiseLite Perlin (different gradient table, different
# permutation, different smoothstep). Our FastNoiseLite-based
# NoiseOctaves produces narrower surface variance (~28 cells vs
# vanilla's ~65), causing the persistent "1-cell beach" issue. This
# port replicates vanilla's exact noise math so re-tuned WorldgenDensity
# constants can produce vanilla-shape surface distributions.
#
# Vanilla algorithm (z.java):
# - Constructor takes Random; initializes 3 offset doubles (a, b, c) and
#   a 256-int permutation table (Fisher-Yates shuffle).
# - 3D Perlin sample: smoothstep `t³(t(t·6 - 15) + 10)`, 8 corner
#   gradient lookups via permutation table, trilerp.
# - 3D grid fill: bulk version that fills a flat double[] array with
#   ADDITIVE per-cell noise samples. Reuses i6==0 cache to skip
#   redundant grad lookups when the inner Y axis stays in the same
#   integer cell across multiple Y samples.
#
# Critical implementation notes:
# - Uses our JavaRandom port for bit-exact Random parity.
# - Permutation table is 512 ints (first 256 + duplicate 256, vanilla's
#   trick to avoid index-mod-256 in the lookup hot path).
# - The `_grad_2d` and `_grad_3d` functions use bit tricks on the
#   permutation index — preserved verbatim because changes break the
#   noise distribution character.

# Permutation table (size 512: first 256 shuffled, last 256 = copy).
# Vanilla `z.d`. Sized for direct index lookup without modulo.
var _perm: PackedInt32Array

# Three random offsets vanilla applies to (x, y, z) before the integer
# floor + permutation lookup. Vanilla `z.a`, `z.b`, `z.c`.
var _x_offset: float
var _y_offset: float
var _z_offset: float


# Construct from a JavaRandom — pulls 3 doubles + 256 nextInt calls.
# Mirrors `z.java:13-32` exactly, including the dual-write of d[n+256].
func _init(rng: JavaRandom) -> void:
	_x_offset = rng.next_double() * 256.0
	_y_offset = rng.next_double() * 256.0
	_z_offset = rng.next_double() * 256.0
	_perm = PackedInt32Array()
	_perm.resize(512)
	# Initial permutation: identity 0..255.
	for i in range(256):
		_perm[i] = i
	# Fisher-Yates shuffle: for n in 0..255, swap d[n] with d[rng.next_int(256-n) + n].
	# Then duplicate to indices 256..511.
	for n in range(256):
		var swap_idx: int = rng.next_int_bounded(256 - n) + n
		var tmp: int = _perm[n]
		_perm[n] = _perm[swap_idx]
		_perm[swap_idx] = tmp
		_perm[n + 256] = _perm[n]


# 3D Perlin sample at world coords (x, y, z). Mirrors `z.java:34-63`.
func sample_3d(x: float, y: float, z: float) -> float:
	var d5: float = x + _x_offset
	var d6: float = y + _y_offset
	var d7: float = z + _z_offset
	var n2: int = int(d5)
	var n3: int = int(d6)
	var n4: int = int(d7)
	# Floor adjustment for negative inputs (Java's int cast truncates
	# toward zero, but Perlin expects floor toward -infinity).
	if d5 < float(n2):
		n2 -= 1
	if d6 < float(n3):
		n3 -= 1
	if d7 < float(n4):
		n4 -= 1
	var n5: int = n2 & 0xFF
	var n6: int = n3 & 0xFF
	var n7: int = n4 & 0xFF
	# Improved Perlin smoothstep: 6t⁵ - 15t⁴ + 10t³
	d5 -= float(n2)
	d6 -= float(n3)
	d7 -= float(n4)
	var d8: float = d5 * d5 * d5 * (d5 * (d5 * 6.0 - 15.0) + 10.0)
	var d9: float = d6 * d6 * d6 * (d6 * (d6 * 6.0 - 15.0) + 10.0)
	var d10: float = d7 * d7 * d7 * (d7 * (d7 * 6.0 - 15.0) + 10.0)
	# Permutation table lookups for the 8 cube corner gradients.
	var n8: int = _perm[n5] + n6
	var n9: int = _perm[n8] + n7
	var n10: int = _perm[n8 + 1] + n7
	var n11: int = _perm[n5 + 1] + n6
	var n12: int = _perm[n11] + n7
	var n13: int = _perm[n11 + 1] + n7
	# Trilerp the 8 corner gradients. Vanilla's nested b()/a() calls.
	return _lerp(
		d10,
		_lerp(
			d9,
			_lerp(d8, _grad_3d(_perm[n9], d5, d6, d7), _grad_3d(_perm[n12], d5 - 1.0, d6, d7)),
			_lerp(
				d8,
				_grad_3d(_perm[n10], d5, d6 - 1.0, d7),
				_grad_3d(_perm[n13], d5 - 1.0, d6 - 1.0, d7)
			)
		),
		_lerp(
			d9,
			_lerp(
				d8,
				_grad_3d(_perm[n9 + 1], d5, d6, d7 - 1.0),
				_grad_3d(_perm[n12 + 1], d5 - 1.0, d6, d7 - 1.0)
			),
			_lerp(
				d8,
				_grad_3d(_perm[n10 + 1], d5, d6 - 1.0, d7 - 1.0),
				_grad_3d(_perm[n13 + 1], d5 - 1.0, d6 - 1.0, d7 - 1.0)
			)
		)
	)


# 2D variant (z=0). Mirrors `z.java:84-86` (which delegates to 3D with z=0).
func sample_2d(x: float, z: float) -> float:
	return sample_3d(x, z, 0.0)


# Bulk-fill a 3D grid with ADDITIVE noise samples (caller pre-zeros the
# array if needed; the +=. semantics let nf.java accumulate octaves
# into the same buffer). Mirrors `z.java:88-185`.
#
# When size_y == 1, takes a 2D-optimized path (vanilla `z.java:89-126`).
# Otherwise uses the 3D path with the i6==0 inner-cache trick to avoid
# redundant trilerp setup for adjacent Y cells in the same integer Y.
#
# `dArray` is indexed (i_x * size_y + i_y) * size_z + i_z, matching
# vanilla's flat-array layout.
# gdlint: disable=function-arguments-number
func sample_3d_grid_additive(
	out: PackedFloat64Array,
	base_x: float,
	base_y: float,
	base_z: float,
	size_x: int,
	size_y: int,
	size_z: int,
	scale_x: float,
	scale_y: float,
	scale_z: float,
	amp_divisor: float
) -> void:
	if size_y == 1:
		_sample_2d_grid_additive(out, base_x, base_z, size_x, size_z, scale_x, scale_z, amp_divisor)
		return
	# Full 3D path: vanilla z.java:127-185.
	var n15: int = 0
	var d17: float = 1.0 / amp_divisor
	var n16: int = -1
	var n17: int = 0
	var n18: int = 0
	var n19: int = 0
	var n20: int = 0
	var n21: int = 0
	var n22: int = 0
	var d18: float = 0.0
	var d19: float = 0.0
	var d20: float = 0.0
	var d21: float = 0.0
	for i4 in range(size_x):
		var d22: float = (base_x + float(i4)) * scale_x + _x_offset
		var n23: int = int(d22)
		if d22 < float(n23):
			n23 -= 1
		var n24: int = n23 & 0xFF
		d22 -= float(n23)
		var d23: float = d22 * d22 * d22 * (d22 * (d22 * 6.0 - 15.0) + 10.0)
		for i5 in range(size_z):
			var d24: float = (base_z + float(i5)) * scale_z + _z_offset
			var n25: int = int(d24)
			if d24 < float(n25):
				n25 -= 1
			var n26: int = n25 & 0xFF
			d24 -= float(n25)
			var d25: float = d24 * d24 * d24 * (d24 * (d24 * 6.0 - 15.0) + 10.0)
			for i6 in range(size_y):
				var d26: float = (base_y + float(i6)) * scale_y + _y_offset
				var n27: int = int(d26)
				if d26 < float(n27):
					n27 -= 1
				var n28: int = n27 & 0xFF
				d26 -= float(n27)
				var d27: float = d26 * d26 * d26 * (d26 * (d26 * 6.0 - 15.0) + 10.0)
				# Vanilla z.java caches d18-d21 across i6 iterations when n28
				# (integer Y cell) hasn't changed. The cached values use
				# d26 (Y subpixel) from when the cache was last computed,
				# which drifts as i6 advances within the same integer Y
				# cell. From a "correct Perlin sample" standpoint this is
				# wrong, but VANILLA TERRAIN DEPENDS ON THIS — vanilla's
				# bulk-grid output uses these cached (technically incorrect)
				# values, which is what produces vanilla's characteristic
				# smooth terrain appearance.
				#
				# Earlier we disabled the cache to match sum-of-point-samples
				# (commit 7bd8f23), which gave us bit-correct Perlin values
				# but cliffs everywhere — terrain that diverged from vanilla's
				# saved worlds at the same seed. Re-enabling restores vanilla
				# parity. The 'wrong' cache is intentional vanilla behavior.
				if i6 == 0 or n28 != n16:
					n16 = n28
					n17 = _perm[n24] + n28
					n18 = _perm[n17] + n26
					n19 = _perm[n17 + 1] + n26
					n20 = _perm[n24 + 1] + n28
					n21 = _perm[n20] + n26
					n22 = _perm[n20 + 1] + n26
					d18 = _lerp(
						d23,
						_grad_3d(_perm[n18], d22, d26, d24),
						_grad_3d(_perm[n21], d22 - 1.0, d26, d24)
					)
					d19 = _lerp(
						d23,
						_grad_3d(_perm[n19], d22, d26 - 1.0, d24),
						_grad_3d(_perm[n22], d22 - 1.0, d26 - 1.0, d24)
					)
					d20 = _lerp(
						d23,
						_grad_3d(_perm[n18 + 1], d22, d26, d24 - 1.0),
						_grad_3d(_perm[n21 + 1], d22 - 1.0, d26, d24 - 1.0)
					)
					d21 = _lerp(
						d23,
						_grad_3d(_perm[n19 + 1], d22, d26 - 1.0, d24 - 1.0),
						_grad_3d(_perm[n22 + 1], d22 - 1.0, d26 - 1.0, d24 - 1.0)
					)
				var d28: float = _lerp(d27, d18, d19)
				var d29: float = _lerp(d27, d20, d21)
				var d30: float = _lerp(d25, d28, d29)
				out[n15] += d30 * d17
				n15 += 1


# 2D-optimized grid path (vanilla z.java:89-126). When size_y == 1 the
# 3D path's middle loop is constant — collapse to the inner X/Z loops.
# `out` is indexed `i_x * size_z + i_z`.
func _sample_2d_grid_additive(
	out: PackedFloat64Array,
	base_x: float,
	base_z: float,
	size_x: int,
	size_z: int,
	scale_x: float,
	scale_z: float,
	amp_divisor: float
) -> void:
	var n9: int = 0
	var d11: float = 1.0 / amp_divisor
	for i2 in range(size_x):
		var d12: float = (base_x + float(i2)) * scale_x + _x_offset
		var n10: int = int(d12)
		if d12 < float(n10):
			n10 -= 1
		var n11: int = n10 & 0xFF
		d12 -= float(n10)
		var d13: float = d12 * d12 * d12 * (d12 * (d12 * 6.0 - 15.0) + 10.0)
		for i3 in range(size_z):
			var d14: float = (base_z + float(i3)) * scale_z + _z_offset
			var n12: int = int(d14)
			if d14 < float(n12):
				n12 -= 1
			var n13: int = n12 & 0xFF
			d14 -= float(n12)
			var d15: float = d14 * d14 * d14 * (d14 * (d14 * 6.0 - 15.0) + 10.0)
			var n5: int = _perm[n11] + 0
			var n6: int = _perm[n5] + n13
			var n7: int = _perm[n11 + 1] + 0
			var n8: int = _perm[n7] + n13
			var d9: float = _lerp(
				d13, _grad_2d(_perm[n6], d12, d14), _grad_3d(_perm[n8], d12 - 1.0, 0.0, d14)
			)
			var d10: float = _lerp(
				d13,
				_grad_2d(_perm[n6 + 1], d12, d14 - 1.0),
				_grad_3d(_perm[n8 + 1], d12 - 1.0, 0.0, d14 - 1.0)
			)
			var d16: float = _lerp(d15, d9, d10)
			out[n9] += d16 * d11
			n9 += 1


# Linear interpolation. Vanilla `z.java::b(d2, d3, d4) = d3 + d2 * (d4 - d3)`.
static func _lerp(t: float, a: float, b: float) -> float:
	return a + t * (b - a)


# 2D gradient (vanilla z.java:69-74). Bit-trick gradient vector lookup
# using lower 4 bits of the permutation hash. 12 possible 2D gradients.
static func _grad_2d(hash: int, x: float, y: float) -> float:
	var n3: int = hash & 0xF
	var d4: float = float(1 - ((n3 & 8) >> 3)) * x
	var d5: float
	if n3 < 4:
		d5 = 0.0
	elif n3 == 12 or n3 == 14:
		d5 = x
	else:
		d5 = y
	var sign_d4: float = -d4 if (n3 & 1) != 0 else d4
	var sign_d5: float = -d5 if (n3 & 2) != 0 else d5
	return sign_d4 + sign_d5


# 3D gradient (vanilla z.java:76-82). Same bit-trick as 2D but the
# branches on `n3 < 8` and `n3 < 4` pick from (x, y, z) instead.
static func _grad_3d(hash: int, x: float, y: float, z: float) -> float:
	var n3: int = hash & 0xF
	var d5: float = x if n3 < 8 else y
	var d7: float
	if n3 < 4:
		d7 = y
	elif n3 == 12 or n3 == 14:
		d7 = x
	else:
		d7 = z
	var sign_d5: float = -d5 if (n3 & 1) != 0 else d5
	var sign_d7: float = -d7 if (n3 & 2) != 0 else d7
	return sign_d5 + sign_d7
