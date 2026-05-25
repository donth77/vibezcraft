class_name Minecart
extends CharacterBody3D

# Vanilla MC Alpha 1.2.6 EntityMinecart (vendor/alpha-1.2.6-src/src/qd.java).
# Rolls on RAIL blocks, follows rail orientation, free-falls otherwise.
# Right-click an empty cart to mount; sneak / right-click to dismount.
#
# Vanilla refs:
#   qd.java         — EntityMinecart per-tick physics + rail lookup table
#   qe.java         — BlockMinecartTrack (the RAIL block)
#   nv.java::ItemMinecart — right-click on rail spawns this entity
#
# Stage 1 scope: placement on rails, mount/dismount, basic gravity +
# bump damp, persistence, item break-drops. Rail-following physics
# (slope acceleration, friction, curves) lands in Stage 2.

# Vanilla qd.java rail-direction lookup table `int[10][2][3] j`. For
# each rail meta 0..9, two endpoint offsets (in cells, relative to the
# rail cell) — the two neighbors the cart can roll toward. Ascending
# variants have a -1 Y on one endpoint (climbing rail drops on that
# side). Curves connect two perpendicular endpoints.
const RAIL_ENDPOINTS: Array = [
	[Vector3(0, 0, -1), Vector3(0, 0, 1)],  # 0: N-S straight
	[Vector3(-1, 0, 0), Vector3(1, 0, 0)],  # 1: E-W straight
	[Vector3(-1, -1, 0), Vector3(1, 0, 0)],  # 2: ascending east  (climb +X)
	[Vector3(-1, 0, 0), Vector3(1, -1, 0)],  # 3: ascending west  (climb -X)
	[Vector3(0, 0, -1), Vector3(0, -1, 1)],  # 4: ascending north (climb -Z)
	[Vector3(0, -1, -1), Vector3(0, 0, 1)],  # 5: ascending south (climb +Z)
	[Vector3(0, 0, 1), Vector3(1, 0, 0)],  # 6: curve N-E (S endpoint + E endpoint)
	[Vector3(0, 0, 1), Vector3(-1, 0, 0)],  # 7: curve S-E (S + W)
	[Vector3(0, 0, -1), Vector3(-1, 0, 0)],  # 8: curve S-W (N + W)
	[Vector3(0, 0, -1), Vector3(1, 0, 0)],  # 9: curve N-W (N + E)
]

# Vanilla AABB — `qd.java::a(0.98f, 0.7f)` sets width=0.98 height=0.7,
# so the collision box is 0.98 × 0.7 × 0.98 m (slightly smaller than
# a full block). Visual hull matches.
const HULL_LENGTH: float = 0.98
const HULL_WIDTH: float = 0.98
const HULL_HEIGHT: float = 0.7
const FLOOR_THICKNESS: float = 0.0625  # 1 vanilla unit, thin metal floor
const WALL_HEIGHT: float = HULL_HEIGHT - FLOOR_THICKNESS
const WALL_THICKNESS: float = 0.0625

# Per-tick → per-second physics constants (×20 TPS scale where applicable).
# Vanilla EntityMinecart uses a softer drag than boats (0.997 vs 0.99) so
# carts coast farther — they're meant to glide on rails.
# On-rail friction is much lower than off-rail (vanilla qd.java uses
# 0.997 per tick when on a rail, 0.95 horizontal off-rail). Empty cart
# on flat rails travels ~10 blocks per kick per minecraft.wiki.
const DRAG_ON_RAIL_PER_TICK: float = 0.997
const DRAG_OFF_RAIL_PER_TICK: float = 0.95
# Legacy aliases — kept so any external readers still resolve.
const DRAG_HORIZ_PER_TICK: float = 0.997
const DRAG_VERT_PER_TICK: float = 0.95
# Vanilla terrain gravity is 0.04 per tick² for entities = 16 m/s².
const GRAVITY: float = 16.0
const BUMP_DAMP: float = 0.5

# Rider thrust — vanilla minecarts get a small forward kick when the
# rider presses forward. Scale tuned similarly to boat: matches a
# walking rider's per-tick velocity × 0.2 then ramped to per-second.
const RIDER_THRUST: float = 4.0
const MAX_HORIZ_PER_AXIS: float = 6.0

# Vanilla minecart health — 6 HP (qd.java sets `this.b` damage threshold
# to 40 with 10×-per-hit multiplier same as the boat).
const MAX_HEALTH: int = 6

# Seat offset (player position relative to cart origin). Same math as
# boat: hip lands on the cart floor interior, capsule center 0.15 m
# above that.
const _SEAT_OFFSET: Vector3 = Vector3(0, FLOOR_THICKNESS + 0.15, 0)

var health: int = MAX_HEALTH
var _owner_player: Node3D = null
var _rider: Node3D = null
var _chunk_manager: Node = null
var _visual_root: Node3D = null
var _damage_rock: float = 0.0
var _damage_time: float = 0.0
var _player_ref: Node3D = null


func setup(spawn_pos: Vector3, yaw: float, owner: Node3D) -> void:
	global_position = spawn_pos
	rotation.y = yaw
	_owner_player = owner


func _ready() -> void:
	# Layer 2 = selection-only (player raycast hits for mount/break;
	# player body walks through). Mask layer 1 = terrain so we don't
	# free-fall through the world.
	collision_layer = 0b10
	collision_mask = 0b01
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	_player_ref = get_tree().get_root().find_child("Player", true, false) as Node3D
	_build_collider()
	_build_visual_mesh()


func _build_collider() -> void:
	# Vanilla `qd.java::a(0.98f, 0.7f)` → 0.98 × 0.7 × 0.98 AABB.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(HULL_LENGTH, HULL_HEIGHT, HULL_WIDTH)
	shape.shape = box
	shape.position = Vector3(0, HULL_HEIGHT * 0.5, 0)
	add_child(shape)


# Build a simple open-top metal hull. Uses planks.png as a placeholder
# texture since we don't have a dedicated minecart skin in the pack.
# A vanilla-faithful skin from vendor/mojang/alpha-1.2.6/item/cart.png
# can be wired through in Stage 2 (same pattern as boat.png).
func _build_visual_mesh() -> void:
	_visual_root = Node3D.new()
	add_child(_visual_root)
	var planks_tex: Texture2D = load(
		"res://assets/textures/blocks/packs/%s/planks.png" % BlockAtlas.active_pack
	)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if planks_tex != null:
		mat.albedo_texture = planks_tex
	else:
		mat.albedo_color = Color(0.45, 0.30, 0.20)
	# Floor slab — full footprint, thin.
	var floor_mi := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(HULL_LENGTH, FLOOR_THICKNESS, HULL_WIDTH)
	floor_mi.mesh = floor_mesh
	floor_mi.position = Vector3(0, FLOOR_THICKNESS * 0.5, 0)
	floor_mi.material_override = mat
	_visual_root.add_child(floor_mi)
	# 4 walls forming an open-top hull.
	var wall_y: float = FLOOR_THICKNESS + WALL_HEIGHT * 0.5
	var inner_len: float = HULL_LENGTH - 2.0 * WALL_THICKNESS
	for sz: float in [
		HULL_WIDTH * 0.5 - WALL_THICKNESS * 0.5, -(HULL_WIDTH * 0.5 - WALL_THICKNESS * 0.5)
	]:
		var wall := MeshInstance3D.new()
		var wall_mesh := BoxMesh.new()
		wall_mesh.size = Vector3(inner_len, WALL_HEIGHT, WALL_THICKNESS)
		wall.mesh = wall_mesh
		wall.position = Vector3(0, wall_y, sz)
		wall.material_override = mat
		_visual_root.add_child(wall)
	for sx: float in [
		HULL_LENGTH * 0.5 - WALL_THICKNESS * 0.5, -(HULL_LENGTH * 0.5 - WALL_THICKNESS * 0.5)
	]:
		var wall := MeshInstance3D.new()
		var wall_mesh := BoxMesh.new()
		wall_mesh.size = Vector3(WALL_THICKNESS, WALL_HEIGHT, HULL_WIDTH)
		wall.mesh = wall_mesh
		wall.position = Vector3(sx, wall_y, 0)
		wall.material_override = mat
		_visual_root.add_child(wall)


