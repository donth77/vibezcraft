#ifndef MESHER_NATIVE_H
#define MESHER_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// Native port of scripts/world/mesher.gd — face-culled naive meshing.
// Output is byte-identical to the GDScript version (enforced by
// tests/test_mesher_native.gd parity cases).
//
// The GDScript wrapper marshals:
//   blocks    = chunk.blocks                (PackedByteArray of CHUNK_VOLUME)
//   max_y     = chunk.max_y                 (int)
//   uv_table  = BlockAtlas.uv_table_flat()  (PackedFloat32Array, 4 floats
//                                            per (block_id*3 + face_kind))
// and gets back a Dictionary matching Mesher.mesh_chunk's shape:
//   { vertices: PackedVector3Array, normals: PackedVector3Array,
//     uvs:      PackedVector2Array, indices: PackedInt32Array }
class MesherNative : public RefCounted {
	GDCLASS(MesherNative, RefCounted);

public:
	// Must mirror scripts/world/chunk.gd.
	static constexpr int SIZE_X = 16;
	static constexpr int SIZE_Y = 128;
	static constexpr int SIZE_Z = 16;
	// Mirrors scripts/world/blocks.gd.
	static constexpr int AIR = 0;

	MesherNative();
	~MesherNative();

	String ping() const;

	Dictionary mesh_chunk_data(
			const PackedByteArray &p_blocks,
			int p_max_y,
			const PackedFloat32Array &p_uv_table) const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif
