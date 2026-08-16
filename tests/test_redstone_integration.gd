extends GutTest

# Phase 8b — consumers driven by the power model
# (.claude/redstone-plan.md §3.7). Doors and TNT are the only two things
# Alpha wires up besides wire itself, and both read cy.o()
# (is_block_indirectly_powered).
#
# Fake world implements only what Redstone needs. The optional
# has_method callbacks (spawn_block_drop / prime_tnt / play_door_sound)
# are declared here so the test can assert they fire without dragging in
# the scene tree.

const DOOR_LOWER := Vector3i(0, 64, 0)
const DOOR_UPPER := Vector3i(0, 65, 0)
# Solid block west of the door that a lever can energise.
const RELAY := Vector3i(-1, 64, 0)
const LEVER_POS := Vector3i(-2, 64, 0)


class FakeWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var drops: Array = []
	var primed: Array = []
	var door_sounds: int = 0

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block_state(pos: Vector3i, id: int, meta: int, _notify: bool = true) -> bool:
		var old_id: int = blocks.get(pos, Blocks.AIR)
		var old_meta: int = metas.get(pos, 0)
		if old_id == id and old_meta == (meta & 0xF):
			return false
		blocks[pos] = id
		metas[pos] = meta & 0xF
		return true

	func spawn_block_drop(pos: Vector3i, dropped_id: int) -> void:
		drops.append([pos, dropped_id])

	func prime_tnt(pos: Vector3i) -> void:
		primed.append(pos)

	func play_door_sound(_pos: Vector3i) -> void:
		door_sounds += 1

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _w: FakeWorld


func before_each() -> void:
	_w = FakeWorld.new()


func _build_door(id: int, open: bool = false) -> void:
	var lower_meta: int = 4 if open else 0
	_w.put(DOOR_LOWER, id, lower_meta)
	_w.put(DOOR_UPPER, id, lower_meta + 8)


func _place_lever(on: bool) -> void:
	_w.put(RELAY, Blocks.STONE)
	var meta: int = Redstone.MOUNT_EAST_WALL | (Redstone.POWERED_BIT if on else 0)
	_w.put(LEVER_POS, Blocks.LEVER, meta)


# --- Doors (gv.java:156) ---


func test_powered_lever_opens_a_wooden_door() -> void:
	_build_door(Blocks.WOODEN_DOOR)
	_place_lever(true)
	Redstone.on_neighbor_changed(_w, DOOR_LOWER)
	assert_eq(_w.get_world_block_meta(DOOR_LOWER) & 4, 4, "lower half open")
	assert_eq(_w.get_world_block_meta(DOOR_UPPER) & 4, 4, "upper half follows")
	assert_eq(_w.door_sounds, 1, "door sound played once")


func test_powered_lever_opens_an_iron_door() -> void:
	# Iron doors are hand-immune but must still obey redstone — that's
	# the entire point of an iron door in Alpha.
	_build_door(Blocks.IRON_DOOR)
	_place_lever(true)
	Redstone.on_neighbor_changed(_w, DOOR_LOWER)
	assert_eq(_w.get_world_block_meta(DOOR_LOWER) & 4, 4, "iron door opens on power")


func test_unpowered_lever_leaves_the_door_shut() -> void:
	_build_door(Blocks.WOODEN_DOOR)
	_place_lever(false)
	Redstone.on_neighbor_changed(_w, DOOR_LOWER)
	assert_eq(_w.get_world_block_meta(DOOR_LOWER) & 4, 0, "stays closed")
	assert_eq(_w.door_sounds, 0, "no sound when nothing changed")


func test_removing_power_closes_an_open_door() -> void:
	_build_door(Blocks.WOODEN_DOOR, true)
	_place_lever(false)
	Redstone.on_neighbor_changed(_w, DOOR_LOWER)
	assert_eq(_w.get_world_block_meta(DOOR_LOWER) & 4, 0, "closes when power drops")


