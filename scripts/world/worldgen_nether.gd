class_name WorldgenNether
extends RefCounted

# Alpha 1.2.6 Nether terrain — a port of `kj.java` (ChunkProviderHell).
# See docs/nether-alpha-1.2.6-implementation-plan.md §6.
#
# This is the CLARITY-FIRST REFERENCE implementation. It is deliberately
# a direct transcription of the source rather than an optimised one: a
# native port lands in Batch 5 and has to match this byte for byte, and
# tests/test_nether_worldgen_oracle.gd checks it against fixtures emitted
# by running the actual decompiled `kj.java` under a JDK.
#
# Two layouts are in play and confusing them silently transposes the
# world, so they are never mixed:
#
#   Alpha   (x * 16 + z) * 128 + y   — what kj.java indexes
#   Project  y * 256 + z * 16 + x    — what Chunk.blocks stores
#
# Generation happens entirely in the Alpha layout with RAW ALPHA BLOCK
# IDS, exactly as the source does. `remap_to_chunk` is the single place
# that converts both the layout and the ids, so each can be tested on its
# own.
#
# Worker-thread contract: everything here is pure computation over
# PackedByteArray / PackedFloat64Array. No scene nodes, no resources, no
# autoloads.

# kj.java:40-44 — the interpolation lattice.
const _CELLS_XZ: int = 4  # n4: 4 coarse cells across each horizontal axis
const _LAVA_LEVEL: int = 32  # n5: cells below this fill with lava, not air
const _GRID_XZ: int = 5  # n6 / n8: cell count + 1
const _GRID_Y: int = 17  # n7: vertical samples

# kj.java:207-208 — the base noise scales.
const _SCALE_XZ: float = 684.412
const _SCALE_Y: float = 2053.236

# kj.java:98 — surface-patch noise scale.
const _SURFACE_SCALE: float = 0.03125
# kj.java:97 — the Y the surface rules pivot around. Not sea level; the
# Nether has no sea, this is where the lava plain and the patches sit.
const _SURFACE_PIVOT: int = 64

# kj.java:190-191 — per-chunk RNG seeding for the surface pass.
const _SEED_MUL_X: int = 341873128712
const _SEED_MUL_Z: int = 132897987541

# Raw Alpha block ids, as written by the source. Kept separate from
# `Blocks.*` so the port reads like `kj.java` and the remap stays a single
# explicit step.
const ALPHA_AIR: int = 0
const ALPHA_GRASS: int = 2
const ALPHA_DIRT: int = 3
const ALPHA_BEDROCK: int = 7
const ALPHA_LAVA_FLOWING: int = 10
const ALPHA_LAVA_STILL: int = 11
const ALPHA_GRAVEL: int = 13
const ALPHA_NETHERRACK: int = 87
const ALPHA_SOUL_SAND: int = 88
# Written only by population (Batch 4), never by terrain.
const ALPHA_MUSHROOM_BROWN: int = 39
const ALPHA_MUSHROOM_RED: int = 40
const ALPHA_FIRE: int = 51
const ALPHA_GLOWSTONE: int = 89

const _CHUNK_VOLUME: int = 32768

# Raw Alpha id -> project id. Every id the Nether generator can emit is
# listed; anything else is a bug and remap_to_chunk says so loudly rather
# than writing a byte nobody registered.
const _ID_REMAP: Dictionary = {
	ALPHA_AIR: 0,  # Blocks.AIR
	ALPHA_GRASS: 4,  # Blocks.GRASS
	ALPHA_DIRT: 3,  # Blocks.DIRT
	ALPHA_BEDROCK: 1,  # Blocks.BEDROCK
	ALPHA_LAVA_FLOWING: 25,  # Blocks.LAVA_FLOWING
	ALPHA_LAVA_STILL: 26,  # Blocks.LAVA_STILL
	ALPHA_GRAVEL: 18,  # Blocks.GRAVEL
	ALPHA_NETHERRACK: 97,  # Blocks.NETHERRACK
	ALPHA_SOUL_SAND: 98,  # Blocks.SOUL_SAND
	# Population-only ids (Batch 4).
	ALPHA_FIRE: 27,  # Blocks.FIRE
	ALPHA_GLOWSTONE: 99,  # Blocks.GLOWSTONE
	ALPHA_MUSHROOM_BROWN: 39,  # Blocks.MUSHROOM_BROWN
	ALPHA_MUSHROOM_RED: 40,  # Blocks.MUSHROOM_RED
}

