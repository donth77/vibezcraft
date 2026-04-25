class_name DroppedItem
extends Node3D

# Vanilla MC dropped-item behavior:
#   - Spawns at the broken-block position and hovers (no gravity, no
#     collision — MC items just float in place at the spawn height).
#   - Sine-wave bob + slow Y-spin for visual life.
#   - Magnet: when player gets within MAGNET_RADIUS, accelerates toward them.
#   - Pickup: at PICKUP_RADIUS the item plays "pop", removes self, adds to
#     the player's inventory. PICKUP_DELAY_SEC prevents instant re-grab off
#     your own break.

const MESH_SIZE: float = 0.25
const PICKUP_DELAY_SEC: float = 0.5  # default for break-spawned items
# Vanilla Alpha 1.2.6: eo.java:126 sets delayBeforeCanPickup=40 ticks (2s)
# for ANY player-originated drop — Q-throw OR death (eb.b → fo.g → eb.a).
# Same delay for both, so the player can sprint back to a death pile and
# scoop loot before items despawn at LIFETIME_SEC (6000 ticks = 5 min).
const PLAYER_DROP_DELAY_SEC: float = 2.0
const LIFETIME_SEC: float = 300.0  # matches vanilla Java MC
const PICKUP_RADIUS: float = 0.9
const MAGNET_RADIUS: float = 1.8
const MAGNET_SPEED: float = 9.0
const SPIN_SPEED: float = 1.2  # rad/s
# Alpha af.java:24 — `sin((age + partial) / 10.0 + d) * 0.1 + 0.1`. Per-tick
# phase increment is 1/10 rad; at 20 tps that's 2 rad/s → 1/π ≈ 0.3183 Hz
# (one full bob every ~3.14 s). Amplitude 0.1 with +0.1 bias gives a
# non-negative [0, 0.2] block offset.
const HOVER_AMPLITUDE: float = 0.1
const HOVER_FREQUENCY: float = 1.0 / PI  # cycles/sec — ~0.318
const GRAVITY: float = -22.0  # vanilla feel — items arc and settle quickly, not float
const TERMINAL_VELOCITY: float = -32.0
const HORIZONTAL_DRAG: float = 2.5  # 1/s — quickly damps thrown velocity

var item_id: int = 0
var _spawn_time: float = 0.0
var _hover_phase: float = 0.0
var _velocity: Vector3 = Vector3.ZERO  # full 3D so thrown items arc forward
var _pickup_delay: float = PICKUP_DELAY_SEC
var _picked_up: bool = false
var _is_sprite_item: bool = false  # vanilla af.java RenderItem "item" branch
var _mesh: MeshInstance3D
var _player: Node3D
var _camera: Camera3D  # cached — used to billboard sprite items
var _chunk_manager: Node  # cached — used by push-out-of-solid-block
var _ray_query: PhysicsRayQueryParameters3D  # reused per-frame to avoid allocs


func setup(
	p_item_id: int,
	p_initial_velocity: Vector3 = Vector3.ZERO,
	p_pickup_delay: float = PICKUP_DELAY_SEC
) -> void:
	# Called AFTER add_child + global_position set, so the block id and spawn
	# position are valid before the mesh is built. Pass a non-zero velocity
	# (and a longer pickup delay) for player-thrown drops.
	item_id = p_item_id
	_velocity = p_initial_velocity
	_pickup_delay = p_pickup_delay
	_spawn_time = Time.get_ticks_msec() / 1000.0
	# Mesh is a child Node3D so we can bob its local Y without fighting the
	# root's gravity-controlled global Y. Block IDs render as a real cube
	# via BlockMesh; non-block items (coal, ingots, sticks, tools — id >=
	# 100) get the voxel-extruded sprite mesh used by held items, which
	# would otherwise show as a textureless cube. Non-cube blocks (sapling,
	# future torches/plants) take the sprite path too — vanilla draws them
	# as flat 2D billboards on the ground, not as textured cubes with the
	# icon tiled on every face.
	_mesh = MeshInstance3D.new()
	_is_sprite_item = (p_item_id >= Items.STICK or Blocks.needs_gdscript_mesher(p_item_id))
	if _is_sprite_item:
		_build_sprite_mesh(p_item_id)
	else:
		_mesh.mesh = BlockMesh.get_cube_mesh(p_item_id, MESH_SIZE)
	add_child(_mesh)
	_ray_query = PhysicsRayQueryParameters3D.new()


func _process(delta: float) -> void:
	if _picked_up:
		return
	# Alpha 1.2.6 af.java (RenderItem) has two branches:
	#   • Full-cube block (line 38-56): 3D cube, continuous Y-spin
	#     (glRotatef(f5, 0, 1, 0), f5 = age / 20 * 180/π).
	#   • Item / tool / non-cube block (line 57-91): flat 2D sprite,
	#     billboarded to the camera on Y (glRotatef(180 - cam.yaw, 0, 1, 0)),
	#     NO age-based spin — only the sine bob.
	# We preserve the extrusion for visual depth but keep the billboard +
	# no-spin behavior so a diagonal tool sprite stays readable from every
	# angle instead of flashing through a thin edge-on view each rotation.
	if _is_sprite_item:
		_billboard_to_camera()
	else:
		rotate_y(delta * SPIN_SPEED)

	if _player == null:
		_player = _find_player()
	var elapsed: float = Time.get_ticks_msec() / 1000.0 - _spawn_time
	if elapsed > LIFETIME_SEC:
		queue_free()
		return

	# Magnet / pickup. Vanilla rule: skip the pull entirely if the player's
	# inventory can't take this item — otherwise the item orbits the
	# player at PICKUP_RADIUS forever (magnet pulls in, pickup fails,
	# repeat) and looks like it's tied to them by an invisible string.
	if _player != null and elapsed >= _pickup_delay and _player_can_accept():
		var target: Vector3 = _player.global_position + Vector3(0, 0.4, 0)
		var to_target: Vector3 = target - global_position
		var dist: float = to_target.length()
		if dist <= PICKUP_RADIUS:
			_try_pickup(_player)
			return
		if dist <= MAGNET_RADIUS:
			var step: Vector3 = to_target.normalized() * MAGNET_SPEED * delta
			if step.length() >= dist:
				global_position = target
			else:
				global_position += step
			_velocity = Vector3.ZERO
			return

	# Alpha 1.2.6 eo.java:47 — pushOutOfBlocks runs BEFORE move every tick,
	# so the impulse is integrated this frame. Cheap: 1 lookup in the common
	# case (center not in a solid); 7 only when stuck.
	_push_out_of_solid_block()

	# Always-on gravity. Each frame, raycast straight down — if there's still
	# terrain under us, snap to it and zero the velocity; otherwise fall.
	# This way breaking the block under a resting item resumes the fall.
	_apply_physics(delta)

	# Visual hover bob — Alpha af.java:36 applies the bob unconditionally
	# every render tick (glTranslatef(d2, d3 + f4, d4)), so it runs while
	# the item is arcing/sliding as well as at rest. Gating on at-rest
	# caused a visible jump the frame the item settled: mesh.y would snap
	# from 0 to the current sin-wave value. Keeping the bob always-on
	# means the sin phase advances continuously through the fall and the
	# transition to rest is smooth (the item's arc naturally dominates
	# the small bob while in motion).
	if _mesh != null:
		_hover_phase += delta * HOVER_FREQUENCY * TAU
		# +amp bias keeps the bob non-negative so the sprite never dips
		# below its resting Y and clips through the floor.
		_mesh.position.y = sin(_hover_phase) * HOVER_AMPLITUDE + HOVER_AMPLITUDE


func _apply_physics(delta: float) -> void:
	# Gravity on Y, exponential drag on horizontal so thrown items glide
	# briefly before settling. No horizontal collision — items rarely travel
	# more than a block from their spawn before friction stops them.
	_velocity.y = maxf(_velocity.y + GRAVITY * delta, TERMINAL_VELOCITY)
	var drag_factor: float = clampf(1.0 - HORIZONTAL_DRAG * delta, 0.0, 1.0)
	_velocity.x *= drag_factor
	_velocity.z *= drag_factor
	var new_pos: Vector3 = global_position + _velocity * delta
	# Down raycast snaps the item to the floor when it would pass through.
	_ray_query.from = global_position
	_ray_query.to = Vector3(new_pos.x, new_pos.y - MESH_SIZE * 0.5, new_pos.z)
	var result := get_world_3d().direct_space_state.intersect_ray(_ray_query)
	if not result.is_empty() and _velocity.y <= 0.0:
		new_pos.y = result.position.y + MESH_SIZE * 0.5
		_velocity.y = 0.0
	global_position = new_pos


# Build a voxel-extruded sprite mesh from the item's icon texture and
# scale to MESH_SIZE world units (sprite is 16 native px wide → uniform
# scale = MESH_SIZE / 16). Uses the same depth-tested item shader the
# third-person held tool uses.
func _build_sprite_mesh(id: int) -> void:
	var tex: Texture2D = ItemIcons.icon_for(id)
	if tex == null:
		return
	var mesh: ArrayMesh = SpriteExtruder.build(tex)
	if mesh == null:
		return
	_mesh.mesh = mesh
	var ps: float = MESH_SIZE / 16.0
	_mesh.scale = Vector3(ps, ps, ps)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/held_item_world.gdshader") as Shader
	mat.set_shader_parameter("item_texture", tex)
	_mesh.material_override = mat


