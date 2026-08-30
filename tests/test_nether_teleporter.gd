# gdlint: disable=max-public-methods
extends GutTest

# Portal coordinate scaling, destination search and construction
# (docs/nether-alpha-1.2.6-implementation-plan.md §7.2/§7.3, Batch 7).
#
# `no.java` does three things in order: look for an existing portal
# within 128, build one within 16 if there is none, then look again so
# arrival always goes through the same placement path.
#
# The search is an exhaustive scan whose ORDER is part of the contract —
# X ascending, then Z, then Y descending, keeping the smallest squared 3D
# distance and preferring the first cell at a tie. Players notice when
# that changes, because a portal appears to move.

const _OBSIDIAN := 11


class FakeWorld:
	extends Node

	var blocks: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id

	func count(id: int) -> int:
		var n: int = 0
		for key: Vector3i in blocks.keys():
			if blocks[key] == id:
				n += 1
		return n


func _new_world() -> FakeWorld:
	var w := FakeWorld.new()
	autofree(w)
	return w


# A lit portal sheet, two wide by three tall, at `origin`, running along X.
func _place_portal(w: FakeWorld, origin: Vector3i) -> void:
	for along: int in range(2):
		for up: int in range(3):
			w.set_world_block(origin + Vector3i(along, up, 0), Blocks.PORTAL)


# --- Coordinate scaling (§7.2) ---


func test_entering_the_nether_divides_by_eight() -> void:
	var scaled: Vector3 = NetherTeleporter.scale_position(
		Vector3(800.0, 70.0, 1600.0), DimensionContext.OVERWORLD, DimensionContext.NETHER
	)
	assert_eq(scaled.x, 100.0, "X divided by 8")
	assert_eq(scaled.z, 200.0, "Z divided by 8")
	assert_eq(scaled.y, 70.0, "Y is not scaled")


func test_returning_multiplies_by_eight() -> void:
	var scaled: Vector3 = NetherTeleporter.scale_position(
		Vector3(100.0, 70.0, 200.0), DimensionContext.NETHER, DimensionContext.OVERWORLD
	)
	assert_eq(scaled.x, 800.0, "X multiplied by 8")
	assert_eq(scaled.z, 1600.0, "Z multiplied by 8")


func test_negative_coordinates_use_floor_not_truncation() -> void:
	# The failure this guards: truncation sends both -7 and 7 to 0, which
	# folds a 16-block band of the Overworld onto one Nether column and
	# lands return trips in the wrong place on the negative side.
	var minus: Vector3 = NetherTeleporter.scale_position(
		Vector3(-7.0, 70.0, -1.0), DimensionContext.OVERWORLD, DimensionContext.NETHER
	)
	var plus: Vector3 = NetherTeleporter.scale_position(
		Vector3(7.0, 70.0, 1.0), DimensionContext.OVERWORLD, DimensionContext.NETHER
	)
	assert_eq(minus.x, -1.0, "-7 / 8 floors to -1")
	assert_eq(plus.x, 0.0, "7 / 8 floors to 0")
	assert_ne(minus.x, plus.x, "the two sides of zero stay distinct")


func test_scaling_is_monotonic_across_zero() -> void:
	var previous: float = -INF
	for x: int in range(-64, 65):
		var scaled: float = (
			NetherTeleporter
			. scale_position(
				Vector3(float(x), 70.0, 0.0), DimensionContext.OVERWORLD, DimensionContext.NETHER
			)
			. x
		)
		assert_true(scaled >= previous, "scaling never goes backwards at x=%d" % x)
		previous = scaled


func test_a_round_trip_lands_in_the_same_nether_column() -> void:
	# 8:1 is lossy by design — a round trip cannot return the exact block,
	# but it must return to the same Nether column it came from.
	for x: int in [-1000, -137, -8, -1, 0, 1, 8, 137, 1000]:
		var overworld := Vector3(float(x), 70.0, 0.0)
		var nether: Vector3 = NetherTeleporter.scale_position(
			overworld, DimensionContext.OVERWORLD, DimensionContext.NETHER
		)
		var back: Vector3 = NetherTeleporter.scale_position(
			nether, DimensionContext.NETHER, DimensionContext.OVERWORLD
		)
		var again: Vector3 = NetherTeleporter.scale_position(
			back, DimensionContext.OVERWORLD, DimensionContext.NETHER
		)
		assert_eq(again.x, nether.x, "x=%d returns to the same Nether column" % x)


