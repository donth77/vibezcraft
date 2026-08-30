class_name PortalIndex
extends RefCounted

# Where the portals are, per dimension. Rebuildable cache data — see
# docs/nether-alpha-1.2.6-implementation-plan.md §7.3.
#
# The plan permits this and is precise about what it may and may not do:
#
#     "A portal index may avoid loading every chunk in the radius, but it
#      is rebuildable cache data, must validate indexed portals before
#      use, must remove stale entries, and must fall back to bounded raw
#      chunk search. Never make correctness depend on the cache."
#
# So the index answers exactly one question — WHICH CHUNKS ARE WORTH
# LOADING — and never decides where a player lands. `NetherTeleporter`
# still runs the raw `no.java` scan over what is loaded, and its answer
# wins even when it disagrees with the index.
#
# The reason a hint is needed at all is that `ChunkManager.get_world_block`
# returns AIR for an unloaded chunk. A literal 128-radius scan is 257×257
# columns spanning 289 chunks; loading all of them to look for a 2×3 sheet
# is not affordable, and NOT loading them makes the scan silently blind.
# Recording portals as they are built sidesteps both.
#
# Entries are BOTTOM cells of portal columns, which is the same
# normalisation the search uses, so a hint and a scan result compare
# directly.

const _FORMAT_VERSION: int = 1
const _FILE_NAME: String = "portals.bin"

# A stale entry can sit at most this far from the real bottom cell before
# it stops describing the same portal. Three is the interior height, so a
# column that lost its floor still resolves to itself.
const _COLUMN_SLACK: int = 3

# Magic 'MCPX', matching SaveLoad's header convention. A `static var`
# rather than a const because PackedByteArray literals are not constant
# expressions in GDScript — SaveLoad._magic does the same.
static var _magic: PackedByteArray = PackedByteArray([0x4D, 0x43, 0x50, 0x58])
# dimension:int → { Vector3i bottom_cell: true }
static var _entries: Dictionary = {}
# Dimensions whose on-disk copy no longer matches memory.
static var _dirty: Dictionary = {}


static func reset() -> void:
	_entries.clear()
	_dirty.clear()


static func _bucket(dimension: int) -> Dictionary:
	if not _entries.has(dimension):
		_entries[dimension] = {}
	return _entries[dimension]


# --- Mutation ---


# Record one portal column by its bottom cell.
static func record(dimension: int, bottom_cell: Vector3i) -> void:
	var bucket: Dictionary = _bucket(dimension)
	if bucket.has(bottom_cell):
		return
	bucket[bottom_cell] = true
	_dirty[dimension] = true


# Record a whole freshly-lit sheet. Takes the cells rather than a frame
# description so both callers — fire activation and teleporter
# construction — can hand over exactly what they wrote.
static func record_sheet(dimension: int, cells: Array) -> void:
	var bottoms: Dictionary = {}
	for cell: Vector3i in cells:
		var column := Vector2i(cell.x, cell.z)
		if not bottoms.has(column) or cell.y < (bottoms[column] as Vector3i).y:
			bottoms[column] = cell
	for column: Vector2i in bottoms:
		record(dimension, bottoms[column])


# Drop every entry that could describe the column containing `cell`.
# Called when a portal cell is cleared; the entry may name a different Y
# than the cell being removed, so the whole column band goes.
static func forget_at(dimension: int, cell: Vector3i) -> void:
	if not _entries.has(dimension):
		return
	var bucket: Dictionary = _entries[dimension]
	var doomed: Array[Vector3i] = []
	for entry: Vector3i in bucket:
		if entry.x != cell.x or entry.z != cell.z:
			continue
		if absi(entry.y - cell.y) <= _COLUMN_SLACK:
			doomed.append(entry)
	for entry: Vector3i in doomed:
		bucket.erase(entry)
		_dirty[dimension] = true


static func count(dimension: int) -> int:
	if not _entries.has(dimension):
		return 0
	return (_entries[dimension] as Dictionary).size()


static func entries(dimension: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if not _entries.has(dimension):
		return out
	for entry: Vector3i in _entries[dimension]:
		out.append(entry)
	return out


# --- Query ---


# Indexed portals within `radius`, nearest first, using the same squared
# 3D distance as the raw search so the two agree about which is closest.
#
# Ties break on the raw scan's own order — X ascending, then Z ascending,
# then Y DESCENDING — so a hint list and a scan result pick the same
# portal when two are equidistant.
static func candidates(dimension: int, around: Vector3, radius: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if not _entries.has(dimension):
		return out
	for entry: Vector3i in _entries[dimension]:
		if absi(entry.x - AlphaMath.floor_int(around.x)) > radius:
			continue
		if absi(entry.z - AlphaMath.floor_int(around.z)) > radius:
			continue
		out.append(entry)
	var sorter := func(a: Vector3i, b: Vector3i) -> bool:
		var da: float = _squared_distance(a, around)
		var db: float = _squared_distance(b, around)
		if da != db:
			return da < db
		if a.x != b.x:
			return a.x < b.x
		if a.z != b.z:
			return a.z < b.z
		return a.y > b.y
	out.sort_custom(sorter)
	return out


static func _squared_distance(cell: Vector3i, around: Vector3) -> float:
	var dx: float = float(cell.x) + 0.5 - around.x
	var dy: float = float(cell.y) + 0.5 - around.y
	var dz: float = float(cell.z) + 0.5 - around.z
	return dx * dx + dy * dy + dz * dz


# Chunk coords worth loading before running the raw search. This is the
# whole point of the index: a bounded list instead of 289 chunks.
static func chunk_hints(dimension: int, around: Vector3, radius: int) -> Array[Vector2i]:
	var seen: Dictionary = {}
	var out: Array[Vector2i] = []
	for entry: Vector3i in candidates(dimension, around, radius):
		var coord := Vector2i(
			int(floor(float(entry.x) / float(Chunk.SIZE_X))),
			int(floor(float(entry.z) / float(Chunk.SIZE_Z)))
		)
		if seen.has(coord):
			continue
		seen[coord] = true
		out.append(coord)
	return out


# Confirm an indexed cell against the live world, dropping it if it lies.
# The plan requires validation before use and removal of stale entries;
# both happen here, so no caller can accidentally skip either.
#
# Returns false when the chunk is not loaded too — an unverifiable hint is
# not a usable one, and the entry survives for a later attempt.
static func validate(dimension: int, world, cell: Vector3i) -> bool:
	if world == null:
		return false
	if world.get_world_block(cell) != Blocks.PORTAL:
		# Only forget when we could actually see the cell. An unloaded
		# chunk also reads as AIR, and forgetting on that would erase the
		# index every time the player walks away from a portal.
		if _chunk_is_loaded(world, cell):
			forget_at(dimension, cell)
		return false
	return true


static func _chunk_is_loaded(world, cell: Vector3i) -> bool:
	if not world.has_method("has_chunk_at"):
		# A world that cannot answer is treated as fully resident, which
		# is what the test doubles want and what a single-chunk fixture is.
		return true
	return world.has_chunk_at(cell.x, cell.z)


# --- Rebuild ---


# Re-derive the index for one dimension from whatever chunks are resident.
# This is the "rebuildable" half of the contract: an index file that is
# lost, corrupt or predates a portal still converges once the player
# stands near one.
#
# Deliberately NOT called per frame — chunk scanning is 32K reads apiece.
# It runs on explicit recovery and from tests.
static func rebuild_from_loaded(world, dimension: int) -> int:
	if world == null or not world.has_method("loaded_chunk_coords"):
		return 0
	var bucket: Dictionary = _bucket(dimension)
	var found: int = 0
	for coord: Vector2i in world.loaded_chunk_coords():
		for local_x: int in range(Chunk.SIZE_X):
			for local_z: int in range(Chunk.SIZE_Z):
				var world_x: int = coord.x * Chunk.SIZE_X + local_x
				var world_z: int = coord.y * Chunk.SIZE_Z + local_z
				var y: int = 0
				while y < Chunk.SIZE_Y:
					if world.get_world_block(Vector3i(world_x, y, world_z)) != Blocks.PORTAL:
						y += 1
						continue
					var bottom := Vector3i(world_x, y, world_z)
					if not bucket.has(bottom):
						bucket[bottom] = true
						_dirty[dimension] = true
					found += 1
					# Skip the rest of this column; only its floor is an
					# entry.
					while (
						y < Chunk.SIZE_Y
						and world.get_world_block(Vector3i(world_x, y, world_z)) == Blocks.PORTAL
					):
						y += 1
	return found


# --- Persistence ---


static func path(world_name: String = "", dimension: int = SaveLoad.DIM_ACTIVE) -> String:
	return "%s/%s" % [SaveLoad.dimension_dir(world_name, dimension), _FILE_NAME]


static func is_dirty(dimension: int) -> bool:
	return _dirty.get(dimension, false)


# Write one dimension's index. Goes through SaveLoad.atomic_write so a
# crash mid-write cannot leave an unreadable file — the index is only a
# cache, but a truncated one would still spam errors on every load.
static func save(world_name: String = "", dimension: int = SaveLoad.DIM_ACTIVE) -> bool:
	var resolved: int = SaveLoad.resolve_dimension(dimension)
	var bucket: Dictionary = _entries.get(resolved, {})
	var bytes := PackedByteArray()
	bytes.append_array(_magic)
	var header := StreamPeerBuffer.new()
	header.big_endian = false
	header.put_32(_FORMAT_VERSION)
	header.put_32(bucket.size())
	for entry: Vector3i in bucket:
		header.put_32(entry.x)
		header.put_32(entry.y)
		header.put_32(entry.z)
	bytes.append_array(header.data_array)
	DirAccess.make_dir_recursive_absolute(SaveLoad.dimension_dir(world_name, resolved))
	var ok: bool = SaveLoad.atomic_write(path(world_name, resolved), bytes)
	if ok:
		_dirty[resolved] = false
	return ok


# Merge one dimension's on-disk index into memory. A missing or
# unreadable file is not an error — it means "no hints on disk", and the
# raw search still works.
#
# MERGE, not replace. Loading is not the same as forgetting: a dimension
# switch reloads the destination's index, and if that clobbered the
# bucket then anything learned this session but not yet flushed — a portal
# lit since the last save, or any hint at all in a session whose writes
# were skipped — would vanish on the way back. Entries that no longer
# describe a real portal are handled by `validate`, which is the only
# place staleness is supposed to be resolved.
#
# World isolation comes from `reset()` at world entry (ChunkManager
# ._ready), not from clobbering here — those are different questions and
# conflating them is what made this subtle.
static func load_index(world_name: String = "", dimension: int = SaveLoad.DIM_ACTIVE) -> int:
	var resolved: int = SaveLoad.resolve_dimension(dimension)
	var bucket: Dictionary = _bucket(resolved)
	var bytes: PackedByteArray = SaveLoad.read_with_recovery(path(world_name, resolved))
	if bytes.size() < 12:
		return bucket.size()
	for i: int in range(_magic.size()):
		if bytes[i] != _magic[i]:
			push_warning(
				(
					"[PortalIndex] bad magic in %s — keeping in-memory hints"
					% path(world_name, resolved)
				)
			)
			return bucket.size()
	var reader := StreamPeerBuffer.new()
	reader.big_endian = false
	reader.data_array = bytes.slice(_magic.size())
	var version: int = reader.get_32()
	if version != _FORMAT_VERSION:
		push_warning(
			"[PortalIndex] version %d != %d — keeping in-memory hints" % [version, _FORMAT_VERSION]
		)
		return bucket.size()
	var count_in_file: int = reader.get_32()
	# A count that outruns the payload means a truncated file. The index is
	# a cache, so read what is there rather than refusing the world.
	var available: int = int((reader.get_size() - reader.get_position()) / 12)
	for _i: int in range(mini(count_in_file, available)):
		var x: int = reader.get_32()
		var y: int = reader.get_32()
		var z: int = reader.get_32()
		bucket[Vector3i(x, y, z)] = true
	return bucket.size()
