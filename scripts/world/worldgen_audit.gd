class_name WorldgenAudit
extends RefCounted

# Worldgen sanity-check tool. Generates a sample of chunks, counts
# blocks/decorations, and prints a comparison report against vanilla
# Alpha 1.2.6 expected values. Run via env var
# `MC_CLONE_WORLDGEN_AUDIT=1` (logs at startup) or by calling
# `WorldgenAudit.print_report(0, 0, 5)` from a debug key.
#
# All "VANILLA EXPECTED" numbers are sourced from `vendor/alpha-1.2.6-src/`
# decompile + Bukkit/mc-dev cross-reference. They're approximate (±30%
# tolerance is fine — biome variation in vanilla, our biome-less port,
# and noise seed luck all spread the numbers around).

const _STATUS_OK: String = "OK"
const _STATUS_HIGH: String = "HIGH"
const _STATUS_LOW: String = "LOW"
const _TOLERANCE_MULTIPLIER: float = 0.4  # ±40% counts as OK

# Vanilla expected per-chunk averages (16×128×16 cell chunk). Numbers are
# the midpoint of the typical vanilla range; the OK band is mid * (1 ± tolerance).
const _VANILLA_EXPECTED: Dictionary = {
	# Block counts (per chunk = 32768 cells total). Calibrated against
	# vanilla Alpha 1.2.6 numbers AND empirical observation of working
	# terrain. Round numbers — ±40% tolerance covers seed/coverage noise.
	"air_avg": 14000,  # huge variance with cave + ocean coverage; rough
	"stone_avg": 13500,
	# DIRT: surface 3 cells × ~200 land columns = ~600, plus the dirt-vein
	# ore decorator (20 × ~32 = up to 640). Total typical: 1000-1800.
	"dirt_avg": 1400,
	"grass_avg": 200,  # 256 columns minus sand/water/cliffs that strip the top
	# SAND: vanilla beach band ~8% × beach-noise gate ~50% × 4 cells
	# deep × 256 columns ≈ 41. Earlier 30/75 were both wrong (30 too
	# low, 75 too high). Real vanilla typically lands 30-60 depending
	# on ocean coverage.
	"sand_avg": 40,
	# BEDROCK: vanilla y=0 always (256), y=1 4/5 (~205), y=2 3/5 (~154),
	# y=3 2/5 (~102), y=4 1/5 (~51). Total ~768 per chunk.
	"bedrock_avg": 768,
	# WATER: 40% ocean coverage × ~10 cells avg fill above floor = ~1000.
	# With deeper oceans, can exceed.
	"water_avg": 1200,
	# Trees: ~1.5 oaks per chunk × ~5 trunk cells = 7.5 logs
	# × ~30 leaf cells per canopy = 45 leaves.
	"log_avg": 8,
	"leaves_avg": 45,
	"coal_ore_avg": 111,  # vanilla empirical baseline
	"iron_ore_avg": 77,
	"gold_ore_avg": 8.5,
	"diamond_ore_avg": 3.5,
	# Surface stats.
	"surface_y_mean": 68,  # vanilla plains biome surface mean (sea_level + 4)
	"surface_y_min": 30,  # deep ocean trenches (3D-density only)
	"surface_y_max": 95,  # mountain peaks
	"above_sea_frac": 0.6,  # ~60% of plains-biome columns are land
	"beach_band_frac": 0.08,  # ~8% of columns are TRUE beaches (excl. ocean tops)
	# Decorations.
	"flower_avg": 4,  # ~3 calls × ~1-2 successful placements
	"mushroom_avg": 1.5,
	"tree_avg": 1.5,
}


