extends Node

# Tile-entity store + ticker for furnaces. Vanilla TileEntityFurnace lives
# per-block and runs onUpdate every game tick. We keep a single global
# Dictionary keyed by world position so the chunk's PackedByteArray block
# array stays a pure id store (no per-block extension).
#
# Per-furnace state:
#   input  (ItemStack): item being smelted
#   fuel   (ItemStack): fuel buffer
#   output (ItemStack): result accumulator
#   cook_time     (int): 0..SMELT_TICKS, advances when lit + smeltable
#   burn_time     (int): remaining ticks of current fuel unit
#   burn_total    (int): full burn ticks of the consumed fuel — for UI flame bar
#
# Persistence: when a chunk unloads, ChunkManager calls `serialize_chunk`
# to extract its furnace dicts; on reload, `restore_chunk` puts them back.
# Furnaces inside unloaded chunks freeze (don't tick) to keep the load
# bounded by render distance × ~4 furnaces/chunk worst case.

const TICK_HZ: float = 20.0  # vanilla MC game-tick rate
const _TICK_INTERVAL: float = 1.0 / TICK_HZ

# coord (Vector3i, world-block coords) → state Dictionary
var _furnaces: Dictionary = {}
# Coords whose lit-state needs reconciling against the world block id.
# Drained at the end of each tick into set_world_block calls.
var _lit_changes: Dictionary = {}  # Vector3i → bool (true = should be lit)

var _accum: float = 0.0
var _chunk_manager: Node


func _process(delta: float) -> void:
	if _chunk_manager == null:
		_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
		if _chunk_manager == null:
			return
	_accum += delta
	while _accum >= _TICK_INTERVAL:
		_accum -= _TICK_INTERVAL
		_tick_all()


# Returns the live state dict for a furnace at `pos`, creating one if it
# doesn't exist yet. Caller is responsible for ensuring `pos` is actually
# a furnace block (the FurnaceScreen does this on RMB).
func get_or_create(pos: Vector3i) -> Dictionary:
	if not _furnaces.has(pos):
		_furnaces[pos] = {
			"input": ItemStack.new(),
			"fuel": ItemStack.new(),
			"output": ItemStack.new(),
			"cook_time": 0,
			"burn_time": 0,
			"burn_total": 0,
		}
	return _furnaces[pos]


func has_furnace(pos: Vector3i) -> bool:
	return _furnaces.has(pos)


# Forget a furnace (block was broken). Caller is responsible for spitting
# out any contained items as DroppedItem entities first.
func forget(pos: Vector3i) -> void:
	_furnaces.erase(pos)


# --- Persistence hooks (step 7.2) ---


# Build a chunk-local serialization of every furnace inside `chunk_coord`.
# Returns {Vector3i_local: state_dict} where state_dict's ItemStacks are
# flattened to `[item_id, count, damage]` arrays so it round-trips through
# var_to_bytes cleanly. Used by ChunkManager._persist_chunk.
func serialize_chunk(chunk_coord: Vector2i) -> Dictionary:
	var result: Dictionary = {}
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	for world_pos: Vector3i in _furnaces.keys():
		if world_pos.x < min_x or world_pos.x >= max_x:
			continue
		if world_pos.z < min_z or world_pos.z >= max_z:
			continue
		var state: Dictionary = _furnaces[world_pos]
		var local_pos := Vector3i(world_pos.x - min_x, world_pos.y, world_pos.z - min_z)
		result[local_pos] = {
			"input": _pack_stack(state.input),
			"fuel": _pack_stack(state.fuel),
			"output": _pack_stack(state.output),
			"cook_time": state.cook_time,
			"burn_time": state.burn_time,
			"burn_total": state.burn_total,
		}
	return result


# Drop every furnace in the given chunk from the live store. Called by
# ChunkManager._persist_chunk right after serialize_chunk.
func forget_chunk(chunk_coord: Vector2i) -> void:
	var min_x: int = chunk_coord.x * Chunk.SIZE_X
	var min_z: int = chunk_coord.y * Chunk.SIZE_Z
	var max_x: int = min_x + Chunk.SIZE_X
	var max_z: int = min_z + Chunk.SIZE_Z
	var to_remove: Array[Vector3i] = []
	for world_pos: Vector3i in _furnaces.keys():
		if world_pos.x < min_x or world_pos.x >= max_x:
			continue
		if world_pos.z < min_z or world_pos.z >= max_z:
			continue
		to_remove.append(world_pos)
	for pos: Vector3i in to_remove:
		_furnaces.erase(pos)


