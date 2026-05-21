#include "mesher_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

// Face order: +Y (top), -Y (bottom), +X, -X, +Z, -Z.
// Vertex winding is CCW when viewed from outside the cube.
static const float FACE_VERTS[6][4][3] = {
	// +Y
	{ { 0, 1, 0 }, { 0, 1, 1 }, { 1, 1, 1 }, { 1, 1, 0 } },
	// -Y
	{ { 0, 0, 1 }, { 0, 0, 0 }, { 1, 0, 0 }, { 1, 0, 1 } },
	// +X
	{ { 1, 0, 0 }, { 1, 1, 0 }, { 1, 1, 1 }, { 1, 0, 1 } },
	// -X
	{ { 0, 0, 1 }, { 0, 1, 1 }, { 0, 1, 0 }, { 0, 0, 0 } },
	// +Z
	{ { 1, 0, 1 }, { 1, 1, 1 }, { 0, 1, 1 }, { 0, 0, 1 } },
	// -Z
	{ { 0, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 }, { 1, 0, 0 } },
};

static const float FACE_NORMALS[6][3] = {
	{ 0, 1, 0 },
	{ 0, -1, 0 },
	{ 1, 0, 0 },
	{ -1, 0, 0 },
	{ 0, 0, 1 },
	{ 0, 0, -1 },
};

static const int FACE_NEIGHBOR[6][3] = {
	{ 0, 1, 0 },
	{ 0, -1, 0 },
	{ 1, 0, 0 },
	{ -1, 0, 0 },
	{ 0, 0, 1 },
	{ 0, 0, -1 },
};

// face_idx → face_kind: 0=top, 1=bottom, 2=side. Must mirror Mesher._FACE_KIND.
static const int FACE_KIND[6] = { 0, 1, 2, 2, 2, 2 };

// WATER_SURFACE_DROP removed after Flow #4 — top heights are now per-
// corner and derived from water_corner_height() using the adjacent cells'
// metadata. The uniform 8/9 drop is a special case (cell surrounded by
// sources) that falls out of the general formula naturally.

// True if `id` lets a water face show through. Mirrors the water-side
// cull rule in Mesher._emit_water_faces:
//   skip if is_water(neighbor) or is_opaque(neighbor)
// Blocks.is_opaque returns false for AIR + LEAVES + GLASS + SAPLING +
// WATER_* + LAVA_*, so those are the emit-through cases. This helper
// centralizes that set so the cpp and gd paths don't drift.
static inline bool is_water_id(int id) {
	return id == MesherNative::WATER_FLOWING || id == MesherNative::WATER_STILL;
}

static inline bool is_lava_id(int id) {
	return id == MesherNative::LAVA_FLOWING || id == MesherNative::LAVA_STILL;
}

// Vanilla BlockFluids.d() cull rule: emit a fluid face if the neighbor
// isn't the same fluid family AND isn't opaque. Opaque excludes AIR,
// LEAVES, GLASS, SAPLING, and the other fluid family — those all let
// the face show through. Same-family neighbors handled at call site.
static inline bool is_fluid_face_emit_target(int neighbor_id, bool self_is_lava) {
	if (neighbor_id == MesherNative::AIR || neighbor_id == MesherNative::LEAVES
			|| neighbor_id == MesherNative::GLASS
			|| neighbor_id == MesherNative::SAPLING) {
		return true;
	}
	return self_is_lava ? is_water_id(neighbor_id) : is_lava_id(neighbor_id);
}

// Neighbor chunk edge slices — one per cardinal direction. Populated
// by the caller from Chunk.east_edge_slices() etc.; size 0 means the
// neighbor isn't loaded, in which case OOB reads return AIR / 0 (matches
// Chunk.get_block's "unloaded = no block" fallback). Mirror of
// scripts/world/chunk.gd::get_block / get_block_meta.
struct EdgeSlices {
	const uint8_t *blocks_west;
	int64_t blocks_west_size;
	const uint8_t *blocks_east;
	int64_t blocks_east_size;
	const uint8_t *blocks_north;
	int64_t blocks_north_size;
	const uint8_t *blocks_south;
	int64_t blocks_south_size;
	const uint8_t *meta_west;
	int64_t meta_west_size;
	const uint8_t *meta_east;
	int64_t meta_east_size;
	const uint8_t *meta_north;
	int64_t meta_north_size;
	const uint8_t *meta_south;
	int64_t meta_south_size;
};

// Single-cell read helpers. In-chunk fast path uses blocks_ptr directly.
// Out-of-chunk X/Z reads check the appropriate edge slice; if the slice
// is empty (unloaded neighbor), fall back to AIR / 0 per Chunk.get_block
// semantics. Y is never read from edges — world-top AIR / world-floor
// bedrock are uniform across chunks.
static inline int read_block(
		const uint8_t *blocks_ptr, const EdgeSlices &edges, int x, int y, int z) {
	if (y < 0 || y >= MesherNative::SIZE_Y) {
		return MesherNative::AIR;
	}
	if (x >= 0 && x < MesherNative::SIZE_X && z >= 0 && z < MesherNative::SIZE_Z) {
		return blocks_ptr[y * MesherNative::SIZE_X * MesherNative::SIZE_Z
				+ z * MesherNative::SIZE_X + x];
	}
	// X out-of-bounds: west / east slices. Corner reads (both X and Z
	// OOB) always return AIR since edges don't cover diagonals.
	if (x == -1 && edges.blocks_west_size > 0 && z >= 0 && z < MesherNative::SIZE_Z) {
		return edges.blocks_west[y * MesherNative::SIZE_Z + z];
	}
	if (x == MesherNative::SIZE_X && edges.blocks_east_size > 0 && z >= 0
			&& z < MesherNative::SIZE_Z) {
		return edges.blocks_east[y * MesherNative::SIZE_Z + z];
	}
	if (z == -1 && edges.blocks_north_size > 0 && x >= 0 && x < MesherNative::SIZE_X) {
		return edges.blocks_north[y * MesherNative::SIZE_X + x];
	}
	if (z == MesherNative::SIZE_Z && edges.blocks_south_size > 0 && x >= 0
			&& x < MesherNative::SIZE_X) {
		return edges.blocks_south[y * MesherNative::SIZE_X + x];
	}
	return MesherNative::AIR;
}

