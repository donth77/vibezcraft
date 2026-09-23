# gdlint: disable=max-public-methods
# gdlint: disable=max-file-lines
extends GutTest

# Field report #10 (github.com/donth77/vibezcraft/issues/10). Same shape as
# the #8 / #9 files: one file per report, each test named for the symptom
# the reporter described. Rail placement lives in test_rail_shape.gd and
# the chest's mesher parity in test_mesher_native.gd, beside their peers.

const _DROPPED_ITEM_SCRIPT: GDScript = preload("res://scripts/world/dropped_item.gd")
const _MINECART_SCRIPT: GDScript = preload("res://scripts/entities/minecart.gd")
const _BOAT_SCRIPT: GDScript = preload("res://scripts/entities/boat.gd")
const _MODEL_BOX: GDScript = preload("res://scripts/entities/model_box.gd")
const _PLAYER_SCRIPT: GDScript = preload("res://scripts/player/player.gd")
const _PLAYER_SCENE: PackedScene = preload("res://scenes/player/player.tscn")
const _CHEST_SCREEN_SCRIPT: GDScript = preload("res://scripts/ui/chest_screen.gd")
const _CHUNK_MANAGER_SCRIPT: GDScript = preload("res://scripts/world/chunk_manager.gd")
const _ALPHA_CART_PATH: String = "res://assets/textures/entities/packs/alpha_vanilla/cart.png"

const _FLOOR_Y: int = 63
const _BED_DIRECTIONS: Array[Vector3i] = [
	Vector3i(0, 0, 1), Vector3i(-1, 0, 0), Vector3i(0, 0, -1), Vector3i(1, 0, 0)
]


# Minimal voxel world as a Node — entities type their manager reference as
# `Node`, so a RefCounted assigned to one is silently dropped.
class VoxelWorldNode:
	extends Node3D
	var blocks: Dictionary = {}
	var metas: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


# A LightingNative compiled from sources that predate the batch relight:
# it loads, it answers the calls it knows, and it has no
# update_block_light_around_world_many.
class StaleLightingNative:
	extends RefCounted


# One real Chunk behind the ChunkManager surface Lighting needs.
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


# Counts spawn passes instead of running them.
class _CountingSpawner:
	extends PassiveSpawner
	var passes: int = 0

	func _run_one_tick(_chunk_mgr: Node, _player: Node3D) -> void:
		passes += 1


# Records the wake instead of relocating a body that is in no tree.
class _WakeProbePlayer:
	extends "res://scripts/player/player.gd"
	var wakes: int = 0

	func _wake_up() -> void:
		wakes += 1


var _previous_pack: String


func before_all() -> void:
	BlockAtlas.reset()
	BlockAtlas.build()


func before_each() -> void:
	_previous_pack = BlockAtlas.active_pack


func after_each() -> void:
	BlockAtlas.active_pack = _previous_pack


# --- "Invalid call. Nonexistent function 'update_block_light_around_world_many'
#      in base 'LightingNative'" (a creeper blew up) ---


# The reporter's scripts were newer than their compiled extension. The
# batch relight an explosion flushes through was the one native call with
# no fallback, so the stale library aborted the detonation mid-flush.
func test_a_stale_lighting_library_falls_back_instead_of_crashing() -> void:
	var sources: Array[Vector3i] = [Vector3i(4, 70, 4), Vector3i(9, 70, 9)]
	var stale := StaleLightingNative.new()
	assert_false(stale.has_method("update_block_light_around_world_many"), "fixture is stale")
	var reference: PackedByteArray = _relight_removed_torches(sources, null)
	var result: PackedByteArray = _relight_removed_torches(sources, stale)
	assert_eq(result, reference, "the GDScript path ran and produced the same light")


func _relight_removed_torches(sources: Array[Vector3i], native: RefCounted) -> PackedByteArray:
	var manager := _OneChunkWorld.new()
	add_child_autofree(manager)
	var saved: RefCounted = Lighting._native_lighting
	Lighting._native_lighting = null
	for pos: Vector3i in sources:
		manager.chunk.set_block(pos.x, pos.y, pos.z, Blocks.TORCH)
	Lighting.fill_block_light(manager.chunk)
	for pos: Vector3i in sources:
		manager.chunk.set_block(pos.x, pos.y, pos.z, Blocks.AIR)
	Lighting._native_lighting = native
	Lighting.update_block_light_around_world_many(sources, manager)
	Lighting._native_lighting = saved
	return manager.chunk.block_light


# --- "railing uphill hitbox isn't expected hitbox" ---


func test_an_ascending_rail_has_vanillas_taller_hitbox() -> void:
	# jn.java:26-32 — 10/16 tall for a ramp, 2/16 for everything else.
	for meta: int in range(10):
		var box: AABB = Blocks.selection_aabb(Blocks.RAIL, meta)
		var ramp: bool = meta >= RailShape.ASCEND_EAST and meta <= RailShape.ASCEND_SOUTH
		assert_almost_eq(box.size.y, 0.625 if ramp else 0.125, 1e-6, "meta %d height" % meta)
		assert_eq(Vector2(box.size.x, box.size.z), Vector2.ONE, "meta %d covers the cell" % meta)


func test_the_cursor_target_for_a_ramp_is_the_taller_box() -> void:
	# The player's ray hits the plant_faces soup the mesher emits for the
	# rail, not selection_aabb itself — it has to carry the same height.
	var chunk := Chunk.new()
	chunk.set_block(3, 63, 3, Blocks.STONE)
	chunk.set_block_with_meta(3, 64, 3, Blocks.RAIL, RailShape.ASCEND_EAST)
	var top: float = -INF
	for v: Vector3 in Mesher.mesh_chunk(chunk).get("plant_faces", PackedVector3Array()):
		top = maxf(top, v.y)
	assert_almost_eq(top, 64.625, 1e-4, "the ramp's box reaches 10/16 of the cell")


# --- "breaking a uphill rail in creative gives you a different unique rail block" ---


func test_breaking_a_rail_in_creative_gives_the_rail_item() -> void:
	assert_eq(Blocks.pick_item(Blocks.RAIL), Items.RAIL, "the item that places rails")
	assert_true(
		load("res://scripts/player/interaction.gd").source_code.contains(
			"Blocks.pick_item(broken_id)"
		),
		"creative break hands over the picked item, not the raw cell id"
	)


func test_creative_pick_gives_the_block_itself_unless_an_item_places_it() -> void:
	var cases: Array = [
		[Blocks.STONE, Blocks.STONE],
		[Blocks.COAL_ORE, Blocks.COAL_ORE],
		[Blocks.GRASS, Blocks.GRASS],
		[Blocks.CHEST, Blocks.CHEST],
		[Blocks.SIGN_WALL, Items.SIGN],
		[Blocks.REDSTONE_WIRE, Items.REDSTONE],
		[Blocks.REDSTONE_REPEATER_ON, Items.REDSTONE_REPEATER],
		[Blocks.REDSTONE_TORCH_OFF, Blocks.REDSTONE_TORCH],
		[Blocks.LIT_FURNACE, Blocks.FURNACE],
		[Blocks.BED_HEAD, Items.BED],
		[Blocks.CROPS, Items.WHEAT_SEEDS],
		[Blocks.FIRE, Blocks.AIR],
		[Blocks.WATER_STILL, Blocks.AIR],
		[Blocks.PORTAL, Blocks.AIR],
	]
	for case: Array in cases:
		assert_eq(Blocks.pick_item(case[0]), case[1], Blocks.name_of(case[0]))


func test_every_picked_item_is_something_an_inventory_can_hold() -> void:
	for id: int in Blocks.REGISTERED_IDS:
		var picked: int = Blocks.pick_item(id)
		if picked == Blocks.AIR:
			continue
		assert_true(
			Items.is_registered(picked) or Blocks.has_item_form(picked),
			"%s picks a real stack" % Blocks.name_of(id)
		)


# --- "chest textures are wonky and have double the storage they should" ---


func test_a_chest_is_alphas_opaque_cube() -> void:
	assert_true(Blocks.is_opaque(Blocks.CHEST), "c.java inherits Block's opaque cube")
	assert_eq(Blocks.mesh_shape(Blocks.CHEST), Blocks.MESH_SHAPE_DIRECTIONAL_CUBE)
	assert_true(Blocks.is_solid_collision(Blocks.CHEST))
	assert_eq(Blocks.selection_aabb(Blocks.CHEST), AABB(Vector3.ZERO, Vector3.ONE))


func test_a_chest_shows_its_latch_on_the_one_face_it_was_placed_facing() -> void:
	for meta: int in range(4):
		var front: int = Blocks.directional_front_face_idx(meta)
		for face: int in range(6):
			var expected: String = "chest_side"
			if face <= 1:
				expected = "chest_top"
			elif face == front:
				expected = "chest_front"
			assert_eq(
				Blocks.directional_face_texture(Blocks.CHEST, face, meta),
				expected,
				"meta %d face %d" % [meta, face]
			)


func test_the_chest_icon_cube_carries_the_latch() -> void:
	# BlockMesh builds the inventory icon, the held block and the dropped
	# item; face 5 (-Z) is the front the icon renderer turns to the camera.
	var mesh: ArrayMesh = BlockMesh.get_cube_mesh(Blocks.CHEST, 1.0)
	var uvs: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var front: Rect2 = BlockAtlas.uv_rect("chest_front")
	for k: int in range(4):
		assert_true(front.grow(1e-5).has_point(uvs[5 * 4 + k]), "-Z face samples chest_front")


func test_a_single_chest_screen_shows_three_rows_not_six() -> void:
	var screen: Control = _CHEST_SCREEN_SCRIPT.new()
	add_child_autofree(screen)
	var scale: int = _CHEST_SCREEN_SCRIPT.SCALE
	# er.java:21-24 — 114 + rows × 18.
	assert_eq(_CHEST_SCREEN_SCRIPT.PANEL_H, 168 * scale, "a 3-row GuiChest is 168 px tall")
	var local: Dictionary = screen.get("_local_node_for")
	assert_eq(local.size(), 27, "27 chest slots")
	# er.java:52-53 — two crops: title + three slot rows, then the player
	# block from y=126. The old single 222-px crop was the double chest.
	var regions: Array[Rect2] = []
	for node: Node in screen.find_children("*", "TextureRect", true, false):
		var tex: Texture2D = (node as TextureRect).texture
		if tex is AtlasTexture:
			regions.append((tex as AtlasTexture).region)
	assert_true(regions.has(Rect2(0, 0, 176, 71)), "chest rows crop")
	assert_true(regions.has(Rect2(0, 126, 176, 96)), "player inventory crop")
	assert_false(regions.has(Rect2(0, 0, 176, 222)), "no double-chest art")
	# Every chest slot sits in the chest crop, every player slot below it.
	for panel: Panel in local.values():
		assert_lt(panel.position.y, 71.0 * scale, "chest slot inside the chest rows")
	for panel: Variant in screen.get("_slot_nodes"):
		if panel != null:
			assert_gte((panel as Panel).position.y, 71.0 * scale, "player slot below them")


func test_a_chest_minecart_carries_the_chest_cube_at_three_quarter_scale() -> void:
	var cart: Node3D = _MINECART_SCRIPT.new()
	cart.set("variant", _MINECART_SCRIPT.VARIANT_CHEST)
	add_child_autofree(cart)
	var payload: MeshInstance3D = cart.get("_payload_mi")
	assert_not_null(payload, "mi.java:56-66 draws the block in the cart")
	if payload == null:
		return
	assert_eq(payload.mesh, BlockMesh.get_cube_mesh(Blocks.CHEST, 1.0))
	assert_eq(payload.scale, Vector3.ONE * 0.75)


# --- "minecart and boat textures are still messed up/weird" ---


func test_model_box_unwraps_faces_like_ka_java() -> void:
	# ka.java:68-73 for a 16 × 8 × 2 box at skin offset (0, 0): +X, -X,
	# -Y, +Y, -Z, +Z.
	var rects: Array[Rect2] = _MODEL_BOX.face_rects(Vector2i(0, 0), Vector3i(16, 8, 2))
	assert_eq(rects[0], Rect2(18, 2, 2, 8))
	assert_eq(rects[1], Rect2(0, 2, 2, 8))
	assert_eq(rects[2], Rect2(2, 0, 16, 2))
	assert_eq(rects[3], Rect2(18, 0, 16, 2))
	assert_eq(rects[4], Rect2(2, 2, 16, 8))
	assert_eq(rects[5], Rect2(20, 2, 16, 8))


func test_the_cart_hull_is_vanillas_model_shape() -> void:
	var bounds: AABB = _MINECART_SCRIPT._build_hull_mesh().get_aabb()
	_assert_bounds(bounds, Vector3(-0.5, 0.0, -0.625), Vector3(0.5, 0.625, 0.625), "cart")


func test_the_boat_hull_is_vanillas_model_shape() -> void:
	var bounds: AABB = _BOAT_SCRIPT._build_hull_mesh().get_aabb()
	# Long along local X under the boat's -90° visual root, as in cv.java.
	_assert_bounds(bounds, Vector3(-0.75, 0.0, -0.625), Vector3(0.75, 0.625, 0.625), "boat")


func _assert_bounds(bounds: AABB, lo: Vector3, hi: Vector3, label: String) -> void:
	assert_true(bounds.position.is_equal_approx(lo), "%s min %s" % [label, bounds.position])
	assert_true(bounds.end.is_equal_approx(hi), "%s max %s" % [label, bounds.end])


# The reported look: every face sampled a third-by-half sliver of its
# crop, so a floor showed a couple of stretched texel rows. The inside of
# each floor must sample exactly vanilla's inner-floor rectangle.
func test_the_cart_floor_samples_its_whole_inner_panel() -> void:
	var mesh: ArrayMesh = _MINECART_SCRIPT._build_hull_mesh()
	# im.java floor: skin (0, 10), 20 × 16 × 2 — its +Z face, turned up.
	_assert_up_faces_sample(mesh, 0.125, Rect2(24, 12, 20, 16), "cart floor")


func test_the_boat_floor_samples_its_whole_inner_panel() -> void:
	var mesh: ArrayMesh = _BOAT_SCRIPT._build_hull_mesh()
	# cv.java floor: skin (0, 8), 24 × 16 × 4.
	_assert_up_faces_sample(mesh, 0.25, Rect2(32, 12, 24, 16), "boat floor")


func _assert_up_faces_sample(mesh: ArrayMesh, floor_y: float, texels: Rect2, label: String) -> void:
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var rect := Rect2(texels.position / Vector2(64, 32), texels.size / Vector2(64, 32))
	var span := Rect2()
	var found: int = 0
	for i: int in range(verts.size()):
		if normals[i].y < 0.99 or absf(verts[i].y - floor_y) > 1e-4:
			continue
		assert_true(rect.grow(1e-4).has_point(uvs[i]), "%s uv %s in %s" % [label, uvs[i], rect])
		span = Rect2(uvs[i], Vector2.ZERO) if found == 0 else span.expand(uvs[i])
		found += 1
	assert_eq(found, 6, "%s: one upward quad" % label)
	# The whole panel, bar nc.java's 0.1-texel inset — not a sliver of it.
	assert_almost_eq(span.size.x, rect.size.x - 0.2 / 64.0, 1e-5, "%s spans its width" % label)
	assert_almost_eq(span.size.y, rect.size.y - 0.2 / 32.0, 1e-5, "%s spans its depth" % label)


func test_a_pack_without_a_cart_skin_falls_back_to_alphas() -> void:
	BlockAtlas.active_pack = "pixel_perfection"
	var cart: Node3D = _MINECART_SCRIPT.new()
	autofree(cart)
	var texture: Texture2D = cart.call("_load_cart_texture")
	assert_not_null(texture, "never an untextured white hull")
	if texture != null:
		assert_eq(texture.resource_path, _ALPHA_CART_PATH)


# --- "throwing an item on ice close to another block can cause the item
#      to slide through the block" ---


func _item_in(world: Node3D, at: Vector3, velocity: Vector3) -> Node3D:
	var item: Node3D = _DROPPED_ITEM_SCRIPT.new()
	add_child_autofree(item)
	item.set("_chunk_manager", world)
	item.global_position = at
	item.set("_velocity", velocity)
	return item


func _floor(world: VoxelWorldNode, id: int, from_x: int, to_x: int) -> void:
	for x: int in range(from_x, to_x + 1):
		for z: int in range(-1, 2):
			world.put(Vector3i(x, _FLOOR_Y, z), id)


# The same order _process uses: push-out, then the move.
func _run(item: Node3D, frames: int, dt: float, face_x: float) -> float:
	var half: float = float(_DROPPED_ITEM_SCRIPT.MESH_SIZE) * 0.5
	var furthest: float = -INF
	for _i: int in range(frames):
		item.call("_push_out_of_solid_block")
		item.call("_apply_physics", dt)
		furthest = maxf(furthest, item.global_position.x + half)
	return furthest - face_x


func test_an_item_sliding_on_ice_stops_at_the_block_it_hits() -> void:
	# A cobblestone block standing on the ice, hit at 6 m/s on a 20 fps
	# frame: each step (0.3 m) was more than the item's own half-size, so
	# the push-out picked "down" into the ice and then "out the far side".
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	_floor(world, Blocks.ICE, -2, 5)
	world.put(Vector3i(2, _FLOOR_Y + 1, 0), Blocks.COBBLESTONE)
	var half: float = float(_DROPPED_ITEM_SCRIPT.MESH_SIZE) * 0.5
	var item: Node3D = _item_in(
		world, Vector3(0.5, float(_FLOOR_Y + 1) + half, 0.5), Vector3(6.0, 0.0, 0.0)
	)
	var overshoot: float = _run(item, 80, 1.0 / 20.0, 2.0)
	assert_lte(overshoot, 1e-6, "the item never enters the block")
	assert_almost_eq(float(item.get("_velocity").x), 0.0, 1e-9, "the blocked axis stops")


func test_see_through_solids_stop_a_sliding_item_too() -> void:
	# The push-out rescue only ever fires inside OPAQUE blocks, so glass,
	# ice, leaves and slime were walked straight through at any frame rate.
	var half: float = float(_DROPPED_ITEM_SCRIPT.MESH_SIZE) * 0.5
	for wall: int in [
		Blocks.GLASS, Blocks.ICE, Blocks.LEAVES, Blocks.SLIME_BLOCK, Blocks.HALF_SLAB, Blocks.CHEST
	]:
		var world := VoxelWorldNode.new()
		add_child_autofree(world)
		_floor(world, Blocks.STONE, -2, 5)
		world.put(Vector3i(2, _FLOOR_Y + 1, 0), wall)
		var item: Node3D = _item_in(
			world, Vector3(0.5, float(_FLOOR_Y + 1) + half, 0.5), Vector3(3.5, 0.0, 0.0)
		)
		var overshoot: float = _run(item, 120, 1.0 / 60.0, 2.0)
		assert_lte(overshoot, 1e-6, "%s stops it" % Blocks.name_of(wall))


func test_an_item_still_glides_across_open_floor() -> void:
	# The floor under a sliding item must never read as a wall — it crosses
	# cell boundaries untouched and slides as far as it did before.
	var half: float = float(_DROPPED_ITEM_SCRIPT.MESH_SIZE) * 0.5
	for ground: int in [Blocks.STONE, Blocks.HALF_SLAB]:
		var world := VoxelWorldNode.new()
		add_child_autofree(world)
		_floor(world, ground, -2, 6)
		var top: float = float(_FLOOR_Y) + Blocks.collision_aabb(ground).size.y
		var item: Node3D = _item_in(world, Vector3(0.5, top + half, 0.5), Vector3(3.5, 0.0, 0.0))
		_run(item, 180, 1.0 / 60.0, 0.0)
		# 3.5 m/s under the 2.5/s drag glides ~1.34 m, well past the seam
		# at x = 1.
		assert_gt(item.global_position.x, 1.7, "%s: slid over the seams" % Blocks.name_of(ground))
		assert_almost_eq(item.global_position.y, top + half, 1e-4, "and rests on the surface")


func test_a_rising_item_stops_at_the_ceiling() -> void:
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	world.put(Vector3i(0, _FLOOR_Y + 3, 0), Blocks.GLASS)
	var item: Node3D = _item_in(
		world, Vector3(0.5, float(_FLOOR_Y) + 1.5, 0.5), Vector3(0.0, 9.0, 0.0)
	)
	var half: float = float(_DROPPED_ITEM_SCRIPT.MESH_SIZE) * 0.5
	for _i: int in range(10):
		item.call("_apply_physics", 1.0 / 20.0)
		assert_lte(item.global_position.y + half, float(_FLOOR_Y + 3) + 1e-6, "under the glass")


func test_a_thrown_item_cannot_start_inside_the_wall_the_player_hugs() -> void:
	# The throw used to place the item 0.4 m ahead of the eye outright —
	# 0.1 m inside a wall the 0.3 m capsule was pressed against.
	var world := VoxelWorldNode.new()
	add_child_autofree(world)
	world.put(Vector3i(1, _FLOOR_Y + 2, 0), Blocks.GLASS)
	var item: Node3D = _item_in(world, Vector3(0.7, float(_FLOOR_Y) + 2.5, 0.5), Vector3.ZERO)
	item.call("move_clipped", Vector3(0.4, 0.0, 0.0))
	var half: float = float(_DROPPED_ITEM_SCRIPT.MESH_SIZE) * 0.5
	assert_lte(item.global_position.x + half, 1.0 + 1e-6, "stops at the glass face")


func test_half_slabs_and_open_gates_have_vanillas_bounds() -> void:
	for slab: int in [Blocks.HALF_SLAB, Blocks.WOOD_HALF_SLAB, Blocks.COBBLESTONE_HALF_SLAB]:
		# qj.java:13-14.
		assert_eq(Blocks.selection_aabb(slab), AABB(Vector3.ZERO, Vector3(1.0, 0.5, 1.0)))
	var open_meta: int = 0
	for meta: int in range(16):
		if Blocks.is_fence_gate_open(meta):
			open_meta = meta
			break
	assert_true(Blocks.is_fence_gate_open(open_meta), "found an open-gate meta")
	assert_false(Blocks.collision_aabb(Blocks.FENCE_GATE, open_meta).has_volume(), "walk-through")


# --- "sleeping doesn't make you lay down in bed" ---


func test_the_in_bed_view_looks_level_toward_the_foot_of_the_bed() -> void:
	for hd: Vector3i in _BED_DIRECTIONS:
		var basis: Basis = _PLAYER_SCRIPT.sleep_view_basis(hd)
		assert_true((-basis.z).is_equal_approx(-Vector3(hd)), "%s: facing the foot" % hd)
		assert_true(basis.y.is_equal_approx(Vector3.UP), "%s: level" % hd)


func test_the_in_bed_eye_is_at_the_pillow() -> void:
	var foot := Vector3i(10, 64, -3)
	for hd: Vector3i in _BED_DIRECTIONS:
		var eye: Vector3 = _PLAYER_SCRIPT.sleep_eye_position(foot, hd)
		var along: float = (eye - (Vector3(foot) + Vector3(0.5, 0.0, 0.5))).dot(Vector3(hd))
		assert_almost_eq(along, 1.4, 1e-5, "%s: 0.1 from the headboard end" % hd)
		assert_almost_eq(eye.y, 64.0 + 1.0575, 1e-5, "%s: Beta's eye height" % hd)


func test_the_sleeper_lies_on_their_back_with_their_head_on_the_pillow() -> void:
	var foot := Vector3i(10, 64, -3)
	var foot_centre := Vector3(foot) + Vector3(0.5, 0.0, 0.5)
	for hd: Vector3i in _BED_DIRECTIONS:
		var xf: Transform3D = _PLAYER_SCRIPT.sleep_model_transform(foot, hd)
		assert_true((-xf.basis.z).is_equal_approx(Vector3.UP), "%s: face up" % hd)
		assert_true(xf.basis.y.is_equal_approx(Vector3(hd)), "%s: head to the headboard" % hd)
		assert_almost_eq(xf.origin.y, 64.7375, 1e-5, "%s: spine height" % hd)
		# Model feet at -0.9, head top at +1.1 along its own Y.
		var feet: float = (xf * Vector3(0, -0.9, 0) - foot_centre).dot(Vector3(hd))
		var crown: float = (xf * Vector3(0, 1.1, 0) - foot_centre).dot(Vector3(hd))
		assert_almost_eq(feet, -0.525, 1e-5, "%s: feet at the foot end" % hd)
		assert_almost_eq(crown, 1.475, 1e-5, "%s: crown just short of the headboard" % hd)


func test_sleeping_swaps_the_hand_for_the_lying_body_and_waking_restores_it() -> void:
	var player: CharacterBody3D = _PLAYER_SCENE.instantiate()
	autofree(player)
	player.health = 20
	# Off-tree instantiation skips @onready; wire the camera by hand.
	var camera: Camera3D = player.get_node("Camera3D")
	player.set("_camera", camera)
	var props: Dictionary = {}
	for field: String in [
		"_fp_hand", "_held_block", "_held_tool_pivot", "_held_block_tp", "_held_tool_tp_pivot"
	]:
		var node := Node3D.new()
		autofree(node)
		player.set(field, node)
		props[field] = node
	player.is_sleeping = true
	player.call("_apply_camera_effects", 1.0 / 60.0)
	assert_true(bool(player.get("_sleep_view_active")), "in the bed view")
	assert_false((props["_fp_hand"] as Node3D).visible, "no first-person hand")
	assert_false((props["_held_tool_pivot"] as Node3D).visible, "no first-person tool")
	assert_true((props["_held_tool_tp_pivot"] as Node3D).visible, "the body holds it")
	player.is_sleeping = false
	player.call("_apply_camera_effects", 1.0 / 60.0)
	assert_false(bool(player.get("_sleep_view_active")), "back to the perspective rig")
	assert_true((props["_fp_hand"] as Node3D).visible, "the hand is back")
	assert_false((props["_held_tool_tp_pivot"] as Node3D).visible, "body props hidden again")
	assert_true(camera.position.is_equal_approx(_PLAYER_SCRIPT._CAM_FIRST_PERSON), "eye anchor")


func test_a_hit_wakes_a_sleeper() -> void:
	# EntityHuman.java:346-348 (Beta), with no skip to dawn.
	var player := _WakeProbePlayer.new()
	autofree(player)
	player.health = 20
	player.is_sleeping = true
	player.sleep_ticks = 20.0
	var tick_before: int = WorldTime.current_tick()
	player.take_damage(1, "mob")
	assert_false(player.is_sleeping, "woken")
	assert_eq(player.wakes, 1, "through the normal wake-up")
	assert_eq(player.sleep_ticks, 0.0, "no lingering sleep fade")
	assert_eq(WorldTime.current_tick(), tick_before, "no time skip")


# --- "[PERF] 4 fps for 32.1 s ... worldgen.generate_chunk 194.0, worldgen.caves 99.0" ---
#
# The native cave carve takes a fraction of a millisecond; the time was in
# GDScript passes around it that walked all 32,768 cells per chunk. Each
# was replaced by C++ searches, so each must still reach exactly the same
# answer as the walk it replaced.


func _speckled_chunk(seed: int) -> Chunk:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var chunk := Chunk.new()
	var ids: Array[int] = [
		Blocks.STONE,
		Blocks.DIRT,
		Blocks.WATER_STILL,
		Blocks.SAPLING,
		Blocks.SUGAR_CANE,
		Blocks.TORCH,
		Blocks.SIGN_WALL,
		Blocks.CHEST,
	]
	var blocks: PackedByteArray = chunk.blocks
	for _i: int in range(400):
		blocks[rng.randi_range(0, Chunk.TOTAL_BLOCKS - 1)] = ids[rng.randi_range(0, ids.size() - 1)]
	chunk.blocks = blocks
	return chunk


func test_the_saved_chunk_decode_finds_what_the_cell_walk_found() -> void:
	var coord := Vector2i(-3, 7)
	for seed: int in [1, 2, 3]:
		var source: Chunk = _speckled_chunk(seed)
		# The walk the decode used to do, kept here as the reference.
		var saplings: Array[Vector3i] = []
		var cane_tops: Dictionary = {}
		var non_cube: bool = false
		for i: int in range(Chunk.TOTAL_BLOCKS):
			var b: int = source.blocks[i]
			non_cube = non_cube or Blocks.needs_gdscript_mesher(b)
			var lx: int = i % Chunk.SIZE_X
			var lz: int = (i / Chunk.SIZE_X) % Chunk.SIZE_Z
			var ly: int = i / (Chunk.SIZE_X * Chunk.SIZE_Z)
			if b == Blocks.SAPLING:
				saplings.append(Vector3i(coord.x * 16 + lx, ly, coord.y * 16 + lz))
			elif b == Blocks.SUGAR_CANE:
				var key := Vector2i(lx, lz)
				if not cane_tops.has(key) or int(cane_tops[key]) < ly:
					cane_tops[key] = ly
		var expected_canes: Array[Vector3i] = []
		for key: Vector2i in cane_tops:
			expected_canes.append(
				Vector3i(coord.x * 16 + key.x, cane_tops[key], coord.y * 16 + key.y)
			)
		var entry: Dictionary = {
			"bytes": source.blocks.compress(FileAccess.COMPRESSION_FASTLZ), "max_y": 127
		}
		var decoded: Array = _CHUNK_MANAGER_SCRIPT._decode_saved_entry(coord, entry)
		var chunk: Chunk = decoded[0]
		assert_eq(decoded[1], saplings, "seed %d: saplings, in order" % seed)
		assert_eq(chunk.cane_tops, expected_canes, "seed %d: cane tops, in order" % seed)
		assert_eq(chunk.has_non_cube_blocks, non_cube, "seed %d: non-cube flag" % seed)
		assert_true(chunk.has_sign_blocks, "seed %d: sign flag" % seed)


func test_a_chunk_without_non_cube_cells_decodes_with_the_flag_clear() -> void:
	var source := Chunk.new()
	var blocks: PackedByteArray = source.blocks
	blocks.fill(Blocks.STONE)
	var entry: Dictionary = {"bytes": blocks.compress(FileAccess.COMPRESSION_FASTLZ), "max_y": 127}
	var chunk: Chunk = _CHUNK_MANAGER_SCRIPT._decode_saved_entry(Vector2i.ZERO, entry)[0]
	assert_false(chunk.has_non_cube_blocks)
	assert_false(chunk.has_sign_blocks)
	assert_eq(chunk.cane_tops.size(), 0)


func test_the_cave_post_pass_sets_the_flags_the_cell_walk_did() -> void:
	for seed: int in [4, 5]:
		var chunk: Chunk = _speckled_chunk(seed)
		chunk.has_non_cube_blocks = false
		chunk.has_water_cells = false
		chunk.block_meta.fill(3)
		Worldgen._post_process_native_caves(chunk)
		assert_true(chunk.has_non_cube_blocks, "seed %d: saw the torches / saplings" % seed)
		assert_true(chunk.has_water_cells, "seed %d: saw the water" % seed)
		assert_eq(chunk.block_meta.count(0), Chunk.TOTAL_BLOCKS, "meta zeroed")
	var plain := Chunk.new()
	var stone: PackedByteArray = plain.blocks
	stone.fill(Blocks.STONE)
	plain.blocks = stone
	Worldgen._post_process_native_caves(plain)
	assert_false(plain.has_non_cube_blocks, "nothing non-cube in solid stone")
	assert_false(plain.has_water_cells, "nor any water")


func test_max_y_by_layers_matches_the_column_walk() -> void:
	for seed: int in [6, 7, 8]:
		var chunk: Chunk = _speckled_chunk(seed)
		var reference: int = 0
		for x: int in range(Chunk.SIZE_X):
			for z: int in range(Chunk.SIZE_Z):
				for y: int in range(Chunk.SIZE_Y - 1, -1, -1):
					if chunk.get_block_unchecked(x, y, z) != Blocks.AIR:
						reference = maxi(reference, y)
						break
		assert_eq(Worldgen._top_non_air_layer(chunk.blocks), reference, "seed %d" % seed)
	assert_eq(Worldgen._top_non_air_layer(Chunk.new().blocks), 0, "an empty chunk")


func test_every_non_cube_id_is_in_the_shared_list() -> void:
	var ids: PackedInt32Array = Blocks.gdscript_mesher_ids()
	for id: int in range(256):
		assert_eq(ids.has(id), Blocks.needs_gdscript_mesher(id), "id %d" % id)


# "chunk_mgr.tick.mob_spawn 121.1" — one loading frame ran a spawn pass
# for every 50 ms it had taken, forty of them back to back.
func test_a_long_frame_runs_at_most_two_spawn_passes() -> void:
	var dimension_was: int = DimensionContext.active()
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	var spawner := _CountingSpawner.new()
	var host := Node.new()
	add_child_autofree(host)
	var player := Node3D.new()
	add_child_autofree(player)
	spawner.tick(2.0, host, player)
	assert_eq(spawner.passes, 2, "the backlog is dropped, not paid off in one frame")
	spawner.tick(1.0 / 20.0, host, player)
	assert_eq(spawner.passes, 3, "and the normal cadence carries on")
	DimensionContext.set_active(dimension_was)
