class_name Smelting
extends RefCounted

# Vanilla MC smelting registry. Two static maps:
#   _RESULTS:    input item id → output item id (1-input, 1-output)
#   _FUEL_TICKS: fuel item id → burn-time-in-ticks per unit
#
# Vanilla burn times (Bukkit/mc-dev TileEntityFurnace.fuelTime):
#   coal = 1600t (8 smelts × 200t each), planks = 300t, log = 300t,
#   stick = 100t, sapling = 100t (we don't have saplings yet),
#   wooden tool = 200t, lava bucket = 20000t (deferred — needs buckets).
#
# The smelt cycle is 200 ticks regardless of input. At 20 TPS that's 10
# seconds per smelt — verbatim vanilla.

const SMELT_TICKS: int = 200

const _RESULTS: Dictionary = {
	Blocks.IRON_ORE: Items.IRON_INGOT,
	Blocks.GOLD_ORE: Items.GOLD_INGOT,
	Blocks.COBBLESTONE: Blocks.STONE,
	Blocks.SAND: Blocks.GLASS,
	Blocks.LOG: Items.CHARCOAL,
	# Vanilla Alpha — food smelt entries from TileEntityFurnace.smelt():
	#   raw porkchop  → cooked porkchop (3 HP → 8 HP)
	#   raw fish      → cooked fish     (2 HP → 5 HP)
	# Same 200-tick cycle as any other smelt.
	Items.RAW_PORKCHOP: Items.COOKED_PORKCHOP,
	Items.RAW_FISH: Items.COOKED_FISH,
	# Clay ball → brick (vanilla Alpha — fires brick from clay nuggets,
	# the only way to obtain BRICK items pre-stripped). 4 clay balls
	# per clay block → smelt 4 → 4 brick items → 1 brick block.
	Items.CLAY_BALL: Items.BRICK,
}

const _FUEL_TICKS: Dictionary = {
	Items.COAL: 1600,
	Items.CHARCOAL: 1600,  # vanilla — identical to coal
	Blocks.PLANKS: 300,
	Blocks.LOG: 300,
	Items.STICK: 100,
}


# Returns the smelted output item id for a given input, or AIR if the
# input has no smelt recipe.
static func result_for(input_id: int) -> int:
	return _RESULTS.get(input_id, Blocks.AIR)


# Returns the burn time (in ticks) for a fuel item, or 0 if non-fuel.
static func fuel_burn_ticks(fuel_id: int) -> int:
	return _FUEL_TICKS.get(fuel_id, 0)


static func is_smeltable(input_id: int) -> bool:
	return _RESULTS.has(input_id)


static func is_fuel(item_id: int) -> bool:
	return _FUEL_TICKS.has(item_id)
