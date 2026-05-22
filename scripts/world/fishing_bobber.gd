class_name FishingBobber
extends Node3D

# Vanilla Alpha hj.java port (EntityFishingHook). The bobber is the
# lure cast out by ItemFishingRod (bj.java).
#
# Lifecycle:
#   1. Cast: ItemFishingRod.a() spawns one at player camera position
#      with velocity derived from look direction (× 1.5).
#   2. Flight: gravity 0.04 per tick (~0.8 b/s/s), drag 0.92×, air friction.
#   3. In-water: drag drops to 0.5× (heavier sink), gravity decreases as
#      water-percentage rises. Bobber floats just under surface.
#   4. Bite tick: each in-water tick has 1/500 chance to trigger a "bite"
#      (hj.java:232). Bite duration k = 10-40 ticks (nextInt(30)+10).
#      During bite: bobber dips (aA -= 0.2), plays splash sound, emits
#      bubble + splash particles.
#   5. Reel: ItemFishingRod.a() detects player.fishEntity != null on
#      right-click. If active bite (k > 0), spawns EntityItem (raw_fish)
#      flying toward player at vel (target - pos) × 0.1 + small Y bias.
#      Always damages rod by 1.
#
# Our simplifications:
#   * Single bobber per player (no pooling). Player.fishing_bobber holds
#     the ref; ItemFishingRod.use_item checks for non-null.
#   * Vanilla bite chance simplified to a precomputed wait-for-bite count
#     in [200, 800] ticks (10-40s at 20 TPS, matches vanilla average).
#   * Particles via FluidFx.spawn_water_bubble (existing pool).

const GRAVITY: float = -3.0  # m/s² (mapped from vanilla 0.04/tick * 20² scale)
const DRAG_AIR: float = 0.92
const DRAG_WATER: float = 0.5
const CAST_SPEED: float = 12.0  # m/s — vanilla applies vel * 1.5 from 0.4 base, scaled here
const BITE_CHANCE_PER_TICK: int = 500  # 1/500 vanilla rate per in-water tick
const BITE_DURATION_MIN: int = 10
const BITE_DURATION_RANGE: int = 30

const _BOBBER_SPRITE_PATH: String = "res://assets/textures/entities/packs/alpha_vanilla/bobber.png"
# Vanilla jw.java scales the bobber quad by 0.5 — bobber appears as
# a half-block-tall billboard. Keep this in sync with extract output.
const _BOBBER_WORLD_SIZE: float = 0.5

var velocity: Vector3 = Vector3.ZERO
var _owner_player: Node3D = null
var _chunk_manager: Node = null
var _bite_active: int = 0  # ticks of active-bite remaining
var _in_water: bool = false
# Set true the first tick the bobber transitions out-of-water →
# in-water so we play "random.splash" once at impact (vanilla
# Entity.N() handleWaterMovement behavior).
var _splash_played: bool = false
var _sprite: Sprite3D
var _tick_accum: float = 0.0


# Vanilla bj.java::a spawns hj at player camera pos with velocity
# derived from look direction. We set up the visuals + initial velocity
# here. Caller (interaction.gd) attaches us to the scene root.
func setup(player: Node3D, chunk_manager: Node, camera_pos: Vector3, look_dir: Vector3) -> void:
	_owner_player = player
	_chunk_manager = chunk_manager
	global_position = camera_pos
	# Project bobber 0.4 m forward from the camera so it doesn't spawn
	# inside the player's own head. Then apply cast velocity along look.
	global_position += look_dir * 0.4
	velocity = look_dir.normalized() * CAST_SPEED
	# Vanilla jw.java (RenderFish) pulls an 8×8 tile from particles.png
	# at (8, 16)→(16, 24), scales 0.5 (half-block billboard) and rotates
	# to face the camera each frame. Sprite3D's BILLBOARD_ENABLED gives
	# us the auto-rotation; texture_filter NEAREST keeps the pixel art
	# crisp; pixel_size translates the 8-pixel sprite to 0.5 world units.
	_sprite = Sprite3D.new()
	_sprite.texture = load(_BOBBER_SPRITE_PATH) as Texture2D
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_sprite.pixel_size = _BOBBER_WORLD_SIZE / 8.0  # 8 px sprite → 0.5 m
	# Force transparency (alpha-tested) — the trailing fishing-line
	# pixels are transparent in the sprite, so we want them not to
	# render. Sprite3D defaults to opaque cube around the quad which
	# clobbers depth ordering against water/terrain.
	_sprite.transparent = true
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	# No shadow casting — bobbers are visual-only.
	_sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_sprite)


