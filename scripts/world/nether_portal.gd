class_name NetherPortal
extends RefCounted

# Alpha 1.2.6 Nether portal block — a port of `x.java`.
# See docs/nether-alpha-1.2.6-implementation-plan.md §7.1.
#
# The frame rule is the part people misremember, so it is worth stating
# exactly. The tested footprint is FOUR wide by FIVE tall, and the four
# outer corner cells are SKIPPED by the validator — they may be obsidian,
# air, or anything else, and it makes no difference:
#
#       .  #  #  .        . = corner, not tested
#       #  o  o  #        # = must be obsidian (10 of them)
#       #  o  o  #        o = interior, must be air or fire (2x3)
#       #  o  o  #
#       .  #  #  .
#
# Activation happens when fire is placed inside a valid frame. Removal is
# per-cell: each portal block re-validates itself when a neighbour
# changes and clears only ITSELF, so breaking one frame block dissolves
# the sheet cell by cell as the updates propagate. There is no flood
# fill, which is why breaking obsidian next to two adjacent portals never
# damages the other one.

# Obsidian is the frame material; fire is what lights it.
const _FRAME_BLOCK: int = Blocks.OBSIDIAN
const _INTERIOR_WIDTH: int = 2
const _INTERIOR_HEIGHT: int = 3

# x.java:20-25 — the visual slab is 0.125 either side of centre, so a
# quarter-block thick, oriented across the frame's axis.
const VISUAL_THICKNESS: float = 0.25

# x.java:129 — one in a hundred display ticks plays the ambient hum.
const AMBIENT_SOUND_CHANCE: int = 100
# x.java:133 — four particles per display tick, per cell.
const PARTICLES_PER_TICK: int = 4

# Axis constants. A portal sheet always lies along exactly one horizontal
# axis; `x.java` derives it from which neighbours are obsidian.
const AXIS_NONE: int = 0
const AXIS_X: int = 1
const AXIS_Z: int = 2


# Which horizontal axis a frame at this cell runs along, by looking for
# obsidian on either side. x.java:41-49: if BOTH axes report obsidian (or
# neither does), the frame is ambiguous and nothing is built.
static func frame_axis(world, pos: Vector3i) -> int:
	var along_x: bool = (
		world.get_world_block(pos + Vector3i(-1, 0, 0)) == _FRAME_BLOCK
		or world.get_world_block(pos + Vector3i(1, 0, 0)) == _FRAME_BLOCK
	)
	var along_z: bool = (
		world.get_world_block(pos + Vector3i(0, 0, -1)) == _FRAME_BLOCK
		or world.get_world_block(pos + Vector3i(0, 0, 1)) == _FRAME_BLOCK
	)
	if along_x == along_z:
		return AXIS_NONE
	return AXIS_X if along_x else AXIS_Z


# Axis of an EXISTING portal sheet, derived from adjacent portal cells
# rather than from the frame. x.java uses this for the visual orientation
# and the particle direction — the plan is explicit that no axis metadata
# is stored, so the save contract is unchanged.
static func portal_axis(world, pos: Vector3i) -> int:
	if (
		world.get_world_block(pos + Vector3i(-1, 0, 0)) == Blocks.PORTAL
		or world.get_world_block(pos + Vector3i(1, 0, 0)) == Blocks.PORTAL
	):
		return AXIS_X
	if (
		world.get_world_block(pos + Vector3i(0, 0, -1)) == Blocks.PORTAL
		or world.get_world_block(pos + Vector3i(0, 0, 1)) == Blocks.PORTAL
	):
		return AXIS_Z
	# A single isolated cell has no neighbour to derive from. x.java's
	# bounds code falls through to the Z-facing slab in that case.
	return AXIS_Z


# x.java:39-72 — validate a frame around `pos` and, if it holds, fill the
# 2x3 interior with portal blocks. Returns true when a portal was lit.
#
# `pos` is the cell fire was placed in; the validator first walks one step
# back along the axis if that cell is air, so lighting either interior
# column works.
static func try_create(world, pos: Vector3i) -> bool:
	var axis: int = frame_axis(world, pos)
	if axis == AXIS_NONE:
		return false
	var step: Vector3i = Vector3i(1, 0, 0) if axis == AXIS_X else Vector3i(0, 0, 1)
	var origin: Vector3i = pos
	# x.java:52-55 — normalise to the frame's first interior column, so
	# the loops below index from a known corner.
	if world.get_world_block(origin - step) == Blocks.AIR:
		origin -= step

	for along: int in range(-1, 3):
		for up: int in range(-1, 4):
			var is_frame_cell: bool = along == -1 or along == 2 or up == -1 or up == 3
			# x.java:60 — the four CORNERS are skipped entirely. Their
			# contents are irrelevant to activation.
			var is_corner: bool = (along == -1 or along == 2) and (up == -1 or up == 3)
			if is_corner:
				continue
			var cell: Vector3i = origin + step * along + Vector3i(0, up, 0)
			var id: int = world.get_world_block(cell)
			if is_frame_cell:
				if id != _FRAME_BLOCK:
					return false
			elif id != Blocks.AIR and id != Blocks.FIRE:
				return false

	var lit: Array[Vector3i] = []
	for along: int in range(_INTERIOR_WIDTH):
		for up: int in range(_INTERIOR_HEIGHT):
			var cell: Vector3i = origin + step * along + Vector3i(0, up, 0)
			world.set_world_block(cell, Blocks.PORTAL)
			lit.append(cell)
	# Recording here rather than at the callsite is deliberate: lighting a
	# portal is the only way one comes into existence by hand, so the index
	# cannot drift by someone forgetting to announce it. The index is a
	# hint only — see PortalIndex — so a wrong dimension would cost a
	# wasted chunk load, never a wrong destination.
	PortalIndex.record_sheet(DimensionContext.active(), lit)
	return true


# x.java:75-108 — a portal cell re-checks itself whenever a neighbour
# changes, and clears ONLY itself when the frame no longer holds.
#
# Per-cell removal rather than a flood fill is deliberate and observable:
# each cleared cell is itself a neighbour change for the next one, so the
# sheet dissolves outward from the break while an unrelated portal one
# block away is untouched.
static func on_neighbor_change(world, pos: Vector3i) -> void:
	if world.get_world_block(pos) != Blocks.PORTAL:
		return
	if not _still_valid(world, pos):
		world.set_world_block(pos, Blocks.AIR)
		PortalIndex.forget_at(DimensionContext.active(), pos)


static func _still_valid(world, pos: Vector3i) -> bool:
	var axis: int = portal_axis(world, pos)
	var step: Vector3i = Vector3i(1, 0, 0) if axis == AXIS_X else Vector3i(0, 0, 1)

	# x.java:84-87 — walk down to the bottom cell of this column.
	var bottom: Vector3i = pos
	while world.get_world_block(bottom + Vector3i(0, -1, 0)) == Blocks.PORTAL:
		bottom += Vector3i(0, -1, 0)
	# The cell under the column must be frame.
	if world.get_world_block(bottom + Vector3i(0, -1, 0)) != _FRAME_BLOCK:
		return false
	# x.java:92-96 — the column must be exactly three tall with frame above.
	var height: int = 1
	while height < 4 and world.get_world_block(bottom + Vector3i(0, height, 0)) == Blocks.PORTAL:
		height += 1
	if height != _INTERIOR_HEIGHT:
		return false
	if world.get_world_block(bottom + Vector3i(0, height, 0)) != _FRAME_BLOCK:
		return false
	# x.java:98-102 — a cell cannot belong to both orientations at once.
	var linked_x: bool = (
		world.get_world_block(pos + Vector3i(-1, 0, 0)) == Blocks.PORTAL
		or world.get_world_block(pos + Vector3i(1, 0, 0)) == Blocks.PORTAL
	)
	var linked_z: bool = (
		world.get_world_block(pos + Vector3i(0, 0, -1)) == Blocks.PORTAL
		or world.get_world_block(pos + Vector3i(0, 0, 1)) == Blocks.PORTAL
	)
	if linked_x and linked_z:
		return false
	# x.java:103-106 — ALONG the axis, one side is frame and the other is
	# the partner column. The sheet is two wide, so each column has
	# obsidian on its outer side and its partner on the inner one; either
	# arrangement is fine, and neither holding means an edge was lost.
	#
	# Along, not across: `n7`/`n8` in the source are the along-axis unit
	# vector, set from which neighbours are PORTAL. Testing the
	# perpendicular here passes the whole sheet through as invalid.
	var plus: int = world.get_world_block(pos + step)
	var minus: int = world.get_world_block(pos - step)
	return (
		(plus == _FRAME_BLOCK and minus == Blocks.PORTAL)
		or (minus == _FRAME_BLOCK and plus == Blocks.PORTAL)
	)


# Every portal cell connected to `pos` along its own sheet. Used by the
# teleporter to normalise an arrival to the bottom cell, and by tests.
static func sheet_cells(world, pos: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if world.get_world_block(pos) != Blocks.PORTAL:
		return out
	var axis: int = portal_axis(world, pos)
	var step: Vector3i = Vector3i(1, 0, 0) if axis == AXIS_X else Vector3i(0, 0, 1)
	var seen: Dictionary = {}
	var queue: Array[Vector3i] = [pos]
	while not queue.is_empty():
		var cell: Vector3i = queue.pop_back()
		if seen.has(cell):
			continue
		if world.get_world_block(cell) != Blocks.PORTAL:
			continue
		seen[cell] = true
		out.append(cell)
		for offset: Vector3i in [step, -step, Vector3i(0, 1, 0), Vector3i(0, -1, 0)]:
			if not seen.has(cell + offset):
				queue.append(cell + offset)
	return out


# no.java:36-38 — an arrival normalises DOWN to the bottom cell of its
# column before the player is placed, so two portals of different heights
# still put the player on the floor.
static func bottom_of_column(world, pos: Vector3i) -> Vector3i:
	var cell: Vector3i = pos
	while world.get_world_block(cell + Vector3i(0, -1, 0)) == Blocks.PORTAL:
		cell += Vector3i(0, -1, 0)
	return cell
