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


func test_the_portal_block_has_no_collision_or_drop_but_can_be_ray_traced() -> void:
	assert_false(Blocks.is_solid_collision(Blocks.PORTAL), "walk straight through")
	assert_eq(Blocks.collision_aabb(Blocks.PORTAL).size, Vector3.ZERO, "no entity collision")
	assert_eq(
		Blocks.selection_aabb(Blocks.PORTAL).size,
		Vector3(0.25, 1.0, 1.0),
		"x.java fallback ray bounds are a quarter-block slab"
	)
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
	# bq.java counts the cooldown down only while OUTSIDE, so the travel
	# tick — which is an in-portal tick — does not spend one of the ten.
	assert_eq(e.cooldown, PortalExposure.COOLDOWN_TICKS, "full ten ticks banked")
	for tick: int in range(PortalExposure.COOLDOWN_TICKS):
		assert_true(e.on_cooldown(), "still cooling at tick %d" % tick)
		e.in_portal = false
		e.advance()
	assert_false(e.on_cooldown(), "cooldown expired once outside")


# The arrival case, and the one the old cooldown test never covered: it
# always stepped the player OUT while counting down. A player arrives
# standing IN the destination portal, so if the cooldown drained under
# their feet the meter would refill and send them straight back — the
# enter/leave loop reported from a real save, where the player was found
# parked inside the Nether portal cell.
func test_standing_in_the_arrival_portal_never_bounces_back() -> void:
	var e := PortalExposure.new()
	e.in_portal = true
	for _i: int in range(PortalExposure.TICKS_TO_TRAVEL):
		e.advance()
	assert_true(e.travelled_this_tick, "first travel happened")
	# Never leave the portal. Far longer than the cooldown, and longer
	# than a second full fill would take.
	for tick: int in range(PortalExposure.TICKS_TO_TRAVEL * 2):
		e.in_portal = true
		assert_false(e.advance(), "no re-travel while still inside (tick %d)" % tick)
	assert_true(e.on_cooldown(), "cooldown is refreshed, not counted down, while inside")
	# bq.java — during the refreshed cooldown the entity ticks as
	# OUTSIDE, so the meter drains: the purple fades even while the
	# player stands in the arrival portal, and it must never refill
	# underfoot.
	assert_eq(e.exposure, 0.0, "meter drains to empty; it must not refill underfoot")
	# Stepping out finally releases it.
	for _i: int in range(PortalExposure.COOLDOWN_TICKS):
		e.in_portal = false
		e.advance()
	assert_false(e.on_cooldown(), "leaving the portal lets the cooldown expire")


func test_arrival_state_standing_inside_never_re_travels() -> void:
	# The field loop, replayed on the exact arrival state PortalTravel
	# leaves behind: meter at 1.0 (purple fade-out) plus a live cooldown,
	# player standing in the destination portal. 400 ticks (20 s) of
	# standing still must produce zero travels, the purple must fade, and
	# stepping out then back in must take the normal 81-tick fill.
	var e := PortalExposure.new()
	e.exposure = 1.0
	e.cooldown = PortalExposure.COOLDOWN_TICKS
	for tick: int in range(400):
		e.in_portal = true
		assert_false(e.advance(), "no bounce-back while standing inside (tick %d)" % tick)
	assert_eq(e.exposure, 0.0, "overlay fully faded while standing inside")
	assert_true(e.on_cooldown(), "cooldown still armed until the player steps out")
	for _i: int in range(PortalExposure.COOLDOWN_TICKS):
		e.in_portal = false
		e.advance()
	assert_false(e.on_cooldown(), "stepping out releases the cooldown")
	var travelled_on: int = -1
	for tick: int in range(PortalExposure.TICKS_TO_TRAVEL + 5):
		e.in_portal = true
		if e.advance():
			travelled_on = tick + 1
			break
	assert_eq(travelled_on, PortalExposure.TICKS_TO_TRAVEL, "deliberate re-entry travels normally")


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


# --- which bottom-row cells can actually be lit -------------------------
# A 4x5 frame has FOUR blocks in its bottom row, but only the middle two
# sit under the 2x3 interior. The outer two are CORNERS, and the cell above
# a corner is the frame's own side column — so the ignition target is not
# air and interaction._try_flint_and_steel bails before BlockFire.place
# ever runs. Silent no-op: no fire, no portal, and (until now) no sound.
#
# Note _build_frame above deliberately omits corners, which is legitimate
# for validation tests — activation ignores corner contents — but it means
# no existing test ever modelled the frame a player actually builds. That
# is why this reached a real save as "the portal is broken" when both
# frames were valid and try_create succeeded on them: half the bottom row a
# player naturally clicks is a dead target.


# Same 4x5 frame, but WITH the four corners a player lays down.
func _build_frame_with_corners(world: FakeWorld, origin: Vector3i, step: Vector3i) -> void:
	_build_frame(world, origin, step)
	for along: int in [-1, 2]:
		for up: int in [-1, 3]:
			world.set_world_block(origin + step * along + Vector3i(0, up, 0), _OBSIDIAN)


# The ignition rule from interaction._try_flint_and_steel: fire lands in
# block_pos + normal, and the attempt is abandoned unless that cell is air.
func _ignition_target_is_air(world: FakeWorld, clicked: Vector3i) -> bool:
	return world.get_world_block(clicked + Vector3i(0, 1, 0)) == Blocks.AIR


func test_frame_corners_are_dead_ignition_targets() -> void:
	var world: FakeWorld = _new_world()
	var origin := Vector3i(0, 64, 0)
	var step := Vector3i(1, 0, 0)
	_build_frame_with_corners(world, origin, step)
	for along: int in [-1, 2]:
		var clicked: Vector3i = origin + step * along + Vector3i(0, -1, 0)
		assert_false(
			_ignition_target_is_air(world, clicked),
			"top face of bottom-row corner aims at the side column, not the interior"
		)


func test_bottom_row_middle_cells_light_the_portal() -> void:
	for along: int in [0, 1]:
		var world: FakeWorld = _new_world()
		var origin := Vector3i(0, 64, 0)
		var step := Vector3i(1, 0, 0)
		_build_frame_with_corners(world, origin, step)
		var clicked: Vector3i = origin + step * along + Vector3i(0, -1, 0)
		assert_true(_ignition_target_is_air(world, clicked), "middle cell targets air")
		assert_true(
			BlockFire.place(world, clicked + Vector3i(0, 1, 0)),
			"lighting above a middle bottom-row cell creates a portal, not fire"
		)
		assert_eq(world.count(Blocks.PORTAL), 6, "the 2x3 interior fills with portal")
		assert_eq(world.count(Blocks.FIRE), 0, "no stray fire left in the frame")


# --- the arrival site must hold the whole frame -------------------------
# build_frame lays its bottom row across `along -1..2`, but _site_is_clear
# used to verify support under the BASE COLUMN only. A ledge whose edge fell
# away one block later therefore passed, and the Nether portal was built
# with a floor under half its width — reproduced from a real save, where the
# frame spanned x -5..-2 above ground that stopped at x -4.


func _clear_pocket(world: FakeWorld, base: Vector3i) -> void:
	# Everything the site check wants to be air.
	for along: int in range(-1, 3):
		for up: int in range(0, 5):
			for across: int in range(0, 2):
				world.set_world_block(base + Vector3i(along, up, across), Blocks.AIR)


func test_a_ledge_under_only_the_base_column_is_rejected() -> void:
	var world: FakeWorld = _new_world()
	var base := Vector3i(0, 60, 0)
	_clear_pocket(world, base)
	# Ground under the base column only — the other three overhang.
	world.set_world_block(base + Vector3i(0, -1, 0), Blocks.NETHERRACK)
	assert_false(
		NetherTeleporter._site_is_clear(world, base),
		"a site that cannot hold the whole bottom row is not a valid site"
	)


func test_ground_under_the_full_bottom_row_is_accepted() -> void:
	var world: FakeWorld = _new_world()
	var base := Vector3i(0, 60, 0)
	_clear_pocket(world, base)
	for along: int in range(-1, 3):
		world.set_world_block(base + Vector3i(along, -1, 0), Blocks.NETHERRACK)
	assert_true(
		NetherTeleporter._site_is_clear(world, base), "fully supported ground is a valid site"
	)


