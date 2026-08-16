class_name RailShape
## Rail auto-orientation — the shape half of Alpha's `oc.java`
## (MinecartTrackLogic), extracted so it has exactly one implementation.
##
## Two callers need identical answers and used to be unable to share one:
## placement (`interaction.gd`, which auto-orients a rail against its
## neighbours) and redstone (`jn.java:89`, which re-runs the SAME
## computation on an ambiguous junction when a power source next to it
## changes). Keeping the logic in an Interaction instance method meant
## the redstone path could not reach it and the tie-break could not be
## unit-tested without a scene tree.
##
## Statics only, `manager`-first, mirroring `redstone.gd`. Nothing here
## touches the scene tree.

# Meta layout, vanilla `oc.java`:
#   0 = straight N/S      1 = straight E/W
#   2 = ascending east    3 = ascending west
#   4 = ascending north   5 = ascending south
#   6 = curve S+E         7 = curve S+W
#   8 = curve N+W         9 = curve N+E
const STRAIGHT_NS: int = 0
const STRAIGHT_EW: int = 1
const ASCEND_EAST: int = 2
const ASCEND_WEST: int = 3
const ASCEND_NORTH: int = 4
const ASCEND_SOUTH: int = 5
const CURVE_SE: int = 6
const CURVE_SW: int = 7
const CURVE_NW: int = 8
const CURVE_NE: int = 9


# How many of the four same-Y horizontal neighbours are rails.
# `oc.c()` — the count `jn.java:89` tests for exactly 3.
static func connection_count(manager, pos: Vector3i) -> int:
	var total: int = 0
	for offset: Vector3i in [
		Vector3i(0, 0, -1), Vector3i(0, 0, 1), Vector3i(1, 0, 0), Vector3i(-1, 0, 0)
	]:
		if manager.get_world_block(pos + offset) == Blocks.RAIL:
			total += 1
	return total


# Pick the rail meta (0..9) for the rail at `pos` from its surroundings.
# Mirrors vanilla's priority order:
#   0. Three or more connections → the ambiguous tie-break (uses `powered`)
#   1. Two opposite same-Y neighbours → straight aligned with them
#   2. Two perpendicular same-Y neighbours → curve wrapping their corner
#   3. One same-Y neighbour → straight aligned with that neighbour
#   4. Higher/lower-Y-only neighbours → ascending toward / away from them
#   5. Nothing at all → `isolated_meta`
#
# `isolated_meta` is the caller's fallback for a rail with no neighbours:
# placement passes the player's facing axis, the redstone path passes the
# rail's current meta (a junction always has neighbours, so it is never
# actually reached from there).
static func compute(manager, pos: Vector3i, powered: bool, isolated_meta: int) -> int:
	var n: bool = manager.get_world_block(pos + Vector3i(0, 0, -1)) == Blocks.RAIL
	var s: bool = manager.get_world_block(pos + Vector3i(0, 0, 1)) == Blocks.RAIL
	var e: bool = manager.get_world_block(pos + Vector3i(1, 0, 0)) == Blocks.RAIL
	var w: bool = manager.get_world_block(pos + Vector3i(-1, 0, 0)) == Blocks.RAIL
	var n_up: bool = manager.get_world_block(pos + Vector3i(0, 1, -1)) == Blocks.RAIL
	var s_up: bool = manager.get_world_block(pos + Vector3i(0, 1, 1)) == Blocks.RAIL
	var e_up: bool = manager.get_world_block(pos + Vector3i(1, 1, 0)) == Blocks.RAIL
	var w_up: bool = manager.get_world_block(pos + Vector3i(-1, 1, 0)) == Blocks.RAIL
	# Lower-Y horizontal neighbours — required for chained ramps. Vanilla
	# checks both above AND below. Without these, a rail placed on top of
	# a step couldn't auto-orient as ramping down to the rail at the
	# lower step, so chained staircases broke unless every other rail was
	# flat.
	var n_down: bool = manager.get_world_block(pos + Vector3i(0, -1, -1)) == Blocks.RAIL
	var s_down: bool = manager.get_world_block(pos + Vector3i(0, -1, 1)) == Blocks.RAIL
	var e_down: bool = manager.get_world_block(pos + Vector3i(1, -1, 0)) == Blocks.RAIL
	var w_down: bool = manager.get_world_block(pos + Vector3i(-1, -1, 0)) == Blocks.RAIL
	# (0) Three or more connections is genuinely ambiguous, and it's the
	# one place Alpha consults redstone.
	if int(n) + int(s) + int(e) + int(w) >= 3:
		var ambiguous: int = ambiguous_meta(n, s, e, w, powered)
		if ambiguous == STRAIGHT_NS:
			return _ascending_along_z(n_up, s_up)
		if ambiguous == STRAIGHT_EW:
			return _ascending_along_x(e_up, w_up)
		return ambiguous
	# (1) Two-opposite straight beats everything — even if there's also a
	# perpendicular neighbour (vanilla picks the straight in that case and
	# the perpendicular rail will adjust on its own re-evaluation).
	if n and s:
		return _ascending_along_z(n_up, s_up)
	if e and w:
		return _ascending_along_x(e_up, w_up)
	# (2) Curves — exactly 2 perpendicular neighbours, no opposite pair.
	if n and e:
		return CURVE_NE
	if n and w:
		return CURVE_NW
	if s and e:
		return CURVE_SE
	if s and w:
		return CURVE_SW
	# (3) Single same-Y neighbour → straight aligned with it. Also
	# considers higher-Y neighbours to make a ramp.
	if n or s:
		return _ascending_along_z(n_up, s_up)
	if e or w:
		return _ascending_along_x(e_up, w_up)
	# (4) Higher-Y-only neighbours → ascending toward them.
	if e_up:
		return ASCEND_EAST
	if w_up:
		return ASCEND_WEST
	if n_up:
		return ASCEND_NORTH
	if s_up:
		return ASCEND_SOUTH
	# (4b) Lower-Y-only neighbours → ascending AWAY from them (i.e. the
	# OPPOSITE side of this rail is the high end, the side facing the
	# lower neighbour is the low end). e_down (rail one step east-and-
	# down) means this rail should descend east = ascend west.
	if e_down:
		return ASCEND_WEST
	if w_down:
		return ASCEND_EAST
	if n_down:
		return ASCEND_SOUTH
	if s_down:
		return ASCEND_NORTH
	# (5) Isolated rail → caller's fallback.
	return isolated_meta


# Junction shape for a rail with 3+ connections — the ambiguous branch of
# oc.java:227-260. Straights are assigned first (E/W overriding N/S),
# then the four curve tests run; because each test simply overwrites the
# result, running them in REVERSE order flips which curve wins. Vanilla
# uses that ordering difference, and nothing else, as its powered /
# unpowered tie-break.
static func ambiguous_meta(n: bool, s: bool, e: bool, w: bool, powered: bool) -> int:
	var meta: int = -1
	if n or s:
		meta = STRAIGHT_NS
	if w or e:
		meta = STRAIGHT_EW
	if powered:
		if s and e:
			meta = CURVE_SE
		if w and s:
			meta = CURVE_SW
		if e and n:
			meta = CURVE_NE
		if n and w:
			meta = CURVE_NW
	else:
		if n and w:
			meta = CURVE_NW
		if e and n:
			meta = CURVE_NE
		if w and s:
			meta = CURVE_SW
		if s and e:
			meta = CURVE_SE
	return meta


# A rail straight along Z, flipped to the matching ascending meta when
# one of the Z neighbours is a step higher.
static func _ascending_along_z(n_up: bool, s_up: bool) -> int:
	if n_up:
		return ASCEND_NORTH
	if s_up:
		return ASCEND_SOUTH
	return STRAIGHT_NS


# Same but for the X axis.
static func _ascending_along_x(e_up: bool, w_up: bool) -> int:
	if e_up:
		return ASCEND_EAST
	if w_up:
		return ASCEND_WEST
	return STRAIGHT_EW
