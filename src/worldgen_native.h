#ifndef WORLDGEN_NATIVE_H
#define WORLDGEN_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

// Native port of the heightmap + stratified-layer pass in
// scripts/world/worldgen.gd. The caller (GDScript Worldgen) samples the
// noise into a 16×16 heightmap (one surface-Y per column, row-major
// `z * 16 + x`) and hands it in; C++ fills the 16×128×16 PackedByteArray
// with the bedrock / stone / dirt / grass layers. Ore veins and tree
// placement stay in GDScript for now — they write on top of the result
// returned here.
//
// Parity with the GDScript fill pass is enforced by
// tests/test_worldgen_native.gd: chunk.blocks from the native path must
// be byte-equal to the chunk.blocks from the GDScript path.
class WorldgenNative : public RefCounted {
	GDCLASS(WorldgenNative, RefCounted);

public:
	// Must mirror scripts/world/chunk.gd.
	static constexpr int SIZE_X = 16;
	static constexpr int SIZE_Y = 128;
	static constexpr int SIZE_Z = 16;
	// Mirrors scripts/world/blocks.gd.
	static constexpr int AIR = 0;
	static constexpr int BEDROCK = 1;
	static constexpr int STONE = 2;
	static constexpr int DIRT = 3;
	static constexpr int GRASS = 4;
	// Mirrors scripts/world/worldgen.gd.
	static constexpr int64_t WORLD_SEED = 12345;

	WorldgenNative();
	~WorldgenNative();

	// Returns { blocks: PackedByteArray (size 16*128*16), max_y: int }.
	// heightmap has exactly SIZE_X * SIZE_Z entries; out-of-range values
	// are clamped to [0, SIZE_Y-1].
	Dictionary build_base_terrain(
			int p_chunk_x,
			int p_chunk_z,
			const PackedInt32Array &p_heightmap) const;

protected:
	static void _bind_methods();

private:
	// Deterministic per-(x, y, z, seed) hash. Must match Worldgen._hash3
	// bit-for-bit so bedrock-band placement is identical.
	static int64_t hash3(int64_t x, int64_t y, int64_t z);

	// Per-layer bedrock placement in the y=1..3 band. Must match
	// Worldgen._is_bedrock_at.
	static bool is_bedrock_at(int world_x, int y, int world_z);

	// Column-fill layer resolver. Must match Worldgen._block_at.
	static int block_at(int world_x, int y, int world_z, int surface_y);
};

} // namespace godot

#endif
