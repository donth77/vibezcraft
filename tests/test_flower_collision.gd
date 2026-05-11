extends GutTest

# Verifies that worldgen-placed flowers produce a non-empty plant_faces
# soup in the meshed chunk dict — without it, the cross-quad collision
# never lands on `chunk_node._plants_shape` and the player's interaction
# raycast (which masks layers 1+2) misses the flower entirely. Symptom
# of a regression here: visible flowers that can't be selected/broken.


func before_each() -> void:
	BlockAtlas.reset()
	BlockAtlas.build()
	if Mesher._native_mesher == null:
		Mesher.enable_native()
	if Worldgen._native_worldgen == null:
		Worldgen.enable_native()


# Find the first worldgen chunk coord (within ±5) that ends up with at
# least one flower or mushroom placed. Determinism guarantees that on a
# given WORLD_SEED, the same coord always produces the same flowers, so
# tracking it down once is enough.
func _find_chunk_with_flowers() -> Dictionary:
	for cx in range(-5, 6):
		for cz in range(-5, 6):
			var chunk := Worldgen.generate_chunk(cx, cz)
			if not chunk.has_non_cube_blocks:
				continue
			# Verify at least one block is a flower or mushroom (vs e.g. fire).
			for i in range(Chunk.TOTAL_BLOCKS):
				var b: int = chunk.blocks[i]
				if (
					b == Blocks.FLOWER_RED
					or b == Blocks.FLOWER_YELLOW
					or b == Blocks.MUSHROOM_BROWN
					or b == Blocks.MUSHROOM_RED
				):
					return {"chunk": chunk, "coord": Vector2i(cx, cz)}
	return {}


func test_worldgen_chunk_with_flowers_produces_plant_faces() -> void:
	var found := _find_chunk_with_flowers()
	assert_false(found.is_empty(), "No chunk with flowers in [-5,5] range — scatter didn't fire")
	if found.is_empty():
		return
	var chunk: Chunk = found.chunk
	assert_true(
		chunk.has_non_cube_blocks,
		"chunk(%d,%d) has flowers but flag is false" % [found.coord.x, found.coord.y]
	)
	# Lighting first — the cross-quad emission samples per-cell sky/block light.
	Lighting.fill_sky_light(chunk)
	Lighting.fill_block_light(chunk)
	var data: Dictionary = Mesher.mesh_chunk_fast(chunk)
	assert_true(
		data.has("plant_faces"),
		"chunk(%d,%d) mesh missing plant_faces key" % [found.coord.x, found.coord.y]
	)
	if data.has("plant_faces"):
		var pf: PackedVector3Array = data.plant_faces
		assert_gt(
			pf.size(),
			0,
			"chunk(%d,%d) plant_faces empty despite flowers" % [found.coord.x, found.coord.y]
		)


# Same test, but exercises the GDScript reference path (non-native) so
# we cover both code paths.
# Simulates the runtime PLACE path: start with a chunk that has NO
# non-cube blocks, then write a flower via `set_block` (the same call
# the chunk_manager.set_world_block runtime path uses), and verify the
# resulting mesh includes plant_faces. Repros the user-reported bug:
# placed flowers are visually present but have no plant collision shape,
# so the player can't select/break them.
func test_placed_flower_after_set_block_produces_plant_faces() -> void:
	var chunk := Chunk.new()
	# Plant a single cell of grass at y=64, then place a flower above.
	chunk.set_block(5, 64, 5, Blocks.GRASS)
	# Verify clean state — no non-cube blocks yet.
	assert_false(chunk.has_non_cube_blocks, "Pre-place: flag should be false")
	# Simulate the place: same call set_world_block ends up making.
	chunk.set_block(5, 65, 5, Blocks.FLOWER_RED)
	assert_true(chunk.has_non_cube_blocks, "Post-place: flag must be true")
	Lighting.fill_sky_light(chunk)
	Lighting.fill_block_light(chunk)
	var data: Dictionary = Mesher.mesh_chunk_fast(chunk)
	assert_true(data.has("plant_faces"), "Post-place mesh missing plant_faces")
	if data.has("plant_faces"):
		assert_gt((data.plant_faces as PackedVector3Array).size(), 0, "plant_faces empty")


func test_gdscript_mesh_chunk_with_flowers_produces_plant_faces() -> void:
	var found := _find_chunk_with_flowers()
	assert_false(found.is_empty(), "No chunk with flowers found")
	if found.is_empty():
		return
	var chunk: Chunk = found.chunk
	Lighting.fill_sky_light(chunk)
	Lighting.fill_block_light(chunk)
	var data: Dictionary = Mesher.mesh_chunk(chunk)  # pure-GDScript path
	assert_true(data.has("plant_faces"), "GDScript mesh missing plant_faces key")
	if data.has("plant_faces"):
		assert_gt(
			(data.plant_faces as PackedVector3Array).size(), 0, "plant_faces empty (GDS path)"
		)
