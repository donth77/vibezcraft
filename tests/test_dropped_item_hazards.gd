extends GutTest

# Alpha 1.2.6 EntityItem (`vendor/alpha-1.2.6-src/src/eo.java`) inherits
# Entity's burning-block damage (`lw.java` + `cy.java::c(AABB)`). Items have
# five health, take one point per 20 Hz contact tick in fire or lava, retain
# the signed Fire counter after leaving, and are extinguished by water.

const POS := Vector3(4.5, 64.5, 4.5)
const CELL := Vector3i(4, 64, 4)


class FakeWorld:
	extends Node
	var blocks: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func put(pos: Vector3i, id: int) -> void:
		blocks[pos] = id


var _world: FakeWorld


func before_each() -> void:
	_world = FakeWorld.new()
	add_child_autofree(_world)


func _item() -> DroppedItem:
	var item := DroppedItem.new()
	_world.add_child(item)
	item.set_process(false)
	item.global_position = POS
	item.setup(Items.STICK)
	return item


func _prime_safe_tick(item: DroppedItem) -> void:
	assert_false(item._environment_tick(), "safe tick keeps the item")
	assert_eq(item._fire_ticks, -1, "safe Entity settles to -fireResistance")


func test_fire_contact_consumes_five_source_health_and_destroys_the_item() -> void:
	var item: DroppedItem = _item()
	_prime_safe_tick(item)
	_world.put(CELL, Blocks.FIRE)
	assert_false(item._environment_tick(), "first contact singes but does not destroy")
	assert_eq(item._health, 4)
	assert_eq(item._fire_ticks, 300, "-1 -> 0 seeds Entity's trailing Fire counter")
	assert_false(item._environment_tick(), "second contact applies burn + contact damage")
	assert_eq(item._health, 2)
	assert_true(item._environment_tick(), "third sustained contact exhausts five health")
	assert_true(item.is_queued_for_deletion(), "fire destroys the dropped entity")


func test_lava_contact_uses_the_same_alpha_burning_block_path() -> void:
	var item: DroppedItem = _item()
	_prime_safe_tick(item)
	_world.put(CELL, Blocks.LAVA_STILL)
	var destroyed: bool = false
	for _tick: int in range(3):
		destroyed = item._environment_tick()
		if destroyed:
			break
	assert_true(destroyed, "lava destroys the five-health item within three source ticks")
	assert_true(item.is_queued_for_deletion())


func test_flowing_lava_is_destructive_too() -> void:
	var item: DroppedItem = _item()
	_prime_safe_tick(item)
	_world.put(CELL, Blocks.LAVA_FLOWING)
	for _tick: int in range(3):
		if item._environment_tick():
			break
	assert_true(item.is_queued_for_deletion(), "both Alpha lava block states burn items")


func test_brief_fire_contact_keeps_burning_after_the_item_leaves() -> void:
	var item: DroppedItem = _item()
	_prime_safe_tick(item)
	_world.put(CELL, Blocks.FIRE)
	assert_false(item._environment_tick())
	assert_eq(item._health, 4)
	_world.put(CELL, Blocks.AIR)
	assert_false(item._environment_tick())
	assert_eq(item._health, 3, "Fire=300 applies the first trailing damage point")
	assert_eq(item._fire_ticks, 299)


func test_water_extinguishes_before_trailing_damage() -> void:
	var item: DroppedItem = _item()
	_prime_safe_tick(item)
	_world.put(CELL, Blocks.FIRE)
	assert_false(item._environment_tick())
	assert_eq(item._health, 4)
	_world.put(CELL, Blocks.WATER_STILL)
	assert_false(item._environment_tick())
	assert_eq(item._health, 4, "water cancels the pending Fire=300 damage")
	assert_eq(item._fire_ticks, -1, "the post-move safe state is restored")


func test_aabb_sampling_catches_a_hazard_under_one_edge() -> void:
	var item: DroppedItem = _item()
	_prime_safe_tick(item)
	# Center stays in x=4, but the 0.25 m item AABB crosses into x=5.
	item.global_position.x = 4.95
	_world.put(Vector3i(5, 64, 4), Blocks.FIRE)
	assert_false(item._environment_tick())
	assert_eq(item._health, 4, "edge overlap is contact even when the center cell is safe")


func test_health_and_fire_state_survive_entity_persistence_payloads() -> void:
	var item: DroppedItem = _item()
	item._health = 2
	item._fire_ticks = 137
	var payload: Dictionary = item.to_save_dict()
	assert_eq(payload["health"], 2)
	assert_eq(payload["fire_ticks"], 137)

	var restored: DroppedItem = _item()
	restored.restore_from_dict(payload)
	assert_eq(restored._health, 2, "dimension travel does not heal a singed drop")
	assert_eq(restored._fire_ticks, 137, "dimension travel does not extinguish it")


func test_older_payloads_default_to_a_healthy_unlit_item() -> void:
	var item: DroppedItem = _item()
	item.restore_from_dict({"item_id": Items.STICK, "pos": POS})
	assert_eq(item._health, 5)
	assert_eq(item._fire_ticks, 0)
