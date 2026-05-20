#include "lighting_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {

// Y-major indexing matches scripts/world/chunk.gd:`Chunk.index`.
inline int idx(int x, int y, int z) {
	return y * LightingNative::SIZE_X * LightingNative::SIZE_Z + z * LightingNative::SIZE_X + x;
}

inline int max_int(int a, int b) {
	return a > b ? a : b;
}

} // namespace

LightingNative::LightingNative() {}
LightingNative::~LightingNative() {}

PackedByteArray LightingNative::fill_sky_light(
		const PackedByteArray &p_blocks,
		const PackedByteArray &p_opacity_lut) const {
	PackedByteArray out;
	out.resize(CHUNK_VOLUME);
	if (p_blocks.size() < CHUNK_VOLUME || p_opacity_lut.size() < 256) {
		return out; // malformed input — return zero-filled to avoid crash
	}
	const uint8_t *blocks = p_blocks.ptr();
	uint8_t *sky = out.ptrw();
	const uint8_t *op = p_opacity_lut.ptr();

	// --- Phase 1: per-column top-down ---
	// Mirrors Lighting._column_pass exactly. Above the heightmap (no opacity
	// hit yet) cells stay at 15. Once we hit any opacity, every subsequent
	// cell consumes max(1, opacity).
	for (int x = 0; x < SIZE_X; x++) {
		for (int z = 0; z < SIZE_Z; z++) {
			int light = MAX_LIGHT;
			bool below_heightmap = false;
			for (int y = SIZE_Y - 1; y >= 0; y--) {
				int i = idx(x, y, z);
				int opacity = op[blocks[i]];
				if (!below_heightmap && opacity == 0) {
					sky[i] = MAX_LIGHT;
					continue;
				}
				below_heightmap = true;
				int step = max_int(opacity, 1);
				light = max_int(0, light - step);
				sky[i] = (uint8_t)light;
			}
		}
	}

	// --- Phase 2: lateral BFS ---
	// Seed only cells at MAX_LIGHT (sky-exposed). They're the only sources
	// that can push a brighter value into a neighbor; darker cells get
	// covered via re-queue from neighbor updates.
	std::vector<int> queue;
	queue.reserve(CHUNK_VOLUME / 4);
	for (int y = 0; y < SIZE_Y; y++) {
		for (int z = 0; z < SIZE_Z; z++) {
			for (int x = 0; x < SIZE_X; x++) {
				int i = idx(x, y, z);
				if (sky[i] == MAX_LIGHT) {
					queue.push_back(i);
				}
			}
		}
	}

	// Inline 6-neighbor offsets. Stored as packed (dx, dy, dz) so the
	// inner loop can index by direction.
	static constexpr int N_DX[6] = { 1, -1, 0, 0, 0, 0 };
	static constexpr int N_DY[6] = { 0, 0, 1, -1, 0, 0 };
	static constexpr int N_DZ[6] = { 0, 0, 0, 0, 1, -1 };

	while (!queue.empty()) {
		int p = queue.back();
		queue.pop_back();
		int l = sky[p];
		if (l <= 1) {
			continue;
		}
		int py = p / (SIZE_X * SIZE_Z);
		int pz = (p / SIZE_X) % SIZE_Z;
		int px = p % SIZE_X;
		for (int n = 0; n < 6; n++) {
			int nx = px + N_DX[n];
			int ny = py + N_DY[n];
			int nz = pz + N_DZ[n];
			if (nx < 0 || nx >= SIZE_X || ny < 0 || ny >= SIZE_Y || nz < 0 || nz >= SIZE_Z) {
				continue;
			}
			int ni = idx(nx, ny, nz);
			int nopacity = op[blocks[ni]];
			int step = max_int(nopacity, 1);
			int new_light = max_int(0, l - step);
			if (new_light > sky[ni]) {
				sky[ni] = (uint8_t)new_light;
				if (new_light > 1) {
					queue.push_back(ni);
				}
			}
		}
	}

	return out;
}

// --- Bounded BFS update across world coords (cross-chunk) ---

namespace {

// Chunk slab — one for each chunk intersecting the BFS box. Holds direct
// pointers into the GDScript-owned PackedByteArrays so the BFS can read
// blocks + height_map and read/write sky_light without per-cell
// dictionary lookups.
struct ChunkSlab {
	int chunk_x;
	int chunk_z;
	const uint8_t *blocks;
	uint8_t *sky_light; // mutable — written by BFS
	const uint8_t *height_map;
	PackedByteArray sky_owned; // keeps the array alive for the lifetime of the slab
	bool changed; // set true if BFS modified any cell — caller writes back only when set
};

// Pack chunk coord (x, z) into a 64-bit key. World chunk coords can be
// negative; we shift the int32 high bit out of the way before combining.
inline int64_t chunk_key(int x, int z) {
	return (int64_t(x) << 32) | (int64_t(uint32_t(z)));
}

// Convert a world coord to (chunk_key, local_index in chunk array).
// Floor-division because chunk coords use floor semantics for negatives.
inline int floor_div_size(int v, int size) {
	int q = v / size;
	if (v < 0 && (q * size) != v) {
		q -= 1;
	}
	return q;
}

inline int idx_local(int lx, int ly, int lz) {
	return ly * LightingNative::SIZE_X * LightingNative::SIZE_Z
			+ lz * LightingNative::SIZE_X + lx;
}

inline int hidx_local(int lx, int lz) {
	return lz * LightingNative::SIZE_X + lx;
}

} // namespace

