extends GutTest

# Dispatch-order guard for items that place blocks.
#
# `Interaction._place_block_from_held` rejects every item id outright:
#
#     if stack.item_id >= 100 or Items.is_tool_item(stack.item_id):
#         return false
#
# That is correct as a default — right-clicking with a pork chop must not
# place a pork chop. But a handful of items DO place a block (a sign, a
# bed, a rail, redstone dust), and each of those has to be dispatched
# ABOVE the guard. Put one below it and the branch is simply dead: the
# code reads fine, the block id is right, the support check is right, and
# right-clicking does nothing whatsoever.
#
# That is exactly what happened to redstone dust. Nothing else caught it
# because every other redstone test drives the world model directly and
# never goes through the placement path at all.
#
# Asserting on source order is unusual, and it is the honest thing to
# assert here: the defect is positional, and a behavioural test would
# need a live scene tree, a camera and a raycast hit to reach the same
# conclusion.

const _INTERACTION_PATH := "res://scripts/player/interaction.gd"

# Items whose right-click places a block. Add to this list whenever a new
# one is introduced and the guard below does the rest.
const _PLACING_ITEMS: Array[String] = [
	"REDSTONE",
	"RAIL",
	"SIGN",
	"BED",
	"PAINTING",
	"SUGAR_CANE",
	"WHEAT_SEEDS",
	"WOODEN_DOOR",
	"IRON_DOOR",
]


func _source_lines() -> PackedStringArray:
	var script: GDScript = load(_INTERACTION_PATH) as GDScript
	assert_not_null(script, "interaction.gd loads")
	if script == null:
		return PackedStringArray()
	return script.source_code.split("\n")


# Comments quote both the guard and the dispatches — including the ones
# in this file's own subject matter — so every scan has to skip them or
# it measures prose instead of code.
func _is_code(line: String) -> bool:
	return not line.strip_edges().begins_with("#")


# Line index of the item-id rejection, or -1.
func _guard_line(lines: PackedStringArray) -> int:
	for i in range(lines.size()):
		if _is_code(lines[i]) and lines[i].contains("stack.item_id >= 100"):
			return i
	return -1


# First line index that dispatches on `Items.<name>`, or -1.
func _dispatch_line(lines: PackedStringArray, item_name: String) -> int:
	var needle: String = "stack.item_id == Items.%s" % item_name
	for i in range(lines.size()):
		if _is_code(lines[i]) and lines[i].contains(needle):
			return i
	return -1


func test_the_item_rejection_guard_still_exists() -> void:
	# If this ever stops matching, the tests below are silently vacuous.
	var lines: PackedStringArray = _source_lines()
	assert_gt(_guard_line(lines), 0, "the `item_id >= 100` guard is still there to be beaten")


func test_every_block_placing_item_is_dispatched_before_the_guard() -> void:
	var lines: PackedStringArray = _source_lines()
	var guard: int = _guard_line(lines)
	assert_gt(guard, 0, "guard found")
	if guard <= 0:
		return
	for item_name: String in _PLACING_ITEMS:
		var dispatch: int = _dispatch_line(lines, item_name)
		assert_gt(dispatch, -1, "Items.%s has a placement branch at all" % item_name)
		if dispatch < 0:
			continue
		assert_lt(
			dispatch,
			guard,
			(
				(
					"Items.%s is dispatched at line %d, BELOW the item guard at line %d — "
					% [item_name, dispatch + 1, guard + 1]
				)
				+ "that branch is unreachable and right-clicking will do nothing"
			)
		)


func test_every_placeable_redstone_block_has_a_placement_branch() -> void:
	# Coverage, not order: a redstone component with no branch at all is
	# just as unplaceable as one stranded below the guard. Ore uses the
	# generic block path (it is an ordinary cube) and the OFF torch is
	# never placed by hand — vanilla places the lit id and lets the first
	# neighbour update invert it.
	var source: String = load(_INTERACTION_PATH).source_code
	for block_name: String in [
		"LEVER",
		"STONE_BUTTON",
		"STONE_PRESSURE_PLATE",
		"WOODEN_PRESSURE_PLATE",
		"REDSTONE_TORCH",
	]:
		assert_true(
			source.contains("stack.item_id == Blocks.%s" % block_name),
			"Blocks.%s has a placement branch" % block_name
		)


func test_redstone_dust_places_wire_and_needs_a_solid_cube_under_it() -> void:
	# The two facts the placement branch depends on, checked against the
	# model rather than the scene: dust is an item id (so it must clear
	# the guard), and wire's support rule is the normal-cube test.
	assert_gte(Items.REDSTONE, 100, "dust is an item id, which is why the guard bites")
	assert_eq(Blocks.drops(Blocks.REDSTONE_WIRE), Items.REDSTONE, "and wire returns that item")

	var world := _SupportWorld.new()
	var place := Vector3i(0, 64, 0)
	world.blocks[place + Vector3i(0, -1, 0)] = Blocks.STONE
	assert_true(Redstone.is_normal_cube(world, place + Vector3i(0, -1, 0)), "stone supports wire")
	world.blocks[place + Vector3i(0, -1, 0)] = Blocks.GLASS
	assert_false(Redstone.is_normal_cube(world, place + Vector3i(0, -1, 0)), "glass does not")
	world.blocks[place + Vector3i(0, -1, 0)] = Blocks.HALF_SLAB
	assert_false(Redstone.is_normal_cube(world, place + Vector3i(0, -1, 0)), "nor does a slab")


class _SupportWorld:
	extends RefCounted
	var blocks: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(_pos: Vector3i) -> int:
		return 0
