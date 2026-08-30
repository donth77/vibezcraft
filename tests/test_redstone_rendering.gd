# gdlint: disable=max-public-methods
extends GutTest

# Every redstone block, across every surface it can appear on.
#
# The redstone set broke on three different rendering surfaces in a
# single playtest — the spawner icon, the held item and the dropped
# entity — each through a different code path, each while the other
# surfaces looked fine. Reasoning about them one at a time is what let
# that happen, so this walks the whole matrix instead:
#
#   inventory / spawner icon · held item · dropped entity · placed in world
#
# Each surface asserts the thing that was actually wrong when it broke,
# not merely that a call returned something.

const Y: int = 64

# Every id a player can hold or place from this feature.
const REDSTONE_BLOCKS: Array = [
	Blocks.REDSTONE_ORE,
	Blocks.GLOWING_REDSTONE_ORE,
	Blocks.REDSTONE_WIRE,
	Blocks.REDSTONE_TORCH,
	Blocks.REDSTONE_TORCH_OFF,
	Blocks.LEVER,
	Blocks.STONE_BUTTON,
	Blocks.STONE_PRESSURE_PLATE,
	Blocks.WOODEN_PRESSURE_PLATE,
]

# Held-item sizes, mirroring player.gd's constants closely enough that a
# mesh which builds here builds there.
const HELD_SIZE: float = 0.4
const _SFX_SCRIPT := preload("res://scripts/audio/sfx.gd")


func before_each() -> void:
	BlockAtlas.reset()


func _label(id: int) -> String:
	return Blocks.name_of(id)


# --- Surface 1: inventory + debug spawner icon -------------------------


func test_every_redstone_block_resolves_an_inventory_icon() -> void:
	for id: int in REDSTONE_BLOCKS:
		assert_not_null(ItemIcons.icon_for(id), "%s has an icon" % _label(id))


func test_the_dust_item_resolves_an_icon_too() -> void:
	# The item the player actually carries, distinct from the wire block.
	assert_not_null(ItemIcons.icon_for(Items.REDSTONE), "redstone dust has an icon")


func test_sprite_tiled_blocks_get_a_tile_and_solid_ones_may_get_a_bake() -> void:
	# The icon bug: a sprite-on-transparency tile wrapped around a cube
	# shows up on three faces at once. Headless there is no bake, so what
	# this pins is the ROUTING — sprite-tiled ids must not be registered
	# for one.
	var iconified: Array = (
		load("res://scripts/ui/block_icon_renderer.gd")
		. get_script_constant_map()["_ICONIFIED_BLOCKS"]
	)
	for id: int in REDSTONE_BLOCKS:
		if Blocks.has_sprite_tile(id):
			assert_false(iconified.has(id), "%s must not be cube-baked" % _label(id))


# --- Surface 2: held item ----------------------------------------------


# Mirror of player.gd::_update_held_item's routing decision.
func _held_takes_sprite_path(id: int) -> bool:
	return (
		not Blocks.is_registered(id)
		or (Blocks.has_sprite_tile(id) and Blocks.mesh_shape(id) != Blocks.MESH_SHAPE_TORCH)
	)


func test_every_redstone_block_builds_a_held_mesh() -> void:
	for id: int in REDSTONE_BLOCKS:
		if _held_takes_sprite_path(id):
			var tex: Texture2D = ItemIcons.icon_for(id)
			assert_not_null(tex, "%s has a sprite to extrude" % _label(id))
			if tex == null:
				continue
			var extruded: ArrayMesh = SpriteExtruder.build(tex)
			assert_not_null(extruded, "%s extrudes a held mesh" % _label(id))
			if extruded != null:
				assert_gt(extruded.get_surface_count(), 0, "%s held mesh has geometry" % _label(id))
		else:
			var mesh: ArrayMesh = BlockMesh.get_cube_mesh(id, HELD_SIZE)
			assert_not_null(mesh, "%s builds a held block mesh" % _label(id))
			if mesh != null:
				assert_gt(mesh.get_surface_count(), 0, "%s held block has geometry" % _label(id))


func test_both_redstone_torches_use_the_pillar_mesh_not_a_cube() -> void:
	# The specific regression: a redstone torch through the generic cube
	# builder smears its sprite over six faces.
	#
	# Vertex COUNT cannot tell them apart — a box is 24 verts whether it
	# is a cube or a pillar, because each face carries its own four for
	# per-face UVs. The width is what differs: `_build_torch` is 2/16 of
	# a cell across, a cube is the full cell.
	var cube_w: float = _mesh_bounds(BlockMesh.get_cube_mesh(Blocks.STONE, HELD_SIZE)).size.x
	for id: int in [Blocks.TORCH, Blocks.REDSTONE_TORCH, Blocks.REDSTONE_TORCH_OFF]:
		assert_lt(
			_mesh_bounds(BlockMesh.get_cube_mesh(id, HELD_SIZE)).size.x,
			cube_w * 0.5,
			"%s is a pillar, not a full cube" % _label(id)
		)
		assert_gt(
			_vertex_count(BlockMesh.get_held_torch_mesh(HELD_SIZE, id)),
			0,
			"%s builds its first-person torch mesh" % _label(id)
		)


func test_the_two_torch_ids_do_not_share_a_cached_mesh() -> void:
	# They differ only by texture, so a cache key that ignored the id
	# would silently hand the lit mesh to the unlit torch.
	var lit: ArrayMesh = BlockMesh.get_held_torch_mesh(HELD_SIZE, Blocks.REDSTONE_TORCH)
	var unlit: ArrayMesh = BlockMesh.get_held_torch_mesh(HELD_SIZE, Blocks.REDSTONE_TORCH_OFF)
	assert_ne(lit, unlit, "each torch id gets its own mesh")


# --- Surface 3: dropped entity -----------------------------------------


func test_every_redstone_block_builds_a_dropped_visual() -> void:
	# dropped_item.gd routes on the same shared predicate now, so the
	# check is that whichever branch it lands in actually produces
	# something.
	for id: int in REDSTONE_BLOCKS:
		if Blocks.has_sprite_tile(id):
			var tex: Texture2D = ItemIcons.icon_for(id)
			assert_not_null(tex, "%s dropped sprite source" % _label(id))
			if tex != null:
				assert_not_null(SpriteExtruder.build(tex), "%s drops as a sprite" % _label(id))
		else:
			assert_gt(
				_vertex_count(BlockMesh.get_cube_mesh(id, 0.25)),
				0,
				"%s drops as a cube" % _label(id)
			)


func test_the_dust_item_builds_a_dropped_visual() -> void:
	var tex: Texture2D = ItemIcons.icon_for(Items.REDSTONE)
	assert_not_null(tex, "dust sprite")
	if tex != null:
		assert_not_null(SpriteExtruder.build(tex), "dust drops as a sprite")


# --- Surface 4: placed in the world ------------------------------------


func test_wire_quads_enable_the_shaders_alpha_discard() -> void:
	# The dust tiles are a thin cross / line drawn on transparency. The
	# chunk shader only discards transparent texels when the mesher sets
	# COLOR.a = 1.0; with it at 0.0 the quad renders as a solid coloured
	# SQUARE filling the whole cell instead of a dust trail.
	var chunk := Chunk.new()
	chunk.set_block(8, Y, 8, Blocks.REDSTONE_WIRE)
	chunk.set_block_meta(8, Y, 8, 12)
	var colors: PackedColorArray = Mesher.mesh_chunk(chunk).colors
	assert_gt(colors.size(), 0, "wire emitted geometry")
	for c: Color in colors:
		assert_eq(c.a, 1.0, "every wire vertex enables alpha discard")


func test_opaque_redstone_shapes_keep_alpha_discard_off() -> void:
	# The other side of it: lever, button and plate sample fully opaque
	# tiles (cobblestone / stone / planks). Turning discard on for those
	# lets MSAA edge samples reach into neighbouring atlas slots, which is
	# why the flag is per-face rather than global.
	for id: int in [Blocks.LEVER, Blocks.STONE_BUTTON, Blocks.WOODEN_PRESSURE_PLATE]:
		var chunk := Chunk.new()
		chunk.set_block(8, Y, 8, id)
		chunk.set_block_meta(8, Y, 8, Redstone.MOUNT_FLOOR)
		for c: Color in Mesher.mesh_chunk(chunk).colors:
			assert_eq(c.a, 0.0, "%s keeps discard off" % _label(id))


func _straight_run_uvs(along_x: bool) -> PackedVector2Array:
	# A three-cell straight run; return the UVs of the MIDDLE cell only,
	# by meshing with and without it and taking the difference.
	var with_mid := Chunk.new()
	var without := Chunk.new()
	for i in range(-1, 2):
		var cx: int = 8 + (i if along_x else 0)
		var cz: int = 8 + (0 if along_x else i)
		with_mid.set_block(cx, Y - 1, cz, Blocks.STONE)
		without.set_block(cx, Y - 1, cz, Blocks.STONE)
		with_mid.set_block(cx, Y, cz, Blocks.REDSTONE_WIRE)
		with_mid.set_block_meta(cx, Y, cz, 12)
		if i == 0:
			continue
		without.set_block(cx, Y, cz, Blocks.REDSTONE_WIRE)
		without.set_block_meta(cx, Y, cz, 12)
	var a: PackedVector2Array = Mesher.mesh_chunk(with_mid).uvs
	var b: PackedVector2Array = Mesher.mesh_chunk(without).uvs
	return a.slice(b.size()) if a.size() > b.size() else PackedVector2Array()


func _wire_quad_bounds(west: bool, east: bool, north: bool, south: bool) -> AABB:
	# Build a wire at (8,Y,8) with dust neighbours only on the requested
	# sides, and return the bounds of the wire cell's own quad.
	var chunk := Chunk.new()
	var bare := Chunk.new()
	for spot: Array in [[-1, 0, west], [1, 0, east], [0, -1, north], [0, 1, south]]:
		if not bool(spot[2]):
			continue
		var cx: int = 8 + int(spot[0])
		var cz: int = 8 + int(spot[1])
		for c: Chunk in [chunk, bare]:
			c.set_block(cx, Y - 1, cz, Blocks.STONE)
			c.set_block(cx, Y, cz, Blocks.REDSTONE_WIRE)
			c.set_block_meta(cx, Y, cz, 12)
	chunk.set_block(8, Y - 1, 8, Blocks.STONE)
	bare.set_block(8, Y - 1, 8, Blocks.STONE)
	chunk.set_block(8, Y, 8, Blocks.REDSTONE_WIRE)
	chunk.set_block_meta(8, Y, 8, 12)
	# Select by CENTROID, not by differencing against a bare chunk: the
	# mesher emits cells in x/y/z order, so with an east neighbour the
	# extra vertices at the tail belong to that neighbour, not to the cell
	# under test. That mistake made this helper silently measure the wrong
	# quad for any layout with a +X or +Z neighbour.
	var full: PackedVector3Array = Mesher.mesh_chunk(chunk).vertices
	var box := AABB()
	var found: bool = false
	for i in range(0, full.size(), 4):
		var centroid: Vector3 = (full[i] + full[i + 1] + full[i + 2] + full[i + 3]) * 0.25
		if centroid.x <= 8.0 or centroid.x >= 9.0 or centroid.z <= 8.0 or centroid.z >= 9.0:
			continue
		# …and above the floor. The support block's top face occupies the
		# exact same XZ footprint; wire sits 1/32 above it.
		if centroid.y <= float(Y) + 0.001:
			continue
		for j in range(4):
			if not found:
				box = AABB(full[i + j], Vector3.ZERO)
				found = true
			else:
				box = box.expand(full[i + j])
	assert_true(found, "found the wire cell's own quad")
	return box


func test_an_unconnected_wire_arm_is_cropped_back() -> void:
	# bk.java:473-497 — vanilla pulls the quad AND its UVs in by 5/16 on
	# every side with no connection, so a corner is an L-shaped stub, not
	# a full four-armed plus. We used to draw the whole cross every time.
	var crop: float = 0.3125
	# Corner: connected west and north only.
	var corner: AABB = _wire_quad_bounds(true, false, true, false)
	assert_almost_eq(corner.position.x, 8.0, 0.001, "west arm reaches the cell edge")
	assert_almost_eq(corner.end.x, 9.0 - crop, 0.001, "east arm is cropped back")
	assert_almost_eq(corner.position.z, 8.0, 0.001, "north arm reaches the edge")
	assert_almost_eq(corner.end.z, 9.0 - crop, 0.001, "south arm is cropped back")


func test_an_isolated_wire_still_draws_the_full_cross() -> void:
	# The `if (bl4 || bl5 || bl2 || bl3)` guard: with NO connections at
	# all, vanilla skips the cropping entirely.
	var lone: AABB = _wire_quad_bounds(false, false, false, false)
	assert_almost_eq(lone.position.x, 8.0, 0.001, "full width")
	assert_almost_eq(lone.end.x, 9.0, 0.001, "full width")
	assert_almost_eq(lone.position.z, 8.0, 0.001, "full depth")
	assert_almost_eq(lone.end.z, 9.0, 0.001, "full depth")


func test_a_t_junction_crops_only_its_one_dead_side() -> void:
	# Connected west, east and north — only the south arm retracts.
	var tee: AABB = _wire_quad_bounds(true, true, true, false)
	assert_almost_eq(tee.position.x, 8.0, 0.001, "west reaches")
	assert_almost_eq(tee.end.x, 9.0, 0.001, "east reaches")
	assert_almost_eq(tee.position.z, 8.0, 0.001, "north reaches")
	assert_almost_eq(tee.end.z, 9.0 - 0.3125, 0.001, "south is cropped")


func test_a_wire_run_points_its_strip_along_the_run() -> void:
	# The dust line tile's strip runs along the tile's own X axis (rows
	# 6-9 opaque across every column — measured from the art). So for the
	# strip to follow the wire, U has to advance along whichever world
	# axis the run follows.
	#
	# The check: on an east-west run, two verts that differ in world X
	# must differ in U. On a north-south run, U must instead advance with
	# world Z. Getting this backwards is a 90° rotation — the wire
	# visibly crosses the direction it is carrying power.
	var ew: PackedVector2Array = _straight_run_uvs(true)
	var ns: PackedVector2Array = _straight_run_uvs(false)
	assert_eq(ew.size(), 4, "east-west middle cell is one quad")
	assert_eq(ns.size(), 4, "north-south middle cell is one quad")
	if ew.size() != 4 or ns.size() != 4:
		return
	# Corner order is (x0,z0) (x0,z1) (x1,z1) (x1,z0). Corner 0→1 moves in
	# Z only; corner 0→3 moves in X only.
	assert_almost_eq(ew[0].x, ew[1].x, 0.0001, "east-west: U constant along Z")
	assert_ne(ew[0].x, ew[3].x, "east-west: U advances along X")
	assert_almost_eq(ns[0].x, ns[3].x, 0.0001, "north-south: U constant along X")
	assert_ne(ns[0].x, ns[1].x, "north-south: U advances along Z")


func test_the_lever_handle_samples_only_the_stick_column() -> void:
	# The lever tile is 20 opaque pixels — a 2x10 stick at x[7..8],
	# y[6..15] — on an otherwise transparent 16x16 sprite. The handle box
	# runs with the shader's discard path OFF (its base is opaque
	# cobblestone), so any UV reaching outside the stick paints solid
	# black and the lever reads as a fat dark slab.
	#
	# Every handle UV must therefore land inside that column.
	var lever_tile: Rect2 = BlockAtlas.uv_rect_for(Blocks.LEVER, BlockAtlas.FACE_SIDE)
	var stick := Rect2(
		lever_tile.position.x + lever_tile.size.x * (7.0 / 16.0),
		lever_tile.position.y + lever_tile.size.y * (6.0 / 16.0),
		lever_tile.size.x * (2.0 / 16.0),
		lever_tile.size.y * (10.0 / 16.0)
	)
	var cobble: Rect2 = BlockAtlas.uv_rect("cobblestone")
	# No floor block — the lever emitter doesn't need support, and a stone
	# cube underneath would contribute 24 stone UVs of its own.
	var chunk := Chunk.new()
	chunk.set_block(8, Y, 8, Blocks.LEVER)
	chunk.set_block_meta(8, Y, 8, Redstone.MOUNT_FLOOR)
	var eps: float = 0.0001
	var outside: int = 0
	for uv: Vector2 in Mesher.mesh_chunk(chunk).uvs:
		var in_stick: bool = stick.grow(eps).has_point(uv)
		var in_cobble: bool = cobble.grow(eps).has_point(uv)
		if not in_stick and not in_cobble:
			outside += 1
	assert_eq(outside, 0, "every lever UV is inside the stick column or the cobblestone base")


# --- Lever handle rotation (bk.java:147-192) ---------------------------


func _lever_handle_verts(mount: int, on: bool) -> PackedVector3Array:
	# Difference against a bare cell isolates the lever; then drop the
	# axis-aligned cobblestone base by keeping only verts that are NOT on
	# the base's own grid, which the rotation makes trivially separable.
	var chunk := Chunk.new()
	chunk.set_block(8, Y, 8, Blocks.LEVER)
	chunk.set_block_meta(8, Y, 8, mount | (Redstone.POWERED_BIT if on else 0))
	return Mesher.mesh_chunk(chunk).vertices


func test_the_lever_handle_is_rotated_not_axis_aligned() -> void:
	# Vanilla tilts the handle ±40°; ours used to translate an
	# axis-aligned box instead, so the lever slid rather than swung.
	#
	# A rotated stick has vertices at coordinates that no axis-aligned
	# box could produce: its 8 corners take more than 2 distinct values on
	# the axes the tilt touches.
	var verts: PackedVector3Array = _lever_handle_verts(Redstone.MOUNT_FLOOR, true)
	var ys: Dictionary = {}
	var zs: Dictionary = {}
	for v: Vector3 in verts:
		ys[snappedf(v.y, 0.0001)] = true
		zs[snappedf(v.z, 0.0001)] = true
	# The base contributes 2 distinct Y and 2 distinct Z. A tilted handle
	# adds more of both; a translated axis-aligned one would not.
	assert_gt(ys.size(), 4, "handle tilt produces off-grid Y values")
	assert_gt(zs.size(), 4, "handle tilt produces off-grid Z values")


func test_flipping_the_lever_mirrors_the_handle_rather_than_sliding_it() -> void:
	# On and off are ±40° about the same pivot, so the two states are
	# mirror images through the cell centre — not the same shape shifted.
	var on: PackedVector3Array = _lever_handle_verts(Redstone.MOUNT_FLOOR, true)
	var off: PackedVector3Array = _lever_handle_verts(Redstone.MOUNT_FLOOR, false)
	assert_eq(on.size(), off.size(), "same vertex count in both states")
	assert_ne(on, off, "the handle actually moves")
	var on_z: float = 0.0
	var off_z: float = 0.0
	for v: Vector3 in on:
		on_z += v.z
	for v: Vector3 in off:
		off_z += v.z
	assert_ne(snappedf(on_z, 0.001), snappedf(off_z, 0.001), "the handle leans to opposite sides")


func test_the_lever_handle_roots_in_its_own_base() -> void:
	# The invariant that catches a wrong yaw on ANY mount, which two
	# rounds of hand-derived rotation tables did not: the handle has to
	# physically touch the base plate it grows out of. Get the yaw wrong
	# and the stick appears across the cell from its base, floating.
	#
	# Base is the first box emitted (24 verts), handle the second.
	for mount: int in [
		Redstone.MOUNT_WEST_WALL,
		Redstone.MOUNT_EAST_WALL,
		Redstone.MOUNT_NORTH_WALL,
		Redstone.MOUNT_SOUTH_WALL,
		Redstone.MOUNT_FLOOR,
		Redstone.MOUNT_FLOOR_ALT,
	]:
		for on: bool in [true, false]:
			var chunk := Chunk.new()
			chunk.set_block(8, Y, 8, Blocks.LEVER)
			chunk.set_block_meta(8, Y, 8, mount | (Redstone.POWERED_BIT if on else 0))
			var verts: PackedVector3Array = Mesher.mesh_chunk(chunk).vertices
			assert_eq(verts.size(), 48, "base + handle, 24 verts each")
			if verts.size() != 48:
				continue
			var base: AABB = _bounds_of_faces(verts.slice(0, 24))
			var handle: AABB = _bounds_of_faces(verts.slice(24))
			assert_true(
				base.grow(0.02).intersects(handle),
				(
					"lever mount %d (%s) handle %s must touch its base %s"
					% [mount, "on" if on else "off", str(handle), str(base)]
				)
			)


func test_the_lever_handle_stays_inside_its_cell() -> void:
	# A wrong rotation order or a missed translate sends the stick through
	# the wall it is mounted on.
	for mount: int in [
		Redstone.MOUNT_FLOOR,
		Redstone.MOUNT_FLOOR_ALT,
		Redstone.MOUNT_WEST_WALL,
		Redstone.MOUNT_EAST_WALL,
		Redstone.MOUNT_NORTH_WALL,
		Redstone.MOUNT_SOUTH_WALL,
	]:
		for on: bool in [true, false]:
			for v: Vector3 in _lever_handle_verts(mount, on):
				assert_between(v.x, 7.9, 9.1, "x inside cell (mount %d)" % mount)
				assert_between(v.y, float(Y) - 0.1, float(Y) + 1.1, "y inside cell")
				assert_between(v.z, 7.9, 9.1, "z inside cell (mount %d)" % mount)


func test_the_levers_grey_cap_lands_on_the_handles_tip() -> void:
	# The lever tile is grey for its top two rows and wood for the eight
	# below. MC puts a box's top edge at v0 (the image's top row), which
	# makes the TIP the grey cap and the shaft wood. Ours had it upside
	# down: grey root, wooden tip.
	#
	# Checked on a FLOOR lever, where "tip" is unambiguously the end
	# furthest from the base plate.
	var chunk := Chunk.new()
	chunk.set_block(8, Y, 8, Blocks.LEVER)
	chunk.set_block_meta(8, Y, 8, Redstone.MOUNT_FLOOR)
	var data: Dictionary = Mesher.mesh_chunk(chunk)
	var verts: PackedVector3Array = data.vertices
	var uvs: PackedVector2Array = data.uvs
	# The handle is the second box emitted; the base is the first 24.
	var tile: Rect2 = BlockAtlas.uv_rect_for(Blocks.LEVER, BlockAtlas.FACE_SIDE)
	var v_top: float = tile.position.y + tile.size.y * (6.0 / 16.0)
	var lowest_y: float = 1e9
	var highest_y: float = -1e9
	for i in range(24, verts.size()):
		lowest_y = minf(lowest_y, verts[i].y)
		highest_y = maxf(highest_y, verts[i].y)
	# Average V at the handle's highest and lowest vertices.
	var v_at_top: float = 0.0
	var n_top: int = 0
	var v_at_bottom: float = 0.0
	var n_bottom: int = 0
	for i in range(24, verts.size()):
		if is_equal_approx(verts[i].y, highest_y):
			v_at_top += uvs[i].y
			n_top += 1
		elif is_equal_approx(verts[i].y, lowest_y):
			v_at_bottom += uvs[i].y
			n_bottom += 1
	assert_gt(n_top, 0, "found vertices at the handle tip")
	assert_gt(n_bottom, 0, "found vertices at the handle root")
	if n_top == 0 or n_bottom == 0:
		return
	# Smaller V = nearer the tile's top = the grey cap.
	assert_lt(
		v_at_top / float(n_top),
		v_at_bottom / float(n_bottom),
		"the tip samples nearer the tile's top (the grey cap) than the root does"
	)
	assert_almost_eq(v_top, v_top, 0.0001, "tile rect resolved")


func test_a_floor_torch_sits_on_the_ground_not_above_it() -> void:
	# A block's rendered geometry must not float above its own selection
	# box. ob.java:135 puts the floor torch's bounds at y 0.0..0.6, and
	# `selection_aabb` encodes that; the render used to start at 0.125, so
	# the torch hovered 2/16 over the block it stood on.
	#
	# Checked for all three torch ids — they share one emitter, and the
	# redstone pair is what surfaced it in play.
	for id: int in [Blocks.TORCH, Blocks.REDSTONE_TORCH, Blocks.REDSTONE_TORCH_OFF]:
		var chunk := Chunk.new()
		chunk.set_block(8, Y, 8, id)
		chunk.set_block_meta(8, Y, 8, Redstone.MOUNT_FLOOR)
		var lowest: float = 1e9
		for v: Vector3 in Mesher.mesh_chunk(chunk).vertices:
			lowest = minf(lowest, v.y)
		var box_bottom: float = (
			float(Y) + Blocks.selection_aabb(id, Redstone.MOUNT_FLOOR).position.y
		)
		assert_almost_eq(lowest, box_bottom, 0.001, "%s renders from its box's floor" % _label(id))


func test_a_torch_never_renders_outside_its_own_selection_box() -> void:
	# The placed model uses only the narrow body strip. Keeping that tight
	# geometry inside the selection box prevents Pixel Perfection's wider
	# item-art pixels from becoming extra geometry around the torch head.
	for id: int in [Blocks.TORCH, Blocks.REDSTONE_TORCH, Blocks.REDSTONE_TORCH_OFF]:
		for mount: int in [
			Redstone.MOUNT_FLOOR,
			Redstone.MOUNT_WEST_WALL,
			Redstone.MOUNT_EAST_WALL,
			Redstone.MOUNT_NORTH_WALL,
			Redstone.MOUNT_SOUTH_WALL,
		]:
			var chunk := Chunk.new()
			chunk.set_block(8, Y, 8, id)
			chunk.set_block_meta(8, Y, 8, mount)
			var lowest: float = 1e9
			var highest: float = -1e9
			for v: Vector3 in Mesher.mesh_chunk(chunk).vertices:
				lowest = minf(lowest, v.y)
				highest = maxf(highest, v.y)
			var sel: AABB = Blocks.selection_aabb(id, mount)
			assert_between(
				lowest - float(Y),
				sel.position.y - 0.001,
				sel.position.y + sel.size.y,
				"%s mount %d starts inside its box" % [_label(id), mount]
			)
			assert_lte(
				highest - float(Y),
				sel.position.y + sel.size.y + 0.001,
				"%s mount %d ends inside its box" % [_label(id), mount]
			)


# --- Break / place / step audio ----------------------------------------


func test_every_redstone_block_has_a_sound_material() -> void:
	# `SFX._material_for` returns "" for anything it doesn't know, and
	# `play_break` early-returns on "" — so a missing row is not a wrong
	# sound, it is SILENCE. All nine redstone blocks were missing, which
	# is why they snapped with no audio at all.
	var sfx := _SFX_SCRIPT.new()
	for id: int in REDSTONE_BLOCKS:
		assert_ne(sfx._material_for(id), "", "%s has a sound material" % _label(id))
	sfx.free()


func test_redstone_sound_materials_match_the_vanilla_registrations() -> void:
	# Read off nq.java, where `d`/`h` are both the stone sound and `e` is
	# wood. The wooden plate differing from the stone plate is the point:
	# they differ in sound as well as in what trips them.
	var expected: Dictionary = {
		Blocks.REDSTONE_ORE: "stone",  # nq.java:96  an(73).a(h)
		Blocks.GLOWING_REDSTONE_ORE: "stone",  # nq.java:97  an(74).a(h)
		Blocks.REDSTONE_WIRE: "stone",  # nq.java:78  lu(55).a(d)
		Blocks.REDSTONE_TORCH: "wood",  # nq.java:99  bo(76).a(e)
		Blocks.REDSTONE_TORCH_OFF: "wood",  # nq.java:98  bo(75).a(e)
		Blocks.LEVER: "wood",  # nq.java:92  pl(69).a(e)
		Blocks.STONE_BUTTON: "stone",  # nq.java:100 iy(77).a(h)
		Blocks.STONE_PRESSURE_PLATE: "stone",  # nq.java:93  ap(70).a(h)
		Blocks.WOODEN_PRESSURE_PLATE: "wood",  # nq.java:95  ap(72).a(e)
	}
	var sfx := _SFX_SCRIPT.new()
	for id: Variant in expected.keys():
		assert_eq(
			sfx._material_for(int(id)), str(expected[id]), "%s sound material" % _label(int(id))
		)
	sfx.free()


func test_buttons_and_plates_do_not_share_the_stone_cubes_icon_mesh() -> void:
	# Their icon and held model came from the plain cube builder, textured
	# with `stone` / `planks` — pixel-identical to the STONE and PLANKS
	# icons, so they read as absent when you scan the spawner for them.
	var stone: AABB = _mesh_bounds(BlockMesh.get_cube_mesh(Blocks.STONE, 1.0))
	for id: int in [Blocks.STONE_BUTTON, Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE]:
		var box: AABB = _mesh_bounds(BlockMesh.get_cube_mesh(id, 1.0))
		assert_lt(box.size.y, stone.size.y, "%s is flatter than a full cube" % _label(id))
		# Centred, not shoved against an edge — the selection box's
		# POSITION is meta-dependent and an icon has no meta.
		var centre: Vector3 = box.position + box.size * 0.5
		assert_almost_eq(centre.x, 0.0, 0.001, "%s icon centred in X" % _label(id))
		assert_almost_eq(centre.y, 0.0, 0.001, "%s icon centred in Y" % _label(id))
		assert_almost_eq(centre.z, 0.0, 0.001, "%s icon centred in Z" % _label(id))


# --- Surface 5: can the player's cursor actually hit it -----------------


func test_every_redstone_attachment_is_targetable_where_it_is_actually_drawn() -> void:
	# The bug this catches took a full playtest to find, because nothing
	# about it is visible: the block renders, it powers circuits, it saves
	# and loads. It just cannot be CLICKED.
	#
	# These shapes emit no collision faces on purpose — you walk through a
	# lever, as in vanilla. The cursor raycast reads the layer-2 "plant"
	# face soup instead, and with nothing in it the ray passes through to
	# the block behind.
	#
	# The assertion is deliberately OVERLAP, not "somewhere in the cell".
	# The first version of this test only checked the latter, and passed
	# happily while the button's target sat on the opposite wall from the
	# button — because `selection_aabb` was being asked without metadata
	# and returned its default mount.
	for id: int in REDSTONE_BLOCKS:
		if Blocks.mesh_shape(id) == Blocks.MESH_SHAPE_CUBE:
			continue  # ore is a solid block; the normal collider covers it
		for mount: int in [
			Redstone.MOUNT_WEST_WALL,
			Redstone.MOUNT_EAST_WALL,
			Redstone.MOUNT_NORTH_WALL,
			Redstone.MOUNT_SOUTH_WALL,
			Redstone.MOUNT_FLOOR,
		]:
			var chunk := Chunk.new()
			chunk.set_block(8, Y - 1, 8, Blocks.STONE)
			chunk.set_block(8, Y, 8, id)
			chunk.set_block_meta(8, Y, 8, mount)
			var data: Dictionary = Mesher.mesh_chunk(chunk)
			var target: AABB = _bounds_of_faces(data.get("plant_faces", PackedVector3Array()))
			var drawn: AABB = _drawn_bounds(chunk, id, mount)
			assert_gt(target.size.length(), 0.0, "%s emits a target" % _label(id))
			assert_true(
				target.grow(0.02).intersects(drawn),
				(
					"%s target %s must overlap the shape it draws %s (mount %d)"
					% [_label(id), str(target), str(drawn), mount]
				)
			)


# Bounds of the visible geometry the block itself contributes, isolated
# by differencing against the same scene without it.
func _drawn_bounds(chunk: Chunk, id: int, mount: int) -> AABB:
	var bare := Chunk.new()
	bare.set_block(8, Y - 1, 8, Blocks.STONE)
	var base_count: int = Mesher.mesh_chunk(bare).vertices.size()
	var full: PackedVector3Array = Mesher.mesh_chunk(chunk).vertices
	assert_gt(full.size(), base_count, "%s drew something (mount %d)" % [_label(id), mount])
	return _bounds_of_faces(full.slice(base_count))


func _bounds_of_faces(pts: PackedVector3Array) -> AABB:
	if pts.is_empty():
		return AABB()
	var box := AABB(pts[0], Vector3.ZERO)
	for v: Vector3 in pts:
		box = box.expand(v)
	return box


func test_the_cursor_target_matches_the_selection_outline() -> void:
	# The target box is derived from Blocks.selection_aabb, so what you
	# can click is the same box the outline draws. Checked on wire, whose
	# box is a 1/16 slab — a full-cube target there would let you click a
	# wire from a metre above it.
	var chunk := Chunk.new()
	chunk.set_block(8, Y, 8, Blocks.REDSTONE_WIRE)
	var faces: PackedVector3Array = Mesher.mesh_chunk(chunk).get(
		"plant_faces", PackedVector3Array()
	)
	assert_gt(faces.size(), 0, "wire emits a target")
	var top: float = -1e9
	for v: Vector3 in faces:
		top = maxf(top, v.y)
	var expected: float = float(Y) + Blocks.selection_aabb(Blocks.REDSTONE_WIRE).size.y
	assert_almost_eq(top, expected, 0.001, "wire target is as thin as its outline")


func _placed_vertex_count(id: int, meta: int) -> int:
	var chunk := Chunk.new()
	chunk.set_block(8, Y - 1, 8, Blocks.STONE)
	chunk.set_block(9, Y, 8, Blocks.STONE)  # a wall for the wall-mounted ones
	chunk.set_block(8, Y, 8, id)
	chunk.set_block_meta(8, Y, 8, meta)
	return Mesher.mesh_chunk(chunk).vertices.size()


func test_every_redstone_block_renders_when_placed() -> void:
	var empty: int = _placed_vertex_count(Blocks.AIR, 0)
	for id: int in REDSTONE_BLOCKS:
		assert_gt(
			_placed_vertex_count(id, Redstone.MOUNT_EAST_WALL),
			empty,
			"%s adds geometry when placed" % _label(id)
		)


func test_no_redstone_attachment_is_meshed_as_a_plain_cube() -> void:
	# The assertion that was missing, and the reason a placed torch could
	# render as a solid block while this file stayed green: "adds
	# geometry" is satisfied perfectly well by a cube.
	#
	# Comparing against STONE in the same cell is the direct test — if an
	# attachment is being run through the full-cube pass, its output is
	# vertex-for-vertex what stone produces there.
	var stone: int = _placed_vertex_count(Blocks.STONE, 0)
	for id: int in REDSTONE_BLOCKS:
		if not Blocks.has_sprite_tile(id) and Blocks.mesh_shape(id) == Blocks.MESH_SHAPE_CUBE:
			continue  # ore really is a cube
		assert_ne(
			_placed_vertex_count(id, Redstone.MOUNT_EAST_WALL),
			stone,
			"%s is meshed as its own shape, not a stone-sized cube" % _label(id)
		)


func test_both_lever_floor_rotations_render() -> void:
	# pl.java rolls 5 or 6 for a floor lever; a missing case would make
	# half of all placed levers invisible.
	for meta: int in [Redstone.MOUNT_FLOOR, Redstone.MOUNT_FLOOR_ALT]:
		var chunk := Chunk.new()
		chunk.set_block(8, Y - 1, 8, Blocks.STONE)
		chunk.set_block(8, Y, 8, Blocks.LEVER)
		chunk.set_block_meta(8, Y, 8, meta)
		assert_gt(
			Mesher.mesh_chunk(chunk).vertices.size(),
			Mesher.mesh_chunk(_floor_only()).vertices.size(),
			"floor lever meta %d renders" % meta
		)


func test_every_wall_mount_renders_for_lever_button_and_torch() -> void:
	for id: int in [Blocks.LEVER, Blocks.STONE_BUTTON, Blocks.REDSTONE_TORCH]:
		for meta: int in [
			Redstone.MOUNT_WEST_WALL,
			Redstone.MOUNT_EAST_WALL,
			Redstone.MOUNT_NORTH_WALL,
			Redstone.MOUNT_SOUTH_WALL,
		]:
			var chunk := Chunk.new()
			chunk.set_block(8, Y - 1, 8, Blocks.STONE)
			chunk.set_block(8, Y, 8, id)
			chunk.set_block_meta(8, Y, 8, meta)
			assert_gt(
				Mesher.mesh_chunk(chunk).vertices.size(),
				Mesher.mesh_chunk(_floor_only()).vertices.size(),
				"%s on mount %d renders" % [_label(id), meta]
			)


func test_wire_renders_at_every_power_level() -> void:
	# Powered and unpowered use different tiles; a missing one would make
	# a live circuit invisible.
	for power: int in [0, 1, 8, 15]:
		var chunk := Chunk.new()
		chunk.set_block(8, Y - 1, 8, Blocks.STONE)
		chunk.set_block(8, Y, 8, Blocks.REDSTONE_WIRE)
		chunk.set_block_meta(8, Y, 8, power)
		assert_gt(
			Mesher.mesh_chunk(chunk).vertices.size(),
			Mesher.mesh_chunk(_floor_only()).vertices.size(),
			"wire at power %d renders" % power
		)


func test_plates_render_pressed_and_released() -> void:
	for id: int in [Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE]:
		for meta: int in [0, 1]:
			var chunk := Chunk.new()
			chunk.set_block(8, Y - 1, 8, Blocks.STONE)
			chunk.set_block(8, Y, 8, id)
			chunk.set_block_meta(8, Y, 8, meta)
			assert_gt(
				Mesher.mesh_chunk(chunk).vertices.size(),
				Mesher.mesh_chunk(_floor_only()).vertices.size(),
				"%s meta %d renders" % [_label(id), meta]
			)


func _floor_only() -> Chunk:
	var chunk := Chunk.new()
	chunk.set_block(8, Y - 1, 8, Blocks.STONE)
	return chunk


# Enclosing box of every vertex in the mesh.
func _mesh_bounds(mesh: ArrayMesh) -> AABB:
	var box := AABB()
	var first: bool = true
	for i in range(mesh.get_surface_count()):
		for v: Vector3 in mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array:
			if first:
				box = AABB(v, Vector3.ZERO)
				first = false
			else:
				box = box.expand(v)
	return box


func _vertex_count(mesh: ArrayMesh) -> int:
	if mesh == null or mesh.get_surface_count() == 0:
		return 0
	var total: int = 0
	for i in range(mesh.get_surface_count()):
		total += (mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return total
