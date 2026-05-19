# gdlint: disable=max-public-methods
extends GutTest

# Lighting slice 3: sky-light fill on chunk gen. Vanilla reference is
# Bukkit/mc-dev `Chunk.java` init-lighting loop (~line 160) for the
# column pass and World.b(EnumSkyBlock, ...) for lateral propagation.

# Pin to 2D heightmap mode — 3D density produces overhangs that block
# sky light differently and would invalidate the "high above surface =
# full daylight" assertions that test against a known max_y.
var _terrain_3d_was: bool


func before_all() -> void:
	_terrain_3d_was = Worldgen.terrain_3d_enabled
	Worldgen.terrain_3d_enabled = false


func after_all() -> void:
	Worldgen.terrain_3d_enabled = _terrain_3d_was


# --- Block opacity ---


func test_air_glass_sapling_are_fully_transparent() -> void:
	assert_eq(Blocks.light_opacity(Blocks.AIR), 0)
	assert_eq(Blocks.light_opacity(Blocks.GLASS), 0)
	assert_eq(Blocks.light_opacity(Blocks.SAPLING), 0)


func test_leaves_have_opacity_one() -> void:
	# Vanilla BlockLeaves.lightOpacity = 1 — light passes with -1/cell.
	assert_eq(Blocks.light_opacity(Blocks.LEAVES), 1)


func test_water_has_alpha_opacity_zero() -> void:
	# Alpha 1.2.6 BlockFluids doesn't override Block.q, so q[water]=q[lava]=0
	# (nq.java:139 + ld.java:53). The column pass bumps 0 → 1 (ha.java:199),
	# so fluids attenuate 1/step — NOT the Bukkit/Beta value of 3.
	assert_eq(Blocks.light_opacity(Blocks.WATER_STILL), 0)
	assert_eq(Blocks.light_opacity(Blocks.WATER_FLOWING), 0)
	assert_eq(Blocks.light_opacity(Blocks.LAVA_STILL), 0)
	assert_eq(Blocks.light_opacity(Blocks.LAVA_FLOWING), 0)


func test_solid_blocks_are_fully_opaque() -> void:
	assert_eq(Blocks.light_opacity(Blocks.STONE), 15)
	assert_eq(Blocks.light_opacity(Blocks.DIRT), 15)
	assert_eq(Blocks.light_opacity(Blocks.LOG), 15)


# --- Column pass: top-down fill ---


func test_empty_chunk_after_fill_has_full_sky_light_everywhere() -> void:
	# All-air chunk: sky_light = 15 throughout (no opacity to attenuate).
	var chunk := Chunk.new()
	Lighting.fill_sky_light(chunk)
	assert_eq(chunk.get_sky_light(0, 0, 0), 15)
	assert_eq(chunk.get_sky_light(8, 64, 8), 15)
	assert_eq(chunk.get_sky_light(15, 127, 15), 15)


func test_solid_block_blocks_sky_light_below_it() -> void:
	# Place a stone slab at y=64. Above stays at 15; AT the stone = 0;
	# directly below = 0 (no lateral propagation can reach a sealed cell
	# in an all-air column with one solid plate).
	var chunk := Chunk.new()
	chunk.set_block(8, 64, 8, Blocks.STONE)
	Lighting.fill_sky_light(chunk)
	assert_eq(chunk.get_sky_light(8, 65, 8), 15, "above stone is full daylight")
	assert_eq(chunk.get_sky_light(8, 64, 8), 0, "stone cell is opaque → 0")
	# Wait — the cell below: lateral propagation will light it from the
	# 4 surrounding air columns (which still have full daylight reaching
	# y=63). So this should be ~14, not 0. Test that lateral works.
	assert_gt(
		chunk.get_sky_light(8, 63, 8), 10, "lateral fill from neighbors lights the cell below"
	)


func test_full_solid_floor_kills_sky_light_below() -> void:
	# Fill an entire y=64 slab with stone. Now lateral can't help — the
	# entire layer is opaque. Below should be 0 everywhere.
	var chunk := Chunk.new()
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			chunk.set_block(x, 64, z, Blocks.STONE)
	Lighting.fill_sky_light(chunk)
	# Above: 15
	assert_eq(chunk.get_sky_light(8, 65, 8), 15)
	# At slab: 0
	assert_eq(chunk.get_sky_light(8, 64, 8), 0)
	# Below the sealed slab: 0
	assert_eq(chunk.get_sky_light(8, 63, 8), 0)
	assert_eq(chunk.get_sky_light(8, 50, 8), 0)
	assert_eq(chunk.get_sky_light(8, 0, 8), 0)


