# gdlint: disable=max-public-methods
extends GutTest

# The block-update state path (.claude/redstone-plan.md §7.2) — atomic
# id+meta commits and the notification queue that carries their fanout.
#
# These run against a REAL `ChunkManager` with a real `Chunk` bound into
# it, not a fake world. Every other redstone test uses a double, which is
# the right call for the power rules but means the plumbing underneath
# them — the queue's budget, its dedup key, whether a metadata-only write
# actually notifies — was never executed by anything except the running
# game.

const ChunkManagerScript := preload("res://scripts/world/chunk_manager.gd")
const ChunkNodeScript := preload("res://scripts/world/chunk_node.gd")

const Y: int = 64

var _cm: Node3D


func before_each() -> void:
	Redstone.reset_state()
	TickScheduler.reset_for_tests()
	# In the tree, because ChunkNode reads its own global transform — but
	# with no player, so `_process` returns immediately and no chunk
	# streaming or worker job ever starts.
	_cm = ChunkManagerScript.new()
	add_child_autofree(_cm)
	_bind_chunk(Vector2i(0, 0))


func after_each() -> void:
	Redstone.reset_state()
	TickScheduler.reset_for_tests()


func _bind_chunk(coord: Vector2i) -> Chunk:
	var chunk := Chunk.new()
	var node: Node3D = ChunkNodeScript.new()
	# `chunk_data` before `add_child`, the way ChunkManager does it —
	# ChunkNode._ready moves it into `chunk` and builds the mesh.
	node.chunk_data = chunk
	node.chunk = chunk
	_cm._chunks[coord] = node
	_cm.add_child(node)
	return chunk


func _pump_wire() -> void:
	while Redstone.has_pending_wire_work():
		Redstone.drain_wire_work(_cm, Redstone.WIRE_STEPS_PER_DRAIN)


# --- Atomic id + metadata ----------------------------------------------


func test_a_block_and_its_metadata_land_in_one_commit() -> void:
	# A lever placed on-state has to be visible as ON to the very first
	# neighbour update it triggers. Writing the id and then the meta
	# would fan out an OFF lever first and an ON one after.
	var pos := Vector3i(3, Y, 3)
	# Support first: a floor lever with nothing under it is legitimately
	# popped off by its own support check during this very fanout.
	_cm.set_world_block(pos + Vector3i(0, -1, 0), Blocks.STONE)
	_cm.set_world_block(pos, Blocks.LEVER, Redstone.MOUNT_FLOOR | Redstone.POWERED_BIT)
	assert_eq(_cm.get_world_block(pos), Blocks.LEVER, "id committed")
	assert_eq(
		_cm.get_world_block_meta(pos),
		Redstone.MOUNT_FLOOR | Redstone.POWERED_BIT,
		"metadata committed with it"
	)


func test_a_metadata_only_write_still_notifies() -> void:
	# Wire propagation writes metadata and nothing else. If the atomic
	# path treated "same id" as "nothing happened", a wire's level could
	# change with no downstream update at all.
	var pos := Vector3i(4, Y, 4)
	_cm.set_world_block(pos + Vector3i(0, -1, 0), Blocks.STONE)
	_cm.set_world_block(pos, Blocks.REDSTONE_WIRE, 0)
	_drain_everything()
	# Silent write: the level sticks, because nothing was told to look.
	_cm.set_world_block_state(pos, Blocks.REDSTONE_WIRE, 9, false)
	assert_eq(_cm.get_world_block_meta(pos), 9, "a silent write is not re-evaluated")
	# Same kind of write WITH the fanout: the update reaches this wire,
	# finds no source feeding it, and puts the level back to 0. That
	# round trip is only possible if a metadata-only write notifies.
	_cm.set_world_block_state(pos, Blocks.REDSTONE_WIRE, 12, true)
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(pos), 0, "the notified write was re-evaluated")


