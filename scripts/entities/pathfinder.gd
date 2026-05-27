class_name Pathfinder
extends RefCounted

# A* pathfinder over the voxel grid for 1-cell-tall ground mobs (pig,
# chicken, sheep, future cow). Returns the sequence of cells the mob
# walks through to get from `start` to `goal`, EXCLUDING the start
# cell — so `result[0]` is the first cell to step into, `result[-1]`
# is the goal. Returns an empty Array when no path exists within
# `max_dist` cumulative cost or `max_iters` search iterations.
#
# Algorithmic port of vanilla `bt.findPath` (PathFinder):
#   * 8-way XZ moves
#   * 1-block step up / step down for slope traversal
#   * Euclidean heuristic (admissible → A* optimal)
#   * Per-step cost: 1.0 straight, ~1.414 diagonal, +0.5 for vertical
#
# Performance notes:
#   * Open set is a plain Array<[f_score, cell]>; linear-scan pop of the
#     minimum f. With max_iters=200 + bounded branching, the open set
#     stays small (<100 entries), so the scan is faster than maintaining
#     a heap structure in GDScript.
#   * `_is_walkable` does at most 2 chunk lookups per cell. With ~24
#     neighbor evals per iter × 200 iters worst-case = 4800 cell
#     lookups per call. At ~1.5 paths/sec across the mob cap, that's
#     ~7k lookups/sec — negligible (~0.7ms total on a modern CPU).
#   * Closed-set tracking via `g_score` Dictionary lookups (O(1)
#     hashed) means a single visited cell never re-expands.
#
# Caller contract: `cm` is a Node exposing `get_world_block(Vector3i)`
# returning a Blocks ID (matches ChunkManager + Worldgen interfaces).

# Step cost constants — vanilla uses uniform 1.0 + path-finder-specific
# penalties for swim/lava; we keep the geometric distances and ignore
# penalties (terrain weighting can land later if mobs start drowning
# in water trying to take a shortcut).
const _STRAIGHT_COST: float = 1.0
const _DIAGONAL_COST: float = 1.4142136  # sqrt(2)
const _VERTICAL_BONUS: float = 0.5  # added to step-up / step-down moves

