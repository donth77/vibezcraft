extends Node

# Block-sound playback. Maintains a small pool of AudioStreamPlayer nodes so
# multiple sounds can overlap. Played from a global autoload so callers don't
# need to manage their own player.

const POOL_SIZE: int = 6
const PITCH_JITTER: float = 0.1  # ±10% per play, like vanilla MC

const _DIG_SOUNDS: Dictionary = {
	"stone":
	[
		"res://assets/audio/sfx/Stone_dig1.ogg",
		"res://assets/audio/sfx/Stone_dig2.ogg",
		"res://assets/audio/sfx/Stone_dig3.ogg",
		"res://assets/audio/sfx/Stone_dig4.ogg",
	],
	"grass":
	[
		"res://assets/audio/sfx/Grass_dig1.ogg",
		"res://assets/audio/sfx/Grass_dig2.ogg",
		"res://assets/audio/sfx/Grass_dig3.ogg",
		"res://assets/audio/sfx/Grass_dig4.ogg",
	],
	"wood":
	[
		"res://assets/audio/sfx/Wood_dig1.ogg",
		"res://assets/audio/sfx/Wood_dig2.ogg",
		"res://assets/audio/sfx/Wood_dig3.ogg",
		"res://assets/audio/sfx/Wood_dig4.ogg",
	],
	"sand":
	[
		"res://assets/audio/sfx/Sand_dig1.ogg",
		"res://assets/audio/sfx/Sand_dig2.ogg",
		"res://assets/audio/sfx/Sand_dig3.ogg",
		"res://assets/audio/sfx/Sand_dig4.ogg",
	],
	"gravel":
	[
		"res://assets/audio/sfx/Gravel_dig1.ogg",
		"res://assets/audio/sfx/Gravel_dig2.ogg",
		"res://assets/audio/sfx/Gravel_dig3.ogg",
		"res://assets/audio/sfx/Gravel_dig4.ogg",
	],
}