func test_water_does_not_attenuate_sky_light() -> void:
	# Alpha column pass: q=0 cells above the heightmap stay at 15 (the
	# attenuating loop in ha.java:197 only runs once we hit an opacity > 0
	# cell). Water has q=0, so a water column stays fully lit at 15; the
	# first opaque cell below the water is where sky-light drops. This is
	# why underwater dirt/sand is visible — the face ABOVE samples the
	# water cell's light (full daylight), not 0.
	var chunk := Chunk.new()
	for wy: int in [58, 59, 60]:
		chunk.set_block(8, wy, 8, Blocks.WATER_STILL)
		chunk.set_block(7, wy, 8, Blocks.STONE)
		chunk.set_block(9, wy, 8, Blocks.STONE)
		chunk.set_block(8, wy, 7, Blocks.STONE)
		chunk.set_block(8, wy, 9, Blocks.STONE)
	chunk.set_block(8, 57, 8, Blocks.STONE)  # floor
	Lighting.fill_sky_light(chunk)
	assert_eq(chunk.get_sky_light(8, 61, 8), 15, "above water is full daylight")
	assert_eq(chunk.get_sky_light(8, 60, 8), 15, "water is transparent to sky-light")
	assert_eq(chunk.get_sky_light(8, 59, 8), 15, "water is transparent to sky-light")
	assert_eq(chunk.get_sky_light(8, 58, 8), 15, "water is transparent to sky-light")
	assert_eq(chunk.get_sky_light(8, 57, 8), 0, "stone floor below water is opaque → 0")


# --- Lateral pass ---


func test_lateral_fills_into_open_cave_under_overhang() -> void:
	# Build: solid roof at y=64 across the chunk, with a 1-cell air "window"
	# at (0, 64, 0). The window column itself stays at 15 (column pass:
	# all-air column reads 15 down to y=0). Cells UNDER the roof get 0 from
	# their own column pass, then receive lateral light from the window
	# column with `15 - 1 = 14` per step.
	var chunk := Chunk.new()
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			chunk.set_block(x, 64, z, Blocks.STONE)
	# Punch a window
	chunk.set_block(0, 64, 0, Blocks.AIR)
	Lighting.fill_sky_light(chunk)
	# The open column itself: full daylight all the way down.
	assert_eq(chunk.get_sky_light(0, 63, 0), 15, "open window column stays at 15")
	# Cell adjacent to the window, 1 step under the roof: 15 - 1 = 14.
	assert_eq(chunk.get_sky_light(1, 63, 0), 14, "1 step from window under roof: 15 - 1")
	# A few cells away laterally: dimmer but still > 0.
	assert_gt(chunk.get_sky_light(3, 63, 0), 0, "lateral 3 cells away still has some light")
	# Far corner (15 cells away): light has decayed past 0.
	assert_eq(
		chunk.get_sky_light(15, 63, 15), 0, "opposite corner under sealed roof: lateral can't reach"
	)


# --- Worldgen integration ---


func test_worldgen_chunk_surface_is_lit_underground_is_dark() -> void:
	# Real worldgen chunk: well above any tree canopy should be 15;
	# 5 blocks underground from a typical surface should be 0. We sample
	# at h + 12 (above the tallest possible oak: trunk 6 + canopy 2 = 8,
	# plus a margin) so trees never read as "above surface" attenuating
	# light here.
	var chunk := Worldgen.generate_chunk(0, 0)
	Lighting.fill_sky_light(chunk)
	for x: int in [2, 8, 13]:
		for z: int in [2, 8, 13]:
			var h := Worldgen.surface_height(x, z)
			# Well above any tree canopy: full daylight.
			if h + 12 < Chunk.SIZE_Y:
				assert_eq(
					chunk.get_sky_light(x, h + 12, z),
					15,
					"high above surface (%d,%d,%d) full daylight" % [x, h + 12, z]
				)
			# 5 cells underground from a typical surface: must be dark
			# (lateral can't propagate through 5+ blocks of solid stone).
			if h - 5 > 0:
				assert_eq(
					chunk.get_sky_light(x, h - 5, z),
					0,
					"5 below surface (%d,%d,%d) pitch dark" % [x, h - 5, z]
				)


func test_refill_after_block_added_blocks_light_below() -> void:
	# Slice 4 incremental: simulate a player placing a stone block. The
	# sky_light immediately below should drop from 15 to 0 (full daylight
	# replaced by sealed-from-sky), and a sealed cell several blocks down
	# should also be 0. Mirrors vanilla's mc.a() recompute.
	var chunk := Chunk.new()
	# Build a sealed chamber: stone walls at (x±1, y∈40..50, z) and
	# (x, y∈40..50, z±1) so lateral can't relight from the side.
	for wy in range(40, 51):
		chunk.set_block(7, wy, 8, Blocks.STONE)
		chunk.set_block(9, wy, 8, Blocks.STONE)
		chunk.set_block(8, wy, 7, Blocks.STONE)
		chunk.set_block(8, wy, 9, Blocks.STONE)
	chunk.set_block(8, 39, 8, Blocks.STONE)  # floor
	# Center column (8, 40..50, 8) is open air. Initial fill: full daylight.
	Lighting.fill_sky_light(chunk)
	assert_eq(chunk.get_sky_light(8, 50, 8), 15, "open shaft top is full daylight")
	assert_eq(chunk.get_sky_light(8, 41, 8), 15, "open shaft bottom is full daylight")
	# "Place" stone at the top → re-fill. Now shaft is sealed.
	chunk.set_block(8, 50, 8, Blocks.STONE)
	Lighting.fill_sky_light(chunk)
	assert_eq(chunk.get_sky_light(8, 50, 8), 0, "stone cap goes to 0")
	assert_eq(chunk.get_sky_light(8, 49, 8), 0, "below cap, sealed shaft is dark")
	assert_eq(chunk.get_sky_light(8, 41, 8), 0, "deep in sealed shaft is dark")


