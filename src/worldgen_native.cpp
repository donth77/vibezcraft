#include "worldgen_native.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

using namespace godot;

namespace {

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
	int64_t next_long() {
		const int64_t high = static_cast<int32_t>(next(32));  // sign-extend
		const int64_t low = static_cast<uint32_t>(next(32));  // unsigned
		return (high << 32) + low;
	}

	// 24-bit precision float in [0, 1).
	float next_float() { return static_cast<float>(next(24)) / 16777216.0f; }
};

// Mirror worldgen_caves.gd constants.
constexpr int CAVES_RADIUS_CHUNKS = 8;
// Must stay in sync with worldgen_caves.gd::_CAVE_MAX_Y. Capped below
// sea level (SEA_LEVEL - 5 = 59) so caves don't break through ocean
// floors. Visual cleanup; deviation from vanilla 120.
constexpr int CAVE_MAX_Y = 59;
constexpr double CAVE_PI = 3.141592653589793;
constexpr double CAVE_TAU = 2.0 * CAVE_PI;

// Cell read — target chunk only. CAVES never read across chunk
// boundaries; the cross-chunk effect comes from the 17×17 seed loop,
// each iteration of which is clipped to the target chunk's AABB.
inline int chunk_read(const uint8_t *blocks_ptr, int x, int y, int z) {
	return blocks_ptr[y * WorldgenNative::SIZE_X * WorldgenNative::SIZE_Z
			+ z * WorldgenNative::SIZE_X + x];
}

inline void chunk_write(uint8_t *blocks_ptr, int x, int y, int z, int id) {
	blocks_ptr[y * WorldgenNative::SIZE_X * WorldgenNative::SIZE_Z
			+ z * WorldgenNative::SIZE_X + x] = static_cast<uint8_t>(id);
}

inline bool is_water_id(int id) {
	return id == WorldgenNative::WATER_FLOWING || id == WorldgenNative::WATER_STILL;
}

// AABB touches-water scan — early-abort a worm carve if any cell in
// the bounding box is already water (lakes / ocean fill). Mirrors
// worldgen_caves.gd::_aabb_touches_water.
bool aabb_touches_water(
		const uint8_t *blocks_ptr, int mnx, int mxx, int mny, int mxy, int mnz, int mxz) {
	const int y_lo = std::max(mny, 0);
	const int y_hi = std::min(mxy + 1, WorldgenNative::SIZE_Y);
	for (int ax = mnx; ax < mxx; ax++) {
		for (int az = mnz; az < mxz; az++) {
			for (int ay = y_lo; ay < y_hi; ay++) {
				if (is_water_id(chunk_read(blocks_ptr, ax, ay, az))) {
					return true;
				}
			}
		}
	}
	return false;
}

// lx.java:101-128 — carve cells inside the ellipsoid. Top-down y-scan
// so GRASS is detected before the DIRT below; AIR above y=10 and
// LAVA_STILL below y=10 replace STONE/DIRT/GRASS, and the underside of
// a GRASS cell gets DIRT → GRASS rewritten so the cave mouth looks
// vanilla. Mirrors worldgen_caves.gd::_carve_ellipsoid line-for-line.
void carve_ellipsoid(uint8_t *blocks_ptr, int chunk_x, int chunk_z, double pos_x,
		double pos_y, double pos_z, double horiz_r, double vert_r, int mnx, int mxx, int mny,
		int mxy, int mnz, int mxz) {
	for (int ax = mnx; ax < mxx; ax++) {
		const double nx = (double(ax + chunk_x * 16) + 0.5 - pos_x) / horiz_r;
		const double nx2 = nx * nx;
		for (int az = mnz; az < mxz; az++) {
			const double nz = (double(az + chunk_z * 16) + 0.5 - pos_z) / horiz_r;
			const double nz2 = nz * nz;
			bool saw_grass = false;
			for (int ay = mxy - 1; ay >= mny; ay--) {
				if (ay < 1 || ay >= CAVE_MAX_Y) {
					continue;
				}
				const double ny = (double(ay) + 0.5 - pos_y) / vert_r;
				if (ny <= -0.7) {
					continue;
				}
				if (nx2 + ny * ny + nz2 >= 1.0) {
					continue;
				}
				const int id = chunk_read(blocks_ptr, ax, ay, az);
				if (id == WorldgenNative::GRASS) {
					saw_grass = true;
				}
				if (id != WorldgenNative::STONE && id != WorldgenNative::DIRT
						&& id != WorldgenNative::GRASS) {
					continue;
				}
				// lx.java:115-116 — ay<10 writes LAVA_STILL instead of AIR.
				if (ay < 10) {
					chunk_write(blocks_ptr, ax, ay, az, WorldgenNative::LAVA_STILL);
				} else {
					chunk_write(blocks_ptr, ax, ay, az, WorldgenNative::AIR);
				}
				if (saw_grass && ay > 0) {
					if (chunk_read(blocks_ptr, ax, ay - 1, az) == WorldgenNative::DIRT) {
						chunk_write(blocks_ptr, ax, ay - 1, az, WorldgenNative::GRASS);
					}
				}
			}
		}
	}
}

// Forward decl — carve_worm calls itself recursively for branches.
void carve_worm(JavaRandom &outer_rng, uint8_t *blocks_ptr, int chunk_x, int chunk_z,
		double init_x, double init_y, double init_z, double width, double init_yaw,
		double init_pitch, int init_step, int init_length, double vertical_scale);

