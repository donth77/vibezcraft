class_name ItemStack
extends RefCounted

# A single inventory slot's contents: a block/item ID, a count, and a
# damage value. Damage only applies to tools (which never stack — count
# stays 1). Stacked items always have damage = 0.

const MAX_SIZE: int = 64

var item_id: int = Blocks.AIR
var count: int = 0
var damage: int = 0  # used count for tools; 0 = pristine


func _init(p_item_id: int = Blocks.AIR, p_count: int = 0) -> void:
	item_id = p_item_id
	count = p_count
	damage = 0


func is_empty() -> bool:
	return count == 0 or item_id == Blocks.AIR


# Tools have a max-durability value > 0 from Items._TOOL_DATA. Returns 0
# for non-tool stacks (so durability-bar rendering can early-out).
func max_durability() -> int:
	return Items.tool_durability(item_id)


# True if this stack should show a green-to-red durability bar in the UI.
func should_show_durability() -> bool:
	return damage > 0 and max_durability() > 0


# Increments damage by `amount`. Returns true iff the tool just broke
# (i.e., the stack was consumed). Caller should play the snap sound.
func damage_tool(amount: int = 1) -> bool:
	var max_d: int = max_durability()
	if max_d <= 0:
		return false
	damage += amount
	if damage >= max_d:
		item_id = Blocks.AIR
		count = 0
		damage = 0
		return true
	return false


# Returns the overflow that didn't fit. Honors the per-item cap so tools
# never stack past 1.
func add(amount: int) -> int:
	if amount <= 0:
		return 0
	var cap: int = MAX_SIZE if item_id == Blocks.AIR else Items.max_stack_size(item_id)
	var space: int = cap - count
	var added: int = mini(amount, space)
	count += added
	return amount - added


# Copies item_id + count + damage from another stack — used when moving a
# stack between cursor and slot so durability survives the move. Vanilla
# uses ItemStack.copy() for this.
func copy_from(other: ItemStack) -> void:
	item_id = other.item_id
	count = other.count
	damage = other.damage


func clear() -> void:
	item_id = Blocks.AIR
	count = 0
	damage = 0


# Returns the amount actually removed.
func remove(amount: int) -> int:
	if amount <= 0:
		return 0
	var taken: int = mini(amount, count)
	count -= taken
	if count <= 0:
		item_id = Blocks.AIR
		count = 0
		damage = 0
	return taken
