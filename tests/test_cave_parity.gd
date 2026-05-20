extends GutTest

# Native ↔ GDScript cave parity. The GDScript reference in
# scripts/world/worldgen_caves.gd is the source of truth (bit-exact mirror
# of vanilla Alpha 1.2.6 lx.java). The native port in
# src/worldgen_native.cpp `scatter_caves` MUST produce byte-identical
# output. This test covers a spread of coords across all four quadrants
# plus the origin (the well-tested case) — a divergence at any of them
# fails the suite, and the native cave path in worldgen.gd needs to be
# rolled back to the GDScript fallback until fixed.
#
# Background: 2026-04-24 repro at cx=-5 carved ~1600 extra cells per
# chunk, dumping the player into bedrock-deep "missing terrain" voids.


func _carve_through_gdscript(coord_x: int, coord_z: int) -> Chunk:
	var c := Chunk.new()
	if Worldgen._native_worldgen != null:
		Worldgen._build_base_terrain_native(c, coord_x, coord_z)
	else:
		Worldgen._build_base_terrain_gdscript(c, coord_x, coord_z)
	Worldgen._scatter_ores(c, coord_x, coord_z)
	var CavesScript: GDScript = preload("res://scripts/world/worldgen_caves.gd")
	CavesScript.scatter(c, coord_x, coord_z)
	return c


func _carve_through_native(coord_x: int, coord_z: int) -> Chunk:
	var c := Chunk.new()
	Worldgen._build_base_terrain_native(c, coord_x, coord_z)
	Worldgen._scatter_ores(c, coord_x, coord_z)
	c.blocks = Worldgen._native_worldgen.call("scatter_caves", coord_x, coord_z, c.blocks)
	return c


func test_native_caves_match_gdscript_reference() -> void:
	if (
		Worldgen._native_worldgen == null
		or not Worldgen._native_worldgen.has_method("scatter_caves")
	):
		pending("native worldgen extension not loaded — skipping parity check")
		return
	# Sample across all four quadrants + origin + the historical regression
	# coord (-5, 0). Each chunk takes ~10 ms native + ~80 ms GDScript so the
	# full sweep stays under 1 s.
	var coords: Array = [
		Vector2i(0, 0),
		Vector2i(-5, 0),
		Vector2i(5, 0),
		Vector2i(0, -5),
		Vector2i(0, 5),
		Vector2i(3, -2),
		Vector2i(-2, 4),
		Vector2i(-7, -7),
		Vector2i(7, 7),
	]
	for coord: Vector2i in coords:
		var c_gd := _carve_through_gdscript(coord.x, coord.y)
		var c_native := _carve_through_native(coord.x, coord.y)
		var mismatch: int = 0
		var first_idx: int = -1
		for i in range(Chunk.TOTAL_BLOCKS):
			if c_gd.blocks[i] != c_native.blocks[i]:
				mismatch += 1
				if first_idx == -1:
					first_idx = i
		assert_eq(
			mismatch,
			0,
			(
				"native scatter_caves diverges from GDScript at %s by %d cells (first idx=%d)"
				% [coord, mismatch, first_idx]
			)
		)
