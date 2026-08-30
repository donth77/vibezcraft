# gdlint: disable=max-public-methods
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
	var nat: Dictionary = native.mesh_chunk_data_lit2(
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
		empty,
		Blocks.selection_aabb_flat()
	)
	# Mirror the production combo exactly: native lit2 emits cubes +
	# fluids + CROSS plants + snow layers, and returns the remaining
	# non-cube cells (torches, fences, crops, …) in `special_cells` for
	# the GDScript appendix. Without the appendix, any chunk containing
	# a player-built shape diverges from the reference.
	if chunk.has_non_cube_blocks:
		Mesher._append_special_cells(chunk, nat)
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
	assert_eq(
		nat.get("collision_faces", PackedVector3Array()),
		gds.collision_faces,
		"%s: physical collision soup byte-equal" % label
	)
	assert_eq(
		nat.get("plant_faces", PackedVector3Array()),
		gds.plant_faces,
		"%s: ray-selection soup byte-equal" % label
	)
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
	# driver's sky-subtraction uniform produces the same brightness.
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


# --- Redstone attachments -----------------------------------------------
#
# The native mesher carries its own hardcoded list of non-cube block ids;
# anything missing from it silently falls through to the full-cube pass.
# The redstone set was never added, so in-game a placed torch rendered as
# a solid block with the torch sprite on every face and a dust line
# rendered as a red cube — while every GDScript-only test passed, because
# `Mesher.mesh_chunk` (the reference) handled them correctly all along.
#
# Parity is the assertion that catches this. "Produces geometry" does
# not: a wrong-shaped cube produces plenty.


func test_parity_every_redstone_attachment() -> void:
	for id: int in [
		Blocks.REDSTONE_WIRE,
		Blocks.REDSTONE_TORCH,
		Blocks.REDSTONE_TORCH_OFF,
		Blocks.LEVER,
		Blocks.STONE_BUTTON,
		Blocks.STONE_PRESSURE_PLATE,
		Blocks.WOODEN_PRESSURE_PLATE,
		Blocks.REDSTONE_REPEATER_OFF,
		Blocks.REDSTONE_REPEATER_ON,
	]:
		var chunk := Chunk.new()
		chunk.set_block(8, 63, 8, Blocks.STONE)
		chunk.set_block(9, 64, 8, Blocks.STONE)  # wall for the wall-mounted ones
		chunk.set_block(8, 64, 8, id)
		chunk.set_block_meta(8, 64, 8, Redstone.MOUNT_EAST_WALL)
		var both := _mesh_both(chunk)
		_assert_parity(both[0], both[1], "placed %s" % Blocks.name_of(id))


func test_parity_redstone_ore_stays_a_full_cube() -> void:
	# The other half: ore IS an ordinary opaque cube, so the native pass
	# is right to own it. Skipping it would be its own bug.
	for id: int in [Blocks.REDSTONE_ORE, Blocks.GLOWING_REDSTONE_ORE]:
		var chunk := Chunk.new()
		chunk.set_block(8, 64, 8, id)
		var both := _mesh_both(chunk)
		_assert_parity(both[0], both[1], Blocks.name_of(id))
		assert_eq(both[1].vertices.size(), 24, "%s is a full cube" % Blocks.name_of(id))


func test_parity_wire_at_every_power_level() -> void:
	for power: int in [0, 1, 8, 15]:
		var chunk := Chunk.new()
		chunk.set_block(8, 63, 8, Blocks.STONE)
		chunk.set_block(8, 64, 8, Blocks.REDSTONE_WIRE)
		chunk.set_block_meta(8, 64, 8, power)
		var both := _mesh_both(chunk)
		_assert_parity(both[0], both[1], "wire at power %d" % power)


func test_parity_a_wire_run_with_neighbours() -> void:
	# Wire topology depends on its neighbours, so a straight run and a
	# cross exercise different tiles and different quad counts.
	var chunk := Chunk.new()
	for offset: Vector2i in [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		chunk.set_block(8 + offset.x, 63, 8 + offset.y, Blocks.STONE)
		chunk.set_block(8 + offset.x, 64, 8 + offset.y, Blocks.REDSTONE_WIRE)
		chunk.set_block_meta(8 + offset.x, 64, 8 + offset.y, 12)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "wire T-junction")


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


