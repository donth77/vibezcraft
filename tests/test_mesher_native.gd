extends GutTest

# Integration + parity tests for the MesherNative GDExtension.
#
# The scaffold tests (class registration, ping()) prove the toolchain
# works end to end. The parity tests guarantee the native implementation
# produces byte-identical output to the GDScript Mesher — this is the
# regression guard that lets us eventually swap ChunkManager over to
# the native path without visual/collision differences.


func before_each() -> void:
	BlockAtlas.reset()
	BlockAtlas.build()


# --- Scaffold ---


func test_class_is_registered() -> void:
	assert_true(
		ClassDB.class_exists("MesherNative"),
		"MesherNative not registered — did the .gdextension load? Rebuild via `scons`."
	)


func test_ping_returns_expected_string() -> void:
	var mn = ClassDB.instantiate("MesherNative")
	assert_not_null(mn, "failed to instantiate MesherNative")
	assert_eq(mn.ping(), "native mesher stub alive")


# --- Parity ---


func _mesh_both(chunk: Chunk) -> Array:
	# Use the lit native path so per-vertex COLOR matches the GDScript
	# Mesher.mesh_chunk output. The unlit `mesh_chunk_data` is still bound
	# for back-compat but no longer used by ChunkManager.
	Lighting.fill_sky_light(chunk)
	var gds: Dictionary = Mesher.mesh_chunk(chunk)
	var native = ClassDB.instantiate("MesherNative")
	# Edge slices empty — fixtures don't populate neighbors. Matches how
	# a freshly-loaded chunk with no adjacent chunks meshes.
	var empty := PackedByteArray()
	var nat: Dictionary = native.mesh_chunk_data_lit(
		chunk.blocks,
		chunk.block_meta,
		chunk.sky_light,
		chunk.block_light,
		chunk.max_y,
		BlockAtlas.uv_table_flat(),
		empty,
		empty,
		empty,
		empty,
		empty,
		empty,
		empty,
		empty
	)
	# Append non-cube geometry (cross-quads, torches, doors, fence, stairs)
	# the same way `mesh_chunk_fast` does in production. The native path
	# only emits cubes; non-cube shapes (saplings, flowers, mushrooms,
	# torches, …) come from `_append_non_cube_geometry` running on top.
	# Without this, any chunk containing a non-cube block diverges from
	# the GDScript reference simply because the appendix wasn't called.
	if chunk.has_non_cube_blocks:
		Mesher._append_non_cube_geometry(chunk, nat)
	return [gds, nat]


func _assert_parity(gds: Dictionary, nat: Dictionary, label: String) -> void:
	assert_eq(nat.vertices.size(), gds.vertices.size(), "%s: vertex count" % label)
	assert_eq(nat.normals.size(), gds.normals.size(), "%s: normal count" % label)
	assert_eq(nat.uvs.size(), gds.uvs.size(), "%s: uv count" % label)
	assert_eq(nat.indices.size(), gds.indices.size(), "%s: index count" % label)
	assert_eq(nat.colors.size(), gds.colors.size(), "%s: color count" % label)
	# Byte-identical Packed arrays — any drift in winding, UV order, or
	# vertex position blows this up.
	assert_eq(nat.vertices, gds.vertices, "%s: vertices byte-equal" % label)
	assert_eq(nat.normals, gds.normals, "%s: normals byte-equal" % label)
	assert_eq(nat.uvs, gds.uvs, "%s: uvs byte-equal" % label)
	assert_eq(nat.indices, gds.indices, "%s: indices byte-equal" % label)
	assert_eq(nat.colors, gds.colors, "%s: colors byte-equal" % label)
	# Water + lava sub-mesh parity — native emits both fluids via
	# emit_fluid_cell, byte-equal to GDScript's _emit_fluid_faces.
	assert_eq(
		nat.water_vertices.size(), gds.water_vertices.size(), "%s: water vertex count" % label
	)
	assert_eq(nat.water_vertices, gds.water_vertices, "%s: water vertices byte-equal" % label)
	assert_eq(nat.water_normals, gds.water_normals, "%s: water normals byte-equal" % label)
	assert_eq(nat.water_uvs, gds.water_uvs, "%s: water uvs byte-equal" % label)
	# Water per-vertex COLOR (sky/15 in R, block/15 in G) — emitted only on
	# the lit path. Byte-equal across native and GDScript so the day/night
	# driver's sky_factor uniform produces the same brightness.
	assert_eq(
		nat.get("water_colors", PackedColorArray()),
		gds.water_colors,
		"%s: water colors byte-equal" % label
	)
	assert_eq(nat.water_indices, gds.water_indices, "%s: water indices byte-equal" % label)
	assert_eq(
		nat.get("lava_vertices", PackedVector3Array()).size(),
		gds.lava_vertices.size(),
		"%s: lava vertex count" % label
	)
	assert_eq(
		nat.get("lava_vertices", PackedVector3Array()),
		gds.lava_vertices,
		"%s: lava vertices byte-equal" % label
	)
	assert_eq(
		nat.get("lava_normals", PackedVector3Array()),
		gds.lava_normals,
		"%s: lava normals byte-equal" % label
	)
	assert_eq(
		nat.get("lava_uvs", PackedVector2Array()), gds.lava_uvs, "%s: lava uvs byte-equal" % label
	)
	assert_eq(
		nat.get("lava_colors", PackedColorArray()),
		gds.lava_colors,
		"%s: lava colors byte-equal" % label
	)
	assert_eq(
		nat.get("lava_indices", PackedInt32Array()),
		gds.lava_indices,
		"%s: lava indices byte-equal" % label
	)


