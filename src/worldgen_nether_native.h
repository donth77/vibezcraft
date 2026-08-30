#ifndef WORLDGEN_NETHER_NATIVE_H
#define WORLDGEN_NETHER_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

// Native port of the Alpha 1.2.6 Nether generator — scripts/world/
// worldgen_nether.gd, worldgen_nether_caves.gd and
// worldgen_nether_population.gd.
//
// The GDScript side stays the correctness reference. This must match it
// byte for byte, which tests/test_nether_worldgen_native.gd enforces
// against the same source-oracle fixtures both paths are measured by.
//
// Deliberately a SEPARATE class rather than a dimension flag on
// WorldgenNative: the two generators share only their noise primitives
// (worldgen_native_shared.h), and overloading the Overworld entry points
// with a dimension parameter is what the plan says not to do.
class WorldgenNetherNative : public RefCounted {
	GDCLASS(WorldgenNetherNative, RefCounted)

protected:
	static void _bind_methods();

public:
	// Set from Game._ready and on every world load. Rebuilds the seven
	// octave generators lazily and drops the caches.
	void set_world_seed(int64_t p_seed);

	// Terrain only — density, surface, bedrock, caves. Raw Alpha block
	// ids in Alpha's own (x * 16 + z) * 128 + y layout, matching the
	// GDScript reference so the project remap stays one explicit step on
	// the script side.
	PackedByteArray generate_terrain_only(int p_chunk_x, int p_chunk_z);

	// Terrain plus the decorations of the four source chunks that reach
	// this one.
	PackedByteArray generate_raw(int p_chunk_x, int p_chunk_z);

	// One source chunk's decorations as a flat [x, y, z, id, ...] list in
	// world coordinates. Exposed so parity tests can compare write lists
	// directly rather than only whole chunks.
	PackedInt32Array write_list(int p_source_x, int p_source_z);

	// Drop the terrain and write-list caches.
	void clear_caches();
};

}  // namespace godot

#endif  // WORLDGEN_NETHER_NATIVE_H
