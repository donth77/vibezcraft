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

# Vanilla collision AABB (`qd.java::a(0.98f, 0.7f)`) is 0.98 × 0.7 × 0.98
# m — a square footprint by code, but the visual model in cv2.java
# ModelMinecart is RECTANGULAR (about 1.2 long × 0.85 wide × 0.6 tall).
# Square visual reads as a wooden crate; rectangular reads as a cart.
# Collider stays square (vanilla parity); visual is shaped to match
# the vanilla cart silhouette.
const HULL_LENGTH: float = 1.2
const HULL_WIDTH: float = 0.85
const HULL_HEIGHT: float = 0.6
# Collision AABB stays at vanilla 0.98 × 0.7 × 0.98 regardless of visual.
const COLLISION_WIDTH: float = 0.98
const COLLISION_HEIGHT: float = 0.7
const FLOOR_THICKNESS: float = 0.0625  # 1 vanilla unit, thin metal floor
const WALL_HEIGHT: float = HULL_HEIGHT - FLOOR_THICKNESS
const WALL_THICKNESS: float = 0.0625

# Per-tick → per-second physics constants (×20 TPS scale where applicable).
# Vanilla qd.java::e_() uses 0.997 per tick on-rail, 0.95 per tick off-rail.
# pow(p, delta*20) at 60 FPS = pow(0.997, 1/3) ≈ 0.999; ^60/s = 0.94 =
# 0.997^20 = vanilla per-second decay. Conversion is correct.
const DRAG_ON_RAIL_PER_TICK: float = 0.997
const DRAG_OFF_RAIL_PER_TICK: float = 0.95
# Legacy aliases — kept so any external readers still resolve.
const DRAG_HORIZ_PER_TICK: float = 0.997
const DRAG_VERT_PER_TICK: float = 0.95
# Vanilla terrain gravity is 0.04 per tick² for entities = 16 m/s².
const GRAVITY: float = 16.0
const BUMP_DAMP: float = 0.5

# Vanilla slope impulse — qd.java:162 `d8 = 0.0078125` blocks/tick
# applied once per tick to az/aB on ascending rails. Convert to m/s²:
# 0.0078125 b/tick * 20 ticks/s = 0.15625 m/s per tick → as an
# acceleration that's 0.15625 * 20 = 3.125 m/s². Per frame we apply
# `SLOPE_ACCEL * delta`.
const SLOPE_ACCEL: float = 3.125

# Rider thrust — vanilla minecarts have no rider acceleration (you
# bump them manually or use slopes). This is a deviation for UX:
# WASD when seated thrusts the cart along the rail axis.
const RIDER_THRUST: float = 4.0
# Vanilla qd.java:160 caps at d7 = 0.4 blocks/tick = 8 m/s.
const MAX_HORIZ_PER_AXIS: float = 8.0
# Radius for cart-cart collision detection. Vanilla qd.java:342 uses
# AABB expanded by 0.2 — for our square 0.98 footprint that's a contact
# radius of (0.98/2 + 0.2) ≈ 0.69 m.
const CART_COLLISION_RADIUS: float = 0.69

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
var _floor_mat: StandardMaterial3D = null
var _wall_mat: StandardMaterial3D = null
var _last_light_brightness: float = -1.0


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
	add_to_group("minecarts")
	_build_collider()
	_build_visual_mesh()


func _build_collider() -> void:
	# Vanilla `qd.java::a(0.98f, 0.7f)` → 0.98 × 0.7 × 0.98 AABB.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Collision AABB uses vanilla 0.98 × 0.7 × 0.98 — square footprint
	# from qd.java::a(0.98f, 0.7f). Differs from the visual hull
	# (rectangular for cart-shape silhouette).
	box.size = Vector3(COLLISION_WIDTH, COLLISION_HEIGHT, COLLISION_WIDTH)
	shape.shape = box
	shape.position = Vector3(0, COLLISION_HEIGHT * 0.5, 0)
	add_child(shape)


