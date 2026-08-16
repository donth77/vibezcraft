extends GutTest

# Fluid displacement drops — `ja.java:101-113` (`flowIntoBlock`).
#
#   if (existing > 0) {
#       if (material == lava) triggerLavaMixEffects(...)
#       else Block.blocksList[existing].dropBlockAsItems(...)
#   }
#   setBlockAndMetadata(fluid)
#
# Water hands the block it displaces to the drop path; lava does not.
# Our port skipped the drop entirely, so a water stream crossing a
# redstone line DELETED the dust instead of washing it off as something
# you can pick up again — and the only test covering it asserted
# `Blocks.is_replaceable()`, which is a different question (can the fluid
# move in at all) and stayed green throughout.
#
# So these tests run the real flow and inspect what the world spawned.

const SRC := Vector3i(0, 64, 0)
const FLOOR_Y: int = 63


class FluidWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var drops: Array = []

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block(pos: Vector3i, id: int, meta: int = -1) -> bool:
		blocks[pos] = id
		metas[pos] = 0 if meta < 0 else (meta & 0xF)
		return true

	func set_world_block_with_meta(pos: Vector3i, id: int, meta: int) -> bool:
		blocks[pos] = id
		metas[pos] = meta & 0xF
		return true

	func spawn_block_drop(pos: Vector3i, dropped_id: int) -> void:
		drops.append([pos, dropped_id])

	func get_chunk_at_coord(_coord: Vector2i):
		return null

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _w: FluidWorld


func before_each() -> void:
	_w = FluidWorld.new()
	TickScheduler.reset_for_tests()
	# Stone floor wide enough that vanilla's depth-4 drop search
	# (`ja.java:115-143`) finds no hole in any direction. Otherwise the
	# flow biases toward the nearest edge and never reaches the cell
	# under test — the spread is directional, not uniform.
	for x in range(-6, 7):
		for z in range(-6, 7):
			_w.put(Vector3i(x, FLOOR_Y, z), Blocks.STONE)


func after_each() -> void:
	TickScheduler.reset_for_tests()


# Put `id` one cell east of the source and let the source flow into it.
func _flow_into(id: int, fluid: int = Blocks.WATER_STILL) -> Vector3i:
	var target: Vector3i = SRC + Vector3i(1, 0, 0)
	_w.put(target, id, 0)
	_w.put(SRC, fluid, 0)
	BlockFluids.update(_w, SRC, fluid)
	return target


func _dropped_ids() -> Array:
	var out: Array = []
	for entry: Array in _w.drops:
		out.append(entry[1])
	return out


# --- The redstone matrix -----------------------------------------------


func test_water_washing_wire_away_drops_redstone_dust() -> void:
	var target: Vector3i = _flow_into(Blocks.REDSTONE_WIRE)
	assert_true(Blocks.is_water(_w.get_world_block(target)), "water moved in")
	assert_eq(_dropped_ids(), [Items.REDSTONE], "wire came back as dust")


func test_both_torch_ids_wash_out_as_a_lit_torch() -> void:
	# Vanilla `an.java`-style two-id blocks always drop the canonical
	# item, so an OFF torch caught by a flood is not lost.
	for id: int in [Blocks.REDSTONE_TORCH, Blocks.REDSTONE_TORCH_OFF]:
		before_each()
		_flow_into(id)
		assert_eq(_dropped_ids(), [Blocks.REDSTONE_TORCH], "%s → lit torch" % Blocks.name_of(id))


func test_lever_button_and_both_plates_drop_themselves() -> void:
	for id: int in [
		Blocks.LEVER,
		Blocks.STONE_BUTTON,
		Blocks.STONE_PRESSURE_PLATE,
		Blocks.WOODEN_PRESSURE_PLATE,
	]:
		before_each()
		_flow_into(id)
		assert_eq(_dropped_ids(), [id], "%s drops itself" % Blocks.name_of(id))


func test_redstone_ore_blocks_the_flow_and_is_not_removed() -> void:
	for id: int in [Blocks.REDSTONE_ORE, Blocks.GLOWING_REDSTONE_ORE]:
		before_each()
		var target: Vector3i = _flow_into(id)
		assert_eq(_w.get_world_block(target), id, "%s stands its ground" % Blocks.name_of(id))
		assert_eq(_w.drops.size(), 0, "and drops nothing")


# --- The water / lava split --------------------------------------------


func test_lava_destroys_without_dropping() -> void:
	# ja.java takes the `triggerLavaMixEffects` branch for lava, which
	# never calls dropBlockAsItems.
	var target: Vector3i = _flow_into(Blocks.REDSTONE_WIRE, Blocks.LAVA_STILL)
	assert_true(Blocks.is_lava(_w.get_world_block(target)), "lava moved in")
	assert_eq(_w.drops.size(), 0, "nothing recoverable from lava")


func test_flowing_into_air_drops_nothing() -> void:
	_w.put(SRC, Blocks.WATER_STILL, 0)
	BlockFluids.update(_w, SRC, Blocks.WATER_STILL)
	assert_gt(_w.blocks.size(), 0, "the flow happened")
	assert_eq(_w.drops.size(), 0, "empty cells produce no drops")


func test_water_spreading_over_water_drops_nothing() -> void:
	# Guards the obvious own-goal: the fluid family is explicitly exempt
	# in `Blocks.drops`, and without that a spreading pool would litter
	# itself with water-block items.
	_flow_into(Blocks.WATER_FLOWING)
	assert_eq(_w.drops.size(), 0, "no self-drops")


# --- The unit under it -------------------------------------------------


func test_wash_away_reports_what_it_dropped() -> void:
	assert_eq(
		BlockFluids.wash_away(_w, SRC, Blocks.REDSTONE_WIRE, Blocks.WATER_FLOWING),
		Items.REDSTONE,
		"water drops"
	)
	assert_eq(
		BlockFluids.wash_away(_w, SRC, Blocks.REDSTONE_WIRE, Blocks.LAVA_FLOWING),
		Blocks.AIR,
		"lava does not"
	)
	assert_eq(
		BlockFluids.wash_away(_w, SRC, Blocks.GLASS, Blocks.WATER_FLOWING),
		Blocks.AIR,
		"a block with no drop reports none"
	)
