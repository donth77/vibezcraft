extends GutTest

# Parity test for VoxelColliderNative — the C++ port of voxel_collider.gd's
# move() AABB-vs-voxel collision routine. Per CLAUDE.md, native ports must
# match the GDScript reference byte-for-byte (here: result fields equal to
# within float tolerance). Tests run the same inputs through both paths and
# compare the result dicts.

const _BLOCK_AIR: int = 0
const _BLOCK_STONE: int = 1


# Build a minimal stand-in for ChunkManager that the GDScript VoxelCollider
# can call into: provides `get_world_block(Vector3i)` and
# `get_chunk_at_coord(Vector2i)` against an in-memory grid keyed by
# (cx, cz). For native, we pass the same grid as chunk_data.
class FakeChunkManager:
	extends Node
	var _chunks: Dictionary = {}  # Vector2i → FakeChunk

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


# Solid LUT mirroring Blocks.is_solid_collision: stone is solid; AIR isn't.
# We only exercise these two IDs in this test.
func _solid_lut() -> PackedByteArray:
	var lut := PackedByteArray()
	lut.resize(256)
	lut[_BLOCK_STONE] = 1
	return lut


func _make_floor_chunk() -> PackedByteArray:
	# 16×128×16 chunk; layer y=63 = stone, everything else AIR.
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


func _assert_dicts_match(a: Dictionary, b: Dictionary, label: String) -> void:
	var pa: Vector3 = a["pos"]
	var pb: Vector3 = b["pos"]
	var va: Vector3 = a["vel"]
	var vb: Vector3 = b["vel"]
	assert_almost_eq(pa.x, pb.x, 0.0001, "%s: pos.x" % label)
	assert_almost_eq(pa.y, pb.y, 0.0001, "%s: pos.y" % label)
	assert_almost_eq(pa.z, pb.z, 0.0001, "%s: pos.z" % label)
	assert_almost_eq(va.x, vb.x, 0.0001, "%s: vel.x" % label)
	assert_almost_eq(va.y, vb.y, 0.0001, "%s: vel.y" % label)
	assert_almost_eq(va.z, vb.z, 0.0001, "%s: vel.z" % label)
	assert_eq(bool(a["on_floor"]), bool(b["on_floor"]), "%s: on_floor" % label)


func _run_parity(
	cm: FakeChunkManager,
	native,
	pos: Vector3,
	half: Vector3,
	vel: Vector3,
	delta: float,
	label: String
) -> void:
	var gd_result: Dictionary = VoxelCollider.move(cm, pos, half, vel, delta)
	var chunk_data: Array = _chunk_data_for(cm, -1, 1, -1, 1)
	var native_result: Dictionary = native.move(pos, half, vel, delta, chunk_data, _solid_lut())
	_assert_dicts_match(gd_result, native_result, label)


func test_class_is_registered() -> void:
	assert_true(
		ClassDB.class_exists("VoxelColliderNative"),
		"VoxelColliderNative not registered — did the .gdextension load? Rebuild via `scons`."
	)


func test_unobstructed_falls_match() -> void:
	# Mob falling through empty space — gravity-only velocity. Both paths
	# should advance pos.y by velocity.y * delta and leave vel/on_floor alone.
	var cm := FakeChunkManager.new()
	cm.set_chunk(0, 0, _make_floor_chunk())
	var native = ClassDB.instantiate("VoxelColliderNative")
	_run_parity(
		cm,
		native,
		Vector3(2.0, 80.0, 2.0),
		Vector3(0.3, 0.95, 0.3),
		Vector3(0.0, -5.0, 0.0),
		1.0 / 60.0,
		"unobstructed fall"
	)


func test_lands_on_floor_match() -> void:
	# Mob falling onto stone floor at y=63. AABB center at y=64.5 with
	# half_y=0.95 puts feet at 63.55. One frame of -5 m/s would land at 63.47
	# which is below floor top (64) — should clip and set on_floor=true.
	var cm := FakeChunkManager.new()
	cm.set_chunk(0, 0, _make_floor_chunk())
	var native = ClassDB.instantiate("VoxelColliderNative")
	_run_parity(
		cm,
		native,
		Vector3(2.0, 64.95, 2.0),
		Vector3(0.3, 0.95, 0.3),
		Vector3(0.0, -5.0, 0.0),
		1.0 / 60.0,
		"land on floor"
	)


func test_walk_into_wall_match() -> void:
	# Build a wall at x=5, y=64..65, z=0..15 (a single column of stone).
	# Mob walking +X into it should clip horizontally and zero vel.x.
	var cm := FakeChunkManager.new()
	var blocks := _make_floor_chunk()
	for z in range(16):
		blocks[64 * 16 * 16 + z * 16 + 5] = _BLOCK_STONE
		blocks[65 * 16 * 16 + z * 16 + 5] = _BLOCK_STONE
	cm.set_chunk(0, 0, blocks)
	var native = ClassDB.instantiate("VoxelColliderNative")
	_run_parity(
		cm,
		native,
		Vector3(4.5, 64.95, 8.0),
		Vector3(0.3, 0.95, 0.3),
		Vector3(4.0, 0.0, 0.0),
		1.0 / 60.0,
		"walk into wall"
	)


func test_floor_probe_with_no_y_motion_match() -> void:
	# Mob sitting on floor with zero velocity. Y branch should run the
	# is_on_floor probe and report grounded — matches GDScript fallback.
	var cm := FakeChunkManager.new()
	cm.set_chunk(0, 0, _make_floor_chunk())
	var native = ClassDB.instantiate("VoxelColliderNative")
	_run_parity(
		cm,
		native,
		Vector3(2.0, 64.95, 2.0),
		Vector3(0.3, 0.95, 0.3),
		Vector3(0.0, 0.0, 0.0),
		1.0 / 60.0,
		"floor probe"
	)


func test_no_chunks_treated_as_air() -> void:
	# AABB sits in chunk (0,0) but no chunk data passed — all cells should
	# read as AIR (matches GDScript get_world_block fallback for unloaded
	# chunks). Mob falls freely.
	var cm := FakeChunkManager.new()
	# Don't add any chunk
	var native = ClassDB.instantiate("VoxelColliderNative")
	_run_parity(
		cm,
		native,
		Vector3(2.0, 80.0, 2.0),
		Vector3(0.3, 0.95, 0.3),
		Vector3(0.0, -5.0, 0.0),
		1.0 / 60.0,
		"no chunks loaded"
	)


func test_cross_chunk_walk_match() -> void:
	# Mob straddling the chunk boundary at x=16. Both chunks loaded; floor
	# in both. Walk +X and ensure both paths handle the cross-chunk lookup.
	var cm := FakeChunkManager.new()
	cm.set_chunk(0, 0, _make_floor_chunk())
	cm.set_chunk(1, 0, _make_floor_chunk())
	var native = ClassDB.instantiate("VoxelColliderNative")
	_run_parity(
		cm,
		native,
		Vector3(15.7, 64.95, 8.0),
		Vector3(0.3, 0.95, 0.3),
		Vector3(2.0, 0.0, 0.0),
		1.0 / 60.0,
		"cross-chunk walk"
	)
