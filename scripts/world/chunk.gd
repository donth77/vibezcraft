class_name Chunk
extends RefCounted

# Pure block-data container. Visualization is handled by chunk_node.gd.

const SIZE_X := 16
const SIZE_Y := 128
const SIZE_Z := 16
const TOTAL_BLOCKS := SIZE_X * SIZE_Y * SIZE_Z

var blocks: PackedByteArray
# Per-cell 4-bit block metadata (0..15). Used by BlockFluids for flow
# level (0 = source, 1..7 = cascading spread, 8 = falling), by furnaces
# for lit/unlit + rotation, saplings for tree-type index, etc. Mirrors
# vanilla Alpha `ha.java`'s `NibbleArray e` field (Bukkit Chunk.java
# `BlockMeta`). Same byte-per-cell vs nibble trade-off as sky_light —
# 32 KB memory for O(1) random-access reads without shift/mask on the
# hot path (Flow algorithm does 6+ metadata lookups per tick per fluid
# cell; keeping it cheap matters).
var block_meta: PackedByteArray
# Per-cell sky-light (0..15) — 15 = full daylight, 0 = pitch black. Matches
# vanilla EnumSkyBlock.SKY (Bukkit/mc-dev EnumSkyBlock.java: `SKY("Sky",
# 0, 15)` — last arg 15 is the "default value when chunk unloaded"). Vanilla
# packs this into a NibbleArray (4-bit/cell) for RAM; we use one byte per
# cell to skip the shift+mask per access — 32 KB per chunk vs 16 KB packed,
# which is irrelevant at our chunk counts and saves real wall-clock time
# on the meshing inner loop.
var sky_light: PackedByteArray
# Per-cell block-light (0..15) — emitted by torches, lava, glowstone.
# Default 0 (no emitters). Same byte-per-cell rationale as sky_light.
# Vanilla EnumSkyBlock.BLOCK declares default 0 for the same reason.
var block_light: PackedByteArray
var dirty: bool = true
# Highest Y at which a non-AIR block exists. Lets the mesher skip the empty
# upper layers entirely. Monotonically increases — a player breaking the
# topmost block won't shrink it, but the cost of meshing 1 extra layer is
# negligible.
var max_y: int = 0
# Sticky flag: true once any non-cube block (sapling, future torch/slab)
# has been written into this chunk. Mesher.mesh_chunk_fast checks it to
# decide between the C++ MesherNative cube fast-path and the pure-GDScript
# Mesher.mesh_chunk that knows the cross-quad / custom shape branches.
# Sticky-only-grows is fine — flipping it back when the last sapling is
# broken would just churn the next mesh between native and GDScript paths
# for no visible difference, and worldgen never sets it so the hot path
# stays on the native cube fast-path.
var has_non_cube_blocks: bool = false
# World coords of the top SUGAR_CANE cell in each cane column. Populated by
# worker-thread paths (Worldgen._scatter_sugar_cane + _decode_saved_entry)
# so chunk materialize can drain the list straight into the growth queue
# instead of scanning all 32 KB of chunk.blocks on the main thread —
# `_enqueue_existing_canes` used to be ~12 ms per materialize.
var cane_tops: Array[Vector3i] = []
# Sticky flag set when any water cell exists in the chunk. Mesher uses it
# to build the water sub-mesh; chunk_node.gd uses it to spawn the second
# MeshInstance3D with the water shader material. Same sticky-only-grows
# rule as has_non_cube_blocks.
var has_water_cells: bool = false
var has_chest_blocks: bool = false
# Per-(x,z) heightmap, 256 entries indexed `z * SIZE_X + x`. Each cell
# stores `(y of topmost cell with light_opacity > 0) + 1`. Cells at
# `y >= height_map[x,z]` are sky-exposed (vanilla canSeeSky semantics).
# Mirrors Alpha 1.2.6 ha.java's `byte[256] h` field. Maintained
# incrementally by `set_block` / `set_block_unchecked`; rebuilt lazily
# from raw blocks via `_rebuild_height_map` if `_height_map_dirty` is set
# (e.g. on chunk gen, or after restoring from a save without one).
var height_map: PackedByteArray
# Optional 1-cell-wide edge slices from the 4 neighbor chunks, populated
# at mesh-dispatch time by chunk_node._dispatch_remesh when those
# neighbors are loaded. Lets get_block() + get_block_meta() see one cell
# across the chunk seam so the mesher can cull shared water faces.
# Layout: each slice is a flat PackedByteArray of SIZE_Y × (SIZE_X|SIZE_Z).
var edge_blocks_west: PackedByteArray
var edge_blocks_east: PackedByteArray
var edge_blocks_north: PackedByteArray
var edge_blocks_south: PackedByteArray
var edge_meta_west: PackedByteArray
var edge_meta_east: PackedByteArray
var edge_meta_north: PackedByteArray
var edge_meta_south: PackedByteArray
var _height_map_dirty: bool = true


