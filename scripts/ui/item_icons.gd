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
}

# Real 16×16 item sprites (sourced from InventivetalentDev/minecraft-assets,
# Alpha-faithful art). Keyed by Items.* IDs. Items not in this map fall
# through to the colored-square placeholder below.
const _ITEM_TEXTURE_PATHS: Dictionary = {
	Items.STICK: "res://assets/textures/items/stick.png",
	Items.WOODEN_PICKAXE: "res://assets/textures/items/wooden_pickaxe.png",
}

# Placeholder colors for items that don't have real sprites yet.
const _ITEM_PLACEHOLDER_COLORS: Dictionary = {
	Items.STONE_PICKAXE: Color(0.55, 0.55, 0.55),
	Items.IRON_PICKAXE: Color(0.85, 0.85, 0.85),
	Items.DIAMOND_PICKAXE: Color(0.30, 0.85, 0.85),
	Items.WOODEN_SHOVEL: Color(0.70, 0.55, 0.30),
	Items.WOODEN_AXE: Color(0.60, 0.45, 0.20),
	Items.COAL: Color(0.10, 0.10, 0.10),
	Items.IRON_INGOT: Color(0.92, 0.86, 0.78),
	Items.GOLD_INGOT: Color(0.95, 0.85, 0.30),
	Items.DIAMOND: Color(0.30, 0.95, 0.95),
}

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
	elif _ITEM_TEXTURE_PATHS.has(item_id):
		tex = load(_ITEM_TEXTURE_PATHS[item_id]) as Texture2D
	elif _ITEM_PLACEHOLDER_COLORS.has(item_id):
		tex = _build_solid_icon(_ITEM_PLACEHOLDER_COLORS[item_id])
	_cache[item_id] = tex
	return tex


static func clear_cache() -> void:
	_cache.clear()


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
