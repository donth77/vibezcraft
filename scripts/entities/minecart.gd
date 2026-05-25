class_name Minecart
extends CharacterBody3D

# gdlint: disable=max-file-lines

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
# Explicit preload — GUT loads test scripts before class_name registers
# the global EntityLighting identifier, so bare `EntityLighting.foo()`
# fails to parse in tests with "Identifier ... not declared in the
# current scope". Preload via const lets us call the same static
# methods through the preloaded GDScript instead.
const _ENTITY_LIGHTING: GDScript = preload("res://scripts/world/entity_lighting.gd")
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

# Vanilla qd.java `d` field — 0=normal, 1=chest, 2=furnace. Determines
# visual (chest mesh on top for variant 1) and right-click behaviour
# (variant 1 opens chest UI instead of mounting). Must be set BEFORE
# _ready so _build_visual_mesh sees the correct value — use
# `setup(..., variant)` or set the property right after `Minecart.new()`.
const VARIANT_NORMAL: int = 0
const VARIANT_CHEST: int = 1
const VARIANT_FURNACE: int = 2

# Chest variant inventory size — vanilla 27 slots (same as block chest).
const CHEST_INVENTORY_SIZE: int = 27

var variant: int = VARIANT_NORMAL
# 27-slot ItemStack array for chest cart. Lazily filled to size when
# variant == CHEST. Direct refs; chest_screen mutates these stacks.
var chest_items: Array = []
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
# Chest cart only — the animated chest sitting in the cart's bed.
# Reuses ChestNode (same geometry + lid animation as world chests).
var _chest_node: Node3D = null
# Furnace cart only — the cube mesh sitting in the cart's bed. Swapped
# between FURNACE / LIT_FURNACE block ids when fuel state flips.
var _furnace_mi: MeshInstance3D = null
# Furnace cart fuel state — when _fuel_ticks > 0 the cart is "burning"
# and applies push velocity along (_push_x, _push_z). Vanilla qd.java
# fields: e (fuel ticks), f/g (push direction).
var _fuel_ticks: int = 0
var _push_x: float = 0.0
var _push_z: float = 0.0
var _is_burning: bool = false
# Accumulates delta until ≥ 1/20 s, then fires cart-cart collision once
# and resets. Vanilla's collision math is a per-TICK impulse (qd.java
# runs at 20 TPS); running it every frame at 60+ FPS triples the push,
# which made adjacent placement shove much harder than vanilla.
var _collision_tick_accum: float = 0.0


func setup(spawn_pos: Vector3, yaw: float, owner: Node3D, cart_variant: int = 0) -> void:
	global_position = spawn_pos
	rotation.y = yaw
	_owner_player = owner
	variant = cart_variant


func _ready() -> void:
	# Layer 2 = selection-only (player raycast hits for mount/break;
	# player body walks through). Mask layer 1 = terrain so we don't
	# free-fall through the world.
	collision_layer = 0b10
	collision_mask = 0b01
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	_player_ref = get_tree().get_root().find_child("Player", true, false) as Node3D
	add_to_group("minecarts")
	_ensure_chest_inventory()
	_build_collider()
	_build_visual_mesh()


# Initialise the chest_items array to 27 empty ItemStacks when the
# variant is CHEST. No-op for other variants.
func _ensure_chest_inventory() -> void:
	if variant != VARIANT_CHEST:
		return
	if chest_items.size() == CHEST_INVENTORY_SIZE:
		return
	chest_items.resize(CHEST_INVENTORY_SIZE)
	for i: int in range(CHEST_INVENTORY_SIZE):
		if chest_items[i] == null:
			chest_items[i] = ItemStack.new()


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
	# Variant-specific add-ons: chest cart drops a small chest mesh
	# inside the bed; furnace cart (not yet implemented) would drop a
	# furnace mesh in the same slot.
	if variant == VARIANT_CHEST:
		_build_chest_mesh()
	elif variant == VARIANT_FURNACE:
		_build_furnace_mesh()


# Build a chest sitting in the cart's bed. Reuses ChestNode so the
# chest's geometry, textures, and lid animation match a world chest
# exactly — no hand-rolled BoxMesh that drifts visually. Scaled down
# slightly so it tucks inside the cart walls instead of poking through.
func _build_chest_mesh() -> void:
	var chest_script: GDScript = load("res://scripts/entities/chest_node.gd")
	_chest_node = chest_script.new() as Node3D
	# Vanilla world chest is 1×1×1; cart bed is 0.85 wide × 1.2 long ×
	# WALL_HEIGHT tall. Scale 0.7 fits inside the gunwales with clearance.
	var s: float = 0.7
	_chest_node.scale = Vector3(s, s, s)
	# Bottom of chest on cart floor, centered XZ. Chest's "front" face
	# is -Z by default — same as our cart's front (where the rider would
	# look toward forward motion), so no extra rotation needed.
	_chest_node.position = Vector3(0, FLOOR_THICKNESS, 0)
	_visual_root.add_child(_chest_node)


# Build a furnace sitting in the cart's bed. Reuses BlockMesh.get_cube_mesh
# so the furnace's face textures (top, side, front) match the world
# furnace block exactly. Scaled down to fit the cart bed; rotated 180°
# around Y so the firebox (-Z face per Blocks.get_face_texture) faces
# +Z = the cart's forward direction. Track lit/unlit by rebuilding the
# mesh when fuel state flips.
func _build_furnace_mesh() -> void:
	_furnace_mi = MeshInstance3D.new()
	_furnace_mi.mesh = BlockMesh.get_cube_mesh(_active_furnace_block_id(), 1.0)
	_furnace_mi.material_override = BlockAtlas.material()
	# BlockMesh.get_cube_mesh emits a cube centred on its own origin and
	# spanning ±size/2 per axis. After scaling by `s`, the cube spans
	# ±(s/2). Position the mesh so the cube's BOTTOM rests on the cart
	# floor: y = FLOOR_THICKNESS + (s/2). XZ stays at 0 — the cube is
	# already centred under the cart origin.
	var s: float = 0.7
	_furnace_mi.scale = Vector3(s, s, s)
	_furnace_mi.position = Vector3(0.0, FLOOR_THICKNESS + s * 0.5, 0.0)
	# Spin so the firebox face (-Z = vanilla front) points to the cart's
	# forward (+Z). Same convention as the chest cart's chest_node.
	_furnace_mi.rotation.y = PI
	_visual_root.add_child(_furnace_mi)


# Helper — the furnace block id for the current burning state. Vanilla
# stores two distinct block ids (FURNACE / LIT_FURNACE) with different
# front-face textures (firebox shows flames when lit). For now the cart
# starts unlit; flips to lit when fueled by the physics step (stage 2).
func _active_furnace_block_id() -> int:
	return Blocks.LIT_FURNACE if _is_burning else Blocks.FURNACE


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


# Vanilla qd.java::a(eb) (lines 582-604).
#   d==0 (NORMAL): rider dismounts on RMB; empty cart mounts the player.
#   d==1 (CHEST): opens the chest UI; never mounts.
#   d==2 (FURNACE): held coal adds 1200 fuel ticks; ALWAYS sets push
#       direction to cart - player (cart accelerates away). Never mounts.
func right_click_with(held_id: int, player: Node3D) -> bool:
	if variant == VARIANT_CHEST:
		_open_chest_screen(player)
		return true
	if variant == VARIANT_FURNACE:
		if held_id == Items.COAL or held_id == Items.CHARCOAL:
			_add_fuel(player)
		# Vanilla qd.java:600-601 sets push direction every RMB,
		# regardless of held item. Push points AWAY from the player so
		# the cart drives off in the direction the player is facing.
		if player != null:
			_push_x = global_position.x - player.global_position.x
			_push_z = global_position.z - player.global_position.z
		return true
	if _rider == player:
		dismount()
		return true
	if _rider != null:
		return false
	mount(player)
	return true


# Vanilla qd.java::g (type==2 with held coal) — `this.e += 1200` and
# consumes one coal. 1200 ticks = 60 s of burning. If the cart has no
# current push direction (just placed, idle), seed it from the player's
# facing so the cart starts thrusting in a sensible direction.
func _add_fuel(player: Node3D) -> void:
	_fuel_ticks += 1200
	if absf(_push_x) < 0.01 and absf(_push_z) < 0.01:
		if absf(velocity.x) > 0.01 or absf(velocity.z) > 0.01:
			_push_x = velocity.x
			_push_z = velocity.z
		elif player != null:
			# Use player's yaw to face the cart's push the way they're looking.
			var yaw: float = player.rotation.y
			_push_x = -sin(yaw)
			_push_z = -cos(yaw)
	_update_burning_visual()
	# Consume one from the player's selected stack.
	if player != null:
		var inv: Inventory = player.get("inventory") as Inventory
		if inv != null and inv.has_method("consume_one_selected"):
			inv.consume_one_selected()


# Open the chest UI bound to THIS cart's chest_items array. The screen
# script (chest_screen.gd) reads/writes the array in place — when the
# screen closes, the cart's inventory is already up-to-date with no
# extra syncing.
func _open_chest_screen(player: Node3D) -> void:
	_ensure_chest_inventory()
	var screen: Node = player.get_node_or_null("Crosshair/ChestScreen") if player != null else null
	if screen == null or not screen.has_method("open_entity"):
		return
	if _chest_node != null and _chest_node.has_method("set_open"):
		_chest_node.set_open(true)
	SFX.play_chest_open()
	screen.open_entity(
		chest_items, "Minecart with Chest", Callable(self, "_on_chest_screen_closed")
	)


func _on_chest_screen_closed() -> void:
	if _chest_node != null and _chest_node.has_method("set_open"):
		_chest_node.set_open(false)
	SFX.play_chest_close()


# Flip the furnace mesh between FURNACE (cold) and LIT_FURNACE (burning)
# based on _fuel_ticks. Called when fuel is added or runs out.
func _update_burning_visual() -> void:
	if _furnace_mi == null:
		return
	var want_burning: bool = _fuel_ticks > 0
	if want_burning == _is_burning:
		return
	_is_burning = want_burning
	_furnace_mi.mesh = BlockMesh.get_cube_mesh(_active_furnace_block_id(), 1.0)


# Furnace cart per-frame thrust. Vanilla qd.java type==2:
#   - if |push| > 0.01: az *= 0.8, aB *= 0.8, az += push_x * 0.04,
#     aB += push_z * 0.04 — each tick.
#   - fuel ticks down at random (~1/4 chance per tick).
#   - if fuel hits 0: push direction zeroed → cart coasts to stop.
# Converted to per-frame at our 60+ FPS:
#   - per-second thrust = 0.04 b/tick * 20 = 0.8 m/s² along push axis.
#   - per-second decay = 0.8 per tick = 0.8^20 = 0.012/s — too aggressive
#     for our drag stack (already handled by DRAG_ON_RAIL). Skip the
#     extra ×0.8 and rely on the global drag; the +0.04 thrust still
#     accelerates the cart visibly.
func _apply_furnace_thrust(delta: float) -> void:
	if _fuel_ticks <= 0:
		# Idle furnace cart — push has no effect; let drag handle decel.
		if _is_burning:
			_is_burning = false
			_update_burning_visual()
		return
	# Decrement fuel. Vanilla: random subtract once per 4 ticks; we use
	# a steady -1 per tick equivalent at 20 TPS for predictability.
	_fuel_ticks -= int(delta * 20.0)
	if _fuel_ticks <= 0:
		_fuel_ticks = 0
		_push_x = 0.0
		_push_z = 0.0
		_update_burning_visual()
		return
	# Apply thrust along normalized push direction. 0.8 m/s² == vanilla
	# 0.04 b/tick × 20.
	var mag: float = sqrt(_push_x * _push_x + _push_z * _push_z)
	if mag > 0.01:
		var nx: float = _push_x / mag
		var nz: float = _push_z / mag
		var accel: float = 0.8
		velocity.x += nx * accel * delta
		velocity.z += nz * accel * delta
	# Sync push direction with velocity (vanilla qd.java:287-297). If
	# the cart reverses against its push, zero the push (player can
	# brake by shoving the cart backwards); otherwise the push tracks
	# the cart's current motion.
	var vel_sq: float = velocity.x * velocity.x + velocity.z * velocity.z
	if mag > 0.01 and vel_sq > 0.001:
		if _push_x * velocity.x + _push_z * velocity.z < 0.0:
			_push_x = 0.0
			_push_z = 0.0
		else:
			_push_x = velocity.x
			_push_z = velocity.z


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
	# Vanilla qd.java::d() drops the cart variant item + the chest +
	# all chest contents for chest carts. Furnace cart would drop a
	# furnace too. Alpha drops just one of each (vanilla recipe is
	# `1 cart + 1 chest -> 1 chest cart`, so breaking returns both).
	var parent: Node = get_parent()
	if parent == null:
		return
	_drop_one(parent, Items.MINECART)
	if variant == VARIANT_CHEST:
		_drop_one(parent, Blocks.CHEST)
		for stack in chest_items:
			if stack == null or stack.is_empty():
				continue
			_drop_stack(parent, stack)
	elif variant == VARIANT_FURNACE:
		_drop_one(parent, Blocks.FURNACE)


