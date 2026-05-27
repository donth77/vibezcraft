class_name MobBase
extends CharacterBody3D

# gdlint: disable=max-file-lines

const _VOXEL_COLLIDER: GDScript = preload("res://scripts/entities/voxel_collider.gd")

# Shared base for every living entity in the game (pigs, cows, zombies,
# etc.). Mirrors vanilla `lw.java` (Entity) + `qy.java` (EntityLiving)
# at a level that's enough to ship the first concrete mob (Pig) without
# locking in AI specifics here. Subclasses add behavior on top:
#   * PassiveAI (Pig/Cow/Chicken/Sheep) — wander + flee
#   * HostileAI (Zombie/Skeleton/Spider/Creeper/Slime) — target + attack
#
# This M0 cut intentionally ships the minimum:
#   * Gravity + ground-friction physics via CharacterBody3D.move_and_slide
#   * Health + take_damage + knockback impulse
#   * Death → spawn item drop(s) → queue_free
#   * A "hurt flash" red tint via mesh material_override on every
#     MeshInstance3D descendant (~vanilla's setBeenAttacked render tint)
#
# Out of M0 (added in later mob phases):
#   * AI FSM (idle/wander/target/attack/flee)
#   * Pathfinding (voxel A*)
#   * Despawn radius check (>128 m from nearest player)
#   * Per-mob attack damage path
#   * Daylight burn (zombies/skeletons)
#   * Per-mob sounds
#
# Known gaps vs vanilla hf.java (EntityLiving) — documented here so the
# next mob-phase author knows what's missing rather than has to re-audit:
#   * Death animation delay (vanilla `O = 20` ticks of falling-over
#     before despawn) — we queue_free instantly. Cosmetic.
#   * Armor catch-up damage (vanilla applies the DIFFERENCE if a 2nd
#     hit during invuln window is bigger than the first). We just drop
#     mid-cooldown hits — same shortcut player.gd uses.
#   * Last-attacker ref (vanilla `a(lw, int)` takes the attacker Entity
#     for "who killed me" tracking). We only pass knockback direction.
#     Add when arrows / projectile damage need to credit the shooter.
#   * Fall damage — mobs ignore vertical impact damage. Add when
#     pathfinding can step off a cliff.

# Vanilla EntityLiving.b()` — entities accelerate downward by 0.08/tick
# = 1.6/sec² before drag. Per-second × 20² TPS = -16 m/s² as continuous
# gravity. Matches FallingBlock + PrimedTNT.
const GRAVITY: float = -16.0
const TERMINAL_VELOCITY: float = -32.0

# Frictional decay applied to horizontal velocity each frame. Mirrors
# vanilla `lw.java::aF` ground-friction factor 0.546 per tick → ≈0.001
# per second. Tuned so a knockback impulse decays in ~0.5 s.
const _GROUND_FRICTION: float = 0.001

# Invulnerability window after a hit. Vanilla EntityLiving.hurtResistantTime
# = 20 ticks = 1.0 s (hf.java:30 `bj = 20`). Matches vanilla so rapid
# left-click spam doesn't melt a mob in a fraction of vanilla's intended
# time-to-kill.
const _DAMAGE_COOLDOWN_SEC: float = 1.0

# Hurt flash duration — vanilla `EntityLivingBase.hurtTime` lasts 10
# ticks = 0.5 s with the red tint shader. We mirror by overriding
# material_override on every MeshInstance3D descendant for that window.
const _HURT_FLASH_SEC: float = 0.3

# Death animation — vanilla `hf.O` counts up 20 ticks (1 s at 20 TPS)
# while the renderer rotates the model on its Z axis up to 90°
# (`ec.java`: `GL11.glRotatef((O + partialTick - 1) / 20 * 1.6f * 90,
# 0, 0, 1)`). Mob tilts to the LEFT and falls over before despawning.
# Drops + death SFX still fire immediately at die() so the player
# doesn't have to wait to collect them.
const _DEATH_DURATION: float = 1.0
const _DEATH_TILT_ANGLE: float = -PI * 0.5  # 90° fall to left (vanilla)

# Knockback magnitudes when hit. Vanilla applies `xz × 0.4, y × 0.4` to
# the entity's velocity (scaled by attacker's knockback enchant — we
# have no enchants, so flat values).
const KNOCKBACK_HORIZONTAL: float = 5.0
const KNOCKBACK_VERTICAL: float = 4.0
# Stuck-arrows cosmetic — see `add_stuck_arrow` for behavior. Max
# count + decay window mirror vanilla EntityLiving (`arrowsInBody`
# capped at ~14, one falls off every 600 ticks ≈ 30 s @ 20 tps).
const _STUCK_ARROW_MAX: int = 12
const _STUCK_ARROW_DECAY_SEC: float = 30.0

# --- Environment hazards (water / lava / fire) — vanilla hf.java::b
# (water/lava-aware movement) + hf.java::B (air ticks + contact damage).
# All passive mobs inherit; hostile mobs will too when they land.

# In-fluid movement — replaces normal gravity. Vanilla water:
# `velocity *= 0.8 / tick`, gravity = 0.02 m/tick downward; lava:
# `velocity *= 0.5 / tick`, gravity = 0.02. Effective terminal velocity
# is small enough that the swim-impulse below dominates and the mob
# bobs at the surface.
const _WATER_DRAG_PER_TICK: float = 0.8
const _LAVA_DRAG_PER_TICK: float = 0.5
const _FLUID_GRAVITY: float = -0.4  # 0.02 m/tick × 20 = 0.4 m/s² down

# Swim assist — vanilla `hf.java:588-592` toggles the jumping flag with
# 80 % probability per tick while submerged, and `hf.java:518-525` then
# adds 0.04 m/tick (= 0.8 m/s instant) upward to motionY when the
# jumping flag is set AND the entity is in water or lava. Net effect:
# ~+0.06 m/tick average upward drift, enough to overcome FLUID_GRAVITY
# and float the mob to the surface.
const _SWIM_IMPULSE: float = 0.8
const _SWIM_CHANCE: float = 0.8

# Drowning — vanilla `hf.java:114-126`. The entity's `bk` (air) field
# decrements 1 / tick while the EYE cell is water. When `bk <= -20`
# (20 ticks past zero) vanilla deals 2 damage and resets to 0, so
# damage continues at 1 Hz until the head clears water. Max air `bh`
# is 300 ticks (15 s) in vanilla; we use 200 ticks (10 s) — the value
# that ships in the v1.2.6 EntityHuman and most mob subclasses inherit
# unchanged. Damage is dealt through `take_damage`, so the 1 s invuln
# cooldown applies and the visible cadence stays at the vanilla rate.
const _MAX_AIR_TICKS: int = 200
const _DROWN_INTERVAL_TICKS: int = 20
const _DROWN_DAMAGE: int = 2

# Fire / lava contact damage — vanilla `fa.java` (Entity) applies 1 HP
# every 20 ticks while standing in a BlockFire cell, and 4 HP every 20
# ticks while inside a lava block. We mirror both with a single tick
# accumulator (cleared when the mob steps out of fire/lava).
const _FIRE_DAMAGE: int = 1
const _LAVA_DAMAGE: int = 4
const _FIRE_TICK_INTERVAL_TICKS: int = 20

# Lingering on-fire state — vanilla `fa.h(int)` (setOnFire) sets the
# fire timer when the entity touches lava (15 s) or fire (8 s), and
# the timer ticks down each frame in fa.java::B(). While the timer is
# > 0 the entity continues to take fire damage even after leaving the
# hazard, and renders with the flame sprite overlay. Water extinguishes
# immediately (sets timer to 0 in vanilla qy::B).
const _LAVA_ON_FIRE_TICKS: int = 300  # 15 s
const _FIRE_ON_FIRE_TICKS: int = 160  # 8 s

# Environment-tick cadence — 20 Hz matches vanilla's integer-tick math
# so the random rolls (swim chance) and counters (air, fire damage)
# stay vanilla-faithful instead of becoming frame-rate-dependent.
const _ENV_TICK_DT: float = 1.0 / 20.0

# LOD tiering. Vanilla MC modern uses "simulation distance" — far
# entities render but tick less frequently. Same idea: 4 tiers based
# on horizontal distance from the player. Subclasses read `_lod_tier`
# (0..3) to scale AI tick rate, skip pathfinding, or skip animation
# updates. Constants are squared so the per-frame distance check
# avoids sqrt.
const LOD_NEAR: int = 0  # <32 m — full AI 20 Hz, A* pathfinding, anim
const LOD_MID: int = 1  # 32-64 m — AI 5 Hz, simple wander (no A*), anim
const LOD_FAR: int = 2  # 64-96 m — AI 1 Hz, no anim updates
const LOD_GATED: int = 3  # >96 m — process_mode DISABLED, invisible

const _LOD_NEAR_RADIUS: float = 32.0
const _LOD_MID_RADIUS: float = 64.0
const _LOD_FAR_RADIUS: float = 96.0
const _LOD_NEAR_RADIUS_SQ: float = _LOD_NEAR_RADIUS * _LOD_NEAR_RADIUS
const _LOD_MID_RADIUS_SQ: float = _LOD_MID_RADIUS * _LOD_MID_RADIUS
const _LOD_FAR_RADIUS_SQ: float = _LOD_FAR_RADIUS * _LOD_FAR_RADIUS

# Backwards-compat alias for old _PHYSICS_GATE constant references.
const _PHYSICS_GATE_RADIUS: float = _LOD_FAR_RADIUS
const _PHYSICS_GATE_RADIUS_SQ: float = _LOD_FAR_RADIUS_SQ

# Periodic stuck-in-terrain check. Mobs occasionally end up buried
# inside a solid block (chunk re-mesh races, penetration recovery
# edge cases). Sampling at 2 s is rare enough to be free and fast
# enough that the player rarely notices a stuck mob.
const _STUCK_CHECK_INTERVAL: float = 2.0

