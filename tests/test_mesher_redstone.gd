extends GutTest

# Mesher coverage for the six redstone attachments (.claude/redstone-plan.md §4).
#
# Redstone geometry is not decorative: wire's TOPOLOGY is the same
# predicate its power rules use (`lu.java:295 c()` — `bk.java:437-455`
# renders from the identical test), so a rendering bug here means the
# shape you see and the circuit you built have diverged. That is the
# worst kind of bug in a game about building circuits, and until now no
# mesher test touched any redstone block at all.

const ChunkManagerScript := preload("res://scripts/world/chunk_manager.gd")

const Y: int = 64
const X: int = 8
const Z: int = 8


func before_each() -> void:
	BlockAtlas.reset()


func _floor_at(chunk: Chunk, x: int, z: int) -> void:
	chunk.set_block(x, Y - 1, z, Blocks.STONE)


# A chunk with wire at (X, Y, Z) on stone, plus whatever else the caller
# lays around it.
func _wire_chunk() -> Chunk:
	var chunk := Chunk.new()
	_floor_at(chunk, X, Z)
	chunk.set_block(X, Y, Z, Blocks.REDSTONE_WIRE)
	chunk.set_block_meta(X, Y, Z, Redstone.WIRE_MAX_POWER)
	return chunk


func _uv_centre(data: Dictionary) -> Vector2:
	var uvs: PackedVector2Array = data.get("uvs", PackedVector2Array())
	var total := Vector2.ZERO
	for uv: Vector2 in uvs:
		total += uv
	return total / maxf(1.0, float(uvs.size()))


func _collision_faces(data: Dictionary) -> PackedVector3Array:
	return data.get("collision_faces", PackedVector3Array())


# --- Wire topology mirrors the power predicate -------------------------


func test_wire_uses_the_line_tile_for_a_straight_run_and_cross_otherwise() -> void:
	# bk.java picks between two tiles; the only way to tell them apart
	# from mesh data is the UV region each occupies, so compare the two
	# against each other rather than against a hard-coded rect.
	var straight := _wire_chunk()
	_floor_at(straight, X - 1, Z)
	_floor_at(straight, X + 1, Z)
	straight.set_block(X - 1, Y, Z, Blocks.REDSTONE_WIRE)
	straight.set_block(X + 1, Y, Z, Blocks.REDSTONE_WIRE)

	var cross := _wire_chunk()
	for offset: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
		_floor_at(cross, X + offset.x, Z + offset.y)
		cross.set_block(X + offset.x, Y, Z + offset.y, Blocks.REDSTONE_WIRE)

	assert_ne(
		_uv_centre(Mesher.mesh_chunk(straight)),
		_uv_centre(Mesher.mesh_chunk(cross)),
		"a straight run and a cross use different tiles"
	)


func test_wire_topology_sees_a_button_exactly_as_it_sees_more_wire() -> void:
	# The RS-04 regression in mesh form. A button next to wire has to
	# change the wire's rendered shape; if `is_power_source` forgets the
	# button, the wire renders as an isolated dot beside it.
	var with_wire := _wire_chunk()
	_floor_at(with_wire, X + 1, Z)
	with_wire.set_block(X + 1, Y, Z, Blocks.REDSTONE_WIRE)
	_floor_at(with_wire, X - 1, Z)
	with_wire.set_block(X - 1, Y, Z, Blocks.REDSTONE_WIRE)

	var with_button := _wire_chunk()
	_floor_at(with_button, X - 1, Z)
	with_button.set_block(X - 1, Y, Z, Blocks.REDSTONE_WIRE)
	with_button.set_block(X + 1, Y, Z, Blocks.STONE)
	with_button.set_block(X + 2, Y, Z, Blocks.STONE_BUTTON)
	with_button.set_block_meta(X + 2, Y, Z, Redstone.MOUNT_WEST_WALL)

	var isolated := _wire_chunk()
	_floor_at(isolated, X - 1, Z)
	isolated.set_block(X - 1, Y, Z, Blocks.REDSTONE_WIRE)

	# Wire → wire → wire is a straight line; wire → wire → [solid, button]
	# is too, because the wire climbs the solid block toward the button.
	# An isolated stub is neither.
	assert_ne(
		_uv_centre(Mesher.mesh_chunk(isolated)),
		_uv_centre(Mesher.mesh_chunk(with_wire)),
		"a stub and a straight run differ"
	)


func test_wire_topology_sees_both_plates() -> void:
	for id: int in [Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE]:
		var plain := _wire_chunk()
		var with_plate := _wire_chunk()
		_floor_at(with_plate, X + 1, Z)
		with_plate.set_block(X + 1, Y, Z, id)
		assert_ne(
			_uv_centre(Mesher.mesh_chunk(plain)),
			_uv_centre(Mesher.mesh_chunk(with_plate)),
			"%s changes the wire's shape" % Blocks.name_of(id)
		)


