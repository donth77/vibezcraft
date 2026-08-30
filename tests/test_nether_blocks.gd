# gdlint: disable=max-public-methods
extends GutTest

# Netherrack, soul sand, glowstone, glowstone dust and the portal
# (docs/nether-alpha-1.2.6-implementation-plan.md §4, Batch 2).
#
# Every property here traces to a line of Alpha source, cited inline.
# The registrations are:
#
#   nq.java:110  nq bb = new qb(87, 103).c(0.4f).a(h)             netherrack
#   nq.java:111  nq bc = new it(88, 104).c(0.5f).a(l)             soul sand
#   nq.java:112  nq bd = new hk(89, 105, hb.o).c(0.3f).a(j).a(1)  glowstone
#   nq.java:113  x  be = new x (90,  14).c(-1f) .a(j).a(0.75f)    portal
#   dx.java:101  dx aR = new dx(92).a(73)                         dust
#   en.java:32   nine dust -> one glowstone
#
# The portal is the interesting one: it is a block whose id (206) sits
# ABOVE the item floor of 100, and it must never reach an item-facing
# path. Half this file exists to pin that.

const _WORLD := "test_nether_blocks"
const _INTERACTION := preload("res://scripts/player/interaction.gd")

var _dimension_was: int


func before_each() -> void:
	_dimension_was = DimensionContext.active()


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)
	SaveLoad.delete_world(_WORLD)
	SaveLoad.clear_cache()


# --- Registration and ids ---


func test_the_reserved_ids_are_now_claimed_by_the_right_registry() -> void:
	assert_eq(Blocks.NETHERRACK, 97, "netherrack took its reserved id")
	assert_eq(Blocks.SOUL_SAND, 98, "soul sand took its reserved id")
	assert_eq(Blocks.GLOWSTONE, 99, "glowstone took its reserved id")
	assert_eq(Blocks.PORTAL, 206, "portal took its reserved id")
	assert_eq(Items.GLOWSTONE_DUST, 205, "glowstone dust took its reserved id")
	for id: int in [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE, Blocks.PORTAL]:
		assert_true(Blocks.is_registered(id), "block %d is registered" % id)
		assert_false(Items.is_registered(id), "block %d is not an item" % id)
	assert_true(Items.is_registered(Items.GLOWSTONE_DUST), "dust is an item")
	assert_false(Blocks.is_registered(Items.GLOWSTONE_DUST), "dust is not a block")


func test_the_three_inventory_blocks_have_an_item_form() -> void:
	for id: int in [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE]:
		assert_true(Blocks.has_item_form(id), "block %d can be carried" % id)
		assert_true(Blocks.is_inventory_placeable(id), "block %d can be placed" % id)


func test_names_resolve_both_directions() -> void:
	assert_eq(Blocks.name_of(Blocks.NETHERRACK), "netherrack")
	assert_eq(Blocks.name_of(Blocks.SOUL_SAND), "soul_sand")
	assert_eq(Blocks.name_of(Blocks.GLOWSTONE), "glowstone")
	assert_eq(Blocks.name_of(Blocks.PORTAL), "portal")
	assert_eq(Items.id_from_name("netherrack"), Blocks.NETHERRACK)
	assert_eq(Items.id_from_name("soul_sand"), Blocks.SOUL_SAND)
	assert_eq(Items.id_from_name("glowstone"), Blocks.GLOWSTONE)
	assert_eq(Items.id_from_name("glowstone_dust"), Items.GLOWSTONE_DUST)
	assert_eq(Items.display_name(Items.GLOWSTONE_DUST), "Glowstone Dust")


# --- Hardness and tools ---


func test_hardness_matches_the_source_registrations() -> void:
	assert_almost_eq(Blocks.hardness(Blocks.NETHERRACK), 0.4, 1e-6, "nq.java:110 .c(0.4f)")
	assert_almost_eq(Blocks.hardness(Blocks.SOUL_SAND), 0.5, 1e-6, "nq.java:111 .c(0.5f)")
	assert_almost_eq(Blocks.hardness(Blocks.GLOWSTONE), 0.3, 1e-6, "nq.java:112 .c(0.3f)")


func test_the_portal_is_unbreakable() -> void:
	# nq.java:113 `.c(-1.0f)` — vanilla's indestructible sentinel, the
	# same value bedrock uses.
	assert_eq(Blocks.hardness(Blocks.PORTAL), -1.0, "portal hardness is the unbreakable sentinel")
	assert_eq(
		Blocks.hardness(Blocks.PORTAL),
		Blocks.hardness(Blocks.BEDROCK),
		"same sentinel bedrock uses"
	)


func test_preferred_tools_follow_the_source_materials() -> void:
	# Netherrack is rock (hb.d) -> pickaxe; soul sand is sand (hb.m) ->
	# shovel, like sand and gravel.
	assert_eq(
		Blocks.preferred_tool_type(Blocks.NETHERRACK),
		Items.TOOL_TYPE_PICKAXE,
		"netherrack is a pickaxe block"
	)
	assert_eq(
		Blocks.preferred_tool_type(Blocks.SOUL_SAND),
		Items.TOOL_TYPE_SHOVEL,
		"soul sand is a shovel block"
	)


func test_no_nether_block_needs_a_tool_tier() -> void:
	# None of the three carry a harvest-level requirement in Alpha, so
	# every pickaxe tier works on netherrack and glowstone drops its dust
	# regardless of what broke it.
	for id: int in [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE]:
		assert_eq(Blocks.required_harvest_level(id), 0, "block %d has no tier gate" % id)


func test_bare_hand_timing_uses_the_authoritative_material_branch() -> void:
	# Netherrack is rock material. Alpha's player-relative hardness takes
	# the wrong-tool branch with an empty hand: 0.4 hardness * 5 = 2.0 s.
	assert_almost_eq(Blocks.break_time_bare_hand(Blocks.NETHERRACK), 2.0, 1e-6)
	for id: int in [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE, Blocks.PORTAL]:
		assert_almost_eq(
			Blocks.break_time_bare_hand(id),
			Blocks.break_time(id, Blocks.AIR),
			1e-6,
			"bare-hand helper delegates for block %d" % id
		)


func test_nether_blast_resistance_matches_alpha_registration_math() -> void:
	# nq.c(hardness) stores hardness*5 and the public getter divides by 5.
	# nq.b(value) stores value*3, so explicit values expose value*3/5.
	assert_almost_eq(Blocks.explosion_resistance(Blocks.NETHERRACK), 0.4, 1e-6)
	assert_almost_eq(Blocks.explosion_resistance(Blocks.SOUL_SAND), 0.5, 1e-6)
	assert_almost_eq(Blocks.explosion_resistance(Blocks.GLOWSTONE), 0.3, 1e-6)
	assert_almost_eq(Blocks.explosion_resistance(Blocks.PORTAL), 0.0, 1e-6)
	assert_almost_eq(Blocks.explosion_resistance(Blocks.OBSIDIAN), 1200.0, 1e-6)
	assert_almost_eq(Blocks.explosion_resistance(Blocks.BEDROCK), 3600000.0, 1e-6)
	assert_almost_eq(Blocks.explosion_resistance(Blocks.LAVA_FLOWING), 0.0, 1e-6)
	assert_almost_eq(Blocks.explosion_resistance(Blocks.LAVA_STILL), 100.0, 1e-6)
	assert_almost_eq(Blocks.explosion_resistance(Blocks.GRAVEL), 0.6, 1e-6)


# --- Drops ---


func test_glowstone_drops_exactly_one_dust_and_never_itself() -> void:
	# hk.java::a(int, Random) returns dx.aR unconditionally. Alpha has no
	# fortune term and no 2-4 range; that is a later version's behaviour.
	assert_eq(Blocks.drops(Blocks.GLOWSTONE), Items.GLOWSTONE_DUST, "drops dust")
	assert_ne(Blocks.drops(Blocks.GLOWSTONE), Blocks.GLOWSTONE, "never drops the block")
	assert_eq(Blocks.drop_quantity(Blocks.GLOWSTONE), 1, "exactly one")


func test_glowstone_drop_is_independent_of_the_tool_used() -> void:
	for tool: int in [
		0,
		Items.WOODEN_PICKAXE,
		Items.DIAMOND_PICKAXE,
		Items.GOLD_PICKAXE,
		Items.IRON_SHOVEL,
	]:
		assert_eq(
			Blocks.drop_with_tool(Blocks.GLOWSTONE, tool),
			Items.GLOWSTONE_DUST,
			"tool %d still yields dust" % tool
		)


func test_netherrack_and_soul_sand_drop_themselves() -> void:
	assert_eq(Blocks.drops(Blocks.NETHERRACK), Blocks.NETHERRACK, "netherrack drops itself")
	assert_eq(Blocks.drops(Blocks.SOUL_SAND), Blocks.SOUL_SAND, "soul sand drops itself")


func test_netherrack_only_harvests_with_a_pickaxe() -> void:
	# qb.java gives netherrack rock material (hb.d). fo.java::b rejects
	# rock when the player has no harvesting item, while ac.java::a accepts
	# every rock-material block for every pickaxe tier.
	for tool: int in [Blocks.AIR, Items.WOODEN_SHOVEL, Items.GOLD_SWORD]:
		assert_eq(
			Blocks.random_drop(Blocks.NETHERRACK, tool),
			Blocks.AIR,
			"tool %d breaks netherrack but cannot harvest it" % tool
		)
	for pickaxe: int in [
		Items.WOODEN_PICKAXE,
		Items.STONE_PICKAXE,
		Items.IRON_PICKAXE,
		Items.DIAMOND_PICKAXE,
		Items.GOLD_PICKAXE,
	]:
		assert_eq(
			Blocks.random_drop(Blocks.NETHERRACK, pickaxe),
			Blocks.NETHERRACK,
			"pickaxe %d harvests one netherrack" % pickaxe
		)


func test_soul_sand_harvests_itself_even_without_a_shovel() -> void:
	# it.java uses sand material (hb.m), which fo.java::b allows the player
	# to harvest without a tool. A shovel is a speed bonus, not a drop gate.
	for tool: int in [Blocks.AIR, Items.WOODEN_SHOVEL, Items.DIAMOND_PICKAXE, Items.GOLD_SWORD]:
		assert_eq(
			Blocks.random_drop(Blocks.SOUL_SAND, tool),
			Blocks.SOUL_SAND,
			"tool %d yields one soul sand" % tool
		)


func test_the_survival_break_path_spawns_each_nether_drop() -> void:
	# This drives Interaction._complete_break, the gameplay entry point,
	# rather than stopping at the Blocks registry. It catches the original
	# symptom where a correct table entry could still fail to become a
	# DroppedItem in the world.
	DimensionContext.set_active(DimensionContext.NETHER)
	var cases: Array[Array] = [
		[Blocks.NETHERRACK, Blocks.AIR, []],
		[Blocks.NETHERRACK, Items.WOODEN_SHOVEL, []],
		[Blocks.NETHERRACK, Items.WOODEN_PICKAXE, [Blocks.NETHERRACK]],
		[Blocks.SOUL_SAND, Blocks.AIR, [Blocks.SOUL_SAND]],
		[Blocks.SOUL_SAND, Items.WOODEN_SHOVEL, [Blocks.SOUL_SAND]],
		[Blocks.GLOWSTONE, Blocks.AIR, [Items.GLOWSTONE_DUST]],
		[Blocks.GLOWSTONE, Items.DIAMOND_PICKAXE, [Items.GLOWSTONE_DUST]],
		[Blocks.GLOWSTONE, Items.WOODEN_SHOVEL, [Items.GLOWSTONE_DUST]],
	]
	for entry: Array in cases:
		var result: Dictionary = _break_through_interaction(entry[0], entry[1])
		assert_eq(result.block_after, Blocks.AIR, "block %d was removed" % entry[0])
		assert_eq(result.drops, entry[2], "block %d with tool %d" % [entry[0], entry[1]])


func test_the_portal_drops_nothing() -> void:
	assert_eq(Blocks.drops(Blocks.PORTAL), Blocks.AIR, "x.java has no drop")
	for tool: int in [Blocks.AIR, Items.WOODEN_PICKAXE, Items.DIAMOND_PICKAXE]:
		assert_eq(
			Blocks.random_drop(Blocks.PORTAL, tool), Blocks.AIR, "no drop with tool %d" % tool
		)


# --- Light ---


func test_glowstone_emits_full_light() -> void:
	assert_eq(Blocks.light_emission(Blocks.GLOWSTONE), 15, "nq.java:112 .a(1.0f) -> 15")


func test_the_portal_emits_light_eleven() -> void:
	# .a(0.75f) -> int(15 * 0.75) = 11.
	assert_eq(Blocks.light_emission(Blocks.PORTAL), 11, "nq.java:113 .a(0.75f) -> 11")


func test_netherrack_and_soul_sand_emit_nothing() -> void:
	assert_eq(Blocks.light_emission(Blocks.NETHERRACK), 0)
	assert_eq(Blocks.light_emission(Blocks.SOUL_SAND), 0)


func test_the_portal_does_not_block_light() -> void:
	# A thin translucent surface, registered non-opaque in vanilla.
	assert_eq(Blocks.light_opacity(Blocks.PORTAL), 0, "light passes through a portal")
	assert_false(Blocks.is_opaque(Blocks.PORTAL), "and terrain behind it keeps its faces")


func test_the_solid_nether_blocks_are_opaque() -> void:
	for id: int in [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE]:
		assert_true(Blocks.is_opaque(id), "block %d is a solid cube" % id)
		assert_eq(Blocks.light_opacity(id), 15, "block %d blocks light fully" % id)


# --- Soul sand physics ---


func test_soul_sand_collision_top_is_seven_eighths() -> void:
	# it.java::d uses f2 = 0.125f and returns a box ending at y+1-f2.
	# This has to be a real collision height: it changes eye/foot height
	# and step-up, which a speed modifier on a full cube cannot.
	var box: AABB = Blocks.collision_aabb(Blocks.SOUL_SAND)
	assert_eq(box.position, Vector3.ZERO, "full-width cell")
	assert_eq(box.size.x, 1.0, "full width in X")
	assert_eq(box.size.z, 1.0, "full width in Z")
	assert_almost_eq(box.size.y, 0.875, 1e-6, "top face sits at 0.875")
	assert_eq(
		Blocks.selection_aabb(Blocks.SOUL_SAND),
		AABB(Vector3.ZERO, Vector3.ONE),
		"base block bounds remain full-height for ray selection"
	)


func test_soul_sand_scales_horizontal_motion_by_four_tenths() -> void:
	# it.java::a(cy, x, y, z, lw): `lw2.az *= 0.4; lw2.aB *= 0.4;`
	var entity := CharacterBody3D.new()
	add_child_autofree(entity)
	entity.velocity = Vector3(5.0, -9.0, -2.5)
	assert_true(Blocks.apply_soul_sand_drag(entity), "drag applied")
	assert_almost_eq(entity.velocity.x, 2.0, 1e-6, "X scaled by 0.4")
	assert_almost_eq(entity.velocity.z, -1.0, 1e-6, "Z scaled by 0.4")


func test_soul_sand_leaves_vertical_motion_alone() -> void:
	# The source touches az and aB only. Scaling aA too would stop the
	# player jumping out of soul sand, which vanilla allows.
	var entity := CharacterBody3D.new()
	add_child_autofree(entity)
	entity.velocity = Vector3(1.0, 8.5, 1.0)
	Blocks.apply_soul_sand_drag(entity)
	assert_almost_eq(entity.velocity.y, 8.5, 1e-6, "Y untouched")


func test_soul_sand_drag_is_safe_on_a_null_or_velocity_less_entity() -> void:
	assert_false(Blocks.apply_soul_sand_drag(null), "null entity is a no-op")
	var plain := Node3D.new()
	add_child_autofree(plain)
	assert_false(Blocks.apply_soul_sand_drag(plain), "an entity with no velocity is a no-op")


func test_the_walk_hook_routes_soul_sand_to_the_drag() -> void:
	# The production entry point: Blocks.on_entity_walking is what the
	# player, mobs and carts all call for the cell under their feet.
	var world := _FakeWorld.new()
	autofree(world)
	world.blocks[Vector3i(0, 63, 0)] = Blocks.SOUL_SAND
	var entity := CharacterBody3D.new()
	add_child_autofree(entity)
	entity.velocity = Vector3(10.0, 0.0, 10.0)
	Blocks.on_entity_walking(world, Vector3i(0, 63, 0), entity)
	assert_almost_eq(entity.velocity.x, 4.0, 1e-6, "walking on soul sand slows X")
	assert_almost_eq(entity.velocity.z, 4.0, 1e-6, "and Z")


func test_soul_sand_collision_callback_reapplies_without_changing_cells() -> void:
	# lw.java invokes block/entity collision callbacks after every move, not
	# only when the lowest occupied cell changes.
	var world := _FakeWorld.new()
	autofree(world)
	world.blocks[Vector3i.ZERO] = Blocks.SOUL_SAND
	var entity := CharacterBody3D.new()
	add_child_autofree(entity)
	entity.velocity = Vector3(10.0, 3.0, 10.0)
	var box := AABB(Vector3(0.1, 0.1, 0.1), Vector3(0.8, 0.8, 0.8))
	assert_eq(Blocks.apply_entity_collision_callbacks(world, box, entity), 1)
	assert_almost_eq(entity.velocity.x, 4.0, 1e-6, "first move applies 0.4")
	assert_eq(Blocks.apply_entity_collision_callbacks(world, box, entity), 1)
	assert_almost_eq(entity.velocity.x, 1.6, 1e-6, "same-cell next move applies it again")
	assert_almost_eq(entity.velocity.y, 3.0, 1e-6, "vertical motion remains untouched")


func test_soul_sand_drag_reaches_node3d_entities_with_private_motion() -> void:
	var entity := _PrivateVelocityEntity.new()
	add_child_autofree(entity)
	entity._velocity = Vector3(5.0, -2.0, -5.0)
	assert_true(Blocks.apply_soul_sand_drag(entity), "dropped-item/arrow storage is supported")
	assert_eq(entity._velocity, Vector3(2.0, -2.0, -2.0))


func test_walking_on_ordinary_ground_does_not_slow_anything() -> void:
	var world := _FakeWorld.new()
	autofree(world)
	world.blocks[Vector3i(0, 63, 0)] = Blocks.STONE
	var entity := CharacterBody3D.new()
	add_child_autofree(entity)
	entity.velocity = Vector3(10.0, 0.0, 10.0)
	Blocks.on_entity_walking(world, Vector3i(0, 63, 0), entity)
	assert_almost_eq(entity.velocity.x, 10.0, 1e-6, "stone does not drag")


# --- Portal exclusion from every item-facing path ---


func test_the_portal_has_no_item_form() -> void:
	assert_true(Blocks.is_registered(Blocks.PORTAL), "it is a real block")
	assert_false(Blocks.has_item_form(Blocks.PORTAL), "with no inventory form")
	assert_false(Blocks.is_inventory_placeable(Blocks.PORTAL), "and no placement")
	assert_true(Blocks.WORLD_ONLY_IDS.has(Blocks.PORTAL), "it is listed as a world-only block")


func test_the_portal_is_absent_from_the_debug_spawner() -> void:
	var script: GDScript = load("res://scripts/ui/debug_item_spawner.gd") as GDScript
	assert_not_null(script, "debug spawner loads")
	if script == null:
		return
	var consts: Dictionary = script.get_script_constant_map()
	var blocks: Array = consts.get("_BLOCKS", []) as Array
	var items: Array = consts.get("_ITEMS", []) as Array
	assert_false(blocks.has(Blocks.PORTAL), "portal is not in the block grid")
	assert_false(items.has(Blocks.PORTAL), "nor the item grid")
	for id: int in [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE]:
		assert_true(blocks.has(id), "block %d IS in the grid" % id)
	assert_true(items.has(Items.GLOWSTONE_DUST), "dust is in the item grid")


func test_the_portal_is_absent_from_the_inventory_icon_bake() -> void:
	var script: GDScript = load("res://scripts/ui/block_icon_renderer.gd") as GDScript
	assert_not_null(script, "icon renderer loads")
	if script == null:
		return
	var iconified: Array = script.get_script_constant_map().get("_ICONIFIED_BLOCKS", []) as Array
	assert_false(iconified.has(Blocks.PORTAL), "no inventory icon is baked for the portal")
	for id: int in [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE]:
		assert_true(iconified.has(id), "block %d gets an iso bake" % id)


