class_name MobBase
extends CharacterBody3D

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

# Active-mob registry — every MobBase joins on _ready, leaves on
# _exit_tree. Used by MobSpawnerManager._count_nearby_mobs to skip the
# O(chunk_manager.get_children()) walk (which scales with chunk count,
# drops, falling blocks, etc.) in favor of O(active_mobs) which is
# bounded by the spawn cap. Keyed by instance_id for cheap erase.
static var _active_mobs: Dictionary = {}

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
# Death animation state. Once die() fires, _dying=true and _death_time
# counts up from 0. _process applies a linear Z-rotation toward
# _DEATH_TILT_ANGLE; on reaching _DEATH_DURATION the entity is freed.
# AI/physics/damage all gated on `_dying` in subclasses.
var _dying: bool = false
var _death_time: float = 0.0
# Environment state — recomputed per physics_process. _in_water /
# _in_lava are body checks (used for drag + swim); _check_head_in_water
# is sampled separately inside the env tick for drowning.
var _in_water: bool = false
var _in_lava: bool = false
var _env_tick_accum: float = 0.0
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


# Read-only accessor for MobSpawnerManager + future spawn-cap code.
# Returns the raw dictionary; callers iterate values() in their own
# loops to avoid the extra Array allocation.
static func active_mobs() -> Dictionary:
	return _active_mobs


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
	# Sample environment for this frame. Cached on the instance so the
	# env tick (below) can reuse without re-walking voxel cells.
	_in_water = _check_in_water()
	_in_lava = _check_in_lava()
	var in_fire: bool = _check_in_fire()
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
	elif not is_on_floor():
		# Gravity. is_on_floor() is the CharacterBody3D ground test
		# against the collision shape; mobs only fall when airborne.
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
	move_and_slide()
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
	if _damage_cooldown_remaining > 0.0:
		_damage_cooldown_remaining = maxf(0.0, _damage_cooldown_remaining - delta)
	if _hurt_flash_remaining > 0.0:
		_hurt_flash_remaining = maxf(0.0, _hurt_flash_remaining - delta)
		if _hurt_flash_remaining == 0.0:
			_clear_hurt_flash()
	_tick_fire_animation(delta)
	_tick_stuck_arrow_decay(delta)


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
	amount: int, knockback_dir: Vector3 = Vector3.ZERO, knockback_strength: float = 1.0
) -> bool:
	if amount <= 0 or health <= 0:
		return false
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
	global_position = pos
	velocity = d.get("vel", Vector3.ZERO)
	rotation.y = d.get("yaw", 0.0)
	health = clampi(d.get("hp", max_health), 0, max_health)
