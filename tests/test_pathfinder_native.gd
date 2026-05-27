extends GutTest

# Parity test for PathfinderNative — the C++ port of pathfinder.gd's A*.
# Native ports must produce the same path as the GDScript reference for
# any reachable goal. We compare the two return values for several
# canonical scenarios.

const _BLOCK_AIR: int = 0
const _BLOCK_STONE: int = 1


class FakeChunkManager:
	extends Node
	var _chunks: Dictionary = {}

	func set_chunk(cx: int, cz: int, blocks: PackedByteArray) -> void:
		var fc := FakeChunk.new()
		fc.blocks = blocks
		_chunks[Vector2i(cx, cz)] = fc

	func get_world_block(world_pos: Vector3i) -> int:
		var cx: int = int(floor(float(world_pos.x) / 16.0))
		var cz: int = int(floor(float(world_pos.z) / 16.0))
		var key := Vector2i(cx, cz)
		if not _chunks.has(key):
			return _BLOCK_AIR
		var lx: int = world_pos.x - cx * 16
		var lz: int = world_pos.z - cz * 16
		var fc: FakeChunk = _chunks[key]
		var idx: int = world_pos.y * 16 * 16 + lz * 16 + lx
		if idx < 0 or idx >= fc.blocks.size():
			return _BLOCK_AIR
		return fc.blocks[idx]

	func get_chunk_at_coord(coord: Vector2i):
		return _chunks.get(coord, null)


class FakeChunk:
	var blocks: PackedByteArray


func _solid_lut() -> PackedByteArray:
	var lut := PackedByteArray()
	lut.resize(256)
	lut[_BLOCK_STONE] = 1
	return lut


func _make_floor_chunk() -> PackedByteArray:
	# 16×128×16 chunk; y=63 stone, everything else AIR.
	var blocks := PackedByteArray()
	blocks.resize(16 * 128 * 16)
	for x in range(16):
		for z in range(16):
			blocks[63 * 16 * 16 + z * 16 + x] = _BLOCK_STONE
	return blocks


func _chunk_data_for(cm: FakeChunkManager, cx_lo: int, cx_hi: int, cz_lo: int, cz_hi: int) -> Array:
	var out: Array = []
	for cx in range(cx_lo, cx_hi + 1):
		for cz in range(cz_lo, cz_hi + 1):
			var fc: FakeChunk = cm.get_chunk_at_coord(Vector2i(cx, cz))
			if fc != null:
				out.append([cx, cz, fc.blocks])
	return out


func _assert_paths_equal(a: Array, b: Array, label: String) -> void:
	assert_eq(a.size(), b.size(), "%s: path length" % label)
	if a.size() != b.size():
		return
	for i in range(a.size()):
		var pa: Vector3i = a[i]
		var pb: Vector3i = b[i]
		assert_eq(pa, pb, "%s: cell %d" % [label, i])


func test_class_is_registered() -> void:
	assert_true(
		ClassDB.class_exists("PathfinderNative"),
		"PathfinderNative not registered — did the .gdextension load? Rebuild via `scons`."
	)


func test_walkable_probe_matches() -> void:
	# Walkable cell — AIR with stone floor below.
	var cm := FakeChunkManager.new()
	cm.set_chunk(0, 0, _make_floor_chunk())
	var native = ClassDB.instantiate("PathfinderNative")
	var chunk_data: Array = _chunk_data_for(cm, 0, 0, 0, 0)
	# Walkable: at y=64 (AIR above stone at y=63)
	var gd_walkable: bool = Pathfinder.is_walkable(cm, Vector3i(5, 64, 5))
	var native_walkable: bool = native.is_walkable(Vector3i(5, 64, 5), chunk_data, _solid_lut())
	assert_eq(gd_walkable, native_walkable, "y=64 walkable parity")
	# Not walkable: at y=63 (stone here)
	gd_walkable = Pathfinder.is_walkable(cm, Vector3i(5, 63, 5))
	native_walkable = native.is_walkable(Vector3i(5, 63, 5), chunk_data, _solid_lut())
	assert_eq(gd_walkable, native_walkable, "y=63 not walkable parity")


func test_straight_path_match() -> void:
	# Walk from (5, 64, 5) to (10, 64, 5) on flat stone floor.
	var cm := FakeChunkManager.new()
	cm.set_chunk(0, 0, _make_floor_chunk())
	var native = ClassDB.instantiate("PathfinderNative")
	var gd_path: Array = Pathfinder.find_path(cm, Vector3i(5, 64, 5), Vector3i(10, 64, 5))
	var chunk_data: Array = _chunk_data_for(cm, 0, 0, 0, 0)
	var native_path: Array = native.find_path(
		Vector3i(5, 64, 5), Vector3i(10, 64, 5), 16.0, 200, chunk_data, _solid_lut()
	)
	_assert_paths_equal(gd_path, native_path, "straight path")


func test_start_equals_goal_match() -> void:
	var cm := FakeChunkManager.new()
	cm.set_chunk(0, 0, _make_floor_chunk())
	var native = ClassDB.instantiate("PathfinderNative")
	var gd_path: Array = Pathfinder.find_path(cm, Vector3i(5, 64, 5), Vector3i(5, 64, 5))
	var chunk_data: Array = _chunk_data_for(cm, 0, 0, 0, 0)
	var native_path: Array = native.find_path(
		Vector3i(5, 64, 5), Vector3i(5, 64, 5), 16.0, 200, chunk_data, _solid_lut()
	)
	assert_eq(gd_path.size(), 0, "start==goal returns empty (gd)")
	assert_eq(native_path.size(), 0, "start==goal returns empty (native)")


func test_unreachable_match() -> void:
	# Wall the goal off — no walkable floor beneath it. Both paths empty.
	var cm := FakeChunkManager.new()
	cm.set_chunk(0, 0, _make_floor_chunk())
	# Goal at y=100 has AIR below, no floor → unreachable.
	var native = ClassDB.instantiate("PathfinderNative")
	var gd_path: Array = Pathfinder.find_path(cm, Vector3i(5, 64, 5), Vector3i(8, 100, 5))
	var chunk_data: Array = _chunk_data_for(cm, 0, 0, 0, 0)
	var native_path: Array = native.find_path(
		Vector3i(5, 64, 5), Vector3i(8, 100, 5), 16.0, 200, chunk_data, _solid_lut()
	)
	assert_eq(gd_path.size(), 0, "unreachable goal returns empty (gd)")
	assert_eq(native_path.size(), 0, "unreachable goal returns empty (native)")


func test_cross_chunk_path_match() -> void:
	# Path that crosses chunk boundary at x=16.
	var cm := FakeChunkManager.new()
	cm.set_chunk(0, 0, _make_floor_chunk())
	cm.set_chunk(1, 0, _make_floor_chunk())
	var native = ClassDB.instantiate("PathfinderNative")
	var gd_path: Array = Pathfinder.find_path(cm, Vector3i(14, 64, 5), Vector3i(20, 64, 5))
	# (cx_lo, cx_hi, cz_lo, cz_hi) — covers chunks (0,0) and (1,0).
	var chunk_data: Array = _chunk_data_for(cm, 0, 1, 0, 0)
	var native_path: Array = native.find_path(
		Vector3i(14, 64, 5), Vector3i(20, 64, 5), 16.0, 200, chunk_data, _solid_lut()
	)
	_assert_paths_equal(gd_path, native_path, "cross-chunk path")