func _init() -> void:
	blocks = PackedByteArray()
	blocks.resize(TOTAL_BLOCKS)
	# Block metadata: 0 = default. Zero-filled by resize(). For water/lava
	# a 0 meta = source block (vanilla BlockFluids: level=0 is source,
	# 1..7 is flowing cascade). For non-fluid blocks 0 is also the default
	# state. So this array's zero-init correctness is automatic.
	block_meta = PackedByteArray()
	block_meta.resize(TOTAL_BLOCKS)
	# Default sky-light = 15 (full daylight) so any cell never visited by the
	# light-fill pass still reads as "lit" — matches vanilla's behavior of
	# treating unloaded chunks as fully sky-lit (EnumSkyBlock.SKY default 15).
	# Slice 3's fill pass will later overwrite this with proper top-down +
	# lateral propagation; until then, the world looks as bright as it does
	# today.
	sky_light = PackedByteArray()
	sky_light.resize(TOTAL_BLOCKS)
	sky_light.fill(15)
	# Block-light defaults to 0 (no emitters present). PackedByteArray's
	# resize already zero-fills, so no explicit loop needed.
	block_light = PackedByteArray()
	block_light.resize(TOTAL_BLOCKS)
	# Heightmap: 256 entries, all 0 = "no opaque blocks anywhere" so every
	# cell reads as sky-exposed by default. The all-zero state IS already
	# consistent with an empty (all-AIR) chunk, so _height_map_dirty
	# starts FALSE — worldgen incremental writes via set_block_unchecked
	# keep it correct as blocks land. Restored chunks set the flag back to
	# true via _decode_saved_entry, OR persist + restore the array
	# directly to skip the rebuild.
	height_map = PackedByteArray()
	height_map.resize(SIZE_X * SIZE_Z)
	_height_map_dirty = false


# Extract the blocks + meta at a constant-x plane in a single pass.
# Returns [blocks_slice, meta_slice] indexed `y * SIZE_Z + z`. Fuses
# the two separate 2048-cell loops (_slice_x + _slice_meta_x) into one
# — halves the iteration count per edge extraction.
func _edge_slices_x(local_x: int) -> Array:
	var sz: int = SIZE_Y * SIZE_Z
	var out_b := PackedByteArray()
	out_b.resize(sz)
	var out_m := PackedByteArray()
	out_m.resize(sz)
	var src_b := blocks
	var src_m := block_meta
	for y in range(SIZE_Y):
		var base: int = y * SIZE_X * SIZE_Z + local_x
		for z in range(SIZE_Z):
			var src_idx: int = base + z * SIZE_X
			var dst_idx: int = y * SIZE_Z + z
			out_b[dst_idx] = src_b[src_idx]
			out_m[dst_idx] = src_m[src_idx]
	return [out_b, out_m]