func test_an_unchanged_state_write_reports_no_change() -> void:
	# White wool, because its metadata is inert — a redstone block's level is
	# derived, so it would be rewritten by its own update before the
	# second call and this would test the wrong thing.
	var pos := Vector3i(5, Y, 5)
	assert_true(
		_cm.set_world_block_state(pos, Blocks.WOOL_WHITE, 7, false), "the first write is a change"
	)
	assert_false(
		_cm.set_world_block_state(pos, Blocks.WOOL_WHITE, 7, false),
		"writing the same id and meta is a no-op"
	)


# --- Notification queue ------------------------------------------------


func test_the_fanout_covers_the_changed_cell_and_its_six_neighbours() -> void:
	# vanilla World.applyPhysics — 7 cells, not 6.
	_cm._notify_draining = true
	_cm.enqueue_block_notification(Vector3i(8, Y, 8), Blocks.LEVER)
	assert_eq(_cm.pending_notification_count(), 7, "self plus six neighbours")
	_cm._notify_draining = false


func test_the_queue_dedups_on_cell_and_source() -> void:
	# Two different blocks changing next to one cell are two different
	# events in vanilla (`n5` differs), and the consumers that read the
	# source id would lose one of them if the key were the cell alone.
	_cm._notify_draining = true
	_cm.enqueue_block_notification(Vector3i(8, Y, 8), Blocks.LEVER)
	_cm.enqueue_block_notification(Vector3i(8, Y, 8), Blocks.LEVER)
	assert_eq(_cm.pending_notification_count(), 7, "the same event twice is one event")
	_cm.enqueue_block_notification(Vector3i(8, Y, 8), Blocks.STONE_BUTTON)
	assert_eq(_cm.pending_notification_count(), 14, "a different source is a different event")
	_cm._notify_draining = false


func test_a_drain_pauses_at_its_budget_and_keeps_the_rest() -> void:
	# The property that makes a cascade safe: work is never discarded, it
	# is deferred. `_process` resumes the queue on the next frame.
	var budget: int = _cm._NOTIFY_BUDGET_PER_DRAIN
	_cm._notify_draining = true
	var i: int = 0
	# Spread over a genuinely large cell space; the fanout overlaps
	# heavily, so a small one saturates below the budget and this loop
	# would never finish.
	while _cm.pending_notification_count() <= budget + 64 and i < 20000:
		var cell := Vector3i(i % 16, Y + (i / 16) % 60, (i / 960) % 16)
		_cm.enqueue_block_notification(cell, Blocks.LEVER)
		i += 1
	_cm._notify_draining = false
	var queued_before: int = _cm.pending_notification_count()
	assert_gt(queued_before, budget, "more queued than one drain can take")
	_cm.drain_block_notifications()
	var left: int = _cm.pending_notification_count()
	assert_gt(left, 0, "the drain paused instead of running to the end")
	assert_eq(left, queued_before - budget, "exactly one budget was consumed")
	_cm.drain_block_notifications()
	assert_eq(_cm.pending_notification_count(), 0, "the resume finishes the rest")


func test_a_write_made_during_a_drain_joins_the_same_queue() -> void:
	# Nested edits (a torch flipping while its own fanout is dispatching)
	# must not spawn a second recursive drain, and must not be dropped.
	_cm._notify_draining = true
	_cm.enqueue_block_notification(Vector3i(2, Y, 2), Blocks.LEVER)
	var during: int = _cm.pending_notification_count()
	_cm.enqueue_block_notification(Vector3i(2, Y, 3), Blocks.LEVER)
	assert_gt(_cm.pending_notification_count(), during, "the nested event was queued, not lost")
	_cm._notify_draining = false
	_cm.drain_block_notifications()
	assert_eq(_cm.pending_notification_count(), 0, "and both drain together")


# --- The two consumers that read the source id -------------------------


func test_breaking_a_block_reports_air_as_the_source() -> void:
	var pos := Vector3i(6, Y, 6)
	_cm.set_world_block(pos + Vector3i(0, -1, 0), Blocks.STONE)
	_cm.set_world_block(pos, Blocks.LEVER, Redstone.MOUNT_FLOOR)
	_drain_everything()
	_cm.set_world_block(pos, Blocks.AIR)
	_cm._notify_draining = true
	_cm.enqueue_block_notification(pos)
	# The default source is whatever now occupies the cell — AIR — which
	# is what stops "break the lever" from reading as a power event.
	var event: Vector4i = _cm._notify_queue[0]
	assert_eq(event.w, Blocks.AIR, "an emptied cell reports AIR")
	_cm._notify_draining = false