# The seven octave generators, drawn from ONE shared JavaRandom in
# kj.java:30-37's exact order: 16, 16, 8, 4, 4, 10, 16. Octave count
# decides how many Perlin permutation tables each consumes, so reordering
# desynchronises every generator after the change.
static var _main_a: NoiseOctaves  # kj this.i
static var _main_b: NoiseOctaves  # kj this.j
static var _selector: NoiseOctaves  # kj this.k
static var _surface_a: NoiseOctaves  # kj this.l
static var _surface_b: NoiseOctaves  # kj this.m
static var _aux_10: NoiseOctaves  # kj this.a
static var _aux_16: NoiseOctaves  # kj this.b
static var _cached_seed: int = 0
static var _built: bool = false
# Native dispatch (Batch 5). The GDScript path stays the correctness
# reference and the fallback for platforms without the extension; when the
# native class is present every entry point routes to it instead, and
# tests/test_nether_worldgen_native.gd proves the two produce identical
# bytes.
static var _native: RefCounted = null

# kj keeps its Random as a field (`this.h`) and reseeds it per chunk. This
# port does NOT: chunk generation runs on WorkerThreadPool, and a shared
# mutable Random is corrupted the moment two workers overlap — the surface
# pass would interleave two chunks' draws. The Random is created per chunk
# and threaded through instead, which is both thread-safe and a closer
# match to how the source actually uses it (seeded, consumed, discarded).

# kj reuses long-lived scratch fields for its noise grids. This port
# allocates per call instead: Packed arrays are copy-on-write value types
# in GDScript, so shared static buffers would be a threading hazard the
# moment two chunk workers overlap, and the allocation is noise next to
# the noise sampling itself.

# --- Index helpers (plan §6.2: never paste source index arithmetic) ---


# Alpha's chunk byte[] index. kj.java writes through this everywhere.
static func alpha_index(x: int, y: int, z: int) -> int:
	return (x * 16 + z) * 128 + y


# Our Chunk.blocks index. Y-major; see CLAUDE.md.
static func project_index(x: int, y: int, z: int) -> int:
	return y * (Chunk.SIZE_X * Chunk.SIZE_Z) + z * Chunk.SIZE_X + x


# Coarse density-grid index. kj.java walks (X, Z, Y) with Y innermost.
static func density_index(gx: int, gy: int, gz: int) -> int:
	return (gx * _GRID_XZ + gz) * _GRID_Y + gy


# --- Setup ---


static func enable_native() -> bool:
	if not ClassDB.class_exists("WorldgenNetherNative"):
		return false
	_native = ClassDB.instantiate("WorldgenNetherNative")
	if _native == null:
		return false
	_native.call("set_world_seed", Worldgen.WORLD_SEED)
	return true


static func native_available() -> bool:
	return _native != null


static func native_write_list(source_x: int, source_z: int) -> PackedInt32Array:
	return _native.call("write_list", source_x, source_z)


static func reset() -> void:
	_built = false
	WorldgenNetherPopulation.reset()
	if _native != null:
		_native.call("set_world_seed", Worldgen.WORLD_SEED)


# Build the noise generators up front. Called from Game._ready for the
# same reason Worldgen.surface_height(0, 0) is: `_ensure_built` is the one
# lazy step in the pipeline, and a worker hitting it first would race.
static func warm(world_seed: int) -> void:
	_ensure_built(world_seed)


