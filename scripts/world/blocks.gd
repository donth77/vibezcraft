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


static func is_opaque(id: int) -> bool:
	return id != AIR


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
		GRASS:
			return 0.9
		LOG:
			return 3.0
		PLANKS:
			return 3.0
		STONE, COBBLESTONE, BRICK:
			return 7.5  # painfully slow without a pickaxe — Alpha-faithful
		OBSIDIAN:
			return 250.0  # only diamond pickaxe is practical
	return 1.5


# Alpha-faithful drop table. Returns the item ID dropped when the block is
# broken with bare hands or appropriate tool. AIR means "no drop".
# Bedrock is unbreakable in survival, but if it ever is broken: no drop.
static func drops(id: int) -> int:
	match id:
		STONE:
			return COBBLESTONE
		GRASS:
			return DIRT
		LEAVES:
			return AIR  # Alpha leaves dropped 0 or 1 sapling — no saplings yet
		BEDROCK:
			return AIR
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
	return ""