func test_bulk_remapped_nether_fire_reaches_the_production_appendix() -> void:
	# Player placement goes through Chunk.set_block and always sets the
	# non-cube flag, so ordinary mesher parity fixtures could not reproduce
	# naturally generated fire disappearing. Build through the real raw-id
	# remap instead and compare against the identical support-only chunk.
	var support_raw := PackedByteArray()
	support_raw.resize(Chunk.TOTAL_BLOCKS)
	support_raw[WorldgenNether.alpha_index(8, 63, 8)] = WorldgenNether.ALPHA_NETHERRACK
	var fire_raw: PackedByteArray = support_raw.duplicate()
	fire_raw[WorldgenNether.alpha_index(8, 64, 8)] = WorldgenNether.ALPHA_FIRE
	var support := Chunk.new()
	var fire := Chunk.new()
	WorldgenNether.remap_to_chunk(support_raw, support)
	WorldgenNether.remap_to_chunk(fire_raw, fire)
	Lighting.fill_sky_light(support)
	Lighting.fill_block_light(support)
	Lighting.fill_sky_light(fire)
	Lighting.fill_block_light(fire)
	var support_mesh: Dictionary = Mesher.mesh_chunk_fast(support)
	var fire_mesh: Dictionary = Mesher.mesh_chunk_fast(fire)
	assert_true(fire.has_non_cube_blocks, "the remap advertises its fire cell")
	assert_eq(
		fire_mesh.vertices.size() - support_mesh.vertices.size(),
		32,
		"one floor-supported fire emits eight four-vertex flame planes"
	)
	assert_eq(
		fire_mesh.plant_faces.size() - support_mesh.plant_faces.size(),
		36,
		"and one selection AABB (six faces, two triangles each)"
	)


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
	# Direct read of `collision_faces` from the GDScript Mesher output —
	# the canonical reference for what's in the physics body. Earlier
	# versions of this helper rebuilt the trimesh via
	# ArrayMesh.create_trimesh_shape on the FULL render mesh (cubes +
	# cross-quads), which leaked sapling / flower / tall-grass triangles
	# into "expected" and only happened to pass on worldgen chunks that
	# had zero non-cube blocks. The native flat-soup is cube-only by
	# design — saplings & friends are passable in vanilla — so the
	# render-mesh-trimesh comparison was wrong.
	var gds: Dictionary = Mesher.mesh_chunk(chunk)
	return gds.get("collision_faces", PackedVector3Array())


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


func test_soul_sand_keeps_full_render_and_selection_but_seven_eighths_collision() -> void:
	var chunk := Chunk.new()
	chunk.set_block(8, 64, 8, Blocks.SOUL_SAND)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "soul sand split bounds")
	var render_max_y: float = -INF
	var collision_max_y: float = -INF
	var selection_max_y: float = -INF
	for vertex: Vector3 in both[1].vertices:
		render_max_y = maxf(render_max_y, vertex.y)
	for vertex: Vector3 in both[1].collision_faces:
		collision_max_y = maxf(collision_max_y, vertex.y)
	for vertex: Vector3 in both[1].plant_faces:
		selection_max_y = maxf(selection_max_y, vertex.y)
	assert_almost_eq(render_max_y, 65.0, 1e-6, "visual remains a full cube")
	assert_almost_eq(collision_max_y, 64.875, 1e-6, "physics ends at seven eighths")
	assert_almost_eq(selection_max_y, 65.0, 1e-6, "ray selection remains full-height")


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


func test_parity_native_noncube_pass_mixed_shapes() -> void:
	# Exercises the lit2 native non-cube pass + special-cells appendix
	# ordering contract: cross plants + snow layers (native) interleaved
	# in scan position with torch / fence / crops (GDScript appendix).
	# Any phase-ordering mistake reorders the vertex stream and fails
	# byte equality against the reference's two-phase appendix.
	var chunk := Chunk.new()
	for x in range(8):
		chunk.set_block(x, 10, 4, Blocks.STONE)
	chunk.set_block(0, 11, 4, Blocks.TORCH)
	chunk.set_block(1, 11, 4, Blocks.FLOWER_RED)
	chunk.set_block(2, 11, 4, Blocks.SNOW_LAYER)
	chunk.set_block(3, 11, 4, Blocks.FENCE)
	chunk.set_block(4, 11, 4, Blocks.SAPLING)
	chunk.set_block(5, 11, 4, Blocks.CROPS)
	chunk.set_block(6, 11, 4, Blocks.MUSHROOM_BROWN)
	chunk.set_block(7, 11, 4, Blocks.SUGAR_CANE)
	var both := _mesh_both(chunk)
	_assert_parity(both[0], both[1], "mixed non-cube shapes")
	assert_gt(int(both[1].vertices.size()), 0, "mixed chunk emits geometry")
	assert_gt(int(both[1].plant_faces.size()), 0, "plants emit selection soup")


# --- Cross-chunk edge light (lit3) ---