# A world that can answer residency, so create_portal takes the same
# has_chunk_at path the real ChunkManager does. Chunks are resident unless
# explicitly withheld.
class ResidencyWorld:
	extends FakeWorld

	var absent_chunks: Dictionary = {}

	func has_chunk_at(world_x: int, world_z: int) -> bool:
		return not absent_chunks.has(
			Vector2i(int(floor(world_x / 16.0)), int(floor(world_z / 16.0)))
		)


func test_a_site_straddling_an_unloaded_chunk_is_rejected() -> void:
	# The frame runs base.x-1 .. base.x+2, so a base two blocks from the
	# edge reaches into the next chunk. Writes there are dropped silently by
	# the real ChunkManager, which loses part of the frame — floor included.
	var world := ResidencyWorld.new()
	autofree(world)
	world.absent_chunks[Vector2i(1, 0)] = true
	assert_false(
		NetherTeleporter._footprint_is_resident(world, 14, 0),
		"a footprint reaching into an unloaded chunk is not buildable"
	)
	assert_true(
		NetherTeleporter._footprint_is_resident(world, 8, 0),
		"a footprint wholly inside a resident chunk is buildable"
	)


func test_created_portals_always_get_a_full_width_floor() -> void:
	# End to end: whatever site create_portal picks, every column of the
	# frame's bottom row must end up solid. This is the invariant the real
	# save violated — frame across x -5..-2 over ground that stopped at -4.
	var world := ResidencyWorld.new()
	autofree(world)
	# A ledge: solid only for x <= 0, open air beyond, across the band the
	# search will consider.
	for x: int in range(-40, 41):
		for z: int in range(-40, 41):
			if x <= 0:
				world.set_world_block(Vector3i(x, 59, z), Blocks.NETHERRACK)
	var base: Vector3i = NetherTeleporter.create_portal(world, Vector3(0.5, 60.5, 0.5))
	for along: int in range(-1, 3):
		var under: Vector3i = base + Vector3i(along, -1, 0)
		assert_true(
			Blocks.is_solid_collision(world.get_world_block(under)),
			"bottom row column %d rests on something solid (at %s)" % [along, under]
		)


func test_portal_survives_mining_but_not_explosions() -> void:
	# Two different axes, and vanilla splits them:
	#   * hardness -1.0 (nq.java:113 `.c(-1.0f)`) — the unbreakable
	#     sentinel, so the sheet is never mined out;
	#   * blast resistance 0 — because setHardness only RAISES resistance
	#     when `resistance < hardness * 5`, and -1 never satisfies that,
	#     so the portal keeps the 0 default.
	# That combination is why a ghast fireball really does erase the
	# sheet from inside an intact obsidian frame (frame resistance 2000
	# survives), and relighting is the vanilla remedy.
	assert_eq(Blocks.hardness(Blocks.PORTAL), -1.0, "unbreakable sentinel, per nq.java:113")
	assert_eq(Blocks.explosion_resistance(Blocks.PORTAL), 0.0, "blast resistance is the 0 default")
	assert_gt(
		Blocks.explosion_resistance(Blocks.OBSIDIAN),
		Blocks.explosion_resistance(Blocks.PORTAL),
		"the frame outlasts the sheet, which is what the player sees"
	)
	# The blast ray subtracts `(resistance + 0.3) * coeff`; a negative
	# term would make a blast STRONGER for crossing a cell.
	assert_gte(Blocks.explosion_resistance(Blocks.PORTAL) + 0.3, 0.0, "ray term stays positive")
	# Entity collision and ray tracing are distinct. x.java returns null for
	# the former but sets thin bounds for the latter; hardness is what blocks
	# mining once the ray has targeted the sheet.
	assert_eq(
		Blocks.selection_aabb(Blocks.PORTAL).size,
		Vector3(0.25, 1.0, 1.0),
		"targetable, while hardness still makes it unmineable"
	)