func test_refill_after_block_removed_relights_column() -> void:
	# Inverse: a sealed shaft is dark, then we mine the cap and the column
	# floods with light again.
	var chunk := Chunk.new()
	for wy in range(40, 51):
		chunk.set_block(7, wy, 8, Blocks.STONE)
		chunk.set_block(9, wy, 8, Blocks.STONE)
		chunk.set_block(8, wy, 7, Blocks.STONE)
		chunk.set_block(8, wy, 9, Blocks.STONE)
	chunk.set_block(8, 39, 8, Blocks.STONE)
	chunk.set_block(8, 50, 8, Blocks.STONE)  # cap on
	Lighting.fill_sky_light(chunk)
	assert_eq(chunk.get_sky_light(8, 49, 8), 0, "sealed shaft is dark before mining")
	# Mine the cap.
	chunk.set_block(8, 50, 8, Blocks.AIR)
	Lighting.fill_sky_light(chunk)
	assert_eq(chunk.get_sky_light(8, 50, 8), 15, "cap mined, top is daylight")
	assert_eq(chunk.get_sky_light(8, 41, 8), 15, "shaft bottom relights to 15")


# --- Bounded BFS update vs. full refill parity ---


func _make_test_chunk_with_shaft() -> Chunk:
	var c := Chunk.new()
	for wy in range(40, 51):
		c.set_block(7, wy, 8, Blocks.STONE)
		c.set_block(9, wy, 8, Blocks.STONE)
		c.set_block(8, wy, 7, Blocks.STONE)
		c.set_block(8, wy, 9, Blocks.STONE)
	c.set_block(8, 39, 8, Blocks.STONE)
	return c


func _sky_light_arrays_equal(a: Chunk, b: Chunk) -> bool:
	for y in range(Chunk.SIZE_Y):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				if a.get_sky_light(x, y, z) != b.get_sky_light(x, y, z):
					return false
	return true


func test_bounded_update_matches_full_refill_after_cap_added() -> void:
	# Sealed shaft: place a stone cap. Both algorithms must converge to the
	# same chunk-wide sky_light state.
	var bounded := _make_test_chunk_with_shaft()
	var full := _make_test_chunk_with_shaft()
	Lighting.fill_sky_light(bounded)
	Lighting.fill_sky_light(full)
	bounded.set_block(8, 50, 8, Blocks.STONE)
	full.set_block(8, 50, 8, Blocks.STONE)
	# Bounded path: incremental update around the edit.
	Lighting.update_sky_light_around(bounded, 8, 50, 8)
	# Reference: full chunk refill.
	Lighting.fill_sky_light(full)
	assert_true(
		_sky_light_arrays_equal(bounded, full),
		"bounded update result should match full refill after stone cap"
	)


func test_bounded_update_matches_full_refill_after_cap_removed() -> void:
	# Sealed shaft starts capped → mine the cap. Both should re-flood
	# the shaft to identical values.
	var bounded := _make_test_chunk_with_shaft()
	var full := _make_test_chunk_with_shaft()
	bounded.set_block(8, 50, 8, Blocks.STONE)
	full.set_block(8, 50, 8, Blocks.STONE)
	Lighting.fill_sky_light(bounded)
	Lighting.fill_sky_light(full)
	bounded.set_block(8, 50, 8, Blocks.AIR)
	full.set_block(8, 50, 8, Blocks.AIR)
	Lighting.update_sky_light_around(bounded, 8, 50, 8)
	Lighting.fill_sky_light(full)
	assert_true(
		_sky_light_arrays_equal(bounded, full),
		"bounded update result should match full refill after cap mined"
	)


func test_fill_sky_light_is_idempotent() -> void:
	# Sanity: fill_sky_light run twice on the same chunk should give the
	# same result as run once. If this fails, there's an order-dependence
	# bug in column_pass + lateral_pass.
	var a := Worldgen.generate_chunk(0, 0)
	var b := Worldgen.generate_chunk(0, 0)
	Lighting.fill_sky_light(a)
	Lighting.fill_sky_light(b)
	Lighting.fill_sky_light(b)  # extra pass
	assert_true(_sky_light_arrays_equal(a, b), "fill_sky_light should be idempotent")


func test_bounded_update_matches_full_refill_in_dense_chunk() -> void:
	# Real worldgen chunk: place a stone block in the surface column,
	# then mine the original surface block. Both edits use the bounded
	# update; the result should match a from-scratch full refill.
	var bounded := Worldgen.generate_chunk(0, 0)
	var full := Worldgen.generate_chunk(0, 0)
	Lighting.fill_sky_light(bounded)
	Lighting.fill_sky_light(full)
	# Mine the cell directly above some surface point at (4, 4) — the
	# top-of-column air cell. (Won't change anything visually, but exercises
	# the bounded path on a dense chunk.)
	var h: int = Worldgen.surface_height(4, 4)
	if h + 1 < Chunk.SIZE_Y:
		bounded.set_block(4, h + 1, 4, Blocks.STONE)
		full.set_block(4, h + 1, 4, Blocks.STONE)
		Lighting.update_sky_light_around(bounded, 4, h + 1, 4)
		Lighting.fill_sky_light(full)
		assert_true(
			_sky_light_arrays_equal(bounded, full),
			"bounded update should match full refill on dense chunk"
		)


# --- Cross-chunk lateral propagation (slice 4b) ---


# Minimal manager-shaped object so we can exercise the world-coord BFS
# without spinning up a real ChunkManager (which needs a scene tree, a
# Player node, the worker thread pool, etc). Holds {coord → Chunk} and
# routes get/set the same way the real manager does.
class _StubManager:
	var chunks: Dictionary = {}

	func get_world_block(world_pos: Vector3i) -> int:
		if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
			return Blocks.AIR
		var cx: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
		var cz: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
		var coord := Vector2i(cx, cz)
		if not chunks.has(coord):
			return Blocks.AIR
		var lx: int = world_pos.x - cx * Chunk.SIZE_X
		var lz: int = world_pos.z - cz * Chunk.SIZE_Z
		return (chunks[coord] as Chunk).get_block(lx, world_pos.y, lz)

	func get_world_sky_light(world_pos: Vector3i) -> int:
		if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
			return 15
		var cx: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
		var cz: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
		var coord := Vector2i(cx, cz)
		if not chunks.has(coord):
			return 15
		var lx: int = world_pos.x - cx * Chunk.SIZE_X
		var lz: int = world_pos.z - cz * Chunk.SIZE_Z
		return (chunks[coord] as Chunk).get_sky_light(lx, world_pos.y, lz)

	func set_world_sky_light(world_pos: Vector3i, value: int) -> void:
		if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
			return
		var cx: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
		var cz: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
		var coord := Vector2i(cx, cz)
		if not chunks.has(coord):
			return
		var lx: int = world_pos.x - cx * Chunk.SIZE_X
		var lz: int = world_pos.z - cz * Chunk.SIZE_Z
		(chunks[coord] as Chunk).set_sky_light(lx, world_pos.y, lz, value)

	func is_sky_exposed_at_world(world_pos: Vector3i) -> bool:
		if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
			return world_pos.y >= Chunk.SIZE_Y
		var cx: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
		var cz: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
		var coord := Vector2i(cx, cz)
		if not chunks.has(coord):
			return true
		var lx: int = world_pos.x - cx * Chunk.SIZE_X
		var lz: int = world_pos.z - cz * Chunk.SIZE_Z
		return (chunks[coord] as Chunk).is_sky_exposed(lx, world_pos.y, lz)

	# Block-light world-coord accessors mirror the sky pair above. Used by
	# update_block_light_around_world / relight_chunk_borders' block channel.
	func get_world_block_light(world_pos: Vector3i) -> int:
		if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
			return 0
		var cx: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
		var cz: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
		var coord := Vector2i(cx, cz)
		if not chunks.has(coord):
			return 0
		var lx: int = world_pos.x - cx * Chunk.SIZE_X
		var lz: int = world_pos.z - cz * Chunk.SIZE_Z
		return (chunks[coord] as Chunk).get_block_light(lx, world_pos.y, lz)

	func set_world_block_light(world_pos: Vector3i, value: int) -> void:
		if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
			return
		var cx: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
		var cz: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
		var coord := Vector2i(cx, cz)
		if not chunks.has(coord):
			return
		var lx: int = world_pos.x - cx * Chunk.SIZE_X
		var lz: int = world_pos.z - cz * Chunk.SIZE_Z
		(chunks[coord] as Chunk).set_block_light(lx, world_pos.y, lz, value)

	# Stubs for the relight pass — it calls these at the end so the manager
	# can re-mesh and re-persist; tests don't care, just absorb the calls.
	func get_chunk_at_coord(coord: Vector2i) -> Chunk:
		if not chunks.has(coord):
			return null
		return chunks[coord] as Chunk

	func notify_chunk_lighting_updated(_coord: Vector2i) -> void:
		pass


func test_cross_chunk_relight_lights_edge_from_neighbor() -> void:
	# Two adjacent chunks at world x=0..15 and x=16..31. Chunk (0,0) has
	# a sealed roof at y=64 across its WHOLE footprint. Chunk (1,0) is
	# all-air (sky-exposed). Initial fill is chunk-bounded so c00's edge
	# cell at (15, 63, 0) is dark — the sealed roof above it kills the
	# column. Cross-chunk relight should pull light in from c10's air
	# at world x=16.
	var manager := _StubManager.new()
	var c00 := Chunk.new()
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			c00.set_block(x, 64, z, Blocks.STONE)
	var c10 := Chunk.new()
	manager.chunks[Vector2i(0, 0)] = c00
	manager.chunks[Vector2i(1, 0)] = c10
	Lighting.fill_sky_light(c00)
	Lighting.fill_sky_light(c10)
	assert_eq(c00.get_sky_light(15, 63, 0), 0, "edge cell starts dark before cross-chunk relight")
	# World coord (15, 63, 0) — chunk (0,0) local (15, 63, 0).
	Lighting.update_sky_light_around_world(Vector3i(15, 63, 0), manager)
	assert_gt(
		c00.get_sky_light(15, 63, 0), 0, "cross-chunk relight must light edge cell from neighbor"
	)


func test_cross_chunk_relight_propagates_into_neighbor() -> void:
	# Inverse direction: the relight is triggered in c00 but should also
	# brighten c10's edge cells. Seal c10 with a solid roof; the edit at
	# world (15, 63, 0) is in c00, but the BFS box extends to world x=30
	# (15 + radius). c10's cell at world (16, 63, 0) — local (0, 63, 0)
	# — should be relit from c00 propagating across the seam.
	var manager := _StubManager.new()
	var c00 := Chunk.new()
	var c10 := Chunk.new()
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			c10.set_block(x, 64, z, Blocks.STONE)
	manager.chunks[Vector2i(0, 0)] = c00
	manager.chunks[Vector2i(1, 0)] = c10
	Lighting.fill_sky_light(c00)
	Lighting.fill_sky_light(c10)
	# c10's edge starts dark (sealed roof, no neighbor light in slice 3).
	assert_eq(c10.get_sky_light(0, 63, 0), 0, "c10 edge starts dark before cross-chunk relight")
	# Trigger relight at the c00-side edge.
	Lighting.update_sky_light_around_world(Vector3i(15, 63, 0), manager)
	assert_gt(c10.get_sky_light(0, 63, 0), 0, "neighbor chunk's edge cell relit across the seam")


func test_glass_does_not_block_sky_light() -> void:
	# Glass has opacity 0 above the heightmap, but vanilla's "below heightmap
	# = -1 per cell" rule kicks in once we hit the glass. So glass at y=64
	# in an otherwise-air column reads 15 (above heightmap), and a cell
	# below at y=63 (now below heightmap) drops to 14. Below that, every
	# air cell loses 1 more.
	var chunk := Chunk.new()
	chunk.set_block(8, 64, 8, Blocks.GLASS)
	Lighting.fill_sky_light(chunk)
	# Pure-glass cell above any opaque block — opacity 0 means light still
	# passes through, but the heightmap-trigger fires (vanilla behavior).
	# Check the cells just below the glass:
	assert_eq(chunk.get_sky_light(8, 65, 8), 15, "above glass full daylight")
	assert_eq(
		chunk.get_sky_light(8, 64, 8), 15, "glass cell itself: opacity 0 above heightmap reads 15"
	)
	# After the glass, lateral propagation from neighboring full-daylight
	# columns brings this cell back up to 15 (column pass would drop to 14
	# but the four side neighbors at y=63 are 15 → 14 reaches here).
	assert_gt(chunk.get_sky_light(8, 63, 8), 13, "below glass relit by lateral neighbors")


# --- Block-light channel (emission BFS from torches/lava/glowstone) ---


func test_lava_seeds_block_light_at_15() -> void:
	# Single lava cell in an empty chunk. The cell itself reads 15 (its
	# own emission). Vanilla ld.java:168 `d() return 30` on Alpha's 0-30
	# internal scale = 15 on our 0-15 scale.
	var chunk := Chunk.new()
	chunk.set_block(8, 64, 8, Blocks.LAVA_STILL)
	Lighting.fill_block_light(chunk)
	assert_eq(chunk.get_block_light(8, 64, 8), 15)


func test_block_light_decays_in_air() -> void:
	# Air (opacity 0) decays by max(1, 0) = 1 per step. 15-cell reach.
	var chunk := Chunk.new()
	chunk.set_block(8, 64, 8, Blocks.LAVA_STILL)
	Lighting.fill_block_light(chunk)
	assert_eq(chunk.get_block_light(9, 64, 8), 14)
	assert_eq(chunk.get_block_light(10, 64, 8), 13)
	assert_eq(chunk.get_block_light(15, 64, 8), 8)


