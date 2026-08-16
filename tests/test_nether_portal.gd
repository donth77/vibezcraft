# gdlint: disable=max-public-methods
extends GutTest

# Nether portal frame, activation, self-removal, exposure and texture
# (docs/nether-alpha-1.2.6-implementation-plan.md §7.1/§7.2, Batch 7).
#
# The frame rule is the part that gets misremembered, so it is tested
# exhaustively rather than by example. Alpha's validator walks a 4x5
# footprint and SKIPS the four corners:
#
#       .  #  #  .        . = corner, never tested
#       #  o  o  #        # = must be obsidian (10 cells)
#       #  o  o  #        o = interior, air or fire (2x3)
#       #  o  o  #
#       .  #  #  .
#
# Removal is per-cell, not a flood fill, which is why breaking one frame
# block cannot damage a second portal standing beside it.

const _OBSIDIAN := 11


# Minimal world double. The portal code only needs block get/set, and a
# real ChunkManager would drag in streaming, workers and a save path.
class FakeWorld:
	extends Node

	var blocks: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id

	func set_world_block_with_meta(pos: Vector3i, id: int, _meta: int) -> void:
		blocks[pos] = id

	func get_world_block_meta(_pos: Vector3i) -> int:
		return 0

	func count(id: int) -> int:
		var n: int = 0
		for key: Vector3i in blocks.keys():
			if blocks[key] == id:
				n += 1
		return n


# Build a complete valid frame with its lower-left interior cell at
# `origin`, running along `step`. Corners are left as AIR so every test
# starts from the minimal legal frame.
func _build_frame(world: FakeWorld, origin: Vector3i, step: Vector3i) -> void:
	for along: int in range(-1, 3):
		for up: int in range(-1, 4):
			var is_corner: bool = (along == -1 or along == 2) and (up == -1 or up == 3)
			if is_corner:
				continue
			var is_frame: bool = along == -1 or along == 2 or up == -1 or up == 3
			if is_frame:
				world.set_world_block(origin + step * along + Vector3i(0, up, 0), _OBSIDIAN)


func _new_world() -> FakeWorld:
	var w := FakeWorld.new()
	autofree(w)
	return w


# --- Frame validation ---


func test_a_complete_frame_lights_on_both_axes() -> void:
	for step: Vector3i in [Vector3i(1, 0, 0), Vector3i(0, 0, 1)]:
		var w: FakeWorld = _new_world()
		var origin := Vector3i(0, 64, 0)
		_build_frame(w, origin, step)
		assert_true(NetherPortal.try_create(w, origin), "frame along %s lights" % str(step))
		assert_eq(w.count(Blocks.PORTAL), 6, "and fills exactly the 2x3 interior")


func test_the_four_corners_are_never_tested() -> void:
	# The plan's headline frame fact. Corners may be obsidian, air, or
	# anything else; activation must not care.
	var step := Vector3i(1, 0, 0)
	var origin := Vector3i(0, 64, 0)
	for corner_fill: int in [Blocks.AIR, _OBSIDIAN, Blocks.STONE, Blocks.GLOWSTONE]:
		var w: FakeWorld = _new_world()
		_build_frame(w, origin, step)
		for along: int in [-1, 2]:
			for up: int in [-1, 3]:
				w.set_world_block(origin + step * along + Vector3i(0, up, 0), corner_fill)
		assert_true(
			NetherPortal.try_create(w, origin), "corners filled with %d still light" % corner_fill
		)


func test_every_required_frame_cell_is_load_bearing() -> void:
	# Exhaustive: knock out each of the ten non-corner frame cells in turn
	# and confirm the frame refuses to light. A validator that skipped one
	# would pass an example-based test.
	var step := Vector3i(1, 0, 0)
	var origin := Vector3i(0, 64, 0)
	var tested: int = 0
	for along: int in range(-1, 3):
		for up: int in range(-1, 4):
			var is_corner: bool = (along == -1 or along == 2) and (up == -1 or up == 3)
			var is_frame: bool = along == -1 or along == 2 or up == -1 or up == 3
			if is_corner or not is_frame:
				continue
			var w: FakeWorld = _new_world()
			_build_frame(w, origin, step)
			w.set_world_block(origin + step * along + Vector3i(0, up, 0), Blocks.AIR)
			assert_false(
				NetherPortal.try_create(w, origin),
				"removing frame cell (%d, %d) prevents lighting" % [along, up]
			)
			tested += 1
	assert_eq(tested, 10, "the frame has exactly ten required obsidian cells")


func test_a_blocked_interior_cell_prevents_lighting() -> void:
	var step := Vector3i(1, 0, 0)
	var origin := Vector3i(0, 64, 0)
	for along: int in range(2):
		for up: int in range(3):
			var w: FakeWorld = _new_world()
			_build_frame(w, origin, step)
			w.set_world_block(origin + step * along + Vector3i(0, up, 0), Blocks.STONE)
			assert_false(
				NetherPortal.try_create(w, origin),
				"a solid interior cell at (%d, %d) blocks activation" % [along, up]
			)


func test_fire_inside_the_frame_is_allowed() -> void:
	# Activation happens BECAUSE fire was placed, so the validator has to
	# accept fire in the interior as readily as air.
	var w: FakeWorld = _new_world()
	var origin := Vector3i(0, 64, 0)
	_build_frame(w, origin, Vector3i(1, 0, 0))
	w.set_world_block(origin, Blocks.FIRE)
	assert_true(NetherPortal.try_create(w, origin), "fire in the interior still lights")


func test_lighting_either_interior_column_works() -> void:
	# x.java normalises one step back along the axis when that cell is
	# air, so striking either column lights the same portal.
	var step := Vector3i(1, 0, 0)
	var origin := Vector3i(0, 64, 0)
	for column: int in range(2):
		var w: FakeWorld = _new_world()
		_build_frame(w, origin, step)
		assert_true(
			NetherPortal.try_create(w, origin + step * column), "lighting column %d works" % column
		)
		assert_eq(w.count(Blocks.PORTAL), 6, "and fills the same six cells")


func test_an_ambiguous_frame_is_refused() -> void:
	# Obsidian on both axes (or neither) leaves the orientation undefined.
	var w: FakeWorld = _new_world()
	var origin := Vector3i(0, 64, 0)
	_build_frame(w, origin, Vector3i(1, 0, 0))
	w.set_world_block(origin + Vector3i(0, 0, -1), _OBSIDIAN)
	w.set_world_block(origin + Vector3i(0, 0, 1), _OBSIDIAN)
	assert_eq(NetherPortal.frame_axis(w, origin), NetherPortal.AXIS_NONE, "axis is ambiguous")
	assert_false(NetherPortal.try_create(w, origin), "so nothing lights")


func test_bare_air_lights_nothing() -> void:
	var w: FakeWorld = _new_world()
	assert_false(NetherPortal.try_create(w, Vector3i(0, 64, 0)), "no frame, no portal")
	assert_eq(w.count(Blocks.PORTAL), 0, "and nothing was written")


# --- Self-removal ---


func test_breaking_a_frame_block_dissolves_the_portal() -> void:
	var w: FakeWorld = _new_world()
	var origin := Vector3i(0, 64, 0)
	var step := Vector3i(1, 0, 0)
	_build_frame(w, origin, step)
	NetherPortal.try_create(w, origin)
	assert_eq(w.count(Blocks.PORTAL), 6, "lit")
	# Knock out the block under the left column and propagate.
	w.set_world_block(origin + Vector3i(0, -1, 0), Blocks.AIR)
	_propagate_removal(w, origin, step)
	assert_eq(w.count(Blocks.PORTAL), 0, "the whole sheet went out")


func test_an_intact_portal_survives_a_neighbour_update() -> void:
	var w: FakeWorld = _new_world()
	var origin := Vector3i(0, 64, 0)
	var step := Vector3i(1, 0, 0)
	_build_frame(w, origin, step)
	NetherPortal.try_create(w, origin)
	_propagate_removal(w, origin, step)
	assert_eq(w.count(Blocks.PORTAL), 6, "nothing was removed from a valid frame")


func test_removal_does_not_damage_an_adjacent_portal() -> void:
	# The reason removal is per-cell rather than a flood fill. Two frames
	# side by side; breaking one must leave the other lit.
	var w: FakeWorld = _new_world()
	var step := Vector3i(1, 0, 0)
	var a := Vector3i(0, 64, 0)
	var b := Vector3i(0, 64, 8)
	_build_frame(w, a, step)
	_build_frame(w, b, step)
	NetherPortal.try_create(w, a)
	NetherPortal.try_create(w, b)
	assert_eq(w.count(Blocks.PORTAL), 12, "both lit")
	w.set_world_block(a + Vector3i(0, -1, 0), Blocks.AIR)
	_propagate_removal(w, a, step)
	assert_eq(w.count(Blocks.PORTAL), 6, "only the broken one went out")
	for up: int in range(3):
		for along: int in range(2):
			assert_eq(
				w.get_world_block(b + step * along + Vector3i(0, up, 0)),
				Blocks.PORTAL,
				"the untouched portal is intact"
			)


# Re-validate every cell until nothing changes, which is what the real
# block-update cascade does one neighbour at a time.
func _propagate_removal(w: FakeWorld, origin: Vector3i, step: Vector3i) -> void:
	for _pass: int in range(6):
		for along: int in range(2):
			for up: int in range(3):
				NetherPortal.on_neighbor_change(w, origin + step * along + Vector3i(0, up, 0))


# --- Block properties ---


func test_the_portal_block_has_no_collision_drop_or_selection() -> void:
	assert_false(Blocks.is_solid_collision(Blocks.PORTAL), "walk straight through")
	assert_eq(Blocks.selection_aabb(Blocks.PORTAL).size, Vector3.ZERO, "not targetable")
	assert_eq(Blocks.drops(Blocks.PORTAL), Blocks.AIR, "no drop")
	assert_false(Blocks.has_item_form(Blocks.PORTAL), "no item form")
	assert_eq(Blocks.light_emission(Blocks.PORTAL), 11, "emits 11")


func test_the_visual_slab_is_a_quarter_block_thick() -> void:
	# x.java:20-25 — 0.125 either side of centre.
	assert_almost_eq(NetherPortal.VISUAL_THICKNESS, 0.25, 1e-6, "0.125 * 2")


# --- Exposure (bq.java:33-57) ---


func test_continuous_exposure_travels_on_the_eighty_first_tick() -> void:
	# The nominal figure is 80 (1.0 / 0.0125) and that is what the plan
	# quotes, but 0.0125 is not exactly representable: eighty additions
	# land just short of 1.0, so the crossing happens on tick 81.
	var e := PortalExposure.new()
	e.in_portal = true
	for tick: int in range(PortalExposure.TICKS_TO_TRAVEL - 1):
		assert_false(e.advance(), "tick %d does not travel yet" % tick)
	assert_true(e.advance(), "tick %d travels" % PortalExposure.TICKS_TO_TRAVEL)


func test_the_trigger_fires_once_on_entry() -> void:
	var e := PortalExposure.new()
	e.in_portal = true
	e.advance()
	assert_true(e.triggered_this_tick, "the first tick inside triggers")
	e.advance()
	assert_false(e.triggered_this_tick, "and not again while still inside")


func test_leaving_drains_at_a_twentieth_per_tick() -> void:
	var e := PortalExposure.new()
	e.in_portal = true
	for _i: int in range(40):
		e.advance()
	var filled: float = e.exposure
	assert_almost_eq(filled, 40.0 * 0.0125, 1e-6, "half full after 40 ticks")
	e.in_portal = false
	e.advance()
	assert_almost_eq(e.exposure, filled - 0.05, 1e-6, "drains 0.05 per tick")


func test_a_full_meter_drains_in_twenty_ticks() -> void:
	var e := PortalExposure.new()
	e.in_portal = true
	for _i: int in range(PortalExposure.TICKS_TO_TRAVEL):
		e.advance()
	e.in_portal = false
	for _i: int in range(20):
		e.advance()
	assert_eq(e.exposure, 0.0, "empty after 20 ticks out")


func test_a_brief_pass_through_never_travels() -> void:
	# Walk in for ten ticks, out for ten, repeatedly. The 4:1 drain rate
	# means this can never accumulate to 1.
	var e := PortalExposure.new()
	for _cycle: int in range(20):
		e.in_portal = true
		for _i: int in range(10):
			assert_false(e.advance(), "a brief pass does not travel")
		e.in_portal = false
		for _i: int in range(10):
			assert_false(e.advance(), "and it drains back down")
	assert_eq(e.exposure, 0.0, "the meter ends empty")


func test_travel_starts_a_ten_tick_cooldown() -> void:
	var e := PortalExposure.new()
	e.in_portal = true
	for _i: int in range(PortalExposure.TICKS_TO_TRAVEL):
		e.advance()
	assert_true(e.travelled_this_tick, "travelled")
	# The travel tick itself decrements the cooldown once.
	assert_eq(e.cooldown, 9, "ten ticks, one already spent")
	for tick: int in range(9):
		assert_true(e.on_cooldown(), "still cooling at tick %d" % tick)
		e.in_portal = false
		e.advance()
	assert_false(e.on_cooldown(), "cooldown expired")


func test_reset_clears_everything() -> void:
	var e := PortalExposure.new()
	e.in_portal = true
	for _i: int in range(PortalExposure.TICKS_TO_TRAVEL):
		e.advance()
	e.reset()
	assert_eq(e.exposure, 0.0, "meter cleared")
	assert_eq(e.cooldown, 0, "cooldown cleared")
	assert_false(e.in_portal, "and the flag")


# --- Texture (et.java) ---


func test_the_texture_generator_produces_thirty_two_frames() -> void:
	PortalTexture.ensure_built()
	for i: int in range(PortalTexture.FRAMES):
		var img: Image = PortalTexture.frame_image(i)
		assert_eq(img.get_width(), 16, "frame %d is 16 wide" % i)
		assert_eq(img.get_height(), 16, "frame %d is 16 tall" % i)


func test_the_frames_are_deterministic() -> void:
	# `new Random(100L)` walked in a fixed order, so a rebuild must
	# reproduce the same bytes — that is what lets the plan ask for hashes.
	PortalTexture.ensure_built()
	var first: Array[String] = []
	for i: int in range(PortalTexture.FRAMES):
		first.append(PortalTexture.frame_hash(i))
	PortalTexture.reset()
	PortalTexture.ensure_built()
	for i: int in range(PortalTexture.FRAMES):
		assert_eq(PortalTexture.frame_hash(i), first[i], "frame %d rebuilds identically" % i)


func test_the_frames_differ_from_each_other() -> void:
	# An animation whose frames are all the same is a still image.
	PortalTexture.ensure_built()
	var seen: Dictionary = {}
	for i: int in range(PortalTexture.FRAMES):
		seen[PortalTexture.frame_hash(i)] = true
	assert_eq(seen.size(), PortalTexture.FRAMES, "all 32 frames are distinct")


func test_the_animation_advances_one_frame_per_tick_and_wraps() -> void:
	assert_eq(PortalTexture.frame_at(0.0), 0, "starts at frame 0")
	assert_eq(PortalTexture.frame_at(PortalTexture.FRAME_SECONDS * 5.0), 5, "one frame per tick")
	assert_eq(PortalTexture.frame_at(PortalTexture.FRAME_SECONDS * 32.0), 0, "wraps after 32")
	assert_eq(PortalTexture.frame_at(PortalTexture.FRAME_SECONDS * 33.0), 1, "and keeps going")


func test_the_texture_set_is_shared_not_per_block() -> void:
	# The plan forbids a material or texture per portal block.
	PortalTexture.ensure_built()
	assert_same(
		PortalTexture.frame_texture(3),
		PortalTexture.frame_texture(3),
		"the same frame returns the same texture instance"
	)


func test_the_portal_reads_purple() -> void:
	# Sanity on the channel order: et.java writes blue highest, green
	# lowest. Getting the order wrong yields a green portal that still
	# hashes deterministically.
	PortalTexture.ensure_built()
	var img: Image = PortalTexture.frame_image(0)
	var blue_total: int = 0
	var green_total: int = 0
	for x: int in range(16):
		for y: int in range(16):
			var c: Color = img.get_pixel(x, y)
			blue_total += int(c.b * 255.0)
			green_total += int(c.g * 255.0)
	assert_gt(blue_total, green_total, "blue dominates green — the portal is purple")