# Build the open-top hull. Uses vanilla cart.png skin (64×32) with
# per-face uv1 cropping to the floor strip vs wall strip — same
# splotch-free approach as the boat hull. Vanilla cv2.java ModelMinecart
# uses the same skin layout: floor strip at (0, 10)→(20, 28), wall
# strips at (0, 0)→(16, 10) and similar.
func _build_visual_mesh() -> void:
	_visual_root = Node3D.new()
	add_child(_visual_root)
	var cart_tex: Texture2D = _load_cart_texture()
	# Vanilla cart.png is 64×32. Floor occupies a 20×16 strip at (0, 10)
	# in pixel coords. Walls occupy 24×8 strips at (0, 0) approx — but
	# the model is simple enough that we just use the floor region for
	# the bottom face and the rest of the texture (top half) for walls.
	# Normalize pixel coords to [0,1] UV.
	var floor_offset := Vector3(0.0, 10.0 / 32.0, 0.0)
	var floor_scale := Vector3(20.0 / 64.0, 16.0 / 32.0, 1.0)
	var wall_offset := Vector3(0.0, 0.0, 0.0)
	var wall_scale := Vector3(24.0 / 64.0, 8.0 / 32.0, 1.0)
	_floor_mat = _make_cart_material(cart_tex)
	_floor_mat.uv1_offset = floor_offset
	_floor_mat.uv1_scale = floor_scale
	_wall_mat = _make_cart_material(cart_tex)
	_wall_mat.uv1_offset = wall_offset
	_wall_mat.uv1_scale = wall_scale
	# Floor slab — full footprint, thin. Long axis (HULL_LENGTH) is
	# placed along LOCAL Z so when the cart yaws to align with the rail
	# (rotation.y derived from atan2 against the rail axis), the cart's
	# length lines up with the track direction. Earlier build had length
	# along local X, which left the cart sideways to the rail.
	var floor_mi := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(HULL_WIDTH, FLOOR_THICKNESS, HULL_LENGTH)
	floor_mi.mesh = floor_mesh
	floor_mi.position = Vector3(0, FLOOR_THICKNESS * 0.5, 0)
	floor_mi.material_override = _floor_mat
	_visual_root.add_child(floor_mi)
	# 4 walls forming an open-top hull. Long walls run along LOCAL Z
	# (length axis), short ends along LOCAL X (width axis).
	var wall_y: float = FLOOR_THICKNESS + WALL_HEIGHT * 0.5
	var inner_len: float = HULL_LENGTH - 2.0 * WALL_THICKNESS
	# Long sides on +X / -X faces — Z is the length axis.
	for sx: float in [
		HULL_WIDTH * 0.5 - WALL_THICKNESS * 0.5, -(HULL_WIDTH * 0.5 - WALL_THICKNESS * 0.5)
	]:
		var wall := MeshInstance3D.new()
		var wall_mesh := BoxMesh.new()
		wall_mesh.size = Vector3(WALL_THICKNESS, WALL_HEIGHT, inner_len)
		wall.mesh = wall_mesh
		wall.position = Vector3(sx, wall_y, 0)
		wall.material_override = _wall_mat
		_visual_root.add_child(wall)
	# Short ends on +Z / -Z faces (front and back of cart).
	for sz: float in [
		HULL_LENGTH * 0.5 - WALL_THICKNESS * 0.5, -(HULL_LENGTH * 0.5 - WALL_THICKNESS * 0.5)
	]:
		var wall := MeshInstance3D.new()
		var wall_mesh := BoxMesh.new()
		wall_mesh.size = Vector3(HULL_WIDTH, WALL_HEIGHT, WALL_THICKNESS)
		wall.mesh = wall_mesh
		wall.position = Vector3(0, wall_y, sz)
		wall.material_override = _wall_mat
		_visual_root.add_child(wall)


# Pack-aware cart skin loader. Falls back to the shared entity dir
# (where the vanilla cart.png was extracted), then to null.
func _load_cart_texture() -> Texture2D:
	var pack_path := "res://assets/textures/entities/packs/%s/cart.png" % BlockAtlas.active_pack
	if ResourceLoader.exists(pack_path):
		return load(pack_path) as Texture2D
	return null


func _make_cart_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if tex != null:
		mat.albedo_texture = tex
	else:
		mat.albedo_color = Color(0.55, 0.55, 0.60)  # metallic grey fallback
	return mat


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
	# Soft push when player walks into an empty cart. On rails, the
	# push is projected onto the rail axis so the player can roll the
	# cart along the track without bumping it sideways off the snap or
	# past the end. Off rail, free-form push (cart already left the
	# rails — sliding it around is fine).
	if _rider == null:
		var rail_axis_for_push: Vector3 = (
			_rail_axis_for(rail_info.meta) if on_rail else Vector3.ZERO
		)
		_apply_soft_push(delta, rail_axis_for_push)
	velocity.x = clampf(velocity.x, -MAX_HORIZ_PER_AXIS, MAX_HORIZ_PER_AXIS)
	velocity.z = clampf(velocity.z, -MAX_HORIZ_PER_AXIS, MAX_HORIZ_PER_AXIS)
	# Friction. On-rail drag (0.997) makes carts coast ~10 blocks per
	# kick (vanilla minecraft.wiki figure); off-rail drag (0.95) brings
	# carts to a slower stop when they leave the rails.
	var tick_scale: float = delta * 20.0
	var horiz_drag: float = DRAG_ON_RAIL_PER_TICK if on_rail else DRAG_OFF_RAIL_PER_TICK
	var horiz_factor: float = pow(horiz_drag, tick_scale)
	velocity.x *= horiz_factor
	velocity.z *= horiz_factor
	if not on_rail:
		velocity.y *= pow(DRAG_VERT_PER_TICK, tick_scale)
	# Cart-cart collision — share momentum + push apart. Vanilla
	# qd.java::g(lw) at lines 481-538. Done after drag so the averaged
	# velocity is the just-decayed value, not stale velocity from last
	# frame.
	_apply_cart_cart_collision()
	# Yaw — track the rail direction when on rails (so the cart sprite
	# orients along the track), else track rider facing. Rail axis is
	# undirected (cart can face either way), so pick the orientation
	# closest to the current rotation to avoid spinning 180° when the
	# cart's initial yaw happens to be opposite the canonical axis
	# (e.g. just-placed cart with player facing the "wrong" way along
	# the rail).
	var target_yaw: float = rotation.y
	if on_rail:
		var axis: Vector3 = _rail_axis_for(rail_info.meta)
		if absf(axis.x) > 0.001 or absf(axis.z) > 0.001:
			var yaw_a: float = atan2(-axis.x, -axis.z)
			var yaw_b: float = atan2(axis.x, axis.z)
			var diff_a: float = absf(_shortest_angle(yaw_a - rotation.y))
			var diff_b: float = absf(_shortest_angle(yaw_b - rotation.y))
			target_yaw = yaw_a if diff_a <= diff_b else yaw_b
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
	# Move. On rails, we translate position directly along the rail
	# axis instead of using move_and_slide — physics collision response
	# was shoving the cart off the rail when the player walked into it
	# (cart's mask 0b01 sees the player's terrain layer, and the slide
	# resolution kicked the cart sideways). After translation, rail
	# physics on the next tick snaps any residual perpendicular drift.
	# Off-rail uses move_and_slide for normal gravity + terrain bumps.
	if on_rail:
		global_position += velocity * delta
	else:
		var was_grounded: bool = is_on_floor()
		move_and_slide()
		if not was_grounded and is_on_floor():
			velocity *= BUMP_DAMP
		if is_on_wall():
			velocity = velocity.slide(get_wall_normal())
	if _rider != null:
		_rider.global_position = global_position + _SEAT_OFFSET
	_update_damage_rock(delta)
	_update_entity_lighting()


# Sample sky+block light at the cart's cell and modulate the cart
# materials so the hull dims at night / under cover and brightens near
# torches. Vanilla EntityRenderer does the same per-tick. Skip the
# StandardMaterial3D writes when brightness hasn't moved meaningfully
# since last frame (LUT result rounded to 2 dp) — material rebinds are
# cheap individually but happen 60-144×/s per cart and across N carts.
func _update_entity_lighting() -> void:
	if _floor_mat == null or _wall_mat == null:
		return
	var cell := Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + FLOOR_THICKNESS + 0.5)),
		int(floor(global_position.z))
	)
	var b: float = EntityLighting.sample_brightness(_chunk_manager, cell)
	if absf(b - _last_light_brightness) < 0.01:
		return
	_last_light_brightness = b
	var c := Color(b, b, b)
	_floor_mat.albedo_color = c
	_wall_mat.albedo_color = c


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
	# Primary: cart's containing cell. Cache the Vector3i so we only
	# walk the chunk-lookup arithmetic once per check (not twice for
	# block then meta).
	var here := Vector3i(cx, cy, cz)
	if _chunk_manager.get_world_block(here) == Blocks.RAIL:
		return {"cell": here, "meta": _chunk_manager.get_world_block_meta(here)}
	# Fallback: cell below (cart sitting just above a rail after Y drift).
	var below := Vector3i(cx, cy - 1, cz)
	if _chunk_manager.get_world_block(below) == Blocks.RAIL:
		return {"cell": below, "meta": _chunk_manager.get_world_block_meta(below)}
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
		_apply_end_of_track_brake(cell, Vector3i(0, 0, 1), Vector3i(0, 0, -1), delta)
		return
	# Straight E-W.
	if meta == 1:
		global_position.z = float(cell.z) + 0.5
		global_position.y = rail_y
		velocity.z = 0.0
		velocity.y = 0.0
		_apply_end_of_track_brake(cell, Vector3i(1, 0, 0), Vector3i(-1, 0, 0), delta)
		return
	# Ascending east (meta 2) — diagonal in X-Y plane. The rail surface
	# at local X=0 (cell.x) is at cell.y + 1/16; at local X=1 (cell.x+1)
	# it's at cell.y + 1 + 1/16. Linearly interpolate the cart's Y based
	# on its X position within the cell.
	# Ascending east/west/north/south — vanilla qd.java:174-185 applies a
	# single per-tick `0.0078125` impulse on ascending rails (not a
	# gravity-scaled continuous force). Conversion: 0.0078125 b/tick *
	# 20 = 0.15625 m/s per tick → as m/s² that's SLOPE_ACCEL = 3.125.
	# Sign: meta 2/4 pull velocity toward the downhill cardinal (-X, +Z
	# respectively); meta 3/5 the opposite.
	if meta == 2:
		global_position.z = float(cell.z) + 0.5
		velocity.z = 0.0
		var t2: float = clampf(global_position.x - float(cell.x), 0.0, 1.0)
		global_position.y = rail_y + t2
		velocity.x -= SLOPE_ACCEL * delta  # downhill = -X
		velocity.y = velocity.x * 0.5  # tan(slope) = rise/run = 1/2
		return
	if meta == 3:
		global_position.z = float(cell.z) + 0.5
		velocity.z = 0.0
		var t3: float = clampf(global_position.x - float(cell.x), 0.0, 1.0)
		global_position.y = rail_y + (1.0 - t3)
		velocity.x += SLOPE_ACCEL * delta  # downhill = +X
		velocity.y = -velocity.x * 0.5
		return
	if meta == 4:
		global_position.x = float(cell.x) + 0.5
		velocity.x = 0.0
		var t4: float = clampf(global_position.z - float(cell.z), 0.0, 1.0)
		global_position.y = rail_y + (1.0 - t4)
		velocity.z += SLOPE_ACCEL * delta  # downhill = +Z
		velocity.y = -velocity.z * 0.5
		return
	if meta == 5:
		global_position.x = float(cell.x) + 0.5
		velocity.x = 0.0
		var t5: float = clampf(global_position.z - float(cell.z), 0.0, 1.0)
		global_position.y = rail_y + t5
		velocity.z -= SLOPE_ACCEL * delta  # downhill = -Z
		velocity.y = velocity.z * 0.5
		return
	# Curves (meta 6-9) — Stage 2b smooth arc interpolation. Cart's
	# position is snapped to the nearest point on a quarter-circle arc
	# that wraps the corner inside the cell; velocity is projected onto
	# the tangent so the cart's motion is constrained to follow the
	# curve.
	if meta >= 6 and meta <= 9:
		_apply_curve_physics(cell, meta)
		return