func test_the_default_source_is_the_block_now_in_the_cell() -> void:
	var pos := Vector3i(7, Y, 7)
	_cm.set_world_block(pos + Vector3i(0, -1, 0), Blocks.STONE)
	_cm.set_world_block(pos, Blocks.LEVER, Redstone.MOUNT_FLOOR)
	_drain_everything()
	_cm._notify_draining = true
	_cm.enqueue_block_notification(pos)
	assert_eq(_cm._notify_queue[0].w, Blocks.LEVER, "reports the placed block")
	_cm._notify_draining = false


# --- Wire through the real state path ----------------------------------


func test_wire_propagates_through_the_real_manager() -> void:
	# End to end on the shipping plumbing: a lever, a stone mount, and a
	# wire run, driven entirely by `set_world_block` and the queue.
	for x in range(0, 8):
		_cm.set_world_block(Vector3i(x, Y - 1, 2), Blocks.STONE)
		_cm.set_world_block(Vector3i(x, Y, 2), Blocks.REDSTONE_WIRE, 0)
	_cm.set_world_block(Vector3i(8, Y - 1, 2), Blocks.STONE)
	_cm.set_world_block(Vector3i(8, Y, 2), Blocks.STONE)
	_cm.set_world_block(Vector3i(9, Y, 2), Blocks.LEVER, Redstone.MOUNT_WEST_WALL)
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(Vector3i(7, Y, 2)), 0, "unpowered lever leaves it dark")

	_cm.set_world_block(
		Vector3i(9, Y, 2), Blocks.LEVER, Redstone.MOUNT_WEST_WALL | Redstone.POWERED_BIT
	)
	# What flipping the lever in-game does (pl.java:145-157): notify around
	# the lever AND around the block it is mounted on. The mount's other
	# neighbours are two cells from the lever, outside its own fanout, so
	# this second notification is the only thing that reaches the wire.
	Redstone.notify_around_mount(_cm, Vector3i(9, Y, 2), Blocks.LEVER)
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(Vector3i(7, Y, 2)), 15, "nearest cell reads 15")
	assert_eq(_cm.get_world_block_meta(Vector3i(6, Y, 2)), 14, "and decays one per step")
	assert_eq(_cm.get_world_block_meta(Vector3i(0, Y, 2)), 8, "seven steps out")


# --- Plate driving a door through a wire run ---------------------------


func test_a_plate_powers_a_wire_run_that_opens_an_iron_door() -> void:
	# Reported from a playtest: standing on a plate lit the wire but the
	# door stayed shut. This is that exact topology — plate, a run of
	# dust, and the door at the far end — driven through the real manager.
	var door := Vector3i(0, Y, 14)
	_build_iron_door(door)
	for x in range(1, 5):
		_cm.set_world_block(Vector3i(x, Y - 1, 14), Blocks.STONE)
		_cm.set_world_block(Vector3i(x, Y, 14), Blocks.REDSTONE_WIRE, 0)
	var plate := Vector3i(5, Y, 14)
	_cm.set_world_block(plate + Vector3i(0, -1, 0), Blocks.STONE)
	_cm.set_world_block(plate, Blocks.WOODEN_PRESSURE_PLATE, 0)
	_drain_everything()
	assert_false(_door_is_open(door), "shut to begin with")

	_cm.set_world_block_state(plate, Blocks.WOODEN_PRESSURE_PLATE, 1)
	Redstone.notify_around_support(_cm, plate, Blocks.WOODEN_PRESSURE_PLATE)
	_drain_everything()
	assert_gt(_cm.get_world_block_meta(Vector3i(4, Y, 14)), 0, "the run lit up")
	assert_true(_door_is_open(door), "and the door opened")

	_cm.set_world_block_state(plate, Blocks.WOODEN_PRESSURE_PLATE, 0)
	Redstone.notify_around_support(_cm, plate, Blocks.WOODEN_PRESSURE_PLATE)
	_drain_everything()
	assert_false(_door_is_open(door), "and shut again when released")


