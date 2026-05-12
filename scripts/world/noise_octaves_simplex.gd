class_name NoiseOctavesSimplex
extends RefCounted

# Vanilla Alpha 1.2.6 reverse-FBM Simplex stack — direct port of
# `ng.java` (vendor/alpha-1.2.6-src/src/ng.java). This is the
# multi-octave wrapper around aw.java (Simplex) that vanilla po.java
# uses for climate (temperature, rainfall, extreme).
#
# Algorithm (verbatim from ng.java):
#   For each octave i in 0..N-1:
#     freq = biome_freq_decay^i  (default 0.5)
#     amp  = amp_decay^i         (default 0.5)
#     scale = (input_scale / 1.5) * freq
#     aw.a writes per-cell sample × 70 × (0.55 / amp) into out[]
#
# Output range for 4 octaves: roughly [-577, +577] worst case
# (sum of 70 × 1 × 0.55 × (1 + 2 + 4 + 8)). Vanilla biome decision
# tree relies on this wide range to occasionally produce cold/hot
# extremes — our FastNoiseLite_FBM with [-1, 1] normalization
# couldn't reach those tails without an amp hack.

var _octaves: Array[NoiseSimplex] = []
var _octave_count: int = 0


# Vanilla ng.java constructor — all octaves share ONE JavaRandom.
# Each aw consumes 3 + 256 random doubles, so each octave gets a
# different gradient table that continues from the prior.
static func create(rng: JavaRandom, octave_count: int) -> NoiseOctavesSimplex:
	var n := NoiseOctavesSimplex.new()
	n._octave_count = octave_count
	n._octaves.resize(octave_count)
	for i in range(octave_count):
		n._octaves[i] = NoiseSimplex.new(rng)
	return n


# Bulk-grid fill (2D). Mirrors `ng.java::a()` with biome_freq_decay
# parameter (vanilla's `d6`). amp_decay defaults to 0.5 like vanilla's
# 8-arg wrapper. out is indexed `i_x * size_z + i_z`.
# gdlint: disable=function-arguments-number
func sample_2d_grid(
	out: PackedFloat64Array,
	base_x: float,
	base_z: float,
	size_x: int,
	size_z: int,
	scale_x: float,
	scale_z: float,
	biome_freq_decay: float,
	amp_decay: float = 0.5
) -> void:
	scale_x /= 1.5
	scale_z /= 1.5
	out.fill(0.0)
	var amp: float = 1.0
	var freq: float = 1.0
	for i in range(_octave_count):
		_octaves[i].sample_2d_grid_additive(
			out, base_x, base_z, size_x, size_z, scale_x * freq, scale_z * freq, 0.55 / amp
		)
		freq *= biome_freq_decay
		amp *= amp_decay


# Convenience: sample at a single (x, z) point. Scale matches vanilla
# po.java's per-noise scale (0.025 for temp, 0.05 for rain, 0.25 for
# extreme) — internally divided by 1.5 by sample_2d_grid.
func sample_2d(x: float, z: float, scale: float = 1.0, biome_freq_decay: float = 0.5) -> float:
	var out: PackedFloat64Array = PackedFloat64Array()
	out.resize(1)
	sample_2d_grid(out, x, z, 1, 1, scale, scale, biome_freq_decay)
	return out[0]
