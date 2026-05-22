# gdlint: disable=max-file-lines
# gdlint: disable=class-definitions-order
extends CharacterBody3D

signal health_changed(current: int, maximum: int)
signal damaged(amount: int, source: String)
signal died
# Emitted with remaining air as a fraction in [0, 1]. Bar UI hides at 1.0.
signal air_changed(fraction: float)
# Edge signal for the underwater blue tint overlay. Emitted only when the
# head-submerged state actually flips to avoid per-frame repaints.
signal head_submerged_changed(submerged: bool)

const WALK_SPEED: float = 4.317
const SNEAK_SPEED: float = 1.295
const JUMP_VELOCITY: float = 8.0
const GRAVITY: float = -32.0
# Vanilla EntityLiving.P = 0.5f — max ledge height the player steps onto
# without jumping. Enables walking up stairs (0.5-block steps).
const STEP_HEIGHT: float = 0.6
const MOUSE_SENSITIVITY: float = 0.002
const PITCH_LIMIT_DEG: float = 89.0
# Vanilla ladder climbing (hf.java / EntityLiving.e()). Climb speed
# 0.1175 blocks/tick × 20 TPS = 2.35 b/s. Max descent 0.15 b/tick = 3 b/s.
const LADDER_CLIMB_SPEED: float = 2.35
const LADDER_MAX_DESCENT: float = 3.0

# Vanilla water physics (EntityLiving.e() in Bukkit/mc-dev):
#   motY *= 0.5
#   motY -= 0.02
# Per-tick (20 Hz). Terminal sink = 0.02 / (1 - 0.5) = 0.04 blocks/tick = 0.8 m/s.
# Horizontal damping by the same 0.5, so top walking speed in water ≈ 50%
# of land speed at steady state. We run at 60 Hz; convert the per-tick
# factors to per-second continuous equivalents:
#   drag per second    = 0.5^20  = 9.5e-7 (effectively "near zero very fast")
#   gravity per second = -0.02 * 20 = -0.4 m/s of additional down-velocity
#     but capped by drag so terminal stays at 0.8 m/s sink.
# Rather than hand-tune those, port the same form per-frame with exp-mapped
# drag so timestep independence holds: v *= pow(drag_per_tick, delta*20).
const WATER_DRAG_PER_TICK: float = 0.5
const WATER_GRAVITY_PER_TICK: float = 0.02  # blocks/tick, downward
# Vanilla EntityHuman swim-up: when jump is held in water, motY += 0.04
# per tick (a continuous upward thrust, not a single impulse like ground
# jump). 0.04 × 20 = 0.8 blocks/sec² of upward accel — just strong enough
# to beat gravity and rise toward the surface.
const SWIM_UP_PER_TICK: float = 0.04
# Horizontal input acceleration in water — vanilla's `this.a(f, f1, 0.02F)`
# vs land's 0.1F. We apply it as a direct target-speed clamp here (the
# actual acceleration is handled by move_and_slide), scaled by the vanilla
# ratio 0.02/0.1 = 0.2 of land speed. But vanilla's terminal water swim
# speed is ~2 m/s (not 0.86 m/s) because of how the thrust + drag interact;
# 50% of WALK_SPEED is closer to the felt speed.
const WATER_MOVE_SPEED: float = WALK_SPEED * 0.5

# Vanilla creative flight: double-tap jump toggles flight, space = ascend,
# sneak = descend, horizontal speed doubles. Vanilla's default fly speed is
# ~10.89 m/s (2.5× walk). Only available in creative mode — exits whenever
# creative toggles off.
const FLY_SPEED: float = 10.89
const FLY_VERTICAL_SPEED: float = 7.5
# Max seconds between two jump presses that still count as a double-tap.
# Vanilla uses ~0.3 s; shorter feels sluggish, longer triggers accidentally.
const FLY_DOUBLE_TAP_SEC: float = 0.3

# Vanilla EntityLiving.deathTime → render-pitch mapping. Over ~20 ticks
# (1 s) the body rolls 0° → 90° on death. Camera + character model both
# tilt; the collision capsule itself stays upright.
const _DEATH_TILT_DURATION_SEC: float = 1.0
const _DEATH_TILT_MAX_DEG: float = 90.0

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
const DAMAGE_DROWN: String = "drown"
const DAMAGE_LAVA: String = "lava"
const DAMAGE_CACTUS: String = "cactus"
# Vanilla BlockCactus damages every tick the entity AABB intersects a
# cactus cell shrunk by 1/16 on each side. Damage = 1 HP. We rate-limit
# to half-second intervals (10 vanilla ticks) — matches the apparent
# damage rate when standing in a cactus and avoids 20Hz HP drain.
const _CACTUS_DAMAGE_INTERVAL_SEC: float = 0.5
const _CACTUS_DAMAGE: int = 1
# Vanilla EntityLiving: airTicks = 300 (15 s) when head out of water,
# decrements each tick head is submerged. At -20 ticks (1 s past zero),
# deals 2 damage and resets to 0. We use seconds instead of ticks.
const _AIR_MAX_SEC: float = 15.0
const _DROWN_DAMAGE_INTERVAL_SEC: float = 1.0
const _DROWN_DAMAGE: int = 2

# Lava contact damage. Vanilla Alpha Entity.burn/attackEntityFrom(LAVA, 4)
# fires once per physics tick (~50 ms) while the entity is touching a
# lava cell, plus sets the entity on fire for 15 s afterward. We run the
# damage on a half-second timer like drowning so it doesn't out-pace the
# hurt-resistant-time cooldown, and skip the fire-tick for now (requires
# an entity-fire system we don't have yet).
const _LAVA_DAMAGE_INTERVAL_SEC: float = 0.5
const _LAVA_DAMAGE: int = 4

# Timer state for lava contact damage. Mirrors `_drown_tick` — accumulates
# delta while the player's feet/body overlap a lava cell, fires damage
# every interval, resets when the player leaves lava.
var _lava_tick: float = 0.0
# Same pattern for cactus contact damage.
var _cactus_tick: float = 0.0
# Edge-detect flag for the lava-entry fizz SFX. True while player's AABB
# overlaps lava; on rising edge (false → true), play one fizz sound.
var _was_in_lava: bool = false

# Vanilla Alpha Entity.K() (lw.java:206-212): on lava contact the fire
# counter `bg` is set to 600 ticks at 20 Hz = 30 seconds. While bg > 0,
# a 1-damage fire tick applies every 20 ticks (see bg%20 check at
# lw.java:200-203). Earlier drafts used 15 s — Beta/Release shortened
# it; Alpha 1.2.6 is the full 30 s so the "swim quick or you die"
# pressure is authentic.
const _FIRE_AFTER_LAVA_SEC: float = 30.0
const _FIRE_BURN_INTERVAL_SEC: float = 1.0
const _FIRE_BURN_DAMAGE: int = 1
var _fire_remaining_sec: float = 0.0
var _fire_burn_tick: float = 0.0

# Old _DEBUG_FILL_* constants and per-set hotkey handlers lived here;
# they've been replaced by the DebugItemSpawner UI (F4), which ships a
# grid of every implemented block + item plus a quantity selector.
# Adding a new item no longer requires touching player.gd.
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
# Swim-sound stride — vanilla emits `game.neutral.swim` per block traveled
# at vanilla water speed (~0.8 m/s). Our water speed is ~2.7× faster
# (2.16 m/s, tuned for non-tedious gameplay), so stretch the distance
# accordingly. Net cadence lands at roughly 1 sound per second of active
# swimming, matching vanilla perception.
const _SWIM_INTERVAL_M: float = 2.7
# Minimum seconds between splash sounds. Without this, a player treading
# with jump held edges the feet across the water cell boundary on every
# micro-bob and re-triggers splash each time — audible as SFX spam.
const _SPLASH_MIN_INTERVAL_SEC: float = 1.0
# Minimum entry speed (m/s) for a splash. Vanilla fires unconditionally on
# the !inWater→inWater edge with volume scaled by speed, so we keep only a
# tiny gate to skip dead-stop cell flips. Walk speed (4.317) easily clears
# this, so wading off a beach still splashes. Tread-spam at the surface
# is debounced via _SPLASH_MIN_INTERVAL_SEC.
const _SPLASH_MIN_SPEED: float = 0.5
const _FP_SWING_Y_TWIST_DEG: float = -15.0  # subtle wrist hint; vanilla 70° over-rotates our pose
const _FP_SWING_X_TILT_DEG: float = -25.0  # tilt-down at peak — main rotation contribution

# Held-block rest pose in camera-local space — vanilla MC puts the cube in the
# lower-right of the view, tilted to show three faces.
const _HELD_BLOCK_POSITION: Vector3 = Vector3(0.5, -0.45, -0.65)
const _HELD_BLOCK_ROTATION: Vector3 = Vector3(-0.1745, -0.7854, 0.0)  # (-10°, -45°, 0°)
const _HELD_BLOCK_SIZE: float = 0.42
# Fence-specific FP pose. The 4-box mesh (2 posts on Z + 2 rails along Z)
# is asymmetric, so the cube default's mild -10° pitch leaves the rails
# end-on to the camera and the player sees a vertical sliver. Mirror the
# TP-fence pitch (-45°) so the top is tipped forward enough that both
# rails read as horizontal slats; bump up slightly and pull back from
# the cube position so the longer Z extent doesn't clip into the view.
# `var` (not `const`) so ToolTuner can live-tune these — see the FP
# fence override in apply_tuner_value/get_tuner_value.
var _held_fence_position: Vector3 = Vector3(0.630, -0.510, -0.750)
var _held_fence_rotation: Vector3 = Vector3(deg_to_rad(6.0), deg_to_rad(40.0), deg_to_rad(2.0))

