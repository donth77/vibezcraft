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
const WOODEN_SWORD: int = 107
# WOODEN_HOE: Beta 1.6 addition. Recipe is parked in recipes.json's
# "_disabled" array so normal players can't craft one; the rest of the
# path (tool data, sprite, till logic, farmland block, block icon) stays
# active so debug-mode (J) testing still exercises end-to-end behavior.
const WOODEN_HOE: int = 108
const STONE_AXE: int = 109
const STONE_SHOVEL: int = 110
const STONE_SWORD: int = 111
const IRON_AXE: int = 112
const IRON_SHOVEL: int = 113
const IRON_SWORD: int = 114
const DIAMOND_AXE: int = 115
const DIAMOND_SHOVEL: int = 116
const DIAMOND_SWORD: int = 117
# Gold tier — speed 12.0 (fastest of any material!) but durability 32
# (lowest) and harvest level 0 (can't drop iron/gold/diamond ore).
# Mostly a fun tier in vanilla.
const GOLD_PICKAXE: int = 118
const GOLD_AXE: int = 119
const COAL: int = 120
const IRON_INGOT: int = 121
const GOLD_INGOT: int = 122
const DIAMOND: int = 123
# Charcoal — smelt log → charcoal. Stacks separately from coal in vanilla
# but functions identically as a fuel. Same burn time (1600 ticks).
const CHARCOAL: int = 125
# Gold tier (continued) — shovel + sword squeezed in here since 118/119
# already have pickaxe + axe and 120-125 were taken before tools were
# fully fleshed out.
const GOLD_SHOVEL: int = 126
const GOLD_SWORD: int = 127
# Flint — gravel drops it 1/10 of the time per BlockGravel.dropNaturally.
# Used to craft flint and steel; for now a standalone item.
const FLINT: int = 128
# Leather — defined now so leather-armor recipes can reference it. No
# source yet (cows haven't shipped); you can debug-grant via console once
# inventory APIs land for ad-hoc spawns.
const LEATHER: int = 124
# Bone meal — vanilla `ItemDye` (subtype 15). Right-click on a sapling
# fast-tracks it into a tree (BlockSapling.grow). Pre-Beta-1.8 vanilla
# only sources bone meal from skeleton bone drops, ground in the craft
# grid → 3× bone meal. Skeletons aren't shipped yet, so for now this is
# debug-only (J in tool_tuner). The right-click handler is fully wired so
# the moment skeletons + bones land, the recipe in data/recipes.json can
# enable and the path becomes naturally reachable.
const BONEMEAL: int = 129

# Armor — iron, gold, diamond × {helmet, chestplate, leggings, boots}.
# Slot routing (head/chest/legs/feet) is derived from the id via the
# helpers at the bottom of this file. Stored per-tier in contiguous
# ranges so iteration is cheap.
const IRON_HELMET: int = 130
const IRON_CHESTPLATE: int = 131
const IRON_LEGGINGS: int = 132
const IRON_BOOTS: int = 133
const GOLD_HELMET: int = 134
const GOLD_CHESTPLATE: int = 135
const GOLD_LEGGINGS: int = 136
const GOLD_BOOTS: int = 137
const DIAMOND_HELMET: int = 138
const DIAMOND_CHESTPLATE: int = 139
const DIAMOND_LEGGINGS: int = 140
const DIAMOND_BOOTS: int = 141
# Vanilla Alpha ItemBucket (ds.java) — one class, three in-game forms
# toggled by ItemBucket.itemID stored per-stack. We use three separate
# ids instead for simplicity; the interaction code in interaction.gd
# swaps item ids on use (empty + water source → water bucket, etc.).
# Alpha buckets don't stack (stack size = 1) — handled in max_stack_size
# via `is_tool_item` once we mark these; until then, vanilla bucket is a
# non-tool item that stacks, which is WRONG but harmless for testing.
const BUCKET_EMPTY: int = 142
const BUCKET_WATER: int = 143
const BUCKET_LAVA: int = 144
# Vanilla Alpha ItemFlintAndSteel — extends Item directly (not ItemTool),
# stack=1, durability=64 (65 uses including the final-break consumption).
# Right-click on a face places FIRE in the air cell on that face's normal
# side, costs 1 durability per ignition. Vanilla recipe: iron_ingot in
# top-left, flint in bottom-right of a 2×2 grid. See data/recipes.json.
const FLINT_AND_STEEL: int = 145
# Vanilla Alpha door items (eu.java). maxStackSize=1 (eu.java:aX=1),
# right-click-place on a top-face spawns a two-block-tall door oriented
# by player yaw. Wood door opens/closes on RMB; iron requires redstone.
const WOODEN_DOOR: int = 146
const IRON_DOOR: int = 147
# Vanilla Alpha gunpowder (`ItemGunpowder` doesn't exist as a class — it's a
# bare `Item` registered as nq.aV at id 289). Drops from creepers (1×) on
# death; the only other source is debug spawning until creepers ship. Used
# in the TNT recipe (4 sand + 5 gunpowder in a 3×3 checkerboard).
const GUNPOWDER: int = 148
# Sugar cane item — drops from breaking the SUGAR_CANE block. Held in
# hand as a green stick. Vanilla introduced as "reeds" in Alpha v1.0.4.
# We just carry it as a placeable plant for now (no sugar/paper crafting).
const SUGAR_CANE: int = 149
# Compass — Alpha 1.2.6 ItemCompass (id 345 vanilla → 150 here). Stack of 64.
# Custom icon: needle rotates per frame, pointing at world spawn coord
# (atan2(spawn.z - player.z, spawn.x - player.x) in icon space). Vanilla
# recipe is 4 iron ingots + 1 redstone in a + pattern; we ship the item
# without a recipe until redstone lands and supply via debug spawner.
const COMPASS: int = 150
# Clock — Alpha 1.2.6 ItemClock (id 347 vanilla → 151 here). Stack of 64.
# Dial angle = WorldTime.tick / 24000 * TAU so it sweeps a full rotation
# over each in-game day. Vanilla recipe: 4 gold ingots + 1 redstone;
# again, recipe deferred until redstone lands.
const CLOCK: int = 151
# Redstone dust — Alpha 1.2.6 ItemRedstone (id 331 vanilla → 152 here).
# Drops from breaking redstone ore (Beta added that block; for now supply
# via debug spawner). Used as the catalyst in compass + clock recipes;
# the power-system semantics (signal propagation, repeaters, etc.) come
# in a later phase — for now this is just a craft ingredient item.
const REDSTONE: int = 152

# --- Indev/Alpha food + materials (vanilla item IDs 256-350). Sprite
# positions verified against dx.java item registrations. No eating /
# hunger system yet (Alpha used direct HP healing; Beta 1.8 added
# hunger) — for now food items are inventory-only.

# Apple — vanilla 260 (dx.h). 4 HP heal on eat. Crafting input for
# golden_apple. No natural source in Alpha (leaves don't drop apples
# until Beta 1.5); debug-spawn only.
const APPLE: int = 153
# Bread — vanilla 297 (dx.S). 5 HP heal. Recipe: 3 wheat horizontal.
const BREAD: int = 154
# Wheat — vanilla 296 (dx.R). Harvested from mature crops. Phase B
# adds the crops block + farming mechanic; for now debug-spawn only.
# Recipe input for bread.
const WHEAT: int = 155
# Wheat seeds — vanilla 295 (dx.Q). Drops from breaking tall grass
# (also Phase B). Planted on tilled farmland with right-click.
const WHEAT_SEEDS: int = 156
# String — vanilla 287 (dx.I). Spider drop in vanilla; debug-spawn
# until mobs ship. Recipe input for fishing rod, bow, wool.
const STRING: int = 157
# Feather — vanilla 288 (dx.J). Chicken drop; debug-spawn until mobs
# ship. Recipe input for arrows.
const FEATHER: int = 158
# Paper — vanilla 339 (dx.aI). Recipe: 3 sugar_cane horizontal.
const PAPER: int = 159
# Book — vanilla 340 (dx.aJ). Recipe: 3 paper stacked vertically.
# Used in vanilla bookshelf recipe (3 books + 6 planks).
const BOOK: int = 160
# Brick (item) — vanilla 336 (dx.aF). Smelted from clay ball (Phase C
# adds clay block + worldgen). 4 → 1 brick block via 2×2 craft.
const BRICK: int = 161
# Saddle — vanilla 329 (dx.ay). No recipe in vanilla — chest loot only
# (Alpha dungeons). aY=1 stack-size. Right-click on pig to mount in
# vanilla; mounting system is post-mob work.
const SADDLE: int = 162
# Bowl — vanilla 281 (dx.C). Recipe: 3 planks in a V shape. Used to
# craft mushroom stew. Empty bowl returned when stew is eaten in
# vanilla (no eating yet).
const BOWL: int = 163
# Mushroom stew — vanilla 282 (dx.D). 5 HP heal (Alpha). Recipe:
# 1 red mushroom + 1 brown mushroom + 1 bowl shapeless. stack=1.
const MUSHROOM_STEW: int = 164
# Leather armor — vanilla 298-301 (dx.T-W). Lowest defense tier
# (helmet=1, chest=3, legs=2, boots=1, total=7 vs iron 15 / diamond 20).
# Recipe: leather in standard armor pattern.
const LEATHER_HELMET: int = 165
const LEATHER_CHESTPLATE: int = 166
const LEATHER_LEGGINGS: int = 167
const LEATHER_BOOTS: int = 168
# Porkchop — raw vanilla 319 (dx.ao, 3 HP), cooked vanilla 320 (dx.ap,
# 8 HP). Pig drop in vanilla. Smelt raw → cooked. Debug-spawn until
# mobs ship.
const RAW_PORKCHOP: int = 169
const COOKED_PORKCHOP: int = 170
# Golden apple — vanilla 322 (dx.ar, 42 HP). Recipe: 8 gold_ingots
# surrounding 1 apple (Alpha/early-Beta — pre-nerf to 8-block recipe
# in Beta 1.9). Debug-craftable once apple is available.
const GOLDEN_APPLE: int = 171
# Fishing — Alpha v1.0.16 (raw/cooked fish) + v1.0.17 (fishing rod).
# Fishing rod has durability 65 (aY=64+1) and aX=1 (stack). Recipe:
# 3 sticks diagonal + 2 string vertical. Cast/reel/bobber mechanic
# is a follow-up commit; for now items are debug-spawnable.
const FISHING_ROD: int = 172
# Raw fish — vanilla 349 (dx.aS, 2 HP). Caught with fishing rod.
const RAW_FISH: int = 173
# Cooked fish — vanilla 350 (dx.aT, 5 HP). Smelt raw_fish → cooked_fish.
const COOKED_FISH: int = 174
# Egg — vanilla 344 (dx.aN). Chicken drop in vanilla. Used in cake
# recipe + throwable entity (Alpha v1.0.14). Both deferred until
# chickens / cake ship — for now debug-spawn only.
const EGG: int = 175
# Milk bucket — vanilla 335 (dx.aE). Right-click cow with empty bucket.
# Drinking returns empty bucket + clears status effects (no effects
# system in Alpha). Used in cake recipe.
const MILK_BUCKET: int = 176
# Sugar — vanilla 353. [BETA 1.2 exception] — added with cake. Recipe:
# 1 sugar_cane → 1 sugar (shapeless). Used in cake. We ship this
# pre-cake so the chain is ready once cake mechanic lands.
const SUGAR: int = 177

# Armor-slot kinds — align with the 4 armor slots in Inventory (slots
# 36..39 in the flat array). Zero is "not armor".
const ARMOR_SLOT_NONE: int = 0
const ARMOR_SLOT_HEAD: int = 1
const ARMOR_SLOT_CHEST: int = 2
const ARMOR_SLOT_LEGS: int = 3
const ARMOR_SLOT_FEET: int = 4

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
const TOOL_TYPE_HOE: int = 5  # Beta-era; see WOODEN_HOE note above
# Flint-and-steel doesn't really fit any of the dig-tool taxonomies (it's
# not for breaking blocks, just for igniting fire). Carved out as its own
# type so the break-time / harvest-level paths can ignore it cleanly,
# while still routing through `_TOOL_DATA` for stack=1 + durability.
const TOOL_TYPE_FLINT_AND_STEEL: int = 6
# Fishing rod — bj.java in Alpha 1.2.6 (vanilla 346). Right-click casts,
# right-click while bobber-out reels. Cast mechanic is a follow-up.
const TOOL_TYPE_FISHING_ROD: int = 7

