class_name Lighting
extends RefCounted

# Sky-light propagation. Two-phase fill, called from the worker thread
# alongside meshing (lifetime: worker owns the chunk during gen → light →
# mesh, then hands to main).
#
# Vanilla reference (Bukkit/mc-dev `Chunk.java` init-lighting loop, lines
# ~160-185):
#   l = 15
#   for y from top down:
#     opacity = block_opacity(x, y, z)
#     if opacity == 0 and l != 15:
#       opacity = 1   # even pure-air cells consume 1 light below the heightmap
#     l = max(0, l - opacity)
#     setSkyLight(x, y, z, l)
#
# Then a separate BFS handles lateral propagation (caves, overhangs, light
# leaking through windows / leaf canopies). Vanilla does this incrementally
# via World.b(EnumSkyBlock, ...) — we run a one-shot BFS over the chunk on
# fill since we're starting from scratch.

const _MAX_LIGHT: int = 15

# Six 6-neighbor offsets for BFS.
const _NEIGHBORS: Array = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

# Maximum range a light value can travel from its source. With per-cell
# decay ≥ 1, a level-15 source dies in 15 steps, so any change at (lx, ly,
# lz) can only affect cells within this radius. Used by the bounded
# `update_sky_light_around` recompute to clamp the BFS box.
const _LIGHT_DECAY_RADIUS: int = 15

# Set by Game._ready() after the GDExtension loads. When non-null, the
# fast-path uses the C++ port (~10× faster than the GDScript fallback).
# Same lazy-instantiation pattern as Mesher._native_mesher / Worldgen.
static var _native_lighting: RefCounted
# Cached 256-entry opacity LUT, built once and handed to LightingNative on
# every fill. Built lazily through Blocks.light_opacity so it stays in
# sync with any block-id additions.
static var _native_opacity_lut: PackedByteArray
# 256-entry block-light emission LUT handed to LightingNative.
# fill_block_light. Lava returns 15 (max); everything else 0 today. Same
# lazy-init pattern as the opacity LUT; invalidated if Blocks ever grows
# a set_light_emission API (none today — values are constant).
static var _native_emission_lut: PackedByteArray


static func enable_native() -> bool:
	if _native_lighting != null:
		return true
	if not ClassDB.class_exists("LightingNative"):
		push_warning("Lighting.enable_native: LightingNative class not in ClassDB")
		return false
	_native_lighting = ClassDB.instantiate("LightingNative")
	return _native_lighting != null


# Fill `chunk.sky_light` in-place. Idempotent — overwrites prior values.
# Within-chunk only: lateral propagation is bounds-checked and never reads
# past the chunk's 16×128×16 footprint. Cross-chunk seam propagation runs
# separately via `relight_chunk_borders`, which the chunk_manager invokes
# after `_materialize_chunk` once a chunk is in the loaded set.
#
# Fast path: C++ LightingNative.fill_sky_light returns the new sky_light
# array (PackedByteArrays are COW so it must return rather than mutate).
# Falls through to the GDScript column + lateral passes when the
# extension isn't loaded. Parity guarded by tests/test_lighting.gd.
static func fill_sky_light(chunk: Chunk) -> void:
	var probe_token := PerfProbe.begin("lighting.fill_sky")
	if _native_lighting != null:
		chunk.sky_light = _native_lighting.fill_sky_light(chunk.blocks, _opacity_lut_for_native())
		PerfProbe.end("lighting.fill_sky", probe_token)
		return
	_column_pass(chunk)
	_lateral_pass(chunk)
	PerfProbe.end("lighting.fill_sky", probe_token)


# Collects the chunks intersecting the 31×31 box around world_pos and
# routes the BFS to the C++ LightingNative.update_sky_light_around_world.
# Manager must expose `get_chunk_at_coord(Vector2i) -> Chunk` (or null
# for unloaded). Touched chunks are written back + marked dirty via
# `manager.notify_chunk_lighting_updated(coord)`.
static func _update_sky_light_around_world_native(world_pos: Vector3i, manager) -> void:
	# BFS box spans world_pos ± 15. Convert to chunk-coord bounds.
	var min_x: int = world_pos.x - _LIGHT_DECAY_RADIUS
	var max_x: int = world_pos.x + _LIGHT_DECAY_RADIUS
	var min_z: int = world_pos.z - _LIGHT_DECAY_RADIUS
	var max_z: int = world_pos.z + _LIGHT_DECAY_RADIUS
	var min_cx: int = int(floor(float(min_x) / float(Chunk.SIZE_X)))
	var max_cx: int = int(floor(float(max_x) / float(Chunk.SIZE_X)))
	var min_cz: int = int(floor(float(min_z) / float(Chunk.SIZE_Z)))
	var max_cz: int = int(floor(float(max_z) / float(Chunk.SIZE_Z)))
	# Marshal each loaded chunk's data into the C++ input array shape.
	var chunk_data: Array = []
	for cx in range(min_cx, max_cx + 1):
		for cz in range(min_cz, max_cz + 1):
			var chunk: Chunk = manager.get_chunk_at_coord(Vector2i(cx, cz))
			if chunk == null:
				continue
			# Heightmap must be up-to-date before C++ reads it.
			# Trigger a rebuild via is_sky_exposed if dirty.
			chunk.is_sky_exposed(0, Chunk.SIZE_Y - 1, 0)
			chunk_data.append([cx, cz, chunk.blocks, chunk.sky_light, chunk.height_map])
	var result: Dictionary = _native_lighting.update_sky_light_around_world(
		world_pos.x, world_pos.y, world_pos.z, chunk_data, _opacity_lut_for_native()
	)
	# Apply each modified sky_light back to its chunk and notify the manager.
	for k: Vector2i in result:
		var c: Chunk = manager.get_chunk_at_coord(k)
		if c == null:
			continue
		c.sky_light = result[k]
		manager.notify_chunk_lighting_updated(k)