func test_power_at_either_half_opens_the_door() -> void:
	# gv.java checks o(x,y,z) || o(x,y+1,z): a signal reaching only the
	# TOP cell must still open the pair.
	_build_door(Blocks.WOODEN_DOOR)
	_w.put(Vector3i(-1, 65, 0), Blocks.STONE)
	_w.put(Vector3i(-2, 65, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	Redstone.on_neighbor_changed(_w, DOOR_LOWER)
	assert_eq(_w.get_world_block_meta(DOOR_LOWER) & 4, 4, "upper-half signal opens both")


func test_door_notified_via_its_upper_half_still_drives_the_pair() -> void:
	_build_door(Blocks.WOODEN_DOOR)
	_place_lever(true)
	Redstone.on_neighbor_changed(_w, DOOR_UPPER)
	assert_eq(_w.get_world_block_meta(DOOR_LOWER) & 4, 4, "resolved from the lower half")
	assert_eq(_w.get_world_block_meta(DOOR_UPPER) & 4, 4, "upper mirrors")


func test_repeat_notification_does_not_re_toggle() -> void:
	_build_door(Blocks.WOODEN_DOOR)
	_place_lever(true)
	for _i in range(5):
		Redstone.on_neighbor_changed(_w, DOOR_LOWER)
	assert_eq(_w.get_world_block_meta(DOOR_LOWER) & 4, 4, "still open, not flapping")
	assert_eq(_w.door_sounds, 1, "sound only on the actual transition")


# --- TNT (v.java:23) ---


func test_powered_tnt_primes_and_clears_its_cell() -> void:
	var tnt := Vector3i(0, 64, 0)
	_w.put(tnt, Blocks.TNT)
	_w.put(tnt + Vector3i(-1, 0, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	Redstone.on_neighbor_changed(_w, tnt, Blocks.LEVER)
	assert_eq(_w.get_world_block(tnt), Blocks.AIR, "block consumed")
	assert_eq(_w.primed.size(), 1, "one primed entity spawned")
	assert_eq(_w.primed[0], tnt, "at the TNT's cell")


func test_unpowered_tnt_stays_put() -> void:
	var tnt := Vector3i(0, 64, 0)
	_w.put(tnt, Blocks.TNT)
	_w.put(tnt + Vector3i(-1, 0, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL)
	Redstone.on_neighbor_changed(_w, tnt, Blocks.LEVER)
	assert_eq(_w.get_world_block(tnt), Blocks.TNT, "not primed")
	assert_eq(_w.primed.size(), 0, "no entity")


func test_tnt_primes_through_a_relay_block() -> void:
	var tnt := Vector3i(0, 64, 0)
	_w.put(tnt, Blocks.TNT)
	_w.put(RELAY, Blocks.STONE)
	_w.put(LEVER_POS, Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	# The changed neighbour here is the STONE relay, which is not itself a
	# power source — but vanilla still primes, because the notification
	# that reaches the TNT carries the id of the block that changed at the
	# ORIGIN of the fanout (the lever), not the relay in between.
	Redstone.on_neighbor_changed(_w, tnt, Blocks.LEVER)
	assert_eq(_w.primed.size(), 1, "strong power relayed through stone reaches TNT")


func test_already_powered_tnt_ignores_an_unrelated_neighbour_change() -> void:
	# v.java:23 guards on `nq.m[n5].e()` — the block that CHANGED has to
	# be able to provide power. Without that clause, TNT sitting in an
	# already-powered cell detonates the moment anything at all is edited
	# next to it: place a torch two cells away, walk a chunk boundary,
	# reload a region. The power state is identical in both calls below;
	# only the changed-neighbour id differs.
	var tnt := Vector3i(0, 64, 0)
	_w.put(tnt, Blocks.TNT)
	_w.put(tnt + Vector3i(-1, 0, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	assert_true(Redstone.is_block_indirectly_powered(_w, tnt), "TNT cell is powered")
	# Someone stacks a dirt block on top. Dirt cannot provide power.
	_w.put(tnt + Vector3i(0, 1, 0), Blocks.DIRT)
	Redstone.on_neighbor_changed(_w, tnt, Blocks.DIRT)
	assert_eq(_w.get_world_block(tnt), Blocks.TNT, "unrelated neighbour does not ignite")
	assert_eq(_w.primed.size(), 0, "no primed entity")
	# A source-capable neighbour change on the same powered cell still does.
	Redstone.on_neighbor_changed(_w, tnt, Blocks.LEVER)
	assert_eq(_w.primed.size(), 1, "a power-source change still primes")


func test_breaking_a_source_reports_air_and_cannot_ignite_tnt() -> void:
	# Removing a block notifies with AIR (vanilla passes the new id), and
	# `n5 > 0` rejects it. Prevents the "break the lever, blow up the TNT"
	# inversion.
	var tnt := Vector3i(0, 64, 0)
	_w.put(tnt, Blocks.TNT)
	_w.put(tnt + Vector3i(-1, 0, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	Redstone.on_neighbor_changed(_w, tnt, Blocks.AIR)
	assert_eq(_w.get_world_block(tnt), Blocks.TNT, "AIR origin never primes")
	assert_eq(_w.primed.size(), 0, "no primed entity")


# --- Mounted-component support loss (pl.java:h) ---


func test_lever_pops_off_when_its_support_disappears() -> void:
	_w.put(LEVER_POS, Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	# RELAY (the mount) is left as AIR.
	Redstone.on_neighbor_changed(_w, LEVER_POS)
	assert_eq(_w.get_world_block(LEVER_POS), Blocks.AIR, "lever removed")
	assert_eq(_w.drops.size(), 1, "dropped as an item")
	assert_eq(_w.drops[0][1], Blocks.LEVER, "drops itself")


func test_lever_stays_while_supported() -> void:
	_place_lever(true)
	Redstone.on_neighbor_changed(_w, LEVER_POS)
	assert_eq(_w.get_world_block(LEVER_POS), Blocks.LEVER, "still mounted")
	assert_eq(_w.drops.size(), 0, "no drop")


func test_floor_lever_needs_the_block_below() -> void:
	var pos := Vector3i(3, 64, 3)
	_w.put(pos, Blocks.LEVER, Redstone.MOUNT_FLOOR | Redstone.POWERED_BIT)
	Redstone.on_neighbor_changed(_w, pos)
	assert_eq(_w.get_world_block(pos), Blocks.AIR, "no floor → pops off")
	_w = FakeWorld.new()
	_w.put(pos + Vector3i(0, -1, 0), Blocks.STONE)
	_w.put(pos, Blocks.LEVER, Redstone.MOUNT_FLOOR_ALT | Redstone.POWERED_BIT)
	Redstone.on_neighbor_changed(_w, pos)
	assert_eq(_w.get_world_block(pos), Blocks.LEVER, "supported alt rotation stays")


func test_non_redstone_cells_are_ignored_by_the_dispatch() -> void:
	var pos := Vector3i(5, 64, 5)
	_w.put(pos, Blocks.STONE)
	Redstone.on_neighbor_changed(_w, pos)
	assert_eq(_w.get_world_block(pos), Blocks.STONE, "untouched")
	assert_eq(_w.drops.size(), 0, "no side effects")
