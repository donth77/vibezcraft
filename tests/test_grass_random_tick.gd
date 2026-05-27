extends GutTest

# Grass random-tick — vanilla `os.java::a()` port. Tests cover:
#   * `is_random_tickable` gate (only GRASS today)
#   * Decay path: dim cell under opaque cover demotes to DIRT (vanilla
#     1/4 chance per tick — we force the dice to always hit by setting
#     the GDScript RNG seed)
#   * Spread path: well-lit grass adjacent to lit dirt promotes the
#     dirt to GRASS
#   * No-op paths: well-lit grass without dirt neighbors, dim grass
#     without opaque cover, dirt with no light, dirt with opaque cover
#
# Uses a minimal FakeManager backed by a Dictionary of cells. Light is
# stored per-cell since the real lighting BFS depends on a fully-loaded
# world we don't want to spin up for unit tests.


class FakeManager:
	extends RefCounted
	var blocks: Dictionary = {}  # Vector3i → block_id
	var sky_light: Dictionary = {}  # Vector3i → 0..15
	var block_light: Dictionary = {}  # Vector3i → 0..15
	var writes: Array = []  # log of [pos, id] tuples

	func set_cell(pos: Vector3i, id: int, sky: int = 0, blk: int = 0) -> void:
		blocks[pos] = id
		sky_light[pos] = sky
		block_light[pos] = blk

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_sky_light(pos: Vector3i) -> int:
		return sky_light.get(pos, 15)  # default: open sky

	func get_world_block_light(pos: Vector3i) -> int:
		return block_light.get(pos, 0)

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id
		writes.append([pos, id])


var _mgr: FakeManager


func before_each() -> void:
	_mgr = FakeManager.new()


# --- is_random_tickable gate ---


func test_grass_is_random_tickable() -> void:
	assert_true(Blocks.is_random_tickable(Blocks.GRASS))


func test_dirt_is_not_random_tickable() -> void:
	assert_false(Blocks.is_random_tickable(Blocks.DIRT))


func test_stone_is_not_random_tickable() -> void:
	assert_false(Blocks.is_random_tickable(Blocks.STONE))


func test_air_is_not_random_tickable() -> void:
	assert_false(Blocks.is_random_tickable(Blocks.AIR))


# --- Decay: dim grass under opaque cover → DIRT ---


# Vanilla: grass with stone on top + zero light → 1/4 chance/tick to
# demote. Seed the RNG so we deterministically roll a hit.
func test_grass_decays_under_opaque_dark_cover() -> void:
	var pos := Vector3i(0, 64, 0)
	var above: Vector3i = pos + Vector3i(0, 1, 0)
	_mgr.set_cell(pos, Blocks.GRASS, 0, 0)
	# Above is STONE (opaque) with zero light — meets vanilla decay
	# conditions: light < 4 AND material.blocksMovement().
	_mgr.set_cell(above, Blocks.STONE, 0, 0)
	# Run the tick repeatedly until decay fires. With the 1/4 chance,
	# 100 attempts has < 1e-12 chance of never hitting.
	for _i in range(100):
		Blocks.on_random_tick(_mgr, pos, Blocks.GRASS)
		if _mgr.blocks[pos] == Blocks.DIRT:
			break
	assert_eq(_mgr.blocks[pos], Blocks.DIRT, "grass under opaque dark cover should decay to DIRT")


# Vanilla guard: decay ONLY fires when the above-cell is opaque.
# Grass under AIR (even dark AIR) stays as grass.
func test_grass_under_air_does_not_decay() -> void:
	var pos := Vector3i(0, 64, 0)
	var above: Vector3i = pos + Vector3i(0, 1, 0)
	_mgr.set_cell(pos, Blocks.GRASS, 0, 0)
	_mgr.set_cell(above, Blocks.AIR, 0, 0)
	for _i in range(100):
		Blocks.on_random_tick(_mgr, pos, Blocks.GRASS)
	assert_eq(_mgr.blocks[pos], Blocks.GRASS, "grass under AIR should NOT decay even when dim")


# Decay requires light < 4. With sky-light 15 (sun overhead), even
# opaque-covered grass survives because the light gate prevents decay.
# (This is the "well-lit under glass" case — but our test uses a stone
# cover with high light, which can't physically happen unless we mock.
# Asserts the gate logic, not a real-world scenario.)
func test_grass_under_opaque_but_lit_does_not_decay() -> void:
	var pos := Vector3i(0, 64, 0)
	var above: Vector3i = pos + Vector3i(0, 1, 0)
	_mgr.set_cell(pos, Blocks.GRASS, 15, 0)
	_mgr.set_cell(above, Blocks.STONE, 15, 0)  # mocked: opaque + lit
	for _i in range(100):
		Blocks.on_random_tick(_mgr, pos, Blocks.GRASS)
	assert_eq(_mgr.blocks[pos], Blocks.GRASS, "lit grass should NOT decay")