# Stop the cart from rolling off the end of a straight rail. For a
# rail with two cardinal neighbor offsets (pos_dir = the "positive"
# end, neg_dir = "negative" end), checks whether each end has a rail
# block to roll into. If not, the cart approaching that end is
# clamped to the cell center and its velocity in that direction zeroed
# — the rail line terminates at the cell edge, the cart stops there.
func _apply_end_of_track_brake(
	cell: Vector3i, pos_dir: Vector3i, neg_dir: Vector3i, _delta: float
) -> void:
	if _chunk_manager == null:
		return
	# A rail one cell DOWN counts as a continuation too — that's the
	# top of a descending ramp. Without this, a flat rail sitting at
	# the top of a ramp would brake the cart at its centre instead of
	# letting it roll onto the slope.
	var pos_has_rail: bool = (
		_chunk_manager.get_world_block(cell + pos_dir) == Blocks.RAIL
		or _chunk_manager.get_world_block(cell + pos_dir + Vector3i(0, -1, 0)) == Blocks.RAIL
	)
	var neg_has_rail: bool = (
		_chunk_manager.get_world_block(cell + neg_dir) == Blocks.RAIL
		or _chunk_manager.get_world_block(cell + neg_dir + Vector3i(0, -1, 0)) == Blocks.RAIL
	)
	# Pick the motion axis from whichever cardinal direction has a
	# non-zero component (rails are axis-aligned).
	var axis_x: bool = pos_dir.x != 0
	var v_along: float = velocity.x if axis_x else velocity.z
	var pos_along: float = global_position.x if axis_x else global_position.z
	var center: float = (float(cell.x) if axis_x else float(cell.z)) + 0.5
	# Rolling toward the +end (positive velocity along axis) into a
	# non-rail neighbor → clamp position back to center, kill velocity.
	if v_along > 0.0 and not pos_has_rail and pos_along >= center:
		if axis_x:
			global_position.x = center
			velocity.x = 0.0
		else:
			global_position.z = center
			velocity.z = 0.0
	# Same for the -end.
	if v_along < 0.0 and not neg_has_rail and pos_along <= center:
		if axis_x:
			global_position.x = center
			velocity.x = 0.0
		else:
			global_position.z = center
			velocity.z = 0.0


# Snap cart to a quarter-circle arc inside a curve-rail cell. Each
# curve meta wraps around one of the cell's four corners (see
# RAIL_ENDPOINTS). The arc has radius 0.5 and is centered at the
# wrap corner; cart's position projects onto the nearest arc point,
# and velocity is constrained to the tangent at that point.
func _apply_curve_physics(cell: Vector3i, meta: int) -> void:
	# Wrap-corner per meta, in cell-local 2D coords (x, z) ∈ [0, 1]².
	var corner_x: float = 0.0
	var corner_z: float = 0.0
	match meta:
		6:  # NE curve: S + E endpoints → wraps SE corner
			corner_x = 1.0
			corner_z = 1.0
		7:  # NW curve: S + W endpoints → wraps SW corner
			corner_x = 0.0
			corner_z = 1.0
		8:  # SW curve: N + W endpoints → wraps NW corner
			corner_x = 0.0
			corner_z = 0.0
		_:  # 9 SE curve: N + E endpoints → wraps NE corner
			corner_x = 1.0
			corner_z = 0.0
	var local_x: float = global_position.x - float(cell.x)
	var local_z: float = global_position.z - float(cell.z)
	var dx: float = local_x - corner_x
	var dz: float = local_z - corner_z
	# Cart's angle from corner. Distance might be 0 if cart is exactly
	# at the corner — clamp to a tiny minimum to avoid NaN from atan2.
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist < 0.001:
		# Cart sitting at the corner — nudge along the arc midline.
		dx = -corner_x + 0.5 - corner_x
		dz = -corner_z + 0.5 - corner_z
	# Snap radius to 0.5 (arc radius).
	var inv: float = 0.5 / maxf(dist, 0.001)
	var snap_dx: float = dx * inv
	var snap_dz: float = dz * inv
	global_position.x = float(cell.x) + corner_x + snap_dx
	global_position.z = float(cell.z) + corner_z + snap_dz
	global_position.y = float(cell.y) + 1.0 / 16.0
	velocity.y = 0.0
	# Tangent direction at the snapped point — perpendicular to the
	# radius vector (snap_dx, snap_dz). For a CCW arc, tangent is
	# (-snap_dz, snap_dx); for CW, (snap_dz, -snap_dx). Either way,
	# project velocity onto the tangent line (both directions are
	# valid since the cart can travel along the arc either way).
	var tx: float = -snap_dz
	var tz: float = snap_dx
	var tlen: float = sqrt(tx * tx + tz * tz)
	if tlen > 0.001:
		tx /= tlen
		tz /= tlen
	var along: float = velocity.x * tx + velocity.z * tz
	velocity.x = tx * along
	velocity.z = tz * along


