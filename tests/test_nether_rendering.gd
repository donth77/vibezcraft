# gdlint: disable=max-public-methods
extends GutTest

# Presentation matrix for the Nether content
# (docs/nether-alpha-1.2.6-implementation-plan.md §9, Batch 2).
#
# The plan's acceptance bar is that a new block or item works in EVERY
# representation, not just the one you happened to look at: debug
# spawner, inventory icon, first- and third-person held, dropped entity,
# and placed in the world. Its stated failure mode — "an item works only
# after a console grant, appears as a placeholder in one view, or changes
# visual type when dropped" — is exactly what this file checks.
#
# The portal is the inverse case. Every one of those cells must be EMPTY
# for it, and it is the reason the engine stopped inferring content kind
# from the id.

const _SOLID_NETHER_BLOCKS: Array[int] = [Blocks.NETHERRACK, Blocks.SOUL_SAND, Blocks.GLOWSTONE]
const _DROPPED_ITEM := preload("res://scripts/world/dropped_item.gd")


func before_all() -> void:
	BlockAtlas.reset()


func after_all() -> void:
	BlockAtlas.reset()


# Mirror of player.gd::_update_held_item's routing decision. Kept in step
# with the real thing by test_the_held_routing_mirror_matches_the_source
# below, so this file cannot silently drift from production.
func _held_takes_sprite_path(id: int) -> bool:
	return (
		not Blocks.is_registered(id)
		or (Blocks.has_sprite_tile(id) and Blocks.mesh_shape(id) != Blocks.MESH_SHAPE_TORCH)
	)


func test_the_held_routing_mirror_matches_the_source() -> void:
	var script: GDScript = load("res://scripts/player/player.gd") as GDScript
	assert_not_null(script, "player.gd loads")
	if script == null:
		return
	var src: String = script.source_code
	assert_true(
		src.contains("not Blocks.is_registered(id)"),
		"held routing asks the registry, not an id range"
	)
	assert_false(src.contains("id >= Items.STICK"), "the old numeric held-item split is gone")


# --- Atlas / world rendering ---


func test_every_nether_block_has_an_atlas_tile() -> void:
	# A missing LAYOUT entry does not fail loudly: Blocks.get_face_texture
	# returns the right name and BlockAtlas.uv_rect falls through to
	# Rect2(0,0,0,0), which bakes grey-pixel-only UVs into the cube mesh
	# AND the inventory icon. That is the "placeholder in one view" the
	# plan forbids.
	for id: int in _SOLID_NETHER_BLOCKS:
		for face: String in ["top", "bottom", "side"]:
			var tile: String = Blocks.get_face_texture(id, face)
			assert_ne(tile, "", "%s has a %s tile name" % [Blocks.name_of(id), face])
			var rect: Rect2 = BlockAtlas.uv_rect(tile)
			assert_gt(rect.size.x, 0.0, "%s (%s) resolves to a real atlas slot" % [tile, face])


func test_the_portal_tile_is_registered_for_batch_seven() -> void:
	# Batch 7 owns the portal's mesh and animation, but its texture input
	# has to exist first.
	var tile: String = Blocks.get_face_texture(Blocks.PORTAL, "side")
	assert_eq(tile, "portal", "portal has a tile name")
	assert_gt(BlockAtlas.uv_rect(tile).size.x, 0.0, "and a real atlas slot")


func test_solid_nether_blocks_use_the_plain_cube_mesh() -> void:
	for id: int in _SOLID_NETHER_BLOCKS:
		assert_eq(
			Blocks.mesh_shape(id),
			Blocks.MESH_SHAPE_CUBE,
			"%s renders as a full cube" % Blocks.name_of(id)
		)
		assert_false(
			Blocks.needs_gdscript_mesher(id),
			"%s stays on the native cube fast path" % Blocks.name_of(id)
		)


# --- Inventory icon ---


func test_every_nether_block_and_the_dust_have_an_inventory_icon() -> void:
	for id: int in _SOLID_NETHER_BLOCKS:
		assert_not_null(ItemIcons.icon_for(id), "%s has an inventory icon" % Blocks.name_of(id))
	assert_not_null(ItemIcons.icon_for(Items.GLOWSTONE_DUST), "glowstone dust has an icon")


func test_the_blocks_take_the_baked_cube_icon_and_the_dust_takes_a_sprite() -> void:
	# "Changes visual type" is the failure the plan calls out: a block
	# must read as a 3D cube everywhere and an item as a flat sprite.
	for id: int in _SOLID_NETHER_BLOCKS:
		assert_false(
			_held_takes_sprite_path(id),
			"%s is a cube in the hand, not a billboard" % Blocks.name_of(id)
		)
	assert_true(_held_takes_sprite_path(Items.GLOWSTONE_DUST), "dust is a sprite in the hand")


# --- Held item (FP and TP share the routing) ---


func test_held_meshes_build_for_every_nether_block() -> void:
	for id: int in _SOLID_NETHER_BLOCKS:
		var mesh: Mesh = BlockMesh.get_cube_mesh(id, 0.3)
		assert_not_null(mesh, "%s builds a held cube" % Blocks.name_of(id))
		if mesh != null:
			assert_gt(mesh.get_surface_count(), 0, "%s held cube has geometry" % Blocks.name_of(id))


func test_the_dust_extrudes_a_held_sprite() -> void:
	var tex: Texture2D = ItemIcons.icon_for(Items.GLOWSTONE_DUST)
	assert_not_null(tex, "dust has a sprite to extrude")
	if tex == null:
		return
	var extruded: ArrayMesh = SpriteExtruder.build(tex)
	assert_not_null(extruded, "dust extrudes into a held mesh")
	if extruded != null:
		assert_gt(extruded.get_surface_count(), 0, "and that mesh has geometry")


# --- Dropped entity ---


func test_dropped_nether_blocks_render_as_cubes_and_the_dust_as_a_sprite() -> void:
	# DroppedItem picks its mesh with the same registry query the held
	# path uses; this asserts the two agree, so an item cannot change
	# appearance between the hand and the ground.
	for id: int in _SOLID_NETHER_BLOCKS:
		assert_true(Blocks.is_registered(id), "%s is a block" % Blocks.name_of(id))
		assert_false(Blocks.has_sprite_tile(id), "%s is not a sprite tile" % Blocks.name_of(id))
	assert_false(Blocks.is_registered(Items.GLOWSTONE_DUST), "dust takes the sprite branch")


func test_a_dropped_nether_block_spawns_with_a_mesh() -> void:
	for id: int in _SOLID_NETHER_BLOCKS:
		var item: Node3D = _DROPPED_ITEM.new()
		add_child_autofree(item)
		item.global_position = Vector3(0, 65, 0)
		item.setup(id)
		assert_eq(item.item_id, id, "%s dropped entity carries its id" % Blocks.name_of(id))
		assert_false(item._is_sprite_item, "%s drops as a cube" % Blocks.name_of(id))


func test_dropped_glowstone_dust_spawns_as_a_sprite() -> void:
	var item: Node3D = _DROPPED_ITEM.new()
	add_child_autofree(item)
	item.global_position = Vector3(0, 65, 0)
	item.setup(Items.GLOWSTONE_DUST)
	assert_true(item._is_sprite_item, "dust drops as a billboard sprite")


# --- Pickup / inventory ---


func test_every_nether_item_stacks_normally() -> void:
	for id: int in _SOLID_NETHER_BLOCKS:
		assert_eq(Items.max_stack_size(id), 64, "%s stacks to 64" % Blocks.name_of(id))
	assert_eq(Items.max_stack_size(Items.GLOWSTONE_DUST), 64, "dust stacks to 64")


func test_a_nether_stack_survives_the_inventory() -> void:
	var inv := Inventory.new()
	for id: int in _SOLID_NETHER_BLOCKS:
		assert_eq(inv.add_item(id, 32), 0, "%s fits in the inventory" % Blocks.name_of(id))
	assert_eq(inv.add_item(Items.GLOWSTONE_DUST, 64), 0, "a full dust stack fits")


# --- Portal exclusion ---


func test_the_portal_is_excluded_from_every_item_facing_path() -> void:
	assert_false(Blocks.has_item_form(Blocks.PORTAL), "no item form")
	assert_false(Items.is_registered(Blocks.PORTAL), "not an item")
	assert_eq(Items.display_name(Blocks.PORTAL), "", "no item display name")
	assert_eq(Blocks.drops(Blocks.PORTAL), Blocks.AIR, "no drop")
	assert_false(Blocks.is_solid_collision(Blocks.PORTAL), "no collision")
	assert_eq(Blocks.selection_aabb(Blocks.PORTAL).size, Vector3.ZERO, "no selection box")


func test_the_portal_cannot_be_placed_from_a_stack() -> void:
	# `_place_block_from_held` gates on is_inventory_placeable, so a
	# portal id that somehow reached a slot still cannot be placed.
	assert_false(Blocks.is_inventory_placeable(Blocks.PORTAL), "the placement guard rejects it")


func test_no_recipe_produces_a_portal() -> void:
	Recipes.ensure_loaded()
	var f := FileAccess.open("res://data/recipes.json", FileAccess.READ)
	assert_not_null(f, "recipe JSON loads")
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	assert_false(text.contains('"portal"'), "no recipe mentions the portal")
