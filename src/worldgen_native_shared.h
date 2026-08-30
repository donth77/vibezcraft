#ifndef WORLDGEN_NATIVE_SHARED_H
#define WORLDGEN_NATIVE_SHARED_H

// Primitives shared by the Overworld and Nether native generators.
//
// These lived in an anonymous namespace inside worldgen_native.cpp until
// the Nether port needed them. Nothing about them changed in the move —
// the Overworld hash fixture in tests/fixtures/overworld_baseline_hashes.json
// is what proves that.
//
// Everything here is header-only on purpose: the structs carry no static
// state, and the two grid helpers are `inline` so both translation units
// can include this without an ODR clash.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace worldgen_shared {

// Bit-exact C++ port of java.util.Random. Mirrors the GDScript
// JavaRandom in scripts/world/java_random.gd; since C++ int64_t has
// native two's-complement wrap-on-overflow, we don't need the 24-bit
// split that the GDScript version uses. Simpler + faster.
//
// Algorithm (OpenJDK):
//   seed = (input ^ MULTIPLIER) & MASK
//   next(bits):
//     seed = (seed * MULTIPLIER + INCREMENT) & MASK
//     return (int)(seed >> (48 - bits))
struct JavaRandom {
	static constexpr int64_t MULTIPLIER = 25214903917LL;  // 0x5DEECE66D
	static constexpr int64_t INCREMENT = 11LL;  // 0xB
	static constexpr int64_t MASK = 281474976710655LL;  // (1 << 48) - 1

	int64_t seed;

	explicit JavaRandom(int64_t input) { set_seed(input); }

	void set_seed(int64_t input) { seed = (input ^ MULTIPLIER) & MASK; }

	int next(int bits) {
		seed = (seed * MULTIPLIER + INCREMENT) & MASK;
		return static_cast<int>(seed >> (48 - bits));
	}

	// java.util.Random.nextInt(int bound). Power-of-2 fast path +
	// rejection sampling — byte-exact with OpenJDK.
	int next_int_bounded(int bound) {
		if (bound <= 0) {
			return 0;
		}
		if ((bound & -bound) == bound) {
			// Power of 2 — exact bijection via 31-bit multiply.
			return static_cast<int>((int64_t(bound) * int64_t(next(31))) >> 31);
		}
		int bits = next(31);
		int val = bits % bound;
		while (bits - val + (bound - 1) < 0) {
			bits = next(31);
			val = bits % bound;
		}
		return val;
	}

	// Signed int64. (int)next(32) << 32 + next(32); first is sign-
	// extended to 64 bits, second is treated as unsigned 32 bits.
	// KNOWN DEVIATION from Java, kept deliberately. OpenJDK's nextLong is
	// `((long)next(32) << 32) + next(32)` with BOTH halves sign-extended,
	// so a negative low word subtracts; this runs 2^32 high in that case.
	// The GDScript side matched the same mistake, which is why the
	// two-way parity tests never caught it — see
	// tests/test_alpha_source_oracle.gd, where the JDK itself is the
	// oracle.
	//
	// Only the cave generator calls this, and its output is baked into
	// every Overworld world already saved, so correcting it here would
	// re-carve unvisited chunks of existing saves. GDScript pins the same
	// behaviour behind JavaRandom.next_long_legacy_unsigned_low(). Any
	// NEW native generator (the Nether, Batch 5) must use a correctly
	// sign-extended nextLong instead.
	int64_t next_long_legacy_unsigned_low() {
		const int64_t high = static_cast<int32_t>(next(32));  // sign-extend
		const int64_t low = static_cast<uint32_t>(next(32));  // unsigned (the deviation)
		return (high << 32) + low;
	}

	// True Java parity — use this for anything new.
	int64_t next_long() {
		const int64_t high = static_cast<int32_t>(next(32));
		const int64_t low = static_cast<int32_t>(next(32));
		return (high << 32) + low;
	}

	// 24-bit precision float in [0, 1).
	float next_float() { return static_cast<float>(next(24)) / 16777216.0f; }

	// 53-bit precision double in [0, 1).
	double next_double() {
		const int64_t high = static_cast<int64_t>(next(26));
		const int64_t low = static_cast<int64_t>(next(27));
		return static_cast<double>((high << 27) + low) / 9007199254740992.0;
	}
};

// ===========================================================================
// NoisePerlin — bit-exact port of vanilla Alpha 1.2.6 z.java (Perlin noise).
// Mirror of scripts/world/noise_perlin.gd. Used by the e/f/selector/h/g/
// beach/soil/forest noise stacks in 3D density terrain generation.
// ===========================================================================
struct NoisePerlin {
	int perm[512];
	double x_offset;
	double y_offset;
	double z_offset;

	explicit NoisePerlin(JavaRandom &rng) {
		x_offset = rng.next_double() * 256.0;
		y_offset = rng.next_double() * 256.0;
		z_offset = rng.next_double() * 256.0;
		for (int i = 0; i < 256; i++) {
			perm[i] = i;
		}
		for (int n = 0; n < 256; n++) {
			const int swap_idx = rng.next_int_bounded(256 - n) + n;
			const int tmp = perm[n];
			perm[n] = perm[swap_idx];
			perm[swap_idx] = tmp;
			perm[n + 256] = perm[n];
		}
	}

	static inline double lerp(double t, double a, double b) {
		return a + t * (b - a);
	}

	static inline double grad_3d(int hash, double x, double y, double z) {
		const int n3 = hash & 0xF;
		const double d5 = (n3 < 8) ? x : y;
		double d7;
		if (n3 < 4) {
			d7 = y;
		} else if (n3 == 12 || n3 == 14) {
			d7 = x;
		} else {
			d7 = z;
		}
		const double sd5 = ((n3 & 1) != 0) ? -d5 : d5;
		const double sd7 = ((n3 & 2) != 0) ? -d7 : d7;
		return sd5 + sd7;
	}

	// 3D Perlin sample. Mirror of z.java::a(double, double, double).
	double sample_3d(double x, double y, double z) const {
		double d5 = x + x_offset;
		double d6 = y + y_offset;
		double d7 = z + z_offset;
		int n2 = static_cast<int>(d5);
		int n3 = static_cast<int>(d6);
		int n4 = static_cast<int>(d7);
		if (d5 < static_cast<double>(n2)) {
			n2 -= 1;
		}
		if (d6 < static_cast<double>(n3)) {
			n3 -= 1;
		}
		if (d7 < static_cast<double>(n4)) {
			n4 -= 1;
		}
		const int n5 = n2 & 0xFF;
		const int n6 = n3 & 0xFF;
		const int n7 = n4 & 0xFF;
		d5 -= static_cast<double>(n2);
		d6 -= static_cast<double>(n3);
		d7 -= static_cast<double>(n4);
		const double d8 = d5 * d5 * d5 * (d5 * (d5 * 6.0 - 15.0) + 10.0);
		const double d9 = d6 * d6 * d6 * (d6 * (d6 * 6.0 - 15.0) + 10.0);
		const double d10 = d7 * d7 * d7 * (d7 * (d7 * 6.0 - 15.0) + 10.0);
		const int n8 = perm[n5] + n6;
		const int n9 = perm[n8] + n7;
		const int n10 = perm[n8 + 1] + n7;
		const int n11 = perm[n5 + 1] + n6;
		const int n12 = perm[n11] + n7;
		const int n13 = perm[n11 + 1] + n7;
		return lerp(d10,
				lerp(d9,
						lerp(d8, grad_3d(perm[n9], d5, d6, d7),
								grad_3d(perm[n12], d5 - 1.0, d6, d7)),
						lerp(d8, grad_3d(perm[n10], d5, d6 - 1.0, d7),
								grad_3d(perm[n13], d5 - 1.0, d6 - 1.0, d7))),
				lerp(d9,
						lerp(d8,
								grad_3d(perm[n9 + 1], d5, d6, d7 - 1.0),
								grad_3d(perm[n12 + 1], d5 - 1.0, d6, d7 - 1.0)),
						lerp(d8,
								grad_3d(perm[n10 + 1], d5, d6 - 1.0, d7 - 1.0),
								grad_3d(perm[n13 + 1], d5 - 1.0, d6 - 1.0, d7 - 1.0))));
	}

	// Bulk 3D grid additive fill — accumulates noise values into out[].
	// Mirror of z.java::a(double[], ...) bulk method. Uses the inner-cache
	// trick (vanilla cache d18-d21 across i6 iterations when n28 unchanged).
	// out is indexed (x * size_y + y) * size_z + z (vanilla layout, Y inner).
	void sample_3d_grid_additive(double *out, double base_x, double base_y, double base_z,
			int size_x, int size_y, int size_z, double scale_x, double scale_y, double scale_z,
			double amp_divisor) const {
		if (size_y == 1) {
			sample_2d_grid_additive(out, base_x, base_z, size_x, size_z, scale_x, scale_z,
					amp_divisor);
			return;
		}
		const double inv_amp = 1.0 / amp_divisor;
		int n15 = 0;
		int n16 = -1, n17 = 0, n18 = 0, n19 = 0, n20 = 0, n21 = 0, n22 = 0;
		double d18 = 0, d19 = 0, d20 = 0, d21 = 0;
		for (int i4 = 0; i4 < size_x; i4++) {
			double d22 = (base_x + double(i4)) * scale_x + x_offset;
			int n23 = static_cast<int>(d22);
			if (d22 < double(n23)) {
				n23 -= 1;
			}
			const int n24 = n23 & 0xFF;
			d22 -= double(n23);
			const double d23 = d22 * d22 * d22 * (d22 * (d22 * 6.0 - 15.0) + 10.0);
			for (int i5 = 0; i5 < size_z; i5++) {
				double d24 = (base_z + double(i5)) * scale_z + z_offset;
				int n25 = static_cast<int>(d24);
				if (d24 < double(n25)) {
					n25 -= 1;
				}
				const int n26 = n25 & 0xFF;
				d24 -= double(n25);
				const double d25 = d24 * d24 * d24 * (d24 * (d24 * 6.0 - 15.0) + 10.0);
				for (int i6 = 0; i6 < size_y; i6++) {
					double d26 = (base_y + double(i6)) * scale_y + y_offset;
					int n27 = static_cast<int>(d26);
					if (d26 < double(n27)) {
						n27 -= 1;
					}
					const int n28 = n27 & 0xFF;
					d26 -= double(n27);
					const double d27 = d26 * d26 * d26 * (d26 * (d26 * 6.0 - 15.0) + 10.0);
					if (i6 == 0 || n28 != n16) {
						n16 = n28;
						n17 = perm[n24] + n28;
						n18 = perm[n17] + n26;
						n19 = perm[n17 + 1] + n26;
						n20 = perm[n24 + 1] + n28;
						n21 = perm[n20] + n26;
						n22 = perm[n20 + 1] + n26;
						d18 = lerp(d23, grad_3d(perm[n18], d22, d26, d24),
								grad_3d(perm[n21], d22 - 1.0, d26, d24));
						d19 = lerp(d23, grad_3d(perm[n19], d22, d26 - 1.0, d24),
								grad_3d(perm[n22], d22 - 1.0, d26 - 1.0, d24));
						d20 = lerp(d23, grad_3d(perm[n18 + 1], d22, d26, d24 - 1.0),
								grad_3d(perm[n21 + 1], d22 - 1.0, d26, d24 - 1.0));
						d21 = lerp(d23, grad_3d(perm[n19 + 1], d22, d26 - 1.0, d24 - 1.0),
								grad_3d(perm[n22 + 1], d22 - 1.0, d26 - 1.0, d24 - 1.0));
					}
					const double d28 = lerp(d27, d18, d19);
					const double d29 = lerp(d27, d20, d21);
					const double d30 = lerp(d25, d28, d29);
					out[n15] += d30 * inv_amp;
					n15++;
				}
			}
		}
	}

	// 2D-optimized grid path (vanilla z.java:89-126).
	void sample_2d_grid_additive(double *out, double base_x, double base_z, int size_x,
			int size_z, double scale_x, double scale_z, double amp_divisor) const {
		const double inv_amp = 1.0 / amp_divisor;
		int n9 = 0;
		for (int i2 = 0; i2 < size_x; i2++) {
			double d12 = (base_x + double(i2)) * scale_x + x_offset;
			int n10 = static_cast<int>(d12);
			if (d12 < double(n10)) {
				n10 -= 1;
			}
			const int n11 = n10 & 0xFF;
			d12 -= double(n10);
			const double d13 = d12 * d12 * d12 * (d12 * (d12 * 6.0 - 15.0) + 10.0);
			for (int i3 = 0; i3 < size_z; i3++) {
				double d14 = (base_z + double(i3)) * scale_z + z_offset;
				int n12 = static_cast<int>(d14);
				if (d14 < double(n12)) {
					n12 -= 1;
				}
				const int n13 = n12 & 0xFF;
				d14 -= double(n12);
				const double d15 = d14 * d14 * d14 * (d14 * (d14 * 6.0 - 15.0) + 10.0);
				const int n5 = perm[n11] + 0;
				const int n6 = perm[n5] + n13;
				const int n7 = perm[n11 + 1] + 0;
				const int n8 = perm[n7] + n13;
				const double d9 = lerp(d13, grad_3d(perm[n6], d12, 0.0, d14),
						grad_3d(perm[n8], d12 - 1.0, 0.0, d14));
				const double d10 = lerp(d13,
						grad_3d(perm[n6 + 1], d12, 0.0, d14 - 1.0),
						grad_3d(perm[n8 + 1], d12 - 1.0, 0.0, d14 - 1.0));
				const double d16 = lerp(d15, d9, d10);
				out[n9] += d16 * inv_amp;
				n9++;
			}
		}
	}
};

// NoiseOctaves bulk grid (vanilla nf.a 10-arg). Accumulates per-octave
// reverse-FBM into out[]. amp_v halves per octave; coords are pre-
// multiplied by amp_v; sample is divided by amp_v (= contribution multiplier).
inline void octaves_3d_grid(const std::vector<NoisePerlin> &octaves, double *out,
		double base_x, double base_y, double base_z, int sx, int sy, int sz, double scale_x,
		double scale_y, double scale_z) {
	std::fill(out, out + sx * sy * sz, 0.0);
	double amp_v = 1.0;
	for (const auto &o : octaves) {
		o.sample_3d_grid_additive(
				out, base_x, base_y, base_z, sx, sy, sz,
				scale_x * amp_v, scale_y * amp_v, scale_z * amp_v, amp_v);
		amp_v /= 2.0;
	}
}

// 2D bulk grid (vanilla nf.a 8-arg wrapper) — base_y=10, scale_y=1, size_y=1.
inline void octaves_2d_grid(const std::vector<NoisePerlin> &octaves, double *out, double base_x,
		double base_z, int sx, int sz, double scale_x, double scale_z) {
	std::fill(out, out + sx * sz, 0.0);
	double amp_v = 1.0;
	for (const auto &o : octaves) {
		o.sample_3d_grid_additive(
				out, base_x, 10.0, base_z, sx, 1, sz,
				scale_x * amp_v, 1.0 * amp_v, scale_z * amp_v, amp_v);
		amp_v /= 2.0;
	}
}

}  // namespace worldgen_shared

#endif  // WORLDGEN_NATIVE_SHARED_H
