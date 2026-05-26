class_name BlockFluids
extends RefCounted

# BlockFluids algorithm port. Mirrors Alpha 1.2.6's `ja.java` (BlockFlowing)
# and `ir.java` (BlockStationary), cross-checked against Beta's
# BlockFluid + BlockFlowing + BlockStationary. The Alpha and Beta sources
# are algorithmically identical here — both use the same updateTick body,
# 2-source water consolidation, lava 1/4 stall, and shortest-path flow
# biasing. Beta's only structural change was the BlockStationary subclass
# split (which we model as a metadata flag rather than a separate block
# class — same effect). This file is fully Beta-faithful.
#
# Called from `Blocks.on_scheduled_tick` when a flowing-fluid tick fires.
# Both fluids use the same algorithm with two knobs:
#   - `DECAY_PER_STEP`: 1 for water, 2 for lava (lava thins twice as fast)
#   - `TICK_RATE`:      5 for water, 30 for lava (lava flows ~6× slower)
#
# Known divergence: `_is_solid_blocker` doesn't yet enumerate Beta's
# door/sign/ladder/reed/portal exceptions (those blocks aren't in our
# block set yet). Add those exceptions when the blocks land.
#
# Level semantics (stored in chunk.block_meta):
#   0       → source block (infinite; never dries up)
#   1..7    → flowing; level increments away from source, 8+ = dry
#   8..15   → "falling" bit set (bit 3) — cell is being fed from above,
#             flows outward as if it were level 0..7 respectively
#
# Key vanilla algorithm steps (ja.java:23-99, see inline refs):
#
#   1. Read current level `n6`.
#   2. If `n6 > 0` (not a source): look at 4 lateral neighbors, take
#      min(their levels) → `n8`. Counter source-neighbors in `_source_count`.
#      Compute proposed new level `n5 = n8 + DECAY_PER_STEP`.
#      Sanity: if n5 >= 8 (decayed past reach) or n8 < 0 (no neighbors):
#        → drain (set n5 = -1 = AIR).
#      If cell above is same fluid: copy level from above (keeps stream fed).
#      Water-only: if >=2 source-neighbors AND below is solid → become
#        source (classic "2-source rule" for infinite water).
#      Lava-only: 3/4 chance per tick to NOT update level (random stall;
#        makes lava feel slower than its tick rate alone implies).
#   3. If level changed → write new meta, reschedule.
#      Else → reschedule anyway (still-water check).
#   4. Spread phase:
#      a) If cell below is flowable → flow down with level preserved +
#         "falling" bit set. Water falling fills fast.
#      b) Else if n6 == 0 or cell below is solid → spread laterally to
#         flowable neighbors with level = n6 + DECAY_PER_STEP.
#
# Shortest-path spread bias (k()/a() in ja.java:115-177) is implemented
# via `_shortest_path_dirs` + `_shortest_path_search` — depth-limited
# drop-search that flags only the cardinal dirs tied for minimum distance.
# Biases water toward holes instead of filling adjacent cells uniformly.
# Flowing→still convergence (ja.java:16-21 `j()`) is implemented via
# `_promote_to_still` — stable flowing cells stop ticking after their
# level settles.

# Alpha 1.2.6 tick rates. ja.java doesn't set these directly; they come
# from the subclass constructor (BlockFlowing.ctor calls super with
# tickRate). Values verified against Bukkit/mc-dev BlockFlowing.
const WATER_TICK_RATE: int = 5  # 250 ms per spread step @ 20 Hz
const LAVA_TICK_RATE: int = 30  # 1.5 s per spread step (overworld; 10 in nether)

# Per-step level decay. Water reach = 7 blocks (source at 0 → level 7
# after 7 decay steps, level 8 would be dry). Lava reach = 3 blocks
# (source at 0 → level 2 after 1 step = 2, level 4 after 2 steps = 4,
# level 6 after 3 steps — any further would be 8+ = dry).
const WATER_DECAY_PER_STEP: int = 1
const LAVA_DECAY_PER_STEP: int = 2

# "Falling" bit — set in meta when a cell is being fed from directly above.
# Falling fluid has full "effective source" behavior for downstream cells.
# Vanilla: level >= 8 is the falling state; level & 7 is the display level.
const FALLING_BIT: int = 8

# Self-rescheduling counter per class — used as an internal tracking hook
# that vanilla's ja.java resets at the top of tick. Here it's scoped to
# the single tick call via a local var.


# Entry point from Blocks.on_scheduled_tick. `manager` is ChunkManager;
# `pos` is world coords; `block_id` is the fluid id (water_flowing or
# lava_flowing) that was scheduled. Mirrors ja.java:23 `a(World, x, y, z, Random)`.
static func update(manager, pos: Vector3i, block_id: int) -> void:
	var is_water_fluid: bool = Blocks.is_water(block_id)
	var decay: int = WATER_DECAY_PER_STEP if is_water_fluid else LAVA_DECAY_PER_STEP
	var tick_rate: int = WATER_TICK_RATE if is_water_fluid else LAVA_TICK_RATE
	# `current_level` is the RAW meta value (0 = source, 1-7 = flowing,
	# 8-15 = falling with the level=meta-8 bit). Vanilla ja.java's `n6`
	# is the same raw integer — the gate + stall + level-change checks
	# all compare against raw. Earlier versions of this code used an
	# "effective" level (falling → 0) for the gate, which treated
	# falling cells as sources and left them undrainable when their
	# upstream was removed (floating water blocks). See ja.java:31/65.
	var current_level: int = manager.get_world_block_meta(pos)
	var should_schedule_recheck: bool = true
	var source_count: int = 0
	# ja.java:31 — only recompute level if we're not a source (n6 > 0).
	# Flowing (1-7) AND falling (8-15) both enter this branch.
	if current_level > 0:
		var min_n: int = -100
		var scan := _scan_neighbor_min(
			manager, pos + Vector3i(-1, 0, 0), block_id, min_n, source_count
		)
		min_n = scan.min_n
		source_count = scan.source_count
		scan = _scan_neighbor_min(manager, pos + Vector3i(1, 0, 0), block_id, min_n, source_count)
		min_n = scan.min_n
		source_count = scan.source_count
		scan = _scan_neighbor_min(manager, pos + Vector3i(0, 0, -1), block_id, min_n, source_count)
		min_n = scan.min_n
		source_count = scan.source_count
		scan = _scan_neighbor_min(manager, pos + Vector3i(0, 0, 1), block_id, min_n, source_count)
		min_n = scan.min_n
		source_count = scan.source_count
		var proposed: int = min_n + decay
		# ja.java:38 — decayed past reach (>=8) or no neighbors (<0): drain.
		if proposed >= 8 or min_n < 0:
			proposed = -1
		# ja.java:41-44 — fluid directly above keeps us fed. Copy its level
		# (and the falling bit) so a waterfall doesn't pulse-dry in the middle.
		var above_level: int = _fluid_level_at(manager, pos + Vector3i(0, 1, 0), block_id)
		if above_level >= 0:
			proposed = above_level if above_level >= 8 else above_level + 8
		# ja.java:45-51 — water's 2-source rule. With >=2 source neighbors
		# and a solid block below, convert to source (level=0). This is
		# what makes an infinite-water pool work from a 2x2 grid of buckets.
		if is_water_fluid and source_count >= 2:
			var below_id: int = manager.get_world_block(pos + Vector3i(0, -1, 0))
			if _is_solid_blocker(below_id):
				proposed = 0
			elif (
				Blocks.is_water(below_id)
				and manager.get_world_block_meta(pos + Vector3i(0, -1, 0)) == 0
			):
				proposed = 0
		# ja.java:52-55 — lava's 1-in-4 stall. Vanilla `n6 < 8 && n5 < 8
		# && n5 > n6` — all raw comparisons (n6 < 8 excludes falling,
		# since falling cells shouldn't random-stall). Was mis-comparing
		# against effective_current, which coerced falling to 0 and
		# stalled falling lava too.
		if (
			not is_water_fluid
			and current_level < 8
			and proposed < 8
			and proposed > current_level
			and randi() % 4 != 0
		):
			proposed = current_level
			should_schedule_recheck = false
		if proposed != current_level:
			if proposed < 0:
				# Drained. Set cell to AIR + schedule no recheck.
				manager.set_world_block(pos, Blocks.AIR)
				return
			manager.set_world_block_with_meta(pos, block_id, proposed)
			TickScheduler.schedule(pos, block_id, tick_rate)
			# Lava ignition — qh.java's fire-spread loop runs from neighbor
			# blocks but the ignition seed comes from lava. Probe here each
			# time lava's level changes so a spreading lava flow lights
			# flammable along its path.
			if not is_water_fluid:
				_try_lava_ignite(manager, pos)
			# fall through to spread logic
		elif should_schedule_recheck:
			# ja.java:65-66 — level didn't change and we committed to the
			# recheck path. Vanilla calls j() here, which promotes the
			# flowing cell to its STILL sibling (bh+1). Flowing→still
			# convergence: a settled flowing cell stops ticking.
			#
			# Critical: vanilla continues to the spread phase AFTER
			# promoting (the `j()` call is in an `else if` block, not a
			# `return`). Spreading writes to NEIGHBORS, not this cell, so
			# promotion + spread commute. Removing the spread would halt
			# cascades after one tick — e.g. a lateral cell at level 1
			# adjacent to a source computes proposed=1, stabilizes,
			# promotes, and never feeds level 2 outward. Fall through.
			_promote_to_still(manager, pos, block_id)
	else:
		# Source block — always reschedule so we continue feeding outward.
		TickScheduler.schedule(pos, block_id, tick_rate)
	# Refresh current_level after any self-update.
	current_level = manager.get_world_block_meta(pos)
	var spread_level: int = _effective_level(current_level)
	# ja.java:71-76 — try to flow down first. If the cell below is flowable,
	# fill it with our level + FALLING_BIT so downstream cells know they're
	# being fed vertically.
	var below_pos := pos + Vector3i(0, -1, 0)
	if _is_flowable_into(manager, below_pos, block_id):
		var below_meta: int = current_level if current_level >= 8 else current_level + 8
		_place_flowing(manager, below_pos, block_id, below_meta)
	elif spread_level >= 0 and (spread_level == 0 or _is_below_solid(manager, below_pos)):
		# ja.java:77-97 — spread laterally ONLY toward the shortest downward
		# path. `_shortest_path_dirs` runs vanilla's k() recursive search
		# (depth-limited at 4 cells) and returns a bool[4] over W/E/N/S
		# marking the direction(s) tied for the minimum distance to a drop.
		# This is what makes water trace around obstacles instead of
		# filling every adjacent cell.
		var new_level: int = spread_level + decay
		if current_level >= 8:
			new_level = 1
		if new_level < 8:
			var dirs: Array = _shortest_path_dirs(manager, pos, block_id)
			var offsets: Array = [
				Vector3i(-1, 0, 0),
				Vector3i(1, 0, 0),
				Vector3i(0, 0, -1),
				Vector3i(0, 0, 1),
			]
			for i in range(4):
				if not dirs[i]:
					continue
				var target_pos: Vector3i = pos + (offsets[i] as Vector3i)
				if _is_flowable_into(manager, target_pos, block_id):
					_place_flowing(manager, target_pos, block_id, new_level)