# Fall damage — vanilla `lw.java::e(distance, multiplier)` formula:
# damage = max(0, floor(fall_distance - 3)) HP. Safe threshold matches
# the player's; see `_fall_peak_y` / `_was_voxel_on_floor` state vars
# below for the edge-triggered damage application path.
const _FALL_DAMAGE_SAFE_BLOCKS: float = 3.0

# Mob-vs-mob soft push — vanilla Entity.collideWithEntity. VoxelCollider
# only checks block cells, so without this pass mobs would clip clean
# through each other. Pushes are applied as a tiny velocity impulse
# (1/dist scaled by _MOB_PUSH_STRENGTH) every frame; mobs ease apart
# over a few ticks rather than hard-snapping. Vanilla uses 0.05 — we
# match. Symmetric pairs (A pushes B, B pushes A) so the per-call cost
# stays single-mob and the visible separation rate sums to 2x.
const _MOB_PUSH_STRENGTH: float = 0.05
# XZ early-out radius. No two mob species today have combined half-extents
# > 0.7 m, so anything > 1.5 m apart trivially can't overlap. Cheap abs()
# check skips ~95% of pair iterations before the sqrt.
const _MOB_PUSH_QUICK_REJECT: float = 1.5

# Seconds in GATED state before auto-despawn. Vanilla uses ~30s
# after >128m delay.
const _DESPAWN_GATED_SECONDS: float = 30.0

# Wander helper — vanilla `EntityCreature.findRandomTargetBlock`.
# Cooldown ticks DOWN per call in `pick_wander_target`; range is the
# horizontal radius for the random target. Used by hostile mob AIs
# when no player target is in detect range.
const WANDER_COOLDOWN_SEC: float = 4.0
const WANDER_RADIUS_MIN: float = 3.0
const WANDER_RADIUS_MAX: float = 6.0

# Fire-billboard constants — port of `character_model.gd`'s Beta-era
# Render.renderEntityOnFire. Mob-specific dimensions come from
# `_get_body_height()` + `_get_body_width()`. Sprite count = how many
# 0.45-step layers fit inside `body_height / scale`.
const _FIRE_STRIP_PATH_0: String = "res://assets/textures/particles/fire_layer_0.png"
const _FIRE_STRIP_PATH_1: String = "res://assets/textures/particles/fire_layer_1.png"
const _FIRE_STRIP_FRAMES: int = 32
const _FIRE_ANIM_FPS: float = 24.0
const _FIRE_LAYER_HEIGHT: float = 1.4
const _FIRE_LAYER_SHRINK: float = 0.9
const _FIRE_LAYER_Y_STEP: float = 0.45
const _FIRE_LAYER_Z_STEP: float = 0.03
const _FIRE_SCALE_FACTOR: float = 1.4  # vanilla `entity.width * 1.4`

# Idle-SFX talk cadence — vanilla `EntityLiving.bs` field. Each AI tick
# rolls `randi() % 1000 < _idle_sfx_timer`; on a hit, timer resets to
# -_IDLE_SFX_TALK_INTERVAL so there's a mandatory ~4 s cooldown before
# the next possible fire. See `roll_idle_sfx_tick` for the full math.
const _IDLE_SFX_TALK_INTERVAL: int = 80

# Active-mob registry — every MobBase joins on _ready, leaves on
# _exit_tree. Used by MobSpawnerManager._count_nearby_mobs to skip the
# O(chunk_manager.get_children()) walk (which scales with chunk count,
# drops, falling blocks, etc.) in favor of O(active_mobs) which is
# bounded by the spawn cap. Keyed by instance_id for cheap erase.
static var _active_mobs: Dictionary = {}
# Shared cached player ref — every mob's distance gate would otherwise
# do its own tree walk. One static cache, re-resolved when stale.
static var _cached_player_node: Node3D = null
# Shared StandardMaterial3D cache, keyed by texture path. Every mob's
# _build_model previously allocated a fresh material + reloaded the
# texture, which was the dominant cost in per-spawn _ready() (~3-5 ms
# per material × 1-2 materials per mob). Sharing one material across
# all instances of the same species drops _ready cost ~3-5x without
# any visual / state-reset risk (materials are immutable per species).
static var _shared_materials: Dictionary = {}

# Per-mob-class shape caches. Every chicken's body capsule has
# identical (radius, height); every pig's head box has identical size.
# Sharing one Shape3D resource across all instances of a class saves
# N-1 allocations (small per-shape but adds up at the 70-mob spawn
# cap). Godot's physics server treats Shape3D as immutable, so sharing
# is safe — no instance can mutate another's collision.
# Keys are "capsule|<radius>|<height>" and "box|<sx>|<sy>|<sz>" so
# subclass overrides with different dimensions still get distinct
# cached resources.
static var _shape_cache: Dictionary = {}

@export var max_health: int = 10
@export var drop_item_id: int = 0  # 0 = no drop
@export var drop_count_min: int = 0
@export var drop_count_max: int = 0

var health: int = 0
var _damage_cooldown_remaining: float = 0.0
# Vanilla EntityLiving.aN — remembers the magnitude of the hit that
# started the current iframe. A new hit during iframe is dropped if
# `new <= aN`, otherwise it lands with `new - aN` damage (and aN
# updates). Without this, fire-tick damage (1 HP, 0.5s rearm) gates
# arrow damage (4-7 HP) for a full second per tick — a burning zombie
# tanks arrows it should otherwise eat in 1 hit.
var _last_damage_amount: int = 0
var _hurt_flash_remaining: float = 0.0
var _chunk_manager: Node
var _hurt_mat_overrides: Array = []  # [(MeshInstance3D, original_override)] pairs
# Cached world-brightness from EntityLighting.sample_brightness. -1
# forces the first per-frame material write; later frames skip if the
# delta is < 0.005 to avoid GPU uniform churn on a stationary mob.
var _last_lit_brightness: float = -1.0
# Counts up every AI tick; on idle-SFX hit, resets to
# `-_IDLE_SFX_TALK_INTERVAL` for a mandatory cooldown. See
# `roll_idle_sfx_tick` for the vanilla `EntityLiving.bs` math.
var _idle_sfx_timer: int = 0
# Death animation state. Once die() fires, _dying=true and _death_time
# counts up from 0. _process applies a linear Z-rotation toward
# _DEATH_TILT_ANGLE; on reaching _DEATH_DURATION the entity is freed.
# AI/physics/damage all gated on `_dying` in subclasses.
var _dying: bool = false
var _death_time: float = 0.0
# Fall damage — vanilla `lw.java::e(distance, multiplier)` formula:
# damage = max(0, floor(fall_distance - 3)) HP. Track the highest Y
# reached while airborne; on the airborne→grounded edge compute
# `peak - current` and damage if it exceeds the safe threshold.
# Skipped when landing in water/lava (vanilla water absorbs impact)
# and for mobs that return false from `_takes_fall_damage()` (chicken
# slow-fall). NAN sentinel on `_fall_peak_y` = "not currently tracking"
# (just spawned, just landed, or never airborne).
var _fall_peak_y: float = NAN
var _was_voxel_on_floor: bool = true
# Environment state — recomputed per physics_process. _in_water /
# _in_lava are body checks (used for drag + swim); _check_head_in_water
# is sampled separately inside the env tick for drowning.
var _in_water: bool = false
var _in_lava: bool = false
var _in_fire_cached: bool = false
var _env_tick_accum: float = 0.0
# Throttles _check_in_water/lava/fire to the env-tick cadence (20 Hz)
# instead of per physics frame. Each check is a Vector3i + floor x3 +
# get_world_block — adds up across many mobs.
var _env_sample_accum: float = 0.0
var _env_sampled_once: bool = false
var _stuck_check_accum: float = 0.0
# Stuck-mob diagnostic state. Only consumed when Game.debug_enabled is
# true — fires when velocity > 0.1 m/s but XZ position hasn't moved over
# 1 s. Kept around because the chicken-pack-bunching bug was partially
# fixed by `_apply_mob_separation`'s position-nudge path, but we never
# pinned down the root cause of voxel_move appearing to clip velocity
# in flat AIR. If the symptom recurs (any species, any terrain), this
# diagnostic surfaces the cell context without re-adding code.
var _stuck_diag_accum: float = 0.0
var _stuck_diag_last_xz: Vector2 = Vector2(NAN, NAN)
var _stuck_diag_logged_at_ms: int = 0
# Consecutive seconds the mob has been stuck (vel > 0.1 but no XZ
# progress). Resets to 0 the moment the mob actually moves. After 2 s,
# the stuck-handler in _physics_process applies a position kick in the
# velocity direction and resets this back to 0. Re-arms if still stuck.
var _stuck_seconds: float = 0.0
# Set by _physics_process when the distance gate fires. Subclasses
# read this AFTER `super._physics_process()` and skip their own AI /
# pathfinding work when true — without it, mob_base's early-return
# only saved base-class physics but skeletons / creepers kept running
# expensive A* + target search every frame anyway.
var _physics_gated: bool = false
# Current LOD tier (LOD_NEAR..LOD_GATED). Recomputed each frame in
# _physics_process. Subclasses use this to scale AI tick rate and
# decide whether to run pathfinding vs simple wander.
var _lod_tier: int = LOD_NEAR
# Bounds total population — vanilla despawns mobs > 128 m from any
# player after a 30 s grace. Without this, passive mobs accumulate
# forever (24+ per km of exploration). When the mob enters GATED,
# arm a SceneTreeTimer; if the timer fires before the mob is
# re-ungated, queue_free. process_mode = ALWAYS on the timer so it
# fires even though the mob itself is DISABLED.
var _despawn_timer: SceneTreeTimer = null
# Frame skip counter for move_and_slide throttling — see
# _physics_process. Resets every time move_and_slide actually fires.
var _move_frame_skip: int = 0
# Set by VoxelCollider.move each frame — replaces CharacterBody3D's
# is_on_floor() since we no longer use move_and_slide.
var _voxel_on_floor: bool = false
# True when the last collision step zeroed a non-zero horizontal
# velocity component (i.e., the mob hit a wall). Subclasses can read
# this to drive vanilla "isCollidedHorizontally" behaviors — currently
# only the spider's Beta wall-climb mechanic.
var _was_collided_horizontally: bool = false

