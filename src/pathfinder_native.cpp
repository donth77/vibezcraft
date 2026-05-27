#include "pathfinder_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>

#include <cmath>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {

constexpr int SIZE_X = PathfinderNative::SIZE_X;
constexpr int SIZE_Y = PathfinderNative::SIZE_Y;
constexpr int SIZE_Z = PathfinderNative::SIZE_Z;

constexpr double STRAIGHT_COST = 1.0;
constexpr double DIAGONAL_COST = 1.4142136;
constexpr double VERTICAL_BONUS = 0.5;

struct ChunkEntry {
	int cx;
	int cz;
	const uint8_t *blocks;
};

inline int floor_div(int a, int b) {
	int q = a / b;
	int r = a % b;
	return (r != 0 && (r ^ b) < 0) ? q - 1 : q;
}

inline bool cell_solid(
		int x, int y, int z,
		const ChunkEntry *chunks, int n_chunks,
		const uint8_t *solid_lut) {
	if (y < 0 || y >= SIZE_Y) {
		return false;
	}
	int cx = floor_div(x, SIZE_X);
	int cz = floor_div(z, SIZE_Z);
	const uint8_t *blocks = nullptr;
	for (int i = 0; i < n_chunks; i++) {
		if (chunks[i].cx == cx && chunks[i].cz == cz) {
			blocks = chunks[i].blocks;
			break;
		}
	}
	if (blocks == nullptr) {
		return false;
	}
	int local_x = x - cx * SIZE_X;
	int local_z = z - cz * SIZE_Z;
	int idx = y * SIZE_X * SIZE_Z + local_z * SIZE_X + local_x;
	uint8_t id = blocks[idx];
	return solid_lut[id] != 0;
}

// _is_walkable(cm, pos) from pathfinder.gd: passable here + solid floor.
inline bool walkable(
		int x, int y, int z,
		const ChunkEntry *chunks, int n_chunks,
		const uint8_t *solid_lut) {
	if (cell_solid(x, y, z, chunks, n_chunks, solid_lut)) {
		return false;
	}
	return cell_solid(x, y - 1, z, chunks, n_chunks, solid_lut);
}

// Pack a Vector3i cell into a 64-bit key. Y uses 7 bits (0..127), X and Z
// use ~28 bits each (signed) — enough range for any plausible world coord.
inline int64_t pack_cell(int x, int y, int z) {
	uint64_t ux = (uint32_t)(x);
	uint64_t uy = (uint32_t)(y) & 0x7F;
	uint64_t uz = (uint32_t)(z);
	return (int64_t)((ux << 39) | (uz << 7) | uy);
}

inline double heuristic(int ax, int ay, int az, int bx, int by, int bz) {
	double dx = (double)(ax - bx);
	double dy = (double)(ay - by);
	double dz = (double)(az - bz);
	return std::sqrt(dx * dx + dy * dy + dz * dz);
}

// 8-way XZ neighbor offsets — matches NEIGHBOR_DELTAS in pathfinder.gd.
// Cardinals first so equal-cost ties prefer straight moves (linear-scan
// open set takes the lower index when f scores are equal).
constexpr int N_DELTAS = 8;
constexpr int DELTAS[N_DELTAS][2] = {
	{ -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 },
	{ -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 },
};

struct OpenEntry {
	double f;
	int x, y, z;
};

} // namespace

PathfinderNative::PathfinderNative() {}
PathfinderNative::~PathfinderNative() {}

