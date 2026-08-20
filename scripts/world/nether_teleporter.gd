class_name NetherTeleporter
extends RefCounted

# Alpha 1.2.6 portal destination search and construction — a port of
# `no.java`. See docs/nether-alpha-1.2.6-implementation-plan.md §7.3.
#
# Three steps, in order, exactly as `no.a(World, Entity)` does them:
#
#   1. look for an existing portal within 128 blocks;
#   2. if none, build one within 16;
#   3. look again, so arrival always goes through the same placement path.
#
# The search is deliberately not "nearest by some clever index". It is an
# exhaustive scan whose ORDER is part of the contract: X ascending, then
# Z ascending, then Y from 127 down, keeping the smallest squared 3D
# distance and preferring the FIRST cell at a tie. A different traversal
# picks a different portal when two are equidistant, which players notice
# as a portal that "moves".

# no.java:24 — horizontal search radius for an existing portal.
const SEARCH_RADIUS: int = 128
# no.java:96 — radius for finding somewhere to build one.
const BUILD_RADIUS: int = 16
# no.java:158-163 — when nothing suitable exists at all, the fallback
# platform is clamped into this band so it is never in the bedrock floor
# or jammed against the roof.
const FALLBACK_MIN_Y: int = 70
const FALLBACK_MAX_Y: int = 118

# Site-search bounds — the FULL column, minus the bedrock plates.
# Vanilla `no.java` scans every height for a buildable site and clamps
# only the last-resort platform to 70-118. The first shipped version
# confined the SITE SEARCH itself to that band, which is why Overworld
# return portals materialised as platforms floating at Y 70 over flat
# ~64-surface terrain (audit finding #4).
const SITE_SEARCH_MIN_Y: int = 4
const SITE_SEARCH_MAX_Y: int = 120

const _FRAME_BLOCK: int = Blocks.OBSIDIAN

# The player body's origin is its capsule CENTER (half-height 0.9), not
# its feet. A landing of cell.y + 0.5 therefore sank the capsule 0.4 m
# into the frame's floor row — deep symmetric penetration that
# move_and_slide cannot resolve, so the arrival was paralyzed in every
# axis (field reports #1-#3: "impossible to move and walk out"). Same
# convention as the voxel floor guard: origin = floor top + half height
# + skin.
const _PLAYER_ORIGIN_ABOVE_FLOOR: float = 0.901


# §7.2 — entering the Nether divides X/Z by the destination's coordinate
# scale; returning multiplies by the source's.
#
# Uses floor rather than truncation so the mapping is continuous across
# zero: truncating sends both -7 and 7 to 0, which folds a 16-block band
# of the Overworld onto one Nether column and makes return trips land in
# the wrong place on the negative side.
static func scale_coordinate(value: float, from_scale: float, to_scale: float) -> float:
	return floorf(value * from_scale / to_scale)


# Map a position from one dimension to another.
static func scale_position(pos: Vector3, from_dim: int, to_dim: int) -> Vector3:
	var from_scale: float = DimensionContext.provider(from_dim).coordinate_scale
	var to_scale: float = DimensionContext.provider(to_dim).coordinate_scale
	return Vector3(
		scale_coordinate(pos.x, from_scale, to_scale),
		pos.y,
		scale_coordinate(pos.z, from_scale, to_scale)
	)