func test_a_wire_that_bends_right_before_a_door_does_not_open_it() -> void:
	# Vanilla lu.java:270-280: a corner powers NOTHING horizontally. This
	# is the most likely explanation when a circuit lights up but its
	# consumer stays dead, so it is pinned as intended behaviour rather
	# than left to look like the bug above.
	var door := Vector3i(0, Y, 10)
	_build_iron_door(door)
	# Run comes in along X then turns north at the cell beside the door.
	for x in range(1, 4):
		_cm.set_world_block(Vector3i(x, Y - 1, 10), Blocks.STONE)
		_cm.set_world_block(Vector3i(x, Y, 10), Blocks.REDSTONE_WIRE, 0)
	_cm.set_world_block(Vector3i(1, Y - 1, 9), Blocks.STONE)
	_cm.set_world_block(Vector3i(1, Y, 9), Blocks.REDSTONE_WIRE, 0)
	_cm.set_world_block(Vector3i(4, Y, 10), Blocks.STONE)
	_cm.set_world_block(
		Vector3i(5, Y, 10), Blocks.LEVER, Redstone.MOUNT_WEST_WALL | Redstone.POWERED_BIT
	)
	Redstone.notify_around_mount(_cm, Vector3i(5, Y, 10), Blocks.LEVER)
	_drain_everything()
	assert_gt(_cm.get_world_block_meta(Vector3i(1, Y, 10)), 0, "the run is lit")
	assert_false(_door_is_open(door), "but a corner feeds nothing sideways — vanilla")


func test_a_button_beside_the_last_wire_cell_kills_the_doors_power() -> void:
	# Reported from a playtest as "a button next to the iron door messed
	# up the circuit". It is expected, and it is the same rule as the
	# corner above — just much harder to see coming.
	#
	# Wire CONNECTS to a button whether or not it is pressed
	# (lu.java:295 asks `Block.e()`, a class property that takes no
	# metadata). So parking a button beside the run's last cell gives that
	# cell a second, perpendicular connection — turning a straight into a
	# corner. The wire still lights up; it just stops feeding sideways.
	var door := Vector3i(0, Y, 12)
	_build_iron_door(door)
	for x in range(1, 4):
		_cm.set_world_block(Vector3i(x, Y - 1, 12), Blocks.STONE)
		_cm.set_world_block(Vector3i(x, Y, 12), Blocks.REDSTONE_WIRE, 0)
	# The button, on its own block, north of the run's last cell — built
	# BEFORE the circuit is powered, which is the order a player works in.
	_cm.set_world_block(Vector3i(1, Y, 10), Blocks.STONE)
	_cm.set_world_block(Vector3i(1, Y, 11), Blocks.STONE_BUTTON, Redstone.MOUNT_NORTH_WALL)
	_cm.set_world_block(Vector3i(4, Y, 12), Blocks.STONE)
	_cm.set_world_block(
		Vector3i(5, Y, 12), Blocks.LEVER, Redstone.MOUNT_WEST_WALL | Redstone.POWERED_BIT
	)
	Redstone.notify_around_mount(_cm, Vector3i(5, Y, 12), Blocks.LEVER)
	_drain_everything()
	assert_gt(_cm.get_world_block_meta(Vector3i(1, Y, 12)), 0, "the wire lights up")
	assert_false(_door_is_open(door), "but the bend means it feeds the door nothing")


func test_the_same_run_without_the_button_does_open_the_door() -> void:
	# The control. Without it the test above would pass for any reason at
	# all — a broken run, an unpowered lever, a door that never opens.
	var door := Vector3i(0, Y, 12)
	_build_iron_door(door)
	for x in range(1, 4):
		_cm.set_world_block(Vector3i(x, Y - 1, 12), Blocks.STONE)
		_cm.set_world_block(Vector3i(x, Y, 12), Blocks.REDSTONE_WIRE, 0)
	_cm.set_world_block(Vector3i(4, Y, 12), Blocks.STONE)
	_cm.set_world_block(
		Vector3i(5, Y, 12), Blocks.LEVER, Redstone.MOUNT_WEST_WALL | Redstone.POWERED_BIT
	)
	Redstone.notify_around_mount(_cm, Vector3i(5, Y, 12), Blocks.LEVER)
	_drain_everything()
	assert_true(_door_is_open(door), "a straight run does open it")


