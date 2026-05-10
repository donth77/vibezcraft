class_name NoiseOctaves
extends RefCounted

# Port of vanilla Alpha 1.2.6 nf.java (NoiseGeneratorOctaves) — slice 3-A
# of the 3D-density-terrain port (see .claude/worldgen-deferred.md).
#
# Vanilla algorithm (verbatim from `nf.java`):
#   public double a(double d2, double d3) {
#       double d4 = 0.0;        // sum
#       double d5 = 1.0;        // amplitude factor
#       for (int i2 = 0; i2 < this.b; ++i2) {
#           d4 += this.a[i2].a(d2 * d5, d3 * d5) / d5;
#           d5 /= 2.0;
#       }
#       return d4;
#   }
#
# This is REVERSE-FBM:
#   * d5 starts at 1.0 and HALVES per octave → coordinate scale shrinks
#     (lower frequency, larger features) per iteration.
#   * Result is divided by d5 → effective amplitude DOUBLES per octave.
#   * Net effect: low-frequency octaves dominate. With N=16 octaves the
#     last octave contributes at amplitude 2^15 ≈ 32k while the first
#     contributes at amplitude 1. The big features set the baseline; the
#     small features just decorate.
#
# This shape is what gives Alpha terrain its characteristic "continents
# with detail riding on top" look — opposite of the default-FastNoiseLite
# FBM (gain=0.5) which makes small features dominate (the islandy/over-
# beached feel we shipped previously).
#
# Faithfulness vs perf:
#   * NOT bit-faithful to vanilla — vanilla uses Java Random + a custom
#     Perlin gradient table (z.java); we use FastNoiseLite per-octave.
#     Same SHAPE characteristics (reverse-FBM, large-feature dominance);
#     different seed → different exact values at the same coordinates.
#   * Pragmatic: FastNoiseLite is already in the codebase and well-
#     optimized. Rewriting Java's Random + Perlin from scratch for bit-
#     parity would be substantial work for no gameplay-visible benefit
#     (the player can't see the difference between two reverse-FBM
#     stacks at the same scale).
#   * Native C++ port lands in slice 3-A2 (worldgen_native.cpp) once the
#     density-grid integration in slice 3-B confirms the algorithm lands
#     correctly. Until then, GDScript-only.

# Default FastNoiseLite frequency for each octave's Perlin. We pre-bake
# the spatial scaling into the sample coords (vanilla pattern), so the
# Perlin itself just samples at unit frequency.
const _PERLIN_BASE_FREQUENCY: float = 1.0

var _octaves: Array[FastNoiseLite] = []
var _vanilla_octaves: Array[NoisePerlin] = []  # populated when create_vanilla() used
var _octave_count: int = 0
var _is_vanilla: bool = false


# Construct a NoiseOctaves with `octave_count` Perlin layers, all derived
# from `base_seed`. Each octave gets a distinct seed (`base_seed + i`)
# so the per-octave Perlins aren't correlated — vanilla nf.java does the
# same by passing the SAME Random instance to each `new z(random)` (each
# z constructor consumes Random output, so each octave ends up with a
# different gradient table). We use seed offset instead because
# FastNoiseLite seeds are int and mixing them deterministically is
# trivial without porting Java Random.
static func create(base_seed: int, octave_count: int) -> NoiseOctaves:
	var n := NoiseOctaves.new()
	n._octave_count = octave_count
	n._is_vanilla = false
	n._octaves.resize(octave_count)
	for i in range(octave_count):
		var perlin := FastNoiseLite.new()
		perlin.noise_type = FastNoiseLite.TYPE_PERLIN
		perlin.frequency = _PERLIN_BASE_FREQUENCY
		# Distinct seed per octave. base_seed + i is the simplest mix that
		# stays deterministic on `apply_world_seed` — no need to hash since
		# adjacent integers already produce uncorrelated Perlin tables.
		perlin.seed = base_seed + i
		# Single-octave per FastNoiseLite — we do the multi-octave summation
		# ourselves in sample_2d/sample_3d_grid so we control the reverse-FBM
		# behavior. FRACTAL_NONE keeps each get_noise_*d call cheap.
		perlin.fractal_type = FastNoiseLite.FRACTAL_NONE
		n._octaves[i] = perlin
	return n


# Vanilla `nf.java` constructor pattern — all octaves share ONE JavaRandom.
# Each NoisePerlin constructor pulls 256+3 random doubles from the SAME
# Random instance, so each octave's gradient table is a deterministic
# continuation of the prior. This is what gives vanilla its distinctive
# noise distribution (correlated octaves with specific bit-relationships)
# vs our FastNoiseLite-based approach (independent per-octave seeds).
#
# Use this when you need vanilla-shape noise output (wider variance,
# proper reverse-FBM tail behavior). The trade is ~2× slower per sample
# than FastNoiseLite (GDScript Perlin vs C++ FastNoiseLite).
static func create_vanilla(world_seed: int, octave_count: int) -> NoiseOctaves:
	var n := NoiseOctaves.new()
	n._octave_count = octave_count
	n._is_vanilla = true
	n._vanilla_octaves.resize(octave_count)
	# All octaves consume from the same Random — vanilla nf.java pattern.
	var rng := JavaRandom.new(world_seed)
	for i in range(octave_count):
		n._vanilla_octaves[i] = NoisePerlin.new(rng)
	return n