static inline int read_meta(
		const uint8_t *meta_ptr, const EdgeSlices &edges, int x, int y, int z) {
	if (y < 0 || y >= MesherNative::SIZE_Y) {
		return 0;
	}
	if (x >= 0 && x < MesherNative::SIZE_X && z >= 0 && z < MesherNative::SIZE_Z) {
		return meta_ptr[y * MesherNative::SIZE_X * MesherNative::SIZE_Z
				+ z * MesherNative::SIZE_X + x];
	}
	if (x == -1 && edges.meta_west_size > 0 && z >= 0 && z < MesherNative::SIZE_Z) {
		return edges.meta_west[y * MesherNative::SIZE_Z + z];
	}
	if (x == MesherNative::SIZE_X && edges.meta_east_size > 0 && z >= 0
			&& z < MesherNative::SIZE_Z) {
		return edges.meta_east[y * MesherNative::SIZE_Z + z];
	}
	if (z == -1 && edges.meta_north_size > 0 && x >= 0 && x < MesherNative::SIZE_X) {
		return edges.meta_north[y * MesherNative::SIZE_X + x];
	}
	if (z == MesherNative::SIZE_Z && edges.meta_south_size > 0 && x >= 0
			&& x < MesherNative::SIZE_X) {
		return edges.meta_south[y * MesherNative::SIZE_X + x];
	}
	return 0;
}

// Per-corner top height for variable-height fluid rendering. Mirrors
// scripts/world/mesher.gd::_fluid_corner_height line-for-line — weighted
// average over the 4 cells sharing this world corner, source/falling
// cells weighted 10× so sources pull the corner toward full height.
// `is_lava` picks which fluid family counts: water cells never raise a
// lava corner and vice versa (otherwise a water stack on top of a lava
// cell would drag the lava surface up).
static float fluid_corner_height(const uint8_t *blocks_ptr, const uint8_t *meta_ptr,
		const EdgeSlices &edges, int cx, int y, int cz, bool is_lava) {
	int total_weight = 0;
	float total_top = 0.0f;
	for (int dx = -1; dx <= 0; dx++) {
		for (int dz = -1; dz <= 0; dz++) {
			const int sx = cx + dx;
			const int sz = cz + dz;
			const int above_id = read_block(blocks_ptr, edges, sx, y + 1, sz);
			const bool above_same = is_lava ? is_lava_id(above_id) : is_water_id(above_id);
			if (above_same) {
				return 1.0f;
			}
			const int cell_id = read_block(blocks_ptr, edges, sx, y, sz);
			const bool cell_same = is_lava ? is_lava_id(cell_id) : is_water_id(cell_id);
			if (!cell_same) {
				continue;
			}
			const int level = read_meta(meta_ptr, edges, sx, y, sz);
			const int clamped = (level >= 8) ? 0 : level;
			const float depth = float(clamped + 1) / 9.0f;  // ld.b()
			const float top = 1.0f - depth;
			const int weight = (level == 0 || level >= 8) ? 10 : 1;
			total_top += top * float(weight);
			total_weight += weight;
		}
	}
	if (total_weight == 0) {
		return 0.0f;
	}
	return total_top / float(total_weight);
}

// Effective fluid level for flow math. Mirrors Mesher._fluid_effective_level
// and ld.java:c() — returns -1 if the cell isn't this fluid family, 0 for
// falling cells (meta >= 8, treated as a source for spreading purposes),
// else the raw meta (1-7).
static inline int fluid_effective_level(const uint8_t *blocks_ptr, const uint8_t *meta_ptr,
		const EdgeSlices &edges, int x, int y, int z, bool is_lava) {
	const int id = read_block(blocks_ptr, edges, x, y, z);
	const bool same = is_lava ? is_lava_id(id) : is_water_id(id);
	if (!same) {
		return -1;
	}
	const int lvl = read_meta(meta_ptr, edges, x, y, z);
	return (lvl >= 8) ? 0 : lvl;
}