# --- Entity contact, through the real manager --------------------------


func _capsule_at(feet: Vector3) -> Node3D:
	var body := CharacterBody3D.new()
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.8
	capsule.radius = 0.3
	shape.shape = capsule
	body.add_child(shape)
	_cm.add_child(body)
	body.global_position = feet + Vector3(0.0, 0.9, 0.0)
	return body


func test_the_managers_own_sweep_presses_a_plate_under_the_player() -> void:
	# The last untested seam, and the same shape as every bug this
	# feature has had: the geometry is covered in test_entity_bounds.gd
	# and the plate logic in test_redstone_inputs.gd, but nothing checked
	# that ChunkManager actually WIRES the two together.
	var plate := Vector3i(6, Y, 6)
	_cm.set_world_block(plate + Vector3i(0, -1, 0), Blocks.STONE)
	_cm.set_world_block(plate, Blocks.WOODEN_PRESSURE_PLATE, 0)
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(plate), 0, "starts released")

	_cm._player = _capsule_at(Vector3(plate) + Vector3(0.5, 0.0, 0.5))
	_cm._sweep_player_block_contact()
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(plate), 1, "the sweep pressed it")


func test_a_dropped_entity_presses_a_wooden_plate_but_not_a_stone_one() -> void:
	# lg.a vs lg.b through the real contact route rather than a fake.
	for pair: Array in [[Blocks.WOODEN_PRESSURE_PLATE, 1], [Blocks.STONE_PRESSURE_PLATE, 0]]:
		var plate := Vector3i(9, Y, 9)
		_cm.set_world_block(plate + Vector3i(0, -1, 0), Blocks.STONE)
		_cm.set_world_block(plate, int(pair[0]), 0)
		_drain_everything()
		var item := DroppedItem.new()
		_cm.add_child(item)
		item.global_position = Vector3(plate) + Vector3(0.5, 0.1, 0.5)
		_cm.report_entity_contact(item)
		_drain_everything()
		assert_eq(
			_cm.get_world_block_meta(plate),
			int(pair[1]),
			"%s under a dropped item" % Blocks.name_of(int(pair[0]))
		)
		item.free()
		_cm.set_world_block(plate, Blocks.AIR)
		_drain_everything()


func test_contact_only_fires_when_the_entity_changes_cell() -> void:
	# The throttle. Without it every physics frame would re-enter the
	# plate path, and TickScheduler permits duplicates.
	var plate := Vector3i(11, Y, 11)
	_cm.set_world_block(plate + Vector3i(0, -1, 0), Blocks.STONE)
	_cm.set_world_block(plate, Blocks.WOODEN_PRESSURE_PLATE, 0)
	_drain_everything()
	_cm._player = _capsule_at(Vector3(plate) + Vector3(0.5, 0.0, 0.5))
	_cm._sweep_player_block_contact()
	_drain_everything()
	var settled: int = TickScheduler.pending_count()
	for _i in range(30):
		_cm._sweep_player_block_contact()
	assert_eq(TickScheduler.pending_count(), settled, "30 stationary frames queue nothing new")


# --- Consumers, driven through the real manager ------------------------


func _build_iron_door(at: Vector3i) -> void:
	_cm.set_world_block(at + Vector3i(0, -1, 0), Blocks.STONE)
	_cm.set_world_block(at, Blocks.IRON_DOOR, 0)
	_cm.set_world_block(at + Vector3i(0, 1, 0), Blocks.IRON_DOOR, 8)


func _door_is_open(at: Vector3i) -> bool:
	return (_cm.get_world_block_meta(at) & 4) != 0