# Vanilla nf.a(double, double) — 2D sample. Returns the summed reverse-FBM
# value. Output range: roughly [-2^N, 2^N] where N = octave_count, since
# each Perlin returns ~[-1, 1] and the last octave's contribution is
# divided by 2^(N-1) (which means MULTIPLIED by 2^(N-1) in reverse-FBM
# math — see top-of-file commentary).
func sample_2d(x: float, z: float) -> float:
	var sum: float = 0.0
	# `amp` is vanilla's `d5` — starts at 1.0, halves each octave. The
	# coords get multiplied by `amp` (smaller frequency per octave); the
	# result gets divided by `amp` (larger amplitude per octave).
	var amp: float = 1.0
	if _is_vanilla:
		for i in range(_octave_count):
			sum += _vanilla_octaves[i].sample_2d(x * amp, z * amp) / amp
			amp /= 2.0
		return sum
	for i in range(_octave_count):
		sum += _octaves[i].get_noise_2d(x * amp, z * amp) / amp
		amp /= 2.0
	return sum


# Vanilla nf.a(double[], baseX, baseY, baseZ, sizeX, sizeY, sizeZ,
# scaleX, scaleY, scaleZ) — fill a flat 3D grid via reverse-FBM. The
# output array is indexed `(x * size_y + y) * size_z + z` (vanilla
# layout, mirror of px.java's density grid access pattern).
#
# Per-cell sampling in GDScript (slow-but-correct path); native C++
# slice (3-A2) will use a per-octave grid sweep that matches vanilla's
# `z.java.a(double[], ...)` block-fill API. For now, ~5×5×17 = 425
# cells × N octaves Perlin samples per chunk — at FastNoiseLite ~50ns
# per sample × 16 octaves × 425 cells ≈ 340µs. Workable on the worker
# thread; the parity-test reference path doesn't need to be fast.
func sample_3d_grid(
	out: PackedFloat64Array,
	base_x: float,
	base_y: float,
	base_z: float,
	size_x: int,
	size_y: int,
	size_z: int,
	scale_x: float,
	scale_y: float,
	scale_z: float
) -> void:
	# Vanilla noise path: per-octave NoisePerlin's bulk grid fill (vanilla
	# z.java:88 pattern). Each call accumulates additively — pre-zero
	# the buffer first.
	if _is_vanilla:
		out.fill(0.0)
		var amp_v: float = 1.0
		for i in range(_octave_count):
			# Vanilla nf.java:39 passes (scale * d8, ..., d8); z.java
			# uses 1/d8 as the per-cell multiplier internally. So the
			# 10th argument is the AMP itself (not 1/amp).
			_vanilla_octaves[i].sample_3d_grid_additive(
				out,
				base_x,
				base_y,
				base_z,
				size_x,
				size_y,
				size_z,
				scale_x * amp_v,
				scale_y * amp_v,
				scale_z * amp_v,
				amp_v
			)
			amp_v /= 2.0
		return
	# Native fast path — same FastNoiseLite instances are passed to
	# C++, so noise output is byte-identical to the GDScript loop below.
	# ~10× faster (Variant dispatch overhead per get_noise_3d call is
	# the dominant cost in the GDScript path).
	if Worldgen._native_worldgen != null:
		var native_out: PackedFloat64Array = (
			Worldgen
			. _native_worldgen
			. call(
				"sample_noise_grid_3d",
				_octaves,
				base_x,
				base_y,
				base_z,
				size_x,
				size_y,
				size_z,
				scale_x,
				scale_y,
				scale_z,
			)
		)
		# Copy into the caller-supplied output buffer (signature contract).
		for i in range(native_out.size()):
			out[i] = native_out[i]
		return
	# Pre-zero so we accumulate per-octave contributions on top.
	out.fill(0.0)
	var amp: float = 1.0
	for octave in range(_octave_count):
		var fx_scale: float = scale_x * amp
		var fy_scale: float = scale_y * amp
		var fz_scale: float = scale_z * amp
		var inv_amp: float = 1.0 / amp
		for x in range(size_x):
			var sx: float = (base_x + float(x)) * fx_scale
			for y in range(size_y):
				var sy: float = (base_y + float(y)) * fy_scale
				for z in range(size_z):
					var sz: float = (base_z + float(z)) * fz_scale
					var idx: int = (x * size_y + y) * size_z + z
					out[idx] += _octaves[octave].get_noise_3d(sx, sy, sz) * inv_amp
		amp /= 2.0