func _drop_one(parent: Node, item_id: int) -> void:
	var item := DroppedItem.new()
	parent.add_child(item)
	var jitter := Vector3(randf_range(-0.2, 0.2), 0.3, randf_range(-0.2, 0.2))
	item.global_position = global_position + Vector3(0, 0.4, 0) + jitter
	item.setup(item_id)


func _drop_stack(parent: Node, stack) -> void:
	# DroppedItem holds one item; spawn `count` instances. Practical
	# cart inventories rarely hold full 64-stacks so this is fine.
	for _i: int in range(stack.count):
		var item := DroppedItem.new()
		parent.add_child(item)
		var jitter := Vector3(randf_range(-0.3, 0.3), 0.3, randf_range(-0.3, 0.3))
		item.global_position = global_position + Vector3(0, 0.4, 0) + jitter
		item.setup(stack.item_id)


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
	# Furnace cart self-propulsion. Vanilla qd.java::e_() type==2:
	# while pushed (|f,g| > 0.01), velocity *= 0.8 then += dir * 0.04
	# per tick (= 0.8 m/s² per second of acceleration along the push
	# direction). Fuel decays randomly (~1/4 ticks → ~5/s).
	if variant == VARIANT_FURNACE:
		_apply_furnace_thrust(delta)
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
	# qd.java::g(lw) at lines 481-538. Vanilla fires this once per
	# tick (20 TPS); running it every frame at 60+ FPS would over-apply
	# the per-tick impulse and triple the push when carts spawn next
	# to each other. Gate on a delta accumulator so it fires at vanilla
	# cadence regardless of frame rate.
	_collision_tick_accum += delta
	if _collision_tick_accum >= 1.0 / 20.0:
		_collision_tick_accum = 0.0
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
	var b: float = _ENTITY_LIGHTING.sample_brightness(_chunk_manager, cell)
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
	var d: Dictionary = {
		"pos": global_position,
		"yaw": rotation.y,
		"velocity": velocity,
		"health": health,
		"variant": variant,
		"has_rider": _rider != null,
	}
	if variant == VARIANT_CHEST:
		var items: Array = []
		for s in chest_items:
			if s == null:
				items.append({"id": 0, "count": 0})
			else:
				items.append({"id": s.item_id, "count": s.count})
		d["chest"] = items
	if variant == VARIANT_FURNACE:
		d["fuel"] = _fuel_ticks
		d["push_x"] = _push_x
		d["push_z"] = _push_z
	return d


func restore_from_dict(d: Dictionary) -> void:
	global_position = d.get("pos", Vector3.ZERO) as Vector3
	rotation.y = float(d.get("yaw", 0.0))
	velocity = d.get("velocity", Vector3.ZERO) as Vector3
	health = int(d.get("health", MAX_HEALTH))
	variant = int(d.get("variant", VARIANT_NORMAL))
	if variant == VARIANT_CHEST and d.has("chest"):
		_ensure_chest_inventory()
		var saved: Array = d.get("chest", []) as Array
		for i: int in range(mini(saved.size(), chest_items.size())):
			var entry: Dictionary = saved[i]
			chest_items[i].item_id = int(entry.get("id", 0))
			chest_items[i].count = int(entry.get("count", 0))
	if variant == VARIANT_FURNACE:
		_fuel_ticks = int(d.get("fuel", 0))
		_push_x = float(d.get("push_x", 0.0))
		_push_z = float(d.get("push_z", 0.0))
		call_deferred("_update_burning_visual")
	if bool(d.get("has_rider", false)):
		call_deferred("_remount_saved_rider")


func _remount_saved_rider() -> void:
	if _rider != null:
		return
	var player: Node3D = get_tree().get_root().find_child("Player", true, false) as Node3D
	if player == null:
		return
	mount(player)
