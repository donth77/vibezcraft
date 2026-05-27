class_name TickScheduler
extends RefCounted

# Scheduled block-tick queue. Mirrors Alpha's `World.b(x, y, z, blockID,
# delay)` mechanism: a block calls `schedule(pos, id, delay_ticks)` to
# request a callback after N game ticks, and the scheduler fires it on
# the appropriate future tick. Used by BlockFluids (Flow #3) — water
# reschedules itself every 5 ticks, lava every 30.
#
# Cadence is vanilla's 20 Hz game tick (50 ms per tick). `advance(delta)`
# accumulates wall-clock seconds; when enough has passed to cross a tick
# boundary, `_tick_all(manager)` drains every entry whose `fire_tick` is
# now due. Multiple ticks can fire in one frame (e.g. after a frame hitch
# or a long pause), clamped at `_MAX_TICKS_PER_ADVANCE` so a resumed-from-
# pause session doesn't do 600 seconds of catch-up in one frame.
#
# Vanilla reference:
#   vendor/alpha-1.2.6-src/src/cy.java::World.b(int,int,int,int,int)
#   vendor/alpha-1.2.6-src/src/cy.java::World.c(boolean) (tick drain)
#
# Thread: scheduler lives entirely on the main thread. Block-tick
# callbacks may write into the world via ChunkManager.set_world_block,
# which dispatches worker remeshes as usual.

const SECONDS_PER_TICK: float = 0.05  # vanilla 20 Hz
# Cap how many ticks we catch up in a single advance() call. A 10 s frame
# hitch shouldn't fire 200 queued ticks — clamp to prevent a main-thread
# spiral when the scheduler queue is large.
const _MAX_TICKS_PER_ADVANCE: int = 20

# Monotonic tick counter. Starts at 0, increments once per game tick.
# Wraps at int64 max but that's centuries of play time — never an issue.
static var _current_tick: int = 0

# Pending entries. Array of Dictionaries: { pos: Vector3i, block_id: int,
# fire_tick: int }. Kept as a plain array (not heap) — typical active
# fluid counts are under a few hundred, and an O(n) drain per tick is
# ~µs. If this becomes a hot spot (huge cascades), swap in a binary heap.
static var _pending: Array = []

# Wall-clock seconds carried across frames. Drained in SECONDS_PER_TICK
# chunks by advance().
static var _accum_seconds: float = 0.0


# Enqueue a scheduled tick. `delay_ticks` is a positive integer — the
# callback fires `delay_ticks` ticks from now (so delay=1 fires next tick).
# Vanilla allows a priority arg; we omit it since Alpha only uses
# priority for fluid ordering and that's already encoded in the fire_tick
# ordering (same-tick entries fire in enqueue order).
#
# Duplicate schedules at the same (pos, block_id) are allowed — vanilla
# checks for them to prevent queue spam but the cost is trivial for us
# and the fluid algorithm is idempotent across multiple fire events on
# the same cell.
static func schedule(pos: Vector3i, block_id: int, delay_ticks: int) -> void:
	if delay_ticks < 1:
		delay_ticks = 1
	(
		_pending
		. append(
			{
				"pos": pos,
				"block_id": block_id,
				"fire_tick": _current_tick + delay_ticks,
			}
		)
	)


# Remove all pending ticks for a (pos, block_id) match. Called by the
# block-break path so a block that's been destroyed before its tick
# fires doesn't resurrect it. Vanilla World.b wraps the tick list in a
# HashSet keyed by (pos, id) which implicitly handles this; we walk the
# array since our counts are small.
static func cancel(pos: Vector3i, block_id: int) -> void:
	var write: int = 0
	for read in range(_pending.size()):
		var entry: Dictionary = _pending[read]
		if entry.pos == pos and entry.block_id == block_id:
			continue
		if write != read:
			_pending[write] = entry
		write += 1
	_pending.resize(write)


# Called by ChunkManager._process every frame. `manager` is the
# ChunkManager; scheduled-tick callbacks need it to read+write blocks.
# Accumulates wall-clock delta until a full tick boundary is crossed,
# then drains all due entries.
static func advance(delta: float, manager) -> void:
	_accum_seconds += delta
	var ticks_to_fire: int = int(floor(_accum_seconds / SECONDS_PER_TICK))
	if ticks_to_fire <= 0:
		return
	# Clamp catch-up. Anything beyond the cap gets discarded from accum
	# so we don't stall on the next frame trying to drain the backlog.
	if ticks_to_fire > _MAX_TICKS_PER_ADVANCE:
		ticks_to_fire = _MAX_TICKS_PER_ADVANCE
		_accum_seconds = 0.0
	else:
		_accum_seconds -= float(ticks_to_fire) * SECONDS_PER_TICK
	for _i in range(ticks_to_fire):
		_current_tick += 1
		_tick_all(manager)
		# Vanilla random tick pass — every game tick picks N random
		# cells per loaded chunk and fires per-block updateTick on the
		# `is_random_tickable` subset (grass spread/decay, etc.). Lives
		# on `Blocks` to keep the per-block logic colocated.
		Blocks.run_random_tick_pass(manager)


