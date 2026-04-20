class_name Blocks
extends RefCounted

# Block IDs (Uint8 0-255). IDs are stable — append to the end, never renumber.

const AIR := 0
const BEDROCK := 1
const STONE := 2
const DIRT := 3
const GRASS := 4
const COBBLESTONE := 5
const LOG := 6
const PLANKS := 7
const LEAVES := 8
const SAND := 9
const BRICK := 10
const OBSIDIAN := 11
const COAL_ORE := 12
const IRON_ORE := 13
const GOLD_ORE := 14
const DIAMOND_ORE := 15
const CRAFTING_TABLE := 16
# Vanilla "BlockSoil" — dirt tilled by a hoe. Drops dirt when broken.
const FARMLAND := 17
# Vanilla BlockGravel. Static for now (gravity / falling-block physics
# deferred — vanilla `tickAlways()` will land with the entity-tick system).
const GRAVEL := 18
# Vanilla BlockFurnace + BlockBurningFurnace. Two IDs because the lit /
# unlit state is a separate block in vanilla (toggled in-place when fuel
# starts/stops burning). Only FURNACE is craftable; LIT_FURNACE is set by
# the furnace tile-entity ticker.
const FURNACE := 19
const LIT_FURNACE := 20
# Vanilla BlockGlass — transparent (alpha-test) block from smelting sand.
# Treated as non-opaque so the chunk mesher culls neighbor faces against
# it the same way it does with air.
const GLASS := 21
# Vanilla BlockSapling — drops from leaves at 1/20 per
# BlockLeaves.dropNaturally. Renders as a non-cube cross-quad in vanilla;
# we currently render as a full alpha-tested cube (proper cross-mesh
# requires non-cube mesher path — same TODO as torches/slabs/stairs).
const SAPLING := 22


static func is_opaque(id: int) -> bool:
	# LEAVES + GLASS + SAPLING render with alpha-test (discard in
	# chunk.gdshader); treating any as opaque would cull the stone/dirt
	# faces behind them and the shader discard would then punch straight
	# through to the world background. Mesher pairs this with a "same-id
	# cull" so adjacent leaves/glass don't emit shared internal faces.
	return id != AIR and id != LEAVES and id != GLASS and id != SAPLING


# Vanilla BlockGravel + BlockSand inherit BlockFalling, which schedules
# a fall-tick whenever a neighbor changes. ChunkManager calls this after
# any block becomes AIR to settle anything sitting unsupported above.
static func has_gravity(id: int) -> bool:
	return id == SAND or id == GRAVEL


# Block hardness — base for all break-time math. Vanilla MC values, in
# "block-hardness units" not seconds. Final time = hardness × multiplier
# (1.5 if correct tool, 5.0 if wrong/no tool) ÷ tool speed.
static func hardness(id: int) -> float:
	match id:
		BEDROCK:
			return -1.0  # unbreakable
		LEAVES, GLASS:
			return 0.2
		SAPLING:
			return 0.0  # vanilla: instant break
		DIRT, SAND:
			return 0.5
		GRASS, FARMLAND, GRAVEL:
			return 0.6
		LOG, PLANKS, CRAFTING_TABLE:
			return 2.0
		STONE, COBBLESTONE, BRICK:
			return 1.5
		FURNACE, LIT_FURNACE:
			return 3.5
		COAL_ORE, IRON_ORE, GOLD_ORE, DIAMOND_ORE:
			return 3.0
		OBSIDIAN:
			return 50.0
	return 1.0


# Required harvest level to actually drop the block when broken with a tool.
# 0 = no requirement (any tool / bare hand drops). Vanilla mc-dev values:
#   stone-class & coal: 0  (any pickaxe drops cobblestone/coal)
#   iron ore:           1  (stone pick or better)
#   gold/diamond/redstone ore: 2  (iron pick or better)
#   obsidian:           3  (diamond pick)
static func required_harvest_level(id: int) -> int:
	match id:
		IRON_ORE:
			return 1
		GOLD_ORE, DIAMOND_ORE:
			return 2
		OBSIDIAN:
			return 3
	return 0


