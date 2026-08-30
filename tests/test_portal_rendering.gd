# gdlint: disable=max-public-methods
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

	# BlockFire.place writes fire with metadata when the portal check
	# fails, and schedules its first tick.
	func set_world_block_with_meta(pos: Vector3i, id: int, _meta: int) -> void:
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


# --- The chunk mesher must not see it ---


func _meshed_chunk(with_portal: bool) -> Dictionary:
	# A floor, a pillar STANDING AGAINST the portal cells, and the sheet
	# itself. The pillar matters: its faces toward the portal must be
	# emitted (portal is non-opaque), which catches the native mesher's
	# own opaque-mirror treating an unknown id as solid.
	var chunk := Chunk.new()
	for x: int in range(16):
		for z: int in range(16):
			chunk.set_block(x, 64, z, Blocks.NETHERRACK)
	for up: int in range(3):
		chunk.set_block(6, 65 + up, 7, Blocks.NETHERRACK)
		if with_portal:
			chunk.set_block(7, 65 + up, 7, Blocks.PORTAL)
			chunk.set_block(8, 65 + up, 7, Blocks.PORTAL)
	return Mesher.mesh_chunk(chunk)


func test_a_portal_adds_only_thin_selection_soup_to_the_chunk() -> void:
	# PortalRenderer owns visible geometry and x.java returns null entity
	# collision, so render + physical streams remain byte-identical to AIR.
	# Ray bounds are separate: x.java:16-25 makes the sheet targetable via a
	# 1/4-thick orientation-dependent AABB on the selection layer.
	var without: Dictionary = _meshed_chunk(false)
	var with_portal: Dictionary = _meshed_chunk(true)
	assert_eq(with_portal.vertices, without.vertices, "identical vertices — no cube was emitted")
	assert_eq(with_portal.indices, without.indices, "identical indices")
	assert_eq(
		with_portal.collision_faces,
		without.collision_faces,
		"identical collision soup — the player can walk in"
	)
	assert_eq(with_portal.uvs, without.uvs, "identical UVs")
	assert_gt(
		with_portal.plant_faces.size(), without.plant_faces.size(), "portal adds selection soup"
	)
	for vertex: Vector3 in with_portal.plant_faces:
		assert_true(
			vertex.z == 7.375 or vertex.z == 7.625,
			"X-axis sheet stays within the source's quarter-block Z thickness"
		)
	# And the same oracle through the PRODUCTION path — native cube pass
	# plus the GDScript appendix. When the extension is absent this
	# degrades to the reference path above, which is fine: the point is
	# that whatever path ships, a portal cell contributes nothing.
	var fast_without: Dictionary = _meshed_chunk_fast(false)
	var fast_with: Dictionary = _meshed_chunk_fast(true)
	assert_eq(fast_with.vertices, fast_without.vertices, "production path: identical vertices")
	assert_eq(
		fast_with.collision_faces,
		fast_without.collision_faces,
		"production path: identical collision"
	)
	assert_gt(
		fast_with.plant_faces.size(),
		fast_without.plant_faces.size(),
		"production path: thin ray-selection soup is present"
	)


func _meshed_chunk_fast(with_portal: bool) -> Dictionary:
	var chunk := Chunk.new()
	for x: int in range(16):
		for z: int in range(16):
			chunk.set_block(x, 64, z, Blocks.NETHERRACK)
	for up: int in range(3):
		chunk.set_block(6, 65 + up, 7, Blocks.NETHERRACK)
		if with_portal:
			chunk.set_block(7, 65 + up, 7, Blocks.PORTAL)
			chunk.set_block(8, 65 + up, 7, Blocks.PORTAL)
	return Mesher.mesh_chunk_fast(chunk)