# Returns true when reeling-in produced a successful catch (i.e. the
# bobber was in active-bite state). Caller (ItemFishingRod handler)
# decides what to drop and damages the rod accordingly. Bobber is
# expected to queue_free after reel.
func reel() -> bool:
	var got_fish: bool = _bite_active > 0
	queue_free()
	return got_fish


# Returns the bobber's current world position — used by the reel
# handler to spawn the dropped raw_fish at the bobber, vanilla style.
func get_bobber_position() -> Vector3:
	return global_position


func _physics_process(delta: float) -> void:
	# Accumulate sub-tick wallclock and advance bite logic at 20 Hz
	# (vanilla tick rate) instead of per render-frame. Without this the
	# 1/500 bite roll fires 3-6× faster on high-refresh monitors.
	_tick_accum += delta
	while _tick_accum >= 0.05:
		_tick_accum -= 0.05
		_tick_in_water_check()
	# Per-frame physics (gravity + drag + position update).
	var drag: float = DRAG_WATER if _in_water else DRAG_AIR
	var g: float = GRAVITY * 0.3 if _in_water else GRAVITY  # water buoyancy
	velocity.x *= drag
	velocity.z *= drag
	velocity.y += g * delta
	velocity.y *= drag
	# Bite dip — vanilla aA -= 0.2 on bite trigger. We apply a one-tick
	# downward impulse when a bite first fires.
	if _bite_active > 0 and _bite_active == BITE_DURATION_MIN + BITE_DURATION_RANGE:
		velocity.y -= 1.5
	global_position += velocity * delta
	# Sanity: despawn if we fall through the world.
	if global_position.y < -20.0:
		queue_free()


# Sample the cell at the bobber's current XYZ. Updates _in_water flag
# and runs the bite countdown / activation roll while in water. Vanilla
# hj.java performs a more nuanced 5-slice water-percentage check; we
# use a single-cell sample which reads close enough at our visual scale.
func _tick_in_water_check() -> void:
	if _chunk_manager == null:
		return
	var cell := Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	var id: int = _chunk_manager.get_world_block(cell)
	var was_in_water: bool = _in_water
	_in_water = (id == Blocks.WATER_STILL or id == Blocks.WATER_FLOWING)
	if not _in_water:
		return
	# First-tick transition out-of-water → in-water: play the impact
	# splash that vanilla's Entity.N() (handleWaterMovement) fires for
	# any Entity entering a water cell. Velocity-scaled so a steep cast
	# splashes louder than a gentle one. _splash_played gates so we
	# only fire once even if the bobber wobbles across the surface for
	# several ticks before settling.
	if not was_in_water and not _splash_played:
		_splash_played = true
		SFX.play_splash(velocity)
	# Bite active — count down remaining bite ticks.
	if _bite_active > 0:
		_bite_active -= 1
		return
	# Vanilla hj.java::e_() rolls a 1/500 chance per in-water tick
	# starting immediately on water entry. No initial wait — the
	# expected time to bite is ~25s with high variance (exponential).
	if randi() % BITE_CHANCE_PER_TICK == 0:
		_trigger_bite()


# Bite trigger — vanilla plays "random.splash" + emits bubble + splash
# particles. We map splash to "liquid.water" (closest in our pool) and
# spawn a small puff of bubble particles via the existing FluidFx pool.
func _trigger_bite() -> void:
	_bite_active = BITE_DURATION_MIN + BITE_DURATION_RANGE  # full duration
	# Splash sfx — vanilla "random.splash" plays at 0.25 vol; play_splash
	# scales by velocity^2 internally. Feed a 2.0 Y impulse so the
	# resulting volume is ~-8 dB instead of the -16 dB the previous 0.8
	# magnitude produced (was inaudible over ambient water/footstep).
	SFX.play_splash(Vector3(0, 2.0, 0))
	# Spawn 6-8 bubbles at the bobber surface so the player sees a
	# tell when the bite starts. Existing pool handles emit + cleanup.
	# Upward motion (Y=0.6) — without explicit motion, the bubbles
	# spawn with near-zero velocity and barely move, defeating the
	# "look, fish biting!" cue. Vanilla emits a 1-tall stack of bubble
	# + splash particles that floats up over ~1s, then re-settles.
	var n: int = 6 + randi() % 3
	FluidFx.spawn_water_bubble(_chunk_manager, global_position, Vector3(0, 0.6, 0), n)
