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


# Build a chunk-local serialization of every sign whose world coord
# falls inside the chunk at `chunk_coord`. Returns {Vector3i_local:
# lines_array} where lines_array is 4 strings. Same shape as
# ChestStorage / FurnaceManager so chunk_manager._build_chunk_save_entry
# can bundle all three under one `tile_entities` dict.
func serialize_chunk(chunk_coord: Vector2i) -> Dictionary:
	var result: Dictionary = {}
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	for world_pos: Vector3i in _signs.keys():
		if world_pos.x < min_x or world_pos.x >= max_x:
			continue
		if world_pos.z < min_z or world_pos.z >= max_z:
			continue
		var local_pos := Vector3i(world_pos.x - min_x, world_pos.y, world_pos.z - min_z)
		var lines: Array = (_signs[world_pos] as Array).duplicate()
		result[local_pos] = lines
	return result


# Inverse of serialize_chunk. `dict` is {Vector3i_local: lines_array}.
# Called from ChunkManager._materialize_chunk after a saved chunk loads.
func restore_chunk(chunk_coord: Vector2i, dict: Dictionary) -> void:
	var origin_x: int = chunk_coord.x * Chunk.SIZE_X
	var origin_z: int = chunk_coord.y * Chunk.SIZE_Z
	for local_pos: Vector3i in dict.keys():
		var world_pos := Vector3i(origin_x + local_pos.x, local_pos.y, origin_z + local_pos.z)
		var raw: Array = dict[local_pos]
		var lines: Array = []
		lines.resize(LINES_PER_SIGN)
		for i in range(LINES_PER_SIGN):
			lines[i] = String(raw[i]) if i < raw.size() else ""
		_signs[world_pos] = lines
		# Fire so any SignNode that has already spawned for this world_pos
		# (e.g. a previously-loaded chunk that gets re-decorated) refreshes
		# its labels with the restored text instead of staying blank.
		text_changed.emit(world_pos)


# Drop every sign in chunk_coord. Used by chunk-unload to free memory
# for distant chunks; combined with `serialize_chunk` for the save path.
func forget_chunk(chunk_coord: Vector2i) -> void:
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	var to_drop: Array[Vector3i] = []
	for world_pos: Vector3i in _signs.keys():
		if world_pos.x < min_x or world_pos.x >= max_x:
			continue
		if world_pos.z < min_z or world_pos.z >= max_z:
			continue
		to_drop.append(world_pos)
	for p: Vector3i in to_drop:
		_signs.erase(p)


# Distinct chunk coords containing any live sign. ChunkManager.
# flush_dirty_loaded calls this so chunks whose only edit was a sign
# text change (no block re-place after the initial put → never re-flagged
# in _dirty_loaded after the first save) still get persisted on autosave.
func get_active_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var seen: Dictionary = {}
	for world_pos: Vector3i in _signs.keys():
		var coord := Vector2i(world_pos.x >> 4, world_pos.z >> 4)
		if not seen.has(coord):
			seen[coord] = true
			result.append(coord)
	return result
