# gdlint: disable=max-public-methods
extends GutTest

# Nether environment, lighting, fluids and item rules
# (docs/nether-alpha-1.2.6-implementation-plan.md §5, Batch 6).
#
# Batch 1 gave WorldProvider the whole policy surface but nothing read
# it. This batch wires the systems that should ask, so most of what is
# checked here is a pair: the Nether behaves one way, the Overworld still
# behaves the other, and switching back restores it exactly.
#
# The values themselves are source-derived and cited per test. The one
# that matters most is the brightness table, because it is the difference
# between "gloomy" and "pitch black" and it comes out of a single
# constant in oz.java/om.java.

const _NETHER_WORLD := "test_nether_environment"
# Preloaded once: two tests read this script's source to assert the
# provider checks sit in the right place, and gdlint rejects loading the
# same path twice.
const _INTERACTION := preload("res://scripts/player/interaction.gd")

var _dimension_was: int
var _active_world_was: String


func before_each() -> void:
	_dimension_was = DimensionContext.active()
	_active_world_was = Game.active_world
	Game.active_world = _NETHER_WORLD
	DimensionContext.set_active(DimensionContext.OVERWORLD)


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)
	SaveLoad.delete_world(_NETHER_WORLD)
	Game.active_world = _active_world_was


func _overworld() -> WorldProvider:
	return DimensionContext.provider(DimensionContext.OVERWORLD)


func _nether() -> WorldProvider:
	return DimensionContext.provider(DimensionContext.NETHER)


# --- Brightness table (oz.java:22-28 / om.java:22-28) ---


func test_the_brightness_table_matches_the_source_formula() -> void:
	# Both dimensions use the SAME formula; only the ambient floor differs.
	#
	#   f3 = 1 - i/15
	#   f[i] = (1 - f3) / (f3 * 3 + 1) * (1 - floor) + floor
	for provider: WorldProvider in [_overworld(), _nether()]:
		var floor_value: float = provider.ambient_light_floor
		for level: int in range(16):
			var f: float = 1.0 - float(level) / 15.0
			var expected: float = (1.0 - f) / (f * 3.0 + 1.0) * (1.0 - floor_value) + floor_value
			assert_almost_eq(
				provider.brightness(level),
				expected,
				1e-6,
				"dimension %d brightness[%d]" % [provider.id, level]
			)


func test_the_ambient_floors_are_the_source_constants() -> void:
	assert_almost_eq(_overworld().ambient_light_floor, 0.05, 1e-6, "oz.java:23 uses 0.05")
	assert_almost_eq(_nether().ambient_light_floor, 0.1, 1e-6, "om.java:24 uses 0.1")


func test_unlit_nether_is_exactly_twice_as_bright_as_unlit_overworld() -> void:
	# The observable consequence of that one constant: a pitch-dark Nether
	# cell still reads at 0.1 where the Overworld bottoms out at 0.05.
	assert_almost_eq(_nether().brightness(0), 0.1, 1e-6, "Nether darkness floor")
	assert_almost_eq(_overworld().brightness(0), 0.05, 1e-6, "Overworld darkness floor")
	assert_almost_eq(_nether().brightness(0) / _overworld().brightness(0), 2.0, 1e-6, "exactly 2x")


func test_full_light_is_one_in_both_dimensions() -> void:
	# The floor lifts the bottom of the curve, not the top.
	assert_almost_eq(_overworld().brightness(15), 1.0, 1e-6)
	assert_almost_eq(_nether().brightness(15), 1.0, 1e-6)


func test_the_table_is_monotonic() -> void:
	for provider: WorldProvider in [_overworld(), _nether()]:
		for level: int in range(1, 16):
			assert_gt(
				provider.brightness(level),
				provider.brightness(level - 1),
				"dimension %d brightness rises at level %d" % [provider.id, level]
			)


func test_brightness_table_returns_all_sixteen_entries() -> void:
	var table: PackedFloat32Array = _nether().brightness_table()
	assert_eq(table.size(), 16, "one entry per light level")
	for level: int in range(16):
		assert_almost_eq(table[level], _nether().brightness(level), 1e-6, "entry %d" % level)


# --- Sky light ---


func test_the_nether_generates_no_sky_light() -> void:
	# om.java reports no sky. Propagating a sky channel would light the
	# whole cavern system, so the fill is skipped entirely.
	DimensionContext.set_active(DimensionContext.NETHER)
	var chunk := Chunk.new()
	for x: int in range(Chunk.SIZE_X):
		for z: int in range(Chunk.SIZE_Z):
			chunk.set_block(x, 10, z, Blocks.NETHERRACK)
	Lighting.fill_sky_light(chunk)
	for i: int in range(chunk.sky_light.size()):
		assert_eq(chunk.sky_light[i], 0, "sky light cell %d stays dark" % i)


func test_the_overworld_still_fills_sky_light() -> void:
	# The control: the same call in dimension 0 must light open columns.
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	var chunk := Chunk.new()
	for x: int in range(Chunk.SIZE_X):
		for z: int in range(Chunk.SIZE_Z):
			chunk.set_block(x, 10, z, Blocks.STONE)
	Lighting.fill_sky_light(chunk)
	assert_eq(chunk.get_sky_light(0, 120, 0), 15, "open sky above the floor is lit")
	assert_eq(chunk.get_sky_light(0, 5, 0), 0, "under the floor is dark")


func test_emissive_blocks_light_the_nether_without_a_sky() -> void:
	# With no sky channel the only illumination is block light, so the
	# emissive values have to carry the whole dimension.
	assert_eq(Blocks.light_emission(Blocks.GLOWSTONE), 15, "glowstone is the bright one")
	assert_eq(Blocks.light_emission(Blocks.PORTAL), 11, "portals glow")
	assert_eq(Blocks.light_emission(Blocks.LAVA_STILL), 15, "lava seas glow")
	assert_eq(Blocks.light_emission(Blocks.FIRE), 15, "fire glows")


func test_block_light_propagates_in_the_nether() -> void:
	DimensionContext.set_active(DimensionContext.NETHER)
	var chunk := Chunk.new()
	chunk.set_block(8, 60, 8, Blocks.GLOWSTONE)
	Lighting.fill_block_light(chunk)
	assert_eq(chunk.get_block_light(8, 60, 8), 15, "the source is at full")
	assert_gt(chunk.get_block_light(9, 60, 8), 0, "and it reaches its neighbour")


# --- Fluids (ja.java:27-29) ---


func test_lava_decays_slower_in_the_nether() -> void:
	# `int n7 = 1; if (material == lava && !provider.<flag>) n7 = 2;` —
	# the increment DEFAULTS to 1 and is raised to 2 outside the Nether.
	assert_eq(_overworld().lava_horizontal_decay, 2, "Overworld lava decays by 2 per block")
	assert_eq(_nether().lava_horizontal_decay, 1, "Nether lava decays by 1, so reaches further")


func test_the_lava_tick_cadence_is_the_same_in_both_dimensions() -> void:
	# The plan is explicit that this is a DECAY change, not a faster tick.
	# There is one constant and both dimensions use it.
	assert_eq(BlockFluids.LAVA_TICK_RATE, 30, "30 ticks in both dimensions")
	var src: GDScript = load("res://scripts/world/block_fluids.gd") as GDScript
	assert_not_null(src, "block_fluids loads")
	if src != null:
		assert_false(
			src.source_code.contains("LAVA_TICK_RATE_NETHER"),
			"no per-dimension tick rate was introduced"
		)


func test_nether_lava_reaches_roughly_twice_as_far() -> void:
	# Level 8 is dry. Starting from a source at 0, the Overworld's
	# increment of 2 dries out after 3 steps; the Nether's 1 lasts 7.
	var overworld_reach: int = 0
	var level: int = 0
	while level + _overworld().lava_horizontal_decay < 8:
		level += _overworld().lava_horizontal_decay
		overworld_reach += 1
	var nether_reach: int = 0
	level = 0
	while level + _nether().lava_horizontal_decay < 8:
		level += _nether().lava_horizontal_decay
		nether_reach += 1
	assert_eq(overworld_reach, 3, "Overworld lava reaches 3 blocks")
	assert_eq(nether_reach, 7, "Nether lava reaches 7")


# --- Water evaporation ---


func test_water_placement_is_denied_in_the_nether() -> void:
	assert_true(_overworld().allows_water_placement, "water works in the Overworld")
	assert_false(_nether().allows_water_placement, "water evaporates in the Nether")


func test_the_bucket_path_checks_the_provider_before_placing() -> void:
	# Structural: the evaporation branch has to sit BEFORE the block write
	# and consume the bucket, or a player could carry water down and keep
	# both the water and a full bucket.
	var src: GDScript = _INTERACTION
	var text: String = src.source_code
	var guard: int = text.find("allows_water_placement")
	var write: int = text.find("_chunk_manager.set_world_block_with_meta(place_pos, source_id, 0)")
	assert_gt(guard, -1, "the bucket path consults the provider")
	assert_gt(write, -1, "the fluid write is still there")
	assert_lt(guard, write, "the evaporation check runs before the write")


# --- Sky rendering ---


func test_the_nether_renders_no_sky_and_pins_its_fog() -> void:
	assert_true(_overworld().renders_sky, "the Overworld has a sky")
	assert_false(_nether().renders_sky, "the Nether does not")
	# om.java:18 — `ao.b(0.2f, 0.03f, 0.03f)`.
	var fog: Color = _nether().fog_color
	assert_almost_eq(fog.r, 0.2, 1e-6, "fog red")
	assert_almost_eq(fog.g, 0.03, 1e-6, "fog green")
	assert_almost_eq(fog.b, 0.03, 1e-6, "fog blue")


func test_the_nether_reports_a_fixed_celestial_angle() -> void:
	# om.java:47 — `a(long, float)` returns 0.5f regardless of world time,
	# so anything asking "where is the sun" gets a stable answer even
	# though nothing celestial renders.
	assert_almost_eq(_nether().fixed_celestial_angle, 0.5, 1e-6, "pinned at 0.5")
	assert_lt(_overworld().fixed_celestial_angle, 0.0, "the Overworld uses real world time")


