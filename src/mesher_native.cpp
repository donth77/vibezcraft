#include "mesher_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>

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

MesherNative::MesherNative() {}

MesherNative::~MesherNative() {}

String MesherNative::ping() const {
	return String("native mesher stub alive");
}

Dictionary MesherNative::mesh_chunk_data(
		const PackedByteArray &p_blocks,
		int p_max_y,
		const PackedFloat32Array &p_uv_table) const {
	PackedVector3Array verts;
	PackedVector3Array norms;
	PackedVector2Array uvs;
	PackedInt32Array indices;

	const int block_count = SIZE_X * SIZE_Y * SIZE_Z;
	if (p_blocks.size() < block_count) {
		// Malformed input — return empty mesh rather than crash.
		Dictionary result;
		result["vertices"] = verts;
		result["normals"] = norms;
		result["uvs"] = uvs;
		result["indices"] = indices;
		return result;
	}

	const uint8_t *blocks_ptr = p_blocks.ptr();
	const float *uv_ptr = p_uv_table.ptr();
	const int uv_size = p_uv_table.size();

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

				for (int face = 0; face < 6; face++) {
					const int nx = x + FACE_NEIGHBOR[face][0];
					const int ny = y + FACE_NEIGHBOR[face][1];
					const int nz = z + FACE_NEIGHBOR[face][2];
					int neighbor_id;
					if (nx < 0 || nx >= SIZE_X || ny < 0 || ny >= SIZE_Y || nz < 0 || nz >= SIZE_Z) {
						neighbor_id = AIR;
					} else {
						const int nidx = ny * SIZE_X * SIZE_Z + nz * SIZE_X + nx;
						neighbor_id = blocks_ptr[nidx];
					}
					// Blocks.is_opaque(id) is `id != AIR` today. Inline to
					// avoid a GDScript callback per face; if the rule ever
					// grows more complex, the parity test will catch it.
					if (neighbor_id != AIR) {
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
					for (int v = 0; v < 4; v++) {
						verts.append(Vector3(
								x + FACE_VERTS[face][v][0],
								y + FACE_VERTS[face][v][1],
								z + FACE_VERTS[face][v][2]));
						norms.append(Vector3(nxf, nyf, nzf));
					}
					// UVs: V-flipped so the top of the face samples the top
					// of the texture (matches GDScript Mesher winding).
					uvs.append(Vector2(uv_x, uv_y + uv_h));
					uvs.append(Vector2(uv_x, uv_y));
					uvs.append(Vector2(uv_x + uv_w, uv_y));
					uvs.append(Vector2(uv_x + uv_w, uv_y + uv_h));
					// Reversed winding for cull_back.
					indices.append(base);
					indices.append(base + 2);
					indices.append(base + 1);
					indices.append(base);
					indices.append(base + 3);
					indices.append(base + 2);
				}
			}
		}
	}

	Dictionary result;
	result["vertices"] = verts;
	result["normals"] = norms;
	result["uvs"] = uvs;
	result["indices"] = indices;
	return result;
}

void MesherNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("ping"), &MesherNative::ping);
	ClassDB::bind_method(
			D_METHOD("mesh_chunk_data", "blocks", "max_y", "uv_table"),
			&MesherNative::mesh_chunk_data);
}
