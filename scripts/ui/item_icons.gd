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
	Blocks.BEDROCK: "bedrock",
	Blocks.COAL_ORE: "coal_ore",
	Blocks.IRON_ORE: "iron_ore",
	Blocks.GOLD_ORE: "gold_ore",
	Blocks.DIAMOND_ORE: "diamond_ore",
	Blocks.CRAFTING_TABLE: "crafting_table_side",
	Blocks.GLASS: "glass",
	Blocks.SAPLING: "sapling",
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
}

# Placeholder colors for items that don't have real sprites yet.
const _ITEM_PLACEHOLDER_COLORS: Dictionary = {}

static var _cache: Dictionary = {}


static func icon_for(item_id: int) -> Texture2D:
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


# Generates a 32x32 solid-color icon with a thin dark border. Cheap stand-in
# for non-block items until proper pixel art is added.
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
