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
	var gds: Dictionary = Mesher.mesh_chunk(chunk)
	var native = ClassDB.instantiate("MesherNative")
	var nat: Dictionary = native.mesh_chunk_data(
		chunk.blocks, chunk.max_y, BlockAtlas.uv_table_flat()
	)
	return [gds, nat]


func _assert_parity(gds: Dictionary, nat: Dictionary, label: String) -> void:
	assert_eq(nat.vertices.size(), gds.vertices.size(), "%s: vertex count" % label)
	assert_eq(nat.normals.size(), gds.normals.size(), "%s: normal count" % label)
	assert_eq(nat.uvs.size(), gds.uvs.size(), "%s: uv count" % label)
	assert_eq(nat.indices.size(), gds.indices.size(), "%s: index count" % label)
	# Byte-identical Packed arrays — any drift in winding, UV order, or
	# vertex position blows this up.
	assert_eq(nat.vertices, gds.vertices, "%s: vertices byte-equal" % label)
	assert_eq(nat.normals, gds.normals, "%s: normals byte-equal" % label)
	assert_eq(nat.uvs, gds.uvs, "%s: uvs byte-equal" % label)
	assert_eq(nat.indices, gds.indices, "%s: indices byte-equal" % label)


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
	# stratified layers, ore veins, and trees. Any difference in cull
	# rule, face winding, UV lookup, or vertex position surfaces here.
	var chunk := Worldgen.generate_chunk(0, 0)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "worldgen chunk (0,0)")


func test_parity_offset_worldgen_chunk() -> void:
	# Second worldgen chunk at a different coord to exercise different
	# ore/tree placements. Independent sanity check.
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