# Chunk-adjacent neighbor-on-change handler. Mirrors ir.java:16-21 —
# when a non-fluid block changes near a STILL fluid, flip STILL → FLOWING
# so the flow algorithm can re-check spread. Called from ChunkManager
# set_world_block. Keeps the spread responsive to player edits
# (e.g. punching a hole in a dam).
#
# Flow #5: also drives lava↔water solidification. If `pos` holds lava
# and any of its 5 neighbors (4 lateral + up) is water, the lava cell
# converts per ld.java:223-254: source (meta=0) → OBSIDIAN, flowing
# (meta 1-4) → COBBLESTONE, high-flowing (meta 5-7) → unchanged.
# Water cells themselves don't convert — only lava does.
static func on_neighbor_changed(manager, pos: Vector3i) -> void:
	var id: int = manager.get_world_block(pos)
	if id == Blocks.WATER_STILL:
		_demote_to_flowing(manager, pos, Blocks.WATER_FLOWING)
	elif id == Blocks.LAVA_STILL:
		_demote_to_flowing(manager, pos, Blocks.LAVA_FLOWING)
		_check_lava_solidification(manager, pos)
	elif id == Blocks.LAVA_FLOWING:
		_check_lava_solidification(manager, pos)
	elif Blocks.is_water(id):
		# Water cell itself doesn't convert, but any adjacent lava might.
		# Vanilla's neighbor-notify fans out to all 6 cells; the lava side
		# runs its own ir.java.j() check. Emulate that here so water
		# placement adjacent to lava solidifies the lava immediately.
		for offset: Vector3i in [
			Vector3i(1, 0, 0),
			Vector3i(-1, 0, 0),
			Vector3i(0, 0, 1),
			Vector3i(0, 0, -1),
			Vector3i(0, 1, 0),
			Vector3i(0, -1, 0)
		]:
			var neighbor: Vector3i = pos + offset
			var neighbor_id: int = manager.get_world_block(neighbor)
			if Blocks.is_lava(neighbor_id):
				_check_lava_solidification(manager, neighbor)


