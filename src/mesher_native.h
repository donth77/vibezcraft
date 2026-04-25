#ifndef MESHER_NATIVE_H
#define MESHER_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
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
	static constexpr int LEAVES = 8;
	// Glass + sapling render alpha-tested and participate in the water
	// face-emit rule — water emits its boundary face whenever the neighbor
	// isn't opaque or another fluid. Must match Blocks.is_opaque()'s
	// exclusion set so native and GDScript water meshes are byte-equal.
	static constexpr int GLASS = 21;
	static constexpr int SAPLING = 22;
	// Water ids — now meshed directly by the native path into a separate
	// water sub-mesh stream (surface-dropped top, ground-truth face culling
	// against opaque / same-fluid neighbors). Same ids as blocks.gd.
	static constexpr int WATER_FLOWING = 23;
	static constexpr int WATER_STILL = 24;
	// Lava ids — mirrored so the native mesher handles lava-cube faces
	// the same way GDScript does (non-opaque, so non-lava neighbors emit
	// toward it; adjacent lava same-id culls). Same ids as blocks.gd.
	static constexpr int LAVA_FLOWING = 25;
	static constexpr int LAVA_STILL = 26;

	MesherNative();
	~MesherNative();

	String ping() const;

	// Edge-slice arrays — 1-cell-thick planes from the 4 neighbor chunks.
	// Each `edge_blocks_*` is `SIZE_Y * (SIZE_Z or SIZE_X)` bytes; the
	// mesher reads these at chunk-boundary neighbor lookups to cull
	// shared water faces. Empty array = neighbor unloaded, OOB → AIR.
	// `edge_meta_*` mirrors for the nibble metadata (needed by the
	// variable-height water corner-height formula). Layout:
	//   edge_*_west  (x=-1): size SIZE_Y*SIZE_Z, indexed `y*SIZE_Z + z`
	//   edge_*_east  (x=SIZE_X): same
	//   edge_*_north (z=-1):    size SIZE_Y*SIZE_X, indexed `y*SIZE_X + x`
	//   edge_*_south (z=SIZE_Z): same
	Dictionary mesh_chunk_data(
			const PackedByteArray &p_blocks,
			const PackedByteArray &p_block_meta,
			int p_max_y,
			const PackedFloat32Array &p_uv_table,
			const PackedByteArray &p_edge_blocks_west,
			const PackedByteArray &p_edge_blocks_east,
			const PackedByteArray &p_edge_blocks_north,
			const PackedByteArray &p_edge_blocks_south,
			const PackedByteArray &p_edge_meta_west,
			const PackedByteArray &p_edge_meta_east,
			const PackedByteArray &p_edge_meta_north,
			const PackedByteArray &p_edge_meta_south) const;

	// Slice-5 lighting-aware variant. Same as mesh_chunk_data but also
	// emits per-vertex COLOR (rgb = sky_light/15, block_light/15, 0;
	// alpha = 1) so the chunk shader can sample lighting per face.
	// Sky/block light arrays match `Chunk.sky_light` / `Chunk.block_light`
	// (PackedByteArray of CHUNK_VOLUME, each entry 0..15). Each face's
	// vertex color samples the cell ADJACENT to the face (the cell the
	// face is "looking at" from outside) so opaque cell faces get the
	// light reaching them from the empty side — vanilla behavior.
	//
	// `block_meta` is the Chunk.block_meta nibble (0..15 per cell) —
	// needed by the variable-height water mesher (Flow #4) to derive
	// per-corner top-vertex heights from adjacent fluid levels.
	// Edge slices same pattern as mesh_chunk_data.
	Dictionary mesh_chunk_data_lit(
			const PackedByteArray &p_blocks,
			const PackedByteArray &p_block_meta,
			const PackedByteArray &p_sky_light,
			const PackedByteArray &p_block_light,
			int p_max_y,
			const PackedFloat32Array &p_uv_table,
			const PackedByteArray &p_edge_blocks_west,
			const PackedByteArray &p_edge_blocks_east,
			const PackedByteArray &p_edge_blocks_north,
			const PackedByteArray &p_edge_blocks_south,
			const PackedByteArray &p_edge_meta_west,
			const PackedByteArray &p_edge_meta_east,
			const PackedByteArray &p_edge_meta_north,
			const PackedByteArray &p_edge_meta_south) const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif
