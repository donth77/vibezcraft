class_name Boat
extends CharacterBody3D

# Vanilla MC Alpha 1.2.6 EntityBoat (vendor/alpha-1.2.6-src/src/dp.java).
# Floats on water, the player right-clicks an empty boat to mount,
# sneak/jump to dismount, WASD to paddle.
#
# Vanilla refs:
#   dp.java::e_()  — per-tick physics (buoyancy, thrust, drag, auto-yaw)
#   dp.java::j_()  — passenger seat positioning
#   nv.java        — ItemBoat (id 333), right-click water → spawn
#   da.java        — RenderBoat (visual model)
#
# Shipped: placement, mount/dismount, paddle physics (buoyancy + drag
# + auto-yaw + bump), vanilla-dimension open-hull mesh textured with
# the pack's entity boat skin. Not yet: collision damage + plank/stick
# drops, EntitySave round-trip, paddle visuals (vanilla rocking arms).

# Vanilla model dimensions (cv.java ModelBoat — boxes in 1/16 m units):
#   floor:  24 × 4  × 16 vanilla units = 1.5 × 0.25 × 1.0 m
#   walls:  20 × 6  × 2  vanilla units = 1.25 × 0.375 × 0.125 m (each ×4)
#   total visible height = floor 0.25 m + walls 0.375 m = 0.625 m
# dp.java::a(1.5f, 0.6f) sets the COLLISION box to width=1.5 height=0.6,
# so the AABB is square (1.5 × 0.6 × 1.5) while the visual is narrower.
# We use the visual width for HULL_WIDTH so the mesh + collider match.
# Explicit preload — GUT loads test scripts before class_name registers
# the global EntityLighting identifier, so bare `EntityLighting.foo()`
# fails to parse in tests with "Identifier ... not declared in the
# current scope". Preload via const lets us call the same static
# methods through the preloaded GDScript instead.
const _ENTITY_LIGHTING: GDScript = preload("res://scripts/world/entity_lighting.gd")

const HULL_LENGTH: float = 1.5
const HULL_WIDTH: float = 1.0
const HULL_HEIGHT: float = 0.625
# Walls are 0.375 m tall on top of the 0.25 m floor. Used by the mesh
# builder to inset walls onto the floor surface.
const FLOOR_THICKNESS: float = 0.25
const WALL_HEIGHT: float = 0.375
const WALL_THICKNESS: float = 0.125  # 2 vanilla units

# Vanilla constants from dp.java::e_(), converted from per-tick to
# per-second by ×20 (TPS). Vanilla source comments inline for each.

# `this.aA += 0.04f * d15` where d15 = 2*water_pct - 1, ranges -1..+1.
# In water (d15=+1): +0.04 m/tick² Y accel ≈ +16 m/s² (positive buoyancy).
# In air (d15=-1):   -0.04 m/tick² ≈ -16 m/s² (gravity-like, but weaker
# than vanilla terrain gravity 0.08/tick = -32 m/s²).
const BUOY_ACCEL: float = 16.0  # m/s² magnitude

# `if (this.az < -d4 = 0.4)` — vanilla caps horizontal velocity at
# 0.4 m/tick = 8 m/s. Reduced to 5 m/s as a deliberate non-vanilla
# tweak after user feedback that 8 m/s felt too fast for a paddle
# boat. Easy to bump back to 8.0 for full vanilla parity.
const MAX_HORIZ_PER_AXIS: float = 5.0  # m/s

# `this.az *= 0.99` and `this.aA *= 0.95` per tick when above-water /
# no rider. Per-second: 0.99^20 ≈ 0.82, 0.95^20 ≈ 0.36.
const DRAG_HORIZ_PER_TICK: float = 0.99
const DRAG_VERT_PER_TICK: float = 0.95

# `if (this.aH) this.az *= 0.5` — horizontal speed halves on floor /
# ceiling bump (vanilla's "scrape against bank" feel).
const BUMP_DAMP: float = 0.5

