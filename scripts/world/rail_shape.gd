class_name RailShape
## Rail auto-orientation — a port of Alpha's `oc.java` (MinecartTrackLogic),
## kept in one place so it has exactly one implementation.
##
## Two callers need identical answers: placement (`interaction.gd`, which
## shapes a new rail against its neighbours) and redstone (`jn.java:89`,
## which re-runs the SAME logic on an ambiguous junction when a power
## source next to it changes).
##
## Vanilla shapes rails by LINKS, not by counting neighbours. Every shape
## points at two cells; a rail only joins a neighbour that can take the
## link (it points back already, or has a free end), and joining re-shapes
## that neighbour too. Two consequences the old count-based version got
## wrong, and which read in game as "rails go uphill for no reason":
##   * A slope is always the LOWER rail tilting up toward a rail one step
##     higher. The rail at the top stays flat — nothing ever ascends away
##     from a lower neighbour into empty air.
##   * A neighbour whose two ends are both linked is full. Laying a rail
##     beside the middle of a straight track leaves the track straight.
##
## Statics only, `manager`-first, mirroring `redstone.gd`. Nothing here
## touches the scene tree.

# Meta layout, vanilla `oc.java:26-59`:
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

# jn.java:60 stamps a newly placed rail with meta 15 before shaping it.
# No shape matches 15, so the new rail starts with no links: nothing can
# already be joined to a rail that has not been shaped yet.
const _UNSHAPED: int = 15

const _NORTH := Vector3i(0, 0, -1)
const _SOUTH := Vector3i(0, 0, 1)
const _WEST := Vector3i(-1, 0, 0)
const _EAST := Vector3i(1, 0, 0)
const _UP := Vector3i(0, 1, 0)
# "No rail found." Rails need a block under them, so none can sit at y=-1.
const _NONE := Vector3i(0, -1, 0)


# Shape the rail at `pos`, write its meta, then join it onto every rail
# its new shape points at that will take the link — oc.java:203-290,
# `a(boolean)`, which is what jn.java runs when a rail is placed (`e()`)
# and when an ambiguous junction's power changes (`h()`). Returns the
# rail's new meta.
#
# `fresh` marks a placement: the cell is treated as an unshaped rail
# (meta 15, no links) whether or not the caller has written it yet, and
# the final write puts the rail there.
#
# `isolated_meta` is the shape for a rail no neighbour will link to.
# Alpha always lays those N/S (oc.java:278); placement passes the axis
# the player faces instead, so a lone rail runs where it was aimed.
static func update(
	manager, pos: Vector3i, powered: bool, isolated_meta: int, fresh: bool = false
) -> int:
	var meta: int = compute(manager, pos, powered, isolated_meta, fresh)
	manager.set_world_block_state(pos, Blocks.RAIL, meta)
	# oc.java:284-290 — offer the link to each rail the new shape points
	# at. A neighbour that is already full keeps its shape.
	var no_overrides: Dictionary = {}
	for link: Vector3i in links(pos, meta):
		var other: Vector3i = _rail_near(manager, link, no_overrides)
		if other == _NONE:
			continue
		var other_links: Array[Vector3i] = _live_links(manager, other, no_overrides)
		if _can_accept(other_links, pos):
			_join(manager, other, other_links, pos)
	return meta


# The meta `update` would give the rail at `pos`, without writing
# anything — oc.java:203-280. Exposed so the tie-break can be tested
# against a layout on its own.
static func compute(
	manager, pos: Vector3i, powered: bool, isolated_meta: int, fresh: bool = false
) -> int:
	var overrides: Dictionary = {}
	if fresh:
		overrides[pos] = _UNSHAPED
	var n: bool = _neighbour_accepts(manager, pos, pos + _NORTH, overrides)
	var s: bool = _neighbour_accepts(manager, pos, pos + _SOUTH, overrides)
	var w: bool = _neighbour_accepts(manager, pos, pos + _WEST, overrides)
	var e: bool = _neighbour_accepts(manager, pos, pos + _EAST, overrides)
	var meta: int = -1
	if (n or s) and not w and not e:
		meta = STRAIGHT_NS
	if (w or e) and not n and not s:
		meta = STRAIGHT_EW
	if s and e and not n and not w:
		meta = CURVE_SE
	if s and w and not n and not e:
		meta = CURVE_SW
	if n and w and not s and not e:
		meta = CURVE_NW
	if n and e and not s and not w:
		meta = CURVE_NE
	if meta == -1:
		# Three or more links (every such set contains a corner, so this
		# always lands on a curve) — or none at all.
		meta = ambiguous_meta(n, s, e, w, powered)
	if meta == -1:
		return isolated_meta
	return _ramp(manager, pos, meta, overrides)


# How many of the four sides have a rail at this height or one step up or
# down — oc.java:113-128 `c()`, the count jn.java:89 tests for exactly 3.
static func connection_count(manager, pos: Vector3i) -> int:
	var total: int = 0
	var no_overrides: Dictionary = {}
	for side: Vector3i in [_NORTH, _SOUTH, _WEST, _EAST]:
		if _rail_near(manager, pos + side, no_overrides) != _NONE:
			total += 1
	return total


# Junction shape for a rail with 3+ links — the ambiguous branch of
# oc.java:227-260. Straights are assigned first (E/W overriding N/S),
# then the four curve tests run; because each test simply overwrites the
# result, running them in REVERSE order flips which curve wins. Vanilla
# uses that ordering difference, and nothing else, as its powered /
# unpowered tie-break. -1 when there are no links at all.
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