func _try_pickup(player: Node3D) -> void:
	if not "inventory" in player:
		return
	var inv: Inventory = player.get("inventory") as Inventory
	if inv == null:
		return
	var overflow: int = inv.add_item(item_id, 1)
	if overflow > 0:
		return  # inventory full — leave the item
	_picked_up = true
	SFX.play_pickup()
	queue_free()


func _find_player() -> Node3D:
	return get_tree().root.get_node_or_null("Main/Player") as Node3D


# Alpha af.java:81 — glRotatef(180 - cam.yaw, 0, 1, 0). Rotates on Y only so
# the sprite stays upright; pitch/roll never factor in. SpriteExtruder emits
# the sprite facing +Z, so aiming +Z at the camera (yaw = atan2(dx, dz))
# leaves the sprite flat-on to the viewer at any camera position.
func _billboard_to_camera() -> void:
	if _camera == null:
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			return
	var cam_pos: Vector3 = _camera.global_position
	var dx: float = cam_pos.x - global_position.x
	var dz: float = cam_pos.z - global_position.z
	# Null vector (player stands on the item) — keep last rotation.
	if absf(dx) < 1e-5 and absf(dz) < 1e-5:
		return
	rotation = Vector3(0.0, atan2(dx, dz), 0.0)


# Alpha 1.2.6 eo.java:75-135 (EntityItem.pushOutOfBlocks). Runs every tick
# before move. When the item's center sits inside a solid full cube —
# usually because the player placed a block where it was resting — pick
# the nearest open neighbor face and impulse along that axis so the item
# pops out. Guard on a solid-cube test first so the neighbor scan only
# runs when actually stuck; this is the hot path for resting items.
func _push_out_of_solid_block() -> void:
	if _chunk_manager == null:
		_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager") as Node
		if _chunk_manager == null:
			return
	var pos: Vector3 = global_position
	var bx: int = floori(pos.x)
	var by: int = floori(pos.y)
	var bz: int = floori(pos.z)
	# Alpha gates on nq.o[id] (isOpaqueCube). Our Blocks.is_opaque matches:
	# true for full solids, false for air, fluids, leaves, glass, fire.
	var here_id: int = _chunk_manager.get_world_block(Vector3i(bx, by, bz))
	if not Blocks.is_opaque(here_id):
		return
	var frac_x: float = pos.x - float(bx)
	var frac_y: float = pos.y - float(by)
	var frac_z: float = pos.z - float(bz)
	var open_nx: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx - 1, by, bz))
	)
	var open_px: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx + 1, by, bz))
	)
	var open_ny: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx, by - 1, bz))
	)
	var open_py: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx, by + 1, bz))
	)
	var open_nz: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx, by, bz - 1))
	)
	var open_pz: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx, by, bz + 1))
	)
	var axis: int = -1
	var best: float = 9999.0
	if open_nx and frac_x < best:
		best = frac_x
		axis = 0
	if open_px and 1.0 - frac_x < best:
		best = 1.0 - frac_x
		axis = 1
	if open_ny and frac_y < best:
		best = frac_y
		axis = 2
	if open_py and 1.0 - frac_y < best:
		best = 1.0 - frac_y
		axis = 3
	if open_nz and frac_z < best:
		best = frac_z
		axis = 4
	if open_pz and 1.0 - frac_z < best:
		best = 1.0 - frac_z
		axis = 5
	if axis < 0:
		return
	# Vanilla: rand.nextFloat() * 0.2 + 0.1 = 0.1..0.3 blocks/tick. At
	# 20 tps that's 2..6 m/s along the chosen axis. Set velocity directly —
	# _apply_physics' horizontal drag and 0.98/tick-equivalent Y damping
	# then decay it at roughly vanilla's rate.
	var speed: float = randf_range(2.0, 6.0)
	match axis:
		0:
			_velocity.x = -speed
		1:
			_velocity.x = speed
		2:
			_velocity.y = -speed
		3:
			_velocity.y = speed
		4:
			_velocity.z = -speed
		5:
			_velocity.z = speed


# Returns true if the player's inventory has room for at least 1 of our
# item. False → the magnet (and the pickup attempt) skip this frame so
# the item just sits on the ground until something opens up.
func _player_can_accept() -> bool:
	if _player == null or not "inventory" in _player:
		return false
	# Vanilla Alpha eo.b(eb): pickup test runs in the entity's onCollideWith,
	# but the dead EntityPlayer's hitbox is removed via setEntityDead before
	# the next tick — so a dead player physically can't trigger the collision
	# and re-absorb their own loot. We don't remove the body on death (the
	# death screen freezes input while the body stays put), so gate explicitly
	# on health: a corpse can't pick up items.
	if "health" in _player and int(_player.get("health")) <= 0:
		return false
	var inv: Inventory = _player.get("inventory") as Inventory
	if inv == null:
		return false
	return inv.can_accept(item_id, 1)
