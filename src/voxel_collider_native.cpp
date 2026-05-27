#include "voxel_collider_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

using namespace godot;

namespace {

// Up to 4 chunks (2×2) can intersect a fast-moving entity's swept AABB; a
// small fixed-size scan beats unordered_map for this size.
struct ChunkEntry {
	int cx;
	int cz;
	const uint8_t *blocks;
};

constexpr int SIZE_X = VoxelColliderNative::SIZE_X;
constexpr int SIZE_Y = VoxelColliderNative::SIZE_Y;
constexpr int SIZE_Z = VoxelColliderNative::SIZE_Z;
constexpr double EPSILON = 0.0001;

inline int floor_div(int a, int b) {
	// Matches GDScript int(floor(float(a) / float(b))) for b > 0.
	int q = a / b;
	int r = a % b;
	return (r != 0 && (r ^ b) < 0) ? q - 1 : q;
}

inline int floord(double v) {
	return (int)std::floor(v);
}

inline double sign_of(double v) {
	if (v > 0.0) return 1.0;
	if (v < 0.0) return -1.0;
	return 0.0;
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
		return false; // unloaded / out-of-range chunk → AIR
	}
	int local_x = x - cx * SIZE_X;
	int local_z = z - cz * SIZE_Z;
	int idx = y * SIZE_X * SIZE_Z + local_z * SIZE_X + local_x;
	uint8_t id = blocks[idx];
	return solid_lut[id] != 0;
}

// Walks the integer cells the AABB overlaps along the X axis and returns
// the clipped X motion (≤ |motion|, same sign). Mirrors
// voxel_collider.gd::_clip_x.
double clip_x(
		double pos_x, double pos_y, double pos_z,
		double half_x, double half_y, double half_z,
		double motion,
		const ChunkEntry *chunks, int n_chunks,
		const uint8_t *solid_lut) {
	double sign_motion = sign_of(motion);
	int lo_y = floord(pos_y - half_y);
	int hi_y = floord(pos_y + half_y);
	int lo_z = floord(pos_z - half_z);
	int hi_z = floord(pos_z + half_z);
	double clipped = motion;
	double lead_x = pos_x + half_x * sign_motion + motion;
	double trail_x = pos_x + half_x * sign_motion;
	int lo_x = floord(std::fmin(trail_x, lead_x));
	int hi_x = floord(std::fmax(trail_x, lead_x));
	for (int cx = lo_x; cx <= hi_x; cx++) {
		for (int cy = lo_y; cy <= hi_y; cy++) {
			for (int cz = lo_z; cz <= hi_z; cz++) {
				if (!cell_solid(cx, cy, cz, chunks, n_chunks, solid_lut)) {
					continue;
				}
				double face = (sign_motion > 0.0) ? (double)cx : (double)(cx + 1);
				double allowed = (face - (pos_x + half_x * sign_motion)) * sign_motion;
				allowed = std::fmax(0.0, allowed - EPSILON);
				if (allowed * sign_motion < clipped * sign_motion) {
					clipped = allowed * sign_motion;
				}
			}
		}
	}
	return clipped;
}

double clip_y(
		double pos_x, double pos_y, double pos_z,
		double half_x, double half_y, double half_z,
		double motion,
		const ChunkEntry *chunks, int n_chunks,
		const uint8_t *solid_lut) {
	double sign_motion = sign_of(motion);
	int lo_x = floord(pos_x - half_x);
	int hi_x = floord(pos_x + half_x);
	int lo_z = floord(pos_z - half_z);
	int hi_z = floord(pos_z + half_z);
	double clipped = motion;
	double lead_y = pos_y + half_y * sign_motion + motion;
	double trail_y = pos_y + half_y * sign_motion;
	int lo_y = floord(std::fmin(trail_y, lead_y));
	int hi_y = floord(std::fmax(trail_y, lead_y));
	for (int cy = lo_y; cy <= hi_y; cy++) {
		for (int cx = lo_x; cx <= hi_x; cx++) {
			for (int cz = lo_z; cz <= hi_z; cz++) {
				if (!cell_solid(cx, cy, cz, chunks, n_chunks, solid_lut)) {
					continue;
				}
				double face = (sign_motion > 0.0) ? (double)cy : (double)(cy + 1);
				double allowed = (face - (pos_y + half_y * sign_motion)) * sign_motion;
				allowed = std::fmax(0.0, allowed - EPSILON);
				if (allowed * sign_motion < clipped * sign_motion) {
					clipped = allowed * sign_motion;
				}
			}
		}
	}
	return clipped;
}