# Distinct chunk coords containing any live furnace. See the matching
# helper in chest_storage.gd for why this exists — same content-only-
# edit-not-flagged-dirty issue.
func get_active_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var seen: Dictionary = {}
	for world_pos: Vector3i in _furnaces.keys():
		var coord := Vector2i(world_pos.x >> 4, world_pos.z >> 4)
		if not seen.has(coord):
			seen[coord] = true
			result.append(coord)
	return result


# Inverse of serialize_chunk. `dict` is {Vector3i_local: state_dict}.
# Called from ChunkManager._materialize_chunk after a saved chunk loads.
func restore_chunk(chunk_coord: Vector2i, dict: Dictionary) -> void:
	var origin_x: int = chunk_coord.x * Chunk.SIZE_X
	var origin_z: int = chunk_coord.y * Chunk.SIZE_Z
	for local_pos: Vector3i in dict.keys():
		var world_pos := Vector3i(origin_x + local_pos.x, local_pos.y, origin_z + local_pos.z)
		var s: Dictionary = dict[local_pos]
		_furnaces[world_pos] = {
			"input": _unpack_stack(s.input),
			"fuel": _unpack_stack(s.fuel),
			"output": _unpack_stack(s.output),
			"cook_time": int(s.cook_time),
			"burn_time": int(s.burn_time),
			"burn_total": int(s.burn_total),
		}


# ItemStack → [item_id, count, damage] for var_to_bytes safety.
func _pack_stack(stack: ItemStack) -> Array:
	return [stack.item_id, stack.count, stack.damage]


# Inverse of _pack_stack.
func _unpack_stack(packed: Array) -> ItemStack:
	var stack := ItemStack.new(int(packed[0]), int(packed[1]))
	stack.damage = int(packed[2])
	return stack


# --- Ticker ---


func _tick_all() -> void:
	for pos: Vector3i in _furnaces.keys():
		_tick_one(pos, _furnaces[pos])
	# Apply any lit-state transitions (single set_world_block per change)
	for pos: Vector3i in _lit_changes.keys():
		var should_lit: bool = _lit_changes[pos]
		var current: int = _chunk_manager.get_world_block(pos)
		var target: int = Blocks.LIT_FURNACE if should_lit else Blocks.FURNACE
		if current != target and (current == Blocks.FURNACE or current == Blocks.LIT_FURNACE):
			_chunk_manager.set_world_block(pos, target)
	_lit_changes.clear()


# Mirrors TileEntityFurnace.h() / onUpdate(). One game tick.
func _tick_one(pos: Vector3i, state: Dictionary) -> void:
	var was_lit: bool = state.burn_time > 0
	# 1. Burn-time decrement.
	if state.burn_time > 0:
		state.burn_time -= 1
	# 2. Try to ignite if not currently burning.
	var input: ItemStack = state.input
	var fuel: ItemStack = state.fuel
	var output: ItemStack = state.output
	if state.burn_time == 0 and _can_smelt(input, output) and not fuel.is_empty():
		var ticks: int = Smelting.fuel_burn_ticks(fuel.item_id)
		if ticks > 0:
			state.burn_time = ticks
			state.burn_total = ticks
			fuel.remove(1)
	# 3. Advance cook progress when lit + recipe valid; else reset.
	if state.burn_time > 0 and _can_smelt(input, output):
		state.cook_time += 1
		if state.cook_time >= Smelting.SMELT_TICKS:
			_complete_smelt(state)
			state.cook_time = 0
	else:
		state.cook_time = 0
	# 4. Reconcile lit block id (defer to end-of-tick).
	var now_lit: bool = state.burn_time > 0
	if was_lit != now_lit:
		_lit_changes[pos] = now_lit


# Vanilla canSmelt(): input non-empty, has a recipe, output can stack.
func _can_smelt(input: ItemStack, output: ItemStack) -> bool:
	if input.is_empty() or not Smelting.is_smeltable(input.item_id):
		return false
	var result: int = Smelting.result_for(input.item_id)
	if output.is_empty():
		return true
	if output.item_id != result:
		return false
	return output.count < ItemStack.MAX_SIZE


func _complete_smelt(state: Dictionary) -> void:
	var input: ItemStack = state.input
	var output: ItemStack = state.output
	var result: int = Smelting.result_for(input.item_id)
	if output.is_empty():
		output.item_id = result
		output.count = 1
	else:
		output.count += 1
	input.remove(1)