const _PICKUP_SOUND: String = "res://assets/audio/sfx/Pop.ogg"
const _TOOL_BREAK_SOUND: String = "res://assets/audio/sfx/tool_break.ogg"
# Alpha 1.2.6 `sound3/random/click.ogg` — UI click for menu buttons.
const _CLICK_SOUND: String = "res://assets/audio/sfx/click.ogg"
# Alpha 1.2.6 `sound3/random/fuse.ogg` — TNT/creeper fuse hiss. Played once
# at ignition (vanilla v.java line 45 `cy.a(kr2, "random.fuse", 1.0f, 1.0f)`),
# NOT looped during the 4-second fuse — the audio is a one-shot crackle.
const _FUSE_SOUND: String = "res://assets/audio/sfx/random/fuse.ogg"
# Alpha 1.2.6 `sound3/random/explode{1..4}.ogg` — vanilla picks one
# uniformly per detonation. ks.java::b() pitch jitter envelope is
# `(1 + (rand-rand) × 0.2) × 0.7` ≈ 0.7 ± 0.14, giving the explosion a
# bassy thump rather than the raw clip's mid-range.
const _EXPLODE_SOUNDS: Array = [
	"res://assets/audio/sfx/random/explode1.ogg",
	"res://assets/audio/sfx/random/explode2.ogg",
	"res://assets/audio/sfx/random/explode3.ogg",
	"res://assets/audio/sfx/random/explode4.ogg",
]
# Alpha 1.2.6 `sound3/random/glass{1,2,3}.ogg` — sharp shatter that BlockGlass
# emits on break (StepSoundC.soundOnDestroyed override). The step / place
# sound stays "stone" via _material_for since vanilla glass uses Material.glass
# whose stepSoundName is "step.stone".
const _GLASS_BREAK_SOUNDS: Array = [
	"res://assets/audio/sfx/random/glass1.ogg",
	"res://assets/audio/sfx/random/glass2.ogg",
	"res://assets/audio/sfx/random/glass3.ogg",
]
# Alpha 1.2.6 `sound3/random/chestopen.ogg` + `chestclosed.ogg` — the
# wooden creak vanilla TileEntityChest plays on lid open / close.
# Sourced from the local PrismLauncher Alpha install (mcasset.cloud
# /a1.2.6 has the same files if anyone needs to re-extract). Pitch-jitter
# matches vanilla GuiContainerChest.click which seeds Random per frame.
const _CHEST_OPEN_SOUND: String = "res://assets/audio/sfx/random/chestopen.ogg"
const _CHEST_CLOSE_SOUND: String = "res://assets/audio/sfx/random/chestclosed.ogg"
# Alpha 1.2.6 `newsound/random/door_{open,close}.ogg` — gv.java:98-102
# randomly picks one of the two on every toggle. Pitch jitter 0.9..1.0.
const _DOOR_OPEN_SOUND: String = "res://assets/audio/sfx/random/door_open.ogg"
const _DOOR_CLOSE_SOUND: String = "res://assets/audio/sfx/random/door_close.ogg"
# Alpha 1.2.6 `sound3/random/fizz.ogg` — extracted from
# InventivetalentDev/minecraft-assets @ a1.2.6 (vendor client.jar
# doesn't ship audio; the launcher downloads it on first run). Used
# for lava→obsidian/cobble conversion and lava-contact burn cues.
const _FIZZ_SOUND: String = "res://assets/audio/sfx/fluid/fizz.ogg"
# Alpha 1.2.6 `sound3/fire/fire.ogg` — low crackling loop-able clip.
# Vanilla `qh.java::b(cy,x,y,z,Random)` (BlockFire.randomDisplayTick)
# plays this 1-in-24 per random tick on a FIRE cell at pitch
# `(rand * 0.7 + 0.3)`, volume `1.0 + rand`. We scale similarly below.
const _FIRE_CRACKLE_SOUND: String = "res://assets/audio/sfx/fire/fire.ogg"
# Player damage sounds — vanilla EntityHuman.getHurtSound /
# getFallSound. hit{1,2,3} rotate randomly per hit; fallbig fires when
# the fall damage is > 4, else fallsmall.
const _PLAYER_HIT_SOUNDS: Array = [
	"res://assets/audio/sfx/damage/hit1.ogg",
	"res://assets/audio/sfx/damage/hit2.ogg",
	"res://assets/audio/sfx/damage/hit3.ogg",
]
const _PLAYER_FALL_BIG: String = "res://assets/audio/sfx/damage/fallbig.ogg"
const _PLAYER_FALL_SMALL: String = "res://assets/audio/sfx/damage/fallsmall.ogg"
# Water audio — Alpha a1.2.6 assets (sound3/liquid/). `splash.ogg` fires on
# water entry (`Entity.N()` in Bukkit/mc-dev: plays sound with volume scaled
# by impact speed when `!inWater && justEnteredWater`). `swim1-4.ogg` cycle
# during horizontal motion while submerged — vanilla `Entity.h()` emits
# `game.neutral.swim` on a stride interval tied to travel distance.
const _WATER_SPLASH_SOUND: String = "res://assets/audio/sfx/water/splash.ogg"
const _WATER_SWIM_SOUNDS: Array = [
	"res://assets/audio/sfx/water/swim1.ogg",
	"res://assets/audio/sfx/water/swim2.ogg",
	"res://assets/audio/sfx/water/swim3.ogg",
	"res://assets/audio/sfx/water/swim4.ogg",
]

# Vanilla MC plays step.gravel for hoe tilling, soil step events, etc.
const _GRAVEL_STEP_SOUNDS: Array = [
	"res://assets/audio/sfx/step/gravel1.ogg",
	"res://assets/audio/sfx/step/gravel2.ogg",
	"res://assets/audio/sfx/step/gravel3.ogg",
	"res://assets/audio/sfx/step/gravel4.ogg",
]