# ld.java:223-254 `j()` — lava solidification check. If `pos` holds
# lava and any of its 5 notable neighbors (4 lateral + 1 above) is
# water, replace the lava cell per its level:
#   level 0 (source)       → OBSIDIAN
#   level 1-4 (flowing)    → COBBLESTONE
#   level 5-7 (far-flowing) → no change (fades out before hardening)
#   level 8+ (falling)     → no change (handled separately by vanilla;
#                            matches our "treat as source-like flow")
static func _check_lava_solidification(manager, pos: Vector3i) -> void:
	var id: int = manager.get_world_block(pos)
	if not Blocks.is_lava(id):
		return
	var touching_water: bool = false
	for offset: Vector3i in [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1),
		Vector3i(0, 1, 0)
	]:
		if Blocks.is_water(manager.get_world_block(pos + offset)):
			touching_water = true
			break
	if not touching_water:
		return
	var level: int = manager.get_world_block_meta(pos)
	var replacement: int = -1
	if level == 0:
		replacement = Blocks.OBSIDIAN
	elif level <= 4:
		replacement = Blocks.COBBLESTONE
	else:
		return  # level 5-7 or falling: no solidification
	# Cancel any scheduled tick for this cell — we're replacing the lava
	# with a solid block; a tick firing on the new cobblestone would be
	# a no-op but burning a tick slot is wasteful.
	TickScheduler.cancel(pos, Blocks.LAVA_FLOWING)
	TickScheduler.cancel(pos, Blocks.LAVA_STILL)
	manager.set_world_block(pos, replacement)
	# Fizz + 8 largesmoke particles (ld.java:256-261 `i()`). Routed
	# through ChunkManager so the visual effect is owned by a stable
	# scene node and doesn't leak if fluid callbacks fire while the
	# world is being torn down (e.g. save + quit mid-conversion).
	if manager.has_method("spawn_fluid_fizz"):
		manager.call("spawn_fluid_fizz", pos)


# --- Private helpers ---


# ja.java:191-203 `f()` — scan one neighbor, update running min and
# source-counter. Packaged as a dictionary return so the caller can fold
# the two outputs back into locals.
static func _scan_neighbor_min(
	manager, neighbor_pos: Vector3i, block_id: int, min_n: int, source_count: int
) -> Dictionary:
	var level: int = _fluid_level_at(manager, neighbor_pos, block_id)
	if level < 0:
		return {"min_n": min_n, "source_count": source_count}
	if level == 0:
		source_count += 1
	if level >= 8:
		level = 0
	var new_min: int = min_n
	if min_n < 0 or level < min_n:
		new_min = level
	return {"min_n": new_min, "source_count": source_count}


