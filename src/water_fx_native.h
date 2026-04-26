#ifndef WATER_FX_NATIVE_H
#define WATER_FX_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cstdint>

namespace godot {

// Native port of vanilla Alpha 1.2.6's TextureWaterFX (oe.java in the
// CFR-decompiled source). Runs a 16×16 cellular automaton each frame
// to drive the animated water tile in terrain.png — the "boiling" look
// you see in MC Alpha screenshots that procedural hash noise can only
// approximate.
//
// Algorithm per tick (oe.java:16-76):
//   1. h[c] = (sum of 3-row vertical neighbors of g) / 3.3 + i[c] * 0.8
//   2. i[c] += j[c] * 0.05  (clamped >= 0)   ← velocity gets pushed by impulse
//      j[c] -= 0.1                            ← impulse decays
//      with 5% chance, j[c] = 0.5             ← random impulse injection
//   3. swap(g, h)
//   4. write RGBA per cell:
//        f = clamp(g[c], 0, 1); f2 = f*f
//        R = 32 + f2*32, G = 50 + f2*64, B = 255, A = 146 + f2*50
//
// We replace Math.random() with a seeded SplitMix64 so the tick stream
// is deterministic for tests; the Godot wrapper seeds it from a fixed
// value by default, and live water uses a noise() based seed so visual
// motion isn't perfectly regular.
class WaterFXNative : public RefCounted {
	GDCLASS(WaterFXNative, RefCounted);

public:
	static constexpr int GRID = 16;
	static constexpr int CELLS = GRID * GRID;

	WaterFXNative();
	~WaterFXNative();

	// Seed the internal SplitMix64. Calling reset() afterward sets all
	// buffers to zero so the visible texture starts flat.
	void set_seed(int64_t p_seed);
	void reset();

	// Run one tick. Returns the freshly-written RGBA buffer (256 cells *
	// 4 bytes = 1024 bytes) so the caller can drop it straight into an
	// `Image.set_data()` call.
	PackedByteArray tick();

protected:
	static void _bind_methods();

private:
	float g[CELLS];
	float h[CELLS];
	float i_buf[CELLS];
	float j_buf[CELLS];
	uint64_t rng_state;
	int tick_counter;

	double rng_next_unit();
};

} // namespace godot

#endif