static func _opacity_lut_for_native() -> PackedByteArray:
	if _native_opacity_lut.is_empty():
		_native_opacity_lut = PackedByteArray()
		_native_opacity_lut.resize(256)
		for i in range(256):
			_native_opacity_lut[i] = Blocks.light_opacity(i)
	return _native_opacity_lut


static func _emission_lut_for_native() -> PackedByteArray:
	if _native_emission_lut.is_empty():
		_native_emission_lut = PackedByteArray()
		_native_emission_lut.resize(256)
		for i in range(256):
			_native_emission_lut[i] = Blocks.light_emission(i)
	return _native_emission_lut


# Fill `chunk.block_light` in-place from per-cell light_emission() sources.
# Vanilla's EnumSkyBlock.Block channel — torches, lava, glowstone emit
# Block.lightValue (Alpha Block.d()), decays by max(1, opacity) per step.
# Runs off the worker thread alongside fill_sky_light. Within-chunk only;
# cross-chunk seam propagation runs separately via `relight_chunk_borders`
# on chunk-load, and `update_block_light_around_world` on player edits.
#
# Fast path: LightingNative.fill_block_light. Parity with the GDScript
# fallback enforced by tests/test_lighting.gd.
static func fill_block_light(chunk: Chunk) -> void:
	var probe_token := PerfProbe.begin("lighting.fill_block")
	if _native_lighting != null:
		chunk.block_light = _native_lighting.fill_block_light(
			chunk.blocks, _opacity_lut_for_native(), _emission_lut_for_native()
		)
		PerfProbe.end("lighting.fill_block", probe_token)
		return
	var queue: Array[Vector3i] = []
	# Seed from every cell that emits light. Non-emitters start at 0; the
	# BFS doesn't need to visit them until a neighbor pushes a value in.
	for y in range(Chunk.SIZE_Y):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				var id: int = chunk.get_block_unchecked(x, y, z)
				var e: int = Blocks.light_emission(id)
				if e > 0:
					chunk.set_block_light(x, y, z, e)
					queue.append(Vector3i(x, y, z))
	# Standard BFS propagation — same shape as _lateral_pass for sky light,
	# but the input source is per-cell emission instead of a column-preseeded
	# heightmap.
	while not queue.is_empty():
		var p: Vector3i = queue.pop_back()
		var l: int = chunk.get_block_light(p.x, p.y, p.z)
		if l <= 1:
			continue
		for n: Vector3i in _NEIGHBORS:
			var nx: int = p.x + n.x
			var ny: int = p.y + n.y
			var nz: int = p.z + n.z
			if (
				nx < 0
				or nx >= Chunk.SIZE_X
				or ny < 0
				or ny >= Chunk.SIZE_Y
				or nz < 0
				or nz >= Chunk.SIZE_Z
			):
				continue
			var nid: int = chunk.get_block_unchecked(nx, ny, nz)
			var nopacity: int = Blocks.light_opacity(nid)
			var step: int = maxi(nopacity, 1)
			var new_light: int = maxi(0, l - step)
			if new_light > chunk.get_block_light(nx, ny, nz):
				chunk.set_block_light(nx, ny, nz, new_light)
				if new_light > 1:
					queue.append(Vector3i(nx, ny, nz))
	PerfProbe.end("lighting.fill_block", probe_token)


# Phase 1: per-column top-down. Mirrors vanilla Chunk.h() init-lighting.
# Above the topmost non-transparent cell, sky_light stays at 15. Once we
# encounter ANY opacity, every subsequent cell consumes max(1, opacity).
# This is why caves under solid terrain are 0 — the surface block kicks
# l down to 0 in one step (opacity 15), and below it stays at 0.
static func _column_pass(chunk: Chunk) -> void:
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			var light: int = _MAX_LIGHT
			var below_heightmap: bool = false
			for y in range(Chunk.SIZE_Y - 1, -1, -1):
				var id: int = chunk.get_block_unchecked(x, y, z)
				var opacity: int = Blocks.light_opacity(id)
				# Above the heightmap (any non-transparent block): sky_light
				# stays at 15 with no per-cell loss. Once we drop below, even
				# pure-air cells consume 1 light per step (vanilla's "j1 = 1
				# if l != 15" branch).
				if not below_heightmap and opacity == 0:
					chunk.set_sky_light(x, y, z, _MAX_LIGHT)
					continue
				below_heightmap = true
				var step: int = maxi(opacity, 1)
				light = maxi(0, light - step)
				chunk.set_sky_light(x, y, z, light)