func test_parity_empty_chunk() -> void:
	var chunk := Chunk.new()
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "empty chunk")
	assert_eq(both[1].vertices.size(), 0, "empty chunk yields 0 vertices")


func test_parity_single_stone_block() -> void:
	var chunk := Chunk.new()
	chunk.set_block(8, 64, 8, Blocks.STONE)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "single stone block")
	assert_eq(both[1].vertices.size(), 24, "6 faces × 4 verts")


func test_parity_two_adjacent_blocks() -> void:
	var chunk := Chunk.new()
	chunk.set_block(5, 5, 5, Blocks.STONE)
	chunk.set_block(6, 5, 5, Blocks.STONE)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "two adjacent blocks (culled face)")


func test_parity_full_worldgen_chunk() -> void:
	# The real regression guard — a realistic chunk with heightmap,
	# stratified layers, ore veins, caves (with lava), and trees. Any
	# difference in cull rule, face winding, UV lookup, vertex position,
	# or tapered-fluid corner heights surfaces here.
	var chunk := Worldgen.generate_chunk(0, 0)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "worldgen chunk (0,0)")


func test_parity_offset_worldgen_chunk() -> void:
	# Second worldgen chunk at a different coord to exercise different
	# ore/tree/cave-lava placements. Independent sanity check.
	var chunk := Worldgen.generate_chunk(3, -2)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "worldgen chunk (3,-2)")


func test_parity_grass_column_exercises_all_three_face_kinds() -> void:
	# Grass has distinct textures for top / bottom / side, so this chunk
	# forces every FACE_KIND index to resolve correctly.
	var chunk := Chunk.new()
	chunk.set_block(8, 40, 8, Blocks.GRASS)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "isolated grass block")


func test_parity_water_surface_cell() -> void:
	# Single surface-layer water cell (AIR above) — native must emit the
	# SURFACE_DROP top vertex, correct face culling against AIR neighbors,
	# and match _emit_water_faces byte-for-byte including the chunk-local
	# UV convention (u0=x, v0=z/y).
	var chunk := Chunk.new()
	chunk.set_block(4, 64, 4, Blocks.WATER_STILL)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "single surface water cell")
	assert_gt(both[1].water_vertices.size(), 0, "water cell emits water faces")


func test_parity_water_column_culls_internal_faces() -> void:
	# Two stacked water cells — the shared internal face must cull on
	# both sides (same-id rule). Only the lower cell's top is non-surface
	# (above is water), so it stays a full cube; the upper cell is surface.
	var chunk := Chunk.new()
	chunk.set_block(8, 62, 8, Blocks.WATER_STILL)
	chunk.set_block(8, 63, 8, Blocks.WATER_STILL)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "stacked water column")


func test_parity_water_next_to_stone() -> void:
	# Water adjacent to an opaque stone cell — per BlockFluids.d(), water
	# does NOT emit its face toward stone (stone owns that boundary). The
	# stone face toward water still emits (is_opaque(water) == false).
	var chunk := Chunk.new()
	chunk.set_block(5, 64, 5, Blocks.WATER_STILL)
	chunk.set_block(6, 64, 5, Blocks.STONE)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "water next to stone")