var _air_ticks: int = _MAX_AIR_TICKS
var _fire_dmg_accum_ticks: int = 0
var _on_fire_ticks: int = 0
# Fire-sprite billboard — stacked Sprite3Ds with the vanilla Beta
# fire_layer_0/1 textures, parented to a pivot Node3D that yaws to
# face the camera every frame. Built lazily in _ready (after subclass
# model is constructed); hidden when _on_fire_ticks == 0.
var _fire_pivot: Node3D = null
var _fire_sprites: Array[Sprite3D] = []
var _fire_anim_time: float = 0.0
# Stuck arrows cosmetic — see `add_stuck_arrow` for behavior. Each
# entry in `_stuck_arrows` is a Node3D pivot whose local -Z points
# into the body; a child MeshInstance3D holds the small visible mesh.
var _arrows_stuck: int = 0
var _stuck_arrows: Array[Node3D] = []
var _stuck_arrow_decay_accum: float = 0.0
# Wander cooldown — see `pick_wander_target` for usage. Decrements
# every call; subclass AI ticks invoke it when no target is in range.
var _wander_cooldown_sec: float = 0.0
# Last entity to damage this mob. Vanilla `hf.aq` (lastAttacker) tracks
# the same. Drop tables in subclasses can read this for kill-source
# attribution (e.g. creepers drop a music disc when killed by a
# skeleton arrow per vanilla `dq.b(lw)`). Cleared on landing a damage
# tick where the new attacker is null/Vector3.ZERO knockback.
var _last_attacker: Node = null


# Read-only accessor for MobSpawnerManager + future spawn-cap code.
# Returns the raw dictionary; callers iterate values() in their own
# loops to avoid the extra Array allocation.
static func active_mobs() -> Dictionary:
	return _active_mobs


# Returns a cached StandardMaterial3D for the given texture path.
# Configures it as unshaded + nearest-filter (mob standard) and with
# optional alpha-scissor for skeleton-style transparent textures.
#
# Cache key uses the UNRESOLVED original path so live pack swaps reuse
# the same material instance (refresh_for_pack mutates albedo_texture
# in place — every mob holding a material_override ref picks up the
# new pack art instantly).
static func get_shared_material(
	texture_path: String, alpha_scissor: bool = false
) -> StandardMaterial3D:
	var key: String = "%s|%d" % [texture_path, 1 if alpha_scissor else 0]
	var cached: StandardMaterial3D = _shared_materials.get(key) as StandardMaterial3D
	if cached != null:
		return cached
	var resolved: String = _resolve_pack_mob_path(texture_path)
	var tex: Texture2D = load(resolved) as Texture2D
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	if alpha_scissor:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
	_shared_materials[key] = mat
	return mat


# Resolve a shared-mob texture path to its per-pack override when the
# active pack ships one, else return the path unchanged. Shared mob
# textures live under res://assets/textures/mob/; per-pack overrides
# live at res://assets/textures/blocks/packs/{active}/mobs/. Anything
# outside the shared mob dir (entity sprites, item icons) is passed
# through untouched so this can be called from any texture load.
static func _resolve_pack_mob_path(path: String) -> String:
	var prefix: String = "res://assets/textures/mob/"
	if not path.begins_with(prefix):
		return path
	var pack: String = BlockAtlas.active_pack
	if pack == BlockAtlas.DEFAULT_PACK:
		return path
	var fname: String = path.substr(prefix.length())
	var pack_path: String = "%s%s/mobs/%s" % [BlockAtlas.PACK_BASE, pack, fname]
	if ResourceLoader.exists(pack_path):
		return pack_path
	return path


# Pack-aware texture loader for mobs that don't go through
# get_shared_material (pig/cow/chicken/sheep/slime build their own
# materials). Mirrors the resolution rules above so per-pack mob art
# kicks in regardless of how the mob script wires its material.
static func load_mob_texture(path: String) -> Texture2D:
	return load(_resolve_pack_mob_path(path)) as Texture2D


# Re-resolve every cached material's albedo_texture against the active
# pack. Because mobs hold the StandardMaterial3D by reference (via
# material_override), mutating albedo_texture in place propagates to
# every existing instance — no need to iterate _active_mobs or rebuild
# meshes. Called from settings_menu on texture-pack swap.
static func refresh_for_pack() -> void:
	for key: String in _shared_materials.keys():
		var mat: StandardMaterial3D = _shared_materials[key] as StandardMaterial3D
		if mat == null:
			continue
		# Key format: "<original_path>|<alpha_scissor_int>". Recover the
		# path so we can re-run the pack resolver against the new active
		# pack.
		var sep: int = key.rfind("|")
		if sep < 0:
			continue
		var original_path: String = key.substr(0, sep)
		var resolved: String = _resolve_pack_mob_path(original_path)
		mat.albedo_texture = load(resolved) as Texture2D


func _on_gated_despawn_check() -> void:
	# Called by the SceneTreeTimer after _DESPAWN_GATED_SECONDS. If
	# the mob is still gated (i.e. player hasn't re-approached), free
	# it. Otherwise it's been ungated; the next gate cycle re-arms.
	if not is_instance_valid(self):
		return
	if _physics_gated:
		queue_free()
	else:
		_despawn_timer = null


# AABB half-extents for the voxel collider. Subclasses override
# (most mobs are 0.6 wide × 1.8 tall, half = 0.3 / 0.9 / 0.3).
func _voxel_half_extents() -> Vector3:
	return Vector3(0.3, _get_body_height() * 0.5, 0.3)


# Floor check via voxel collider — replaces CharacterBody3D.is_on_floor()
# which is stale because we no longer call move_and_slide. Subclass
# code calls mob_is_on_floor() in place of the native is_on_floor().
func mob_is_on_floor() -> bool:
	return _voxel_on_floor


# Vanilla fall-damage opt-out. Returns true by default — every Alpha
# EntityLiving subclass calls the damage formula on landing. Chicken
# overrides to return false (vanilla `ou.java` clamps Y velocity AND
# never calls fall damage even on huge drops, modeled in our impl
# by suppressing the check entirely). Slime / passive / hostile mobs
# all take fall damage like the player.
func _takes_fall_damage() -> bool:
	return true


func _cached_player() -> Node3D:
	if _cached_player_node != null and is_instance_valid(_cached_player_node):
		return _cached_player_node
	_cached_player_node = (get_tree().root.get_node_or_null("Main/Player") as Node3D)
	return _cached_player_node


# Returns a horizontal world target 3-6 m away, or Vector3.ZERO if
# the cooldown hasn't expired yet. Shared `EntityCreature.find
# RandomTargetBlock` wander helper for hostile mobs (zombie, skeleton,
# future creeper / spider) — keeps the mob moving when no target is
# in detect range so it doesn't freeze in place. Decrement happens
# here on every call, so route this through the AI tick (delta = AI
# tick dt) — NOT per-frame, or the cooldown burns 3× faster on 60 fps
# hosts. Passive mobs (pig / cow / sheep / chicken) have their own
# species-specific wander FSMs (flee + idle eat); leaving those
# separate until a passive-mob refactor sweeps through.
#
# Usage in a hostile AI tick:
#   if _ai_path.is_empty():
#       var t := pick_wander_target(_AI_TICK_DT)
#       if t != Vector3.ZERO:
#           _repath_to(t)
#   else:
#       _tick_walk_path()  # half-speed for ambient stroll
func pick_wander_target(delta: float) -> Vector3:
	_wander_cooldown_sec -= delta
	if _wander_cooldown_sec > 0.0:
		return Vector3.ZERO
	_wander_cooldown_sec = WANDER_COOLDOWN_SEC
	var theta: float = randf() * TAU
	var dist: float = randf_range(WANDER_RADIUS_MIN, WANDER_RADIUS_MAX)
	return global_position + Vector3(cos(theta) * dist, 0, sin(theta) * dist)


# LOD-aware roll for the per-tick "pick new wander target" gate. Returns
# true with 1/denom_at_near probability when at LOD_NEAR. AI tick rate
# drops 4×/20× at LOD_MID/FAR, so we shrink the denom by the same
# factor to keep the per-real-second pick rate constant — otherwise
# far mobs sample the gate once per real second × 1/80 ≈ 1 attempt
# per 80 s and read as frozen.
func roll_wander_gate(denom_at_near: int) -> bool:
	var scale: float = 1.0
	if _lod_tier == LOD_MID:
		scale = 4.0
	elif _lod_tier == LOD_FAR:
		scale = 20.0
	var denom: int = maxi(1, int(round(float(denom_at_near) / scale)))
	return randi() % denom == 0


# Vanilla idle-SFX roll. Mirrors `hf.java::B()` lines:
#     if (this.bd.nextInt(1000) < this.a++) {
#         this.a = -this.b();        // b() = 80, the "talk interval"
#         this.f_();                  // play living sound
#     }
# `_idle_sfx_timer` is the vanilla `a` field — counts up every tick.
# Each tick: roll `randi() % 1000 < timer`. On hit, reset timer to
# `-_IDLE_SFX_TALK_INTERVAL` so there's a mandatory ~4 s cooldown
# before the next possible fire. Mean fire rate ≈ 1 per ~120 ticks
# (6 s per mob), matching vanilla.
#
# MUST be called once per AI tick (20 Hz). If called from `_process`
# (variable framerate) it would over-fire on high-fps hosts. The AI
# tick is also gated on `_dying` + the 48 m physics radius — both
# desirable: dying mobs don't speak, and far-mobs (inaudible past
# the 16 m audio max distance anyway) skip the random call entirely.
#
# Returns true if the roll hit (caller should invoke their species
# `_play_idle_sfx`). Subclasses overriding the talk interval can
# tweak `_idle_sfx_talk_interval` per instance — vanilla mostly uses
# 80 across all mobs but some species (e.g., chicken, slime) may
# want a different cadence.
func roll_idle_sfx_tick() -> bool:
	_idle_sfx_timer += 1
	if _idle_sfx_timer <= 0:
		# Mandatory cooldown — vanilla counts up from -80 to 0 before
		# rolls resume. Saves a random call when guaranteed no-fire.
		return false
	if randi() % 1000 < _idle_sfx_timer:
		_idle_sfx_timer = -_IDLE_SFX_TALK_INTERVAL
		return true
	return false


func _ready() -> void:
	health = max_health
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	_active_mobs[get_instance_id()] = self
	_build_fire_billboards()


func _exit_tree() -> void:
	_active_mobs.erase(get_instance_id())


# --- Collision-shape helpers (called by subclasses' _build_collision_shape) ---
#
# Two-shape design to fix the stuck-clipping issue without losing
# arrow/sword hit coverage on protruding heads / snouts / horns:
#
#   1. Body capsule — vertical CapsuleShape3D on the CharacterBody3D,
#      centered on the mob's origin. Drives ALL physics resolution
#      (move_and_slide, floor contact, wall sliding). Rotationally
#      symmetric around Y so yawing doesn't shift the shape's world
#      center; rounded edges slide off block corners cleanly.
#
#   2. Head Area3D — sibling Area3D with a BoxShape3D positioned at
#      head height + forward offset. HIT-ONLY: Area3D doesn't
#      participate in CharacterBody3D collision resolution, so this
#      can stick forward (covering snouts / horns / beaks) without
#      ever causing depenetration-stuck. It rotates with the mob,
#      which is correct — the visible head also rotates with the body.
#
# Layer 3 (0b100) is the dedicated mob-hit-volume layer. Arrows +
# melee raycasts include it in their mask; nothing else reads it.


func _build_body_capsule(radius: float, height: float) -> void:
	var body_col := CollisionShape3D.new()
	body_col.shape = _cached_capsule(radius, height)
	# Y offset so the capsule bottom sits at the mob's feet (y = 0).
	body_col.position = Vector3(0.0, height * 0.5, 0.0)
	add_child(body_col)


func _build_head_hit_area(box_size: Vector3, box_position: Vector3) -> void:
	var head_area := Area3D.new()
	head_area.collision_layer = 0b100
	head_area.collision_mask = 0
	var head_col := CollisionShape3D.new()
	head_col.shape = _cached_box(box_size)
	head_col.position = box_position
	head_area.add_child(head_col)
	add_child(head_area)


# Static accessors — return a CapsuleShape3D / BoxShape3D unique per
# (script_path, dimensions) tuple. Same dims on the same mob class →
# same Shape3D instance; differing dims (subclass override) → fresh
# entry. RefCounted-style retention means cached shapes outlive any
# single mob and stay alive while ANY instance still references them.
static func _cached_capsule(radius: float, height: float) -> CapsuleShape3D:
	var key: String = "capsule|%f|%f" % [radius, height]
	var cached: CapsuleShape3D = _shape_cache.get(key) as CapsuleShape3D
	if cached != null:
		return cached
	var capsule := CapsuleShape3D.new()
	capsule.radius = radius
	capsule.height = height
	_shape_cache[key] = capsule
	return capsule


static func _cached_box(size: Vector3) -> BoxShape3D:
	var key: String = "box|%f|%f|%f" % [size.x, size.y, size.z]
	var cached: BoxShape3D = _shape_cache.get(key) as BoxShape3D
	if cached != null:
		return cached
	var box := BoxShape3D.new()
	box.size = size
	_shape_cache[key] = box
	return box


