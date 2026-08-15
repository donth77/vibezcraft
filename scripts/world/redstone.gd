class_name Redstone
## Alpha 1.2.6 redstone power model.
##
## Port of the four World-level power queries in
## `vendor/alpha-1.2.6-src/src/cy.java:1589-1644`, plus the per-block
## weak/strong power rules from the component classes. See
## `.claude/redstone-plan.md` §2 for the full derivation.
##
## Alpha's model is a two-tier BOOLEAN system — only wire carries a
## 0-15 level, and it carries it in its own metadata. Everything else
## answers yes/no to "are you powering this neighbour slot?".
##
## Statics only, `manager`-first, mirroring `block_fluids.gd`. Nothing
## here touches the scene tree, so the whole model is testable against a
## fake world.

# Neighbour slot ids. `slot` identifies WHICH of the six neighbours the
# queried block occupies relative to the cell doing the asking, matching
# the argument order in cy.java's n()/o() fanouts and the clicked-face
# index used by placement (ob.java:44-59).
const SLOT_BELOW: int = 0
const SLOT_ABOVE: int = 1
const SLOT_NORTH: int = 2  # neighbour at z-1
const SLOT_SOUTH: int = 3  # neighbour at z+1
const SLOT_WEST: int = 4  # neighbour at x-1
const SLOT_EAST: int = 5  # neighbour at x+1

# slot → offset from the asking cell to that neighbour.
const SLOT_OFFSETS: Array[Vector3i] = [
	Vector3i(0, -1, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, 0, -1),
	Vector3i(0, 0, 1),
	Vector3i(-1, 0, 0),
	Vector3i(1, 0, 0),
]

# Mount-orientation metadata shared by torch (ob.java), lever (pl.java)
# and button (iy.java): 1-4 = the four walls, 5 = floor, 6 = the second
# floor rotation levers get. Values are the low 3 bits; bit 3 (0x8) is
# the on/pressed flag for lever + button.
const MOUNT_WEST_WALL: int = 1  # attached to the block at x-1
const MOUNT_EAST_WALL: int = 2  # attached to the block at x+1
const MOUNT_NORTH_WALL: int = 3  # attached to the block at z-1
const MOUNT_SOUTH_WALL: int = 4  # attached to the block at z+1
const MOUNT_FLOOR: int = 5
const MOUNT_FLOOR_ALT: int = 6
const POWERED_BIT: int = 8

# Which slot a mounted component strong-powers: the block it is
# attached to, seen from that block's point of view. A floor-mounted
# lever (mount 5) sits ABOVE its support, so from the support's
# perspective the lever occupies slot 1.
const _MOUNT_TO_STRONG_SLOT: Dictionary = {
	MOUNT_WEST_WALL: SLOT_EAST,
	MOUNT_EAST_WALL: SLOT_WEST,
	MOUNT_NORTH_WALL: SLOT_SOUTH,
	MOUNT_SOUTH_WALL: SLOT_NORTH,
	MOUNT_FLOOR: SLOT_ABOVE,
	MOUNT_FLOOR_ALT: SLOT_ABOVE,
}


# True for blocks that can act as a redstone source — vanilla
# `Block.e()` / `isPowerSource`. Wire is included: `lu.java:e()` returns
# its guard flag, which is true outside a wire recomputation.
static func is_power_source(id: int) -> bool:
	return id == Blocks.LEVER


# Offset from a mounted component to the block it is attached to.
static func mount_offset(meta: int) -> Vector3i:
	match meta & 0x7:
		MOUNT_WEST_WALL:
			return Vector3i(-1, 0, 0)
		MOUNT_EAST_WALL:
			return Vector3i(1, 0, 0)
		MOUNT_NORTH_WALL:
			return Vector3i(0, 0, -1)
		MOUNT_SOUTH_WALL:
			return Vector3i(0, 0, 1)
	return Vector3i(0, -1, 0)


# --- Per-block power rules ---------------------------------------------
#
# WEAK power (`Block.c(IBlockAccess, …)`) is what a component offers to
# any adjacent cell — this is what wire reads.
# STRONG power (`Block.c(World, …)`) is what it pushes INTO the block it
# is mounted on, which then relays to that block's other neighbours.


# `_slot` is this block's position relative to the asker (see SLOT_*).
# Unused for the lever (an on lever powers every direction) but part of
# the signature because wire's weak rule IS directional — §3.2.4 lands
# in Phase 8c.
static func provides_weak_power(manager, pos: Vector3i, _slot: int) -> bool:
	var id: int = manager.get_world_block(pos)
	match id:
		Blocks.LEVER:
			# pl.java:181 — an on lever weakly powers every direction.
			return (manager.get_world_block_meta(pos) & POWERED_BIT) > 0
	return false


# Vanilla cy.j / isBlockProvidingPowerTo.
static func provides_strong_power(manager, pos: Vector3i, slot: int) -> bool:
	var id: int = manager.get_world_block(pos)
	match id:
		Blocks.LEVER:
			# pl.java:185 — only into the block it is mounted on.
			var meta: int = manager.get_world_block_meta(pos)
			if (meta & POWERED_BIT) == 0:
				return false
			return _MOUNT_TO_STRONG_SLOT.get(meta & 0x7, SLOT_ABOVE) == slot
	return false


# --- The four World queries (cy.java:1589-1644) -------------------------


# cy.n — is this cell strong-powered by any of its six neighbours? This
# is what turns an ordinary solid block into a relay.
static func is_block_powered(manager, pos: Vector3i) -> bool:
	for slot in range(6):
		if provides_strong_power(manager, pos + SLOT_OFFSETS[slot], slot):
			return true
	return false


# cy.k — power this cell offers outward. The one conditional that makes
# redstone work: a NORMAL SOLID CUBE that is strong-powered becomes a
# source itself; anything else falls through to its own weak rule.
static func indirect_power_from(manager, pos: Vector3i, slot: int) -> bool:
	if is_normal_cube(manager, pos):
		return is_block_powered(manager, pos)
	return provides_weak_power(manager, pos, slot)


# cy.o — is this cell powered by anything at all? The query every
# consumer (door, TNT, wire) actually calls.
static func is_block_indirectly_powered(manager, pos: Vector3i) -> bool:
	for slot in range(6):
		if indirect_power_from(manager, pos + SLOT_OFFSETS[slot], slot):
			return true
	return false


# Vanilla cy.g(x,y,z) / isBlockNormalCube — a full opaque cube that can
# conduct. Non-cube shapes (slabs, stairs, torches, wire) never relay,
# which is why redstone can't be run through a staircase.
static func is_normal_cube(manager, pos: Vector3i) -> bool:
	var id: int = manager.get_world_block(pos)
	if id == Blocks.AIR:
		return false
	if not Blocks.is_opaque(id):
		return false
	return Blocks.mesh_shape(id) == Blocks.MESH_SHAPE_CUBE


# --- Dispatch -----------------------------------------------------------


# Called for every cell in a block-update fanout (ChunkManager's
# notification drain). Vanilla routes this through each Block's
# onNeighborBlockChange; we branch on id here so the dispatch cost for
# the overwhelmingly common "not a redstone cell" case is one match.
static func on_neighbor_changed(manager, pos: Vector3i) -> void:
	var id: int = manager.get_world_block(pos)
	match id:
		Blocks.LEVER:
			_check_mounted_support(manager, pos, id)
		Blocks.WOODEN_DOOR, Blocks.IRON_DOOR:
			_update_door(manager, pos, id)
		Blocks.TNT:
			_update_tnt(manager, pos)


# Mounted components pop off as an item when their support goes away
# (pl.java:h / iy.java:h).
static func _check_mounted_support(manager, pos: Vector3i, id: int) -> void:
	var meta: int = manager.get_world_block_meta(pos)
	var support: Vector3i = pos + mount_offset(meta)
	if is_normal_cube(manager, support):
		return
	manager.set_world_block_state(pos, Blocks.AIR, 0)
	if manager.has_method("spawn_block_drop"):
		manager.call("spawn_block_drop", pos, Blocks.drops(id))


# gv.java:156 — a door opens when EITHER of its two cells is powered.
# The open bit lives in bit 2 of the lower half's metadata; the upper
# half mirrors it with bit 3 set (see interaction.gd::_toggle_door).
static func _update_door(manager, pos: Vector3i, id: int) -> void:
	var meta: int = manager.get_world_block_meta(pos)
	# Always drive the pair from the LOWER half so both cells agree.
	var lower: Vector3i = pos
	var lower_meta: int = meta
	if (meta & 8) != 0:
		lower = pos + Vector3i(0, -1, 0)
		if manager.get_world_block(lower) != id:
			return
		lower_meta = manager.get_world_block_meta(lower)
	var upper: Vector3i = lower + Vector3i(0, 1, 0)
	var powered: bool = (
		is_block_indirectly_powered(manager, lower) or is_block_indirectly_powered(manager, upper)
	)
	var is_open: bool = (lower_meta & 4) != 0
	if powered == is_open:
		return
	var new_lower: int = lower_meta ^ 4
	manager.set_world_block_state(lower, id, new_lower)
	if manager.get_world_block(upper) == id:
		manager.set_world_block_state(upper, id, new_lower + 8)
	if manager.has_method("play_door_sound"):
		manager.call("play_door_sound", lower)


# v.java:23 — powered TNT primes and clears its cell. Vanilla also
# requires the CHANGED neighbour to be a power source; our fanout
# doesn't carry which neighbour moved, so the indirect-power check
# alone decides. Same observable behaviour for every Alpha circuit,
# since nothing else can power a TNT cell.
static func _update_tnt(manager, pos: Vector3i) -> void:
	if not is_block_indirectly_powered(manager, pos):
		return
	manager.set_world_block_state(pos, Blocks.AIR, 0)
	if manager.has_method("prime_tnt"):
		manager.call("prime_tnt", pos)