# Vanilla c(eb) — right-click while same-player rider dismounts;
# otherwise mounts an empty cart.
func right_click_with(_held_id: int, player: Node3D) -> bool:
	if _rider == player:
		dismount()
		return true
	if _rider != null:
		return false
	mount(player)
	return true


func mount(player: Node3D) -> void:
	if _rider != null:
		return
	_rider = player
	if player.has_method("set_mount"):
		player.set_mount(self)


func dismount() -> void:
	if _rider == null:
		return
	var p: Node3D = _rider
	_rider = null
	if p != null and p.has_method("set_mount"):
		p.set_mount(null)
	# Pop the rider above the cart collider so they don't get stuck
	# inside on land. Same fix as the boat's dismount.
	if p != null:
		p.global_position = Vector3(
			p.global_position.x, global_position.y + HULL_HEIGHT + 0.9, p.global_position.z
		)


# Vanilla qd.java::f(lw, int) — same damage logic as boat. Each hit
# adds attacker damage × 10 to internal counter; cart breaks at >40.
# Rock animation kicks in on every hit.
func take_damage(amount: int) -> void:
	if amount <= 0:
		return
	_damage_rock = -_damage_rock if _damage_rock != 0.0 else 1.0
	_damage_time = 10.0
	health = maxi(0, health - amount)
	if health <= 0:
		_destroy()


func _destroy() -> void:
	if _rider != null:
		dismount()
	_spawn_break_drops()
	SFX.play_break(Blocks.PLANKS)
	queue_free()


func _spawn_break_drops() -> void:
	# Vanilla qd.java::d() drops 1 minecart item + the cart's iron-based
	# build cost. Alpha drops just the minecart item (consistent with
	# vanilla CraftingManager: 5 iron → 1 cart, so breaking returns 1).
	var parent: Node = get_parent()
	if parent == null:
		return
	var item := DroppedItem.new()
	parent.add_child(item)
	var jitter := Vector3(randf_range(-0.2, 0.2), 0.3, randf_range(-0.2, 0.2))
	item.global_position = global_position + Vector3(0, 0.4, 0) + jitter
	item.setup(Items.MINECART)


