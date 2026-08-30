# gdlint: disable=max-public-methods
extends GutTest

# Beta 1.3 BlockRedstoneRepeater coverage. The historical implementation
# has several deliberate oddities: two world-state IDs plus one item ID,
# directional output despite canProvidePower() returning false, and an
# unpowered scheduled tick that always produces a minimum output pulse.

const Y: int = 64
const POS := Vector3i(8, Y, 8)
const _SFX_SCRIPT := preload("res://scripts/audio/sfx.gd")


class FakeWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var drops: Array = []

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block_state(pos: Vector3i, id: int, meta: int, _notify: bool = true) -> bool:
		var masked: int = meta & 0xF
		if get_world_block(pos) == id and get_world_block_meta(pos) == masked:
			return false
		blocks[pos] = id
		metas[pos] = masked
		return true

	func spawn_block_drop(pos: Vector3i, item_id: int) -> void:
		drops.append([pos, item_id])

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta & 0xF


var _w: FakeWorld


func before_each() -> void:
	TickScheduler.reset_for_tests()
	Redstone.reset_state()
	BlockAtlas.reset()
	Recipes.load_from_json("res://data/recipes.json")
	_w = FakeWorld.new()
	_w.put(POS + Vector3i(0, -1, 0), Blocks.STONE)


func after_each() -> void:
	TickScheduler.reset_for_tests()
	Redstone.reset_state()


func _advance_ticks(count: int) -> void:
	for _i in range(count):
		TickScheduler.advance(TickScheduler.SECONDS_PER_TICK, _w)


func _power_rear(meta: int, powered: bool = true) -> Vector3i:
	var rear: Vector3i = POS + Redstone.repeater_input_offset(meta)
	var lever_meta: int = Redstone.MOUNT_FLOOR | (Redstone.POWERED_BIT if powered else 0)
	_w.put(rear, Blocks.LEVER, lever_meta)
	return rear


# --- Registration / item split ----------------------------------------


func test_state_blocks_and_item_are_registered_without_id_overlap() -> void:
	assert_true(Blocks.is_registered(Blocks.REDSTONE_REPEATER_OFF))
	assert_true(Blocks.is_registered(Blocks.REDSTONE_REPEATER_ON))
	assert_true(Items.is_registered(Items.REDSTONE_REPEATER))
	assert_false(Items.is_registered(Blocks.REDSTONE_REPEATER_OFF))
	assert_false(Items.is_registered(Blocks.REDSTONE_REPEATER_ON))
	assert_false(Blocks.is_registered(Items.REDSTONE_REPEATER))
	for id: int in [Blocks.REDSTONE_REPEATER_OFF, Blocks.REDSTONE_REPEATER_ON]:
		assert_true(Blocks.WORLD_ONLY_IDS.has(id), "state id %d is world-only" % id)
		assert_false(Blocks.has_item_form(id), "state id %d never enters inventory" % id)


func test_both_states_drop_the_dedicated_item() -> void:
	assert_eq(Blocks.drops(Blocks.REDSTONE_REPEATER_OFF), Items.REDSTONE_REPEATER)
	assert_eq(Blocks.drops(Blocks.REDSTONE_REPEATER_ON), Items.REDSTONE_REPEATER)
	assert_eq(Items.display_name(Items.REDSTONE_REPEATER), "Redstone Repeater")
	assert_eq(Items.max_stack_size(Items.REDSTONE_REPEATER), 64)


func test_debug_spawner_lists_the_item_once_beside_redstone_dust() -> void:
	var script: GDScript = load("res://scripts/ui/debug_item_spawner.gd") as GDScript
	assert_not_null(script, "debug item spawner loads")
	if script == null:
		return
	var items: Array = script.get_script_constant_map()["_ITEMS"]
	assert_eq(items.count(Items.REDSTONE_REPEATER), 1, "one dedicated repeater entry")
	assert_eq(
		items.find(Items.REDSTONE_REPEATER),
		items.find(Items.REDSTONE) + 1,
		"repeater is discoverable beside redstone dust"
	)