# Vanilla armor defense points (Bukkit/mc-dev `EnumArmorMaterial`).
# Full-set totals: gold 11, iron 15, diamond 20. Damage reduction
# formula (EntityLiving.damageArmor): final = damage × (25 -
# total_defense) / 25. So full diamond passes through 20% of damage.
# Hook site: whatever damage-event system lands later calls this per
# equipped slot and applies the formula; no current caller.
const _ARMOR_DEFENSE: Dictionary = {
	# Leather — lowest tier; full set total = 7.
	LEATHER_HELMET: 1,
	LEATHER_CHESTPLATE: 3,
	LEATHER_LEGGINGS: 2,
	LEATHER_BOOTS: 1,
	IRON_HELMET: 2,
	IRON_CHESTPLATE: 6,
	IRON_LEGGINGS: 5,
	IRON_BOOTS: 2,
	GOLD_HELMET: 2,
	GOLD_CHESTPLATE: 5,
	GOLD_LEGGINGS: 3,
	GOLD_BOOTS: 1,
	DIAMOND_HELMET: 3,
	DIAMOND_CHESTPLATE: 8,
	DIAMOND_LEGGINGS: 6,
	DIAMOND_BOOTS: 3,
}

# [tool_type, material_speed, harvest_level, durability]. Used by Blocks
# to compute break time + drop gating.
const _TOOL_DATA: Dictionary = {
	WOODEN_PICKAXE: [TOOL_TYPE_PICKAXE, 2.0, 0, 59],
	WOODEN_AXE: [TOOL_TYPE_AXE, 2.0, 0, 59],
	WOODEN_SHOVEL: [TOOL_TYPE_SHOVEL, 2.0, 0, 59],
	WOODEN_SWORD: [TOOL_TYPE_SWORD, 2.0, 0, 59],
	# Hoe — Beta-era; tool data kept for if/when we re-enable.
	WOODEN_HOE: [TOOL_TYPE_HOE, 1.0, 0, 59],
	STONE_PICKAXE: [TOOL_TYPE_PICKAXE, 4.0, 1, 131],
	STONE_AXE: [TOOL_TYPE_AXE, 4.0, 1, 131],
	STONE_SHOVEL: [TOOL_TYPE_SHOVEL, 4.0, 1, 131],
	STONE_SWORD: [TOOL_TYPE_SWORD, 4.0, 1, 131],
	IRON_PICKAXE: [TOOL_TYPE_PICKAXE, 6.0, 2, 250],
	IRON_AXE: [TOOL_TYPE_AXE, 6.0, 2, 250],
	IRON_SHOVEL: [TOOL_TYPE_SHOVEL, 6.0, 2, 250],
	IRON_SWORD: [TOOL_TYPE_SWORD, 6.0, 2, 250],
	DIAMOND_PICKAXE: [TOOL_TYPE_PICKAXE, 8.0, 3, 1561],
	DIAMOND_AXE: [TOOL_TYPE_AXE, 8.0, 3, 1561],
	DIAMOND_SHOVEL: [TOOL_TYPE_SHOVEL, 8.0, 3, 1561],
	DIAMOND_SWORD: [TOOL_TYPE_SWORD, 8.0, 3, 1561],
	GOLD_PICKAXE: [TOOL_TYPE_PICKAXE, 12.0, 0, 32],
	GOLD_AXE: [TOOL_TYPE_AXE, 12.0, 0, 32],
	GOLD_SHOVEL: [TOOL_TYPE_SHOVEL, 12.0, 0, 32],
	GOLD_SWORD: [TOOL_TYPE_SWORD, 12.0, 0, 32],
	# Vanilla nv.java sets aY=64 (durability) + aX=1 (stack=1). speed/
	# harvest_level are unused for flint-and-steel since it's not a dig
	# tool — we pass 1.0/0 as benign defaults.
	FLINT_AND_STEEL: [TOOL_TYPE_FLINT_AND_STEEL, 1.0, 0, 64],
	# Vanilla bj.java aY=64 — fishing rod loses durability on each
	# successful reel-in (not on cast).
	FISHING_ROD: [TOOL_TYPE_FISHING_ROD, 1.0, 0, 64],
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
		"stone_axe":
			return STONE_AXE
		"stone_shovel":
			return STONE_SHOVEL
		"stone_sword":
			return STONE_SWORD
		"iron_axe":
			return IRON_AXE
		"iron_shovel":
			return IRON_SHOVEL
		"iron_sword":
			return IRON_SWORD
		"diamond_axe":
			return DIAMOND_AXE
		"diamond_shovel":
			return DIAMOND_SHOVEL
		"diamond_sword":
			return DIAMOND_SWORD
		"gold_pickaxe":
			return GOLD_PICKAXE
		"gold_axe":
			return GOLD_AXE
		"gold_shovel":
			return GOLD_SHOVEL
		"gold_sword":
			return GOLD_SWORD
		"flint":
			return FLINT
		"sapling":
			return Blocks.SAPLING
		"torch":
			return Blocks.TORCH
		"iron_pickaxe":
			return IRON_PICKAXE
		"diamond_pickaxe":
			return DIAMOND_PICKAXE
		"wooden_shovel":
			return WOODEN_SHOVEL
		"wooden_axe":
			return WOODEN_AXE
		"wooden_sword":
			return WOODEN_SWORD
		"wooden_hoe":
			return WOODEN_HOE
		"coal":
			return COAL
		"iron_ingot":
			return IRON_INGOT
		"gold_ingot":
			return GOLD_INGOT
		"diamond":
			return DIAMOND
		"charcoal":
			return CHARCOAL
		"leather":
			return LEATHER
		"bonemeal":
			return BONEMEAL
		"iron_helmet":
			return IRON_HELMET
		"iron_chestplate":
			return IRON_CHESTPLATE
		"iron_leggings":
			return IRON_LEGGINGS
		"iron_boots":
			return IRON_BOOTS
		"gold_helmet":
			return GOLD_HELMET
		"gold_chestplate":
			return GOLD_CHESTPLATE
		"gold_leggings":
			return GOLD_LEGGINGS
		"gold_boots":
			return GOLD_BOOTS
		"diamond_helmet":
			return DIAMOND_HELMET
		"diamond_chestplate":
			return DIAMOND_CHESTPLATE
		"diamond_leggings":
			return DIAMOND_LEGGINGS
		"diamond_boots":
			return DIAMOND_BOOTS
		"bucket":
			return BUCKET_EMPTY
		"water_bucket":
			return BUCKET_WATER
		"lava_bucket":
			return BUCKET_LAVA
		"flint_and_steel":
			return FLINT_AND_STEEL
		"wooden_door":
			return WOODEN_DOOR
		"iron_door":
			return IRON_DOOR
		"gunpowder":
			return GUNPOWDER
		"compass":
			return COMPASS
		"clock":
			return CLOCK
		"redstone":
			return REDSTONE
		"tnt":
			return Blocks.TNT
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
		"furnace":
			return Blocks.FURNACE
		"lit_furnace":
			return Blocks.LIT_FURNACE
		"glass":
			return Blocks.GLASS
		"farmland":
			return Blocks.FARMLAND
		"gravel":
			return Blocks.GRAVEL
		"chest":
			return Blocks.CHEST
		"fence":
			return Blocks.FENCE
		"wood_stairs":
			return Blocks.WOOD_STAIRS
		"cobblestone_stairs":
			return Blocks.COBBLESTONE_STAIRS
		"ladder":
			return Blocks.LADDER
		"pumpkin":
			return Blocks.PUMPKIN
		"jack_o_lantern":
			return Blocks.JACK_O_LANTERN
		"bookshelf":
			return Blocks.BOOKSHELF
		"crops":
			return Blocks.CROPS
		"wool_white":
			return Blocks.WOOL_WHITE
		"wool_orange":
			return Blocks.WOOL_ORANGE
		"wool_magenta":
			return Blocks.WOOL_MAGENTA
		"wool_light_blue":
			return Blocks.WOOL_LIGHT_BLUE
		"wool_yellow":
			return Blocks.WOOL_YELLOW
		"wool_lime":
			return Blocks.WOOL_LIME
		"wool_pink":
			return Blocks.WOOL_PINK
		"wool_gray":
			return Blocks.WOOL_GRAY
		"wool_light_gray":
			return Blocks.WOOL_LIGHT_GRAY
		"wool_cyan":
			return Blocks.WOOL_CYAN
		"wool_purple":
			return Blocks.WOOL_PURPLE
		"wool_blue":
			return Blocks.WOOL_BLUE
		"wool_brown":
			return Blocks.WOOL_BROWN
		"wool_green":
			return Blocks.WOOL_GREEN
		"wool_red":
			return Blocks.WOOL_RED
		"wool_black":
			return Blocks.WOOL_BLACK
		"sponge":
			return Blocks.SPONGE
		"iron_block":
			return Blocks.IRON_BLOCK
		"gold_block":
			return Blocks.GOLD_BLOCK
		"diamond_block":
			return Blocks.DIAMOND_BLOCK
		"flower_red":
			return Blocks.FLOWER_RED
		"flower_yellow":
			return Blocks.FLOWER_YELLOW
		"mushroom_red":
			return Blocks.MUSHROOM_RED
		"mushroom_brown":
			return Blocks.MUSHROOM_BROWN
		"sugar_cane":
			return SUGAR_CANE
		"apple":
			return APPLE
		"bread":
			return BREAD
		"wheat":
			return WHEAT
		"wheat_seeds":
			return WHEAT_SEEDS
		"string":
			return STRING
		"feather":
			return FEATHER
		"paper":
			return PAPER
		"book":
			return BOOK
		"brick_item":
			return BRICK
		"saddle":
			return SADDLE
		"bowl":
			return BOWL
		"mushroom_stew":
			return MUSHROOM_STEW
		"leather_helmet":
			return LEATHER_HELMET
		"leather_chestplate":
			return LEATHER_CHESTPLATE
		"leather_leggings":
			return LEATHER_LEGGINGS
		"leather_boots":
			return LEATHER_BOOTS
		"raw_porkchop":
			return RAW_PORKCHOP
		"cooked_porkchop":
			return COOKED_PORKCHOP
		"golden_apple":
			return GOLDEN_APPLE
		"fishing_rod":
			return FISHING_ROD
		"raw_fish":
			return RAW_FISH
		"cooked_fish":
			return COOKED_FISH
		"egg":
			return EGG
		"milk_bucket":
			return MILK_BUCKET
		"sugar":
			return SUGAR
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
		STONE_AXE:
			return "Stone Axe"
		STONE_SHOVEL:
			return "Stone Shovel"
		STONE_SWORD:
			return "Stone Sword"
		IRON_AXE:
			return "Iron Axe"
		IRON_SHOVEL:
			return "Iron Shovel"
		IRON_SWORD:
			return "Iron Sword"
		DIAMOND_AXE:
			return "Diamond Axe"
		DIAMOND_SHOVEL:
			return "Diamond Shovel"
		DIAMOND_SWORD:
			return "Diamond Sword"
		GOLD_PICKAXE:
			return "Gold Pickaxe"
		GOLD_AXE:
			return "Gold Axe"
		GOLD_SHOVEL:
			return "Gold Shovel"
		GOLD_SWORD:
			return "Gold Sword"
		FLINT:
			return "Flint"
		Blocks.SAPLING:
			return "Sapling"
		IRON_PICKAXE:
			return "Iron Pickaxe"
		DIAMOND_PICKAXE:
			return "Diamond Pickaxe"
		WOODEN_SHOVEL:
			return "Wooden Shovel"
		WOODEN_AXE:
			return "Wooden Axe"
		WOODEN_SWORD:
			return "Wooden Sword"
		WOODEN_HOE:
			return "Wooden Hoe"
		COAL:
			return "Coal"
		IRON_INGOT:
			return "Iron Ingot"
		GOLD_INGOT:
			return "Gold Ingot"
		DIAMOND:
			return "Diamond"
		CHARCOAL:
			return "Charcoal"
		LEATHER:
			return "Leather"
		BONEMEAL:
			return "Bone Meal"
		IRON_HELMET:
			return "Iron Helmet"
		IRON_CHESTPLATE:
			return "Iron Chestplate"
		IRON_LEGGINGS:
			return "Iron Leggings"
		IRON_BOOTS:
			return "Iron Boots"
		GOLD_HELMET:
			return "Gold Helmet"
		GOLD_CHESTPLATE:
			return "Gold Chestplate"
		GOLD_LEGGINGS:
			return "Gold Leggings"
		GOLD_BOOTS:
			return "Gold Boots"
		DIAMOND_HELMET:
			return "Diamond Helmet"
		DIAMOND_CHESTPLATE:
			return "Diamond Chestplate"
		DIAMOND_LEGGINGS:
			return "Diamond Leggings"
		DIAMOND_BOOTS:
			return "Diamond Boots"
		BUCKET_EMPTY:
			return "Bucket"
		BUCKET_WATER:
			return "Water Bucket"
		BUCKET_LAVA:
			return "Lava Bucket"
		FLINT_AND_STEEL:
			return "Flint and Steel"
		WOODEN_DOOR:
			return "Wooden Door"
		IRON_DOOR:
			return "Iron Door"
		GUNPOWDER:
			return "Gunpowder"
		SUGAR_CANE:
			return "Sugar Cane"
		COMPASS:
			return "Compass"
		CLOCK:
			return "Clock"
		REDSTONE:
			return "Redstone"
		Blocks.TNT:
			return "TNT"
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
		Blocks.FURNACE, Blocks.LIT_FURNACE:
			return "Furnace"
		Blocks.GLASS:
			return "Glass"
		Blocks.FARMLAND:
			return "Farmland"
		Blocks.GRAVEL:
			return "Gravel"
		Blocks.CHEST:
			return "Chest"
		Blocks.TORCH:
			return "Torch"
		Blocks.FIRE:
			return "Fire"
		Blocks.FENCE:
			return "Fence"
		Blocks.WOOD_STAIRS:
			return "Wooden Stairs"
		Blocks.COBBLESTONE_STAIRS:
			return "Cobblestone Stairs"
		Blocks.LADDER:
			return "Ladder"
		Blocks.SUGAR_CANE:
			return "Sugar Cane"
		Blocks.ICE:
			return "Ice"
		Blocks.SNOW_BLOCK:
			return "Snow Block"
		Blocks.SNOW_LAYER:
			return "Snow Layer"
		Blocks.CACTUS:
			return "Cactus"
		Blocks.PUMPKIN:
			return "Pumpkin"
		Blocks.JACK_O_LANTERN:
			return "Jack o'Lantern"
		Blocks.BOOKSHELF:
			return "Bookshelf"
		Blocks.CROPS:
			return "Wheat Crops"
		Blocks.WOOL_WHITE:
			return "White Wool"
		Blocks.WOOL_ORANGE:
			return "Orange Wool"
		Blocks.WOOL_MAGENTA:
			return "Magenta Wool"
		Blocks.WOOL_LIGHT_BLUE:
			return "Light Blue Wool"
		Blocks.WOOL_YELLOW:
			return "Yellow Wool"
		Blocks.WOOL_LIME:
			return "Lime Wool"
		Blocks.WOOL_PINK:
			return "Pink Wool"
		Blocks.WOOL_GRAY:
			return "Gray Wool"
		Blocks.WOOL_LIGHT_GRAY:
			return "Light Gray Wool"
		Blocks.WOOL_CYAN:
			return "Cyan Wool"
		Blocks.WOOL_PURPLE:
			return "Purple Wool"
		Blocks.WOOL_BLUE:
			return "Blue Wool"
		Blocks.WOOL_BROWN:
			return "Brown Wool"
		Blocks.WOOL_GREEN:
			return "Green Wool"
		Blocks.WOOL_RED:
			return "Red Wool"
		Blocks.WOOL_BLACK:
			return "Black Wool"
		Blocks.SPONGE:
			return "Sponge"
		Blocks.IRON_BLOCK:
			return "Block of Iron"
		Blocks.GOLD_BLOCK:
			return "Block of Gold"
		Blocks.DIAMOND_BLOCK:
			return "Block of Diamond"
		APPLE:
			return "Apple"
		BREAD:
			return "Bread"
		WHEAT:
			return "Wheat"
		WHEAT_SEEDS:
			return "Seeds"
		STRING:
			return "String"
		FEATHER:
			return "Feather"
		PAPER:
			return "Paper"
		BOOK:
			return "Book"
		BRICK:
			return "Brick"
		SADDLE:
			return "Saddle"
		BOWL:
			return "Bowl"
		MUSHROOM_STEW:
			return "Mushroom Stew"
		LEATHER_HELMET:
			return "Leather Cap"
		LEATHER_CHESTPLATE:
			return "Leather Tunic"
		LEATHER_LEGGINGS:
			return "Leather Pants"
		LEATHER_BOOTS:
			return "Leather Boots"
		RAW_PORKCHOP:
			return "Raw Porkchop"
		COOKED_PORKCHOP:
			return "Cooked Porkchop"
		GOLDEN_APPLE:
			return "Golden Apple"
		FISHING_ROD:
			return "Fishing Rod"
		RAW_FISH:
			return "Raw Fish"
		COOKED_FISH:
			return "Cooked Fish"
		EGG:
			return "Egg"
		MILK_BUCKET:
			return "Milk Bucket"
		SUGAR:
			return "Sugar"
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


# Armor slot-kind routing. Maps an armor item id to one of ARMOR_SLOT_*.
# Non-armor items return ARMOR_SLOT_NONE. Used by the inventory UI to
# validate slot placement (helmets only go in the head slot, etc.).
static func armor_slot_for(item_id: int) -> int:
	match item_id:
		LEATHER_HELMET, IRON_HELMET, GOLD_HELMET, DIAMOND_HELMET:
			return ARMOR_SLOT_HEAD
		LEATHER_CHESTPLATE, IRON_CHESTPLATE, GOLD_CHESTPLATE, DIAMOND_CHESTPLATE:
			return ARMOR_SLOT_CHEST
		LEATHER_LEGGINGS, IRON_LEGGINGS, GOLD_LEGGINGS, DIAMOND_LEGGINGS:
			return ARMOR_SLOT_LEGS
		LEATHER_BOOTS, IRON_BOOTS, GOLD_BOOTS, DIAMOND_BOOTS:
			return ARMOR_SLOT_FEET
	return ARMOR_SLOT_NONE


static func is_armor(item_id: int) -> bool:
	return armor_slot_for(item_id) != ARMOR_SLOT_NONE


static func armor_defense(item_id: int) -> int:
	return _ARMOR_DEFENSE.get(item_id, 0)


static func tool_durability(item_id: int) -> int:
	if not _TOOL_DATA.has(item_id):
		return 0
	return _TOOL_DATA[item_id][3]


# Per-item max stack size. Vanilla ItemTool/ItemSword override
# `maxStackSize` to 1 — without this, two pickaxes in one slot would
# share a single damage value and burn out together. Non-tool items
# stack to ItemStack.MAX_SIZE (64).
# Alpha-style food heal value. Returns HP restored when the player
# right-clicks the item in hand. 0 for non-food. Pre-Beta 1.8 — no
# hunger system; eating heals directly. Values verified against
# Alpha vendor/alpha-1.2.6-src/src/dx.java constructor args, where
# `qk(id, food_value)` passes food_value into qk.b (heal amount).
#
#   apple           dx.h = qk(4, 4)    → 4
#   bread           dx.S = qk(41, 5)   → 5
#   raw porkchop    dx.ao = qk(63, 3)  → 3
#   cooked porkchop dx.ap = qk(64, 8)  → 8
#   golden apple    dx.ar = qk(66, 42) → 42
#   raw fish        dx.aS = qk(93, 2)  → 2
#   cooked fish     dx.aT = qk(94, 5)  → 5
#   mushroom stew   dx.D  = au(26, 10) → 10  (returns bowl after)
static func food_value(item_id: int) -> int:
	match item_id:
		APPLE:
			return 4
		BREAD:
			return 5
		RAW_PORKCHOP:
			return 3
		COOKED_PORKCHOP:
			return 8
		GOLDEN_APPLE:
			return 42
		RAW_FISH:
			return 2
		COOKED_FISH:
			return 5
		MUSHROOM_STEW:
			return 10
	return 0


static func is_food(item_id: int) -> bool:
	return food_value(item_id) > 0


static func max_stack_size(item_id: int) -> int:
	if is_tool_item(item_id):
		return 1
	# Vanilla ItemBucket overrides maxStackSize to 1 — filled buckets
	# need per-stack state (which fluid), and even empty buckets follow
	# the same convention. Matches ItemBucket.itemID uniqueness rule.
	if item_id == BUCKET_EMPTY or item_id == BUCKET_WATER or item_id == BUCKET_LAVA:
		return 1
	# Vanilla eu.java:aX=1 — door items don't stack.
	if item_id == WOODEN_DOOR or item_id == IRON_DOOR:
		return 1
	# Vanilla pe.java:aX=1 (ItemSaddle) — Infdev addition, treasure-only,
	# never stacks. Same for mushroom stew (au.java:aX=1) — eating
	# returns an empty bowl so the slot can only hold one stew at a time.
	if item_id == SADDLE or item_id == MUSHROOM_STEW:
		return 1
	# Vanilla aE.java:aX=1 (ItemBucketMilk) — milk bucket is per-stack
	# state like other buckets and doesn't stack. Egg in vanilla stacks
	# to 16 (aX=16) — throwable item cap.
	if item_id == MILK_BUCKET:
		return 1
	if item_id == EGG:
		return 16
	return ItemStack.MAX_SIZE
