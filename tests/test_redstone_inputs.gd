# gdlint: disable=max-public-methods
extends GutTest

# Phase 8e — stone button and both pressure plates
# (.claude/redstone-plan.md §§3.5, 3.6).
#
# The button is Alpha's only momentary source: it releases itself after
# exactly 20 ticks. The two plates differ in ONE respect — what counts
# as an entity — and that difference is the reason both exist.

const Y: int = 64
const SUPPORT := Vector3i(0, 63, 0)
const PLATE := Vector3i(0, 64, 0)
const WALL := Vector3i(0, 64, 0)
const BUTTON := Vector3i(1, 64, 0)


class FakeWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var drops: Array = []
	var clicks: Array = []
	# Entities as {position, living} — the manager's overlap query is
	# replaced by this list so cases don't need a scene tree.
	var entities: Array = []

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

	func entities_overlap_box(box: AABB, living_only: bool) -> bool:
		for e: Dictionary in entities:
			if living_only and not bool(e["living"]):
				continue
			if box.has_point(e["pos"] as Vector3):
				return true
		return false

	func spawn_block_drop(pos: Vector3i, dropped_id: int) -> void:
		drops.append([pos, dropped_id])

	func play_redstone_click(pos: Vector3i, on: bool) -> void:
		clicks.append([pos, on])

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _w: FakeWorld


func before_each() -> void:
	TickScheduler.reset_for_tests()
	Redstone.reset_state()
	_w = FakeWorld.new()


func after_each() -> void:
	TickScheduler.reset_for_tests()


func _place_button() -> void:
	_w.put(Vector3i(0, Y, 0), Blocks.STONE)
	_w.put(BUTTON, Blocks.STONE_BUTTON, Redstone.MOUNT_WEST_WALL)


func _place_plate(id: int) -> void:
	_w.put(SUPPORT, Blocks.STONE)
	_w.put(PLATE, id, 0)


func _stand(living: bool, at: Vector3 = Vector3(0.5, 64.05, 0.5)) -> void:
	_w.entities.append({"pos": at, "living": living})


# --- Button: the 20-tick pulse ---


func test_pressing_powers_the_button() -> void:
	_place_button()
	assert_true(Redstone.press_button(_w, BUTTON), "press accepted")
	assert_eq(
		_w.get_world_block_meta(BUTTON) & Redstone.POWERED_BIT,
		Redstone.POWERED_BIT,
		"pressed bit set"
	)


func test_press_preserves_mount_orientation() -> void:
	_place_button()
	Redstone.press_button(_w, BUTTON)
	assert_eq(_w.get_world_block_meta(BUTTON) & 0x7, Redstone.MOUNT_WEST_WALL, "orientation intact")


func test_pressing_an_already_pressed_button_is_rejected() -> void:
	_place_button()
	Redstone.press_button(_w, BUTTON)
	assert_false(Redstone.press_button(_w, BUTTON), "second press does nothing")
	assert_eq(TickScheduler.pending_count(), 1, "and does not stack another release")


func test_button_releases_after_exactly_twenty_ticks() -> void:
	_place_button()
	Redstone.press_button(_w, BUTTON)
	for _i in range(19):
		TickScheduler.advance(0.05, _w)
	assert_eq(
		_w.get_world_block_meta(BUTTON) & Redstone.POWERED_BIT,
		Redstone.POWERED_BIT,
		"still held at tick 19"
	)
	TickScheduler.advance(0.05, _w)
	assert_eq(_w.get_world_block_meta(BUTTON) & Redstone.POWERED_BIT, 0, "released on tick 20")


func test_button_click_sounds_go_up_then_down() -> void:
	_place_button()
	Redstone.press_button(_w, BUTTON)
	for _i in range(20):
		TickScheduler.advance(0.05, _w)
	assert_eq(_w.clicks.size(), 2, "one click each way")
	assert_true(bool(_w.clicks[0][1]), "press is the ON pitch")
	assert_false(bool(_w.clicks[1][1]), "release is the OFF pitch")


func test_pressed_button_powers_every_direction_weakly() -> void:
	_place_button()
	Redstone.press_button(_w, BUTTON)
	for slot in range(6):
		assert_true(Redstone.provides_weak_power(_w, BUTTON, slot), "weak slot %d" % slot)


func test_button_strong_powers_only_its_mount() -> void:
	_place_button()
	Redstone.press_button(_w, BUTTON)
	for slot in range(6):
		assert_eq(
			Redstone.provides_strong_power(_w, BUTTON, slot),
			slot == Redstone.SLOT_EAST,
			(
				"a west-wall mount strong-powers SLOT_EAST — the mount block sees "
				+ "the button at its +X — not slot %d" % slot
			)
		)


func test_unpressed_button_powers_nothing() -> void:
	_place_button()
	for slot in range(6):
		assert_false(Redstone.provides_weak_power(_w, BUTTON, slot), "slot %d" % slot)


func test_button_pops_off_when_its_wall_goes() -> void:
	_place_button()
	_w.put(Vector3i(0, Y, 0), Blocks.AIR)
	Redstone.on_neighbor_changed(_w, BUTTON)
	assert_eq(_w.get_world_block(BUTTON), Blocks.AIR, "removed")
	assert_eq(_w.drops[0][1], Blocks.STONE_BUTTON, "drops itself")


# --- Plates: sensitivity is the whole point ---


func test_wooden_plate_triggers_for_a_living_entity() -> void:
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	_stand(true)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	assert_eq(_w.get_world_block_meta(PLATE), 1, "pressed")


