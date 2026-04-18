class_name ItemIcons
extends RefCounted

# Maps block IDs to a "representative" texture for the inventory UI.
# Uses raw 32x32 PNGs directly (no atlas math needed for UI).

const _ICON_PATHS: Dictionary = {
	Blocks.STONE: "res://assets/textures/blocks/raw/stone.png",
	Blocks.COBBLESTONE: "res://assets/textures/blocks/raw/cobblestone.png",
	Blocks.DIRT: "res://assets/textures/blocks/raw/dirt.png",
	Blocks.GRASS: "res://assets/textures/blocks/raw/grass_side.png",
	Blocks.LOG: "res://assets/textures/blocks/raw/log_side.png",
	Blocks.PLANKS: "res://assets/textures/blocks/raw/planks.png",
	Blocks.LEAVES: "res://assets/textures/blocks/raw/leaves.png",
	Blocks.SAND: "res://assets/textures/blocks/raw/sand.png",
	Blocks.BEDROCK: "res://assets/textures/blocks/raw/bedrock.png",
}

static var _cache: Dictionary = {}


static func icon_for(item_id: int) -> Texture2D:
	if _cache.has(item_id):
		return _cache[item_id]
	if not _ICON_PATHS.has(item_id):
		return null
	var tex: Texture2D = load(_ICON_PATHS[item_id]) as Texture2D
	_cache[item_id] = tex
	return tex