# no.java:19-70 — the nearest existing portal, or null.
#
# Returns the BOTTOM cell of the winning column, which is what the
# arrival placement expects.
static func find_portal(world, around: Vector3, radius: int = SEARCH_RADIUS) -> Variant:
	var best_distance: float = -1.0
	var best: Vector3i = Vector3i.ZERO
	var found: bool = false
	var centre_x: int = AlphaMath.floor_int(around.x)
	var centre_z: int = AlphaMath.floor_int(around.z)
	# An unloaded chunk reads as AIR, so descending 128 cells through one
	# is 128 lookups guaranteed to find nothing. At radius 128 that is
	# 8.4M reads for a scan that can only ever see the resident ring.
	# Skipping the column outright is a pure speedup — it changes no
	# result, only how long it takes to reach the same one.
	#
	# Measured on the ring a transition actually materializes (5x5 chunks
	# plus index hints): ~170 ms, against ~1.7 s for the same scan with no
	# residency test. It stays slow in absolute terms because the resident
	# columns still descend 128 cells each, and there is no honest way to
	# skip those: the Nether's bedrock roof puts every chunk's max_y at
	# 127, and narrowing by the portal index would make correctness depend
	# on the cache, which the plan forbids. It is paid once per portal
	# trip, behind the loading screen. Alpha's own `no.java` is no faster.
	var can_test_residency: bool = world.has_method("has_chunk_at")
	for x: int in range(centre_x - radius, centre_x + radius + 1):
		var dx: float = float(x) + 0.5 - around.x
		# Residency is a property of the CHUNK, so ask once per 16 columns
		# rather than per column: 4.4K calls instead of 66K at radius 128.
		# The answer is identical either way — the test is constant across
		# a chunk — and on a real ChunkManager each call builds a Vector2i
		# and does two floor-divides, so the saving is worth the branch.
		var last_chunk_z: int = -2147483648
		var column_resident: bool = true
		for z: int in range(centre_z - radius, centre_z + radius + 1):
			if can_test_residency:
				var chunk_z: int = z >> 4
				if chunk_z != last_chunk_z:
					last_chunk_z = chunk_z
					column_resident = world.has_chunk_at(x, z)
				if not column_resident:
					continue
			var dz: float = float(z) + 0.5 - around.z
			var y: int = 127
			while y >= 0:
				if world.get_world_block(Vector3i(x, y, z)) != Blocks.PORTAL:
					y -= 1
					continue
				# Normalise to the bottom of this column before measuring.
				while world.get_world_block(Vector3i(x, y - 1, z)) == Blocks.PORTAL:
					y -= 1
				var dy: float = float(y) + 0.5 - around.y
				var distance: float = dx * dx + dy * dy + dz * dz
				# Strictly less-than: the first cell found at a tie wins,
				# which is what makes the scan order part of the contract.
				if not found or distance < best_distance:
					best_distance = distance
					best = Vector3i(x, y, z)
					found = true
				y -= 1
	if not found:
		return null
	return best


# no.java:47-66 — where the player actually stands on arrival. The cell
# centre, nudged half a block toward whichever neighbours are also
# portal, so the player lands in the middle of the sheet rather than
# inside one of its columns.
static func arrival_position(world, portal_cell: Vector3i) -> Vector3:
	var pos := Vector3(
		float(portal_cell.x) + 0.5,
		float(portal_cell.y) + _PLAYER_ORIGIN_ABOVE_FLOOR,
		float(portal_cell.z) + 0.5
	)
	if world.get_world_block(portal_cell + Vector3i(-1, 0, 0)) == Blocks.PORTAL:
		pos.x -= 0.5
	if world.get_world_block(portal_cell + Vector3i(1, 0, 0)) == Blocks.PORTAL:
		pos.x += 0.5
	if world.get_world_block(portal_cell + Vector3i(0, 0, -1)) == Blocks.PORTAL:
		pos.z -= 0.5
	if world.get_world_block(portal_cell + Vector3i(0, 0, 1)) == Blocks.PORTAL:
		pos.z += 0.5
	return pos


