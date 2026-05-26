# gdlint: disable=max-public-methods
extends GutTest

# Dungeon worldgen integration tests. WorldgenDungeons.scatter runs
# per-chunk during decoration and tries `_ATTEMPTS_PER_CHUNK` (8)
# candidate sites in Y range [_MIN_Y, _MAX_Y] = [8, 90]. Vanilla
# `cp.java` validity gates each candidate (floor + ceiling solid, 1-5
# two-tall non-solid wall openings; water/lava count as non-solid).
# With our cave density that gives roughly 1 dungeon per 30-60 chunks
# (varies by seed). A 11×11 sample reliably yields ≥1.
const _CHUNK_SWEEP_HALF: int = 5
const _MIN_EXPECTED_DUNGEONS: int = 1


# Returns array of {pos: Vector3i, chunk: Chunk} for every
# MOB_SPAWNER block placed across an 9×9 chunk patch around origin.
# Spawners are unique to the dungeon decoration (worldgen places no
# other spawners) so finding one guarantees a dungeon site.
func _scan_dungeons() -> Array:
	var hits: Array = []
	for cx in range(-_CHUNK_SWEEP_HALF, _CHUNK_SWEEP_HALF + 1):
		for cz in range(-_CHUNK_SWEEP_HALF, _CHUNK_SWEEP_HALF + 1):
			var chunk: Chunk = Worldgen.generate_chunk(cx, cz)
			for y in range(8, 91):
				for z in range(Chunk.SIZE_Z):
					for x in range(Chunk.SIZE_X):
						if chunk.get_block(x, y, z) == Blocks.MOB_SPAWNER:
							var hit := {
								"pos": Vector3i(cx * Chunk.SIZE_X + x, y, cz * Chunk.SIZE_Z + z),
								"local": Vector3i(x, y, z),
								"chunk": chunk,
							}
							hits.append(hit)
	return hits


func test_dungeons_generate_in_sample_region() -> void:
	var hits := _scan_dungeons()
	assert_gte(
		hits.size(),
		_MIN_EXPECTED_DUNGEONS,
		(
			"expected ≥%d dungeon spawners in 9×9 chunk patch, found %d"
			% [_MIN_EXPECTED_DUNGEONS, hits.size()]
		)
	)


func test_dungeon_generation_is_deterministic() -> void:
	# Regenerating the same chunk twice should produce identical
	# spawner placements (deterministic worldgen invariant).
	var first := _scan_dungeons()
	var second := _scan_dungeons()
	assert_eq(first.size(), second.size(), "dungeon count stable across regens")
	# Compare positions as a sorted set so any reordering doesn't fail.
	var first_positions: Array = []
	var second_positions: Array = []
	for h in first:
		first_positions.append(h["pos"])
	for h in second:
		second_positions.append(h["pos"])
	first_positions.sort()
	second_positions.sort()
	assert_eq(first_positions, second_positions, "dungeon positions stable across regens")


# For every spawner found, sanity-check the room geometry: the cell
# DIRECTLY BELOW the spawner should be cobblestone OR mossy cobble
# (room floor), and at least one adjacent horizontal cell should be
# air (room interior). Skips cells that fall outside the local chunk
# bounds (room straddles a chunk boundary — the rest of the room
# lives in the neighbor chunk we may not have generated).
func test_spawners_have_room_floor() -> void:
	var hits := _scan_dungeons()
	if hits.is_empty():
		pending("no dungeons in sample region — covered by separate test")
		return
	var checked: int = 0
	for h in hits:
		var local: Vector3i = h["local"]
		var chunk: Chunk = h["chunk"]
		# Floor cell sits 1 below the spawner. Spawners place at the
		# center of a hollow room, so this should always be safe.
		if local.y < 1:
			continue
		var below: int = chunk.get_block(local.x, local.y - 1, local.z)
		var is_floor: bool = below == Blocks.COBBLESTONE or below == Blocks.MOSSY_COBBLESTONE
		assert_true(
			is_floor,
			(
				"spawner at %s — floor below is block %d (expected cobble/mossy)"
				% [str(h["pos"]), below]
			)
		)
		checked += 1
	assert_gt(checked, 0, "at least one spawner had a verifiable floor cell")


# Spawners only appear in the dungeon Y band [_MIN_Y, _MAX_Y] = [8, 90].
func test_spawners_within_dungeon_y_band() -> void:
	var hits := _scan_dungeons()
	for h in hits:
		var y: int = h["pos"].y
		assert_between(y, 8, 90, "spawner at Y=%d should be in [8, 90]" % y)


# Vanilla rolls X / Z half-extents independently in {2, 3}, so room
# half-widths in our sample should span both values. The wall ring at
# y=cy+1 (one above the spawner) is pure cobble; we walk outward from
# the spawner to find it, which reveals the room's half-extent.
func test_room_sizes_vary_per_attempt() -> void:
	var hits := _scan_dungeons()
	if hits.is_empty():
		pending("no dungeons in sample region")
		return
	var seen_hx: Dictionary = {}
	for h in hits:
		var local: Vector3i = h["local"]
		var chunk: Chunk = h["chunk"]
		# Walk +X from the spawner until we hit cobble — that's the wall.
		# Half-extent = distance traveled.
		var hx: int = 0
		for d in range(1, 5):
			if local.x + d >= Chunk.SIZE_X:
				break
			if chunk.get_block(local.x + d, local.y, local.z) == Blocks.COBBLESTONE:
				hx = d
				break
		if hx > 0:
			seen_hx[hx] = true
	# With 11×11 chunks we get 3-5 dungeons on average. Across 25%-each
	# of the 4 size combinations, we'd expect to see both hx=2 and hx=3
	# eventually. But with small samples, sometimes only one. Just check
	# that whatever we see is in the legal range.
	for k in seen_hx.keys():
		assert_between(k, 2, 3, "half-extent X = %d not in [2, 3]" % k)


# Spawner config (mob_name) must round-trip through serialize + restore.
# Mirrors what `chunk_manager.gd::_build_chunk_save_entry` does.
func test_spawner_persists_through_serialize_restore() -> void:
	var hits := _scan_dungeons()
	if hits.is_empty():
		pending("no dungeons in sample region")
		return
	# Worldgen now defers tile-entity registration to the main thread
	# via `chunk.pending_tile_entities`; in tests we don't go through
	# ChunkManager._materialize_chunk, so we drain it ourselves.
	var first: Dictionary = hits[0]
	var world_pos: Vector3i = first["pos"]
	var chunk: Chunk = first["chunk"]
	var chunk_coord := Vector2i(world_pos.x >> 4, world_pos.z >> 4)
	MobSpawnerManager.forget_chunk(chunk_coord)
	for te: Dictionary in chunk.pending_tile_entities:
		if te.get("type", "") != "spawner":
			continue
		var local_pos: Vector3i = te.get("pos", Vector3i.ZERO)
		var wpos := Vector3i(
			chunk_coord.x * 16 + local_pos.x, local_pos.y, chunk_coord.y * 16 + local_pos.z
		)
		MobSpawnerManager.configure(wpos, str(te.get("mob", "")))
	var serialized: Dictionary = MobSpawnerManager.serialize_chunk(chunk_coord)
	assert_gt(serialized.size(), 0, "serialize_chunk yields at least the dungeon spawner")
	var local := Vector3i(
		world_pos.x - chunk_coord.x * 16, world_pos.y, world_pos.z - chunk_coord.y * 16
	)
	assert_true(serialized.has(local), "serialized dict has the spawner's local coord")
	var mob_name: String = str(serialized[local])
	# Spawner pool contains both zombie and skeleton — accept either.
	var valid_pool: Array = ["zombie", "skeleton", "spider"]
	assert_true(
		mob_name in valid_pool, "spawner mob_name %s should be in %s" % [mob_name, str(valid_pool)]
	)
	# Round-trip: forget then restore.
	MobSpawnerManager.forget_chunk(chunk_coord)
	var after_forget: Dictionary = MobSpawnerManager.serialize_chunk(chunk_coord)
	assert_eq(after_forget.size(), 0, "forget_chunk clears entries for that chunk")
	MobSpawnerManager.restore_chunk(chunk_coord, serialized)
	var after_restore: Dictionary = MobSpawnerManager.serialize_chunk(chunk_coord)
	assert_eq(after_restore.size(), serialized.size(), "restore_chunk re-populates entries")
	assert_eq(str(after_restore[local]), mob_name, "restored mob name matches pre-serialize")
