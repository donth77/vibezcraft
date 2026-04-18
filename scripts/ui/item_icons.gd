class_name ItemIcons
extends RefCounted

# Maps block IDs to a "representative" texture for the inventory UI.
# Uses raw 32x32 PNGs directly (no atlas math needed for UI).

const _ICON_NAMES: Dictionary = {
	Blocks.STONE: "stone",
	Blocks.COBBLESTONE: "cobblestone",
	Blocks.DIRT: "dirt",
	Blocks.GRASS: "grass_side",
	Blocks.LOG: "log_side",
	Blocks.PLANKS: "planks",
	Blocks.LEAVES: "leaves",
	Blocks.SAND: "sand",
	Blocks.BEDROCK: "bedrock",
}

static var _cache: Dictionary = {}


static func icon_for(item_id: int) -> Texture2D:
	if _cache.has(item_id):
		return _cache[item_id]
	if not _ICON_NAMES.has(item_id):
		return null
	var path := "%s%s/%s.png" % [BlockAtlas.PACK_BASE, BlockAtlas.active_pack, _ICON_NAMES[item_id]]
	var tex: Texture2D = load(path) as Texture2D
	_cache[item_id] = tex
	return tex


static func clear_cache() -> void:
	_cache.clear()
