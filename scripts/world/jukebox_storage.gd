extends Node

# Tile-entity store for jukeboxes. Vanilla TileEntityRecordPlayer holds
# a single `record` ItemStack per block (only the item id matters —
# discs never stack and have no per-instance state). We mirror that
# with a Dictionary keyed by world position → item_id int. Empty
# jukebox = key not present.
#
# Same passive-store pattern as ChestStorage: no per-tick logic, just
# a typed map. Audio playback lives in JukeboxAudio; this autoload
# only tracks what disc is in which jukebox.
#
# Persistence: same chunk-keyed snapshot pattern ChestStorage uses
# (serialize_chunk + restore_chunk hooks below) so the saved chunk
# dict carries the jukebox contents along with the block array.

# Vector3i (world-block coords) → int (disc item id). Empty jukebox =
# key not present in the dict.
var _jukeboxes: Dictionary = {}


# Insert / replace the disc in this jukebox. Returns the PREVIOUS disc
# id (or 0 if the slot was empty) so the caller can spawn it as a
# DroppedItem (the "eject before insert" path).
func set_disc(pos: Vector3i, disc_id: int) -> int:
	var prev: int = int(_jukeboxes.get(pos, 0))
	if disc_id == 0:
		_jukeboxes.erase(pos)
	else:
		_jukeboxes[pos] = disc_id
	return prev


# Returns the disc id at this jukebox, or 0 if empty / not a jukebox.
func get_disc(pos: Vector3i) -> int:
	return int(_jukeboxes.get(pos, 0))


func has_disc(pos: Vector3i) -> bool:
	return _jukeboxes.has(pos)


# Forget the jukebox entirely (block was broken). Caller is responsible
# for spawning the contained disc as a DroppedItem BEFORE calling this
# — once we erase, the disc id is gone.
func forget(pos: Vector3i) -> void:
	_jukeboxes.erase(pos)


# --- Persistence hooks (mirror ChestStorage.serialize_chunk pattern) ---


# Build a chunk-local snapshot of every jukebox in the chunk at
# `chunk_coord`. Returns {Vector3i_local: disc_id_int}. Used by
# ChunkManager._persist_chunk to bundle TE state into the saved chunk.
func serialize_chunk(chunk_coord: Vector2i) -> Dictionary:
	var result: Dictionary = {}
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	for world_pos: Vector3i in _jukeboxes.keys():
		if world_pos.x < min_x or world_pos.x >= max_x:
			continue
		if world_pos.z < min_z or world_pos.z >= max_z:
			continue
		var local_pos := Vector3i(world_pos.x - min_x, world_pos.y, world_pos.z - min_z)
		result[local_pos] = _jukeboxes[world_pos]
	return result


# Returns every chunk coord that holds at least one jukebox. Mirrors
# ChestStorage.get_active_chunks — used by ChunkManager.flush_dirty_loaded
# so a chunk whose only edit was a disc swap (no block placement → never
# in _dirty_loaded) still persists on autosave + save-and-quit.
func get_active_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var seen: Dictionary = {}
	for world_pos: Vector3i in _jukeboxes.keys():
		var coord := Vector2i(world_pos.x >> 4, world_pos.z >> 4)
		if not seen.has(coord):
			seen[coord] = true
			result.append(coord)
	return result


# Drop all jukeboxes whose world coord falls in `chunk_coord`. Called
# by ChunkManager right after serialize_chunk so the unloaded chunk's
# TE state stops occupying memory.
func forget_chunk(chunk_coord: Vector2i) -> void:
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	var to_erase: Array[Vector3i] = []
	for world_pos: Vector3i in _jukeboxes.keys():
		if (
			world_pos.x >= min_x
			and world_pos.x < max_x
			and world_pos.z >= min_z
			and world_pos.z < max_z
		):
			to_erase.append(world_pos)
	for p: Vector3i in to_erase:
		_jukeboxes.erase(p)


# Inverse of serialize_chunk. `dict` is {Vector3i_local: disc_id_int}.
# ChunkManager calls this when loading a persisted chunk so the
# jukebox contents come back along with the block array.
func restore_chunk(chunk_coord: Vector2i, dict: Dictionary) -> void:
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	for local_pos_v: Variant in dict.keys():
		var local_pos: Vector3i = local_pos_v as Vector3i
		var world_pos := Vector3i(local_pos.x + min_x, local_pos.y, local_pos.z + min_z)
		_jukeboxes[world_pos] = int(dict[local_pos_v])