// Per-cell horizontal flow vector. Ports vanilla ld.java:91-155 (BlockFluids
// .getFlowVector). Mirrors Mesher._fluid_flow_vector — keep in sync.
// Returns a unit vector (or zero) packed into the X/Z lanes of a Vector2.
// Used by water.gdshader to scroll surface UV along the spreading direction.
static Vector2 fluid_flow_vector(const uint8_t *blocks_ptr, const uint8_t *meta_ptr,
		const EdgeSlices &edges, int x, int y, int z, bool is_lava) {
	const int my_level = fluid_effective_level(blocks_ptr, meta_ptr, edges, x, y, z, is_lava);
	if (my_level < 0) {
		return Vector2(0.0f, 0.0f);
	}
	float fx = 0.0f;
	float fz = 0.0f;
	for (int dir_i = 0; dir_i < 4; dir_i++) {
		int dx = 0;
		int dz = 0;
		switch (dir_i) {
			case 0: dx = -1; break;
			case 1: dz = -1; break;
			case 2: dx = 1; break;
			case 3: dz = 1; break;
		}
		const int nx = x + dx;
		const int nz = z + dz;
		int n_level = fluid_effective_level(blocks_ptr, meta_ptr, edges, nx, y, nz, is_lava);
		if (n_level < 0) {
			// Same opacity rule used by the cube-face cull elsewhere in
			// this file — AIR/LEAVES/GLASS/SAPLING/FIRE/TORCH/water/lava
			// all let flow continue (water can pour off a ledge); only
			// hard-opaque blocks stop spreading.
			const int nid = read_block(blocks_ptr, edges, nx, y, nz);
			const bool n_is_water = (nid == MesherNative::WATER_FLOWING
					|| nid == MesherNative::WATER_STILL);
			const bool n_is_lava = (nid == MesherNative::LAVA_FLOWING
					|| nid == MesherNative::LAVA_STILL);
			const bool n_opaque = (nid != MesherNative::AIR
					&& nid != MesherNative::LEAVES
					&& nid != MesherNative::GLASS
					&& nid != MesherNative::SAPLING
					&& nid != MesherNative::FIRE
					&& nid != MesherNative::TORCH
					&& !n_is_water && !n_is_lava);
			if (n_opaque) {
				continue;
			}
			n_level = fluid_effective_level(blocks_ptr, meta_ptr, edges, nx, y - 1, nz, is_lava);
			if (n_level < 0) {
				continue;
			}
			const int diff_drop = n_level - (my_level - 8);
			fx += float(dx) * float(diff_drop);
			fz += float(dz) * float(diff_drop);
			continue;
		}
		const int diff = n_level - my_level;
		fx += float(dx) * float(diff);
		fz += float(dz) * float(diff);
	}
	if (fx == 0.0f && fz == 0.0f) {
		return Vector2(0.0f, 0.0f);
	}
	const float len = std::sqrt(fx * fx + fz * fz);
	return Vector2(fx / len, fz / len);
}


// Emit the 6 boundary faces for a fluid cell (water or lava) into the
// appropriate vertex stream. Shared by both mesh_chunk_data paths — the
// non-lit and lit variants route the same water/lava arrays since the
// fluid shaders sample TIME + VERTEX / UV, not per-vertex COLOR.
//
// Mirrors scripts/world/mesher.gd::_emit_fluid_faces line-for-line.
// Keep them in sync; parity is enforced by tests/test_mesher_native.gd.
static void emit_fluid_cell(
		int x, int y, int z, int id,
		bool is_lava,
		const uint8_t *blocks_ptr,
		const uint8_t *meta_ptr,
		const EdgeSlices &edges,
		PackedVector3Array &wverts,
		PackedVector3Array &wnorms,
		PackedVector2Array &wuvs,
		PackedInt32Array &windices,
		// Lighting-aware variant: when sky_ptr / block_light_ptr are non-null,
		// per-face sky+block light is sampled at the OPEN neighbor cell and
		// packed into wcolors as Color(sky/15, block/15, 0, 1). The non-lit
		// `mesh_chunk_data` entry-point passes nullptr and an unused colors
		// array — the result then carries an empty water_colors so the
		// consumer skips ARRAY_COLOR on the resulting ArrayMesh.
		PackedColorArray *wcolors = nullptr,
		const uint8_t *sky_ptr = nullptr,
		const uint8_t *block_light_ptr = nullptr,
		double light_scale = 0.0) {
	(void)id;  // passed for future per-level metadata routing
	const float corner_h[4] = {
		fluid_corner_height(blocks_ptr, meta_ptr, edges, x, y, z, is_lava),
		fluid_corner_height(blocks_ptr, meta_ptr, edges, x + 1, y, z, is_lava),
		fluid_corner_height(blocks_ptr, meta_ptr, edges, x, y, z + 1, is_lava),
		fluid_corner_height(blocks_ptr, meta_ptr, edges, x + 1, y, z + 1, is_lava),
	};
	// Cell-wide flow vector (X/Z), packed into Color.b/.a per-face below.
	// Computed once per cell since flow is a property of the cell, not
	// the face. Encoding: -1..1 → 0..1 via `(v * 0.5 + 0.5)` — survives
	// Color's [0,1] clamp and round-trips losslessly in float32.
	const Vector2 flow = fluid_flow_vector(blocks_ptr, meta_ptr, edges, x, y, z, is_lava);
	const float flow_b = float(flow.x) * 0.5f + 0.5f;
	const float flow_a = float(flow.y) * 0.5f + 0.5f;

	for (int face = 0; face < 6; face++) {
		const int nx = x + FACE_NEIGHBOR[face][0];
		const int ny = y + FACE_NEIGHBOR[face][1];
		const int nz = z + FACE_NEIGHBOR[face][2];
		const int neighbor_id = read_block(blocks_ptr, edges, nx, ny, nz);
		// Same-family neighbor culls (interior surface draws no internal
		// faces). is_fluid_face_emit_target() handles the non-opaque /
		// different-fluid / AIR cases.
		const bool same_family = is_lava ? is_lava_id(neighbor_id) : is_water_id(neighbor_id);
		if (same_family) {
			continue;
		}
		if (!is_fluid_face_emit_target(neighbor_id, is_lava)) {
			continue;
		}

		const int base = wverts.size();
		// Reuse the cube FACE_VERTS table. Top vertices (vy > 0.5)
		// pick their per-corner height from the precomputed table;
		// corner index = (int(vx)) + (int(vz) << 1) — matches the
		// [(0,0), (1,0), (0,1), (1,1)] ordering used in GDScript.
		for (int v = 0; v < 4; v++) {
			const float vx = FACE_VERTS[face][v][0];
			const float vy = FACE_VERTS[face][v][1];
			const float vz = FACE_VERTS[face][v][2];
			float local_y = 0.0f;
			if (vy > 0.5f) {
				const int corner_idx = int(vx) + (int(vz) << 1);
				local_y = corner_h[corner_idx];
			}
			wverts.append(Vector3(float(x) + vx, float(y) + local_y, float(z) + vz));
			const Vector3 normal(FACE_NORMALS[face][0], FACE_NORMALS[face][1],
					FACE_NORMALS[face][2]);
			wnorms.append(normal);
		}
		// UVs derived from chunk-local coords — the water shader samples
		// world-position for its ripple noise, so these are mostly
		// stylistic but must match the GDScript values for parity.
		float u0, v0, u1, v1;
		if (face == 0 || face == 1) {  // +Y / -Y
			u0 = float(x); v0 = float(z);
			u1 = float(x + 1); v1 = float(z + 1);
		} else if (face == 2 || face == 3) {  // +X / -X
			u0 = float(z); v0 = float(y);
			u1 = float(z + 1); v1 = float(y + 1);
		} else {  // +Z / -Z
			u0 = float(x); v0 = float(y);
			u1 = float(x + 1); v1 = float(y + 1);
		}
		wuvs.append(Vector2(u0, v1));
		wuvs.append(Vector2(u0, v0));
		wuvs.append(Vector2(u1, v0));
		wuvs.append(Vector2(u1, v1));
		// Per-face per-vertex light. Mirrors the cube-face rule: sample
		// the open neighbor cell so the face brightens / darkens with the
		// air it looks at. OOB neighbors fall back to (sky=15, block=0)
		// like Chunk.get_sky_light's default.
		if (wcolors != nullptr && sky_ptr != nullptr && block_light_ptr != nullptr) {
			int nsky;
			int nblk;
			if (nx < 0 || nx >= MesherNative::SIZE_X
					|| ny < 0 || ny >= MesherNative::SIZE_Y
					|| nz < 0 || nz >= MesherNative::SIZE_Z) {
				nsky = 15;
				nblk = 0;
			} else {
				const int nidx = ny * MesherNative::SIZE_X * MesherNative::SIZE_Z
						+ nz * MesherNative::SIZE_X + nx;
				nsky = sky_ptr[nidx];
				nblk = block_light_ptr[nidx];
			}
			const float sky_n = float(double(nsky) * light_scale);
			const float blk_n = float(double(nblk) * light_scale);
			// R=sky/15, G=block/15 (per-face light), B=flow.x encoded,
			// A=flow.z encoded. Same flow value across all 6 faces of
			// this cell — see Mesher._emit_fluid_faces for the shared
			// convention.
			const Color face_light(sky_n, blk_n, flow_b, flow_a);
			wcolors->append(face_light);
			wcolors->append(face_light);
			wcolors->append(face_light);
			wcolors->append(face_light);
		}
		windices.append(base);
		windices.append(base + 2);
		windices.append(base + 1);
		windices.append(base);
		windices.append(base + 3);
		windices.append(base + 2);
	}
}

