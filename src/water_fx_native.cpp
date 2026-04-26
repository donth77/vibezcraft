#include "water_fx_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>

using namespace godot;

WaterFXNative::WaterFXNative() : rng_state(0x9E3779B97F4A7C15ULL), tick_counter(0) {
	std::memset(g, 0, sizeof(g));
	std::memset(h, 0, sizeof(h));
	std::memset(i_buf, 0, sizeof(i_buf));
	std::memset(j_buf, 0, sizeof(j_buf));
}

WaterFXNative::~WaterFXNative() {}

void WaterFXNative::set_seed(int64_t p_seed) {
	// SplitMix64 needs a non-zero state to avoid the all-zeros fixed point.
	// Mix the seed with the golden ratio so seed=0 still produces a
	// well-distributed stream.
	rng_state = static_cast<uint64_t>(p_seed) ^ 0x9E3779B97F4A7C15ULL;
	if (rng_state == 0) {
		rng_state = 0x9E3779B97F4A7C15ULL;
	}
}

void WaterFXNative::reset() {
	std::memset(g, 0, sizeof(g));
	std::memset(h, 0, sizeof(h));
	std::memset(i_buf, 0, sizeof(i_buf));
	std::memset(j_buf, 0, sizeof(j_buf));
	tick_counter = 0;
}

// SplitMix64 — small high-quality 64-bit RNG. Returns a uniform double
// in [0, 1). Used in place of Math.random() so the tick stream is
// deterministic for parity tests.
double WaterFXNative::rng_next_unit() {
	rng_state += 0x9E3779B97F4A7C15ULL;
	uint64_t z = rng_state;
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	z = z ^ (z >> 31);
	// Top 53 bits → uniform double in [0, 1).
	return double(z >> 11) * (1.0 / double(1ULL << 53));
}

PackedByteArray WaterFXNative::tick() {
	++tick_counter;
	// Phase 1: blur g vertically (3-row sum) and mix with i. oe.java:23-33.
	// The inner loop's index `n3 + n2*16` reads cells at column `n2 = n4`
	// stepping rows `i2 = n5-1..n5+1` (with wraparound via & 0xF).
	for (int n5 = 0; n5 < GRID; ++n5) {
		for (int n4 = 0; n4 < GRID; ++n4) {
			float f2 = 0.0f;
			for (int i2 = n5 - 1; i2 <= n5 + 1; ++i2) {
				int n3 = i2 & 0xF;
				int n2 = n4 & 0xF;
				f2 += g[n3 + n2 * GRID];
			}
			h[n5 + n4 * GRID] = f2 / 3.3f + i_buf[n5 + n4 * GRID] * 0.8f;
		}
	}
	// Phase 2: integrate impulse → velocity, decay impulse, random kick.
	// oe.java:34-46.
	for (int n5 = 0; n5 < GRID; ++n5) {
		for (int n4 = 0; n4 < GRID; ++n4) {
			int n6 = n5 + n4 * GRID;
			i_buf[n6] = i_buf[n6] + j_buf[n5 + n4 * GRID] * 0.05f;
			if (i_buf[n5 + n4 * GRID] < 0.0f) {
				i_buf[n5 + n4 * GRID] = 0.0f;
			}
			int n7 = n5 + n4 * GRID;
			j_buf[n7] = j_buf[n7] - 0.1f;
			if (rng_next_unit() < 0.05) {
				j_buf[n5 + n4 * GRID] = 0.5f;
			}
		}
	}
	// Phase 3: swap g and h. After this, g holds the freshly-blurred
	// state that we encode into the RGBA buffer below.
	for (int idx = 0; idx < CELLS; ++idx) {
		float tmp = g[idx];
		g[idx] = h[idx];
		h[idx] = tmp;
	}
	// Phase 4: encode RGBA. oe.java:50-75. Vanilla writes into a
	// pre-allocated `byte[]` (`this.a`); we just produce one fresh each
	// tick and let Godot's PackedByteArray COW handle it.
	PackedByteArray out;
	out.resize(CELLS * 4);
	uint8_t *ptr = out.ptrw();
	for (int n4 = 0; n4 < CELLS; ++n4) {
		float f2 = g[n4];
		if (f2 > 1.0f) {
			f2 = 1.0f;
		}
		if (f2 < 0.0f) {
			f2 = 0.0f;
		}
		float f3 = f2 * f2;
		int r = int(32.0f + f3 * 32.0f);
		int gr = int(50.0f + f3 * 64.0f);
		int b = 255;
		int a = int(146.0f + f3 * 50.0f);
		ptr[n4 * 4 + 0] = uint8_t(r);
		ptr[n4 * 4 + 1] = uint8_t(gr);
		ptr[n4 * 4 + 2] = uint8_t(b);
		ptr[n4 * 4 + 3] = uint8_t(a);
	}
	return out;
}

void WaterFXNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &WaterFXNative::set_seed);
	ClassDB::bind_method(D_METHOD("reset"), &WaterFXNative::reset);
	ClassDB::bind_method(D_METHOD("tick"), &WaterFXNative::tick);
}
