extends GutTest

const ChunkManagerScript := preload("res://scripts/world/chunk_manager.gd")
const ChunkNodeScript := preload("res://scripts/world/chunk_node.gd")


func before_each() -> void:
	BlockAtlas.reset()


func test_empty_chunk_produces_no_geometry() -> void:
	var chunk := Chunk.new()
	var data := Mesher.mesh_chunk(chunk)
	assert_eq(data.vertices.size(), 0)
	assert_eq(data.indices.size(), 0)


func test_isolated_block_produces_six_faces() -> void:
	var chunk := Chunk.new()
	chunk.set_block(8, 64, 8, Blocks.STONE)
	var data := Mesher.mesh_chunk(chunk)
	# 6 faces × 4 verts = 24 verts, 6 faces × 6 indices = 36 indices
	assert_eq(data.vertices.size(), 24)
	assert_eq(data.indices.size(), 36)
	assert_eq(data.normals.size(), 24)
	assert_eq(data.uvs.size(), 24)


func test_alpha_test_flag_only_enables_discard_for_cutout_cubes() -> void:
	var opaque_chunk := Chunk.new()
	opaque_chunk.set_block(8, 64, 8, Blocks.STONE)
	var opaque_data := Mesher.mesh_chunk(opaque_chunk)
	assert_eq(opaque_data.colors.size(), 24)
	for color: Color in opaque_data.colors:
		assert_eq(color.a, 0.0, "opaque faces disable texture-alpha discard under MSAA")

	var cutout_chunk := Chunk.new()
	cutout_chunk.set_block(8, 64, 8, Blocks.LEAVES)
	var cutout_data := Mesher.mesh_chunk(cutout_chunk)
	assert_eq(cutout_data.colors.size(), 24)
	for color: Color in cutout_data.colors:
		assert_eq(color.a, 1.0, "cutout faces retain transparent-texel discard")


func test_alpha_test_flag_covers_opaque_and_cutout_special_geometry() -> void:
	# These meshes all use tight geometry over fully opaque atlas pixels.
	# They should receive the same MSAA-safe treatment as opaque cubes.
	var opaque_shapes: Array[int] = [
		Blocks.FENCE,
		Blocks.WOOD_STAIRS,
		Blocks.FENCE_GATE,
		Blocks.HALF_SLAB,
		Blocks.SIGN_STANDING,
		Blocks.SNOW_LAYER,
		Blocks.TORCH,
	]
	for id: int in opaque_shapes:
		var chunk := Chunk.new()
		chunk.set_block(8, 64, 8, id)
		var data := Mesher.mesh_chunk(chunk)
		assert_gt(data.colors.size(), 0, "opaque special shape %d emits geometry" % id)
		for color: Color in data.colors:
			assert_eq(color.a, 0.0, "opaque special shape %d disables discard" % id)

	# Sprite/window geometry still needs transparent texels removed.
	var cutout_shapes: Array[int] = [
		Blocks.LADDER,
		Blocks.WOODEN_DOOR,
		Blocks.SAPLING,
		Blocks.RAIL,
		Blocks.BED_FOOT,
	]
	for id: int in cutout_shapes:
		var chunk := Chunk.new()
		chunk.set_block(8, 64, 8, id)
		var data := Mesher.mesh_chunk(chunk)
		assert_gt(data.colors.size(), 0, "cutout special shape %d emits geometry" % id)
		for color: Color in data.colors:
			assert_eq(color.a, 1.0, "cutout special shape %d retains discard" % id)


func test_cached_block_entity_meshes_use_the_same_alpha_test_contract() -> void:
	var cases: Array = [
		[Blocks.STONE, 0.0],
		[Blocks.LEAVES, 1.0],
		[Blocks.FENCE, 0.0],
		[Blocks.WOODEN_DOOR, 1.0],
		[Blocks.TORCH, 0.0],
		[Blocks.LADDER, 1.0],
	]
	for case: Array in cases:
		var id: int = case[0]
		var expected_alpha: float = case[1]
		var mesh: ArrayMesh = BlockMesh.get_cube_mesh(id)
		var arrays: Array = mesh.surface_get_arrays(0)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		assert_eq(colors.size(), vertices.size(), "block entity %d colors every vertex" % id)
		for color: Color in colors:
			assert_eq(color.a, expected_alpha, "block entity %d preserves its cutout contract" % id)


