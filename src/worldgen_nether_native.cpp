#include "worldgen_nether_native.h"
#include "worldgen_native_shared.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <vector>

using namespace godot;
using worldgen_shared::JavaRandom;
using worldgen_shared::NoisePerlin;
using worldgen_shared::octaves_3d_grid;

// ===========================================================================
// Alpha 1.2.6 Nether generator — native port.
//
// Mirrors scripts/world/worldgen_nether.gd (kj.java),
// worldgen_nether_caves.gd (ju.java + dl.java) and
// worldgen_nether_population.gd (kj.java's populate plus kf/pm/dt/lp/aj).
// The WHY of every constant and every source quirk lives on the GDScript
// side; this file carries only notes specific to the C++ translation.
//
// One rule governs the whole file: GDScript is the reference and this must
// not drift from it. Anything that looks like an optimisation but would
// reorder a rounding step is not one.
// ===========================================================================

namespace {

constexpr int CHUNK_VOLUME = 32768;
constexpr int CELLS_XZ = 4;
constexpr int LAVA_LEVEL = 32;
constexpr int GRID_XZ = 5;
constexpr int GRID_Y = 17;
constexpr double SCALE_XZ = 684.412;
constexpr double SCALE_Y = 2053.236;
constexpr double SURFACE_SCALE = 0.03125;
constexpr int SURFACE_PIVOT = 64;
constexpr int64_t SEED_MUL_X = 341873128712LL;
constexpr int64_t SEED_MUL_Z = 132897987541LL;

constexpr double PI_D = 3.14159265358979323846;
// Java's `(float)Math.PI`. Spelt out because the double PI is a different
// number once it reaches a float expression.
constexpr float PI_F = 3.1415927410125732f;

// Raw Alpha block ids.
constexpr uint8_t A_AIR = 0;
constexpr uint8_t A_GRASS = 2;
constexpr uint8_t A_DIRT = 3;
constexpr uint8_t A_BEDROCK = 7;
constexpr uint8_t A_LAVA_FLOWING = 10;
constexpr uint8_t A_LAVA_STILL = 11;
constexpr uint8_t A_GRAVEL = 13;
constexpr uint8_t A_MUSHROOM_BROWN = 39;
constexpr uint8_t A_MUSHROOM_RED = 40;
constexpr uint8_t A_FIRE = 51;
constexpr uint8_t A_NETHERRACK = 87;
constexpr uint8_t A_SOUL_SAND = 88;
constexpr uint8_t A_GLOWSTONE = 89;

inline int alpha_index(int x, int y, int z) {
	return (x * 16 + z) * 128 + y;
}

inline int density_index(int gx, int gy, int gz) {
	return (gx * GRID_XZ + gz) * GRID_Y + gy;
}

// Java rounds after EVERY float operation. C++ float arithmetic already
// does, so these just make the grouping explicit and greppable against
// the GDScript reference's _fmul/_fadd/_fdiv/_fsub.
inline float fmul(float a, float b) {
	return a * b;
}
inline float fadd(float a, float b) {
	return a + b;
}
inline float fsub(float a, float b) {
	return a - b;
}
inline float fdiv(float a, float b) {
	return a / b;
}

// --- Alpha MathHelper (fi.java) -------------------------------------------
//
// A 65536-entry table of FLOAT sines indexed by
// `(int)(angle * 10430.378f) & 0xFFFF`. Not std::sin: the table's
// quantisation changes which blocks a tunnel clips.

constexpr float SIN_SCALE = 10430.3779296875f;
constexpr float COS_OFFSET = 16384.0f;
constexpr int SIN_TABLE_SIZE = 65536;

const float *sin_table() {
	static const std::vector<float> table = [] {
		std::vector<float> t(SIN_TABLE_SIZE);
		for (int i = 0; i < SIN_TABLE_SIZE; ++i) {
			t[i] = static_cast<float>(std::sin(static_cast<double>(i) * PI_D * 2.0 / 65536.0));
		}
		return t;
	}();
	return table.data();
}

inline float alpha_sin(float angle) {
	return sin_table()[static_cast<int>(fmul(angle, SIN_SCALE)) & 0xFFFF];
}

inline float alpha_cos(float angle) {
	return sin_table()[static_cast<int>(fadd(fmul(angle, SIN_SCALE), COS_OFFSET)) & 0xFFFF];
}

inline int floor_to_int(double v) {
	const int n = static_cast<int>(v);
	return v < static_cast<double>(n) ? n - 1 : n;
}

// --- Noise state ----------------------------------------------------------
//
// kj.java draws seven octave generators from ONE shared Random in the
// order 16, 16, 8, 4, 4, 10, 16.

struct NetherNoise {
	std::vector<NoisePerlin> main_a, main_b, selector, surface_a, surface_b, aux_10, aux_16;
	int64_t seed = 0;
	bool built = false;

	static void draw(std::vector<NoisePerlin> &into, JavaRandom &rng, int octaves) {
		into.clear();
		into.reserve(octaves);
		for (int i = 0; i < octaves; ++i) {
			into.emplace_back(rng);
		}
	}

	void build(int64_t world_seed) {
		JavaRandom shared(world_seed);
		draw(main_a, shared, 16);
		draw(main_b, shared, 16);
		draw(selector, shared, 8);
		draw(surface_a, shared, 4);
		draw(surface_b, shared, 4);
		draw(aux_10, shared, 10);
		draw(aux_16, shared, 16);
		seed = world_seed;
		built = true;
	}
};

// Module state. Guarded because generation runs on WorkerThreadPool.
int64_t g_world_seed = 12345;
NetherNoise g_noise;
std::mutex g_state_mutex;
std::map<int64_t, std::vector<uint8_t>> g_terrain_cache;
std::map<int64_t, std::vector<int32_t>> g_writes_cache;

constexpr size_t CACHE_LIMIT = 512;

inline int64_t cache_key(int cx, int cz) {
	return (static_cast<int64_t>(cx) << 32) ^ (static_cast<uint32_t>(cz));
}

const NetherNoise &ensure_noise() {
	// Built under the same lock the caches use; the tables are read-only
	// afterwards, so sampling needs no synchronisation.
	std::lock_guard<std::mutex> guard(g_state_mutex);
	if (!g_noise.built || g_noise.seed != g_world_seed) {
		g_noise.build(g_world_seed);
	}
	return g_noise;
}

// --- Stage 1: coarse density field (kj.java:195-258) ----------------------

void density_grid(const NetherNoise &noise, int chunk_x, int chunk_z, std::vector<double> &out) {
	const int total = GRID_XZ * GRID_Y * GRID_XZ;
	out.assign(total, 0.0);
	std::vector<double> sel(total), a(total), b(total);
	std::vector<double> aux10(GRID_XZ * GRID_XZ), aux16(GRID_XZ * GRID_XZ);

	const double base_x = chunk_x * CELLS_XZ;
	const double base_z = chunk_z * CELLS_XZ;

	// The two auxiliary fields are sampled and never read — the DEAD-VALUE
	// note in the GDScript reference explains why both paths keep them.
	octaves_3d_grid(noise.aux_10, aux10.data(), base_x, 0.0, base_z, GRID_XZ, 1, GRID_XZ, 1.0,
			0.0, 1.0);
	octaves_3d_grid(noise.aux_16, aux16.data(), base_x, 0.0, base_z, GRID_XZ, 1, GRID_XZ, 100.0,
			0.0, 100.0);
	octaves_3d_grid(noise.selector, sel.data(), base_x, 0.0, base_z, GRID_XZ, GRID_Y, GRID_XZ,
			SCALE_XZ / 80.0, SCALE_Y / 60.0, SCALE_XZ / 80.0);
	octaves_3d_grid(noise.main_a, a.data(), base_x, 0.0, base_z, GRID_XZ, GRID_Y, GRID_XZ,
			SCALE_XZ, SCALE_Y, SCALE_XZ);
	octaves_3d_grid(noise.main_b, b.data(), base_x, 0.0, base_z, GRID_XZ, GRID_Y, GRID_XZ,
			SCALE_XZ, SCALE_Y, SCALE_XZ);

	double bias[GRID_Y];
	for (int gy = 0; gy < GRID_Y; ++gy) {
		bias[gy] = std::cos(static_cast<double>(gy) * PI_D * 6.0 / GRID_Y) * 2.0;
		double d = static_cast<double>(gy);
		if (gy > GRID_Y / 2) {
			d = static_cast<double>(GRID_Y - 1 - gy);
		}
		if (d < 4.0) {
			d = 4.0 - d;
			bias[gy] -= d * d * d * 10.0;
		}
	}

	int idx = 0;
	for (int gx = 0; gx < GRID_XZ; ++gx) {
		for (int gz = 0; gz < GRID_XZ; ++gz) {
			for (int gy = 0; gy < GRID_Y; ++gy) {
				const double lo = a[idx] / 512.0;
				const double hi = b[idx] / 512.0;
				const double t = (sel[idx] / 10.0 + 1.0) / 2.0;
				double value;
				if (t < 0.0) {
					value = lo;
				} else if (t > 1.0) {
					value = hi;
				} else {
					value = lo + (hi - lo) * t;
				}
				value -= bias[gy];
				if (gy > GRID_Y - 4) {
					// FLOAT32 in the source: `(float)(i3 - 13) / 3.0f`.
					const float mix = fdiv(static_cast<float>(gy - (GRID_Y - 4)), 3.0f);
					value = value * (1.0 - mix) + -10.0 * mix;
				}
				out[idx] = value;
				++idx;
			}
		}
	}
}

// --- Stage 2: base fill (kj.java:40-93) -----------------------------------

void fill_base(const NetherNoise &noise, uint8_t *blocks, int chunk_x, int chunk_z) {
	std::vector<double> grid;
	density_grid(noise, chunk_x, chunk_z, grid);
	for (int cell_x = 0; cell_x < CELLS_XZ; ++cell_x) {
		for (int cell_z = 0; cell_z < CELLS_XZ; ++cell_z) {
			for (int cell_y = 0; cell_y < 16; ++cell_y) {
				const double y_step = 0.125;
				double c000 = grid[density_index(cell_x, cell_y, cell_z)];
				double c001 = grid[density_index(cell_x, cell_y, cell_z + 1)];
				double c100 = grid[density_index(cell_x + 1, cell_y, cell_z)];
				double c101 = grid[density_index(cell_x + 1, cell_y, cell_z + 1)];
				const double d000 =
						(grid[density_index(cell_x, cell_y + 1, cell_z)] - c000) * y_step;
				const double d001 =
						(grid[density_index(cell_x, cell_y + 1, cell_z + 1)] - c001) * y_step;
				const double d100 =
						(grid[density_index(cell_x + 1, cell_y + 1, cell_z)] - c100) * y_step;
				const double d101 =
						(grid[density_index(cell_x + 1, cell_y + 1, cell_z + 1)] - c101) * y_step;
				for (int sub_y = 0; sub_y < 8; ++sub_y) {
					double e00 = c000;
					double e01 = c001;
					const double de0 = (c100 - c000) * 0.25;
					const double de1 = (c101 - c001) * 0.25;
					for (int sub_x = 0; sub_x < 4; ++sub_x) {
						const int world_y = cell_y * 8 + sub_y;
						const int x = cell_x * 4 + sub_x;
						double v = e00;
						const double dv = (e01 - e00) * 0.25;
						for (int sub_z = 0; sub_z < 4; ++sub_z) {
							const int z = cell_z * 4 + sub_z;
							uint8_t id = A_AIR;
							if (world_y < LAVA_LEVEL) {
								id = A_LAVA_STILL;
							}
							if (v > 0.0) {
								id = A_NETHERRACK;
							}
							blocks[alpha_index(x, world_y, z)] = id;
							v += dv;
						}
						e00 += de0;
						e01 += de1;
					}
					c000 += d000;
					c001 += d001;
					c100 += d100;
					c101 += d101;
				}
			}
		}
	}
}

// --- Stage 3: surface replacement and bedrock (kj.java:95-165) ------------

void apply_surface(
		const NetherNoise &noise, uint8_t *blocks, int chunk_x, int chunk_z, JavaRandom &rng) {
	const double s = SURFACE_SCALE;
	std::vector<double> soul(256), gravel(256), depth(256);
	octaves_3d_grid(noise.surface_a, soul.data(), chunk_x * 16, chunk_z * 16, 0.0, 16, 16, 1, s,
			s, 1.0);
	// X and Z swapped with a magic Y — that is what the source does.
	octaves_3d_grid(noise.surface_a, gravel.data(), chunk_z * 16, 109.0134, chunk_x * 16, 16, 1,
			16, s, 1.0, s);
	octaves_3d_grid(noise.surface_b, depth.data(), chunk_x * 16, chunk_z * 16, 0.0, 16, 16, 1,
			s * 2.0, s * 2.0, s * 2.0);

	for (int lx = 0; lx < 16; ++lx) {
		for (int lz = 0; lz < 16; ++lz) {
			const bool is_soul = soul[lx + lz * 16] + rng.next_double() * 0.2 > 0.0;
			const bool is_gravel = gravel[lx + lz * 16] + rng.next_double() * 0.2 > 0.0;
			const int column_depth =
					static_cast<int>(depth[lx + lz * 16] / 3.0 + 3.0 + rng.next_double() * 0.25);
			int remaining = -1;
			uint8_t top_block = A_NETHERRACK;
			uint8_t filler_block = A_NETHERRACK;
			for (int y = 127; y >= 0; --y) {
				const int idx = alpha_index(lx, y, lz);
				// Both nextInt(5) calls are inside the loop, and the second
				// only runs when the first test fails.
				if (y >= 127 - rng.next_int_bounded(5)) {
					blocks[idx] = A_BEDROCK;
					continue;
				}
				if (y <= rng.next_int_bounded(5)) {
					blocks[idx] = A_BEDROCK;
					continue;
				}
				const uint8_t current = blocks[idx];
				if (current == A_AIR) {
					remaining = -1;
					continue;
				}
				if (current != A_NETHERRACK) {
					continue;
				}
				if (remaining == -1) {
					if (column_depth <= 0) {
						top_block = A_AIR;
						filler_block = A_NETHERRACK;
					} else if (y >= SURFACE_PIVOT - 4 && y <= SURFACE_PIVOT + 1) {
						top_block = A_NETHERRACK;
						filler_block = A_NETHERRACK;
						if (is_gravel) {
							top_block = A_GRAVEL;
							filler_block = A_NETHERRACK;
						}
						if (is_soul) {
							top_block = A_SOUL_SAND;
							filler_block = A_SOUL_SAND;
						}
					}
					if (y < SURFACE_PIVOT && top_block == A_AIR) {
						top_block = A_LAVA_STILL;
					}
					remaining = column_depth;
					blocks[idx] = (y >= SURFACE_PIVOT - 1) ? top_block : filler_block;
					continue;
				}
				if (remaining <= 0) {
					continue;
				}
				--remaining;
				blocks[idx] = filler_block;
			}
		}
	}
}

// --- Stage 4: caves (ju.java + dl.java) -----------------------------------

constexpr int CAVE_NEIGHBOURHOOD = 8;
constexpr int MAX_CARVE_Y = 120;
constexpr int MIN_CARVE_Y = 1;

bool touches_lava(const uint8_t *blocks, int x0, int x1, int y0, int y1, int z0, int z1) {
	for (int x = x0; x < x1; ++x) {
		for (int z = z0; z < z1; ++z) {
			int y = y1 + 1;
			while (y >= y0 - 1) {
				if (y >= 0 && y < 128) {
					const uint8_t id = blocks[alpha_index(x, y, z)];
					if (id == A_LAVA_FLOWING || id == A_LAVA_STILL) {
						return true;
					}
					// The scan walks the SHELL, not the volume.
					if (!(y == y0 - 1 || x == x0 || x == x1 - 1 || z == z0 || z == z1 - 1)) {
						y = y0;
					}
				}
				--y;
			}
		}
	}
	return false;
}

void carve_ellipsoid(uint8_t *blocks, int chunk_x, int chunk_z, double pos_x, double pos_y,
		double pos_z, double horiz_radius, double vert_radius, int x0, int x1, int y0, int y1,
		int z0, int z1) {
	for (int x = x0; x < x1; ++x) {
		const double nx = (static_cast<double>(x + chunk_x * 16) + 0.5 - pos_x) / horiz_radius;
		for (int z = z0; z < z1; ++z) {
			const double nz = (static_cast<double>(z + chunk_z * 16) + 0.5 - pos_z) / horiz_radius;
			// The write index sits one Y ABOVE the tested cell — see the
			// GDScript reference for why that skew is kept.
			for (int y = y1 - 1; y >= y0; --y) {
				const double ny = (static_cast<double>(y) + 0.5 - pos_y) / vert_radius;
				if (ny <= -0.7) {
					continue;
				}
				if (nx * nx + ny * ny + nz * nz >= 1.0) {
					continue;
				}
				const int idx = alpha_index(x, y + 1, z);
				const uint8_t id = blocks[idx];
				if (id == A_NETHERRACK || id == A_DIRT || id == A_GRASS) {
					blocks[idx] = A_AIR;
				}
			}
		}
	}
}

void carve_worm(JavaRandom &outer_rng, uint8_t *blocks, int chunk_x, int chunk_z, double pos_x,
		double pos_y, double pos_z, float width, float yaw, float pitch, int step, int length,
		double vertical_scale) {
	const double centre_x = static_cast<double>(chunk_x * 16 + 8);
	const double centre_z = static_cast<double>(chunk_z * 16 + 8);
	float yaw_drift = 0.0f;
	float pitch_drift = 0.0f;
	JavaRandom rng(outer_rng.next_long());
	if (length <= 0) {
		const int span = CAVE_NEIGHBOURHOOD * 16 - 16;
		length = span - rng.next_int_bounded(span / 4);
	}
	bool is_room = false;
	if (step == -1) {
		step = length / 2;
		is_room = true;
	}
	const int branch_step = rng.next_int_bounded(length / 2) + length / 4;
	const bool wide_turn = rng.next_int_bounded(6) == 0;

	while (step < length) {
		const float phase = fdiv(fmul(static_cast<float>(step), PI_F), static_cast<float>(length));
		const double horiz_radius = 1.5 + fmul(fmul(alpha_sin(phase), width), 1.0f);
		const double vert_radius = horiz_radius * vertical_scale;
		const float cos_pitch = alpha_cos(pitch);
		const float sin_pitch = alpha_sin(pitch);
		pos_x += fmul(alpha_cos(yaw), cos_pitch);
		pos_y += sin_pitch;
		pos_z += fmul(alpha_sin(yaw), cos_pitch);
		pitch = fmul(pitch, wide_turn ? 0.92f : 0.7f);
		pitch = fadd(pitch, fmul(pitch_drift, 0.1f));
		yaw = fadd(yaw, fmul(yaw_drift, 0.1f));
		pitch_drift = fmul(pitch_drift, 0.9f);
		yaw_drift = fmul(yaw_drift, 0.75f);
		pitch_drift = fadd(pitch_drift,
				fmul(fmul(fsub(rng.next_float(), rng.next_float()), rng.next_float()), 2.0f));
		yaw_drift = fadd(yaw_drift,
				fmul(fmul(fsub(rng.next_float(), rng.next_float()), rng.next_float()), 4.0f));

		if (!is_room && step == branch_step && width > 1.0f) {
			// Both sub-tunnels are seeded from the OUTER rng: ju.java's
			// recursive call is `this.a(...)`, whose first act is
			// `new Random(this.b.nextLong())` on the CLASS random.
			carve_worm(outer_rng, blocks, chunk_x, chunk_z, pos_x, pos_y, pos_z,
					fadd(fmul(rng.next_float(), 0.5f), 0.5f), fsub(yaw, 1.5707964f),
					fdiv(pitch, 3.0f), step, length, 1.0);
			carve_worm(outer_rng, blocks, chunk_x, chunk_z, pos_x, pos_y, pos_z,
					fadd(fmul(rng.next_float(), 0.5f), 0.5f), fadd(yaw, 1.5707964f),
					fdiv(pitch, 3.0f), step, length, 1.0);
			return;
		}

		if (is_room || rng.next_int_bounded(4) != 0) {
			const double dx = pos_x - centre_x;
			const double dz = pos_z - centre_z;
			const double remaining = static_cast<double>(length - step);
			const double reach = fadd(fadd(width, 2.0f), 16.0f);
			if (dx * dx + dz * dz - remaining * remaining > reach * reach) {
				return;
			}
			if (pos_x >= centre_x - 16.0 - horiz_radius * 2.0 &&
					pos_z >= centre_z - 16.0 - horiz_radius * 2.0 &&
					pos_x <= centre_x + 16.0 + horiz_radius * 2.0 &&
					pos_z <= centre_z + 16.0 + horiz_radius * 2.0) {
				const int x0 = std::max(floor_to_int(pos_x - horiz_radius) - chunk_x * 16 - 1, 0);
				const int x1 = std::min(floor_to_int(pos_x + horiz_radius) - chunk_x * 16 + 1, 16);
				const int y0 = std::max(floor_to_int(pos_y - vert_radius) - 1, MIN_CARVE_Y);
				const int y1 = std::min(floor_to_int(pos_y + vert_radius) + 1, MAX_CARVE_Y);
				const int z0 = std::max(floor_to_int(pos_z - horiz_radius) - chunk_z * 16 - 1, 0);
				const int z1 = std::min(floor_to_int(pos_z + horiz_radius) - chunk_z * 16 + 1, 16);
				if (!touches_lava(blocks, x0, x1, y0, y1, z0, z1)) {
					carve_ellipsoid(blocks, chunk_x, chunk_z, pos_x, pos_y, pos_z, horiz_radius,
							vert_radius, x0, x1, y0, y1, z0, z1);
					if (is_room) {
						break;
					}
				}
			}
		}
		++step;
	}
}

void spawn_from_source_chunk(JavaRandom &rng, uint8_t *blocks, int source_x, int source_z,
		int target_x, int target_z) {
	int count = rng.next_int_bounded(rng.next_int_bounded(rng.next_int_bounded(10) + 1) + 1);
	if (rng.next_int_bounded(5) != 0) {
		count = 0;
	}
	for (int i = 0; i < count; ++i) {
		const double x = static_cast<double>(source_x * 16 + rng.next_int_bounded(16));
		const double y = static_cast<double>(rng.next_int_bounded(128));
		const double z = static_cast<double>(source_z * 16 + rng.next_int_bounded(16));
		int branches = 1;
		if (rng.next_int_bounded(4) == 0) {
			carve_worm(rng, blocks, target_x, target_z, x, y, z,
					fadd(1.0f, fmul(rng.next_float(), 6.0f)), 0.0f, 0.0f, -1, -1, 0.5);
			branches += rng.next_int_bounded(4);
		}
		for (int b = 0; b < branches; ++b) {
			const float yaw = fmul(fmul(rng.next_float(), PI_F), 2.0f);
			const float pitch = fdiv(fmul(fsub(rng.next_float(), 0.5f), 2.0f), 8.0f);
			const float width = fadd(fmul(rng.next_float(), 2.0f), rng.next_float());
			carve_worm(rng, blocks, target_x, target_z, x, y, z, fmul(width, 2.0f), yaw, pitch, 0,
					0, 0.5);
		}
	}
}

void carve_caves(uint8_t *blocks, int chunk_x, int chunk_z, int64_t world_seed) {
	JavaRandom rng(world_seed);
	// next_long, NOT the legacy unsigned-low variant the Overworld caves
	// are pinned to — this is new code, so it uses the Alpha-correct one.
	const int64_t mul_x = rng.next_long() / 2 * 2 + 1;
	const int64_t mul_z = rng.next_long() / 2 * 2 + 1;
	for (int sx = chunk_x - CAVE_NEIGHBOURHOOD; sx <= chunk_x + CAVE_NEIGHBOURHOOD; ++sx) {
		for (int sz = chunk_z - CAVE_NEIGHBOURHOOD; sz <= chunk_z + CAVE_NEIGHBOURHOOD; ++sz) {
			// dl.java:16 — `(long)i2 * l2 + (long)i3 * l3 ^ cy2.u`. In Java
			// `^` binds LOOSER than `+`, so the xor applies to the whole
			// sum. Grouping it as `a + (b ^ seed)` silently reseeds every
			// cave in the world.
			rng.set_seed((static_cast<int64_t>(sx) * mul_x +
								 static_cast<int64_t>(sz) * mul_z) ^
					world_seed);
			spawn_from_source_chunk(rng, blocks, sx, sz, chunk_x, chunk_z);
		}
	}
}

// --- Terrain assembly -----------------------------------------------------

void build_terrain(uint8_t *blocks, int chunk_x, int chunk_z, int64_t world_seed) {
	const NetherNoise &noise = ensure_noise();
	std::memset(blocks, 0, CHUNK_VOLUME);
	JavaRandom rng(static_cast<int64_t>(chunk_x) * SEED_MUL_X +
			static_cast<int64_t>(chunk_z) * SEED_MUL_Z);
	fill_base(noise, blocks, chunk_x, chunk_z);
	apply_surface(noise, blocks, chunk_x, chunk_z, rng);
	carve_caves(blocks, chunk_x, chunk_z, world_seed);
}

const std::vector<uint8_t> &cached_terrain(int chunk_x, int chunk_z, int64_t world_seed) {
	const int64_t key = cache_key(chunk_x, chunk_z);
	{
		std::lock_guard<std::mutex> guard(g_state_mutex);
		auto it = g_terrain_cache.find(key);
		if (it != g_terrain_cache.end()) {
			return it->second;
		}
	}
	// Computed OUTSIDE the lock: two workers may duplicate one chunk's
	// terrain, which is deterministic, so the duplicate is wasted time
	// rather than a correctness problem.
	std::vector<uint8_t> terrain(CHUNK_VOLUME);
	build_terrain(terrain.data(), chunk_x, chunk_z, world_seed);
	std::lock_guard<std::mutex> guard(g_state_mutex);
	if (g_terrain_cache.size() >= CACHE_LIMIT) {
		g_terrain_cache.clear();
	}
	return g_terrain_cache.emplace(key, std::move(terrain)).first->second;
}

// --- Population (kj.java:265-312 plus kf/pm/dt/lp/aj) ---------------------

constexpr int WINDOW_CHUNKS = 2;
constexpr int WINDOW = WINDOW_CHUNKS * 16;
constexpr int HEIGHT = 128;
constexpr int LAVA_SPRINGS = 8;
constexpr int GLOWSTONE_B_COUNT = 10;
constexpr int ANCHOR_Y_SPAN = 120;
constexpr int ANCHOR_Y_BASE = 4;
constexpr int FIRE_ATTEMPTS = 64;
constexpr int GLOWSTONE_ATTEMPTS = 1500;
constexpr int MUSHROOM_ATTEMPTS = 64;

inline int window_index(int lx, int y, int lz) {
	return (lx * WINDOW + lz) * HEIGHT + y;
}

inline bool opaque_support(uint8_t id) {
	return id == 1 || id == A_GRASS || id == A_DIRT || id == A_BEDROCK || id == A_GRAVEL ||
			id == A_NETHERRACK || id == A_SOUL_SAND || id == A_GLOWSTONE;
}

struct Window {
	std::vector<uint8_t> cells;
	int origin_x;
	int origin_z;

