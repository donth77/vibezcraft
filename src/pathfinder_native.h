#ifndef PATHFINDER_NATIVE_H
#define PATHFINDER_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector3i.hpp>

namespace godot {

// Native port of scripts/entities/pathfinder.gd's A* over the voxel grid.
// Hot path for hostile mob AI — at 20 Hz × ~7 NEAR mobs that's ~140
// find_path calls/sec. GDScript reference cost is ~1-3 ms per call
// (dominated by cm.get_world_block dict lookups + open_set linear scans).
// C++ port drops both to native arithmetic with std::unordered_map + a
// per-call chunk-data ptr table.
//
// Algorithm is identical to the GDScript reference — 8-way XZ moves with
// ±1 Y step, Euclidean heuristic, diagonal + vertical cost premium. Parity
// guarded by tests/test_pathfinder_native.gd.
//
// Caller passes the chunk-data table the search might touch (typically 1-4
// chunks around start/goal). Cells outside listed chunks are treated as
// non-solid — same OOB rule as VoxelColliderNative.
class PathfinderNative : public RefCounted {
	GDCLASS(PathfinderNative, RefCounted);

public:
	static constexpr int SIZE_X = 16;
	static constexpr int SIZE_Y = 128;
	static constexpr int SIZE_Z = 16;

	PathfinderNative();
	~PathfinderNative();

	// Run A* from start to goal. Returns an Array of Vector3i in walk
	// order EXCLUDING start (caller walks from current pos → result[0]).
	// Empty Array → unreachable within max_dist or max_iters budget.
	//
	//   p_start, p_goal — world-coord cells
	//   p_max_dist      — max cumulative path cost; cells past this are pruned
	//   p_max_iters     — A* iteration cap (vanilla Beta uses 200)
	//   p_chunk_data    — Array of Array, each inner = [
	//                       chunk_x: int,
	//                       chunk_z: int,
	//                       blocks: PackedByteArray (CHUNK_VOLUME)
	//                     ]
	//   p_solid_lut     — 256-entry PackedByteArray, solid_lut[id] != 0 if
	//                     Blocks.is_solid_collision(id) is true.
	Array find_path(
			const Vector3i &p_start,
			const Vector3i &p_goal,
			double p_max_dist,
			int p_max_iters,
			const Array &p_chunk_data,
			const PackedByteArray &p_solid_lut) const;

	// Single-cell walkability probe — same rules as find_path uses
	// internally. Lets wander-target pickers prefilter samples cheaply.
	bool is_walkable(
			const Vector3i &p_pos,
			const Array &p_chunk_data,
			const PackedByteArray &p_solid_lut) const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif
