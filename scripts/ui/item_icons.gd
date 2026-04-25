class_name ItemIcons
extends RefCounted

# Maps item IDs to a representative texture for the inventory UI. Block IDs
# pull from the active block-texture pack; non-block items (sticks, tools)
# fall through to a procedural solid-color placeholder until proper sprites
# are added.

const _BLOCK_ICON_NAMES: Dictionary = {
	Blocks.STONE: "stone",
	Blocks.COBBLESTONE: "cobblestone",
	Blocks.DIRT: "dirt",
	Blocks.GRASS: "grass_side",
	Blocks.LOG: "log_side",
	Blocks.PLANKS: "planks",
	Blocks.LEAVES: "leaves",
	Blocks.SAND: "sand",
	Blocks.GRAVEL: "gravel",
	Blocks.BEDROCK: "bedrock",
	Blocks.BRICK: "brick",
	Blocks.OBSIDIAN: "obsidian",
	Blocks.COAL_ORE: "coal_ore",
	Blocks.IRON_ORE: "iron_ore",
	Blocks.GOLD_ORE: "gold_ore",
	Blocks.DIAMOND_ORE: "diamond_ore",
	Blocks.CRAFTING_TABLE: "crafting_table_side",
	Blocks.FURNACE: "furnace_front",
	Blocks.GLASS: "glass",
	Blocks.SAPLING: "sapling",
	Blocks.TORCH: "torch",
}

# Item sprite basenames. Resolved at load time: first try
# `packs/{active_pack}/items/{basename}.png`, then fall back to the shared
# `assets/textures/items/{basename}.png` directory. This lets packs ship
# their own item art (like blocks) while allowing any item to use a
# pack-agnostic default.
const _ITEM_TEXTURE_NAMES: Dictionary = {
	Items.STICK: "stick",
	Items.WOODEN_PICKAXE: "wooden_pickaxe",
	Items.WOODEN_AXE: "wooden_axe",
	Items.WOODEN_SHOVEL: "wooden_shovel",
	Items.WOODEN_SWORD: "wooden_sword",
	Items.WOODEN_HOE: "wooden_hoe",
	Items.STONE_PICKAXE: "stone_pickaxe",
	Items.STONE_AXE: "stone_axe",
	Items.STONE_SHOVEL: "stone_shovel",
	Items.STONE_SWORD: "stone_sword",
	Items.IRON_PICKAXE: "iron_pickaxe",
	Items.IRON_AXE: "iron_axe",
	Items.IRON_SHOVEL: "iron_shovel",
	Items.IRON_SWORD: "iron_sword",
	Items.DIAMOND_PICKAXE: "diamond_pickaxe",
	Items.DIAMOND_AXE: "diamond_axe",
	Items.DIAMOND_SHOVEL: "diamond_shovel",
	Items.DIAMOND_SWORD: "diamond_sword",
	Items.GOLD_PICKAXE: "gold_pickaxe",
	Items.GOLD_AXE: "gold_axe",
	Items.GOLD_SHOVEL: "gold_shovel",
	Items.GOLD_SWORD: "gold_sword",
	Items.FLINT: "flint",
	Items.IRON_HELMET: "iron_helmet",
	Items.IRON_CHESTPLATE: "iron_chestplate",
	Items.IRON_LEGGINGS: "iron_leggings",
	Items.IRON_BOOTS: "iron_boots",
	Items.GOLD_HELMET: "gold_helmet",
	Items.GOLD_CHESTPLATE: "gold_chestplate",
	Items.GOLD_LEGGINGS: "gold_leggings",
	Items.GOLD_BOOTS: "gold_boots",
	Items.DIAMOND_HELMET: "diamond_helmet",
	Items.DIAMOND_CHESTPLATE: "diamond_chestplate",
	Items.DIAMOND_LEGGINGS: "diamond_leggings",
	Items.DIAMOND_BOOTS: "diamond_boots",
	Items.LEATHER: "leather",
	Items.CHARCOAL: "charcoal",
	Items.COAL: "coal",
	Items.IRON_INGOT: "iron_ingot",
	Items.GOLD_INGOT: "gold_ingot",
	Items.DIAMOND: "diamond",
	# Bone meal — extracted from vanilla Beta 1.4's gui/items.png (the
	# version that introduced the dye system). Sprite is unchanged in
	# every later version, so this is the canonical look.
	Items.BONEMEAL: "bonemeal",
	# Flint and steel — canonical Alpha 1.2.6 sprite at items.png (5,0),
	# extracted by scripts/dev/extract_alpha_pack.py into the alpha_vanilla
	# pack. Other packs fall through to the placeholder color until they
	# ship their own sprite.
	Items.FLINT_AND_STEEL: "flint_and_steel",
	# Buckets — placeholder colors picked up by the fallback-color path
	# below. Leave them OUT of this table so the icon renderer uses the
	# solid-color fallback; real sprites can be dropped in later.
}

# Placeholder colors for items that don't have real sprites yet. Renders
# as a solid square with a dark border (see _build_solid_icon).
const _ITEM_PLACEHOLDER_COLORS: Dictionary = {
	Items.BUCKET_EMPTY: Color(0.75, 0.75, 0.78),  # steel grey
	Items.BUCKET_WATER: Color(0.25, 0.45, 0.9),  # water blue
	Items.BUCKET_LAVA: Color(0.98, 0.63, 0.0),  # lava orange
}

static var _cache: Dictionary = {}


static func icon_for(item_id: int) -> Texture2D:
	# Buckets — canonical Alpha 1.2.6 sprites (gui/items.png tiles 74/75/76,
	# extracted directly from the vendor jar). Short-circuit above the
	# cache: a prior call before the bucket branch existed could cache
	# null here, and `_cache.has()` returns true on a null value — so
	# going through the cache would keep serving stale nulls forever.
	if item_id == Items.BUCKET_EMPTY:
		return _load_item_sprite("bucket")
	if item_id == Items.BUCKET_WATER:
		return _load_item_sprite("water_bucket")
	if item_id == Items.BUCKET_LAVA:
		return _load_item_sprite("lava_bucket")
	# Vanilla MC renders block icons as live 3D isometric cubes — we match
	# that via BlockIconRenderer's pre-baked viewport snapshots. Falls back
	# to the flat side-face PNG until baking finishes (briefly at startup),
	# then to a solid color square for non-block items.
	var baked: Texture2D = BlockIconRenderer.get_icon(item_id)
	if baked != null:
		return baked
	if _cache.has(item_id):
		return _cache[item_id]
	var tex: Texture2D = null
	if _BLOCK_ICON_NAMES.has(item_id):
		var path := (
			"%s%s/%s.png"
			% [BlockAtlas.PACK_BASE, BlockAtlas.active_pack, _BLOCK_ICON_NAMES[item_id]]
		)
		tex = load(path) as Texture2D
	elif _ITEM_TEXTURE_NAMES.has(item_id):
		tex = _load_item_sprite(_ITEM_TEXTURE_NAMES[item_id])
	elif _ITEM_PLACEHOLDER_COLORS.has(item_id):
		tex = _build_solid_icon(_ITEM_PLACEHOLDER_COLORS[item_id])
	# Last-ditch procedural fallbacks for items whose pixel-art sprite
	# isn't on disk yet. Keeps the debug spawner + inventory readable
	# during development; the asset file wins once dropped in place.
	if tex == null and item_id == Items.BONEMEAL:
		tex = _build_bonemeal_icon()
	# Buckets — explicit branch instead of going through
	# _ITEM_PLACEHOLDER_COLORS. The const-dict lookup turned up empty
	# in practice (either a class-load ordering quirk or a stale _cache
	# entry written before the dict was populated); an explicit branch
	# has no such dependency. Colors match the placeholder table.
	if tex == null and item_id == Items.BUCKET_EMPTY:
		tex = _build_bucket_icon(Color(0.78, 0.78, 0.80), Color(0, 0, 0, 0))
	if tex == null and item_id == Items.BUCKET_WATER:
		tex = _build_bucket_icon(Color(0.78, 0.78, 0.80), Color(0.25, 0.45, 0.9, 1.0))
	if tex == null and item_id == Items.BUCKET_LAVA:
		tex = _build_bucket_icon(Color(0.78, 0.78, 0.80), Color(0.98, 0.63, 0.0, 1.0))
	_cache[item_id] = tex
	return tex


static func clear_cache() -> void:
	_cache.clear()


# Resolves an item sprite to a Texture2D, preferring the active pack's
# `items/` subdirectory and falling back to the shared `assets/textures/items/`
# directory when the pack doesn't override.
static func _load_item_sprite(basename: String) -> Texture2D:
	var pack_path := "%s%s/items/%s.png" % [BlockAtlas.PACK_BASE, BlockAtlas.active_pack, basename]
	if ResourceLoader.exists(pack_path):
		return load(pack_path) as Texture2D
	return load("res://assets/textures/items/%s.png" % basename) as Texture2D


# Procedural 16×16 pile-of-powder sprite — visually matches vanilla's
# bone-meal dye icon well enough to be recognizable. Pile tapers from a
# 1-px top to a ~12-px base; cream body with right-edge shadow and a few
# lighter/darker specks for grain. Transparent background so the slot /
# cell styling shows through.
static func _build_bonemeal_icon() -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var body := Color(0.96, 0.93, 0.78, 1.0)
	var shadow := Color(0.74, 0.70, 0.52, 1.0)
	var highlight := Color(1.0, 0.99, 0.90, 1.0)
	# Per-row [xmin, xmax]; empty row = skip.
	var rows: Array = [
		[],
		[],
		[],
		[7, 8],
		[6, 9],
		[5, 10],
		[5, 11],
		[4, 11],
		[4, 12],
		[3, 12],
		[3, 13],
		[2, 13],
		[2, 14],
		[2, 14],
		[3, 13],
		[],
	]
	for y in range(rows.size()):
		var row: Array = rows[y]
		if row.is_empty():
			continue
		for x in range(int(row[0]), int(row[1]) + 1):
			img.set_pixel(x, y, body)
		# Shadow along the right edge + base for a bit of volume.
		img.set_pixel(int(row[1]), y, shadow)
	# Grain specks.
	img.set_pixel(6, 6, highlight)
	img.set_pixel(9, 9, highlight)
	img.set_pixel(4, 11, highlight)
	img.set_pixel(8, 8, shadow)
	img.set_pixel(5, 13, shadow)
	img.set_pixel(11, 12, shadow)
	return ImageTexture.create_from_image(img)


# Generates a 32x32 solid-color icon with a thin dark border. Cheap stand-in
# for non-block items until proper pixel art is added.
# 16×16 pixel-art bucket sprite. `metal` = pail color, `fluid` = contents
# (alpha=0 for an empty bucket). Rough silhouette: trapezoidal body
# narrowing to the bottom, a 1-px handle over the top, an inner lip so
# the inside shows a hint of fluid. Visually matches vanilla's bucket
# item better than a solid square and — critically — actually renders,
# which the const-dict fallback didn't.
static func _build_bucket_icon(metal: Color, fluid: Color) -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var shadow := Color(metal.r * 0.55, metal.g * 0.55, metal.b * 0.55, 1.0)
	# Handle: thin arc across the top of the bucket, y=2 row only.
	for x in range(5, 11):
		img.set_pixel(x, 2, shadow)
	img.set_pixel(4, 3, shadow)
	img.set_pixel(11, 3, shadow)
	# Body — outer walls (metal) and inner fill (fluid if set, else metal).
	# Rows 4..13 form the pail, tapering from x=[3..12] at top to x=[5..10] at bottom.
	var rows: Array = [
		[3, 12], [3, 12], [4, 11], [4, 11], [4, 11], [5, 10], [5, 10], [5, 10], [5, 10], [5, 10]
	]
	for i in range(rows.size()):
		var y: int = 4 + i
		var row: Array = rows[i]
		var xmin: int = int(row[0])
		var xmax: int = int(row[1])
		for x in range(xmin, xmax + 1):
			img.set_pixel(x, y, metal)
		# Right-edge shadow for a bit of volume.
		img.set_pixel(xmax, y, shadow)
	# Inner fluid — inset one pixel from the outer metal. Only if fluid alpha>0.
	if fluid.a > 0.0:
		var fluid_rows: Array = [
			[4, 11], [4, 11], [5, 10], [5, 10], [5, 10], [6, 9], [6, 9], [6, 9]
		]
		for i in range(fluid_rows.size()):
			var y: int = 4 + i
			var row: Array = fluid_rows[i]
			for x in range(int(row[0]), int(row[1]) + 1):
				img.set_pixel(x, y, fluid)
	return ImageTexture.create_from_image(img)


static func _build_solid_icon(color: Color) -> Texture2D:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(color)
	var border := Color(color.r * 0.4, color.g * 0.4, color.b * 0.4, 1.0)
	for x in range(32):
		img.set_pixel(x, 0, border)
		img.set_pixel(x, 31, border)
		img.set_pixel(0, x, border)
		img.set_pixel(31, x, border)
	return ImageTexture.create_from_image(img)