# Yaw smoothing — vanilla `if (d2 > 20.0) d2 = 20.0;` clamps the
# per-tick yaw delta to ±20° = 400°/s. With our new "target = rider
# facing" auto-yaw (instead of motion direction), the boat rotates
# fast enough to track the player's view without visible lag — same
# perceived behavior as vanilla. Earlier 3.0 rad/s value was too slow
# once the target switched from motion vector to rider facing; the
# boat felt like it dragged behind every camera turn.
const MAX_YAW_RATE: float = 5.0  # rad/s (~286°/s)
# Motion threshold below which auto-yaw doesn't fire. Vanilla
# `d3*d3 + d23*d23 > 0.001` where d3/d23 are per-TICK position
# deltas (m/tick). Sqrt(0.001) = 0.0316 m/tick = **0.63 m/s** velocity
# threshold; squared in m/s is 0.4. Earlier value (0.001 in m/s
# units) let auto-yaw fire at any motion ≥ 0.03 m/s — boat turned
# the moment you nudged it, which is exactly why it "turns too
# easily" compared to vanilla.
const MIN_MOTION_SQ_FOR_YAW: float = 0.4

# Rider thrust — vanilla math gives ~8 m/s² (`rider.az * 0.2 = 0.02
# m/tick²` integrated to per-second). Dropped to 5 m/s² so accel scales
# with the lowered MAX_HORIZ_PER_AXIS (also 5) — paddle still reaches
# top speed in ~1 s of held input, just at a slower top speed.
const RIDER_THRUST: float = 5.0  # m/s² accel for full forward input

# Vanilla `BoatHealth` — 4 HP max. Damage on collision lands in stage 3.
const MAX_HEALTH: int = 4

# Seat offset (player position relative to boat origin). Player.set_mount
# locks the model into the seated pose: both legs rotate ~80° forward at
# the hip, so the rider's "lowest point" is the hip joint (center − 0.15
# per character_model.gd line 400), not the feet. To sit the hip on the
# boat floor interior:
#   floor_top  = FLOOR_THICKNESS = 0.25
#   center     = floor_top + 0.15 = 0.40
# Camera (center + 0.7) lands at boat + 1.10 ≈ 1 m above water — head
# clears the gunwale (0.625) by ~0.5 m, matches vanilla seated framing.
const _SEAT_OFFSET: Vector3 = Vector3(0, 0.40, 0)

var health: int = MAX_HEALTH
# Set by interaction.gd at spawn time so the boat knows which player
# initiated the placement (used for the first mount + drop targeting).
var _owner_player: Node3D = null
# Set when the player mounts. null == empty boat.
var _rider: Node3D = null
# Cached reference to ChunkManager so _physics_process can sample
# water cells without walking the scene tree each tick. Resolved in
# _ready via get_tree().root.
var _chunk_manager: Node = null
# Root for all visual mesh pieces. Wraps the 5 hull boxes so the
# damage-rock animation can rotate the whole hull together without
# affecting the collider.
var _visual_root: Node3D = null
# Damage-rock state — vanilla `this.b` (timeBeforeHit / "rock") and
# `this.c` (damageTime). On hit: b flips sign so the boat oscillates;
# c sets the magnitude. Both decay back to neutral each tick. See
# `da.java`: rotation_x = sign(b) * b² * max(a,0) / 10 * c.
var _damage_rock: float = 0.0
var _damage_time: float = 0.0
# Tracks the previous frame's water-contact state so we can detect
# the air→water transition and fire a splash SFX. Vanilla `dp.java`
# uses the same edge to trigger the splash particles (line 197).
var _was_touching_water: bool = false
# Cached Player node for the soft-push proximity check. Set in
# _ready; nullable in case the boat outlives the player or spawns
# before the Player node exists.
var _player_ref: Node3D = null
var _floor_mat: StandardMaterial3D = null
var _wall_mat: StandardMaterial3D = null
var _last_light_brightness: float = -1.0


func setup(spawn_pos: Vector3, yaw: float, owner: Node3D) -> void:
	global_position = spawn_pos
	rotation.y = yaw
	_owner_player = owner
	# Drop-in splash: kick the boat downward on placement so it
	# overshoots the equilibrium and bobs visibly before settling.
	# Vanilla spawns boats slightly above the water and lets gravity
	# pull them in; we approximate by adding an initial v_y instead of
	# adjusting the spawn cell (safer — no chance of spawning in the
	# wrong cell when the click lands near a shoreline).
	velocity = Vector3(0, -3.0, 0)