func test_block_light_stops_at_fully_enclosed_wall() -> void:
	# Enclose a single cell in stone on all 6 sides so BFS can't route
	# around the wall through adjacent air. That cell must read 0 even
	# when a lava source sits just past the far wall.
	var chunk := Chunk.new()
	chunk.set_block(5, 64, 5, Blocks.LAVA_STILL)
	# Target cell at (7, 64, 5). Wall it in with stone on all 6 neighbors.
	chunk.set_block(6, 64, 5, Blocks.STONE)
	chunk.set_block(8, 64, 5, Blocks.STONE)
	chunk.set_block(7, 63, 5, Blocks.STONE)
	chunk.set_block(7, 65, 5, Blocks.STONE)
	chunk.set_block(7, 64, 4, Blocks.STONE)
	chunk.set_block(7, 64, 6, Blocks.STONE)
	Lighting.fill_block_light(chunk)
	assert_eq(chunk.get_block_light(5, 64, 5), 15, "lava self lit")
	assert_eq(chunk.get_block_light(7, 64, 5), 0, "fully enclosed cell isolated from lava BFS")


func test_empty_chunk_has_zero_block_light() -> void:
	var chunk := Chunk.new()
	Lighting.fill_block_light(chunk)
	for y: int in [0, 32, 64, 96, 127]:
		for x: int in [0, 8, 15]:
			for z: int in [0, 8, 15]:
				assert_eq(chunk.get_block_light(x, y, z), 0)


# --- Block-light cross-chunk relight + edit-time BFS ---


func test_update_block_light_around_world_lights_neighbors_of_lava() -> void:
	# Single-chunk smoke test for the new world-coord block-light BFS.
	# Place lava at (8, 64, 8) AFTER fill (so fill_block_light wouldn't have
	# seen it), then run the bounded BFS — it should propagate the emission
	# the same as fill_block_light would have.
	var manager := _StubManager.new()
	var chunk := Chunk.new()
	manager.chunks[Vector2i(0, 0)] = chunk
	Lighting.fill_block_light(chunk)
	chunk.set_block(8, 64, 8, Blocks.LAVA_STILL)
	Lighting.update_block_light_around_world(Vector3i(8, 64, 8), manager)
	assert_eq(chunk.get_block_light(8, 64, 8), 15, "lava cell self-lit")
	assert_eq(chunk.get_block_light(9, 64, 8), 14, "neighbor decays by 1")
	assert_eq(chunk.get_block_light(10, 64, 8), 13)


func test_update_block_light_around_world_darkens_after_emitter_removed() -> void:
	# Bidirectional recompute: removing a torch/lava cell must darken the
	# cells it was lighting. Vanilla mc.a() handles this in one pass via
	# `max(emission, max_neighbor - opacity)` — same logic the world BFS uses.
	var manager := _StubManager.new()
	var chunk := Chunk.new()
	manager.chunks[Vector2i(0, 0)] = chunk
	chunk.set_block(8, 64, 8, Blocks.LAVA_STILL)
	Lighting.fill_block_light(chunk)
	assert_eq(chunk.get_block_light(9, 64, 8), 14)
	# Remove the lava and re-run the bounded BFS at the edit position.
	chunk.set_block(8, 64, 8, Blocks.AIR)
	Lighting.update_block_light_around_world(Vector3i(8, 64, 8), manager)
	assert_eq(chunk.get_block_light(8, 64, 8), 0, "removed-emitter cell drops to 0")
	assert_eq(chunk.get_block_light(9, 64, 8), 0, "previously-lit neighbor drops to 0")


func test_update_block_light_around_world_crosses_chunk_seam() -> void:
	# Place lava just inside chunk (0,0) at world (15, 64, 0). The 14-cell
	# decay reach extends across the seam into chunk (1,0). Without the
	# cross-chunk world-coord BFS, the emission would stop at x=15.
	var manager := _StubManager.new()
	var c00 := Chunk.new()
	var c10 := Chunk.new()
	manager.chunks[Vector2i(0, 0)] = c00
	manager.chunks[Vector2i(1, 0)] = c10
	c00.set_block(15, 64, 0, Blocks.LAVA_STILL)
	Lighting.fill_block_light(c00)  # internal-only fill; c10 sees nothing
	Lighting.fill_block_light(c10)
	assert_eq(c10.get_block_light(0, 64, 0), 0, "neighbor edge dark before cross-chunk BFS")
	Lighting.update_block_light_around_world(Vector3i(15, 64, 0), manager)
	# Emission at (15, 64, 0) is 15. World (16, 64, 0) — local (0, 64, 0)
	# of c10 — is one step away, so 14. Anything > 0 proves the cross-chunk
	# write happened.
	assert_eq(
		c10.get_block_light(0, 64, 0), 14, "cross-chunk: lava in c00 lights c10's edge cell at 14"
	)


