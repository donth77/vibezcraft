extends Node

# Tile-entity store for signs. Vanilla qc.java (TileEntitySign) holds a
# String[4] for the 4 lines of text (15 chars each in vanilla, but the
# string length isn't hard-enforced in source — clients clip via the
# edit GUI). We keep one Dictionary global keyed by world position,
# same pattern as ChestStorage / FurnaceManager.
#
# Stage 1: text is empty by default on every sign. Stage 2 wires the
# edit GUI which mutates `set_text(pos, line, text)`. The persistence
# hooks at the bottom serialize/restore via the chunk save path so
# inscribed text survives chunk unload + world reload.

# Emitted whenever a sign's text changes via set_text. SignNode (the
# in-world Label3D wrapper) listens to refresh its rendered text; the
# emit fires synchronously so the visible text updates the same frame
# the GUI's Done button is pressed.
signal text_changed(pos: Vector3i)

const LINES_PER_SIGN: int = 4
const MAX_CHARS_PER_LINE: int = 15

# Vector3i (world-block coords) → Array[String] (length 4).
var _signs: Dictionary = {}


# Live 4-string array for the sign at `pos`, creating an empty entry
# (4 empty strings) on first access.
func get_or_create(pos: Vector3i) -> Array:
	if not _signs.has(pos):
		var lines: Array = []
		lines.resize(LINES_PER_SIGN)
		for i in range(LINES_PER_SIGN):
			lines[i] = ""
		_signs[pos] = lines
	return _signs[pos]


func has_sign(pos: Vector3i) -> bool:
	return _signs.has(pos)


# Set one of the 4 text lines. Clips at MAX_CHARS_PER_LINE so the edit
# GUI doesn't need to enforce length itself.
func set_text(pos: Vector3i, line_idx: int, text: String) -> void:
	if line_idx < 0 or line_idx >= LINES_PER_SIGN:
		return
	var lines: Array = get_or_create(pos)
	lines[line_idx] = text.substr(0, MAX_CHARS_PER_LINE)
	text_changed.emit(pos)


# Get all 4 lines as a snapshot Array (caller can mutate without
# touching live state). Returns 4 empty strings if no sign at pos.
func get_lines(pos: Vector3i) -> Array:
	if not _signs.has(pos):
		var empty: Array = []
		empty.resize(LINES_PER_SIGN)
		for i in range(LINES_PER_SIGN):
			empty[i] = ""
		return empty
	return (_signs[pos] as Array).duplicate()


# Forget a sign — called when the block breaks. Vanilla doesn't try
# to preserve sign text through the item form, so we drop it here.
func forget(pos: Vector3i) -> void:
	_signs.erase(pos)


# Persistence: serialize every sign within (cx, cz) into a flat Array
# the chunk save format can store. Inverse of `restore_from_snapshot`.
# Layout per entry: [x, y, z, line0, line1, line2, line3]. We use a
# flat dict-list instead of a structured serializer so the chunk save
# code can write/read it via var_to_bytes without a schema dep.
func snapshot_for_chunk(cx: int, cz: int) -> Array:
	var out: Array = []
	for pos: Vector3i in _signs:
		var entry_cx: int = int(floor(float(pos.x) / float(Chunk.SIZE_X)))
		var entry_cz: int = int(floor(float(pos.z) / float(Chunk.SIZE_Z)))
		if entry_cx != cx or entry_cz != cz:
			continue
		var lines: Array = _signs[pos]
		(
			out
			. append(
				{
					"pos": pos,
					"l0": String(lines[0]),
					"l1": String(lines[1]),
					"l2": String(lines[2]),
					"l3": String(lines[3]),
				}
			)
		)
	return out


# Drop every sign in (cx, cz). Used by chunk-unload to free memory for
# distant chunks; combined with `snapshot_for_chunk` for the save path.
func forget_chunk(cx: int, cz: int) -> void:
	var to_drop: Array = []
	for pos: Vector3i in _signs:
		var entry_cx: int = int(floor(float(pos.x) / float(Chunk.SIZE_X)))
		var entry_cz: int = int(floor(float(pos.z) / float(Chunk.SIZE_Z)))
		if entry_cx == cx and entry_cz == cz:
			to_drop.append(pos)
	for p: Vector3i in to_drop:
		_signs.erase(p)


# Restore from a snapshot — drops any existing signs in (cx, cz)
# first so reloads don't get duplicates. Layout matches what
# `snapshot_for_chunk` produces.
func restore_from_snapshot(cx: int, cz: int, snapshot: Array) -> void:
	forget_chunk(cx, cz)
	for entry in snapshot:
		var lines: Array = []
		lines.resize(LINES_PER_SIGN)
		lines[0] = String(entry.get("l0", ""))
		lines[1] = String(entry.get("l1", ""))
		lines[2] = String(entry.get("l2", ""))
		lines[3] = String(entry.get("l3", ""))
		_signs[entry.pos] = lines
