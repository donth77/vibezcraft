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


# Chunk snapshot / restore — used by the save-load pipeline so sign
# text survives chunk unload + world reload.
func test_snapshot_and_restore_round_trip() -> void:
	# Two signs in chunk (0, 0), one in chunk (1, 0). Snapshot of
	# (0, 0) should only include the first two.
	var p1 := Vector3i(3, 64, 3)
	var p2 := Vector3i(8, 64, 9)
	var p3 := Vector3i(20, 64, 5)  # chunk (1, 0)
	SignStorage.set_text(p1, 0, "first")
	SignStorage.set_text(p2, 1, "second")
	SignStorage.set_text(p3, 2, "other chunk")
	var snap: Array = SignStorage.snapshot_for_chunk(0, 0)
	assert_eq(snap.size(), 2)
	# Drop the chunk we just snapshotted, then restore.
	SignStorage.forget_chunk(0, 0)
	assert_false(SignStorage.has_sign(p1))
	assert_false(SignStorage.has_sign(p2))
	assert_true(SignStorage.has_sign(p3))  # chunk (1, 0) untouched
	SignStorage.restore_from_snapshot(0, 0, snap)
	assert_true(SignStorage.has_sign(p1))
	assert_eq(SignStorage.get_lines(p1)[0], "first")
	assert_true(SignStorage.has_sign(p2))
	assert_eq(SignStorage.get_lines(p2)[1], "second")
