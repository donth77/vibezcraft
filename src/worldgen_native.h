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
	static constexpr int WATER_FLOWING = 23;
	static constexpr int WATER_STILL = 24;
	static constexpr int LAVA_STILL = 26;
	// Mirrors scripts/world/worldgen.gd. Alpha 1.2.6 px.java:103 (sea level).
	// world_seed is mutable so the GDScript main-menu "World seed" setting
	// can rewrite it via set_world_seed() before any chunk gen runs. The
	// 12345 default mirrors the GDScript-side default for back-compat with
	// pre-feature saves and parity tests. Static — every WorldgenNative
	// instance shares the same seed (Worldgen only constructs one).
	static int64_t world_seed;
	static constexpr int SEA_LEVEL = 64;
	static constexpr int BEACH_DEPTH_BELOW = 4;

	WorldgenNative();
	~WorldgenNative();

	// Setter exposed to GDScript via _bind_methods. Worldgen.apply_world_seed
	// calls this AND rewrites its own static var so both paths stay locked.
	static void set_world_seed(int64_t p_seed);

	// Returns { blocks: PackedByteArray (size 16*128*16), max_y: int }.
	// heightmap has exactly SIZE_X * SIZE_Z entries; out-of-range values
	// are clamped to [0, SIZE_Y-1].
	Dictionary build_base_terrain(
			int p_chunk_x,
			int p_chunk_z,
			const PackedInt32Array &p_heightmap) const;

	// Native port of Worldgen._scatter_ores. Takes the post-base-terrain
	// blocks array and a flattened ore-configs array (5 ints per entry:
	// block_id, attempts_per_chunk, vein_size_max, y_min, y_max) so the
	// caller still owns the knobs. Runs the 4-decoration-pass overlap
	// trick in C++ — each pass walks every ore config × every attempt
	// and scatters an ellipsoid-along-line vein via place_vein_ellipsoid.
	// Returns the mutated blocks array; caller assigns back to chunk.blocks.
	//
	// Parity with Worldgen._scatter_ores_gdscript is enforced by
	// tests/test_worldgen_native.gd — chunk.blocks must be byte-equal
	// after generate_chunk with either path.
	PackedByteArray scatter_ores(
			int p_chunk_x,
			int p_chunk_z,
			const PackedByteArray &p_blocks,
			const PackedInt32Array &p_ore_configs) const;

	// Native port of worldgen_caves.gd — the Alpha 1.2.6 cave generator.
	// Takes the post-ore-scatter blocks array, runs the 17×17 neighbor-
	// chunk loop with JavaRandom re-seeding, carves worm ellipsoids, and
	// returns the mutated blocks. Bit-exact with the GDScript version
	// (same JavaRandom stream consumption order) — enforced by
	// test_caves_deterministic + seed-stability tests.
	//
	// The port uses C++ int64_t's native signed-wrap semantics for the
	// Java Random LCG, which matches Java's long arithmetic directly —
	// no need for GDScript's 24-bit-split workaround.
	PackedByteArray scatter_caves(
			int p_chunk_x, int p_chunk_z, const PackedByteArray &p_blocks) const;

	// Native port of Worldgen3D.fill_chunk + density_grid + climate noise
	// for the 3D density terrain pipeline. Replaces the dominant ~74 ms/chunk
	// GDScript hot path. Output: 16x128x16 PackedByteArray with STONE / WATER /
	// AIR cells (per the px.java density crossing). The GDScript caller still
	// runs the surface_layer pass (vanilla port + bedrock RNG) on top.
	PackedByteArray fill_chunk_3d(int p_chunk_x, int p_chunk_z) const;

protected:
	static void _bind_methods();

private:
	// Deterministic per-(x, y, z, seed) hash. Must match Worldgen._hash3
	// bit-for-bit so bedrock-band placement is identical.
	static int64_t hash3(int64_t x, int64_t y, int64_t z);

	// 4-arg variant — matches Worldgen._hash4. Ore scatter varies only
	// the `d` argument (attempt index), which is why the Knuth mix is
	// critical: without it, the high bits of the hash never change and
	// every attempt lands at the same (y, z).
	static int64_t hash4(int64_t a, int64_t b, int64_t c, int64_t d);

	// Deterministic pseudo-random float in [0, 1) — mirrors
	// Worldgen._float01. Used by place_vein_ellipsoid for per-sample
	// angle + radius jitter.
	static double float01(int64_t seed_hash, int64_t salt);

	// Per-layer bedrock placement in the y=1..3 band. Must match
	// Worldgen._is_bedrock_at.
	static bool is_bedrock_at(int world_x, int y, int world_z);

	// Column-fill layer resolver. Must match Worldgen._block_at.
	static int block_at(int world_x, int y, int world_z, int surface_y);

	// Deterministic port of vanilla WorldGenMinable.generate — ellipsoid-
	// along-line fill. Writes ore only where the existing cell is STONE,
	// so chunk.blocks below-surface pattern is preserved exactly. Pointer
	// arg so scatter_ores can hand us the backing buffer directly and
	// avoid a per-write CoW hit on PackedByteArray.
	static void place_vein_ellipsoid(
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
			int y_hi);
};

} // namespace godot

#endif