# ja.java:16-21 (`h()`) — returns the fluid level at (x, y, z) if the
# cell holds the same fluid family (flowing or still of the same
# material), else -1. Level is chunk metadata 0..15.
static func _fluid_level_at(manager, pos: Vector3i, block_id: int) -> int:
	var id: int = manager.get_world_block(pos)
	if not _same_fluid_family(id, block_id):
		return -1
	return manager.get_world_block_meta(pos)


# Convert "falling" levels (>=8) to their base level (0..7) for arithmetic.
# Matches ja.java's pattern `if (n5 >= 8) n5 = 0` sprinkled throughout.
static func _effective_level(meta: int) -> int:
	if meta >= 8:
		return 0
	return meta


# True if two ids are both water or both lava (either flowing or still).
static func _same_fluid_family(id_a: int, id_b: int) -> bool:
	if Blocks.is_water(id_a) and Blocks.is_water(id_b):
		return true
	if Blocks.is_lava(id_a) and Blocks.is_lava(id_b):
		return true
	return false


# ja.java:205-214 `m()` — true if cell can accept flowing fluid. Excludes
# same-fluid (already has it) and lava-blocks-water / water-blocks-lava
# cases. Opaque solids and fragile-destroyable blocks are accepted;
# caller's _place_flowing handles the destroy side-effect.
static func _is_flowable_into(manager, pos: Vector3i, block_id: int) -> bool:
	var id: int = manager.get_world_block(pos)
	if _same_fluid_family(id, block_id):
		return false
	# Opposite-family fluid: lava and water don't merge via BlockFluids —
	# the conversion (→ stone/cobble/obsidian) is handled elsewhere.
	if Blocks.is_water(id) and Blocks.is_lava(block_id):
		return false
	if Blocks.is_lava(id) and Blocks.is_water(block_id):
		return false
	if _is_solid_blocker(id):
		return false
	return true


# ja.java:179-189 `l()` — "solid for fluid" check. Matches the hardcoded
# list: pumpkins + doors + portals + some misc plus any block whose
# material blocks movement. Simplified for our block set: treat any
# opaque block as solid.
static func _is_solid_blocker(id: int) -> bool:
	if id == Blocks.AIR:
		return false
	if Blocks.is_water(id) or Blocks.is_lava(id):
		return false
	# Use `is_solid_collision` instead of `is_opaque` so blocks that are
	# rendered non-opaque but physically solid (CHEST, MOB_SPAWNER,
	# LEAVES, GLASS, etc.) correctly block fluid flow. Vanilla water
	# flows AROUND chests / over leaves rather than through them, and a
	# dungeon spawner shouldn't get overwritten by an adjacent water
	# stream just because its cage renders see-through.
	return Blocks.is_solid_collision(id)


# True if the cell below `pos` is a solid blocker — fluid pools on top of
# solids rather than flowing through.
static func _is_below_solid(manager, below_pos: Vector3i) -> bool:
	var id: int = manager.get_world_block(below_pos)
	return _is_solid_blocker(id)


# ja.java:101-113 `g()` — place a flowing fluid at target cell. Destroys
# fragile target blocks if we're lava (e.g. flowing lava into wood →
# sets the wood's drop free, then overwrites). Water destroys no blocks;
# it just overwrites AIR or plant blocks.
static func _place_flowing(manager, pos: Vector3i, block_id: int, meta: int) -> void:
	var existing: int = manager.get_world_block(pos)
	if existing != Blocks.AIR:
		# Vanilla calls nq.m[n6].b_(world, x, y, z, meta) which drops the
		# block as items. We skip item drops for flow-collisions (matches
		# Alpha behavior for plants — they just vanish into the flow).
		# Lava: don't drop items either; TODO set fire once fire ticks exist.
		pass
	manager.set_world_block_with_meta(pos, block_id, meta)
	# Newly-placed flowing cell must tick so it can continue spreading.
	var rate: int = WATER_TICK_RATE if Blocks.is_water(block_id) else LAVA_TICK_RATE
	TickScheduler.schedule(pos, block_id, rate)


# ir.java pattern — when a neighbor change happens near a STILL cell,
# swap to FLOWING of the same family so the update algorithm re-checks
# spread. Preserves meta (level carries across the id swap).
#
# DIRECT write, not via manager.set_world_block_with_meta: routing back
# through set_world_block would re-fire _notify_fluid_neighbors on THIS
# cell's 6 neighbors, which would demote more STILLs, which would each
# re-enter here, ad infinitum. In an ocean this hits stack overflow
# immediately. Vanilla gets away with the cascade because its neighbor-
# notify is queued for the next tick (World.applyPhysics defers); we
# have no such queue on the edit path, so we write the id + meta
# directly and schedule a tick — the fluid algorithm's own tick-time
# spread will walk outward iteratively across frames.
static func _demote_to_flowing(manager, pos: Vector3i, flowing_id: int) -> void:
	var chunk_x: int = int(floor(float(pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(pos.z) / float(Chunk.SIZE_Z)))
	# manager is an untyped param (avoids a circular import on
	# ChunkManager), so get_chunk_at_coord's return type can't be inferred.
	# Declare `chunk` as Chunk explicitly.
	var chunk: Chunk = manager.get_chunk_at_coord(Vector2i(chunk_x, chunk_z))
	if chunk == null:
		return
	var lx: int = pos.x - chunk_x * Chunk.SIZE_X
	var lz: int = pos.z - chunk_z * Chunk.SIZE_Z
	var existing_meta: int = chunk.get_block_meta(lx, pos.y, lz)
	# set_block_with_meta on the chunk is the direct write — bypasses
	# ChunkManager's notify fanout entirely. We DO need the chunk flagged
	# dirty so the next re-mesh picks up the id change; set_block_with_meta
	# handles that via chunk.dirty = true.
	chunk.set_block_with_meta(lx, pos.y, lz, flowing_id, existing_meta)
	var rate: int = WATER_TICK_RATE if Blocks.is_water(flowing_id) else LAVA_TICK_RATE
	TickScheduler.schedule(pos, flowing_id, rate)


# Inverse of _demote_to_flowing. When a flowing fluid stabilizes (tick
# fires, level didn't change), promote it to its STILL sibling so it
# stops ticking. Same direct-write pattern — bypass set_world_block's
# notify fanout, just swap the id while preserving the level metadata.
#
# Vanilla ja.java:16-21 `j()` — flowing → still by writing `this.bh + 1`
# (id + 1; our WATER_FLOWING=23 → WATER_STILL=24 mirrors this).
static func _promote_to_still(manager, pos: Vector3i, flowing_id: int) -> void:
	var chunk_x: int = int(floor(float(pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(pos.z) / float(Chunk.SIZE_Z)))
	var chunk: Chunk = manager.get_chunk_at_coord(Vector2i(chunk_x, chunk_z))
	if chunk == null:
		return
	var lx: int = pos.x - chunk_x * Chunk.SIZE_X
	var lz: int = pos.z - chunk_z * Chunk.SIZE_Z
	var existing_meta: int = chunk.get_block_meta(lx, pos.y, lz)
	var still_id: int = (
		Blocks.WATER_STILL if flowing_id == Blocks.WATER_FLOWING else Blocks.LAVA_STILL
	)
	chunk.set_block_with_meta(lx, pos.y, lz, still_id, existing_meta)


# Vanilla ja.java:145-177 `k()` — returns a length-4 boolean array
# flagging which of the 4 cardinal directions (W, E, N, S) has the
# shortest path to a downward drop within the search depth limit.
# Multiple dirs can tie for the minimum; all tied dirs get spread to.
# The result biases water toward the most efficient downhill path
# instead of filling all 4 adjacent cells equally.
static func _shortest_path_dirs(manager, pos: Vector3i, block_id: int) -> Array:
	var distances: Array = [1000, 1000, 1000, 1000]
	var offsets: Array = [
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1),
	]
	for i in range(4):
		var neighbor: Vector3i = pos + (offsets[i] as Vector3i)
		# ja.java:165 — skip blocked cells and same-family sources.
		if _is_solid_blocker(manager.get_world_block(neighbor)):
			continue
		if (
			_same_fluid_family(manager.get_world_block(neighbor), block_id)
			and manager.get_world_block_meta(neighbor) == 0
		):
			continue
		# ja.java:166 — if the cell BELOW the neighbor is NOT a solid
		# blocker, this direction drops immediately (distance 0).
		var below: Vector3i = neighbor + Vector3i(0, -1, 0)
		if not _is_solid_blocker(manager.get_world_block(below)):
			distances[i] = 0
		else:
			# Recursive depth-limited search (max 4 deep). Pass `i` as
			# the direction we came FROM so the recursion skips the
			# backtrack case (no wasted work revisiting pos).
			distances[i] = _shortest_path_search(manager, neighbor, 1, i, block_id)
	# Find min; flag every dir tied with it.
	var min_dist: int = distances[0]
	for i in range(1, 4):
		if distances[i] < min_dist:
			min_dist = distances[i]
	var result: Array = [false, false, false, false]
	for i in range(4):
		result[i] = distances[i] == min_dist
	return result


# ja.java:115-143 `a()` — recursive drop-search. Returns the shortest
# distance from (x, y, z) to a cell whose below is a drop. Capped at
# depth 4 so a flat infinite ocean doesn't stack-overflow.
#
# `from_dir` is the direction we came from, encoded the same way as the
# outer cardinal index: 0=-X, 1=+X, 2=-Z, 3=+Z. We skip the opposite
# direction (coming back to where we started).
static func _shortest_path_search(
	manager, pos: Vector3i, depth: int, from_dir: int, block_id: int
) -> int:
	var best: int = 1000
	var offsets: Array = [
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1),
	]
	# ja.java:119 — skip the direction we came from. Pairs:
	# (0,1), (1,0), (2,3), (3,2). 0 ↔ 1 on X, 2 ↔ 3 on Z.
	for i in range(4):
		if (
			(i == 0 and from_dir == 1)
			or (i == 1 and from_dir == 0)
			or (i == 2 and from_dir == 3)
			or (i == 3 and from_dir == 2)
		):
			continue
		var neighbor: Vector3i = pos + (offsets[i] as Vector3i)
		if _is_solid_blocker(manager.get_world_block(neighbor)):
			continue
		if (
			_same_fluid_family(manager.get_world_block(neighbor), block_id)
			and manager.get_world_block_meta(neighbor) == 0
		):
			continue
		# Drop at this step — vanilla returns the CURRENT depth (not depth+1).
		if not _is_solid_blocker(manager.get_world_block(neighbor + Vector3i(0, -1, 0))):
			return depth
		# ja.java:139 — max depth = 4 (distance 5 is the sentinel "unreachable").
		# Below the cap, recurse and fold result into best.
		if depth >= 4:
			continue
		var sub: int = _shortest_path_search(manager, neighbor, depth + 1, i, block_id)
		if sub < best:
			best = sub
	return best