static func _ensure_built(world_seed: int) -> void:
	if _built and _cached_seed == world_seed:
		return
	# kj.java:30 — ONE Random, shared by all seven constructors.
	var shared := JavaRandom.new(world_seed)
	_main_a = NoiseOctaves.create_vanilla_chained(shared, 16)
	_main_b = NoiseOctaves.create_vanilla_chained(shared, 16)
	_selector = NoiseOctaves.create_vanilla_chained(shared, 8)
	_surface_a = NoiseOctaves.create_vanilla_chained(shared, 4)
	_surface_b = NoiseOctaves.create_vanilla_chained(shared, 4)
	_aux_10 = NoiseOctaves.create_vanilla_chained(shared, 10)
	_aux_16 = NoiseOctaves.create_vanilla_chained(shared, 16)
	_cached_seed = world_seed
	_built = true


# --- Stage 1: coarse density field (kj.java:195-258) ---


static func density_grid(chunk_x: int, chunk_z: int) -> PackedFloat64Array:
	_ensure_built(Worldgen.WORLD_SEED)
	var total: int = _GRID_XZ * _GRID_Y * _GRID_XZ
	var out := PackedFloat64Array()
	out.resize(total)
	var aux10_buf := PackedFloat64Array()
	aux10_buf.resize(_GRID_XZ * _GRID_XZ)
	var aux16_buf := PackedFloat64Array()
	aux16_buf.resize(_GRID_XZ * _GRID_XZ)
	var sel_buf := PackedFloat64Array()
	sel_buf.resize(total)
	var main_a_buf := PackedFloat64Array()
	main_a_buf.resize(total)
	var main_b_buf := PackedFloat64Array()
	main_b_buf.resize(total)
	var base_x: int = chunk_x * _CELLS_XZ
	var base_z: int = chunk_z * _CELLS_XZ

	# kj.java:209-213. `this.f` (aux 10) and `this.g` (aux 16) are sampled
	# and their results assigned to locals that the source then never
	# reads again — see the DEAD-VALUE note in the blend loop. They are
	# kept because dropping them would diverge from the source if a later
	# Alpha revision starts reading them, and they cost nothing: sampling
	# does not touch the shared Random.
	_aux_10.sample_3d_grid(aux10_buf, base_x, 0, base_z, _GRID_XZ, 1, _GRID_XZ, 1.0, 0.0, 1.0)
	_aux_16.sample_3d_grid(aux16_buf, base_x, 0, base_z, _GRID_XZ, 1, _GRID_XZ, 100.0, 0.0, 100.0)
	_selector.sample_3d_grid(
		sel_buf,
		base_x,
		0,
		base_z,
		_GRID_XZ,
		_GRID_Y,
		_GRID_XZ,
		_SCALE_XZ / 80.0,
		_SCALE_Y / 60.0,
		_SCALE_XZ / 80.0
	)
	_main_a.sample_3d_grid(
		main_a_buf, base_x, 0, base_z, _GRID_XZ, _GRID_Y, _GRID_XZ, _SCALE_XZ, _SCALE_Y, _SCALE_XZ
	)
	_main_b.sample_3d_grid(
		main_b_buf, base_x, 0, base_z, _GRID_XZ, _GRID_Y, _GRID_XZ, _SCALE_XZ, _SCALE_Y, _SCALE_XZ
	)

	# kj.java:215-227 — vertical bias, one value per Y sample.
	#
	# `cos(y * PI * 6 / 17) * 2` gives the Nether its stacked-cavern
	# banding. The cubic penalty within four samples of EITHER vertical
	# end is what seals the floor and roof: it subtracts up to 640, which
	# no density value can overcome.
	var bias := PackedFloat64Array()
	bias.resize(_GRID_Y)
	for gy: int in range(_GRID_Y):
		bias[gy] = cos(float(gy) * PI * 6.0 / float(_GRID_Y)) * 2.0
		var d: float = float(gy)
		if gy > _GRID_Y / 2:
			d = float(_GRID_Y - 1 - gy)
		if d < 4.0:
			d = 4.0 - d
			bias[gy] -= d * d * d * 10.0

	# kj.java:228-257 — blend the two main fields with the selector.
	var idx: int = 0
	for gx: int in range(_GRID_XZ):
		for gz: int in range(_GRID_XZ):
			# DEAD VALUES: the source computes `d5` from the aux-10 field
			# and `d7` from the aux-16 field here, clamps and rescales
			# both, then never reads either again. `d6` is likewise fixed
			# at 0.0, which makes the lower-bound blend branch below
			# unreachable. Verified against the compiled source by the
			# Batch 3 oracle; the Overworld provider (px.java) DOES read
			# its equivalents, which is presumably where they came from.
			for gy: int in range(_GRID_Y):
				var lo: float = main_a_buf[idx] / 512.0
				var hi: float = main_b_buf[idx] / 512.0
				var t: float = (sel_buf[idx] / 10.0 + 1.0) / 2.0
				var value: float = 0.0
				if t < 0.0:
					value = lo
				elif t > 1.0:
					value = hi
				else:
					value = lo + (hi - lo) * t
				value -= bias[gy]
				# Top blend toward -10 over the last three samples, which
				# is what actually caps the world under the roof bedrock.
				if gy > _GRID_Y - 4:
					# FLOAT32 arithmetic in the source: `(float)(i3 - 13)
					# / 3.0f`. 1/3 as a float32 is 0.33333334, not
					# 0.3333333333333333, and the difference is visible in
					# the final bytes. _f32 pins it.
					var mix: float = _f32(_f32(float(gy - (_GRID_Y - 4))) / _f32(3.0))
					value = value * (1.0 - mix) + -10.0 * mix
				out[idx] = value
				idx += 1
	return out