	uint8_t read(int x, int y, int z) const {
		const int lx = x - origin_x;
		const int lz = z - origin_z;
		if (lx < 0 || lx >= WINDOW || lz < 0 || lz >= WINDOW || y < 0 || y >= HEIGHT) {
			return A_AIR;
		}
		return cells[window_index(lx, y, lz)];
	}

	void write(int x, int y, int z, uint8_t id) {
		const int lx = x - origin_x;
		const int lz = z - origin_z;
		if (lx < 0 || lx >= WINDOW || lz < 0 || lz >= WINDOW || y < 0 || y >= HEIGHT) {
			return;
		}
		cells[window_index(lx, y, lz)] = id;
	}
};

// kf.java. DEVIATION: the source follows placement with a block update
// that runs Alpha's fluid tick during generation; this places the source
// block and leaves the flow to the project's own fluid system.
void lava_spring(Window &w, int x, int y, int z) {
	if (w.read(x, y + 1, z) != A_NETHERRACK) {
		return;
	}
	const uint8_t here = w.read(x, y, z);
	if (here != A_AIR && here != A_NETHERRACK) {
		return;
	}
	const int nx[5] = { x - 1, x + 1, x, x, x };
	const int ny[5] = { y, y, y, y, y - 1 };
	const int nz[5] = { z, z, z - 1, z + 1, z };
	int rock = 0;
	int air = 0;
	for (int i = 0; i < 5; ++i) {
		const uint8_t id = w.read(nx[i], ny[i], nz[i]);
		if (id == A_NETHERRACK) {
			++rock;
		} else if (id == A_AIR) {
			++air;
		}
	}
	if (rock == 4 && air == 1) {
		w.write(x, y, z, A_LAVA_FLOWING);
	}
}

// pm.java. Draw order is X, Y, Z.
void fire_cluster(Window &w, JavaRandom &rng, int x, int y, int z) {
	for (int i = 0; i < FIRE_ATTEMPTS; ++i) {
		const int tx = x + rng.next_int_bounded(8) - rng.next_int_bounded(8);
		const int ty = y + rng.next_int_bounded(4) - rng.next_int_bounded(4);
		const int tz = z + rng.next_int_bounded(8) - rng.next_int_bounded(8);
		if (w.read(tx, ty, tz) != A_AIR) {
			continue;
		}
		if (w.read(tx, ty - 1, tz) != A_NETHERRACK) {
			continue;
		}
		w.write(tx, ty, tz, A_FIRE);
	}
}

// dt.java / lp.java — byte-identical in the decompiled source, so one
// implementation serves both entry points.
void glowstone(Window &w, JavaRandom &rng, int x, int y, int z) {
	if (w.read(x, y, z) != A_AIR) {
		return;
	}
	if (w.read(x, y + 1, z) != A_NETHERRACK) {
		return;
	}
	w.write(x, y, z, A_GLOWSTONE);
	for (int i = 0; i < GLOWSTONE_ATTEMPTS; ++i) {
		const int tx = x + rng.next_int_bounded(8) - rng.next_int_bounded(8);
		const int ty = y - rng.next_int_bounded(12);
		const int tz = z + rng.next_int_bounded(8) - rng.next_int_bounded(8);
		if (w.read(tx, ty, tz) != A_AIR) {
			continue;
		}
		// Exactly ONE orthogonal neighbour must already be glowstone.
		int touching = 0;
		touching += w.read(tx - 1, ty, tz) == A_GLOWSTONE;
		touching += w.read(tx + 1, ty, tz) == A_GLOWSTONE;
		touching += w.read(tx, ty - 1, tz) == A_GLOWSTONE;
		touching += w.read(tx, ty + 1, tz) == A_GLOWSTONE;
		touching += w.read(tx, ty, tz - 1) == A_GLOWSTONE;
		touching += w.read(tx, ty, tz + 1) == A_GLOWSTONE;
		if (touching != 1) {
			continue;
		}
		w.write(tx, ty, tz, A_GLOWSTONE);
	}
}

// aj.java. The source predicate is `light <= 13 && isOpaqueCube(below)`;
// no light exists during Nether population, so only the support remains.
void mushroom(Window &w, JavaRandom &rng, int x, int y, int z, uint8_t block_id) {
	for (int i = 0; i < MUSHROOM_ATTEMPTS; ++i) {
		const int tx = x + rng.next_int_bounded(8) - rng.next_int_bounded(8);
		const int ty = y + rng.next_int_bounded(4) - rng.next_int_bounded(4);
		const int tz = z + rng.next_int_bounded(8) - rng.next_int_bounded(8);
		if (w.read(tx, ty, tz) != A_AIR) {
			continue;
		}
		if (!opaque_support(w.read(tx, ty - 1, tz))) {
			continue;
		}
		w.write(tx, ty, tz, block_id);
	}
}

void populate(Window &w, JavaRandom &rng, int source_x, int source_z) {
	const int base_x = source_x * 16;
	const int base_z = source_z * 16;
	for (int i = 0; i < LAVA_SPRINGS; ++i) {
		const int x = base_x + rng.next_int_bounded(16) + 8;
		const int y = rng.next_int_bounded(ANCHOR_Y_SPAN) + ANCHOR_Y_BASE;
		const int z = base_z + rng.next_int_bounded(16) + 8;
		lava_spring(w, x, y, z);
	}
	const int fire_count = rng.next_int_bounded(rng.next_int_bounded(10) + 1) + 1;
	for (int i = 0; i < fire_count; ++i) {
		const int x = base_x + rng.next_int_bounded(16) + 8;
		const int y = rng.next_int_bounded(ANCHOR_Y_SPAN) + ANCHOR_Y_BASE;
		const int z = base_z + rng.next_int_bounded(16) + 8;
		fire_cluster(w, rng, x, y, z);
	}
	// Note the missing `+ 1` — glowstone A can legitimately be zero.
	const int glow_a = rng.next_int_bounded(rng.next_int_bounded(10) + 1);
	for (int i = 0; i < glow_a; ++i) {
		const int x = base_x + rng.next_int_bounded(16) + 8;
		const int y = rng.next_int_bounded(ANCHOR_Y_SPAN) + ANCHOR_Y_BASE;
		const int z = base_z + rng.next_int_bounded(16) + 8;
		glowstone(w, rng, x, y, z);
	}
	for (int i = 0; i < GLOWSTONE_B_COUNT; ++i) {
		const int x = base_x + rng.next_int_bounded(16) + 8;
		const int y = rng.next_int_bounded(128);
		const int z = base_z + rng.next_int_bounded(16) + 8;
		glowstone(w, rng, x, y, z);
	}
	// Both guards are `nextInt(1) == 0`, always true — the draw still
	// happens and still advances the stream.
	if (rng.next_int_bounded(1) == 0) {
		const int x = base_x + rng.next_int_bounded(16) + 8;
		const int y = rng.next_int_bounded(128);
		const int z = base_z + rng.next_int_bounded(16) + 8;
		mushroom(w, rng, x, y, z, A_MUSHROOM_BROWN);
	}
	if (rng.next_int_bounded(1) == 0) {
		const int x = base_x + rng.next_int_bounded(16) + 8;
		const int y = rng.next_int_bounded(128);
		const int z = base_z + rng.next_int_bounded(16) + 8;
		mushroom(w, rng, x, y, z, A_MUSHROOM_RED);
	}
}

// The canonical RNG state: the source chunk's own seed, advanced by
// exactly the draws its surface pass makes.
JavaRandom post_surface_rng(int chunk_x, int chunk_z, int64_t world_seed) {
	const NetherNoise &noise = ensure_noise();
	std::vector<uint8_t> scratch(CHUNK_VOLUME, 0);
	JavaRandom rng(static_cast<int64_t>(chunk_x) * SEED_MUL_X +
			static_cast<int64_t>(chunk_z) * SEED_MUL_Z);
	fill_base(noise, scratch.data(), chunk_x, chunk_z);
	apply_surface(noise, scratch.data(), chunk_x, chunk_z, rng);
	(void)world_seed;
	return rng;
}

const std::vector<int32_t> &cached_write_list(int source_x, int source_z, int64_t world_seed) {
	const int64_t key = cache_key(source_x, source_z);
	{
		std::lock_guard<std::mutex> guard(g_state_mutex);
		auto it = g_writes_cache.find(key);
		if (it != g_writes_cache.end()) {
			return it->second;
		}
	}
	Window w;
	w.cells.assign(WINDOW * HEIGHT * WINDOW, 0);
	w.origin_x = source_x * 16;
	w.origin_z = source_z * 16;
	for (int dx = 0; dx < WINDOW_CHUNKS; ++dx) {
		for (int dz = 0; dz < WINDOW_CHUNKS; ++dz) {
			const std::vector<uint8_t> &terrain =
					cached_terrain(source_x + dx, source_z + dz, world_seed);
			for (int x = 0; x < 16; ++x) {
				for (int z = 0; z < 16; ++z) {
					for (int y = 0; y < HEIGHT; ++y) {
						w.cells[window_index(dx * 16 + x, y, dz * 16 + z)] =
								terrain[alpha_index(x, y, z)];
					}
				}
			}
		}
	}
	const std::vector<uint8_t> before = w.cells;
	JavaRandom rng = post_surface_rng(source_x, source_z, world_seed);
	populate(w, rng, source_x, source_z);

	std::vector<int32_t> writes;
	for (int lx = 0; lx < WINDOW; ++lx) {
		for (int lz = 0; lz < WINDOW; ++lz) {
			for (int y = 0; y < HEIGHT; ++y) {
				const int i = window_index(lx, y, lz);
				if (before[i] == w.cells[i]) {
					continue;
				}
				writes.push_back(source_x * 16 + lx);
				writes.push_back(y);
				writes.push_back(source_z * 16 + lz);
				writes.push_back(w.cells[i]);
			}
		}
	}
	std::lock_guard<std::mutex> guard(g_state_mutex);
	if (g_writes_cache.size() >= CACHE_LIMIT) {
		g_writes_cache.clear();
	}
	return g_writes_cache.emplace(key, std::move(writes)).first->second;
}

}  // namespace

