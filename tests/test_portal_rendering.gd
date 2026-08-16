extends GutTest

# Portal presentation — the 32-frame texture, the shared material, and the
# display tick that drives sound and particles.
# (docs/nether-alpha-1.2.6-implementation-plan.md §7.1, Batch 7.)
#
# The plan is specific about two things that are easy to get wrong and
# invisible until they bite: the generated texture must be byte-identical
# every session (`Random(100)`, walked in a fixed order), and there must be
# ONE material and ONE texture for every portal in the world rather than
# one per block or per chunk.

const _FIXTURE := "res://tests/fixtures/portal_texture_hashes.json"


class FakeWorld:
	extends Node

	var blocks: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id


func before_each() -> void:
	PortalIndex.reset()


func after_all() -> void:
	PortalIndex.reset()


func _fixture() -> Dictionary:
	var f := FileAccess.open(_FIXTURE, FileAccess.READ)
	assert_not_null(f, "the pinned hash fixture exists")
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed as Dictionary


# --- Texture determinism ---


func test_every_frame_matches_its_pinned_hash() -> void:
	# The strongest statement available about the generator: not "it is
	# stable within a run" but "it produces these exact bytes". A change to
	# the sine table, the RNG, the loop order or the colour maths moves at
	# least one of these.
	var fixture: Dictionary = _fixture()
	if fixture.is_empty():
		return
	var expected: Array = fixture["frame_hashes"]
	assert_eq(expected.size(), PortalTexture.FRAMES, "the fixture covers every frame")
	for i: int in range(PortalTexture.FRAMES):
		assert_eq(PortalTexture.frame_hash(i), str(expected[i]), "frame %d is byte-identical" % i)


func test_the_generator_parameters_match_the_source() -> void:
	var fixture: Dictionary = _fixture()
	if fixture.is_empty():
		return
	assert_eq(PortalTexture.SEED, int(fixture["seed"]), "et.java:13 seeds with a literal 100")
	assert_eq(PortalTexture.FRAMES, int(fixture["frames"]), "32 frames")
	assert_eq(PortalTexture.SIZE, int(fixture["size"]), "16x16 each")


func test_rebuilding_from_scratch_reproduces_the_same_frames() -> void:
	var before: String = PortalTexture.frame_hash(7)
	PortalTexture.reset()
	assert_eq(PortalTexture.frame_hash(7), before, "a fresh build is the same build")


# --- The strip the shader samples ---


func test_the_strip_stacks_all_frames_in_order() -> void:
	var strip: ImageTexture = PortalTexture.strip_texture()
	assert_eq(strip.get_width(), PortalTexture.SIZE, "one frame wide")
	assert_eq(
		strip.get_height(), PortalTexture.SIZE * PortalTexture.FRAMES, "thirty-two frames tall"
	)


func test_the_strip_rows_are_the_frames() -> void:
	# Spot-check that frame N really occupies rows [N*16, N*16+16). If the
	# blit order were wrong the animation would still play, just scrambled
	# — which is exactly the kind of bug a size assertion misses.
	var strip: Image = PortalTexture.strip_texture().get_image()
	for frame: int in [0, 1, 17, 31]:
		var source: Image = PortalTexture.frame_image(frame)
		assert_eq(
			strip.get_pixel(3, frame * PortalTexture.SIZE + 5),
			source.get_pixel(3, 5),
			"strip row for frame %d comes from frame %d" % [frame, frame]
		)


func test_the_strip_matches_its_pinned_hash() -> void:
	var fixture: Dictionary = _fixture()
	if fixture.is_empty():
		return
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(PortalTexture.strip_texture().get_image().get_data())
	assert_eq(ctx.finish().hex_encode(), str(fixture["strip_hash"]), "the strip is byte-identical")


# --- Resource sharing ---


func test_the_strip_texture_is_one_shared_instance() -> void:
	assert_same(
		PortalTexture.strip_texture(),
		PortalTexture.strip_texture(),
		"asking twice returns the same texture, not a copy"
	)


func test_the_portal_material_is_one_shared_instance() -> void:
	# The plan: "Use one shared material/texture resource, not one material
	# per block or chunk."
	BlockAtlas.reset()
	var first: ShaderMaterial = BlockAtlas.portal_material()
	var second: ShaderMaterial = BlockAtlas.portal_material()
	assert_same(first, second, "one material for every portal in the world")
	assert_not_null(first.shader, "and it has the portal shader bound")


func test_the_material_binds_the_strip_and_the_source_cadence() -> void:
	BlockAtlas.reset()
	var mat: ShaderMaterial = BlockAtlas.portal_material()
	assert_same(
		mat.get_shader_parameter("frames"),
		PortalTexture.strip_texture(),
		"the material samples the shared strip"
	)
	assert_almost_eq(
		float(mat.get_shader_parameter("frames_per_second")),
		20.0,
		1e-4,
		"vanilla advances one frame per client tick"
	)
	assert_eq(int(mat.get_shader_parameter("frame_count")), 32, "over 32 frames")


func test_two_renderers_still_share_one_material() -> void:
	BlockAtlas.reset()
	var a := PortalRenderer.new()
	var b := PortalRenderer.new()
	autofree(a)
	autofree(b)
	add_child_autofree(a)
	add_child_autofree(b)
	assert_same(
		a.get_node("PortalCells").material_override,
		b.get_node("PortalCells").material_override,
		"two renderers, one material"
	)


