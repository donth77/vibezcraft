class_name WorldgenSprings
extends RefCounted

# Liquid springs — Alpha 1.2.6 `pj.java` (WorldGenLiquids) port.
# Vanilla `px.java:434-445` calls this 50× per chunk for water springs
# and 20× per chunk for lava springs during the `b()` decorate phase.
# Most attempts fail the wall-pattern check; the rare successes place a
# single source block in a stone wall that becomes a small pool via
# fluid flow.
#
# Wall pattern (`pj.a` lines 19-69):
#   * Block ABOVE must be STONE
#   * Block BELOW must be STONE
#   * Block at (x, y, z) must be AIR or STONE (replaceable)
#   * Exactly 3 STONE + 1 AIR among the 4 horizontal neighbors
# This produces a fluid source on a stone wall facing a cave AIR cell.
# Fluid flow ticks pick it up next world tick and the cell flows out.
#
# --- Spillover pattern (matches our ore-vein generator) ---
#
# Vanilla's per-attempt position is `chunk_origin + 8 + rand[0,16)`,
# so the 16-cell-wide attempt AABB straddles four chunks (own + 3 NE
# neighbors). To stay chunk-isolated (no cross-chunk writes during
# gen) AND still match vanilla's per-chunk effective spring count, we
# run FOUR decoration passes per chunk — the own pass + three SW
# neighbors — and clip writes to the target chunk's local bounds. This
# is the same approach `Worldgen._scatter_ores` uses; see CLAUDE.md's
# "Ore vein reconstruction" invariant for the rationale.
#
# --- Performance ---
#
# Per-chunk cost: 4 passes × 70 attempts × ~9 voxel reads = ~2.5 K reads.
# `chunk.get_block_unchecked` is a PackedByteArray index (≈ 50 ns), so
# the whole spring decorate is ~125 µs per chunk. Neighbor reads are
# inlined (no per-attempt array allocation), and the fail-fast order
# is: y-bounds → in-chunk-bounds → above-stone → below-stone → center →
# 4 neighbors. >95 % of attempts bail at the above/below-stone gate
# (most positions are not in a stone sandwich) so the neighbor sweep
# rarely runs.

# Sample counts — vanilla `px.java:434, 440`. 50 water, 20 lava per
# source chunk. With 4 SW-spillover passes we get 4× per target chunk,
# matching vanilla's effective density.
const _WATER_SPRING_ATTEMPTS: int = 50
const _LAVA_SPRING_ATTEMPTS: int = 20

# Y distribution exponents — vanilla nests `rand.nextInt(rand.nextInt(N))`
# to bias toward low Y. Water uses one nesting (cubic-ish), lava uses
# TWO nestings (very strongly toward low Y, ~80 % of lava springs land
# below y=32).
const _WATER_Y_OUTER_MAX: int = 120
const _WATER_Y_OFFSET: int = 8
const _LAVA_Y_INNER_MAX: int = 112
const _LAVA_Y_OFFSET_INNER: int = 8
const _LAVA_Y_OFFSET_OUTER: int = 8

# Per-pass RNG seed mixing constants — same prime trio the ore-vein
# generator uses, plus a per-pass salt (`+3`) so the spring stream is
# independent of ores and caves.
const _SEED_MUL_X: int = 341873128712
const _SEED_MUL_Z: int = 132897987541
const _SEED_SALT: int = 3


# Run the per-chunk spring pass. Called from worldgen.gd after caves
# (so the wall-pattern checks see realistic post-cave block layout).
static func scatter(chunk: Chunk, chunk_x: int, chunk_z: int) -> void:
	var probe_token := PerfProbe.begin("worldgen.springs")
	# 4-pass spillover — own chunk + 3 SW neighbors. Each pass uses a
	# deterministic JavaRandom keyed on its SOURCE chunk so re-loading
	# the world reproduces the same springs.
	var rng := JavaRandom.new()
	for sdx: int in [-1, 0]:
		for sdz: int in [-1, 0]:
			_run_one_pass(chunk, chunk_x, chunk_z, chunk_x + sdx, chunk_z + sdz, rng)
	PerfProbe.end("worldgen.springs", probe_token)