# Held-tool rest pose. Vanilla MC uses +45° Y but at our render scale that
# turns the pickaxe sideways too much — flat face barely visible. Trim to
# +25° so the flat side mostly faces the camera (like vanilla looks at
# typical GUI scales) while still showing some depth on one edge.
# Third-person held block — parented to the right arm so it swings with the
# mining animation. Position is at the wrist (arm hangs to y≈-0.75).
const _TP_HELD_BLOCK_POSITION: Vector3 = Vector3(0, -0.78, -0.18)
const _TP_HELD_BLOCK_ROTATION: Vector3 = Vector3(-0.3491, -0.4363, 0)  # (-20°, -25°, 0°)
const _TP_HELD_BLOCK_SIZE: float = 0.30
const _TP_HELD_TORCH_POSITION: Vector3 = Vector3(0, -0.6, -0.22)
const _TP_HELD_TORCH_ROTATION: Vector3 = Vector3(-0.7854, -0.4363, 0)  # (-45°, -25°, 0°)
const _TP_HELD_FENCE_POSITION: Vector3 = Vector3(0, -0.6, -0.22)
const _TP_HELD_FENCE_ROTATION: Vector3 = Vector3(-0.7854, -0.4363, 0)  # (-45°, -25°, 0°)

# Per-tick flow push for swimming in flowing water/lava. Cheap — a single
# get_world_block + 4 neighbor reads per frame. Only runs when the player's
# center cell is fluid (not every frame of play). Vanilla EntityLiving.move
# scales the flow vector by 0.014 per tick — that's the constant here.
const _FLUID_FLOW_PUSH_PER_TICK: float = 0.014

@export var sneak_toggle: bool = false  # false = hold to sneak, true = press to toggle

var inventory: Inventory
var creative_mode: bool = false
var perspective: int = PERSPECTIVE_FIRST
var is_mining: bool = false  # set by Interaction; drives mining-swing animation
# Active fishing bobber, if any — Interaction sets this on cast and
# clears it on reel. Single bobber per player (vanilla parity:
# eb.n holds the bobber ref; spawning a new one auto-reels the old).
var fishing_bobber: Node = null


# One-shot arm swing for right-click item-use (bucket fill/place, etc.).
# Called by Interaction after a successful use; character_model runs
# through one swing cycle and returns to rest. Looping mining swings
# are handled separately via `is_mining`.
func trigger_use_swing() -> void:
	if _character_model != null and _character_model.has_method("trigger_use_swing"):
		_character_model.trigger_use_swing()


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
# Counts down each physics tick after spawn / respawn. While > 0, the
# spawn-relocate check runs every tick (looking at the actual loaded
# chunks for dry land). Decrements to 0 once relocated or after the
# budget expires. Multi-frame budget so a respawn into a region whose
# chunks haven't loaded yet still gets corrected once they're in.
# 30 ticks ≈ 0.5 s — well within the chunk-streaming window.
var _spawn_check_ticks_remaining: int = 90
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

# Axe-specific TP mesh rotation offset. Axes have a diagonal blade (top-right)
# that, after the shared orient rotations, points up into the player's face.
# These offsets apply to _held_tool_tp.rotation when the held item is an axe.
var _axe_tp_mesh_rotation: Vector3 = Vector3(PI, 0, deg_to_rad(-80))

# "fp" or "tp" — which value set the tuner sliders read/write.
var _tuner_mode: String = "fp"

var _is_sneaking: bool = false
# Creative flight state. `_is_flying` short-circuits gravity + vertical
# input in _physics_process; `_last_jump_press_time` drives the vanilla
# double-tap-to-toggle pattern. Both reset when creative mode exits.
var _is_flying: bool = false
# Vanilla EntityLiving.deathTime counts up each tick while dead; the render
# pass maps that into a Z-axis roll of the entity model from 0° → 90° over
# the first ~20 ticks (1 s). We track elapsed seconds in the same shape
# and apply the roll to the camera (first-person view tilts with the
# falling head) and the character model (third-person body lies sideways).
var _death_time_sec: float = 0.0
var _last_jump_press_time: float = -10.0
# Water state between frames — `_was_in_water` drives the splash trigger
# (vanilla Entity.N() fires on !inWater → inWater edge). `_swim_distance`
# accumulates horizontal travel while submerged, stepping `play_swim()` at
# a vanilla-like stride cadence.
var _was_in_water: bool = false
var _swim_distance: float = 0.0
# Wall-clock timestamp of the last splash — debounces edge-flip spam.
var _last_splash_time: float = -10.0
# Drowning — time in seconds of air remaining. At 0, `_drown_tick` counts
# up toward _DROWN_DAMAGE_INTERVAL_SEC and applies damage each interval.
var _air_sec: float = _AIR_MAX_SEC
var _drown_tick: float = 0.0
# Tracks head-submerged state across frames for the underwater-tint
# overlay. Signal is edge-triggered so the HUD only repaints on transitions.
var _was_head_submerged: bool = false
var _step_distance: float = 0.0  # accumulates horizontal travel between footsteps
var _character_model: Node3D
var _fp_hand: Node3D  # first-person right hand attached to camera
var _fp_hand_base_position: Vector3 = Vector3.ZERO
var _fp_hand_base_rotation: Vector3 = Vector3.ZERO
var _held_block: MeshInstance3D  # FP cube shown in lieu of the hand when holding a block
var _held_block_tp: MeshInstance3D  # third-person cube parented to arm_r
# Loosened to GeometryInstance3D so the held node can be either a
# MeshInstance3D (voxel-extruded tools) OR a Sprite3D (flat 2D items
# like signs — matches vanilla Alpha's af.java "item" branch).
var _held_tool: GeometryInstance3D
var _held_tool_pivot: Node3D  # parent of _held_tool — sits at the fist; rotation pivots here
var _held_tool_orient: Node3D  # carries the vanilla 50°Y / -25°Z inner sprite tilt
var _held_tool_tp: GeometryInstance3D  # third-person tool mesh / sprite, parented to arm_r
var _held_tool_tp_pivot: Node3D  # parent of _held_tool_tp at the wrist (so rotation pivots there)
var _held_tool_tp_orient: Node3D  # TP orient node (mirrors _held_tool_orient role)
var _held_block_id: int = 0  # 0 = AIR = nothing held; show the hand instead
var _tool_tuner: Control  # debug-only slider panel; toggled with T

@onready var _camera: Camera3D = $Camera3D

# Currently-mounted mob (set by Pig.mount via set_mount), or null. While
# non-null, player physics is suspended: position is driven by the mob's
# saddle transform, WASD input flows to the mob, and pressing sneak
# dismounts. Restored to free movement on set_mount(null).
var _mounted_to: Node3D = null
# Saved collision-shape disabled state so set_mount(null) can restore
# whatever it was before mounting (in case dev tools / cheats disabled
# it elsewhere). Defaults to "was enabled" — the typical case.
var _pre_mount_collision_disabled: bool = false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Search ONLY within the spawn chunk (0..15 on X/Z) for a column
	# above sea level. Bounded scope means the chunk loader still has
	# the spawn chunk in its initial-load set — no chunk-load lag, no
	# infinite-fall regression. If the entire spawn chunk is ocean we
	# accept the water spawn (rare with the new ELEVATION_LAND_BIAS).
	var safe: Vector2i = _find_safe_spawn_in_chunk()
	global_position = Vector3(float(safe.x) + 0.5, 100.0, float(safe.y) + 0.5)
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
	var chest_screen: Control = get_node_or_null("Crosshair/ChestScreen")
	if chest_screen != null:
		chest_screen.bind(inventory)
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
		# mesh (vanilla MC's ItemModelGenerator path). Non-cube blocks
		# (sapling, future torches/plants) also route through the sprite
		# path — vanilla renders them as flat 2D billboards in the held
		# position via RenderItem.renderItemIn2D, not as a textured cube.
		# Without this, the sapling icon tiles onto all six faces of the
		# held cube, which reads as obviously wrong.
		# Sprite path: items (id ≥ 100), cross-quads (sapling, fire), and
		# torch — vanilla MC renders all of these as a flat 2D billboard in
		# the held position via RenderItem.renderItemIn2D. CHEST is also
		# routed through the GDScript mesher (MESH_SHAPE_EXTERNAL) but
		# reads as a textured cube in the inventory icon — taking the
		# sprite path made the held chest sample at the sprite extruder's
		# native scale and balloon to fill the screen. Cube path keeps it
		# the same size as any other held block.
		var shape: int = Blocks.mesh_shape(id)
		# Non-block items and cross-quad blocks (sapling/fire) take the
		# sprite-extruder path. Everything else goes through the held-block
		# path — BlockMesh.get_cube_mesh special-cases TORCH (pillar),
		# FENCE (post), and STAIRS (step shape) so they render correctly.
		var as_sprite: bool = (
			id >= Items.STICK
			or shape == Blocks.MESH_SHAPE_CROSS
			or shape == Blocks.MESH_SHAPE_LADDER
		)
		if as_sprite:
			_build_held_tool(id)
		else:
			_build_held_block(id)
	_apply_held_visibility()
	# Mirror to the inventory preview — vanilla GuiInventory shows the
	# currently-held stack in the avatar's right hand.
	CharacterPreview.set_held_item(id)


