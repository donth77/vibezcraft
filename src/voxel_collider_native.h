#ifndef VOXEL_COLLIDER_NATIVE_H
#define VOXEL_COLLIDER_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// Native port of scripts/entities/voxel_collider.gd. Hot path: called per
// mob per physics frame (35 × 60 = 2100 calls/sec at typical mob load).
// Pure arithmetic (AABB clipping + cell iteration) — exactly what C++ wins
// at, and what GDScript was spending ~360 µs / call on.
//
// Caller passes in pre-collected chunk data covering the swept AABB so the
// hot inner loop (`_cell_solid`) doesn't have to call back into GDScript
// per cell. Worker-thread safe (no scene tree access).
class VoxelColliderNative : public RefCounted {
	GDCLASS(VoxelColliderNative, RefCounted);

public:
	static constexpr int SIZE_X = 16;
	static constexpr int SIZE_Y = 128;
	static constexpr int SIZE_Z = 16;

	VoxelColliderNative();
	~VoxelColliderNative();

	// Mirrors VoxelCollider.move(). See voxel_collider.gd for full algorithm
	// notes and vanilla references.
	//
	//   p_pos_in       — current world-space AABB center
	//   p_half_extents — entity's AABB half-size (e.g. zombie = (0.3, 0.95, 0.3))
	//   p_velocity     — m/s
	//   p_delta        — frame time (s)
	//   p_chunk_data   — Array of Array, each inner = [
	//                      chunk_x: int,
	//                      chunk_z: int,
	//                      blocks: PackedByteArray (CHUNK_VOLUME)
	//                    ]
	//                    Caller picks chunks the swept AABB might touch
	//                    (typically 1-4). Cells outside listed chunks are
	//                    treated as non-solid (matches GDScript OOB rule).
	//   p_solid_lut    — 256-entry PackedByteArray, solid_lut[id] != 0 if
	//                    Blocks.is_solid_collision(id) is true.
	//
	// Returns: { pos: Vector3, vel: Vector3, on_floor: bool }
	// CALLER MUST write `vel` back to its entity's velocity — GDScript
	// passes Vector3 by VALUE, so in-out parameter mutation doesn't
	// propagate. (Was the root cause of the stuck-chickens bug.)
	Dictionary move(
			const Vector3 &p_pos_in,
			const Vector3 &p_half_extents,
			const Vector3 &p_velocity,
			double p_delta,
			const Array &p_chunk_data,
			const PackedByteArray &p_solid_lut) const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif
