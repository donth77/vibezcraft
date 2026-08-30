# gdlint: disable=max-public-methods
extends GutTest

# PortalIndex — the rebuildable portal-location cache
# (docs/nether-alpha-1.2.6-implementation-plan.md §7.3, Batch 7).
#
# The plan's constraint is the interesting part: the index may narrow the
# search, but correctness must never depend on it. These tests pin both
# halves — that hints are useful, and that a wrong or missing index still
# leaves the raw search able to find the truth.

const _NETHER := -1
const _OVERWORLD := 0
const _TEST_WORLD := "PortalIndexTestWorld"


class FakeWorld:
	extends Node

	var blocks: Dictionary = {}
	var loaded: Dictionary = {}  # Vector2i → true; empty means "all resident"

	func get_world_block(pos: Vector3i) -> int:
		if not loaded.is_empty() and not has_chunk_at(pos.x, pos.z):
			return Blocks.AIR
		return int(blocks.get(pos, Blocks.AIR))

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id

	func has_chunk_at(world_x: int, world_z: int) -> bool:
		if loaded.is_empty():
			return true
		return loaded.has(_coord(world_x, world_z))

	func loaded_chunk_coords() -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		if loaded.is_empty():
			var seen: Dictionary = {}
			for key: Vector3i in blocks.keys():
				var coord: Vector2i = _coord(key.x, key.z)
				if not seen.has(coord):
					seen[coord] = true
					out.append(coord)
			return out
		for coord: Vector2i in loaded.keys():
			out.append(coord)
		return out

	func _coord(world_x: int, world_z: int) -> Vector2i:
		return Vector2i(
			int(floor(float(world_x) / float(Chunk.SIZE_X))),
			int(floor(float(world_z) / float(Chunk.SIZE_Z)))
		)


func before_each() -> void:
	PortalIndex.reset()


func after_all() -> void:
	PortalIndex.reset()
	SaveLoad.delete_world(_TEST_WORLD)


func _new_world() -> FakeWorld:
	var w := FakeWorld.new()
	autofree(w)
	return w


# --- Recording ---


func test_recording_a_sheet_stores_one_entry_per_column() -> void:
	(
		PortalIndex
		. record_sheet(
			_NETHER,
			[
				Vector3i(0, 64, 0),
				Vector3i(0, 65, 0),
				Vector3i(0, 66, 0),
				Vector3i(1, 64, 0),
				Vector3i(1, 65, 0),
				Vector3i(1, 66, 0),
			]
		)
	)
	assert_eq(PortalIndex.count(_NETHER), 2, "a 2x3 sheet is two columns")
	var stored: Array[Vector3i] = PortalIndex.entries(_NETHER)
	assert_has(stored, Vector3i(0, 64, 0), "the bottom of the first column")
	assert_has(stored, Vector3i(1, 64, 0), "the bottom of the second")


func test_recording_the_same_portal_twice_does_not_duplicate() -> void:
	PortalIndex.record(_NETHER, Vector3i(0, 64, 0))
	PortalIndex.record(_NETHER, Vector3i(0, 64, 0))
	assert_eq(PortalIndex.count(_NETHER), 1, "idempotent")


func test_dimensions_do_not_share_entries() -> void:
	PortalIndex.record(_NETHER, Vector3i(0, 64, 0))
	PortalIndex.record(_OVERWORLD, Vector3i(500, 70, 500))
	assert_eq(PortalIndex.count(_NETHER), 1, "the Nether has its own")
	assert_eq(PortalIndex.count(_OVERWORLD), 1, "and so does the Overworld")
	assert_eq(PortalIndex.entries(_NETHER)[0].x, 0, "and they are not the same entry")


func test_forgetting_removes_the_whole_column_band() -> void:
	# The entry names the bottom cell; the block that was actually broken
	# may be any cell in the column, so the removal has to cover the band.
	PortalIndex.record(_NETHER, Vector3i(4, 64, 4))
	PortalIndex.forget_at(_NETHER, Vector3i(4, 66, 4))
	assert_eq(PortalIndex.count(_NETHER), 0, "the top cell still clears the entry")