// lx.java:10-135 — the worm random-walk. Port of
// worldgen_caves.gd::_carve_worm. Uses its OWN JavaRandom seeded from
// outer.next_long() — lets branches diverge without biasing the outer
// chunk stream.
void carve_worm(JavaRandom &outer_rng, uint8_t *blocks_ptr, int chunk_x, int chunk_z,
		double init_x, double init_y, double init_z, double width, double init_yaw,
		double init_pitch, int init_step, int init_length, double vertical_scale) {
	JavaRandom worm_rng(outer_rng.next_long());
	const double origin_x = double(chunk_x * 16 + 8);
	const double origin_z = double(chunk_z * 16 + 8);

	int length = init_length;
	if (length <= 0) {
		const int base = 128 - 16;  // 112
		length = base - worm_rng.next_int_bounded(base / 4);
	}

	int step = init_step;
	bool is_room = false;
	if (step == -1) {
		step = length / 2;
		is_room = true;
	}

	const int branch_step = worm_rng.next_int_bounded(length / 2) + length / 4;
	const bool tight_drift = worm_rng.next_int_bounded(6) == 0;
	double yaw_accel = 0.0;
	double pitch_accel = 0.0;
	double pos_x = init_x;
	double pos_y = init_y;
	double pos_z = init_z;
	double yaw = init_yaw;
	double pitch = init_pitch;

	while (step < length) {
		const double horiz_radius =
				1.5 + std::sin(double(step) * CAVE_PI / double(length)) * width;
		const double vert_radius = horiz_radius * vertical_scale;
		const double cos_p = std::cos(pitch);
		pos_x += std::cos(yaw) * cos_p;
		pos_y += std::sin(pitch);
		pos_z += std::sin(yaw) * cos_p;
		pitch *= tight_drift ? 0.92 : 0.7;
		pitch += pitch_accel * 0.1;
		yaw += yaw_accel * 0.1;
		pitch_accel *= 0.9;
		yaw_accel *= 0.75;
		// CRITICAL: float ops must use DOUBLE precision to match GDScript
		// floats (which are 64-bit). JavaRandom.next_float returns a float32,
		// but the subsequent arithmetic (subtract, multiply) is done in
		// f64 in GDScript; mirror here by casting up.
		pitch_accel += (double(worm_rng.next_float()) - double(worm_rng.next_float()))
				* double(worm_rng.next_float()) * 2.0;
		yaw_accel += (double(worm_rng.next_float()) - double(worm_rng.next_float()))
				* double(worm_rng.next_float()) * 4.0;

		// Mid-worm branch spawn — only for non-room main worms wider than 1.
		if (!is_room && step == branch_step && width > 1.0) {
			carve_worm(outer_rng, blocks_ptr, chunk_x, chunk_z, pos_x, pos_y, pos_z,
					double(worm_rng.next_float()) * 0.5 + 0.5, yaw - CAVE_PI / 2.0, pitch / 3.0,
					step, length, 1.0);
			carve_worm(outer_rng, blocks_ptr, chunk_x, chunk_z, pos_x, pos_y, pos_z,
					double(worm_rng.next_float()) * 0.5 + 0.5, yaw + CAVE_PI / 2.0, pitch / 3.0,
					step, length, 1.0);
			return;
		}

		// 3-in-4 carve, room variants always.
		if (!is_room && worm_rng.next_int_bounded(4) == 0) {
			step++;
			continue;
		}

		// Early-abort if we've wandered too far from target chunk.
		const double dx = pos_x - origin_x;
		const double dz = pos_z - origin_z;
		const double steps_remaining = double(length - step);
		const double max_reach = width + 2.0 + 16.0;
		if (dx * dx + dz * dz - steps_remaining * steps_remaining > max_reach * max_reach) {
			return;
		}

		// AABB-outside-chunk quick skip.
		if (pos_x < origin_x - 16.0 - horiz_radius * 2.0
				|| pos_z < origin_z - 16.0 - horiz_radius * 2.0
				|| pos_x > origin_x + 16.0 + horiz_radius * 2.0
				|| pos_z > origin_z + 16.0 + horiz_radius * 2.0) {
			step++;
			continue;
		}

		// Compute carve AABB in chunk-local coords, clipped to chunk bounds.
		const int carve_min_x = std::max(int(std::floor(pos_x - horiz_radius)) - chunk_x * 16 - 1, 0);
		const int carve_max_x = std::min(int(std::floor(pos_x + horiz_radius)) - chunk_x * 16 + 1,
				WorldgenNative::SIZE_X);
		const int carve_min_y = std::max(int(std::floor(pos_y - vert_radius)) - 1, 1);
		const int carve_max_y = std::min(int(std::floor(pos_y + vert_radius)) + 1, CAVE_MAX_Y);
		const int carve_min_z = std::max(int(std::floor(pos_z - horiz_radius)) - chunk_z * 16 - 1, 0);
		const int carve_max_z = std::min(int(std::floor(pos_z + horiz_radius)) - chunk_z * 16 + 1,
				WorldgenNative::SIZE_Z);

		// Skip carve if AABB touches any existing water cell (lakes/ocean).
		if (aabb_touches_water(blocks_ptr, carve_min_x, carve_max_x, carve_min_y, carve_max_y,
					carve_min_z, carve_max_z)) {
			step++;
			continue;
		}

		carve_ellipsoid(blocks_ptr, chunk_x, chunk_z, pos_x, pos_y, pos_z, horiz_radius,
				vert_radius, carve_min_x, carve_max_x, carve_min_y, carve_max_y, carve_min_z,
				carve_max_z);

		if (is_room) {
			break;
		}
		step++;
	}
}