func test_parity_worldgen_chunk_with_water() -> void:
	# A chunk from a region that gets ocean fill — exercises water meshing
	# at realistic density. Coord picked from the beach-band sweep in
	# test_worldgen so the generated chunk is guaranteed to contain water.
	var chunk := Worldgen.generate_chunk(-3, 3)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "worldgen chunk with ocean water")


func test_water_flow_vector_points_at_lower_neighbor() -> void:
	# Source water at (5, 64, 5) with a level-3 flowing neighbor at (6, 64, 5).
	# Vanilla flow algorithm sums (neighbor_offset * level_diff) over the 4
	# horizontal neighbors. With only one fluid neighbor, the sum is
	# (+1, 0) * (3 - 0) = (3, 0). Normalized → (1, 0), packed into Color.b
	# as (1*0.5+0.5)=1.0, Color.a as (0*0.5+0.5)=0.5. Both native and
	# GDScript paths must agree — this is the only place that exercises a
	# *non-zero* flow encoding (worldgen oceans are mostly static sources).
	var chunk := Chunk.new()
	chunk.set_block(5, 64, 5, Blocks.WATER_STILL)
	chunk.set_block(6, 64, 5, Blocks.WATER_FLOWING)
	chunk.set_block_meta(6, 64, 5, 3)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "water source with one flowing neighbor")
	# Encoded flow on the source cell: B=1.0 (flow.x=+1), A=0.5 (flow.z=0).
	# Pull any vertex from the source cell's contribution. A source's first
	# face emit is +Y at base index 0 (water_colors[0]).
	assert_gt(both[1].water_colors.size(), 0, "source cell emits water faces")
	var c0: Color = both[1].water_colors[0]
	assert_almost_eq(c0.b, 1.0, 0.001, "flow.x encoded → 1.0 (cell flows +X)")
	assert_almost_eq(c0.a, 0.5, 0.001, "flow.z encoded → 0.5 (no Z flow)")


# --- Collision parity ---


# Guards the trimesh-on-worker optimization. The face soup emitted by
# MesherNative must produce a ConcavePolygonShape3D byte-equivalent to
# the one ArrayMesh.create_trimesh_shape() produces from the render mesh.
# If they ever diverge, the collision mesh won't match the visual mesh.
func _collision_faces_via_old_path(chunk: Chunk) -> PackedVector3Array:
	var gds: Dictionary = Mesher.mesh_chunk(chunk)
	if gds.vertices.is_empty():
		return PackedVector3Array()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = gds.vertices
	arrays[Mesh.ARRAY_NORMAL] = gds.normals
	arrays[Mesh.ARRAY_TEX_UV] = gds.uvs
	arrays[Mesh.ARRAY_INDEX] = gds.indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var shape: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	return shape.get_faces() if shape != null else PackedVector3Array()


func test_parity_collision_faces_single_block() -> void:
	var chunk := Chunk.new()
	chunk.set_block(8, 64, 8, Blocks.STONE)
	var native = ClassDB.instantiate("MesherNative")
	var empty := PackedByteArray()
	var data: Dictionary = native.mesh_chunk_data(
		chunk.blocks,
		chunk.block_meta,
		chunk.max_y,
		BlockAtlas.uv_table_flat(),
		empty,
		empty,
		empty,
		empty,
		empty,
		empty,
		empty,
		empty
	)
	var native_faces: PackedVector3Array = data.collision_faces
	var expected := _collision_faces_via_old_path(chunk)
	assert_eq(native_faces.size(), expected.size(), "single block: collision face count")
	assert_eq(native_faces, expected, "single block: collision faces byte-equal")


func test_parity_collision_faces_worldgen_chunk() -> void:
	var chunk := Worldgen.generate_chunk(0, 0)
	var native = ClassDB.instantiate("MesherNative")
	var empty := PackedByteArray()
	var data: Dictionary = native.mesh_chunk_data(
		chunk.blocks,
		chunk.block_meta,
		chunk.max_y,
		BlockAtlas.uv_table_flat(),
		empty,
		empty,
		empty,
		empty,
		empty,
		empty,
		empty,
		empty
	)
	var native_faces: PackedVector3Array = data.collision_faces
	var expected := _collision_faces_via_old_path(chunk)
	assert_eq(native_faces.size(), expected.size(), "worldgen: collision face count")
	assert_eq(native_faces, expected, "worldgen: collision faces byte-equal")