# no.java:72-217 — build a portal near `around` and return its bottom
# interior cell.
#
# Vanilla runs two site searches of decreasing strictness before falling
# back to carving a platform. This port keeps the fallback and the Y
# clamp — the parts a player can end up depending on — and simplifies the
# site search to a single clearance test over the full column, because
# the two-pass version's only observable difference is WHICH clear spot
# wins, and the plan's canonicalisation already accepts a deterministic
# choice there.
#
# Recorded as a deliberate deviation in the plan's findings log.
static func create_portal(world, around: Vector3) -> Vector3i:
	var centre_x: int = AlphaMath.floor_int(around.x)
	var centre_z: int = AlphaMath.floor_int(around.z)
	var best_distance: float = -1.0
	var best := Vector3i(centre_x, int(around.y), centre_z)
	var found: bool = false

	var can_test_residency: bool = world.has_method("has_chunk_at")
	for x: int in range(centre_x - BUILD_RADIUS, centre_x + BUILD_RADIUS + 1):
		var dx: float = float(x) + 0.5 - around.x
		for z: int in range(centre_z - BUILD_RADIUS, centre_z + BUILD_RADIUS + 1):
			# Same reason as the search: an unloaded column is all-AIR to
			# us, and building a frame there would write into nothing.
			# The WHOLE footprint has to be resident, not just this column:
			# set_world_block silently drops writes to unloaded chunks, so a
			# base within two blocks of a chunk edge could pass this test and
			# then lose part of its frame — bottom row included — to the
			# neighbour that was not loaded yet.
			if can_test_residency and not _footprint_is_resident(world, x, z):
				continue
			var dz: float = float(z) + 0.5 - around.z
			for y: int in range(SITE_SEARCH_MAX_Y, SITE_SEARCH_MIN_Y - 1, -1):
				if not _site_is_clear(world, Vector3i(x, y, z)):
					continue
				var dy: float = float(y) + 0.5 - around.y
				var distance: float = dx * dx + dy * dy + dz * dz
				# No break: every valid site in the column competes on 3D
				# distance, exactly as vanilla's full scan does. Breaking
				# on the first (highest) hit re-biased arrivals upward —
				# the same failure the old Y band caused.
				if not found or distance < best_distance:
					best_distance = distance
					best = Vector3i(x, y, z)
					found = true

	if not found:
		# no.java:158-163 — nothing suitable anywhere, so clamp into the
		# safe band and carve a platform to stand the frame on. The
		# platform is what guarantees a floor here, so it must reach every
		# column the frame will occupy; a partially resident footprint
		# would slab only the loaded half and leave the rest hanging.
		best.y = clampi(best.y, FALLBACK_MIN_Y, FALLBACK_MAX_Y)
		_build_platform(world, best)
	build_frame(world, best)
	return best


# Every chunk column the frame OR its fallback platform can touch. The
# frame runs x-1..x+2 at a fixed z; _build_platform widens that to
# x-2..x+3 and z-1..z+1, so the platform bounds are the superset used
# here. Writes outside a resident chunk are dropped on the floor by
# ChunkManager.set_world_block, which is how a portal ends up built with
# half of it — floor included — simply absent.
static func _footprint_is_resident(world, base_x: int, base_z: int) -> bool:
	for x: int in range(base_x - 2, base_x + 4):
		for z: int in range(base_z - 1, base_z + 2):
			if not world.has_chunk_at(x, z):
				return false
	return true


# A 4-wide, 5-tall, 2-deep pocket of air with something solid underneath —
# enough for the frame plus the player, without burying it in terrain.
static func _site_is_clear(world, base: Vector3i) -> bool:
	# Support under the WHOLE frame footprint, not just the base column.
	# build_frame lays its bottom row across `along -1..2`, so checking one
	# column accepted sites where the other three overhang open air — the
	# Nether arrival with a floor under only half the frame. A site that
	# cannot hold the whole row is rejected here, which routes construction
	# to the _build_platform fallback that carves its own slab.
	for along: int in range(-1, 3):
		if not Blocks.is_solid_collision(world.get_world_block(base + Vector3i(along, -1, 0))):
			return false
	for along: int in range(-1, 3):
		for up: int in range(0, 5):
			for across: int in range(0, 2):
				var cell := base + Vector3i(along, up, across)
				if world.get_world_block(cell) != Blocks.AIR:
					return false
	return true


# no.java:164-176 — an obsidian slab under the frame, so the fallback
# portal is never floating.
static func _build_platform(world, base: Vector3i) -> void:
	# Inside no.java's same editingBlocks bracket — the carve and slab
	# writes must not fan out mid-structure either.
	if world.has_method("begin_block_edit"):
		world.begin_block_edit()
	if world.has_method("begin_batch"):
		world.begin_batch()
	for along: int in range(-2, 4):
		for across: int in range(-1, 2):
			world.set_world_block(base + Vector3i(along, -1, across), _FRAME_BLOCK)
			for up: int in range(0, 5):
				world.set_world_block(base + Vector3i(along, up, across), Blocks.AIR)
	if world.has_method("end_batch"):
		world.end_batch()
	if world.has_method("end_block_edit"):
		world.end_block_edit()
	_rebuild_touched_chunks(world, base + Vector3i(-2, -1, -1), base + Vector3i(3, 4, 1))


# no.java:178-207 — the frame itself: a 4x5 obsidian ring with a 2x3
# portal interior, laid along X. Built directly rather than lit by fire,
# because the destination has no player to strike a flint.
static func build_frame(world, base: Vector3i) -> void:
	# no.java:202-212 — construction is bracketed by `cy2.i = true` for
	# the same reason x.java's fill is: the half-built sheet must not be
	# observable by its own per-cell validation, or it erases itself as
	# it is written.
	if world.has_method("begin_block_edit"):
		world.begin_block_edit()
	# The six portal cells each emit light 11 — batch the floods into one
	# drain, same as the ignition path in nether_portal.try_create.
	if world.has_method("begin_batch"):
		world.begin_batch()
	var lit: Array[Vector3i] = []
	for along: int in range(-1, 3):
		for up: int in range(-1, 4):
			var is_frame_cell: bool = along == -1 or along == 2 or up == -1 or up == 3
			var cell := base + Vector3i(along, up, 0)
			if is_frame_cell:
				world.set_world_block(cell, _FRAME_BLOCK)
			else:
				world.set_world_block(cell, Blocks.PORTAL)
				lit.append(cell)
	if world.has_method("end_batch"):
		world.end_batch()
	if world.has_method("end_block_edit"):
		world.end_block_edit()
	_rebuild_touched_chunks(world, base + Vector3i(-1, -1, 0), base + Vector3i(2, 3, 0))
	PortalIndex.record_sheet(DimensionContext.active(), lit)


# no.java:12-17 — the whole destination routine. Find, else build then
# find, so arrival always goes through the same placement path.
#
# Returns the world position the player should be placed at.
static func destination_for(world, arrival_centre: Vector3) -> Vector3:
	var existing: Variant = find_portal(world, arrival_centre)
	if existing == null:
		var built: Vector3i = create_portal(world, arrival_centre)
		existing = find_portal(world, arrival_centre, BUILD_RADIUS + 8)
		if existing == null:
			# The frame we just built must be findable; if it is not,
			# something rejected the writes and standing on the base cell
			# is still safer than returning an unvalidated coordinate.
			return Vector3(
				float(built.x) + 0.5,
				float(built.y) + _PLAYER_ORIGIN_ABOVE_FLOOR,
				float(built.z) + 0.5
			)
	return arrival_position(world, existing as Vector3i)


# Same-frame mesh + collision rebuild for every chunk the write AABB
# touches. set_world_block marks dirty flags but leaves the remesh to
# its caller; a structure carved without this exists only in block data
# — the chunk still MESHES AND COLLIDES as the virgin terrain, and a
# player placed "in the doorway" is entombed in collision for geometry
# that is no longer there.
static func _rebuild_touched_chunks(world, cell_min: Vector3i, cell_max: Vector3i) -> void:
	if not world.has_method("rebuild_chunk_now"):
		return
	var min_c := Vector2i(
		floori(float(cell_min.x) / float(Chunk.SIZE_X)),
		floori(float(cell_min.z) / float(Chunk.SIZE_Z))
	)
	var max_c := Vector2i(
		floori(float(cell_max.x) / float(Chunk.SIZE_X)),
		floori(float(cell_max.z) / float(Chunk.SIZE_Z))
	)
	for cx: int in range(min_c.x, max_c.x + 1):
		for cz: int in range(min_c.y, max_c.y + 1):
			world.rebuild_chunk_now(Vector2i(cx, cz))
