class_name ItemStack
extends RefCounted

# A single inventory slot's contents: a block/item ID and a count.

const MAX_SIZE: int = 64

var item_id: int = Blocks.AIR
var count: int = 0


func _init(p_item_id: int = Blocks.AIR, p_count: int = 0) -> void:
	item_id = p_item_id
	count = p_count


func is_empty() -> bool:
	return count == 0 or item_id == Blocks.AIR


# Returns the overflow that didn't fit.
func add(amount: int) -> int:
	if amount <= 0:
		return 0
	var space: int = MAX_SIZE - count
	var added: int = mini(amount, space)
	count += added
	return amount - added


# Returns the amount actually removed.
func remove(amount: int) -> int:
	if amount <= 0:
		return 0
	var taken: int = mini(amount, count)
	count -= taken
	if count <= 0:
		item_id = Blocks.AIR
		count = 0
	return taken