# --- Stage 2: base fill (kj.java:40-93) ---


static func fill_base(blocks: PackedByteArray, chunk_x: int, chunk_z: int) -> void:
	var grid: PackedFloat64Array = density_grid(chunk_x, chunk_z)
	for cell_x: int in range(_CELLS_XZ):
		for cell_z: int in range(_CELLS_XZ):
			for cell_y: int in range(16):
				var y_step: float = 0.125
				var c000: float = grid[density_index(cell_x, cell_y, cell_z)]
				var c001: float = grid[density_index(cell_x, cell_y, cell_z + 1)]
				var c100: float = grid[density_index(cell_x + 1, cell_y, cell_z)]
				var c101: float = grid[density_index(cell_x + 1, cell_y, cell_z + 1)]
				var d000: float = (grid[density_index(cell_x, cell_y + 1, cell_z)] - c000) * y_step
				var d001: float = (
					(grid[density_index(cell_x, cell_y + 1, cell_z + 1)] - c001) * y_step
				)
				var d100: float = (
					(grid[density_index(cell_x + 1, cell_y + 1, cell_z)] - c100) * y_step
				)
				var d101: float = (
					(grid[density_index(cell_x + 1, cell_y + 1, cell_z + 1)] - c101) * y_step
				)
				for sub_y: int in range(8):
					var xz_step: float = 0.25
					var e00: float = c000
					var e01: float = c001
					var de0: float = (c100 - c000) * xz_step
					var de1: float = (c101 - c001) * xz_step
					for sub_x: int in range(4):
						var world_y: int = cell_y * 8 + sub_y
						var x: int = cell_x * 4 + sub_x
						var z_step: float = 0.25
						var v: float = e00
						var dv: float = (e01 - e00) * z_step
						for sub_z: int in range(4):
							var z: int = cell_z * 4 + sub_z
							# kj.java:73-79 — below the lava level an empty
							# cell is LAVA, not air. Above it, air.
							var id: int = ALPHA_AIR
							if world_y < _LAVA_LEVEL:
								id = ALPHA_LAVA_STILL
							if v > 0.0:
								id = ALPHA_NETHERRACK
							blocks[alpha_index(x, world_y, z)] = id
							v += dv
						e00 += de0
						e01 += de1
					c000 += d000
					c001 += d001
					c100 += d100
					c101 += d101


# --- Stage 3: surface replacement and bedrock (kj.java:95-165) ---