func _shortest_angle(a: float) -> float:
	var x: float = a
	while x > PI:
		x -= TAU
	while x < -PI:
		x += TAU
	return x


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


# Cart-cart collision — vanilla qd.java::g(lw) lines 481-538. When two
# carts touch, scale each cart's velocity to 20% then add (a) the average
# of their combined velocities and (b) a tiny push apart along the line
# connecting them. Net effect: momentum is shared (a cart slamming into
# a stopped one transfers most of its velocity), and the pair gently
# pushes apart so they don't sit overlapping forever. We process each
# pair only once by gating on the lower instance ID — the OTHER cart in
# the pair will be skipped when its own _physics_process runs this frame.
func _apply_cart_cart_collision() -> void:
	var my_id: int = get_instance_id()
	var carts: Array = get_tree().get_nodes_in_group("minecarts")
	var max_dist_sq: float = (2.0 * CART_COLLISION_RADIUS) * (2.0 * CART_COLLISION_RADIUS)
	for n: Node in carts:
		if n == self:
			continue
		var other := n as Minecart
		if other == null or other.get_instance_id() < my_id:
			continue
		var dx: float = other.global_position.x - global_position.x
		var dz: float = other.global_position.z - global_position.z
		var dist_sq: float = dx * dx + dz * dz
		if dist_sq >= max_dist_sq or dist_sq < 0.0001:
			continue
		var dist: float = sqrt(dist_sq)
		dx /= dist
		dz /= dist
		# Vanilla: d5 = 1/dist clamped to 1.0; then *= 0.1 * 0.5 = 0.05.
		# Per-tick velocity unit, so blocks/tick → m/s: *20.
		var inv_dist: float = minf(1.0 / dist, 1.0)
		var push: float = 0.05 * inv_dist * 20.0
		var avg_x: float = (velocity.x + other.velocity.x) * 0.5
		var avg_z: float = (velocity.z + other.velocity.z) * 0.5
		velocity.x = velocity.x * 0.2 + avg_x - dx * push
		velocity.z = velocity.z * 0.2 + avg_z - dz * push
		other.velocity.x = other.velocity.x * 0.2 + avg_x + dx * push
		other.velocity.z = other.velocity.z * 0.2 + avg_z + dz * push


func _apply_soft_push(delta: float, rail_axis: Vector3) -> void:
	if _player_ref == null:
		return
	var dx: float = _player_ref.global_position.x - global_position.x
	var dz: float = _player_ref.global_position.z - global_position.z
	var push_radius: float = HULL_LENGTH * 0.5 + 0.35
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist >= push_radius or dist < 0.001:
		return
	var overlap: float = (push_radius - dist) / push_radius
	var push := Vector3(-dx / dist, 0, -dz / dist)
	# On rails, project push onto rail axis so the player can only roll
	# the cart along the track, not bump it sideways off the snap.
	# Off rail, push freely. The end-of-track brake catches a along-rail
	# push past the last rail's center.
	if rail_axis != Vector3.ZERO:
		var along: float = push.dot(rail_axis)
		push = rail_axis * along
	var accel: float = 4.0 * overlap
	velocity.x += push.x * accel * delta
	velocity.z += push.z * accel * delta


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