func test_repeater_has_beta_bounds_light_and_material_properties() -> void:
	for id: int in [Blocks.REDSTONE_REPEATER_OFF, Blocks.REDSTONE_REPEATER_ON]:
		assert_eq(Blocks.mesh_shape(id), Blocks.MESH_SHAPE_REDSTONE_REPEATER)
		assert_false(Blocks.is_opaque(id))
		assert_true(Blocks.is_solid_collision(id))
		assert_eq(Blocks.light_opacity(id), 0)
		assert_eq(
			Blocks.selection_aabb(id), AABB(Vector3.ZERO, Vector3(1.0, 0.125, 1.0)), "1/8-high base"
		)
	assert_eq(Blocks.light_emission(Blocks.REDSTONE_REPEATER_OFF), 0)
	assert_eq(Blocks.light_emission(Blocks.REDSTONE_REPEATER_ON), 9)
	var sfx := _SFX_SCRIPT.new()
	assert_eq(sfx._material_for(Blocks.REDSTONE_REPEATER_OFF), "wood")
	assert_eq(sfx._material_for(Blocks.REDSTONE_REPEATER_ON), "wood")
	sfx.free()


# --- Directional power -------------------------------------------------


func test_powered_repeater_outputs_in_exactly_one_slot_for_every_facing() -> void:
	var expected: Array[int] = [
		Redstone.SLOT_SOUTH,
		Redstone.SLOT_WEST,
		Redstone.SLOT_NORTH,
		Redstone.SLOT_EAST,
	]
	for facing in range(4):
		_w.put(POS, Blocks.REDSTONE_REPEATER_ON, facing)
		for slot in range(6):
			var should_power: bool = slot == expected[facing]
			assert_eq(
				Redstone.provides_weak_power(_w, POS, slot),
				should_power,
				"facing %d weak slot %d" % [facing, slot]
			)
			assert_eq(
				Redstone.provides_strong_power(_w, POS, slot),
				should_power,
				"facing %d strong slot %d" % [facing, slot]
			)


func test_unpowered_repeater_outputs_nothing() -> void:
	_w.put(POS, Blocks.REDSTONE_REPEATER_OFF, 0)
	for slot in range(6):
		assert_false(Redstone.provides_weak_power(_w, POS, slot), "weak slot %d" % slot)
		assert_false(Redstone.provides_strong_power(_w, POS, slot), "strong slot %d" % slot)


func test_input_is_sampled_only_from_the_rear() -> void:
	for facing in range(4):
		_w.blocks.clear()
		_w.metas.clear()
		_w.put(POS + Vector3i(0, -1, 0), Blocks.STONE)
		_w.put(POS, Blocks.REDSTONE_REPEATER_OFF, facing)
		var rear: Vector3i = _power_rear(facing)
		assert_true(Redstone.repeater_input_powered(_w, POS), "facing %d reads rear" % facing)
		_w.put(rear, Blocks.AIR)
		var side: Vector3i = POS + Redstone.repeater_output_offset((facing + 1) & 3)
		_w.put(side, Blocks.LEVER, Redstone.MOUNT_FLOOR | Redstone.POWERED_BIT)
		assert_false(Redstone.repeater_input_powered(_w, POS), "facing %d ignores side" % facing)


func test_beta_repeater_is_not_a_wire_connection_source() -> void:
	# BlockRedstoneRepeater.canProvidePower() is false in Beta 1.3.
	# Directional world power still works through the methods above, but
	# dust does not auto-connect visually until the later Beta 1.7 rule.
	assert_false(Redstone.is_power_source(Blocks.REDSTONE_REPEATER_OFF))
	assert_false(Redstone.is_power_source(Blocks.REDSTONE_REPEATER_ON))


# --- Delay and scheduled transitions ----------------------------------


func test_four_metadata_delays_are_2_4_6_8_game_ticks() -> void:
	for delay_index in range(4):
		assert_eq(
			Redstone.repeater_delay_ticks(delay_index << 2),
			[2, 4, 6, 8][delay_index],
			"delay index %d" % delay_index
		)
		assert_almost_eq(
			Redstone.repeater_torch_offset(delay_index << 2),
			[-0.0625, 0.0625, 0.1875, 0.3125][delay_index],
			0.0001,
			"delay torch index %d" % delay_index
		)


func test_right_click_cycle_preserves_direction_and_powered_state() -> void:
	_w.put(POS, Blocks.REDSTONE_REPEATER_ON, 3 | (2 << 2))
	assert_eq(Redstone.cycle_repeater_delay(_w, POS), 8)
	assert_eq(_w.get_world_block(POS), Blocks.REDSTONE_REPEATER_ON)
	assert_eq(_w.get_world_block_meta(POS), 3 | (3 << 2))
	assert_eq(Redstone.cycle_repeater_delay(_w, POS), 2)
	assert_eq(_w.get_world_block_meta(POS), 3)