func test_a_lever_beside_an_iron_door_opens_and_closes_it() -> void:
	var door := Vector3i(2, Y, 12)
	var mount := Vector3i(3, Y, 12)
	_build_iron_door(door)
	_cm.set_world_block(mount, Blocks.STONE)
	_cm.set_world_block(Vector3i(4, Y, 12), Blocks.LEVER, Redstone.MOUNT_WEST_WALL)
	_drain_everything()
	assert_false(_door_is_open(door), "shut while the lever is off")

	_cm.set_world_block(
		Vector3i(4, Y, 12), Blocks.LEVER, Redstone.MOUNT_WEST_WALL | Redstone.POWERED_BIT
	)
	Redstone.notify_around_mount(_cm, Vector3i(4, Y, 12), Blocks.LEVER)
	_drain_everything()
	assert_true(_door_is_open(door), "opens on power")

	_cm.set_world_block(Vector3i(4, Y, 12), Blocks.LEVER, Redstone.MOUNT_WEST_WALL)
	Redstone.notify_around_mount(_cm, Vector3i(4, Y, 12), Blocks.LEVER)
	_drain_everything()
	assert_false(_door_is_open(door), "closes again")


func test_a_button_drives_an_iron_door() -> void:
	var door := Vector3i(2, Y, 4)
	_build_iron_door(door)
	_cm.set_world_block(Vector3i(3, Y, 4), Blocks.STONE)
	_cm.set_world_block(Vector3i(4, Y, 4), Blocks.STONE_BUTTON, Redstone.MOUNT_WEST_WALL)
	_drain_everything()
	assert_true(Redstone.press_button(_cm, Vector3i(4, Y, 4)), "button presses")
	_drain_everything()
	assert_true(_door_is_open(door), "the pulse opens the door")

	Redstone.button_tick(_cm, Vector3i(4, Y, 4))
	_drain_everything()
	assert_false(_door_is_open(door), "and it shuts when the button releases")


func test_a_pressure_plate_drives_an_iron_door() -> void:
	var door := Vector3i(2, Y, 6)
	var plate := Vector3i(3, Y, 6)
	_build_iron_door(door)
	_cm.set_world_block(plate + Vector3i(0, -1, 0), Blocks.STONE)
	_cm.set_world_block(plate, Blocks.WOODEN_PRESSURE_PLATE, 0)
	_drain_everything()
	# Press it directly — entity detection has its own coverage in
	# tests/test_entity_bounds.gd; what matters here is that a pressed
	# plate reaches the door through the real notification queue.
	_cm.set_world_block_state(plate, Blocks.WOODEN_PRESSURE_PLATE, 1)
	Redstone.notify_around_support(_cm, plate, Blocks.WOODEN_PRESSURE_PLATE)
	_drain_everything()
	assert_true(_door_is_open(door), "a pressed plate opens the door")

	_cm.set_world_block_state(plate, Blocks.WOODEN_PRESSURE_PLATE, 0)
	Redstone.notify_around_support(_cm, plate, Blocks.WOODEN_PRESSURE_PLATE)
	_drain_everything()
	assert_false(_door_is_open(door), "and releasing it shuts the door")


func test_wire_drives_an_iron_door_at_the_end_of_a_run() -> void:
	# The full chain: lever → mount → wire run → door.
	var door := Vector3i(0, Y, 8)
	_build_iron_door(door)
	for x in range(1, 6):
		_cm.set_world_block(Vector3i(x, Y - 1, 8), Blocks.STONE)
		_cm.set_world_block(Vector3i(x, Y, 8), Blocks.REDSTONE_WIRE, 0)
	_cm.set_world_block(Vector3i(6, Y, 8), Blocks.STONE)
	_cm.set_world_block(Vector3i(7, Y, 8), Blocks.LEVER, Redstone.MOUNT_WEST_WALL)
	_drain_everything()
	assert_false(_door_is_open(door), "dark run leaves the door shut")

	_cm.set_world_block(
		Vector3i(7, Y, 8), Blocks.LEVER, Redstone.MOUNT_WEST_WALL | Redstone.POWERED_BIT
	)
	Redstone.notify_around_mount(_cm, Vector3i(7, Y, 8), Blocks.LEVER)
	_drain_everything()
	assert_gt(_cm.get_world_block_meta(Vector3i(1, Y, 8)), 0, "the run is live")
	assert_true(_door_is_open(door), "and the far end opens the door")


