class_name LeafDecay
extends RefCounted

# Alpha-style leaf decay: when a log is broken, any LEAVES block within a
# small cube around it that can no longer reach a LOG via a flood-fill of
# at most DECAY_RADIUS steps through adjacent LEAVES is orphaned and
# should decay to AIR. Vanilla does this as a random-tick effect with a
# "decayable" metadata bit; we don't have per-block metadata or random
# ticks yet, so we trigger it event-driven from ChunkManager.set_world_block
# whenever the removed block was a LOG.
#
# This is a pure utility: it takes a `get_block` Callable so tests can
# stub out a synthetic world without instantiating a real ChunkManager.

const DECAY_RADIUS: int = 4  # max BFS steps through leaves before orphaning
const SCAN_RADIUS: int = DECAY_RADIUS + 1  # cube around the broken log

const _NEIGHBORS: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]


# Returns world positions of leaves that cannot reach any LOG within
# DECAY_RADIUS BFS steps through LEAVES. Intended to be called right after
# the log at `center` has already been removed from the world — the
# get_block callable should reflect post-removal state.
static func find_orphan_leaves(get_block: Callable, center: Vector3i) -> Array[Vector3i]:
	var orphans: Array[Vector3i] = []
	for dx in range(-SCAN_RADIUS, SCAN_RADIUS + 1):
		for dy in range(-SCAN_RADIUS, SCAN_RADIUS + 1):
			for dz in range(-SCAN_RADIUS, SCAN_RADIUS + 1):
				var p := center + Vector3i(dx, dy, dz)
				if get_block.call(p) != Blocks.LEAVES:
					continue
				if not _reaches_log(get_block, p):
					orphans.append(p)
	return orphans


# BFS from `start` through LEAVES, looking for a LOG within DECAY_RADIUS
# steps. Returns true as soon as any LOG neighbor is found.
static func _reaches_log(get_block: Callable, start: Vector3i) -> bool:
	var visited: Dictionary = {start: true}
	var queue: Array = [{"pos": start, "dist": 0}]
	while not queue.is_empty():
		var entry: Dictionary = queue.pop_front()
		var pos: Vector3i = entry.pos
		var dist: int = entry.dist
		for d: Vector3i in _NEIGHBORS:
			var np: Vector3i = pos + d
			if visited.has(np):
				continue
			var b: int = get_block.call(np)
			if b == Blocks.LOG:
				return true
			# Only hop through leaves, and only if we have budget for the
			# next step to still be ≤ DECAY_RADIUS from the start.
			if b == Blocks.LEAVES and dist + 1 < DECAY_RADIUS:
				visited[np] = true
				queue.append({"pos": np, "dist": dist + 1})
	return false