func test_rising_edge_waits_for_selected_delay() -> void:
	var meta: int = 1 | (2 << 2)  # facing east, 6 game ticks
	_w.put(POS, Blocks.REDSTONE_REPEATER_OFF, meta)
	_power_rear(meta)
	Redstone.on_neighbor_changed(_w, POS)
	var queued: Array = TickScheduler.peek_for_chunk(0, 0)
	assert_eq(queued.size(), 1)
	assert_eq(int(queued[0]["delay"]), 6)
	_advance_ticks(5)
	assert_eq(_w.get_world_block(POS), Blocks.REDSTONE_REPEATER_OFF, "no early edge")
	_advance_ticks(1)
	assert_eq(_w.get_world_block(POS), Blocks.REDSTONE_REPEATER_ON, "rises on tick six")
	assert_eq(_w.get_world_block_meta(POS), meta, "metadata survives state swap")


func test_falling_edge_waits_for_selected_delay() -> void:
	var meta: int = 2 | (1 << 2)  # facing south, 4 game ticks
	_w.put(POS, Blocks.REDSTONE_REPEATER_ON, meta)
	Redstone.on_neighbor_changed(_w, POS)
	_advance_ticks(3)
	assert_eq(_w.get_world_block(POS), Blocks.REDSTONE_REPEATER_ON, "no early fall")
	_advance_ticks(1)
	assert_eq(_w.get_world_block(POS), Blocks.REDSTONE_REPEATER_OFF, "falls on tick four")


func test_short_input_still_produces_one_minimum_output_pulse() -> void:
	var meta: int = 0 | (1 << 2)  # 4 ticks
	_w.put(POS, Blocks.REDSTONE_REPEATER_OFF, meta)
	var rear: Vector3i = _power_rear(meta)
	Redstone.on_neighbor_changed(_w, POS)
	# Pulse ends before the scheduled rising edge. Beta's OFF update tick
	# still turns on, then schedules the ON state to fall one delay later.
	_w.put(rear, Blocks.AIR)
	Redstone.on_neighbor_changed(_w, POS)
	_advance_ticks(4)
	assert_eq(_w.get_world_block(POS), Blocks.REDSTONE_REPEATER_ON, "minimum pulse starts")
	assert_eq(TickScheduler.pending_count(), 1, "falling edge queued")
	_advance_ticks(3)
	assert_eq(_w.get_world_block(POS), Blocks.REDSTONE_REPEATER_ON)
	_advance_ticks(1)
	assert_eq(_w.get_world_block(POS), Blocks.REDSTONE_REPEATER_OFF, "minimum pulse ends")


func test_placement_into_existing_power_uses_the_one_tick_fast_path() -> void:
	_w.put(POS, Blocks.REDSTONE_REPEATER_OFF, 0)
	_power_rear(0)
	Redstone.on_repeater_placed(_w, POS)
	var queued: Array = TickScheduler.peek_for_chunk(0, 0)
	assert_eq(queued.size(), 1)
	assert_eq(int(queued[0]["delay"]), 1)
	_advance_ticks(1)
	assert_eq(_w.get_world_block(POS), Blocks.REDSTONE_REPEATER_ON)


func test_repeater_drops_when_opaque_support_disappears() -> void:
	_w.put(POS, Blocks.REDSTONE_REPEATER_ON, 7)
	_w.put(POS + Vector3i(0, -1, 0), Blocks.AIR)
	Redstone.on_neighbor_changed(_w, POS)
	assert_eq(_w.get_world_block(POS), Blocks.AIR)
	assert_eq(_w.drops, [[POS, Items.REDSTONE_REPEATER]])


# --- Recipe and rendering ----------------------------------------------


func test_beta_recipe_is_torch_dust_torch_over_three_stone() -> void:
	var grid: Array = [
		Blocks.REDSTONE_TORCH,
		Items.REDSTONE,
		Blocks.REDSTONE_TORCH,
		Blocks.STONE,
		Blocks.STONE,
		Blocks.STONE,
	]
	var result: Dictionary = Recipes.match_grid(grid, 3, 2)
	assert_eq(result.get("item_id", -1), Items.REDSTONE_REPEATER)
	assert_eq(result.get("count", 0), 1)
	grid[3] = Blocks.COBBLESTONE
	assert_ne(
		Recipes.match_grid(grid, 3, 2).get("item_id", -1),
		Items.REDSTONE_REPEATER,
		"recipe requires smooth stone"
	)


