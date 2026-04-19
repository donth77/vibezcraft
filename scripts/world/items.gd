class_name Items
extends RefCounted

# Non-block item IDs. Blocks own 0-99; non-block items start at 100. The same
# ID space is shared with Blocks because ItemStack.item_id is a single int —
# a "log" in the inventory carries Blocks.LOG (6), a "stick" carries 100.
# Append new IDs to the end. Never renumber — they're persisted on disk.

const STICK: int = 100
const WOODEN_PICKAXE: int = 101
const STONE_PICKAXE: int = 102
const IRON_PICKAXE: int = 103
const DIAMOND_PICKAXE: int = 104
const WOODEN_SHOVEL: int = 105
const WOODEN_AXE: int = 106
const COAL: int = 120
const IRON_INGOT: int = 121
const GOLD_INGOT: int = 122
const DIAMOND: int = 123

# Tool taxonomy. Vanilla MC EnumToolMaterial constants (Bukkit/mc-dev):
#   wood:    speed 2.0, durability 59,    harvest level 0
#   stone:   speed 4.0, durability 131,   harvest level 1
#   iron:    speed 6.0, durability 250,   harvest level 2
#   diamond: speed 8.0, durability 1561,  harvest level 3
#   gold:    speed 12.0, durability 32,   harvest level 0
const TOOL_TYPE_PICKAXE: int = 1
const TOOL_TYPE_AXE: int = 2
const TOOL_TYPE_SHOVEL: int = 3
const TOOL_TYPE_SWORD: int = 4

# [tool_type, material_speed, harvest_level, durability]. Used by Blocks
# to compute break time + drop gating.
const _TOOL_DATA: Dictionary = {
	WOODEN_PICKAXE: [TOOL_TYPE_PICKAXE, 2.0, 0, 59],
	WOODEN_AXE: [TOOL_TYPE_AXE, 2.0, 0, 59],
	WOODEN_SHOVEL: [TOOL_TYPE_SHOVEL, 2.0, 0, 59],
	STONE_PICKAXE: [TOOL_TYPE_PICKAXE, 4.0, 1, 131],
	IRON_PICKAXE: [TOOL_TYPE_PICKAXE, 6.0, 2, 250],
	DIAMOND_PICKAXE: [TOOL_TYPE_PICKAXE, 8.0, 3, 1561],
}


# Unified name → id lookup. Covers BOTH non-block items and blocks so recipe
# JSON can reference any input/output by string key. Returns -1 for unknowns.
static func id_from_name(item_name: String) -> int:
	match item_name:
		"stick":
			return STICK
		"wooden_pickaxe":
			return WOODEN_PICKAXE
		"stone_pickaxe":
			return STONE_PICKAXE
		"iron_pickaxe":
			return IRON_PICKAXE
		"diamond_pickaxe":
			return DIAMOND_PICKAXE
		"wooden_shovel":
			return WOODEN_SHOVEL
		"wooden_axe":
			return WOODEN_AXE
		"coal":
			return COAL
		"iron_ingot":
			return IRON_INGOT
		"gold_ingot":
			return GOLD_INGOT
		"diamond":
			return DIAMOND
		"air":
			return Blocks.AIR
		"bedrock":
			return Blocks.BEDROCK
		"stone":
			return Blocks.STONE
		"dirt":
			return Blocks.DIRT
		"grass":
			return Blocks.GRASS
		"cobblestone":
			return Blocks.COBBLESTONE
		"log":
			return Blocks.LOG
		"planks":
			return Blocks.PLANKS
		"leaves":
			return Blocks.LEAVES
		"sand":
			return Blocks.SAND
		"brick":
			return Blocks.BRICK
		"obsidian":
			return Blocks.OBSIDIAN
		"coal_ore":
			return Blocks.COAL_ORE
		"iron_ore":
			return Blocks.IRON_ORE
		"gold_ore":
			return Blocks.GOLD_ORE
		"diamond_ore":
			return Blocks.DIAMOND_ORE
		"crafting_table":
			return Blocks.CRAFTING_TABLE
	return -1


# Human-readable display name for tooltips. Covers BOTH non-block items and
# blocks. Returns "" for AIR / unknown.
static func display_name(item_id: int) -> String:
	match item_id:
		STICK:
			return "Stick"
		WOODEN_PICKAXE:
			return "Wooden Pickaxe"
		STONE_PICKAXE:
			return "Stone Pickaxe"
		IRON_PICKAXE:
			return "Iron Pickaxe"
		DIAMOND_PICKAXE:
			return "Diamond Pickaxe"
		WOODEN_SHOVEL:
			return "Wooden Shovel"
		WOODEN_AXE:
			return "Wooden Axe"
		COAL:
			return "Coal"
		IRON_INGOT:
			return "Iron Ingot"
		GOLD_INGOT:
			return "Gold Ingot"
		DIAMOND:
			return "Diamond"
		Blocks.AIR:
			return ""
		Blocks.BEDROCK:
			return "Bedrock"
		Blocks.STONE:
			return "Stone"
		Blocks.DIRT:
			return "Dirt"
		Blocks.GRASS:
			return "Grass Block"
		Blocks.COBBLESTONE:
			return "Cobblestone"
		Blocks.LOG:
			return "Wood"
		Blocks.PLANKS:
			return "Wooden Planks"
		Blocks.LEAVES:
			return "Leaves"
		Blocks.SAND:
			return "Sand"
		Blocks.BRICK:
			return "Bricks"
		Blocks.OBSIDIAN:
			return "Obsidian"
		Blocks.COAL_ORE:
			return "Coal Ore"
		Blocks.IRON_ORE:
			return "Iron Ore"
		Blocks.GOLD_ORE:
			return "Gold Ore"
		Blocks.DIAMOND_ORE:
			return "Diamond Ore"
		Blocks.CRAFTING_TABLE:
			return "Crafting Table"
	return ""


# --- Tool helpers ---


# NOTE: do NOT name this `is_tool` — that collides with GDScript.is_tool()
# (built-in 0-arg method that returns whether the script has @tool), and
# Godot resolves Items.is_tool(id) to the built-in instead of our static.
static func is_tool_item(item_id: int) -> bool:
	return _TOOL_DATA.has(item_id)


static func tool_type(item_id: int) -> int:
	if not _TOOL_DATA.has(item_id):
		return 0
	return _TOOL_DATA[item_id][0]


static func tool_speed(item_id: int) -> float:
	if not _TOOL_DATA.has(item_id):
		return 1.0
	return _TOOL_DATA[item_id][1]


static func tool_harvest_level(item_id: int) -> int:
	if not _TOOL_DATA.has(item_id):
		return 0
	return _TOOL_DATA[item_id][2]


static func tool_durability(item_id: int) -> int:
	if not _TOOL_DATA.has(item_id):
		return 0
	return _TOOL_DATA[item_id][3]
