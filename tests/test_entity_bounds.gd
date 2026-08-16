extends GutTest

# Phase 8e — pressure plates against REAL entity coordinate conventions
# (.claude/redstone-plan.md §3.6, §7.3).
#
# The bug this file exists to prevent shipped once already and no unit
# test caught it: plate detection sampled `entity.global_position` as a
# point. Every plate test passed, because each one put its fake sample
# point inside the plate box. In the running game the player's origin is
# the CENTRE of a 1.8 m capsule — about 0.9 m above the feet — and a
# plate's detection box is 0.25 m tall, so a normally standing player's
# origin is never inside it and no plate ever fired.
#
# Everything here therefore builds real `Node3D`s with the collision
# shapes the entities actually construct, positions them the way the
# game positions them, and runs the same predicate the manager runs.

const PLATE := Vector3i(4, 64, 7)
# player.gd builds a 1.8 m capsule with a default (zero) shape transform,
# so `global_position` sits 0.9 m above the feet.
const PLAYER_HEIGHT: float = 1.8
const PLAYER_RADIUS: float = 0.3
# minecart.gd COLLISION_WIDTH / COLLISION_HEIGHT.
const CART_WIDTH: float = 0.98
const CART_HEIGHT: float = 0.7

var _spawned: Array[Node3D] = []


# A world that answers `entities_overlap_box` exactly the way
# ChunkManager does — through `EntityBounds` — so these tests exercise
# the shipping predicate rather than a re-implementation of it.
class EntityWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var living: Array[Node3D] = []
	var other: Array[Node3D] = []
	var clicks: Array = []

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block_state(pos: Vector3i, id: int, meta: int, _notify: bool = true) -> bool:
		blocks[pos] = id
		metas[pos] = meta & 0xF
		return true

	func entities_overlap_box(box: AABB, living_only: bool) -> bool:
		for node: Node3D in living:
			if is_instance_valid(node) and EntityBounds.overlaps(box, node):
				return true
		if living_only:
			return false
		for node: Node3D in other:
			if is_instance_valid(node) and EntityBounds.overlaps(box, node):
				return true
		return false

	func play_redstone_click(_pos: Vector3i, on: bool) -> void:
		clicks.append(on)

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _w: EntityWorld


func before_each() -> void:
	_w = EntityWorld.new()
	_w.put(PLATE + Vector3i(0, -1, 0), Blocks.STONE)
	TickScheduler.reset_for_tests()


func after_each() -> void:
	for node: Node3D in _spawned:
		if is_instance_valid(node):
			node.free()
	_spawned.clear()
	TickScheduler.reset_for_tests()


func _track(node: Node3D) -> Node3D:
	_spawned.append(node)
	add_child_autofree(node)
	return node


# A body with a capsule collider, positioned by its FEET the way the game
# positions a standing entity.
func _capsule_body(feet: Vector3, height: float, radius: float) -> Node3D:
	var body := CharacterBody3D.new()
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = height
	capsule.radius = radius
	shape.shape = capsule
	body.add_child(shape)
	_track(body)
	body.global_position = feet + Vector3(0.0, height * 0.5, 0.0)
	return body


func _box_body(centre: Vector3, size: Vector3) -> Node3D:
	var body := CharacterBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_track(body)
	body.global_position = centre
	return body


func _bare_node(at: Vector3) -> Node3D:
	var node := Node3D.new()
	_track(node)
	node.global_position = at
	return node


func _cell_centre(cell: Vector3i) -> Vector3:
	return Vector3(cell) + Vector3(0.5, 0.0, 0.5)


func _press(block_id: int) -> bool:
	_w.put(PLATE, block_id, 0)
	Redstone.update_plate(_w, PLATE, block_id, true)
	return _w.get_world_block_meta(PLATE) > 0


# --- The regression that started this ----------------------------------


func test_a_normally_standing_player_is_0_9_m_above_the_plate_box() -> void:
	# Pinned as its own assertion because it is the whole reason the
	# point-sample was wrong. If this ever stops being true the tests
	# below stop meaning what they say.
	var player: Node3D = _capsule_body(_cell_centre(PLATE), PLAYER_HEIGHT, PLAYER_RADIUS)
	var box: AABB = Redstone.plate_detection_box(PLATE)
	assert_false(box.has_point(player.global_position), "origin is OUTSIDE the detection box")
	assert_almost_eq(player.global_position.y - float(PLATE.y), 0.9, 0.001, "0.9 m above")
	assert_true(EntityBounds.overlaps(box, player), "but the BOUNDS do overlap it")