# Drain every pending entry whose fire_tick is now due. Mirrors vanilla's
# `World.c(boolean)` loop. Order preserved within a tick — entries enqueued
# earlier fire earlier, matching vanilla's insertion-order stability.
static func _tick_all(manager) -> void:
	if _pending.is_empty():
		return
	var probe_token := PerfProbe.begin("tick.scheduler")
	# Partition pending into "fire now" (fire_tick <= current) and "later".
	# Single-pass compaction so we don't allocate extra arrays.
	var fire_now: Array = []
	var remaining: Array = []
	for entry: Dictionary in _pending:
		if entry.fire_tick <= _current_tick:
			fire_now.append(entry)
		else:
			remaining.append(entry)
	_pending = remaining
	for entry: Dictionary in fire_now:
		# Pass the scheduled block id to the callback so it can verify
		# the cell still holds what we queued (player may have broken
		# it mid-tick). Blocks.on_scheduled_tick switches on block id
		# and dispatches to the fluid / redstone / whatever handler.
		Blocks.on_scheduled_tick(manager, entry.pos, entry.block_id)
	PerfProbe.end("tick.scheduler", probe_token)


# Harvest + remove every pending tick whose position falls inside the
# chunk `(cx, cz)`. Returns a plain-data array the caller can stash in
# the chunk's save entry, then hand back to `restore_ticks()` on reload.
#
# Fire-tick values are stored as RELATIVE offsets (delay = fire_tick -
# current_tick at harvest time). That way pending ticks resume with the
# same wall-clock delay after the chunk comes back, regardless of how
# long the world ticked while the chunk was unloaded.
#
# Without this, ticks for unloaded chunks stay in _pending and fire as
# no-ops (manager.get_world_block is OOB → AIR → id mismatch in
# on_scheduled_tick). That's both a leak AND a correctness bug: fluid
# mid-flow freezes on chunk reload since no tick re-enters the cell.
# Non-destructive variant of take_for_chunk: returns the same Array of
# dicts but leaves the scheduler queue intact. Used by ChunkManager's
# autosave + save-and-quit flush_dirty_loaded path, where the live
# chunk keeps running after the save so we don't want to drain its
# pending ticks. Same dict shape as take_for_chunk (pos, block_id,
# delay) so save/load callers can use either interchangeably.
static func peek_for_chunk(cx: int, cz: int) -> Array:
	var harvested: Array = []
	for entry: Dictionary in _pending:
		var pos: Vector3i = entry.pos
		var entry_cx: int = int(floor(float(pos.x) / float(Chunk.SIZE_X)))
		var entry_cz: int = int(floor(float(pos.z) / float(Chunk.SIZE_Z)))
		if entry_cx == cx and entry_cz == cz:
			(
				harvested
				. append(
					{
						"pos": pos,
						"block_id": entry.block_id,
						"delay": max(1, entry.fire_tick - _current_tick),
					}
				)
			)
	return harvested


static func take_for_chunk(cx: int, cz: int) -> Array:
	var harvested: Array = []
	var write: int = 0
	for read in range(_pending.size()):
		var entry: Dictionary = _pending[read]
		var pos: Vector3i = entry.pos
		var entry_cx: int = int(floor(float(pos.x) / float(Chunk.SIZE_X)))
		var entry_cz: int = int(floor(float(pos.z) / float(Chunk.SIZE_Z)))
		if entry_cx == cx and entry_cz == cz:
			(
				harvested
				. append(
					{
						"pos": pos,
						"block_id": entry.block_id,
						"delay": max(1, entry.fire_tick - _current_tick),
					}
				)
			)
			continue
		if write != read:
			_pending[write] = entry
		write += 1
	_pending.resize(write)
	return harvested


# Re-enqueue ticks previously harvested via `take_for_chunk`. Each entry's
# stored relative `delay` becomes (current_tick + delay) at restore time.
static func restore_ticks(entries: Array) -> void:
	for entry: Dictionary in entries:
		var delay: int = entry.get("delay", 1) as int
		if delay < 1:
			delay = 1
		(
			_pending
			. append(
				{
					"pos": entry.pos,
					"block_id": entry.block_id,
					"fire_tick": _current_tick + delay,
				}
			)
		)


# Diagnostic — scheduler state for the debug panel / tests.
static func pending_count() -> int:
	return _pending.size()


static func current_tick() -> int:
	return _current_tick


# Test hook. Tests need a clean scheduler between cases since the static
# queue persists across GUT test boundaries.
static func reset_for_tests() -> void:
	_pending.clear()
	_current_tick = 0
	_accum_seconds = 0.0