MesherNative::MesherNative() {}

MesherNative::~MesherNative() {}

String MesherNative::ping() const {
	return String("native mesher stub alive");
}

Dictionary MesherNative::mesh_chunk_data(
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
		const PackedByteArray &p_edge_meta_south) const {
	PackedVector3Array verts;
	PackedVector3Array norms;
	PackedVector2Array uvs;
	PackedInt32Array indices;
	// Collision faces = triangle soup (3 verts per triangle, flat). Built
	// alongside the render mesh so ConcavePolygonShape3D can be constructed
	// on the main thread without calling ArrayMesh.create_trimesh_shape()
	// (which walked the mesh to extract this same data). Byte-equivalent
	// to the old path — enforced by test_parity_collision_faces.
	PackedVector3Array collision_faces;
	// Water sub-mesh — translucent, attaches a different ShaderMaterial on
	// the Godot side. Emitted only when the chunk contains water cells;
	// consumer (chunk_node) checks `water_vertices.is_empty()` before
	// building the second MeshInstance3D.
	PackedVector3Array water_verts;
	PackedVector3Array water_norms;
	PackedVector2Array water_uvs;
	// Non-lit path doesn't have sky/block light arrays, so water_colors
	// stays empty here. chunk_node's "if not water_colors.is_empty()"
	// guard ensures the resulting ArrayMesh has no ARRAY_COLOR attribute,
	// and the water shader's lighting term defaults to 1.0 in that case.
	PackedColorArray water_colors;
	PackedInt32Array water_indices;
	// Lava sub-mesh — opaque + emissive, separate material. Same tapered
	// geometry algorithm as water; kept in its own stream so chunk_node
	// can attach the lava shader.
	PackedVector3Array lava_verts;
	PackedVector3Array lava_norms;
	PackedVector2Array lava_uvs;
	PackedColorArray lava_colors;
	PackedInt32Array lava_indices;

	const int block_count = SIZE_X * SIZE_Y * SIZE_Z;
	if (p_blocks.size() < block_count || p_block_meta.size() < block_count) {
		// Malformed input — return empty mesh rather than crash.
		Dictionary result;
		result["vertices"] = verts;
		result["normals"] = norms;
		result["uvs"] = uvs;
		result["indices"] = indices;
		result["collision_faces"] = collision_faces;
		result["water_vertices"] = water_verts;
		result["water_normals"] = water_norms;
		result["water_uvs"] = water_uvs;
		result["water_colors"] = water_colors;
		result["water_indices"] = water_indices;
		result["lava_vertices"] = lava_verts;
		result["lava_normals"] = lava_norms;
		result["lava_uvs"] = lava_uvs;
		result["lava_colors"] = lava_colors;
		result["lava_indices"] = lava_indices;
		return result;
	}

	const uint8_t *blocks_ptr = p_blocks.ptr();
	const uint8_t *meta_ptr = p_block_meta.ptr();
	const float *uv_ptr = p_uv_table.ptr();
	const int uv_size = p_uv_table.size();

	// Pack neighbor-chunk edge slices once per mesh call. Empty arrays
	// (unloaded neighbor) stay at size 0; read_block / read_meta fall
	// through to AIR / 0. Matches Chunk.get_block semantics exactly.
	EdgeSlices edges = {
		p_edge_blocks_west.ptr(), p_edge_blocks_west.size(),
		p_edge_blocks_east.ptr(), p_edge_blocks_east.size(),
		p_edge_blocks_north.ptr(), p_edge_blocks_north.size(),
		p_edge_blocks_south.ptr(), p_edge_blocks_south.size(),
		p_edge_meta_west.ptr(), p_edge_meta_west.size(),
		p_edge_meta_east.ptr(), p_edge_meta_east.size(),
		p_edge_meta_north.ptr(), p_edge_meta_north.size(),
		p_edge_meta_south.ptr(), p_edge_meta_south.size(),
	};

	// Mirror Mesher.mesh_chunk: iterate up to max_y+1 (clamped to SIZE_Y-1).
	const int top = std::min(p_max_y + 1, SIZE_Y - 1);
	for (int y = 0; y <= top; y++) {
		for (int z = 0; z < SIZE_Z; z++) {
			for (int x = 0; x < SIZE_X; x++) {
				const int idx = y * SIZE_X * SIZE_Z + z * SIZE_X + x;
				const int id = blocks_ptr[idx];
				if (id == AIR) {
					continue;
				}
				// Water goes to the translucent sub-mesh. Separate stream so
				// the consumer can attach the water ShaderMaterial and sort
				// translucent geometry independently.
				if (id == WATER_FLOWING || id == WATER_STILL) {
					emit_fluid_cell(x, y, z, id, /*is_lava=*/false,
							blocks_ptr, meta_ptr, edges,
							water_verts, water_norms, water_uvs, water_indices);
					continue;
				}
				// Lava — same tapered algorithm, separate opaque/emissive
				// stream bound to the lava ShaderMaterial on the consumer.
				if (id == LAVA_FLOWING || id == LAVA_STILL) {
					emit_fluid_cell(x, y, z, id, /*is_lava=*/true,
							blocks_ptr, meta_ptr, edges,
							lava_verts, lava_norms, lava_uvs, lava_indices);
					continue;
				}
				// Non-cube blocks are meshed by GDScript's
				// _append_non_cube_geometry — skip cube face emission.
				if (id == SAPLING || id == FIRE || id == TORCH || id == CHEST || id == FENCE || id == WOOD_STAIRS || id == COBBLESTONE_STAIRS || id == WOODEN_DOOR || id == IRON_DOOR || id == LADDER || id == FLOWER_RED || id == FLOWER_YELLOW || id == MUSHROOM_BROWN || id == MUSHROOM_RED || id == SUGAR_CANE || id == SNOW_LAYER || id == CROPS || id == TALL_GRASS || id == HALF_SLAB || id == SIGN_STANDING || id == SIGN_WALL) {
					continue;
				}

				for (int face = 0; face < 6; face++) {
					const int nx = x + FACE_NEIGHBOR[face][0];
					const int ny = y + FACE_NEIGHBOR[face][1];
					const int nz = z + FACE_NEIGHBOR[face][2];
					// Edge-aware read: cross-chunk neighbors return the
					// actual block when the edge slice is populated, so
					// two adjacent solid chunks cull their shared face
					// properly (no more ~15-25% triangle overhead at
					// chunk borders per optimizations.md §2).
					const int neighbor_id = read_block(blocks_ptr, edges, nx, ny, nz);
					// Mirror Mesher._emit_block_faces:
					//   hide = (is_opaque(neighbor) && neighbor != LEAVES) || neighbor == id
					// LEAVES + water use alpha / translucent rendering, so the
					// faces BEHIND them must stay emitted. Same-id neighbors
					// still cull (canopy interiors stay cheap).
					const bool neighbor_is_water =
							(neighbor_id == WATER_FLOWING || neighbor_id == WATER_STILL);
					const bool neighbor_is_lava =
							(neighbor_id == LAVA_FLOWING || neighbor_id == LAVA_STILL);
					// Mirrors Blocks.is_opaque() — alpha-tested + non-cube blocks
					// (LEAVES, GLASS, SAPLING, FIRE, TORCH) all let adjacent
					// faces emit. Without the GLASS/SAPLING/FIRE/TORCH excludes,
					// e.g. placing a torch on a stone wall culls the stone face
					// it's mounted on and the sky background shows through.
					const bool neighbor_opaque =
							(neighbor_id != AIR && neighbor_id != LEAVES
									&& neighbor_id != GLASS && neighbor_id != ICE && neighbor_id != CACTUS && neighbor_id != SNOW_LAYER && neighbor_id != SAPLING
									&& neighbor_id != FIRE && neighbor_id != TORCH && neighbor_id != CHEST && neighbor_id != FENCE
									&& neighbor_id != WOOD_STAIRS && neighbor_id != COBBLESTONE_STAIRS && neighbor_id != WOODEN_DOOR && neighbor_id != IRON_DOOR && neighbor_id != LADDER && neighbor_id != FLOWER_RED && neighbor_id != FLOWER_YELLOW && neighbor_id != MUSHROOM_BROWN && neighbor_id != MUSHROOM_RED && neighbor_id != SUGAR_CANE && neighbor_id != CROPS && neighbor_id != TALL_GRASS && neighbor_id != HALF_SLAB && neighbor_id != SIGN_STANDING && neighbor_id != SIGN_WALL
									&& !neighbor_is_water && !neighbor_is_lava);
					const bool neighbor_hides_face =
							neighbor_opaque || (neighbor_id == id);
					if (neighbor_hides_face) {
						continue;
					}

					// UV lookup — mirrors BlockAtlas.uv_rect_for(id, kind).
					const int uv_idx = (id * 3 + FACE_KIND[face]) * 4;
					float uv_x = 0.0f, uv_y = 0.0f, uv_w = 0.0f, uv_h = 0.0f;
					if (uv_idx + 3 < uv_size) {
						uv_x = uv_ptr[uv_idx + 0];
						uv_y = uv_ptr[uv_idx + 1];
						uv_w = uv_ptr[uv_idx + 2];
						uv_h = uv_ptr[uv_idx + 3];
					}

					const int base = verts.size();
					const float nxf = FACE_NORMALS[face][0];
					const float nyf = FACE_NORMALS[face][1];
					const float nzf = FACE_NORMALS[face][2];
					Vector3 v0(x + FACE_VERTS[face][0][0], y + FACE_VERTS[face][0][1],
							z + FACE_VERTS[face][0][2]);
					Vector3 v1(x + FACE_VERTS[face][1][0], y + FACE_VERTS[face][1][1],
							z + FACE_VERTS[face][1][2]);
					Vector3 v2(x + FACE_VERTS[face][2][0], y + FACE_VERTS[face][2][1],
							z + FACE_VERTS[face][2][2]);
					Vector3 v3(x + FACE_VERTS[face][3][0], y + FACE_VERTS[face][3][1],
							z + FACE_VERTS[face][3][2]);
					verts.append(v0);
					verts.append(v1);
					verts.append(v2);
					verts.append(v3);
					const Vector3 normal(nxf, nyf, nzf);
					norms.append(normal);
					norms.append(normal);
					norms.append(normal);
					norms.append(normal);
					// UVs: V-flipped so the top of the face samples the top
					// of the texture (matches GDScript Mesher winding).
					// Side faces (idx 2-5) also swap U so asymmetric text
					// (e.g. TNT's "N" on the side) renders un-mirrored.
					if (face < 2) {
						uvs.append(Vector2(uv_x, uv_y + uv_h));
						uvs.append(Vector2(uv_x, uv_y));
						uvs.append(Vector2(uv_x + uv_w, uv_y));
						uvs.append(Vector2(uv_x + uv_w, uv_y + uv_h));
					} else {
						uvs.append(Vector2(uv_x + uv_w, uv_y + uv_h));
						uvs.append(Vector2(uv_x + uv_w, uv_y));
						uvs.append(Vector2(uv_x, uv_y));
						uvs.append(Vector2(uv_x, uv_y + uv_h));
					}
					// Reversed winding for cull_back: triangles are (0,2,1)
					// and (0,3,2) in vertex space → (v0,v2,v1) and (v0,v3,v2).
					indices.append(base);
					indices.append(base + 2);
					indices.append(base + 1);
					indices.append(base);
					indices.append(base + 3);
					indices.append(base + 2);
					// Same two triangles as a flat soup for trimesh collision.
					collision_faces.append(v0);
					collision_faces.append(v2);
					collision_faces.append(v1);
					collision_faces.append(v0);
					collision_faces.append(v3);
					collision_faces.append(v2);
				}
			}
		}
	}

	Dictionary result;
	result["vertices"] = verts;
	result["normals"] = norms;
	result["uvs"] = uvs;
	result["indices"] = indices;
	result["collision_faces"] = collision_faces;
	result["water_vertices"] = water_verts;
	result["water_normals"] = water_norms;
	result["water_uvs"] = water_uvs;
	result["water_colors"] = water_colors;  // empty in non-lit path
	result["water_indices"] = water_indices;
	result["lava_vertices"] = lava_verts;
	result["lava_normals"] = lava_norms;
	result["lava_uvs"] = lava_uvs;
	result["lava_colors"] = lava_colors;  // empty in non-lit path
	result["lava_indices"] = lava_indices;
	return result;
}