func test_forgetting_leaves_a_different_column_alone() -> void:
	PortalIndex.record(_NETHER, Vector3i(4, 64, 4))
	PortalIndex.record(_NETHER, Vector3i(5, 64, 4))
	PortalIndex.forget_at(_NETHER, Vector3i(4, 64, 4))
	assert_eq(PortalIndex.count(_NETHER), 1, "only the named column went")
	assert_eq(PortalIndex.entries(_NETHER)[0].x, 5, "the partner column survives")


func test_forgetting_leaves_a_distant_portal_in_the_same_column_alone() -> void:
	PortalIndex.record(_NETHER, Vector3i(4, 20, 4))
	PortalIndex.record(_NETHER, Vector3i(4, 90, 4))
	PortalIndex.forget_at(_NETHER, Vector3i(4, 20, 4))
	assert_eq(PortalIndex.count(_NETHER), 1, "a portal 70 blocks up is a different portal")
	assert_eq(PortalIndex.entries(_NETHER)[0].y, 90, "and it is the one left standing")


# --- Query ordering ---


func test_candidates_come_back_nearest_first() -> void:
	PortalIndex.record(_NETHER, Vector3i(50, 64, 0))
	PortalIndex.record(_NETHER, Vector3i(5, 64, 0))
	PortalIndex.record(_NETHER, Vector3i(20, 64, 0))
	var got: Array[Vector3i] = PortalIndex.candidates(_NETHER, Vector3(0.5, 64.5, 0.5), 128)
	assert_eq(got.size(), 3, "all three are in range")
	assert_eq(got[0].x, 5, "nearest first")
	assert_eq(got[1].x, 20, "then the middle one")
	assert_eq(got[2].x, 50, "then the far one")


func test_candidates_break_ties_the_way_the_raw_scan_does() -> void:
	# Same tie the teleporter test pins: from x = 0.5 the cells at -5 and
	# +5 are equidistant, and the X-ascending scan keeps the lower one.
	# The index must agree, or a hint would send the transition to load
	# chunks around a portal the scan is not going to pick.
	PortalIndex.record(_NETHER, Vector3i(-5, 64, 0))
	PortalIndex.record(_NETHER, Vector3i(5, 64, 0))
	var got: Array[Vector3i] = PortalIndex.candidates(_NETHER, Vector3(0.5, 64.5, 0.5), 128)
	assert_eq(got[0].x, -5, "the index agrees with the scan's tie-break")


func test_candidates_respect_the_radius() -> void:
	PortalIndex.record(_NETHER, Vector3i(200, 64, 0))
	assert_eq(
		PortalIndex.candidates(_NETHER, Vector3(0.5, 64.5, 0.5), 128).size(),
		0,
		"outside 128 it is not a candidate"
	)
	assert_eq(
		PortalIndex.candidates(_NETHER, Vector3(0.5, 64.5, 0.5), 256).size(),
		1,
		"a wider radius reaches it"
	)


func test_chunk_hints_are_deduplicated_chunk_coords() -> void:
	# Both columns of one portal live in the same chunk; hinting it twice
	# would make the transition load it twice.
	PortalIndex.record(_NETHER, Vector3i(4, 64, 4))
	PortalIndex.record(_NETHER, Vector3i(5, 64, 4))
	var hints: Array[Vector2i] = PortalIndex.chunk_hints(_NETHER, Vector3(0.5, 64.5, 0.5), 128)
	assert_eq(hints.size(), 1, "one chunk, one hint")
	assert_eq(hints[0], Vector2i(0, 0), "and it is the right chunk")


func test_chunk_hints_floor_negative_coordinates() -> void:
	PortalIndex.record(_NETHER, Vector3i(-1, 64, -1))
	var hints: Array[Vector2i] = PortalIndex.chunk_hints(_NETHER, Vector3(0.5, 64.5, 0.5), 128)
	assert_eq(hints[0], Vector2i(-1, -1), "block -1 belongs to chunk -1, not chunk 0")


# --- Validation ---