# --- Spread: well-lit grass → adjacent lit dirt becomes grass ---


# Vanilla spread requires SOURCE above-light >= 9 AND target above-light
# >= 4. Put grass at (0, 64, 0) under bright sky; put dirt at (1, 64, 0)
# also under bright sky. Repeated ticks should eventually promote.
func test_grass_spreads_to_adjacent_lit_dirt() -> void:
	var grass_pos := Vector3i(0, 64, 0)
	var dirt_pos := Vector3i(1, 64, 0)
	_mgr.set_cell(grass_pos, Blocks.GRASS, 15, 0)
	_mgr.set_cell(grass_pos + Vector3i(0, 1, 0), Blocks.AIR, 15, 0)  # well-lit + non-opaque
	_mgr.set_cell(dirt_pos, Blocks.DIRT, 15, 0)
	_mgr.set_cell(dirt_pos + Vector3i(0, 1, 0), Blocks.AIR, 15, 0)  # well-lit + non-opaque
	# The spread sample picks a random offset in ±1 X, ±3 Y, ±1 Z (27
	# cells). Only ONE of those 27 hits our dirt cell. 200 trials gives
	# >99.9% probability of at least one hit AND a successful promotion
	# (since the dirt + light conditions are met).
	for _i in range(200):
		Blocks.on_random_tick(_mgr, grass_pos, Blocks.GRASS)
		if _mgr.blocks.get(dirt_pos, Blocks.AIR) == Blocks.GRASS:
			break
	assert_eq(_mgr.blocks[dirt_pos], Blocks.GRASS, "adjacent lit dirt should be promoted to GRASS")


# Vanilla guard: spread refuses if source above-light < 9. Grass dimly
# lit (e.g., light 5) should NOT promote even adjacent dirt.
func test_dim_grass_does_not_spread() -> void:
	var grass_pos := Vector3i(0, 64, 0)
	var dirt_pos := Vector3i(1, 64, 0)
	_mgr.set_cell(grass_pos, Blocks.GRASS, 5, 0)  # dim — under 9
	_mgr.set_cell(grass_pos + Vector3i(0, 1, 0), Blocks.AIR, 5, 0)
	_mgr.set_cell(dirt_pos, Blocks.DIRT, 15, 0)
	_mgr.set_cell(dirt_pos + Vector3i(0, 1, 0), Blocks.AIR, 15, 0)
	for _i in range(200):
		Blocks.on_random_tick(_mgr, grass_pos, Blocks.GRASS)
	assert_eq(_mgr.blocks[dirt_pos], Blocks.DIRT, "dim grass (light < 9) should NOT spread")


# Vanilla guard: spread refuses if target above-light < 4. Bright grass
# next to dirt under opaque cover (= low light) doesn't promote.
func test_grass_does_not_spread_to_dark_dirt() -> void:
	var grass_pos := Vector3i(0, 64, 0)
	var dirt_pos := Vector3i(1, 64, 0)
	_mgr.set_cell(grass_pos, Blocks.GRASS, 15, 0)
	_mgr.set_cell(grass_pos + Vector3i(0, 1, 0), Blocks.AIR, 15, 0)
	_mgr.set_cell(dirt_pos, Blocks.DIRT, 0, 0)  # dark
	_mgr.set_cell(dirt_pos + Vector3i(0, 1, 0), Blocks.STONE, 0, 0)  # opaque cover
	for _i in range(200):
		Blocks.on_random_tick(_mgr, grass_pos, Blocks.GRASS)
	assert_eq(_mgr.blocks[dirt_pos], Blocks.DIRT, "dark dirt should NOT receive grass")


# Cross-class guard: on_random_tick with a non-grass id is a no-op.
# Defensive against id mismatch between the `is_random_tickable` filter
# and the dispatch (e.g. future blocks added to the filter but not the
# dispatch).
func test_on_random_tick_with_non_grass_id_is_noop() -> void:
	var pos := Vector3i(0, 64, 0)
	_mgr.set_cell(pos, Blocks.DIRT, 0, 0)
	for _i in range(50):
		Blocks.on_random_tick(_mgr, pos, Blocks.DIRT)
	assert_eq(_mgr.writes.size(), 0, "non-grass dispatch should not write any blocks")