# Per-tick physics. Two branches:
#   1. On a rail: snap to rail line, project motion onto rail axis,
#      apply slope gravity for ascending rails, use on-rail friction
#      (0.997 — cart coasts far). Vanilla qd.java::e_() does the same
#      using the 10-direction j[][][] lookup table.
#   2. Off rail: standard gravity + drag (cart fell off the rails or
#      was placed in open air). Same shape as the boat's on-land
#      physics.
func _physics_process(delta: float) -> void:
	var rail_info: Dictionary = _find_rail_under_cart()
	var on_rail: bool = not rail_info.is_empty()
	if on_rail:
		_apply_rail_physics(rail_info.cell, rail_info.meta, delta)
	else:
		# Standard gravity — cart falls if unsupported.
		velocity.y -= GRAVITY * delta
	# Rider thrust. On rails, project the WASD input onto the rail
	# axis so the cart accelerates along the rail (regardless of which
	# direction the rider is looking). Off rail, free-form like a boat.
	if _rider != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var thrust_dir: Vector3 = _read_rider_input()
		if thrust_dir.length_squared() > 0.001:
			if on_rail:
				var rail_axis: Vector3 = _rail_axis_for(rail_info.meta)
				var along: float = thrust_dir.dot(rail_axis)
				velocity += rail_axis * along * RIDER_THRUST * delta
			else:
				velocity.x += thrust_dir.x * RIDER_THRUST * delta
				velocity.z += thrust_dir.z * RIDER_THRUST * delta
	# Soft push when player walks into an empty cart.
	if _rider == null:
		_apply_soft_push(delta)
	velocity.x = clampf(velocity.x, -MAX_HORIZ_PER_AXIS, MAX_HORIZ_PER_AXIS)
	velocity.z = clampf(velocity.z, -MAX_HORIZ_PER_AXIS, MAX_HORIZ_PER_AXIS)
	# Friction. On-rail drag (0.997) makes carts coast ~10 blocks per
	# kick (vanilla minecraft.wiki figure); off-rail drag (0.95) brings
	# carts to a quick stop when they leave the rails.
	var tick_scale: float = delta * 20.0
	var horiz_drag: float = DRAG_ON_RAIL_PER_TICK if on_rail else DRAG_OFF_RAIL_PER_TICK
	velocity.x *= pow(horiz_drag, tick_scale)
	velocity.z *= pow(horiz_drag, tick_scale)
	if not on_rail:
		velocity.y *= pow(DRAG_VERT_PER_TICK, tick_scale)
	# Yaw — track the rail direction when on rails (so the cart sprite
	# orients along the track), else track rider facing.
	var target_yaw: float = rotation.y
	if on_rail:
		var axis: Vector3 = _rail_axis_for(rail_info.meta)
		# Pick yaw such that the cart's local -Z faces along the axis
		# (matches Godot forward convention).
		if absf(axis.x) > 0.001 or absf(axis.z) > 0.001:
			target_yaw = atan2(-axis.x, -axis.z)
	elif _rider != null:
		target_yaw = _rider.rotation.y
	var diff: float = target_yaw - rotation.y
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	# Carts on rails snap yaw quickly (~half a second) since the rail
	# orientation is fixed; off-rail cart turns more gradually.
	var yaw_rate: float = 10.0 if on_rail else 5.0
	var max_step: float = yaw_rate * delta
	diff = clampf(diff, -max_step, max_step)
	rotation.y += diff
	var was_grounded: bool = is_on_floor()
	move_and_slide()
	if not was_grounded and is_on_floor():
		velocity *= BUMP_DAMP
	if is_on_wall() and not on_rail:
		velocity = velocity.slide(get_wall_normal())
	if _rider != null:
		_rider.global_position = global_position + _SEAT_OFFSET
	_update_damage_rock(delta)


# Find the rail block under the cart. Returns {cell: Vector3i, meta:
# int} on hit, {} on miss. Checks the cart's current cell first
# (regular rails) and the cell below (lets a cart that just rolled
# off an ascending rail still register on the higher rail's neighbor).
func _find_rail_under_cart() -> Dictionary:
	if _chunk_manager == null:
		return {}
	var cx: int = int(floor(global_position.x))
	var cy: int = int(floor(global_position.y))
	var cz: int = int(floor(global_position.z))
	# Primary: cart's containing cell.
	if _chunk_manager.get_world_block(Vector3i(cx, cy, cz)) == Blocks.RAIL:
		return {
			"cell": Vector3i(cx, cy, cz),
			"meta": _chunk_manager.get_world_block_meta(Vector3i(cx, cy, cz)),
		}
	# Fallback: cell below (handles the cart sitting just above a rail
	# after a small Y drift).
	if _chunk_manager.get_world_block(Vector3i(cx, cy - 1, cz)) == Blocks.RAIL:
		return {
			"cell": Vector3i(cx, cy - 1, cz),
			"meta": _chunk_manager.get_world_block_meta(Vector3i(cx, cy - 1, cz)),
		}
	return {}


# Return the unit direction vector the rail's axis points along.
# For straight rails: pure X or Z. For ascending rails: diagonal in
# the climbing plane. For curves (meta 6-9): pick the axis closer to
# the cart's current velocity (crude — Stage 2a snap-through instead
# of smooth arc interpolation; Stage 2b can add curve interpolation).
# gdlint: disable=max-returns
func _rail_axis_for(meta: int) -> Vector3:
	match meta:
		0:
			return Vector3(0, 0, 1)
		1:
			return Vector3(1, 0, 0)
		2:
			# Ascending east: from (-1,-1,0) to (+1,0,0) is (+2, +1, 0).
			return Vector3(2, 1, 0).normalized()
		3:
			# Ascending west: from (-1,0,0) to (+1,-1,0) is (+2, -1, 0).
			return Vector3(2, -1, 0).normalized()
		4:
			# Ascending north: from (0,0,-1) to (0,-1,+1) is (0, -1, +2).
			return Vector3(0, -1, 2).normalized()
		5:
			# Ascending south: from (0,-1,-1) to (0,0,+1) is (0, +1, +2).
			return Vector3(0, 1, 2).normalized()
		6, 7, 8, 9:
			# Curves — pick the dominant axis of current velocity.
			# Stage 2a crude curve handling: continue along the
			# perpendicular axis without smooth interpolation.
			if absf(velocity.x) > absf(velocity.z):
				return Vector3(1, 0, 0)
			return Vector3(0, 0, 1)
	return Vector3(0, 0, 1)


# Snap cart to rail line, kill off-axis velocity, apply slope gravity
# for ascending rails. Called from _physics_process when the cart is
# on a rail.
# gdlint: disable=max-returns
func _apply_rail_physics(cell: Vector3i, meta: int, delta: float) -> void:
	var rail_y: float = float(cell.y) + 1.0 / 16.0
	# Straight N-S: snap X to cell center, lock Y to rail surface.
	if meta == 0:
		global_position.x = float(cell.x) + 0.5
		global_position.y = rail_y
		velocity.x = 0.0
		velocity.y = 0.0
		return
	# Straight E-W.
	if meta == 1:
		global_position.z = float(cell.z) + 0.5
		global_position.y = rail_y
		velocity.z = 0.0
		velocity.y = 0.0
		return
	# Ascending east (meta 2) — diagonal in X-Y plane. The rail surface
	# at local X=0 (cell.x) is at cell.y + 1/16; at local X=1 (cell.x+1)
	# it's at cell.y + 1 + 1/16. Linearly interpolate the cart's Y based
	# on its X position within the cell.
	if meta == 2:
		global_position.z = float(cell.z) + 0.5
		velocity.z = 0.0
		var t2: float = clampf(global_position.x - float(cell.x), 0.0, 1.0)
		global_position.y = rail_y + t2
		# Slope gravity along rail axis. Rail axis = (2, 1, 0)/sqrt(5).
		# Gravity component along this axis = (0, -1, 0).dot(axis) =
		# -1/sqrt(5). So velocity in axis direction gets reduced (downhill
		# = -X side). Scale = GRAVITY * delta * (1/sqrt(5)).
		var slope_accel: float = -GRAVITY * delta / sqrt(5.0)
		velocity.x += slope_accel  # gravity pulls -X (downhill)
		# Y velocity is implicit in the X velocity * slope ratio.
		velocity.y = velocity.x * 0.5  # tan(slope) = rise/run = 1/2
		return
	# Ascending west (meta 3) — mirror of meta 2.
	if meta == 3:
		global_position.z = float(cell.z) + 0.5
		velocity.z = 0.0
		var t3: float = clampf(global_position.x - float(cell.x), 0.0, 1.0)
		global_position.y = rail_y + (1.0 - t3)
		var slope_accel: float = GRAVITY * delta / sqrt(5.0)
		velocity.x += slope_accel  # gravity pulls +X (downhill)
		velocity.y = -velocity.x * 0.5
		return
	# Ascending north (meta 4) — Z-axis climber, high Y at low Z.
	if meta == 4:
		global_position.x = float(cell.x) + 0.5
		velocity.x = 0.0
		var t4: float = clampf(global_position.z - float(cell.z), 0.0, 1.0)
		global_position.y = rail_y + (1.0 - t4)
		var slope_accel: float = GRAVITY * delta / sqrt(5.0)
		velocity.z += slope_accel
		velocity.y = -velocity.z * 0.5
		return
	# Ascending south (meta 5) — Z-axis climber, high Y at high Z.
	if meta == 5:
		global_position.x = float(cell.x) + 0.5
		velocity.x = 0.0
		var t5: float = clampf(global_position.z - float(cell.z), 0.0, 1.0)
		global_position.y = rail_y + t5
		var slope_accel: float = -GRAVITY * delta / sqrt(5.0)
		velocity.z += slope_accel
		velocity.y = velocity.z * 0.5
		return
	# Curves (meta 6-9) — Stage 2a crude handling: snap to cell center
	# and continue in the dominant velocity direction. Vanilla
	# interpolates smoothly along the curve arc; that's a Stage 2b
	# refinement once the basic loop works.
	if meta >= 6 and meta <= 9:
		global_position.y = rail_y
		velocity.y = 0.0
		# Kill perpendicular velocity based on dominant axis.
		if absf(velocity.x) > absf(velocity.z):
			global_position.z = float(cell.z) + 0.5
			velocity.z = 0.0
		else:
			global_position.x = float(cell.x) + 0.5
			velocity.x = 0.0
		return


func _read_rider_input() -> Vector3:
	var input := Vector3.ZERO
	if _rider == null:
		return input
	var yaw: float = _rider.rotation.y
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var rt := Vector3(cos(yaw), 0, -sin(yaw))
	if Input.is_action_pressed("move_forward"):
		input += fwd
	if Input.is_action_pressed("move_back"):
		input -= fwd
	if Input.is_action_pressed("move_left"):
		input -= rt
	if Input.is_action_pressed("move_right"):
		input += rt
	if input.length_squared() > 0.001:
		input = input.normalized()
	return input


func _apply_soft_push(delta: float) -> void:
	if _player_ref == null:
		return
	var dx: float = _player_ref.global_position.x - global_position.x
	var dz: float = _player_ref.global_position.z - global_position.z
	var push_radius: float = HULL_LENGTH * 0.5 + 0.35
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist >= push_radius or dist < 0.001:
		return
	var overlap: float = (push_radius - dist) / push_radius
	var push_x: float = -dx / dist
	var push_z: float = -dz / dist
	var accel: float = 4.0 * overlap
	velocity.x += push_x * accel * delta
	velocity.z += push_z * accel * delta


func _update_damage_rock(delta: float) -> void:
	if _visual_root == null:
		return
	if _damage_time > 0.0:
		_damage_time = maxf(0.0, _damage_time - delta * 20.0)
	if absf(_damage_rock) > 0.001:
		_damage_rock *= pow(0.85, delta * 20.0)
		_visual_root.rotation.x = _damage_rock * 0.4
	elif _visual_root.rotation.x != 0.0:
		_damage_rock = 0.0
		_visual_root.rotation.x = 0.0


# --- Persistence (EntitySave TYPE_MINECART) ---


func to_save_dict() -> Dictionary:
	return {
		"pos": global_position,
		"yaw": rotation.y,
		"velocity": velocity,
		"health": health,
		"has_rider": _rider != null,
	}


func restore_from_dict(d: Dictionary) -> void:
	global_position = d.get("pos", Vector3.ZERO) as Vector3
	rotation.y = float(d.get("yaw", 0.0))
	velocity = d.get("velocity", Vector3.ZERO) as Vector3
	health = int(d.get("health", MAX_HEALTH))
	if bool(d.get("has_rider", false)):
		call_deferred("_remount_saved_rider")


func _remount_saved_rider() -> void:
	if _rider != null:
		return
	var player: Node3D = get_tree().get_root().find_child("Player", true, false) as Node3D
	if player == null:
		return
	mount(player)