# Which tool type is "correct" for break-speed bonus (see Items.TOOL_TYPE_*).
# 0 = any/none (no bonus from any tool). Mirrors vanilla ItemPickaxe's block list.
static func preferred_tool_type(id: int) -> int:
	match id:
		STONE, COBBLESTONE, BRICK, OBSIDIAN:
			return Items.TOOL_TYPE_PICKAXE
		COAL_ORE, IRON_ORE, GOLD_ORE, DIAMOND_ORE:
			return Items.TOOL_TYPE_PICKAXE
		FURNACE, LIT_FURNACE:
			return Items.TOOL_TYPE_PICKAXE
		LOG, PLANKS:
			return Items.TOOL_TYPE_AXE
		DIRT, GRASS, SAND, FARMLAND, GRAVEL:
			return Items.TOOL_TYPE_SHOVEL
	return 0


# Time (seconds) to break this block with the given tool (or AIR for bare
# hand). Returns -1.0 for unbreakable. Mirrors vanilla Beta's
# `Block.getPlayerRelativeBlockHardness`:
#   • If the block's material requires a tool and the held tool doesn't
#     qualify, the slow branch applies: `hardness × 5` seconds.
#   • Otherwise the fast branch: `hardness × 1.5 / strVsBlock`, where
#     strVsBlock is the tool's speed when it's effective against this
#     block (correct type + sufficient tier), else 1.0 (bare-hand rate).
# "Requires a tool" = stone-class (pickaxe preferred, harvest level 0) or
# anything with a positive harvest level (ores, obsidian). Soft blocks
# (dirt, grass, wood, leaves, sand) all break fine bare-handed.
static func break_time(id: int, tool_id: int) -> float:
	var h: float = hardness(id)
	if h < 0.0:
		return -1.0
	var tool_kind: int = Items.tool_type(tool_id) if tool_id != AIR else 0
	var preferred: int = preferred_tool_type(id)
	var required_level: int = required_harvest_level(id)
	var type_ok: bool = preferred != 0 and tool_kind == preferred
	var tier_ok: bool = tool_id != AIR and Items.tool_harvest_level(tool_id) >= required_level
	var effective: bool = type_ok and tier_ok
	var requires_tool: bool = (
		(preferred == Items.TOOL_TYPE_PICKAXE and required_level == 0) or required_level > 0
	)
	if requires_tool and not effective:
		return h * 5.0
	var speed: float = Items.tool_speed(tool_id) if effective else 1.0
	return h * 1.5 / speed


# Wraps drop_with_tool with vanilla random-drop overrides:
#   • Leaves: 5% chance of SAPLING (BlockLeaves.dropNaturally — 1/20)
#   • Gravel: 10% chance of FLINT instead of gravel (BlockGravel)
# All other blocks return the deterministic drop_with_tool result.
static func random_drop(id: int, tool_id: int) -> int:
	if id == LEAVES:
		# Leaves use a 1/20 sapling roll regardless of tool.
		if randi() % 20 == 0:
			return SAPLING
		return AIR
	if id == GRAVEL:
		# 1/10 flint chance — only when broken with a shovel-or-bare-hand
		# (vanilla); a non-shovel/non-bare break still drops gravel via
		# drop_with_tool's normal path.
		if randi() % 10 == 0:
			return Items.FLINT
	return drop_with_tool(id, tool_id)


# Returns the item dropped when the block is broken with `tool_id`, gated
# by tool harvest level. AIR means "no drop". `tool_id == AIR` is bare hand.
static func drop_with_tool(id: int, tool_id: int) -> int:
	# Hard tier gate: if the tool is below the block's required level, no drop.
	var required: int = required_harvest_level(id)
	if required > 0:
		if tool_id == AIR:
			return AIR  # bare hand never satisfies a level requirement
		if Items.tool_harvest_level(tool_id) < required:
			return AIR
	# Stone-class blocks (cobblestone-droppers) ALSO require *some* pickaxe
	# even at level 0 — bare hand on stone drops nothing in vanilla.
	if preferred_tool_type(id) == Items.TOOL_TYPE_PICKAXE and required == 0:
		if tool_id == AIR or Items.tool_type(tool_id) != Items.TOOL_TYPE_PICKAXE:
			return AIR
	return drops(id)