# Phase 2: lateral BFS within the chunk. Seeds from every cell with
# sky_light > 1 (cells with light 0 or 1 can't reduce a neighbor below
# its current value, so they don't propagate). Each step writes
# `max(neighbor, my_light - max(1, neighbor_opacity))` and re-queues if
# the neighbor changed. Bounded by the chunk's 32K-cell footprint.
static func _lateral_pass(chunk: Chunk) -> void:
	# Seed only "potentially propagating" cells. After the column pass:
	# - Cells with light < 14 can't push a higher value into a neighbor
	#   (`max(0, light - 1) = light - 1 < 14` already ≤ neighbor unless
	#   neighbor itself is darker — those get covered by the BFS expansion).
	# - Above-heightmap cells at 15 are the primary sources; any darker
	#   cell that's adjacent to a brighter one will get popped via the
	#   neighbor-update path during BFS.
	# Seeding only cells at == 15 cuts ~5–10× off the seed work for typical
	# above-ground chunks while still converging to the same steady state.
	var queue: Array[Vector3i] = []
	for y in range(Chunk.SIZE_Y):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				if chunk.get_sky_light(x, y, z) == 15:
					queue.append(Vector3i(x, y, z))
	while not queue.is_empty():
		var p: Vector3i = queue.pop_back()
		var l: int = chunk.get_sky_light(p.x, p.y, p.z)
		if l <= 1:
			continue
		for n: Vector3i in _NEIGHBORS:
			var nx: int = p.x + n.x
			var ny: int = p.y + n.y
			var nz: int = p.z + n.z
			if (
				nx < 0
				or nx >= Chunk.SIZE_X
				or ny < 0
				or ny >= Chunk.SIZE_Y
				or nz < 0
				or nz >= Chunk.SIZE_Z
			):
				continue
			var nid: int = chunk.get_block_unchecked(nx, ny, nz)
			var nopacity: int = Blocks.light_opacity(nid)
			var step: int = maxi(nopacity, 1)
			var new_light: int = maxi(0, l - step)
			if new_light > chunk.get_sky_light(nx, ny, nz):
				chunk.set_sky_light(nx, ny, nz, new_light)
				if new_light > 1:
					queue.append(Vector3i(nx, ny, nz))


# Incremental sky-light update after a single block change at chunk-local
# (lx, ly, lz). Bounded to a 15-cell radius — light dies in 15 steps so
# a change can't propagate further. Mirrors vanilla mc.a() (vendor/alpha-
# 1.2.6-src/src/mc.java): for every cell in the box, recompute as
# `max(emission, max(6_neighbors) - opacity)`. If the value changed,
# re-queue neighbors. Handles BOTH brightening (block removed → light
# spreads in) and darkening (block placed → cells lit by old neighbor
# get pulled down) via the same recompute rule. Cells outside the box
# stay fixed and act as boundary inputs.
#
# vs. fill_sky_light: cheaper for a single edit (~box volume vs full
# chunk) and uses an emission-aware recompute that doesn't need a
# separate column pass — sky-exposed cells get emission=15 directly.
static func update_sky_light_around(chunk: Chunk, lx: int, ly: int, lz: int) -> void:
	var probe_token := PerfProbe.begin("lighting.update_sky")
	var x_lo: int = maxi(0, lx - _LIGHT_DECAY_RADIUS)
	var x_hi: int = mini(Chunk.SIZE_X - 1, lx + _LIGHT_DECAY_RADIUS)
	var y_lo: int = maxi(0, ly - _LIGHT_DECAY_RADIUS)
	var y_hi: int = mini(Chunk.SIZE_Y - 1, ly + _LIGHT_DECAY_RADIUS)
	var z_lo: int = maxi(0, lz - _LIGHT_DECAY_RADIUS)
	var z_hi: int = mini(Chunk.SIZE_Z - 1, lz + _LIGHT_DECAY_RADIUS)
	# Seed with the edit cell plus the column above (heightmap might have
	# moved up/down — every cell whose sky_exposed status could've flipped
	# needs a recompute) plus the 6 immediate neighbors. BFS expansion
	# fans out from there, naturally bounded by the box. Cuts the seed
	# from ~30K cells to ~SIZE_Y + 7 (≤135).
	var queue: Array[Vector3i] = []
	for y in range(y_lo, y_hi + 1):
		queue.append(Vector3i(lx, y, lz))
	for n: Vector3i in _NEIGHBORS:
		var nx: int = lx + n.x
		var ny: int = ly + n.y
		var nz: int = lz + n.z
		if nx >= x_lo and nx <= x_hi and ny >= y_lo and ny <= y_hi and nz >= z_lo and nz <= z_hi:
			queue.append(Vector3i(nx, ny, nz))
	while not queue.is_empty():
		var p: Vector3i = queue.pop_back()
		var current: int = chunk.get_sky_light(p.x, p.y, p.z)
		var new_light: int = _recompute_sky_light_at(chunk, p.x, p.y, p.z)
		if new_light == current:
			continue
		chunk.set_sky_light(p.x, p.y, p.z, new_light)
		# Re-queue neighbors within the box. Outside-box neighbors are
		# fixed inputs — vanilla expands the box on cy.a() for those; we
		# keep the radius static (light can't reach further than 15 cells).
		for n: Vector3i in _NEIGHBORS:
			var nx: int = p.x + n.x
			var ny: int = p.y + n.y
			var nz: int = p.z + n.z
			if (
				nx >= x_lo
				and nx <= x_hi
				and ny >= y_lo
				and ny <= y_hi
				and nz >= z_lo
				and nz <= z_hi
			):
				queue.append(Vector3i(nx, ny, nz))
	PerfProbe.end("lighting.update_sky", probe_token)