static func apply_surface(
	blocks: PackedByteArray, chunk_x: int, chunk_z: int, rng: JavaRandom
) -> void:
	_ensure_built(Worldgen.WORLD_SEED)
	var s: float = _SURFACE_SCALE
	# kj.java:98-100. Note the second call's argument order: it passes
	# (chunk_z * 16, 109.0134, chunk_x * 16) — X and Z swapped, with a
	# magic Y. That is what the source does; it is not a typo here.
	var soul_buf := PackedFloat64Array()
	soul_buf.resize(256)
	var gravel_buf := PackedFloat64Array()
	gravel_buf.resize(256)
	var depth_buf := PackedFloat64Array()
	depth_buf.resize(256)
	_surface_a.sample_3d_grid(soul_buf, chunk_x * 16, chunk_z * 16, 0.0, 16, 16, 1, s, s, 1.0)
	_surface_a.sample_3d_grid(
		gravel_buf, chunk_z * 16, 109.0134, chunk_x * 16, 16, 1, 16, s, 1.0, s
	)
	_surface_b.sample_3d_grid(
		depth_buf, chunk_x * 16, chunk_z * 16, 0.0, 16, 16, 1, s * 2.0, s * 2.0, s * 2.0
	)

	for lx: int in range(16):
		for lz: int in range(16):
			# kj.java:103-105 — three draws per column, in this order.
			var soul: bool = soul_buf[lx + lz * 16] + rng.next_double() * 0.2 > 0.0
			var gravel: bool = gravel_buf[lx + lz * 16] + rng.next_double() * 0.2 > 0.0
			var depth: int = int(depth_buf[lx + lz * 16] / 3.0 + 3.0 + rng.next_double() * 0.25)
			var remaining: int = -1
			var top_block: int = ALPHA_NETHERRACK
			var filler_block: int = ALPHA_NETHERRACK
			for y: int in range(127, -1, -1):
				var idx: int = alpha_index(lx, y, lz)
				# kj.java:110-117 — the two bedrock bands. BOTH nextInt(5)
				# calls are inside the loop, and the second only runs when
				# the first test fails. Getting that consumption order
				# wrong desynchronises every later column.
				if y >= 127 - rng.next_int_bounded(5):
					blocks[idx] = ALPHA_BEDROCK
					continue
				if y <= rng.next_int_bounded(5):
					blocks[idx] = ALPHA_BEDROCK
					continue
				var current: int = blocks[idx]
				if current == ALPHA_AIR:
					remaining = -1
					continue
				if current != ALPHA_NETHERRACK:
					continue
				if remaining == -1:
					if depth <= 0:
						top_block = ALPHA_AIR
						filler_block = ALPHA_NETHERRACK
					elif y >= _SURFACE_PIVOT - 4 and y <= _SURFACE_PIVOT + 1:
						top_block = ALPHA_NETHERRACK
						filler_block = ALPHA_NETHERRACK
						# kj.java:130-141 — gravel first, then soul sand
						# overrides it. The source writes each assignment
						# as its own `if`; the effect is this.
						if gravel:
							top_block = ALPHA_GRAVEL
							filler_block = ALPHA_NETHERRACK
						if soul:
							top_block = ALPHA_SOUL_SAND
							filler_block = ALPHA_SOUL_SAND
					if y < _SURFACE_PIVOT and top_block == ALPHA_AIR:
						top_block = ALPHA_LAVA_STILL
					remaining = depth
					if y >= _SURFACE_PIVOT - 1:
						blocks[idx] = top_block
					else:
						blocks[idx] = filler_block
					continue
				if remaining <= 0:
					continue
				remaining -= 1
				blocks[idx] = filler_block


# --- Entry points ---


# Raw Alpha bytes in the Alpha layout, terrain only. Matches what the
# oracle's `after_caves` stage reports.
# kj.java:167 — the per-chunk seed, set BEFORE any fill. The density pass
# does not consume the Random, but the surface pass does, so the order
# still matters. Exposed so the oracle test can drive one stage at a time
# and bisect a mismatch instead of only knowing the chunk differs.
static func new_chunk_buffer() -> PackedByteArray:
	var blocks := PackedByteArray()
	blocks.resize(_CHUNK_VOLUME)
	return blocks