func test_two_adjacent_blocks_cull_shared_face() -> void:
	var chunk := Chunk.new()
	chunk.set_block(5, 5, 5, Blocks.STONE)
	chunk.set_block(6, 5, 5, Blocks.STONE)
	var data := Mesher.mesh_chunk(chunk)
	# 12 faces total - 2 shared faces culled = 10 faces × 4 verts = 40
	assert_eq(data.vertices.size(), 40)
	assert_eq(data.indices.size(), 60)


func test_stack_of_three_culls_internal_faces() -> void:
	var chunk := Chunk.new()
	chunk.set_block(0, 5, 0, Blocks.STONE)
	chunk.set_block(0, 6, 0, Blocks.STONE)
	chunk.set_block(0, 7, 0, Blocks.STONE)
	var data := Mesher.mesh_chunk(chunk)
	# 18 faces total - 4 shared faces culled = 14 faces × 4 verts = 56
	assert_eq(data.vertices.size(), 56)


# --- complete chunk-seam state on the FIRST mesh -----------------------
# docs/lighting-chunk-seams.md Defect 2: Chunk.get_sky_light answers an OOB
# read with 15, so a chunk meshed without neighbor light planes paints its
# border faces full daylight — a bright stripe down cave walls whose true
# value is 0. chunk_manager._snapshot_neighbor_edge_planes now hands the
# worker block/meta/light planes, so the FIRST mesh already has real light
# and culls internal faces instead of waiting for the seam heal.


# Solid stone with a sealed pitch-dark cave carved the full width in X, so
# the pocket meets both chunk borders.
func _sealed_cave_chunk() -> Chunk:
	var c := Chunk.new()
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			for y in range(1, 60):
				c.set_block(x, y, z, Blocks.STONE)
	for x in range(Chunk.SIZE_X):
		for z in range(5, 11):
			for y in range(30, 35):
				c.set_block(x, y, z, Blocks.AIR)
	Lighting.fill_sky_light(c)
	Lighting.fill_block_light(c)
	return c


# Brightest sky-light the mesher packed onto a cave face lying on the given
# chunk-border plane.
func _max_seam_sky_light(chunk: Chunk, border_x: int) -> int:
	var data := Mesher.mesh_chunk(chunk)
	var verts: PackedVector3Array = data["vertices"]
	var cols: PackedColorArray = data["colors"]
	var worst := 0
	for i in range(verts.size()):
		var v: Vector3 = verts[i]
		if v.y < 29.5 or v.y > 35.5 or v.z < 4.5 or v.z > 11.5:
			continue
		if absf(v.x - float(border_x)) > 0.001:
			continue
		worst = maxi(worst, int(round(cols[i].r * 15.0)))
	return worst


func test_sealed_cave_seam_is_full_bright_without_neighbor_light() -> void:
	# The failure mode the fix removes — kept so a regression is loud.
	var c := _sealed_cave_chunk()
	assert_eq(
		_max_seam_sky_light(c, Chunk.SIZE_X), 15, "OOB default leaks daylight onto the seam face"
	)


func test_sealed_cave_first_mesh_samples_dark_complete_edge() -> void:
	var c := _sealed_cave_chunk()
	var planes: Array = _sealed_cave_chunk().west_edge_slices()
	c.edge_blocks_east = planes[0]
	c.edge_meta_east = planes[1]
	c.edge_sky_light_east = planes[2]
	c.edge_block_light_east = planes[3]
	assert_eq(
		_max_seam_sky_light(c, Chunk.SIZE_X), 0, "seam face samples the neighbor's real dark cave"
	)


func test_first_mesh_culls_shared_solid_face_from_complete_edge() -> void:
	var c := Chunk.new()
	c.set_block(Chunk.SIZE_X - 1, 20, 8, Blocks.STONE)
	var neighbor := Chunk.new()
	neighbor.set_block(0, 20, 8, Blocks.STONE)
	var planes: Array = neighbor.west_edge_slices()
	c.edge_blocks_east = planes[0]
	c.edge_meta_east = planes[1]
	c.edge_sky_light_east = planes[2]
	c.edge_block_light_east = planes[3]

	var data := Mesher.mesh_chunk(c)
	assert_eq(
		data.vertices.size(), 20, "the neighbor block culls the shared face on the first mesh"
	)


func test_complete_edge_planes_bind_and_clear() -> void:
	var c := Chunk.new()
	var planes: Array = _sealed_cave_chunk().west_edge_slices()
	ChunkManagerScript._set_edge_planes(c, {"east": planes})
	assert_false(c.edge_blocks_east.is_empty(), "block plane binds")
	assert_false(c.edge_meta_east.is_empty(), "metadata plane binds")
	assert_false(c.edge_sky_light_east.is_empty(), "supplied side binds")
	assert_true(c.edge_sky_light_west.is_empty(), "unsupplied side stays empty")
	ChunkManagerScript._set_edge_planes(c, {})
	assert_true(c.edge_blocks_east.is_empty(), "block plane clears")
	assert_true(c.edge_meta_east.is_empty(), "metadata plane clears")
	assert_true(c.edge_sky_light_east.is_empty(), "clear unbinds every side")
	assert_true(c.edge_block_light_east.is_empty(), "clear unbinds block light too")


func test_complete_edge_binding_matches_canonical_slices() -> void:
	var c := _sealed_cave_chunk()
	# Asymmetric values so a transposed or mis-strided layout cannot pass.
	c.set_sky_light(0, 40, 3, 7)
	c.set_block_light(Chunk.SIZE_X - 1, 41, 9, 11)
	c.set_sky_light(5, 42, 0, 4)
	c.set_block_light(9, 43, Chunk.SIZE_Z - 1, 13)
	var reference: Array = c.west_edge_slices()
	var snap := Chunk.new()
	ChunkManagerScript._set_edge_planes(snap, {"east": reference})
	assert_eq(snap.edge_blocks_east, reference[0])
	assert_eq(snap.edge_meta_east, reference[1])
	assert_eq(snap.edge_sky_light_east, reference[2])
	assert_eq(snap.edge_block_light_east, reference[3])


# WorkerThreadPool invokes the worker as `_compute_chunk_data.bind(...)`, so
# its arity is only resolved at call time — a signature drift would surface
# as a silent worker failure in-game rather than a parse error. Drive the
# real bound callable once and assert what it publishes.
func test_worker_entry_point_accepts_bound_complete_edge() -> void:
	var manager: Node = ChunkManagerScript.new()
	autofree(manager)
	var plane: Array = _sealed_cave_chunk().west_edge_slices()
	var coord := Vector2i(0, 0)
	var task: Callable = manager._compute_chunk_data.bind(coord, {}, {"east": plane})
	task.call()
	var results: Dictionary = manager._ready_results
	assert_true(results.has(coord), "worker published a result")
	var published: Chunk = results[coord]["chunk"]
	assert_false(results[coord]["mesh"].is_empty(), "worker produced mesh data")
	# The transient planes must not ride along onto the published chunk, or
	# relight / re-mesh / save would start seeing neighbor state they never
	# see today.
	assert_true(published.edge_blocks_east.is_empty(), "block plane cleared before publish")
	assert_true(published.edge_meta_east.is_empty(), "metadata plane cleared before publish")
	assert_true(published.edge_sky_light_east.is_empty(), "light plane cleared before publish")
	assert_true(published.edge_block_light_east.is_empty(), "block-light plane cleared too")