func test_wooden_plate_triggers_for_a_non_living_entity() -> void:
	# lg.a — dropped items, arrows and minecarts all count.
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	_stand(false)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	assert_eq(_w.get_world_block_meta(PLATE), 1, "an item trips a wooden plate")


func test_stone_plate_ignores_a_non_living_entity() -> void:
	# lg.b — living entities only. This is the ONLY behavioural
	# difference between the two plates.
	_place_plate(Blocks.STONE_PRESSURE_PLATE)
	_stand(false)
	Redstone.update_plate(_w, PLATE, Blocks.STONE_PRESSURE_PLATE)
	assert_eq(_w.get_world_block_meta(PLATE), 0, "an item does not trip a stone plate")


func test_stone_plate_triggers_for_a_living_entity() -> void:
	_place_plate(Blocks.STONE_PRESSURE_PLATE)
	_stand(true)
	Redstone.update_plate(_w, PLATE, Blocks.STONE_PRESSURE_PLATE)
	assert_eq(_w.get_world_block_meta(PLATE), 1, "a mob or player trips it")


func test_sensitivity_predicate() -> void:
	assert_true(Redstone.plate_living_only(Blocks.STONE_PRESSURE_PLATE), "stone: living only")
	assert_false(Redstone.plate_living_only(Blocks.WOODEN_PRESSURE_PLATE), "wood: everything")


# --- Plates: the inset detection box ---


func test_detection_box_matches_the_vanilla_inset() -> void:
	var box: AABB = Redstone.plate_detection_box(PLATE)
	assert_almost_eq(box.position.x, 0.125, 0.0001, "inset 1/8 on -X")
	assert_almost_eq(box.position.z, 0.125, 0.0001, "inset 1/8 on -Z")
	assert_almost_eq(box.end.x, 0.875, 0.0001, "inset 1/8 on +X")
	assert_almost_eq(box.end.z, 0.875, 0.0001, "inset 1/8 on +Z")
	assert_almost_eq(box.size.y, 0.25, 0.0001, "quarter-block tall")


func test_an_entity_at_the_cell_corner_does_not_trip_it() -> void:
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	_stand(true, Vector3(0.05, 64.05, 0.05))
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	assert_eq(_w.get_world_block_meta(PLATE), 0, "outside the inset box")


func test_an_entity_above_the_box_does_not_trip_it() -> void:
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	_stand(true, Vector3(0.5, 64.6, 0.5))
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	assert_eq(_w.get_world_block_meta(PLATE), 0, "jumping clear releases it")


# --- Plates: release and rechecking ---


func test_plate_schedules_a_recheck_while_held() -> void:
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	_stand(true)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	assert_eq(TickScheduler.pending_count(), 1, "recheck queued")


func test_plate_releases_once_the_box_empties() -> void:
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	_stand(true)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	assert_eq(_w.get_world_block_meta(PLATE), 1, "pressed")
	_w.entities.clear()
	for _i in range(Redstone.PLATE_RECHECK_TICKS):
		TickScheduler.advance(0.05, _w)
	assert_eq(_w.get_world_block_meta(PLATE), 0, "released after the recheck")


func test_a_settled_empty_plate_stops_rechecking() -> void:
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	assert_eq(TickScheduler.pending_count(), 0, "nothing standing on it, nothing scheduled")


func test_repeated_contact_does_not_stack_rechecks_unboundedly() -> void:
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	_stand(true)
	for _i in range(5):
		Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	# One per contact is fine — they collapse as they fire — but the
	# meta must not thrash.
	assert_eq(_w.get_world_block_meta(PLATE), 1, "still pressed, not flapping")
	assert_eq(_w.clicks.size(), 1, "only the initial press clicked")


# --- Plate power output ---


func test_pressed_plate_powers_every_direction_weakly() -> void:
	_place_plate(Blocks.STONE_PRESSURE_PLATE)
	_stand(true)
	Redstone.update_plate(_w, PLATE, Blocks.STONE_PRESSURE_PLATE)
	for slot in range(6):
		assert_true(Redstone.provides_weak_power(_w, PLATE, slot), "weak slot %d" % slot)


func test_pressed_plate_strong_powers_the_block_below() -> void:
	_place_plate(Blocks.STONE_PRESSURE_PLATE)
	_stand(true)
	Redstone.update_plate(_w, PLATE, Blocks.STONE_PRESSURE_PLATE)
	for slot in range(6):
		assert_eq(
			Redstone.provides_strong_power(_w, PLATE, slot),
			slot == Redstone.SLOT_ABOVE,
			"plate strong-powers only its support (slot 1), not %d" % slot
		)


func test_unpressed_plate_powers_nothing() -> void:
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	for slot in range(6):
		assert_false(Redstone.provides_weak_power(_w, PLATE, slot), "slot %d" % slot)


func test_plate_pops_off_without_support() -> void:
	_w.put(PLATE, Blocks.STONE_PRESSURE_PLATE, 0)
	Redstone.on_neighbor_changed(_w, PLATE)
	assert_eq(_w.get_world_block(PLATE), Blocks.AIR, "removed")
	assert_eq(_w.drops[0][1], Blocks.STONE_PRESSURE_PLATE, "drops itself")


# --- Driving a consumer ---


func test_a_plate_opens_a_door_beside_it() -> void:
	_place_plate(Blocks.WOODEN_PRESSURE_PLATE)
	var door := PLATE + Vector3i(1, 0, 0)
	_w.put(door, Blocks.WOODEN_DOOR, 0)
	_w.put(door + Vector3i(0, 1, 0), Blocks.WOODEN_DOOR, 8)
	_stand(true)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	Redstone.on_neighbor_changed(_w, door)
	assert_eq(_w.get_world_block_meta(door) & 4, 4, "door opened")