# Generate `radius`×2+1 chunks around (center_cx, center_cz), scan them,
# and print a formatted report. Slow — generates fresh chunks
# synchronously, so don't call from the worker thread.
static func print_report(center_cx: int = 0, center_cz: int = 0, radius: int = 2) -> void:
	# Ensure the native fast paths are enabled before timing — Game._ready
	# calls enable_native AFTER warming the audit, so without this the
	# audit times the GDScript-only path while real gameplay uses native.
	# Side effect: enable_native is idempotent.
	Worldgen.enable_native()
	var t_start: int = Time.get_ticks_msec()
	var chunks: Array = []
	for cx in range(center_cx - radius, center_cx + radius + 1):
		for cz in range(center_cz - radius, center_cz + radius + 1):
			chunks.append({"coord": Vector2i(cx, cz), "chunk": Worldgen.generate_chunk(cx, cz)})
	var elapsed_ms: int = Time.get_ticks_msec() - t_start

	var stats: Dictionary = _aggregate_stats(chunks)
	_print_header(center_cx, center_cz, radius, chunks.size(), elapsed_ms)
	_print_surface_section(stats)
	_print_block_section(stats, chunks.size())
	_print_decoration_section(stats, chunks.size())
	if Worldgen.biomes_enabled:
		_print_biome_section(chunks)
	_print_footer()


static func _aggregate_stats(chunks: Array) -> Dictionary:
	var counts: Dictionary = {}  # block_id → total count
	var surface_ys: Array[int] = []
	var above_sea_count: int = 0
	var beach_band_count: int = 0
	var ocean_count: int = 0
	for entry: Dictionary in chunks:
		var chunk: Chunk = entry.chunk
		# Per-block tallies.
		for i in range(Chunk.TOTAL_BLOCKS):
			var b: int = chunk.blocks[i]
			counts[b] = counts.get(b, 0) + 1
		# Per-column surface y. Classify ocean by top BLOCK (water = ocean
		# column whose floor is below sea level), not by surface_y >=
		# SEA_LEVEL — because ocean columns' topmost non-AIR is the water
		# itself at y=SEA_LEVEL, which would otherwise read as "land".
		for x in range(Chunk.SIZE_X):
			for z in range(Chunk.SIZE_Z):
				var sy: int = Worldgen.chunk_column_surface_y(chunk, x, z)
				if sy < 0:
					continue
				var top_block: int = chunk.get_block_unchecked(x, sy, z)
				var is_water_top: bool = (
					top_block == Blocks.WATER_STILL or top_block == Blocks.WATER_FLOWING
				)
				if is_water_top:
					ocean_count += 1
					# Find the actual floor under water for the surface_ys
					# stats — gives a meaningful "how deep are oceans" view.
					var floor_y: int = sy - 1
					while floor_y >= 0:
						var b: int = chunk.get_block_unchecked(x, floor_y, z)
						if b != Blocks.WATER_STILL and b != Blocks.WATER_FLOWING:
							break
						floor_y -= 1
					if floor_y >= 0:
						surface_ys.append(floor_y)
				else:
					surface_ys.append(sy)
					above_sea_count += 1
				# True-beach count: only LAND columns whose surface sits
				# in the beach Y-band qualify. Ocean columns trivially have
				# water-top at SEA_LEVEL which would otherwise pollute this
				# metric (they're ocean, not beach).
				if (
					not is_water_top
					and sy >= Worldgen.SEA_LEVEL - Worldgen.BEACH_DEPTH_BELOW
					and sy <= Worldgen.SEA_LEVEL + Worldgen.BEACH_HEIGHT_ABOVE
				):
					beach_band_count += 1
	surface_ys.sort()
	var s_min: int = surface_ys[0] if not surface_ys.is_empty() else 0
	var s_max: int = surface_ys[-1] if not surface_ys.is_empty() else 0
	var s_mean: float = 0.0
	for sy: int in surface_ys:
		s_mean += float(sy)
	if not surface_ys.is_empty():
		s_mean /= float(surface_ys.size())
	var s_median: int = surface_ys[surface_ys.size() / 2] if not surface_ys.is_empty() else 0
	var col_total: int = surface_ys.size()
	return {
		"counts": counts,
		"surface_min": s_min,
		"surface_max": s_max,
		"surface_mean": s_mean,
		"surface_median": s_median,
		"col_total": col_total,
		"above_sea_count": above_sea_count,
		"beach_band_count": beach_band_count,
		"ocean_count": ocean_count,
	}