func test_the_portal_is_passable_but_has_thin_ray_bounds() -> void:
	# x.java returns null from the entity-collision method, then sets a
	# 1/4-thick orientation-dependent bound for rendering/ray tracing.
	assert_false(Blocks.is_solid_collision(Blocks.PORTAL), "walk straight through")
	assert_eq(Blocks.collision_aabb(Blocks.PORTAL).size, Vector3.ZERO, "no entity collision")
	var box: AABB = Blocks.selection_aabb(Blocks.PORTAL)
	assert_eq(box.position, Vector3(0.375, 0.0, 0.0), "isolated-cell fallback is X-thin")
	assert_eq(box.size, Vector3(0.25, 1.0, 1.0), "ray target is a quarter-block slab")


func test_the_portal_still_round_trips_as_a_stored_byte() -> void:
	# Unobtainable as an item, perfectly ordinary as terrain.
	var chunk := Chunk.new()
	chunk.set_block(2, 70, 3, Blocks.PORTAL)
	assert_eq(chunk.get_block(2, 70, 3), Blocks.PORTAL, "chunk storage holds id 206")
	var restored: PackedByteArray = chunk.blocks.compress().decompress(chunk.blocks.size())
	assert_eq(restored, chunk.blocks, "and survives the compression path")


# --- Recipe ---


func test_nine_dust_crafts_one_glowstone() -> void:
	Recipes.ensure_loaded()
	var grid: Array = []
	for i: int in range(9):
		grid.append(Items.GLOWSTONE_DUST)
	var result: Dictionary = Recipes.match_grid(grid, 3, 3)
	assert_eq(int(result.get("item_id", 0)), Blocks.GLOWSTONE, "a full 3x3 of dust makes glowstone")
	assert_eq(int(result.get("count", 0)), 1, "exactly one block")


func test_there_is_no_four_dust_recipe() -> void:
	# Alpha v1.2.6 has only the nine-dust form; the four-dust recipe is a
	# later change and the plan forbids it explicitly.
	Recipes.ensure_loaded()
	var grid: Array = [
		Items.GLOWSTONE_DUST, Items.GLOWSTONE_DUST, Items.GLOWSTONE_DUST, Items.GLOWSTONE_DUST
	]
	var result: Dictionary = Recipes.match_grid(grid, 2, 2)
	assert_eq(int(result.get("item_id", 0)), 0, "2x2 of dust crafts nothing")


func test_eight_dust_is_not_enough() -> void:
	Recipes.ensure_loaded()
	var grid: Array = []
	for i: int in range(9):
		grid.append(Items.GLOWSTONE_DUST if i < 8 else 0)
	var result: Dictionary = Recipes.match_grid(grid, 3, 3)
	assert_eq(int(result.get("item_id", 0)), 0, "the recipe consumes all nine slots")


# --- Fire on netherrack ---


func test_fire_on_netherrack_survives_the_no_fuel_extinguish() -> void:
	# qh.java:52 gates the "nothing nearby to burn" path on whether the
	# block below is netherrack. On stone the fire goes out; on
	# netherrack it stays lit forever.
	var world := _FakeWorld.new()
	autofree(world)
	var fire_pos := Vector3i(0, 64, 0)
	world.blocks[fire_pos + Vector3i(0, -1, 0)] = Blocks.NETHERRACK
	world.blocks[fire_pos] = Blocks.FIRE
	world.meta[fire_pos] = 10  # well past the age-3 threshold
	BlockFire.update(world, fire_pos)
	assert_eq(world.blocks[fire_pos], Blocks.FIRE, "netherrack fire is eternal")


func test_the_same_fire_on_stone_goes_out() -> void:
	# The control case — proves the test above is measuring the netherrack
	# rule and not simply a fire that never extinguishes.
	var world := _FakeWorld.new()
	autofree(world)
	var fire_pos := Vector3i(0, 64, 0)
	world.blocks[fire_pos + Vector3i(0, -1, 0)] = Blocks.STONE
	world.blocks[fire_pos] = Blocks.FIRE
	world.meta[fire_pos] = 10
	BlockFire.update(world, fire_pos)
	assert_eq(world.blocks[fire_pos], Blocks.AIR, "fire with no fuel on stone burns out")


func test_fire_on_netherrack_survives_the_max_age_burnout() -> void:
	# The second extinguish path: age 15 with nothing flammable below.
	# Also gated on the netherrack flag. Run it many times because the
	# stone case is a 1-in-4 roll.
	var world := _FakeWorld.new()
	autofree(world)
	var fire_pos := Vector3i(0, 64, 0)
	for attempt: int in range(40):
		world.blocks.clear()
		world.meta.clear()
		world.blocks[fire_pos + Vector3i(0, -1, 0)] = Blocks.NETHERRACK
		# A flammable neighbour keeps the first extinguish path from
		# firing, so this test isolates the age-15 burnout.
		world.blocks[fire_pos + Vector3i(1, 0, 0)] = Blocks.PLANKS
		world.blocks[fire_pos] = Blocks.FIRE
		world.meta[fire_pos] = BlockFire.MAX_AGE
		BlockFire.update(world, fire_pos)
		assert_eq(world.blocks[fire_pos], Blocks.FIRE, "attempt %d: still burning" % attempt)


# --- Save round trip ---


func test_the_new_blocks_survive_a_region_round_trip() -> void:
	SaveLoad.delete_world(_WORLD)
	SaveLoad.clear_cache()
	var blocks := PackedByteArray()
	blocks.resize(Chunk.TOTAL_BLOCKS)
	var probes: Array[int] = [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE, Blocks.PORTAL]
	for i: int in range(probes.size()):
		blocks[i] = probes[i]
	var empty := PackedByteArray()
	empty.resize(Chunk.TOTAL_BLOCKS)
	var hm := PackedByteArray()
	hm.resize(Chunk.SIZE_X * Chunk.SIZE_Z)
	var entry: Dictionary = {
		"bytes": blocks.compress(FileAccess.COMPRESSION_FASTLZ),
		"block_meta": empty.compress(FileAccess.COMPRESSION_FASTLZ),
		"sky_light": empty.compress(FileAccess.COMPRESSION_FASTLZ),
		"block_light": empty.compress(FileAccess.COMPRESSION_FASTLZ),
		"height_map": hm.compress(FileAccess.COMPRESSION_FASTLZ),
		"max_y": 70,
		"pending_ticks": [],
	}
	assert_true(SaveLoad.save_chunk(Vector2i(0, 0), entry, _WORLD), "region written")
	SaveLoad.clear_cache()
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), _WORLD)
	assert_true(loaded.has("bytes"), "region read back")
	if loaded.has("bytes"):
		var out: PackedByteArray = loaded["bytes"].decompress(Chunk.TOTAL_BLOCKS)
		for i: int in range(probes.size()):
			assert_eq(out[i], probes[i], "id %d round-trips through disk" % probes[i])


# Minimal world double: BlockFire, Blocks.on_entity_walking and the normal
# survival break path only need block/meta reads and writes plus a light
# sample. Building a real ChunkManager would drag in streaming, workers
# and a save path.
class _FakeWorld:
	extends Node3D

	var blocks: Dictionary = {}
	var meta: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func get_world_block_meta(pos: Vector3i) -> int:
		return int(meta.get(pos, 0))

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id
		meta[pos] = 0

	func set_world_block_with_meta(pos: Vector3i, id: int, m: int) -> void:
		blocks[pos] = id
		meta[pos] = m

	func get_world_effective_light(_pos: Vector3i) -> int:
		return 15


class _PrivateVelocityEntity:
	extends Node3D

	var _velocity: Vector3 = Vector3.ZERO


class _FakeBreakPlayer:
	extends Node3D

	var inventory := Inventory.new()


func _break_through_interaction(block_id: int, tool_id: int) -> Dictionary:
	var pos := Vector3i(3, 64, 5)
	var world := _FakeWorld.new()
	var player := _FakeBreakPlayer.new()
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	player.add_child(camera)
	add_child(world)
	add_child(player)
	var interaction: Node = _INTERACTION.new()
	interaction.process_mode = Node.PROCESS_MODE_DISABLED
	player.add_child(interaction)
	interaction.set("_chunk_manager", world)
	world.blocks[pos] = block_id
	if tool_id != Blocks.AIR:
		player.inventory.selected().item_id = tool_id
		player.inventory.selected().count = 1
	interaction.call("_complete_break", pos)
	var dropped_ids: Array[int] = []
	for child: Node in world.get_children():
		if child is DroppedItem:
			dropped_ids.append((child as DroppedItem).item_id)
	var result := {"block_after": world.get_world_block(pos), "drops": dropped_ids}
	player.free()
	world.free()
	return result
