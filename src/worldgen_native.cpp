#include "worldgen_native.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

// Must mirror Worldgen._BEDROCK_THRESHOLDS_EIGHTHS.
// Y=0 is always bedrock; [1..3] fade out; Y>=4 never bedrock.
static const int BEDROCK_THRESHOLDS_EIGHTHS[4] = { 8, 5, 3, 1 };

WorldgenNative::WorldgenNative() {}

WorldgenNative::~WorldgenNative() {}

int64_t WorldgenNative::hash3(int64_t x, int64_t y, int64_t z) {
	int64_t h = WORLD_SEED;
	h = (h * 73856093LL) ^ x;
	h = (h * 19349663LL) ^ y;
	h = (h * 83492791LL) ^ z;
	// absi: mirrors GDScript Worldgen._hash3's trailing absi(h). Using a
	// ternary rather than std::abs so we match Godot's `x < 0 ? -x : x`
	// semantics exactly on the signed-int64 edge cases.
	return h < 0 ? -h : h;
}

bool WorldgenNative::is_bedrock_at(int world_x, int y, int world_z) {
	if (y < 1 || y > 3) {
		return false;
	}
	const int threshold = BEDROCK_THRESHOLDS_EIGHTHS[y];
	return (hash3(world_x, y, world_z) & 7) < threshold;
}

int WorldgenNative::block_at(int world_x, int y, int world_z, int surface_y) {
	if (y == 0) {
		return BEDROCK;
	}
	if (y <= 3 && is_bedrock_at(world_x, y, world_z)) {
		return BEDROCK;
	}
	if (y == surface_y) {
		return GRASS;
	}
	if (y >= surface_y - 3) {
		return DIRT;
	}
	return STONE;
}

Dictionary WorldgenNative::build_base_terrain(
		int p_chunk_x,
		int p_chunk_z,
		const PackedInt32Array &p_heightmap) const {
	PackedByteArray blocks;
	const int volume = SIZE_X * SIZE_Y * SIZE_Z;
	blocks.resize(volume);
	uint8_t *blocks_ptr = blocks.ptrw();
	// PackedByteArray.resize() zero-fills, but be explicit: AIR=0 is the
	// default for untouched cells above the surface.
	for (int i = 0; i < volume; i++) {
		blocks_ptr[i] = AIR;
	}

	int max_y = 0;
	const int hm_expected = SIZE_X * SIZE_Z;
	const int hm_size = p_heightmap.size();
	const int32_t *hm_ptr = p_heightmap.ptr();

	for (int x = 0; x < SIZE_X; x++) {
		for (int z = 0; z < SIZE_Z; z++) {
			const int world_x = p_chunk_x * SIZE_X + x;
			const int world_z = p_chunk_z * SIZE_Z + z;
			// Heightmap index mirrors the GDScript caller's layout.
			const int hm_idx = z * SIZE_X + x;
			if (hm_idx >= hm_size || hm_idx >= hm_expected) {
				continue;
			}
			int h = hm_ptr[hm_idx];
			if (h < 0) {
				h = 0;
			} else if (h >= SIZE_Y) {
				h = SIZE_Y - 1;
			}
			for (int y = 0; y <= h; y++) {
				const int idx = y * SIZE_X * SIZE_Z + z * SIZE_X + x;
				const int id = block_at(world_x, y, world_z, h);
				blocks_ptr[idx] = static_cast<uint8_t>(id);
				if (id != AIR && y > max_y) {
					max_y = y;
				}
			}
		}
	}

	Dictionary result;
	result["blocks"] = blocks;
	result["max_y"] = max_y;
	return result;
}

void WorldgenNative::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("build_base_terrain", "chunk_x", "chunk_z", "heightmap"),
			&WorldgenNative::build_base_terrain);
}