# Two-chunk seam scenario: a dark room in the EAST neighbor hugging the
# boundary. With the neighbor's edge slices (blocks + meta + LIGHT)
# attached, the surviving seam faces must sample the neighbor's real
# light (dark), not the sky=15 OOB default — and native lit3 must stay
# byte-identical to the GDScript reference. Regression guard for the
# fix in docs/lighting-chunk-seams.md (seam faces rendered full-bright
# in caves / at night).
func test_parity_lit3_seam_light() -> void:
	var a := Chunk.new()
	var b := Chunk.new()
	for y in range(0, 64):
		for z in range(16):
			for x in range(16):
				a.set_block(x, y, z, Blocks.STONE)
				b.set_block(x, y, z, Blocks.STONE)
	# Dark room in B hugging the seam (x=0..1, y=30..32, z=6..9).
	for y in range(30, 33):
		for z in range(6, 10):
			for x in range(0, 2):
				b.set_block(x, y, z, Blocks.AIR)
	# Chunk._init defaults sky light to 15 — darken B's border column so
	# the room is genuinely pitch black at the plane the slice reads.
	for y in range(Chunk.SIZE_Y):
		for z in range(Chunk.SIZE_Z):
			b.set_sky_light(0, y, z, 0)
	Lighting.fill_sky_light(a)
	# Attach B's west plane (blocks + meta + sky + block light) to A's
	# east edge — the steady-state seam-heal configuration.
	var pair: Array = b.west_edge_slices()
	a.edge_blocks_east = pair[0]
	a.edge_meta_east = pair[1]
	a.edge_sky_light_east = pair[2]
	a.edge_block_light_east = pair[3]
	var gds: Dictionary = Mesher.mesh_chunk(a)
	var native = ClassDB.instantiate("MesherNative")
	var empty := PackedByteArray()
	var nat: Dictionary = native.mesh_chunk_data_lit3(
		a.blocks,
		a.block_meta,
		a.sky_light,
		a.block_light,
		a.max_y,
		BlockAtlas.uv_table_flat(),
		empty,
		pair[0],
		empty,
		empty,
		empty,
		pair[1],
		empty,
		empty,
		empty,
		pair[2],
		empty,
		empty,
		empty,
		pair[3],
		empty,
		empty,
		Blocks.selection_aabb_flat()
	)
	_assert_parity(gds, nat, "lit3 seam light")
	# The surviving seam faces (the 3x4 room wall) must be DARK —
	# sampled from B's border column, not the OOB default.
	var seam_faces: int = 0
	var verts: PackedVector3Array = nat.vertices
	var norms: PackedVector3Array = nat.normals
	var cols: PackedColorArray = nat.colors
	var i: int = 0
	while i + 3 < verts.size():
		if norms[i] == Vector3(1, 0, 0) and verts[i].x == 16.0:
			assert_eq(cols[i].r, 0.0, "seam face samples the neighbor's dark light")
			seam_faces += 1
		i += 4
	assert_eq(seam_faces, 12, "exactly the 3x4 room wall survives at the seam")


# Release artifacts can temporarily carry an older native library (for
# example, a local export made before the C++ side module was rebuilt).
# Such a library has lit2 but not lit3, so it cannot consume neighbor light
# planes. Production must choose the byte-correct GDScript reference for a
# seam-heal mesh instead of restoring full-bright cave borders.
func test_stale_native_falls_back_when_edge_light_is_attached() -> void:
	var chunk := Chunk.new()
	chunk.set_block(Chunk.SIZE_X - 1, 20, 8, Blocks.STONE)
	chunk.edge_sky_light_east.resize(Chunk.SIZE_Y * Chunk.SIZE_Z)
	chunk.edge_sky_light_east.fill(0)
	chunk.edge_block_light_east.resize(Chunk.SIZE_Y * Chunk.SIZE_Z)
	chunk.edge_block_light_east.fill(0)
	var expected: Dictionary = Mesher.mesh_chunk(chunk)

	var saved_native: RefCounted = Mesher._native_mesher
	var saved_lit2: bool = Mesher._native_has_lit2
	var saved_lit3: bool = Mesher._native_has_lit3
	Mesher._native_mesher = ClassDB.instantiate("MesherNative")
	Mesher._native_has_lit2 = true
	Mesher._native_has_lit3 = false
	var actual: Dictionary = Mesher.mesh_chunk_fast(chunk)
	Mesher._native_mesher = saved_native
	Mesher._native_has_lit2 = saved_lit2
	Mesher._native_has_lit3 = saved_lit3

	_assert_parity(expected, actual, "stale-native edge-light fallback")