# Step sounds — sourced from a1.2.6 newsound/step/. Played as the player
# walks, picked from the variants by material. Quieter than dig sounds.
const _STEP_VOLUME_DB: float = -8.0  # ~vanilla volume relative to dig
const _STEP_SOUNDS: Dictionary = {
	"grass":
	[
		"res://assets/audio/sfx/step/grass1.ogg",
		"res://assets/audio/sfx/step/grass2.ogg",
		"res://assets/audio/sfx/step/grass3.ogg",
		"res://assets/audio/sfx/step/grass4.ogg",
	],
	"stone":
	[
		"res://assets/audio/sfx/step/stone1.ogg",
		"res://assets/audio/sfx/step/stone2.ogg",
		"res://assets/audio/sfx/step/stone3.ogg",
		"res://assets/audio/sfx/step/stone4.ogg",
	],
	"wood":
	[
		"res://assets/audio/sfx/step/wood1.ogg",
		"res://assets/audio/sfx/step/wood2.ogg",
		"res://assets/audio/sfx/step/wood3.ogg",
		"res://assets/audio/sfx/step/wood4.ogg",
	],
	"sand":
	[
		"res://assets/audio/sfx/step/sand1.ogg",
		"res://assets/audio/sfx/step/sand2.ogg",
		"res://assets/audio/sfx/step/sand3.ogg",
		"res://assets/audio/sfx/step/sand4.ogg",
	],
	"cloth":
	[
		"res://assets/audio/sfx/step/cloth1.ogg",
		"res://assets/audio/sfx/step/cloth2.ogg",
		"res://assets/audio/sfx/step/cloth3.ogg",
		"res://assets/audio/sfx/step/cloth4.ogg",
	],
	"gravel":
	[
		"res://assets/audio/sfx/step/gravel1.ogg",
		"res://assets/audio/sfx/step/gravel2.ogg",
		"res://assets/audio/sfx/step/gravel3.ogg",
		"res://assets/audio/sfx/step/gravel4.ogg",
	],
}

var _players: Array = []
var _next_player: int = 0
var _stream_cache: Dictionary = {}


func _ready() -> void:
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


func play_break(block_id: int) -> void:
	# Glass has a dedicated shatter set, not the stone dig variants — vanilla
	# BlockGlass overrides StepSound.soundOnDestroyed to "random.glass*".
	if block_id == Blocks.GLASS:
		var path: String = _GLASS_BREAK_SOUNDS[randi() % _GLASS_BREAK_SOUNDS.size()]
		_play_one(path, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))
		return
	var mat := _material_for(block_id)
	if mat == "":
		return
	_play_random(mat, 1.0)


# Place sound is the same dig sound at slightly lower pitch — vanilla MC trick.
func play_place(block_id: int) -> void:
	var mat := _material_for(block_id)
	if mat == "":
		return
	_play_random(mat, 0.85)


