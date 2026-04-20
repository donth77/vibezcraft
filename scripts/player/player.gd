# gdlint: disable=max-file-lines
extends CharacterBody3D

signal health_changed(current: int, maximum: int)
signal damaged(amount: int, source: String)
signal died

const WALK_SPEED: float = 4.317
const SNEAK_SPEED: float = 1.295
const JUMP_VELOCITY: float = 8.0
const GRAVITY: float = -32.0
const MOUSE_SENSITIVITY: float = 0.002
const PITCH_LIMIT_DEG: float = 89.0

# Vanilla MC Alpha player health — 20 half-hearts (10 full hearts on the
# HUD). Reaches 0 → death → instant respawn (no death screen yet).
const MAX_HEALTH: int = 20
# Vanilla fall-damage formula: damage = max(0, fall_blocks - 3). Jumping
# 3 blocks or less never hurts; falling 10 blocks does 7 damage, etc.
const FALL_DAMAGE_SAFE_BLOCKS: float = 3.0
# Vanilla EntityLivingBase.maxHurtResistantTime — 20 ticks at 20 TPS = 1.0s
# of post-hit grace where most subsequent damage is dropped. (Vanilla
# allows STRONGER overlapping damage to still land within this window;
# we keep it simple and fully ignore everything for now.)
const DAMAGE_COOLDOWN_SEC: float = 1.0
# Vanilla Alpha health regen (pre-Beta 1.8 hunger system): heals 1 HP
# every 4 seconds while below max and not currently dying. No food
# gating — just a constant background heal rate.
const HEALTH_REGEN_INTERVAL_SEC: float = 4.0

# Damage types — affects whether armor reduction kicks in. Vanilla Alpha
# armor DOES NOT reduce fall damage (DamageSource.FALL.ignoresArmor),
# unlike mob damage which it does reduce.
const DAMAGE_GENERIC: String = "generic"
const DAMAGE_FALL: String = "fall"

const _DEBUG_FILL_BLOCKS: Array = [
	Blocks.STONE,
	Blocks.COBBLESTONE,
	Blocks.DIRT,
	Blocks.GRASS,
	Blocks.SAND,
	Blocks.GRAVEL,
	Blocks.LOG,
	Blocks.PLANKS,
	Blocks.LEAVES,
]

# Smelting / tool-tier starter pack — ALL raw ores + fuel (for furnace
# path) PLUS already-smelted ingots + diamond (for direct tool crafting
# without having to smelt every time). 16 of each. Bound to KEY_K.
const _DEBUG_FILL_SMELT: Array = [
	Blocks.COAL_ORE,
	Blocks.IRON_ORE,
	Blocks.GOLD_ORE,
	Blocks.DIAMOND_ORE,
	Blocks.COBBLESTONE,
	Items.COAL,
	Items.IRON_INGOT,
	Items.GOLD_INGOT,
	Items.DIAMOND,
]

# Every tool we've built. As new tools come online (stone/iron/diamond
# pick, axe, shovel, sword), append the IDs here.
const _DEBUG_FILL_TOOLS: Array = [
	Items.WOODEN_PICKAXE,
	Items.WOODEN_AXE,
	Items.WOODEN_SHOVEL,
	Items.WOODEN_SWORD,
	Items.STONE_PICKAXE,
	Items.STONE_AXE,
	Items.STONE_SHOVEL,
	Items.STONE_SWORD,
	Items.IRON_PICKAXE,
	Items.IRON_AXE,
	Items.IRON_SHOVEL,
	Items.IRON_SWORD,
	Items.DIAMOND_PICKAXE,
	Items.DIAMOND_AXE,
	Items.DIAMOND_SHOVEL,
	Items.DIAMOND_SWORD,
	Items.GOLD_PICKAXE,
	Items.GOLD_AXE,
	Items.GOLD_SHOVEL,
	Items.GOLD_SWORD,
	Items.IRON_HELMET,
	Items.IRON_CHESTPLATE,
	Items.IRON_LEGGINGS,
	Items.IRON_BOOTS,
	Items.DIAMOND_HELMET,
	Items.DIAMOND_CHESTPLATE,
	Items.DIAMOND_LEGGINGS,
	Items.DIAMOND_BOOTS,
	# Hoe is Beta 1.6 — kept here as a debug-only grant. The recipe is
	# disabled so normal players can't craft one, but devs can press J in
	# debug mode to test the till logic.
	Items.WOODEN_HOE,
]
const _CAM_FIRST_PERSON: Vector3 = Vector3(0, 0.7, 0)
const _CAM_THIRD_BACK: Vector3 = Vector3(0, 1.0, 3.5)
const _CAM_THIRD_FRONT: Vector3 = Vector3(0, 1.0, -3.5)

# Vanilla MC F5 cycles: first → third-back → third-front → first.
const PERSPECTIVE_FIRST: int = 0
const PERSPECTIVE_THIRD_BACK: int = 1
const PERSPECTIVE_THIRD_FRONT: int = 2
const PERSPECTIVE_COUNT: int = 3

# Vanilla MC first-person swing transform. The dominant motion is a Y-axis
# wrist twist (signed for our right-handed hand-on-the-right-of-screen pose),
# combined with three translation curves that peak at different times in the
# 0..1 swing cycle: X (toward screen center) peaks early, Z (forward) at mid,
# Y (slight up) peaks late. Reproduces the recognizable punch arc.
const _FP_SWING_TRANSLATE_SCALE: float = 0.5  # screen-space units

# Footstep cadence — vanilla MC fires a step sound roughly every 1.6 blocks
# of horizontal travel (and only when grounded). Sneaking is naturally
# slower so the same distance gives a longer interval, no special-case.
const _STEP_INTERVAL_M: float = 1.6
const _FP_SWING_Y_TWIST_DEG: float = -15.0  # subtle wrist hint; vanilla 70° over-rotates our pose
const _FP_SWING_X_TILT_DEG: float = -25.0  # tilt-down at peak — main rotation contribution

# Held-block rest pose in camera-local space — vanilla MC puts the cube in the
# lower-right of the view, tilted to show three faces.
const _HELD_BLOCK_POSITION: Vector3 = Vector3(0.5, -0.45, -0.65)
const _HELD_BLOCK_ROTATION: Vector3 = Vector3(-0.1745, -0.7854, 0.0)  # (-10°, -45°, 0°)
const _HELD_BLOCK_SIZE: float = 0.42

# Held-tool rest pose. Vanilla MC uses +45° Y but at our render scale that
# turns the pickaxe sideways too much — flat face barely visible. Trim to
# +25° so the flat side mostly faces the camera (like vanilla looks at
# typical GUI scales) while still showing some depth on one edge.
# Third-person held block — parented to the right arm so it swings with the
# mining animation. Position is at the wrist (arm hangs to y≈-0.75).
const _TP_HELD_BLOCK_POSITION: Vector3 = Vector3(0, -0.78, -0.18)
const _TP_HELD_BLOCK_ROTATION: Vector3 = Vector3(0, -0.4363, 0)  # (0°, -25°, 0°)
const _TP_HELD_BLOCK_SIZE: float = 0.30

@export var sneak_toggle: bool = false  # false = hold to sneak, true = press to toggle

var inventory: Inventory
var creative_mode: bool = false
var perspective: int = PERSPECTIVE_FIRST
var is_mining: bool = false  # set by Interaction; drives mining-swing animation
var health: int = MAX_HEALTH

# Fall tracking — _fall_peak_y is the HIGHEST Y reached during the
# current air period. On landing we compute (peak - land_y) to get the
# actual fall distance regardless of jumps bumping the start upward.
var _fall_peak_y: float = 0.0
var _was_on_floor: bool = false
# Set true on spawn / respawn so the very first landing doesn't deal
# fall damage. Vanilla-equivalent: EntityPlayer.fallDistance is reset
# on respawn AND the player isn't considered "falling" until they leave
# the ground for the first time post-spawn. Without this we'd take 37
# damage from the initial drop at (8, 100, 8) and respawn-loop forever.
var _fall_immune_next_landing: bool = true
# Counts down each physics tick after a successful damage hit. While > 0,
# `take_damage` returns early — vanilla's hurtResistantTime behavior so
# the player can't be ground to death by mob ticks landing on the same
# frame.
var _damage_cooldown_remaining: float = 0.0
# Counts up while below max HP. When >= HEALTH_REGEN_INTERVAL_SEC, +1 HP
# and resets. Cleared on death; doesn't tick while at max.
var _regen_accum: float = 0.0

# Tunable at runtime via the FP Tool Tuner panel. These defaults are the
# user's hand-tuned best preset (closest match to vanilla MC) — keep in
# sync with _FP_BEST_PRESET in tool_tuner.gd.
var _held_tool_position: Vector3 = Vector3(0.390, -0.630, -0.640)
var _held_tool_rotation: Vector3 = Vector3(0.0, deg_to_rad(9.0), 0.0)
var _held_tool_pixel_size: float = 0.036

# Per-axis swing magnitudes (degrees at peak).
#   X = pitch (chop down/forward), Y = yaw (twist), Z = roll (spin around shaft)
var _tool_swing_x_deg: float = -55.0
var _tool_swing_y_deg: float = 0.0
var _tool_swing_z_deg: float = 0.0

# Forward thrust on top of rotation. Pure rotation reads as "flipping
# toward the player" even when the math says the head moves forward;
# this translation makes the in/out motion physically obvious.
var _tool_swing_thrust_fwd: float = 0.08

# When true, _apply_tool_swing uses the verbatim Beta 1.7.3 vanilla
# ItemRenderer curves instead of our hand-tuned amplitudes. Toggled from
# the FP Tool Tuner panel.
var _use_vanilla_swing: bool = true

# Per-mode vanilla orient flag. When true, the orient node applies the
# vanilla "renderItem" inner sprite tilt: +50° Y then -25° Z. This makes
# the held tool look like a tool (head forward-up-right, handle rolled
# -25°) instead of a flat front-facing sprite. FP off by default because
# the user's hand-tuned FP preset already encodes the desired orientation
# in the rest-pose sliders; TP on because the third-person arm needs the
# vanilla tilt to read correctly. Toggle button targets the active mode.
var _use_vanilla_orient_fp: bool = false
var _use_vanilla_orient_tp: bool = true

# Third-person held-tool rest pose (parented to the arm_r node, so
# coordinates are arm-local). Tunable from the FP Tool Tuner panel after
# switching it to TP mode.
var _tp_held_tool_position: Vector3 = Vector3(0, -0.75, -0.15)
var _tp_held_tool_rotation: Vector3 = Vector3(deg_to_rad(-20), deg_to_rad(35), 0)
var _tp_held_tool_pixel_size: float = 0.035

# "fp" or "tp" — which value set the tuner sliders read/write.
var _tuner_mode: String = "fp"

var _is_sneaking: bool = false
var _step_distance: float = 0.0  # accumulates horizontal travel between footsteps
var _character_model: Node3D
var _fp_hand: Node3D  # first-person right hand attached to camera
var _fp_hand_base_position: Vector3 = Vector3.ZERO
var _fp_hand_base_rotation: Vector3 = Vector3.ZERO
var _held_block: MeshInstance3D  # FP cube shown in lieu of the hand when holding a block
var _held_block_tp: MeshInstance3D  # third-person cube parented to arm_r
var _held_tool: MeshInstance3D  # FP voxel-extruded 3D tool mesh (vanilla ItemModelGenerator)
var _held_tool_pivot: Node3D  # parent of _held_tool — sits at the fist; rotation pivots here
var _held_tool_orient: Node3D  # carries the vanilla 50°Y / -25°Z inner sprite tilt
var _held_tool_tp: MeshInstance3D  # third-person tool mesh, parented to arm_r
var _held_tool_tp_pivot: Node3D  # parent of _held_tool_tp at the wrist (so rotation pivots there)
var _held_tool_tp_orient: Node3D  # TP orient node (mirrors _held_tool_orient role)
var _held_block_id: int = 0  # 0 = AIR = nothing held; show the hand instead
var _tool_tuner: Control  # debug-only slider panel; toggled with T

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	inventory = Inventory.new()
	inventory.changed.connect(_update_held_item)
	inventory.changed.connect(_update_armor_overlay)
	var hotbar: Control = get_node_or_null("Crosshair/Hotbar")
	if hotbar != null:
		hotbar.bind(inventory)
	var inv_screen: Control = get_node_or_null("Crosshair/InventoryScreen")
	if inv_screen != null:
		inv_screen.bind(inventory)
	var table_screen: Control = get_node_or_null("Crosshair/CraftingTableScreen")
	if table_screen != null:
		table_screen.bind(inventory)
	var furnace_screen: Control = get_node_or_null("Crosshair/FurnaceScreen")
	if furnace_screen != null:
		furnace_screen.bind(inventory)
	# Build the player character model (hidden in first person)
	var model_script: GDScript = load("res://scripts/player/character_model.gd")
	_character_model = model_script.new()
	add_child(_character_model)
	# FP tool tuner panel — hidden until T is pressed. Crosshair is a
	# CanvasLayer (not a Control), so we use the generic Node type here.
	var crosshair: Node = get_node_or_null("Crosshair")
	if crosshair != null:
		var tuner_script: GDScript = load("res://scripts/ui/tool_tuner.gd")
		_tool_tuner = tuner_script.new()
		_tool_tuner.setup(self)
		crosshair.add_child(_tool_tuner)
		# Top-right perf/world stats — visible while debug mode is on.
		var stats_script: GDScript = load("res://scripts/ui/debug_stats.gd")
		var stats: Control = stats_script.new()
		crosshair.add_child(stats)
	# First-person hand (visible only in 1st person; attached to camera so
	# it stays anchored in the lower-right corner of the view).
	_build_fp_hand()
	_update_held_item()  # set initial hand-vs-block visibility
	_update_armor_overlay()
	_apply_perspective()
	_update_debug_label()


func _build_fp_hand() -> void:
	if _character_model == null or not _character_model.has_method("build_fp_arm"):
		return
	_fp_hand = _character_model.build_fp_arm()
	_camera.add_child(_fp_hand)
	# Lower-right of view, angled inward and slightly forward — vanilla MC
	# first-person arm position.
	_fp_hand_base_position = Vector3(0.42, -0.55, -0.70)
	_fp_hand_base_rotation = Vector3(deg_to_rad(-25), deg_to_rad(20), deg_to_rad(8))
	_fp_hand.position = _fp_hand_base_position
	_fp_hand.rotation = _fp_hand_base_rotation


# Vanilla MC: when the selected hotbar slot has a block, show that block in
# the lower-right of the view instead of the bare hand. Rebuilt on demand
# whenever the held id changes; same swing/punch animation drives it.
# Pushes the armor-slot item ids to both the world-space player model
# AND the inventory-preview model so the preview reflects what the player
# is actually wearing. Helmet = slot 36, chest = 37, legs = 38, feet = 39
# (see Inventory.ARMOR_START).
func _update_armor_overlay() -> void:
	if inventory == null:
		return
	var helmet: int = inventory.slots[Inventory.ARMOR_START].item_id
	var chest: int = inventory.slots[Inventory.ARMOR_START + 1].item_id
	var legs: int = inventory.slots[Inventory.ARMOR_START + 2].item_id
	var feet: int = inventory.slots[Inventory.ARMOR_START + 3].item_id
	if _character_model != null and _character_model.has_method("update_armor"):
		_character_model.update_armor(helmet, chest, legs, feet)
	# Mirror to the live inventory preview (offscreen viewport).
	var preview_model: Node3D = CharacterPreview.get_model()
	if preview_model != null and preview_model.has_method("update_armor"):
		preview_model.update_armor(helmet, chest, legs, feet)


func _update_held_item() -> void:
	if inventory == null:
		return
	var id: int = inventory.selected().item_id
	if id == _held_block_id:
		return
	_held_block_id = id
	# Tear down any existing held visual; we rebuild for the new id.
	if _held_block != null:
		_held_block.queue_free()
		_held_block = null
	if _held_block_tp != null:
		_held_block_tp.queue_free()
		_held_block_tp = null
	if _held_tool != null:
		_held_tool.queue_free()
		_held_tool = null
	if _held_tool_pivot != null:
		_held_tool_pivot.queue_free()
		_held_tool_pivot = null
	# orient is a child of pivot so queue_free above already disposes the
	# Node3D; just drop our reference to it.
	_held_tool_orient = null
	if _held_tool_tp != null:
		_held_tool_tp.queue_free()
		_held_tool_tp = null
	if _held_tool_tp_pivot != null:
		_held_tool_tp_pivot.queue_free()
		_held_tool_tp_pivot = null
	# TP orient is a child of TP pivot; queue_free above already disposed it.
	_held_tool_tp_orient = null
	if id != Blocks.AIR:
		# Block IDs live in [1..99]; non-block items (sticks, tools, coal,
		# ingots, diamond) start at Items.STICK = 100. Block-IDs get a 3D
		# cube held in the hand; everything else uses the sprite-extruded
		# mesh (vanilla MC's ItemModelGenerator path).
		if id >= Items.STICK:
			_build_held_tool(id)
		else:
			_build_held_block(id)
	_apply_held_visibility()
	# Mirror to the inventory preview — vanilla GuiInventory shows the
	# currently-held stack in the avatar's right hand.
	CharacterPreview.set_held_item(id)


func _build_held_block(id: int) -> void:
	_held_block = MeshInstance3D.new()
	_held_block.mesh = BlockMesh.get_cube_mesh(id, _HELD_BLOCK_SIZE)
	# Force the FP held block to draw on top of world geometry — same
	# fix as the FP hand. Without this it z-fights nearby blocks.
	_held_block.material_override = BlockAtlas.overlay_material()
	_held_block.position = _HELD_BLOCK_POSITION
	_held_block.rotation = _HELD_BLOCK_ROTATION
	_camera.add_child(_held_block)
	# TP block lives under the right arm so it inherits walking + mining swings.
	var arm_r: Node3D = null
	if _character_model != null:
		arm_r = _character_model.get("arm_r") as Node3D
	if arm_r != null:
		_held_block_tp = MeshInstance3D.new()
		_held_block_tp.mesh = BlockMesh.get_cube_mesh(id, _TP_HELD_BLOCK_SIZE)
		_held_block_tp.position = _TP_HELD_BLOCK_POSITION
		_held_block_tp.rotation = _TP_HELD_BLOCK_ROTATION
		arm_r.add_child(_held_block_tp)


# Vanilla MC voxel-extrudes the 16×16 item sprite into a 3D mesh — each
# opaque pixel becomes a thin voxel of THICKNESS depth (vanilla 1px out
# of 16, same proportion as our pixel_size scale). This gives held tools
# real visible chunkiness instead of looking like flat paper. The mesh
# is built in pixel units; we scale it down to world units here.
func _build_held_tool(id: int) -> void:
	var tex: Texture2D = ItemIcons.icon_for(id)
	if tex == null:
		print("[HeldTool] no texture for item id %d" % id)
		return
	# Pivot node sits at the FIST. Rotation pivots here, so the head arcs
	# forward while the handle stays in place — like vanilla MC's swing.
	# Without this, rotating the mesh around its center swung the handle
	# back toward the player (tilt-inward feel).
	_held_tool_pivot = Node3D.new()
	_held_tool_pivot.position = _held_tool_position
	_held_tool_pivot.rotation = _held_tool_rotation
	_camera.add_child(_held_tool_pivot)

	# Orient node carries the vanilla inner sprite tilt (50°Y, -25°Z).
	# Mesh sits inside orient so the tilt is part of the rest pose; the
	# outer pivot then handles the swing rotation around the fist.
	_held_tool_orient = Node3D.new()
	_apply_orient_to(_held_tool_orient, _use_vanilla_orient_fp)
	_held_tool_pivot.add_child(_held_tool_orient)

	_held_tool = MeshInstance3D.new()
	var mesh: ArrayMesh = SpriteExtruder.build(tex)
	_held_tool.mesh = mesh
	var ps: float = _held_tool_pixel_size
	_held_tool.scale = Vector3(ps, ps, ps)
	# Find the actual handle tip (bottom-most opaque pixel — for the pickaxe
	# that's the lower-left corner) and offset the mesh so THAT point lands
	# at the pivot origin. Without this, rotating around bounding-box center
	# made the handle visibly slide out of the fist as the head arced forward.
	var pivot_px: Vector2 = SpriteExtruder.get_handle_pivot_offset(tex)
	_held_tool.position = Vector3(-pivot_px.x * ps, -pivot_px.y * ps, 0)
	# Custom shader: textured + per-face Notch shading + depth_test_disabled
	# so the tool always draws on top of world geometry.
	var shader: Shader = load("res://shaders/held_item.gdshader") as Shader
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("item_texture", tex)
	mat.render_priority = 100
	_held_tool.material_override = mat
	_held_tool_orient.add_child(_held_tool)

	# Third-person variant — SAME voxel-extruded mesh, just smaller and
	# parented to the right arm so it inherits walking + mining swings.
	# (User reported the TP tool looked flat — same extruded mesh as FP,
	# so 3D-ness comes from the per-face shading; verifying the world
	# shader binds the texture correctly.)
	var arm_r: Node3D = null
	if _character_model != null:
		arm_r = _character_model.get("arm_r") as Node3D
	if arm_r != null:
		# TP tool — chunky 3D mesh held in the right fist. Wrapped in a
		# pivot Node3D so the tool rotation pivots at the wrist (handle
		# end), matching the FP architecture.
		# Pivot at the wrist, pulled slightly OUT to the side of the arm so
		# the pickaxe isn't buried inside the arm geometry. Upright pose
		# (head up, handle in fist) with a Y twist for 3D visibility.
		_held_tool_tp_pivot = Node3D.new()
		_held_tool_tp_pivot.position = _tp_held_tool_position
		_held_tool_tp_pivot.rotation = _tp_held_tool_rotation
		arm_r.add_child(_held_tool_tp_pivot)

		# TP orient node — same role as FP _held_tool_orient. Carries vanilla
		# 50°Y / -25°Z inner sprite tilt when the toggle is on.
		_held_tool_tp_orient = Node3D.new()
		_apply_orient_to(_held_tool_tp_orient, _use_vanilla_orient_tp)
		# Axe sprites are mirror-arranged vs pickaxe (head upper-LEFT
		# instead of upper-RIGHT), so the same orient transform points
		# the blade back at the player's face. Flip 180° around the
		# tool-local Y to swing the blade forward.
		if Items.tool_type(id) == Items.TOOL_TYPE_AXE:
			_held_tool_tp_orient.transform.basis = (
				_held_tool_tp_orient.transform.basis * Basis(Vector3.UP, deg_to_rad(180.0))
			)
		_held_tool_tp_pivot.add_child(_held_tool_tp_orient)

		_held_tool_tp = MeshInstance3D.new()
		_held_tool_tp.mesh = SpriteExtruder.build(tex)
		var tp_ps: float = _tp_held_tool_pixel_size
		# Non-tool loose items (coal, ingots, diamond) use a tighter scale
		# and skip the handle-pivot offset. Applying the handle pivot to a
		# compact item pulls it upward off the hand; centering + shrinking
		# keeps it nestled in the fist without clipping the arm mesh.
		if Items.is_tool_item(id):
			_held_tool_tp.scale = Vector3(tp_ps, tp_ps, tp_ps)
			var tp_pivot_px: Vector2 = SpriteExtruder.get_handle_pivot_offset(tex)
			_held_tool_tp.position = Vector3(-tp_pivot_px.x * tp_ps, -tp_pivot_px.y * tp_ps, 0)
		else:
			var loose_ps: float = tp_ps * 0.6
			_held_tool_tp.scale = Vector3(loose_ps, loose_ps, loose_ps)
			_held_tool_tp.position = Vector3.ZERO
		var tp_shader: Shader = load("res://shaders/held_item_world.gdshader") as Shader
		var tp_mat := ShaderMaterial.new()
		tp_mat.shader = tp_shader
		tp_mat.set_shader_parameter("item_texture", tex)
		_held_tool_tp.material_override = tp_mat
		_held_tool_tp_orient.add_child(_held_tool_tp)


# Vanilla renderItem inner sprite tilt — what makes a held tool look like
# a held tool instead of a flat playing card. Sets orient.basis to the
# composed rotation when `enabled` is true, identity otherwise.
func _apply_orient_to(orient: Node3D, enabled: bool) -> void:
	if orient == null:
		return
	if enabled:
		var b := Basis(Vector3.UP, deg_to_rad(50.0))
		b = b * Basis(Vector3(0, 0, 1), deg_to_rad(-25.0))
		orient.transform.basis = b
	else:
		orient.transform.basis = Basis.IDENTITY


# Re-applies the (possibly tuner-edited) rest-pose vars to the live FP tool
# pivot + mesh. Pixel-size also rescales the mesh and re-runs the handle-tip
# pivot offset since the offset is in world units.
func _refresh_tool_pose() -> void:
	if _held_tool_pivot != null:
		_held_tool_pivot.position = _held_tool_position
		_held_tool_pivot.rotation = _held_tool_rotation
	_apply_orient_to(_held_tool_orient, _use_vanilla_orient_fp)
	if _held_tool != null and inventory != null:
		var ps: float = _held_tool_pixel_size
		_held_tool.scale = Vector3(ps, ps, ps)
		var tex: Texture2D = ItemIcons.icon_for(inventory.selected().item_id)
		if tex != null:
			var pivot_px: Vector2 = SpriteExtruder.get_handle_pivot_offset(tex)
			_held_tool.position = Vector3(-pivot_px.x * ps, -pivot_px.y * ps, 0)


# Tuner read accessor — returns the current value for the named knob.
# Routes through _tuner_mode: "fp" reads FP rest-pose + swing; "tp" reads
# TP rest-pose (and returns FP swing values unchanged since swing knobs
# don't drive the TP mesh — the arm animation does).
func get_tuner_value(key: String) -> float:
	var pos: Vector3 = _tp_held_tool_position if _tuner_mode == "tp" else _held_tool_position
	var rot: Vector3 = _tp_held_tool_rotation if _tuner_mode == "tp" else _held_tool_rotation
	var ps: float = _tp_held_tool_pixel_size if _tuner_mode == "tp" else _held_tool_pixel_size
	var values: Dictionary = {
		"pos_x": pos.x,
		"pos_y": pos.y,
		"pos_z": pos.z,
		"rot_x_deg": rad_to_deg(rot.x),
		"rot_y_deg": rad_to_deg(rot.y),
		"rot_z_deg": rad_to_deg(rot.z),
		"pixel_size": ps,
		"swing_x_deg": _tool_swing_x_deg,
		"swing_y_deg": _tool_swing_y_deg,
		"swing_z_deg": _tool_swing_z_deg,
		"swing_thrust_fwd": _tool_swing_thrust_fwd,
	}
	return values.get(key, 0.0)


# Tuner write — slider drag lands here. Routes by _tuner_mode: rest-pose
# keys hit either the FP or TP set, swing keys are FP-only.
func apply_tuner_value(key: String, v: float) -> void:
	if _tuner_mode == "tp":
		_apply_tp_tuner_value(key, v)
		_refresh_tp_pose()
		return
	match key:
		"pos_x":
			_held_tool_position.x = v
		"pos_y":
			_held_tool_position.y = v
		"pos_z":
			_held_tool_position.z = v
		"rot_x_deg":
			_held_tool_rotation.x = deg_to_rad(v)
		"rot_y_deg":
			_held_tool_rotation.y = deg_to_rad(v)
		"rot_z_deg":
			_held_tool_rotation.z = deg_to_rad(v)
		"pixel_size":
			_held_tool_pixel_size = v
		"swing_x_deg":
			_tool_swing_x_deg = v
		"swing_y_deg":
			_tool_swing_y_deg = v
		"swing_z_deg":
			_tool_swing_z_deg = v
		"swing_thrust_fwd":
			_tool_swing_thrust_fwd = v
	_refresh_tool_pose()


# TP rest-pose write side. Swing/thrust keys are no-ops in TP mode (the
# third-person mesh inherits the arm's mining swing, not _apply_tool_swing).
func _apply_tp_tuner_value(key: String, v: float) -> void:
	match key:
		"pos_x":
			_tp_held_tool_position.x = v
		"pos_y":
			_tp_held_tool_position.y = v
		"pos_z":
			_tp_held_tool_position.z = v
		"rot_x_deg":
			_tp_held_tool_rotation.x = deg_to_rad(v)
		"rot_y_deg":
			_tp_held_tool_rotation.y = deg_to_rad(v)
		"rot_z_deg":
			_tp_held_tool_rotation.z = deg_to_rad(v)
		"pixel_size":
			_tp_held_tool_pixel_size = v


# Pure forward-chop swing for tools — pickaxe head pitches down/forward
# toward the block being mined, then returns. Composition order matters:
# swing must be applied AFTER rest (swing_x * rest) so the swing axis
# stays aligned with the WORLD X axis. With rest * swing_x, the swing
# happens in mesh-local space and then gets rotated by the rest's Y
# tilt — which introduces a horizontal motion that reads as "flipping
# to the side" instead of a clean down-and-forward chop.
func _apply_tool_swing(node: Node3D, base_pos: Vector3, base_rot: Vector3, progress: float) -> void:
	if progress <= 0.0:
		node.position = base_pos
		node.rotation = base_rot
		return
	if _use_vanilla_swing:
		_apply_vanilla_tool_swing(node, base_pos, base_rot, progress)
		return
	var f1: float = sin(sqrt(progress) * PI)  # peak at progress=0.25
	var rest: Basis = Basis.from_euler(base_rot)
	# Build per-axis swing rotations. Edit the constants above to tune.
	var swing_x := Basis(Vector3.RIGHT, deg_to_rad(_tool_swing_x_deg * f1))
	var swing_y := Basis(Vector3.UP, deg_to_rad(_tool_swing_y_deg * f1))
	var swing_z := Basis(Vector3.BACK, deg_to_rad(_tool_swing_z_deg * f1))
	var swing := swing_x * swing_y * swing_z
	# Forward thrust — push the whole tool toward -Z (away from camera) so
	# the in-and-out chop motion is unambiguously visible. Pure rotation
	# alone reads as "tilting" instead of "stabbing forward".
	node.position = base_pos + Vector3(0, 0, -_tool_swing_thrust_fwd * f1)
	# Apply swing AFTER rest (swing * rest) so axes stay world-aligned.
	node.transform.basis = swing * rest


# Verbatim Beta 1.7.3 ItemRenderer.renderItemInFirstPerson curves for the
# pickaxe path. Order matches GL stack: swing translate → rest translate →
# rest yaw +45° → swing yaw kick → swing roll kick → swing pitch (the chop).
# Sliders for swing X/Y/Z and thrust are ignored when this is active; the
# rest-pose sliders still feed in via base_pos / base_rot so position can
# be tuned independently of the swing math.
func _apply_vanilla_tool_swing(
	node: Node3D, base_pos: Vector3, base_rot: Vector3, progress: float
) -> void:
	var s: float = progress
	var sin_s_pi: float = sin(s * PI)
	var sin_sqrt_s_pi: float = sin(sqrt(s) * PI)
	var sin_sqrt_s_2pi: float = sin(sqrt(s) * PI * 2.0)
	var sin_s2_pi: float = sin(s * s * PI)
	# Swing translate (vanilla "swing arc"): X swings left, Y small bob, Z forward
	var swing_translate := Vector3(
		-sin_sqrt_s_pi * 0.4,
		sin_sqrt_s_2pi * 0.2,
		-sin_s_pi * 0.2,
	)
	node.position = base_pos + swing_translate
	# Rest pose comes from sliders (base_rot), then vanilla applies three
	# swing rotations in LOCAL frame (right-multiply, matches glRotate stack).
	#   yaw kick   = -sin(s²·π) * 20°  around +Y
	#   roll kick  = -sin(√s·π) * 20°  around +Z (vanilla GL +Z = OUT of screen)
	#   chop pitch = -sin(√s·π) * 80°  around +X
	var basis: Basis = Basis.from_euler(base_rot)
	basis = basis * Basis(Vector3.UP, deg_to_rad(-sin_s2_pi * 20.0))
	basis = basis * Basis(Vector3(0, 0, 1), deg_to_rad(-sin_sqrt_s_pi * 20.0))
	basis = basis * Basis(Vector3.RIGHT, deg_to_rad(-sin_sqrt_s_pi * 80.0))
	node.transform.basis = basis


# Toggle vanilla-curve mode from the tuner UI. Returns the new state so the
# button can update its label.
func toggle_vanilla_swing() -> bool:
	_use_vanilla_swing = not _use_vanilla_swing
	return _use_vanilla_swing


func is_vanilla_swing() -> bool:
	return _use_vanilla_swing


func toggle_vanilla_orient() -> bool:
	# Toggles the orient flag for whichever mode the tuner is in, and
	# re-applies just that mode's orient node so we don't disturb the other.
	if _tuner_mode == "tp":
		_use_vanilla_orient_tp = not _use_vanilla_orient_tp
		_apply_orient_to(_held_tool_tp_orient, _use_vanilla_orient_tp)
		return _use_vanilla_orient_tp
	_use_vanilla_orient_fp = not _use_vanilla_orient_fp
	_apply_orient_to(_held_tool_orient, _use_vanilla_orient_fp)
	return _use_vanilla_orient_fp


func is_vanilla_orient() -> bool:
	return _use_vanilla_orient_tp if _tuner_mode == "tp" else _use_vanilla_orient_fp


# Tuner mode switch: "fp" routes slider reads/writes to the FP rest pose,
# "tp" to the TP rest pose. Swing knobs only meaningfully apply in FP mode
# (TP inherits the arm's mining swing); in TP mode they're inert no-ops.
func set_tuner_mode(mode: String) -> void:
	if mode != "fp" and mode != "tp":
		return
	_tuner_mode = mode


func get_tuner_mode() -> String:
	return _tuner_mode


# Re-applies the (possibly tuner-edited) TP rest-pose vars to the live TP
# tool pivot + mesh. Mirrors _refresh_tool_pose for the third-person path.
func _refresh_tp_pose() -> void:
	if _held_tool_tp_pivot != null:
		_held_tool_tp_pivot.position = _tp_held_tool_position
		_held_tool_tp_pivot.rotation = _tp_held_tool_rotation
	_apply_orient_to(_held_tool_tp_orient, _use_vanilla_orient_tp)
	if _held_tool_tp != null and inventory != null:
		var ps: float = _tp_held_tool_pixel_size
		_held_tool_tp.scale = Vector3(ps, ps, ps)
		var tex: Texture2D = ItemIcons.icon_for(inventory.selected().item_id)
		if tex != null:
			var pivot_px: Vector2 = SpriteExtruder.get_handle_pivot_offset(tex)
			_held_tool_tp.position = Vector3(-pivot_px.x * ps, -pivot_px.y * ps, 0)


# Original FP-hand / held-block swing — vanilla MC's bare-hand path uses
# different curves than the item path (3-axis translate + Y-twist). Kept
# separate so tools can use their own ItemRenderer-faithful swing above.
func _apply_fp_swing(node: Node3D, base_pos: Vector3, base_rot: Vector3, progress: float) -> void:
	if progress <= 0.0:
		node.position = base_pos
		node.rotation = base_rot
		return
	var s: float = progress
	var sq: float = sqrt(s)
	var sin_pi_sq: float = sin(PI * sq)  # peak at s=0.25 — early
	var sin_pi_s2: float = sin(PI * s * s)  # peak at s≈0.71 — late
	var sin_pi_s: float = sin(PI * s)  # peak at s=0.5 — mid
	# Previous (matched vanilla MC ratios more closely): (-0.40, 0.20, -0.20).
	# Current: trimmed forward extension so the punch reads as a small jab
	# rather than a big lunge. Restore the old triple if this feels too short.
	var offset := Vector3(
		-0.40 * sin_pi_sq,  # X: sweep toward screen center
		0.20 * sin_pi_s2,  # Y: slight upward arc near end of swing
		-0.12 * sin_pi_s,  # Z: forward extension at mid-swing
	)
	node.position = base_pos + offset * _FP_SWING_TRANSLATE_SCALE
	node.rotation = Vector3(
		base_rot.x + sin_pi_s2 * deg_to_rad(_FP_SWING_X_TILT_DEG),
		base_rot.y + sin_pi_sq * deg_to_rad(_FP_SWING_Y_TWIST_DEG),
		base_rot.z,
	)


func _apply_held_visibility() -> void:
	# First-person: show exactly one of {hand, held block, held tool}.
	# Third-person: only the cube version is visible on the body model
	# (TP tool sprite rendering is a future addition).
	var first_person: bool = perspective == PERSPECTIVE_FIRST
	var holding: bool = _held_block_id != Blocks.AIR
	if _fp_hand != null:
		_fp_hand.visible = first_person and not holding
	if _held_block != null:
		_held_block.visible = first_person
	if _held_block_tp != null:
		_held_block_tp.visible = not first_person
	if _held_tool_pivot != null:
		_held_tool_pivot.visible = first_person
	if _held_tool_tp_pivot != null:
		_held_tool_tp_pivot.visible = not first_person


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_apply_mouse_motion(event)
		return
	if event.is_action_pressed("toggle_inventory"):
		_toggle_inventory_screen()
	elif event.is_action_pressed("pause"):
		# Esc closes any open inventory-style screen first; otherwise opens the
		# ingame pause menu (which freezes the scene tree — Alpha singleplayer
		# paused the world while GuiIngameMenu was up).
		var inv_screen: Control = get_node_or_null("Crosshair/InventoryScreen")
		var table_screen: Control = get_node_or_null("Crosshair/CraftingTableScreen")
		var furnace_screen: Control = get_node_or_null("Crosshair/FurnaceScreen")
		var pause_menu: Control = get_node_or_null("Crosshair/PauseMenu")
		if inv_screen != null and inv_screen.is_open():
			inv_screen.toggle()
		elif table_screen != null and table_screen.is_open():
			table_screen.toggle()
		elif furnace_screen != null and furnace_screen.is_open():
			furnace_screen.close()
		elif pause_menu != null:
			pause_menu.open()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_toggle"):
		Game.debug_enabled = not Game.debug_enabled
		if not Game.debug_enabled:
			creative_mode = false  # leaving debug also clears creative
		_update_debug_label()
	elif event.is_action_pressed("toggle_perspective"):
		perspective = (perspective + 1) % PERSPECTIVE_COUNT
		_apply_perspective()
	elif Game.debug_enabled and event.is_action_pressed("debug_creative"):
		creative_mode = not creative_mode
		_update_debug_label()
	elif Game.debug_enabled and event.is_action_pressed("debug_fill_hotbar"):
		_debug_fill_hotbar()
	elif Game.debug_enabled and event.is_action_pressed("debug_fill_tools"):
		_debug_fill_tools()
	elif Game.debug_enabled and event.is_action_pressed("debug_fill_smelt"):
		_debug_fill_smelt()
	elif event.is_action_pressed("debug_tool_tuner"):
		if _tool_tuner != null and _tool_tuner.has_method("toggle"):
			_tool_tuner.toggle()
	elif event.is_action_pressed("drop_selected"):
		_drop_selected_item(_drop_modifier_held())
	elif event.is_action_pressed("hotbar_prev"):
		_cycle_hotbar(-1)
	elif event.is_action_pressed("hotbar_next"):
		_cycle_hotbar(1)
	else:
		_select_hotbar_from_event(event)


func _cycle_hotbar(direction: int) -> void:
	# Vanilla MC: wheel up moves selection LEFT (previous), wheel down moves
	# RIGHT (next). Wraps around.
	var next_slot: int = (
		(inventory.selected_slot + direction + Inventory.HOTBAR_SIZE) % Inventory.HOTBAR_SIZE
	)
	# inventory.select() ignores no-op selection of the current slot — we
	# always go to a different slot here, so just call it directly.
	inventory.select(next_slot)


func _select_hotbar_from_event(event: InputEvent) -> void:
	for i in range(9):
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			inventory.select(i)
			return


func _play_footstep() -> void:
	# Sample the block immediately below the player's feet. Capsule extends
	# 0.9m down from origin; sample 0.1m below that to land inside the block.
	var chunk_manager: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if chunk_manager == null or not chunk_manager.has_method("get_world_block"):
		return
	var feet_y: float = global_position.y - 1.0
	var block_pos := Vector3i(
		int(floor(global_position.x)), int(floor(feet_y)), int(floor(global_position.z))
	)
	var block_id: int = chunk_manager.get_world_block(block_pos)
	if block_id == Blocks.AIR:
		return
	SFX.play_step(block_id)


func _toggle_inventory_screen() -> void:
	var inv_screen: Control = get_node_or_null("Crosshair/InventoryScreen")
	if inv_screen != null and inv_screen.has_method("toggle"):
		inv_screen.toggle()


func _drop_modifier_held() -> bool:
	# Vanilla MC: Ctrl+Q (Cmd+Q on Mac) drops the entire stack.
	return Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)


func _drop_selected_item(drop_stack: bool) -> void:
	var stack: ItemStack = inventory.selected()
	if stack.is_empty():
		return
	var dropped_id: int = stack.item_id
	var count: int = stack.count if drop_stack else 1
	if drop_stack:
		inventory.consume_selected_stack()
	else:
		inventory.consume_one_selected()
	var chunk_manager: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if chunk_manager == null:
		return
	# Always spawn at the PLAYER's eye position — not the camera's. In third-
	# person the camera sits behind/in front of the player, so using its
	# position would launch items from empty space far from the avatar.
	var look_dir: Vector3 = _player_look_direction()
	var eye_pos: Vector3 = global_position + Vector3(0, _CAM_FIRST_PERSON.y, 0)
	var spawn_pos: Vector3 = eye_pos + look_dir * 0.4
	var velocity: Vector3 = look_dir * 3.5 + Vector3(0, 0.6, 0)
	for i in range(count):
		var item := DroppedItem.new()
		chunk_manager.add_child(item)
		item.global_position = spawn_pos
		item.setup(dropped_id, velocity, DroppedItem.PLAYER_DROP_DELAY_SEC)


# Player-facing direction with camera pitch folded in. Independent of which
# perspective is active (camera position varies by mode but the player's
# yaw + the camera's pitch always describe where they're looking).
func _player_look_direction() -> Vector3:
	var horiz: Vector3 = -transform.basis.z  # player body forward (yaw only)
	var pitch: float = _camera.rotation.x
	# Front mode inverts pitch in the input handler — undo that here so the
	# throw direction follows the player's view, not the camera's.
	if perspective == PERSPECTIVE_THIRD_FRONT:
		pitch = -pitch
	return horiz * cos(pitch) + Vector3(0, sin(pitch), 0)


func _debug_fill_hotbar() -> void:
	for i in range(min(_DEBUG_FILL_BLOCKS.size(), Inventory.HOTBAR_SIZE)):
		var stack: ItemStack = inventory.slots[i]
		stack.item_id = _DEBUG_FILL_BLOCKS[i]
		stack.count = ItemStack.MAX_SIZE
	inventory.changed.emit()


# Drops one of every craftable tool into the inventory. Uses add_item so
# the tools land in the first available hotbar/main slot, instead of
# overwriting whatever's there.
func _debug_fill_tools() -> void:
	for tool_id: int in _DEBUG_FILL_TOOLS:
		inventory.add_item(tool_id, 1)


# Smelting starter pack — 16 of each raw ore + cobblestone + coal so the
# furnace + smelting + ingot path can be tested without spelunking.
func _debug_fill_smelt() -> void:
	for item_id: int in _DEBUG_FILL_SMELT:
		inventory.add_item(item_id, 16)


func _update_debug_label() -> void:
	var label: Label = get_node_or_null("Crosshair/DebugLabel") as Label
	if label == null:
		return
	if not Game.debug_enabled:
		label.text = ""
		return
	if creative_mode:
		label.text = "DEBUG | CREATIVE"
	else:
		label.text = "DEBUG"


func _process(_delta: float) -> void:
	_update_camera_collision()


# Vanilla MC camera collision: in third-person, raycast from the player's
# eye to the desired camera position. If terrain is in the way, pull the
# camera in to just before the obstruction. Without this, digging straight
# down in third-person puts the camera inside the world and you see through
# everything (back faces are culled by the chunk shader).
func _update_camera_collision() -> void:
	if perspective == PERSPECTIVE_FIRST:
		return
	var desired_local: Vector3 = (
		_CAM_THIRD_BACK if perspective == PERSPECTIVE_THIRD_BACK else _CAM_THIRD_FRONT
	)
	var eye_world: Vector3 = global_position + global_transform.basis * _CAM_FIRST_PERSON
	var desired_world: Vector3 = global_position + global_transform.basis * desired_local
	var query := PhysicsRayQueryParameters3D.create(eye_world, desired_world)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		_camera.position = desired_local
		return
	# Clamp to just before the hit. 0.3m buffer keeps the camera from
	# intersecting the wall it just bumped into.
	var hit_world: Vector3 = hit.position
	var ray_dir: Vector3 = (desired_world - eye_world).normalized()
	var hit_distance: float = eye_world.distance_to(hit_world)
	var safe_distance: float = maxf(0.0, hit_distance - 0.3)
	var safe_world: Vector3 = eye_world + ray_dir * safe_distance
	# Convert back into the player-local frame the camera lives in.
	_camera.position = global_transform.basis.inverse() * (safe_world - global_position)


func _apply_perspective() -> void:
	# Camera anchor + facing per perspective. Position is set immediately on
	# perspective switch, then refined per-frame by _update_camera_collision()
	# which clamps the third-person camera if it would clip into a block.
	# In FRONT mode the camera is rotated 180° around Y to look back at the
	# player; mouse pitch is inverted in _apply_mouse_motion to compensate.
	match perspective:
		PERSPECTIVE_FIRST:
			_camera.position = _CAM_FIRST_PERSON
			_camera.rotation.y = 0.0
		PERSPECTIVE_THIRD_BACK:
			_camera.position = _CAM_THIRD_BACK
			_camera.rotation.y = 0.0
		PERSPECTIVE_THIRD_FRONT:
			_camera.position = _CAM_THIRD_FRONT
			_camera.rotation.y = PI
	var third: bool = perspective != PERSPECTIVE_FIRST
	if _character_model != null:
		# Hide the body model in first person (we'd be inside our own head)
		_character_model.visible = third
	# Hand vs held-block visibility is centralized — also gates on first-person.
	_apply_held_visibility()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y += GRAVITY * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	_update_sneak()

	var input_dir: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_forward", "move_back"
	)
	var direction: Vector3 = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var speed: float = SNEAK_SPEED if _is_sneaking else WALK_SPEED

	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()

	# Footstep cadence — accumulate horizontal travel while grounded; fire a
	# step sound (picked from the material under our feet) every STEP_INTERVAL_M.
	if is_on_floor():
		var step_speed: float = Vector2(velocity.x, velocity.z).length()
		_step_distance += step_speed * delta
		if _step_distance >= _STEP_INTERVAL_M:
			_step_distance = 0.0
			_play_footstep()
	else:
		_step_distance = 0.0  # reset mid-jump so we don't fire on landing

	# Drive arm/leg animations: mining swing first (it owns the right arm while
	# active), then walking (which skips the right arm during the swing).
	if _character_model != null and _character_model.has_method("update_walk_animation"):
		var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
		var progress: float = _character_model.update_mining_swing(is_mining, delta)
		var arm_locked: bool = _character_model.is_mining_visually()
		_character_model.update_walk_animation(horiz_speed, delta, arm_locked)
		# Drive the swing on whichever first-person prop is currently visible.
		if _fp_hand != null and _fp_hand.visible:
			_apply_fp_swing(_fp_hand, _fp_hand_base_position, _fp_hand_base_rotation, progress)
		if _held_block != null and _held_block.visible:
			_apply_fp_swing(_held_block, _HELD_BLOCK_POSITION, _HELD_BLOCK_ROTATION, progress)
		# Apply swing to the PIVOT (which sits at the fist), not the mesh —
		# this makes the head arc forward while the handle stays in place.
		if _held_tool_pivot != null and _held_tool_pivot.visible:
			_apply_tool_swing(_held_tool_pivot, _held_tool_position, _held_tool_rotation, progress)

	_update_fall_tracking()
	if _damage_cooldown_remaining > 0.0:
		_damage_cooldown_remaining = maxf(0.0, _damage_cooldown_remaining - delta)
	_tick_health_regen(delta)


# Pre-Beta 1.8 health regen: +1 HP every HEALTH_REGEN_INTERVAL_SEC while
# below max. No hunger gating; just a steady passive heal.
func _tick_health_regen(delta: float) -> void:
	if health <= 0 or health >= MAX_HEALTH:
		_regen_accum = 0.0
		return
	_regen_accum += delta
	if _regen_accum >= HEALTH_REGEN_INTERVAL_SEC:
		_regen_accum -= HEALTH_REGEN_INTERVAL_SEC
		health = mini(MAX_HEALTH, health + 1)
		health_changed.emit(health, MAX_HEALTH)

	# Recover if we fall through the world
	if global_position.y < -20.0:
		global_position = Vector3(8, 100.0, 8)
		velocity = Vector3.ZERO


# Called every physics frame. Tracks the highest Y reached while airborne
# and applies fall damage on the tick the player lands. Mirrors vanilla
# EntityPlayer.fall() — damage = max(0, fall_blocks - 3). Doesn't apply
# in creative mode.
func _update_fall_tracking() -> void:
	var on_floor: bool = is_on_floor()
	if not on_floor:
		_fall_peak_y = maxf(_fall_peak_y, global_position.y)
	elif not _was_on_floor:
		# Just landed this tick.
		if _fall_immune_next_landing:
			_fall_immune_next_landing = false
		else:
			var fall_distance: float = _fall_peak_y - global_position.y
			if fall_distance > FALL_DAMAGE_SAFE_BLOCKS and not creative_mode:
				take_damage(int(floor(fall_distance - FALL_DAMAGE_SAFE_BLOCKS)), DAMAGE_FALL)
		_fall_peak_y = global_position.y
	else:
		# Standing still on the floor.
		_fall_peak_y = global_position.y
	_was_on_floor = on_floor


# Public damage entry point. Applies armor-reduction unless the source
# bypasses armor (fall damage does per vanilla Alpha behavior). Emits
# signals for UI + sound hooks; routes to respawn on 0 HP.
func take_damage(amount: int, source: String = DAMAGE_GENERIC) -> void:
	if amount <= 0 or health <= 0:
		return
	if _damage_cooldown_remaining > 0.0:
		return  # vanilla hurtResistantTime — drop overlapping hits
	var final_amount: int = amount
	if source != DAMAGE_FALL and inventory != null:
		# Vanilla armor formula: final = damage × (25 - total_points) / 25.
		var total_defense: int = 0
		for i in range(Inventory.ARMOR_SIZE):
			var stack: ItemStack = inventory.slots[Inventory.ARMOR_START + i]
			total_defense += Items.armor_defense(stack.item_id)
		final_amount = int(round(float(amount) * float(25 - total_defense) / 25.0))
		if final_amount < 1:
			final_amount = 1  # vanilla: at least 1 damage if any made it through
		# Vanilla EntityPlayer.damageArmor — each worn piece loses
		# max(1, absorbed/4) durability per hit.
		_damage_armor(amount - final_amount)
	health = maxi(0, health - final_amount)
	_damage_cooldown_remaining = DAMAGE_COOLDOWN_SEC
	# Vanilla branches on source: fall damage plays fall.big/.small,
	# generic hits play the rotating hit1/2/3. Matches EntityHuman.
	if source == DAMAGE_FALL:
		SFX.play_player_fall(final_amount)
	else:
		SFX.play_player_hit()
	damaged.emit(final_amount, source)
	health_changed.emit(health, MAX_HEALTH)
	if health == 0:
		died.emit()
		_show_death_screen()


func _show_death_screen() -> void:
	# Freeze physics-level input until the player clicks Respawn.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var screen: Control = get_node_or_null("Crosshair/DeathScreen") as Control
	if screen != null and screen.has_method("open"):
		screen.open()
	else:
		# Fallback if the scene node isn't wired yet.
		_respawn()


# Instant-respawn: teleport to the scene's spawn position and restore
# health. Vanilla shows a death screen with a Respawn button; that's
# deferred until the death-flow UI lands.
func _respawn() -> void:
	global_position = Vector3(8, 100.0, 8)
	velocity = Vector3.ZERO
	_fall_peak_y = global_position.y
	_fall_immune_next_landing = true
	_damage_cooldown_remaining = 0.0
	_regen_accum = 0.0
	health = MAX_HEALTH
	health_changed.emit(health, MAX_HEALTH)


# Vanilla EntityPlayer.damageArmor — distributes durability loss across
# every worn armor piece. Per-piece loss = max(1, absorbed_dmg / 4).
# When a piece's durability runs out, ItemStack.damage_tool() empties
# the slot. Refreshes inventory + UI so the durability bars and the 3D
# overlay update in lockstep.
func _damage_armor(absorbed: int) -> void:
	if absorbed <= 0 or inventory == null:
		return
	var per_piece_loss: int = maxi(1, absorbed / 4)
	var any_changed: bool = false
	for i in range(Inventory.ARMOR_SIZE):
		var stack: ItemStack = inventory.slots[Inventory.ARMOR_START + i]
		if not stack.is_empty() and stack.max_durability() > 0:
			stack.damage_tool(per_piece_loss)
			any_changed = true
	if any_changed:
		inventory.changed.emit()


func _apply_mouse_motion(event: InputEventMouseMotion) -> void:
	rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
	# Front-mode camera sits at Y=PI; without inverting pitch, mouse-down would
	# tilt the view up. Flip the sign so up/down feels consistent across modes.
	var pitch_sign: float = -1.0 if perspective == PERSPECTIVE_THIRD_FRONT else 1.0
	_camera.rotate_x(pitch_sign * -event.relative.y * MOUSE_SENSITIVITY)
	var pitch_limit: float = deg_to_rad(PITCH_LIMIT_DEG)
	_camera.rotation.x = clamp(_camera.rotation.x, -pitch_limit, pitch_limit)


func _update_sneak() -> void:
	if sneak_toggle:
		if Input.is_action_just_pressed("sneak"):
			_is_sneaking = not _is_sneaking
	else:
		_is_sneaking = Input.is_action_pressed("sneak")