// lx.java:137-158 — inner generator for a single seed-chunk. `rng` is
// already seeded for (seed_cx, seed_cz). Must consume the RNG stream in
// the exact same order as worldgen_caves.gd::_spawn_from_seed_chunk.
void spawn_from_seed_chunk(JavaRandom &rng, uint8_t *blocks_ptr, int chunk_x, int chunk_z,
		int seed_cx, int seed_cz) {
	const int n_outer = rng.next_int_bounded(40) + 1;
	const int n_mid = rng.next_int_bounded(n_outer) + 1;
	int cave_count = rng.next_int_bounded(n_mid);
	if (rng.next_int_bounded(15) != 0) {
		cave_count = 0;
	}
	for (int i = 0; i < cave_count; i++) {
		const double x = double(seed_cx * 16 + rng.next_int_bounded(16));
		const int y_outer = rng.next_int_bounded(120) + 8;
		const double y = double(rng.next_int_bounded(y_outer));
		const double z = double(seed_cz * 16 + rng.next_int_bounded(16));
		int worm_count = 1;
		if (rng.next_int_bounded(4) == 0) {
			carve_worm(rng, blocks_ptr, chunk_x, chunk_z, x, y, z,
					1.0 + double(rng.next_float()) * 6.0, 0.0, 0.0, -1, -1, 0.5);
			worm_count += rng.next_int_bounded(4);
		}
		for (int w = 0; w < worm_count; w++) {
			const double yaw = double(rng.next_float()) * CAVE_TAU;
			const double pitch = (double(rng.next_float()) - 0.5) * 2.0 / 8.0;
			const double width = double(rng.next_float()) * 2.0 + double(rng.next_float());
			carve_worm(rng, blocks_ptr, chunk_x, chunk_z, x, y, z, width, yaw, pitch, 0, 0, 1.0);
		}
	}
}

}  // namespace

// Mirror Worldgen._BEDROCK_THRESHOLDS_FIFTHS. Alpha 1.2.6 px.java:119
// does `if (i4 <= 0 + this.j.nextInt(5))` → per-layer probabilities
// 5/5, 4/5, 3/5, 2/5, 1/5 for y=0..4. We hash into the same distribution
// via `(hash3 % 5) < threshold`.
static const int BEDROCK_THRESHOLDS_FIFTHS[5] = { 5, 4, 3, 2, 1 };

// Definition for the mutable static seed. Default mirrors GDScript
// Worldgen.WORLD_SEED for back-compat; rewritten by Worldgen.apply_world_seed
// via the bound set_world_seed method below.
int64_t WorldgenNative::world_seed = 12345;

WorldgenNative::WorldgenNative() {}

WorldgenNative::~WorldgenNative() {}

void WorldgenNative::set_world_seed(int64_t p_seed) {
	world_seed = p_seed;
}

int64_t WorldgenNative::hash3(int64_t x, int64_t y, int64_t z) {
	int64_t h = world_seed;
	h = (h * 73856093LL) ^ x;
	h = (h * 19349663LL) ^ y;
	h = (h * 83492791LL) ^ z;
	// Final Knuth multiplicative mix — must match GDScript Worldgen._hash3
	// exactly so bedrock-band placement stays identical across paths.
	h = h * 2654435761LL;
	// absi: mirrors the trailing absi(h). Ternary matches Godot's
	// `x < 0 ? -x : x` semantics on signed-int64 edge cases.
	return h < 0 ? -h : h;
}

int64_t WorldgenNative::hash4(int64_t a, int64_t b, int64_t c, int64_t d) {
	int64_t h = world_seed;
	h = (h * 73856093LL) ^ a;
	h = (h * 19349663LL) ^ b;
	h = (h * 83492791LL) ^ c;
	h = (h * 49979693LL) ^ d;
	h = h * 2654435761LL;
	return h < 0 ? -h : h;
}

double WorldgenNative::float01(int64_t seed_hash, int64_t salt) {
	// Mirrors Worldgen._float01: low 24 bits of hash3(seed, salt, 0x5E1D)
	// divided by 2^24. Keeps full float precision, no allocations.
	return static_cast<double>(hash3(seed_hash, salt, 0x5E1DLL) & 0xFFFFFFLL) / 16777216.0;
}

bool WorldgenNative::is_bedrock_at(int world_x, int y, int world_z) {
	if (y < 1 || y > 4) {
		return false;
	}
	const int threshold = BEDROCK_THRESHOLDS_FIFTHS[y];
	return (hash3(world_x, y, world_z) % 5) < threshold;
}

int WorldgenNative::block_at(int world_x, int y, int world_z, int surface_y) {
	if (y == 0) {
		return BEDROCK;
	}
	if (y <= 4 && is_bedrock_at(world_x, y, world_z)) {
		return BEDROCK;
	}
	if (y == surface_y) {
		// Below sea = DIRT (ocean floor); at/above sea = GRASS. Mirrors
		// Worldgen._block_at — must NOT subtract BEACH_DEPTH_BELOW here
		// (that's the beach-band constant, not the grass/dirt line).
		if (surface_y < SEA_LEVEL) {
			return DIRT;
		}
		return GRASS;
	}
	if (y >= surface_y - 3) {
		return DIRT;
	}
	return STONE;
}

Dictionary WorldgenNative::build_base_terrain(
		int p_chunk_x,
		int p_chunk_z,
		const PackedInt32Array &p_heightmap) const {
	PackedByteArray blocks;
	const int volume = SIZE_X * SIZE_Y * SIZE_Z;
	blocks.resize(volume);
	uint8_t *blocks_ptr = blocks.ptrw();
	// PackedByteArray.resize() zero-fills, but be explicit: AIR=0 is the
	// default for untouched cells above the surface.
	for (int i = 0; i < volume; i++) {
		blocks_ptr[i] = AIR;
	}

	int max_y = 0;
	const int hm_expected = SIZE_X * SIZE_Z;
	const int hm_size = p_heightmap.size();
	const int32_t *hm_ptr = p_heightmap.ptr();

	for (int x = 0; x < SIZE_X; x++) {
		for (int z = 0; z < SIZE_Z; z++) {
			const int world_x = p_chunk_x * SIZE_X + x;
			const int world_z = p_chunk_z * SIZE_Z + z;
			// Heightmap index mirrors the GDScript caller's layout.
			const int hm_idx = z * SIZE_X + x;
			if (hm_idx >= hm_size || hm_idx >= hm_expected) {
				continue;
			}
			int h = hm_ptr[hm_idx];
			if (h < 0) {
				h = 0;
			} else if (h >= SIZE_Y) {
				h = SIZE_Y - 1;
			}
			for (int y = 0; y <= h; y++) {
				const int idx = y * SIZE_X * SIZE_Z + z * SIZE_X + x;
				const int id = block_at(world_x, y, world_z, h);
				blocks_ptr[idx] = static_cast<uint8_t>(id);
				if (id != AIR && y > max_y) {
					max_y = y;
				}
			}
		}
	}

	Dictionary result;
	result["blocks"] = blocks;
	result["max_y"] = max_y;
	return result;
}

// Slice 3-D: native port of WorldgenDensity.build_density_terrain. The
// hot inner loop — per-cell trilerp from a 5×17×5 coarse density grid
// into the full 16×128×16 chunk, plus the density blend (primary +
// secondary + selector) and Y-bias subtraction.
//
// In GDScript this loop is ~32K cells × ~7 lerps each = ~224K function
// calls. GDScript function-dispatch overhead alone makes that ~50-100ms
// per chunk — the dominant cost in 3D-density mode. Native does the
// same math in raw doubles, ~5-10× faster.
//
// Caller pre-samples noise grids in GDScript (FastNoiseLite is already
// fast in Godot's C++) and hands the raw float arrays. This avoids
// also porting NoiseOctaves to native (would need a separate Perlin
// implementation that matches FastNoiseLite's gradient table for
// parity — much bigger scope).
//
// Grid layouts:
//   density_a, density_b, selector: 5*17*5 = 425 doubles, indexed
//                                   `(gx * GRID_Y + gy) * GRID_Z + gz`
//   col_target_y, col_amplitude:    5*5    =  25 doubles, indexed
//                                   `gx * GRID_Z + gz`
Dictionary WorldgenNative::build_density_terrain(
		int p_chunk_x,
		int p_chunk_z,
		const PackedFloat64Array &p_density_a,
		const PackedFloat64Array &p_density_b,
		const PackedFloat64Array &p_selector,
		const PackedFloat64Array &p_col_target_y,
		const PackedFloat64Array &p_col_amplitude,
		float p_stone_bias_factor,
		float p_air_bias_factor,
		float p_noise_normalizer,
		float p_selector_normalizer,
		int p_top_taper_cells,
		float p_top_taper_force_air) const {
	// Mirror WorldgenDensity GDScript constants.
	constexpr int GRID_X = 5;
	constexpr int GRID_Y = 17;
	constexpr int GRID_Z = 5;
	constexpr int COARSE_STEP_X = 4;
	constexpr int COARSE_STEP_Y = 8;
	constexpr int COARSE_STEP_Z = 4;
	constexpr int GRID_SIZE = GRID_X * GRID_Y * GRID_Z;

	(void)p_chunk_x;  // unused — chunk coords already baked into noise samples
	(void)p_chunk_z;

	// Bail if any input grid is sized wrong (caller bug).
	if (p_density_a.size() != GRID_SIZE || p_density_b.size() != GRID_SIZE
			|| p_selector.size() != GRID_SIZE
			|| p_col_target_y.size() != GRID_X * GRID_Z
			|| p_col_amplitude.size() != GRID_X * GRID_Z) {
		Dictionary err;
		err["blocks"] = PackedByteArray();
		err["max_y"] = 0;
		return err;
	}

	const double *da = p_density_a.ptr();
	const double *db = p_density_b.ptr();
	const double *sel = p_selector.ptr();
	const double *targets = p_col_target_y.ptr();
	const double *amps = p_col_amplitude.ptr();

	// Working density grid — local doubles, modified in place. Same
	// layout as the input grids.
	double density[GRID_SIZE];

	// Step 1: blend primary + secondary via selector, normalize.
	// d10 = lerp(d12, d13, clamp((selector/N + 1) / 2, 0, 1))
	const double sel_inv = 1.0 / static_cast<double>(p_selector_normalizer);
	const double noise_inv = 1.0 / static_cast<double>(p_noise_normalizer);
	for (int i = 0; i < GRID_SIZE; i++) {
		const double d12 = da[i] * noise_inv;
		const double d13 = db[i] * noise_inv;
		const double d14 = (sel[i] * sel_inv + 1.0) * 0.5;
		double t = d14;
		if (t < 0.0) {
			t = 0.0;
		} else if (t > 1.0) {
			t = 1.0;
		}
		density[i] = d12 + (d13 - d12) * t;
	}

	// Step 2: per-column Y-bias subtraction + top-of-world taper.
	// Mirrors WorldgenDensity._y_bias_with_target_amp + the top-taper
	// branch. Asymmetric stone/air bias, divided by per-column amplitude.
	const int taper_start = GRID_Y - p_top_taper_cells;
	const double taper_div = static_cast<double>(p_top_taper_cells - 1);
	for (int gx = 0; gx < GRID_X; gx++) {
		for (int gy = 0; gy < GRID_Y; gy++) {
			const double world_y = static_cast<double>(gy * COARSE_STEP_Y);
			double taper = 0.0;
			if (gy >= taper_start) {
				taper = static_cast<double>(gy - taper_start) / taper_div;
			}
			for (int gz = 0; gz < GRID_Z; gz++) {
				const int col_idx = gx * GRID_Z + gz;
				const double col_target = targets[col_idx];
				const double col_amp = amps[col_idx];
				const double diff = world_y - col_target;
				double y_bias = 0.0;
				if (diff < 0.0) {
					y_bias = diff * static_cast<double>(p_stone_bias_factor) / col_amp;
				} else {
					y_bias = diff * static_cast<double>(p_air_bias_factor) / col_amp;
				}
				const int idx = (gx * GRID_Y + gy) * GRID_Z + gz;
				double biased = density[idx] - y_bias;
				if (taper > 0.0) {
					biased = biased * (1.0 - taper)
							+ static_cast<double>(p_top_taper_force_air) * taper;
				}
				density[idx] = biased;
			}
		}
	}

	// Step 3: trilerp density grid into per-cell threshold → STONE/AIR.
	// 8 corner densities define each coarse cube; sub-cell loop walks
	// the COARSE_STEP_X × COARSE_STEP_Y × COARSE_STEP_Z cells inside.
	PackedByteArray blocks;
	const int volume = SIZE_X * SIZE_Y * SIZE_Z;
	blocks.resize(volume);
	uint8_t *blocks_ptr = blocks.ptrw();
	for (int i = 0; i < volume; i++) {
		blocks_ptr[i] = AIR;
	}
	int max_y = 0;
	for (int gx = 0; gx < GRID_X - 1; gx++) {
		for (int gz = 0; gz < GRID_Z - 1; gz++) {
			for (int gy = 0; gy < GRID_Y - 1; gy++) {
				const double d000 = density[(gx * GRID_Y + gy) * GRID_Z + gz];
				const double d001 = density[(gx * GRID_Y + gy) * GRID_Z + gz + 1];
				const double d010 = density[(gx * GRID_Y + (gy + 1)) * GRID_Z + gz];
				const double d011 = density[(gx * GRID_Y + (gy + 1)) * GRID_Z + gz + 1];
				const double d100 = density[((gx + 1) * GRID_Y + gy) * GRID_Z + gz];
				const double d101 = density[((gx + 1) * GRID_Y + gy) * GRID_Z + gz + 1];
				const double d110 = density[((gx + 1) * GRID_Y + (gy + 1)) * GRID_Z + gz];
				const double d111 = density[((gx + 1) * GRID_Y + (gy + 1)) * GRID_Z + gz + 1];
				for (int sy = 0; sy < COARSE_STEP_Y; sy++) {
					const double ty = static_cast<double>(sy) / static_cast<double>(COARSE_STEP_Y);
					const double d00 = d000 + (d010 - d000) * ty;
					const double d01 = d001 + (d011 - d001) * ty;
					const double d10 = d100 + (d110 - d100) * ty;
					const double d11 = d101 + (d111 - d101) * ty;
					const int world_y = gy * COARSE_STEP_Y + sy;
					if (world_y >= SIZE_Y) {
						continue;
					}
					for (int sx = 0; sx < COARSE_STEP_X; sx++) {
						const double tx = static_cast<double>(sx) / static_cast<double>(COARSE_STEP_X);
						const double d0 = d00 + (d10 - d00) * tx;
						const double d1 = d01 + (d11 - d01) * tx;
						const int local_x = gx * COARSE_STEP_X + sx;
						for (int sz = 0; sz < COARSE_STEP_Z; sz++) {
							const double tz = static_cast<double>(sz) / static_cast<double>(COARSE_STEP_Z);
							const double d = d0 + (d1 - d0) * tz;
							if (d > 0.0) {
								const int local_z = gz * COARSE_STEP_Z + sz;
								const int idx = world_y * SIZE_X * SIZE_Z + local_z * SIZE_X + local_x;
								blocks_ptr[idx] = STONE;
								if (world_y > max_y) {
									max_y = world_y;
								}
							}
						}
					}
				}
			}
		}
	}

	Dictionary result;
	result["blocks"] = blocks;
	result["max_y"] = max_y;
	return result;
}

// Slice 3-D2: native port of WorldgenDensity.apply_surface_layer.
// After build_density_terrain fills the chunk with raw STONE/AIR, this
// pass converts the topmost STONE per column → GRASS (or DIRT below
// sea level — vanilla `px.java:130-148` rule), the next 3 STONE cells
// → DIRT, then runs the deterministic bedrock pass at y=0..4 using
// the same hash3 the GDScript `is_bedrock_at` uses.
//
// 16×16 columns × ~128-cell scan top-down was ~16ms in GDScript.
// Native version is ~1ms — column scan is just byte reads in a flat
// array.
PackedByteArray WorldgenNative::apply_surface_layer(
		int p_chunk_x,
		int p_chunk_z,
		const PackedByteArray &p_blocks) const {
	const int volume = SIZE_X * SIZE_Y * SIZE_Z;
	if (p_blocks.size() != volume) {
		return p_blocks;
	}
	PackedByteArray blocks = p_blocks;
	uint8_t *blocks_ptr = blocks.ptrw();
	for (int x = 0; x < SIZE_X; x++) {
		for (int z = 0; z < SIZE_Z; z++) {
			const int world_x = p_chunk_x * SIZE_X + x;
			const int world_z = p_chunk_z * SIZE_Z + z;
			// Walk top-down to find the topmost STONE in this column.
			int top_stone_y = -1;
			for (int y = SIZE_Y - 1; y >= 0; y--) {
				const int idx = y * SIZE_X * SIZE_Z + z * SIZE_X + x;
				if (blocks_ptr[idx] == STONE) {
					top_stone_y = y;
					break;
				}
			}
			if (top_stone_y >= 0) {
				// Top cell: GRASS if at/above sea level, DIRT otherwise
				// (ocean floor — water fill will cover it). Vanilla
				// `px.java:130-148` does the same.
				const int top_idx = top_stone_y * SIZE_X * SIZE_Z + z * SIZE_X + x;
				blocks_ptr[top_idx] = (top_stone_y >= SEA_LEVEL) ? GRASS : DIRT;
				// Next 3 STONE cells → DIRT.
				for (int dy = 1; dy < 4; dy++) {
					const int y = top_stone_y - dy;
					if (y < 0) {
						break;
					}
					const int idx = y * SIZE_X * SIZE_Z + z * SIZE_X + x;
					if (blocks_ptr[idx] == STONE) {
						blocks_ptr[idx] = DIRT;
					}
				}
			}
			// Bedrock pass at y=0..4 — probabilistic per the same hash
			// `is_bedrock_at` the GDScript path uses, so byte-for-byte
			// parity holds.
			for (int y = 0; y < 5; y++) {
				if (is_bedrock_at(world_x, y, world_z)) {
					const int idx = y * SIZE_X * SIZE_Z + z * SIZE_X + x;
					blocks_ptr[idx] = BEDROCK;
				}
			}
		}
	}
	return blocks;
}

// Slice 3-D3: native port of NoiseOctaves.sample_3d_grid. The caller
// passes the same Array<Ref<FastNoiseLite>> that GDScript uses (one
// configured Perlin per octave), and we run the reverse-FBM accumulation
// loop in C++. Because the underlying FastNoiseLite instances are SHARED
// between GDScript and native paths, the noise output at any (x,y,z) is
// byte-identical — so the grid we produce here matches the GDScript
// fallback exactly.
//
// Per-call cost: ~10ms in GDScript (Variant dispatch overhead per
// `get_noise_3d` call) → ~1ms native (direct C++ method call). Three
// noise grids per chunk × 16-octave reverse-FBM = ~20K Perlin samples,
// so this matters during chunk gen.
PackedFloat64Array WorldgenNative::sample_noise_grid_3d(
		const Array &p_octaves,
		double p_base_x,
		double p_base_y,
		double p_base_z,
		int p_size_x,
		int p_size_y,
		int p_size_z,
		double p_scale_x,
		double p_scale_y,
		double p_scale_z) const {
	PackedFloat64Array out;
	const int total = p_size_x * p_size_y * p_size_z;
	out.resize(total);
	double *out_ptr = out.ptrw();
	for (int i = 0; i < total; i++) {
		out_ptr[i] = 0.0;
	}
	const int octave_count = p_octaves.size();
	double amp = 1.0;
	for (int octave = 0; octave < octave_count; octave++) {
		Ref<FastNoiseLite> noise = p_octaves[octave];
		if (noise.is_null()) {
			amp /= 2.0;
			continue;
		}
		const double fx_scale = p_scale_x * amp;
		const double fy_scale = p_scale_y * amp;
		const double fz_scale = p_scale_z * amp;
		const double inv_amp = 1.0 / amp;
		for (int x = 0; x < p_size_x; x++) {
			const double sx = (p_base_x + static_cast<double>(x)) * fx_scale;
			for (int y = 0; y < p_size_y; y++) {
				const double sy = (p_base_y + static_cast<double>(y)) * fy_scale;
				for (int z = 0; z < p_size_z; z++) {
					const double sz = (p_base_z + static_cast<double>(z)) * fz_scale;
					const int idx = (x * p_size_y + y) * p_size_z + z;
					out_ptr[idx] += noise->get_noise_3d(sx, sy, sz) * inv_amp;
				}
			}
		}
		amp /= 2.0;
	}
	return out;
}

// Deterministic port of Worldgen._place_vein_ellipsoid, which is itself a
// port of vanilla WorldGenMinable.generate (df.java). Traces a short line
// (d0..d1, d4..d5, d2..d3) and fills a radius-varying ellipsoid at b+1
// samples along it, writing ore only over STONE. Writes clipped to the
// target chunk's bounds so the 4-decoration-pass overlap trick in
// scatter_ores doesn't leak into neighbour chunks.
void WorldgenNative::place_vein_ellipsoid(
		uint8_t *blocks_ptr,
		int chunk_x,
		int chunk_z,
		int seed_world_x,
		int seed_world_y,
		int seed_world_z,
		int ore_id,
		int b,
		int64_t seed_hash,
		int y_lo,
		int y_hi) {
	const double bf = static_cast<double>(b);
	const double f = float01(seed_hash, 1) * 3.141592653589793;
	const double d0 = static_cast<double>(seed_world_x + 8) + std::sin(f) * bf / 8.0;
	const double d1 = static_cast<double>(seed_world_x + 8) - std::sin(f) * bf / 8.0;
	const double d2 = static_cast<double>(seed_world_z + 8) + std::cos(f) * bf / 8.0;
	const double d3 = static_cast<double>(seed_world_z + 8) - std::cos(f) * bf / 8.0;
	// df.java:22-23 has both endpoints 2..4 blocks ABOVE the seed y.
	// (`random.nextInt(3) + 2`). GDScript _place_vein_ellipsoid comments
	// call this out explicitly — earlier revisions had -2 which was wrong.
	const double d4 =
			static_cast<double>(seed_world_y + (hash3(seed_hash, 2, ore_id) % 3) + 2);
	const double d5 =
			static_cast<double>(seed_world_y + (hash3(seed_hash, 3, ore_id) % 3) + 2);
	const int chunk_origin_x = chunk_x * SIZE_X;
	const int chunk_origin_z = chunk_z * SIZE_Z;

	for (int l = 0; l <= b; l++) {
		const double t = static_cast<double>(l) / bf;
		const double d6 = d0 + (d1 - d0) * t;
		const double d7 = d4 + (d5 - d4) * t;
		const double d8 = d2 + (d3 - d2) * t;
		const double d9 = float01(seed_hash, l * 97 + 5) * bf / 16.0;
		const double radius =
				(std::sin(static_cast<double>(l) * 3.141592653589793 / bf) + 1.0) * d9 + 1.0;
		const double half_r = radius / 2.0;
		const int min_x = static_cast<int>(std::floor(d6 - half_r));
		const int min_y = static_cast<int>(std::floor(d7 - half_r));
		const int min_z = static_cast<int>(std::floor(d8 - half_r));
		const int max_x = static_cast<int>(std::floor(d6 + half_r));
		const int max_y = static_cast<int>(std::floor(d7 + half_r));
		const int max_z = static_cast<int>(std::floor(d8 + half_r));

		for (int bx = min_x; bx <= max_x; bx++) {
			const int lx = bx - chunk_origin_x;
			if (lx < 0 || lx >= SIZE_X) {
				continue;
			}
			const double nx = (static_cast<double>(bx) + 0.5 - d6) / half_r;
			const double nx2 = nx * nx;
			if (nx2 >= 1.0) {
				continue;
			}
			for (int by = min_y; by <= max_y; by++) {
				if (by < y_lo || by > y_hi) {
					continue;
				}
				const double ny = (static_cast<double>(by) + 0.5 - d7) / half_r;
				const double nxy2 = nx2 + ny * ny;
				if (nxy2 >= 1.0) {
					continue;
				}
				for (int bz = min_z; bz <= max_z; bz++) {
					const int lz = bz - chunk_origin_z;
					if (lz < 0 || lz >= SIZE_Z) {
						continue;
					}
					const double nz = (static_cast<double>(bz) + 0.5 - d8) / half_r;
					if (nxy2 + nz * nz >= 1.0) {
						continue;
					}
					const int idx = by * SIZE_X * SIZE_Z + lz * SIZE_X + lx;
					if (blocks_ptr[idx] != STONE) {
						continue;
					}
					blocks_ptr[idx] = static_cast<uint8_t>(ore_id);
				}
			}
		}
	}
}

PackedByteArray WorldgenNative::scatter_ores(
		int p_chunk_x,
		int p_chunk_z,
		const PackedByteArray &p_blocks,
		const PackedInt32Array &p_ore_configs) const {
	// Copy-on-write — we write into `out`, which CoWs off the caller's
	// buffer on first mutation. The ore_configs array is [block_id,
	// attempts, vein_size, y_min, y_max] × N, flattened so the GDScript
	// caller can keep tuning the knobs without rebuilding the native lib.
	PackedByteArray out = p_blocks;
	const int volume = SIZE_X * SIZE_Y * SIZE_Z;
	if (out.size() < volume) {
		return out;
	}
	uint8_t *blocks_ptr = out.ptrw();
	const int cfg_size = p_ore_configs.size();
	const int32_t *cfg_ptr = p_ore_configs.ptr();

	// Vanilla WorldGenMinable shifts each vein's centre by +8 on X/Z, so
	// a chunk at (cx, cz)'s decoration pass writes its veins into the
	// 2×2 NE square starting at (cx, cz). To collect the full ore set
	// for our target chunk, we run the decoration passes for the 3
	// SW-adjacent chunks plus our own and clip every placement to our
	// bounds. This mirrors vanilla's population-phase overlap without
	// any cross-chunk side effects. Same loop shape as
	// Worldgen._scatter_ores.
	for (int dcx = -1; dcx <= 0; dcx++) {
		for (int dcz = -1; dcz <= 0; dcz++) {
			const int deco_cx = p_chunk_x + dcx;
			const int deco_cz = p_chunk_z + dcz;
			for (int c = 0; c + 4 < cfg_size; c += 5) {
				const int ore_id = cfg_ptr[c];
				const int attempts = cfg_ptr[c + 1];
				const int vein_size = cfg_ptr[c + 2];
				const int y_min = cfg_ptr[c + 3];
				const int y_max = cfg_ptr[c + 4];
				const int y_lo = (y_min > 1) ? y_min : 1;
				const int y_hi = (y_max < SIZE_Y - 1) ? y_max : SIZE_Y - 1;
				if (y_hi < y_lo) {
					continue;
				}
				const int span = y_hi - y_lo + 1;
				for (int attempt = 0; attempt < attempts; attempt++) {
					const int64_t seed_hash = hash4(deco_cx, deco_cz, ore_id, attempt);
					const int world_x =
							deco_cx * SIZE_X + static_cast<int>(seed_hash % SIZE_X);
					const int world_z =
							deco_cz * SIZE_Z + static_cast<int>((seed_hash >> 8) % SIZE_Z);
					const int world_y = y_lo + static_cast<int>((seed_hash >> 16) % span);
					place_vein_ellipsoid(
							blocks_ptr,
							p_chunk_x,
							p_chunk_z,
							world_x,
							world_y,
							world_z,
							ore_id,
							vein_size,
							seed_hash,
							y_lo,
							y_hi);
				}
			}
		}
	}
	return out;
}