# 8-way XZ neighbor offsets (no Y component — Y handled per offset in
# the dy loop inside the main expansion). Diagonals listed AFTER
# cardinals so equal-cost ties prefer straight moves (lower index
# wins linear-scan in the open set when f scores match exactly).
const _NEIGHBOR_DELTAS: Array = [
	Vector3i(-1, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(0, 0, -1),
	Vector3i(0, 0, 1),
	Vector3i(-1, 0, -1),
	Vector3i(1, 0, -1),
	Vector3i(-1, 0, 1),
	Vector3i(1, 0, 1),
]

# Set by Game._ready() after the GDExtension loads. When non-null,
# find_path() dispatches to the C++ PathfinderNative — ~10× faster than
# the GDScript reference. Same lazy-instantiation pattern as Lighting.
static var _native: RefCounted
# 256-entry solid-collision LUT handed to PathfinderNative on every call.
# Identical to VoxelCollider's; cached lazily.
static var _native_solid_lut: PackedByteArray


static func enable_native() -> bool:
	if _native != null:
		return true
	if not ClassDB.class_exists("PathfinderNative"):
		push_warning("Pathfinder.enable_native: PathfinderNative class not in ClassDB")
		return false
	_native = ClassDB.instantiate("PathfinderNative")
	return _native != null


static func _solid_lut_for_native() -> PackedByteArray:
	if _native_solid_lut.is_empty():
		_native_solid_lut = PackedByteArray()
		_native_solid_lut.resize(256)
		for i in range(256):
			_native_solid_lut[i] = 1 if Blocks.is_solid_collision(i) else 0
	return _native_solid_lut


# Gather chunks the A* search might touch. Use a generous box around the
# bounding rect of start+goal expanded by max_dist on each side, since A*
# can wander outside the direct line. Caller pays one chunk-dict lookup
# per chunk in the box (typically 1-4) plus a small Array build.
static func _gather_chunks_for_native(
	cm: Node, start: Vector3i, goal: Vector3i, max_dist: float
) -> Array:
	var pad: int = int(ceil(max_dist))
	var min_x: int = mini(start.x, goal.x) - pad
	var max_x: int = maxi(start.x, goal.x) + pad
	var min_z: int = mini(start.z, goal.z) - pad
	var max_z: int = maxi(start.z, goal.z) + pad
	var min_cx: int = int(floor(float(min_x) / float(Chunk.SIZE_X)))
	var max_cx: int = int(floor(float(max_x) / float(Chunk.SIZE_X)))
	var min_cz: int = int(floor(float(min_z) / float(Chunk.SIZE_Z)))
	var max_cz: int = int(floor(float(max_z) / float(Chunk.SIZE_Z)))
	var out: Array = []
	for cx in range(min_cx, max_cx + 1):
		for cz in range(min_cz, max_cz + 1):
			# Untyped so test stubs (FakeChunk) don't trip Chunk coercion.
			var chunk = cm.get_chunk_at_coord(Vector2i(cx, cz))
			if chunk == null:
				continue
			out.append([cx, cz, chunk.blocks])
	return out


# Run A* from `start` to `goal`. Returns the path EXCLUDING start
# (callers walk straight from current position to result[0]).
# Empty Array → unreachable within budget. Single-cell case
# (start == goal) returns empty (already there, nothing to walk).
static func find_path(
	cm: Node, start: Vector3i, goal: Vector3i, max_dist: float = 16.0, max_iters: int = 200
) -> Array:
	if start == goal:
		return []
	if _native != null:
		var chunk_data: Array = _gather_chunks_for_native(cm, start, goal, max_dist)
		return _native.find_path(
			start, goal, max_dist, max_iters, chunk_data, _solid_lut_for_native()
		)
	# Open set: Array of [f_score, position]. Closed set tracked
	# implicitly via g_score (any cell in g_score with current_g
	# >= stored is "closed" — we just skip re-expansion).
	var open_set: Array = []
	var came_from: Dictionary = {}
	var g_score: Dictionary = {start: 0.0}
	open_set.append([_heuristic(start, goal), start])
	var iters: int = 0
	while not open_set.is_empty() and iters < max_iters:
		iters += 1
		# Linear-scan pop of the lowest f. Open set stays small
		# (<100) so this is cheap.
		var min_idx: int = 0
		var min_f: float = open_set[0][0]
		for i in range(1, open_set.size()):
			if open_set[i][0] < min_f:
				min_idx = i
				min_f = open_set[i][0]
		var current_entry: Array = open_set[min_idx]
		var current: Vector3i = current_entry[1]
		open_set.remove_at(min_idx)
		if current == goal:
			return _reconstruct_path(came_from, current)
		var current_g: float = g_score[current]
		for delta in _NEIGHBOR_DELTAS:
			# For each XZ direction, try same level → step up →
			# step down. Only ONE can be walkable per direction
			# (same-level passable AND step-up walkable would
			# require the same cell to be both AIR and OPAQUE), so
			# the first-hit `break` doesn't miss alternatives.
			for dy in [0, 1, -1]:
				var neighbor: Vector3i = current + Vector3i(delta.x, dy, delta.z)
				if not _is_walkable(cm, neighbor):
					continue
				var diagonal: bool = delta.x != 0 and delta.z != 0
				var step_cost: float = _DIAGONAL_COST if diagonal else _STRAIGHT_COST
				if dy != 0:
					step_cost += _VERTICAL_BONUS
				var tentative_g: float = current_g + step_cost
				if tentative_g > max_dist:
					break
				if not g_score.has(neighbor) or tentative_g < g_score[neighbor]:
					came_from[neighbor] = current
					g_score[neighbor] = tentative_g
					open_set.append([tentative_g + _heuristic(neighbor, goal), neighbor])
				break  # one valid dy per direction; see comment above
	return []


static func _heuristic(a: Vector3i, b: Vector3i) -> float:
	var dx: float = float(a.x - b.x)
	var dy: float = float(a.y - b.y)
	var dz: float = float(a.z - b.z)
	return sqrt(dx * dx + dy * dy + dz * dz)


# A cell is walkable for a 1-tall mob if:
#   * the cell itself is passable (not opaque — AIR, snow_layer, etc.)
#   * the cell BELOW is opaque (a real floor)
# 2-cell mobs (zombie, player) need an additional head-clearance check
# above; deferred until those mobs land.
# Public — exposed so the wander-target picker in pig.gd can prefilter
# samples (skip unreachable goals before scoring).
static func is_walkable(cm: Node, pos: Vector3i) -> bool:
	if _native != null:
		# Tiny gather — single cell needs at most the chunk containing
		# the cell and the chunk containing the floor cell directly below.
		var chunk_data: Array = _gather_chunks_for_native(cm, pos, pos, 1.0)
		return _native.is_walkable(pos, chunk_data, _solid_lut_for_native())
	return _is_walkable(cm, pos)


static func _is_walkable(cm: Node, pos: Vector3i) -> bool:
	# Use `is_solid_collision` rather than `is_opaque` for both gates so
	# physically-solid-but-non-opaque blocks (CHEST, MOB_SPAWNER,
	# LEAVES, GLASS) are handled correctly. Without this, the cell ABOVE
	# a chest is rejected as floor (vanilla mobs CAN step onto chests —
	# player safespot by standing on a chest), and mobs would also try
	# to walk THROUGH chests / spawner cages because the cell here was
	# classified as passable.
	var here_id: int = cm.get_world_block(pos)
	if Blocks.is_solid_collision(here_id):
		return false
	var floor_id: int = cm.get_world_block(pos + Vector3i(0, -1, 0))
	return Blocks.is_solid_collision(floor_id)


# Walk the came_from chain back from `end` to the start. Result is
# in walk order (start-adjacent first, goal last) and EXCLUDES start
# itself — the mob is already there.
static func _reconstruct_path(came_from: Dictionary, end: Vector3i) -> Array:
	var path: Array = [end]
	var current: Vector3i = end
	while came_from.has(current):
		current = came_from[current]
		path.push_front(current)
	# Strip start (path[0]) — caller walks from current position to
	# path[0] which would be a no-op step otherwise.
	path.pop_front()
	return path