# Bare-hand break time in seconds (Alpha hardness × 1.5 baseline).
# A return of -1.0 means unbreakable (bedrock).
static func break_time_bare_hand(id: int) -> float:
	match id:
		BEDROCK:
			return -1.0
		LEAVES:
			return 0.3
		DIRT, SAND:
			return 0.75
		GRASS, FARMLAND, GRAVEL:
			return 0.9
		LOG:
			return 3.0
		PLANKS:
			return 3.0
		STONE, COBBLESTONE, BRICK:
			return 7.5  # painfully slow without a pickaxe — Alpha-faithful
		FURNACE, LIT_FURNACE:
			return 17.5  # 3.5 hardness × 5 (no-tool penalty)
		COAL_ORE, IRON_ORE, GOLD_ORE, DIAMOND_ORE:
			return 15.0  # ores are tougher than stone — wood-pick takes ~2.5s
		OBSIDIAN:
			return 250.0  # only diamond pickaxe is practical
	return 1.5


# Alpha-faithful drop table. Returns the item ID dropped when the block is
# broken with bare hands or appropriate tool. AIR means "no drop".
# Bedrock is unbreakable in survival, but if it ever is broken: no drop.
# Ore-tier drop gating (wood-pick required for stone, etc.) lands with
# the tool-tier system in a later slice — for now, ores drop their items.
static func drops(id: int) -> int:
	match id:
		STONE:
			return COBBLESTONE
		GRASS, FARMLAND:
			return DIRT
		LEAVES:
			return AIR  # Alpha leaves dropped 0 or 1 sapling — no saplings yet
		GLASS:
			return AIR  # vanilla: glass shatters when broken, drops nothing
		SAPLING:
			return SAPLING  # drops itself when broken
		BEDROCK:
			return AIR
		COAL_ORE:
			return Items.COAL
		DIAMOND_ORE:
			return Items.DIAMOND
		IRON_ORE, GOLD_ORE:
			return id  # iron/gold ore drops itself (smelt for ingot)
		LIT_FURNACE:
			return FURNACE  # vanilla: lit furnace breaks back into the unlit form
	return id


static func name_of(id: int) -> String:
	match id:
		AIR:
			return "air"
		BEDROCK:
			return "bedrock"
		STONE:
			return "stone"
		DIRT:
			return "dirt"
		GRASS:
			return "grass"
		COBBLESTONE:
			return "cobblestone"
		LOG:
			return "log"
		PLANKS:
			return "planks"
		LEAVES:
			return "leaves"
		SAND:
			return "sand"
		COAL_ORE:
			return "coal_ore"
		IRON_ORE:
			return "iron_ore"
		GOLD_ORE:
			return "gold_ore"
		DIAMOND_ORE:
			return "diamond_ore"
		CRAFTING_TABLE:
			return "crafting_table"
		FARMLAND:
			return "farmland"
		GRAVEL:
			return "gravel"
		FURNACE:
			return "furnace"
		LIT_FURNACE:
			return "lit_furnace"
		GLASS:
			return "glass"
		SAPLING:
			return "sapling"
	return "unknown"


# Returns the texture name for a given block face. face ∈ {"top", "bottom", "side"}
static func get_face_texture(id: int, face: String) -> String:
	match id:
		BEDROCK:
			return "bedrock"
		STONE:
			return "stone"
		DIRT:
			return "dirt"
		GRASS:
			match face:
				"top":
					return "grass_top"
				"bottom":
					return "dirt"
				_:
					return "grass_side"
		COBBLESTONE:
			return "cobblestone"
		LOG:
			match face:
				"top", "bottom":
					return "log_top"
				_:
					return "log_side"
		PLANKS:
			return "planks"
		LEAVES:
			return "leaves"
		SAND:
			return "sand"
		COAL_ORE:
			return "coal_ore"
		IRON_ORE:
			return "iron_ore"
		GOLD_ORE:
			return "gold_ore"
		DIAMOND_ORE:
			return "diamond_ore"
		CRAFTING_TABLE:
			match face:
				"top":
					return "crafting_table_top"
				"bottom":
					return "planks"
				_:
					return "crafting_table_side"
		FARMLAND:
			match face:
				"top":
					return "farmland"
				_:
					return "dirt"
		GRAVEL:
			return "gravel"
		FURNACE:
			match face:
				"top", "bottom":
					return "furnace_top"
				_:
					return "furnace_front"
		LIT_FURNACE:
			match face:
				"top", "bottom":
					return "furnace_top"
				_:
					return "furnace_front_lit"
		GLASS:
			return "glass"
		SAPLING:
			return "sapling"
	return ""