static func _print_header(cx: int, cz: int, r: int, chunk_count: int, elapsed_ms: int) -> void:
	var mode_label: String = (
		"3D_DENSITY"
		if Worldgen.terrain_mode == Worldgen.TerrainMode.MODE_3D_DENSITY
		else "2D_HEIGHTMAP"
	)
	print("")
	print("============== Worldgen Audit ==============")
	print("  terrain_mode=%s   seed=%d" % [mode_label, Worldgen.WORLD_SEED])
	print(
		(
			"  sampled %d chunks at (%d,%d)..(%d,%d)   gen took %d ms"
			% [chunk_count, cx - r, cz - r, cx + r, cz + r, elapsed_ms]
		)
	)


static func _print_surface_section(stats: Dictionary) -> void:
	print("")
	print("--- Surface Statistics ---")
	var col_total: int = stats.col_total
	if col_total == 0:
		print("  (no columns sampled)")
		return
	var above_frac: float = float(stats.above_sea_count) / float(col_total)
	var beach_frac: float = float(stats.beach_band_count) / float(col_total)
	var ocean_frac: float = float(stats.ocean_count) / float(col_total)
	print(
		(
			"  Surface y    min=%d max=%d mean=%.1f median=%d   VANILLA: min~%d max~%d mean~%d"
			% [
				stats.surface_min,
				stats.surface_max,
				stats.surface_mean,
				stats.surface_median,
				_VANILLA_EXPECTED.surface_y_min,
				_VANILLA_EXPECTED.surface_y_max,
				_VANILLA_EXPECTED.surface_y_mean,
			]
		)
	)
	print(
		(
			"  Above sea    %d/%d (%.1f%%)   VANILLA: ~%d%%"
			% [
				stats.above_sea_count,
				col_total,
				above_frac * 100.0,
				int(_VANILLA_EXPECTED.above_sea_frac * 100.0),
			]
		)
	)
	print(
		(
			"  Beach band   %d/%d (%.1f%%)   VANILLA: ~%d%% [SEE NOTE]"
			% [
				stats.beach_band_count,
				col_total,
				beach_frac * 100.0,
				int(_VANILLA_EXPECTED.beach_band_frac * 100.0),
			]
		)
	)
	print("  Ocean        %d/%d (%.1f%%)" % [stats.ocean_count, col_total, ocean_frac * 100.0])
	print("    (NOTE: vanilla beach band % is for plains biome only — high beach % means")
	print("     surface clusters in y∈[60,65], producing the sand-in-forest bug)")


static func _print_block_section(stats: Dictionary, chunk_count: int) -> void:
	print("")
	print("--- Block Counts (per chunk averages) ---")
	print("  %-16s   %10s   %10s   %s" % ["BLOCK", "OBSERVED", "VANILLA", "STATUS"])
	var per_chunk: Callable = func(id: int) -> float:
		return float(stats.counts.get(id, 0)) / float(chunk_count)
	_print_block_row("AIR", per_chunk.call(Blocks.AIR), _VANILLA_EXPECTED.air_avg)
	_print_block_row("STONE", per_chunk.call(Blocks.STONE), _VANILLA_EXPECTED.stone_avg)
	_print_block_row("DIRT", per_chunk.call(Blocks.DIRT), _VANILLA_EXPECTED.dirt_avg)
	_print_block_row("GRASS", per_chunk.call(Blocks.GRASS), _VANILLA_EXPECTED.grass_avg)
	_print_block_row("SAND", per_chunk.call(Blocks.SAND), _VANILLA_EXPECTED.sand_avg)
	_print_block_row("BEDROCK", per_chunk.call(Blocks.BEDROCK), _VANILLA_EXPECTED.bedrock_avg)
	_print_block_row(
		"WATER",
		per_chunk.call(Blocks.WATER_STILL) + per_chunk.call(Blocks.WATER_FLOWING),
		_VANILLA_EXPECTED.water_avg
	)
	# Lava: no vanilla baseline (cave lava floor is highly variable).
	_print_block_row(
		"LAVA", per_chunk.call(Blocks.LAVA_STILL) + per_chunk.call(Blocks.LAVA_FLOWING), 0
	)
	_print_block_row("LOG", per_chunk.call(Blocks.LOG), _VANILLA_EXPECTED.log_avg)
	_print_block_row("LEAVES", per_chunk.call(Blocks.LEAVES), _VANILLA_EXPECTED.leaves_avg)
	_print_block_row("COAL_ORE", per_chunk.call(Blocks.COAL_ORE), _VANILLA_EXPECTED.coal_ore_avg)
	_print_block_row("IRON_ORE", per_chunk.call(Blocks.IRON_ORE), _VANILLA_EXPECTED.iron_ore_avg)
	_print_block_row("GOLD_ORE", per_chunk.call(Blocks.GOLD_ORE), _VANILLA_EXPECTED.gold_ore_avg)
	_print_block_row(
		"DIAMOND_ORE", per_chunk.call(Blocks.DIAMOND_ORE), _VANILLA_EXPECTED.diamond_ore_avg
	)


static func _print_decoration_section(stats: Dictionary, chunk_count: int) -> void:
	print("")
	print("--- Decorations (per chunk averages) ---")
	print("  %-16s   %10s   %10s   %s" % ["TYPE", "OBSERVED", "VANILLA", "STATUS"])
	var per_chunk: Callable = func(id: int) -> float:
		return float(stats.counts.get(id, 0)) / float(chunk_count)
	var flowers: float = per_chunk.call(Blocks.FLOWER_RED) + per_chunk.call(Blocks.FLOWER_YELLOW)
	var mushrooms: float = (
		per_chunk.call(Blocks.MUSHROOM_BROWN) + per_chunk.call(Blocks.MUSHROOM_RED)
	)
	# Trees: count log columns (each tree has 1 trunk column with ~5 logs).
	var tree_count: float = per_chunk.call(Blocks.LOG) / 5.0
	_print_block_row("Flowers", flowers, _VANILLA_EXPECTED.flower_avg)
	_print_block_row("Mushrooms", mushrooms, _VANILLA_EXPECTED.mushroom_avg)
	_print_block_row("Trees (est.)", tree_count, _VANILLA_EXPECTED.tree_avg)


static func _print_block_row(name: String, observed: float, vanilla: float) -> void:
	var status: String = _classify(observed, vanilla)
	print("  %-16s   %10.1f   %10.1f   %s" % [name, observed, vanilla, status])


static func _classify(observed: float, vanilla: float) -> String:
	if vanilla <= 0.0:
		return "(no vanilla baseline)"
	var lo: float = vanilla * (1.0 - _TOLERANCE_MULTIPLIER)
	var hi: float = vanilla * (1.0 + _TOLERANCE_MULTIPLIER)
	if observed < lo:
		return "LOW (%.0f%% of vanilla)" % (observed / vanilla * 100.0)
	if observed > hi:
		return "HIGH (%.0f%% of vanilla)" % (observed / vanilla * 100.0)
	return "OK (%.0f%%)" % (observed / vanilla * 100.0)


# Sample biome at every chunk's center column and report the
# distribution. Confirms climate noise produces all 11 biomes and
# their relative frequencies match expectation. Vanilla audit
# baseline for biome distribution: ~30% Plains, ~20% Forest,
# ~10% each of Desert/Taiga/Tundra/Swamp, smaller slices for the
# rest. Concrete numbers vary per noise implementation.
static func _print_biome_section(chunks: Array) -> void:
	var counts: Array[int] = []
	counts.resize(Biomes.COUNT)
	counts.fill(0)
	for entry: Dictionary in chunks:
		var coord: Vector2i = entry["coord"]
		# Sample center of chunk (8, 8 in local coords).
		var wx: int = coord.x * Chunk.SIZE_X + 8
		var wz: int = coord.y * Chunk.SIZE_Z + 8
		var biome: int = BiomeClimate.biome_at(wx, wz)
		counts[biome] += 1
	print("")
	print("--- Biome Distribution (chunk centers) ---")
	for i in range(Biomes.COUNT):
		if counts[i] == 0:
			continue
		var pct: float = 100.0 * float(counts[i]) / float(chunks.size())
		print("  %-18s %4d  (%5.1f%%)" % [Biomes.name_of(i), counts[i], pct])


static func _print_footer() -> void:
	print("============================================")
	print("")