// Slice-5 lighting-aware mesh build. Same algorithm as mesh_chunk_data
// but also emits per-vertex COLOR with sky_light/15 in R and block_light/15
// in G, sampled from the cell adjacent to each face (the "open" side the
// face looks at). Mirrors the GDScript Mesher.mesh_chunk lighting branch
// added in slice 5 — keep them in sync. Parity test:
// tests/test_mesher_native.gd::test_parity_lit_chunk.
Dictionary MesherNative::mesh_chunk_data_lit(
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
		const PackedByteArray &p_edge_meta_south) const {
	PackedVector3Array verts;
	PackedVector3Array norms;
	PackedVector2Array uvs;
	PackedColorArray colors;
	PackedInt32Array indices;
	PackedVector3Array collision_faces;
	// Water sub-mesh — translucent material. Now carries per-vertex COLOR
	// sampled from the open neighbor cell (sky_light/15 in R, block_light/15
	// in G), so the water shader can dim it at night / in caves the same
	// way cube blocks dim. Without this, water stayed bright in dark
	// environments and read as "almost transparent at night."
	PackedVector3Array water_verts;
	PackedVector3Array water_norms;
	PackedVector2Array water_uvs;
	PackedColorArray water_colors;
	PackedInt32Array water_indices;
	// Lava sub-mesh — emissive shader self-illuminates, but mesh still
	// carries COLOR for parity with water and for the chunk_node ARRAY_COLOR
	// branch. The lava shader currently ignores it (lava is its own light
	// source, doesn't dim with the day cycle).
	PackedVector3Array lava_verts;
	PackedVector3Array lava_norms;
	PackedVector2Array lava_uvs;
	PackedColorArray lava_colors;
	PackedInt32Array lava_indices;

	const int block_count = SIZE_X * SIZE_Y * SIZE_Z;
	if (p_blocks.size() < block_count
			|| p_block_meta.size() < block_count
			|| p_sky_light.size() < block_count
			|| p_block_light.size() < block_count) {
		// Malformed input — return empty mesh rather than crash.
		Dictionary result;
		result["vertices"] = verts;
		result["normals"] = norms;
		result["uvs"] = uvs;
		result["colors"] = colors;
		result["indices"] = indices;
		result["collision_faces"] = collision_faces;
		result["water_vertices"] = water_verts;
		result["water_normals"] = water_norms;
		result["water_uvs"] = water_uvs;
		result["water_colors"] = water_colors;
		result["water_indices"] = water_indices;
		result["lava_vertices"] = lava_verts;
		result["lava_normals"] = lava_norms;
		result["lava_uvs"] = lava_uvs;
		result["lava_colors"] = lava_colors;
		result["lava_indices"] = lava_indices;
		return result;
	}

	const uint8_t *blocks_ptr = p_blocks.ptr();
	const uint8_t *meta_ptr = p_block_meta.ptr();
	const uint8_t *sky_ptr = p_sky_light.ptr();
	const uint8_t *block_light_ptr = p_block_light.ptr();
	const float *uv_ptr = p_uv_table.ptr();
	const int uv_size = p_uv_table.size();
	// Compute light_scale in DOUBLE so the multiply happens at the same
	// precision GDScript does (GDScript floats are 64-bit; Color stores
	// 32-bit). We cast to float only at the final Color() step. Without
	// this, native and GDScript paths disagree at 1 ULP and the test
	// parity check on PackedColorArray blows up.
	const double light_scale = 1.0 / 15.0;

	EdgeSlices edges = {
		p_edge_blocks_west.ptr(), p_edge_blocks_west.size(),
		p_edge_blocks_east.ptr(), p_edge_blocks_east.size(),
		p_edge_blocks_north.ptr(), p_edge_blocks_north.size(),
		p_edge_blocks_south.ptr(), p_edge_blocks_south.size(),
		p_edge_meta_west.ptr(), p_edge_meta_west.size(),
		p_edge_meta_east.ptr(), p_edge_meta_east.size(),
		p_edge_meta_north.ptr(), p_edge_meta_north.size(),
		p_edge_meta_south.ptr(), p_edge_meta_south.size(),
	};

	const int top = std::min(p_max_y + 1, SIZE_Y - 1);
	for (int y = 0; y <= top; y++) {
		for (int z = 0; z < SIZE_Z; z++) {
			for (int x = 0; x < SIZE_X; x++) {
				const int idx = y * SIZE_X * SIZE_Z + z * SIZE_X + x;
				const int id = blocks_ptr[idx];
				if (id == AIR) {
					continue;
				}
				if (id == WATER_FLOWING || id == WATER_STILL) {
					// Slice-5+water: fluids now carry per-vertex COLOR
					// sampled from the open neighbor (sky_light/15 in R,
					// block_light/15 in G), so the water shader dims at
					// night / in caves like cube blocks. Match the
					// GDScript Mesher._emit_fluid_faces lit branch.
					emit_fluid_cell(x, y, z, id, /*is_lava=*/false,
							blocks_ptr, meta_ptr, edges,
							water_verts, water_norms, water_uvs, water_indices,
							&water_colors, sky_ptr, block_light_ptr, light_scale);
					continue;
				}
				if (id == LAVA_FLOWING || id == LAVA_STILL) {
					emit_fluid_cell(x, y, z, id, /*is_lava=*/true,
							blocks_ptr, meta_ptr, edges,
							lava_verts, lava_norms, lava_uvs, lava_indices,
							&lava_colors, sky_ptr, block_light_ptr, light_scale);
					continue;
				}
				if (id == SAPLING || id == FIRE || id == TORCH || id == CHEST || id == FENCE || id == WOOD_STAIRS || id == COBBLESTONE_STAIRS || id == WOODEN_DOOR || id == IRON_DOOR || id == LADDER || id == FLOWER_RED || id == FLOWER_YELLOW || id == MUSHROOM_BROWN || id == MUSHROOM_RED || id == SUGAR_CANE || id == SNOW_LAYER || id == CROPS || id == TALL_GRASS || id == HALF_SLAB || id == SIGN_STANDING || id == SIGN_WALL) {
					continue;
				}
				for (int face = 0; face < 6; face++) {
					const int nx = x + FACE_NEIGHBOR[face][0];
					const int ny = y + FACE_NEIGHBOR[face][1];
					const int nz = z + FACE_NEIGHBOR[face][2];
					// Neighbor block — edge-aware, same semantics as
					// the non-lit path. Light samples stay at the
					// slice-1 invariant (OOB sky=15, block=0) because
					// we don't snapshot neighbor light arrays; the
					// worker always sees the target chunk's own light
					// at its borders. Mesher parity tests don't cover
					// cross-chunk light sampling yet.
					const int neighbor_id = read_block(blocks_ptr, edges, nx, ny, nz);
					int neighbor_sky;
					int neighbor_block;
					if (nx < 0 || nx >= SIZE_X || ny < 0 || ny >= SIZE_Y || nz < 0 || nz >= SIZE_Z) {
						neighbor_sky = 15;
						neighbor_block = 0;
					} else {
						const int nidx = ny * SIZE_X * SIZE_Z + nz * SIZE_X + nx;
						neighbor_sky = sky_ptr[nidx];
						neighbor_block = block_light_ptr[nidx];
					}
					const bool neighbor_is_water =
							(neighbor_id == WATER_FLOWING || neighbor_id == WATER_STILL);
					const bool neighbor_is_lava =
							(neighbor_id == LAVA_FLOWING || neighbor_id == LAVA_STILL);
					// Mirrors Blocks.is_opaque() — alpha-tested + non-cube blocks
					// (LEAVES, GLASS, SAPLING, FIRE, TORCH) all let adjacent
					// faces emit. Without the GLASS/SAPLING/FIRE/TORCH excludes,
					// e.g. placing a torch on a stone wall culls the stone face
					// it's mounted on and the sky background shows through.
					const bool neighbor_opaque =
							(neighbor_id != AIR && neighbor_id != LEAVES
									&& neighbor_id != GLASS && neighbor_id != ICE && neighbor_id != CACTUS && neighbor_id != SNOW_LAYER && neighbor_id != SAPLING
									&& neighbor_id != FIRE && neighbor_id != TORCH && neighbor_id != CHEST && neighbor_id != FENCE
									&& neighbor_id != WOOD_STAIRS && neighbor_id != COBBLESTONE_STAIRS && neighbor_id != WOODEN_DOOR && neighbor_id != IRON_DOOR && neighbor_id != LADDER && neighbor_id != FLOWER_RED && neighbor_id != FLOWER_YELLOW && neighbor_id != MUSHROOM_BROWN && neighbor_id != MUSHROOM_RED && neighbor_id != SUGAR_CANE && neighbor_id != CROPS && neighbor_id != TALL_GRASS && neighbor_id != HALF_SLAB && neighbor_id != SIGN_STANDING && neighbor_id != SIGN_WALL
									&& !neighbor_is_water && !neighbor_is_lava);
					const bool neighbor_hides_face =
							neighbor_opaque || (neighbor_id == id);
					if (neighbor_hides_face) {
						continue;
					}

					const int uv_idx = (id * 3 + FACE_KIND[face]) * 4;
					float uv_x = 0.0f, uv_y = 0.0f, uv_w = 0.0f, uv_h = 0.0f;
					if (uv_idx + 3 < uv_size) {
						uv_x = uv_ptr[uv_idx + 0];
						uv_y = uv_ptr[uv_idx + 1];
						uv_w = uv_ptr[uv_idx + 2];
						uv_h = uv_ptr[uv_idx + 3];
					}

					const int base = verts.size();
					const float nxf = FACE_NORMALS[face][0];
					const float nyf = FACE_NORMALS[face][1];
					const float nzf = FACE_NORMALS[face][2];
					Vector3 v0(x + FACE_VERTS[face][0][0], y + FACE_VERTS[face][0][1],
							z + FACE_VERTS[face][0][2]);
					Vector3 v1(x + FACE_VERTS[face][1][0], y + FACE_VERTS[face][1][1],
							z + FACE_VERTS[face][1][2]);
					Vector3 v2(x + FACE_VERTS[face][2][0], y + FACE_VERTS[face][2][1],
							z + FACE_VERTS[face][2][2]);
					Vector3 v3(x + FACE_VERTS[face][3][0], y + FACE_VERTS[face][3][1],
							z + FACE_VERTS[face][3][2]);
					verts.append(v0);
					verts.append(v1);
					verts.append(v2);
					verts.append(v3);
					const Vector3 normal(nxf, nyf, nzf);
					norms.append(normal);
					norms.append(normal);
					norms.append(normal);
					norms.append(normal);
					// Side faces (idx 2-5) swap U so asymmetric horizontal
					// detail (TNT's "N") renders un-mirrored. Top/bottom keep
					// the original order.
					if (face < 2) {
						uvs.append(Vector2(uv_x, uv_y + uv_h));
						uvs.append(Vector2(uv_x, uv_y));
						uvs.append(Vector2(uv_x + uv_w, uv_y));
						uvs.append(Vector2(uv_x + uv_w, uv_y + uv_h));
					} else {
						uvs.append(Vector2(uv_x + uv_w, uv_y + uv_h));
						uvs.append(Vector2(uv_x + uv_w, uv_y));
						uvs.append(Vector2(uv_x, uv_y));
						uvs.append(Vector2(uv_x, uv_y + uv_h));
					}
					// Per-vertex face light = neighbor cell's sky/block. Flat
					// per-face — Alpha 1.2.6 had no smooth lighting (added
					// Beta 1.6); all 4 verts get the same value.
					const float sky_n = float(double(neighbor_sky) * light_scale);
					const float blk_n = float(double(neighbor_block) * light_scale);
					const Color face_light(sky_n, blk_n, 0.0f, 1.0f);
					colors.append(face_light);
					colors.append(face_light);
					colors.append(face_light);
					colors.append(face_light);
					indices.append(base);
					indices.append(base + 2);
					indices.append(base + 1);
					indices.append(base);
					indices.append(base + 3);
					indices.append(base + 2);
					collision_faces.append(v0);
					collision_faces.append(v2);
					collision_faces.append(v1);
					collision_faces.append(v0);
					collision_faces.append(v3);
					collision_faces.append(v2);
				}
			}
		}
	}

	Dictionary result;
	result["vertices"] = verts;
	result["normals"] = norms;
	result["uvs"] = uvs;
	result["colors"] = colors;
	result["indices"] = indices;
	result["collision_faces"] = collision_faces;
	result["water_vertices"] = water_verts;
	result["water_normals"] = water_norms;
	result["water_uvs"] = water_uvs;
	result["water_colors"] = water_colors;
	result["water_indices"] = water_indices;
	result["lava_vertices"] = lava_verts;
	result["lava_normals"] = lava_norms;
	result["lava_uvs"] = lava_uvs;
	result["lava_colors"] = lava_colors;
	result["lava_indices"] = lava_indices;
	return result;
}

void MesherNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("ping"), &MesherNative::ping);
	ClassDB::bind_method(
			D_METHOD("mesh_chunk_data",
					"blocks",
					"block_meta",
					"max_y",
					"uv_table",
					"edge_blocks_west",
					"edge_blocks_east",
					"edge_blocks_north",
					"edge_blocks_south",
					"edge_meta_west",
					"edge_meta_east",
					"edge_meta_north",
					"edge_meta_south"),
			&MesherNative::mesh_chunk_data);
	ClassDB::bind_method(
			D_METHOD("mesh_chunk_data_lit",
					"blocks",
					"block_meta",
					"sky_light",
					"block_light",
					"max_y",
					"uv_table",
					"edge_blocks_west",
					"edge_blocks_east",
					"edge_blocks_north",
					"edge_blocks_south",
					"edge_meta_west",
					"edge_meta_east",
					"edge_meta_north",
					"edge_meta_south"),
			&MesherNative::mesh_chunk_data_lit);
}