func _ready() -> void:
	# Layer 2 = selection-only so the player's pickup/right-click
	# raycast (mask 0b11) hits the boat for mount/break, while the
	# player's body (mask 0b01) walks straight through (we don't want
	# the player body to push the boat or vice versa).
	collision_layer = 0b10
	# Mask layer 1 = terrain so move_and_slide() bumps off the ground
	# instead of dropping us through the world. Without this the boat
	# free-falls into the void as soon as buoyancy goes negative
	# (above water). Vanilla EntityBoat collides with terrain too.
	collision_mask = 0b01
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	_player_ref = get_tree().get_root().find_child("Player", true, false) as Node3D
	_build_collider()
	_build_visual_mesh()


func _build_collider() -> void:
	# Vanilla dp.java::a(1.5f, 0.6f) sets EntityBoat collision to
	# width=1.5 height=0.6 — square AABB 1.5 × 0.6 × 1.5 m. Boat is on
	# the selection-only layer so the player raycast (mask 0b11) hits
	# the boat for mount but the player body (mask 0b01) walks through.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(HULL_LENGTH, 0.6, HULL_LENGTH)
	shape.shape = box
	shape.position = Vector3(0, 0.3, 0)
	add_child(shape)


func _build_visual_mesh() -> void:
	# Original 5-piece BoxMesh hull (floor + 4 walls), the layout that
	# read as the correct boat shape in earlier testing. Walls sit on
	# top of the floor; short ends span the FULL hull width, long walls
	# are inset by WALL_THICKNESS on each X end so the short ends own
	# the corner geometry. Matches vanilla cv.java ModelBoat layout.
	#
	# Texture is the vanilla 64×32 boat.png cropped via the material's
	# uv1_offset/uv1_scale instead of AtlasTexture. BoxMesh emits face
	# UVs in [0, 1] per face; uv1 transform remaps that range to the
	# vanilla floor strip or wall strip sub-rect. Since the transform
	# only scales-down + offsets, every sample stays inside the target
	# region — no out-of-region pixels reading as black (the AtlasTexture
	# splotch bug).
	_visual_root = Node3D.new()
	add_child(_visual_root)
	# Rotate the hull 90° so its length axis (built along local +X for
	# math convenience) aligns with Godot's default forward (-Z). When
	# auto-yaw sets boat.rotation.y = rider.rotation.y, the player's
	# forward then maps to the boat's front, not its side.
	_visual_root.rotation.y = -PI / 2.0
	var boat_tex: Texture2D = _load_boat_texture()
	# Vanilla skin regions (in 64×32 pixel coords, normalized to UV).
	# Floor strip (0,8)→(24,12) = 24 × 4 pixels of horizontal planks.
	# Wall strip (0,0)→(20,6) = 20 × 6 pixels of vertical planks.
	var floor_offset := Vector3(0.0, 8.0 / 32.0, 0.0)
	var floor_scale := Vector3(24.0 / 64.0, 4.0 / 32.0, 1.0)
	var wall_offset := Vector3(0.0, 0.0, 0.0)
	var wall_scale := Vector3(20.0 / 64.0, 6.0 / 32.0, 1.0)
	_floor_mat = _make_boat_material(boat_tex)
	_floor_mat.uv1_offset = floor_offset
	_floor_mat.uv1_scale = floor_scale
	_wall_mat = _make_boat_material(boat_tex)
	_wall_mat.uv1_offset = wall_offset
	_wall_mat.uv1_scale = wall_scale
	# Floor slab — full hull footprint, sits with its bottom at y=0.
	var floor_mi := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(HULL_LENGTH, FLOOR_THICKNESS, HULL_WIDTH)
	floor_mi.mesh = floor_mesh
	floor_mi.position = Vector3(0, FLOOR_THICKNESS * 0.5, 0)
	floor_mi.material_override = _floor_mat
	_visual_root.add_child(floor_mi)
	# Long sides (along local X = boat's length) — inset by
	# WALL_THICKNESS so short ends seal the corners.
	var inner_len: float = HULL_LENGTH - 2.0 * WALL_THICKNESS
	var wall_y: float = FLOOR_THICKNESS + WALL_HEIGHT * 0.5
	for sz: float in [
		HULL_WIDTH * 0.5 - WALL_THICKNESS * 0.5, -(HULL_WIDTH * 0.5 - WALL_THICKNESS * 0.5)
	]:
		var wall := MeshInstance3D.new()
		var wall_mesh := BoxMesh.new()
		wall_mesh.size = Vector3(inner_len, WALL_HEIGHT, WALL_THICKNESS)
		wall.mesh = wall_mesh
		wall.position = Vector3(0, wall_y, sz)
		wall.material_override = _wall_mat
		_visual_root.add_child(wall)
	# Short ends (along local Z = boat's width) — span the full width,
	# owning the corner geometry.
	for sx: float in [
		HULL_LENGTH * 0.5 - WALL_THICKNESS * 0.5, -(HULL_LENGTH * 0.5 - WALL_THICKNESS * 0.5)
	]:
		var wall := MeshInstance3D.new()
		var wall_mesh := BoxMesh.new()
		wall_mesh.size = Vector3(WALL_THICKNESS, WALL_HEIGHT, HULL_WIDTH)
		wall.mesh = wall_mesh
		wall.position = Vector3(sx, wall_y, 0)
		wall.material_override = _wall_mat
		_visual_root.add_child(wall)


# Kept for reference / future use — one continuous mesh approach. Not
# currently called; superseded by the 5-piece BoxMesh layout above.
func _build_hull_mesh() -> ArrayMesh:
	var hx: float = HULL_WIDTH * 0.5
	var hz: float = HULL_LENGTH * 0.5
	var ix: float = hx - WALL_THICKNESS
	var iz: float = hz - WALL_THICKNESS
	var y_bot: float = 0.0
	var y_floor: float = FLOOR_THICKNESS
	var y_top: float = HULL_HEIGHT
	var floor_uv := Rect2(0.0, 8.0 / 32.0, 24.0 / 64.0, 4.0 / 32.0)
	var wall_uv := Rect2(0.0, 0.0, 20.0 / 64.0, 6.0 / 32.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Floor bottom (visible from below, normal -Y).
	_emit_quad(
		st,
		Vector3(0, -1, 0),
		[
			Vector3(-hx, y_bot, -hz),
			Vector3(hx, y_bot, -hz),
			Vector3(hx, y_bot, hz),
			Vector3(-hx, y_bot, hz)
		],
		floor_uv
	)
	# Floor inner cavity (visible from inside, normal +Y). Recessed
	# to the inner-perimeter rectangle.
	_emit_quad(
		st,
		Vector3(0, 1, 0),
		[
			Vector3(-ix, y_floor, iz),
			Vector3(ix, y_floor, iz),
			Vector3(ix, y_floor, -iz),
			Vector3(-ix, y_floor, -iz)
		],
		floor_uv
	)
	# 4 outer wall faces.
	_emit_quad(
		st,
		Vector3(-1, 0, 0),
		[
			Vector3(-hx, y_bot, hz),
			Vector3(-hx, y_top, hz),
			Vector3(-hx, y_top, -hz),
			Vector3(-hx, y_bot, -hz)
		],
		wall_uv
	)
	_emit_quad(
		st,
		Vector3(1, 0, 0),
		[
			Vector3(hx, y_bot, -hz),
			Vector3(hx, y_top, -hz),
			Vector3(hx, y_top, hz),
			Vector3(hx, y_bot, hz)
		],
		wall_uv
	)
	_emit_quad(
		st,
		Vector3(0, 0, -1),
		[
			Vector3(-hx, y_bot, -hz),
			Vector3(-hx, y_top, -hz),
			Vector3(hx, y_top, -hz),
			Vector3(hx, y_bot, -hz)
		],
		wall_uv
	)
	_emit_quad(
		st,
		Vector3(0, 0, 1),
		[
			Vector3(hx, y_bot, hz),
			Vector3(hx, y_top, hz),
			Vector3(-hx, y_top, hz),
			Vector3(-hx, y_bot, hz)
		],
		wall_uv
	)
	# 4 inner wall faces — normals point INWARD so the texture shows
	# to a viewer inside the cavity.
	_emit_quad(
		st,
		Vector3(1, 0, 0),
		[
			Vector3(-ix, y_floor, -iz),
			Vector3(-ix, y_top, -iz),
			Vector3(-ix, y_top, iz),
			Vector3(-ix, y_floor, iz)
		],
		wall_uv
	)
	_emit_quad(
		st,
		Vector3(-1, 0, 0),
		[
			Vector3(ix, y_floor, iz),
			Vector3(ix, y_top, iz),
			Vector3(ix, y_top, -iz),
			Vector3(ix, y_floor, -iz)
		],
		wall_uv
	)
	_emit_quad(
		st,
		Vector3(0, 0, 1),
		[
			Vector3(ix, y_floor, -iz),
			Vector3(ix, y_top, -iz),
			Vector3(-ix, y_top, -iz),
			Vector3(-ix, y_floor, -iz)
		],
		wall_uv
	)
	_emit_quad(
		st,
		Vector3(0, 0, -1),
		[
			Vector3(-ix, y_floor, iz),
			Vector3(-ix, y_top, iz),
			Vector3(ix, y_top, iz),
			Vector3(ix, y_floor, iz)
		],
		wall_uv
	)
	# Gunwale top ring at Y = y_top — 4 strips forming a frame.
	_emit_quad(
		st,
		Vector3(0, 1, 0),
		[
			Vector3(-hx, y_top, -iz),
			Vector3(hx, y_top, -iz),
			Vector3(hx, y_top, -hz),
			Vector3(-hx, y_top, -hz)
		],
		wall_uv
	)
	_emit_quad(
		st,
		Vector3(0, 1, 0),
		[
			Vector3(-hx, y_top, hz),
			Vector3(hx, y_top, hz),
			Vector3(hx, y_top, iz),
			Vector3(-hx, y_top, iz)
		],
		wall_uv
	)
	_emit_quad(
		st,
		Vector3(0, 1, 0),
		[
			Vector3(-hx, y_top, iz),
			Vector3(-ix, y_top, iz),
			Vector3(-ix, y_top, -iz),
			Vector3(-hx, y_top, -iz)
		],
		wall_uv
	)
	_emit_quad(
		st,
		Vector3(0, 1, 0),
		[
			Vector3(ix, y_top, iz),
			Vector3(hx, y_top, iz),
			Vector3(hx, y_top, -iz),
			Vector3(ix, y_top, -iz)
		],
		wall_uv
	)
	return st.commit()


# Emit one quad (2 tris) with the given outward normal, 4 CCW-from-
# outside corner verts, and UVs mapping the corners of uv_rect.
func _emit_quad(st: SurfaceTool, n: Vector3, verts: Array, uv_rect: Rect2) -> void:
	var u0: float = uv_rect.position.x
	var v0: float = uv_rect.position.y
	var u1: float = uv_rect.position.x + uv_rect.size.x
	var v1: float = uv_rect.position.y + uv_rect.size.y
	var uvs: Array = [Vector2(u0, v1), Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1)]
	for tri_idx: int in [0, 1, 2, 0, 2, 3]:
		st.set_normal(n)
		st.set_uv(uvs[tri_idx])
		st.add_vertex(verts[tri_idx])


# Pack-aware boat skin loader. Falls back to the shared entity dir if
# the active pack doesn't ship one, then to null (mesh renders untextured
# wood-brown if no skin is found).
func _load_boat_texture() -> Texture2D:
	var pack_path := "res://assets/textures/entities/packs/%s/boat.png" % BlockAtlas.active_pack
	if ResourceLoader.exists(pack_path):
		return load(pack_path) as Texture2D
	var shared_path := "res://assets/textures/entities/boat.png"
	if ResourceLoader.exists(shared_path):
		return load(shared_path) as Texture2D
	return null


func _make_boat_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	if tex != null:
		mat.albedo_texture = tex
	else:
		mat.albedo_color = Color(0.62, 0.45, 0.27)
	return mat


# Called by interaction.gd::_try_right_click_boat when the player
# right-clicks the boat. Vanilla `dp.java::c(eb)` returns true and
# starts/stops the mount based on current state — empty boat mounts,
# same-player boat dismounts. Returns true if the click was consumed.
func right_click_with(_held_id: int, player: Node3D) -> bool:
	if _rider == player:
		dismount()
		return true
	if _rider != null:
		return false  # occupied by someone else
	mount(player)
	return true


# Mount the player onto the boat. Player's physics short-circuits via
# the existing Player.set_mount hook (pig uses the same path).
func mount(player: Node3D) -> void:
	if _rider != null:
		return
	_rider = player
	if player.has_method("set_mount"):
		player.set_mount(self)


# Drop the rider off. Called by Player when it sees sneak/jump while
# mounted (Player._physics_process drives this via the existing
# `_mounted_to.dismount()` call on sneak).
func dismount() -> void:
	if _rider == null:
		return
	var p: Node3D = _rider
	_rider = null
	if p != null and p.has_method("set_mount"):
		p.set_mount(null)
	# Pop the rider's capsule above the boat collider before they
	# re-engage physics. Player.set_mount re-enables collision in place,
	# and the seat position (boat + 0.4 in Y) leaves the player's
	# capsule (extends ±0.9 from center) overlapping the boat's 1.5×0.6
	# collider — on water they sink out freely, but on land the terrain
	# below blocks downward extraction and the player ends up stuck
	# inside the hull. boat.y + 1.7 puts the capsule bottom (0.9 below
	# center) just above the boat's top face at boat.y + 0.6, with a
	# small clearance for gravity to take over cleanly.
	if p != null:
		p.global_position = Vector3(
			p.global_position.x, global_position.y + 1.7, p.global_position.z
		)


# Left-click damage path. Vanilla EntityBoat (dp.java::f(lw, int))
# decrements health, then destroys + drops 3 planks + 2 sticks at HP
# <= 0. We dismount any current rider first so the player isn't left
# stuck inside a destroyed boat.
#
# Vanilla also kicks the damage-rock state — `this.b = -this.b;
# this.c = 10;` — so the boat visibly shakes after each hit. The
# sign flip on `b` is what makes the rock oscillate (rotate one way,
# next hit rotates the other) instead of accumulating in one direction.
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
	# Vanilla CraftingManager registers boat = 5 planks → 1 boat. On
	# break, vanilla drops 3 planks + 2 sticks (Bukkit nv.java::d()).
	var parent: Node = get_parent()
	if parent == null:
		return
	for _i in range(3):
		_spawn_drop(parent, Blocks.PLANKS)
	for _i in range(2):
		_spawn_drop(parent, Items.STICK)


# --- Persistence (EntitySave TYPE_BOAT) ---
#
# We persist enough state to reconstruct the boat after a save/load
# round-trip: world position, yaw, current velocity, health. Rider is
# NOT serialized — the player's mount state is rebuilt at runtime when
# they re-mount (or stays dismounted after reload, which matches how
# vanilla unloads passengers when chunks unload around a saved boat).


func to_save_dict() -> Dictionary:
	# `has_rider` triggers re-mount on load — without it, the player's
	# saved position (which is the seat = boat + 0.4 m) lands them
	# mid-air after PlayerSave restores them but before any boat is
	# spawned, and they free-fall through the void before the boat
	# arrives to catch them.
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
		# Defer one frame so the player node's _ready has finished and
		# the Player.set_mount hook is wired up. Without the defer the
		# call lands before Player's character_model exists and the
		# seated-pose toggle silently no-ops.
		call_deferred("_remount_saved_rider")


func _remount_saved_rider() -> void:
	if _rider != null:
		return
	var player: Node3D = get_tree().get_root().find_child("Player", true, false) as Node3D
	if player == null:
		return
	mount(player)


func _spawn_drop(parent: Node, item_id: int) -> void:
	var item := DroppedItem.new()
	parent.add_child(item)
	# Small jitter so drops scatter from the boat's center cell rather
	# than stacking on top of each other.
	var jitter := Vector3(randf_range(-0.2, 0.2), 0.3, randf_range(-0.2, 0.2))
	item.global_position = global_position + Vector3(0, 0.4, 0) + jitter
	item.setup(item_id)


# Per-tick physics — buoyancy + drag + rider thrust + auto-yaw + bump.
# Mirrors vanilla dp.java::e_() but on a per-second clock instead of
# vanilla's 20 Hz fixed tick.
func _physics_process(delta: float) -> void:
	# Analog water fraction — vanilla samples 5 vertical slices across
	# the hull and uses `(2 * water_pct - 1)` as the buoyancy sign.
	# We use 3 slices (bottom, mid, top) which is enough resolution to
	# get an EQUILIBRIUM near the surface (~1.5/3 in water = ~0) instead
	# of the binary ±1 that made the boat oscillate aggressively after
	# placement. d15 ∈ [-1, +1]: -1 = fully in air (fall), 0 = at
	# equilibrium half-submerged, +1 = fully under water (push up hard).
	var d15: float = _sample_water_fraction() * 2.0 - 1.0
	velocity.y += d15 * BUOY_ACCEL * delta
	# Rider thrust — vanilla reads `aq.az` (passenger velocity) at 0.2
	# scale. We read input directly: WASD in WORLD-space relative to
	# the player's look direction (so paddling forward = where the
	# player is looking), only when input isn't captured by a UI.
	#
	# Gate to water-touching only (d15 > -1, i.e. at least one slice
	# in water). Beached boats don't paddle — vanilla isn't strict
	# about this, but the "I drove my boat onto a sand dune" UX is bad.
	var touches_water: bool = d15 > -1.0
	# Air→water transition splash. Fires on placement (boat falls into
	# water from its drop-in spawn) and on any subsequent transition
	# from above-water to in-water (e.g. driving off a 1-block drop).
	if touches_water and not _was_touching_water:
		SFX.play_splash(velocity)
	_was_touching_water = touches_water
	if _rider != null and touches_water and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var thrust_dir: Vector3 = _read_rider_input()
		if thrust_dir.length_squared() > 0.001:
			velocity.x += thrust_dir.x * RIDER_THRUST * delta
			velocity.z += thrust_dir.z * RIDER_THRUST * delta
	# Soft push from a nearby player walking into the boat. Vanilla
	# `lw.java::e(lw)` does mutual collision push on AABB overlap; we
	# approximate with a horizontal-distance check — close enough at
	# entity scale. Skipped when the boat has a rider (you can't push
	# the boat you're riding) and when the boat is on water (water
	# context already allows free motion + the rider mounts anyway).
	if _rider == null:
		_apply_soft_push(delta)
	# Speed cap — vanilla caps each horizontal axis at 0.4/tick = 8 m/s.
	velocity.x = clampf(velocity.x, -MAX_HORIZ_PER_AXIS, MAX_HORIZ_PER_AXIS)
	velocity.z = clampf(velocity.z, -MAX_HORIZ_PER_AXIS, MAX_HORIZ_PER_AXIS)
	# Drag — pow() lets us match vanilla's per-tick decay regardless of
	# our frame delta. tick_scale = delta * 20 (ticks elapsed this frame).
	var tick_scale: float = delta * 20.0
	velocity.x *= pow(DRAG_HORIZ_PER_TICK, tick_scale)
	velocity.z *= pow(DRAG_HORIZ_PER_TICK, tick_scale)
	velocity.y *= pow(DRAG_VERT_PER_TICK, tick_scale)
	# Auto-yaw — vanilla turns toward motion direction with ±20°/tick
	# bound. Skipped at near-zero motion to avoid jitter.
	_apply_auto_yaw(delta)
	# Move + bump damp. CharacterBody3D's move_and_slide returns
	# collision info via get_slide_collision_count().
	var was_grounded: bool = is_on_floor()
	move_and_slide()
	if not was_grounded and is_on_floor():
		# Hit bottom — halve all components (vanilla `aH` branch).
		velocity *= BUMP_DAMP
	# Wall bump anti-flicker. When paddling into terrain, rider thrust
	# kept adding velocity into the wall every frame, and move_and_slide
	# kept pushing the boat back out — the boat visibly stuttered at
	# the shoreline. Slide cancels the wall-perpendicular component of
	# velocity so subsequent thrust either pushes along the wall or
	# pushes back into open water. CharacterBody3D already prevents
	# penetration; this just stops the per-frame visual jitter.
	if is_on_wall():
		velocity = velocity.slide(get_wall_normal())
	# Drive rider to seat position. Rider's own physics short-circuits
	# while _mounted_to != null (Player._physics_process check).
	if _rider != null:
		_rider.global_position = global_position + _SEAT_OFFSET
	# Damage rock decay + visual tilt. Vanilla `da.java`:
	#   GL11.glRotatef(..., 1.0f, 0.0f, 0.0f)
	# Rotates around the X axis. In our coord system the boat's length
	# is along X, so X-axis rotation = ROLL (side-to-side wobble), not
	# pitch. Initial implementation used .z (which is pitch with our
	# axis layout) and read as forward/back tipping — wrong.
	_update_damage_rock(delta)
	_update_entity_lighting()


# Sample sky+block light at the boat's cell and modulate the hull
# materials so it dims at night / under cover and brightens near torches.
# Mirrors the cart's lighting hook — same EntityLighting helper. Cached
# brightness skips redundant material writes (60-144×/s otherwise).
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


