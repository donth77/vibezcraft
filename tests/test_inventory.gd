extends GutTest


func test_new_inventory_is_all_empty() -> void:
	var inv := Inventory.new()
	# Phase 5: 45 slots (9 hotbar + 27 main + 4 armor + 4 craft + 1 result).
	assert_eq(inv.slots.size(), Inventory.TOTAL_SIZE)
	for slot: ItemStack in inv.slots:
		assert_true(slot.is_empty())


func test_add_item_to_empty_inventory_fills_first_slot() -> void:
	var inv := Inventory.new()
	var overflow: int = inv.add_item(Blocks.STONE, 5)
	assert_eq(overflow, 0)
	assert_eq(inv.slots[0].item_id, Blocks.STONE)
	assert_eq(inv.slots[0].count, 5)


func test_add_stacks_with_existing_matching_slot() -> void:
	var inv := Inventory.new()
	inv.add_item(Blocks.STONE, 5)
	inv.add_item(Blocks.STONE, 3)
	assert_eq(inv.slots[0].count, 8)


func test_add_overflows_to_next_slot_when_stack_is_full() -> void:
	var inv := Inventory.new()
	inv.add_item(Blocks.STONE, 60)
	inv.add_item(Blocks.STONE, 10)
	# 60 + 4 = 64 in slot 0, remaining 6 in slot 1
	assert_eq(inv.slots[0].count, 64)
	assert_eq(inv.slots[1].item_id, Blocks.STONE)
	assert_eq(inv.slots[1].count, 6)


func test_add_returns_overflow_when_inventory_is_full() -> void:
	var inv := Inventory.new()
	# Fill every storage slot (hotbar + main, NOT armor/craft) with a different
	# block so there's no matching stack to merge into.
	var storage_slots: int = Inventory.HOTBAR_SIZE + Inventory.MAIN_SIZE
	for i in range(storage_slots):
		var stack: ItemStack = inv.slots[i]
		stack.item_id = Blocks.STONE + (i % 5) + 1  # cycle a few block ids
		stack.count = ItemStack.MAX_SIZE
	var overflow: int = inv.add_item(Blocks.LEAVES, 5)
	assert_eq(overflow, 5, "all 5 should overflow")


func test_select_slot() -> void:
	var inv := Inventory.new()
	inv.select(3)
	assert_eq(inv.selected_slot, 3)


func test_select_clamps_invalid() -> void:
	var inv := Inventory.new()
	inv.select(-1)
	assert_eq(inv.selected_slot, 0)
	inv.select(Inventory.HOTBAR_SIZE)
	assert_eq(inv.selected_slot, 0)


func test_consume_one_selected() -> void:
	var inv := Inventory.new()
	inv.add_item(Blocks.STONE, 3)
	assert_true(inv.consume_one_selected())
	assert_eq(inv.slots[0].count, 2)


func test_consume_one_selected_empties_slot_at_zero() -> void:
	var inv := Inventory.new()
	inv.add_item(Blocks.STONE, 1)
	inv.consume_one_selected()
	assert_true(inv.slots[0].is_empty())


func test_consume_one_selected_returns_false_on_empty() -> void:
	var inv := Inventory.new()
	assert_false(inv.consume_one_selected())
