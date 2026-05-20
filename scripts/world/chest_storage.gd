extends Node

# Tile-entity store for chests. Vanilla TileEntityChest holds a 27-slot
# ItemStack[] per block. We keep a single global Dictionary keyed by world
# position so the chunk's PackedByteArray block array stays a pure id
# store — same pattern as FurnaceManager.
#
# No per-tick logic (chests are passive containers, unlike furnaces), so
# this autoload is just a typed map.
#
# Persistence: not yet wired — this dict lives for the process lifetime.
# Phase 7 saves chunk-keyed snapshots to disk; ChunkManager will call a
# `serialize_chunk` / `restore_chunk` helper here at that point.

const _SLOT_COUNT: int = 27

# Vector3i (world-block coords) → Array[ItemStack] (length 27).
var _chests: Dictionary = {}


# Returns the live 27-slot array for the chest at `pos`, creating an
# empty inventory if this is the first access. Caller is responsible
# for ensuring `pos` is actually a chest block (interaction.gd does this
# on RMB before showing the UI).
func get_or_create(pos: Vector3i) -> Array:
	if not _chests.has(pos):
		var slots: Array = []
		slots.resize(_SLOT_COUNT)
		for i in range(_SLOT_COUNT):
			slots[i] = ItemStack.new()
		_chests[pos] = slots
	return _chests[pos]


func has_chest(pos: Vector3i) -> bool:
	return _chests.has(pos)


# Forget a chest (block was broken). Caller is responsible for spitting
# the contents into DroppedItem entities BEFORE calling this — once we
# erase, the items are gone.
func forget(pos: Vector3i) -> void:
	_chests.erase(pos)


# Snapshot view of every non-empty stack in this chest, for the
# break-block-spits-contents path. Returns a fresh Array (caller can
# mutate without touching live state).
func contents_snapshot(pos: Vector3i) -> Array:
	if not _chests.has(pos):
		return []
	var out: Array = []
	for stack: ItemStack in _chests[pos]:
		if not stack.is_empty():
			var clone := ItemStack.new()
			clone.copy_from(stack)
			out.append(clone)
	return out


# --- Persistence hooks (step 7.2) ---


# Build a chunk-local serialization of every chest whose world coord falls
# inside the chunk at `chunk_coord`. Returns {Vector3i_local: items_array}
# where items_array is 27 entries of `[item_id, count, damage]`. Used by
# ChunkManager._persist_chunk to bundle TE state into the saved chunk dict.
func serialize_chunk(chunk_coord: Vector2i) -> Dictionary:
	var result: Dictionary = {}
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	for world_pos: Vector3i in _chests.keys():
		if world_pos.x < min_x or world_pos.x >= max_x:
			continue
		if world_pos.z < min_z or world_pos.z >= max_z:
			continue
		var local_pos := Vector3i(world_pos.x - min_x, world_pos.y, world_pos.z - min_z)
		var items: Array = []
		items.resize(_SLOT_COUNT)
		var slots: Array = _chests[world_pos]
		for i in range(_SLOT_COUNT):
			var stack: ItemStack = slots[i]
			items[i] = [stack.item_id, stack.count, stack.damage]
		result[local_pos] = items
	return result


# Drop every chest in the given chunk from the live store. Called by
# ChunkManager._persist_chunk right after serialize_chunk so the unloaded
# chunk's TEs don't linger in memory.
func forget_chunk(chunk_coord: Vector2i) -> void:
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	var to_remove: Array[Vector3i] = []
	for world_pos: Vector3i in _chests.keys():
		if world_pos.x < min_x or world_pos.x >= max_x:
			continue
		if world_pos.z < min_z or world_pos.z >= max_z:
			continue
		to_remove.append(world_pos)
	for pos: Vector3i in to_remove:
		_chests.erase(pos)


# Distinct chunk coords containing any live chest. ChunkManager.flush_
# dirty_loaded calls this so chunks whose only "edit" was chest-content
# changes (no block placement → never flagged in _dirty_loaded) still
# get persisted on autosave + save-and-quit.
func get_active_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var seen: Dictionary = {}
	for world_pos: Vector3i in _chests.keys():
		# Arithmetic right shift gives the correct chunk for negative
		# world coords too (-1 >> 4 == -1, not 0).
		var coord := Vector2i(world_pos.x >> 4, world_pos.z >> 4)
		if not seen.has(coord):
			seen[coord] = true
			result.append(coord)
	return result


# Inverse of serialize_chunk. `dict` is {Vector3i_local: items_array}.
# Called from ChunkManager._materialize_chunk after a saved chunk loads.
func restore_chunk(chunk_coord: Vector2i, dict: Dictionary) -> void:
	var origin_x: int = chunk_coord.x * Chunk.SIZE_X
	var origin_z: int = chunk_coord.y * Chunk.SIZE_Z
	for local_pos: Vector3i in dict.keys():
		var world_pos := Vector3i(origin_x + local_pos.x, local_pos.y, origin_z + local_pos.z)
		var items_data: Array = dict[local_pos]
		var slots: Array = []
		slots.resize(_SLOT_COUNT)
		for i in range(_SLOT_COUNT):
			if i < items_data.size():
				var d: Array = items_data[i]
				var stack := ItemStack.new(int(d[0]), int(d[1]))
				stack.damage = int(d[2])
				slots[i] = stack
			else:
				slots[i] = ItemStack.new()
		_chests[world_pos] = slots
