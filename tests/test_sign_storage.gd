extends GutTest

# SignStorage tile-entity registry tests. Locks in:
#   - 4 lines × 15 chars contract (vanilla qc.java)
#   - per-chunk snapshot / restore round-trip (used by chunk save path)
#   - clipping at MAX_CHARS_PER_LINE
#   - forget() clears entries


func before_each() -> void:
	# Start each test with a clean global registry — SignStorage is an
	# autoload so state leaks across tests otherwise.
	for pos in SignStorage._signs.keys():
		SignStorage._signs.erase(pos)


func test_get_or_create_returns_four_empty_lines() -> void:
	var pos := Vector3i(5, 64, -3)
	var lines: Array = SignStorage.get_or_create(pos)
	assert_eq(lines.size(), SignStorage.LINES_PER_SIGN)
	for i in range(SignStorage.LINES_PER_SIGN):
		assert_eq(lines[i], "", "line %d should default to empty" % i)
	assert_true(SignStorage.has_sign(pos))


func test_set_text_writes_per_line() -> void:
	var pos := Vector3i(0, 70, 0)
	SignStorage.set_text(pos, 0, "Hello")
	SignStorage.set_text(pos, 2, "World")
	var lines: Array = SignStorage.get_lines(pos)
	assert_eq(lines[0], "Hello")
	assert_eq(lines[1], "")
	assert_eq(lines[2], "World")
	assert_eq(lines[3], "")


# Vanilla qc.java doesn't strictly clip but the edit GUI limits input
# to 15 chars per line. We enforce on set_text so any caller (GUI or
# debug script) gets the same hard cap.
func test_set_text_clips_at_max_chars_per_line() -> void:
	var pos := Vector3i(1, 1, 1)
	var long_text: String = "abcdefghijklmnopqrstuvwxyz"  # 26 chars
	SignStorage.set_text(pos, 0, long_text)
	var lines: Array = SignStorage.get_lines(pos)
	assert_eq(lines[0].length(), SignStorage.MAX_CHARS_PER_LINE)
	assert_eq(lines[0], long_text.substr(0, SignStorage.MAX_CHARS_PER_LINE))


func test_get_lines_returns_empty_array_for_unknown_pos() -> void:
	var lines: Array = SignStorage.get_lines(Vector3i(999, 99, 999))
	assert_eq(lines.size(), SignStorage.LINES_PER_SIGN)
	for i in range(SignStorage.LINES_PER_SIGN):
		assert_eq(lines[i], "")
	# No side effect — calling get_lines on a missing pos shouldn't
	# auto-create the entry.
	assert_false(SignStorage.has_sign(Vector3i(999, 99, 999)))


func test_forget_removes_entry() -> void:
	var pos := Vector3i(2, 65, 2)
	SignStorage.set_text(pos, 0, "to be deleted")
	assert_true(SignStorage.has_sign(pos))
	SignStorage.forget(pos)
	assert_false(SignStorage.has_sign(pos))


# Chunk serialize / restore — used by the save-load pipeline so sign
# text survives chunk unload + world reload. Mirrors the Chest/Furnace
# serializer contract: local-pos keyed dict round-trips through the
# tile_entities blob bundled into the saved chunk entry.
func test_serialize_and_restore_round_trip() -> void:
	# Two signs in chunk (0, 0), one in chunk (1, 0). serialize_chunk
	# of (0, 0) should only include the first two.
	var p1 := Vector3i(3, 64, 3)
	var p2 := Vector3i(8, 64, 9)
	var p3 := Vector3i(20, 64, 5)  # chunk (1, 0)
	SignStorage.set_text(p1, 0, "first")
	SignStorage.set_text(p2, 1, "second")
	SignStorage.set_text(p3, 2, "other chunk")
	var snap: Dictionary = SignStorage.serialize_chunk(Vector2i(0, 0))
	assert_eq(snap.size(), 2)
	# Local pos keys (world - chunk_origin) — verifies the chunk-relative
	# encoding so cross-chunk relocations don't double-map.
	assert_true(snap.has(Vector3i(3, 64, 3)))
	assert_true(snap.has(Vector3i(8, 64, 9)))
	# Drop the chunk we just serialized, then restore.
	SignStorage.forget_chunk(Vector2i(0, 0))
	assert_false(SignStorage.has_sign(p1))
	assert_false(SignStorage.has_sign(p2))
	assert_true(SignStorage.has_sign(p3))  # chunk (1, 0) untouched
	SignStorage.restore_chunk(Vector2i(0, 0), snap)
	assert_true(SignStorage.has_sign(p1))
	assert_eq(SignStorage.get_lines(p1)[0], "first")
	assert_true(SignStorage.has_sign(p2))
	assert_eq(SignStorage.get_lines(p2)[1], "second")


func test_get_active_chunks_returns_one_coord_per_chunk() -> void:
	SignStorage.set_text(Vector3i(1, 64, 1), 0, "a")
	SignStorage.set_text(Vector3i(2, 64, 2), 0, "b")  # same chunk
	SignStorage.set_text(Vector3i(20, 64, 5), 0, "c")  # chunk (1, 0)
	var active: Array[Vector2i] = SignStorage.get_active_chunks()
	assert_eq(active.size(), 2)
	assert_has(active, Vector2i(0, 0))
	assert_has(active, Vector2i(1, 0))


# Negative-coord chunks: arithmetic right-shift maps world (-1, _, -1)
# into chunk (-1, -1), not (0, 0). Regression for the chest-pattern
# shift convention.
func test_get_active_chunks_negative_coords() -> void:
	SignStorage.set_text(Vector3i(-1, 64, -1), 0, "neg")
	var active: Array[Vector2i] = SignStorage.get_active_chunks()
	assert_eq(active.size(), 1)
	assert_eq(active[0], Vector2i(-1, -1))