# One source-chunk pass. Generates 70 spring attempts (50 water + 20
# lava); each lands at (src_x*16+8+rand[0,16), y, src_z*16+8+rand[0,16))
# which straddles four chunks. Only the attempts that fall inside the
# target chunk's local interior (lx, lz in [1, 14]) actually try to
# place — the 1-cell border keeps the neighbor reads in-chunk.
static func _run_one_pass(
	chunk: Chunk, tgt_x: int, tgt_z: int, src_x: int, src_z: int, rng: JavaRandom
) -> void:
	rng.set_seed(src_x * _SEED_MUL_X + src_z * _SEED_MUL_Z + _SEED_SALT)
	var base_world_x: int = src_x * Chunk.SIZE_X + 8
	var base_world_z: int = src_z * Chunk.SIZE_Z + 8
	var tgt_world_x: int = tgt_x * Chunk.SIZE_X
	var tgt_world_z: int = tgt_z * Chunk.SIZE_Z
	# Water attempts (`px.java:434-439`).
	for _i in range(_WATER_SPRING_ATTEMPTS):
		var dx: int = rng.next_int_bounded(16)
		var y_outer: int = rng.next_int_bounded(_WATER_Y_OUTER_MAX) + _WATER_Y_OFFSET
		var y: int = rng.next_int_bounded(y_outer)
		var dz: int = rng.next_int_bounded(16)
		var lx: int = base_world_x + dx - tgt_world_x
		var lz: int = base_world_z + dz - tgt_world_z
		_try_place(chunk, lx, y, lz, Blocks.WATER_STILL)
	# Lava attempts (`px.java:440-445`) — same XZ band, stronger low-Y bias.
	for _i in range(_LAVA_SPRING_ATTEMPTS):
		var dx: int = rng.next_int_bounded(16)
		var y_inner: int = rng.next_int_bounded(_LAVA_Y_INNER_MAX) + _LAVA_Y_OFFSET_INNER
		var y_outer: int = rng.next_int_bounded(y_inner) + _LAVA_Y_OFFSET_OUTER
		var y: int = rng.next_int_bounded(y_outer)
		var dz: int = rng.next_int_bounded(16)
		var lx: int = base_world_x + dx - tgt_world_x
		var lz: int = base_world_z + dz - tgt_world_z
		_try_place(chunk, lx, y, lz, Blocks.LAVA_STILL)


# Wall-pattern check + placement, fully inlined for the hot path.
# Returns silently — caller doesn't need the success bool. Fail-fast
# order: y bounds (rejects ~1/128 of attempts immediately) → chunk
# bounds (rejects ~3/4 of attempts since most spill into neighbors) →
# above/below stone sandwich (rejects ~95 % of remaining attempts —
# most cells aren't ceilinged by stone) → center replaceable → 3+1
# neighbor pattern.
static func _try_place(chunk: Chunk, lx: int, y: int, lz: int, fluid_id: int) -> void:
	# Y bounds — vanilla skips y=0 and y=127 via the above/below gates;
	# we early-out to avoid the array access on out-of-range Y.
	if y < 1 or y >= Chunk.SIZE_Y - 1:
		return
	# Chunk bounds — keep neighbor reads in-chunk by holding a 1-cell
	# border. About 75 % of attempts fall outside this band (spillover).
	if lx < 1 or lx >= Chunk.SIZE_X - 1 or lz < 1 or lz >= Chunk.SIZE_Z - 1:
		return
	# Above + below must both be STONE — the steepest filter. Inline,
	# constant compared, no function-call overhead.
	if chunk.get_block_unchecked(lx, y + 1, lz) != Blocks.STONE:
		return
	if chunk.get_block_unchecked(lx, y - 1, lz) != Blocks.STONE:
		return
	# Center must be AIR or STONE. Vanilla allows STONE so a fully-
	# buried source can land (rare but the flow ticks find it).
	var center: int = chunk.get_block_unchecked(lx, y, lz)
	if center != Blocks.AIR and center != Blocks.STONE:
		return
	# Four horizontal neighbors — unrolled to avoid per-attempt Array
	# allocation. Count STONE walls + AIR openings simultaneously.
	var n_west: int = chunk.get_block_unchecked(lx - 1, y, lz)
	var n_east: int = chunk.get_block_unchecked(lx + 1, y, lz)
	var n_north: int = chunk.get_block_unchecked(lx, y, lz - 1)
	var n_south: int = chunk.get_block_unchecked(lx, y, lz + 1)
	var stone_count: int = (
		int(n_west == Blocks.STONE)
		+ int(n_east == Blocks.STONE)
		+ int(n_north == Blocks.STONE)
		+ int(n_south == Blocks.STONE)
	)
	if stone_count != 3:
		return
	var air_count: int = (
		int(n_west == Blocks.AIR)
		+ int(n_east == Blocks.AIR)
		+ int(n_north == Blocks.AIR)
		+ int(n_south == Blocks.AIR)
	)
	if air_count != 1:
		return
	# Pattern matched. Place the fluid source; flow ticks find it next
	# tick and spill into the adjacent cave AIR cell.
	chunk.set_block_unchecked(lx, y, lz, fluid_id)