Dictionary LightingNative::update_sky_light_around_world(
		int p_world_x,
		int p_world_y,
		int p_world_z,
		const Array &p_chunk_data,
		const PackedByteArray &p_opacity_lut) const {
	Dictionary result;
	if (p_opacity_lut.size() < 256) {
		return result;
	}
	const uint8_t *op = p_opacity_lut.ptr();

	// Build the chunk lookup map. Slabs own the COW PackedByteArray so
	// the pointers stay valid for the BFS lifetime.
	std::unordered_map<int64_t, ChunkSlab> slabs;
	slabs.reserve(p_chunk_data.size());
	for (int i = 0; i < p_chunk_data.size(); i++) {
		Array entry = p_chunk_data[i];
		if (entry.size() < 5) {
			continue;
		}
		ChunkSlab slab;
		slab.chunk_x = int(entry[0]);
		slab.chunk_z = int(entry[1]);
		PackedByteArray bp = entry[2];
		PackedByteArray sp = entry[3];
		PackedByteArray hp = entry[4];
		if (bp.size() < CHUNK_VOLUME || sp.size() < CHUNK_VOLUME
				|| hp.size() < SIZE_X * SIZE_Z) {
			continue;
		}
		slab.blocks = bp.ptr();
		slab.sky_owned = sp; // own a ref so ptrw stays valid
		slab.sky_light = slab.sky_owned.ptrw();
		slab.height_map = hp.ptr();
		slab.changed = false;
		slabs[chunk_key(slab.chunk_x, slab.chunk_z)] = slab;
	}

	// Bounded box clamps. X/Z extend across chunk borders, Y stays in
	// SIZE_Y bounds.
	const int x_lo = p_world_x - 15;
	const int x_hi = p_world_x + 15;
	const int y_lo = std::max(0, p_world_y - 15);
	const int y_hi = std::min(SIZE_Y - 1, p_world_y + 15);
	const int z_lo = p_world_z - 15;
	const int z_hi = p_world_z + 15;

	// World-coord helpers — encapsulate the chunk routing.
	auto get_block = [&](int wx, int wy, int wz) -> int {
		if (wy < 0 || wy >= SIZE_Y) {
			return 0; // AIR for OOB-y; matches Chunk.get_block
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return 0; // unloaded chunk reads as AIR
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		return it->second.blocks[idx_local(lx, wy, lz)];
	};
	auto get_sky = [&](int wx, int wy, int wz) -> int {
		if (wy < 0 || wy >= SIZE_Y) {
			return MAX_LIGHT; // OOB-y reads as full daylight (slice-1 invariant)
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return MAX_LIGHT;
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		return it->second.sky_light[idx_local(lx, wy, lz)];
	};
	auto set_sky = [&](int wx, int wy, int wz, int value) -> void {
		if (wy < 0 || wy >= SIZE_Y) {
			return;
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return;
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		int li = idx_local(lx, wy, lz);
		if (it->second.sky_light[li] == value) {
			return;
		}
		it->second.sky_light[li] = (uint8_t)value;
		it->second.changed = true;
	};
	// Sky-exposed via cached heightmap (same semantic as
	// Chunk.is_sky_exposed): cell at y is exposed iff y >= height_map[lx,lz].
	auto is_sky_exposed = [&](int wx, int wy, int wz) -> bool {
		if (wy >= SIZE_Y) {
			return true;
		}
		if (wy < 0) {
			return false;
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return true; // unloaded ≡ sky-exposed
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		int top = it->second.height_map[hidx_local(lx, lz)];
		return wy >= top;
	};

	// Per-cell sky-light recompute — mirrors Lighting._recompute_sky_light_at_world.
	// Under-cover cells (emission == 0) treat unloaded-neighbour chunks as
	// DARK rather than sky=15 — see the matching block in relight_chunk_borders
	// for the rationale.
	auto in_loaded_edit = [&](int wx, int wz) -> bool {
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		return slabs.find(chunk_key(cx, cz)) != slabs.end();
	};
	auto recompute = [&](int wx, int wy, int wz) -> int {
		int id = get_block(wx, wy, wz);
		int raw_op = op[id];
		int emission = is_sky_exposed(wx, wy, wz) ? MAX_LIGHT : 0;
		if (raw_op >= 15) {
			return emission;
		}
		int step = std::max(raw_op, 1);
		int max_n = 0;
		bool under_cover = emission == 0;
		static constexpr int N_DX[6] = { 1, -1, 0, 0, 0, 0 };
		static constexpr int N_DY[6] = { 0, 0, 1, -1, 0, 0 };
		static constexpr int N_DZ[6] = { 0, 0, 0, 0, 1, -1 };
		for (int n = 0; n < 6; n++) {
			int nx = wx + N_DX[n];
			int ny = wy + N_DY[n];
			int nz = wz + N_DZ[n];
			int nl;
			if (under_cover && !in_loaded_edit(nx, nz)) {
				nl = 0;
			} else {
				nl = get_sky(nx, ny, nz);
			}
			if (nl > max_n) {
				max_n = nl;
			}
		}
		int from_neighbors = std::max(0, max_n - step);
		return std::max(emission, from_neighbors);
	};

	// Seed: edit cell column + 6 neighbors (matches GDScript reduced
	// seed). Box-clamped so we don't re-queue past the radius.
	std::vector<int64_t> queue; // (wx, wy, wz) packed into 64 bits
	queue.reserve(64);
	auto pack_pos = [](int wx, int wy, int wz) -> int64_t {
		// 24 bits per axis is enough for any world; signed fits comfortably.
		return (int64_t(wx & 0xFFFFFF) << 40)
				| (int64_t(wy & 0xFFFF) << 24)
				| int64_t(wz & 0xFFFFFF);
	};
	auto unpack_pos = [](int64_t k, int &wx, int &wy, int &wz) {
		// Sign-extend each 24-bit / 16-bit field back to int.
		int64_t bx = (k >> 40) & 0xFFFFFF;
		if (bx & 0x800000) bx |= ~int64_t(0xFFFFFF);
		int64_t by = (k >> 24) & 0xFFFF;
		if (by & 0x8000) by |= ~int64_t(0xFFFF);
		int64_t bz = k & 0xFFFFFF;
		if (bz & 0x800000) bz |= ~int64_t(0xFFFFFF);
		wx = int(bx);
		wy = int(by);
		wz = int(bz);
	};

	for (int y = y_lo; y <= y_hi; y++) {
		queue.push_back(pack_pos(p_world_x, y, p_world_z));
	}
	static constexpr int N_DX[6] = { 1, -1, 0, 0, 0, 0 };
	static constexpr int N_DY[6] = { 0, 0, 1, -1, 0, 0 };
	static constexpr int N_DZ[6] = { 0, 0, 0, 0, 1, -1 };
	for (int n = 0; n < 6; n++) {
		int nx = p_world_x + N_DX[n];
		int ny = p_world_y + N_DY[n];
		int nz = p_world_z + N_DZ[n];
		if (nx >= x_lo && nx <= x_hi && ny >= y_lo && ny <= y_hi && nz >= z_lo && nz <= z_hi) {
			queue.push_back(pack_pos(nx, ny, nz));
		}
	}

	while (!queue.empty()) {
		int wx, wy, wz;
		unpack_pos(queue.back(), wx, wy, wz);
		queue.pop_back();
		int current = get_sky(wx, wy, wz);
		int new_light = recompute(wx, wy, wz);
		if (new_light == current) {
			continue;
		}
		set_sky(wx, wy, wz, new_light);
		for (int n = 0; n < 6; n++) {
			int nx = wx + N_DX[n];
			int ny = wy + N_DY[n];
			int nz = wz + N_DZ[n];
			if (nx >= x_lo && nx <= x_hi && ny >= y_lo && ny <= y_hi && nz >= z_lo && nz <= z_hi) {
				queue.push_back(pack_pos(nx, ny, nz));
			}
		}
	}

	// Build result dict: only chunks whose sky_light changed get
	// emitted, keyed by Vector2i(chunk_x, chunk_z).
	for (auto &kv : slabs) {
		if (kv.second.changed) {
			Vector2i coord(kv.second.chunk_x, kv.second.chunk_z);
			result[coord] = kv.second.sky_owned;
		}
	}
	return result;
}

PackedByteArray LightingNative::fill_block_light(
		const PackedByteArray &p_blocks,
		const PackedByteArray &p_opacity_lut,
		const PackedByteArray &p_emission_lut) const {
	PackedByteArray out;
	out.resize(CHUNK_VOLUME);
	if (p_blocks.size() < CHUNK_VOLUME
			|| p_opacity_lut.size() < 256
			|| p_emission_lut.size() < 256) {
		return out;  // malformed input — zero-filled fallback
	}
	const uint8_t *blocks = p_blocks.ptr();
	uint8_t *blk = out.ptrw();
	const uint8_t *op = p_opacity_lut.ptr();
	const uint8_t *em = p_emission_lut.ptr();

	// Seed from every cell that emits light. PackedByteArray.resize()
	// zero-fills, so non-emitter cells start at 0 and never enter the
	// queue until a neighbor pushes a value in.
	std::vector<int> queue;
	queue.reserve(256);
	for (int y = 0; y < SIZE_Y; y++) {
		for (int z = 0; z < SIZE_Z; z++) {
			for (int x = 0; x < SIZE_X; x++) {
				int i = idx(x, y, z);
				uint8_t e = em[blocks[i]];
				if (e > 0) {
					blk[i] = e;
					queue.push_back(i);
				}
			}
		}
	}

	// Same 6-neighbor table + BFS shape as fill_sky_light. Per-step
	// decay = max(1, opacity) so dense matter always darkens at least 1
	// unit per cell. "if new_light > current" keeps the BFS monotone —
	// a brighter path always overwrites a darker prior value.
	static constexpr int N_DX[6] = { 1, -1, 0, 0, 0, 0 };
	static constexpr int N_DY[6] = { 0, 0, 1, -1, 0, 0 };
	static constexpr int N_DZ[6] = { 0, 0, 0, 0, 1, -1 };
	while (!queue.empty()) {
		int p = queue.back();
		queue.pop_back();
		int l = blk[p];
		if (l <= 1) {
			continue;
		}
		int py = p / (SIZE_X * SIZE_Z);
		int pz = (p / SIZE_X) % SIZE_Z;
		int px = p % SIZE_X;
		for (int n = 0; n < 6; n++) {
			int nx = px + N_DX[n];
			int ny = py + N_DY[n];
			int nz = pz + N_DZ[n];
			if (nx < 0 || nx >= SIZE_X || ny < 0 || ny >= SIZE_Y
					|| nz < 0 || nz >= SIZE_Z) {
				continue;
			}
			int ni = idx(nx, ny, nz);
			int nopacity = op[blocks[ni]];
			int step = max_int(nopacity, 1);
			int new_light = max_int(0, l - step);
			if (new_light > blk[ni]) {
				blk[ni] = (uint8_t)new_light;
				if (new_light > 1) {
					queue.push_back(ni);
				}
			}
		}
	}

	return out;
}

// --- Bounded block-light BFS across world coords ---
//
// Mirrors update_sky_light_around_world. The slab carries `block_light`
// instead of `sky_light` and there is no height_map (block channel's
// per-cell source is `emission_lut[id]`, not "is the column open above
// this cell"). Same packed-coord queue, same bidirectional recompute,
// same loaded-chunk-only writes.

namespace {

struct BlockChannelSlab {
	int chunk_x;
	int chunk_z;
	const uint8_t *blocks;
	uint8_t *block_light;
	PackedByteArray block_owned;
	bool changed;
};

} // namespace

Dictionary LightingNative::update_block_light_around_world(
		int p_world_x,
		int p_world_y,
		int p_world_z,
		const Array &p_chunk_data,
		const PackedByteArray &p_opacity_lut,
		const PackedByteArray &p_emission_lut) const {
	Dictionary result;
	if (p_opacity_lut.size() < 256 || p_emission_lut.size() < 256) {
		return result;
	}
	const uint8_t *op = p_opacity_lut.ptr();
	const uint8_t *em = p_emission_lut.ptr();

	std::unordered_map<int64_t, BlockChannelSlab> slabs;
	slabs.reserve(p_chunk_data.size());
	for (int i = 0; i < p_chunk_data.size(); i++) {
		Array entry = p_chunk_data[i];
		if (entry.size() < 4) {
			continue;
		}
		BlockChannelSlab slab;
		slab.chunk_x = int(entry[0]);
		slab.chunk_z = int(entry[1]);
		PackedByteArray bp = entry[2];
		PackedByteArray lp = entry[3];
		if (bp.size() < CHUNK_VOLUME || lp.size() < CHUNK_VOLUME) {
			continue;
		}
		slab.blocks = bp.ptr();
		slab.block_owned = lp;
		slab.block_light = slab.block_owned.ptrw();
		slab.changed = false;
		slabs[chunk_key(slab.chunk_x, slab.chunk_z)] = slab;
	}

	const int x_lo = p_world_x - 15;
	const int x_hi = p_world_x + 15;
	const int y_lo = std::max(0, p_world_y - 15);
	const int y_hi = std::min(SIZE_Y - 1, p_world_y + 15);
	const int z_lo = p_world_z - 15;
	const int z_hi = p_world_z + 15;

	auto get_block = [&](int wx, int wy, int wz) -> int {
		if (wy < 0 || wy >= SIZE_Y) {
			return 0;
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return 0;
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		return it->second.blocks[idx_local(lx, wy, lz)];
	};
	auto get_block_light = [&](int wx, int wy, int wz) -> int {
		if (wy < 0 || wy >= SIZE_Y) {
			return 0;  // OOB-y: no torches above/below the world (matches Chunk default)
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return 0;  // unloaded ≡ no torches (matches Chunk OOB default)
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		return it->second.block_light[idx_local(lx, wy, lz)];
	};
	// Loaded-chunk gate. Mirrors GDScript's _world_pos_in_loaded_chunk —
	// without it, the BFS infinite-loops on cells in unloaded chunks
	// adjacent to a loaded source (set is a no-op so current/new_light
	// keep diverging). Block channel needs this; sky channel dodges it
	// because OOB defaults to 15.
	auto in_loaded = [&](int wx, int wz) -> bool {
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		return slabs.find(chunk_key(cx, cz)) != slabs.end();
	};
	auto set_block_light = [&](int wx, int wy, int wz, int value) -> void {
		if (wy < 0 || wy >= SIZE_Y) {
			return;
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return;
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		int li = idx_local(lx, wy, lz);
		if (it->second.block_light[li] == value) {
			return;
		}
		it->second.block_light[li] = (uint8_t)value;
		it->second.changed = true;
	};

	auto recompute = [&](int wx, int wy, int wz) -> int {
		int id = get_block(wx, wy, wz);
		int raw_op = op[id];
		int emission = em[id];
		if (raw_op >= 15) {
			return emission;
		}
		int step = std::max(raw_op, 1);
		int max_n = 0;
		static constexpr int N_DX[6] = { 1, -1, 0, 0, 0, 0 };
		static constexpr int N_DY[6] = { 0, 0, 1, -1, 0, 0 };
		static constexpr int N_DZ[6] = { 0, 0, 0, 0, 1, -1 };
		for (int n = 0; n < 6; n++) {
			int nl = get_block_light(wx + N_DX[n], wy + N_DY[n], wz + N_DZ[n]);
			if (nl > max_n) {
				max_n = nl;
			}
		}
		int from_neighbors = std::max(0, max_n - step);
		return std::max(emission, from_neighbors);
	};

	std::vector<int64_t> queue;
	queue.reserve(64);
	auto pack_pos = [](int wx, int wy, int wz) -> int64_t {
		return (int64_t(wx & 0xFFFFFF) << 40)
				| (int64_t(wy & 0xFFFF) << 24)
				| int64_t(wz & 0xFFFFFF);
	};
	auto unpack_pos = [](int64_t k, int &wx, int &wy, int &wz) {
		int64_t bx = (k >> 40) & 0xFFFFFF;
		if (bx & 0x800000) bx |= ~int64_t(0xFFFFFF);
		int64_t by = (k >> 24) & 0xFFFF;
		if (by & 0x8000) by |= ~int64_t(0xFFFF);
		int64_t bz = k & 0xFFFFFF;
		if (bz & 0x800000) bz |= ~int64_t(0xFFFFFF);
		wx = int(bx);
		wy = int(by);
		wz = int(bz);
	};

	queue.push_back(pack_pos(p_world_x, p_world_y, p_world_z));
	static constexpr int N_DX[6] = { 1, -1, 0, 0, 0, 0 };
	static constexpr int N_DY[6] = { 0, 0, 1, -1, 0, 0 };
	static constexpr int N_DZ[6] = { 0, 0, 0, 0, 1, -1 };
	for (int n = 0; n < 6; n++) {
		int nx = p_world_x + N_DX[n];
		int ny = p_world_y + N_DY[n];
		int nz = p_world_z + N_DZ[n];
		if (nx >= x_lo && nx <= x_hi && ny >= y_lo && ny <= y_hi && nz >= z_lo && nz <= z_hi) {
			queue.push_back(pack_pos(nx, ny, nz));
		}
	}

	while (!queue.empty()) {
		int wx, wy, wz;
		unpack_pos(queue.back(), wx, wy, wz);
		queue.pop_back();
		if (!in_loaded(wx, wz)) {
			continue;  // see in_loaded comment — anti infinite-loop
		}
		int current = get_block_light(wx, wy, wz);
		int new_light = recompute(wx, wy, wz);
		if (new_light == current) {
			continue;
		}
		set_block_light(wx, wy, wz, new_light);
		for (int n = 0; n < 6; n++) {
			int nx = wx + N_DX[n];
			int ny = wy + N_DY[n];
			int nz = wz + N_DZ[n];
			if (nx >= x_lo && nx <= x_hi && ny >= y_lo && ny <= y_hi && nz >= z_lo && nz <= z_hi) {
				queue.push_back(pack_pos(nx, ny, nz));
			}
		}
	}

	for (auto &kv : slabs) {
		if (kv.second.changed) {
			Vector2i coord(kv.second.chunk_x, kv.second.chunk_z);
			result[coord] = kv.second.block_owned;
		}
	}
	return result;
}

// --- Cross-chunk relight on chunk load (slice 3b) ---
//
// One-shot pass that walks the 4 cardinal seam planes of the target chunk
// against each loaded neighbor and runs a dual-channel (sky + block)
// bidirectional BFS to converge the seams. Mirrors vanilla
// WorldServer.lightChunk → World.b(EnumSkyBlock, AABB).

namespace {

struct DualChannelSlab {
	int chunk_x;
	int chunk_z;
	const uint8_t *blocks;
	uint8_t *sky_light;
	uint8_t *block_light;
	const uint8_t *height_map;
	PackedByteArray sky_owned;
	PackedByteArray block_owned;
	bool sky_changed;
	bool block_changed;
};

} // namespace

Dictionary LightingNative::relight_chunk_borders(
		int p_target_x,
		int p_target_z,
		const Array &p_chunk_data,
		const PackedByteArray &p_opacity_lut,
		const PackedByteArray &p_emission_lut) const {
	Dictionary result;
	if (p_opacity_lut.size() < 256 || p_emission_lut.size() < 256) {
		return result;
	}
	const uint8_t *op = p_opacity_lut.ptr();
	const uint8_t *em = p_emission_lut.ptr();

	std::unordered_map<int64_t, DualChannelSlab> slabs;
	slabs.reserve(p_chunk_data.size());
	for (int i = 0; i < p_chunk_data.size(); i++) {
		Array entry = p_chunk_data[i];
		if (entry.size() < 6) {
			continue;
		}
		DualChannelSlab slab;
		slab.chunk_x = int(entry[0]);
		slab.chunk_z = int(entry[1]);
		PackedByteArray bp = entry[2];
		PackedByteArray sp = entry[3];
		PackedByteArray lp = entry[4];
		PackedByteArray hp = entry[5];
		if (bp.size() < CHUNK_VOLUME
				|| sp.size() < CHUNK_VOLUME
				|| lp.size() < CHUNK_VOLUME
				|| hp.size() < SIZE_X * SIZE_Z) {
			continue;
		}
		slab.blocks = bp.ptr();
		slab.sky_owned = sp;
		slab.sky_light = slab.sky_owned.ptrw();
		slab.block_owned = lp;
		slab.block_light = slab.block_owned.ptrw();
		slab.height_map = hp.ptr();
		slab.sky_changed = false;
		slab.block_changed = false;
		slabs[chunk_key(slab.chunk_x, slab.chunk_z)] = slab;
	}
	auto target_it = slabs.find(chunk_key(p_target_x, p_target_z));
	if (target_it == slabs.end()) {
		return result;  // target itself missing — caller should not have called us
	}

	// AABB bound: target chunk + 15-cell halo (light decay range).
	const int bx_lo = p_target_x * SIZE_X - 15;
	const int bx_hi = (p_target_x + 1) * SIZE_X - 1 + 15;
	const int bz_lo = p_target_z * SIZE_Z - 15;
	const int bz_hi = (p_target_z + 1) * SIZE_Z - 1 + 15;
	const int by_lo = 0;
	const int by_hi = SIZE_Y - 1;

	auto get_block = [&](int wx, int wy, int wz) -> int {
		if (wy < 0 || wy >= SIZE_Y) {
			return 0;
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return 0;
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		return it->second.blocks[idx_local(lx, wy, lz)];
	};
	auto get_sky = [&](int wx, int wy, int wz) -> int {
		if (wy < 0 || wy >= SIZE_Y) {
			return MAX_LIGHT;
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return MAX_LIGHT;
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		return it->second.sky_light[idx_local(lx, wy, lz)];
	};
	auto get_block_light = [&](int wx, int wy, int wz) -> int {
		if (wy < 0 || wy >= SIZE_Y) {
			return 0;
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return 0;
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		return it->second.block_light[idx_local(lx, wy, lz)];
	};
	auto in_loaded = [&](int wx, int wz) -> bool {
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		return slabs.find(chunk_key(cx, cz)) != slabs.end();
	};
	auto set_sky = [&](int wx, int wy, int wz, int value) -> void {
		if (wy < 0 || wy >= SIZE_Y) {
			return;
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return;
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		int li = idx_local(lx, wy, lz);
		if (it->second.sky_light[li] == value) {
			return;
		}
		it->second.sky_light[li] = (uint8_t)value;
		it->second.sky_changed = true;
	};
	auto set_block_light = [&](int wx, int wy, int wz, int value) -> void {
		if (wy < 0 || wy >= SIZE_Y) {
			return;
		}
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) {
			return;
		}
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		int li = idx_local(lx, wy, lz);
		if (it->second.block_light[li] == value) {
			return;
		}
		it->second.block_light[li] = (uint8_t)value;
		it->second.block_changed = true;
	};
	auto is_sky_exposed = [&](int wx, int wy, int wz) -> bool {
		if (wy >= SIZE_Y) return true;
		if (wy < 0) return false;
		int cx = floor_div_size(wx, SIZE_X);
		int cz = floor_div_size(wz, SIZE_Z);
		auto it = slabs.find(chunk_key(cx, cz));
		if (it == slabs.end()) return true;
		int lx = wx - cx * SIZE_X;
		int lz = wz - cz * SIZE_Z;
		return wy >= it->second.height_map[hidx_local(lx, lz)];
	};

	static constexpr int N_DX[6] = { 1, -1, 0, 0, 0, 0 };
	static constexpr int N_DY[6] = { 0, 0, 1, -1, 0, 0 };
	static constexpr int N_DZ[6] = { 0, 0, 0, 0, 1, -1 };

	auto recompute_sky = [&](int wx, int wy, int wz) -> int {
		int id = get_block(wx, wy, wz);
		int raw_op = op[id];
		int emission = is_sky_exposed(wx, wy, wz) ? MAX_LIGHT : 0;
		if (raw_op >= 15) {
			return emission;
		}
		int step = std::max(raw_op, 1);
		int max_n = 0;
		// Under-cover (emission == 0): treat unloaded-neighbour chunks
		// as DARK (sky=0) instead of the vanilla "unknown = sky 15"
		// convention. An unloaded neighbour at this y is just as likely
		// to be under the same multi-chunk overhang as we are; phantom-
		// 15 lights would flood-light covered chunks at load boundaries.
		// Sky-exposed cells still use the vanilla 15 default.
		bool under_cover = emission == 0;
		for (int n = 0; n < 6; n++) {
			int nx = wx + N_DX[n];
			int ny = wy + N_DY[n];
			int nz = wz + N_DZ[n];
			int nl;
			if (under_cover && !in_loaded(nx, nz)) {
				nl = 0;
			} else {
				nl = get_sky(nx, ny, nz);
			}
			if (nl > max_n) max_n = nl;
		}
		return std::max(emission, std::max(0, max_n - step));
	};
	auto recompute_block = [&](int wx, int wy, int wz) -> int {
		int id = get_block(wx, wy, wz);
		int raw_op = op[id];
		int emission = em[id];
		if (raw_op >= 15) {
			return emission;
		}
		int step = std::max(raw_op, 1);
		int max_n = 0;
		for (int n = 0; n < 6; n++) {
			int nl = get_block_light(wx + N_DX[n], wy + N_DY[n], wz + N_DZ[n]);
			if (nl > max_n) max_n = nl;
		}
		return std::max(emission, std::max(0, max_n - step));
	};

	std::vector<int64_t> sky_queue;
	std::vector<int64_t> block_queue;
	auto pack_pos = [](int wx, int wy, int wz) -> int64_t {
		return (int64_t(wx & 0xFFFFFF) << 40)
				| (int64_t(wy & 0xFFFF) << 24)
				| int64_t(wz & 0xFFFFFF);
	};
	auto unpack_pos = [](int64_t k, int &wx, int &wy, int &wz) {
		int64_t bx = (k >> 40) & 0xFFFFFF;
		if (bx & 0x800000) bx |= ~int64_t(0xFFFFFF);
		int64_t by = (k >> 24) & 0xFFFF;
		if (by & 0x8000) by |= ~int64_t(0xFFFF);
		int64_t bz = k & 0xFFFFFF;
		if (bz & 0x800000) bz |= ~int64_t(0xFFFFFF);
		wx = int(bx);
		wy = int(by);
		wz = int(bz);
	};

	auto seed_cell = [&](int wx, int wy, int wz) {
		int cur_sky = get_sky(wx, wy, wz);
		int new_sky = recompute_sky(wx, wy, wz);
		if (new_sky != cur_sky) {
			set_sky(wx, wy, wz, new_sky);
			sky_queue.push_back(pack_pos(wx, wy, wz));
		}
		int cur_blk = get_block_light(wx, wy, wz);
		int new_blk = recompute_block(wx, wy, wz);
		if (new_blk != cur_blk) {
			set_block_light(wx, wy, wz, new_blk);
			block_queue.push_back(pack_pos(wx, wy, wz));
		}
	};

	// Walk each cardinal seam between the target and any loaded neighbor.
	// The sky channel walks with a ~15-cell halo into both sides; block
	// channel uses the same seeds since the recompute logic differs but
	// the seam topology is identical.
	for (int oi = 0; oi < 4; oi++) {
		int dx = (oi == 0 ? 1 : (oi == 1 ? -1 : 0));
		int dz = (oi == 2 ? 1 : (oi == 3 ? -1 : 0));
		int n_chunk_x = p_target_x + dx;
		int n_chunk_z = p_target_z + dz;
		if (slabs.find(chunk_key(n_chunk_x, n_chunk_z)) == slabs.end()) {
			continue;
		}
		if (dx != 0) {
			int t_world_x = p_target_x * SIZE_X + (dx > 0 ? SIZE_X - 1 : 0);
			int n_world_x = t_world_x + dx;
			for (int z = 0; z < SIZE_Z; z++) {
				int world_z = p_target_z * SIZE_Z + z;
				for (int y = 0; y < SIZE_Y; y++) {
					seed_cell(t_world_x, y, world_z);
					seed_cell(n_world_x, y, world_z);
				}
			}
		} else {
			int t_world_z = p_target_z * SIZE_Z + (dz > 0 ? SIZE_Z - 1 : 0);
			int n_world_z = t_world_z + dz;
			for (int x = 0; x < SIZE_X; x++) {
				int world_x = p_target_x * SIZE_X + x;
				for (int y = 0; y < SIZE_Y; y++) {
					seed_cell(world_x, y, t_world_z);
					seed_cell(world_x, y, n_world_z);
				}
			}
		}
	}

	// Drain sky BFS.
	while (!sky_queue.empty()) {
		int wx, wy, wz;
		unpack_pos(sky_queue.back(), wx, wy, wz);
		sky_queue.pop_back();
		if (!in_loaded(wx, wz)) {
			continue;
		}
		int current = get_sky(wx, wy, wz);
		int new_light = recompute_sky(wx, wy, wz);
		if (new_light == current) {
			continue;
		}
		set_sky(wx, wy, wz, new_light);
		for (int n = 0; n < 6; n++) {
			int nx = wx + N_DX[n];
			int ny = wy + N_DY[n];
			int nz = wz + N_DZ[n];
			if (nx >= bx_lo && nx <= bx_hi && ny >= by_lo && ny <= by_hi && nz >= bz_lo && nz <= bz_hi) {
				sky_queue.push_back(pack_pos(nx, ny, nz));
			}
		}
	}

	// Drain block BFS.
	while (!block_queue.empty()) {
		int wx, wy, wz;
		unpack_pos(block_queue.back(), wx, wy, wz);
		block_queue.pop_back();
		if (!in_loaded(wx, wz)) {
			continue;
		}
		int current = get_block_light(wx, wy, wz);
		int new_light = recompute_block(wx, wy, wz);
		if (new_light == current) {
			continue;
		}
		set_block_light(wx, wy, wz, new_light);
		for (int n = 0; n < 6; n++) {
			int nx = wx + N_DX[n];
			int ny = wy + N_DY[n];
			int nz = wz + N_DZ[n];
			if (nx >= bx_lo && nx <= bx_hi && ny >= by_lo && ny <= by_hi && nz >= bz_lo && nz <= bz_hi) {
				block_queue.push_back(pack_pos(nx, ny, nz));
			}
		}
	}

	// Build per-chunk result. Emit each channel independently so the
	// caller can avoid touching arrays that didn't change.
	for (auto &kv : slabs) {
		if (!kv.second.sky_changed && !kv.second.block_changed) {
			continue;
		}
		Vector2i coord(kv.second.chunk_x, kv.second.chunk_z);
		Dictionary entry;
		if (kv.second.sky_changed) {
			entry["sky_light"] = kv.second.sky_owned;
		}
		if (kv.second.block_changed) {
			entry["block_light"] = kv.second.block_owned;
		}
		result[coord] = entry;
	}
	return result;
}

void LightingNative::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("fill_sky_light", "blocks", "opacity_lut"),
			&LightingNative::fill_sky_light);
	ClassDB::bind_method(
			D_METHOD("fill_block_light", "blocks", "opacity_lut", "emission_lut"),
			&LightingNative::fill_block_light);
	ClassDB::bind_method(
			D_METHOD("update_sky_light_around_world",
					"world_x", "world_y", "world_z", "chunk_data", "opacity_lut"),
			&LightingNative::update_sky_light_around_world);
	ClassDB::bind_method(
			D_METHOD("update_block_light_around_world",
					"world_x", "world_y", "world_z", "chunk_data", "opacity_lut", "emission_lut"),
			&LightingNative::update_block_light_around_world);
	ClassDB::bind_method(
			D_METHOD("relight_chunk_borders",
					"target_x", "target_z", "chunk_data", "opacity_lut", "emission_lut"),
			&LightingNative::relight_chunk_borders);
}