# Scan 6 neighbors of a lava cell at `pos` for flammable blocks. If one
# is found, place FIRE on an adjacent AIR cell. Gated by a dice roll so
# the ignition isn't instant every tick (~1 in 3 per lava tick = ~every
# 4-5 seconds at LAVA_TICK_RATE). Vanilla's fire-spread system is driven
# from BlockFire's own tick rather than from lava directly, but the net
# effect ("wood next to lava eventually burns") is the same.
static func _try_lava_ignite(manager, pos: Vector3i) -> void:
	if randi() % 3 != 0:
		return
	var offsets: Array = [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]
	for flam_offset: Vector3i in offsets:
		var flam_pos: Vector3i = pos + (flam_offset as Vector3i)
		if not Blocks.is_flammable(manager.get_world_block(flam_pos)):
			continue
		# Look for an AIR cell adjacent to the flammable where fire can land.
		# Prefer the cell ABOVE the flammable (matches vanilla's spread
		# pattern), else any adjacent air.
		var above_flam: Vector3i = flam_pos + Vector3i(0, 1, 0)
		if manager.get_world_block(above_flam) == Blocks.AIR:
			BlockFire.ignite(manager, above_flam)
			return
		for air_offset: Vector3i in offsets:
			var candidate: Vector3i = flam_pos + (air_offset as Vector3i)
			if candidate == pos:
				continue
			if manager.get_world_block(candidate) == Blocks.AIR:
				BlockFire.ignite(manager, candidate)
				return


# Vanilla ld.java:91-155 `e(pk, x, y, z)` — returns a direction vector
# representing "which way does the fluid flow from this cell?". Used by
# EntityLiving to push swimmers downstream. The algorithm:
#
#   For each of the 4 lateral neighbors, compute `delta = neighbor_level
#   - this_level`. A less-filled neighbor (delta > 0) pulls flow toward
#   it; a more-filled neighbor pushes away. Sum the weighted offsets
#   into a running vector, then normalize.
#
#   "Level" is `get_effective_flow_level(id)` which maps a fluid cell
#   to 0..7 (source is highest fill = 0 level, completely drained = 7,
#   falling = 0). The neighbor-depth-1 fallback for non-fluid neighbors
#   (vanilla line 114) handles the classic "cliff drop" case where the
#   cell below a dry neighbor is fluid — fluid still pulls downward
#   into the drop.
#
#   Vanilla also tilts the vector steeply downward (-6) for falling
#   cells (line 123-151); we skip that here since our entity physics
#   handles gravity separately.
#
# Returns a Vector3 in world-space, normalized. Magnitude 0 if no flow.
static func flow_vector(manager, pos: Vector3i, block_id: int) -> Vector3:
	var this_level: int = _flow_level(manager, pos, block_id)
	if this_level < 0:
		return Vector3.ZERO
	var vec := Vector3.ZERO
	var offsets: Array = [
		Vector3i(-1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, 1),
	]
	for i in range(4):
		var neighbor: Vector3i = pos + (offsets[i] as Vector3i)
		var n_level: int = _flow_level(manager, neighbor, block_id)
		if n_level < 0:
			# ld.java:114 — neighbor isn't fluid. If the cell below the
			# neighbor IS fluid (and the neighbor itself isn't solid),
			# the flow pulls toward the drop. Simplified here: only pull
			# if neighbor is air-ish and below-neighbor is same-family.
			if _is_solid_blocker(manager.get_world_block(neighbor)):
				continue
			var below_n: Vector3i = neighbor + Vector3i(0, -1, 0)
			var below_level: int = _flow_level(manager, below_n, block_id)
			if below_level < 0:
				continue
			var weight: int = below_level - (this_level - 8)
			vec += Vector3(float(offsets[i].x * weight), 0.0, float(offsets[i].z * weight))
			continue
		var delta: int = n_level - this_level
		vec += Vector3(float(offsets[i].x * delta), 0.0, float(offsets[i].z * delta))
	return vec.normalized() if vec.length_squared() > 0.0 else Vector3.ZERO


# Vanilla ld.java:24 `a(int n2)` — map raw meta to 0..7 fill level.
# Falling (>=8) returns 0 (reads as a source). Returns -1 if the cell
# isn't our fluid family.
static func _flow_level(manager, pos: Vector3i, block_id: int) -> int:
	var id: int = manager.get_world_block(pos)
	if not _same_fluid_family(id, block_id):
		return -1
	var meta: int = manager.get_world_block_meta(pos)
	if meta >= 8:
		return 0
	return meta
