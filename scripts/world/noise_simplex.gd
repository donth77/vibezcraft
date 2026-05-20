class_name NoiseSimplex
extends RefCounted

# Vanilla Alpha 1.2.6 Simplex noise — direct port of `aw.java`
# (vendor/alpha-1.2.6-src/src/aw.java). This is the per-octave noise
# generator vanilla's `ng.java` reverse-FBM stack uses for climate
# (po.java) and tree-density noise (px.java's c noise).
#
# Vanilla algorithm: 2D Simplex noise (Ken Perlin's improved noise,
# triangular lattice). Differs from z.java (Perlin) which uses a
# square lattice.
#
# Vanilla 2D Simplex output range per sample is roughly [-1, 1].
# Vanilla bulk-fill multiplies by 70 * amp_factor, so accumulated
# output across 4 octaves of reverse-FBM can reach ~[-500, +500] —
# the wide range vanilla biome decision tree depends on.

# Static gradient table — 12 vectors (Z axis present but always 0 for 2D).
const _GRADIENTS: Array = [
	Vector2(1, 1),
	Vector2(-1, 1),
	Vector2(1, -1),
	Vector2(-1, -1),
	Vector2(1, 0),
	Vector2(-1, 0),
	Vector2(1, 0),
	Vector2(-1, 0),
	Vector2(0, 1),
	Vector2(0, -1),
	Vector2(0, 1),
	Vector2(0, -1)
]
# Skew + unskew constants for 2D Simplex (vanilla aw.java:12-13).
const _SKEW: float = 0.36602540378443864967  # 0.5 * (sqrt(3) - 1)
const _UNSKEW: float = 0.21132486540518711775  # (3 - sqrt(3)) / 6

# Permutation table (size 512: first 256 shuffled, last 256 = copy).
# Vanilla `aw.e`. Sized for direct index lookup without modulo.
var _perm: PackedInt32Array
# Three random offsets vanilla applies to (x, y, z) before sampling.
# Vanilla `aw.a`, `aw.b`, `aw.c`. Z is unused for 2D-only sampling.
var _x_offset: float
var _y_offset: float
var _z_offset: float


# Construct from JavaRandom — pulls 3 doubles + 256 nextInt calls.
# Mirrors `aw.java:19-34` exactly, including the dual-write of e[n+256].
func _init(rng: JavaRandom) -> void:
	_x_offset = rng.next_double() * 256.0
	_y_offset = rng.next_double() * 256.0
	_z_offset = rng.next_double() * 256.0
	_perm = PackedInt32Array()
	_perm.resize(512)
	for i in range(256):
		_perm[i] = i
	for n in range(256):
		var swap_idx: int = rng.next_int_bounded(256 - n) + n
		var tmp: int = _perm[n]
		_perm[n] = _perm[swap_idx]
		_perm[swap_idx] = tmp
		_perm[n + 256] = _perm[n]


# Floor toward -infinity (Java's behavior with `(int)` for negatives).
static func _floor(d: float) -> int:
	return int(d) if d > 0.0 else int(d) - 1


# 2D bulk-grid fill — accumulates per-cell Simplex into out[].
# Direct port of `aw.java:44-104`. Caller pre-zeros `out` if needed
# (the +=. semantics let ng.java accumulate octaves into one buffer).
# `out` is indexed `i_x * size_z + i_z` (X stride size_z, Z stride 1).
# gdlint: disable=function-arguments-number
func sample_2d_grid_additive(
	out: PackedFloat64Array,
	base_x: float,
	base_z: float,
	size_x: int,
	size_z: int,
	scale_x: float,
	scale_z: float,
	amp_factor: float
) -> void:
	var n4: int = 0
	for i2 in range(size_x):
		var d7: float = (base_x + float(i2)) * scale_x + _x_offset
		for i3 in range(size_z):
			var d14: float = (base_z + float(i3)) * scale_z + _y_offset
			# Skew (x, z) onto triangular lattice.
			var d15: float = (d7 + d14) * _SKEW
			var n8: int = _floor(d7 + d15)
			var n7: int = _floor(d14 + d15)
			var d13: float = float(n8 + n7) * _UNSKEW
			var d16: float = float(n8) - d13
			var d17: float = d7 - d16
			var d11: float = float(n7) - d13
			var d12: float = d14 - d11
			# Determine simplex offset (in (x,z) order)
			var n6: int
			var n5: int
			if d17 > d12:
				n6 = 1
				n5 = 0
			else:
				n6 = 0
				n5 = 1
			# Three corner offsets (relative to first corner)
			var d18: float = d17 - float(n6) + _UNSKEW
			var d19: float = d12 - float(n5) + _UNSKEW
			var d20: float = d17 - 1.0 + 2.0 * _UNSKEW
			var d21: float = d12 - 1.0 + 2.0 * _UNSKEW
			# Hash to gradient indices via permutation table
			var n9: int = n8 & 0xFF
			var n10: int = n7 & 0xFF
			var n11: int = _perm[n9 + _perm[n10]] % 12
			var n12: int = _perm[n9 + n6 + _perm[n10 + n5]] % 12
			var n13: int = _perm[n9 + 1 + _perm[n10 + 1]] % 12
			# Three corner contributions (clamped at 0 if attenuation < 0)
			var d10: float = 0.0
			var d22: float = 0.5 - d17 * d17 - d12 * d12
			if d22 >= 0.0:
				d22 *= d22
				var g0: Vector2 = _GRADIENTS[n11]
				d10 = d22 * d22 * (g0.x * d17 + g0.y * d12)
			var d9: float = 0.0
			var d23: float = 0.5 - d18 * d18 - d19 * d19
			if d23 >= 0.0:
				d23 *= d23
				var g1: Vector2 = _GRADIENTS[n12]
				d9 = d23 * d23 * (g1.x * d18 + g1.y * d19)
			var d8: float = 0.0
			var d24: float = 0.5 - d20 * d20 - d21 * d21
			if d24 >= 0.0:
				d24 *= d24
				var g2: Vector2 = _GRADIENTS[n13]
				d8 = d24 * d24 * (g2.x * d20 + g2.y * d21)
			# Accumulate. Vanilla: dArray[n14] += 70.0 * (d10 + d9 + d8) * amp_factor
			out[n4] += 70.0 * (d10 + d9 + d8) * amp_factor
			n4 += 1