# Subclasses override to add per-mob AI in _process. The base only handles
# physics + cooldowns; AI lives one level up so changing the AI of a
# specific mob doesn't accidentally break gravity / damage / death.
func _physics_process(delta: float) -> void:
	# Dying — freeze position + skip all physics. The tilt rotation
	# applied in _process is the only thing that should move while the
	# mob is falling over.
	if _dying:
		velocity = Vector3.ZERO
		return
	# Distance gate — mobs far from any player skip physics + AI to
	# keep frame cost flat regardless of total mob count. Vanilla
	# despawns at 128 m; we use a softer 48 m cull so the mob stays
	# alive (preserves spawned populations, world feels consistent on
	# return) but doesn't burn cycles. move_and_slide alone is the
	# dominant per-mob cost; skipping it for distant mobs trades AI
	# liveness for steady FPS in mob-spawner-heavy worlds.
	var p: Node3D = _cached_player()
	if p != null:
		var dx: float = global_position.x - p.global_position.x
		var dz: float = global_position.z - p.global_position.z
		var d_sq: float = dx * dx + dz * dz
		# Tier classification — squared-distance compares avoid sqrt.
		if d_sq > _LOD_FAR_RADIUS_SQ:
			# GATED: hard-disable the node entirely. No physics, no
			# render, no script processing. Re-enabled when player
			# re-approaches. Arm a 30 s despawn timer if not already
			# armed — fires queue_free on a still-gated mob to bound
			# the total population (vanilla despawns at 128 m + delay).
			velocity = Vector3.ZERO
			_physics_gated = true
			_lod_tier = LOD_GATED
			if process_mode != Node.PROCESS_MODE_DISABLED:
				process_mode = Node.PROCESS_MODE_DISABLED
				visible = false
			if _despawn_timer == null:
				# process_mode=ALWAYS so the timer fires even though our
				# own node is DISABLED.
				_despawn_timer = (get_tree().create_timer(
					_DESPAWN_GATED_SECONDS, true, false, true
				))
				_despawn_timer.timeout.connect(_on_gated_despawn_check)
			return
		# Cancel any pending despawn — we're back in range.
		if _despawn_timer != null:
			_despawn_timer = null
		if d_sq > _LOD_MID_RADIUS_SQ:
			_lod_tier = LOD_FAR
		elif d_sq > _LOD_NEAR_RADIUS_SQ:
			_lod_tier = LOD_MID
		else:
			_lod_tier = LOD_NEAR
	if _physics_gated:
		# Re-enable when back in range.
		process_mode = Node.PROCESS_MODE_INHERIT
		visible = true
	_physics_gated = false
	# Chunk-load gate. populate_chunk_at_gen spawns mobs the moment the
	# chunk's block data lands, but the trimesh collider is built async
	# on a worker. During that 1-30 frame window, is_on_floor() returns
	# false (no collider), gravity drops the mob below the eventual
	# floor cell, then the trimesh materializes — move_and_slide's
	# penetration recovery pops the mob UP through the geometry. Same
	# pattern fires when the player walks into a fresh chunk and the
	# trimesh appears around an existing mob at the boundary. Freeze
	# transform + zero velocity until the chunk's coord is in _chunks
	# AND a downward-facing collider is reachable (via is_on_floor or
	# a short cooldown after first contact).
	if _chunk_manager != null and _chunk_manager.has_method("is_chunk_loaded"):
		var mob_chunk := Vector2i(
			int(floor(global_position.x / float(Chunk.SIZE_X))),
			int(floor(global_position.z / float(Chunk.SIZE_Z)))
		)
		if not _chunk_manager.is_chunk_loaded(mob_chunk):
			velocity = Vector3.ZERO
			return
	var pre_move_y: float = global_position.y
	var pre_move_vel_y: float = velocity.y
	# Sample environment for this frame. Cached at 20 Hz (env tick rate)
	# so we don't burn 3 chunk lookups per frame per mob on values that
	# only change when the mob crosses a cell boundary. The cache is
	# refreshed inside the while-loop below at the same 50 ms cadence.
	_env_sample_accum += delta
	if _env_sample_accum >= _ENV_TICK_DT or not _env_sampled_once:
		_env_sample_accum = 0.0
		_env_sampled_once = true
		_in_water = _check_in_water()
		_in_lava = _check_in_lava()
		_in_fire_cached = _check_in_fire()
	var in_fire: bool = _in_fire_cached
	# Gravity / drag — fluid cells replace normal gravity entirely.
	# Vanilla water: velocity *= 0.8/tick, gravity -0.02/tick.
	# Vanilla lava:  velocity *= 0.5/tick, gravity -0.02/tick.
	# In air: standard -16 m/s² + floor friction.
	if _in_water:
		var k: float = pow(_WATER_DRAG_PER_TICK, 20.0 * delta)
		velocity *= k
		velocity.y += _FLUID_GRAVITY * delta
	elif _in_lava:
		var k: float = pow(_LAVA_DRAG_PER_TICK, 20.0 * delta)
		velocity *= k
		velocity.y += _FLUID_GRAVITY * delta
	elif not _voxel_on_floor:
		# Gravity. VoxelCollider sets _voxel_on_floor based on whether
		# a solid cell sits directly below the AABB feet — replaces
		# CharacterBody3D.is_on_floor() since we no longer use
		# move_and_slide.
		velocity.y = maxf(velocity.y + GRAVITY * delta, TERMINAL_VELOCITY)
	else:
		# Drop any residual upward velocity once grounded so we don't
		# accumulate y-bounce across the floor. Apply horizontal friction
		# only while grounded — vanilla `lw.aF = 0.546` is the per-tick
		# GROUND friction. In air, momentum persists (vanilla applies a
		# tiny 0.91/tick drag, close enough to "no decay" for our cases).
		# Applying friction in-air broke step-up jumps: the cow's walk
		# velocity decayed faster than the ~0.75 s air time, so it
		# couldn't cover the 1-block horizontal gap.
		if velocity.y < 0.0:
			velocity.y = 0.0
		var f: float = pow(_GROUND_FRICTION, delta)
		velocity.x *= f
		velocity.z *= f
	# Custom voxel-AABB collision (VoxelCollider) instead of
	# move_and_slide. Per-mob cost drops from ~2-3 ms to ~0.05 ms
	# because we read chunk block data directly (1-30 cell checks)
	# instead of going through PhysicsServer3D's BVH + trimesh
	# narrow-phase. Vanilla World.getCollidingBoundingBoxes does
	# exactly this — it's how MC scales to 70+ mobs cheaply.
	# Coord convention: global_position is FEET (Godot CharacterBody3D
	# default). VoxelCollider works in AABB CENTER, so we offset in
	# and out.
	var half: Vector3 = _voxel_half_extents()
	var center: Vector3 = global_position + Vector3(0.0, half.y, 0.0)
	var collide_result: Dictionary = _VOXEL_COLLIDER.move(
		_chunk_manager, center, half, velocity, delta
	)
	var new_center: Vector3 = collide_result.get("pos", center) as Vector3
	global_position = new_center - Vector3(0.0, half.y, 0.0)
	# Write clipped velocity back — VoxelCollider zeros components that
	# hit walls/floors. Without this, mob's velocity stays at pre-clip
	# value and AI thinks it's moving while position stays stuck. This
	# was the root cause of the stuck-chickens bug in the first attempt.
	var pre_clip_vx: float = velocity.x
	var pre_clip_vz: float = velocity.z
	velocity = collide_result.get("vel", velocity) as Vector3
	_voxel_on_floor = bool(collide_result.get("on_floor", false))
	# Fall damage — vanilla `lw.java::e(distance, mult)` → `hf.java`
	# damage = max(0, floor(fall_distance - 3)) HP. Edge-triggered on
	# the airborne→grounded transition. While airborne, track the
	# highest Y reached so a mob that bumps upward mid-fall (e.g.,
	# water column geyser, knockback, slime hop) doesn't underreport
	# its actual fall depth. Skipped when landing in water/lava
	# (vanilla water absorbs impact entirely) and for mobs that return
	# false from `_takes_fall_damage()` (chicken slow-fall).
	if _takes_fall_damage():
		if _voxel_on_floor and not _was_voxel_on_floor and not is_nan(_fall_peak_y):
			if not _in_water and not _in_lava:
				var fall_dist: float = _fall_peak_y - global_position.y
				if fall_dist > _FALL_DAMAGE_SAFE_BLOCKS:
					var dmg: int = int(floor(fall_dist - _FALL_DAMAGE_SAFE_BLOCKS))
					if dmg > 0:
						take_damage(dmg, Vector3.ZERO, 0.0, null)
			_fall_peak_y = NAN
		elif not _voxel_on_floor:
			# Track / extend the peak while airborne.
			if is_nan(_fall_peak_y) or global_position.y > _fall_peak_y:
				_fall_peak_y = global_position.y
	_was_voxel_on_floor = _voxel_on_floor
	# Horizontal collision = a non-zero pre-clip x/z component was zeroed
	# by the wall scan. Threshold matches the collider's own 1e-4 motion
	# epsilon. Used by spider for the Beta wall-climb mechanic.
	_was_collided_horizontally = (
		(absf(pre_clip_vx) > 0.0001 and absf(velocity.x) <= 0.0001)
		or (absf(pre_clip_vz) > 0.0001 and absf(velocity.z) <= 0.0001)
	)
	# Penetration-recovery clamp. Compare the actual upward motion this
	# frame against what `velocity.y` could have produced. Any excess is
	# move_and_slide pushing the body out of a freshly-materialized
	# collider (chunk trimesh just attached) — snap back so the mob
	# doesn't ride that pop into the stratosphere. Slop of 0.2 m covers
	# normal step-up snapping. Vanilla swim impulse (in water) leaves
	# velocity.y positive in advance, so it doesn't get caught.
	var actual_dy: float = global_position.y - pre_move_y
	var expected_max_dy: float = maxf(pre_move_vel_y, 0.0) * delta + 0.2
	if actual_dy > expected_max_dy:
		global_position.y = pre_move_y
		velocity.y = 0.0
	# Periodic stuck-check. Live mobs can end up clipped inside a solid
	# block from gameplay races (chunk re-mesh during move, edge-case
	# penetration recovery, fluid + ground transitions). Sample the
	# feet+head cells every 2 s; if both are opaque, push up. Cheap
	# (2 chunk lookups every 2 s = 1/sec) and self-corrects without
	# requiring a save/reload to trigger the existing _unstick path.
	_stuck_check_accum += delta
	if _stuck_check_accum >= _STUCK_CHECK_INTERVAL:
		_stuck_check_accum = 0.0
		_unstick_if_buried()
	# Mob-vs-mob soft push. Only fires for NEAR/MID mobs — FAR mobs are
	# visually small enough that clipping isn't noticeable, and skipping
	# them halves the per-frame work. Cost is bounded by the early-out
	# `_MOB_PUSH_QUICK_REJECT` (~95% of pairs skip after 4 ops).
	if _lod_tier <= LOD_MID:
		_apply_mob_separation()
	# Stuck-mob handling — always runs (cheap), diagnostic print is the
	# only Game.debug_enabled-gated piece. Detects mobs whose AI is
	# trying to move (vel_xz > 0.1) but who haven't actually progressed
	# (moved_xz < 0.05 in 1 s). After 2 consecutive stuck seconds,
	# applies a small direct position kick in the velocity direction to
	# dislodge from the voxel collider's "near-zero motion clip in flat
	# AIR" edge case. Root cause was never traced; this is the
	# belt-and-suspenders fallback. Chickens were the obvious symptom
	# but the same code helps any species that ends up stuck.
	_stuck_diag_accum += delta
	if _stuck_diag_accum >= 1.0:
		_stuck_diag_accum = 0.0
		var cur_xz := Vector2(global_position.x, global_position.z)
		if not is_nan(_stuck_diag_last_xz.x):
			var vel_xz: float = Vector2(velocity.x, velocity.z).length()
			var moved_xz: float = (cur_xz - _stuck_diag_last_xz).length()
			if vel_xz > 0.1 and moved_xz < 0.05:
				_stuck_seconds += 1.0
				if Game.debug_enabled:
					var now_ms: int = Time.get_ticks_msec()
					if (now_ms - _stuck_diag_logged_at_ms) > 5000:
						_stuck_diag_logged_at_ms = now_ms
						_dump_stuck_diagnostic(vel_xz)
				if _stuck_seconds >= 2.0:
					_stuck_seconds = 0.0  # re-arm; fires again 2 s later if still stuck
					_kick_stuck_mob()
			else:
				_stuck_seconds = 0.0
		_stuck_diag_last_xz = cur_xz
	# Environment tick at 20 Hz — swim impulse + drowning + fire/lava
	# damage. Runs AFTER move_and_slide so the air-ticks check uses the
	# mob's settled position. We re-sample head_in_water inside the tick
	# rather than caching from above because the mob may have just
	# climbed out of water during move_and_slide.
	_env_tick_accum += delta
	while _env_tick_accum >= _ENV_TICK_DT:
		_env_tick_accum -= _ENV_TICK_DT
		_env_tick(in_fire)


func _process(delta: float) -> void:
	if _dying:
		_tick_death_animation(delta)
		# Keep the flame UV strip advancing during the fall-over —
		# vanilla `Render.renderEntityOnFire` runs regardless of
		# deathTime, so freezing the animation here reads as a bug.
		_tick_fire_animation(delta)
		return
	# Same distance gate as _physics_process — animations + damage-
	# flash decay are purely visual, and a mob 48+ m from the player
	# is frustum-culled or invisible anyway. Skipping the whole
	# function for far mobs saves ~70-mob × per-frame overhead at
	# night when the hostile cap fills.
	if _physics_gated:
		return
	if _damage_cooldown_remaining > 0.0:
		_damage_cooldown_remaining = maxf(0.0, _damage_cooldown_remaining - delta)
	if _hurt_flash_remaining > 0.0:
		_hurt_flash_remaining = maxf(0.0, _hurt_flash_remaining - delta)
		if _hurt_flash_remaining == 0.0:
			_clear_hurt_flash()
	_tick_fire_animation(delta)
	_tick_stuck_arrow_decay(delta)
	_tick_world_brightness()


# Beta-era `Render.renderEntityOnFire` port — five stacked layered
# fire billboards (or fewer for short mobs) that face the camera, with
# alternating fire_layer_0/fire_layer_1 textures and a 32-frame strip
# animation at 24 FPS. Same algorithm as `character_model.gd`'s player
# fire visual, parameterized on `_get_body_height()` and
# `_get_body_width()` so each mob species gets a correctly-sized stack.
# Built once in _ready; toggled visible whenever `_on_fire_ticks > 0`.
func _build_fire_billboards() -> void:
	var strip0: Texture2D = load(_FIRE_STRIP_PATH_0) as Texture2D
	var strip1: Texture2D = load(_FIRE_STRIP_PATH_1) as Texture2D
	if strip0 == null:
		return
	if strip1 == null:
		strip1 = strip0  # graceful fallback if only one strip ships
	var width: float = _get_body_width()
	var height: float = _get_body_height()
	var scale: float = width * _FIRE_SCALE_FACTOR
	if scale <= 0.0 or height <= 0.0:
		return
	_fire_pivot = Node3D.new()
	_fire_pivot.visible = false
	# Pivot at the mob's FEET (entity origin Y = 0 in our convention).
	# Uniform scale applies the vanilla `entity.width × 1.4` size factor.
	_fire_pivot.position = Vector3(0, 0, 0)
	_fire_pivot.scale = Vector3.ONE * scale
	add_child(_fire_pivot)
	# Beta loop: while (var15 > 0) var15 -= 0.45. var15 starts at
	# `height / scale` — gives 1 layer for chicken (0.4/0.42 ≈ 0.95 →
	# 3 iters via decrement), 3+ for pig/cow, 5 for player. Capped at
	# 6 layers to avoid runaway for any future giant mob.
	var var15: float = height / scale
	var layer_z: float = -0.3
	var x_scale: float = 1.0
	var layer_count: int = 0
	while var15 > 0.0 and layer_count < 6:
		var s := Sprite3D.new()
		s.texture = strip0 if (layer_count % 2 == 0) else strip1
		s.hframes = 1
		s.vframes = _FIRE_STRIP_FRAMES
		s.frame = 0
		s.pixel_size = 1.0 / 16.0
		# Every other layer-pair flips U to break up the repeat pattern
		# (Spoutcraft Render.java:70-74). Negating scale.x mirrors the
		# sprite horizontally with the same width.
		var x_sign: float = -1.0 if (layer_count / 2) % 2 == 0 else 1.0
		s.scale = Vector3(x_scale * x_sign, _FIRE_LAYER_HEIGHT, 1.0)
		s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		s.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		s.shaded = false
		s.transparent = true
		s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
		s.double_sided = true
		s.render_priority = 5 + layer_count
		var y_center: float = 0.7 + _FIRE_LAYER_Y_STEP * float(layer_count)
		s.position = Vector3(0, y_center, layer_z)
		_fire_pivot.add_child(s)
		_fire_sprites.append(s)
		var15 -= _FIRE_LAYER_Y_STEP
		layer_z += _FIRE_LAYER_Z_STEP
		x_scale *= _FIRE_LAYER_SHRINK
		layer_count += 1


# Camera-facing yaw + frame stepping. Skips silently when the pivot
# isn't visible so a non-burning mob does no per-frame work.
func _tick_fire_animation(delta: float) -> void:
	if _fire_pivot == null or not _fire_pivot.visible or _fire_sprites.is_empty():
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam != null:
		var cam_pos: Vector3 = cam.global_position
		var pivot_pos: Vector3 = _fire_pivot.global_position
		var to_cam: Vector3 = cam_pos - pivot_pos
		to_cam.y = 0.0
		if to_cam.length_squared() > 0.0001:
			var yaw: float = atan2(to_cam.x, to_cam.z)
			# Undo parent yaw so the pivot faces world-space camera.
			var parent_yaw: float = global_rotation.y
			_fire_pivot.rotation.y = yaw - parent_yaw
	_fire_anim_time += delta * _FIRE_ANIM_FPS
	var base_frame: int = int(_fire_anim_time) % _FIRE_STRIP_FRAMES
	for s: Sprite3D in _fire_sprites:
		s.frame = base_frame


# Mob bounding-box WIDTH (X = Z, since vanilla mobs are square in
# plan). Used for fire-billboard scaling. Subclasses override to
# return the per-species value; default = chicken-sized (0.3 m).
func _get_body_width() -> float:
	return 0.3


# Per-tick (20 Hz) environment hazards. Vanilla equivalents called out
# inline. Subclasses should NOT override this — they get the behaviour
# for free as long as they call super._physics_process().
func _env_tick(in_fire: bool) -> void:
	if _dying:
		return
	# Swim assist — vanilla hf.java:588-592 + 518-525. 80 % chance to
	# push up by SWIM_IMPULSE when in either water or lava. The drag
	# applied in _physics_process counters most of this each frame so
	# the net rise rate stays at ~0.06 m/tick (= 1.2 m/s ceiling drift).
	if _in_water or _in_lava:
		if randf() < _SWIM_CHANCE:
			velocity.y += _SWIM_IMPULSE
	# Drowning — vanilla hf.java:114-126. Check the EYE cell (top of BB)
	# specifically rather than the body center, so a tall mob with feet
	# submerged + head above water keeps breathing.
	if _check_head_in_water():
		_air_ticks -= 1
		if _air_ticks <= -_DROWN_INTERVAL_TICKS:
			take_damage(_DROWN_DAMAGE, Vector3.ZERO)
			_air_ticks = 0
	else:
		_air_ticks = _MAX_AIR_TICKS
	# On-fire timer — vanilla refreshes to 15 s every tick in lava and
	# sets it to 8 s on first contact with a fire block. Water cell
	# extinguishes immediately. The timer keeps the flame sprites
	# visible (and dealing damage) after the mob steps out of the
	# hazard, matching vanilla's "burning entity" effect.
	if _in_lava:
		_on_fire_ticks = _LAVA_ON_FIRE_TICKS
	elif in_fire and _on_fire_ticks < _FIRE_ON_FIRE_TICKS:
		_on_fire_ticks = _FIRE_ON_FIRE_TICKS
	if _in_water and _on_fire_ticks > 0:
		_on_fire_ticks = 0
		_fire_dmg_accum_ticks = 0
	# Contact damage — lava deals 4 HP per 20 ticks while standing in
	# lava. Otherwise the on-fire timer (set by lava OR fire-block
	# contact) deals 1 HP per 20 ticks until it counts down to 0.
	if _in_lava:
		_fire_dmg_accum_ticks += 1
		if _fire_dmg_accum_ticks >= _FIRE_TICK_INTERVAL_TICKS:
			_fire_dmg_accum_ticks = 0
			take_damage(_LAVA_DAMAGE, Vector3.ZERO)
	elif _on_fire_ticks > 0:
		_on_fire_ticks -= 1
		_fire_dmg_accum_ticks += 1
		if _fire_dmg_accum_ticks >= _FIRE_TICK_INTERVAL_TICKS:
			_fire_dmg_accum_ticks = 0
			take_damage(_FIRE_DAMAGE, Vector3.ZERO)
	else:
		_fire_dmg_accum_ticks = 0
	# Toggle flame-sprite visibility to match the timer.
	if _fire_pivot != null:
		_fire_pivot.visible = _on_fire_ticks > 0 or _in_lava


# Voxel sampling helpers. The mob's body axis-aligned bounding box is
# implicit in _get_body_height / _get_eye_height (overrides per mob);
# the floor of each call is the global position so a mob standing on a
# block at world Y=64 samples cells (..., y=64, ...) for its feet and
# (..., y=64+eye_height, ...) for its head. The chunk-manager call is
# guarded against the singleton not being mounted (headless tests).
func _check_in_water() -> bool:
	if _chunk_manager == null:
		return false
	var cell: Vector3i = Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + _get_body_height() * 0.5)),
		int(floor(global_position.z)),
	)
	var b: int = _chunk_manager.get_world_block(cell)
	return b == Blocks.WATER_FLOWING or b == Blocks.WATER_STILL


func _check_in_lava() -> bool:
	if _chunk_manager == null:
		return false
	var cell: Vector3i = Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + _get_body_height() * 0.5)),
		int(floor(global_position.z)),
	)
	var b: int = _chunk_manager.get_world_block(cell)
	return b == Blocks.LAVA_FLOWING or b == Blocks.LAVA_STILL


func _check_head_in_water() -> bool:
	if _chunk_manager == null:
		return false
	var cell: Vector3i = Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + _get_eye_height())),
		int(floor(global_position.z)),
	)
	var b: int = _chunk_manager.get_world_block(cell)
	return b == Blocks.WATER_FLOWING or b == Blocks.WATER_STILL


func _check_in_fire() -> bool:
	if _chunk_manager == null:
		return false
	# Sample just above the feet (Y + 0.1) so the check catches FIRE
	# blocks placed AT the mob's footprint — fire is a thin 1-cell
	# layer, sampling at Y=0 would miss it on a sloped/edge case.
	var cell: Vector3i = Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + 0.1)),
		int(floor(global_position.z)),
	)
	var b: int = _chunk_manager.get_world_block(cell)
	return b == Blocks.FIRE


# Subclasses override to provide mob-specific bounding box dimensions.
# Defaults are chicken-sized (the smallest passive mob) — using them
# without override gives slightly wrong drown detection on bigger mobs
# but never crashes. Returned values are METERS of total BB extent.
func _get_body_height() -> float:
	return 0.4


func _get_eye_height() -> float:
	return 0.35


# Public damage entry — called by player (melee), arrows (projectile),
# Explosion (TNT blast), and lava. Returns true if the hit landed (false
# during invulnerability window).
#
# `knockback_dir` is the world-space direction from attacker to mob;
# pass Vector3.ZERO for damage-without-knockback (lava, drowning).
func take_damage(
	amount: int,
	knockback_dir: Vector3 = Vector3.ZERO,
	knockback_strength: float = 1.0,
	attacker: Node = null
) -> bool:
	if amount <= 0 or health <= 0:
		return false
	# Latch attacker for kill-source attribution. Vanilla `hf.aq` tracks
	# this for drop tables (creeper-by-skeleton drops a music disc) and
	# AI revenge targeting (which we don't use yet).
	if attacker != null:
		_last_attacker = attacker
	# Vanilla EntityLiving.damageEntity — during iframe, a NEW hit lands
	# with `amount - _last_damage_amount` if it's strictly larger,
	# otherwise it's dropped. Keeps fire-tick from blocking arrows.
	var applied: int = amount
	if _damage_cooldown_remaining > 0.0:
		if amount <= _last_damage_amount:
			return false
		applied = amount - _last_damage_amount
	_last_damage_amount = amount
	health = maxi(0, health - applied)
	_damage_cooldown_remaining = _DAMAGE_COOLDOWN_SEC
	_apply_hurt_flash()
	if knockback_dir.length_squared() > 0.0001:
		var dir: Vector3 = knockback_dir.normalized()
		# Strength multiplier ONLY scales horizontal — vanilla
		# `EntityArrow` applies a fixed ~0.1 vertical regardless of
		# arrow charge; scaling vertical too (as we used to) launched
		# mobs ~3 m on full-charge hits, which the user flagged as
		# "ridiculous". Keep the vertical pop constant so the kick
		# feels like a flinch, not a takeoff.
		var ks: float = maxf(knockback_strength, 0.0)
		velocity.x = dir.x * KNOCKBACK_HORIZONTAL * ks
		velocity.z = dir.z * KNOCKBACK_HORIZONTAL * ks
		velocity.y = KNOCKBACK_VERTICAL
	if health == 0:
		die()
	else:
		# Vanilla hf.java:319 plays getHurtSound (f_) once per landed hit.
		# Subclasses override _play_hurt_sfx to call their species clip.
		_play_hurt_sfx()
	return true


# Vanilla Entity.setDead — drop items, play death SFX, start the
# tilt-over animation. Vanilla `hf.h_` increments `O` from 0 to 20
# ticks (1 s) while the renderer applies a 90° Z rotation, then the
# entity is removed from the world. queue_free is deferred to the
# end of the animation; drops + SFX fire NOW so the player doesn't
# have to wait to pick them up.
# Called by Arrow._hit_mob after a successful damage application.
# Vanilla EntityLiving caps at ~14 stuck arrows visually; we use 12
# (`_STUCK_ARROW_MAX`). Stuck arrows are pure render — they don't
# re-damage or block raycasts (no collision shape on them).
#
# `hit_world_pos` + `hit_dir_world` come from arrow.gd's raycast —
# the precise intersection point on the collision shape's surface and
# the arrow's flight direction at impact. Placing the visual there
# (instead of an RNG-random spot on the body) is what makes head-shots
# read as head-shots: vanilla EntityArrow stays embedded at its actual
# impact pose; we mirror that since we despawn the arrow on hit.
func add_stuck_arrow(hit_world_pos: Vector3, hit_dir_world: Vector3) -> void:
	if _dying or _arrows_stuck >= _STUCK_ARROW_MAX:
		return
	_arrows_stuck += 1
	_spawn_stuck_arrow_visual(hit_world_pos, hit_dir_world)


# Place the stuck-arrow pivot AT the raycast hit point, oriented along
# the arrow's flight direction. Pivot -Z points along arrow_dir, so:
#   * shaft (positioned at +Z) trails OUTSIDE the body along -arrow_dir
#   * head (positioned at -Z) buries INSIDE the body along +arrow_dir
# Matches vanilla EntityArrow's embedded pose where the arrow tip is at
# the impact point and the shaft trails back along the flight path.
func _spawn_stuck_arrow_visual(hit_world_pos: Vector3, hit_dir_world: Vector3) -> void:
	var pivot := Node3D.new()
	add_child(pivot)
	pivot.global_position = hit_world_pos
	# Fallback for missing/zero direction (defensive — arrows always
	# carry non-zero velocity at the moment of impact, but a future
	# caller might trigger this). Aim toward the mob's body center.
	var dir: Vector3 = hit_dir_world
	if dir.length_squared() < 0.0001:
		var hh: float = maxf(_get_body_height() * 0.5, 0.1)
		var body_center: Vector3 = global_position + Vector3(0.0, hh, 0.0)
		dir = body_center - hit_world_pos
		if dir.length_squared() < 0.0001:
			dir = Vector3(0.0, 0.0, -1.0)
	dir = dir.normalized()
	# Up vector — Y axis unless the arrow's nearly vertical (look_at
	# fails when target direction is parallel to up). Pick a sideways
	# fallback in that edge case.
	var up: Vector3 = Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.RIGHT
	pivot.look_at(hit_world_pos + dir, up)
	# Shaft — narrow brown box stretched along -Z. Placed forward of
	# the pivot so most of the shaft sticks OUT (more visible) with
	# the tip burying into the body.
	var shaft := MeshInstance3D.new()
	var shaft_box := BoxMesh.new()
	shaft_box.size = Vector3(0.03, 0.03, 0.3)
	shaft.mesh = shaft_box
	shaft.position = Vector3(0.0, 0.0, 0.08)
	var shaft_mat := StandardMaterial3D.new()
	shaft_mat.albedo_color = Color(0.55, 0.40, 0.25)
	shaft_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shaft.material_override = shaft_mat
	pivot.add_child(shaft)
	# Tiny grey head box. Sits at the end that's buried into the body
	# (local -Z direction from the shaft).
	var head := MeshInstance3D.new()
	var head_box := BoxMesh.new()
	head_box.size = Vector3(0.05, 0.05, 0.05)
	head.mesh = head_box
	head.position = Vector3(0.0, 0.0, -0.08)
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.65, 0.65, 0.7)
	head_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	head.material_override = head_mat
	pivot.add_child(head)
	_stuck_arrows.append(pivot)


# Tick the decay timer; remove the oldest stuck arrow when one falls
# off. Vanilla decays 1 stuck arrow every ~600 ticks (= 30s @ 20 tps);
# matches `_STUCK_ARROW_DECAY_SEC`. Called from `_process`.
func _tick_stuck_arrow_decay(delta: float) -> void:
	if _arrows_stuck == 0:
		return
	_stuck_arrow_decay_accum += delta
	if _stuck_arrow_decay_accum < _STUCK_ARROW_DECAY_SEC:
		return
	_stuck_arrow_decay_accum = 0.0
	_arrows_stuck = maxi(0, _arrows_stuck - 1)
	if _stuck_arrows.is_empty():
		return
	var oldest: Node3D = _stuck_arrows.pop_front()
	if is_instance_valid(oldest):
		oldest.queue_free()


func die() -> void:
	if _dying:
		return
	_dying = true
	_death_time = 0.0
	_play_death_sfx()
	_spawn_drops()
	# Vanilla EntityLiving.onDeath drops stuck arrows alongside the
	# normal loot. We just clear the visual since no Arrow entities
	# are tracked here (they queue_free'd on hit).
	for s: Node3D in _stuck_arrows:
		if is_instance_valid(s):
			s.queue_free()
	_stuck_arrows.clear()
	_arrows_stuck = 0


# Advance the death tilt animation — vanilla `ec.java` lines 40-43:
#   f4 = sqrt((O + partialTick - 1) / 20 × 1.6)
#   f4 = min(f4, 1.0)
#   rotation_z = f4 × 90°
# The sqrt curve + 1.6× scaling means the mob reaches the full 90°
# tilt at O=12.5 ticks (~0.625 s) and HOLDS that pose for the
# remaining ~0.375 s before despawning at O=20 ticks. The fast
# initial fall + held tilted pose reads as "violent collapse" vs the
# slow linear lerp we had before (which felt mushy).
func _tick_death_animation(delta: float) -> void:
	_death_time += delta
	var raw_t: float = (_death_time / _DEATH_DURATION) * 1.6
	var t: float = clampf(sqrt(raw_t), 0.0, 1.0)
	rotation.z = _DEATH_TILT_ANGLE * t
	if _death_time >= _DEATH_DURATION:
		queue_free()


# Per-species SFX hooks. Base = no-op (test_mob is silent). Subclasses
# override with calls into SFX (e.g. SFX.play_pig_say). Three points:
#   _play_idle_sfx — called from a periodic ambient tick (vanilla rolls
#     1/80 per random tick; we'll plumb in M1b alongside AI).
#   _play_hurt_sfx — called from take_damage when a hit lands.
#   _play_death_sfx — called from die() before queue_free.
func _play_idle_sfx() -> void:
	pass


func _play_hurt_sfx() -> void:
	pass


func _play_death_sfx() -> void:
	pass


# Spawn the configured drop item(s) at the mob's position. Mirrors
# Entity.dropItem with a count rolled from [min, max].
func _spawn_drops() -> void:
	if drop_item_id == 0 or drop_count_max <= 0 or _chunk_manager == null:
		return
	var count: int = randi_range(drop_count_min, drop_count_max)
	for _i in range(count):
		var item := DroppedItem.new()
		_chunk_manager.add_child(item)
		# Small upward + random horizontal kick so drops scatter slightly
		# from the corpse position rather than stacking on one cell.
		var jitter := Vector3(randf_range(-0.2, 0.2), 0.3, randf_range(-0.2, 0.2))
		item.global_position = global_position + Vector3(0, 0.4, 0) + jitter
		item.setup(drop_item_id)


# Tint every MeshInstance3D descendant red for _HURT_FLASH_SEC. Stores
# the original material_override so we can restore it after the flash.
func _apply_hurt_flash() -> void:
	_clear_hurt_flash()  # idempotent — restore any pre-existing flash
	_hurt_flash_remaining = _HURT_FLASH_SEC
	var hurt_mat := StandardMaterial3D.new()
	hurt_mat.albedo_color = Color(1.0, 0.4, 0.4, 1.0)
	hurt_mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	for mi in _find_mesh_instances(self):
		_hurt_mat_overrides.append([mi, mi.material_override])
		mi.material_override = hurt_mat


func _clear_hurt_flash() -> void:
	for pair in _hurt_mat_overrides:
		var mi: MeshInstance3D = pair[0]
		if is_instance_valid(mi):
			mi.material_override = pair[1]
	_hurt_mat_overrides.clear()


# Vanilla `EntityRenderer.setBrightness` — entity colors are texture ×
# world.getBrightnessForRender(cell). Mirror that by sampling the cell
# at the mob's body center every frame and pushing the result into
# every StandardMaterial3D.albedo_color descendant. Same EntityLighting
# helper the player + boat + cart use (0.25 floor, 0.05 → 1.0 LUT) so
# mobs match terrain brightness as time of day passes.
#
# Skipped during hurt flash — the red flash material temporarily owns
# every mesh's material_override, and tinting it grey would visibly
# kill the flash. Resumes on the next frame after _clear_hurt_flash.
func _tick_world_brightness() -> void:
	if _chunk_manager == null:
		return
	if _hurt_flash_remaining > 0.0:
		return
	var cell := Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + _get_body_height() * 0.5)),
		int(floor(global_position.z))
	)
	var lit: float = EntityLighting.sample_brightness(_chunk_manager, cell)
	if absf(lit - _last_lit_brightness) < 0.005:
		return  # imperceptible drift — skip the per-mesh material write
	_last_lit_brightness = lit
	for mi in _find_mesh_instances(self):
		var mat := mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		# Cache the original (pre-tint) albedo the first time we touch
		# this material — otherwise we'd lose it after the first call
		# replaces albedo_color with the tint. Stashed via set_meta on
		# the material itself so each mob's materials stay independent.
		# Without this, solid-color meshes (chicken legs, etc.) had
		# their carefully-chosen color overwritten to grey every frame
		# and rendered as washed-out white in daylight.
		var original: Color
		if mat.has_meta("original_albedo"):
			original = mat.get_meta("original_albedo")
		else:
			original = mat.albedo_color
			mat.set_meta("original_albedo", original)
		# Multiply so textured mats (white texel * lit = lit grey, as
		# before) and solid-color mats (orange-yellow * lit = dimmer
		# orange-yellow) both dim correctly with time of day.
		mat.albedo_color = Color(original.r * lit, original.g * lit, original.b * lit, original.a)


# Recursive child walk — collects every MeshInstance3D under `node`.
static func _find_mesh_instances(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child)
		out.append_array(_find_mesh_instances(child))
	return out


# Persistence hooks — called by EntitySave to round-trip a mob through
# entities.bin. Common fields here (position, velocity, yaw, health);
# subclasses override and call super to add per-mob state (e.g. Pig
# appends `saddled`). Vanilla NBT mobs persist analogous fields:
# Pos[3], Motion[3], Rotation[2], Health (hf.java::b(iq)).
func to_save_dict() -> Dictionary:
	return {
		"pos": global_position,
		"vel": velocity,
		"yaw": rotation.y,
		"hp": health,
	}


# Inverse of to_save_dict. Caller has already added the node to the
# tree + set global_position before calling (so transform-dependent
# state — mainly the collision shape — is valid). Subclasses override
# to consume per-mob fields; always call super so the base does its
# part on the same payload Dictionary.
func restore_from_dict(d: Dictionary) -> void:
	var pos: Vector3 = d.get("pos", global_position) as Vector3
	# Old saves (before the chunk-load physics gate) accumulated mobs
	# launched into the upper atmosphere by penetration-recovery pops
	# during chunk re-meshing — Y values up in the 2000-5000 range. Snap
	# any out-of-world Y to a safe altitude near the world ceiling so
	# they fall back to ground instead of staying stuck up there. Same
	# pattern PlayerSave uses for saves that captured a void plunge.
	if pos.y < 0.0 or pos.y > 128.0:
		pos.y = 120.0
	# Unstick — if the saved Y has the mob's feet INSIDE a solid block
	# (live-spawn or worldgen race could have placed it inside grass),
	# nudge up cell-by-cell until both feet+head cells are clear. Done
	# after the chunk has had a chance to load — call_deferred so
	# get_world_block sees the real terrain, not pre-load AIR.
	global_position = pos
	call_deferred("_unstick_after_load")
	velocity = d.get("vel", Vector3.ZERO)
	rotation.y = d.get("yaw", 0.0)
	health = clampi(d.get("hp", max_health), 0, max_health)


# Push the mob upward until its feet + head cells are both AIR or non-
# opaque (plants / water / leaves). Caps at 8 cells of nudge so a mob
# saved deep underground isn't teleported through 100 cells of stone.
func _unstick_after_load() -> void:
	_unstick_if_buried()


# Vanilla Entity.collideWithEntity port — radial soft push away from any
# overlapping mob. AABB-vs-AABB in XZ only (Y collision doesn't matter for
# walking mobs). Mutates `velocity` rather than position so the push gets
# rolled into the NEXT frame's voxel_move; lets terrain collision still
# clip the push if it would shove into a wall.
#
# Loop is dirt-cheap thanks to the abs() early-out — for 46 active mobs
# spread across a chunk, ~95% of pair iterations skip after 4 ops.


# Diagnostic dump for "AI moving but mob not progressing" bugs. Fires
# only via the Game.debug_enabled gate in _physics_process; the call here
# logs one line with mob species, position, velocity, on_floor state, LOD
# tier, and the 3×3×3 block grid around feet so we can see what (if
# anything) the voxel collider is clipping against. Kept around because
# the chicken-bunched fix is empirical — if it regresses, this is what
# we'd want back to diagnose.
func _dump_stuck_diagnostic(vel_xz: float) -> void:
	var cm: Node = _chunk_manager
	if cm == null:
		cm = get_tree().root.get_node_or_null("Main/ChunkManager")
	var species: String = "unknown"
	if has_meta("mob_name"):
		species = str(get_meta("mob_name"))
	else:
		species = get_script().resource_path.get_file().get_basename()
	var pos: Vector3 = global_position
	var half: Vector3 = _voxel_half_extents()
	var fx: int = int(floor(pos.x))
	var fy: int = int(floor(pos.y))
	var fz: int = int(floor(pos.z))
	# 3×3 grid at feet-1 / feet / feet+1 — surfaces a buried mob,
	# a wall right beside it, or a stair/half-block clipping issue.
	var cells: PackedStringArray = PackedStringArray()
	if cm != null and cm.has_method("get_world_block"):
		for ly in [fy - 1, fy, fy + 1]:
			var row: PackedStringArray = PackedStringArray()
			for lz in [fz - 1, fz, fz + 1]:
				var col: PackedStringArray = PackedStringArray()
				for lx in [fx - 1, fx, fx + 1]:
					col.append(str(cm.get_world_block(Vector3i(lx, ly, lz))))
				row.append(",".join(col))
			cells.append("y=%d:[%s]" % [ly, " / ".join(row)])
	print(
		(
			"[STUCK] %s @(%.2f,%.2f,%.2f) vel_xz=%.2f on_floor=%s half=(%.2f,%.2f,%.2f) tier=%d cells=%s"
			% [
				species,
				pos.x,
				pos.y,
				pos.z,
				vel_xz,
				str(_voxel_on_floor),
				half.x,
				half.y,
				half.z,
				_lod_tier,
				" | ".join(cells),
			]
		)
	)


# Direct position kick for mobs the voxel collider is silently clipping.
# Triggered by the stuck-handler after 2 s of vel-but-no-progress. Moves
# the mob ~5 cm in the direction it's TRYING to go, which is enough to
# escape the "near-zero motion clip in flat AIR" edge case we never
# fully traced. Capped small so we don't shove through nearby walls
# (voxel_move will clip the next frame anyway if we land in a solid
# cell). Safe for all species — only fires when AI has set velocity
# and nothing happens for 2 s straight, which is always a bug.
func _kick_stuck_mob() -> void:
	var vel_xz := Vector2(velocity.x, velocity.z)
	if vel_xz.length_squared() < 0.0001:
		return
	var dir: Vector2 = vel_xz.normalized()
	global_position.x += dir.x * 0.05
	global_position.z += dir.y * 0.05


func _apply_mob_separation() -> void:
	var self_id: int = get_instance_id()
	var self_x: float = global_position.x
	var self_z: float = global_position.z
	var self_radius: float = _voxel_half_extents().x
	for other_id: int in _active_mobs:
		if other_id == self_id:
			continue
		var other = _active_mobs[other_id]
		if other == null or not is_instance_valid(other):
			continue
		# Skip dead/gated mobs — they're not pushing anyone.
		if other._dying or other._physics_gated:
			continue
		var dx: float = self_x - other.global_position.x
		var dz: float = self_z - other.global_position.z
		# Cheap early-out before sqrt: combined half-extents max ~0.7 m, so
		# anything past _MOB_PUSH_QUICK_REJECT trivially can't overlap.
		if absf(dx) > _MOB_PUSH_QUICK_REJECT or absf(dz) > _MOB_PUSH_QUICK_REJECT:
			continue
		var sum_radius: float = self_radius + (other as Node3D)._voxel_half_extents().x
		var dist_sq: float = dx * dx + dz * dz
		if dist_sq > sum_radius * sum_radius:
			continue
		var dist: float = sqrt(dist_sq)
		# Position-direct nudge for ALL overlapping pairs (not just
		# exact-stacked). Velocity-only push was unreliable: friction
		# (~0.89/frame) plus voxel_move clipping small near-zero motion
		# in flat AIR (root cause never traced) consumed the push faster
		# than it accumulated. Chickens specifically stayed locked at
		# 0.06 m separation indefinitely — confirmed in [STUCK] logs.
		# Direct position offset bypasses both. Direction: real positional
		# delta when separated, instance-id hash when exactly stacked
		# (prevents oscillation across multi-mob stacks). Magnitude
		# scales with overlap depth and is capped at 2 cm/frame so we
		# never shove a mob into a nearby wall.
		var dir_x: float
		var dir_z: float
		if dist < 0.01:
			var sign_id: float = signf(float(self_id - other_id))
			var ang: float = fmod(float(absi(self_id - other_id)) * 0.6180339, TAU)
			dir_x = sign_id * cos(ang)
			dir_z = sign_id * sin(ang)
		else:
			dir_x = dx / dist
			dir_z = dz / dist
		var overlap: float = sum_radius - dist
		var sep: float = minf(overlap * 0.1, 0.02)
		global_position.x += dir_x * sep
		global_position.z += dir_z * sep


# Per-frame variant — same algorithm but cheap to call repeatedly
# because the early-out (both cells already clear) is the common case.
# Used by the 2 s periodic check inside _physics_process.
func _unstick_if_buried() -> void:
	var cm: Node = _chunk_manager
	if cm == null:
		cm = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null or not cm.has_method("get_world_block"):
		return
	# Cheap early-out — most calls fire this path because the mob is
	# walking around in air normally.
	var feet_cell := Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	var feet_id: int = cm.get_world_block(feet_cell)
	if not Blocks.is_opaque(feet_id):
		return
	# Stuck — nudge up to 8 cells until clear of opaque terrain.
	for _i: int in range(8):
		var head_cell: Vector3i = feet_cell + Vector3i(0, 1, 0)
		var head_id: int = cm.get_world_block(head_cell)
		feet_id = cm.get_world_block(feet_cell)
		if not Blocks.is_opaque(feet_id) and not Blocks.is_opaque(head_id):
			return
		global_position.y = float(feet_cell.y + 1) + 0.001
		feet_cell = Vector3i(
			int(floor(global_position.x)),
			int(floor(global_position.y)),
			int(floor(global_position.z))
		)