func _edge_slices_z(local_z: int) -> Array:
	var sz: int = SIZE_Y * SIZE_X
	var out_b := PackedByteArray()
	out_b.resize(sz)
	var out_m := PackedByteArray()
	out_m.resize(sz)
	var src_b := blocks
	var src_m := block_meta
	for y in range(SIZE_Y):
		var base: int = y * SIZE_X * SIZE_Z + local_z * SIZE_X
		for x in range(SIZE_X):
			var src_idx: int = base + x
			var dst_idx: int = y * SIZE_X + x
			out_b[dst_idx] = src_b[src_idx]
			out_m[dst_idx] = src_m[src_idx]
	return [out_b, out_m]


func east_edge_slices() -> Array:
	return _edge_slices_x(SIZE_X - 1)


func west_edge_slices() -> Array:
	return _edge_slices_x(0)


func south_edge_slices() -> Array:
	return _edge_slices_z(SIZE_Z - 1)


func north_edge_slices() -> Array:
	return _edge_slices_z(0)


# Y-major indexing for cache-friendly vertical scans during meshing/lighting.
static func index(x: int, y: int, z: int) -> int:
	return y * SIZE_X * SIZE_Z + z * SIZE_X + x


# gdlint: disable=max-returns
func get_block(x: int, y: int, z: int) -> int:
	if y < 0 or y >= SIZE_Y:
		return Blocks.AIR
	# In-chunk fast path.
	if x >= 0 and x < SIZE_X and z >= 0 and z < SIZE_Z:
		return blocks[index(x, y, z)]
	# X out-of-bounds: check west / east edge slices. Only one axis can
	# be OOB at a time here (corner reads are never faces the mesher
	# uses for culling — they're only sampled by the corner-height code
	# which is allowed to see AIR for missing neighbors).
	if x == -1 and edge_blocks_west.size() > 0 and z >= 0 and z < SIZE_Z:
		return edge_blocks_west[y * SIZE_Z + z]
	if x == SIZE_X and edge_blocks_east.size() > 0 and z >= 0 and z < SIZE_Z:
		return edge_blocks_east[y * SIZE_Z + z]
	# Z out-of-bounds: north / south.
	if z == -1 and edge_blocks_north.size() > 0 and x >= 0 and x < SIZE_X:
		return edge_blocks_north[y * SIZE_X + x]
	if z == SIZE_Z and edge_blocks_south.size() > 0 and x >= 0 and x < SIZE_X:
		return edge_blocks_south[y * SIZE_X + x]
	return Blocks.AIR


func set_block(x: int, y: int, z: int, id: int) -> void:
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z:
		return
	var idx: int = index(x, y, z)
	blocks[idx] = id
	# Vanilla World.setBlockWithNotify resets metadata on block change —
	# the new block starts in its default state (meta=0). Callers that
	# need a non-default meta use set_block_with_meta.
	block_meta[idx] = 0
	if id != Blocks.AIR and y > max_y:
		max_y = y
	if Blocks.needs_gdscript_mesher(id):
		has_non_cube_blocks = true
	if Blocks.is_water(id):
		has_water_cells = true
	if id == Blocks.CHEST:
		has_chest_blocks = true
	_update_height_map_for_set(x, y, z, id)
	dirty = true


# Write block id + metadata together — vanilla's
# World.setBlockAndMetadataWithNotify. Used by the fluid-flow algorithm
# to place flowing water at level 1..7 without a second write.
func set_block_with_meta(x: int, y: int, z: int, id: int, meta: int) -> void:
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z:
		return
	var idx: int = index(x, y, z)
	blocks[idx] = id
	block_meta[idx] = meta & 0xF
	if id != Blocks.AIR and y > max_y:
		max_y = y
	if Blocks.needs_gdscript_mesher(id):
		has_non_cube_blocks = true
	if Blocks.is_water(id):
		has_water_cells = true
	if id == Blocks.CHEST:
		has_chest_blocks = true
	_update_height_map_for_set(x, y, z, id)
	dirty = true


# Trusted-coord variants for worldgen / mesher inner loops. Callers guarantee
# 0 <= x,z < SIZE_X/Z and 0 <= y < SIZE_Y. Skips ~6 bounds conditionals per
# call, which is meaningful in the ~18k calls/chunk surface pass.
func get_block_unchecked(x: int, y: int, z: int) -> int:
	return blocks[index(x, y, z)]


func set_block_unchecked(x: int, y: int, z: int, id: int) -> void:
	var idx: int = index(x, y, z)
	blocks[idx] = id
	# Reset meta to 0 on block change (vanilla parity — see set_block).
	block_meta[idx] = 0
	if id != Blocks.AIR and y > max_y:
		max_y = y
	if Blocks.needs_gdscript_mesher(id):
		has_non_cube_blocks = true
	if Blocks.is_water(id):
		has_water_cells = true
	if id == Blocks.CHEST:
		has_chest_blocks = true
	_update_height_map_for_set(x, y, z, id)
	dirty = true


# Sky-light access. OOB cells return 15 — matches vanilla's "treat
# unloaded chunks as fully sky-lit" rule (EnumSkyBlock.SKY default value).
# Without this, edge cells would read as 0 from a missing chunk and the
# mesher's per-face sample at (x+1, y, z) for a +X face on a chunk-border
# block would erroneously darken the face once lighting consumes the data.
func get_sky_light(x: int, y: int, z: int) -> int:
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z:
		return 15
	return sky_light[index(x, y, z)]


func set_sky_light(x: int, y: int, z: int, value: int) -> void:
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z:
		return
	sky_light[index(x, y, z)] = clampi(value, 0, 15)


# Block-light access. OOB returns 0 (no emitters — matches vanilla
# EnumSkyBlock.BLOCK default).
func get_block_light(x: int, y: int, z: int) -> int:
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z:
		return 0
	return block_light[index(x, y, z)]


func set_block_light(x: int, y: int, z: int, value: int) -> void:
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z:
		return
	block_light[index(x, y, z)] = clampi(value, 0, 15)


# Block metadata accessors. Value range 0..15 — clamped on write. OOB
# reads return 0 (vanilla's default when querying across a chunk boundary
# into an unloaded chunk). Used by Flow #3 (BlockFluids level), plus the
# handful of other stateful blocks (furnace, sapling type, etc.).
# gdlint: disable=max-returns
func get_block_meta(x: int, y: int, z: int) -> int:
	if y < 0 or y >= SIZE_Y:
		return 0
	if x >= 0 and x < SIZE_X and z >= 0 and z < SIZE_Z:
		return block_meta[index(x, y, z)]
	# Edge slice reads — same pattern as get_block. Empty slice → 0.
	if x == -1 and edge_meta_west.size() > 0 and z >= 0 and z < SIZE_Z:
		return edge_meta_west[y * SIZE_Z + z]
	if x == SIZE_X and edge_meta_east.size() > 0 and z >= 0 and z < SIZE_Z:
		return edge_meta_east[y * SIZE_Z + z]
	if z == -1 and edge_meta_north.size() > 0 and x >= 0 and x < SIZE_X:
		return edge_meta_north[y * SIZE_X + x]
	if z == SIZE_Z and edge_meta_south.size() > 0 and x >= 0 and x < SIZE_X:
		return edge_meta_south[y * SIZE_X + x]
	return 0


func set_block_meta(x: int, y: int, z: int, value: int) -> void:
	if x < 0 or x >= SIZE_X or y < 0 or y >= SIZE_Y or z < 0 or z >= SIZE_Z:
		return
	block_meta[index(x, y, z)] = clampi(value, 0, 15)


# Trusted-coord variants — worldgen / flow algorithm inner loops promise
# 0 <= x,z < SIZE_X/Z, 0 <= y < SIZE_Y. Skips the 6 bounds checks above.
func get_block_meta_unchecked(x: int, y: int, z: int) -> int:
	return block_meta[index(x, y, z)]


func set_block_meta_unchecked(x: int, y: int, z: int, value: int) -> void:
	block_meta[index(x, y, z)] = value & 0xF


# True if (x, y, z) can see the sky — i.e. no cell at or above it in this
# column has light_opacity > 0. Mirrors vanilla canSeeSkyAt(x, y, z) (Alpha
# 1.2.6 ha.java heightmap query). O(1) once `height_map` is up to date;
# O(SIZE_Y * SIZE_X * SIZE_Z) on the first call after creation / restore
# while `_height_map_dirty` triggers a one-time rebuild from blocks.
func is_sky_exposed(x: int, y: int, z: int) -> bool:
	if x < 0 or x >= SIZE_X or z < 0 or z >= SIZE_Z:
		return true  # OOB columns read as fully sky-exposed (no opacity to block)
	if y < 0 or y >= SIZE_Y:
		return y >= SIZE_Y  # above the world is always sky-exposed
	if _height_map_dirty:
		_rebuild_height_map()
	return y >= int(height_map[z * SIZE_X + x])


# Incremental heightmap update on a single-cell write. Two cases:
#   1. Placing/keeping a block with opacity > 0 at y >= current height:
#      the topmost-opaque is now this cell → height = y + 1.
#   2. Replacing the topmost opaque cell with something transparent
#      (opacity 0): the previous top is gone, so we must scan down to
#      find the new highest opaque cell. Bounded by SIZE_Y in the worst
#      case (cleared entire column), but most edits are within a few
#      blocks of the surface so cost stays small.
# Cells deeper than the current heightmap top are never the topmost, so
# replacing them with anything is a no-op for the heightmap.
func _update_height_map_for_set(x: int, y: int, z: int, id: int) -> void:
	if _height_map_dirty:
		# Don't bother maintaining incrementally until first rebuild; the
		# next is_sky_exposed call will rebuild from raw blocks.
		return
	var idx: int = z * SIZE_X + x
	var current_top: int = int(height_map[idx])  # topmost-opaque-y + 1
	var op: int = Blocks.light_opacity(id)
	if op > 0:
		# New opaque (or partially opaque) cell.
		if y + 1 > current_top:
			height_map[idx] = y + 1
		# Else: still under the existing top — no change.
		return
	# Transparent cell. If this WAS the topmost opaque (y + 1 == current_top),
	# scan down to find the new top. Otherwise no-op.
	if y + 1 != current_top:
		return
	var new_top: int = 0
	for cy in range(y - 1, -1, -1):
		if Blocks.light_opacity(blocks[index(x, cy, z)]) > 0:
			new_top = cy + 1
			break
	height_map[idx] = new_top


# Full rebuild — walks each column top-down to find the first cell with
# opacity > 0. Called lazily from is_sky_exposed when _height_map_dirty
# is set (chunk_init / restored-from-save). O(N) where N = TOTAL_BLOCKS;
# each chunk pays this once until the next restore.
func _rebuild_height_map() -> void:
	for z in range(SIZE_Z):
		for x in range(SIZE_X):
			var top: int = 0
			for y in range(SIZE_Y - 1, -1, -1):
				if Blocks.light_opacity(blocks[index(x, y, z)]) > 0:
					top = y + 1
					break
			height_map[z * SIZE_X + x] = top
	_height_map_dirty = false


# Combined effective light for shading. Vanilla's renderer computes
# `max(sky_light * sky_factor, block_light)` per vertex where sky_factor
# scales 0..1 with the sun's position (1.0 high noon, ~0.05 midnight floor
# so caves stay slightly visible without torches). `sky_factor` is supplied
# by the caller — slice 2 (day/night cycle) will route WorldTime's value
# in; until then callers pass 1.0 for "full daylight" which preserves the
# pre-lighting visuals.
func effective_light(x: int, y: int, z: int, sky_factor: float) -> int:
	var sky: int = int(round(float(get_sky_light(x, y, z)) * sky_factor))
	var block: int = get_block_light(x, y, z)
	return maxi(sky, block)
