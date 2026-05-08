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
	static constexpr int SAPLING = 22;
	static constexpr int WATER_FLOWING = 23;
	static constexpr int WATER_STILL = 24;
	static constexpr int LAVA_STILL = 26;
	static constexpr int FIRE = 27;
	static constexpr int TORCH = 28;
	static constexpr int FENCE = 30;
	static constexpr int WOOD_STAIRS = 31;
	static constexpr int COBBLESTONE_STAIRS = 32;
	static constexpr int WOODEN_DOOR = 33;
	static constexpr int IRON_DOOR = 34;
	static constexpr int LADDER = 35;
	static constexpr int FLOWER_RED = 37;
	static constexpr int FLOWER_YELLOW = 38;
	static constexpr int MUSHROOM_BROWN = 39;
	static constexpr int MUSHROOM_RED = 40;
	// Mirrors scripts/world/worldgen.gd. Alpha 1.2.6 px.java:103 (sea level).
	// world_seed is mutable so the GDScript main-menu "World seed" setting
	// can rewrite it via set_world_seed() before any chunk gen runs. The
	// 12345 default mirrors the GDScript-side default for back-compat with
	// pre-feature saves and parity tests. Static — every WorldgenNative
	// instance shares the same seed (Worldgen only constructs one).
	static int64_t world_seed;
	static constexpr int SEA_LEVEL = 64;
	// Must stay in sync with scripts/world/worldgen.gd::BEACH_DEPTH_BELOW.
	// Used by block_at() to choose DIRT (ocean floor) vs GRASS (land surface)
	// when the column's surface y is below the beach band. Mismatch → native
	// vs GDScript chunks diverge at coastline columns; test_worldgen_native
	// parity catches it.
	static constexpr int BEACH_DEPTH_BELOW = 6;

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
	//
	// Returns Dictionary { blocks: PackedByteArray, has_non_cube: bool,
	// has_water: bool }. The flag fields let GDScript update chunk-state
	// without re-scanning the chunk — the inline scan in the C++ pass is
	// ~10× faster than the equivalent GDScript loop and was the dominant
	// cost in the worker thread's cave probe.
	Dictionary scatter_caves(
			int p_chunk_x, int p_chunk_z, const PackedByteArray &p_blocks) const;

	// Slice 3-D: Native port of WorldgenDensity.build_density_terrain
	// (the trilerp + density-blend + Y-bias inner loop). The caller
	// pre-samples all 3 noise grids in GDScript (FastNoiseLite is
	// already fast in Godot's C++), then hands the raw float arrays
	// to this method which performs the per-cell blend, Y-bias
	// computation, and trilerp threshold — replacing ~32K nested-loop
	// `lerp()` calls in GDScript that were the main bottleneck of 3D
	// terrain mode.
	//
	// Grid sizes match Worldgen's GRID_X/Y/Z (5×17×5 = 425 floats);
	// per-column arrays are 5×5 = 25 floats. The mirror in GDScript
	// is `WorldgenDensity.build_density_terrain` — parity is enforced
	// by tests/test_worldgen_native.gd.
	Dictionary build_density_terrain(
			int p_chunk_x,
			int p_chunk_z,
			const PackedFloat64Array &p_density_a,
			const PackedFloat64Array &p_density_b,
			const PackedFloat64Array &p_selector,
			const PackedFloat64Array &p_col_target_y,
			const PackedFloat64Array &p_col_amplitude,
			float p_stone_bias_factor,
			float p_air_bias_factor,
			float p_noise_normalizer,
			float p_selector_normalizer,
			int p_top_taper_cells,
			float p_top_taper_force_air) const;

	// Native port of WorldgenDensity.apply_surface_layer (slice 3-D2).
	// After build_density_terrain fills the chunk with raw STONE/AIR,
	// this pass scans each column top-down, converts the topmost STONE
	// → GRASS (or DIRT below sea level — `px.java:130-148` rule), the
	// next 3 STONE cells → DIRT, then runs the deterministic bedrock
	// pass at y=0..4. Mirrors the GDScript path byte-for-byte; parity
	// guarded by tests/test_density_native_parity.gd.
	//
	// 16×16 columns × ~128-cell scan each = ~32K reads in GDScript.
	// Native pass cuts this to ~1ms.
	PackedByteArray apply_surface_layer(
			int p_chunk_x,
			int p_chunk_z,
			const PackedByteArray &p_blocks) const;

	// Slice 3-D3: native port of NoiseOctaves.sample_3d_grid (the
	// multi-octave reverse-FBM noise grid sampler). Caller passes an
	// Array of Ref<FastNoiseLite> (one per octave, pre-configured by
	// NoiseOctaves.create), C++ does the reverse-FBM accumulation +
	// per-cell get_noise_3d calls — ~10× faster than the GDScript loop
	// because the Variant-dispatch overhead per `get_noise_3d` call
	// dominates the actual noise math.
	//
	// Output array is laid out (x * size_y + y) * size_z + z (matches
	// GDScript layout). Parity with NoiseOctaves.sample_3d_grid is
	// guaranteed because the same FastNoiseLite instances are used —
	// noise output is byte-identical at the same coords.
	PackedFloat64Array sample_noise_grid_3d(
			const Array &p_octaves,
			double p_base_x,
			double p_base_y,
			double p_base_z,
			int p_size_x,
			int p_size_y,
			int p_size_z,
			double p_scale_x,
			double p_scale_y,
			double p_scale_z) const;

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