// Native port of worldgen_caves.gd::scatter — runs the 17×17 seed-chunk
// loop with bit-exact JavaRandom, carves worm ellipsoids into the
// target chunk's blocks. Writes are clipped to the target chunk's AABB
// so only the target chunk mutates; seed-chunk iterations that produce
// worms entirely outside the target run their PRNG stream for
// determinism but emit no carves.
Dictionary WorldgenNative::scatter_caves(
		int p_chunk_x, int p_chunk_z, const PackedByteArray &p_blocks) const {
	PackedByteArray out = p_blocks;
	Dictionary result;
	result["blocks"] = out;
	result["has_non_cube"] = false;
	result["has_water"] = false;
	const int volume = SIZE_X * SIZE_Y * SIZE_Z;
	if (out.size() < volume) {
		return result;
	}
	uint8_t *blocks_ptr = out.ptrw();

	// dl.java:10-20 — seed multipliers derived from world seed, then
	// per-chunk re-seed for each contributing seed chunk.
	JavaRandom rng(world_seed);
	const int64_t l2 = rng.next_long() / 2LL * 2LL + 1LL;  // force odd
	const int64_t l3 = rng.next_long() / 2LL * 2LL + 1LL;
	for (int seed_cx = p_chunk_x - CAVES_RADIUS_CHUNKS;
			seed_cx <= p_chunk_x + CAVES_RADIUS_CHUNKS; seed_cx++) {
		for (int seed_cz = p_chunk_z - CAVES_RADIUS_CHUNKS;
				seed_cz <= p_chunk_z + CAVES_RADIUS_CHUNKS; seed_cz++) {
			// Exact mirror of GDScript's `seed_cx * l2 + seed_cz * l3 ^ world_seed`.
			// GDScript's `^` has lower precedence than `+` (per Godot docs) —
			// same as C++ so the expression groups identically.
			rng.set_seed(int64_t(seed_cx) * l2 + int64_t(seed_cz) * l3 ^ world_seed);
			spawn_from_seed_chunk(rng, blocks_ptr, p_chunk_x, p_chunk_z, seed_cx, seed_cz);
		}
	}

	// Sync the chunk-state flags that GDScript's `set_block_unchecked`
	// would have updated cell-by-cell. The native base-terrain + caves
	// paths bypass that helper (they write blocks_ptr directly), so
	// without this scan the GDScript-side `chunk.has_water_cells` /
	// `has_non_cube_blocks` flags stay stale → mesher dispatch chooses
	// the wrong path and chunk-state diverges from the GDScript reference
	// (test_mesher_native parity catches this).
	//
	// Single linear pass over 32K cells in C++ — replaces the GDScript
	// `_post_process_native_caves` loop that cost ~10-15 ms/chunk and
	// dominated the cave probe time. Mesh-shape and water predicates are
	// inlined here to keep the loop hot.
	bool has_non_cube = false;
	bool has_water = false;
	for (int i = 0; i < volume; i++) {
		const uint8_t id = blocks_ptr[i];
		if (!has_non_cube) {
			// Mirrors Blocks.needs_gdscript_mesher / mesh_shape() — any
			// id whose mesh shape isn't CUBE. Listed by ID; keep in sync
			// with scripts/world/blocks.gd if new non-cube blocks land.
			switch (id) {
				case SAPLING:  // 22
				case FIRE:  // 27
				case TORCH:  // 28
				case FENCE:  // 30
				case WOOD_STAIRS:  // 31
				case COBBLESTONE_STAIRS:  // 32
				case WOODEN_DOOR:  // 33
				case IRON_DOOR:  // 34
				case LADDER:  // 35
				case FLOWER_RED:  // 37
				case FLOWER_YELLOW:  // 38
				case MUSHROOM_BROWN:  // 39
				case MUSHROOM_RED:  // 40
					has_non_cube = true;
					break;
				default:
					break;
			}
		}
		if (!has_water && (id == WATER_STILL || id == WATER_FLOWING)) {
			has_water = true;
		}
		if (has_non_cube && has_water) {
			break;  // both set, nothing more to detect
		}
	}
	result["blocks"] = out;
	result["has_non_cube"] = has_non_cube;
	result["has_water"] = has_water;
	return result;
}

void WorldgenNative::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("build_base_terrain", "chunk_x", "chunk_z", "heightmap"),
			&WorldgenNative::build_base_terrain);
	ClassDB::bind_method(
			D_METHOD(
					"build_density_terrain",
					"chunk_x",
					"chunk_z",
					"density_a",
					"density_b",
					"selector",
					"col_target_y",
					"col_amplitude",
					"stone_bias_factor",
					"air_bias_factor",
					"noise_normalizer",
					"selector_normalizer",
					"top_taper_cells",
					"top_taper_force_air"),
			&WorldgenNative::build_density_terrain);
	ClassDB::bind_method(
			D_METHOD("apply_surface_layer", "chunk_x", "chunk_z", "blocks"),
			&WorldgenNative::apply_surface_layer);
	ClassDB::bind_method(
			D_METHOD(
					"sample_noise_grid_3d",
					"octaves",
					"base_x",
					"base_y",
					"base_z",
					"size_x",
					"size_y",
					"size_z",
					"scale_x",
					"scale_y",
					"scale_z"),
			&WorldgenNative::sample_noise_grid_3d);
	ClassDB::bind_method(
			D_METHOD("scatter_ores", "chunk_x", "chunk_z", "blocks", "ore_configs"),
			&WorldgenNative::scatter_ores);
	ClassDB::bind_method(
			D_METHOD("scatter_caves", "chunk_x", "chunk_z", "blocks"),
			&WorldgenNative::scatter_caves);
	// Static class method exposed as instance-callable so GDScript can
	// invoke `_native_worldgen.set_world_seed(N)` symmetrically with the
	// other native APIs. The static keyword in the header keeps the
	// underlying state shared across instances.
	ClassDB::bind_static_method(
			"WorldgenNative",
			D_METHOD("set_world_seed", "seed"),
			&WorldgenNative::set_world_seed);
}