Array PathfinderNative::find_path(
		const Vector3i &p_start,
		const Vector3i &p_goal,
		double p_max_dist,
		int p_max_iters,
		const Array &p_chunk_data,
		const PackedByteArray &p_solid_lut) const {
	Array out;
	if (p_solid_lut.size() < 256) {
		return out;
	}
	int sx = p_start.x, sy = p_start.y, sz = p_start.z;
	int gx = p_goal.x, gy = p_goal.y, gz = p_goal.z;
	if (sx == gx && sy == gy && sz == gz) {
		return out;
	}

	// Marshal chunks once. 16 covers any plausible mob pathfind span.
	constexpr int MAX_CHUNKS = 16;
	ChunkEntry chunks[MAX_CHUNKS];
	PackedByteArray block_refs[MAX_CHUNKS];
	int n_chunks = 0;
	int input_size = p_chunk_data.size();
	if (input_size > MAX_CHUNKS) {
		input_size = MAX_CHUNKS;
	}
	for (int i = 0; i < input_size; i++) {
		Array entry = p_chunk_data[i];
		if (entry.size() < 3) {
			continue;
		}
		int cx = (int)entry[0];
		int cz = (int)entry[1];
		PackedByteArray blocks = entry[2];
		if (blocks.size() < SIZE_X * SIZE_Y * SIZE_Z) {
			continue;
		}
		block_refs[n_chunks] = blocks;
		chunks[n_chunks].cx = cx;
		chunks[n_chunks].cz = cz;
		chunks[n_chunks].blocks = block_refs[n_chunks].ptr();
		n_chunks++;
	}

	const uint8_t *solid_lut = p_solid_lut.ptr();

	std::vector<OpenEntry> open_set;
	open_set.reserve(128);
	std::unordered_map<int64_t, double> g_score;
	std::unordered_map<int64_t, int64_t> came_from;

	int64_t start_key = pack_cell(sx, sy, sz);
	g_score[start_key] = 0.0;
	open_set.push_back({ heuristic(sx, sy, sz, gx, gy, gz), sx, sy, sz });

	int iters = 0;
	while (!open_set.empty() && iters < p_max_iters) {
		iters++;
		// Linear-scan pop of the lowest f. Open set stays small in
		// practice (<100 entries) so this is cheaper than a heap.
		int min_idx = 0;
		double min_f = open_set[0].f;
		for (size_t i = 1; i < open_set.size(); i++) {
			if (open_set[i].f < min_f) {
				min_idx = (int)i;
				min_f = open_set[i].f;
			}
		}
		OpenEntry current = open_set[min_idx];
		open_set.erase(open_set.begin() + min_idx);

		if (current.x == gx && current.y == gy && current.z == gz) {
			// Reconstruct path back to start, EXCLUDING start.
			std::vector<int64_t> path;
			int64_t cur_key = pack_cell(current.x, current.y, current.z);
			path.push_back(cur_key);
			while (came_from.count(cur_key)) {
				cur_key = came_from[cur_key];
				path.push_back(cur_key);
			}
			// path is goal-first; emit in walk order skipping start
			// (last entry is start, which the GDScript reference pops).
			for (int i = (int)path.size() - 2; i >= 0; i--) {
				int64_t k = path[i];
				int px = (int)((int32_t)((k >> 39) & 0xFFFFFFFF));
				// Sign-extend the 32-bit slice carved out of the 64-bit key.
				// Shifting the X slice down to bit 0 first preserves its
				// sign bit, then a static_cast<int32_t> + widen gives a
				// proper signed coord even for negative world positions.
				int pz_raw = (int)((k >> 7) & 0xFFFFFFFF);
				int32_t pz_signed = (int32_t)pz_raw;
				int py = (int)(k & 0x7F);
				out.append(Vector3i(px, py, (int)pz_signed));
			}
			return out;
		}

		int64_t current_key = pack_cell(current.x, current.y, current.z);
		auto it_g = g_score.find(current_key);
		double current_g = (it_g != g_score.end()) ? it_g->second : 0.0;

		for (int d = 0; d < N_DELTAS; d++) {
			int dx = DELTAS[d][0];
			int dz = DELTAS[d][1];
			// Try same-level → step up → step down. One valid dy per
			// direction (mirrors GDScript reference's `break`).
			int try_dys[3] = { 0, 1, -1 };
			for (int k = 0; k < 3; k++) {
				int dy = try_dys[k];
				int nx = current.x + dx;
				int ny = current.y + dy;
				int nz = current.z + dz;
				if (!walkable(nx, ny, nz, chunks, n_chunks, solid_lut)) {
					continue;
				}
				bool diagonal = (dx != 0 && dz != 0);
				double step_cost = diagonal ? DIAGONAL_COST : STRAIGHT_COST;
				if (dy != 0) {
					step_cost += VERTICAL_BONUS;
				}
				double tentative_g = current_g + step_cost;
				if (tentative_g > p_max_dist) {
					break;
				}
				int64_t neighbor_key = pack_cell(nx, ny, nz);
				auto it_ng = g_score.find(neighbor_key);
				if (it_ng == g_score.end() || tentative_g < it_ng->second) {
					came_from[neighbor_key] = current_key;
					g_score[neighbor_key] = tentative_g;
					double f = tentative_g + heuristic(nx, ny, nz, gx, gy, gz);
					open_set.push_back({ f, nx, ny, nz });
				}
				break; // one dy per direction; see comment in pathfinder.gd
			}
		}
	}
	return out;
}

bool PathfinderNative::is_walkable(
		const Vector3i &p_pos,
		const Array &p_chunk_data,
		const PackedByteArray &p_solid_lut) const {
	if (p_solid_lut.size() < 256) {
		return false;
	}
	constexpr int MAX_CHUNKS = 16;
	ChunkEntry chunks[MAX_CHUNKS];
	PackedByteArray block_refs[MAX_CHUNKS];
	int n_chunks = 0;
	int input_size = p_chunk_data.size();
	if (input_size > MAX_CHUNKS) {
		input_size = MAX_CHUNKS;
	}
	for (int i = 0; i < input_size; i++) {
		Array entry = p_chunk_data[i];
		if (entry.size() < 3) {
			continue;
		}
		int cx = (int)entry[0];
		int cz = (int)entry[1];
		PackedByteArray blocks = entry[2];
		if (blocks.size() < SIZE_X * SIZE_Y * SIZE_Z) {
			continue;
		}
		block_refs[n_chunks] = blocks;
		chunks[n_chunks].cx = cx;
		chunks[n_chunks].cz = cz;
		chunks[n_chunks].blocks = block_refs[n_chunks].ptr();
		n_chunks++;
	}
	const uint8_t *solid_lut = p_solid_lut.ptr();
	return walkable(p_pos.x, p_pos.y, p_pos.z, chunks, n_chunks, solid_lut);
}

void PathfinderNative::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("find_path", "start", "goal", "max_dist", "max_iters", "chunk_data", "solid_lut"),
			&PathfinderNative::find_path);
	ClassDB::bind_method(
			D_METHOD("is_walkable", "pos", "chunk_data", "solid_lut"),
			&PathfinderNative::is_walkable);
}
