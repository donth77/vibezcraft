extends GutTest

# Fishing rod / bobber tests. Locks in tool stats from vanilla bj.java
# + asserts the bobber's bite-window math matches the vanilla
# "1/500 chance, k=nextInt(30)+10" rule from hj.java.


# Vanilla bj.java: aY=64 durability, aX=1 stack. Both are tool-data
# rows in items.gd — these guarantees stop a future stack-size change
# from silently re-enabling fishing rod stacking, which would let the
# player cheese durability by combining stacks.
func test_fishing_rod_tool_data_matches_vanilla() -> void:
	assert_true(Items.is_tool_item(Items.FISHING_ROD), "fishing rod is a tool item")
	assert_eq(Items.max_stack_size(Items.FISHING_ROD), 1, "fishing rod doesn't stack")
	assert_eq(Items.tool_durability(Items.FISHING_ROD), 64, "vanilla bj.java aY=64 durability")
	assert_eq(
		Items.tool_type(Items.FISHING_ROD),
		Items.TOOL_TYPE_FISHING_ROD,
		"fishing rod has its own tool type"
	)


# Fish food values from dx.aS (raw, food=2) + dx.aT (cooked, food=5).
func test_fish_food_values_match_alpha() -> void:
	assert_eq(Items.food_value(Items.RAW_FISH), 2, "dx.aS = qk(93, 2)")
	assert_eq(Items.food_value(Items.COOKED_FISH), 5, "dx.aT = qk(94, 5)")


# Smelt path: raw_fish + furnace → cooked_fish (vanilla
# TileEntityFurnace.smeltRecipes). Already covered in test_food but
# repeated here so the fishing loop end-to-end (catch → smelt → eat)
# is locked in one place.
func test_raw_fish_smelts_to_cooked_fish() -> void:
	assert_true(Smelting.is_smeltable(Items.RAW_FISH))
	assert_eq(Smelting.result_for(Items.RAW_FISH), Items.COOKED_FISH)
	assert_false(Smelting.is_smeltable(Items.COOKED_FISH), "cooked fish doesn't re-smelt")


# Bobber bite-window constants from hj.java:
#   k = nextInt(30) + 10   → bite duration 10..39 ticks
#   nextInt(500) == 0      → bite trigger 1/500 per in-water tick
# These constants live as static fields on FishingBobber; verify them
# so a typo in the script doesn't silently break the fishing curve.
func test_bobber_bite_window_matches_vanilla() -> void:
	# Vanilla nextInt(30)+10 = range [10, 39]. Min should be exactly 10.
	assert_eq(FishingBobber.BITE_DURATION_MIN, 10, "vanilla hj.java k = nextInt(30) + 10 minimum")
	assert_eq(FishingBobber.BITE_DURATION_RANGE, 30, "vanilla hj.java k = nextInt(30) + 10 range")
	assert_eq(FishingBobber.BITE_CHANCE_PER_TICK, 500, "vanilla hj.java nextInt(500) trigger")