# Cross-chunk version of `update_sky_light_around`. Operates in world
# coordinates via a manager that exposes `get_world_block`,
# `get_world_sky_light`, `set_world_sky_light`. Crossing chunk boundaries
# is necessary because edits at the edge of one chunk would otherwise
# leave the neighbor chunk dark — visible as a black seam at the chunk
# border once slice 5 makes lighting render. Vanilla cy.a(SKY, ...) sets
# up regions that span chunks transparently via `World.getLight` /
# `World.setLight` — same semantic, different plumbing for our setup.
#
# Fast path: C++ LightingNative.update_sky_light_around_world. Collects
# the up-to-9 chunks intersecting the 31×31 BFS box, hands their blocks
# + sky_light + height_map to native. Returns a Dictionary keyed by
# chunk coord; we apply each result and mark dirty. Falls through to the
# GDScript BFS otherwise.
static func update_sky_light_around_world(world_pos: Vector3i, manager) -> void:
	var probe_token := PerfProbe.begin("lighting.update_sky_world")
	if _native_lighting != null and manager.has_method("get_chunk_at_coord"):
		_update_sky_light_around_world_native(world_pos, manager)
		PerfProbe.end("lighting.update_sky_world", probe_token)
		return
	var x_lo: int = world_pos.x - _LIGHT_DECAY_RADIUS
	var x_hi: int = world_pos.x + _LIGHT_DECAY_RADIUS
	var y_lo: int = maxi(0, world_pos.y - _LIGHT_DECAY_RADIUS)
	var y_hi: int = mini(Chunk.SIZE_Y - 1, world_pos.y + _LIGHT_DECAY_RADIUS)
	var z_lo: int = world_pos.z - _LIGHT_DECAY_RADIUS
	var z_hi: int = world_pos.z + _LIGHT_DECAY_RADIUS
	# Seed with the edit cell, its column (heightmap shift), and 6
	# neighbors — same shape as the chunk-local variant. BFS expansion
	# fans out naturally; ~30× fewer initial recomputes than the previous
	# every-cell-in-box seed.
	var queue: Array[Vector3i] = []
	for y in range(y_lo, y_hi + 1):
		queue.append(Vector3i(world_pos.x, y, world_pos.z))
	for n: Vector3i in _NEIGHBORS:
		var nx: int = world_pos.x + n.x
		var ny: int = world_pos.y + n.y
		var nz: int = world_pos.z + n.z
		if nx >= x_lo and nx <= x_hi and ny >= y_lo and ny <= y_hi and nz >= z_lo and nz <= z_hi:
			queue.append(Vector3i(nx, ny, nz))
	while not queue.is_empty():
		var p: Vector3i = queue.pop_back()
		# Unloaded chunks: set is a no-op so any divergence between recompute
		# and current would re-queue forever. Skip — manager's OOB defaults
		# still feed correct values into LOADED-chunk recomputes.
		if not _world_pos_in_loaded_chunk(p, manager):
			continue
		var current: int = manager.get_world_sky_light(p)
		var new_light: int = _recompute_sky_light_at_world(p, manager)
		if new_light == current:
			continue
		manager.set_world_sky_light(p, new_light)
		# Re-queue 6 neighbors within the box. Outside-box neighbors are
		# fixed inputs (vanilla expands the box on cy.a() for those; we
		# keep the radius static — light can't reach further than 15 cells
		# from the source).
		for n: Vector3i in _NEIGHBORS:
			var nx: int = p.x + n.x
			var ny: int = p.y + n.y
			var nz: int = p.z + n.z
			if (
				nx >= x_lo
				and nx <= x_hi
				and ny >= y_lo
				and ny <= y_hi
				and nz >= z_lo
				and nz <= z_hi
			):
				queue.append(Vector3i(nx, ny, nz))
	PerfProbe.end("lighting.update_sky_world", probe_token)


# World-coord variant of _recompute_sky_light_at. Reads neighbor block /
# sky_light via the manager so lookups span chunk boundaries. Skips
# nothing — manager.get_world_sky_light returns 15 for unloaded chunks
# (matches vanilla's "treat unloaded as full daylight" rule), so border
# cells correctly read neighbor brightness from across the chunk seam.
static func _recompute_sky_light_at_world(p: Vector3i, manager) -> int:
	var id: int = manager.get_world_block(p)
	var raw_opacity: int = Blocks.light_opacity(id)
	var emission: int = _MAX_LIGHT if _is_sky_exposed_world(p, manager) else 0
	if raw_opacity >= 15:
		return emission
	var step: int = maxi(raw_opacity, 1)
	var max_n: int = 0
	# When the queried cell is UNDER COVER (emission == 0, i.e. height_map
	# at this column > y), treat unloaded-chunk neighbours as DARK rather
	# than the vanilla "unknown = sky 15" convention. Rationale: an
	# unloaded neighbour at the same y is just as likely to be under the
	# same overhang as we are, so phantom-15 lights would flood-light
	# covered chunks at load boundaries. The vanilla convention still
	# applies for sky-exposed cells where the unloaded neighbour would
	# genuinely be sky-lit too. See
	# test_relight_overhang_phantom_light_from_unloaded_neighbour.
	var under_cover: bool = emission == 0
	for n: Vector3i in _NEIGHBORS:
		var np := Vector3i(p.x + n.x, p.y + n.y, p.z + n.z)
		var nl: int
		if under_cover and not _world_pos_in_loaded_chunk(np, manager):
			nl = 0
		else:
			nl = manager.get_world_sky_light(np)
		if nl > max_n:
			max_n = nl
	var from_neighbors: int = maxi(0, max_n - step)
	return maxi(emission, from_neighbors)


# World-coord sky-exposed — delegates to the manager which routes to the
# right chunk's cached heightmap (O(1)). Manager returns true for
# unloaded chunks (vanilla "unknown = sky-exposed" convention).
static func _is_sky_exposed_world(p: Vector3i, manager) -> bool:
	return manager.is_sky_exposed_at_world(p)


# Per-cell sky-light recompute mirroring vanilla mc.a()'s body:
#   emission = (sky_exposed ? 15 : 0)         # SKY channel
#   opacity  = max(1, lightOpacity(block))
#   if opacity >= 15 and emission == 0: return 0
#   from_neighbors = max(0, max(6_neighbors) - opacity)
#   return max(emission, from_neighbors)
static func _recompute_sky_light_at(chunk: Chunk, x: int, y: int, z: int) -> int:
	var id: int = chunk.get_block_unchecked(x, y, z)
	var raw_opacity: int = Blocks.light_opacity(id)
	var emission: int = _MAX_LIGHT if _is_sky_exposed(chunk, x, y, z) else 0
	if raw_opacity >= 15:
		return emission  # opaque cell: only its own emission (0 for non-sky-exposed sky channel)
	var step: int = maxi(raw_opacity, 1)
	var max_n: int = 0
	for n: Vector3i in _NEIGHBORS:
		var nx: int = x + n.x
		var ny: int = y + n.y
		var nz: int = z + n.z
		# Skip OOB neighbors — slice-1's `Chunk.get_sky_light` returns 15
		# for OOB-of-chunk (vanilla "unloaded chunks read as full daylight"),
		# but `fill_sky_light`'s lateral pass skips OOB. If we read OOB as
		# 15 here, edge cells get inflated to 14 (15 - 1) instead of
		# converging to the same value as fill_sky_light. This is the
		# CHUNK-LOCAL recompute used only by `update_sky_light_around` (test
		# helper); the cross-chunk variant `_recompute_sky_light_at_world`
		# DOES read across seams via the manager.
		if (
			nx < 0
			or nx >= Chunk.SIZE_X
			or ny < 0
			or ny >= Chunk.SIZE_Y
			or nz < 0
			or nz >= Chunk.SIZE_Z
		):
			continue
		var nl: int = chunk.get_sky_light(nx, ny, nz)
		if nl > max_n:
			max_n = nl
	var from_neighbors: int = maxi(0, max_n - step)
	return maxi(emission, from_neighbors)


# Sky-exposed query — delegates to the chunk's cached heightmap (vanilla
# ha.java `byte[256] h`). O(1) per call once the heightmap is built. The
# previous walk-up-column impl was O(SIZE_Y - y) and the bounded BFS
# called it ~30K times per edit — cache is the right perf win.
static func _is_sky_exposed(chunk: Chunk, x: int, y: int, z: int) -> bool:
	return chunk.is_sky_exposed(x, y, z)


# Loaded-chunk gate for the world-coord BFS loops. Cells in unloaded
# chunks read OOB defaults via the manager (15 for sky, 0 for block),
# which keeps recompute correct for cells right NEXT TO the seam. But
# attempting to PROCESS an unloaded cell is a trap: the manager's
# set_world_*_light call no-ops, so `current` and `new_light` keep
# diverging on every visit, and the BFS re-queues all 6 neighbors
# every time → infinite loop. The sky channel dodges this by accident
# because its OOB default of 15 makes `recompute(unloaded) == 15 ==
# current` for sky-exposed regions; the block channel (default 0)
# always trips the bug whenever an emitter brightens a cell adjacent
# to an unloaded chunk. Solution: skip unloaded cells in the BFS.
static func _world_pos_in_loaded_chunk(p: Vector3i, manager) -> bool:
	if not manager.has_method("get_chunk_at_coord"):
		# Stub manager without the method: assume loaded (test fixtures
		# build a known set of chunks and never seed BFS into the gap).
		return true
	var cx: int = int(floor(float(p.x) / float(Chunk.SIZE_X)))
	var cz: int = int(floor(float(p.z) / float(Chunk.SIZE_Z)))
	return manager.get_chunk_at_coord(Vector2i(cx, cz)) != null


# ---------------------------------------------------------------------------
# Block-light cross-chunk propagation. Mirrors the sky-light variants above
# but the per-cell source is `Blocks.light_emission` (torches = 14, lava =
# 15, glowstone = 15) instead of "is sky-exposed". Vanilla calls into the
# same `World.b(EnumSkyBlock, ...)` infrastructure with EnumSkyBlock.BLOCK
# selected (mc-dev MCWorld.b: switches on the enum to pick emission vs sky).
# ---------------------------------------------------------------------------


# World-coord block-light recompute, same shape as `_recompute_sky_light_at_world`
# but with per-cell emission as the source term:
#   emission = Blocks.light_emission(block_id)
#   opacity  = max(1, lightOpacity(block_id))
#   if opacity >= 15: return emission   # opaque cell; only its own emission
#   from_neighbors = max(0, max(6 neighbor block_lights) - opacity)
#   return max(emission, from_neighbors)
static func _recompute_block_light_at_world(p: Vector3i, manager) -> int:
	var id: int = manager.get_world_block(p)
	var raw_opacity: int = Blocks.light_opacity(id)
	var emission: int = Blocks.light_emission(id)
	if raw_opacity >= 15:
		return emission
	var step: int = maxi(raw_opacity, 1)
	var max_n: int = 0
	for n: Vector3i in _NEIGHBORS:
		var np := Vector3i(p.x + n.x, p.y + n.y, p.z + n.z)
		var nl: int = manager.get_world_block_light(np)
		if nl > max_n:
			max_n = nl
	var from_neighbors: int = maxi(0, max_n - step)
	return maxi(emission, from_neighbors)


# Edit-time block-light update — bounded BFS in world coords, mirrors
# `update_sky_light_around_world` for the sky channel. Called from
# `set_world_block` whenever a block change alters either light_emission
# (torch placed/broken) OR light_opacity (any block change near an emitter).
# Bidirectional recompute handles both brightening (torch placed) and
# darkening (torch broken — cells lit by it must drop back down) in one pass.
#
# Native fast-path is wired the same way as the sky variant once the C++
# port lands. Until then GDScript runs everywhere; cost is the same shape
# as the sky BFS (~box volume of cells visited).
static func update_block_light_around_world(world_pos: Vector3i, manager) -> void:
	var probe_token := PerfProbe.begin("lighting.update_block_world")
	if _native_lighting != null and manager.has_method("get_chunk_at_coord"):
		_update_block_light_around_world_native(world_pos, manager)
		PerfProbe.end("lighting.update_block_world", probe_token)
		return
	var x_lo: int = world_pos.x - _LIGHT_DECAY_RADIUS
	var x_hi: int = world_pos.x + _LIGHT_DECAY_RADIUS
	var y_lo: int = maxi(0, world_pos.y - _LIGHT_DECAY_RADIUS)
	var y_hi: int = mini(Chunk.SIZE_Y - 1, world_pos.y + _LIGHT_DECAY_RADIUS)
	var z_lo: int = world_pos.z - _LIGHT_DECAY_RADIUS
	var z_hi: int = world_pos.z + _LIGHT_DECAY_RADIUS
	var queue: Array[Vector3i] = []
	queue.append(world_pos)
	for n: Vector3i in _NEIGHBORS:
		var nx: int = world_pos.x + n.x
		var ny: int = world_pos.y + n.y
		var nz: int = world_pos.z + n.z
		if nx >= x_lo and nx <= x_hi and ny >= y_lo and ny <= y_hi and nz >= z_lo and nz <= z_hi:
			queue.append(Vector3i(nx, ny, nz))
	while not queue.is_empty():
		var p: Vector3i = queue.pop_back()
		# See `_world_pos_in_loaded_chunk` — block channel's OOB default of 0
		# makes the infinite-loop trap mandatory to gate against.
		if not _world_pos_in_loaded_chunk(p, manager):
			continue
		var current: int = manager.get_world_block_light(p)
		var new_light: int = _recompute_block_light_at_world(p, manager)
		if new_light == current:
			continue
		manager.set_world_block_light(p, new_light)
		for n: Vector3i in _NEIGHBORS:
			var nx: int = p.x + n.x
			var ny: int = p.y + n.y
			var nz: int = p.z + n.z
			if (
				nx >= x_lo
				and nx <= x_hi
				and ny >= y_lo
				and ny <= y_hi
				and nz >= z_lo
				and nz <= z_hi
			):
				queue.append(Vector3i(nx, ny, nz))
	PerfProbe.end("lighting.update_block_world", probe_token)


# Native fast-path for update_block_light_around_world. Same chunk-data
# marshalling shape as the sky variant, plus an emission_lut. Only
# requires `block_light` per chunk (no height_map needed for the block
# channel — its source is per-cell emission).
static func _update_block_light_around_world_native(world_pos: Vector3i, manager) -> void:
	var min_x: int = world_pos.x - _LIGHT_DECAY_RADIUS
	var max_x: int = world_pos.x + _LIGHT_DECAY_RADIUS
	var min_z: int = world_pos.z - _LIGHT_DECAY_RADIUS
	var max_z: int = world_pos.z + _LIGHT_DECAY_RADIUS
	var min_cx: int = int(floor(float(min_x) / float(Chunk.SIZE_X)))
	var max_cx: int = int(floor(float(max_x) / float(Chunk.SIZE_X)))
	var min_cz: int = int(floor(float(min_z) / float(Chunk.SIZE_Z)))
	var max_cz: int = int(floor(float(max_z) / float(Chunk.SIZE_Z)))
	var chunk_data: Array = []
	for cx in range(min_cx, max_cx + 1):
		for cz in range(min_cz, max_cz + 1):
			var chunk: Chunk = manager.get_chunk_at_coord(Vector2i(cx, cz))
			if chunk == null:
				continue
			chunk_data.append([cx, cz, chunk.blocks, chunk.block_light])
	var result: Dictionary = _native_lighting.update_block_light_around_world(
		world_pos.x,
		world_pos.y,
		world_pos.z,
		chunk_data,
		_opacity_lut_for_native(),
		_emission_lut_for_native()
	)
	for k: Vector2i in result:
		var c: Chunk = manager.get_chunk_at_coord(k)
		if c == null:
			continue
		c.block_light = result[k]
		manager.notify_chunk_lighting_updated(k)


# ---------------------------------------------------------------------------
# Cross-chunk relight on chunk load (slice 3b). Mirrors vanilla
# `World.b(EnumSkyBlock, x1, y1, z1, x2, y2, z2)` called from
# `WorldServer.lightChunk` after a chunk is added to the loaded set
# (Bukkit/mc-dev WorldServer.java). Walks the 4 cardinal seams with a
# loaded neighbor; for every seam cell on EITHER side, the world-coord
# recompute already crosses chunks correctly via `manager.get_world_*`,
# so we can just seed both BFSes from the seams and drain.
#
# The fill_*_light passes are per-chunk and always pessimistic at borders
# (lateral propagation is bounds-checked and never reads OOB). Without
# this relight pass, the seam between an old loaded chunk and a freshly
# loaded one shows hard light/dark steps — visible as a perfect 16×Y
# wall of darkness whenever a torch is near the edge, or a sealed cave
# fails to leak daylight from a sky-open neighbor.
#
# Cost: 4 seams × 16 × 128 = up to 8192 seed cells per channel + bounded
# BFS expansion. Runs on the main thread post-`_materialize_chunk` since
# that's already throttled to one chunk per frame. C++ port is task #7.
# ---------------------------------------------------------------------------


static func relight_chunk_borders(coord: Vector2i, manager) -> void:
	var probe_token := PerfProbe.begin("lighting.relight_borders")
	if not manager.has_method("get_chunk_at_coord"):
		PerfProbe.end("lighting.relight_borders", probe_token)
		return
	var target: Chunk = manager.get_chunk_at_coord(coord)
	if target == null:
		PerfProbe.end("lighting.relight_borders", probe_token)
		return
	# Loaded cardinal neighbors only. Diagonals don't share a face with us
	# (light propagates orthogonally per `_NEIGHBORS`); they can only matter
	# transitively via a cardinal neighbor that's itself loaded.
	var neighbors: Array[Vector2i] = []
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = coord + offset
		if manager.get_chunk_at_coord(n) != null:
			neighbors.append(n)
	if neighbors.is_empty():
		PerfProbe.end("lighting.relight_borders", probe_token)
		return
	# Native fast-path: marshal target + loaded neighbors into the C++
	# slab format and let LightingNative do the seam walk + dual BFS in
	# one call. ~10× faster than the GDScript path for typical chunk loads.
	if _native_lighting != null:
		_relight_chunk_borders_native(coord, target, neighbors, manager)
		PerfProbe.end("lighting.relight_borders", probe_token)
		return
	# AABB bound for the BFS — light decays in 15 steps, so the maximum
	# reach from a seam cell is 15 cells into either chunk. The bound
	# covers the target chunk + a 15-cell halo on every side so we never
	# spuriously overwrite cells in chunks past our loaded neighbors.
	var bx_lo: int = coord.x * Chunk.SIZE_X - _LIGHT_DECAY_RADIUS
	var bx_hi: int = (coord.x + 1) * Chunk.SIZE_X - 1 + _LIGHT_DECAY_RADIUS
	var bz_lo: int = coord.y * Chunk.SIZE_Z - _LIGHT_DECAY_RADIUS
	var bz_hi: int = (coord.y + 1) * Chunk.SIZE_Z - 1 + _LIGHT_DECAY_RADIUS
	var by_lo: int = 0
	var by_hi: int = Chunk.SIZE_Y - 1
	var sky_seeds: Array[Vector3i] = []
	var block_seeds: Array[Vector3i] = []
	var touched: Dictionary = {coord: true}
	for n_coord: Vector2i in neighbors:
		touched[n_coord] = true
		_seed_seam(coord, n_coord, manager, sky_seeds, block_seeds)
	if not sky_seeds.is_empty():
		_drain_world_relight_bfs(sky_seeds, manager, true, bx_lo, bx_hi, by_lo, by_hi, bz_lo, bz_hi)
	if not block_seeds.is_empty():
		_drain_world_relight_bfs(
			block_seeds, manager, false, bx_lo, bx_hi, by_lo, by_hi, bz_lo, bz_hi
		)
	for k: Vector2i in touched:
		manager.notify_chunk_lighting_updated(k)
	PerfProbe.end("lighting.relight_borders", probe_token)


# Native fast-path for relight_chunk_borders. Marshals target + each
# loaded cardinal neighbor's [blocks, sky_light, block_light, height_map]
# into a single C++ call that does the seam walk + dual-channel BFS.
# C++ heightmap reads expect the cached array up to date, so we trigger a
# rebuild via is_sky_exposed before marshalling each chunk (same trick as
# _update_sky_light_around_world_native).
static func _relight_chunk_borders_native(
	coord: Vector2i, target: Chunk, neighbors: Array[Vector2i], manager
) -> void:
	# Synchronous path — kept for the GDScript fallback / tests / any
	# caller that wants the result applied inline. The hot path (chunk
	# materialize) uses prepare_relight_data + compute_relight_borders_native
	# + apply_relight_result to run the BFS on a worker thread.
	var chunk_data: Array = prepare_relight_data(coord, target, neighbors, manager)
	var result: Dictionary = compute_relight_borders_native(coord, chunk_data)
	apply_relight_result(result, manager)


# Main-thread snapshot of the {target + cardinal neighbors} chunk slabs the
# native relight needs. Calls is_sky_exposed first to refresh each chunk's
# height_map cache (main-thread-only mutation). Duplicates each PackedByte
# array so the worker reads a stable buffer even if the player edits a
# block in one of these chunks before the worker finishes.
#
# Output shape (matches what _native_lighting.relight_chunk_borders expects):
#   [[chunk_x, chunk_z, blocks, sky_light, block_light, height_map], ...]
# with target listed first; neighbors that don't exist are skipped.
static func prepare_relight_data(
	coord: Vector2i, target: Chunk, neighbors: Array[Vector2i], manager
) -> Array:
	var t_hm := PerfProbe.begin("lighting.prepare_relight.height_map")
	target.is_sky_exposed(0, Chunk.SIZE_Y - 1, 0)
	PerfProbe.end("lighting.prepare_relight.height_map", t_hm)
	var t_dup := PerfProbe.begin("lighting.prepare_relight.dup")
	var chunk_data: Array = [
		[
			coord.x,
			coord.y,
			target.blocks.duplicate(),
			target.sky_light.duplicate(),
			target.block_light.duplicate(),
			target.height_map.duplicate(),
		]
	]
	PerfProbe.end("lighting.prepare_relight.dup", t_dup)
	for n_coord: Vector2i in neighbors:
		var n: Chunk = manager.get_chunk_at_coord(n_coord)
		if n == null:
			continue
		var t_nhm := PerfProbe.begin("lighting.prepare_relight.height_map")
		n.is_sky_exposed(0, Chunk.SIZE_Y - 1, 0)
		PerfProbe.end("lighting.prepare_relight.height_map", t_nhm)
		var t_ndup := PerfProbe.begin("lighting.prepare_relight.dup")
		(
			chunk_data
			. append(
				[
					n_coord.x,
					n_coord.y,
					n.blocks.duplicate(),
					n.sky_light.duplicate(),
					n.block_light.duplicate(),
					n.height_map.duplicate(),
				]
			)
		)
		PerfProbe.end("lighting.prepare_relight.dup", t_ndup)
	return chunk_data


# Worker-thread-safe wrapper around the native relight call. Reads only the
# snapshot array + the static LUTs (immutable after Lighting.warm_lookups);
# touches no live chunk state, so safe to invoke off main. Returns the
# result dict { Vector2i -> { sky_light, block_light } } unchanged.
static func compute_relight_borders_native(coord: Vector2i, chunk_data: Array) -> Dictionary:
	if _native_lighting == null:
		return {}
	return _native_lighting.relight_chunk_borders(
		coord.x, coord.y, chunk_data, _opacity_lut_for_native(), _emission_lut_for_native()
	)


# Main-thread apply of a relight result. Skips chunks that were unloaded
# while the worker was running. Edits to chunks in the result window after
# dispatch will get overwritten here — accepted because (a) the typical
# walking case has no edits, and (b) the next edit triggers
# `update_*_light_around_world` which repairs the affected cell.
static func apply_relight_result(result: Dictionary, manager) -> void:
	for k: Vector2i in result:
		var c: Chunk = manager.get_chunk_at_coord(k)
		if c == null:
			continue
		var entry: Dictionary = result[k]
		if entry.has("sky_light"):
			c.sky_light = entry["sky_light"]
		if entry.has("block_light"):
			c.block_light = entry["block_light"]
		manager.notify_chunk_lighting_updated(k)


# Walk the shared seam plane between target_coord and n_coord. For each
# cell on EITHER side of the seam, recompute both channels using the
# world-coord recompute (which sees across the seam via the manager).
# If the recomputed value differs from current, write the new value and
# enqueue the cell so the BFS can propagate the change inland.
#
# Bidirectional (write `new` regardless of direction) so a chunk loading
# with stale-saved sky_light from a prior session correctly darkens cells
# whose neighbors are now opaque, not just brightens. Symmetric to vanilla
# `cy.a()` recompute behavior.
static func _seed_seam(
	target_coord: Vector2i,
	n_coord: Vector2i,
	manager,
	sky_seeds: Array[Vector3i],
	block_seeds: Array[Vector3i]
) -> void:
	var dx: int = n_coord.x - target_coord.x
	var dz: int = n_coord.y - target_coord.y
	if dx != 0:
		# West/east seam: y-z plane. Walk the column on the target side
		# (x = 0 or 15) and the matching column on the neighbor side.
		var t_world_x: int = target_coord.x * Chunk.SIZE_X + (Chunk.SIZE_X - 1 if dx > 0 else 0)
		var n_world_x: int = t_world_x + dx
		for z in range(Chunk.SIZE_Z):
			var world_z: int = target_coord.y * Chunk.SIZE_Z + z
			for y in range(Chunk.SIZE_Y):
				_seed_cell(Vector3i(t_world_x, y, world_z), manager, sky_seeds, block_seeds)
				_seed_cell(Vector3i(n_world_x, y, world_z), manager, sky_seeds, block_seeds)
	else:
		# North/south seam: x-y plane.
		var t_world_z: int = target_coord.y * Chunk.SIZE_Z + (Chunk.SIZE_Z - 1 if dz > 0 else 0)
		var n_world_z: int = t_world_z + dz
		for x in range(Chunk.SIZE_X):
			var world_x: int = target_coord.x * Chunk.SIZE_X + x
			for y in range(Chunk.SIZE_Y):
				_seed_cell(Vector3i(world_x, y, t_world_z), manager, sky_seeds, block_seeds)
				_seed_cell(Vector3i(world_x, y, n_world_z), manager, sky_seeds, block_seeds)


# Recompute both channels at p. If either differs from the stored value,
# write the new value and add p to the matching seed list. Skipping cells
# where new == current avoids enqueueing 8K no-op seeds per chunk-load.
static func _seed_cell(
	p: Vector3i, manager, sky_seeds: Array[Vector3i], block_seeds: Array[Vector3i]
) -> void:
	var cur_sky: int = manager.get_world_sky_light(p)
	var new_sky: int = _recompute_sky_light_at_world(p, manager)
	if new_sky != cur_sky:
		manager.set_world_sky_light(p, new_sky)
		sky_seeds.append(p)
	var cur_block: int = manager.get_world_block_light(p)
	var new_block: int = _recompute_block_light_at_world(p, manager)
	if new_block != cur_block:
		manager.set_world_block_light(p, new_block)
		block_seeds.append(p)


# Generic world-coord BFS drain for either channel (selected by `is_sky`).
# Each pop recomputes via the matching world-coord function and writes
# bidirectionally; neighbors within the AABB are re-queued whenever the
# value changes. Same shape as `update_*_light_around_world` BFS but
# parameterized so we don't duplicate the loop for both channels.
static func _drain_world_relight_bfs(
	queue: Array[Vector3i],
	manager,
	is_sky: bool,
	x_lo: int,
	x_hi: int,
	y_lo: int,
	y_hi: int,
	z_lo: int,
	z_hi: int
) -> void:
	while not queue.is_empty():
		var p: Vector3i = queue.pop_back()
		if not _world_pos_in_loaded_chunk(p, manager):
			continue
		var current: int
		var new_light: int
		if is_sky:
			current = manager.get_world_sky_light(p)
			new_light = _recompute_sky_light_at_world(p, manager)
		else:
			current = manager.get_world_block_light(p)
			new_light = _recompute_block_light_at_world(p, manager)
		if new_light == current:
			continue
		if is_sky:
			manager.set_world_sky_light(p, new_light)
		else:
			manager.set_world_block_light(p, new_light)
		for n: Vector3i in _NEIGHBORS:
			var nx: int = p.x + n.x
			var ny: int = p.y + n.y
			var nz: int = p.z + n.z
			if (
				nx >= x_lo
				and nx <= x_hi
				and ny >= y_lo
				and ny <= y_hi
				and nz >= z_lo
				and nz <= z_hi
			):
				queue.append(Vector3i(nx, ny, nz))
