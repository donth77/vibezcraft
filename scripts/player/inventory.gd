class_name Inventory
extends RefCounted

# Vanilla MC Alpha layout, expanded for Phase 5:
#   slots[0..8]   = hotbar (visible always, also accessed by hotbar UI)
#   slots[9..35]  = main inventory (3x9, opened with E)
#   slots[36..39] = armor (helmet, chest, legs, boots — not yet functional)
#   slots[40..43] = 2x2 crafting grid
#   slots[44]     = crafting result (read-only output of the recipe matcher)
#
# Storing everything in one flat array keeps slot indexing trivial for the UI;
# zone-specific helpers below give callers typed access.

signal changed

const HOTBAR_SIZE: int = 9
const MAIN_SIZE: int = 27
const ARMOR_SIZE: int = 4
const CRAFT_SIZE: int = 4

const HOTBAR_START: int = 0
const MAIN_START: int = 9
const ARMOR_START: int = 36
const CRAFT_START: int = 40
const CRAFT_RESULT: int = 44
const TOTAL_SIZE: int = 45

var slots: Array  # Array[ItemStack]
var selected_slot: int = 0


func _init() -> void:
	slots = []
	for i in range(TOTAL_SIZE):
		slots.append(ItemStack.new())


func selected() -> ItemStack:
	return slots[selected_slot]


func select(slot: int) -> void:
	if slot < 0 or slot >= HOTBAR_SIZE or slot == selected_slot:
		return
	selected_slot = slot
	changed.emit()


# Adds items to the inventory. Returns the count that didn't fit.
# Only targets hotbar + main storage — never armor/craft/result slots, which
# are user-managed UI zones.
func add_item(item_id: int, amount: int) -> int:
	if amount <= 0 or item_id == Blocks.AIR:
		return 0
	var remaining: int = amount
	var storage_end: int = MAIN_START + MAIN_SIZE  # exclusive: stops before armor
	for i in range(storage_end):
		if remaining <= 0:
			break
		var slot: ItemStack = slots[i]
		if slot.item_id == item_id and slot.count < ItemStack.MAX_SIZE:
			remaining = slot.add(remaining)
	for i in range(storage_end):
		if remaining <= 0:
			break
		var slot: ItemStack = slots[i]
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


# Empties the selected slot. Returns the count that was removed.
func consume_selected_stack() -> int:
	var s: ItemStack = selected()
	if s.is_empty():
		return 0
	var n: int = s.count
	s.remove(n)
	changed.emit()
	return n


# --- Crafting grid helpers ---


# Returns a flat Array[int] of item_ids for the 2x2 craft slots, AIR for empty.
# Caller passes this to Recipes.match_grid(grid, 2, 2).
func craft_grid_ids() -> Array:
	var grid: Array = []
	for i in range(CRAFT_SIZE):
		grid.append(slots[CRAFT_START + i].item_id)
	return grid


# Recomputes the craft result slot from the current craft grid contents.
# Called whenever a craft slot changes. Doesn't emit `changed` itself —
# the caller already did.
func recompute_craft_result() -> void:
	var matched: Dictionary = Recipes.match_grid(craft_grid_ids(), 2, 2)
	var result: ItemStack = slots[CRAFT_RESULT]
	if matched.is_empty():
		result.item_id = Blocks.AIR
		result.count = 0
	else:
		result.item_id = matched["item_id"]
		result.count = matched["count"]


# Take from the craft result: consumes one of each input slot and emits
# changed. Caller is responsible for actually transferring the result stack
# into the cursor or inventory.
func consume_craft_inputs() -> void:
	for i in range(CRAFT_SIZE):
		slots[CRAFT_START + i].remove(1)
	recompute_craft_result()
	changed.emit()
