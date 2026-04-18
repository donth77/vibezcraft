class_name Inventory
extends RefCounted

# Phase 4 MVP: hotbar-only (9 slots). Phase 4+ will add 27 storage + 4 armor.

signal changed

const HOTBAR_SIZE: int = 9

var slots: Array  # Array[ItemStack]
var selected_slot: int = 0


func _init() -> void:
	slots = []
	for i in range(HOTBAR_SIZE):
		slots.append(ItemStack.new())


func selected() -> ItemStack:
	return slots[selected_slot]


func select(slot: int) -> void:
	if slot < 0 or slot >= HOTBAR_SIZE or slot == selected_slot:
		return
	selected_slot = slot
	changed.emit()


# Adds items to the inventory. Returns the count that didn't fit.
# Tries existing matching stacks first, then empty slots.
func add_item(item_id: int, amount: int) -> int:
	if amount <= 0 or item_id == Blocks.AIR:
		return 0
	var remaining: int = amount
	for slot: ItemStack in slots:
		if remaining <= 0:
			break
		if slot.item_id == item_id and slot.count < ItemStack.MAX_SIZE:
			remaining = slot.add(remaining)
	for slot: ItemStack in slots:
		if remaining <= 0:
			break
		if slot.is_empty():
			slot.item_id = item_id
			remaining = slot.add(remaining)
	if remaining < amount:
		changed.emit()
	return remaining


# Removes one of whatever's in the selected slot. Returns true if consumed.
func consume_one_selected() -> bool:
	var s: ItemStack = selected()
	if s.is_empty():
		return false
	s.remove(1)
	changed.emit()
	return true