func test_a_standing_player_presses_both_plate_types() -> void:
	_w.living.append(_capsule_body(_cell_centre(PLATE), PLAYER_HEIGHT, PLAYER_RADIUS))
	assert_true(_press(Blocks.WOODEN_PRESSURE_PLATE), "wooden plate fires")
	assert_true(_press(Blocks.STONE_PRESSURE_PLATE), "stone plate fires")


func test_a_mob_presses_both_plate_types() -> void:
	# Mobs are shorter than the player; a 0.9 m body on the plate is a
	# chicken-sized worst case for a 0.25 m detection box.
	_w.living.append(_capsule_body(_cell_centre(PLATE), 0.9, 0.2))
	assert_true(_press(Blocks.WOODEN_PRESSURE_PLATE), "wooden plate fires")
	assert_true(_press(Blocks.STONE_PRESSURE_PLATE), "stone plate fires")


# --- lg.a vs lg.b: which entities count --------------------------------


func test_a_dropped_item_wakes_wood_but_not_stone() -> void:
	_w.other.append(_bare_node(_cell_centre(PLATE) + Vector3(0.0, 0.1, 0.0)))
	assert_true(_press(Blocks.WOODEN_PRESSURE_PLATE), "wooden plate takes every entity (lg.a)")
	assert_false(_press(Blocks.STONE_PRESSURE_PLATE), "stone plate takes living only (lg.b)")


func test_an_arrow_wakes_wood_but_not_stone() -> void:
	var arrow := Node3D.new()
	arrow.set_script(load("res://scripts/entities/arrow.gd"))
	_track(arrow)
	arrow.global_position = _cell_centre(PLATE) + Vector3(0.0, 0.1, 0.0)
	_w.other.append(arrow)
	assert_true(_press(Blocks.WOODEN_PRESSURE_PLATE), "arrow trips wood")
	assert_false(_press(Blocks.STONE_PRESSURE_PLATE), "arrow does not trip stone")


func test_a_cart_whose_edge_only_overlaps_still_presses() -> void:
	# The case a centre-point test cannot see: a 0.98 m wide cart sitting
	# one cell over, with only its side inside the plate's inset box.
	var centre: Vector3 = _cell_centre(PLATE) + Vector3(0.8, CART_HEIGHT * 0.5, 0.0)
	var cart: Node3D = _box_body(centre, Vector3(CART_WIDTH, CART_HEIGHT, CART_WIDTH))
	var box: AABB = Redstone.plate_detection_box(PLATE)
	assert_false(box.has_point(cart.global_position), "cart origin is outside the box")
	assert_true(EntityBounds.overlaps(box, cart), "but its hull overlaps")
	_w.other.append(cart)
	assert_true(_press(Blocks.WOODEN_PRESSURE_PLATE), "edge contact presses a wooden plate")


func test_the_detection_box_is_inset_exactly_as_ap_java_specifies() -> void:
	# (x+0.125, y, z+0.125) to (x+0.875, y+0.25, z+0.875). Asserted on the
	# geometry rather than through an entity, because no entity is small
	# enough to fit inside the 1/8 ring: even a dropped item's 0.25 m box
	# reaches into the detection region from the corner, which is exactly
	# what vanilla does too.
	var box: AABB = Redstone.plate_detection_box(PLATE)
	assert_almost_eq(box.position.x, float(PLATE.x) + 0.125, 0.0001, "inset on -X")
	assert_almost_eq(box.position.z, float(PLATE.z) + 0.125, 0.0001, "inset on -Z")
	assert_almost_eq(box.position.y, float(PLATE.y), 0.0001, "sits on the cell floor")
	assert_almost_eq(box.size.x, 0.75, 0.0001, "0.75 wide")
	assert_almost_eq(box.size.y, 0.25, 0.0001, "0.25 tall")
	assert_almost_eq(box.size.z, 0.75, 0.0001, "0.75 deep")


func test_an_entity_in_the_next_cell_over_does_not_press() -> void:
	# A whole cell away, so nothing about its bounds can reach the box.
	_w.other.append(_bare_node(_cell_centre(PLATE) + Vector3(1.0, 0.1, 0.0)))
	assert_false(_press(Blocks.WOODEN_PRESSURE_PLATE), "an adjacent cell is not contact")


func test_an_entity_a_metre_above_does_not_press() -> void:
	_w.living.append(
		_capsule_body(_cell_centre(PLATE) + Vector3(0.0, 2.0, 0.0), PLAYER_HEIGHT, PLAYER_RADIUS)
	)
	assert_false(_press(Blocks.STONE_PRESSURE_PLATE), "nothing overhead trips a plate")


# --- The contact guard must survive all of the above -------------------