# The two cells a rail of shape `meta` at `pos` points at — oc.java:26-59.
# A ramp's high end points one step up. Any other meta (the unshaped 15)
# points nowhere.
static func links(pos: Vector3i, meta: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	match meta:
		STRAIGHT_NS:
			out = [pos + _NORTH, pos + _SOUTH]
		STRAIGHT_EW:
			out = [pos + _WEST, pos + _EAST]
		ASCEND_EAST:
			out = [pos + _WEST, pos + _EAST + _UP]
		ASCEND_WEST:
			out = [pos + _WEST + _UP, pos + _EAST]
		ASCEND_NORTH:
			out = [pos + _NORTH + _UP, pos + _SOUTH]
		ASCEND_SOUTH:
			out = [pos + _NORTH, pos + _SOUTH + _UP]
		CURVE_SE:
			out = [pos + _EAST, pos + _SOUTH]
		CURVE_SW:
			out = [pos + _WEST, pos + _SOUTH]
		CURVE_NW:
			out = [pos + _WEST, pos + _NORTH]
		CURVE_NE:
			out = [pos + _EAST, pos + _NORTH]
	return out


# oc.java:194-201 `c(int,int,int)` — whether the rail serving `cell`, if
# there is one, would link to the rail at `pos`.
static func _neighbour_accepts(
	manager, pos: Vector3i, cell: Vector3i, overrides: Dictionary
) -> bool:
	var other: Vector3i = _rail_near(manager, cell, overrides)
	if other == _NONE:
		return false
	return _can_accept(_live_links(manager, other, overrides), pos)


# The rail at `pos`'s links that are returned: each must lead to a rail
# whose own shape points back — oc.java:61-70 `b()`. Entries become the
# partner's actual cell, which may be a step above or below the nominal
# link. A link aimed at an unshaped rail is dropped here, which is what
# lets a neighbour pointing at a fresh rail's cell still take it.
static func _live_links(manager, pos: Vector3i, overrides: Dictionary) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for link: Vector3i in links(pos, _meta_at(manager, pos, overrides)):
		var partner: Vector3i = _rail_near(manager, link, overrides)
		if partner == _NONE:
			continue
		if not _points_at(links(partner, _meta_at(manager, partner, overrides)), pos):
			continue
		out.append(partner)
	return out


# oc.java:130-145 `c(oc)` — a rail takes a link to `other` if it already
# has it, or if it has a free end.
static func _can_accept(rail_links: Array[Vector3i], other: Vector3i) -> bool:
	return _points_at(rail_links, other) or rail_links.size() < 2


# Add a link to `other` onto the rail at `pos` and re-shape it from its
# links — oc.java:147-192 `d(oc)`. This is how laying a rail turns its
# neighbour into a curve, or tilts it into a ramp up to the new rail.
static func _join(manager, pos: Vector3i, rail_links: Array[Vector3i], other: Vector3i) -> void:
	var joined: Array[Vector3i] = rail_links.duplicate()
	joined.append(other)
	var n: bool = _points_at(joined, pos + _NORTH)
	var s: bool = _points_at(joined, pos + _SOUTH)
	var w: bool = _points_at(joined, pos + _WEST)
	var e: bool = _points_at(joined, pos + _EAST)
	var meta: int = -1
	if n or s:
		meta = STRAIGHT_NS
	if w or e:
		meta = STRAIGHT_EW
	if s and e and not n and not w:
		meta = CURVE_SE
	if s and w and not n and not e:
		meta = CURVE_SW
	if n and w and not s and not e:
		meta = CURVE_NW
	if n and e and not s and not w:
		meta = CURVE_NE
	if meta == -1:
		meta = STRAIGHT_NS
	manager.set_world_block_state(pos, Blocks.RAIL, _ramp(manager, pos, meta, {}))


# A straight with a rail one step up beyond either end becomes the ramp
# toward it — oc.java:172-187 / 262-277. Only ever UP: a slope is the
# lower rail tilting to meet the higher one. Where both ends have one,
# the later test (south / west) wins, as in vanilla.
static func _ramp(manager, pos: Vector3i, meta: int, overrides: Dictionary) -> int:
	if meta == STRAIGHT_NS:
		if _is_rail(manager, pos + _NORTH + _UP, overrides):
			meta = ASCEND_NORTH
		if _is_rail(manager, pos + _SOUTH + _UP, overrides):
			meta = ASCEND_SOUTH
	elif meta == STRAIGHT_EW:
		if _is_rail(manager, pos + _EAST + _UP, overrides):
			meta = ASCEND_EAST
		if _is_rail(manager, pos + _WEST + _UP, overrides):
			meta = ASCEND_WEST
	return meta


# The rail serving horizontal cell `cell`: a rail in the cell itself, else
# one a step up, else one a step down — oc.java:82-93 `a(on)`. Rails link
# across a one-block height change; that is how a ramp meets the flat.
static func _rail_near(manager, cell: Vector3i, overrides: Dictionary) -> Vector3i:
	if _is_rail(manager, cell, overrides):
		return cell
	if _is_rail(manager, cell + _UP, overrides):
		return cell + _UP
	if _is_rail(manager, cell - _UP, overrides):
		return cell - _UP
	return _NONE


# oc.java:95-102 `b(oc)` — whether any link is aimed at `target`'s
# column. X/Z only: the link is satisfied by whichever rail in that
# column `_rail_near` finds.
static func _points_at(rail_links: Array[Vector3i], target: Vector3i) -> bool:
	for link: Vector3i in rail_links:
		if link.x == target.x and link.z == target.z:
			return true
	return false


static func _is_rail(manager, cell: Vector3i, overrides: Dictionary) -> bool:
	return overrides.has(cell) or manager.get_world_block(cell) == Blocks.RAIL


static func _meta_at(manager, cell: Vector3i, overrides: Dictionary) -> int:
	if overrides.has(cell):
		return overrides[cell]
	return manager.get_world_block_meta(cell)
