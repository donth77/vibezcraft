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


# Move a mob with AABB collision against the voxel grid. Returns the
# new world position. Mutates `velocity_inout`: sets Y to 0 on floor
# contact, sets X/Z to 0 on wall contact (vanilla behaviour).
#
#   chunk_manager — needed for get_world_block
#   pos_in        — current world-space center of the mob's CAPSULE
#                   (matches CharacterBody3D's global_position convention)
#   half_extents  — mob's AABB half-size (e.g. zombie = (0.3, 0.95, 0.3))
#   velocity_inout — m/s, X/Y/Z. Y/X/Z clamped on impact.
#   delta         — frame time
#
# Returns: out dict { pos: Vector3, on_floor: bool }
static func move(
	chunk_manager: Node,
	pos_in: Vector3,
	half_extents: Vector3,
	velocity_inout: Vector3,
	delta: float
) -> Dictionary:
	if chunk_manager == null:
		return {"pos": pos_in + velocity_inout * delta, "on_floor": false}
	var step: Vector3 = velocity_inout * delta
	var pos: Vector3 = pos_in
	var on_floor: bool = false
	# X step
	if absf(step.x) > 0.0001:
		var clipped: float = _clip_x(chunk_manager, pos, half_extents, step.x)
		pos.x += clipped
		if absf(clipped - step.x) > 0.0001:
			velocity_inout.x = 0.0
	# Y step
	if absf(step.y) > 0.0001:
		var clipped_y: float = _clip_y(chunk_manager, pos, half_extents, step.y)
		pos.y += clipped_y
		if absf(clipped_y - step.y) > 0.0001:
			if step.y < 0.0:
				on_floor = true
			velocity_inout.y = 0.0
	else:
		# Even with no Y motion, check if the cell just below is solid
		# so AI can detect "grounded" state.
		on_floor = _is_on_floor(chunk_manager, pos, half_extents)
	# Z step
	if absf(step.z) > 0.0001:
		var clipped_z: float = _clip_z(chunk_manager, pos, half_extents, step.z)
		pos.z += clipped_z
		if absf(clipped_z - step.z) > 0.0001:
			velocity_inout.z = 0.0
	return {"pos": pos, "on_floor": on_floor}


# Walks integer cells the AABB overlaps in the X direction and finds
# the nearest solid block face along the motion. Returns the clipped
# distance (≤ |motion|, same sign).
static func _clip_x(cm: Node, pos: Vector3, half: Vector3, motion: float) -> float:
	var sign_motion: float = signf(motion)
	var lo_y: int = int(floor(pos.y - half.y))
	var hi_y: int = int(floor(pos.y + half.y))
	var lo_z: int = int(floor(pos.z - half.z))
	var hi_z: int = int(floor(pos.z + half.z))
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
	var lo_x: int = int(floor(pos.x - half.x))
	var hi_x: int = int(floor(pos.x + half.x))
	var lo_z: int = int(floor(pos.z - half.z))
	var hi_z: int = int(floor(pos.z + half.z))
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
	var lo_x: int = int(floor(pos.x - half.x))
	var hi_x: int = int(floor(pos.x + half.x))
	var lo_y: int = int(floor(pos.y - half.y))
	var hi_y: int = int(floor(pos.y + half.y))
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