func _build_held_block(id: int) -> void:
	_held_block = MeshInstance3D.new()
	if id == Blocks.TORCH:
		_held_block.mesh = BlockMesh.get_held_torch_mesh(_HELD_BLOCK_SIZE * 2.0)
	else:
		_held_block.mesh = BlockMesh.get_cube_mesh(id, _HELD_BLOCK_SIZE)
	# Force the FP held block to draw on top of world geometry — same
	# fix as the FP hand. Without this it z-fights nearby blocks.
	_held_block.material_override = BlockAtlas.overlay_material()
	if id == Blocks.FENCE:
		_held_block.position = _held_fence_position
		_held_block.rotation = _held_fence_rotation
	else:
		_held_block.position = _HELD_BLOCK_POSITION
		_held_block.rotation = _HELD_BLOCK_ROTATION
	_camera.add_child(_held_block)
	# TP block lives under the right arm so it inherits walking + mining swings.
	var arm_r: Node3D = null
	if _character_model != null:
		arm_r = _character_model.get("arm_r") as Node3D
	if arm_r != null:
		_held_block_tp = MeshInstance3D.new()
		if id == Blocks.TORCH:
			_held_block_tp.mesh = BlockMesh.get_cube_mesh(Blocks.TORCH, _TP_HELD_BLOCK_SIZE * 2.0)
			_held_block_tp.position = _TP_HELD_TORCH_POSITION
			_held_block_tp.rotation = _TP_HELD_TORCH_ROTATION
		elif id == Blocks.FENCE:
			_held_block_tp.mesh = BlockMesh.get_cube_mesh(id, _TP_HELD_BLOCK_SIZE)
			_held_block_tp.position = _TP_HELD_FENCE_POSITION
			_held_block_tp.rotation = _TP_HELD_FENCE_ROTATION
		else:
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
		push_warning("[HeldTool] no texture for item id %d" % id)
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

	var ps: float = _held_tool_pixel_size
	# Vanilla Alpha af.java::RenderItem draws non-block held items as a
	# FLAT 2D sprite — see the "item" branch. Our default voxel-extrusion
	# path makes most items look chunky-3D, which is acceptable for tools
	# but the sign sprite specifically voxelizes into a misshapen blob.
	# For signs we use Sprite3D (purpose-built for 2D-sprite-in-3D-space
	# with alpha-cut + texture filter handled natively, and no cull_back
	# clipping like the MeshInstance3D + shader path).
	# Sign + Boat use Sprite3D for their FP path — both have sprites
	# whose voxel-extrusion would look misshapen (sign is too thin,
	# boat is mostly opaque rounded hull pixels). Tools / loose items
	# go through the voxel-extrusion mesh. Either way we fall through
	# to the TP setup below so the third-person mirror gets built too.
	var is_flat_sprite_item: bool = id == Items.SIGN or id == Items.BOAT
	if is_flat_sprite_item:
		var sprite := Sprite3D.new()
		sprite.texture = tex
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		sprite.pixel_size = ps
		sprite.transparent = true
		sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# render_priority + no_depth_test so the held sprite always
		# draws on top of world geometry (matches the held_item shader's
		# render_priority/depth_test_disabled combo for the other path).
		sprite.render_priority = 100
		sprite.no_depth_test = true
		# Lift the sprite so its BOTTOM sits at the orient pivot —
		# matches the voxel-mesh convention where the handle tip lands
		# at the pivot and the body extends upward from there. Without
		# this the sprite center sat at the pivot (orient y=-0.63m),
		# putting the held sign visually below where tools land.
		sprite.position = Vector3(0, 8.0 * ps, 0)
		_held_tool_orient.add_child(sprite)
		_held_tool = sprite
	else:
		_held_tool = MeshInstance3D.new()
		var mesh: ArrayMesh = SpriteExtruder.build(tex)
		_held_tool.mesh = mesh
		_held_tool.scale = Vector3(ps, ps, ps)
		# Find the actual handle tip (bottom-most opaque pixel — for the
		# pickaxe that's the lower-left corner) and offset the mesh so THAT
		# point lands at the pivot origin. Without this, rotating around
		# bounding-box center made the handle visibly slide out of the fist
		# as the head arced forward.
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
		_held_tool_tp_pivot.add_child(_held_tool_tp_orient)

		# Same Sprite3D treatment for the third-person sign (matches
		# the FP path above so the held sign stays vanilla-Alpha shaped
		# regardless of perspective). Build sprite + early-return so we
		# skip the scale / position logic that's tailored to the
		# voxel-extruded mesh path.
		if id == Items.SIGN or id == Items.BOAT:
			var tp_sprite := Sprite3D.new()
			tp_sprite.texture = tex
			tp_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			# Slightly larger than FP — TP held tools render at ~1.5×
			# the FP pixel size (per _tp_held_tool_pixel_size default).
			tp_sprite.pixel_size = _tp_held_tool_pixel_size * 0.6
			tp_sprite.transparent = true
			tp_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
			tp_sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_held_tool_tp_orient.add_child(tp_sprite)
			_held_tool_tp = tp_sprite
			return
		_held_tool_tp = MeshInstance3D.new()
		_held_tool_tp.mesh = SpriteExtruder.build(tex)
		var tp_ps: float = _tp_held_tool_pixel_size
		# Non-tool loose items (coal, ingots, diamond) use a tighter scale
		# and skip the handle-pivot offset. Applying the handle pivot to a
		# compact item pulls it upward off the hand; centering + shrinking
		# keeps it nestled in the fist without clipping the arm mesh.
		if Items.is_tool_item(id):
			# Flint-and-steel's sprite occupies only ~half the 16×16
			# canvas (the rest is transparent), so the same _tp_held_tool_
			# pixel_size that suits a full-canvas pickaxe makes flint-
			# and-steel read as comically oversized in the fist. Halve
			# the per-pixel scale for this specific item so the visible
			# voxels sit at roughly the same hand-relative size as a
			# pickaxe head.
			var effective_ps: float = tp_ps
			if id == Items.FLINT_AND_STEEL:
				effective_ps = tp_ps * 0.5
			_held_tool_tp.scale = Vector3(effective_ps, effective_ps, effective_ps)
			var tp_pivot_px: Vector2 = SpriteExtruder.get_handle_pivot_offset(tex)
			_held_tool_tp.position = Vector3(
				-tp_pivot_px.x * effective_ps, -tp_pivot_px.y * effective_ps, 0
			)
			if Items.tool_type(id) == Items.TOOL_TYPE_AXE:
				_held_tool_tp.rotation = _axe_tp_mesh_rotation
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
	# FP fence override — see apply_tuner_value for the matching write
	# path. Sliders need to OPEN to the current fence pose, otherwise
	# they'd snap the held block to the tool's pose on first drag.
	var pos: Vector3
	var rot: Vector3
	var ps: float
	if _is_holding_fence_fp():
		pos = _held_fence_position
		rot = _held_fence_rotation
		ps = 0.0
	elif _tuner_mode == "tp":
		pos = _tp_held_tool_position
		rot = _tp_held_tool_rotation
		ps = _tp_held_tool_pixel_size
	else:
		pos = _held_tool_position
		rot = _held_tool_rotation
		ps = _held_tool_pixel_size
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
		"axe_rot_x_deg": rad_to_deg(_axe_tp_mesh_rotation.x),
		"axe_rot_y_deg": rad_to_deg(_axe_tp_mesh_rotation.y),
		"axe_rot_z_deg": rad_to_deg(_axe_tp_mesh_rotation.z),
	}
	return values.get(key, 0.0)


# Tuner write — slider drag lands here. Routes by _tuner_mode: rest-pose
# keys hit either the FP or TP set, swing keys are FP-only.
func apply_tuner_value(key: String, v: float) -> void:
	if _tuner_mode == "tp":
		_apply_tp_tuner_value(key, v)
		_refresh_tp_pose()
		return
	# FP held-fence routing — the fence uses the block path (not the
	# sprite-extruded tool path), so the standard `_held_tool_*` writes
	# below never reach it. When the player is holding a fence, redirect
	# pos/rot sliders to the fence vars and refresh the block instance.
	# pixel_size + swing knobs stay no-op (fence isn't sprite-extruded
	# and doesn't have the tool's _apply_tool_swing pipeline).
	if _is_holding_fence_fp():
		match key:
			"pos_x":
				_held_fence_position.x = v
			"pos_y":
				_held_fence_position.y = v
			"pos_z":
				_held_fence_position.z = v
			"rot_x_deg":
				_held_fence_rotation.x = deg_to_rad(v)
			"rot_y_deg":
				_held_fence_rotation.y = deg_to_rad(v)
			"rot_z_deg":
				_held_fence_rotation.z = deg_to_rad(v)
		if _held_block != null:
			_held_block.position = _held_fence_position
			_held_block.rotation = _held_fence_rotation
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


# True when the player is in FP mode and currently holding a FENCE block.
# Used by the tuner accessors so the FP pos/rot sliders target the held
# fence's transform instead of the (irrelevant) tool pivot.
func _is_holding_fence_fp() -> bool:
	if _tuner_mode != "fp" or inventory == null:
		return false
	var stack: ItemStack = inventory.selected()
	if stack == null or stack.is_empty():
		return false
	return stack.item_id == Blocks.FENCE


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
		"axe_rot_x_deg":
			_axe_tp_mesh_rotation.x = deg_to_rad(v)
			_refresh_axe_tp_rotation()
		"axe_rot_y_deg":
			_axe_tp_mesh_rotation.y = deg_to_rad(v)
			_refresh_axe_tp_rotation()
		"axe_rot_z_deg":
			_axe_tp_mesh_rotation.z = deg_to_rad(v)
			_refresh_axe_tp_rotation()


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
		var id: int = inventory.selected().item_id
		var tex: Texture2D = ItemIcons.icon_for(id)
		if tex != null:
			var pivot_px: Vector2 = SpriteExtruder.get_handle_pivot_offset(tex)
			_held_tool_tp.position = Vector3(-pivot_px.x * ps, -pivot_px.y * ps, 0)
		if Items.tool_type(id) == Items.TOOL_TYPE_AXE:
			_held_tool_tp.rotation = _axe_tp_mesh_rotation


func _refresh_axe_tp_rotation() -> void:
	if _held_tool_tp == null or inventory == null:
		return
	var id: int = inventory.selected().item_id
	if Items.tool_type(id) == Items.TOOL_TYPE_AXE:
		_held_tool_tp.rotation = _axe_tp_mesh_rotation


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
	# Dead — block all player-action inputs (perspective swap, inventory,
	# hotbar cycling, drop, pause, debug toggles, etc.). The Respawn button
	# on the DeathScreen Control is unaffected because button clicks don't
	# go through the player's _unhandled_input. Mirrors vanilla MC's
	# GuiGameOver: input is locked except for the on-screen widget.
	# `_physics_process` already gates movement on `health <= 0` (line 1064).
	if health <= 0:
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
		var chest_screen: Control = get_node_or_null("Crosshair/ChestScreen")
		var pause_menu: Control = get_node_or_null("Crosshair/PauseMenu")
		if inv_screen != null and inv_screen.is_open():
			inv_screen.toggle()
		elif table_screen != null and table_screen.is_open():
			table_screen.toggle()
		elif furnace_screen != null and furnace_screen.is_open():
			furnace_screen.close()
		elif chest_screen != null and chest_screen.is_open():
			chest_screen.close()
		elif pause_menu != null:
			pause_menu.open()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_toggle"):
		Game.debug_enabled = not Game.debug_enabled
		_update_debug_label()
	elif event.is_action_pressed("toggle_perspective"):
		perspective = (perspective + 1) % PERSPECTIVE_COUNT
		_apply_perspective()
	elif event.is_action_pressed("toggle_creative"):
		# Creative is its own user-facing mode now — independent of debug.
		# Stays on across debug-toggle cycles; only this binding flips it.
		creative_mode = not creative_mode
		if not creative_mode:
			_is_flying = false
		_update_debug_label()
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


func _update_debug_label() -> void:
	var label: Label = get_node_or_null("Crosshair/DebugLabel") as Label
	if label == null:
		return
	# Creative + debug are independent now (creative no longer requires
	# debug to enable). Show whichever combination is on:
	if Game.debug_enabled and creative_mode:
		label.text = "DEBUG | CREATIVE"
	elif Game.debug_enabled:
		label.text = "DEBUG"
	elif creative_mode:
		label.text = "CREATIVE"
	else:
		label.text = ""


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
	# Mount short-circuit — when riding a mob, the mob's _process drives
	# our global_position to the saddle and the mob reads WASD input
	# directly. Skip everything else (gravity, water, jump, move_and_slide,
	# fall tracking). Sneak key dismounts.
	if _mounted_to != null:
		velocity = Vector3.ZERO
		if Input.is_action_just_pressed("sneak"):
			if _mounted_to.has_method("dismount"):
				_mounted_to.dismount()
		return
	# While the sign-edit screen is open the player is typing text and
	# Input.is_action_pressed("jump") / get_vector still see WASD + Space
	# (LineEdit consumes the InputEvent but the underlying poll state
	# stays latched). Freeze the body so keystrokes don't leak into
	# movement. Vanilla pauses the world entirely on GUI open in
	# singleplayer; we pause just the player. Only SignEditScreen needs
	# this — inventory/chest/furnace are click-only and the player can
	# walk away from them freely.
	var sign_edit: Node = get_node_or_null("Crosshair/SignEditScreen")
	if sign_edit != null and sign_edit.has_method("is_open") and sign_edit.is_open():
		velocity = Vector3.ZERO
		return
	# Post-spawn safety: relocate-if-in-water with throttle. The spiral
	# search inside _relocate_if_unsafe_spawn is ~130k block lookups
	# (radius 32, column scans), so running it per-tick caused <30 fps
	# stutter. Schedule: immediate check on tick 1, then retries every
	# 20 ticks while still in water. Successful relocate ends the budget.
	#
	# Fast-path: if the FIRST exhaustive 32-cell spiral fails, we already
	# know it's open ocean (the spawn-chunk preload covers more than the
	# search radius), so jump straight to the platform instead of making
	# the player flail in water for 4.5 seconds waiting for retries that
	# can't find anything new.
	if _spawn_check_ticks_remaining > 0 and not Game.is_loading:
		_spawn_check_ticks_remaining -= 1
		var first_tick: bool = _spawn_check_ticks_remaining == 89
		var retry_tick: bool = _spawn_check_ticks_remaining % 20 == 0
		if (first_tick or retry_tick) and _is_in_water():
			if _relocate_if_unsafe_spawn():
				_spawn_check_ticks_remaining = 0
			elif first_tick:
				_create_emergency_spawn_platform()
				_spawn_check_ticks_remaining = 0
		# Final fallback (legacy): budget expired, still in water. Kept as
		# belt-and-suspenders in case the relocate path skips the first-tick
		# branch (e.g. _is_in_water flickers during chunk load).
		if _spawn_check_ticks_remaining == 0 and _is_in_water():
			_create_emergency_spawn_platform()
	# Damage cooldown tick — ALWAYS runs before any branch dispatch.
	# Previously this lived near the bottom of the function, which meant
	# the water / flight branches' early returns skipped it: drown damage
	# fired once, set cooldown to 1.0, and while submerged the cooldown
	# never decremented. Second drown attempt was always blocked, damage
	# silently stopped after one heart.
	if _damage_cooldown_remaining > 0.0:
		_damage_cooldown_remaining = maxf(0.0, _damage_cooldown_remaining - delta)
	# Dead — skip all physics, input, air ticking, and fall tracking.
	# Vanilla EntityLiving pegs motX/Y/Z to 0 on death and gates the
	# locomotion branches on `isAlive()`. Our respawn handler restores
	# control; until then, the corpse just sits still on the death screen
	# while the death-tilt animation plays.
	if health <= 0:
		velocity = Vector3.ZERO
		_death_time_sec += delta
		_apply_death_tilt()
		return
	# Air / drowning tick — runs before branch dispatch so the bar updates
	# consistently whether the player is swimming, walking, or flying.
	_tick_air(delta)
	_tick_lava(delta)
	# Creative flight — double-tap jump toggles. Detected here (not in
	# _unhandled_input) so the jump press still triggers a normal ground
	# jump on the first tap; the second tap within FLY_DOUBLE_TAP_SEC
	# promotes it to a flight toggle. While flying, gravity is skipped and
	# sneak/jump drive vertical motion directly.
	if creative_mode and Input.is_action_just_pressed("jump"):
		var now: float = Time.get_ticks_msec() / 1000.0
		if now - _last_jump_press_time < FLY_DOUBLE_TAP_SEC:
			_is_flying = not _is_flying
			velocity.y = 0.0
		_last_jump_press_time = now

	if creative_mode and _is_flying:
		_update_flight_physics()
		move_and_slide()
		# Airborne — no footstep cadence, no fall tracking while flying.
		# (fall tracking is disarmed because _is_flying disables gravity and
		# we reset _fall_peak_y below so we don't take phantom damage when
		# flight ends mid-air.)
		_fall_peak_y = global_position.y
		_was_on_floor = false
		return

	# Water physics — EntityLiving.e()'s water branch in Bukkit/mc-dev.
	# Swim motion replaces land gravity + jump + walk speed entirely while
	# the player's center cell is submerged. Fall tracking is reset so
	# entering water at high speed doesn't read as a landing impact.
	if _is_in_water():
		# Splash on entry — vanilla Entity.N() edge detect: fires when
		# inWater flips false → true. We add two guards vanilla doesn't
		# strictly need but that prevent obvious spam in our 60 Hz /
		# larger-capsule setup:
		#   * cooldown of _SPLASH_MIN_INTERVAL_SEC (jumping in water
		#     flips the AABB water test on/off once per hop)
		#   * minimum entry speed (slow re-entries from a small jump
		#     shouldn't trigger a new splash)
		if not _was_in_water:
			var now: float = Time.get_ticks_msec() / 1000.0
			var entry_speed: float = velocity.length()
			if (
				entry_speed >= _SPLASH_MIN_SPEED
				and now - _last_splash_time >= _SPLASH_MIN_INTERVAL_SEC
			):
				_last_splash_time = now
				SFX.play_splash(velocity)
		_was_in_water = true
		_update_water_physics(delta)
		var attempted_vx: float = velocity.x
		var attempted_vz: float = velocity.z
		move_and_slide()
		# Swim cadence — tick a random swim sample every _SWIM_INTERVAL_M
		# of horizontal travel. Mirrors Entity.h()'s `game.neutral.swim`.
		var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
		_swim_distance += horiz_speed * delta
		if _swim_distance >= _SWIM_INTERVAL_M:
			_swim_distance = 0.0
			SFX.play_swim()
			# Beta Entity.handleWaterMovement spawns bubble particles
			# trailing the entity each swim tick. We piggy-back on the
			# swim cadence so bubbles emit at the same per-distance
			# rate as the swim sound. Position offset behind the player
			# so they trail rather than spawn on the body.
			var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
			if cm != null:
				var trail: Vector3 = global_position - velocity.normalized() * 0.3
				FluidFx.spawn_water_bubble(cm, trail, velocity * 0.2, 3)
		# Auto-step gated by three vanilla-matching conditions (see
		# EntityLiving.e() `positionChanged && this.c(...)`):
		#   1. is_on_wall — touched something horizontally
		#   2. _pushing_into_wall — input actively driving into it
		#      (mirrors `positionChanged` = motion-was-clipped)
		#   3. _head_above_water — eye cell is air. Vanilla's 0.6m step-up
		#      test fails while head is submerged, so gating here prevents
		#      an auto-jumping loop at the water's edge.
		if is_on_wall() and _pushing_into_wall(attempted_vx, attempted_vz) and _head_above_water():
			_try_water_step_up()
		# Keep walk animation running while swimming — Alpha had no
		# dedicated swim pose (introduced in 1.13); Steve's limbs used the
		# normal walk cycle in water. Mining swing still takes priority.
		if _character_model != null and _character_model.has_method("update_walk_animation"):
			var progress: float = _character_model.update_mining_swing(is_mining, delta)
			var arm_locked: bool = _character_model.is_mining_visually()
			_character_model.update_walk_animation(horiz_speed, delta, arm_locked)
			if _fp_hand != null and _fp_hand.visible:
				_apply_fp_swing(_fp_hand, _fp_hand_base_position, _fp_hand_base_rotation, progress)
		_fall_peak_y = global_position.y
		_was_on_floor = false
		return
	# Left water this frame — clear splash/swim state so next entry re-fires.
	_was_in_water = false
	_swim_distance = 0.0

	var on_ladder: bool = _is_on_ladder()

	if not is_on_floor():
		velocity.y += GRAVITY * delta
	if on_ladder:
		velocity.y = maxf(velocity.y, -LADDER_MAX_DESCENT)
		if _is_sneaking:
			velocity.y = maxf(velocity.y, 0.0)
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

	if on_ladder and not _is_sneaking:
		var climbing: bool = (
			Input.is_action_pressed("move_forward") or Input.is_action_pressed("jump")
		)
		if climbing:
			velocity.y = LADDER_CLIMB_SPEED
	var was_grounded: bool = is_on_floor()
	var pre_slide_vel: Vector3 = velocity
	move_and_slide()
	if was_grounded and is_on_wall() and not Input.is_action_pressed("jump"):
		_try_step_up(pre_slide_vel)

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
			# Fence held in FP uses its own rest-pose vars (live-tuneable via
			# ToolTuner). Passing the cube constants here would overwrite the
			# tuner's edits every physics tick — the visible "flash back" the
			# user reported. Route based on the currently-selected item.
			var hb_base_pos: Vector3 = _HELD_BLOCK_POSITION
			var hb_base_rot: Vector3 = _HELD_BLOCK_ROTATION
			if inventory != null:
				var sel: ItemStack = inventory.selected()
				if sel != null and not sel.is_empty() and sel.item_id == Blocks.FENCE:
					hb_base_pos = _held_fence_position
					hb_base_rot = _held_fence_rotation
			_apply_fp_swing(_held_block, hb_base_pos, hb_base_rot, progress)
		# Apply swing to the PIVOT (which sits at the fist), not the mesh —
		# this makes the head arc forward while the handle stays in place.
		if _held_tool_pivot != null and _held_tool_pivot.visible:
			_apply_tool_swing(_held_tool_pivot, _held_tool_position, _held_tool_rotation, progress)

	if on_ladder:
		_fall_peak_y = global_position.y
	_update_fall_tracking()
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
	# Vanilla EntityLiving.damageEntity: `if (noDamageTicks > maxNoDamageTicks
	# / 2.0) { if (f <= lastDamage) drop; else partial-land; }` — hits are
	# only dropped in the FIRST half of the grace period. In the second
	# half, any new damage lands fully and resets the cooldown. Our drown
	# damage fires every 1 s exactly when the cooldown is expiring; with
	# the old `> 0.0` check, a race frame blocked it and drown effectively
	# stopped after one heart. Half-cooldown gate matches vanilla and lets
	# drowns tick through.
	if _damage_cooldown_remaining > DAMAGE_COOLDOWN_SEC * 0.5:
		return
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
		_drop_inventory_on_death()
		Music.set_paused(true)
		died.emit()
		_show_death_screen()


# Adds an instantaneous impulse to the player's velocity — used by
# Explosion._apply_entity_damage to fling the player away from a TNT
# blast. Vanilla ks.java:96-98 adds (d4, d3, d2) × d13 directly to the
# entity's velocity; we receive the pre-scaled impulse vector and apply
# it the same way. Gravity + air drag handle the arc on subsequent frames.
func apply_explosion_knockback(impulse: Vector3) -> void:
	velocity += impulse


# Vanilla EntityPlayer.dropAllItems / inventoryDrops — every non-empty
# slot (hotbar + main + armor + craft grid) gets ejected as a
# DroppedItem at the player's eye position with a small random outward
# velocity. Slots are cleared in-place so the inventory is empty when
# the player respawns.
func _drop_inventory_on_death() -> void:
	if inventory == null:
		return
	var chunk_manager: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if chunk_manager == null:
		return
	var eye_pos: Vector3 = global_position + Vector3(0, _CAM_FIRST_PERSON.y, 0)
	# Iterate every persistent slot (HOTBAR + MAIN + ARMOR + CRAFT_GRID).
	# CRAFT_RESULT is virtual / re-derived, so skip it.
	for i in range(Inventory.CRAFT_START + Inventory.CRAFT_SIZE):
		var stack: ItemStack = inventory.slots[i]
		if stack.is_empty():
			continue
		var dropped_id: int = stack.item_id
		var count: int = stack.count
		stack.clear()
		for _n in range(count):
			# Random spread — vanilla scatters drops in a small cone
			# around the player so they don't all stack on one tile.
			var fling := Vector3(
				randf_range(-2.5, 2.5), randf_range(0.5, 1.5), randf_range(-2.5, 2.5)
			)
			var item := DroppedItem.new()
			chunk_manager.add_child(item)
			item.global_position = eye_pos
			item.setup(dropped_id, fling, DroppedItem.PLAYER_DROP_DELAY_SEC)
	inventory.changed.emit()


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
	Music.set_paused(false)
	# Force-load the spawn chunk synchronously. Without this, dying far
	# from origin can return to an unloaded chunk (0,0) — the player
	# falls through AIR (unloaded cells read as AIR), drops past y=-20,
	# the y < -20 fallback teleports back to the same unloaded chunk,
	# and the cycle repeats indefinitely. Initial boot has this same
	# protection via ChunkManager._initial_load → _spawn_chunk_sync.
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm != null and cm.has_method("_spawn_chunk_sync"):
		cm.call("_spawn_chunk_sync", Vector2i(0, 0))
	global_position = Vector3(8, 100.0, 8)
	velocity = Vector3.ZERO
	_fall_peak_y = global_position.y
	_fall_immune_next_landing = true
	_damage_cooldown_remaining = 0.0
	_regen_accum = 0.0
	health = MAX_HEALTH
	# Re-arm the spawn-relocate check so a respawn into water / floating /
	# above an unloaded chunk gets corrected over the next ~30 physics
	# ticks (mirrors the initial-spawn safety net). Multi-tick budget so
	# a respawn whose chunks haven't streamed in yet still gets relocated
	# once they load.
	_spawn_check_ticks_remaining = 90
	# Clear fire + lava state — vanilla Entity.reset() zeros bg (fireTicks)
	# on respawn. Without this the trailing burn keeps ticking damage after
	# the player teleports back to spawn.
	_fire_remaining_sec = 0.0
	_fire_burn_tick = 0.0
	_was_in_lava = false
	_lava_tick = 0.0
	# Clear death-tilt so the view returns to upright immediately on respawn.
	_death_time_sec = 0.0
	if _camera != null:
		_camera.rotation.z = 0.0
	if _character_model != null:
		_character_model.rotation.z = 0.0
		if _character_model.has_method("set_on_fire"):
			_character_model.call("set_on_fire", false)
	health_changed.emit(health, MAX_HEALTH)


# Vanilla EntityLiving render-tilt on death: over ~20 ticks (1 s) the
# entity's body roll interpolates from 0° to 90°, so the model lies flat.
# We apply it to the camera (for first-person view tilt; the camera IS
# the head in FP) and to the character model (for third-person so the
# body visibly falls). The Player CharacterBody3D itself stays upright so
# the capsule collision doesn't shift, matching vanilla where the entity
# bounding box doesn't change on death.
func _apply_death_tilt() -> void:
	var progress: float = clampf(_death_time_sec / _DEATH_TILT_DURATION_SEC, 0.0, 1.0)
	var angle: float = deg_to_rad(_DEATH_TILT_MAX_DEG) * progress
	if _camera != null:
		_camera.rotation.z = angle
	if _character_model != null:
		_character_model.rotation.z = angle


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


# Vanilla EntityLiving.P() — full AABB overlap test against water blocks
# (Bukkit/mc-dev EntityLiving.a(Material)). We approximate with three
# vertical probes along the capsule spine (feet, center, head) since the
# 0.3×1.8 capsule spans up to two cells vertically.
#
# Center-only sampling was the "auto-jumps once, can't clear shore" bug:
# step-up lifts the origin past the water cell boundary in one frame, water
# mode ends, land gravity (-32 m/s²) slams the player back down instead of
# letting the arc carry them forward onto the shore. With feet probes,
# water mode persists until the FEET clear water — matching vanilla's AABB
# behavior and giving the step-up impulse its full ~0.75 s to carry the
# player forward.
# Vanilla EntityLiving drowning tick (Bukkit/mc-dev EntityLiving.java ~L147):
#   if (head in water) airTicks = j(airTicks);     // decrements
#   if (airTicks == -20) { airTicks = 0; damageEntity(DROWN, 2); bubbles; }
#   else airTicks = 300;                           // full refill out of water
# Creative bypasses drowning entirely (`abilities.isInvulnerable` branch).
# We emit `air_changed` only when the fraction actually changes enough to
# repaint a bubble slot, to avoid a signal every frame while submerged.
func _tick_air(delta: float) -> void:
	var head_submerged: bool = _head_in_water()
	if head_submerged != _was_head_submerged:
		_was_head_submerged = head_submerged
		head_submerged_changed.emit(head_submerged)
	if head_submerged and not creative_mode:
		_air_sec -= delta
		if _air_sec <= 0.0:
			_drown_tick += delta
			if _drown_tick >= _DROWN_DAMAGE_INTERVAL_SEC:
				_drown_tick = 0.0
				take_damage(_DROWN_DAMAGE, DAMAGE_DROWN)
	else:
		# Not submerged — vanilla snaps air back to full instantly.
		_air_sec = _AIR_MAX_SEC
		_drown_tick = 0.0
	air_changed.emit(clampf(_air_sec / _AIR_MAX_SEC, 0.0, 1.0))


# Lava contact damage. Mirrors vanilla Entity.burn (Alpha source at
# vendor/alpha-1.2.6-src/src/ij.java) — fires 4 damage per tick while
# the entity's AABB overlaps a lava cell. Creative-mode bypasses this
# just like drowning. We sample feet + body-center cells since the
# player's AABB spans ~1.8 m; anywhere we overlap a LAVA block should
# trigger. Damage timer is 0.5 s so it respects hurt-resistant-time
# without creating a frame-rate-dependent pulse.
func _tick_lava(delta: float) -> void:
	if creative_mode:
		# Vanilla lw.java:194-198 — when `bm` (creative) is set, the fire
		# counter `bg` drains by 4 per tick instead of 1. At 20 TPS that's
		# 80 ticks/sec → a fresh 600-tick lava ignite burns out in 7.5 s
		# (vs 30 s in survival). No new damage is dealt; just drain.
		_lava_tick = 0.0
		_was_in_lava = false
		if _fire_remaining_sec > 0.0:
			_fire_remaining_sec = maxf(0.0, _fire_remaining_sec - delta * 4.0)
			_fire_burn_tick = 0.0
		return
	var in_lava: bool = _is_in_lava()
	# FIRE contact seeds the same fire-remaining timer lava uses. Vanilla's
	# BlockFire.a(cy,...,Entity,ao2) calls `entity.setFire(8)` — 8 ticks
	# = 0.4 s, re-seeded while standing IN the fire, so effectively the
	# timer stays topped up. We re-seed to _FIRE_AFTER_LAVA_SEC (30s) so
	# the burn continues after stepping off the fire, matching lava.
	var in_fire: bool = _is_in_fire()
	if in_fire:
		_fire_remaining_sec = _FIRE_AFTER_LAVA_SEC
	# Water extinguishes fire — vanilla Entity.K() / extinguish() zeroes
	# the fire counter when the entity is in water (ij.java:406-411). One
	# fizz SFX on the extinguish edge, then the trailing burn stops.
	if _fire_remaining_sec > 0.0 and _is_in_water():
		_fire_remaining_sec = 0.0
		_fire_burn_tick = 0.0
		SFX.play_fizz(false)
	# Rising-edge fizz + fire-timer seed. Vanilla fires both on
	# isInLava() transition: one-shot sizzle sound + Entity.setFire(15).
	if in_lava and not _was_in_lava:
		SFX.play_fizz(false)
	if in_lava:
		_fire_remaining_sec = _FIRE_AFTER_LAVA_SEC
	_was_in_lava = in_lava
	if in_lava:
		_lava_tick += delta
		if _lava_tick >= _LAVA_DAMAGE_INTERVAL_SEC:
			_lava_tick = 0.0
			take_damage(_LAVA_DAMAGE, DAMAGE_LAVA)
	else:
		_lava_tick = 0.0
	# Cactus contact damage. Vanilla BlockCactus.b deals 1 HP every
	# tick the entity AABB intersects a cactus cell shrunk by 1/16.
	if _is_touching_cactus():
		_cactus_tick += delta
		if _cactus_tick >= _CACTUS_DAMAGE_INTERVAL_SEC:
			_cactus_tick = 0.0
			take_damage(_CACTUS_DAMAGE, DAMAGE_CACTUS)
	else:
		_cactus_tick = 0.0
	# Fire-after-lava trail. Ticks down regardless of current lava state
	# (being re-seeded above when the player is still in lava). Each
	# _FIRE_BURN_INTERVAL_SEC applies 1 damage until the 15-s window
	# expires. Vanilla's is implemented via Entity.fire counter; same
	# result, simpler timer here.
	if _fire_remaining_sec > 0.0:
		_fire_remaining_sec = maxf(0.0, _fire_remaining_sec - delta)
		_fire_burn_tick += delta
		if _fire_burn_tick >= _FIRE_BURN_INTERVAL_SEC:
			_fire_burn_tick = 0.0
			if not in_lava:
				# Only tick the trailing burn OUTSIDE lava — while in
				# lava, _LAVA_DAMAGE above already dominates. Avoids
				# stacking 4+1 hits per tick.
				take_damage(_FIRE_BURN_DAMAGE, DAMAGE_LAVA)
	else:
		_fire_burn_tick = 0.0
	# Third-person flame billboards on the character model. FP is handled
	# by fire_overlay.gd; TP needs a visible flame around the body.
	if _character_model != null and _character_model.has_method("set_on_fire"):
		_character_model.call("set_on_fire", on_fire())


# True while the player is taking or recovering from lava damage.
# HUD overlay reads this to tint the screen; same semantic as
# `_was_head_submerged` for water. Exposed as a read-only property for
# the HUD layer via Player.on_fire.
func on_fire() -> bool:
	return _fire_remaining_sec > 0.0 or _was_in_lava


# True if any of the 3 cells the player's AABB spans (feet / waist /
# head) is lava. Vanilla Alpha checks Entity.isInsideOfMaterial(LAVA);
# our sampling is a cheap approximation that still catches the common
# cases (standing in, walking into, falling in). Corner-straddle edge
# cases are rare and the next tick resolves them.
# True if the player capsule overlaps any CACTUS cell. Vanilla cactus
# AABB is shrunk by 1/16 on each side, so a player who's just outside
# the cactus block boundary doesn't take damage. We approximate by
# checking the 3 cardinal cells the player occupies (feet/waist/eye)
# and the 4 horizontal neighbours, using a 0.4-unit lateral overlap
# threshold (player radius ~0.3 + cactus radius 0.4375 - tolerance).
func _is_touching_cactus() -> bool:
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("get_world_block"):
		return false
	var px: float = global_position.x
	var pz: float = global_position.z
	var fx: int = int(floor(px))
	var fz: int = int(floor(pz))
	for dy: float in [-0.85, 0.0, 0.7]:
		var fy: int = int(floor(global_position.y + dy))
		# Check the cell the player is in plus 4 neighbours; the lateral
		# overlap test catches grazing contacts at cell edges.
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cx: int = fx + dx
				var cz: int = fz + dz
				if cm.get_world_block(Vector3i(cx, fy, cz)) != Blocks.CACTUS:
					continue
				# Cactus cell occupies (cx + 0.0625, cz + 0.0625) to
				# (cx + 0.9375, cz + 0.9375). Player is a 0.6-wide capsule
				# centred at (px, pz). Closest distance from player edge
				# to cactus AABB along each axis:
				var dx_dist: float = max(0.0, abs(px - (float(cx) + 0.5)) - 0.4375 - 0.3)
				var dz_dist: float = max(0.0, abs(pz - (float(cz) + 0.5)) - 0.4375 - 0.3)
				if dx_dist <= 0.0 and dz_dist <= 0.0:
					return true
	return false


func _is_in_lava() -> bool:
	# `global_position` is the CAPSULE CENTER (not the feet) — the collision
	# shape is a 1.8-tall Capsule3D with default zero transform, so the feet
	# sit at center − 0.9. Sample the three player-occupied cells at feet /
	# waist / eye relative to center, matching `_is_in_water`. Earlier values
	# (+0.1, +0.9, +1.6) sat entirely ABOVE the capsule and never intersected
	# a 1-block lava puddle the player was standing in.
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("get_world_block"):
		return false
	var x: int = int(floor(global_position.x))
	var z: int = int(floor(global_position.z))
	for dy: float in [-0.85, 0.0, 0.7]:
		var y: int = int(floor(global_position.y + dy))
		if Blocks.is_lava(cm.get_world_block(Vector3i(x, y, z))):
			return true
	return false


# Any of the 3 player AABB cells is FIRE. Used to trigger the fire-damage
# timer without the 0.5s lava cadence (fire already uses the 1 dmg/sec
# fire-trail path, so a single contact re-seeds the trail).
func _is_in_fire() -> bool:
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("get_world_block"):
		return false
	var x: int = int(floor(global_position.x))
	var z: int = int(floor(global_position.z))
	for dy: float in [-0.85, 0.0, 0.7]:
		var y: int = int(floor(global_position.y + dy))
		if cm.get_world_block(Vector3i(x, y, z)) == Blocks.FIRE:
			return true
	return false


# Head submerged = eye cell is water. Matches vanilla Entity.a(Material)
# which samples at `locY + headHeight` (0 for Entity, but eye-level for
# players in EntityLiving overrides).
func _head_in_water() -> bool:
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("get_world_block"):
		return false
	var head_cell := Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + 0.7)),
		int(floor(global_position.z))
	)
	return Blocks.is_water(cm.get_world_block(head_cell))


func _is_in_water() -> bool:
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("get_world_block"):
		return false
	var x: int = int(floor(global_position.x))
	var z: int = int(floor(global_position.z))
	var sample_dys: Array = [-0.85, 0.0, 0.7]  # feet, center, eye (inside capsule)
	for dy: float in sample_dys:
		var y: int = int(floor(global_position.y + dy))
		if Blocks.is_water(cm.get_world_block(Vector3i(x, y, z))):
			return true
	return false


# True when the player's eye cell is not water — their head has cleared
# the surface. Used to gate the auto-step (vanilla's 0.6m step-up check
# only passes when you've already swum high enough to breach, otherwise
# the overhead cell is water and `this.c(...)` fails).
func _head_above_water() -> bool:
	return not _head_in_water()


# Vanilla's `positionChanged` test, re-expressed for CharacterBody3D. We
# were pushing into a wall this frame iff (a) our attempted horizontal
# velocity had meaningful magnitude and (b) it pointed into the wall we
# bumped (opposite to get_wall_normal, which points OUTWARD from the
# wall toward us).
func _pushing_into_wall(attempted_vx: float, attempted_vz: float) -> bool:
	var attempted: Vector3 = Vector3(attempted_vx, 0, attempted_vz)
	if attempted.length_squared() < 0.25:  # ignore < 0.5 m/s jitter
		return false
	var wall_normal: Vector3 = get_wall_normal()
	# Dot against -wall_normal: positive means we're aimed into the wall.
	# The 0.3 threshold kills grazing contact where the input is nearly
	# parallel to the wall.
	return attempted.normalized().dot(-wall_normal) > 0.3


func _is_on_ladder() -> bool:
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("get_world_block"):
		return false
	var x: int = int(floor(global_position.x))
	var z: int = int(floor(global_position.z))
	var foot_y: int = int(floor(global_position.y - 0.85))
	if cm.get_world_block(Vector3i(x, foot_y, z)) == Blocks.LADDER:
		return true
	if cm.get_world_block(Vector3i(x, foot_y + 1, z)) == Blocks.LADDER:
		return true
	return false


# Vanilla's swim-onto-land auto-step. Fires when move_and_slide reports a
# horizontal wall collision. Probes the block that would be the step-up
# cell — one above the player's waist in the direction of the wall. If
# that cell is passable (AIR or water), nudge velocity.y up to 6 m/s so
# the player hops onto the shore. Matches the motY = 0.3 line in
# EntityLiving.e() in Bukkit/mc-dev.
# Vanilla stepHeight = 0.5f (EntityLiving.P). When the player walks into
# a wall while grounded, test whether lifting the body by STEP_HEIGHT
# clears the obstacle. If so, keep the elevated position and re-run
# horizontal movement — the player smoothly walks up stairs / slabs.
func _try_step_up(intended_vel: Vector3) -> void:
	var h_vel := Vector3(intended_vel.x, 0.0, intended_vel.z)
	if h_vel.length_squared() < 0.001:
		return
	var saved_pos: Vector3 = global_position
	var dt: float = get_physics_process_delta_time()
	# Phase 1: lift up by STEP_HEIGHT.
	move_and_collide(Vector3.UP * STEP_HEIGHT)
	# Phase 2: try horizontal movement at elevated height.
	move_and_collide(h_vel * dt)
	# Phase 3: snap back down to floor.
	move_and_collide(Vector3.DOWN * (STEP_HEIGHT + 0.05))
	# Check horizontal progress.
	var dx: float = global_position.x - saved_pos.x
	var dz: float = global_position.z - saved_pos.z
	if dx * dx + dz * dz < 0.0001:
		global_position = saved_pos
		return
	velocity = intended_vel
	velocity.y = 0.0


func _try_water_step_up() -> void:
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("get_world_block"):
		return
	var wall_normal: Vector3 = get_wall_normal()
	if wall_normal.length_squared() < 0.01:
		return
	# Sample the cell just inside the wall (0.5m past the capsule edge) one
	# block above the player's waist. If that cell is passable, the step is
	# physically possible and vanilla would have fired its canMove check.
	var into_wall: Vector3 = -wall_normal
	var probe_x: int = int(floor(global_position.x + into_wall.x * 0.5))
	var probe_z: int = int(floor(global_position.z + into_wall.z * 0.5))
	var probe_y: int = int(floor(global_position.y + 1.0))
	var above_id: int = cm.get_world_block(Vector3i(probe_x, probe_y, probe_z))
	if above_id == Blocks.AIR or Blocks.is_water(above_id):
		# Clamp UP only — don't cancel a downward swim.
		velocity.y = maxf(velocity.y, 6.0)


# Port of EntityLiving.e()'s `this.P()` branch. Per-tick vanilla ops
# converted to timestep-independent form so the same feel holds at any
# physics frame rate:
#   v *= pow(WATER_DRAG_PER_TICK, delta*20)        # the *= 0.5 per tick
#   v.y -= WATER_GRAVITY_PER_TICK * delta*20       # the -= 0.02 per tick
#   v.y += SWIM_UP_PER_TICK * delta*20 (if jump)   # vanilla's swim thrust
# Horizontal input uses WATER_MOVE_SPEED as a direct target since the
# drag-plus-thrust equilibrium is what we're shooting for (vanilla's
# `this.a(f, f1, 0.02F)` thrust + 0.5 drag settles at ~2 m/s; our direct
# 50%-of-walk-speed target is close enough and avoids a solver loop).
func _update_water_physics(delta: float) -> void:
	var tick_scale: float = delta * 20.0  # how many 20 Hz vanilla ticks this frame spans
	# Horizontal input → target velocity (X/Z). No input → drag-only.
	var input_dir: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_forward", "move_back"
	)
	var direction: Vector3 = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction != Vector3.ZERO:
		velocity.x = direction.x * WATER_MOVE_SPEED
		velocity.z = direction.z * WATER_MOVE_SPEED
	else:
		var drag: float = pow(WATER_DRAG_PER_TICK, tick_scale)
		velocity.x *= drag
		velocity.z *= drag
	# Vertical: vanilla drag, vanilla gravity, optional swim-up thrust.
	# No passive buoyancy / no surface clamp — vanilla water has neither.
	# Verified against EntityLiving.e() water branch (Bukkit/mc-dev):
	#   motY *= 0.5
	#   motY -= 0.02
	#   [swim thrust if jump pressed]
	# Terminal sink rate ≈ 0.8 m/s; holding jump reverses it. The visible
	# "surface bob" in vanilla is the natural rhythm of tap-jump to stay
	# afloat, not a buoyancy force.
	var v_drag: float = pow(WATER_DRAG_PER_TICK, tick_scale)
	velocity.y *= v_drag
	velocity.y -= WATER_GRAVITY_PER_TICK * tick_scale * 20.0
	if Input.is_action_pressed("jump"):
		# Upward thrust, scaled like vanilla's motY += 0.04/tick in m/s².
		velocity.y += SWIM_UP_PER_TICK * tick_scale * 20.0
	# Flow-current push. Vanilla ld.java:157 `a(cy,x,y,z,Entity,Vec3)` adds
	# the fluid's flow vector to the entity's motion each tick, scaled by
	# 0.014 per vanilla EntityLiving.move(). BlockFluids.flow_vector returns
	# a unit-ish world-space Vec3 from the level gradient across neighbors;
	# we apply it as an impulse so the player drifts downstream instead of
	# standing motionless in rapids.
	_apply_fluid_flow_push(tick_scale)


func _apply_fluid_flow_push(tick_scale: float) -> void:
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null:
		return
	var cell := Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + 0.9)),  # waist-ish so we don't miss the cell
		int(floor(global_position.z))
	)
	var id: int = cm.get_world_block(cell)
	if not Blocks.is_fluid(id):
		return
	var flow: Vector3 = BlockFluids.flow_vector(cm, cell, id)
	if flow.length_squared() == 0.0:
		return
	var push: Vector3 = flow * _FLUID_FLOW_PUSH_PER_TICK * tick_scale * 20.0
	velocity.x += push.x
	velocity.z += push.z


# Horizontal motion at FLY_SPEED (ignores sneak slow-down; vanilla doesn't
# crouch while flying). Vertical: jump = up, sneak OR fly_down (Ctrl/Cmd)
# = down, neither = hover. Both descend bindings are first-class — sneak
# matches vanilla Java, Ctrl/Cmd is the more ergonomic alt.
func _update_flight_physics() -> void:
	var input_dir: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_forward", "move_back"
	)
	var direction: Vector3 = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	velocity.x = direction.x * FLY_SPEED
	velocity.z = direction.z * FLY_SPEED
	if Input.is_action_pressed("jump"):
		velocity.y = FLY_VERTICAL_SPEED
	elif Input.is_action_pressed("sneak") or Input.is_action_pressed("fly_down"):
		velocity.y = -FLY_VERTICAL_SPEED
	else:
		velocity.y = 0.0


func _update_sneak() -> void:
	if sneak_toggle:
		if Input.is_action_just_pressed("sneak"):
			_is_sneaking = not _is_sneaking
	else:
		_is_sneaking = Input.is_action_pressed("sneak")


# Scan the 16×16 spawn chunk for the first column whose surface is
# comfortably above sea level. If none found, fall back to the highest
# column we saw (best of bad options — might still be water but
# shallowest spot). Bounded to chunk (0,0) so we never move the player
# beyond the chunk loader's initial-load radius.
# Post-load spawn safety net. Walk a spiral outward from the player's
# current (x, z) and look at the actual loaded-chunk blocks for a column
# whose surface is dry land at or above sea level. Teleports the player
# to that column. Returns true on success (relocated OR already safe),
# false if no safe column found in the loaded radius (so the caller
# can keep retrying as more chunks stream in).
func _relocate_if_unsafe_spawn() -> bool:
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("get_world_block"):
		return false
	# Already safe? Spawn in water or floating in air = unsafe.
	if not _is_in_water() and not _is_floating_in_air(cm):
		return true  # nothing to do, stop retrying
	var px: int = int(floor(global_position.x))
	var pz: int = int(floor(global_position.z))
	# Spiral search outward.
	for r in range(1, 33):
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if abs(dx) != r and abs(dz) != r:
					continue  # only ring at radius r
				var x: int = px + dx
				var z: int = pz + dz
				# Find topmost solid (non-AIR, non-WATER) cell in this column.
				var sy: int = -1
				for y in range(127, 0, -1):
					var b: int = cm.get_world_block(Vector3i(x, y, z))
					if b != Blocks.AIR and not Blocks.is_water(b):
						sy = y
						break
				if sy < Worldgen.SEA_LEVEL:
					continue  # underwater seabed
				# Player capsule is ~1.8 tall. Need 2 cells of AIR clearance
				# directly above the surface. Without this we can teleport
				# into a tight column (leaves overhang, narrow cave mouth)
				# and the player ends up stuck inside a block.
				var above1: int = cm.get_world_block(Vector3i(x, sy + 1, z))
				var above2: int = cm.get_world_block(Vector3i(x, sy + 2, z))
				if above1 != Blocks.AIR or above2 != Blocks.AIR:
					continue
				# Found a dry land column — teleport here. Player capsule
				# centre needs to sit at sy+2.0 so feet (centre - 0.9) land
				# at sy+1.1, just above the solid surface block at sy. The
				# old `sy + 1.5` put feet at sy+0.5 — INSIDE the surface
				# block — and the CharacterBody3D got wedged.
				global_position = Vector3(float(x) + 0.5, float(sy) + 2.0, float(z) + 0.5)
				velocity = Vector3.ZERO
				_fall_immune_next_landing = true
				return true
	return false  # no safe column found, caller should retry


# Last-resort spawn fallback when the spiral search fails to find dry
# land within radius (open ocean spawn). Drops a 5x5 GRASS platform at
# y = SEA_LEVEL just above the water surface, clears the air column
# above so the player can stand, and teleports the player on top.
# Only overwrites WATER / AIR — never destroys existing terrain (so a
# tiny island that the spiral missed because of a chunk-load race
# stays intact).
#
# Vanilla Alpha treats water as is_replaceable for falling blocks, so
# sand/gravel sinks through it (BlockFalling.h sees fluid below as
# unsupported). Using SAND for the platform meant the moment a
# neighbour-update fired (e.g. the water clear at +1) the sand would
# spawn a FallingBlock and disappear into the seabed, dropping the
# player back into the water. GRASS has no gravity → platform stays
# put regardless of neighbour updates.
func _create_emergency_spawn_platform() -> void:
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("set_world_block"):
		return
	var px: int = int(floor(global_position.x))
	var pz: int = int(floor(global_position.z))
	# SEA_LEVEL = 64; water tops out at y=63 (cell at y=63 is the topmost
	# water layer, top edge at y=64). Place GRASS at y=64 — sits at the
	# water surface, player stands on top at y=65.
	var platform_y: int = Worldgen.SEA_LEVEL
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			var gx: int = px + dx
			var gz: int = pz + dz
			var here: int = cm.get_world_block(Vector3i(gx, platform_y, gz))
			if here == Blocks.AIR or Blocks.is_water(here):
				cm.set_world_block(Vector3i(gx, platform_y, gz), Blocks.GRASS)
			# Clear the cell above so the player has head clearance.
			var above: int = cm.get_world_block(Vector3i(gx, platform_y + 1, gz))
			if Blocks.is_water(above):
				cm.set_world_block(Vector3i(gx, platform_y + 1, gz), Blocks.AIR)
	global_position = Vector3(float(px) + 0.5, float(platform_y) + 2.0, float(pz) + 0.5)
	velocity = Vector3.ZERO
	_fall_immune_next_landing = true


# True if the column at the player's position has only AIR around them
# (no solid block within 4 cells below) — they're floating in air with
# no landing in sight.
func _is_floating_in_air(cm: Node) -> bool:
	var x: int = int(floor(global_position.x))
	var y: int = int(floor(global_position.y))
	var z: int = int(floor(global_position.z))
	for dy in range(0, 4):
		var b: int = cm.get_world_block(Vector3i(x, y - dy, z))
		if b != Blocks.AIR and not Blocks.is_water(b):
			return false  # solid block within 4 cells below
	return true


func _find_safe_spawn_in_chunk() -> Vector2i:
	var min_land_y: int = Worldgen.SEA_LEVEL + 2
	var fallback: Vector2i = Vector2i(8, 8)
	var best_y: int = 0
	for x in range(0, 16):
		for z in range(0, 16):
			var surface_y: int = Worldgen.surface_height(x, z)
			if surface_y >= min_land_y:
				return Vector2i(x, z)
			if surface_y > best_y:
				best_y = surface_y
				fallback = Vector2i(x, z)
	return fallback


# Called by a mob (currently Pig) when the player mounts/dismounts.
# Disables the player's collision shape while riding so the mob's
# CharacterBody3D doesn't push us off the saddle, and clears velocity
# so we don't carry residual momentum from the moment of mounting.
func set_mount(mob: Node3D) -> void:
	_mounted_to = mob
	var cshape: CollisionShape3D = _find_collision_shape()
	if mob != null:
		velocity = Vector3.ZERO
		if cshape != null:
			_pre_mount_collision_disabled = cshape.disabled
			cshape.disabled = true
	else:
		if cshape != null:
			cshape.disabled = _pre_mount_collision_disabled


func _find_collision_shape() -> CollisionShape3D:
	for child in get_children():
		if child is CollisionShape3D:
			return child
	return null