# --- Cadence ---


func test_the_animation_advances_at_twenty_hertz_and_wraps() -> void:
	# Sampled mid-frame rather than on the boundaries. A tick boundary is
	# knife-edge in binary floating point — 1.65 / 0.05 evaluates to
	# 32.99999999999999, one ulp short of 33 — so an exact multiple can
	# legitimately answer either side. Mid-frame is what a caller
	# accumulating real time actually asks about, and it is unambiguous.
	assert_eq(PortalTexture.frame_at(0.0), 0, "starts at frame 0")
	assert_eq(PortalTexture.frame_at(0.07), 1, "one tick in, frame 1")
	assert_eq(PortalTexture.frame_at(0.77), 15, "fifteen ticks in, frame 15")
	assert_eq(PortalTexture.frame_at(1.57), 31, "the last frame of the loop")
	assert_eq(PortalTexture.frame_at(1.62), 0, "32 ticks wraps back to the start")
	assert_eq(PortalTexture.frame_at(1.67), 1, "and it keeps going")


# --- The display tick ---


func test_the_renderer_draws_one_instance_per_portal_cell() -> void:
	var renderer := PortalRenderer.new()
	add_child_autofree(renderer)
	var w := FakeWorld.new()
	autofree(w)
	for along: int in range(2):
		for up: int in range(3):
			w.set_world_block(Vector3i(along, 64 + up, 0), Blocks.PORTAL)
	PortalIndex.record_sheet(DimensionContext.active(), [Vector3i(0, 64, 0), Vector3i(1, 64, 0)])
	renderer.set_world(w)
	var mm: MultiMesh = renderer.get_node("PortalCells").multimesh
	assert_eq(mm.instance_count, 6, "a 2x3 sheet is six drawn cells")


func test_the_renderer_draws_nothing_for_a_portal_that_is_gone() -> void:
	var renderer := PortalRenderer.new()
	add_child_autofree(renderer)
	var w := FakeWorld.new()
	autofree(w)
	# The index remembers a portal the world no longer has.
	PortalIndex.record(DimensionContext.active(), Vector3i(0, 64, 0))
	renderer.set_world(w)
	assert_eq(
		renderer.get_node("PortalCells").multimesh.instance_count, 0, "a stale hint draws nothing"
	)


func test_the_renderer_bounds_its_particle_emitters() -> void:
	# The plan: no unbounded particle or voice growth. A wall of portal
	# cells must not become a wall of emitters.
	var renderer := PortalRenderer.new()
	add_child_autofree(renderer)
	var w := FakeWorld.new()
	autofree(w)
	var bottoms: Array[Vector3i] = []
	for column: int in range(20):
		for up: int in range(3):
			w.set_world_block(Vector3i(column, 64 + up, 0), Blocks.PORTAL)
		bottoms.append(Vector3i(column, 64, 0))
	for bottom: Vector3i in bottoms:
		PortalIndex.record(DimensionContext.active(), bottom)
	renderer.set_world(w)
	var emitters: int = 0
	for child: Node in renderer.get_children():
		if child is CPUParticles3D and (child as CPUParticles3D).emitting:
			emitters += 1
	assert_eq(
		renderer.get_node("PortalCells").multimesh.instance_count, 60, "all sixty cells are drawn"
	)
	assert_eq(emitters, PortalRenderer.EFFECT_CELLS, "but only six of them emit")


func test_the_ambient_gate_is_one_in_a_hundred_per_cell_per_tick() -> void:
	# Not a statistical test of the RNG — a statement about the CONSTANT,
	# which is the thing x.java pins and the thing a refactor can silently
	# change into "once a second".
	assert_eq(NetherPortal.AMBIENT_SOUND_CHANCE, 100, "x.java:129 — nextInt(100) == 0")
	assert_eq(NetherPortal.PARTICLES_PER_TICK, 4, "x.java:133 — four particles per tick")


func test_particles_orient_across_the_sheet_not_along_it() -> void:
	# x.java:144-149 — the drift is perpendicular to the sheet. An emitter
	# box that is thin on the wrong axis puts the swirl inside the obsidian
	# frame instead of in front of the player.
	var renderer := PortalRenderer.new()
	add_child_autofree(renderer)
	var w := FakeWorld.new()
	autofree(w)
	# A sheet running along X: two cells side by side on the X axis.
	for along: int in range(2):
		for up: int in range(3):
			w.set_world_block(Vector3i(along, 64 + up, 0), Blocks.PORTAL)
	PortalIndex.record_sheet(DimensionContext.active(), [Vector3i(0, 64, 0), Vector3i(1, 64, 0)])
	renderer.set_world(w)
	var emitter: CPUParticles3D = null
	for child: Node in renderer.get_children():
		if child is CPUParticles3D and (child as CPUParticles3D).emitting:
			emitter = child as CPUParticles3D
			break
	assert_not_null(emitter, "there is an emitter")
	if emitter != null:
		assert_lt(
			emitter.emission_box_extents.z,
			emitter.emission_box_extents.x,
			"an X-axis sheet is thin across Z"
		)
