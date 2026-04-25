#ifndef LIGHTING_NATIVE_H
#define LIGHTING_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace godot {

// Native port of scripts/world/lighting.gd's `fill_sky_light`. Operates
// on raw chunk data — blocks, sky_light, height_map — passed in by the
// GDScript caller (Lighting.fill_sky_light → LightingNative.fill_sky_light).
//
// Same algorithm as the GDScript reference:
//   1. Per-column top-down pass: light = 15 above heightmap, decays
//      max(1, opacity) per cell below.
//   2. Lateral BFS within the chunk: cells at light=15 propagate
//      outward, decrementing by max(1, opacity) per step.
//
// Worker-thread safe — no Godot scene-tree access. Returns a fresh
// PackedByteArray (PackedByteArrays are COW; mutating an in-param wouldn't
// propagate back to the GDScript caller).
class LightingNative : public RefCounted {
	GDCLASS(LightingNative, RefCounted);

public:
	static constexpr int SIZE_X = 16;
	static constexpr int SIZE_Y = 128;
	static constexpr int SIZE_Z = 16;
	static constexpr int CHUNK_VOLUME = SIZE_X * SIZE_Y * SIZE_Z;
	static constexpr int MAX_LIGHT = 15;

	LightingNative();
	~LightingNative();

	// Compute and RETURN sky_light for a chunk. `blocks` is read-only
	// (CHUNK_VOLUME PackedByteArray of block ids). `opacity_lut` is a
	// 256-entry PackedByteArray indexed by block id — passed from
	// Blocks's lazy LUT so C++ doesn't need block-id knowledge. Caller
	// assigns the result back: `chunk.sky_light = native.fill_sky_light(...)`.
	PackedByteArray fill_sky_light(
			const PackedByteArray &p_blocks,
			const PackedByteArray &p_opacity_lut) const;

	// Compute and RETURN block_light for a chunk — the torch/lava/
	// glowstone channel. Seeds from every cell whose `emission_lut[id]`
	// is nonzero (lava = 15 on our 0..15 scale), then BFS-decays by
	// max(1, opacity) per step. Same BFS shape as fill_sky_light but
	// the source is per-cell emission instead of a column-preseeded
	// heightmap. Worker-thread safe.
	//
	// Same parity guard as fill_sky_light: the GDScript reference in
	// Lighting.fill_block_light must produce a byte-equal PackedByteArray
	// for any input; tests/test_lighting.gd enforces this.
	PackedByteArray fill_block_light(
			const PackedByteArray &p_blocks,
			const PackedByteArray &p_opacity_lut,
			const PackedByteArray &p_emission_lut) const;

	// Bounded BFS around a world-coord edit. Replaces
	// Lighting.update_sky_light_around_world. The caller assembles a
	// list of chunk-data tuples covering the up-to-9 chunks intersecting
	// the 31×31×31 BFS box, this routine BFSes across them, and returns
	// the modified sky_light arrays keyed by chunk coord.
	//
	// chunk_data shape: Array of Array, each inner = [
	//   chunk_x: int,
	//   chunk_z: int,
	//   blocks: PackedByteArray (CHUNK_VOLUME),
	//   sky_light: PackedByteArray (CHUNK_VOLUME),
	//   height_map: PackedByteArray (SIZE_X * SIZE_Z)
	// ]
	//
	// Return Dictionary keyed by Vector2i(chunk_x, chunk_z) →
	// modified sky_light PackedByteArray. Caller writes back + marks
	// dirty for any chunk whose array changed.
	Dictionary update_sky_light_around_world(
			int p_world_x,
			int p_world_y,
			int p_world_z,
			const Array &p_chunk_data,
			const PackedByteArray &p_opacity_lut) const;

	// Bounded BFS for the block-light channel — torches/lava/glowstone.
	// Mirrors update_sky_light_around_world's shape but uses per-cell
	// `emission_lut[id]` as the source term instead of "is sky-exposed";
	// no height_map needed.
	//
	// chunk_data shape: Array of Array, each inner = [
	//   chunk_x: int, chunk_z: int,
	//   blocks: PackedByteArray (CHUNK_VOLUME),
	//   block_light: PackedByteArray (CHUNK_VOLUME)
	// ]
	//
	// Returns Dictionary keyed by Vector2i(chunk_x, chunk_z) →
	// modified block_light PackedByteArray.
	Dictionary update_block_light_around_world(
			int p_world_x,
			int p_world_y,
			int p_world_z,
			const Array &p_chunk_data,
			const PackedByteArray &p_opacity_lut,
			const PackedByteArray &p_emission_lut) const;

	// Cross-chunk relight on chunk load. Walks the 4 cardinal seam planes
	// of `target_x, target_z` against each loaded neighbor in chunk_data;
	// for every seam cell on EITHER side, recomputes both sky_light AND
	// block_light using cross-chunk neighbor lookups; seeds two BFSes that
	// drain into the loaded chunks and converge.
	//
	// chunk_data shape: Array of Array, each inner = [
	//   chunk_x: int, chunk_z: int,
	//   blocks: PackedByteArray (CHUNK_VOLUME),
	//   sky_light: PackedByteArray (CHUNK_VOLUME),
	//   block_light: PackedByteArray (CHUNK_VOLUME),
	//   height_map: PackedByteArray (SIZE_X * SIZE_Z)
	// ]
	// The first entry must be the target chunk; remaining entries are
	// loaded cardinal neighbors (caller filters by `manager.has(coord)`).
	//
	// Returns Dictionary keyed by Vector2i(chunk_x, chunk_z) →
	// Dictionary{"sky_light": PBA, "block_light": PBA} for every chunk
	// whose either array changed. Caller writes back + marks dirty.
	Dictionary relight_chunk_borders(
			int p_target_x,
			int p_target_z,
			const Array &p_chunk_data,
			const PackedByteArray &p_opacity_lut,
			const PackedByteArray &p_emission_lut) const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif
