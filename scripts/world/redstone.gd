# gdlint: disable=max-file-lines
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

# Max wire power, and the per-step decay (lu.java:74 `--n9`).
const WIRE_MAX_POWER: int = 15

# Horizontal neighbour offsets in the order lu.java:h() scans them.
const _WIRE_HORIZONTALS: Array[Vector3i] = [
	Vector3i(-1, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(0, 0, -1),
	Vector3i(0, 0, 1),
]

# Torch timing (bo.java). d() returns 2, so an inverter reacts two ticks
# after its mount changes — Alpha's only delay primitive.
const TORCH_TICK_RATE: int = 2
# Burnout: entries older than 100 ticks are discarded, and the 8th
# retained off-transition at one position burns the torch out
# (bo.java:20-32). A torch feeding its own mount through one wire
# oscillates, and this is what stops it.
const TORCH_BURNOUT_WINDOW_TICKS: int = 100
const TORCH_BURNOUT_LIMIT: int = 8

# Button pulse and plate re-check interval — iy.java d() and ap.java
# d() both return 20 ticks (one second).
const BUTTON_PULSE_TICKS: int = 20
const PLATE_RECHECK_TICKS: int = 20

# Beta 1.3 BlockRedstoneRepeater.field_22023_b is {1,2,3,4} redstone
# ticks; update scheduling multiplies each by 2 game ticks. One game tick
# is 50 ms, giving the familiar 0.1/0.2/0.3/0.4 second settings.
const REPEATER_DELAYS: Array[int] = [2, 4, 6, 8]
# RenderBlocks / randomDisplayTick offset of the movable delay torch from
# center, ordered by the same metadata index. The first setting places it
# 1/16 slightly toward the output; later clicks walk it toward the rear.
const REPEATER_TORCH_OFFSETS: Array[float] = [-0.0625, 0.0625, 0.1875, 0.3125]

# ap.java's inset detection box: (x+0.125, y, z+0.125) to
# (x+0.875, y+0.25, z+0.875). Standing at the very corner of the cell
# does NOT trip a plate.
const PLATE_BOX_INSET: float = 0.125
const PLATE_BOX_HEIGHT: float = 0.25

# Per-pump ceilings for an in-flight wire burst. Hitting either PAUSES
# the burst; the queue, membership sets and pending notifications all
# survive to the next frame (see the burst block below).
#
# The real bound is the TIME one. A relaxation costs ~33 µs here
# (measured, `tests/test_redstone_performance.gd`), but that figure is a
# desktop debug-build number and mobile web runs several times slower, so
# a fixed step count would mean something different on every host. The
# step ceiling is only a backstop for the pathological case where each
# relaxation is somehow free.
const WIRE_STEPS_PER_DRAIN: int = 4096
const WIRE_USEC_PER_DRAIN: int = 2000
# How often the clock is consulted. Checking every step would put a
# syscall next to a ~33 µs body; every 16 keeps that overhead under 1%
# while capping the overshoot at roughly half a millisecond.
const _WIRE_TIME_CHECK_INTERVAL: int = 16
# Absolute ceiling for a manager that never pumps (bare test doubles):
# such a caller gets the whole fixpoint synchronously, and this only
# exists so a malformed world can't spin forever. Far above the ~15×N
# relaxations a real depower needs.
const _WIRE_SYNC_STEP_CEILING: int = 1 << 20

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

# Vanilla lu.java's `private boolean a = true` recursion guard, hoisted
# to module scope because our port is static. While a wire recomputes
# its own level, ALL wire is temporarily removed from the power-source
# set so `is_block_indirectly_powered` can't feed a wire its own output
# back as a fresh 15. Wire-to-wire propagation still works: it reads
# neighbour metadata directly (see _wire_power_at) rather than going
# through the power queries.
static var _wire_output_enabled: bool = true

# Fallback burnout log for managers that don't own one (see
# _burnout_log). Only reached by bare test doubles.
static var _fallback_burnout_log: Array = []

# --- In-flight wire burst ----------------------------------------------
#
# One "burst" is one run to the wire fixpoint. It is a static rather than
# a local because it OUTLIVES A FRAME: a large network needs more
# relaxations than fit in a frame budget, and truncating the worklist
# would leave the network permanently half-powered. So the burst pauses
# with all of its state intact and the manager resumes it next frame,
# exactly like the block-notification queue in ChunkManager.
#
# Nothing downstream may observe a paused burst as settled, so the
# zero-crossing notifications ride along in `_burst_notify` and are only
# handed to the world once the queue actually empties.
static var _burst_owner: WeakRef = null
# Ring-style queue: a head INDEX rather than `pop_front()`, which is O(n)
# in Godot and turned a 15,000-relaxation depower into quadratic work —
# most of the measured per-step cost was the shift, not the physics.
# The tail is reclaimed by `_compact_burst_queue` once the dead prefix is
# both large and the majority of the array.
static var _burst_queue: Array[Vector3i] = []
static var _burst_head: int = 0
static var _burst_queued: Dictionary = {}
static var _burst_visited: Dictionary = {}
static var _burst_notify: Array[Vector3i] = []
static var _burst_notify_set: Dictionary = {}
static var _burst_reconcile: bool = false
# Cumulative counters for the whole burst, read by the perf fixture and
# the debug overlay. Reset when a burst settles, not per drain.
static var _burst_steps: int = 0
static var _burst_writes: int = 0
static var _burst_drains: int = 0
static var _last_burst_stats: Dictionary = {"steps": 0, "writes": 0, "drains": 0}


# True for blocks that can act as a redstone source — vanilla
# `Block.e()` / `isPowerSource`. Wire is included: `lu.java:e()` returns
# its guard flag, which is true outside a wire recomputation.
#
# This is a CAPABILITY question, not a state question: every id whose
# vanilla class overrides `e()` to return true belongs here whether or
# not it is currently switched on (pl.java:205, iy.java:206, ap.java:139,
# bo.java, lu.java:282). Three consumers read it and all three break if
# the set is short — wire connectivity (lu.java:295 `c()`), the mesher's
# wire topology, and the changed-neighbour guard TNT and rails share.
static func is_power_source(id: int) -> bool:
	if id == Blocks.REDSTONE_WIRE:
		return _wire_output_enabled
	match id:
		# bo.java:e() returns true for BOTH torch variants, so wire links
		# to an unlit torch as well as a lit one.
		Blocks.LEVER, Blocks.REDSTONE_TORCH, Blocks.REDSTONE_TORCH_OFF:
			return true
		Blocks.STONE_BUTTON, Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE:
			return true
	# Beta 1.3's repeater deliberately returns false from
	# canProvidePower(). Its directional output still participates in the
	# world power queries below, but wire does not visually auto-connect;
	# Mojang added input-side auto-connection in Beta 1.7.
	return false


# Every switchable component notifies TWICE when it changes: once around
# itself, and once around the block it is mounted on (pl.java:145-157 for
# the lever, iy.java for the button, ap.java:92-93 for plates). A torch
# goes further and notifies around all six of its neighbours
# (bo.java:48-53).
#
# That second fanout is not redundancy — it is the entire mechanism by
# which STRONG power leaves a component. A lever on a wall energises the
# wall; the cells that need to hear about it are the wall's neighbours,
# which are two steps from the lever and therefore outside its own
# 7-cell fanout. Without this, the most common circuit in the game — a
# lever on a block with wire running along the ground beside it — does
# nothing at all.
static func notify_around_mount(manager, pos: Vector3i, source_id: int) -> void:
	notify_around(manager, pos + mount_offset(manager.get_world_block_meta(pos)), source_id)


# The same second fanout for a component whose mount is FIXED rather than
# encoded in its metadata. Plates always sit on the block below them, and
# their metadata is the pressed flag — running it through `mount_offset`
# would read a pressed plate (meta 1) as west-wall-mounted and notify the
# wrong cell entirely.
static func notify_around_support(manager, pos: Vector3i, source_id: int) -> void:
	notify_around(manager, pos + Vector3i(0, -1, 0), source_id)


static func notify_around(manager, cell: Vector3i, source_id: int) -> void:
	if not manager.has_method("enqueue_block_notification"):
		return
	manager.call("enqueue_block_notification", cell, source_id)


# The torch variant: bo.java pushes an update around each of its six
# neighbours, so a torch can drive the block above it AND the wire beside
# whatever it is mounted to.
static func notify_around_all_neighbours(manager, pos: Vector3i, source_id: int) -> void:
	for offset: Vector3i in SLOT_OFFSETS:
		notify_around(manager, pos + offset, source_id)


# vanilla `Block.onBlockRemoval` for the switchable components
# (pl.java:160-175, and the same shape in iy.java / ap.java): a component
# that disappears while still ON pushes one last update around its mount.
#
# `set_world_block` already fans out around the cell that changed, which
# covers the component's own neighbours. This covers the MOUNT's — the
# cells its strong power was actually reaching, two steps away — so
# blowing up or washing away a powered lever de-powers the door it was
# driving through the wall.
static func on_block_removed(manager, pos: Vector3i, old_id: int, old_meta: int) -> void:
	match old_id:
		Blocks.LEVER, Blocks.STONE_BUTTON:
			if (old_meta & POWERED_BIT) == 0:
				return
			notify_around(manager, pos + mount_offset(old_meta), old_id)
		Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE:
			if old_meta == 0:
				return
			notify_around(manager, pos + Vector3i(0, -1, 0), old_id)
		Blocks.REDSTONE_TORCH:
			notify_around_all_neighbours(manager, pos, old_id)


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
static func provides_weak_power(manager, pos: Vector3i, slot: int) -> bool:
	var id: int = manager.get_world_block(pos)
	match id:
		Blocks.LEVER:
			# pl.java:181 — an on lever weakly powers every direction.
			return (manager.get_world_block_meta(pos) & POWERED_BIT) > 0
		Blocks.REDSTONE_WIRE:
			return _wire_powers_slot(manager, pos, slot)
		Blocks.REDSTONE_TORCH:
			# bo.java:65 — a lit torch powers every direction EXCEPT into
			# the block it is attached to.
			return slot != _torch_excluded_slot(manager.get_world_block_meta(pos))
		Blocks.STONE_BUTTON:
			# iy.java:180 — a pressed button powers every direction.
			return (manager.get_world_block_meta(pos) & POWERED_BIT) > 0
		Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE:
			# ap.java:127 — a pressed plate powers every direction.
			return manager.get_world_block_meta(pos) > 0
		Blocks.REDSTONE_REPEATER_ON:
			return slot == repeater_output_slot(manager.get_world_block_meta(pos))
	return false


# The one slot a lit torch withholds power from: the one where the
# asking cell IS the torch's mount block.
static func _torch_excluded_slot(meta: int) -> int:
	var away: Vector3i = -mount_offset(meta)
	return SLOT_OFFSETS.find(away)


# lu.java:c(pk, x, y, z, n5) — what a powered wire feeds outward.
#
# Three rules, and the last one surprises people: wire powers the block
# BELOW it always, powers all four horizontal neighbours when it has no
# connections at all, and otherwise powers only along a STRAIGHT line.
# A corner, T or cross feeds nothing horizontally — which is exactly why
# vanilla circuits run wire straight into whatever they drive.
static func _wire_powers_slot(manager, pos: Vector3i, slot: int) -> bool:
	if not _wire_output_enabled:
		return false
	if manager.get_world_block_meta(pos) == 0:
		return false
	# slot 1 = the wire sits directly above the asking cell.
	if slot == SLOT_ABOVE:
		return true
	if slot < SLOT_NORTH or slot > SLOT_EAST:
		return false
	var west: bool = wire_connects_toward(manager, pos, Vector3i(-1, 0, 0))
	var east: bool = wire_connects_toward(manager, pos, Vector3i(1, 0, 0))
	var north: bool = wire_connects_toward(manager, pos, Vector3i(0, 0, -1))
	var south: bool = wire_connects_toward(manager, pos, Vector3i(0, 0, 1))
	if not (west or east or north or south):
		return true
	# slot N names where the WIRE sits relative to the asker, so the
	# asker lies on the opposite side: a wire connected north powers the
	# cell to its south, which queries with slot 2.
	if slot == SLOT_NORTH:
		return north and not west and not east
	if slot == SLOT_SOUTH:
		return south and not west and not east
	if slot == SLOT_WEST:
		return west and not north and not south
	return east and not north and not south


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
		Blocks.STONE_BUTTON:
			# iy.java:184 — like the lever, only into its mount block.
			var button_meta: int = manager.get_world_block_meta(pos)
			if (button_meta & POWERED_BIT) == 0:
				return false
			return _MOUNT_TO_STRONG_SLOT.get(button_meta & 0x7, SLOT_ABOVE) == slot
		Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE:
			# ap.java:131 — slot 1, i.e. the block directly BELOW it.
			if manager.get_world_block_meta(pos) == 0:
				return false
			return slot == SLOT_ABOVE
		Blocks.REDSTONE_TORCH:
			# bo.java:121 — strong power only at slot 0, i.e. into the
			# block directly ABOVE the torch. That single rule is why the
			# classic "torch under a block, wire on top" circuit works.
			return slot == SLOT_BELOW and provides_weak_power(manager, pos, slot)
		Blocks.REDSTONE_WIRE:
			# lu.java:224 delegates the World overload straight to the
			# IBlockAccess one — wire's strong and weak output are the
			# same, which is how a wire drives a door through the block
			# it runs across.
			return _wire_powers_slot(manager, pos, slot)
		Blocks.REDSTONE_REPEATER_ON:
			# BlockRedstoneRepeater delegates indirect/strong output to the
			# same one-direction predicate as weak output.
			return slot == repeater_output_slot(manager.get_world_block_meta(pos))
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
#
# `source_id` is the id of the block whose change triggered this fanout
# — vanilla's `n5` argument. Two consumers genuinely need it (TNT
# v.java:23 and rail junctions jn.java:89, both of which demand the
# changed neighbour BE a power source), so it is threaded through rather
# than inferred. AIR means "unknown origin"; both guards then decline,
# which is the safe direction.
static func on_neighbor_changed(manager, pos: Vector3i, source_id: int = Blocks.AIR) -> void:
	var id: int = manager.get_world_block(pos)
	match id:
		Blocks.REDSTONE_WIRE:
			_check_wire_support(manager, pos)
		Blocks.REDSTONE_TORCH, Blocks.REDSTONE_TORCH_OFF:
			_update_torch(manager, pos, id)
		Blocks.STONE_BUTTON:
			_check_mounted_support(manager, pos, id)
		Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE:
			_check_plate_support(manager, pos, id)
		Blocks.LEVER:
			_check_mounted_support(manager, pos, id)
		Blocks.REDSTONE_REPEATER_OFF, Blocks.REDSTONE_REPEATER_ON:
			_update_repeater(manager, pos, id)
		Blocks.WOODEN_DOOR, Blocks.IRON_DOOR:
			_update_door(manager, pos, id)
		Blocks.TNT:
			_update_tnt(manager, pos, source_id)
		Blocks.RAIL:
			_update_rail(manager, pos, source_id)


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
	var desired_lower: int = (lower_meta | 4) if powered else (lower_meta & ~4)
	var state_changed: bool = powered != is_open
	if state_changed:
		manager.set_world_block_state(lower, id, desired_lower)
	# Keep the two render/collision halves coherent even when a legacy save
	# or an interrupted two-cell placement left only one open bit updated.
	# The old early return compared only the lower half, so a powered lower
	# half made a closed upper half permanent until the input toggled again.
	if (
		manager.get_world_block(upper) == id
		and manager.get_world_block_meta(upper) != desired_lower + 8
	):
		manager.set_world_block_state(upper, id, desired_lower + 8)
	if state_changed and manager.has_method("play_door_sound"):
		manager.call("play_door_sound", lower)


# v.java:23 — `if (n5 > 0 && nq.m[n5].e() && cy.o(x,y,z))`. All THREE
# clauses matter: TNT that is already sitting in a powered cell must not
# re-prime every time some unrelated neighbour is edited, so the block
# that actually changed has to be capable of providing power.
static func _update_tnt(manager, pos: Vector3i, source_id: int) -> void:
	if source_id == Blocks.AIR or not is_power_source(source_id):
		return
	if not is_block_indirectly_powered(manager, pos):
		return
	manager.set_world_block_state(pos, Blocks.AIR, 0)
	if manager.has_method("prime_tnt"):
		manager.call("prime_tnt", pos)


# jn.java:89 — the one place Alpha lets redstone touch a rail. A rail
# with EXACTLY three connections is shape-ambiguous, and vanilla re-runs
# the track logic with the current power state, which flips the curve
# tie-break (oc.java:227-260). Same changed-neighbour guard as TNT, and
# the same `== 3` exactness: a four-way junction is left alone.
static func _update_rail(manager, pos: Vector3i, source_id: int) -> void:
	if source_id == Blocks.AIR or not is_power_source(source_id):
		return
	if RailShape.connection_count(manager, pos) != 3:
		return
	var powered: bool = is_block_indirectly_powered(manager, pos)
	var meta: int = RailShape.compute(manager, pos, powered, manager.get_world_block_meta(pos))
	if meta == manager.get_world_block_meta(pos):
		return
	manager.set_world_block_state(pos, Blocks.RAIL, meta)


# --- Wire propagation (lu.java:h) --------------------------------------


# lu.java:299 static c() — what a wire will link to. Wire connects to
# other wire and to any power source (lever, and later button, plate,
# lit torch). It does NOT connect to plain solid blocks, which is why
# a wire run stops dead at a wall instead of wrapping around it.
static func can_connect_to(manager, pos: Vector3i) -> bool:
	var id: int = manager.get_world_block(pos)
	if id == Blocks.REDSTONE_WIRE:
		# Checked before the source test so wire-to-wire linkage survives
		# the recomputation guard (vanilla does the same ordering).
		return true
	if id == Blocks.AIR:
		return false
	return is_power_source(id)


# Whether the wire at `pos` links toward `offset`, including the two
# vertical cases: up the side of a solid neighbour when this wire isn't
# roofed, and down onto a lower neighbour when the side is open
# (bk.java:437-455 uses the identical predicate for rendering).
static func wire_connects_toward(manager, pos: Vector3i, offset: Vector3i) -> bool:
	var side: Vector3i = pos + offset
	if can_connect_to(manager, side):
		return true
	if not is_normal_cube(manager, side):
		# Open side — a wire one level down is reachable.
		return can_connect_to(manager, side + Vector3i(0, -1, 0))
	# Solid side — a wire on top of it is reachable only if this cell
	# isn't roofed over.
	if is_normal_cube(manager, pos + Vector3i(0, 1, 0)):
		return false
	return can_connect_to(manager, side + Vector3i(0, 1, 0))


# Power level of a wire cell, or -1 when the cell isn't wire.
static func _wire_power_at(manager, pos: Vector3i) -> int:
	if manager.get_world_block(pos) != Blocks.REDSTONE_WIRE:
		return -1
	return manager.get_world_block_meta(pos)


# The level a wire cell SHOULD hold, given its surroundings.
# Direct port of the calculation half of lu.java:h().
static func computed_wire_power(manager, pos: Vector3i) -> int:
	# Suppress every wire's output while asking "am I powered by a real
	# source?", so a wire can't read its own contribution (or one it
	# already fed into an adjacent solid block) as a fresh 15.
	_wire_output_enabled = false
	var externally_powered: bool = is_block_indirectly_powered(manager, pos)
	_wire_output_enabled = true
	if externally_powered:
		return WIRE_MAX_POWER
	var best: int = 0
	var roofed: bool = is_normal_cube(manager, pos + Vector3i(0, 1, 0))
	for offset: Vector3i in _WIRE_HORIZONTALS:
		var side: Vector3i = pos + offset
		best = maxi(best, _wire_power_at(manager, side))
		# The vertical rules are ASYMMETRIC (lu.java:64-70): climb up the
		# side of a solid neighbour only when this cell is open above,
		# but drop down to a lower neighbour only when the side is open.
		if is_normal_cube(manager, side):
			if not roofed:
				best = maxi(best, _wire_power_at(manager, side + Vector3i(0, 1, 0)))
		else:
			best = maxi(best, _wire_power_at(manager, side + Vector3i(0, -1, 0)))
	return maxi(best - 1, 0)


# Recompute `origin` and everything its change reaches, then hand the
# affected cells to the world's block-update fanout.
#
# Vanilla recurses (h() calls h()); GDScript stack depth on a large net
# makes that a real hazard, so this is an explicit worklist. The result
# is identical because wire power is a max-minus-decay fixpoint.
#
# The worklist is a resumable BURST (see the static block above), not a
# local: a manager that advertises `redstone_defers_wire_bursts()` gets
# one drain now and pumps the rest from its own frame loop. Anything
# else — bare test doubles — runs the whole fixpoint synchronously.
static func update_wire(manager, origin: Vector3i, reconcile: bool = false) -> void:
	if manager.get_world_block(origin) != Blocks.REDSTONE_WIRE:
		return
	_seed_burst(manager, origin, reconcile)
	if manager.has_method("redstone_defers_wire_bursts"):
		drain_wire_work(manager, WIRE_STEPS_PER_DRAIN, WIRE_USEC_PER_DRAIN)
		return
	drain_wire_work(manager, _WIRE_SYNC_STEP_CEILING)


# Add `origin` to the in-flight burst, starting one if there isn't a
# live burst for this world. RECONCILE mode walks the entire connected
# network even where nothing changes — needed when metadata may be stale
# (chunk load), and only then. The default CHANGE-DRIVEN mode expands
# only from cells that actually moved, which is what keeps the common
# path cheap: a neighbour notification on a settled net costs one cell
# evaluation instead of a full traversal. Getting this wrong made a
# 16-cell run cost 22 ms — more than a frame — because every one of the
# run's notifications re-walked the whole thing.
static func _seed_burst(manager, origin: Vector3i, reconcile: bool) -> void:
	var owner: Object = null if _burst_owner == null else _burst_owner.get_ref()
	if owner != manager:
		# A different world (or a freed one) owned the last burst. Its
		# cells mean nothing here, and there is no correct way to finish
		# them against this manager, so start clean.
		_clear_burst()
		_burst_owner = weakref(manager)
	if _burst_queued.has(origin):
		# Already pending: merging the reconcile flag below is all that
		# is left to do.
		_burst_reconcile = _burst_reconcile or reconcile
		return
	_burst_queued[origin] = true
	_burst_queue.append(origin)
	# Reconcile is a strict superset of change-driven expansion, so OR-ing
	# it into a burst already in flight can only add work, never lose any.
	_burst_reconcile = _burst_reconcile or reconcile


# Advance the in-flight burst by at most `budget` relaxations, and — when
# `usec_budget` is positive — for at most that long. Returns true while
# work remains. The caller owns the cadence; `_process` on ChunkManager
# pumps once per frame. Tests pass a step budget alone so a fixture's
# frame count doesn't depend on how fast the machine running it is.
static func drain_wire_work(manager, budget: int, usec_budget: int = 0) -> bool:
	if _burst_head >= _burst_queue.size():
		return false
	var owner: Object = null if _burst_owner == null else _burst_owner.get_ref()
	if owner != manager:
		return false
	_burst_drains += 1
	var started: int = Time.get_ticks_usec() if usec_budget > 0 else 0
	var steps: int = 0
	while _burst_head < _burst_queue.size() and steps < budget:
		steps += 1
		if (
			usec_budget > 0
			and steps % _WIRE_TIME_CHECK_INTERVAL == 0
			and Time.get_ticks_usec() - started >= usec_budget
		):
			_compact_burst_queue()
			return true
		_burst_steps += 1
		var pos: Vector3i = _burst_queue[_burst_head]
		_burst_head += 1
		_burst_queued.erase(pos)
		if manager.get_world_block(pos) != Blocks.REDSTONE_WIRE:
			continue
		# `_burst_visited` bounds the outward SCAN so an already-correct
		# network terminates; `_burst_queued` alone can't, because a cell
		# must stay re-enqueueable after its inputs move. A cell is
		# re-examined whenever a neighbour actually changes, regardless
		# of visited.
		var first_visit: bool = not _burst_visited.has(pos)
		_burst_visited[pos] = true
		var current: int = manager.get_world_block_meta(pos)
		var next: int = computed_wire_power(manager, pos)
		var changed: bool = next != current
		if changed:
			# Metadata-only write: no id change, so this depends on the
			# atomic state path notifying and re-meshing (§7.2). The
			# fanout is collected and issued once the whole net settles,
			# so consumers never observe a half-propagated line — not
			# even one paused across a frame boundary.
			manager.set_world_block_state(pos, Blocks.REDSTONE_WIRE, next, false)
			_burst_writes += 1
			# Vanilla only fires block updates when the level crosses
			# zero (lu.java:104). 12 → 11 changes nothing downstream, and
			# skipping those is a large reduction in update churn.
			if (current == 0 or next == 0) and not _burst_notify_set.has(pos):
				_burst_notify_set[pos] = true
				_burst_notify.append(pos)
		# Expand on every change (so the fixpoint is reached), and — in
		# reconcile mode only — on first visit as well, so an update
		# seeded anywhere still repairs its whole network.
		if not (changed or (_burst_reconcile and first_visit)):
			continue
		for neighbor: Vector3i in _wire_neighbors(manager, pos):
			if _burst_queued.has(neighbor):
				continue
			if not changed and _burst_visited.has(neighbor):
				continue
			_burst_queued[neighbor] = true
			_burst_queue.append(neighbor)
	if _burst_head < _burst_queue.size():
		_compact_burst_queue()
		return true
	_settle_burst(manager)
	return false


# Drop the consumed prefix once it is both sizeable and the majority of
# the array, so a long burst's memory stays proportional to the work
# still outstanding rather than to everything it has ever queued.
static func _compact_burst_queue() -> void:
	if _burst_head < 1024 or _burst_head * 2 < _burst_queue.size():
		return
	_burst_queue = _burst_queue.slice(_burst_head)
	_burst_head = 0


# The burst reached its fixpoint: publish the deferred zero-crossings.
# Order matters — the burst is cleared BEFORE the fanout, because
# `enqueue_block_notification` drains synchronously on a real manager and
# that drain can seed a fresh burst through `_check_wire_support`.
static func _settle_burst(manager) -> void:
	var notify: Array[Vector3i] = _burst_notify
	_last_burst_stats = {"steps": _burst_steps, "writes": _burst_writes, "drains": _burst_drains}
	_clear_burst()
	if not manager.has_method("enqueue_block_notification"):
		return
	for pos: Vector3i in notify:
		manager.call("enqueue_block_notification", pos)


static func _clear_burst() -> void:
	_burst_queue = []
	_burst_head = 0
	_burst_queued = {}
	_burst_visited = {}
	_burst_notify = []
	_burst_notify_set = {}
	_burst_reconcile = false
	_burst_steps = 0
	_burst_writes = 0
	_burst_drains = 0
	_burst_owner = null


# True while a paused burst is waiting for its next pump. Consumers use
# this to know the network has NOT settled yet.
static func has_pending_wire_work() -> bool:
	return _burst_head < _burst_queue.size()


# Cells still queued in the in-flight burst — instrumentation for the
# debug overlay and the performance fixture.
static func pending_wire_cells() -> int:
	return _burst_queue.size() - _burst_head


# {steps, writes, drains} for the most recently SETTLED burst.
static func last_burst_stats() -> Dictionary:
	return _last_burst_stats.duplicate()


# Every wire cell this one can exchange power with: the four horizontal
# neighbours at the same level and one step up or down, plus straight
# up and down (a wire stack shares power through the support block).
static func _wire_neighbors(manager, pos: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for offset: Vector3i in _WIRE_HORIZONTALS:
		for vertical: int in [0, 1, -1]:
			var neighbor: Vector3i = pos + offset + Vector3i(0, vertical, 0)
			if manager.get_world_block(neighbor) == Blocks.REDSTONE_WIRE:
				out.append(neighbor)
	for vertical: Vector3i in [Vector3i(0, 1, 0), Vector3i(0, -1, 0)]:
		var neighbor: Vector3i = pos + vertical
		if manager.get_world_block(neighbor) == Blocks.REDSTONE_WIRE:
			out.append(neighbor)
	return out


# Wire needs a normal solid cube directly beneath it (lu.java:a). When
# that goes, the wire pops off as dust.
static func _check_wire_support(manager, pos: Vector3i) -> void:
	if is_normal_cube(manager, pos + Vector3i(0, -1, 0)):
		# Change-driven: this fires for every block update near wire, so
		# it must be cheap on a settled network.
		update_wire(manager, pos)
		return
	manager.set_world_block_state(pos, Blocks.AIR, 0)
	if manager.has_method("spawn_block_drop"):
		manager.call("spawn_block_drop", pos, Blocks.drops(Blocks.REDSTONE_WIRE))


# --- Redstone torch (bo.java) ------------------------------------------


# Is the block this torch hangs on receiving power? bo.java:86-100 asks
# `cy.k(mount, slot)` — the indirect-power query, so a mount block that
# is merely strong-powered by something else counts.
static func torch_mount_powered(manager, pos: Vector3i) -> bool:
	var meta: int = manager.get_world_block_meta(pos)
	var offset: Vector3i = mount_offset(meta)
	var slot: int = SLOT_OFFSETS.find(offset)
	if slot < 0:
		return false
	return indirect_power_from(manager, pos + offset, slot)


# Prune the burnout log, then count how many off-transitions this
# position has inside the retained window. `record` adds the current
# transition first, matching bo.java's `a(world, x, y, z, true)`.
# Vanilla keeps its RedstoneUpdateInfo list in a `private static List`.
# We hang it off the WORLD instead: burnout history is world state, and
# a static outlives the world it belongs to — a torch that burnt out in
# one save would still be suppressed after loading another. Managers
# expose `redstone_burnout_log()`; the static below is only a fallback
# for bare test doubles.
static func _burnout_log(manager) -> Array:
	if manager != null and manager.has_method("redstone_burnout_log"):
		return manager.call("redstone_burnout_log")
	return _fallback_burnout_log


static func _torch_burned_out(manager, pos: Vector3i, record: bool) -> bool:
	var now: int = _world_tick(manager)
	var log: Array = _burnout_log(manager)
	if record:
		log.append({"pos": pos, "tick": now})
	while not log.is_empty() and now - int(log[0]["tick"]) > TORCH_BURNOUT_WINDOW_TICKS:
		log.pop_front()
	var count: int = 0
	for entry: Dictionary in log:
		if entry["pos"] == pos:
			count += 1
			if count >= TORCH_BURNOUT_LIMIT:
				return true
	return false


static func _world_tick(manager) -> int:
	if manager.has_method("redstone_tick"):
		return int(manager.call("redstone_tick"))
	return TickScheduler.current_tick()


# Scheduled-tick handler for both torch ids (bo.java:104-124). Lit torch
# over a powered mount turns off; unlit torch over an unpowered mount
# turns back on unless it has burnt out.
static func torch_tick(manager, pos: Vector3i, block_id: int) -> void:
	var mount_powered: bool = torch_mount_powered(manager, pos)
	var meta: int = manager.get_world_block_meta(pos)
	if block_id == Blocks.REDSTONE_TORCH:
		if not mount_powered:
			return
		manager.set_world_block_state(pos, Blocks.REDSTONE_TORCH_OFF, meta)
		notify_around_all_neighbours(manager, pos, Blocks.REDSTONE_TORCH_OFF)
		if _torch_burned_out(manager, pos, true):
			# Vanilla plays random.fizz at volume 0.5 with a wide pitch
			# jitter and puffs five smoke particles.
			if manager.has_method("play_torch_burnout"):
				manager.call("play_torch_burnout", pos)
		return
	if mount_powered:
		return
	if _torch_burned_out(manager, pos, false):
		return
	manager.set_world_block_state(pos, Blocks.REDSTONE_TORCH, meta)
	notify_around_all_neighbours(manager, pos, Blocks.REDSTONE_TORCH)


# Neighbour-change entry: schedule the 2-tick re-evaluation, and pop the
# torch off if its mount is gone.
static func _update_torch(manager, pos: Vector3i, block_id: int) -> void:
	var meta: int = manager.get_world_block_meta(pos)
	var support: Vector3i = pos + mount_offset(meta)
	if not is_normal_cube(manager, support):
		manager.set_world_block_state(pos, Blocks.AIR, 0)
		if manager.has_method("spawn_block_drop"):
			manager.call("spawn_block_drop", pos, Blocks.drops(block_id))
		return
	# Only schedule when the torch actually disagrees with its mount, so
	# a settled circuit doesn't refill the tick queue on every update.
	var mount_powered: bool = torch_mount_powered(manager, pos)
	var lit: bool = block_id == Blocks.REDSTONE_TORCH
	if lit == mount_powered:
		TickScheduler.schedule(pos, block_id, TORCH_TICK_RATE)


# Resets the transient module state. Burnout history is per-world and
# lives on the manager, so this only clears the fallback log, the wire
# recomputation guard, and any burst left in flight by the old world.
static func reset_state() -> void:
	# Reassign rather than clear(): a plain in-place clear on this static
	# did NOT propagate to readers outside the class (verified by probe),
	# leaving burnout history alive across worlds and test cases.
	_fallback_burnout_log.clear()
	_wire_output_enabled = true
	_clear_burst()
	_last_burst_stats = {"steps": 0, "writes": 0, "drains": 0}


# --- Stone button (iy.java) --------------------------------------------


# Right-click. A pressed button ignores further clicks (iy.java:139)
# and releases itself on a scheduled tick.
static func press_button(manager, pos: Vector3i) -> bool:
	var meta: int = manager.get_world_block_meta(pos)
	if (meta & POWERED_BIT) != 0:
		return false
	manager.set_world_block_state(pos, Blocks.STONE_BUTTON, meta | POWERED_BIT)
	notify_around_mount(manager, pos, Blocks.STONE_BUTTON)
	TickScheduler.schedule(pos, Blocks.STONE_BUTTON, BUTTON_PULSE_TICKS)
	if manager.has_method("play_redstone_click"):
		manager.call("play_redstone_click", pos, true)
	return true


# Scheduled release, exactly BUTTON_PULSE_TICKS after the press.
static func button_tick(manager, pos: Vector3i) -> void:
	var meta: int = manager.get_world_block_meta(pos)
	if (meta & POWERED_BIT) == 0:
		return
	manager.set_world_block_state(pos, Blocks.STONE_BUTTON, meta & 0x7)
	notify_around_mount(manager, pos, Blocks.STONE_BUTTON)
	if manager.has_method("play_redstone_click"):
		manager.call("play_redstone_click", pos, false)


# --- Pressure plates (ap.java) -----------------------------------------


# The inset box an entity has to be inside to trip a plate.
static func plate_detection_box(pos: Vector3i) -> AABB:
	return AABB(
		Vector3(float(pos.x) + PLATE_BOX_INSET, float(pos.y), float(pos.z) + PLATE_BOX_INSET),
		Vector3(1.0 - PLATE_BOX_INSET * 2.0, PLATE_BOX_HEIGHT, 1.0 - PLATE_BOX_INSET * 2.0)
	)


# Wooden plates take every entity (lg.a); stone plates only living ones
# (lg.b). The manager decides what "living" means for its entity set.
static func plate_living_only(block_id: int) -> bool:
	return block_id == Blocks.STONE_PRESSURE_PLATE


# Re-evaluate a plate against whatever is standing on it. Called from
# entity contact and from the 20-tick scheduled re-check, so a plate
# releases once the box empties.
static func update_plate(manager, pos: Vector3i, block_id: int, from_contact: bool = false) -> void:
	# ap.java has two entry points with DIFFERENT guards, and they matter:
	#   :65  entity collision returns early when the plate is already
	#        pressed — otherwise every footstep of a player standing on a
	#        plate would queue another 20-tick recheck, and TickScheduler
	#        permits duplicates, so the queue would grow without bound.
	#   :57  the scheduled tick returns early when the plate is released,
	#        since a plate at rest has nothing to re-check.
	var meta: int = manager.get_world_block_meta(pos)
	if from_contact and meta > 0:
		return
	if not from_contact and meta == 0:
		return
	var occupied: bool = false
	if manager.has_method("entities_overlap_box"):
		occupied = bool(
			manager.call(
				"entities_overlap_box", plate_detection_box(pos), plate_living_only(block_id)
			)
		)
	var was_pressed: bool = meta > 0
	if occupied and not was_pressed:
		manager.set_world_block_state(pos, block_id, 1)
		notify_around_support(manager, pos, block_id)
		if manager.has_method("play_redstone_click"):
			manager.call("play_redstone_click", pos, true)
	elif not occupied and was_pressed:
		manager.set_world_block_state(pos, block_id, 0)
		notify_around_support(manager, pos, block_id)
		if manager.has_method("play_redstone_click"):
			manager.call("play_redstone_click", pos, false)
	# While held down, keep re-checking so the plate can notice the
	# entity leaving (ap.java:104).
	if occupied:
		TickScheduler.schedule(pos, block_id, PLATE_RECHECK_TICKS)


# Plates need a normal cube below, same as wire.
static func _check_plate_support(manager, pos: Vector3i, block_id: int) -> void:
	if is_normal_cube(manager, pos + Vector3i(0, -1, 0)):
		return
	manager.set_world_block_state(pos, Blocks.AIR, 0)
	if manager.has_method("spawn_block_drop"):
		manager.call("spawn_block_drop", pos, Blocks.drops(block_id))


# --- Redstone repeater (Beta 1.3 BlockRedstoneRepeater) ----------------


# The slot the POWERED repeater occupies relative to the cell at its
# output. This is also the slot used to query the rear input cell — the
# apparent symmetry follows World.isBlockIndirectlyProvidingPowerTo's slot
# convention (see the class-level SLOT_* comment).
static func repeater_output_slot(meta: int) -> int:
	match meta & 3:
		0:
			return SLOT_SOUTH  # output points north (-Z)
		1:
			return SLOT_WEST  # output points east (+X)
		2:
			return SLOT_NORTH  # output points south (+Z)
		_:
			return SLOT_EAST  # output points west (-X)


# World-space direction from the repeater cell toward its output/front.
static func repeater_output_offset(meta: int) -> Vector3i:
	return -SLOT_OFFSETS[repeater_output_slot(meta)]


# World-space direction from the repeater cell toward its rear/input.
static func repeater_input_offset(meta: int) -> Vector3i:
	return SLOT_OFFSETS[repeater_output_slot(meta)]


static func repeater_delay_ticks(meta: int) -> int:
	return REPEATER_DELAYS[(meta & 0xC) >> 2]


static func repeater_torch_offset(meta: int) -> float:
	return REPEATER_TORCH_OFFSETS[(meta & 0xC) >> 2]


# Beta 1.3 only samples the cell directly behind the repeater. Side power
# is intentionally ignored, unlike a normal redstone consumer.
static func repeater_input_powered(manager, pos: Vector3i, meta: int = -1) -> bool:
	var state: int = manager.get_world_block_meta(pos) if meta < 0 else meta
	var rear_slot: int = repeater_output_slot(state)
	return indirect_power_from(manager, pos + SLOT_OFFSETS[rear_slot], rear_slot)


# Right-click cycles delay index 0→1→2→3→0 while preserving orientation.
# BlockRedstoneRepeater.blockActivated performs only this metadata write;
# it neither changes power immediately nor restarts an already-pending tick.
static func cycle_repeater_delay(manager, pos: Vector3i) -> int:
	var id: int = manager.get_world_block(pos)
	if id != Blocks.REDSTONE_REPEATER_OFF and id != Blocks.REDSTONE_REPEATER_ON:
		return -1
	var meta: int = manager.get_world_block_meta(pos)
	var next_delay: int = ((((meta & 0xC) >> 2) + 1) & 3) << 2
	var next_meta: int = (meta & 3) | next_delay
	manager.set_world_block_state(pos, id, next_meta)
	return repeater_delay_ticks(next_meta)


# Placement has one historical fast path: if the rear is already powered,
# Beta schedules the unpowered block after ONE game tick rather than waiting
# for the selected 2-tick default delay.
static func on_repeater_placed(manager, pos: Vector3i) -> void:
	if manager.get_world_block(pos) != Blocks.REDSTONE_REPEATER_OFF:
		return
	if repeater_input_powered(manager, pos):
		# ChunkManager includes the changed cell in its production fanout,
		# so `_update_repeater` may already have queued the normal 2-tick
		# delay before the placement hook runs. Beta's onBlockAdded path is
		# explicitly the one-tick fast path; replace that entry rather than
		# retaining a stale second callback.
		TickScheduler.cancel(pos, Blocks.REDSTONE_REPEATER_OFF)
		TickScheduler.schedule(pos, Blocks.REDSTONE_REPEATER_OFF, 1)


# Scheduled transition. The unpowered branch always turns on once its tick
# arrives, even if a short input pulse ended in the meantime; in that case it
# queues the powered state to turn back off after the same delay. This is the
# Beta 1.3 minimum-pulse behavior, not an edge-trigger shortcut.
static func repeater_tick(manager, pos: Vector3i, block_id: int) -> void:
	var meta: int = manager.get_world_block_meta(pos)
	var input_powered: bool = repeater_input_powered(manager, pos, meta)
	if block_id == Blocks.REDSTONE_REPEATER_ON:
		if not input_powered:
			manager.set_world_block_state(pos, Blocks.REDSTONE_REPEATER_OFF, meta)
		return
	manager.set_world_block_state(pos, Blocks.REDSTONE_REPEATER_ON, meta)
	if not input_powered:
		TickScheduler.schedule(pos, Blocks.REDSTONE_REPEATER_ON, repeater_delay_ticks(meta))


# Neighbour update: validate the opaque support first, then schedule only
# when the current output disagrees with the rear input. TickScheduler's
# stale-ID guard naturally discards duplicate entries after the first state
# transition, matching vanilla's de-duplicated block-update set.
static func _update_repeater(manager, pos: Vector3i, block_id: int) -> void:
	if not is_normal_cube(manager, pos + Vector3i(0, -1, 0)):
		manager.set_world_block_state(pos, Blocks.AIR, 0)
		if manager.has_method("spawn_block_drop"):
			manager.call("spawn_block_drop", pos, Blocks.drops(block_id))
		return
	var meta: int = manager.get_world_block_meta(pos)
	var lit: bool = block_id == Blocks.REDSTONE_REPEATER_ON
	if lit != repeater_input_powered(manager, pos, meta):
		TickScheduler.schedule(pos, block_id, repeater_delay_ticks(meta))
