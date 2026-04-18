extends GutTest


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


func test_two_adjacent_blocks_each_emit_full_cubes() -> void:
	var chunk := Chunk.new()
	chunk.set_block(5, 5, 5, Blocks.STONE)
	chunk.set_block(6, 5, 5, Blocks.STONE)
	var data := Mesher.mesh_chunk(chunk)
	# No culling: 2 blocks × 6 faces × 4 verts = 48
	assert_eq(data.vertices.size(), 48)
	assert_eq(data.indices.size(), 72)


func test_stack_of_three_emits_full_cubes() -> void:
	var chunk := Chunk.new()
	chunk.set_block(0, 5, 0, Blocks.STONE)
	chunk.set_block(0, 6, 0, Blocks.STONE)
	chunk.set_block(0, 7, 0, Blocks.STONE)
	var data := Mesher.mesh_chunk(chunk)
	# No culling: 3 blocks × 6 faces × 4 verts = 72
	assert_eq(data.vertices.size(), 72)