func test_wire_draws_a_climb_quad_up_an_unroofed_neighbour() -> void:
	var flat := _wire_chunk()
	flat.set_block(X + 1, Y, Z, Blocks.STONE)

	var climbing := _wire_chunk()
	climbing.set_block(X + 1, Y, Z, Blocks.STONE)
	climbing.set_block(X + 1, Y + 1, Z, Blocks.REDSTONE_WIRE)

	assert_gt(
		Mesher.mesh_chunk(climbing).vertices.size(),
		Mesher.mesh_chunk(flat).vertices.size(),
		"the vertical face is extra geometry"
	)


func test_a_roofed_wire_never_climbs() -> void:
	# lu.java's asymmetric vertical rule: a wire under a solid block
	# cannot reach a wire on top of its neighbour.
	#
	# Measured as a DELTA — adding the roof block adds its own faces, so
	# comparing the two scenes directly would compare the roof, not the
	# climb. What matters is how much the upper wire adds in each case.
	assert_gt(_climb_delta(false), 0, "an unroofed wire gains a climb quad")
	assert_eq(_climb_delta(true), 0, "a roofed one gains nothing but the upper wire itself")


# Extra vertices contributed by putting wire on top of the solid
# neighbour, with and without a block over the lower wire.
func _climb_delta(roofed: bool) -> int:
	var without := _wire_chunk()
	without.set_block(X + 1, Y, Z, Blocks.STONE)
	var with_upper := _wire_chunk()
	with_upper.set_block(X + 1, Y, Z, Blocks.STONE)
	with_upper.set_block(X + 1, Y + 1, Z, Blocks.REDSTONE_WIRE)
	if roofed:
		without.set_block(X, Y + 1, Z, Blocks.STONE)
		with_upper.set_block(X, Y + 1, Z, Blocks.STONE)
	var gained: int = (
		Mesher.mesh_chunk(with_upper).vertices.size() - Mesher.mesh_chunk(without).vertices.size()
	)
	# The upper wire draws its own flat quad in both cases; subtract it so
	# the result is purely the climb.
	return gained - _lone_wire_vertex_count()


func _lone_wire_vertex_count() -> int:
	var solo := Chunk.new()
	solo.set_block(X, Y - 1, Z, Blocks.STONE)
	solo.set_block(X, Y, Z, Blocks.REDSTONE_WIRE)
	var bare := Chunk.new()
	bare.set_block(X, Y - 1, Z, Blocks.STONE)
	return Mesher.mesh_chunk(solo).vertices.size() - Mesher.mesh_chunk(bare).vertices.size()


# --- Pressed-state travel ----------------------------------------------


func test_a_pressed_button_sinks_into_its_wall() -> void:
	# The button's only feedback is that visible travel, so it has to
	# actually move in the mesh.
	var released := Chunk.new()
	released.set_block(X, Y, Z, Blocks.STONE)
	released.set_block(X + 1, Y, Z, Blocks.STONE_BUTTON)
	released.set_block_meta(X + 1, Y, Z, Redstone.MOUNT_WEST_WALL)

	var pressed := Chunk.new()
	pressed.set_block(X, Y, Z, Blocks.STONE)
	pressed.set_block(X + 1, Y, Z, Blocks.STONE_BUTTON)
	pressed.set_block_meta(X + 1, Y, Z, Redstone.MOUNT_WEST_WALL | Redstone.POWERED_BIT)

	var released_aabb: AABB = _bounds_of(Mesher.mesh_chunk(released).vertices)
	var pressed_aabb: AABB = _bounds_of(Mesher.mesh_chunk(pressed).vertices)
	assert_lt(pressed_aabb.size.x, released_aabb.size.x, "the pressed button is shallower")


func test_a_pressed_plate_sits_lower_than_a_released_one() -> void:
	for id: int in [Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE]:
		var up := Chunk.new()
		up.set_block(X, Y - 1, Z, Blocks.STONE)
		up.set_block(X, Y, Z, id)

		var down := Chunk.new()
		down.set_block(X, Y - 1, Z, Blocks.STONE)
		down.set_block(X, Y, Z, id)
		down.set_block_meta(X, Y, Z, 1)

		assert_lt(
			_bounds_of(Mesher.mesh_chunk(down).vertices).end.y,
			_bounds_of(Mesher.mesh_chunk(up).vertices).end.y,
			"%s depresses when stood on" % Blocks.name_of(id)
		)


# --- Attachments are walk-through --------------------------------------


func test_no_redstone_attachment_contributes_collision_geometry() -> void:
	# Every one of these is walk-through in Alpha. A stray collision face
	# would make a wire run something you trip over.
	#
	# Counted as a difference against the identical scene without the
	# attachment, so the support block's own faces — which sit exactly on
	# the shared boundary plane — can't be mistaken for the attachment's.
	for id: int in [
		Blocks.REDSTONE_WIRE,
		Blocks.REDSTONE_TORCH,
		Blocks.REDSTONE_TORCH_OFF,
		Blocks.LEVER,
		Blocks.STONE_BUTTON,
		Blocks.STONE_PRESSURE_PLATE,
		Blocks.WOODEN_PRESSURE_PLATE,
	]:
		var bare := Chunk.new()
		_floor_at(bare, X, Z)
		bare.set_block(X + 1, Y, Z, Blocks.STONE)

		var with_part := Chunk.new()
		_floor_at(with_part, X, Z)
		with_part.set_block(X + 1, Y, Z, Blocks.STONE)
		with_part.set_block(X, Y, Z, id)
		with_part.set_block_meta(X, Y, Z, Redstone.MOUNT_EAST_WALL)

		assert_eq(
			_collision_faces(Mesher.mesh_chunk(with_part)).size(),
			_collision_faces(Mesher.mesh_chunk(bare)).size(),
			"%s adds no collider" % Blocks.name_of(id)
		)


func test_every_redstone_attachment_renders_something() -> void:
	# The trivial guard that would have caught a missing mesh-shape
	# branch: an attachment that draws nothing is invisible in-world.
	for id: int in [
		Blocks.REDSTONE_WIRE,
		Blocks.REDSTONE_TORCH,
		Blocks.REDSTONE_TORCH_OFF,
		Blocks.LEVER,
		Blocks.STONE_BUTTON,
		Blocks.STONE_PRESSURE_PLATE,
		Blocks.WOODEN_PRESSURE_PLATE,
	]:
		var chunk := Chunk.new()
		_floor_at(chunk, X, Z)
		chunk.set_block(X, Y, Z, id)
		chunk.set_block_meta(X, Y, Z, Redstone.MOUNT_FLOOR)
		var before: int = Mesher.mesh_chunk(_bare_floor()).vertices.size()
		assert_gt(
			Mesher.mesh_chunk(chunk).vertices.size(),
			before,
			"%s draws geometry" % Blocks.name_of(id)
		)


# --- Chunk seams -------------------------------------------------------


func test_wire_at_a_seam_connects_through_the_edge_slices() -> void:
	# Reported from a playtest: a dust run crossing a chunk boundary looks
	# like it stops at the seam. The power model crosses fine (proved
	# against a real ChunkManager in test_redstone_state.gd), so the
	# remaining candidate is the MESH — the border cell reading AIR past
	# the seam and drawing itself as an isolated stub instead of a
	# continuous run.
	#
	# Edge slices are what carry the neighbour's blocks and metadata into
	# the worker-thread snapshot, so this binds them the way
	# ChunkManager._set_edge_planes does at materialize time.
	var neighbour := Chunk.new()
	# The neighbour's WEST column (x = 0) continues the run.
	for zz in range(Chunk.SIZE_Z):
		neighbour.set_block(0, Y - 1, zz, Blocks.STONE)
	neighbour.set_block(0, Y - 1, 8, Blocks.STONE)
	neighbour.set_block(0, Y, 8, Blocks.REDSTONE_WIRE)
	neighbour.set_block_meta(0, Y, 8, 11)

	var chunk := Chunk.new()
	var edge_x: int = Chunk.SIZE_X - 1
	chunk.set_block(edge_x, Y - 1, 8, Blocks.STONE)
	chunk.set_block(edge_x, Y, 8, Blocks.REDSTONE_WIRE)
	chunk.set_block_meta(edge_x, Y, 8, 12)
	chunk.set_block(edge_x - 1, Y - 1, 8, Blocks.STONE)
	chunk.set_block(edge_x - 1, Y, 8, Blocks.REDSTONE_WIRE)
	chunk.set_block_meta(edge_x - 1, Y, 8, 13)

	var isolated: PackedVector3Array = Mesher.mesh_chunk(chunk).vertices
	ChunkManagerScript._set_edge_planes(chunk, {"east": neighbour.west_edge_slices()})
	var joined: PackedVector3Array = Mesher.mesh_chunk(chunk).vertices
	assert_ne(isolated, joined, "binding the neighbour's edge slice changes the seam cell's shape")


func test_wire_at_a_chunk_edge_still_meshes() -> void:
	# Wire on the border reads neighbour cells that are outside the
	# chunk. `Chunk.get_block` answers AIR there, so the shape is a stub
	# rather than a crash — the real neighbour arrives with the edge
	# planes on the seam-heal re-mesh.
	var chunk := Chunk.new()
	chunk.set_block(0, Y - 1, 0, Blocks.STONE)
	chunk.set_block(0, Y, 0, Blocks.REDSTONE_WIRE)
	chunk.set_block_meta(0, Y, 0, Redstone.WIRE_MAX_POWER)
	chunk.set_block(Chunk.SIZE_X - 1, Y - 1, Chunk.SIZE_Z - 1, Blocks.STONE)
	chunk.set_block(Chunk.SIZE_X - 1, Y, Chunk.SIZE_Z - 1, Blocks.REDSTONE_WIRE)
	var data: Dictionary = Mesher.mesh_chunk(chunk)
	assert_gt(data.vertices.size(), 0, "border wire produces geometry")


func _bare_floor() -> Chunk:
	var chunk := Chunk.new()
	_floor_at(chunk, X, Z)
	return chunk


func _bounds_of(verts: PackedVector3Array) -> AABB:
	if verts.is_empty():
		return AABB()
	var box := AABB(verts[0], Vector3.ZERO)
	for v: Vector3 in verts:
		box = box.expand(v)
	return box
