class_name VoxelCollider
extends RefCounted

# Custom AABB-vs-voxel-grid collision for mobs. Bypasses Godot's
# PhysicsServer3D entirely — vanilla MC does the same and it's the
# only way to scale to 70+ active mobs without frame-budget collapse.
#
# Vanilla reference: net.minecraft.world.World.getCollidingBoundingBoxes
# + net.minecraft.entity.Entity.moveEntity (Beta 1.7.3 sources).
#
# Algorithm (vanilla port):
#   1. For each axis (X, then Y, then Z), gather all solid block AABBs
#      that the entity's swept AABB overlaps in that axis's direction.
#   2. Clip the entity's motion on that axis to the closest blocker.
#   3. Translate, then repeat for next axis.
#   X-first / Y-second / Z-third ordering matches vanilla so step-up
#   and corner clipping match.

const _SOLID_LAYER: int = 0b01  # informational only; we ignore Godot layers

# Skin inset for the PERPENDICULAR axes when sweeping one axis. A block face
# that sits flush with the AABB's perpendicular face (e.g. the floor the mob
# stands on, whose top is at the mob's exact feet Y) must NOT count as an
# overlapping cell for that sweep — otherwise the cell the mob already rests
# in clips its motion to zero. This was the root cause of the "stuck chickens
# on flat ground" bug: a mob whose feet round-tripped to a hair below an
# integer Y (float32 (feet + half.y) - half.y drift, ≈1e-5 at world heights)
# made `floor(feet)` drop to the floor row, pulling the solid floor cell into
# the horizontal sweep and freezing all XZ motion. The inset (0.001 ≫ that
# drift, ≪ any real overlap) excludes flush-contact cells so only genuinely
# overlapping cells block. Must stay identical in voxel_collider_native.cpp.
const _SKIN: float = 0.001

# Set by Game._ready() after the GDExtension loads. When non-null, move()
# dispatches to the C++ VoxelColliderNative.move() — ~10× faster than the
# GDScript reference. Same lazy-instantiation pattern as Lighting.
static var _native_collider: RefCounted
# 256-entry solid-collision LUT handed to VoxelColliderNative.move on every
# call. solid_lut[id] != 0 iff Blocks.is_solid_collision(id). Built lazily
# so it stays in sync with any new block IDs.
static var _native_solid_lut: PackedByteArray


static func enable_native() -> bool:
	if _native_collider != null:
		return true
	if not ClassDB.class_exists("VoxelColliderNative"):
		push_warning("VoxelCollider.enable_native: VoxelColliderNative class not in ClassDB")
		return false
	_native_collider = ClassDB.instantiate("VoxelColliderNative")
	return _native_collider != null


static func _solid_lut_for_native() -> PackedByteArray:
	if _native_solid_lut.is_empty():
		_native_solid_lut = PackedByteArray()
		_native_solid_lut.resize(256)
		for i in range(256):
			_native_solid_lut[i] = 1 if Blocks.is_solid_collision(i) else 0
	return _native_solid_lut


# Gather chunk-blocks tuples covering the swept AABB the entity might touch
# this frame. Native move() iterates these instead of calling back into
# GDScript for each cell — that round-trip cost is the whole reason we ported.
static func _gather_chunks_for_native(
	cm: Node, pos_in: Vector3, half_extents: Vector3, velocity: Vector3, delta: float
) -> Array:
	var step: Vector3 = velocity * delta
	var min_world_x: float = pos_in.x - half_extents.x + minf(step.x, 0.0)
	var max_world_x: float = pos_in.x + half_extents.x + maxf(step.x, 0.0)
	var min_world_z: float = pos_in.z - half_extents.z + minf(step.z, 0.0)
	var max_world_z: float = pos_in.z + half_extents.z + maxf(step.z, 0.0)
	var min_cx: int = int(floor(min_world_x / float(Chunk.SIZE_X)))
	var max_cx: int = int(floor(max_world_x / float(Chunk.SIZE_X)))
	var min_cz: int = int(floor(min_world_z / float(Chunk.SIZE_Z)))
	var max_cz: int = int(floor(max_world_z / float(Chunk.SIZE_Z)))
	var out: Array = []
	for cx in range(min_cx, max_cx + 1):
		for cz in range(min_cz, max_cz + 1):
			# Untyped so test stubs (FakeChunk) don't trip Chunk-type
			# coercion. Production callers always hand back real Chunks.
			var chunk = cm.get_chunk_at_coord(Vector2i(cx, cz))
			if chunk == null:
				continue
			out.append([cx, cz, chunk.blocks])
	return out