func test_the_day_night_driver_short_circuits_without_a_sky() -> void:
	var src: GDScript = load("res://scripts/world/day_night_driver.gd") as GDScript
	assert_not_null(src, "driver loads")
	if src == null:
		return
	var text: String = src.source_code
	assert_true(text.contains("renders_sky"), "the driver asks the provider")
	assert_true(text.contains("_apply_skyless_environment"), "and has a dedicated skyless path")


# --- Instruments (ae.java:67 / gp.java:40) ---


func test_instruments_wander_only_in_the_nether() -> void:
	assert_false(_overworld().instruments_wander, "the Overworld compass points at spawn")
	assert_true(_nether().instruments_wander, "the Nether compass does not")


func test_the_compass_and_clock_produce_varying_angles_in_the_nether() -> void:
	# Vanilla uses Math.random(), not the world RNG, so two readings
	# disagree. Sampling a handful and requiring more than one distinct
	# value is the honest assertion — a fixed angle would fail it.
	DimensionContext.set_active(DimensionContext.NETHER)
	var compass: Dictionary = {}
	var clock: Dictionary = {}
	for i: int in range(32):
		compass[ItemIcons._compass_target_angle()] = true
		clock[ItemIcons._clock_target_angle()] = true
	assert_gt(compass.size(), 1, "the compass needle wanders")
	assert_gt(clock.size(), 1, "the clock dial wanders")


func test_the_clock_resumes_real_time_after_returning() -> void:
	DimensionContext.set_active(DimensionContext.NETHER)
	var wandering: float = ItemIcons._clock_target_angle()
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	var settled_a: float = ItemIcons._clock_target_angle()
	var settled_b: float = ItemIcons._clock_target_angle()
	assert_eq(settled_a, settled_b, "the Overworld clock is stable again")
	assert_eq(settled_a, -(WorldTime.phase() - 0.25) * TAU, "and reads the real celestial angle")
	# Not a strict inequality: a wander CAN land on the settled value.
	assert_true(is_finite(wandering), "the Nether reading was still a real angle")


# --- Beds and respawn ---


func test_sleeping_is_denied_in_the_nether() -> void:
	assert_true(_overworld().allows_sleeping, "beds work in the Overworld")
	assert_false(_nether().allows_sleeping, "beds do not work in the Nether")


func test_the_bed_path_denies_before_setting_spawn_or_passing_time() -> void:
	# The denial has to come first: Alpha 1.2.6 has no exploding bed, and
	# the plan forbids adding one, so the only correct behaviour is a
	# message and nothing else.
	var src: GDScript = _INTERACTION
	var text: String = src.source_code
	var sleep_fn: int = text.find("func _try_sleep_in_bed")
	assert_gt(sleep_fn, -1, "the sleep handler exists")
	var guard: int = text.find("allows_sleeping", sleep_fn)
	var window: int = text.find("WorldTime.current_tick()", sleep_fn)
	assert_gt(guard, -1, "it consults the provider")
	assert_lt(guard, window, "before it even looks at the time of day")
	assert_false(text.contains("bed_explode"), "no exploding bed was added")


func test_the_nether_never_defines_a_spawn_point() -> void:
	assert_true(_overworld().provides_player_spawn, "the Overworld defines spawn")
	assert_false(_nether().provides_player_spawn, "the Nether never does")


# --- Repeated switching ---


func test_ten_switches_restore_the_overworld_policy_exactly() -> void:
	# Every value a system might have cached, checked after each round
	# trip. The provider objects are shared instances, so a system that
	# mutated one instead of reading it would show up here.
	var baseline: Dictionary = {
		"floor": _overworld().ambient_light_floor,
		"sky": _overworld().has_sky_light,
		"renders": _overworld().renders_sky,
		"decay": _overworld().lava_horizontal_decay,
		"water": _overworld().allows_water_placement,
		"sleep": _overworld().allows_sleeping,
		"wander": _overworld().instruments_wander,
		"brightness": _overworld().brightness_table(),
	}
	for i: int in range(10):
		DimensionContext.set_active(DimensionContext.NETHER)
		assert_false(
			DimensionContext.active_provider().has_sky_light, "round %d: in the Nether" % i
		)
		DimensionContext.set_active(DimensionContext.OVERWORLD)
		var now: WorldProvider = DimensionContext.active_provider()
		assert_eq(now.ambient_light_floor, baseline["floor"], "round %d: ambient floor" % i)
		assert_eq(now.has_sky_light, baseline["sky"], "round %d: sky light" % i)
		assert_eq(now.renders_sky, baseline["renders"], "round %d: sky rendering" % i)
		assert_eq(now.lava_horizontal_decay, baseline["decay"], "round %d: lava decay" % i)
		assert_eq(now.allows_water_placement, baseline["water"], "round %d: water" % i)
		assert_eq(now.allows_sleeping, baseline["sleep"], "round %d: sleeping" % i)
		assert_eq(now.instruments_wander, baseline["wander"], "round %d: instruments" % i)
		assert_eq(now.brightness_table(), baseline["brightness"], "round %d: brightness" % i)