func test_repeated_contact_on_a_held_plate_does_not_grow_the_tick_queue() -> void:
	# ap.java:65 returns early when the plate is already pressed. Without
	# it, every frame a player stands still queues another 20-tick
	# recheck — and TickScheduler permits duplicates, so the queue grows
	# for as long as they stand there.
	_w.living.append(_capsule_body(_cell_centre(PLATE), PLAYER_HEIGHT, PLAYER_RADIUS))
	_w.put(PLATE, Blocks.WOODEN_PRESSURE_PLATE, 0)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE, true)
	var after_first: int = TickScheduler.pending_count()
	for i in range(60):
		Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE, true)
	assert_eq(TickScheduler.pending_count(), after_first, "60 more contacts queue nothing new")


func test_a_plate_notifies_the_block_it_stands_on_not_a_wall() -> void:
	# ap.java:92-93 notifies around the plate AND around the block below
	# it — that second fanout is how a plate's strong power reaches the
	# cells beside its support. The target is FIXED: a plate's metadata
	# is its pressed flag, so deriving the mount from it would read a
	# pressed plate (meta 1) as west-wall-mounted and notify sideways.
	var seen := _NotifyRecorder.new()
	seen.blocks[PLATE] = Blocks.WOODEN_PRESSURE_PLATE
	seen.metas[PLATE] = 1
	Redstone.notify_around_support(seen, PLATE, Blocks.WOODEN_PRESSURE_PLATE)
	assert_eq(seen.notified, [PLATE + Vector3i(0, -1, 0)], "notified its support, below it")


class _NotifyRecorder:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var notified: Array = []

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func enqueue_block_notification(pos: Vector3i, _source_id: int = -1) -> void:
		notified.append(pos)


func test_a_released_plate_ignores_its_scheduled_tick() -> void:
	# ap.java:57 — the other half of the guard. A plate at rest has
	# nothing to re-check, so a stray scheduled tick must not restart the
	# recheck loop.
	_w.put(PLATE, Blocks.WOODEN_PRESSURE_PLATE, 0)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE, false)
	assert_eq(TickScheduler.pending_count(), 0, "no recheck queued for a released plate")


func test_the_plate_releases_once_the_entity_leaves() -> void:
	var player: Node3D = _capsule_body(_cell_centre(PLATE), PLAYER_HEIGHT, PLAYER_RADIUS)
	_w.living.append(player)
	_w.put(PLATE, Blocks.WOODEN_PRESSURE_PLATE, 0)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE, true)
	assert_eq(_w.get_world_block_meta(PLATE), 1, "pressed")
	player.global_position += Vector3(5.0, 0.0, 0.0)
	Redstone.update_plate(_w, PLATE, Blocks.WOODEN_PRESSURE_PLATE, false)
	assert_eq(_w.get_world_block_meta(PLATE), 0, "released on the scheduled recheck")
	assert_eq(_w.clicks, [true, false], "one click on, one click off")


# --- Bounds derivation -------------------------------------------------


func test_bounds_come_from_the_collision_shape_not_the_origin() -> void:
	var body: Node3D = _box_body(Vector3(10.0, 20.0, 30.0), Vector3(2.0, 4.0, 6.0))
	var box: AABB = EntityBounds.world_aabb(body)
	assert_almost_eq(box.position.x, 9.0, 0.001, "min x")
	assert_almost_eq(box.position.y, 18.0, 0.001, "min y")
	assert_almost_eq(box.size.z, 6.0, 0.001, "depth")


func test_a_colliderless_node_falls_back_to_its_vanilla_footprint() -> void:
	var item: Node3D = _bare_node(Vector3(1.0, 2.0, 3.0))
	var box: AABB = EntityBounds.world_aabb(item)
	assert_almost_eq(box.size.y, 0.25, 0.001, "EntityItem.setSize(0.25, 0.25)")
	assert_true(box.has_point(Vector3(1.0, 2.0, 3.0)), "centred on the node origin")


func test_a_rotated_body_reports_its_enclosing_box() -> void:
	# Mobs yaw toward their target, so a box collider's world footprint
	# grows as it turns. The enclosing AABB is what vanilla compares.
	var body: Node3D = _box_body(Vector3(0.5, 0.5, 0.5), Vector3(1.0, 1.0, 1.0))
	var square: AABB = EntityBounds.world_aabb(body)
	body.rotation.y = PI * 0.25
	var turned: AABB = EntityBounds.world_aabb(body)
	assert_almost_eq(square.size.x, 1.0, 0.001, "axis-aligned width")
	assert_gt(turned.size.x, 1.3, "45-degree footprint is wider")