func test_neighbor_edge_signature_changes_on_arrival_edit_and_unload() -> void:
	var manager: Node = ChunkManagerScript.new()
	autofree(manager)
	var neighbor_node := ChunkNodeScript.new()
	autofree(neighbor_node)
	neighbor_node.chunk = Chunk.new()
	manager._chunks[Vector2i(1, 0)] = neighbor_node

	var arrived: Dictionary = manager._snapshot_neighbor_edge_planes(Vector2i.ZERO)
	var arrived_signature: Dictionary = arrived["_signature"]
	assert_true(arrived_signature.has("east"), "arrival is represented in the signature")

	neighbor_node.chunk.set_block_unchecked(0, 20, 8, Blocks.STONE)
	var edited: Dictionary = manager._snapshot_neighbor_edge_planes(Vector2i.ZERO)
	assert_ne(
		edited["_signature"],
		arrived_signature,
		"a border-affecting block revision invalidates an in-flight first mesh"
	)

	manager._chunks.erase(Vector2i(1, 0))
	var unloaded: Dictionary = manager._snapshot_neighbor_edge_planes(Vector2i.ZERO)
	assert_false(unloaded["_signature"].has("east"), "unload invalidates the captured edge")


func test_ready_chunk_remesh_uses_latest_edge_before_presentation() -> void:
	var manager: Node = ChunkManagerScript.new()
	autofree(manager)
	var target := Chunk.new()
	target.set_block_unchecked(Chunk.SIZE_X - 1, 20, 8, Blocks.STONE)
	var stale_mesh: Dictionary = Mesher.mesh_chunk(target)
	assert_eq(stale_mesh.vertices.size(), 24, "stale mesh exposes all isolated-block faces")
	var neighbor := Chunk.new()
	neighbor.set_block_unchecked(0, 20, 8, Blocks.STONE)
	var signature: Dictionary = {"east": [neighbor.get_instance_id(), neighbor.lighting_revision]}
	var latest_edges: Dictionary = {
		"east": neighbor.west_edge_slices(),
		"_signature": signature,
	}
	var coord := Vector2i.ZERO
	manager._remesh_ready_chunk(
		coord, {"chunk": target, "mesh": stale_mesh, "edge_signature": {}}, latest_edges
	)

	var refreshed: Dictionary = manager._ready_results[coord]
	assert_eq(refreshed.mesh.vertices.size(), 20, "latest neighbor culls the internal face")
	assert_eq(refreshed.edge_signature, signature)
	assert_true(target.edge_blocks_east.is_empty(), "transient planes clear before publication")


func test_unload_backing_shell_waits_for_survivor_mesh_apply() -> void:
	var manager: Node = ChunkManagerScript.new()
	autofree(manager)
	var outgoing := ChunkNodeScript.new()
	var survivor := ChunkNodeScript.new()
	autofree(outgoing)
	autofree(survivor)
	var survivor_coord := Vector2i(1, 0)
	manager._chunks[survivor_coord] = survivor
	manager._retiring_chunks[Vector2i.ZERO] = {
		"node": outgoing,
		"gates":
		[
			{
				"coord": survivor_coord,
				"node": survivor,
				"apply_revision": 0,
			}
		],
	}

	manager._drain_retiring_chunks()
	assert_true(
		manager._retiring_chunks.has(Vector2i.ZERO),
		"outgoing mesh remains while the newly exposed boundary is absent"
	)
	assert_false(outgoing.is_queued_for_deletion())

	survivor._mesh_apply_revision = 1
	manager._drain_retiring_chunks()
	assert_false(manager._retiring_chunks.has(Vector2i.ZERO))
	assert_true(outgoing.is_queued_for_deletion(), "shell retires only after safe replacement")


func test_unload_backing_shell_does_not_wait_for_an_evicted_survivor() -> void:
	var manager: Node = ChunkManagerScript.new()
	autofree(manager)
	var outgoing := ChunkNodeScript.new()
	var former_survivor := ChunkNodeScript.new()
	autofree(outgoing)
	autofree(former_survivor)
	manager._retiring_chunks[Vector2i.ZERO] = {
		"node": outgoing,
		"gates":
		[
			{
				"coord": Vector2i(1, 0),
				"node": former_survivor,
				"apply_revision": 0,
			}
		],
	}

	manager._drain_retiring_chunks()
	assert_true(outgoing.is_queued_for_deletion())
	assert_true(manager._retiring_chunks.is_empty())