// ===========================================================================
// Public entry points
// ===========================================================================

void WorldgenNetherNative::set_world_seed(int64_t p_seed) {
	std::lock_guard<std::mutex> guard(g_state_mutex);
	g_world_seed = p_seed;
	g_noise.built = false;
	g_terrain_cache.clear();
	g_writes_cache.clear();
}

void WorldgenNetherNative::clear_caches() {
	std::lock_guard<std::mutex> guard(g_state_mutex);
	g_terrain_cache.clear();
	g_writes_cache.clear();
}

PackedByteArray WorldgenNetherNative::generate_terrain_only(int p_chunk_x, int p_chunk_z) {
	int64_t seed;
	{
		std::lock_guard<std::mutex> guard(g_state_mutex);
		seed = g_world_seed;
	}
	const std::vector<uint8_t> &terrain = cached_terrain(p_chunk_x, p_chunk_z, seed);
	PackedByteArray out;
	out.resize(CHUNK_VOLUME);
	std::memcpy(out.ptrw(), terrain.data(), CHUNK_VOLUME);
	return out;
}

PackedByteArray WorldgenNetherNative::generate_raw(int p_chunk_x, int p_chunk_z) {
	int64_t seed;
	{
		std::lock_guard<std::mutex> guard(g_state_mutex);
		seed = g_world_seed;
	}
	PackedByteArray out = generate_terrain_only(p_chunk_x, p_chunk_z);
	uint8_t *blocks = out.ptrw();
	const int min_x = p_chunk_x * 16;
	const int min_z = p_chunk_z * 16;
	// Ascending (x, z) so two sources writing one cell resolve the same
	// way every time.
	for (int sx = p_chunk_x - 1; sx <= p_chunk_x; ++sx) {
		for (int sz = p_chunk_z - 1; sz <= p_chunk_z; ++sz) {
			const std::vector<int32_t> &writes = cached_write_list(sx, sz, seed);
			for (size_t i = 0; i + 3 < writes.size(); i += 4) {
				const int lx = writes[i] - min_x;
				const int lz = writes[i + 2] - min_z;
				if (lx < 0 || lx >= 16 || lz < 0 || lz >= 16) {
					continue;
				}
				blocks[alpha_index(lx, writes[i + 1], lz)] = static_cast<uint8_t>(writes[i + 3]);
			}
		}
	}
	return out;
}

PackedInt32Array WorldgenNetherNative::write_list(int p_source_x, int p_source_z) {
	int64_t seed;
	{
		std::lock_guard<std::mutex> guard(g_state_mutex);
		seed = g_world_seed;
	}
	const std::vector<int32_t> &writes = cached_write_list(p_source_x, p_source_z, seed);
	PackedInt32Array out;
	out.resize(static_cast<int>(writes.size()));
	if (!writes.empty()) {
		std::memcpy(out.ptrw(), writes.data(), writes.size() * sizeof(int32_t));
	}
	return out;
}

void WorldgenNetherNative::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("set_world_seed", "seed"), &WorldgenNetherNative::set_world_seed);
	ClassDB::bind_method(D_METHOD("generate_terrain_only", "chunk_x", "chunk_z"),
			&WorldgenNetherNative::generate_terrain_only);
	ClassDB::bind_method(D_METHOD("generate_raw", "chunk_x", "chunk_z"),
			&WorldgenNetherNative::generate_raw);
	ClassDB::bind_method(D_METHOD("write_list", "source_x", "source_z"),
			&WorldgenNetherNative::write_list);
	ClassDB::bind_method(D_METHOD("clear_caches"), &WorldgenNetherNative::clear_caches);
}