# --- Removal of a still-powered switch ---------------------------------


func test_destroying_a_powered_lever_depowers_what_it_drove_through_its_mount() -> void:
	# F4 in the playtest guide, and the case the seven-cell fanout alone
	# cannot reach: the door is adjacent to the MOUNT, two cells from the
	# lever. Vanilla's Block.onBlockRemoval pushes a final update around
	# the mount for exactly this.
	var mount := Vector3i(4, Y, 9)
	var lever := Vector3i(5, Y, 9)
	var door := Vector3i(3, Y, 9)
	_cm.set_world_block(mount, Blocks.STONE)
	_cm.set_world_block(door, Blocks.IRON_DOOR, 0)
	_cm.set_world_block(door + Vector3i(0, 1, 0), Blocks.IRON_DOOR, 8)
	_cm.set_world_block(lever, Blocks.LEVER, Redstone.MOUNT_WEST_WALL | Redstone.POWERED_BIT)
	Redstone.notify_around_mount(_cm, lever, Blocks.LEVER)
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(door) & 4, 4, "the door opened")

	# Blow it up / wash it away — any id change routes through here.
	_cm.set_world_block(lever, Blocks.AIR)
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(door) & 4, 0, "and closed again when the lever went")


func test_removing_an_unpowered_lever_notifies_nothing_extra() -> void:
	var recorder := _MountRecorder.new()
	Redstone.on_block_removed(recorder, Vector3i(5, Y, 9), Blocks.LEVER, Redstone.MOUNT_WEST_WALL)
	assert_eq(recorder.notified, [], "an off lever had no power to withdraw")
	Redstone.on_block_removed(
		recorder, Vector3i(5, Y, 9), Blocks.LEVER, Redstone.MOUNT_WEST_WALL | Redstone.POWERED_BIT
	)
	assert_eq(recorder.notified, [Vector3i(4, Y, 9)], "an on lever notifies its mount")


class _MountRecorder:
	extends RefCounted
	var notified: Array = []

	func get_world_block(_pos: Vector3i) -> int:
		return Blocks.AIR

	func get_world_block_meta(_pos: Vector3i) -> int:
		return 0

	func enqueue_block_notification(pos: Vector3i, _source_id: int = -1) -> void:
		notified.append(pos)


func test_live_power_crosses_a_chunk_boundary() -> void:
	# Reported from a playtest: a long dust run spanning two chunks lights
	# up on the lever's side of the seam and stays dark on the other.
	#
	# No reconcile call here — this is the plain runtime path a lever flip
	# takes, with both chunks already loaded.
	_bind_chunk(Vector2i(-1, 0))
	# Run from x = -8 (chunk -1) to x = +7 (chunk 0), crossing x = 0.
	for x in range(-8, 8):
		_cm.set_world_block(Vector3i(x, Y - 1, 3), Blocks.STONE)
		_cm.set_world_block(Vector3i(x, Y, 3), Blocks.REDSTONE_WIRE, 0)
	_cm.set_world_block(Vector3i(-9, Y, 3), Blocks.STONE)
	_cm.set_world_block(Vector3i(-10, Y, 3), Blocks.LEVER, Redstone.MOUNT_EAST_WALL)
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(Vector3i(-8, Y, 3)), 0, "dark to begin with")

	_cm.set_world_block(
		Vector3i(-10, Y, 3), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT
	)
	Redstone.notify_around_mount(_cm, Vector3i(-10, Y, 3), Blocks.LEVER)
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(Vector3i(-8, Y, 3)), 15, "lit at the source end")
	assert_eq(_cm.get_world_block_meta(Vector3i(-1, Y, 3)), 8, "still lit at the seam")
	assert_gt(_cm.get_world_block_meta(Vector3i(0, Y, 3)), 0, "and lit ACROSS the seam")
	assert_eq(_cm.get_world_block_meta(Vector3i(1, Y, 3)), 6, "decaying correctly beyond it")