# Apply a small velocity push when a nearby player overlaps the boat's
# horizontal AABB. Vanilla-style soft collision — the boat scoots away
# from the player walking into it instead of standing as an impenetrable
# wall. Push magnitude scales with overlap distance so a glancing brush
# barely moves it while a head-on shove gets the boat moving.
func _apply_soft_push(delta: float) -> void:
	if _player_ref == null:
		return
	var dx: float = _player_ref.global_position.x - global_position.x
	var dz: float = _player_ref.global_position.z - global_position.z
	# Push radius = boat half-width (0.75 m for the 1.5 m square AABB)
	# + player capsule radius (~0.3 m) + small buffer.
	var push_radius: float = HULL_LENGTH * 0.5 + 0.35
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist >= push_radius or dist < 0.001:
		return
	# Push the boat AWAY from the player. 4 m/s² peak acceleration when
	# the player is right at the boat's edge, scaling linearly to 0 at
	# push_radius — gentle enough to feel like a nudge, not a launch.
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
		_damage_time = maxf(0.0, _damage_time - delta * 20.0)  # 1 unit / tick
	if absf(_damage_rock) > 0.001:
		# Vanilla decays `b` by sign-toward-0 each tick. Per-second decay
		# 0.85^20 ≈ 0.04 of original — visible wobble persists ~1 second.
		_damage_rock *= pow(0.85, delta * 20.0)
		_visual_root.rotation.x = _damage_rock * 0.4
	elif _visual_root.rotation.x != 0.0:
		_damage_rock = 0.0
		_visual_root.rotation.x = 0.0


# Read the rider's WASD into a world-space horizontal unit vector.
# Forward = rider's look direction (XZ-projected). Strafe = rider's
# right vector. Returns a unit-length Vector3 with y=0 (or ZERO if no
# input).
func _read_rider_input() -> Vector3:
	var input := Vector3.ZERO
	if _rider == null:
		return input
	# Rider's body yaw (player.rotation.y) — XZ forward + right vectors.
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


# Turn the boat toward its horizontal motion direction with the same
# clamped per-tick step vanilla uses (dp.java lines 222-240).
func _apply_auto_yaw(delta: float) -> void:
	# Mounted: target the rider's facing instead of motion direction.
	# Vanilla effectively does the same — the rider's yaw drives motion
	# (boat picks up rider velocity), and vanilla's ~400°/s yaw rate is
	# fast enough that the boat aligns with rider facing within ~250 ms,
	# so the player perceives the boat as "always aligned with where I
	# look." Targeting rider facing directly removes the motion-vector
	# lag — pressing W with the camera straight just goes straight.
	#
	# Empty (no rider): fall back to vanilla's motion-direction target so
	# a coasting boat with no driver still aligns with its drift.
	var target_yaw: float = rotation.y
	if _rider != null:
		target_yaw = _rider.rotation.y
	else:
		var horiz_sq: float = velocity.x * velocity.x + velocity.z * velocity.z
		if horiz_sq < MIN_MOTION_SQ_FOR_YAW:
			return
		# Vanilla atan2(dz, dx) gives 0 along +X, CCW; Godot rotation.y
		# is opposite-handed → negate components.
		target_yaw = atan2(-velocity.x, -velocity.z)
	var diff: float = target_yaw - rotation.y
	# Shortest-path delta in [-π, π].
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	# Clamp per-frame turn to MAX_YAW_RATE × delta.
	var max_step: float = MAX_YAW_RATE * delta
	diff = clampf(diff, -max_step, max_step)
	rotation.y += diff


# Sample 3 vertical slices across the hull and return the fraction
# (0.0 .. 1.0) of slices whose containing cell is water. Vanilla
# samples 5 slices and uses the same fraction as the buoyancy modulator;
# 3 is enough resolution to get an equilibrium near the water surface
# without the binary-check oscillation, and saves a couple get_world_block
# calls per physics tick.
#
# Slice positions shifted DOWN by 0.2 m relative to a hull-spanning
# layout so equilibrium lands with the floor's exterior bottom roughly
# 0.04 m ABOVE the visible water surface (N + 0.875). Earlier layout
# (0, 0.3125, 0.594) put equilibrium at boat.y ≈ N + 0.6875, which
# left the floor's side faces straddling the water surface line at
# N + 0.875 — water mesh visibly clipped through the hull from inside.
func _sample_water_fraction() -> float:
	if _chunk_manager == null:
		return 0.0
	var ys: Array = [-0.2, HULL_HEIGHT * 0.5 - 0.2, HULL_HEIGHT * 0.95 - 0.2]
	var hits: int = 0
	for dy: float in ys:
		var cell := Vector3i(
			int(floor(global_position.x)),
			int(floor(global_position.y + dy)),
			int(floor(global_position.z))
		)
		var id: int = _chunk_manager.get_world_block(cell)
		if id == Blocks.WATER_STILL or id == Blocks.WATER_FLOWING:
			hits += 1
	return float(hits) / float(ys.size())