func test_mesh_shape_routes_the_portal_off_the_cube_path() -> void:
	assert_eq(Blocks.mesh_shape(Blocks.PORTAL), Blocks.MESH_SHAPE_NONE, "NONE, never CUBE")
	assert_true(
		Blocks.needs_gdscript_mesher(Blocks.PORTAL),
		"so the native cube path skips it (mirrored in its own skip list)"
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


# --- End to end: flint click to visible instances ---


func test_lighting_a_frame_produces_visible_instances() -> void:
	# The whole chain the player exercises, in one test: fire placed on
	# the bottom frame block -> BlockFire.place -> NetherPortal.try_create
	# -> PortalIndex.record_sheet -> PortalRenderer.rebuild -> MultiMesh
	# instances with the shared material. Every prior test checked one
	# link; the playtest found the chain itself had never been watched.
	var w := FakeWorld.new()
	autofree(w)
	add_child_autofree(w)
	# A 4x5 frame along X at (10..13, 64..68, 5), interior (11..12, 65..67).
	for along: int in range(4):
		for up: int in range(5):
			var is_frame: bool = along == 0 or along == 3 or up == 0 or up == 4
			if is_frame:
				w.set_world_block(Vector3i(10 + along, 64 + up, 5), 11)  # obsidian
	# The player's click: fire lands on top of the bottom frame row, in
	# the interior — the cell with obsidian directly below.
	# place() returns TRUE when a portal was lit instead of fire written.
	var lit: bool = BlockFire.place(w, Vector3i(11, 65, 5))
	assert_true(lit, "place() lit the portal instead of writing fire")
	assert_eq(w.get_world_block(Vector3i(11, 65, 5)), Blocks.PORTAL, "interior is portal")
	assert_eq(PortalIndex.count(DimensionContext.active()), 2, "both columns recorded in the index")
	var renderer := PortalRenderer.new()
	add_child_autofree(renderer)
	renderer.set_world(w)
	var mm: MultiMesh = renderer.get_node("PortalCells").multimesh
	assert_eq(mm.instance_count, 6, "six drawn cells the moment rebuild runs")
	# (Instance TRANSFORM read-back is a dummy-renderer no-op headless,
	# so the world-coordinate placement is asserted on the renderer's own
	# cell list instead.)
	var cells: Array = renderer.get("_cells")
	assert_eq((cells[0]["pos"] as Vector3i).y, 65, "instances at the world cells")
	var mat: ShaderMaterial = renderer.get_node("PortalCells").material_override
	assert_not_null(mat.shader, "shader bound")
	assert_same(
		mat.get_shader_parameter("frames"), PortalTexture.strip_texture(), "strip texture bound"
	)
	var frame0: Image = PortalTexture.frame_image(0)
	var texel: Color = frame0.get_pixel(8, 8)
	assert_gt(texel.a, 0.5, "and the texture it samples is substantially opaque")


func test_fire_on_a_side_column_does_not_light_and_that_is_vanilla() -> void:
	# The other thing a playtester does: click the INNER FACE of a side
	# column, putting fire mid-air in the interior. qh.java's portal
	# check requires obsidian DIRECTLY BELOW the fire cell, so vanilla
	# does not light from there either — the fire just burns out. Pinned
	# so "nothing happened" from that click is never misread as a bug.
	var w := FakeWorld.new()
	autofree(w)
	add_child_autofree(w)
	for along: int in range(4):
		for up: int in range(5):
			if along == 0 or along == 3 or up == 0 or up == 4:
				w.set_world_block(Vector3i(10 + along, 64 + up, 5), 11)
	var lit: bool = BlockFire.place(w, Vector3i(11, 66, 5))  # mid-interior
	assert_false(lit, "no obsidian below the fire cell, no portal")
	assert_eq(w.get_world_block(Vector3i(11, 66, 5)), Blocks.FIRE, "just fire, which burns out")


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


func test_emitter_pool_is_prebuilt_and_dormant() -> void:
	# Building the pool lazily on the first lit portal put CPUParticles
	# node setup + particle-shader compile on the ignition frame, on top
	# of the light floods — a visible hitch. The pool exists from _ready.
	var renderer := PortalRenderer.new()
	add_child_autofree(renderer)
	var emitters: Array = renderer.get("_emitters")
	assert_eq(emitters.size(), PortalRenderer.EFFECT_CELLS, "pool built at _ready")
	for emitter: CPUParticles3D in emitters:
		assert_false(emitter.emitting, "dormant until a portal claims it")
		assert_false(emitter.visible, "invisible until claimed")


func test_particles_are_textured_smoke_motes_not_flat_quads() -> void:
	# The field report: untextured flat-pink 176-quad walls per cell. The
	# vanilla look (jd.java) is a sparse swirl of smoke tiles from
	# particles.png row 0, each tinted purple at a per-particle random
	# brightness, converging back toward the sheet.
	var renderer := PortalRenderer.new()
	add_child_autofree(renderer)
	var particles: CPUParticles3D = (renderer.get("_emitters") as Array)[0]
	var mat: StandardMaterial3D = (particles.mesh as QuadMesh).material
	assert_not_null(mat.albedo_texture, "smoke tile texture, not an untextured quad")
	# AtlasTexture's region is ignored by the 3D particle path — the
	# strip squishes onto each quad as a horizontal dash. The texture
	# must be a standalone bake of the row (probe-verified).
	assert_false(mat.albedo_texture is AtlasTexture, "standalone strip, not an AtlasTexture")
	assert_eq(mat.albedo_texture.get_width(), 128, "the full smoke row")
	assert_eq(mat.albedo_texture.get_height(), 16, "one row tall")
	assert_eq(mat.particles_anim_h_frames, 8, "the 8-frame smoke row")
	assert_not_null(particles.color_initial_ramp, "brightness roll, not one flat pink")
	assert_lt(particles.radial_accel_max, 0.0, "motes converge back toward the sheet")
	assert_eq(particles.amount, 28, "steady-state population, not a quad wall")