func test_both_chunks_are_marked_dirty_when_power_crosses() -> void:
	# Even with the levels correct, the far chunk has to re-mesh or the
	# run just LOOKS dark past the seam — which is what a player sees.
	_bind_chunk(Vector2i(-1, 0))
	for x in range(-4, 4):
		_cm.set_world_block(Vector3i(x, Y - 1, 5), Blocks.STONE)
		_cm.set_world_block(Vector3i(x, Y, 5), Blocks.REDSTONE_WIRE, 0)
	_cm.set_world_block(Vector3i(-5, Y, 5), Blocks.STONE)
	_cm.set_world_block(Vector3i(-6, Y, 5), Blocks.LEVER, Redstone.MOUNT_EAST_WALL)
	_drain_everything()
	_cm._chunks[Vector2i(0, 0)].chunk.dirty = false
	_cm._chunks[Vector2i(-1, 0)].chunk.dirty = false

	_cm.set_world_block(
		Vector3i(-6, Y, 5), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT
	)
	Redstone.notify_around_mount(_cm, Vector3i(-6, Y, 5), Blocks.LEVER)
	_drain_everything()
	assert_true(_cm._chunks[Vector2i(-1, 0)].chunk.dirty, "source chunk re-meshes")
	assert_true(_cm._chunks[Vector2i(0, 0)].chunk.dirty, "far chunk re-meshes too")


# --- Chunk materialize / reload reconciliation -------------------------


func test_a_reloaded_chunk_repairs_wire_metadata_at_its_seam() -> void:
	# The Track F case a fake world can't reach: a chunk comes back from
	# disk holding whatever level its wire had when it was saved, but the
	# source on the OTHER side of the seam changed while it was away.
	# `_reconcile_redstone_edges` is the only thing that fixes it.
	var west: Chunk = _bind_chunk(Vector2i(-1, 0))
	# Wire run crossing x = 0, powered by a lever in the west chunk.
	for x in range(-6, 6):
		_cm.set_world_block(Vector3i(x, Y - 1, 5), Blocks.STONE)
		_cm.set_world_block(Vector3i(x, Y, 5), Blocks.REDSTONE_WIRE, 0)
	_cm.set_world_block(Vector3i(-7, Y, 5), Blocks.STONE)
	_cm.set_world_block(
		Vector3i(-8, Y, 5), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT
	)
	Redstone.notify_around_mount(_cm, Vector3i(-8, Y, 5), Blocks.LEVER)
	_drain_everything()
	assert_gt(_cm.get_world_block_meta(Vector3i(0, Y, 5)), 0, "powered across the seam")

	# Simulate the east chunk having been on disk with a stale level:
	# rewrite its cells silently, the way a load would.
	var east: Chunk = _cm._chunks[Vector2i(0, 0)].chunk
	for x in range(0, 6):
		east.set_block_meta(x, Y, 5, 2)
	assert_eq(_cm.get_world_block_meta(Vector3i(3, Y, 5)), 2, "stale value in place")

	_cm._reconcile_redstone_edges(Vector2i(0, 0), east)
	_drain_everything()
	assert_eq(_cm.get_world_block_meta(Vector3i(0, Y, 5)), 9, "seam cell repaired")
	assert_eq(_cm.get_world_block_meta(Vector3i(3, Y, 5)), 6, "and so is the run inland")
	assert_not_null(west, "west chunk stayed bound")


func test_reconciliation_skips_a_chunk_with_no_wire_in_it() -> void:
	# The fast bail. Chunk streaming materialises many chunks a second
	# and virtually none contain wire; without this the seam walk would
	# be on the hot path for every one of them.
	var far: Chunk = _bind_chunk(Vector2i(4, 4))
	_cm._reconcile_redstone_edges(Vector2i(4, 4), far)
	assert_false(Redstone.has_pending_wire_work(), "no burst was even started")


func _drain_everything() -> void:
	for _i in range(64):
		_cm.drain_block_notifications()
		_pump_wire()
		if _cm.pending_notification_count() == 0 and not Redstone.has_pending_wire_work():
			return