# --- Finding an existing portal ---


func test_an_existing_portal_is_found() -> void:
	var w: FakeWorld = _new_world()
	_place_portal(w, Vector3i(10, 64, 10))
	var found: Variant = NetherTeleporter.find_portal(w, Vector3(10.5, 64.5, 10.5), 32)
	assert_not_null(found, "the portal was found")
	if found != null:
		assert_eq(found as Vector3i, Vector3i(10, 64, 10), "normalised to the bottom cell")


func test_the_search_returns_null_when_there_is_nothing() -> void:
	var w: FakeWorld = _new_world()
	assert_null(
		NetherTeleporter.find_portal(w, Vector3(0.0, 64.0, 0.0), 16), "empty world, no portal"
	)


func test_the_nearest_portal_wins_by_squared_distance() -> void:
	var w: FakeWorld = _new_world()
	_place_portal(w, Vector3i(20, 64, 0))
	_place_portal(w, Vector3i(5, 64, 0))
	var found: Variant = NetherTeleporter.find_portal(w, Vector3(0.5, 64.5, 0.5), 32)
	assert_not_null(found, "found one")
	if found != null:
		assert_eq((found as Vector3i).x, 5, "the closer portal wins")


func test_a_tie_is_broken_by_scan_order() -> void:
	# A real tie, built from the cell centres: searching from x = 0.5 makes
	# dx exactly equal to the cell's X, so the near columns of these two
	# portals (x = -5 and x = 5) are the same distance away. The scan runs X
	# ascending and keeps the FIRST at a tie, so the lower X wins.
	var w: FakeWorld = _new_world()
	_place_portal(w, Vector3i(-6, 64, 0))
	_place_portal(w, Vector3i(5, 64, 0))
	var found: Variant = NetherTeleporter.find_portal(w, Vector3(0.5, 64.5, 0.5), 32)
	assert_not_null(found, "found one")
	if found != null:
		assert_eq((found as Vector3i).x, -5, "the lower X wins the tie")


func test_the_search_normalises_to_the_bottom_of_a_column() -> void:
	var w: FakeWorld = _new_world()
	_place_portal(w, Vector3i(0, 60, 0))
	# Search from high above; the result must still be the bottom cell.
	var found: Variant = NetherTeleporter.find_portal(w, Vector3(0.5, 100.0, 0.5), 16)
	assert_not_null(found, "found")
	if found != null:
		assert_eq((found as Vector3i).y, 60, "bottom of the column, not the top")


func test_a_portal_outside_the_radius_is_not_found() -> void:
	var w: FakeWorld = _new_world()
	_place_portal(w, Vector3i(40, 64, 0))
	assert_null(
		NetherTeleporter.find_portal(w, Vector3(0.5, 64.5, 0.5), 8),
		"beyond the radius it does not exist"
	)
	assert_not_null(
		NetherTeleporter.find_portal(w, Vector3(0.5, 64.5, 0.5), 48),
		"but a wider radius reaches it"
	)


# --- Arrival placement ---


func test_arrival_sits_between_the_two_portal_columns() -> void:
	var w: FakeWorld = _new_world()
	_place_portal(w, Vector3i(0, 64, 0))
	var pos: Vector3 = NetherTeleporter.arrival_position(w, Vector3i(0, 64, 0))
	# The sheet runs along +X, so the arrival nudges half a block that way
	# and lands on the seam rather than inside a column.
	assert_eq(pos.x, 1.0, "nudged toward the partner column")
	assert_almost_eq(pos.y, 64.901, 0.001, "standing on the bottom cell")
	assert_eq(pos.z, 0.5, "centred across the sheet")


# --- Construction ---


func test_a_portal_is_built_when_none_exists() -> void:
	var w: FakeWorld = _new_world()
	# A solid floor to build on.
	for x: int in range(-24, 25):
		for z: int in range(-24, 25):
			w.set_world_block(Vector3i(x, 79, z), Blocks.NETHERRACK)
	var built: Vector3i = NetherTeleporter.create_portal(w, Vector3(0.0, 80.0, 0.0))
	assert_eq(w.count(Blocks.PORTAL), 6, "a 2x3 interior was lit")
	assert_gt(w.count(_OBSIDIAN), 0, "and a frame was raised")
	assert_not_null(
		NetherTeleporter.find_portal(w, Vector3(built.x, built.y, built.z), 32),
		"the built portal is findable"
	)


func test_the_built_frame_has_the_full_obsidian_ring() -> void:
	var w: FakeWorld = _new_world()
	for x: int in range(-8, 9):
		for z: int in range(-8, 9):
			w.set_world_block(Vector3i(x, 79, z), Blocks.NETHERRACK)
	NetherTeleporter.build_frame(w, Vector3i(0, 80, 0))
	var frame_cells: int = 0
	for along: int in range(-1, 3):
		for up: int in range(-1, 4):
			var is_frame: bool = along == -1 or along == 2 or up == -1 or up == 3
			var id: int = w.get_world_block(Vector3i(along, 80 + up, 0))
			if is_frame:
				assert_eq(id, _OBSIDIAN, "frame cell (%d, %d) is obsidian" % [along, up])
				frame_cells += 1
			else:
				assert_eq(id, Blocks.PORTAL, "interior cell (%d, %d) is portal" % [along, up])
	# 10 cells the validator tests (two 3-tall sides, two 2-wide edges) plus
	# the 4 corners it ignores. The teleporter builds the corners anyway —
	# they are optional to activation, but a player looking at a portal that
	# built itself expects a complete rectangle.
	assert_eq(frame_cells, 14, "the built ring includes its corners")


func test_a_built_portal_passes_the_frame_validator() -> void:
	# The strongest check on construction: what the teleporter builds must
	# be a frame the portal block itself considers valid, or it would
	# dissolve on the first neighbour update.
	var w: FakeWorld = _new_world()
	for x: int in range(-8, 9):
		for z: int in range(-8, 9):
			w.set_world_block(Vector3i(x, 79, z), Blocks.NETHERRACK)
	NetherTeleporter.build_frame(w, Vector3i(0, 80, 0))
	for along: int in range(2):
		for up: int in range(3):
			NetherPortal.on_neighbor_change(w, Vector3i(along, 80 + up, 0))
	assert_eq(w.count(Blocks.PORTAL), 6, "the built portal survives revalidation")


func test_a_low_altitude_site_beats_the_fallback_band() -> void:
	# Audit finding #4: the site search used to be confined to the
	# fallback band (70-118), so a perfectly good floor at the player's
	# actual altitude was invisible to it. A floor at Y 40 with the
	# arrival right there must produce a portal AT Y 41, not one lifted
	# into the band.
	var w: FakeWorld = _new_world()
	for x: int in range(-20, 21):
		for z: int in range(-20, 21):
			w.set_world_block(Vector3i(x, 40, z), Blocks.NETHERRACK)
	var built: Vector3i = NetherTeleporter.create_portal(w, Vector3(0.0, 41.0, 0.0))
	assert_eq(built.y, 41, "built on the low floor, not floated to 70")
	assert_eq(w.count(Blocks.PORTAL), 6, "and fully lit")


func test_an_overworld_return_lands_on_the_surface_not_in_the_sky() -> void:
	# The shape of the real bug: a return trip arrives at the player's
	# UNSCALED Nether Y — often 30-60, below the ~64 Overworld surface.
	# With the band restriction there was no valid site and the fallback
	# built a platform floating at Y 70; the full-column search finds the
	# surface instead.
	var w: FakeWorld = _new_world()
	for x: int in range(-20, 21):
		for z: int in range(-20, 21):
			w.set_world_block(Vector3i(x, 63, z), Blocks.NETHERRACK)
	var built: Vector3i = NetherTeleporter.create_portal(w, Vector3(0.0, 30.0, 0.0))
	assert_eq(built.y, 64, "the portal stands on the surface")
	# A fallback platform writes a 6x3 obsidian apron at base-1; a normal
	# build touches only the frame line. One cell OFF that line at floor
	# height still being the original ground is the proof no platform was
	# conjured.
	assert_eq(
		w.get_world_block(built + Vector3i(0, -1, 1)),
		Blocks.NETHERRACK,
		"the ground beside the frame is untouched — no conjured platform"
	)


func test_the_fallback_clamps_into_the_safe_band() -> void:
	# no.java:158-163. With nowhere suitable at all, the platform is
	# clamped to Y 70..118 so it is never in the bedrock floor or jammed
	# against the roof.
	var w: FakeWorld = _new_world()
	var built: Vector3i = NetherTeleporter.create_portal(w, Vector3(0.0, 5.0, 0.0))
	assert_between(
		built.y,
		NetherTeleporter.FALLBACK_MIN_Y,
		NetherTeleporter.FALLBACK_MAX_Y,
		"a too-low arrival is lifted into the band"
	)
	var high: Vector3i = NetherTeleporter.create_portal(_new_world(), Vector3(0.0, 126.0, 0.0))
	assert_between(
		high.y,
		NetherTeleporter.FALLBACK_MIN_Y,
		NetherTeleporter.FALLBACK_MAX_Y,
		"and a too-high one is brought down"
	)


func test_the_fallback_builds_a_platform_to_stand_on() -> void:
	var w: FakeWorld = _new_world()
	var built: Vector3i = NetherTeleporter.create_portal(w, Vector3(0.0, 5.0, 0.0))
	assert_eq(
		w.get_world_block(built + Vector3i(0, -1, 0)),
		_OBSIDIAN,
		"there is solid ground under the frame"
	)


func test_construction_works_at_negative_coordinates() -> void:
	var w: FakeWorld = _new_world()
	var built: Vector3i = NetherTeleporter.create_portal(w, Vector3(-500.0, 80.0, -900.0))
	assert_eq(w.count(Blocks.PORTAL), 6, "a portal was built out there too")
	assert_lt(built.x, 0, "at negative X")
	assert_lt(built.z, 0, "and negative Z")


# --- The whole destination routine ---


func test_destination_prefers_an_existing_portal_over_building() -> void:
	var w: FakeWorld = _new_world()
	_place_portal(w, Vector3i(4, 64, 0))
	var before: int = w.count(_OBSIDIAN)
	var pos: Vector3 = NetherTeleporter.destination_for(w, Vector3(0.5, 64.5, 0.5))
	assert_eq(w.count(_OBSIDIAN), before, "nothing new was built")
	assert_almost_eq(pos.y, 64.901, 0.001, "and the player lands at the existing portal")


func test_destination_builds_when_nothing_is_in_range() -> void:
	var w: FakeWorld = _new_world()
	var pos: Vector3 = NetherTeleporter.destination_for(w, Vector3(0.0, 80.0, 0.0))
	assert_eq(w.count(Blocks.PORTAL), 6, "a portal now exists")
	assert_between(pos.y, 1.0, 127.0, "and the arrival is inside the world")


func test_a_blocked_site_still_produces_a_portal() -> void:
	# Solid rock everywhere: no clear site exists, so the fallback has to
	# carve one rather than give up.
	var w: FakeWorld = _new_world()
	for x: int in range(-20, 21):
		for y: int in range(60, 100):
			for z: int in range(-4, 5):
				w.set_world_block(Vector3i(x, y, z), Blocks.NETHERRACK)
	var pos: Vector3 = NetherTeleporter.destination_for(w, Vector3(0.0, 80.0, 0.0))
	assert_eq(w.count(Blocks.PORTAL), 6, "a portal was carved out of solid rock")
	assert_between(pos.y, 1.0, 127.0, "with a usable arrival position")


func test_arrival_lands_the_capsule_above_the_floor_not_inside_it() -> void:
	# The paralysis bug: the player origin is the capsule CENTER
	# (half-height 0.9), so a cell.y + 0.5 landing sank the body 0.4 m
	# into the frame floor — unresolvable penetration, frozen in every
	# axis. The landing must clear the floor top by half height + skin.
	var w := FakeWorld.new()
	var base := Vector3i(0, 60, 0)
	NetherTeleporter.build_frame(w, base)
	var landing: Vector3 = NetherTeleporter.arrival_position(w, base)
	assert_almost_eq(landing.y, 60.901, 0.001, "origin = floor top + capsule half height + skin")
	assert_eq(landing.x, 1.0, "centered across the two-column doorway")
	assert_eq(landing.z, 0.5, "centered in the one-deep sheet")
