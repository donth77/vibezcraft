extends GutTest


func test_new_chunk_is_all_air() -> void:
	var chunk := Chunk.new()
	assert_eq(chunk.get_block(0, 0, 0), Blocks.AIR)
	assert_eq(chunk.get_block(15, 127, 15), Blocks.AIR)


func test_set_get_roundtrip() -> void:
	var chunk := Chunk.new()
	chunk.set_block(5, 64, 7, Blocks.STONE)
	assert_eq(chunk.get_block(5, 64, 7), Blocks.STONE)


func test_extreme_corners() -> void:
	var chunk := Chunk.new()
	chunk.set_block(0, 0, 0, Blocks.BEDROCK)
	chunk.set_block(15, 127, 15, Blocks.BEDROCK)
	assert_eq(chunk.get_block(0, 0, 0), Blocks.BEDROCK)
	assert_eq(chunk.get_block(15, 127, 15), Blocks.BEDROCK)


func test_out_of_bounds_get_returns_air() -> void:
	var chunk := Chunk.new()
	assert_eq(chunk.get_block(-1, 0, 0), Blocks.AIR)
	assert_eq(chunk.get_block(16, 0, 0), Blocks.AIR)
	assert_eq(chunk.get_block(0, 128, 0), Blocks.AIR)
	assert_eq(chunk.get_block(0, 0, -1), Blocks.AIR)


func test_out_of_bounds_set_is_silently_ignored() -> void:
	var chunk := Chunk.new()
	chunk.set_block(-1, 0, 0, Blocks.STONE)
	chunk.set_block(20, 0, 0, Blocks.STONE)
	# In-bounds neighbor is unaffected
	assert_eq(chunk.get_block(0, 0, 0), Blocks.AIR)


func test_set_marks_dirty() -> void:
	var chunk := Chunk.new()
	chunk.dirty = false
	chunk.set_block(0, 0, 0, Blocks.STONE)
	assert_true(chunk.dirty)
