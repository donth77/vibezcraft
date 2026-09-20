# gdlint: disable=max-public-methods
# gdlint: disable=max-file-lines
extends GutTest

# Field report #9 (github.com/donth77/vibezcraft/issues/9). Same shape as
# test_issue_8_regressions: one file per report, because these are
# unrelated defects that share a reporter, and a re-test of the issue
# should be one run. Each test names the symptom the reporter described.

const _MINECART_SCRIPT: GDScript = preload("res://scripts/entities/minecart.gd")
const _DROPPED_ITEM_SCRIPT: GDScript = preload("res://scripts/world/dropped_item.gd")
const _INTERACTION_SCRIPT: GDScript = preload("res://scripts/player/interaction.gd")
const _SFX_SCRIPT: GDScript = preload("res://scripts/audio/sfx.gd")
const _CHUNK_MANAGER_SCRIPT: GDScript = preload("res://scripts/world/chunk_manager.gd")
const _FURNACE_SCREEN_SCRIPT: GDScript = preload("res://scripts/ui/furnace_screen.gd")

const _FLOOR_Y: int = 63


# Minimal voxel world as a Node — entities type their manager reference as
# `Node`, so a RefCounted assigned to one is silently dropped.
class VoxelWorldNode:
	extends Node3D
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var drops: Array = []

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block(pos: Vector3i, id: int, meta: int = -1) -> bool:
		blocks[pos] = id
		metas[pos] = 0 if meta < 0 else (meta & 0xF)
		return true

	func set_world_block_with_meta(pos: Vector3i, id: int, meta: int) -> bool:
		blocks[pos] = id
		metas[pos] = meta & 0xF
		return true

	func set_world_block_state(pos: Vector3i, id: int, meta: int) -> bool:
		blocks[pos] = id
		metas[pos] = meta & 0xF
		return true

	func spawn_block_drop(pos: Vector3i, dropped_id: int) -> void:
		drops.append([pos, dropped_id])

	func get_chunk_at_coord(_coord: Vector2i):
		return null

	func get_world_sky_light(_pos: Vector3i) -> int:
		return 15

	func get_world_block_light(_pos: Vector3i) -> int:
		return 0

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _dimension_was: int = 0


func before_each() -> void:
	_dimension_was = DimensionContext.active()
	DimensionContext.set_active(DimensionContext.OVERWORLD)


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)


func _cart_on(world: Node3D, cell: Vector3i, meta: int) -> CharacterBody3D:
	var cart: CharacterBody3D = _MINECART_SCRIPT.new()
	add_child_autofree(cart)
	cart.set("_chunk_manager", world)
	world.put(cell, Blocks.RAIL, meta)
	return cart


# --- "when driving a minecart and you turn on rails, it has a weird
#      rotation instead of the proper one expected" ---


# The cart is snapped onto a quarter-circle arc and its velocity projected
# onto the arc tangent, but the model's yaw came from whichever CARDINAL
# axis had the larger velocity component. Three failures in one: the hull
# sat up to 45 degrees off the track through the corner, it snapped a full
# 90 degrees the instant |vx| and |vz| swapped dominance, and a parked cart
# (both components zero) fell through to due north on every curve.
func test_curve_rail_axis_follows_the_arc_not_a_cardinal() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var cell := Vector3i(0, _FLOOR_Y, 0)
	var cart: CharacterBody3D = _cart_on(world, cell, 6)
	# Meta 6 wraps the SE corner (1, 1). Park the cart at the arc's
	# midpoint, 45 degrees round from that corner.
	var d: float = sqrt(0.5) * 0.5
	cart.global_position = Vector3(1.0 - d, float(_FLOOR_Y) + 1.0 / 16.0, 1.0 - d)
	cart.velocity = Vector3.ZERO
	var axis: Vector3 = cart.call("_rail_axis_for", 6, cell)
	assert_almost_eq(axis.length(), 1.0, 1e-4, "unit tangent")
	# At the arc midpoint the tangent is the 45-degree diagonal, so neither
	# component may dominate — a cardinal answer is what the bug looked like.
	assert_almost_eq(
		absf(axis.x), absf(axis.z), 1e-4, "diagonal at the midpoint, not a cardinal snap"
	)
	# Perpendicular to the radius, which is what "tangent" means here.
	var radius := Vector2(cart.global_position.x - 1.0, cart.global_position.z - 1.0)
	assert_almost_eq(
		axis.x * radius.x + axis.z * radius.y, 0.0, 1e-4, "tangent is normal to the radius"
	)


# A stationary cart used to read `absf(velocity.x) > absf(velocity.z)` as
# false and return (0, 0, 1) — due north — for every one of the four curve
# metas. That is the screenshot in the report: an axis-aligned cart sitting
# on a bend.
func test_a_parked_cart_faces_a_different_way_on_each_curve() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var seen: Array[Vector3] = []
	for meta: int in [6, 7, 8, 9]:
		var cell := Vector3i(meta, _FLOOR_Y, 0)
		var cart: CharacterBody3D = _cart_on(world, cell, meta)
		# Same spot inside each cell, so only the curve's corner differs.
		cart.global_position = Vector3(float(meta) + 0.5, float(_FLOOR_Y), 0.25)
		cart.velocity = Vector3.ZERO
		seen.append(cart.call("_rail_axis_for", meta, cell))
	for i: int in range(seen.size()):
		for j: int in range(i + 1, seen.size()):
			# Tangent lines are undirected, so opposite vectors are the same
			# heading. Compare |dot| against 1.
			var parallel: float = absf(seen[i].dot(seen[j]))
			assert_lt(parallel, 0.999, "curve %d and %d get different headings" % [i, j])


# Integration cover for the unit tests above: drive a cart through a whole
# curve cell and check the hull actually points where it is travelling.
#
# The rate limiter that smooths yaw between straight rails must not apply
# here. An arc tangent varies continuously and meets its neighbouring
# straights head-on, so there is no step to smooth — and at the 8 m/s cap
# the arc turns at v/r = 16 rad/s against a 10 rad/s limit, which measured
# as 35 degrees of sustained lag before this was fixed. What is left is one
# frame of it: the yaw is derived before the tick's move is applied, so at
# top speed it trails by 8/60/0.5 = 15.3 degrees and no more.
func test_the_hull_points_along_a_curve_at_full_speed() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var cell := Vector3i(0, _FLOOR_Y, 0)
	world.put(cell, Blocks.RAIL, 6)
	world.put(Vector3i(0, _FLOOR_Y, 1), Blocks.RAIL, 0)
	world.put(Vector3i(1, _FLOOR_Y, 0), Blocks.RAIL, 1)
	var cart: CharacterBody3D = _MINECART_SCRIPT.new()
	add_child_autofree(cart)
	cart.set("_chunk_manager", world)
	cart.global_position = Vector3(0.5, float(_FLOOR_Y) + 1.0 / 16.0, 1.5)
	# MAX_HORIZ_PER_AXIS — the worst case the rate limiter used to lose.
	cart.velocity = Vector3(0.0, 0.0, -float(_MINECART_SCRIPT.MAX_HORIZ_PER_AXIS))
	var worst: float = 0.0
	var ticks_on_curve: int = 0
	for _i: int in range(120):
		cart.call("_physics_process", 1.0 / 60.0)
		var info: Dictionary = cart.call("_find_rail_under_cart")
		if info.is_empty() or info.get("cell") != cell:
			continue
		ticks_on_curve += 1
		var tangent: Vector3 = cart.call("_curve_tangent", cell, 6)
		var heading := Vector3(-sin(cart.rotation.y), 0.0, -cos(cart.rotation.y))
		# The tangent is a line, not a ray — either sense is "aligned".
		worst = maxf(worst, acos(clampf(absf(heading.dot(tangent)), 0.0, 1.0)))
	assert_gt(ticks_on_curve, 3, "premise: the cart really did traverse the curve")
	assert_lt(rad_to_deg(worst), 20.0, "hull tracks the arc (worst %.1f deg)" % rad_to_deg(worst))


# --- "also doesn't turn at angles in model" ---


# _rail_axis_for has always returned a pitched vector for the ascending
# metas — meta 2 is (2, 1, 0).normalised() — but the yaw block only ever
# read .x and .z through atan2, so the Y was computed and thrown away and
# a cart climbed a ramp dead level.
func test_ascending_rails_pitch_the_hull() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var cell := Vector3i(0, _FLOOR_Y, 0)
	var cart: CharacterBody3D = _cart_on(world, cell, 2)
	var axis: Vector3 = cart.call("_rail_axis_for", 2, cell)
	assert_gt(axis.y, 0.0, "the climbing rail has a rise to follow")
	# rise/run of 1/2 — a half-block climb across one cell.
	assert_almost_eq(axis.y, 1.0 / sqrt(5.0), 1e-4, "(2, 1, 0) normalised")


# A positive rotation.x tilts local -Z (forward) up, so the nose rises when
# the cart faces uphill and drops when it faces the same rail downhill.
func test_slope_pitch_flips_with_the_direction_of_travel() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var cell := Vector3i(0, _FLOOR_Y, 0)
	var cart: CharacterBody3D = _cart_on(world, cell, 2)
	cart.global_position = Vector3(0.5, float(_FLOOR_Y), 0.5)
	var axis: Vector3 = cart.call("_rail_axis_for", 2, cell)
	var uphill: float = asin(axis.y)
	assert_gt(uphill, 0.0, "facing up the ramp raises the nose")
	assert_almost_eq(asin(-axis.y), -uphill, 1e-6, "facing the other way drops it")


# The slope pitch and the damage rock share _visual_root.rotation.x. They
# have to sum: a cart taking a hit halfway up a ramp used to snap level for
# the length of the rock and then snap back.
func test_slope_pitch_and_damage_rock_share_the_axis() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var cart: CharacterBody3D = _cart_on(world, Vector3i(0, _FLOOR_Y, 0), 2)
	var visual: Node3D = cart.get("_visual_root")
	assert_not_null(visual, "the cart built its visual root")
	if visual == null:
		return
	cart.set("_slope_pitch", 0.3)
	cart.set("_damage_rock", 0.0)
	cart.call("_update_damage_rock", 1.0 / 60.0)
	assert_almost_eq(visual.rotation.x, 0.3, 1e-4, "slope alone")
	cart.set("_slope_pitch", 0.3)
	cart.set("_damage_rock", 1.0)
	cart.call("_update_damage_rock", 0.0)
	assert_almost_eq(visual.rotation.x, 0.3 + 0.4, 1e-4, "slope plus rock, not one or other")


# The old degenerate branch read `0.5 - 2 * corner` and then divided by the
# un-recomputed near-zero distance, which would have thrown the cart
# hundreds of blocks if anything ever landed within a millimetre of the
# wrap corner.
func test_a_cart_exactly_on_the_wrap_corner_stays_in_its_cell() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var cell := Vector3i(0, _FLOOR_Y, 0)
	var cart: CharacterBody3D = _cart_on(world, cell, 6)
	# Meta 6 wraps (1, 1) — sit exactly on it.
	cart.global_position = Vector3(1.0, float(_FLOOR_Y) + 1.0 / 16.0, 1.0)
	cart.velocity = Vector3.ZERO
	cart.call("_apply_curve_physics", cell, 6)
	var radius: float = Vector2(cart.global_position.x - 1.0, cart.global_position.z - 1.0).length()
	assert_almost_eq(radius, 0.5, 1e-4, "snapped onto the arc, not flung off it")


# --- "putting something into the furnace still leaves the icon in the
#      hotbar ... creating a ghost icon" ---


# Every slot handler on the furnace screen writes inventory.slots in place.
# Repainting its own panels is not enough: the hotbar, the held item, the
# armour bar and the pumpkin overlay all redraw off Inventory.changed and
# nothing else. Every sibling container screen already emits it.
func test_furnace_screen_emits_inventory_changed_on_every_transfer() -> void:
	var source: String = _FURNACE_SCREEN_SCRIPT.source_code
	for handler: String in ["_handle_left_click", "_handle_right_click", "_take_output"]:
		assert_true(source.contains(handler), "premise: %s is still the handler name" % handler)
	assert_true(source.contains("func _commit()"), "the commit helper exists")
	assert_true(
		source.contains("inventory.changed.emit()"),
		"and it notifies the rest of the UI, not just this screen"
	)
	# The bare `_refresh()` tail is what left the hotbar stale — each
	# handler has to route through _commit instead.
	var commits: int = source.count("\t_commit()")
	assert_eq(commits, 3, "all three mutating handlers commit (got %d)" % commits)


# --- "I could place redstone in the same place that redstone was already
#      placed which bugged out the redstone" ---


# Off the tree deliberately: interaction's _ready wires scene children that
# do not exist here, and none of the placement logic under test needs them.
func _interaction_with(world: Node3D) -> Node:
	var interaction: Node = _INTERACTION_SCRIPT.new()
	autofree(interaction)
	interaction.set("_chunk_manager", world)
	return interaction


# Wire is in Blocks.is_replaceable so FLUIDS can wash it away, not to
# invite building into it. Routing placement through that predicate let
# dust land on a cell that already held dust: one redstone burned, a
# duplicate dropped on the floor, and — the part that actually hurt — the
# cell rewritten with meta 0, wiping the wire's power level.
#
# Vanilla ey.java is blunt about it: `if (cy2.a(n2,n3,n4) != 0) return false`.
func test_redstone_dust_will_not_place_into_a_cell_that_already_has_wire() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var interaction: Node = _interaction_with(world)
	var support := Vector3i(0, _FLOOR_Y, 0)
	var wire_cell := Vector3i(0, _FLOOR_Y + 1, 0)
	world.put(support, Blocks.STONE)
	# A live wire carrying power, and a wall beside it whose exposed face
	# points straight at the wire's cell — the aim the reporter found.
	world.put(wire_cell, Blocks.REDSTONE_WIRE, 9)
	world.put(Vector3i(-1, _FLOOR_Y + 1, 0), Blocks.STONE)
	var hit: Dictionary = {
		"block_pos": Vector3i(-1, _FLOOR_Y + 1, 0),
		"normal_i": Vector3i(1, 0, 0),
	}
	assert_false(
		bool(interaction.call("_try_place_redstone_dust", hit)), "placement is refused outright"
	)
	assert_eq(world.get_world_block(wire_cell), Blocks.REDSTONE_WIRE, "the wire survives")
	assert_eq(world.get_world_block_meta(wire_cell), 9, "and keeps its power level")
	assert_eq(world.drops.size(), 0, "no phantom duplicate on the floor")


# The strict-air rule is vanilla's, not a patch over the symptom: dust does
# not displace water or a flower either. Both would be washed out or broken
# a tick later anyway.
func test_redstone_dust_needs_exactly_air_like_vanilla() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var interaction: Node = _interaction_with(world)
	var support := Vector3i(0, _FLOOR_Y, 0)
	var target := Vector3i(0, _FLOOR_Y + 1, 0)
	world.put(support, Blocks.STONE)
	var hit: Dictionary = {"block_pos": support, "normal_i": Vector3i(0, 1, 0)}
	for occupant: int in [Blocks.WATER_STILL, Blocks.FLOWER_RED, Blocks.STONE]:
		world.put(target, occupant)
		assert_false(
			bool(interaction.call("_try_place_redstone_dust", hit)),
			"refused onto block id %d" % occupant
		)
	# Air is the one case that works.
	world.put(target, Blocks.AIR)
	assert_true(bool(interaction.call("_try_place_redstone_dust", hit)), "air accepts wire")
	assert_eq(world.get_world_block(target), Blocks.REDSTONE_WIRE)


# Both repeater states sit in is_replaceable for the same fluid reason, so
# the same self-replace hole was open: the item burned and the delay and
# facing the player had just set were reset.
func test_a_repeater_will_not_place_into_another_repeater() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var interaction: Node = _interaction_with(world)
	world.put(Vector3i(0, _FLOOR_Y, 0), Blocks.STONE)
	world.put(Vector3i(-1, _FLOOR_Y + 1, 0), Blocks.STONE)
	var cell := Vector3i(0, _FLOOR_Y + 1, 0)
	var hit: Dictionary = {
		"block_pos": Vector3i(-1, _FLOOR_Y + 1, 0),
		"normal_i": Vector3i(1, 0, 0),
	}
	for state: int in [Blocks.REDSTONE_REPEATER_OFF, Blocks.REDSTONE_REPEATER_ON]:
		world.put(cell, state, 6)
		assert_false(
			bool(interaction.call("_try_place_redstone_repeater", hit)),
			"refused onto repeater state %d" % state
		)
		assert_eq(world.get_world_block_meta(cell), 6, "facing and delay untouched")


# --- "it's also super loud when it explodes" ---


# Vanilla's 4.0 volume argument is not a gain. qg.java:156-166 multiplies
# the ATTENUATION RADIUS by it and then clamps the gain to unity, so an
# explosion is exactly as loud at the source as anything else and simply
# carries four times as far. Reading it as "+6 dB, non-positional" made a
# creeper sixty blocks away twice as loud as a block break underfoot.
func test_explosions_are_unity_gain_at_four_times_the_range() -> void:
	assert_eq(SFX.EXPLODE_SOUND_MAX_DISTANCE, 64.0, "16 x 4, per qg.java's f7 *= f5")
	assert_eq(
		SFX.EXPLODE_SOUND_MAX_DISTANCE,
		SFX.MOB_SOUND_MAX_DISTANCE * 4.0,
		"four times the ordinary 16 m sound radius"
	)
	# The rolloff keeps its shape: same unit_size-to-range ratio the mob
	# pool uses, so it is unity near the source and then falls away.
	assert_almost_eq(
		SFX.EXPLODE_SOUND_UNIT_SIZE / SFX.EXPLODE_SOUND_MAX_DISTANCE,
		SFX.MOB_SOUND_UNIT_SIZE / SFX.MOB_SOUND_MAX_DISTANCE,
		1e-6,
		"same curve, wider"
	)


# The old code reached for the non-positional AudioStreamPlayer pool, which
# has no distance falloff at all. It has to be a 3D player or the range
# above is decorative.
func test_the_explosion_plays_through_the_positional_pool() -> void:
	var source: String = _SFX_SCRIPT.source_code
	var start: int = source.find("func play_explode(")
	assert_gt(start, -1, "premise: play_explode is still the entry point")
	var body: String = source.substr(start, 1400)
	assert_true(body.contains("_players_3d"), "checks out a positional player")
	assert_true(body.contains("player.global_position = pos"), "and places it at the blast")
	assert_false(body.contains("volume_db = 6.0"), "no +6 dB boost")


# The 3D pool is shared and the explosion widens its range, so every other
# checkout has to set its own range back or a mob would inherit 64 m.
func test_every_3d_pool_checkout_sets_its_own_range() -> void:
	var source: String = _SFX_SCRIPT.source_code
	var checkouts: int = source.count("_players_3d[_next_player_3d]")
	var range_writes: int = source.count("player.max_distance = ")
	assert_eq(range_writes, checkouts, "all %d checkouts claim a range" % checkouts)


# --- "it's difficult to hit the snowballs/fireballs from ghasts back" ---
# (the hit-area size itself is pinned in tests/test_ghast_fireball.gd)

# --- "lots of items dropped cause lag, though often times I don't see items" ---


func _item_in(world: Node3D) -> Node3D:
	var item: Node3D = _DROPPED_ITEM_SCRIPT.new()
	add_child_autofree(item)
	item.set("_chunk_manager", world)
	return item


# A settled item re-derived the same answer every frame: gravity nudged it
# down a hair, the floor probe snapped it back, velocity returned to zero.
# One ray query per item per frame to stay exactly still, times however
# many a creeper just dropped.
func test_a_settled_item_stops_probing_the_floor_every_frame() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	world.put(Vector3i(0, _FLOOR_Y, 0), Blocks.STONE)
	var item: Node3D = _item_in(world)
	var half: float = float(_DROPPED_ITEM_SCRIPT.MESH_SIZE) * 0.5
	item.global_position = Vector3(0.5, float(_FLOOR_Y) + 1.6, 0.5)
	item.set("_velocity", Vector3(0.0, -2.0, 0.0))
	for _i: int in range(60):
		item.call("_apply_physics", 1.0 / 60.0)
	assert_true(bool(item.get("_at_rest")), "it knows it has landed")
	var settled: float = item.global_position.y
	assert_almost_eq(settled, float(_FLOOR_Y + 1) + half, 1e-4, "on the block top")
	# Throttled frames must not move it at all — the whole point is that
	# they do no work.
	for _i: int in range(6):
		item.call("_apply_physics", 1.0 / 60.0)
		assert_almost_eq(item.global_position.y, settled, 1e-9, "throttled frame is a no-op")


# The latency the throttle introduces has to be bounded, and the item must
# still notice its support being mined out.
func test_mining_the_floor_out_still_drops_a_settled_item() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	world.put(Vector3i(0, _FLOOR_Y, 0), Blocks.STONE)
	var item: Node3D = _item_in(world)
	item.global_position = Vector3(0.5, float(_FLOOR_Y) + 1.6, 0.5)
	item.set("_velocity", Vector3(0.0, -2.0, 0.0))
	for _i: int in range(60):
		item.call("_apply_physics", 1.0 / 60.0)
	var settled: float = item.global_position.y
	world.put(Vector3i(0, _FLOOR_Y, 0), Blocks.AIR)
	# Within the probe period (0.2 s = 12 frames at 60 fps) plus a couple
	# of frames of fall, it has to be visibly on its way down.
	for _i: int in range(20):
		item.call("_apply_physics", 1.0 / 60.0)
	assert_lt(item.global_position.y, settled - 0.01, "the fall resumed")
	assert_false(bool(item.get("_at_rest")), "and it is no longer resting")


# Being shoved out of a block is motion, so the throttle has to let go or
# the impulse would sit unintegrated for a fifth of a second.
func test_being_pushed_out_of_a_block_clears_the_rest_throttle() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	world.put(Vector3i(0, _FLOOR_Y, 0), Blocks.STONE)
	world.put(Vector3i(0, _FLOOR_Y + 1, 0), Blocks.STONE)
	var item: Node3D = _item_in(world)
	item.set("_at_rest", true)
	# Sitting inside the upper stone cell, with open air to one side.
	item.global_position = Vector3(0.5, float(_FLOOR_Y) + 1.5, 0.5)
	item.call("_push_out_of_solid_block")
	assert_false(bool(item.get("_at_rest")), "the shove wakes it up")


# With no player resolved yet — the first frames after a world load — an
# item must stay fully active rather than silently freezing.
func test_lod_defaults_to_fully_active_without_a_player() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var item: Node3D = _item_in(world)
	item.call("_refresh_lod")
	assert_true(bool(item.get("_near")), "near until proven otherwise")
	assert_false(bool(item.get("_dormant")), "and never dormant")


func test_lod_tiers_track_distance_from_the_player() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	var player := Node3D.new()
	add_child_autofree(player)
	player.global_position = Vector3.ZERO
	var item: Node3D = _item_in(world)
	item.set("_player", player)
	for probe: Array in [[5.0, true, false], [40.0, false, false], [90.0, false, true]]:
		item.global_position = Vector3(float(probe[0]), 0.0, 0.0)
		item.call("_refresh_lod")
		assert_eq(bool(item.get("_near")), bool(probe[1]), "near at %s m" % probe[0])
		assert_eq(bool(item.get("_dormant")), bool(probe[2]), "dormant at %s m" % probe[0])


# Gating only once the item is AT REST is deliberate: freezing one mid-arc
# would leave it hanging in the air for whoever walks back out to it.
func test_a_falling_item_is_never_gated_however_far_away_it_is() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	world.put(Vector3i(0, _FLOOR_Y, 0), Blocks.STONE)
	var item: Node3D = _item_in(world)
	item.global_position = Vector3(0.5, float(_FLOOR_Y) + 8.0, 0.5)
	item.set("_velocity", Vector3(0.0, -2.0, 0.0))
	item.set("_dormant", true)
	item.set("_near", false)
	for _i: int in range(90):
		item.call("_process", 1.0 / 60.0)
	assert_almost_eq(
		item.global_position.y,
		float(_FLOOR_Y + 1) + float(_DROPPED_ITEM_SCRIPT.MESH_SIZE) * 0.5,
		1e-3,
		"it finished its fall before going dormant"
	)


# --- "gd script fallback world loading is super slow, 1 load per second" ---


# The old budget was a hard "exactly one chunk per frame", which is a
# throughput cap denominated in frames — and frames are the thing that
# collapses under load. At the reporter's 1-5 fps that delivered 1-5 chunks
# a second, which keeps the pending queue deep, which keeps the frame rate
# down. A time budget cannot starve the work that ends the bad frames.
# The load the reporter was timing is _spawn_initial_chunks, which is NOT
# the worker-pool streaming path: it awaits a rendered frame between every
# chunk and does a full synchronous generate + light + mesh on the main
# thread for each one. The frames it waits for are the slow frames it is
# creating, so the loop is a throughput cap denominated in them. At the
# reported 1-5 fps a Far render distance is 289 of those — one to five
# minutes, which is exactly what the report describes.
func test_the_initial_load_yields_on_time_not_once_per_chunk() -> void:
	var source: String = _CHUNK_MANAGER_SCRIPT.source_code
	assert_true(
		source.contains("@export var initial_spawn_budget_usec"), "there is a wall-clock budget"
	)
	var start: int = source.find("func _spawn_initial_chunks()")
	assert_gt(start, -1, "premise: the initial ring still spawns here")
	var body: String = source.substr(start, 1600)
	assert_true(body.contains("initial_spawn_budget_usec"), "the loop spends that budget")
	# The yield has to survive — the loading screen needs frames to draw
	# its progress bar — it just must not cost one per chunk.
	var awaits: int = body.count("await get_tree().process_frame")
	assert_eq(awaits, 1, "exactly one yield, and it is behind the budget check")
	assert_lt(
		body.find("if Time.get_ticks_usec() >= deadline:"),
		body.find("await get_tree().process_frame"),
		"the yield is gated by the deadline, not unconditional"
	)


# The streaming path deliberately did NOT get the same treatment. Its
# ChunkNodes park their mesh in _pending_apply, drained at
# apply_budget_per_frame; materializing faster would only move the backlog
# into live-but-meshless nodes sitting in _chunks with no collision, and
# visible chunk throughput would not change at all.
func test_streaming_materialize_stays_one_per_frame() -> void:
	var source: String = _CHUNK_MANAGER_SCRIPT.source_code
	assert_false(
		source.contains("while _materialize_one_ready_chunk():"),
		"no unbounded drain sitting behind a 1-per-frame apply budget"
	)
	assert_true(source.contains("@export var apply_budget_per_frame: int = 1"), "apply still 1")
	# The per-result gate is the only defence against a worker landing
	# after a dimension switch — it must not have been refactored away.
	assert_true(source.contains("DimensionContext.accepts_result("), "stale-result gate intact")


# --- "I do believe explosions cause lag" ---


# update_block_light_around_world_many was the one lighting entry point
# with no C++ behind it, so a detonation ran its whole convergence in
# GDScript on the main thread — 495-926 ms in the reporter's log, second
# only to the explosion that triggered it.
func test_the_batch_relight_has_a_native_path() -> void:
	assert_true(
		ClassDB.class_exists("LightingNative"),
		"LightingNative not registered — rebuild via `scons`."
	)
	var native: RefCounted = ClassDB.instantiate("LightingNative")
	assert_true(
		native.has_method("update_block_light_around_world_many"),
		"the multi-source entry point is bound"
	)


# Parity: the native BFS and the GDScript reference must agree cell for
# cell. Two torches close enough that their 31-cubes overlap, which is the
# case the batch exists for.
func test_batch_relight_matches_the_gdscript_reference() -> void:
	assert_true(ClassDB.class_exists("LightingNative"), "rebuild via `scons`.")
	var sources: Array[Vector3i] = [Vector3i(4, 70, 4), Vector3i(9, 70, 6)]
	var native_light: PackedByteArray = _relight_both_ways(sources, true)
	var script_light: PackedByteArray = _relight_both_ways(sources, false)
	assert_eq(native_light.size(), script_light.size(), "same array size")
	assert_true(native_light == script_light, "native batch relight is byte-equal")


# Removal is the case most likely to diverge: a recompute-only BFS reads
# its neighbours' stale values, so which cell is visited first can in
# principle decide where it settles. Three shapes — a lone torch, two whose
# 31-cubes overlap, and one of a pair removed so a live source is still
# feeding the cells being darkened.
func test_batch_relight_matches_the_reference_when_lights_are_removed() -> void:
	assert_true(ClassDB.class_exists("LightingNative"), "rebuild via `scons`.")
	var cases: Array = [
		[[Vector3i(8, 70, 8)], [Vector3i(8, 70, 8)]],
		[[Vector3i(6, 70, 8), Vector3i(10, 70, 8)], [Vector3i(6, 70, 8), Vector3i(10, 70, 8)]],
		[[Vector3i(6, 70, 8), Vector3i(10, 70, 8)], [Vector3i(6, 70, 8)]],
	]
	for case: Array in cases:
		var torches: Array[Vector3i] = []
		torches.assign(case[0])
		var removed: Array[Vector3i] = []
		removed.assign(case[1])
		var native_light: PackedByteArray = _relight_after_removal(torches, removed, true)
		var script_light: PackedByteArray = _relight_after_removal(torches, removed, false)
		assert_true(
			native_light == script_light,
			"parity removing %d of %d torches" % [removed.size(), torches.size()]
		)


# And independently of parity: the algorithm has to actually darken. A
# recompute BFS that reads stale neighbours can sit at a wrong fixpoint and
# leave a removed torch's cell lit.
func test_removing_a_torch_actually_darkens_its_cell() -> void:
	var after: PackedByteArray = _relight_after_removal(
		[Vector3i(8, 70, 8)], [Vector3i(8, 70, 8)], false
	)
	assert_eq(after[Chunk.index(8, 70, 8)], 0, "the cell the torch left is dark")
	assert_eq(after[Chunk.index(11, 70, 8)], 0, "and so is what it was lighting")


# Light the torches, then delete them the way set_world_block does — the
# block id is already AIR by the time the deferred relight flushes.
func _relight_after_removal(
	torches: Array[Vector3i], removed: Array[Vector3i], use_native: bool
) -> PackedByteArray:
	var manager := _OneChunkWorld.new()
	add_child_autofree(manager)
	for t: Vector3i in torches:
		manager.chunk.set_block(t.x, t.y, t.z, Blocks.TORCH)
	Lighting.fill_block_light(manager.chunk)
	for r: Vector3i in removed:
		manager.chunk.set_block(r.x, r.y, r.z, Blocks.AIR)
	return _drive_relight(removed, manager, use_native)


# Build an identical one-chunk world twice, relight it through the chosen
# path, and hand back the resulting block_light.
func _relight_both_ways(sources: Array[Vector3i], use_native: bool) -> PackedByteArray:
	var manager := _OneChunkWorld.new()
	add_child_autofree(manager)
	for pos: Vector3i in sources:
		manager.chunk.set_block(pos.x, pos.y, pos.z, Blocks.TORCH)
	Lighting.fill_block_light(manager.chunk)
	return _drive_relight(sources, manager, use_native)


# Swap the native in or out, run the batch, swap back. Asserts the swap
# took: without it the "native" pass silently falls back and every parity
# assertion compares GDScript against itself, which always passes.
func _drive_relight(sources: Array[Vector3i], manager: Node3D, use_native: bool) -> PackedByteArray:
	var saved: RefCounted = Lighting._native_lighting
	Lighting._native_lighting = saved if use_native else null
	if use_native and Lighting._native_lighting == null:
		Lighting.enable_native()
	assert_eq(Lighting._native_lighting != null, use_native, "the requested path is the one used")
	Lighting.update_block_light_around_world_many(sources, manager)
	Lighting._native_lighting = saved
	return manager.chunk.block_light


# One real Chunk behind the ChunkManager surface Lighting needs. A real
# Chunk (not a dict) because the native path marshals chunk.blocks and
# chunk.block_light straight through.
class _OneChunkWorld:
	extends Node3D
	var chunk: Chunk = Chunk.new()

	func get_chunk_at_coord(coord: Vector2i) -> Chunk:
		return chunk if coord == Vector2i.ZERO else null

	func _in_chunk(pos: Vector3i) -> bool:
		return (
			pos.x >= 0
			and pos.x < Chunk.SIZE_X
			and pos.z >= 0
			and pos.z < Chunk.SIZE_Z
			and pos.y >= 0
			and pos.y < Chunk.SIZE_Y
		)

	func get_world_block(pos: Vector3i) -> int:
		if not _in_chunk(pos):
			return Blocks.AIR
		return chunk.get_block(pos.x, pos.y, pos.z)

	func get_world_block_light(pos: Vector3i) -> int:
		if not _in_chunk(pos):
			return 0
		return chunk.block_light[Chunk.index(pos.x, pos.y, pos.z)]

	func set_world_block_light(pos: Vector3i, value: int) -> void:
		if not _in_chunk(pos):
			return
		chunk.block_light[Chunk.index(pos.x, pos.y, pos.z)] = value

	func notify_chunk_lighting_updated(_coord: Vector2i) -> void:
		pass


# --- "worldgen.strip_floating 55.8/67.7" in the reporter's own log ---


# The floating-terrain flood fill was one of only two worldgen passes with
# no native path, and it is not cheap: a 32,768-cell BFS plus a
# 32,768-cell sweep per chunk. Everyone paid it, extension loaded or not.
func test_strip_floating_terrain_has_a_native_path() -> void:
	assert_true(
		ClassDB.class_exists("WorldgenNative"),
		"WorldgenNative not registered — rebuild via `scons`."
	)
	var native: RefCounted = ClassDB.instantiate("WorldgenNative")
	assert_true(native.has_method("strip_floating_terrain"), "the flood fill is bound")


# Parity against the GDScript reference on a shape with all three cases in
# it: a grounded pillar, an island floating in mid-air, and an island
# touching a chunk edge (which must be SPARED, because it may be held up
# through the neighbour this pass cannot see).
func test_strip_floating_terrain_matches_the_gdscript_reference() -> void:
	assert_true(ClassDB.class_exists("WorldgenNative"), "rebuild via `scons`.")
	var chunk := Chunk.new()
	for z: int in range(Chunk.SIZE_Z):
		for x: int in range(Chunk.SIZE_X):
			chunk.set_block(x, 0, z, Blocks.BEDROCK)
	# Grounded: a column standing on the bedrock plane.
	for y: int in range(1, 6):
		chunk.set_block(8, y, 8, Blocks.STONE)
	# Floating: a 2x2x2 island with nothing under it.
	for dx: int in range(2):
		for dz: int in range(2):
			for dy: int in range(2):
				chunk.set_block(3 + dx, 70 + dy, 3 + dz, Blocks.DIRT)
	# Edge-touching: against x = 0, so it is spared.
	chunk.set_block(0, 70, 11, Blocks.STONE)
	chunk.set_block(1, 70, 11, Blocks.STONE)
	var reference: PackedInt32Array = Worldgen._floating_terrain_indices_reference(chunk.blocks)
	var native: RefCounted = ClassDB.instantiate("WorldgenNative")
	var ported: PackedInt32Array = native.call(
		"strip_floating_terrain",
		chunk.blocks,
		Worldgen._floating_support_lut(),
		Worldgen._floating_strip_lut()
	)
	assert_eq(ported.size(), reference.size(), "same number of floating cells")
	assert_true(ported == reference, "native flood fill is index-for-index identical")
	# And the premise held: it found the island and nothing else.
	assert_eq(reference.size(), 8, "the 2x2x2 island, and only it")
	for idx: int in reference:
		var y: int = idx / (Chunk.SIZE_X * Chunk.SIZE_Z)
		assert_between(y, 70, 71, "every stripped cell is from the island")


# The LUTs are what keep the native side ignorant of block ids. If they
# ever disagree with the reference's hardcoded id checks, parity silently
# becomes a comparison of two different algorithms.
func test_the_flood_fill_luts_say_what_the_reference_says() -> void:
	var support: PackedByteArray = Worldgen._floating_support_lut()
	var strip: PackedByteArray = Worldgen._floating_strip_lut()
	assert_eq(support.size(), 256, "full id range")
	assert_eq(strip.size(), 256, "full id range")
	for id: int in [
		Blocks.AIR, Blocks.WATER_STILL, Blocks.WATER_FLOWING, Blocks.LAVA_STILL, Blocks.LAVA_FLOWING
	]:
		assert_eq(support[id], 0, "block id %d carries nothing" % id)
	for id: int in [Blocks.STONE, Blocks.DIRT, Blocks.GRASS, Blocks.SAND, Blocks.GRAVEL]:
		assert_eq(support[id], 1, "block id %d carries structure" % id)
		assert_eq(strip[id], 1, "block id %d is strippable when unsupported" % id)
	# Ore left hanging is a different bug; this pass is deliberately narrow.
	assert_eq(strip[Blocks.COAL_ORE], 0, "ore is not stripped")
	assert_eq(strip[Blocks.BEDROCK], 0, "nor is bedrock")
