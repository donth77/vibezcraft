class_name EntityBounds
## World-space collision bounds for any entity.
##
## Split out of `chunk_manager.gd` because the thing that goes wrong here
## is a COORDINATE CONVENTION, and a convention can only be checked
## against real nodes. Pressure plates originally asked
## `AABB.has_point(entity.global_position)`; every test passed, because
## the fakes put their sample points inside the box. In the running game
## no plate ever fired — the player's `global_position` is the centre of
## a 1.8 m capsule, about 0.9 m above the feet, and a plate's detection
## box is 0.25 m tall. Nothing in a point-based fake can catch that.
##
## So the derivation lives here, takes real `Node3D`s, and is exercised by
## `tests/test_entity_bounds.gd` with the actual shapes the entities
## build for themselves.

# Half-extents for entities that carry no collider of their own — the two
# `Node3D`-based ones. Vanilla `EntityItem.setSize(0.25, 0.25)` and
# `EntityArrow.setSize(0.5, 0.5)`, both centred on the node origin.
const ITEM_EXTENTS: Vector3 = Vector3(0.125, 0.125, 0.125)
const ARROW_EXTENTS: Vector3 = Vector3(0.25, 0.25, 0.25)


# The bounds the physics engine would use: the entity's own
# `CollisionShape3D` in its real world transform, or the vanilla `setSize`
# footprint when it has none.
static func world_aabb(node: Node3D) -> AABB:
	var shape_node: CollisionShape3D = first_collision_shape(node)
	if shape_node != null:
		var local: AABB = shape_local_aabb(shape_node.shape)
		if local.size != Vector3.ZERO:
			return shape_node.global_transform * local
	var extents: Vector3 = fallback_extents(node)
	return AABB(node.global_position - extents, extents * 2.0)


# Vanilla `Entity.boundingBox.intersectsWith` — the test a pressure plate
# actually runs (ap.java:110), and NOT a point-in-box check.
static func overlaps(box: AABB, node: Node3D) -> bool:
	return box.intersects(world_aabb(node))


static func fallback_extents(node: Node3D) -> Vector3:
	return ARROW_EXTENTS if node is Arrow else ITEM_EXTENTS


static func first_collision_shape(node: Node) -> CollisionShape3D:
	for child: Node in node.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			return child as CollisionShape3D
		var nested: CollisionShape3D = first_collision_shape(child)
		if nested != null:
			return nested
	return null


static func shape_local_aabb(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var size: Vector3 = (shape as BoxShape3D).size
		return AABB(-size * 0.5, size)
	if shape is SphereShape3D:
		var r: float = (shape as SphereShape3D).radius
		return AABB(Vector3(-r, -r, -r), Vector3(r, r, r) * 2.0)
	if shape is CapsuleShape3D:
		var cap := shape as CapsuleShape3D
		return AABB(
			Vector3(-cap.radius, -cap.height * 0.5, -cap.radius),
			Vector3(cap.radius * 2.0, cap.height, cap.radius * 2.0)
		)
	if shape is CylinderShape3D:
		var cyl := shape as CylinderShape3D
		return AABB(
			Vector3(-cyl.radius, -cyl.height * 0.5, -cyl.radius),
			Vector3(cyl.radius * 2.0, cyl.height, cyl.radius * 2.0)
		)
	return AABB()


# Lowest cell the bounds occupy — the key `report_entity_contact` uses to
# fire only on arrival.
static func contact_cell(box: AABB) -> Vector3i:
	return Vector3i(floori(box.position.x), floori(box.position.y), floori(box.position.z))
