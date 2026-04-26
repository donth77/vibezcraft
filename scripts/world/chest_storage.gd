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