func test_relight_chunk_borders_lights_sky_at_seam() -> void:
	# Symmetric to test_cross_chunk_relight_lights_edge_from_neighbor but
	# triggered via the chunk-load relight path (relight_chunk_borders)
	# instead of an explicit edit-time BFS. c00 has a sealed roof; c10 is
	# all-air. After both fill, run relight on c00 — its east edge cell
	# should brighten from c10's neighboring sky-lit air.
	var manager := _StubManager.new()
	var c00 := Chunk.new()
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			c00.set_block(x, 64, z, Blocks.STONE)
	var c10 := Chunk.new()
	manager.chunks[Vector2i(0, 0)] = c00
	manager.chunks[Vector2i(1, 0)] = c10
	Lighting.fill_sky_light(c00)
	Lighting.fill_sky_light(c10)
	Lighting.fill_block_light(c00)
	Lighting.fill_block_light(c10)
	assert_eq(c00.get_sky_light(15, 63, 0), 0, "edge cell starts dark")
	Lighting.relight_chunk_borders(Vector2i(0, 0), manager)
	assert_gt(c00.get_sky_light(15, 63, 0), 0, "relight pulls light in from neighbor c10")


func test_relight_chunk_borders_lights_block_across_seam() -> void:
	# Block-channel equivalent: lava in c00 just inside the east edge.
	# Initial fill of c10 sees no emitter, so c10's edge stays dark.
	# After relight, c10's edge brightens.
	var manager := _StubManager.new()
	var c00 := Chunk.new()
	var c10 := Chunk.new()
	manager.chunks[Vector2i(0, 0)] = c00
	manager.chunks[Vector2i(1, 0)] = c10
	c00.set_block(15, 64, 0, Blocks.LAVA_STILL)
	Lighting.fill_sky_light(c00)
	Lighting.fill_sky_light(c10)
	Lighting.fill_block_light(c00)
	Lighting.fill_block_light(c10)
	assert_eq(c10.get_block_light(0, 64, 0), 0, "neighbor edge dark before relight")
	Lighting.relight_chunk_borders(Vector2i(1, 0), manager)
	assert_eq(c10.get_block_light(0, 64, 0), 14, "relight propagates lava emission across seam")


func test_relight_chunk_borders_no_op_with_no_loaded_neighbors() -> void:
	# Single isolated chunk: relight should be a no-op (no neighbors loaded
	# means no seams to recompute against). Verifies the early-return path.
	var manager := _StubManager.new()
	var chunk := Chunk.new()
	manager.chunks[Vector2i(0, 0)] = chunk
	Lighting.fill_sky_light(chunk)
	Lighting.fill_block_light(chunk)
	# Snapshot pre-relight state.
	var before := chunk.sky_light.duplicate()
	Lighting.relight_chunk_borders(Vector2i(0, 0), manager)
	assert_true(chunk.sky_light == before, "isolated chunk's sky_light unchanged by relight")


# --- Overhang spanning a chunk boundary ---
#
# Bug repro: an overhang that crosses a chunk seam leaves the FULLY-COVERED
# chunk with sky_light = 0 everywhere under the overhang. fill_sky_light's
# Phase 2 BFS seeds only cells at MAX_LIGHT, so a chunk with no sky-exposed
# cells gets no seeds, and the chunk-internal pass produces all-zero light.
# relight_chunk_borders must then propagate sky light from the seam inward
# all the way across the 16-cell chunk, so the deepest under-overhang cells
# still receive a graceful gradient (something like 15→14→…→0) rather than
# the visually-jarring "solid black on one side of a seam, normal gradient
# on the other" the user reported.
#
# Setup:
#   chunk A (cx=0): grass floor at y=64, stone overhang at y=70..71 covering
#                   x=8..15 (right half).
#   chunk B (cx=1): grass floor at y=64, stone overhang at y=70..71 covering
#                   x=0..15 (entire chunk).
#   So the overhang spans 24 columns total; chunk B has zero sky-exposed
#   cells in the y=65..69 air pocket.
func test_relight_overhang_spanning_seam_propagates_into_covered_chunk() -> void:
	var manager := _StubManager.new()
	var c00 := Chunk.new()
	var c10 := Chunk.new()
	manager.chunks[Vector2i(0, 0)] = c00
	manager.chunks[Vector2i(1, 0)] = c10
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			# Bedrock + stone fill + grass surface in both chunks.
			for y in range(4):
				c00.set_block(x, y, z, Blocks.BEDROCK)
				c10.set_block(x, y, z, Blocks.BEDROCK)
			for y in range(4, 64):
				c00.set_block(x, y, z, Blocks.STONE)
				c10.set_block(x, y, z, Blocks.STONE)
			c00.set_block(x, 64, z, Blocks.GRASS)
			c10.set_block(x, 64, z, Blocks.GRASS)
	for x in range(8, 16):
		for z in range(Chunk.SIZE_Z):
			c00.set_block(x, 70, z, Blocks.STONE)
			c00.set_block(x, 71, z, Blocks.STONE)
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			c10.set_block(x, 70, z, Blocks.STONE)
			c10.set_block(x, 71, z, Blocks.STONE)
	Lighting.fill_sky_light(c00)
	Lighting.fill_sky_light(c10)
	# Before relight: chunk B's under-overhang air should be all zeros
	# (Phase 2 BFS has no seeds). Documents the bug.
	var pre_edge: int = c10.get_sky_light(0, 65, 8)  # x=16 in world, adjacent to c00
	var pre_far: int = c10.get_sky_light(15, 65, 8)  # x=31 in world, deepest cell
	assert_eq(pre_edge, 0, "pre-relight: chunk B seam-edge cell is 0 (Phase 2 had no seeds)")
	assert_eq(pre_far, 0, "pre-relight: chunk B deepest cell is 0")
	# Run relight for both chunks (mirrors what ChunkManager does on
	# materialize). After relight, the seam-edge cell should pull a useful
	# amount of light from chunk A's open sky, and the gradient should
	# decay smoothly toward the far side instead of dropping to 0 at the
	# seam.
	Lighting.relight_chunk_borders(Vector2i(0, 0), manager)
	Lighting.relight_chunk_borders(Vector2i(1, 0), manager)
	var post_edge: int = c10.get_sky_light(0, 65, 8)
	var post_far: int = c10.get_sky_light(15, 65, 8)
	# Seam-edge cell: chunk A has sky=7 at x=15 (decay 15→7 across columns
	# 8..15). One more step into chunk B at x=0 should land at sky=6.
	assert_gte(
		post_edge,
		5,
		(
			"post-relight: chunk B seam-edge should pull at least sky=5 from chunk A "
			+ "(got %d)" % post_edge
		)
	)
	# Far side: 16 cells deeper at sky=7 minus 16 attenuation can't go
	# below 0. The TEST IS NOT that this cell is non-zero — it'd take a
	# full chunk-crossing BFS — but that the gradient is monotone, i.e.
	# the deepest cell is <= the seam edge. Catches the "everything stays
	# 0 because BFS bailed" regression.
	assert_lte(
		post_far,
		post_edge,
		(
			"post-relight: gradient should decay monotonically away from seam "
			+ "(edge=%d, far=%d)" % [post_edge, post_far]
		)
	)
	# And document that the seam edge is brighter than 0 — the smoke-test
	# assertion that propagation happened at all.
	assert_gt(
		post_edge, 0, "post-relight: at minimum the seam-adjacent cell must receive SOME light"
	)