# Move a mob with AABB collision against the voxel grid.
#
#   chunk_manager — needed for get_world_block
#   pos_in        — current world-space AABB center
#   half_extents  — mob's AABB half-size (e.g. zombie = (0.3, 0.95, 0.3))
#   velocity      — m/s
#   delta         — frame time
#
# Returns: { pos: Vector3, vel: Vector3, on_floor: bool }
# CALLER MUST write `vel` back to its mob's velocity — GDScript passes
# Vector3 by VALUE, so in-out parameter mutation doesn't propagate.
# Bug that caused the "stuck chickens" regression in the first attempt.
static func move(
	chunk_manager: Node, pos_in: Vector3, half_extents: Vector3, velocity: Vector3, delta: float
) -> Dictionary:
	if chunk_manager == null:
		return {"pos": pos_in + velocity * delta, "vel": velocity, "on_floor": false}
	if _native_collider != null:
		# Fast path: marshal swept-AABB chunks once, hand to C++.
		var chunk_data: Array = _gather_chunks_for_native(
			chunk_manager, pos_in, half_extents, velocity, delta
		)
		return _native_collider.move(
			pos_in, half_extents, velocity, delta, chunk_data, _solid_lut_for_native()
		)
	var step: Vector3 = velocity * delta
	var pos: Vector3 = pos_in
	var vel: Vector3 = velocity
	var on_floor: bool = false
	# X step
	if absf(step.x) > 0.0001:
		var clipped: float = _clip_x(chunk_manager, pos, half_extents, step.x)
		pos.x += clipped
		if absf(clipped - step.x) > 0.0001:
			vel.x = 0.0
	# Y step
	if absf(step.y) > 0.0001:
		var clipped_y: float = _clip_y(chunk_manager, pos, half_extents, step.y)
		pos.y += clipped_y
		if absf(clipped_y - step.y) > 0.0001:
			if step.y < 0.0:
				on_floor = true
			vel.y = 0.0
	else:
		# Even with no Y motion, check if the cell just below is solid
		# so AI can detect "grounded" state.
		on_floor = _is_on_floor(chunk_manager, pos, half_extents)
	# Z step
	if absf(step.z) > 0.0001:
		var clipped_z: float = _clip_z(chunk_manager, pos, half_extents, step.z)
		pos.z += clipped_z
		if absf(clipped_z - step.z) > 0.0001:
			vel.z = 0.0
	return {"pos": pos, "vel": vel, "on_floor": on_floor}


# Walks integer cells the AABB overlaps in the X direction and finds
# the nearest solid block face along the motion. Returns the clipped
# distance (≤ |motion|, same sign).
static func _clip_x(cm: Node, pos: Vector3, half: Vector3, motion: float) -> float:
	var sign_motion: float = signf(motion)
	var lo_y: int = int(floor(pos.y - half.y + _SKIN))
	var hi_y: int = int(floor(pos.y + half.y - _SKIN))
	var lo_z: int = int(floor(pos.z - half.z + _SKIN))
	var hi_z: int = int(floor(pos.z + half.z - _SKIN))
	var clipped: float = motion
	# Leading edge of the AABB AFTER motion (where we'd land).
	var lead_x: float = pos.x + half.x * sign_motion + motion
	var trail_x: float = pos.x + half.x * sign_motion
	var lo_x: int = int(floor(minf(trail_x, lead_x)))
	var hi_x: int = int(floor(maxf(trail_x, lead_x)))
	for cx in range(lo_x, hi_x + 1):
		for cy in range(lo_y, hi_y + 1):
			for cz in range(lo_z, hi_z + 1):
				if not _cell_solid(cm, cx, cy, cz):
					continue
				# Block face that blocks our motion:
				# moving +X: face is at cx (block's -X face)
				# moving -X: face is at cx + 1 (block's +X face)
				var face: float = float(cx) if sign_motion > 0.0 else float(cx + 1)
				var allowed: float = (face - (pos.x + half.x * sign_motion)) * sign_motion
				# Clamp to small positive epsilon so we never push past the face.
				allowed = maxf(0.0, allowed - 0.0001)
				if allowed * sign_motion < clipped * sign_motion:
					clipped = allowed * sign_motion
	return clipped


static func _clip_y(cm: Node, pos: Vector3, half: Vector3, motion: float) -> float:
	var sign_motion: float = signf(motion)
	var lo_x: int = int(floor(pos.x - half.x + _SKIN))
	var hi_x: int = int(floor(pos.x + half.x - _SKIN))
	var lo_z: int = int(floor(pos.z - half.z + _SKIN))
	var hi_z: int = int(floor(pos.z + half.z - _SKIN))
	var clipped: float = motion
	var lead_y: float = pos.y + half.y * sign_motion + motion
	var trail_y: float = pos.y + half.y * sign_motion
	var lo_y: int = int(floor(minf(trail_y, lead_y)))
	var hi_y: int = int(floor(maxf(trail_y, lead_y)))
	for cy in range(lo_y, hi_y + 1):
		for cx in range(lo_x, hi_x + 1):
			for cz in range(lo_z, hi_z + 1):
				if not _cell_solid(cm, cx, cy, cz):
					continue
				var face: float = float(cy) if sign_motion > 0.0 else float(cy + 1)
				var allowed: float = (face - (pos.y + half.y * sign_motion)) * sign_motion
				allowed = maxf(0.0, allowed - 0.0001)
				if allowed * sign_motion < clipped * sign_motion:
					clipped = allowed * sign_motion
	return clipped


static func _clip_z(cm: Node, pos: Vector3, half: Vector3, motion: float) -> float:
	var sign_motion: float = signf(motion)
	var lo_x: int = int(floor(pos.x - half.x + _SKIN))
	var hi_x: int = int(floor(pos.x + half.x - _SKIN))
	var lo_y: int = int(floor(pos.y - half.y + _SKIN))
	var hi_y: int = int(floor(pos.y + half.y - _SKIN))
	var clipped: float = motion
	var lead_z: float = pos.z + half.z * sign_motion + motion
	var trail_z: float = pos.z + half.z * sign_motion
	var lo_z: int = int(floor(minf(trail_z, lead_z)))
	var hi_z: int = int(floor(maxf(trail_z, lead_z)))
	for cz in range(lo_z, hi_z + 1):
		for cx in range(lo_x, hi_x + 1):
			for cy in range(lo_y, hi_y + 1):
				if not _cell_solid(cm, cx, cy, cz):
					continue
				var face: float = float(cz) if sign_motion > 0.0 else float(cz + 1)
				var allowed: float = (face - (pos.z + half.z * sign_motion)) * sign_motion
				allowed = maxf(0.0, allowed - 0.0001)
				if allowed * sign_motion < clipped * sign_motion:
					clipped = allowed * sign_motion
	return clipped


# Lightweight floor probe — checks if any solid cell sits directly
# beneath the AABB's bottom face (within 0.02 m tolerance).
static func _is_on_floor(cm: Node, pos: Vector3, half: Vector3) -> bool:
	var lo_x: int = int(floor(pos.x - half.x))
	var hi_x: int = int(floor(pos.x + half.x))
	var lo_z: int = int(floor(pos.z - half.z))
	var hi_z: int = int(floor(pos.z + half.z))
	var foot_y: int = int(floor(pos.y - half.y - 0.02))
	for cx in range(lo_x, hi_x + 1):
		for cz in range(lo_z, hi_z + 1):
			if _cell_solid(cm, cx, foot_y, cz):
				return true
	return false


# Block solid for AABB collision. Mirrors vanilla `Block.canCollide()`:
# air, fluids, plants/saplings/flowers, torches, rails, fire, ladders
# all pass through. Use Blocks.is_solid_collision for the lookup.
static func _cell_solid(cm: Node, x: int, y: int, z: int) -> bool:
	if y < 0 or y >= Chunk.SIZE_Y:
		return false
	var id: int = cm.get_world_block(Vector3i(x, y, z))
	return Blocks.is_solid_collision(id)
