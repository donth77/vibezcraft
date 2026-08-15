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

# ap.java's inset detection box: (x+0.125, y, z+0.125) to
# (x+0.875, y+0.25, z+0.875). Standing at the very corner of the cell
# does NOT trip a plate.
const PLATE_BOX_INSET: float = 0.125
const PLATE_BOX_HEIGHT: float = 0.25

# Safety ceiling on a single propagation drain. A 15-decay network can
# only be so large, but a malformed world shouldn't be able to spin here.
const _WIRE_WORKLIST_CAP: int = 8192

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


# True for blocks that can act as a redstone source — vanilla
# `Block.e()` / `isPowerSource`. Wire is included: `lu.java:e()` returns
# its guard flag, which is true outside a wire recomputation.
static func is_power_source(id: int) -> bool:
	if id == Blocks.REDSTONE_WIRE:
		return _wire_output_enabled
	# bo.java:e() returns true for BOTH torch variants, so wire links to
	# an unlit torch as well as a lit one.
	return id == Blocks.LEVER or id == Blocks.REDSTONE_TORCH or id == Blocks.REDSTONE_TORCH_OFF


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
# is identical because wire power is a max-minus-decay fixpoint. The
# dedup set means CURRENTLY QUEUED, not "already seen" — a cell whose
# input changes again must be re-eligible or the net can settle on a
# stale value.
static func update_wire(manager, origin: Vector3i) -> void:
	if manager.get_world_block(origin) != Blocks.REDSTONE_WIRE:
		return
	var queue: Array[Vector3i] = [origin]
	var queued := {origin: true}
	# `visited` bounds the outward SCAN so an already-correct network
	# terminates; `queued` alone can't, because a cell must stay
	# re-enqueueable after its inputs move. A cell is re-examined
	# whenever a neighbour actually changes, regardless of visited.
	var visited := {}
	var notify: Array[Vector3i] = []
	var steps: int = 0
	while not queue.is_empty() and steps < _WIRE_WORKLIST_CAP:
		steps += 1
		var pos: Vector3i = queue.pop_front()
		queued.erase(pos)
		if manager.get_world_block(pos) != Blocks.REDSTONE_WIRE:
			continue
		var first_visit: bool = not visited.has(pos)
		visited[pos] = true
		var current: int = manager.get_world_block_meta(pos)
		var next: int = computed_wire_power(manager, pos)
		var changed: bool = next != current
		if changed:
			# Metadata-only write: no id change, so this depends on the
			# atomic state path notifying and re-meshing (§7.2). The
			# fanout is collected and issued once the whole net settles,
			# so consumers never observe a half-propagated line.
			manager.set_world_block_state(pos, Blocks.REDSTONE_WIRE, next, false)
			# Vanilla only fires block updates when the level crosses
			# zero (lu.java:104). 12 → 11 changes nothing downstream, and
			# skipping those is a large reduction in update churn.
			if current == 0 or next == 0:
				notify.append(pos)
		# Expand on the first visit (so an update seeded anywhere
		# reconciles its whole network — chunk load relies on this) and
		# again on every change (so the fixpoint is reached).
		if not (first_visit or changed):
			continue
		for neighbor: Vector3i in _wire_neighbors(manager, pos):
			if queued.has(neighbor):
				continue
			if not changed and visited.has(neighbor):
				continue
			queued[neighbor] = true
			queue.append(neighbor)
	if steps >= _WIRE_WORKLIST_CAP:
		push_warning("[Redstone] wire worklist hit its cap at %s" % origin)
	if manager.has_method("enqueue_block_notification"):
		for pos: Vector3i in notify:
			manager.call("enqueue_block_notification", pos)


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
# lives on the manager, so this only clears the fallback log and the
# wire recomputation guard.
static func reset_state() -> void:
	# Reassign rather than clear(): a plain in-place clear on this static
	# did NOT propagate to readers outside the class (verified by probe),
	# leaving burnout history alive across worlds and test cases.
	_fallback_burnout_log.clear()
	_wire_output_enabled = true


# --- Stone button (iy.java) --------------------------------------------


# Right-click. A pressed button ignores further clicks (iy.java:139)
# and releases itself on a scheduled tick.
static func press_button(manager, pos: Vector3i) -> bool:
	var meta: int = manager.get_world_block_meta(pos)
	if (meta & POWERED_BIT) != 0:
		return false
	manager.set_world_block_state(pos, Blocks.STONE_BUTTON, meta | POWERED_BIT)
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
static func update_plate(manager, pos: Vector3i, block_id: int) -> void:
	var occupied: bool = false
	if manager.has_method("entities_overlap_box"):
		occupied = bool(
			manager.call(
				"entities_overlap_box", plate_detection_box(pos), plate_living_only(block_id)
			)
		)
	var was_pressed: bool = manager.get_world_block_meta(pos) > 0
	if occupied and not was_pressed:
		manager.set_world_block_state(pos, block_id, 1)
		if manager.has_method("play_redstone_click"):
			manager.call("play_redstone_click", pos, true)
	elif not occupied and was_pressed:
		manager.set_world_block_state(pos, block_id, 0)
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