func test_a_live_entry_validates() -> void:
	var w: FakeWorld = _new_world()
	w.set_world_block(Vector3i(0, 64, 0), Blocks.PORTAL)
	PortalIndex.record(_NETHER, Vector3i(0, 64, 0))
	assert_true(PortalIndex.validate(_NETHER, w, Vector3i(0, 64, 0)), "the cell is really a portal")
	assert_eq(PortalIndex.count(_NETHER), 1, "and it stays indexed")


func test_a_stale_entry_is_rejected_and_dropped() -> void:
	var w: FakeWorld = _new_world()
	PortalIndex.record(_NETHER, Vector3i(0, 64, 0))
	assert_false(PortalIndex.validate(_NETHER, w, Vector3i(0, 64, 0)), "there is no portal there")
	assert_eq(PortalIndex.count(_NETHER), 0, "so the entry is removed")


func test_an_unloaded_entry_is_rejected_but_kept() -> void:
	# The distinction that matters: an unloaded chunk reads as AIR exactly
	# like a broken portal does. Forgetting on that would empty the index
	# every time the player walked away from their own portal.
	var w: FakeWorld = _new_world()
	w.loaded[Vector2i(99, 99)] = true  # anything but chunk (0,0)
	PortalIndex.record(_NETHER, Vector3i(0, 64, 0))
	assert_false(PortalIndex.validate(_NETHER, w, Vector3i(0, 64, 0)), "cannot be confirmed")
	assert_eq(PortalIndex.count(_NETHER), 1, "but the entry survives for a later attempt")


# --- Rebuild ---


func test_the_index_rebuilds_from_a_loaded_world() -> void:
	var w: FakeWorld = _new_world()
	for along: int in range(2):
		for up: int in range(3):
			w.set_world_block(Vector3i(along, 64 + up, 0), Blocks.PORTAL)
	assert_eq(PortalIndex.count(_NETHER), 0, "starts empty")
	PortalIndex.rebuild_from_loaded(w, _NETHER)
	assert_eq(PortalIndex.count(_NETHER), 2, "one entry per column, recovered from blocks alone")
	assert_has(PortalIndex.entries(_NETHER), Vector3i(0, 64, 0), "bottom cell, not the top")


func test_rebuild_records_only_column_bottoms() -> void:
	var w: FakeWorld = _new_world()
	for up: int in range(3):
		w.set_world_block(Vector3i(0, 64 + up, 0), Blocks.PORTAL)
	PortalIndex.rebuild_from_loaded(w, _NETHER)
	assert_eq(PortalIndex.count(_NETHER), 1, "three stacked cells are one entry")


func test_rebuild_finds_two_portals_stacked_in_one_column() -> void:
	var w: FakeWorld = _new_world()
	for up: int in range(3):
		w.set_world_block(Vector3i(0, 20 + up, 0), Blocks.PORTAL)
		w.set_world_block(Vector3i(0, 90 + up, 0), Blocks.PORTAL)
	PortalIndex.rebuild_from_loaded(w, _NETHER)
	assert_eq(PortalIndex.count(_NETHER), 2, "two separate portals, same X/Z")


# --- Correctness never depends on the cache ---


func test_the_raw_search_finds_a_portal_the_index_has_never_heard_of() -> void:
	var w: FakeWorld = _new_world()
	for along: int in range(2):
		for up: int in range(3):
			w.set_world_block(Vector3i(3, 64 + up, along), Blocks.PORTAL)
	assert_eq(PortalIndex.count(_NETHER), 0, "the index is empty")
	var found: Variant = NetherTeleporter.find_portal(w, Vector3(0.5, 64.5, 0.5), 16)
	assert_not_null(found, "and the raw scan finds it anyway")


func test_a_lying_index_does_not_move_the_destination() -> void:
	# The strongest statement of the plan's rule. The index points
	# somewhere with no portal; the real portal is somewhere else. The
	# answer must be the real one.
	var w: FakeWorld = _new_world()
	for along: int in range(2):
		for up: int in range(3):
			w.set_world_block(Vector3i(3 + along, 64 + up, 0), Blocks.PORTAL)
	PortalIndex.record(_NETHER, Vector3i(-40, 12, -40))
	var found: Variant = NetherTeleporter.find_portal(w, Vector3(0.5, 64.5, 0.5), 16)
	assert_not_null(found, "found the real one")
	if found != null:
		assert_eq(found as Vector3i, Vector3i(3, 64, 0), "not the one the index invented")


