extends GutTest

# Food / eating tests. Locks in Alpha-faithful HP heal values from
# vendor/alpha-1.2.6-src/src/dx.java + tracks the Beta-era smelting
# recipes that pair raw → cooked food.


# Alpha-faithful HP heal values from dx.java qk(id, food_value) calls.
# These should NEVER change without a vanilla-source citation in the
# test message — they're the contract between Items.food_value and the
# right-click handler in interaction.gd.
func test_food_value_matches_alpha_constants() -> void:
	assert_eq(Items.food_value(Items.APPLE), 4, "dx.h = qk(4, 4)")
	assert_eq(Items.food_value(Items.BREAD), 5, "dx.S = qk(41, 5)")
	assert_eq(Items.food_value(Items.RAW_PORKCHOP), 3, "dx.ao = qk(63, 3)")
	assert_eq(Items.food_value(Items.COOKED_PORKCHOP), 8, "dx.ap = qk(64, 8)")
	assert_eq(Items.food_value(Items.GOLDEN_APPLE), 42, "dx.ar = qk(66, 42)")
	assert_eq(Items.food_value(Items.RAW_FISH), 2, "dx.aS = qk(93, 2)")
	assert_eq(Items.food_value(Items.COOKED_FISH), 5, "dx.aT = qk(94, 5)")
	assert_eq(Items.food_value(Items.MUSHROOM_STEW), 10, "dx.D = au(26, 10)")


func test_non_food_items_have_zero_food_value() -> void:
	# Tools, materials, armor — none should register as food. is_food
	# is what the eat handler gates on; a false positive here would
	# eat a stick or a pickaxe.
	assert_eq(Items.food_value(Items.STICK), 0)
	assert_eq(Items.food_value(Items.IRON_INGOT), 0)
	assert_eq(Items.food_value(Items.WOODEN_PICKAXE), 0)
	assert_eq(Items.food_value(Items.LEATHER_HELMET), 0)
	assert_eq(Items.food_value(Items.BOWL), 0)  # bowl is food-adjacent, not food
	assert_eq(Items.food_value(Items.STRING), 0)
	assert_false(Items.is_food(Items.STICK))
	assert_true(Items.is_food(Items.APPLE))


# Mushroom stew is the one food whose slot doesn't decrement to zero —
# vanilla au.java returns an empty bowl after consumption. Stack=1
# always, so the replace_selected hook in interaction.gd is the right
# primitive. Just verifying the stack-size invariant here.
func test_mushroom_stew_does_not_stack() -> void:
	assert_eq(Items.max_stack_size(Items.MUSHROOM_STEW), 1)
	# Bowl itself stacks normally so we can carry multiple from one craft.
	assert_eq(Items.max_stack_size(Items.BOWL), 64)


# Smelting recipes verified against TileEntityFurnace.smelt in vanilla.
# Raw porkchop / raw fish should yield their cooked variants and feed
# back into the food-value table above.
func test_smelting_raw_food_yields_cooked() -> void:
	assert_eq(Smelting.result_for(Items.RAW_PORKCHOP), Items.COOKED_PORKCHOP)
	assert_eq(Smelting.result_for(Items.RAW_FISH), Items.COOKED_FISH)
	assert_true(Smelting.is_smeltable(Items.RAW_PORKCHOP))
	assert_true(Smelting.is_smeltable(Items.RAW_FISH))
	# Cooked variants should NOT be re-smeltable — vanilla doesn't double-cook.
	assert_false(Smelting.is_smeltable(Items.COOKED_PORKCHOP))
	assert_false(Smelting.is_smeltable(Items.COOKED_FISH))