# Vanilla TileEntityChest plays `random.chestopen` on RMB-interact and
# `random.chestclose` when the GUI closes (BlockChest.j → playSoundEffect
# in c.java). Pitch jitter matches the same `rand * 0.1 + 0.9` envelope
# every other random.* sound uses.
func play_chest_open() -> void:
	_play_one(_CHEST_OPEN_SOUND, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


func play_chest_close() -> void:
	_play_one(_CHEST_CLOSE_SOUND, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


# Vanilla gv.java:98-102 — randomly picks door_open or door_close on every
# toggle, with pitch `rand * 0.1 + 0.9`. Not keyed to actual open/close
# state — just a random 50/50 pick per interaction, same as vanilla.
func play_door_toggle() -> void:
	var path: String = _DOOR_OPEN_SOUND if randf() < 0.5 else _DOOR_CLOSE_SOUND
	_play_one(path, 0.0, randf_range(0.9, 1.0))


# Footstep — picks a random variant for the block's material.
func play_step(block_id: int) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var mat := _step_material_for(block_id)
	if mat == "":
		return
	var paths: Array = _STEP_SOUNDS[mat]
	var path: String = paths[randi() % paths.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = _STEP_VOLUME_DB
	player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# Hoe-till "thump" — vanilla MC plays step.gravel here. Pitch + volume
# match BlockSoil.stepSound (volume×0.8, pitch averaged at 1.0).
func play_hoe_till() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var path: String = _GRAVEL_STEP_SOUNDS[randi() % _GRAVEL_STEP_SOUNDS.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = -2.0
	player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# Player "ouch" sound — vanilla EntityHuman.getHurtSound rotates three
# variants and adds pitch jitter. Called whenever the player takes damage
# (not specifically fall damage — that has its own louder sound below).
func play_player_hit() -> void:
	var path: String = _PLAYER_HIT_SOUNDS[randi() % _PLAYER_HIT_SOUNDS.size()]
	_play_one(path, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


# Heavy-fall impact — vanilla branches on > 4 damage: fallbig for big
# falls, fallsmall otherwise. Called INSTEAD of play_player_hit for fall
# damage specifically.
func play_player_fall(damage: int) -> void:
	var path: String = _PLAYER_FALL_BIG if damage > 4 else _PLAYER_FALL_SMALL
	_play_one(path, 0.0, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


func _play_one(path: String, volume_db: float, pitch: float) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.play()


# Water entry splash — vanilla Entity.N() plays `random.splash` when the
# entity transitions from !inWater to inWater (lw.java:160-184). Volume is
# `clamp(sqrt(vx²·0.2 + vy² + vz²·0.2) · 0.2, 0, 1)` — vertical impact
# weighted 5× horizontal so cannonball jumps are loud and gentle wades are
# soft but audible. Pitch jitter is `1.0 + (rand - rand) * 0.4`.
func play_splash(velocity: Vector3) -> void:
	var weighted: float = (
		velocity.x * velocity.x * 0.2 + velocity.y * velocity.y + velocity.z * velocity.z * 0.2
	)
	var f: float = clampf(sqrt(weighted) * 0.2, 0.0, 1.0)
	if f <= 0.0:
		return
	var volume_db: float = linear_to_db(f)
	var pitch: float = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER) * 0.4
	_play_one(_WATER_SPLASH_SOUND, volume_db, pitch)


# Ongoing swim cadence — one random swim sample per stride while the
# player is moving horizontally through water. Vanilla's `Entity.h()`
# cycles `game.neutral.swim` on the same block-travel tracker the footstep
# system uses, so player.gd drives the interval.
func play_swim() -> void:
	var path: String = _WATER_SWIM_SOUNDS[randi() % _WATER_SWIM_SOUNDS.size()]
	_play_one(path, _STEP_VOLUME_DB, 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER))


# Tool snap — vanilla MC's random/break.ogg, played when a tool's
# durability hits zero and the stack is consumed.
func play_tool_break() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_TOOL_BREAK_SOUND)
	if stream == null:
		stream = load(_TOOL_BREAK_SOUND) as AudioStream
		_stream_cache[_TOOL_BREAK_SOUND] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0
	player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# Lava fizzle — fires when a lava cell converts to obsidian/cobble after
# touching water, and also as a one-shot on player-lava contact.
# Mirrors ld.java:257 `random.fizz`. Vanilla's pitch jitter is `2.6 +
# (rand - rand) * 0.8` — treat that as a mean near 2.6× with a ±0.8
# range, same shape we can do with pitch_scale.
func play_fizz(loud: bool = false) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_FIZZ_SOUND)
	if stream == null:
		stream = load(_FIZZ_SOUND) as AudioStream
		_stream_cache[_FIZZ_SOUND] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	# Conversion: loud bubbly hiss. Lava-touch: quieter, shorter-feeling
	# via pitch shift so the two audio cues feel distinct.
	player.volume_db = 0.0 if loud else -6.0
	var base_pitch: float = 2.6 if loud else 1.8
	player.pitch_scale = base_pitch + randf_range(-0.4, 0.4)
	player.play()


# Fire crackle — mirrors vanilla qh.java:186-188 BlockFire.randomDisplayTick:
# 1-in-24 per random tick roll plays this sound at pitch ~0.65 (rand * 0.7
# + 0.3 midpoint). Caller rolls the probability and invokes with the world
# position of the fire cell so distance-attenuation works via AudioStreamPlayer
# position (today we use the non-positional pool for simplicity).
func play_fire_crackle() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_FIRE_CRACKLE_SOUND)
	if stream == null:
		stream = load(_FIRE_CRACKLE_SOUND) as AudioStream
		_stream_cache[_FIRE_CRACKLE_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	# Vanilla pitch: rand(0..1) * 0.7 + 0.3 → [0.3, 1.0], volume 1.0 + rand.
	# Map to our dB range: ~-4 dB midpoint, ± 2 dB jitter.
	player.volume_db = -4.0 + randf_range(-2.0, 2.0)
	player.pitch_scale = randf_range(0.3, 1.0)
	player.play()


# Lava surface pop — vanilla ld.java's randomDisplayTick calls `random.pop`
# alongside the lava spark particle. Reuses the existing pop.ogg stream
# with a muted volume + lower pitch so it reads as a bubble rather than a
# sharp item-pickup cue.
func play_lava_pop() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_PICKUP_SOUND)
	if stream == null:
		stream = load(_PICKUP_SOUND) as AudioStream
		_stream_cache[_PICKUP_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = -8.0
	player.pitch_scale = 0.5 + randf_range(-0.1, 0.1)
	player.play()


# Flint-and-steel ignite — vanilla Alpha 1.2.6 (nv.java) was actually
# SILENT on ignite (the only audio cue was the resulting fire's ambient
# crackle). Modern MC plays `item.flintandsteel.use`, a short metallic
# strike. We use the existing `random.click` asset at slight downward
# pitch (0.9) so the strike reads as a tactile "snap" without sounding
# like a UI button. Swap to a real fire.ignite OGG when a flint-and-
# steel SFX bundle drops in.
func play_flint_and_steel() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_CLICK_SOUND)
	if stream == null:
		stream = load(_CLICK_SOUND) as AudioStream
		_stream_cache[_CLICK_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0
	player.pitch_scale = 0.9
	player.play()


# Menu/button click — vanilla MC plays `random.click` at pitch 1.0 for any
# menu button activation. Pitch is fixed (no jitter) in vanilla so repeated
# clicks read as a single consistent UI cue.
func play_click() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_CLICK_SOUND)
	if stream == null:
		stream = load(_CLICK_SOUND) as AudioStream
		_stream_cache[_CLICK_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0
	player.pitch_scale = 1.0
	player.play()


# Item pickup "pop" — vanilla MC's random/pop.ogg
# TNT fuse hiss — vanilla one-shot at ignition. Pitch jitter ±10% to match
# the random.* family envelope; `loud` controls volume (chained primed-TNT
# in close succession would drown the player's ears at full volume each).
func play_fuse(loud: bool = true) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_FUSE_SOUND)
	if stream == null:
		stream = load(_FUSE_SOUND) as AudioStream
		_stream_cache[_FUSE_SOUND] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0 if loud else -8.0
	player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# TNT/creeper detonation — vanilla picks 1 of 4 explode variants. Pitch
# envelope `(1 + (rand-rand) × 0.2) × 0.7` per ks.java::b() drops the
# clip an octave-ish so the bassy boom reads correctly. `pos` is the
# detonation world coord (unused today; positional 3D audio lands when
# the SFX system sprouts an AudioStreamPlayer3D pool).
func play_explode(_pos: Vector3 = Vector3.ZERO) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var path: String = _EXPLODE_SOUNDS[randi() % _EXPLODE_SOUNDS.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	if stream == null:
		return
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	# Vanilla volume 4.0 — louder than every other random.* sound (which
	# is exactly the drama you want from TNT). Cap at +6 dB so the player's
	# speakers don't clip on a chain detonation.
	player.volume_db = 6.0
	# `(1 + (rand-rand) × 0.2) × 0.7` averages ~0.7 with ±0.14 jitter.
	player.pitch_scale = (1.0 + (randf() - randf()) * 0.2) * 0.7
	player.play()


func play_pickup() -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var stream: AudioStream = _stream_cache.get(_PICKUP_SOUND)
	if stream == null:
		stream = load(_PICKUP_SOUND) as AudioStream
		_stream_cache[_PICKUP_SOUND] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	player.volume_db = 0.0
	# Pitch jitter for variety
	player.pitch_scale = 1.0 + randf_range(-0.15, 0.15)
	player.play()


func _play_random(material: String, base_pitch: float) -> void:
	if not Game.sfx_enabled or Game.is_loading:
		return
	var paths: Array = _DIG_SOUNDS[material]
	var path: String = paths[randi() % paths.size()]
	var stream: AudioStream = _stream_cache.get(path)
	if stream == null:
		stream = load(path) as AudioStream
		_stream_cache[path] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
	# Reset volume in case the player was last used by play_step (which uses
	# a quieter volume_db). Pool reuse means we have to set it every time.
	player.volume_db = 0.0
	player.pitch_scale = base_pitch + randf_range(-PITCH_JITTER, PITCH_JITTER)
	player.play()


# gdlint: disable=max-returns
func _material_for(block_id: int) -> String:
	match block_id:
		Blocks.STONE, Blocks.COBBLESTONE, Blocks.COBBLESTONE_STAIRS, Blocks.BEDROCK, Blocks.BRICK:
			return "stone"
		Blocks.OBSIDIAN, Blocks.COAL_ORE, Blocks.IRON_ORE, Blocks.GOLD_ORE:
			return "stone"
		Blocks.DIAMOND_ORE, Blocks.FURNACE, Blocks.LIT_FURNACE, Blocks.GLASS:
			return "stone"
		Blocks.DIRT, Blocks.GRASS, Blocks.LEAVES, Blocks.SAPLING:
			return "grass"
		Blocks.FLOWER_RED, Blocks.FLOWER_YELLOW, Blocks.MUSHROOM_BROWN, Blocks.MUSHROOM_RED:
			return "grass"
		Blocks.SUGAR_CANE:
			return "grass"
		Blocks.SAND:
			return "sand"
		Blocks.LOG, Blocks.PLANKS, Blocks.CRAFTING_TABLE, Blocks.TORCH:
			return "wood"
		Blocks.CHEST, Blocks.FENCE, Blocks.WOOD_STAIRS, Blocks.WOODEN_DOOR, Blocks.LADDER:
			return "wood"
		Blocks.IRON_DOOR:
			return "stone"
		Blocks.GRAVEL, Blocks.FARMLAND:
			return "gravel"
		Blocks.ICE:
			return "stone"  # vanilla: glass-like shatter; closest in our set
		Blocks.SNOW_BLOCK, Blocks.SNOW_LAYER:
			return "sand"  # vanilla snow uses 'cloth' but sand is closest crunch
		Blocks.CACTUS:
			return "grass"  # vanilla: cloth/grass-like
	return ""


# Step-sound material — diverges from dig: leaves use the soft "cloth"
# variant, not grass-rustle (vanilla MC behavior).
func _step_material_for(block_id: int) -> String:
	if block_id == Blocks.LEAVES:
		return "cloth"
	return _material_for(block_id)