# --- Persistence ---


func test_the_index_round_trips_through_disk() -> void:
	PortalIndex.record(_NETHER, Vector3i(7, 64, -9))
	PortalIndex.record(_NETHER, Vector3i(8, 64, -9))
	assert_true(PortalIndex.save(_TEST_WORLD, _NETHER), "written")
	PortalIndex.reset()
	assert_eq(PortalIndex.count(_NETHER), 0, "memory cleared")
	assert_eq(PortalIndex.load_index(_TEST_WORLD, _NETHER), 2, "two entries read back")
	assert_has(PortalIndex.entries(_NETHER), Vector3i(7, 64, -9), "negative Z survived the trip")


func test_loading_a_missing_index_is_not_an_error() -> void:
	assert_eq(
		PortalIndex.load_index(_TEST_WORLD, _OVERWORLD), 0, "no file means no hints, not a failure"
	)
	assert_eq(PortalIndex.count(_OVERWORLD), 0, "and an empty index")


func test_a_corrupt_index_starts_empty_instead_of_failing() -> void:
	PortalIndex.record(_OVERWORLD, Vector3i(1, 2, 3))
	PortalIndex.save(_TEST_WORLD, _OVERWORLD)
	var f := FileAccess.open(PortalIndex.path(_TEST_WORLD, _OVERWORLD), FileAccess.WRITE)
	assert_not_null(f, "the index file exists to corrupt")
	if f != null:
		f.store_buffer(
			PackedByteArray([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0, 0, 0, 0])
		)
		f.close()
	PortalIndex.reset()
	assert_eq(PortalIndex.load_index(_TEST_WORLD, _OVERWORLD), 0, "garbage reads as no hints")


func test_loading_merges_with_memory_rather_than_replacing_it() -> void:
	# Loading is not forgetting. A dimension switch reloads the
	# destination's index; if that clobbered the bucket, a portal lit
	# since the last save — or every hint in a session whose writes were
	# skipped — would vanish on the way back. Staleness is `validate`'s
	# job, not load's.
	PortalIndex.record(_NETHER, Vector3i(1, 64, 1))
	PortalIndex.save(_TEST_WORLD, _NETHER)
	PortalIndex.record(_NETHER, Vector3i(2, 64, 2))  # learned after the save
	assert_eq(PortalIndex.load_index(_TEST_WORLD, _NETHER), 2, "both survive the load")
	assert_has(PortalIndex.entries(_NETHER), Vector3i(2, 64, 2), "the unsaved one is still there")


func test_loading_a_missing_file_does_not_erase_memory() -> void:
	PortalIndex.record(_OVERWORLD, Vector3i(9, 64, 9))
	PortalIndex.load_index(_TEST_WORLD, _OVERWORLD)
	assert_eq(PortalIndex.count(_OVERWORLD), 1, "no file on disk is not a reason to forget")


func test_saving_and_loading_keep_dimensions_separate_on_disk() -> void:
	PortalIndex.record(_NETHER, Vector3i(1, 64, 1))
	PortalIndex.record(_OVERWORLD, Vector3i(800, 70, 800))
	PortalIndex.save(_TEST_WORLD, _NETHER)
	PortalIndex.save(_TEST_WORLD, _OVERWORLD)
	assert_ne(
		PortalIndex.path(_TEST_WORLD, _NETHER),
		PortalIndex.path(_TEST_WORLD, _OVERWORLD),
		"two files, not one"
	)
	PortalIndex.reset()
	PortalIndex.load_index(_TEST_WORLD, _NETHER)
	assert_eq(PortalIndex.count(_NETHER), 1, "the Nether index came back")
	assert_eq(PortalIndex.count(_OVERWORLD), 0, "without dragging the Overworld's along")