# Regression for the under-overhang flat-shadow bug.
# Was: chunk B's south/north edge cells (z=0, z=15) ended up at sky=14
# because their cardinal neighbour in chunk (1, -1) / (1, 1) is UNLOADED,
# and get_world_sky_light returns 15 for unloaded chunks (vanilla
# "treat unknown as sky-exposed" convention). Phantom-15 sources flood-
# lit covered chunks at load boundaries.
#
# Fix: _recompute_sky_light_at_world now treats unloaded neighbours as
# DARK (sky=0) when the queried cell is itself under cover. Sky-exposed
# cells still use the vanilla 15 convention. See lighting.gd.
func test_relight_overhang_phantom_light_from_unloaded_neighbour() -> void:
	var manager := _StubManager.new()
	var c00 := Chunk.new()
	var c10 := Chunk.new()
	manager.chunks[Vector2i(0, 0)] = c00
	manager.chunks[Vector2i(1, 0)] = c10
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			for y in range(4):
				c00.set_block(x, y, z, Blocks.BEDROCK)
				c10.set_block(x, y, z, Blocks.BEDROCK)
			for y in range(4, 64):
				c00.set_block(x, y, z, Blocks.STONE)
				c10.set_block(x, y, z, Blocks.STONE)
			c00.set_block(x, 64, z, Blocks.GRASS)
			c10.set_block(x, 64, z, Blocks.GRASS)
	for x in range(8, 16):
		for z in range(Chunk.SIZE_Z):
			c00.set_block(x, 70, z, Blocks.STONE)
			c00.set_block(x, 71, z, Blocks.STONE)
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			c10.set_block(x, 70, z, Blocks.STONE)
			c10.set_block(x, 71, z, Blocks.STONE)
	Lighting.fill_sky_light(c00)
	Lighting.fill_sky_light(c10)
	Lighting.relight_chunk_borders(Vector2i(0, 0), manager)
	Lighting.relight_chunk_borders(Vector2i(1, 0), manager)
	# After fix: chunk B's south-edge corner is no longer flood-lit by
	# a phantom-15 source from unloaded chunk (1, -1). Cell at (15, 65, 0)
	# is far from chunk A's seam AND at a chunk corner — should stay dark.
	assert_eq(
		c10.get_sky_light(15, 65, 0),
		0,
		(
			"deep under-overhang corner should be 0 (no real sky exposure "
			+ "within loaded world); got %d" % c10.get_sky_light(15, 65, 0)
		)
	)
	# Seam-adjacent cell still pulls from chunk A's edge (7) with -1 decay.
	assert_eq(
		c10.get_sky_light(0, 65, 8),
		6,
		"seam-adjacent under-overhang cell pulls from chunk A's 7 with -1 decay"
	)