double clip_z(
		double pos_x, double pos_y, double pos_z,
		double half_x, double half_y, double half_z,
		double motion,
		const ChunkEntry *chunks, int n_chunks,
		const uint8_t *solid_lut) {
	double sign_motion = sign_of(motion);
	int lo_x = floord(pos_x - half_x);
	int hi_x = floord(pos_x + half_x);
	int lo_y = floord(pos_y - half_y);
	int hi_y = floord(pos_y + half_y);
	double clipped = motion;
	double lead_z = pos_z + half_z * sign_motion + motion;
	double trail_z = pos_z + half_z * sign_motion;
	int lo_z = floord(std::fmin(trail_z, lead_z));
	int hi_z = floord(std::fmax(trail_z, lead_z));
	for (int cz = lo_z; cz <= hi_z; cz++) {
		for (int cx = lo_x; cx <= hi_x; cx++) {
			for (int cy = lo_y; cy <= hi_y; cy++) {
				if (!cell_solid(cx, cy, cz, chunks, n_chunks, solid_lut)) {
					continue;
				}
				double face = (sign_motion > 0.0) ? (double)cz : (double)(cz + 1);
				double allowed = (face - (pos_z + half_z * sign_motion)) * sign_motion;
				allowed = std::fmax(0.0, allowed - EPSILON);
				if (allowed * sign_motion < clipped * sign_motion) {
					clipped = allowed * sign_motion;
				}
			}
		}
	}
	return clipped;
}

bool is_on_floor_probe(
		double pos_x, double pos_y, double pos_z,
		double half_x, double half_y, double half_z,
		const ChunkEntry *chunks, int n_chunks,
		const uint8_t *solid_lut) {
	int lo_x = floord(pos_x - half_x);
	int hi_x = floord(pos_x + half_x);
	int lo_z = floord(pos_z - half_z);
	int hi_z = floord(pos_z + half_z);
	int foot_y = floord(pos_y - half_y - 0.02);
	for (int cx = lo_x; cx <= hi_x; cx++) {
		for (int cz = lo_z; cz <= hi_z; cz++) {
			if (cell_solid(cx, foot_y, cz, chunks, n_chunks, solid_lut)) {
				return true;
			}
		}
	}
	return false;
}

} // namespace

VoxelColliderNative::VoxelColliderNative() {}
VoxelColliderNative::~VoxelColliderNative() {}

Dictionary VoxelColliderNative::move(
		const Vector3 &p_pos_in,
		const Vector3 &p_half_extents,
		const Vector3 &p_velocity,
		double p_delta,
		const Array &p_chunk_data,
		const PackedByteArray &p_solid_lut) const {
	Dictionary result;
	if (p_solid_lut.size() < 256) {
		// Malformed input — return identity move (no collision applied).
		result["pos"] = p_pos_in + p_velocity * p_delta;
		result["vel"] = p_velocity;
		result["on_floor"] = false;
		return result;
	}

	// Marshal chunk data into a fixed-size stack array. 4 covers any
	// plausible swept-AABB span at mob speeds.
	constexpr int MAX_CHUNKS = 16;
	ChunkEntry chunks[MAX_CHUNKS];
	int n_chunks = 0;
	int input_size = p_chunk_data.size();
	if (input_size > MAX_CHUNKS) {
		input_size = MAX_CHUNKS;
	}
	// Hold the PackedByteArrays alive for the duration of the call by
	// keeping a parallel array of values (ptr() is only valid while the
	// PackedByteArray Variant is referenced).
	PackedByteArray block_refs[MAX_CHUNKS];
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

	Vector3 step = p_velocity * p_delta;
	Vector3 pos = p_pos_in;
	Vector3 vel = p_velocity;
	bool on_floor = false;

	// X step
	if (std::fabs(step.x) > EPSILON) {
		double clipped = clip_x(
				pos.x, pos.y, pos.z,
				p_half_extents.x, p_half_extents.y, p_half_extents.z,
				step.x,
				chunks, n_chunks, solid_lut);
		pos.x += clipped;
		if (std::fabs(clipped - step.x) > EPSILON) {
			vel.x = 0.0f;
		}
	}
	// Y step
	if (std::fabs(step.y) > EPSILON) {
		double clipped = clip_y(
				pos.x, pos.y, pos.z,
				p_half_extents.x, p_half_extents.y, p_half_extents.z,
				step.y,
				chunks, n_chunks, solid_lut);
		pos.y += clipped;
		if (std::fabs(clipped - step.y) > EPSILON) {
			if (step.y < 0.0) {
				on_floor = true;
			}
			vel.y = 0.0f;
		}
	} else {
		on_floor = is_on_floor_probe(
				pos.x, pos.y, pos.z,
				p_half_extents.x, p_half_extents.y, p_half_extents.z,
				chunks, n_chunks, solid_lut);
	}
	// Z step
	if (std::fabs(step.z) > EPSILON) {
		double clipped = clip_z(
				pos.x, pos.y, pos.z,
				p_half_extents.x, p_half_extents.y, p_half_extents.z,
				step.z,
				chunks, n_chunks, solid_lut);
		pos.z += clipped;
		if (std::fabs(clipped - step.z) > EPSILON) {
			vel.z = 0.0f;
		}
	}

	result["pos"] = pos;
	result["vel"] = vel;
	result["on_floor"] = on_floor;
	return result;
}

void VoxelColliderNative::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("move", "pos_in", "half_extents", "velocity", "delta", "chunk_data", "solid_lut"),
			&VoxelColliderNative::move);
}