# The per-chunk Random, seeded exactly as kj.b(int,int) does before any
# fill. The density pass does not consume it, but the surface pass does,
# so it has to be created before either runs.
static func chunk_rng(chunk_x: int, chunk_z: int) -> JavaRandom:
	_ensure_built(Worldgen.WORLD_SEED)
	return JavaRandom.new(chunk_x * _SEED_MUL_X + chunk_z * _SEED_MUL_Z)


# Terrain only: density, surface, bedrock and caves, with no decorations.
# This is what a source chunk's population reads, and what the oracle's
# `after_caves` stage reports.
static func generate_terrain_only(chunk_x: int, chunk_z: int) -> PackedByteArray:
	if _native != null:
		return _native.call("generate_terrain_only", chunk_x, chunk_z)
	return generate_terrain_only_gdscript(chunk_x, chunk_z)


# The reference path, kept callable by name so the parity test can drive
# both sides in one process without unloading the extension.
static func generate_terrain_only_gdscript(chunk_x: int, chunk_z: int) -> PackedByteArray:
	var blocks: PackedByteArray = new_chunk_buffer()
	var rng: JavaRandom = chunk_rng(chunk_x, chunk_z)
	fill_base(blocks, chunk_x, chunk_z)
	apply_surface(blocks, chunk_x, chunk_z, rng)
	WorldgenNetherCaves.carve(blocks, chunk_x, chunk_z)
	return blocks


# The RNG state a chunk's population starts from: its own seed, advanced
# by exactly the draws the surface pass makes.
#
# This is the plan's §6.5 canonicalisation in one function. Alpha does not
# reseed before populating, so its decorations inherit whatever state the
# previously generated chunk left behind — which is what makes vanilla
# Nether decoration load-order dependent. Reconstructing the state per
# source chunk removes that without changing what the decorators do.
#
# Running the surface pass into a scratch buffer is deliberate: the draw
# sequence depends on the terrain it walks, so it cannot be shortcut to a
# fixed number of advances.
static func post_surface_rng(chunk_x: int, chunk_z: int) -> JavaRandom:
	var scratch: PackedByteArray = new_chunk_buffer()
	var rng: JavaRandom = chunk_rng(chunk_x, chunk_z)
	fill_base(scratch, chunk_x, chunk_z)
	apply_surface(scratch, chunk_x, chunk_z, rng)
	return rng


static func generate_raw(chunk_x: int, chunk_z: int) -> PackedByteArray:
	if _native != null:
		return _native.call("generate_raw", chunk_x, chunk_z)
	return generate_raw_gdscript(chunk_x, chunk_z)


static func generate_raw_gdscript(chunk_x: int, chunk_z: int) -> PackedByteArray:
	var blocks: PackedByteArray = generate_terrain_only_gdscript(chunk_x, chunk_z)
	WorldgenNetherPopulation.decorate(blocks, chunk_x, chunk_z)
	return blocks


# Convert raw Alpha bytes + layout into a project Chunk. The ONLY place
# either mapping happens.
static func remap_to_chunk(raw: PackedByteArray, chunk: Chunk) -> void:
	var max_y: int = 0
	for y: int in range(Chunk.SIZE_Y):
		for z: int in range(Chunk.SIZE_Z):
			for x: int in range(Chunk.SIZE_X):
				var alpha_id: int = raw[alpha_index(x, y, z)]
				var project_id: int = int(_ID_REMAP.get(alpha_id, -1))
				if project_id < 0:
					push_error(
						(
							"[WorldgenNether] unmapped Alpha block id %d at (%d, %d, %d)"
							% [alpha_id, x, y, z]
						)
					)
					project_id = Blocks.AIR
				chunk.blocks[project_index(x, y, z)] = project_id
				if project_id != Blocks.AIR and y > max_y:
					max_y = y
	chunk.max_y = max_y


static func generate_chunk(chunk_x: int, chunk_z: int) -> Chunk:
	var chunk := Chunk.new()
	remap_to_chunk(generate_raw(chunk_x, chunk_z), chunk)
	return chunk


# --- Helpers ---


# Round a double through float32, matching a Java `float` expression.
static func _f32(v: float) -> float:
	var b := PackedFloat32Array([v])
	return b[0]
