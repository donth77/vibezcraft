extends GutTest

# What the Nether's light channels actually contain, measured rather than
# reasoned about.
#
# The playtest report is "staggering between light and dark areas way too
# much". The ambient floor was one confirmed cause (om.java:21's 0.1 was
# never reaching the renderer), but a floor only lifts the dark end — it
# cannot produce BRIGHT patches. Anything fully lit in a dimension with no
# sky has to come from the sky channel, and this codebase deliberately
# answers sky = 15 for unloaded neighbours and above the world top.

var _dimension_was: int = 0


func before_each() -> void:
	_dimension_was = DimensionContext.active()


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)


# Build a Nether chunk the way the world actually does, then fill light.
func _nether_chunk(cx: int, cz: int) -> Chunk:
	DimensionContext.set_active(DimensionContext.NETHER)
	var chunk: Chunk = DimensionContext.provider(DimensionContext.NETHER).generate_chunk(cx, cz)
	Lighting.fill_sky_light(chunk)
	Lighting.fill_block_light(chunk)
	return chunk


func _histogram(chunk: Chunk, sky: bool) -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(16)
	counts.fill(0)
	for y: int in range(Chunk.SIZE_Y):
		for z: int in range(Chunk.SIZE_Z):
			for x: int in range(Chunk.SIZE_X):
				var level: int = (
					chunk.get_sky_light(x, y, z) if sky else chunk.get_block_light(x, y, z)
				)
				counts[clampi(level, 0, 15)] += 1
	return counts


func test_the_nether_stores_no_sky_light_anywhere() -> void:
	# om.java has no sky. A single lit sky cell renders as a fully bright
	# face regardless of the ambient floor, because the shader takes
	# max(sky - subtraction, block) and the Nether pushes subtraction 0.
	var chunk: Chunk = _nether_chunk(0, 0)
	var counts: PackedInt32Array = _histogram(chunk, true)
	var lit: int = 0
	for level: int in range(1, 16):
		lit += counts[level]
	gut.p("nether sky-light histogram: %s" % str(counts))
	assert_eq(lit, 0, "no cell in the Nether may carry sky light")


func test_the_nether_is_lit_by_its_block_sources() -> void:
	# The other half: if block light is ALSO near-empty, the dimension is
	# uniformly at the ambient floor and the complaint would be flatness,
	# not staggering. Lava and glowstone are the Nether's only sources.
	var chunk: Chunk = _nether_chunk(0, 0)
	var counts: PackedInt32Array = _histogram(chunk, false)
	var lit: int = 0
	for level: int in range(1, 16):
		lit += counts[level]
	gut.p("nether block-light histogram: %s" % str(counts))
	assert_gt(lit, 0, "the Nether has block-light sources (lava at minimum)")