func test_custom_mesh_has_beta_base_collision_and_two_torches() -> void:
	var emitted: Dictionary = _emit_mesh(Blocks.REDSTONE_REPEATER_OFF, 0)
	assert_eq((emitted["vertices"] as PackedVector3Array).size(), 64)
	assert_eq((emitted["indices"] as PackedInt32Array).size(), 144)
	assert_eq((emitted["collision"] as PackedVector3Array).size(), 36)


func test_delay_metadata_moves_only_the_adjustable_torch_toward_the_rear() -> void:
	var shortest: PackedVector3Array = _emit_mesh(Blocks.REDSTONE_REPEATER_OFF, 0)["vertices"]
	var longest: PackedVector3Array = _emit_mesh(Blocks.REDSTONE_REPEATER_OFF, 12)["vertices"]
	assert_almost_eq(_torch_center(shortest, 24).z, 8.1875, 0.0001, "fixed output torch")
	assert_almost_eq(_torch_center(longest, 24).z, 8.1875, 0.0001, "fixed torch unchanged")
	assert_almost_eq(_torch_center(shortest, 44).z, 8.4375, 0.0001, "short delay position")
	assert_almost_eq(_torch_center(longest, 44).z, 8.8125, 0.0001, "long delay position")


func test_top_uv_rotates_for_all_four_orientations() -> void:
	var rect: Rect2 = BlockAtlas.uv_rect("redstone_repeater_off")
	var seen: Dictionary = {}
	for facing in range(4):
		seen[str(Mesher._repeater_top_uvs(rect, facing))] = true
	assert_eq(seen.size(), 4, "all four metadata directions use a distinct top rotation")


func test_item_icon_uses_the_beta_inventory_sprite() -> void:
	var icon: Texture2D = ItemIcons.icon_for(Items.REDSTONE_REPEATER)
	assert_not_null(icon)
	if icon != null:
		assert_eq(icon.get_width(), 16)
		assert_eq(icon.get_height(), 16)


func test_item_sprite_builds_held_and_dropped_visuals() -> void:
	var icon: Texture2D = ItemIcons.icon_for(Items.REDSTONE_REPEATER)
	assert_not_null(icon, "inventory/debug icon exists")
	if icon == null:
		return
	var held: ArrayMesh = SpriteExtruder.build(icon)
	assert_not_null(held, "held repeater extrudes from the item sprite")
	if held != null:
		assert_gt(held.get_surface_count(), 0, "held repeater has geometry")

	var dropped := DroppedItem.new()
	add_child_autofree(dropped)
	dropped.set_process(false)
	dropped.global_position = Vector3(0.5, 65.0, 0.5)
	dropped.setup(Items.REDSTONE_REPEATER)
	assert_true(dropped._is_sprite_item, "dropped repeater uses the item-sprite path")
	assert_not_null(dropped._mesh.mesh, "dropped repeater has a visible mesh")
	if dropped._mesh.mesh != null:
		assert_gt(dropped._mesh.mesh.get_surface_count(), 0, "dropped repeater mesh has geometry")


func test_both_placed_states_survive_the_full_mesher_dispatch() -> void:
	BlockAtlas.build()
	for id: int in [Blocks.REDSTONE_REPEATER_OFF, Blocks.REDSTONE_REPEATER_ON]:
		var chunk := Chunk.new()
		chunk.set_block(POS.x, POS.y, POS.z, id)
		chunk.set_block_meta(POS.x, POS.y, POS.z, 3 | (2 << 2))
		var emitted: Dictionary = Mesher.mesh_chunk_fast(chunk)
		assert_gt(
			(emitted["vertices"] as PackedVector3Array).size(),
			0,
			"state %d renders through native/GDScript dispatch" % id
		)
		assert_gt(
			(emitted["collision_faces"] as PackedVector3Array).size(),
			0,
			"state %d keeps its placed collision" % id
		)


func _emit_mesh(id: int, meta: int) -> Dictionary:
	BlockAtlas.build()
	var chunk := Chunk.new()
	chunk.set_block(POS.x, POS.y, POS.z, id)
	chunk.set_block_meta(POS.x, POS.y, POS.z, meta)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var collision := PackedVector3Array()
	Mesher._emit_repeater_geometry(
		chunk, POS.x, POS.y, POS.z, id, verts, norms, uvs, colors, indices, collision
	)
	return {
		"vertices": verts,
		"normals": norms,
		"uvs": uvs,
		"colors": colors,
		"indices": indices,
		"collision": collision,
	}


func _torch_center(vertices: PackedVector3Array, first: int) -> Vector3:
	var total := Vector3.ZERO
	for i in range(first, first + 20):
		total += vertices[i]
	return total / 20.0
